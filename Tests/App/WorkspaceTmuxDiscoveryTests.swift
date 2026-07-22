import Combine
import Foundation
import GhosthubSettings
import GhosthubTerminal
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Workspace tmux discovery")
struct WorkspaceTmuxDiscoveryTests {
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

    private final class KwtAvailabilityState: @unchecked Sendable {
        private let lock = NSLock()
        private let remoteInventory: KwtHostInventory
        private var remoteKwtAvailable = true

        init(remoteInventory: KwtHostInventory) {
            self.remoteInventory = remoteInventory
        }

        func load(_ host: TmuxHost) throws -> KwtHostInventory {
            guard host.isRemote else {
                return KwtHostInventory(projects: [])
            }
            lock.lock()
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
    }

    private final class DelayedTmuxPathState: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var started = false

        func resolve() -> Result<String, TmuxBinaryError> {
            lock.lock()
            started = true
            lock.unlock()
            gate.wait()
            return .success("/usr/bin/tmux")
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
            if call == 2 {
                return .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            }
            return .failure(.shellFailed(status: 255))
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

    private final class CancellableDiscoveryState: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var cancelled = false

        func discover(
            _ host: TmuxHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            lock.lock()
            started = true
            lock.unlock()
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.001)
            }
            lock.lock()
            cancelled = true
            lock.unlock()
            return .failure(.probeCancelled(shell: "test"))
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

    @MainActor
    @Test("created sessions publish into host inventory immediately")
    func createdSessionPublishesImmediately() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: { .success("/opt/homebrew/bin/tmux") }
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
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxPathProvider: { .success("/opt/homebrew/bin/tmux") }
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
            nativeTmuxPathProvider: { .success("/usr/bin/tmux") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("attach-session"))
        #expect(!command.contains("new-session"))
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
            nativeTmuxPathProvider: { .success("/opt/homebrew/bin/tmux") },
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
    @Test("creation discovery waits for terminal command launch")
    func createdSessionDoesNotReconcileBeforeLaunch() async throws {
        let environment = try setupStandardEnvironment()
        let attempts = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: { .success("/opt/homebrew/bin/tmux") },
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
        try await Task.sleep(for: .milliseconds(100))

        #expect(attempts.count == baselineAttempts)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
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
            nativeTmuxPathProvider: { .success("/usr/bin/tmux") },
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
            nativeTmuxPathProvider: { .success("/usr/bin/tmux") },
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
            remoteTmuxPathProvider: { _ in .success("/usr/bin/tmux") },
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
    @Test("shutdown cancels detached creation discovery")
    func shutdownCancelsDetachedCreationDiscovery() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = CancellableDiscoveryState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { .success("/usr/bin/tmux") },
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
            nativeTmuxPathProvider: { .success("/usr/bin/tmux") },
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
    @Test("connection probe accepts a tmux-only SSH host")
    func connectionProbeAcceptsRemoteWithoutKwt() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, command in
                #expect(command.contains("command -v tmux"))
                return (
                    status: 0,
                    stdout: "GHOSTHUB_KWT_UNAVAILABLE\n"
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "tmux-only",
            name: "Tmux Only",
            platform: .linux,
            sshDestination: "tmux-only"
        ))
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
            if case .failed = model.workspaceInventoryState { return true }
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
        #expect(!message.contains("255"))
        #expect(
            model.workspaceInventoryWarningsByHost[remoteHostID]?
                .contains("255") == true
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
    var blocksClipboardAccess = false
    var launchError: Error? { nil }

    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool) -> Void
    ) {}
}

@MainActor
private final class SceneTmuxSurfaceStoreStub: TmuxSurfaceStoring {
    private let surface = SceneTmuxPaneSurfaceStub()
    private(set) var requestCount = 0
    private(set) var lastConfiguration: TerminalSurfaceConfiguration?

    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> (any TmuxPaneSurfacing)? {
        requestCount += 1
        lastConfiguration = configuration
        return surface
    }

    func removeSurface(for key: SurfaceKey) {}
}
