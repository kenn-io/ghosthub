import Foundation
import GhosthubBackendTerminal
import GhosthubHerdr
import GhosthubPersistence
import GhosthubTestSupport
import GhosthubTransport
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("Workspace backend terminals", .serialized)
@MainActor
struct WorkspaceBackendTerminalTests {
    private nonisolated static let rexTerminal = BackendTerminalSummary(
        kind: .rex, address: "block:01aa", title: "vim", detail: "work / editor"
    )
    private nonisolated static let coreTerminal = BackendTerminalSummary(
        kind: .herdrCore, address: "t7", title: "review"
    )

    private struct Environment {
        var database: WorkspaceDatabase
        var localHostID: UUID
        var host: HostSummary
        var snapshot: WorkspaceSnapshot

        func selection(_ terminal: BackendTerminalSummary) -> WorkspaceBackendTerminalSelection {
            .init(hostID: host.id, kind: terminal.kind, address: terminal.address)
        }
    }

    private func environment(
        terminals: [BackendTerminalSummary] = [rexTerminal, coreTerminal],
        herdrSessions: [HerdrSessionSummary] = [],
        remote: Bool = false
    ) throws -> Environment {
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            herdrSessions: remote ? [] : herdrSessions,
            herdrAvailable: !remote && !herdrSessions.isEmpty,
            backendTerminals: remote ? [] : terminals
        )
        let host = remote
            ? HostSummary(
                id: UUID(),
                configKey: "builder",
                name: "Builder",
                kind: .remote,
                platform: .linux,
                sshDestination: "dev@builder",
                backendTerminals: terminals
            )
            : local
        return try Environment(
            database: WorkspaceDatabase.inMemory(),
            localHostID: local.id,
            host: host,
            snapshot: WorkspaceSnapshot(
                hosts: remote ? [local, host] : [local], projects: [], worktrees: []
            )
        )
    }

    /// Backend listings and SSH routes the fake host reports. Tests change
    /// them to model a terminal ending or an SSH alias moving.
    private final class FakeHost: Sendable {
        let terminals: Mutex<[BackendTerminalSummary]>
        let failure = Mutex<BackendTerminalCommandError?>(nil)
        /// The route a validation sees, then the route an attach is given.
        let validationRoute = Mutex("sha256:route-a")
        let attachRoute = Mutex("sha256:route-a")
        let attaches = Mutex(0)

        init(_ terminals: [BackendTerminalSummary]) {
            self.terminals = Mutex(terminals)
        }

        func listing(_ kind: BackendTerminalKind) -> BackendTerminalDiscoveryResult {
            if let error = failure.withLock({ $0 }) {
                return .failure(error)
            }
            return .available(terminals.withLock { $0 }.filter { $0.kind == kind })
        }
    }

    private func makeTerminalModel(
        _ environment: Environment,
        store: RecordingNativeSessionSurfaceStore,
        fake: FakeHost? = nil,
        discovery: WorkspaceSceneModel.BackendTerminalDiscovery? = nil,
        herdrStore: RecordingNativeSessionSurfaceStore? = nil,
        workspaceInventoryStore: WorkspaceInventoryStore? = nil,
        startServices: Bool = false
    ) throws -> WorkspaceSceneModel {
        let fake = fake ?? FakeHost(environment.host.backendTerminals)
        return try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            workspaceInventoryStore: workspaceInventoryStore,
            nativeHerdrSurfaceStore: herdrStore,
            nativeBackendTerminalSurfaceStore: store,
            nativeBackendTerminalExecutableProvider: { kind, _, _ in
                .success(kind == .rex ? "/opt/test/kwt" : "/opt/test/herdr-core")
            },
            nativeHerdrPathProvider: { _ in .success("/opt/test/herdr") },
            herdrPaneSplitCapabilityProvider: { _, _, _, _ in .success(nil) },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            herdrSSHConnectionSnapshotProvider: { _ in
                SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
                    routeIdentity: fake.validationRoute.withLock { $0 }
                ))
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            herdrSessionDiscovery: { _ in .available(environment.host.herdrSessions) },
            backendTerminalDiscovery: discovery ?? { _ in
                [.rex: fake.listing(.rex), .herdrCore: fake.listing(.herdrCore)]
            },
            backendTerminalValidationDiscovery: { _, kind, _ in fake.listing(kind) },
            presentationSSHConnectionProvider: { _, _ in
                fake.attaches.withLock { $0 += 1 }
                return testKwtSSHAttachment(routeIdentity: fake.attachRoute.withLock { $0 })
            },
            tmuxReconnectIntervals: [.milliseconds(10)],
            startServices: startServices
        )
    }

    private func launchSurface(
        _ model: WorkspaceSceneModel,
        store: RecordingNativeSessionSurfaceStore,
        after previous: Int = 0
    ) async {
        await waitUntilMainActor {
            model.prepareActiveBackendTerminalSurface()
            return store.requestedKeys.count > previous
                && model.activeBorrowedBackendTerminalConnectionState == .connected
        }
    }

    /// Ends the attach client of the surface opened last.
    private func closeNewestSurface(
        _ store: RecordingNativeSessionSurfaceStore,
        closed: inout Set<UUID>,
        exitCode: UInt32
    ) throws {
        let (id, close) = try #require(store.surface.closeObservers.first {
            !closed.contains($0.key)
        })
        closed.insert(id)
        close(false, exitCode)
    }

    @Test("a local Rex terminal attaches through Ghosthub's kwt in its own surface")
    func localRexAttach() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store)
        let rex = environment.selection(Self.rexTerminal)

        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)

        #expect(model.activeBackendTerminalSelection == rex)
        #expect(store.requestedKeys.last?.target == .backendTerminal)
        let command = try #require(store.lastCommand)
        #expect(command.contains("/opt/test/kwt"))
        #expect(command.contains("block:01aa"))
        await model.shutdown()
    }

    @Test("a terminal the host does not list is not opened")
    func unlistedTerminal() async throws {
        let environment = try environment(terminals: [])
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store)

        await #expect(throws: BackendTerminalPresentationError.self) {
            try await model.openBackendTerminal(environment.selection(Self.rexTerminal))
        }

        #expect(model.activeBackendTerminalSelection == nil)
        await model.shutdown()
    }

    @Test("a Herdr TUI session and a core terminal with the same name keep distinct clients")
    func herdrSessionAndCoreTerminal() async throws {
        let environment = try environment(
            herdrSessions: [.init(name: "t7", isDefault: false, state: .running)]
        )
        let store = RecordingNativeSessionSurfaceStore()
        let herdrStore = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store, herdrStore: herdrStore)
        let tui = WorkspaceHerdrSessionSelection(hostID: environment.host.id, name: "t7")

        try await model.openBorrowedHerdrSession(tui)
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return !herdrStore.requestedKeys.isEmpty
        }
        let tuiKey = try #require(herdrStore.requestedKeys.last)
        let core = environment.selection(Self.coreTerminal)
        try await model.openBackendTerminal(core)
        await launchSurface(model, store: store)

        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(herdrStore.removedKeys.contains(tuiKey))
        #expect(model.activeBackendTerminalSelection == core)
        let command = try #require(store.lastCommand)
        #expect(command.contains("/opt/test/herdr-core"))
        #expect(!command.contains("/opt/test/herdr'"))
        #expect(!command.contains("'session'"))
        await model.shutdown()
    }

    @Test("closing detaches the client and leaves the terminal listed")
    func closeDetaches() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)
        let key = try #require(store.requestedKeys.last)

        model.closeBackendTerminal(rex)

        #expect(model.activeBackendTerminalSelection == nil)
        #expect(store.removedKeys.contains(key))
        #expect(model.snapshot.host(id: environment.host.id)?.backendTerminals
            .contains(Self.rexTerminal) == true)
        await model.shutdown()
    }

    @Test("reconnecting reattaches a live terminal and retires an ended one")
    func reconnect() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)

        // The attach client exits after a detach; the terminal still runs.
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 0)
        #expect(model.activeBackendTerminalSelection == rex)
        #expect(model.activeBorrowedBackendTerminalConnectionState != .connected)
        let attachments = store.requestedKeys.count
        model.reconnectActiveBackendTerminalNow()
        await launchSurface(model, store: store, after: attachments)
        #expect(model.activeBackendTerminalSelection == rex)

        // The program ended, so Rex no longer lists the block.
        try closeNewestSurface(store, closed: &closed, exitCode: 1)
        fake.terminals.withLock { $0 = [] }
        model.reconnectActiveBackendTerminalNow()
        await waitUntilMainActor { model.activeBackendTerminalSelection == nil }
        #expect(model.snapshot.host(id: environment.host.id)?.backendTerminals
            .contains(Self.rexTerminal) == false)
        await model.shutdown()
    }

    @Test("discovery publishes each backend and a failure keeps that backend's last listing")
    func discovery() async throws {
        let environment = try environment(terminals: [])
        let store = RecordingNativeSessionSurfaceStore()
        let calls = Mutex(0)
        let model = try makeTerminalModel(environment, store: store, discovery: { _ in
            let call = calls.withLock { $0 += 1
                return $0
            }
            if call == 1 {
                return [
                    .rex: .available([Self.rexTerminal]),
                    .herdrCore: .available([Self.coreTerminal]),
                ]
            }
            return [
                .rex: .failure(.commandFailed(.rex, status: 1, stderr: "server busy")),
                .herdrCore: .unavailable,
            ]
        })
        model.startHerdrSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?.backendTerminals.count == 2
        }

        model.refreshKwtInventory()
        await waitUntilMainActor { calls.withLock { $0 } == 2
            && model.workspaceInventoryWarningsByHost[environment.host.id] != nil
        }

        #expect(model.snapshot.host(id: environment.host.id)?.backendTerminals
            == [Self.rexTerminal])
        let warning = try #require(model.workspaceInventoryWarningsByHost[environment.host.id])
        #expect(warning.contains("server busy"))
        await model.shutdown()
    }

    @Test("a restored window reopens the terminal once fresh inventory lists it")
    func restoration() async throws {
        let environment = try environment(terminals: [])
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(
            environment, store: store, fake: FakeHost([Self.rexTerminal])
        )
        let rex = environment.selection(Self.rexTerminal)
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(hostKey: "local", projectKey: nil, worktreeGeneration: nil),
            tmux: nil,
            backendTerminal: .init(hostKey: "local", kind: .rex, address: rex.address)
        ))
        #expect(model.activeBackendTerminalSelection == nil)

        model.startHerdrSessionDiscovery()
        await launchSurface(model, store: store)

        #expect(model.activeBackendTerminalSelection == rex)
        #expect(model.restorationState(windowID: UUID()).backendTerminal?.address == rex.address)
        await model.shutdown()
    }

    @Test("a failed open leaves the terminal that is already open")
    func failedOpenKeepsCurrentView() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal, Self.coreTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)
        let key = try #require(store.requestedKeys.last)

        fake.failure.withLock {
            $0 = .commandFailed(.herdrCore, status: 255, stderr: "Connection refused")
        }
        await #expect(throws: BackendTerminalCommandError.self) {
            try await model.openBackendTerminal(environment.selection(Self.coreTerminal))
        }

        #expect(model.activeBackendTerminalSelection == rex)
        #expect(!store.removedKeys.contains(key))
        #expect(model.activeBorrowedBackendTerminalConnectionState == .connected)
        await model.shutdown()
    }

    @Test("a dropped SSH connection reattaches by itself and a clean detach stays detached")
    func automaticReconnect() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)

        // OpenSSH exits with status 255 when the connection drops.
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        await launchSurface(model, store: store, after: 1)
        #expect(model.activeBackendTerminalSelection == rex)

        try closeNewestSurface(store, closed: &closed, exitCode: 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.backendTerminalReconnectSupervisorIsRunning)
        #expect(Set(store.requestedKeys).count == 2)
        #expect(model.activeBorrowedBackendTerminalConnectionState != .connected)
        await model.shutdown()
    }

    @Test("an attach refuses an SSH route other than the one that listed the terminal")
    func changedRouteOnOpen() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.coreTerminal])
        fake.attachRoute.withLock { $0 = "sha256:route-b" }
        let model = try makeTerminalModel(environment, store: store, fake: fake)

        try await model.openBackendTerminal(environment.selection(Self.coreTerminal))
        await waitUntilMainActor {
            if case .disconnected = model.activeBorrowedBackendTerminalConnectionState {
                return true
            }
            return false
        }

        #expect(model.activeBorrowedBackendTerminalConnectionState == .disconnected(
            reason: NativeBackendTerminalCoordinator.routeChangedReason
        ))
        #expect(store.requestedKeys.isEmpty)
        await model.shutdown()
    }

    @Test("a reconnect never moves a terminal to a different SSH route")
    func changedRouteOnReconnect() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.coreTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        try await model.openBackendTerminal(environment.selection(Self.coreTerminal))
        await launchSurface(model, store: store)

        // The SSH alias now names another machine, which also has a "t7".
        fake.validationRoute.withLock { $0 = "sha256:route-b" }
        fake.attachRoute.withLock { $0 = "sha256:route-b" }
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        await waitUntilMainActor { !model.backendTerminalReconnectSupervisorIsRunning
            && model.activeBorrowedBackendTerminalConnectionState == .disconnected(
                reason: NativeBackendTerminalCoordinator.routeChangedReason
            )
        }

        #expect(Set(store.requestedKeys).count == 1)
        #expect(fake.attaches.withLock { $0 } == 1)
        await model.shutdown()
    }

    @Test("a scheduled sweep lets a slow discovery finish")
    func slowDiscoveryFinishes() async throws {
        let environment = try environment(terminals: [])
        let store = RecordingNativeSessionSurfaceStore()
        let cadence = AsyncGate()
        let discovery = BlockingBackendDiscovery(listing: [.rex: .available([Self.rexTerminal])])
        let model = try makeTerminalModel(
            environment,
            store: store,
            discovery: { _ in discovery.discover() },
            workspaceInventoryStore: makeCadenceInventoryStore(cadence: cadence)
        )

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { discovery.starts == 1 }
        await cadence.waitUntilWaiting()
        cadence.open()
        try await Task.sleep(for: .milliseconds(100))
        discovery.release()

        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?.backendTerminals
                == [Self.rexTerminal]
        }
        #expect(discovery.starts == 1)
        await model.shutdown()
    }

    @Test("refresh completion waits for backend terminal discovery")
    func completionWaitsForBackendTerminals() async throws {
        let environment = try environment(terminals: [])
        let discovery = BlockingBackendDiscovery(listing: [:])
        let model = try makeTerminalModel(
            environment,
            store: RecordingNativeSessionSurfaceStore(),
            discovery: { _ in discovery.discover() },
            startServices: true
        )

        await waitUntilMainActor { discovery.starts == 1 }
        #expect(!model.isWorkspaceInventoryRefreshComplete)

        discovery.release()
        await waitUntilMainActor { model.isWorkspaceInventoryRefreshComplete }
        await model.shutdown()
    }
}

/// Holds the first backend terminal discovery until released.
private final class BlockingBackendDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private let listing: [BackendTerminalKind: BackendTerminalDiscoveryResult]

    init(listing: [BackendTerminalKind: BackendTerminalDiscoveryResult]) {
        self.listing = listing
    }

    func discover() -> [BackendTerminalKind: BackendTerminalDiscoveryResult] {
        let first = lock.withLock {
            count += 1
            return count == 1
        }
        if first {
            semaphore.wait()
        }
        return listing
    }

    var starts: Int { lock.withLock { count } }

    func release() {
        semaphore.signal()
    }
}
