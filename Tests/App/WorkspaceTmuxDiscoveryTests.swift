import Combine
import Foundation
import GhosthubSettings
import GhosthubTerminal
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Workspace tmux discovery", .serialized)
struct WorkspaceTmuxDiscoveryTests {
    private static let probeNonce = "TEST-NONCE"

    private static func probeOutput(
        _ lines: [String],
        startupOutput: String? = nil
    ) -> String {
        ([startupOutput].compactMap { $0 }
            + ["GHOSTHUB_SSH_PROBE_\(probeNonce)_START"]
            + lines
            + ["GHOSTHUB_SSH_PROBE_\(probeNonce)_END", ""])
            .joined(separator: "\n")
    }

    @Test("workspace refresh includes exe.dev inventory")
    @MainActor
    func workspaceRefreshIncludesExeInventory() async throws {
        let environment = try setupStandardEnvironment()
        let exeRefreshes = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            refreshExeHosts: {
                _ = exeRefreshes.increment()
            }
        )

        model.refreshWorkspaceInventory()

        #expect(exeRefreshes.count == 1)
        await model.shutdown()
    }

    @Test("inventory refresh completion waits for kwt and tmux")
    @MainActor
    func inventoryRefreshCompletionWaitsForBothSources() async throws {
        let environment = try setupStandardEnvironment()
        let kwtGate = KillGate()
        let kwtCompletions = Counter()
        let tmuxGate = BlockingGate()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in
                await kwtGate.suspend()
                _ = kwtCompletions.increment()
                return KwtHostInventory(projects: [])
            },
            tmuxSessionDiscovery: { _ in
                tmuxGate.wait()
                return .success([])
            },
            startServices: true
        )

        await kwtGate.waitUntilStarted()
        await waitUntilMainActor(timeout: .seconds(15)) {
            tmuxGate.didStart
        }
        #expect(!model.isWorkspaceInventoryRefreshComplete)

        await kwtGate.release()
        await waitUntilMainActor(timeout: .seconds(15)) {
            kwtCompletions.count == 1
        }
        #expect(!model.isWorkspaceInventoryRefreshComplete)

        tmuxGate.release()
        await waitUntilMainActor(timeout: .seconds(15)) {
            model.isWorkspaceInventoryRefreshComplete
        }
        #expect(model.isWorkspaceInventoryRefreshComplete)
        await model.shutdown()
    }

    @MainActor
    @Test("authoritative inventory removal closes retained presentation")
    func authoritativeInventoryRemovalClosesRetainedPresentation() async throws {
        let environment = try setupStandardEnvironment()
        let generation = "0123456789abcdef0123456789abcdef"
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation = generation
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let inventoryRemoved = LockedValue(false)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in
                KwtHostInventory(projects: [
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: environment.project.scopedKey,
                            name: environment.project.name,
                            path: environment.project.rootPath,
                            lastTouched: nil
                        ),
                        worktrees: inventoryRemoved.load() ? [] : [
                            KwtWorktreeRecord(
                                path: environment.worktree.path,
                                branch: environment.worktree.branch,
                                commitHash: "",
                                isMain: true,
                                createdAt: nil,
                                generation: generation,
                                repository: environment.project.scopedKey,
                                sessionName: "kwt-ghosthub-main",
                                tmuxSocketName: nil
                            ),
                        ],
                        warning: nil
                    ),
                ])
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
                && model.snapshot.worktrees.count == 1
        }
        let worktree = try #require(model.snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)

        inventoryRemoved.withLock { $0 = true }
        model.refreshKwtInventory()

        await waitUntilMainActor {
            model.snapshot.worktree(id: worktree.id) == nil
                && model.retainedBorrowedTmuxPresentationCount == 0
        }
        #expect(surfaceStore.removedKeys.count == 1)
        #expect(model.activeBorrowedTmuxSelection == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("authoritative inventory latches a retained canonical generation")
    func authoritativeInventoryLatchesRetainedGeneration() async throws {
        let environment = try setupStandardEnvironment()
        let firstGeneration = "0123456789abcdef0123456789abcdef"
        let replacementGeneration = "fedcba9876543210fedcba9876543210"
        let publishedGeneration = LockedValue(firstGeneration)
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation = nil
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in
                KwtHostInventory(projects: [
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: environment.project.scopedKey,
                            name: environment.project.name,
                            path: environment.project.rootPath,
                            lastTouched: nil
                        ),
                        worktrees: [
                            KwtWorktreeRecord(
                                path: environment.worktree.path,
                                branch: environment.worktree.branch,
                                commitHash: "",
                                isMain: true,
                                createdAt: nil,
                                generation: publishedGeneration.load(),
                                repository: environment.project.scopedKey,
                                sessionName: "kwt-ghosthub-main",
                                tmuxSocketName: nil
                            ),
                        ],
                        warning: nil
                    ),
                ])
            },
            startServices: false
        )
        let initial = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )
        model.openBorrowedTmuxSession(initial)
        let originalHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: initial)
        )

        model.startKwtInventory()
        await waitUntilMainActor {
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == firstGeneration
        }
        let enriched = try #require(model.activeBorrowedTmuxSelection)
        #expect(
            model.retainedBorrowedTmuxHandle(for: enriched) == originalHandle
        )

        publishedGeneration.withLock { $0 = replacementGeneration }
        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.snapshot.worktrees[0].generation == replacementGeneration
                && model.retainedBorrowedTmuxPresentationCount == 0
        }
        await model.shutdown()
    }

    @MainActor
    @Test(
        "authoritative replacement waits for explicit reselection",
        arguments: [
            (
                "kwt-ghosthub-replacement",
                "0123456789abcdef0123456789abcdef"
            ),
            (
                "kwt-ghosthub-main",
                "fedcba9876543210fedcba9876543210"
            ),
        ]
    )
    func authoritativeReplacementWaitsForExplicitReselection(
        replacementName: String,
        replacementGeneration: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        let originalGeneration = "0123456789abcdef0123456789abcdef"
        let replacementActive = LockedValue(false)
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation = originalGeneration
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in
                KwtHostInventory(projects: [
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: environment.project.scopedKey,
                            name: environment.project.name,
                            path: environment.project.rootPath,
                            lastTouched: nil
                        ),
                        worktrees: [
                            KwtWorktreeRecord(
                                path: environment.worktree.path,
                                branch: environment.worktree.branch,
                                commitHash: "",
                                isMain: true,
                                createdAt: nil,
                                generation: replacementActive.load()
                                    ? replacementGeneration
                                    : originalGeneration,
                                repository: environment.project.scopedKey,
                                sessionName: replacementActive.load()
                                    ? replacementName
                                    : "kwt-ghosthub-main",
                                tmuxSocketName: nil
                            ),
                        ],
                        warning: nil
                    ),
                ])
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
                && model.snapshot.worktrees.count == 1
        }
        var userSelection = model.selection
        userSelection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        model.selectFromUser(userSelection)
        let original = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(original)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        replacementActive.withLock { $0 = true }
        model.refreshKwtInventory()
        await waitUntilMainActor {
            guard let worktree = model.snapshot.worktree(
                id: environment.worktree.id
            ) else { return false }
            return worktree.tmuxSessionName == replacementName
                && worktree.generation == replacementGeneration
                && model.retainedBorrowedTmuxPresentationCount == 0
        }

        #expect(model.suppressesSelectedWorktreeSessionOpen)
        #expect(surfaceStore.requestCount == 1)

        model.selectFromUser(userSelection)
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        let replacement = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(replacement)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        await model.shutdown()
    }

    private enum CreationKwtFailurePhase: CaseIterable, Sendable {
        case command
        case inventoryRefresh
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class BlockingGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var started = false

        func wait() {
            lock.lock()
            started = true
            lock.unlock()
            semaphore.wait()
        }

        var didStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        func release() {
            semaphore.signal()
        }
    }

    private actor KillGate {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            started = true
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private final class KwtAvailabilityState: @unchecked Sendable {
        private let lock = NSLock()
        private let remoteInventory: KwtHostInventory
        private var remoteKwtAvailable = true
        private var remoteLoads = 0

        init(remoteInventory: KwtHostInventory) {
            self.remoteInventory = remoteInventory
        }

        func load(_ host: TmuxHost) throws -> KwtHostInventory {
            guard host.isRemote else {
                return KwtHostInventory(projects: [])
            }
            lock.lock()
            remoteLoads += 1
            let isAvailable = remoteKwtAvailable
            lock.unlock()
            guard isAvailable else {
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: 127
                )
            }
            return remoteInventory
        }

        func markRemoteKwtUnavailable() {
            lock.lock()
            remoteKwtAvailable = false
            lock.unlock()
        }

        func markRemoteKwtAvailable() {
            lock.lock()
            remoteKwtAvailable = true
            lock.unlock()
        }

        var remoteLoadCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return remoteLoads
        }
    }

    private final class TmuxReachabilityState: @unchecked Sendable {
        private let lock = NSLock()
        private var remoteReachable = true

        func discover(
            _ host: TmuxHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            guard host.isRemote else { return .success([]) }
            lock.lock()
            let isReachable = remoteReachable
            lock.unlock()
            guard isReachable else {
                return .failure(.shellFailed(status: 255))
            }
            return .success([
                DiscoveredTmuxSession(
                    name: "docbank",
                    windowCount: 1,
                    createdAt: "1721552400",
                    managed: false
                ),
            ])
        }

        func markRemoteUnreachable() {
            lock.lock()
            remoteReachable = false
            lock.unlock()
        }
    }

    private final class DelayedTmuxPathState: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var started = false

        func resolve() -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
            lock.lock()
            started = true
            lock.unlock()
            gate.wait()
            return successfulTmuxResolution("/usr/bin/tmux")
        }

        var didStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        func release() {
            gate.signal()
        }
    }

    private final class DiscoveryState: @unchecked Sendable {
        private let lock = NSLock()
        private var failuresRemaining: Int
        private var attempts = 0
        private var startedHosts: [TmuxHost] = []
        private let delayedHost: TmuxHost?

        init(failuresRemaining: Int, delayedHost: TmuxHost? = nil) {
            self.failuresRemaining = failuresRemaining
            self.delayedHost = delayedHost
        }

        func discover(
            _ host: TmuxHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            lock.lock()
            attempts += 1
            startedHosts.append(host)
            let shouldFail = failuresRemaining > 0
            if shouldFail {
                failuresRemaining -= 1
            }
            let shouldDelay = host == delayedHost
            lock.unlock()
            if shouldDelay {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if shouldFail {
                return .failure(.shellFailed(status: 255))
            }
            if shouldDelay {
                return .success([
                    DiscoveredTmuxSession(
                        name: "stale-session",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            }
            return .success([])
        }

        func allowSuccess() {
            lock.lock()
            failuresRemaining = 0
            lock.unlock()
        }

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        func hasStarted(on host: TmuxHost) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return startedHosts.contains(host)
        }
    }

    private final class StaleDiscoveryState: @unchecked Sendable {
        private let lock = NSLock()
        private let firstGate = DispatchSemaphore(value: 0)
        private var calls = 0
        private var didStartFirst = false

        func discover(
            _ host: TmuxHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            lock.lock()
            calls += 1
            let call = calls
            if call == 1 {
                didStartFirst = true
            }
            lock.unlock()
            if call == 1 {
                firstGate.wait()
                return .success([])
            }
            return .success([
                DiscoveredTmuxSession(
                    name: "release-work",
                    windowCount: 1,
                    createdAt: "1721552400",
                    managed: false
                ),
            ])
        }

        var firstStarted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didStartFirst
        }

        func releaseFirst() {
            firstGate.signal()
        }
    }

    private final class CancellableProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var cancelled = false

        func discover(
            _ host: TmuxHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            .failure(waitForCancellation())
        }

        func probe(
            _ target: TmuxSessionProbeTarget
        ) -> Result<Bool, TmuxBinaryError> {
            .failure(waitForCancellation())
        }

        private func waitForCancellation() -> TmuxBinaryError {
            lock.lock()
            started = true
            lock.unlock()
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.001)
            }
            lock.lock()
            cancelled = true
            lock.unlock()
            return .probeCancelled(shell: "test")
        }

        var didStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        var didCancel: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private final class ProfileReconciliationDiscoveryState:
        @unchecked Sendable {
        private let lock = NSLock()
        private let sessionName: String
        private var calls = 0
        private var firstStarted = false
        private var firstCancelled = false

        init(sessionName: String) {
            self.sessionName = sessionName
        }

        func discover(
            _ host: TmuxHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            lock.lock()
            calls += 1
            let call = calls
            if call == 1 {
                firstStarted = true
            }
            lock.unlock()

            switch call {
            case 1:
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                lock.lock()
                firstCancelled = true
                lock.unlock()
                return .failure(.probeCancelled(shell: host.displayName))
            case 2:
                return .success([
                    DiscoveredTmuxSession(
                        name: sessionName,
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            default:
                return .success([])
            }
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        var didStartFirst: Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstStarted
        }

        var didCancelFirst: Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstCancelled
        }
    }

    @MainActor
    @Test("created sessions publish into host inventory immediately")
    func createdSessionPublishesImmediately() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") }
        )

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        ))

        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        model.retryBorrowedTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        ))
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
    }

    @MainActor
    @Test("ordinary worktree navigation attaches without creating")
    func worktreeNavigationUsesAttachMode() throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )

        model.openBorrowedTmuxSession(selection)

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == "0123456789abcdef0123456789abcdef"
        )
    }

    @MainActor
    @Test("switching sessions retains and reuses each presentation")
    func switchingSessionsReusesRetainedPresentations() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "first"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "second"
        )

        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let firstHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: first)
        )

        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let secondHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: second)
        )

        model.openBorrowedTmuxSession(first)
        model.prepareActiveBorrowedTmuxSurface()

        #expect(model.activeBorrowedTmuxSelection == first)
        #expect(model.retainedBorrowedTmuxHandle(for: first) == firstHandle)
        #expect(firstHandle.surfaceID != secondHandle.surfaceID)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(surfaceStore.requestCount == 2)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("switching between remote hosts retains both presentations")
    func switchingRemoteHostsRetainsPresentations() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        let secondHost = HostSummary(
            id: UUID(),
            configKey: "second-builder",
            name: "Second Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "wesm@second-builder",
            preferredTransport: .ssh,
            lastKnownReachable: true
        )
        snapshot.hosts.append(secondHost)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: secondHost.id,
            name: "deploy-work"
        )

        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let firstHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: first)
        )
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        model.openBorrowedTmuxSession(first)

        #expect(model.retainedBorrowedTmuxHandle(for: first) == firstHandle)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(surfaceStore.requestCount == 2)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("explicit close detaches only its retained presentation")
    func explicitCloseDetachesOnlyTargetPresentation() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "first"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "second"
        )
        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        model.closeBorrowedTmuxSession(first)

        #expect(model.retainedBorrowedTmuxHandle(for: first) == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: second) != nil)
        #expect(model.activeBorrowedTmuxSelection == second)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("closed worktree waits for explicit selection before reopening")
    func closedWorktreeWaitsForExplicitSelection() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        var userSelection = model.selection
        userSelection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        model.selectFromUser(userSelection)
        let tmuxSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(tmuxSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        model.closeBorrowedTmuxSession(tmuxSelection)

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(model.suppressesSelectedWorktreeSessionOpen)

        model.synchronizeSelection(userSelection)
        #expect(model.suppressesSelectedWorktreeSessionOpen)
        #expect(surfaceStore.requestCount == 1)

        model.selectFromUser(userSelection)
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        model.openBorrowedTmuxSession(tmuxSelection)
        await waitUntilMainActor { surfaceStore.requestCount == 2 }
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("explicit close dismisses an unresolved-host presentation")
    func explicitCloseDismissesUnresolvedHostPresentation() throws {
        let environment = try setupStandardEnvironment()
        let unresolvedHost = HostSummary(
            id: UUID(),
            configKey: "unresolved-builder",
            name: "Unresolved Builder",
            kind: .remote,
            platform: .linux,
            preferredTransport: .ssh
        )
        var snapshot = environment.snapshot
        snapshot.hosts.append(unresolvedHost)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: unresolvedHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)

        model.closeBorrowedTmuxSession(selection)

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.activeBorrowedTmuxLaunchMode == nil)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
    }

    @MainActor
    @Test("workspace shutdown detaches every retained presentation")
    func shutdownDetachesEveryRetainedPresentation() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        for name in ["first", "second"] {
            model.openBorrowedTmuxSession(.init(
                hostID: environment.host.id,
                name: name
            ))
            await waitUntilMainActor {
                model.prepareActiveBorrowedTmuxSurface()
                return surfaceStore.requestCount ==
                    model.retainedBorrowedTmuxPresentationCount
            }
        }

        await model.shutdown()

        #expect(surfaceStore.removedKeys.count == 2)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
    }

    @MainActor
    @Test("reopening an ended worktree restores establishment mode")
    func endedWorktreeRetryRestoresEstablishmentMode() {
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "kwt-ghosthub-main",
            worktreeID: UUID(),
            worktreePath: "/srv/ghosthub"
        )

        #expect(
            WorkspaceSceneModel.retryLaunchMode(
                for: selection,
                current: .attachOnly,
                sessionConfirmedEnded: true
            ) == .attach
        )
    }

    @MainActor
    @Test("explicit reselection attaches a replaced worktree's session")
    func explicitReselectionAttachesReplacedSession() throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "editor"
        snapshot.worktrees[0].generation =
            "fedcba9876543210fedcba9876543210"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") }
        )
        let observed = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "editor",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef"
        )
        model.openBorrowedTmuxSession(observed)
        #expect(
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == "0123456789abcdef0123456789abcdef"
        )

        var reselection = model.selection
        reselection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        model.selectFromUser(reselection)

        #expect(
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == "fedcba9876543210fedcba9876543210"
        )
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
    }

    @MainActor
    @Test(
        "returning to an inactive replaced worktree invalidates its retained client",
        arguments: [
            (
                "kwt-ghosthub-replacement",
                String?.none,
                "0123456789abcdef0123456789abcdef"
            ),
            (
                "kwt-ghosthub-main",
                Optional("replacement-socket"),
                "0123456789abcdef0123456789abcdef"
            ),
            (
                "kwt-ghosthub-main",
                String?.none,
                "fedcba9876543210fedcba9876543210"
            ),
        ]
    )
    func returningToReplacedWorktreeInvalidatesRetainedClient(
        replacementName: String,
        replacementSocket: String?,
        replacementGeneration: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let worktree = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef"
        )
        let other = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "other"
        )
        model.openBorrowedTmuxSession(worktree)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let originalHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: worktree)
        )
        model.openBorrowedTmuxSession(other)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        var replacement = worktree
        replacement.name = replacementName
        replacement.socketName = replacementSocket
        replacement.worktreeGeneration = replacementGeneration
        model.openBorrowedTmuxSession(replacement)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 3
        }

        #expect(
            model.retainedBorrowedTmuxHandle(for: replacement) != originalHandle
        )
        if replacement.name != worktree.name
            || replacement.socketName != worktree.socketName {
            #expect(model.retainedBorrowedTmuxHandle(for: worktree) == nil)
        }
        #expect(model.activeBorrowedTmuxSelection == replacement)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("discovered worktree session attaches without managed kwt")
    func discoveredWorktreeSessionAttachesDirectly() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        snapshot.hosts[0].remoteDiagnostics = [.missingKwtCapability]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'attach-session'"))
        #expect(!command.contains("'open'"))
        #expect(!command.contains("managed kwt is unavailable"))
    }

    @MainActor
    @Test("cached worktree session uses kwt when the helper is available")
    func cachedWorktreeSessionUsesKwt() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'open'"))
        #expect(command.contains(environment.worktree.path))
    }

    @MainActor
    @Test("kill carries the discovered session identity through confirmation")
    func killUsesConfirmedSessionIdentity() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "training",
                managed: false,
                windows: [],
                serverPID: "31415",
                sessionID: "$8",
                createdAt: "1721552400"
            ),
        ]
        let killedIdentity = LockedValue<TmuxSessionIdentity?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            tmuxSessionKiller: { _, identity, _ in
                killedIdentity.store(identity)
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "training"
        )

        let request = try await model.prepareTmuxSessionKill(selection)
        model.snapshot.hosts[0].tmuxSessions[0].serverPID = "31416"
        try await model.killTmuxSession(request)

        #expect(request.serverPID == "31415")
        #expect(request.sessionID == "$8")
        #expect(request.sessionCreatedAt == "1721552400")
        #expect(killedIdentity.load() == TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        ))
    }

    @MainActor
    @Test("a failed kill leaves the active session attached")
    func failedKillPreservesActiveSession() async throws {
        let environment = try setupStandardEnvironment()
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        let expectedError = TmuxSessionKillError.commandFailed(
            host: "localhost",
            session: selection.name,
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            tmuxSessionKiller: { _, _, _ in
                throw expectedError
            }
        )
        model.selection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        let originalSelection = model.selection
        model.openBorrowedTmuxSession(selection)
        let request = TmuxSessionKillRequest(
            session: selection,
            confirmedHost: try #require(
                model.snapshot.host(id: environment.host.id)
            ),
            serverPID: "31415",
            sessionID: "$42",
            sessionCreatedAt: "1721552400"
        )

        await #expect {
            try await model.killTmuxSession(request)
        } throws: { error in
            error as? TmuxSessionKillError == expectedError
        }

        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.selection == originalSelection)
    }

    @MainActor
    @Test("kill rejects a host endpoint changed after confirmation")
    func killRejectsChangedEndpoint() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let killCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            tmuxSessionKiller: { _, _, _ in
                _ = killCalls.increment()
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher: configuredHosts.eraseToAnyPublisher()
        )
        model.refreshHosts()
        let confirmedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "spark" }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: confirmedHost.id,
            name: "training",
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)
        let request = TmuxSessionKillRequest(
            session: selection,
            confirmedHost: confirmedHost,
            serverPID: "31415",
            sessionID: "$42",
            sessionCreatedAt: "1721552400"
        )

        configuredHosts.value = [
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()

        await #expect {
            try await model.killTmuxSession(request)
        } throws: { error in
            error as? TmuxSessionKillError == .hostChanged(
                session: selection.name
            )
        }
        #expect(killCalls.count == 0)
    }

    @MainActor
    @Test("kill preparation rejects a disconnected active attachment")
    func killPreparationRejectsDisconnectedAttachment() async throws {
        let environment = try setupStandardEnvironment()
        let identityReads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)

        await #expect {
            _ = try await model.prepareTmuxSessionKill(selection)
        } throws: { error in
            error as? TmuxSessionKillError == .sessionNotRunning(
                host: "localhost",
                session: selection.name
            )
        }
        #expect(identityReads.count == 0)
    }

    @MainActor
    @Test("connected attachment supplies protected-session identity")
    func connectedAttachmentSuppliesIdentity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await Task.yield()

        let request = try await model.prepareTmuxSessionKill(selection)

        #expect(request.serverPID == "31415")
        #expect(request.sessionID == "$42")
        #expect(request.sessionCreatedAt == "1721552400")
        #expect(identityReads.count == 1)
    }

    @MainActor
    @Test("connected attachment keeps retrying activity enrollment")
    func connectedAttachmentKeepsRetryingActivityEnrollment() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                let sample = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: sample == 1 ? "baseline" : "changed"
                )
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { selection, host in
                guard identityReads.increment() > 2 else {
                    throw TmuxSessionKillError.sessionNotRunning(
                        host: host.displayName,
                        session: selection.name
                    )
                }
                try await Task.sleep(for: .milliseconds(20))
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController,
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        await waitUntilMainActor(timeout: .milliseconds(250)) {
            identityReads.count == 3
        }
        let start = Date.now
        for tick in 1 ... 400
            where !model.workingTmuxSessionIDs.contains(selection.id) {
            await activityController.sampleWarmSessions(
                at: start.addingTimeInterval(Double(tick))
            )
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(model.workingTmuxSessionIDs == [selection.id])
        await model.shutdown()
    }

    @MainActor
    @Test("an occluded connected attachment still enrolls warm activity")
    func occludedConnectedAttachmentEnrollsWarmActivity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let identityAvailable = LockedValue(false)
        let sampleCounts = LockedValue<[String: Int]>([:])
        let activityController = TmuxSessionActivityController(
            sampler: { selection, _, _ in
                var count = 0
                sampleCounts.withLock { counts in
                    count = (counts[selection.name] ?? 0) + 1
                    counts[selection.name] = count
                }
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: "\(selection.name)-\(count)"
                )
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { selection, host in
                _ = identityReads.increment()
                guard identityAvailable.load() else {
                    throw TmuxSessionKillError.sessionNotRunning(
                        host: host.displayName,
                        session: selection.name
                    )
                }
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController,
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { identityReads.count >= 1 }

        let second = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        identityAvailable.store(true)

        let start = Date.now
        for tick in 1 ... 400
            where !model.workingTmuxSessionIDs.contains(first.id) {
            await activityController.sampleWarmSessions(
                at: start.addingTimeInterval(Double(tick))
            )
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(model.workingTmuxSessionIDs.contains(first.id))
        await model.shutdown()
    }

    @MainActor
    @Test("connected attachment validates stale discovered activity identity")
    func connectedAttachmentValidatesStaleActivityIdentity() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: selection.name,
                managed: false,
                windows: [],
                serverPID: "1111",
                sessionID: "$1",
                createdAt: "1721552300"
            ),
        ]
        let liveIdentity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$42",
            createdAt: "1721552400"
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let sampledIdentities = LockedValue<[TmuxSessionIdentity]>([])
        let activityController = TmuxSessionActivityController(
            sampler: { _, identity, _ in
                sampledIdentities.withLock { $0.append(identity) }
                return identity == liveIdentity
                    ? .sample(
                        paneID: "%2",
                        dimensions: "120x30",
                        fingerprint: "baseline"
                    )
                    : .ended
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return liveIdentity
            },
            tmuxSessionActivityController: activityController,
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        await waitUntilMainActor(timeout: .milliseconds(250)) {
            identityReads.count == 1
        }
        await activityController.sampleWarmSessions()

        #expect(identityReads.count == 1)
        #expect(sampledIdentities.load() == [liveIdentity])
        await model.shutdown()
    }

    @MainActor
    @Test("closing one attachment preserves shared warm activity")
    func closingOneAttachmentPreservesSharedWarmActivity() async throws {
        let environment = try setupStandardEnvironment()
        let firstSurfaceStore = SceneTmuxSurfaceStoreStub()
        let secondSurfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                let sample = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: sample == 1 ? "baseline" : "changed"
                )
            },
            automaticallyPolls: false
        )
        let firstModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: firstSurfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController
        )
        let secondModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: secondSurfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        firstModel.openBorrowedTmuxSession(selection)
        secondModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(
            firstModel,
            store: firstSurfaceStore
        )
        await launchActiveTmuxSurface(
            secondModel,
            store: secondSurfaceStore
        )
        await waitUntilMainActor { identityReads.count == 2 }
        let start = Date.now
        await activityController.sampleWarmSessions(at: start)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(firstModel.workingTmuxSessionIDs == [selection.id])
        #expect(secondModel.workingTmuxSessionIDs == [selection.id])

        let close = try #require(
            firstSurfaceStore.surface.closeObservers.values.first
        )
        close(false, 1)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(25)
        )

        #expect(firstModel.workingTmuxSessionIDs == [selection.id])
        #expect(secondModel.workingTmuxSessionIDs == [selection.id])
        #expect(activitySamples.count == 3)
        await firstModel.shutdown()
        await secondModel.shutdown()
    }

    @MainActor
    @Test("reopening an attachment preserves its warm activity baseline")
    func reopeningAttachmentPreservesWarmActivityBaseline() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                let sample = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: sample == 1 ? "baseline" : "changed"
                )
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { identityReads.count == 1 }
        let start = Date.now
        await activityController.sampleWarmSessions(at: start)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(model.workingTmuxSessionIDs == [selection.id])

        let close = try #require(
            surfaceStore.surface.closeObservers.values.first
        )
        close(false, 1)
        model.closeBorrowedTmuxSession(selection)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        await waitUntilMainActor { identityReads.count == 2 }
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(25)
        )

        #expect(model.workingTmuxSessionIDs == [selection.id])
        #expect(activitySamples.count == 3)
        await model.shutdown()
    }

    @MainActor
    @Test("protected kill availability survives a generation change")
    func protectedKillSurvivesGenerationChange() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        var selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef",
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await Task.yield()

        selection.worktreeGeneration =
            "fedcba9876543210fedcba9876543210"
        let request = try await model.prepareTmuxSessionKill(selection)

        #expect(request.serverPID == "31415")
        #expect(identityReads.count == 1)
    }

    @MainActor
    @Test("kill closes the active attachment across a generation change")
    func killClosesAttachmentAcrossGenerationChange() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "kwt-ghosthub-main",
                managed: false,
                windows: [],
                serverPID: "31415",
                sessionID: "$8",
                createdAt: "1721552400"
            ),
        ]
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            tmuxSessionKiller: { _, _, _ in }
        )
        var selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)

        selection.worktreeGeneration =
            "fedcba9876543210fedcba9876543210"
        let request = try await model.prepareTmuxSessionKill(selection)
        try await model.killTmuxSession(request)

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(
            model.selection.selectedHostID == environment.host.id
        )
    }

    @MainActor
    @Test("an exited tmux client refreshes stale session inventory")
    func exitedClientRefreshesSessionInventory() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let discoveryCalls = Counter()
        let discovered = DiscoveredTmuxSession(
            name: "release-work",
            windowCount: 1,
            serverPID: "31415",
            sessionID: "$42",
            createdAt: "1721552400",
            managed: true
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                discoveryCalls.increment() == 1
                    ? .success([discovered])
                    : .success([])
            }
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            discoveryCalls.count == 1
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map { $0.name } == ["release-work"]
        }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let close = try #require(
            surfaceStore.surface.closeObservers.values.first
        )
        close(true, nil)
        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)

        await waitUntilMainActor {
            discoveryCalls.count >= 2
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        }
        #expect(model.activeBorrowedTmuxSessionIsConfirmedEnded)

        model.retryBorrowedTmuxSession(selection)

        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
    }

    @MainActor
    @Test("a closed client reconnects when discovery finds the session")
    func exitedClientKeepsRunningSessionReconnectable() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let discoveryCalls = Counter()
        let discovered = DiscoveredTmuxSession(
            name: "release-work",
            windowCount: 1,
            serverPID: "31415",
            sessionID: "$42",
            createdAt: "1721552400",
            managed: true
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                _ = discoveryCalls.increment()
                return .success([discovered])
            }
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { discoveryCalls.count == 1 }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let close = try #require(
            surfaceStore.surface.closeObservers.values.first
        )
        close(true, nil)
        await waitUntilMainActor { discoveryCalls.count >= 2 }

        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        model.retryBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
    }

    @MainActor
    @Test("kill completion preserves a session selected while it runs")
    func killCompletionPreservesNewActiveSession() async throws {
        let environment = try setupStandardEnvironment()
        let killGate = KillGate()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            tmuxSessionKiller: { _, _, _ in
                await killGate.suspend()
            }
        )
        let killed = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "training"
        )
        let replacement = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(killed)
        let request = TmuxSessionKillRequest(
            session: killed,
            confirmedHost: try #require(
                model.snapshot.host(id: environment.host.id)
            ),
            serverPID: "31415",
            sessionID: "$42",
            sessionCreatedAt: "1721552400"
        )

        let killTask = Task {
            try await model.killTmuxSession(request)
        }
        await killGate.waitUntilStarted()
        model.openBorrowedTmuxSession(replacement)
        model.selection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        await killGate.release()
        try await killTask.value

        #expect(model.activeBorrowedTmuxSelection == replacement)
        #expect(model.selection.selectedWorktreeID == environment.worktree.id)
    }

    @MainActor
    @Test("kill completion closes the target selected while it runs")
    func killCompletionClosesNewlyActiveTarget() async throws {
        let environment = try setupStandardEnvironment()
        let killGate = KillGate()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "training",
                managed: false,
                windows: []
            ),
        ]
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            tmuxSessionKiller: { _, _, _ in
                await killGate.suspend()
            }
        )
        let killed = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "training"
        )
        let replacement = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(replacement)
        model.selection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        let request = TmuxSessionKillRequest(
            session: killed,
            confirmedHost: try #require(
                model.snapshot.host(id: environment.host.id)
            ),
            serverPID: "31415",
            sessionID: "$42",
            sessionCreatedAt: "1721552400"
        )

        let killTask = Task {
            try await model.killTmuxSession(request)
        }
        await killGate.waitUntilStarted()
        let activeTarget = WorkspaceTmuxSessionSelection(
            hostID: killed.hostID,
            name: killed.name,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(activeTarget)
        await killGate.release()
        try await killTask.value

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.selection.selectedWorktreeID == nil)
    }

    @MainActor
    @Test("explicit creation attaches when inventory already has the name")
    func knownSessionCreationUsesAttachMode() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "release-work",
                managed: false,
                windows: []
            ),
        ]
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "never-run-this"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("attach-session"))
        #expect(!command.contains("new-session"))
        #expect(!command.contains("never-run-this"))
    }

    @MainActor
    @Test("new named creation carries its launch profile command")
    func profileCreationCarriesInitialCommand() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "codex"
        )

        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)

        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("exec codex"))
        await model.shutdown()
    }

    @MainActor
    @Test("explicit close abandons an unlaunched profile creation")
    func explicitCloseAbandonsUnlaunchedProfileCreation() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "codex"
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))

        #expect(surfaceStore.requestCount == 0)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == [selection.name]
        )

        model.closeBorrowedTmuxSession(selection)

        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        )
        #expect(model.retainedBorrowedTmuxHandle(for: selection) == nil)
        #expect(!model.activeBorrowedTmuxRetryRequiresConfirmation)
        await model.shutdown()
    }

    @MainActor
    @Test("confirmed named creation retries in attach mode")
    func confirmedCreationDemotesToAttachMode() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            },
            createdSessionDiscoveryDelays: [.zero]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
        }

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        model.retryBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("creating a closed retained session launches a replacement")
    func creatingClosedRetainedSessionLaunchesReplacement() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let closedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        surfaceStore.surface.closeObservers[closedHandle.id]?(false, 0)

        model.createTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let replacementHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        let command = try #require(surfaceStore.lastConfiguration?.command)

        #expect(replacementHandle != closedHandle)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(command.contains("new-session"))
        await model.shutdown()
    }

    @MainActor
    @Test("reopening an optimistic session preserves creation intent")
    func reopeningCreatedSessionPreservesCreateMode() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: {
                .failure(.notFound(shell: "test"))
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        model.openBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)

        model.retryBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
    }

    @MainActor
    @Test("failed remote provisioning removes the optimistic session")
    func failedRemoteProvisioningRemovesOptimisticSession() async throws {
        let environment = try setupRemoteEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            remoteTmuxPathProvider: { _, _ in
                .failure(.sshConnectionFailed(
                    host: "office-linux",
                    classification: SSHConnectionFailure.classify(
                        status: 255,
                        output: ""
                    )
                ))
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
        }

        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == []
        )
        await model.shutdown()
    }

    @MainActor
    @Test("launched remote creation reconciles before removing its session")
    func launchedRemoteCreationReconcilesBeforeRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        let attempts = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                guard attempts.increment() > 1 else {
                    return .failure(.sshConnectionFailed(
                        host: "office-linux",
                        classification: SSHConnectionFailure.classify(
                            status: 255,
                            output: ""
                        )
                    ))
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            },
            createdSessionDiscoveryDelays: [.milliseconds(100)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let close = try #require(
            surfaceStore.surface.closeObservers.values.first
        )
        close(false, 1)

        await waitUntilMainActor { attempts.count == 1 }
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )

        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
        }
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(attempts.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("protected workspaces never inherit default-server creation")
    func protectedWorkspaceDoesNotReusePendingDefaultSession() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: {
                .failure(.notFound(shell: "test"))
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let defaultSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-workspace-pr-32"
        )
        let protectedSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: defaultSelection.name,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            socketName: "kwt-pr-0123456789abcdef"
        )

        model.createTmuxSession(defaultSelection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)

        model.openBorrowedTmuxSession(protectedSelection)

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
    }

    @MainActor
    @Test("creation discovery follows automatic terminal command launch")
    func createdSessionDiscoveryFollowsAutomaticLaunch() async throws {
        let environment = try setupStandardEnvironment()
        let attempts = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { _ in
                _ = attempts.increment()
                return .success([])
            },
            createdSessionDiscoveryDelays: [.zero],
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState != .loading
        }
        let baselineAttempts = attempts.count

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        ))
        await waitUntilMainActor {
            surfaceStore.requestCount == 1
                && attempts.count > baselineAttempts
        }

        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
        await model.shutdown()
    }

    @MainActor
    @Test("inactive presentation launches when binary resolution completes")
    func inactivePresentationLaunchesAfterPathResolution() async throws {
        let environment = try setupStandardEnvironment()
        let path = DelayedTmuxPathState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: path.resolve
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await waitUntilMainActor { path.didStart }
        model.hideBorrowedTmuxSession(selection)
        path.release()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("path resolution publishes surface readiness for rerender")
    func pathResolutionPublishesSurfaceReadiness() async throws {
        let environment = try setupStandardEnvironment()
        let path = DelayedTmuxPathState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: path.resolve
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        model.prepareActiveBorrowedTmuxSurface()
        #expect(surfaceStore.requestCount == 0)
        await waitUntilMainActor { path.didStart }

        var updateCount = 0
        let updates = model.objectWillChange.sink { updateCount += 1 }
        path.release()
        await waitUntilMainActor { updateCount > 0 }

        model.prepareActiveBorrowedTmuxSurface()
        #expect(surfaceStore.requestCount == 1)
        withExtendedLifetime(updates) {}
        await model.shutdown()
    }

    @MainActor
    @Test("detaching a created session retries discovery before removal")
    func createdSessionReconcilesBeforeDetachRemoval() async throws {
        let environment = try setupStandardEnvironment()
        let attempts = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                guard attempts.increment() >= 3 else {
                    return .success([])
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)

        await waitUntilMainActor(timeout: .seconds(4)) {
            model.pendingCreatedTmuxSessionCount == 0
                && attempts.count >= 3
        }
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
        await model.shutdown()
    }

    @MainActor
    @Test("successful refresh removes an exhausted optimistic creation")
    func successfulRefreshRemovesExhaustedCreation() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = DiscoveryState(failuresRemaining: 100)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [
                .milliseconds(1),
                .milliseconds(2),
            ]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "failed-creation"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.exhaustedCreatedTmuxSessionCount == 1
                && discovery.attemptCount >= 3
        }
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["failed-creation"]
        )

        discovery.allowSuccess()
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        }
        #expect(model.exhaustedCreatedTmuxSessionCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("endpoint changes cancel detached creation discovery")
    func endpointChangeCancelsDetachedCreationDiscovery() async throws {
        let environment = try setupStandardEnvironment()
        let oldTarget = TmuxHost.ssh(SSHHostInfo(
            user: "wesm",
            hostname: "old.example.com",
            port: nil
        ))
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let discovery = DiscoveryState(
            failuresRemaining: 0,
            delayedHost: oldTarget
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            configuredSSHHostsProvider: { configuredHosts.value },
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )
        model.refreshHosts()
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: remoteHost.id,
            name: "stale-session"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            discovery.hasStarted(on: oldTarget)
        }

        configuredHosts.value = [
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(model.exhaustedCreatedTmuxSessionCount == 0)
        let updatedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        #expect(updatedHost.sshDestination == "wesm@new.example.com")
        #expect(updatedHost.tmuxSessions.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("endpoint change invalidates only that host's retained presentations")
    func endpointChangeInvalidatesOnlyAffectedHostPresentations()
        async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "first-builder",
                name: "First Builder",
                platform: .linux,
                sshDestination: "wesm@first-builder"
            ),
            SSHHost(
                configKey: "second-builder",
                name: "Second Builder",
                platform: .linux,
                sshDestination: "wesm@second-builder"
            ),
        ])
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        model.refreshHosts()
        let firstHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "first-builder" }
        )
        let secondHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "second-builder" }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: firstHost.id,
            name: "first"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: secondHost.id,
            name: "second"
        )
        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let secondHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: second)
        )

        configuredHosts.value = [
            SSHHost(
                configKey: "first-builder",
                name: "First Builder",
                platform: .linux,
                sshDestination: "wesm@replacement-builder"
            ),
            SSHHost(
                configKey: "second-builder",
                name: "Second Builder",
                platform: .linux,
                sshDestination: "wesm@second-builder"
            ),
        ]
        model.refreshHosts()

        #expect(model.retainedBorrowedTmuxHandle(for: first) == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: second) == secondHandle)
        #expect(model.activeBorrowedTmuxSelection == second)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("endpoint changes retire warm activity on the former host")
    func endpointChangeRetiresWarmActivity() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                let sample = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: sample == 1 ? "baseline" : "changed"
                )
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            configuredSSHHostsProvider: { configuredHosts.value },
            tmuxSessionActivityController: activityController
        )
        model.refreshHosts()
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        let oldEndpoint = try #require(TmuxHostResolver.resolve(remoteHost))
        let selection = WorkspaceTmuxSessionSelection(
            hostID: remoteHost.id,
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        activityController.warm(
            selection,
            identity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1721552400"
            ),
            on: oldEndpoint,
            at: start
        )
        await activityController.sampleWarmSessions(at: start)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(model.workingTmuxSessionIDs == [selection.id])

        configuredHosts.value = [
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(40)
        )

        #expect(model.workingTmuxSessionIDs.isEmpty)
        #expect(activitySamples.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("a new scene retires warm activity for reconfigured endpoints")
    func newSceneRetiresWarmActivityForReconfiguredEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                _ = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: "baseline"
                )
            },
            automaticallyPolls: false
        )
        let firstScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            configuredSSHHostsProvider: { configuredHosts.value },
            tmuxSessionActivityController: activityController
        )
        firstScene.refreshHosts()
        let remoteHost = try #require(
            firstScene.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        let oldEndpoint = try #require(TmuxHostResolver.resolve(remoteHost))
        let selection = WorkspaceTmuxSessionSelection(
            hostID: remoteHost.id,
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        activityController.warm(
            selection,
            identity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1721552400"
            ),
            on: oldEndpoint,
            at: start
        )
        await activityController.sampleWarmSessions(at: start)
        #expect(activitySamples.count == 1)
        await firstScene.shutdown()

        configuredHosts.value = [
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        let secondScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            configuredSSHHostsProvider: { configuredHosts.value },
            tmuxSessionActivityController: activityController,
            startServices: true
        )
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(40)
        )

        #expect(activitySamples.count == 1)
        await secondScene.shutdown()
    }

    @MainActor
    @Test("shutdown cancels detached creation discovery")
    func shutdownCancelsDetachedCreationDiscovery() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = CancellableProbeState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [.zero]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            discovery.didStart
        }

        await model.shutdown()
        await waitUntilMainActor {
            discovery.didCancel
        }
    }

    @MainActor
    @Test("stale global discovery cannot erase confirmed creation")
    func staleGlobalDiscoveryCannotEraseCreation() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = StaleDiscoveryState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [.milliseconds(1)],
            startServices: true
        )
        defer { discovery.releaseFirst() }
        await waitUntilMainActor {
            discovery.firstStarted
        }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        }

        discovery.releaseFirst()
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
        await model.shutdown()
    }

    @MainActor
    private func launchActiveTmuxSurface(
        _ model: WorkspaceSceneModel,
        store: SceneTmuxSurfaceStoreStub
    ) async {
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return store.requestCount > 0
        }
    }

    @MainActor
    @Test("transport loss automatically reattaches when the session returns")
    func transportLossAutomaticallyReattaches() async throws {
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "ssh: connect to host build-box port 22: Network is unreachable"
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box",
                classification: transport
            )),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work",
                    windowCount: 1,
                    createdAt: nil,
                    managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remoteSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(remoteSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("attach-session")
                == true
        )
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'") == false
        )
        await model.shutdown()
    }

    @MainActor
    @Test("inactive retained presentation continues automatic recovery")
    func inactivePresentationContinuesAutomaticRecovery() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "local-work",
                managed: false,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                if host.isRemote {
                    return .success([
                        DiscoveredTmuxSession(
                            name: "release-work",
                            windowCount: 1,
                            createdAt: nil,
                            managed: false
                        ),
                    ])
                }
                return .success([])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remote = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let local = WorkspaceTmuxSessionSelection(
            hostID: environment.localHostID,
            name: "local-work"
        )
        model.openBorrowedTmuxSession(remote)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let remoteHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: remote)
        )
        let remoteClose = try #require(
            surfaceStore.surface.closeObservers[remoteHandle.id]
        )
        model.openBorrowedTmuxSession(local)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        remoteClose(false, 255)

        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.retainedBorrowedTmuxSessionIsConnected(remote)
        }
        #expect(model.activeBorrowedTmuxSelection == local)
        #expect(model.retainedBorrowedTmuxHandle(for: remote) == remoteHandle)

        model.openBorrowedTmuxSession(remote)
        model.prepareActiveBorrowedTmuxSurface()
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(surfaceStore.requestCount == 3)
        await model.shutdown()
    }

    @MainActor
    @Test("interrupted profile creation never replays its command automatically")
    func interruptedProfileCreationRequiresExplicitRetry() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "codex"
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState == nil
        }

        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(surfaceStore.requestCount == 1)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxRetryRequiresConfirmation)
        #expect(model.activeBorrowedTmuxRetryCommand == "exec codex")

        model.retryBorrowedTmuxSession(selection)
        for _ in 0 ..< 20 {
            model.prepareActiveBorrowedTmuxSurface()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(surfaceStore.requestCount == 1)

        model.retryBorrowedTmuxSessionAfterProfileCommandConfirmation(
            selection
        )
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        #expect(!model.activeBorrowedTmuxRetryRequiresConfirmation)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("exec codex"))
        await model.shutdown()
    }

    @MainActor
    @Test("returning to interrupted profile creation preserves confirmation")
    func returningToInterruptedProfileCreationPreservesConfirmation()
        async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            createdSessionDiscoveryDelays: [
                .milliseconds(10),
                .milliseconds(20),
            ],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "codex"
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let interruptedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState == nil
        }
        #expect(model.activeBorrowedTmuxRetryRequiresConfirmation)

        let replacement = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(replacement)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        model.openBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(
            model.retainedBorrowedTmuxHandle(for: selection)
                == interruptedHandle
        )
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        model.prepareActiveBorrowedTmuxSurface()
        try await Task.sleep(for: .milliseconds(100))

        #expect(surfaceStore.requestCount == 2)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(model.activeBorrowedTmuxRetryRequiresConfirmation)
        #expect(model.activeBorrowedTmuxRetryCommand == "exec codex")

        model.retryBorrowedTmuxSessionAfterProfileCommandConfirmation(
            selection
        )
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 3
        }
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("exec codex"))
        await model.shutdown()
    }

    @MainActor
    @Test("a pre-launch failure preserves a safe profile command retry")
    func preLaunchFailurePreservesProfileCommand() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        surfaceStore.returnsSurface = false
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "codex"
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(!model.activeBorrowedTmuxRetryRequiresConfirmation)

        surfaceStore.returnsSurface = true
        model.retryBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("exec codex"))
        #expect(!model.activeBorrowedTmuxRetryRequiresConfirmation)
        await model.shutdown()
    }

    @MainActor
    @Test("reconciled profile creation never reruns its command")
    func reconciledProfileCreationDoesNotRerunCommand() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "profile-work"
        )
        let discovery = ProfileReconciliationDiscoveryState(
            sessionName: selection.name
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [.milliseconds(20)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "printf ready"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { discovery.didStartFirst }
        await waitUntilMainActor {
            discovery.didCancelFirst
                && model.pendingCreatedTmuxSessionCount == 0
        }

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(surfaceStore.requestCount == 1)
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            discovery.count == 3
                && (model.activeBorrowedTmuxSessionIsConfirmedEnded
                    || surfaceStore.requestCount > 1)
        }

        #expect(discovery.count == 3)
        #expect(surfaceStore.requestCount == 1)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.activeBorrowedTmuxSessionIsConfirmedEnded)
        await model.shutdown()
    }

    @MainActor
    @Test("interrupted profile creation attaches when its session is present")
    func interruptedProfileCreationAttachesWhenPresent() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "profile-work"
        )
        let discovery = ProfileReconciliationDiscoveryState(
            sessionName: selection.name
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "printf ready"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { discovery.didStartFirst }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(discovery.didCancelFirst)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(model.activeBorrowedTmuxLaunchMode == .attachOnly)
        #expect(surfaceStore.requestCount == 2)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("attach-session"))
        #expect(!command.contains("new-session"))
        #expect(!command.contains("printf ready"))
        await model.shutdown()
    }

    @MainActor
    @Test("cached worktree kwt interruption retries establishment")
    func cachedWorktreeInterruptionRetriesEstablishment() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == true
        )

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("resolver timeout remains retryable")
    func resolverTimeoutRemainsRetryable() async throws {
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.probeTimedOut(shell: "build-box")),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work",
                    windowCount: 1,
                    createdAt: nil,
                    managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(discoveries.count == 2)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("default-socket probe deadline preserves reconnecting state")
    func defaultSocketProbeDeadlinePreservesReconnectingState() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let discovery = CancellableProbeState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            tmuxReconnectIntervals: [.seconds(10)],
            tmuxReconnectProbeDeadline: .milliseconds(20)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor { discovery.didCancel }

        #expect(
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        )
        #expect(
            model.snapshot.host(id: environment.remoteHost.id)?
                .lastKnownReachable == true
        )
        #expect(
            model.workspaceInventoryWarningsByHost[
                environment.remoteHost.id
            ] == nil
        )
        await model.shutdown()
    }

    @MainActor
    @Test("creation reconciliation invalidation keeps reconnecting")
    func creationReconciliationInvalidationKeepsReconnecting() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let attempts = Counter()
        let creationGate = BlockingGate()
        let reconnectProbe = CancellableProbeState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                switch attempts.increment() {
                case 1:
                    creationGate.wait()
                case 2:
                    return reconnectProbe.discover(host)
                default:
                    break
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "created-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        defer { creationGate.release() }
        let createdSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "created-work"
        )
        model.createTmuxSession(createdSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let createdObserverIDs = Set(
            surfaceStore.surface.closeObservers.keys
        )
        model.closeBorrowedTmuxSession(createdSelection)
        await waitUntilMainActor { creationGate.didStart }

        let reconnectSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(reconnectSelection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let reconnectObserverID = try #require(
            Set(surfaceStore.surface.closeObservers.keys)
                .subtracting(createdObserverIDs).first
        )
        let reconnectObserver = try #require(
            surfaceStore.surface.closeObservers[reconnectObserverID]
        )
        reconnectObserver(false, 255)
        await waitUntilMainActor { reconnectProbe.didStart }

        creationGate.release()

        await waitUntilMainActor {
            reconnectProbe.didCancel
                && attempts.count == 3
                && surfaceStore.requestCount == 3
                && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(attempts.count == 3)
        #expect(surfaceStore.requestCount == 3)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[
                environment.remoteHost.id
            ] == nil
        )
        #expect(
            model.snapshot.host(id: environment.remoteHost.id)?
                .lastKnownReachable == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("exact probe deadline retries automatically")
    func exactProbeDeadlineRetriesAutomatically() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let attempts = Counter()
        let probe = CancellableProbeState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxExactSessionProbe: { target in
                switch attempts.increment() {
                case 1:
                    return probe.probe(target)
                default:
                    return .success(true)
                }
            },
            tmuxReconnectIntervals: [.milliseconds(1)],
            tmuxReconnectProbeDeadline: .milliseconds(20)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "protected-work",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            probe.didCancel
                && attempts.count == 2
                && surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(attempts.count == 2)
        #expect(surfaceStore.requestCount == 2)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("stale reconnect discovery cannot mutate a replacement endpoint")
    func staleReconnectDiscoveryCannotMutateReplacementEndpoint()
        async throws {
        let environment = try setupStandardEnvironment()
        let oldTarget = TmuxHost.ssh(SSHHostInfo(
            user: "wesm",
            hostname: "old.example.com",
            port: nil
        ))
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let discoveryGate = BlockingGate()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                #expect(host == oldTarget)
                discoveryGate.wait()
                return .success([
                    DiscoveredTmuxSession(
                        name: "stale-session",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        defer { discoveryGate.release() }
        model.refreshHosts()
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: remoteHost.id,
            name: "stale-session"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor { discoveryGate.didStart }

        configuredHosts.value = [
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()
        discoveryGate.release()
        try await Task.sleep(for: .milliseconds(100))

        let updatedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        #expect(updatedHost.sshDestination == "wesm@new.example.com")
        #expect(updatedHost.tmuxSessions.isEmpty)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("Reconnect Now interrupts the scene supervisor wait")
    func reconnectNowInterruptsSceneWait() async throws {
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "Network is unreachable"
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box", classification: transport
            )),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work", windowCount: 1,
                    createdAt: nil, managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor { discoveries.count == 1 }

        model.reconnectActiveTmuxSessionNow()

        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }
        await model.shutdown()
    }

    @MainActor
    @Test("default-socket absence ends a confirmed session")
    func defaultSocketAbsenceEndsSession() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConfirmedEnded
        }
        #expect(surfaceStore.requestCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("interrupted establishment clears provisional ended state")
    func interruptedEstablishmentClearsEndedState() async throws {
        let environment = try setupRemoteEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionName = "kwt-ghosthub-main"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("recovery continues when discovery confirms establishment")
    func discoveryConfirmationContinuesEstablishmentRecovery() async throws {
        let environment = try setupRemoteEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionName = "kwt-ghosthub-main"
        let discoveries = TmuxDiscoveryResultQueue([
            .success([]),
            .success([
                DiscoveredTmuxSession(
                    name: sessionName,
                    windowCount: 1,
                    createdAt: nil,
                    managed: true
                ),
            ]),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { discoveries.count == 1 }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            discoveries.count == 2
                && surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(
            surfaceStore.lastConfiguration?.command?
                .contains("attach-session") == true
        )
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == false
        )
        await model.shutdown()
    }

    @MainActor
    @Test("a failed replacement stops promising automatic recovery")
    func failedReplacementStopsAutomaticRecovery() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.launchError = SceneSurfaceLaunchError.rejected

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxRecoveryState == nil
        }

        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        model.reconnectActiveTmuxSessionNow()
        try await Task.sleep(for: .milliseconds(25))
        #expect(surfaceStore.requestCount == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("protected-socket absence ends without probing through a surface")
    func protectedSocketAbsenceEndsWithoutSurface() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let probes = TmuxExactProbeResultQueue([.success(false)])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxExactSessionProbe: { _ in probes.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "protected-work",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let endedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConfirmedEnded
        }
        #expect(probes.count == 1)
        #expect(surfaceStore.requestCount == 1)

        let local = WorkspaceTmuxSessionSelection(
            hostID: environment.localHostID,
            name: "local-work"
        )
        model.openBorrowedTmuxSession(local)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        model.openBorrowedTmuxSession(selection)
        model.prepareActiveBorrowedTmuxSurface()

        #expect(model.retainedBorrowedTmuxHandle(for: selection) == endedHandle)
        #expect(model.activeBorrowedTmuxSessionIsConfirmedEnded)
        #expect(surfaceStore.requestCount == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("protected kwt interruption retries establishment")
    func protectedKwtInterruptionRetriesEstablishment() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let probes = TmuxExactProbeResultQueue([
            .success(false),
            .success(false),
            .success(false),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxExactSessionProbe: { _ in probes.removeFirst() },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "protected-work",
            worktreePath: "/srv/ghosthub-pr-42",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConnected
        }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        await model.shutdown()
    }

    @MainActor
    @Test("protected recovery stays direct and attach-only")
    func protectedRecoveryUsesAttachOnly() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let probes = TmuxExactProbeResultQueue([.success(true)])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxExactSessionProbe: { _ in probes.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "protected-work",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("attach-session"))
        #expect(command.contains("kwt-pr-0123456789abcdef"))
        #expect(!command.contains(" pr attach "))
        await model.shutdown()
    }

    @MainActor
    @Test("authentication failure pauses and requests native recovery")
    func authenticationFailureRequestsRecovery() async throws {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "Permission denied (publickey,password)."
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box", classification: classification
            )),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            model.tmuxConnectionRecoveryRequest != nil
        }
        #expect(
            model.tmuxConnectionRecoveryRequest?.hostID
                == environment.remoteHost.id
        )
        guard case .needsAttention(_, true) =
            model.activeBorrowedTmuxRecoveryState
        else {
            Issue.record("Expected reviewable attention state")
            await model.shutdown()
            return
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(discoveries.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("successful SSH recovery resumes its inactive presentation")
    func sshRecoveryResumesInactivePresentation() async throws {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "Permission denied (publickey,password)."
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box", classification: classification
            )),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work", windowCount: 1,
                    createdAt: nil, managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "local-work",
                managed: false,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                host.isRemote ? discoveries.removeFirst() : .success([])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remote = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let local = WorkspaceTmuxSessionSelection(
            hostID: environment.localHostID,
            name: "local-work"
        )
        model.openBorrowedTmuxSession(remote)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let remoteHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: remote)
        )
        surfaceStore.surface.closeObservers[remoteHandle.id]?(false, 255)
        await waitUntilMainActor {
            model.tmuxConnectionRecoveryRequest != nil
        }
        let recoveryRequest = try #require(
            model.tmuxConnectionRecoveryRequest
        )

        model.openBorrowedTmuxSession(local)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        model.resumeTmuxReconnectAfterSSHRecovery(recoveryRequest)

        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.retainedBorrowedTmuxSessionIsConnected(remote)
        }
        #expect(model.activeBorrowedTmuxSelection == local)
        #expect(model.retainedBorrowedTmuxHandle(for: remote) == remoteHandle)
        await model.shutdown()
    }

    @MainActor
    @Test("unresolved host does not inherit retained recovery state")
    func unresolvedHostDoesNotInheritRetainedRecoveryState() async throws {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "Permission denied (publickey,password)."
        )
        let environment = try setupRemoteTmuxEnvironment()
        let unresolvedHost = HostSummary(
            id: UUID(),
            configKey: "unresolved-builder",
            name: "Unresolved Builder",
            kind: .remote,
            platform: .linux,
            preferredTransport: .ssh
        )
        var snapshot = environment.snapshot
        snapshot.hosts.append(unresolvedHost)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                .failure(.sshConnectionFailed(
                    host: "build-box",
                    classification: classification
                ))
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let retained = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(retained)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let retainedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: retained)
        )
        surfaceStore.surface.closeObservers[retainedHandle.id]?(false, 255)
        await waitUntilMainActor {
            model.tmuxConnectionRecoveryRequest != nil
        }

        let unresolved = WorkspaceTmuxSessionSelection(
            hostID: unresolvedHost.id,
            name: "unavailable-work"
        )
        model.openBorrowedTmuxSession(unresolved)

        #expect(model.activeBorrowedTmuxSelection == unresolved)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(model.tmuxConnectionRecoveryRequest == nil)

        model.openBorrowedTmuxSession(retained)
        #expect(model.tmuxConnectionRecoveryRequest?.hostID == retained.hostID)
        guard case .needsAttention(_, true) =
            model.activeBorrowedTmuxRecoveryState
        else {
            Issue.record("Expected retained recovery state")
            await model.shutdown()
            return
        }
        await model.shutdown()
    }

    @MainActor
    @Test("changed host key can reconnect after manual remediation")
    func changedHostKeyRequiresManualRemediation() async throws {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "REMOTE HOST IDENTIFICATION HAS CHANGED!"
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box", classification: classification
            )),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work", windowCount: 1,
                    createdAt: nil, managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState != nil
                && model.activeBorrowedTmuxRecoveryState?.isReconnecting == false
        }
        guard case let .needsAttention(message, false) =
            model.activeBorrowedTmuxRecoveryState
        else {
            Issue.record("Expected manual attention state")
            await model.shutdown()
            return
        }
        #expect(message.contains("known-hosts"))
        #expect(model.tmuxConnectionRecoveryRequest == nil)

        model.resumeTmuxReconnectAfterSSHRecovery(
            TmuxConnectionRecoveryRequest(
                hostID: environment.remoteHost.id,
                message: message
            )
        )
        #expect(
            model.activeBorrowedTmuxRecoveryState == .needsAttention(
                message: message,
                canReviewConnection: false
            )
        )

        model.reconnectActiveTmuxSessionNow()

        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(discoveries.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("clean detach never starts automatic recovery")
    func cleanDetachDoesNotReconnect() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(surfaceStore.requestCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("returning to a cleanly detached retained session does not reopen it")
    func cleanlyDetachedRetainedSessionDoesNotReopen() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remote = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let local = WorkspaceTmuxSessionSelection(
            hostID: environment.localHostID,
            name: "local-work"
        )
        model.openBorrowedTmuxSession(remote)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let remoteHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: remote)
        )
        surfaceStore.surface.closeObservers[remoteHandle.id]?(false, 0)
        model.openBorrowedTmuxSession(local)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        model.openBorrowedTmuxSession(remote)
        model.prepareActiveBorrowedTmuxSurface()

        #expect(model.retainedBorrowedTmuxHandle(for: remote) == remoteHandle)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(surfaceStore.requestCount == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("startup publishes existing local tmux sessions")
    func startupPublishesExistingSessions() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { host in
                #expect(host == .local)
                return .success([
                    DiscoveredTmuxSession(
                        name: "docbank",
                        windowCount: 4,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
        }

        let session = try #require(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.first
        )
        #expect(session.windows.count == 4)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "automatic kwt provisioning follows the remote platform policy",
        arguments: [
            (HostPlatform.macOS, true),
            (HostPlatform.linux, true),
            (HostPlatform.windows, false),
        ]
    )
    func automaticKwtProvisioning(
        platform: HostPlatform,
        expected: Bool
    ) async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "remote",
            name: "Remote",
            platform: platform,
            sshDestination: "remote"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let provisioningAttempts = Counter()
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                    #expect((provisioningAttempts.count > 0) == expected)
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                #expect(host.platform == platform)
                _ = provisioningAttempts.increment()
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect((provisioningAttempts.count > 0) == expected)
        await model.shutdown()
    }

    @MainActor
    @Test("automatic kwt provisioning includes exe.dev hosts")
    func automaticKwtProvisioningIncludesExeHosts() async throws {
        let environment = try setupStandardEnvironment()
        let exeHost = ExeConfiguredHost(
            sshHost: SSHHost(
                configKey: "exe-dev.personal.build",
                name: "build",
                platform: .linux,
                sshDestination: "vm+build@exe.dev"
            ),
            metadata: ExeVMMetadata(
                accountConfigKey: "personal",
                accountName: "Personal",
                vmName: "build"
            )
        )
        let provisionedHost = LockedValue<SSHHost?>(nil)
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                provisionedHost.store(host)
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredExeHostsProvider: { [exeHost] },
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect(provisionedHost.load() == exeHost.sshHost)
        await model.shutdown()
    }

    @MainActor
    @Test("manual SSH hosts retain kwt provisioning precedence")
    func manualHostsRetainKwtProvisioningPrecedence() async throws {
        let environment = try setupStandardEnvironment()
        let manualHost = SSHHost(
            configKey: "manual-build",
            name: "Manual Build",
            platform: .linux,
            sshDestination: "build.exe.xyz"
        )
        let exeHost = ExeConfiguredHost(
            sshHost: SSHHost(
                configKey: "exe-dev.personal.build",
                name: "build",
                platform: .linux,
                sshDestination: manualHost.sshDestination
            ),
            metadata: ExeVMMetadata(
                accountConfigKey: "personal",
                accountName: "Personal",
                vmName: "build"
            )
        )
        let provisionedHost = LockedValue<SSHHost?>(nil)
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                provisionedHost.store(host)
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { [manualHost] },
            configuredExeHostsProvider: { [exeHost] },
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect(provisionedHost.load() == manualHost)
        await model.shutdown()
    }

    @MainActor
    @Test("kwt provisioning failure leaves remote tmux inventory available")
    func provisioningFailureDoesNotBlockTmux() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { _ in
                throw KwtRemoteInstallError.bundleIncomplete
            },
            tmuxSessionDiscovery: { host in
                .success(host.isRemote ? [
                    DiscoveredTmuxSession(
                        name: "build",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ] : [])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.tmuxSessions.map(\.name) == ["build"]
                }
                && !model.workspaceInventoryWarningsByHost.isEmpty
        }

        #expect(remoteInventoryLoads.count == 0)
        let remoteSummary = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        #expect(remoteSummary.primaryDiagnostic?.code == .missingKwt)
        #expect(!remoteSummary.canCreateWorktree)
        await model.shutdown()
    }

    @MainActor
    @Test("an unreachable SSH host does not block local inventory")
    func unreachableRemoteDoesNotBlockLocalInventory() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "wesm-mbp",
            name: "Wes MBP",
            platform: .macOS,
            sshDestination: "wesm@wesm-mbp"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                switch host {
                case .local:
                    return KwtHostInventory(projects: [])
                case let .ssh(info):
                    throw KwtInventoryError.commandFailed(
                        host: info.displayName,
                        status: 255
                    )
                }
            },
            tmuxSessionDiscovery: { host in
                switch host {
                case .local:
                    return .success([
                        DiscoveredTmuxSession(
                            name: "docbank",
                            windowCount: 4,
                            createdAt: "1721552400",
                            managed: false
                        ),
                    ])
                case .ssh:
                    return .failure(.shellFailed(status: 255))
                }
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
                && model.workspaceInventoryWarningsByHost.values.contains {
                    $0.contains("Wes MBP")
                }
        }

        #expect(model.workspaceInventoryState == .loaded)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
        )
        #expect(model.workspaceInventoryWarning == nil)
        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        let remoteSummary = try #require(
            model.snapshot.host(id: remoteHostID)
        )
        #expect(remoteSummary.connectionState == .offline)
        #expect(remoteSummary.primaryDiagnostic?.code == .probeFailure)
        #expect(remoteSummary.lastSeenAt == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[remoteHostID]?
                .contains("status 255") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("fresh failure of every inventory source is retryable")
    func allSourcesFailWithoutInventory() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: 1
                )
            },
            tmuxSessionDiscovery: { _ in
                .failure(.shellFailed(status: 1))
            },
            startServices: true
        )

        await waitUntilMainActor {
            if case .failed = model.workspaceInventoryState {
                return true
            }
            return false
        }

        guard case let .failed(message) = model.workspaceInventoryState else {
            Issue.record("Expected total inventory failure")
            await model.shutdown()
            return
        }
        #expect(message.contains("status 1"))
        #expect(model.workspaceInventoryWarning == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[environment.host.id]?
                .contains("status 1") == true
        )
        #expect(model.snapshot.projects.isEmpty)
        #expect(
            model.snapshot.hosts.allSatisfy { $0.tmuxSessions.isEmpty }
        )
        await model.shutdown()
    }

    @MainActor
    @Test("missing kwt does not block an SSH host's tmux inventory")
    func remoteWithoutKwtDoesNotBlockTmux() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "tmux-only",
            name: "Tmux Only",
            platform: .linux,
            sshDestination: "tmux-only"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                guard host.isRemote else {
                    return KwtHostInventory(projects: [])
                }
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: 127
                )
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
        }

        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        #expect(model.workspaceInventoryWarningsByHost[remoteHostID] == nil)
        let remoteSummary = try #require(
            model.snapshot.host(id: remoteHostID)
        )
        #expect(remoteSummary.primaryDiagnostic?.code == .missingKwt)
        #expect(remoteSummary.lastKnownReachable)
        #expect(remoteSummary.connectionState == .degraded)
        #expect(!remoteSummary.canCreateWorktree)
        await model.shutdown()
    }

    @MainActor
    @Test("losing remote kwt retains cached inventory but disables creation")
    func remoteKwtLossDisablesCreation() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let availability = KwtAvailabilityState(
            remoteInventory: KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: "github.com/kenn-io/docbank",
                        name: "docbank",
                        path: "/srv/docbank",
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        )
        let creationAttempts = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                try availability.load(host)
            },
            kwtWorktreeCreator: { _, _, _ in
                _ = creationAttempts.increment()
            },
            tmuxSessionDiscovery: { host in
                .success(host.isRemote ? [
                    DiscoveredTmuxSession(
                        name: "docbank",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ] : [])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.projects.contains { $0.name == "docbank" }
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.tmuxSessions.contains { $0.name == "docbank" }
                }
        }
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.name == "docbank" }
        )
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))

        availability.markRemoteKwtUnavailable()
        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.snapshot.host(id: cachedProject.hostID)?
                .primaryDiagnostic?.code == .missingKwt
        }

        let unavailableHost = try #require(
            model.snapshot.host(id: cachedProject.hostID)
        )
        #expect(!unavailableHost.canCreateWorktree)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(unavailableHost.tmuxSessions.map(\.name) == ["docbank"])
        #expect(model.workspaceInventoryWarningsByHost[unavailableHost.id] == nil)

        do {
            try await model.createWorktree(WorktreeCreateRequest(
                projectID: cachedProject.id,
                branchName: "feature/should-not-run",
                createsBranch: true
            ))
            Issue.record("Expected unavailable kwt to reject creation")
        } catch let error as KwtWorktreeError {
            #expect(error == .projectUnavailable)
        }
        #expect(creationAttempts.count == 0)

        availability.markRemoteKwtAvailable()
        model.refreshKwtInventory()
        await waitUntilMainActor {
            let host = model.snapshot.host(id: cachedProject.hostID)
            return host?.primaryDiagnostic?.code != .missingKwt
                && host?.canCreateWorktree == true
        }
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))
        await model.shutdown()
    }

    @MainActor
    @Test(
        "status 127 during creation disables kwt and schedules discovery",
        arguments: CreationKwtFailurePhase.allCases
    )
    private func creationKwtLossDisablesCapability(
        phase: CreationKwtFailurePhase
    ) async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let availability = KwtAvailabilityState(
            remoteInventory: KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: "github.com/kenn-io/docbank",
                        name: "docbank",
                        path: "/srv/docbank",
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        )
        let creationAttempts = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                try availability.load(host)
            },
            kwtWorktreeCreator: { _, _, host in
                _ = creationAttempts.increment()
                if phase == .command {
                    throw KwtWorktreeError.commandFailed(
                        host: host.displayName,
                        status: 127
                    )
                }
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.projects.contains { $0.name == "docbank" }
        }
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.name == "docbank" }
        )
        availability.markRemoteKwtUnavailable()

        do {
            try await model.createWorktree(WorktreeCreateRequest(
                projectID: cachedProject.id,
                branchName: "feature/kwt-disappeared",
                createsBranch: true
            ))
            Issue.record("Expected status 127 from worktree creation")
        } catch {
            switch (phase, error) {
            case let (.command, worktreeError as KwtWorktreeError):
                #expect(
                    worktreeError == .commandFailed(
                        host: "build-box",
                        status: 127
                    )
                )
            case let (.inventoryRefresh, inventoryError as KwtInventoryError):
                #expect(
                    inventoryError == .commandFailed(
                        host: "build-box",
                        status: 127
                    )
                )
            default:
                Issue.record("Unexpected status-127 error: \(error)")
            }
        }

        await waitUntilMainActor {
            availability.remoteLoadCount >= 2
                && model.snapshot.host(id: cachedProject.hostID)?
                .primaryDiagnostic?.code == .missingKwt
        }
        #expect(creationAttempts.count == 1)
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
        await model.shutdown()
    }

    @MainActor
    @Test("tmux discovery failure invalidates prior host reachability")
    func tmuxFailureMarksPreviouslyReachableHostOffline() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let availability = KwtAvailabilityState(
            remoteInventory: KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: "github.com/kenn-io/docbank",
                        name: "docbank",
                        path: "/srv/docbank",
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        )
        let reachability = TmuxReachabilityState()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                try availability.load(host)
            },
            tmuxSessionDiscovery: reachability.discover,
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.hosts.contains {
                $0.configKey == remote.configKey
                    && $0.lastKnownReachable
                    && $0.tmuxSessions.map(\.name) == ["docbank"]
            }
        }
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        let lastSeenAt = try #require(remoteHost.lastSeenAt)
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.hostID == remoteHost.id }
        )
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))

        reachability.markRemoteUnreachable()
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: remoteHost.id)?.connectionState == .offline
        }

        let offlineHost = try #require(model.snapshot.host(id: remoteHost.id))
        #expect(!offlineHost.lastKnownReachable)
        #expect(offlineHost.lastSeenAt == lastSeenAt)
        #expect(offlineHost.tmuxSessions.map(\.name) == ["docbank"])
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
        #expect(
            model.workspaceInventoryWarningsByHost[offlineHost.id]?
                .contains("255") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe accepts a tmux-only SSH host")
    func connectionProbeAcceptsRemoteWithoutKwt() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, command in
                #expect(command.contains("command -v tmux"))
                #expect(command.contains(
                    "GHOSTHUB_SSH_PROBE_TEST-NONCE_START"
                ))
                return (
                    status: 0,
                    stdout: Self.probeOutput(
                        [
                            "GHOSTHUB_SSH_REACHED",
                            "GHOSTHUB_TMUX_AVAILABLE",
                            "GHOSTHUB_KWT_UNAVAILABLE",
                        ],
                        startupOutput: "unterminated startup output"
                    ),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "tmux-only",
            name: "Tmux Only",
            platform: .linux,
            sshDestination: "tmux-only"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .online)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.diagnostics.count == 1)
        #expect(summary.diagnostics.first?.code == .missingKwt)
        #expect(summary.diagnostics.first?.severity == .warning)
        #expect(
            summary.diagnostics.first?.recoverySuggestion
                .contains("Tmux sessions remain available") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe distinguishes a reachable host without tmux")
    func connectionProbeReportsMissingTmux() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: 127,
                    stdout: Self.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_UNAVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "host-a",
            name: "Host A",
            platform: .linux,
            sshDestination: "user-a@host-a.example"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.diagnostics.map(\.code) == [.missingTmux])
        #expect(
            summary.diagnostics.first?.summary
                == "tmux is not available."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe requires its nonce-framed protocol block")
    func connectionProbeReportsSSHFailure() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: 255,
                    stdout:
                    "GHOSTHUB_SSH_REACHED\n"
                        + "GHOSTHUB_TMUX_AVAILABLE\n",
                    stderr:
                    "GHOSTHUB_SSH_REACHED\n"
                        + "GHOSTHUB_TMUX_AVAILABLE\n"
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "offline",
            name: "Offline",
            platform: .linux,
            sshDestination: "offline"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .offline)
        #expect(!summary.host.lastKnownReachable)
        #expect(summary.diagnostics.map(\.code) == [
            .sshConnectionFailed,
        ])
        #expect(
            summary.diagnostics.first?.summary
                == "SSH could not connect to the host."
        )
        await model.shutdown()
    }

    @MainActor
    @Test(
        "connection probe keeps non-SSH command failures reachable",
        arguments: [Int32(1), Int32(127)]
    )
    func connectionProbeReportsProbeFailure(status: Int32) async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: status,
                    stdout: Self.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_AVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "misconfigured-shell",
            name: "Misconfigured Shell",
            platform: .linux,
            sshDestination: "misconfigured-shell"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.host.lastSeenAt != nil)
        #expect(summary.diagnostics.map(\.code) == [.probeFailure])
        #expect(
            summary.diagnostics.first?.summary
                == "tmux did not respond successfully."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe treats an unconfirmed SSH timeout as offline")
    func connectionProbeReportsUnconfirmedTimeout() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: -124,
                    stdout: "",
                    stderr: "SSH wrapper output\n"
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "timed-out",
            name: "Timed Out",
            platform: .linux,
            sshDestination: "timed-out"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .offline)
        #expect(!summary.host.lastKnownReachable)
        #expect(summary.host.lastSeenAt == nil)
        #expect(summary.diagnostics.map(\.code) == [.sshConnectionFailed])
        #expect(
            summary.diagnostics.first?.summary
                == "The SSH connection timed out."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("Add Project rejects a host endpoint changed while its sheet is open")
    func addProjectRejectsChangedEndpoint() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let registrationCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtProjectRegistration: { _, _ in
                _ = registrationCalls.increment()
                return KwtProjectRecord(
                    repository: "github.com/kenn-io/ghosthub",
                    name: "ghosthub",
                    path: "/srv/ghosthub",
                    lastTouched: nil
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher()
        )
        model.refreshHosts()
        let capturedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "spark" }
        )

        configuredHosts.value = [
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()
        let result = await model.registerProject(
            "/srv/ghosthub",
            on: capturedHost
        )

        #expect(
            result == .failure(.message(
                "The host connection changed. "
                    + "Close Add Project and try again."
            ))
        )
        #expect(registrationCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe uses native PowerShell for Windows hosts")
    func connectionProbeUsesWindowsPowerShell() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { host, command in
                #expect(host.platform == .windows)
                #expect(command.contains("Get-Command tmux.exe"))
                #expect(command.contains("[Console]::Out.WriteLine()"))
                #expect(command.contains("GHOSTHUB_KWT_AVAILABLE"))
                if let managedPath =
                    KwtBinaryLocator.windowsRemoteManagedRelativePath(
                        revision:
                        KwtBinaryLocator.bundledRemoteRevision()
                    ) {
                    #expect(command.contains(
                        powerShellEncodedArgument(managedPath)
                    ))
                } else {
                    #expect(command.contains(
                        "$ghosthubKwtAvailable = $false"
                    ))
                }
                #expect(!command.contains("Get-Command kwt.exe"))
                #expect(!command.contains("command -v"))
                return (
                    status: 0,
                    stdout: Self.probeOutput(
                        [
                            "GHOSTHUB_SSH_REACHED",
                            "GHOSTHUB_TMUX_AVAILABLE",
                            "GHOSTHUB_KWT_AVAILABLE",
                        ],
                        startupOutput: "unterminated startup output"
                    ),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "arm-builder",
            name: "ARM Builder",
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .online)
        #expect(summary.platform == .windows)
        #expect(summary.diagnostics.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe distinguishes missing psmux from SSH failure")
    func connectionProbeReportsMissingPsmux() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: 127,
                    stdout: Self.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_UNAVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "arm-builder",
            name: "ARM Builder",
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()
        let diagnostic = try #require(summary.diagnostics.first)

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(diagnostic.code == .missingTmux)
        #expect(diagnostic.summary == "psmux is not available.")
        #expect(diagnostic.recoverySuggestion.contains("tmux.exe alias"))
        await model.shutdown()
    }

    @MainActor
    @Test("remote failures do not enter the workspace-wide error")
    func remoteFailureStaysHostScopedWhenLocalAlsoFails() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "offline",
            name: "Offline Host",
            platform: .linux,
            sshDestination: "offline"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: host.isRemote ? 127 : 1
                )
            },
            tmuxSessionDiscovery: { host in
                .failure(.shellFailed(status: host.isRemote ? 255 : 1))
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            if case .failed = model.workspaceInventoryState {
                return true
            }
            return false
        }

        guard case let .failed(message) = model.workspaceInventoryState else {
            Issue.record("Expected local inventory failure")
            await model.shutdown()
            return
        }
        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        #expect(!message.contains("Offline Host"))
        #expect(!message.contains("status 255"))
        #expect(
            model.workspaceInventoryWarningsByHost[remoteHostID]?
                .contains("status 255") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("duplicate project warnings appear once")
    func duplicateProjectWarningsAreDeduplicated() async throws {
        let environment = try setupStandardEnvironment()
        let warning = "project: temporary kwt failure"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in
                KwtHostInventory(projects: [
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: "first",
                            name: "project",
                            path: "/first",
                            lastTouched: nil
                        ),
                        worktrees: [],
                        warning: "temporary kwt failure"
                    ),
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: "second",
                            name: "project",
                            path: "/second",
                            lastTouched: nil
                        ),
                        worktrees: [],
                        warning: "temporary kwt failure"
                    ),
                ])
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.workspaceInventoryWarning != nil
        }
        #expect(model.workspaceInventoryWarning == warning)
        await model.shutdown()
    }
}

@MainActor
private final class SceneTmuxPaneSurfaceStub: TmuxPaneSurfacing {
    var blocksClipboardReads = false
    var launchError: Error?
    var childExitCode: UInt32?
    private(set) var closeObservers: [UUID: (Bool, UInt32?) -> Void] = [:]
    private(set) var lastObserverID: UUID?

    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool, UInt32?) -> Void
    ) {
        closeObservers[id] = onSurfaceClosed
        lastObserverID = id
    }
}

private enum SceneSurfaceLaunchError: LocalizedError {
    case rejected

    var errorDescription: String? {
        "The terminal rejected the replacement surface."
    }
}

@MainActor
private final class SceneTmuxSurfaceStoreStub: TmuxSurfaceStoring {
    let surface = SceneTmuxPaneSurfaceStub()
    var returnsSurface = true
    private(set) var requestCount = 0
    private(set) var lastConfiguration: TerminalSurfaceConfiguration?
    private(set) var requestedKeys: [SurfaceKey] = []
    private(set) var removedKeys: [SurfaceKey] = []
    private var retainedKeys: Set<SurfaceKey> = []

    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> (any TmuxPaneSurfacing)? {
        guard !retainedKeys.contains(key) else { return surface }
        retainedKeys.insert(key)
        requestCount += 1
        lastConfiguration = configuration
        requestedKeys.append(key)
        return returnsSurface ? surface : nil
    }

    func removeSurface(for key: SurfaceKey) {
        retainedKeys.remove(key)
        removedKeys.append(key)
    }
}

private final class TmuxDiscoveryResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values:
        [Result<[DiscoveredTmuxSession], TmuxBinaryError>]
    private var removalCount = 0

    init(_ values: [Result<[DiscoveredTmuxSession], TmuxBinaryError>]) {
        self.values = values
    }

    func removeFirst()
        -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        lock.withLock {
            removalCount += 1
            return values.removeFirst()
        }
    }

    var count: Int {
        lock.withLock { removalCount }
    }
}

private final class TmuxExactProbeResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<Bool, TmuxBinaryError>]
    private var removalCount = 0

    init(_ values: [Result<Bool, TmuxBinaryError>]) {
        self.values = values
    }

    func removeFirst() -> Result<Bool, TmuxBinaryError> {
        lock.withLock {
            removalCount += 1
            return values.removeFirst()
        }
    }

    var count: Int {
        lock.withLock { removalCount }
    }
}
