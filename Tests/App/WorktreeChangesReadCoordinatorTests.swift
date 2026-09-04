import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubApp
@testable import GhosthubUI

@Suite("worktree changes read coordinator")
struct WorktreeChangesReadCoordinatorTests {
    @Test("reads are bounded per host")
    func boundedHostConcurrency() async throws {
        let coordinator = WorktreeChangesReadCoordinator(
            globalLimit: 3,
            perHostLimit: 2
        )
        let probe = ConcurrentReadProbe()
        let hostID = UUID()
        let identities = (0 ..< 5).map {
            changesIdentity(hostID: hostID, index: $0)
        }
        let tasks = identities.map { identity in
            Task {
                try await coordinator.load(identity: identity) {
                    try await probe.load(identity)
                }
            }
        }

        await probe.waitUntilStarted(2)
        #expect(await probe.maximumActive == 2)
        #expect(await probe.startedCount == 2)
        await probe.releaseAll()
        for task in tasks {
            _ = try await task.value
        }

        #expect(await probe.maximumActive == 2)
        #expect(await probe.startedCount == 5)
    }

    @Test("reads are bounded across hosts")
    func boundedGlobalConcurrency() async throws {
        let coordinator = WorktreeChangesReadCoordinator(
            globalLimit: 3,
            perHostLimit: 2
        )
        let probe = ConcurrentReadProbe()
        let identities = (0 ..< 6).map {
            changesIdentity(hostID: UUID(), index: $0)
        }
        let tasks = identities.map { identity in
            Task {
                try await coordinator.load(identity: identity) {
                    try await probe.load(identity)
                }
            }
        }

        await probe.waitUntilStarted(3)
        #expect(await probe.maximumActive == 3)
        #expect(await probe.startedCount == 3)
        await probe.releaseAll()
        for task in tasks {
            _ = try await task.value
        }

        #expect(await probe.maximumActive == 3)
        #expect(await probe.startedCount == 6)
    }

    @Test("identical reads share one underlying inspection")
    func coalescesIdenticalReads() async throws {
        let coordinator = WorktreeChangesReadCoordinator(
            globalLimit: 4,
            perHostLimit: 2
        )
        let probe = ConcurrentReadProbe()
        let identity = changesIdentity(hostID: UUID(), index: 1)
        let first = Task {
            try await coordinator.load(identity: identity) {
                try await probe.load(identity)
            }
        }
        let second = Task {
            try await coordinator.load(identity: identity) {
                try await probe.load(identity)
            }
        }

        await probe.waitUntilStarted(1)
        #expect(await probe.startedCount == 1)
        await probe.releaseAll()
        _ = try await first.value
        _ = try await second.value

        #expect(await probe.startedCount == 1)
    }

    @Test("canceling the last waiter cancels its inspection")
    func cancellationStopsInspection() async {
        let coordinator = WorktreeChangesReadCoordinator(
            globalLimit: 1,
            perHostLimit: 1
        )
        let probe = CancellableReadProbe()
        let identity = changesIdentity(hostID: UUID(), index: 1)
        let task = Task {
            try await coordinator.load(identity: identity) {
                try await probe.load()
            }
        }

        await probe.waitUntilStarted()
        task.cancel()
        _ = await task.result
        await probe.waitUntilCanceled()

        #expect(await probe.wasCanceled)
    }

    @Test("a replacement waits for canceled inspection cleanup")
    func replacementWaitsForCancellationDrain() async throws {
        let coordinator = WorktreeChangesReadCoordinator(
            globalLimit: 1,
            perHostLimit: 1
        )
        let probe = CancellationDrainReadProbe()
        let identity = changesIdentity(hostID: UUID(), index: 1)
        let first = Task {
            try await coordinator.load(identity: identity) {
                try await probe.load(identity)
            }
        }

        await probe.waitUntilStarted(1)
        first.cancel()
        _ = await first.result
        let second = Task {
            try await coordinator.load(identity: identity) {
                try await probe.load(identity)
            }
        }
        try await Task.sleep(for: .milliseconds(25))

        #expect(await probe.startedCount == 1)
        #expect(await probe.maximumActive == 1)
        await probe.releaseCancellationDrain()
        _ = try await second.value

        #expect(await probe.startedCount == 2)
        #expect(await probe.maximumActive == 1)
    }

    @Test("a new generation waits for canceled worktree cleanup")
    func generationReplacementWaitsForCancellationDrain() async throws {
        let coordinator = WorktreeChangesReadCoordinator(
            globalLimit: 2,
            perHostLimit: 2
        )
        let probe = CancellationDrainReadProbe()
        let hostID = UUID()
        let worktreeID = UUID()
        let firstIdentity = changesIdentity(
            hostID: hostID,
            worktreeID: worktreeID,
            index: 1
        )
        let replacementIdentity = changesIdentity(
            hostID: hostID,
            worktreeID: worktreeID,
            index: 2
        )
        let first = Task {
            try await coordinator.load(identity: firstIdentity) {
                try await probe.load(firstIdentity)
            }
        }

        await probe.waitUntilStarted(1)
        first.cancel()
        _ = await first.result
        let replacement = Task {
            try await coordinator.load(identity: replacementIdentity) {
                try await probe.load(replacementIdentity)
            }
        }
        try await Task.sleep(for: .milliseconds(25))

        #expect(await probe.startedCount == 1)
        #expect(await probe.maximumActive == 1)
        await probe.releaseCancellationDrain()
        _ = try await replacement.value

        #expect(await probe.startedCount == 2)
        #expect(await probe.maximumActive == 1)
    }
}

private func changesIdentity(
    hostID: UUID,
    worktreeID: UUID = UUID(),
    index: Int
) -> WorktreeChangesIdentity {
    WorktreeChangesIdentity(
        worktreeID: worktreeID,
        hostID: hostID,
        hostRouteKey: "host",
        projectID: UUID(),
        registrationFingerprint: "registration-\(index)",
        repository: "github.com/acme/project",
        path: "/worktrees/\(index)",
        generation: String(format: "%032x", index + 1),
        usesWindowsPaths: false
    )
}

private actor ConcurrentReadProbe {
    private(set) var startedCount = 0
    private(set) var maximumActive = 0
    private var activeCount = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var releasesAreOpen = false

    func load(
        _ identity: WorktreeChangesIdentity
    ) async throws -> WorktreeFileChanges {
        startedCount += 1
        activeCount += 1
        maximumActive = max(maximumActive, activeCount)
        if !releasesAreOpen {
            await withCheckedContinuation { continuation in
                releases.append(continuation)
            }
        }
        activeCount -= 1
        return WorktreeFileChanges(
            repository: identity.repository,
            path: identity.path,
            generation: identity.generation,
            state: .clean,
            summary: .clean,
            files: [],
            observedAt: "now"
        )
    }

    func waitUntilStarted(_ count: Int) async {
        while startedCount < count {
            await Task.yield()
        }
    }

    func releaseAll() {
        releasesAreOpen = true
        let pending = releases
        releases.removeAll()
        for release in pending {
            release.resume()
        }
    }
}

private actor CancellableReadProbe {
    private(set) var wasCanceled = false
    private var started = false

    func load() async throws -> WorktreeFileChanges {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            wasCanceled = true
            throw error
        }
        throw CancellationError()
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func waitUntilCanceled() async {
        while !wasCanceled {
            await Task.yield()
        }
    }
}

private actor CancellationDrainReadProbe {
    private(set) var startedCount = 0
    private(set) var maximumActive = 0
    private var activeCount = 0
    private var cancellationRelease: CheckedContinuation<Void, Never>?

    func load(
        _ identity: WorktreeChangesIdentity
    ) async throws -> WorktreeFileChanges {
        startedCount += 1
        activeCount += 1
        maximumActive = max(maximumActive, activeCount)
        if startedCount == 1 {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await withCheckedContinuation { continuation in
                    cancellationRelease = continuation
                }
                activeCount -= 1
                throw error
            }
        }
        activeCount -= 1
        return WorktreeFileChanges(
            repository: identity.repository,
            path: identity.path,
            generation: identity.generation,
            state: .clean,
            summary: .clean,
            files: [],
            observedAt: "now"
        )
    }

    func waitUntilStarted(_ count: Int) async {
        while startedCount < count {
            await Task.yield()
        }
    }

    func releaseCancellationDrain() {
        cancellationRelease?.resume()
        cancellationRelease = nil
    }
}
