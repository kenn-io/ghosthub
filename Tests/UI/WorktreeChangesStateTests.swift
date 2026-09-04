import Combine
import Darwin
import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("worktree changes state")
struct WorktreeChangesStateTests {
    @Test(
        "polling requires a visible active app except in the isolated demo",
        arguments: [
            (true, true, false, true),
            (true, false, false, false),
            (false, true, false, false),
            (true, false, true, true),
            (false, false, true, false),
        ]
    )
    func pollingEligibility(
        sidebarVisible: Bool,
        applicationActive: Bool,
        permitsBackgroundDemoControl: Bool,
        expected: Bool
    ) {
        #expect(WorktreeChangesPollingEligibility.isEligible(
            sidebarVisible: sidebarVisible,
            applicationActive: applicationActive,
            permitsBackgroundDemoControl: permitsBackgroundDemoControl
        ) == expected)
    }

    @MainActor
    @Test("successful values survive a later failure and recovery")
    func retainedValueTransitions() throws {
        let hostID = UUID()
        var project = ProjectSummary.fixture(hostID: hostID)
        project.scopedKey = "github.com/kenn-io/ghosthub"
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id,
            path: "/repo/topic"
        )
        worktree.generation = "0123456789abcdef0123456789abcdef"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [project],
            worktrees: [worktree]
        )
        let identity = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: worktree.id,
            in: snapshot
        ))
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: worktree.id)
        let request = try #require(store.beginRequest(for: identity))
        store.finishRequest(
            request,
            for: identity,
            result: .success(.init(
                repository: project.scopedKey,
                path: worktree.path,
                generation: worktree.generation!,
                state: .modified,
                summary: .init(modified: 1),
                files: [.init(
                    path: "Sources/App.swift",
                    originalPath: nil,
                    index: nil,
                    worktree: .modified
                )],
                observedAt: "now"
            )),
            publishResult: true,
            filesChanged: true
        )
        let failing = try #require(store.beginRequest(for: identity))
        store.finishRequest(
            failing,
            for: identity,
            result: .failure(TestFailure()),
            publishResult: true,
            filesChanged: false
        )

        let entry = store.entry(for: identity)
        #expect(entry.files.map(\.path) == ["Sources/App.swift"])
        #expect(entry.isStale)
        #expect(entry.errorMessage != nil)
    }

    @MainActor
    @Test("manual refresh during a read queues one follow-up read")
    func manualRefreshQueuesAfterInFlightRead() throws {
        let fixture = try changesFixture()
        let store = WorktreeChangesStore()
        let initial = try #require(store.beginRequest(
            for: fixture.identity
        ))
        store.finishRequest(
            initial,
            for: fixture.identity,
            result: .success(fixture.result),
            publishResult: true,
            filesChanged: true
        )
        let request = try #require(store.beginRequest(
            for: fixture.identity
        ))

        #expect(!store.entry(for: fixture.identity).isLoading)

        store.requestManualRefresh(for: fixture.identity)
        #expect(store.entry(for: fixture.identity).isLoading)
        store.finishRequest(
            request,
            for: fixture.identity,
            result: .success(fixture.result),
            publishResult: true,
            filesChanged: false
        )

        #expect(store.entry(for: fixture.identity).resumeRevision == 1)
        #expect(store.entry(for: fixture.identity).isLoading)

        let followUp = try #require(store.beginRequest(
            for: fixture.identity
        ))
        store.finishRequest(
            followUp,
            for: fixture.identity,
            result: .success(fixture.result),
            publishResult: true,
            filesChanged: false
        )

        #expect(!store.entry(for: fixture.identity).isLoading)
    }

    @MainActor
    @Test("unchanged background refreshes do not republish visible state")
    func unchangedRefreshDoesNotPublish() throws {
        let fixture = try changesFixture()
        let store = WorktreeChangesStore()
        let first = try #require(store.beginRequest(for: fixture.identity))
        store.finishRequest(
            first,
            for: fixture.identity,
            result: .success(fixture.result),
            publishResult: true,
            filesChanged: true
        )
        let counter = ChangeCounter()
        let observation = store.objectWillChange.sink {
            counter.increment()
        }

        let second = try #require(store.beginRequest(for: fixture.identity))
        store.finishRequest(
            second,
            for: fixture.identity,
            result: .success(fixture.result),
            publishResult: true,
            filesChanged: false
        )

        #expect(counter.value == 0)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    @Test("pruning an unchanged inventory does not republish state")
    func unchangedPruneDoesNotPublish() throws {
        let fixture = try changesFixture()
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)
        let request = try #require(store.beginRequest(for: fixture.identity))
        store.finishRequest(
            request,
            for: fixture.identity,
            result: .success(fixture.result),
            publishResult: true,
            filesChanged: true
        )
        let counter = ChangeCounter()
        let observation = store.objectWillChange.sink {
            counter.increment()
        }

        store.prune(keeping: [fixture.identity])

        #expect(counter.value == 0)
        withExtendedLifetime(observation) {}
    }

    @Test("file comparison detects only exact snapshot changes")
    func exactFileComparison() async {
        let first = WorktreeFileChange(
            path: "Sources/App.swift",
            originalPath: nil,
            index: nil,
            worktree: .modified
        )
        let second = WorktreeFileChange(
            path: "Sources/Other.swift",
            originalPath: nil,
            index: .added,
            worktree: nil
        )

        let unchanged = await WorktreeChangesComparison.filesChanged(
            previous: [first],
            current: [first]
        )
        let changed = await WorktreeChangesComparison.filesChanged(
            previous: [first],
            current: [first, second]
        )

        #expect(!unchanged)
        #expect(changed)
    }

    @MainActor
    @Test("collapsed snapshots are retained within a fixed cache budget")
    func collapsedSnapshotCacheIsBounded() throws {
        let store = WorktreeChangesStore()
        var identities: [WorktreeChangesIdentity] = []
        for index in 0 ... 8 {
            let identity = WorktreeChangesIdentity(
                worktreeID: UUID(),
                hostID: UUID(),
                hostRouteKey: "host-\(index)",
                projectID: UUID(),
                registrationFingerprint: "registration-\(index)",
                repository: "github.com/acme/project-\(index)",
                path: "/repo/\(index)",
                generation: String(format: "%032x", index + 1),
                usesWindowsPaths: false
            )
            identities.append(identity)
            store.setExpanded(true, worktreeID: identity.worktreeID)
            let request = try #require(store.beginRequest(for: identity))
            store.finishRequest(
                request,
                for: identity,
                result: .success(.init(
                    repository: identity.repository,
                    path: identity.path,
                    generation: identity.generation,
                    state: .modified,
                    summary: .init(modified: 1),
                    files: [.init(
                        path: "file-\(index)",
                        originalPath: nil,
                        index: nil,
                        worktree: .modified
                    )],
                    observedAt: "now"
                )),
                publishResult: true,
                filesChanged: true
            )
            store.setExpanded(false, worktreeID: identity.worktreeID)
        }

        #expect(!store.entry(for: identities[0]).hasSuccessfulValue)
        for identity in identities.dropFirst() {
            #expect(store.entry(for: identity).hasSuccessfulValue)
        }
    }

    @Test("identity validates repository path and generation")
    func identityValidation() throws {
        let hostID = UUID()
        var project = ProjectSummary.fixture(hostID: hostID)
        project.scopedKey = "github.com/kenn-io/ghosthub"
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id,
            path: "/repo/topic"
        )
        worktree.generation = "0123456789abcdef0123456789abcdef"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [project],
            worktrees: [worktree]
        )
        let identity = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: worktree.id,
            in: snapshot
        ))
        let result = WorktreeFileChanges(
            repository: project.scopedKey,
            path: "/repo/topic",
            generation: worktree.generation!,
            state: .clean,
            summary: .clean,
            files: [],
            observedAt: "now"
        )

        #expect(identity.matches(result: result, in: snapshot))
    }

    @Test("Windows identity accepts drive paths and slash differences")
    func windowsIdentityValidation() throws {
        let hostID = UUID()
        var host = HostSummary.fixture(id: hostID)
        host.platform = .windows
        var project = ProjectSummary.fixture(hostID: hostID)
        project.scopedKey = "github.com/kenn-io/ghosthub"
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id,
            path: #"C:\Users\user-a\ghosthub"#
        )
        worktree.generation = "0123456789abcdef0123456789abcdef"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [worktree]
        )
        let identity = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: worktree.id,
            in: snapshot
        ))
        let result = WorktreeFileChanges(
            repository: project.scopedKey,
            path: "c:/users/user-a/ghosthub",
            generation: worktree.generation!,
            state: .clean,
            summary: .clean,
            files: [],
            observedAt: "now"
        )

        #expect(identity.matches(result: result, in: snapshot))
    }

    @Test("identity changes when the resolved host route changes")
    func identityIncludesHostRoute() throws {
        let hostID = UUID()
        var project = ProjectSummary.fixture(hostID: hostID)
        project.scopedKey = "github.com/kenn-io/ghosthub"
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id,
            path: "/repo/topic"
        )
        worktree.generation = "0123456789abcdef0123456789abcdef"
        let firstHost = HostSummary.fixture(
            id: hostID,
            configKey: "builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@old-builder:2222"
        )
        let replacementHost = HostSummary.fixture(
            id: hostID,
            configKey: "builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@new-builder:2222"
        )
        let firstSnapshot = WorkspaceSnapshot.fixture(
            hosts: [firstHost],
            projects: [project],
            worktrees: [worktree]
        )
        let replacementSnapshot = WorkspaceSnapshot.fixture(
            hosts: [replacementHost],
            projects: [project],
            worktrees: [worktree]
        )

        let first = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: worktree.id,
            in: firstSnapshot
        ))
        let replacement = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: worktree.id,
            in: replacementSnapshot
        ))

        #expect(first != replacement)
        #expect(first.hostRouteKey != replacement.hostRouteKey)
    }

    @MainActor
    @Test("polling loads immediately and delays only after completion")
    func pollingSequence() async throws {
        let fixture = try changesFixture()
        let recorder = PollRecorder()
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)

        await WorktreeChangesPollLoop.run(
            identity: fixture.identity,
            worktree: fixture.worktree,
            store: store,
            currentSnapshot: { fixture.snapshot },
            isEligible: { true },
            load: { _ in
                await recorder.recordLoad()
                return fixture.result
            },
            sleep: { duration in
                await recorder.recordSleep(duration)
                throw CancellationError()
            }
        )

        #expect(await recorder.loadCount == 1)
        #expect(await recorder.sleeps == [WorktreeChangesPollingPolicy.interval])
        #expect(store.entry(for: fixture.identity).hasSuccessfulValue)
    }

    @MainActor
    @Test("polling executes the complete load away from the main thread")
    func pollingLoadsOffMainThread() async throws {
        let fixture = try changesFixture()
        let probe = LoaderThreadProbe()
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)

        await WorktreeChangesPollLoop.run(
            identity: fixture.identity,
            worktree: fixture.worktree,
            store: store,
            currentSnapshot: { fixture.snapshot },
            isEligible: { true },
            load: { _ in
                probe.record(pthread_main_np() != 0)
                return fixture.result
            },
            sleep: { _ in throw CancellationError() }
        )

        #expect(probe.ranOnMainThread == false)
    }

    @MainActor
    @Test("non-retryable failures stop automatic polling")
    func nonRetryableFailureStopsPolling() async throws {
        let fixture = try changesFixture()
        let recorder = PollRecorder()
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)

        await WorktreeChangesPollLoop.run(
            identity: fixture.identity,
            worktree: fixture.worktree,
            store: store,
            currentSnapshot: { fixture.snapshot },
            isEligible: { true },
            load: { _ in throw ClassifiedTestFailure(isRetryable: false) },
            sleep: { duration in
                await recorder.recordSleep(duration)
                throw CancellationError()
            }
        )

        #expect(await recorder.sleeps.isEmpty)
        #expect(store.entry(for: fixture.identity).errorMessage != nil)
    }

    @MainActor
    @Test("non-retryable failures wait for refresh across task restarts")
    func nonRetryableFailureWaitsForManualRefresh() async throws {
        let fixture = try changesFixture()
        let loader = PermanentThenSuccessfulChangesLoader(
            result: fixture.result
        )
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)
        let poll: () async -> Void = {
            await WorktreeChangesPollLoop.run(
                identity: fixture.identity,
                worktree: fixture.worktree,
                store: store,
                currentSnapshot: { fixture.snapshot },
                isEligible: { true },
                load: { _ in try await loader.load() },
                sleep: { _ in throw CancellationError() }
            )
        }

        await poll()
        await poll()

        #expect(await loader.loadCount == 1)
        #expect(!store.entry(for: fixture.identity).hasSuccessfulValue)

        store.requestManualRefresh(for: fixture.identity)
        await poll()

        #expect(await loader.loadCount == 2)
        #expect(store.entry(for: fixture.identity).hasSuccessfulValue)
    }

    @MainActor
    @Test("retryable failures back off before normal polling resumes")
    func retryableFailureBacksOff() async throws {
        let fixture = try changesFixture()
        let loader = RecoveringChangesLoader(result: fixture.result)
        let recorder = PollRecorder()
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)

        await WorktreeChangesPollLoop.run(
            identity: fixture.identity,
            worktree: fixture.worktree,
            store: store,
            currentSnapshot: { fixture.snapshot },
            isEligible: { true },
            load: { _ in try await loader.load() },
            sleep: { duration in
                await recorder.recordSleep(duration)
                if await recorder.sleeps.count == 3 {
                    throw CancellationError()
                }
            }
        )

        let sleeps = await recorder.sleeps
        #expect(await loader.loadCount == 3)
        #expect(sleeps.count == 3)
        #expect(sleeps[0] > WorktreeChangesPollingPolicy.interval)
        #expect(sleeps[1] > sleeps[0])
        #expect(sleeps[2] == WorktreeChangesPollingPolicy.interval)
    }

    @MainActor
    @Test("a response is discarded when current identity changed")
    func changedIdentityDiscardsResponse() async throws {
        let fixture = try changesFixture()
        var changedSnapshot = fixture.snapshot
        changedSnapshot.projects[0].scopedKey = "github.com/kenn-io/replacement"
        let recorder = PollRecorder()
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)

        await WorktreeChangesPollLoop.run(
            identity: fixture.identity,
            worktree: fixture.worktree,
            store: store,
            currentSnapshot: { changedSnapshot },
            isEligible: { true },
            load: { _ in
                await recorder.recordLoad()
                return fixture.result
            },
            sleep: { duration in
                await recorder.recordSleep(duration)
            }
        )

        #expect(await recorder.loadCount == 1)
        #expect(await recorder.sleeps.isEmpty)
        #expect(!store.entry(for: fixture.identity).hasSuccessfulValue)
    }

    @MainActor
    @Test("a response is discarded when project registration changed")
    func changedRegistrationDiscardsResponse() async throws {
        let fixture = try changesFixture()
        var changedSnapshot = fixture.snapshot
        changedSnapshot.projects[0].registrationFingerprint =
            "replacement-registration"
        let recorder = PollRecorder()
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)

        await WorktreeChangesPollLoop.run(
            identity: fixture.identity,
            worktree: fixture.worktree,
            store: store,
            currentSnapshot: { changedSnapshot },
            isEligible: { true },
            load: { _ in
                await recorder.recordLoad()
                return fixture.result
            },
            sleep: { duration in
                await recorder.recordSleep(duration)
                throw CancellationError()
            }
        )

        #expect(await recorder.loadCount == 1)
        #expect(await recorder.sleeps.isEmpty)
        #expect(!store.entry(for: fixture.identity).hasSuccessfulValue)
    }

    @MainActor
    @Test("generation replacement waits for the in-flight read")
    func generationReplacementDoesNotOverlap() async throws {
        let first = try changesFixture()
        var replacementWorktree = first.worktree
        replacementWorktree.generation =
            "fedcba9876543210fedcba9876543210"
        var replacementSnapshot = first.snapshot
        replacementSnapshot.worktrees = [replacementWorktree]
        let replacementIdentity = try #require(
            WorktreeChangesIdentity.resolve(
                worktreeID: replacementWorktree.id,
                in: replacementSnapshot
            )
        )
        var currentSnapshot = first.snapshot
        let loader = ControlledChangesLoader()
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: first.worktree.id)
        let read: WorktreeChangesLoader = { worktree in
            try await loader.load(worktree)
        }
        let stopAfterDelay: WorktreeChangesSleep = { _ in
            throw CancellationError()
        }

        let firstPoll = Task {
            await WorktreeChangesPollLoop.run(
                identity: first.identity,
                worktree: first.worktree,
                store: store,
                currentSnapshot: { currentSnapshot },
                isEligible: { true },
                load: read,
                sleep: stopAfterDelay
            )
        }
        await loader.waitUntilFirstLoadStarts()
        currentSnapshot = replacementSnapshot
        store.prune(keeping: [replacementIdentity])
        let replacementPoll = Task {
            await WorktreeChangesPollLoop.run(
                identity: replacementIdentity,
                worktree: replacementWorktree,
                store: store,
                currentSnapshot: { currentSnapshot },
                isEligible: { true },
                load: read,
                sleep: stopAfterDelay
            )
        }
        await replacementPoll.value

        #expect(await loader.loadCount == 1)
        #expect(await loader.maximumConcurrentLoads == 1)
        await loader.releaseFirstLoad()
        await firstPoll.value
        #expect(
            store.entry(for: replacementIdentity).resumeRevision == 1
        )

        await WorktreeChangesPollLoop.run(
            identity: replacementIdentity,
            worktree: replacementWorktree,
            store: store,
            currentSnapshot: { currentSnapshot },
            isEligible: { true },
            load: read,
            sleep: stopAfterDelay
        )

        #expect(await loader.loadCount == 2)
        #expect(await loader.maximumConcurrentLoads == 1)
        #expect(
            store.entry(for: replacementIdentity).hasSuccessfulValue
        )
    }

    private func changesFixture() throws -> ChangesFixture {
        let hostID = UUID()
        var project = ProjectSummary.fixture(hostID: hostID)
        project.scopedKey = "github.com/kenn-io/ghosthub"
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id,
            path: "/repo/topic"
        )
        worktree.generation = "0123456789abcdef0123456789abcdef"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [project],
            worktrees: [worktree]
        )
        let identity = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: worktree.id,
            in: snapshot
        ))
        return ChangesFixture(
            snapshot: snapshot,
            worktree: worktree,
            identity: identity,
            result: WorktreeFileChanges(
                repository: project.scopedKey,
                path: worktree.path,
                generation: worktree.generation!,
                state: .clean,
                summary: .clean,
                files: [],
                observedAt: "now"
            )
        )
    }
}

private struct ChangesFixture: Sendable {
    let snapshot: WorkspaceSnapshot
    let worktree: WorktreeSummary
    let identity: WorktreeChangesIdentity
    let result: WorktreeFileChanges
}

private actor PollRecorder {
    private(set) var loadCount = 0
    private(set) var sleeps: [Duration] = []

    func recordLoad() {
        loadCount += 1
    }

    func recordSleep(_ duration: Duration) {
        sleeps.append(duration)
    }
}

private actor ControlledChangesLoader {
    private(set) var loadCount = 0
    private(set) var maximumConcurrentLoads = 0
    private var concurrentLoads = 0
    private var firstLoadStarted = false
    private var firstLoadRelease: CheckedContinuation<Void, Never>?

    func load(_ worktree: WorktreeSummary) async throws
        -> WorktreeFileChanges {
        loadCount += 1
        concurrentLoads += 1
        maximumConcurrentLoads = max(
            maximumConcurrentLoads,
            concurrentLoads
        )
        if loadCount == 1 {
            firstLoadStarted = true
            await withCheckedContinuation { continuation in
                firstLoadRelease = continuation
            }
        }
        concurrentLoads -= 1
        return WorktreeFileChanges(
            repository: "github.com/kenn-io/ghosthub",
            path: worktree.path,
            generation: worktree.generation!,
            state: .clean,
            summary: .clean,
            files: [],
            observedAt: "now"
        )
    }

    func waitUntilFirstLoadStarts() async {
        while !firstLoadStarted {
            await Task.yield()
        }
    }

    func releaseFirstLoad() {
        firstLoadRelease?.resume()
        firstLoadRelease = nil
    }
}

private actor RecoveringChangesLoader {
    private(set) var loadCount = 0
    let result: WorktreeFileChanges

    init(result: WorktreeFileChanges) {
        self.result = result
    }

    func load() throws -> WorktreeFileChanges {
        loadCount += 1
        if loadCount <= 2 {
            throw ClassifiedTestFailure(isRetryable: true)
        }
        return result
    }
}

private actor PermanentThenSuccessfulChangesLoader {
    private(set) var loadCount = 0
    let result: WorktreeFileChanges

    init(result: WorktreeFileChanges) {
        self.result = result
    }

    func load() throws -> WorktreeFileChanges {
        loadCount += 1
        if loadCount == 1 {
            throw ClassifiedTestFailure(isRetryable: false)
        }
        return result
    }
}

private final class LoaderThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var ranOnMainThread: Bool? { lock.withLock { value } }

    func record(_ ranOnMainThread: Bool) {
        lock.withLock { value = ranOnMainThread }
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private struct ClassifiedTestFailure:
    Error, LocalizedError, WorktreeChangesRetryClassifying {
    let isRetryable: Bool
    var errorDescription: String? { "read failed" }
}

private struct TestFailure: Error, LocalizedError {
    var errorDescription: String? { "read failed" }
}
