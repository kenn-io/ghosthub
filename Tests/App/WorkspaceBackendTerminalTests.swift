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
        zellijSessions: [ZellijSessionSummary] = [],
        remote: Bool = false
    ) throws -> Environment {
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            herdrSessions: herdrSessions,
            herdrAvailable: !herdrSessions.isEmpty,
            backendTerminals: remote ? [] : terminals,
            zellijSessions: zellijSessions,
            zellijAvailable: !zellijSessions.isEmpty
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
        /// Failures returned once each, in order, before listings succeed.
        let validationFailures = Mutex<[BackendTerminalCommandError]>([])
        let executableFailures = Mutex<[BackendTerminalCommandError]>([])
        /// Holds each validation until opened, when set.
        let validationGate = Mutex<AsyncGate?>(nil)
        /// Holds only the next validation until opened.
        let nextValidationGate = Mutex<AsyncGate?>(nil)
        /// This Mac's Herdr sessions, when a test changes them.
        let herdrSessions = Mutex<[HerdrSessionSummary]?>(nil)
        /// Holds only the next Herdr session check until opened.
        let nextHerdrValidationGate = Mutex<AsyncGate?>(nil)

        init(_ terminals: [BackendTerminalSummary]) {
            self.terminals = Mutex(terminals)
        }

        func validate(_ kind: BackendTerminalKind) async -> BackendTerminalDiscoveryResult {
            if let gate = validationGate.withLock({ $0 }) {
                await gate.wait()
            }
            if let gate = nextValidationGate.withLock({ gate in
                defer { gate = nil }
                return gate
            }) {
                await gate.wait()
            }
            if let error = validationFailures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
                return .failure(error)
            }
            return listing(kind)
        }

        func executable(_ kind: BackendTerminalKind)
            -> Result<String, BackendTerminalCommandError> {
            if let error = executableFailures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
                return .failure(error)
            }
            return .success(kind == .rex ? "/opt/test/kwt" : "/opt/test/herdr-core")
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
        zellijSessionDiscovery: @escaping WorkspaceSceneModel.ZellijSessionDiscovery = {
            _ in .unavailable
        },
        startServices: Bool = false
    ) throws -> WorkspaceSceneModel {
        let fake = fake ?? FakeHost(environment.host.backendTerminals)
        let localHerdrSessions = environment.snapshot
            .host(id: environment.localHostID)?.herdrSessions ?? []
        let herdrDiscovery: WorkspaceSceneModel.HerdrSessionDiscovery = { host in
            guard host == .local else { return .available([]) }
            return .available(fake.herdrSessions.withLock { $0 } ?? localHerdrSessions)
        }
        return try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            workspaceInventoryStore: workspaceInventoryStore,
            nativeHerdrSurfaceStore: herdrStore,
            nativeBackendTerminalSurfaceStore: store,
            nativeBackendTerminalExecutableProvider: { kind, _, _ in fake.executable(kind) },
            nativeHerdrPathProvider: { _ in .success("/opt/test/herdr") },
            herdrPaneSplitCapabilityProvider: { _, _, _, _ in .success(nil) },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            herdrSSHConnectionSnapshotProvider: { _ in
                SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
                    routeIdentity: fake.validationRoute.withLock { $0 }
                ))
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            herdrSessionDiscovery: herdrDiscovery,
            backendTerminalDiscovery: discovery ?? { _ in
                [.rex: fake.listing(.rex), .herdrCore: fake.listing(.herdrCore)]
            },
            backendTerminalValidationDiscovery: { _, kind, _ in await fake.validate(kind) },
            zellijSessionDiscovery: zellijSessionDiscovery,
            presentationSSHConnectionProvider: { _, _ in
                fake.attaches.withLock { $0 += 1 }
                return testKwtSSHAttachment(routeIdentity: fake.attachRoute.withLock { $0 })
            },
            herdrSessionValidationDiscovery: { host, _ in
                if let gate = fake.nextHerdrValidationGate.withLock({ gate in
                    defer { gate = nil }
                    return gate
                }) {
                    await gate.wait()
                }
                return await herdrDiscovery(host)
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

    @Test("a clean detach reports no reason that repeats its heading")
    func cleanDetachHasNoReason() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store)
        try await model.openBackendTerminal(environment.selection(Self.rexTerminal))
        await launchSurface(model, store: store)

        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 0)

        #expect(model.activeBorrowedBackendTerminalConnectionState == .disconnected(reason: nil))
        await model.shutdown()
    }

    @Test("a connection that drops while Ghosthub finds the attach program reconnects")
    func droppedExecutableLookupReconnects() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal])
        fake.executableFailures.withLock {
            $0 = [.commandFailed(
                .rex, status: 255,
                stderr: "ssh: connect to host builder port 22: Connection refused"
            )]
        }
        let model = try makeTerminalModel(environment, store: store, fake: fake)

        try await model.openBackendTerminal(environment.selection(Self.rexTerminal))
        await launchSurface(model, store: store)

        #expect(fake.attaches.withLock { $0 } == 2)
        await model.shutdown()
    }

    @Test("a saved terminal is restored after a transient validation failure")
    func restorationRetriesTransientFailure() async throws {
        let environment = try environment(terminals: [])
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal])
        fake.validationFailures.withLock {
            $0 = [.commandFailed(.rex, status: 1, stderr: "server busy")]
        }
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let rex = environment.selection(Self.rexTerminal)
        let windowID = UUID()
        model.beginRestoration(WorkspaceWindowState(
            windowID: windowID,
            navigation: .init(hostKey: "local", projectKey: nil, worktreeGeneration: nil),
            tmux: nil,
            backendTerminal: .init(hostKey: "local", kind: .rex, address: rex.address)
        ))

        model.startHerdrSessionDiscovery()
        await launchSurface(model, store: store)

        #expect(model.activeBackendTerminalSelection == rex)
        #expect(model.restorationState(windowID: windowID).backendTerminal?.address
            == rex.address)
        await model.shutdown()
    }

    @Test("a restoration retry waits out a sweep still listing another host")
    func restorationRetryDuringSweep() async throws {
        let environment = try environment(terminals: [Self.rexTerminal], remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal])
        fake.validationFailures.withLock {
            $0 = [.commandFailed(.rex, status: 1, stderr: "server busy")]
        }
        // This Mac's listing stays slow while the remote one is restored.
        let slowLocal = BlockingBackendDiscovery(listing: [:])
        let model = try makeTerminalModel(
            environment,
            store: store,
            fake: fake,
            discovery: { host in
                host == .local ? slowLocal.discover() : [.rex: fake.listing(.rex)]
            }
        )
        let rex = environment.selection(Self.rexTerminal)
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(hostKey: "builder", projectKey: nil, worktreeGeneration: nil),
            tmux: nil,
            backendTerminal: .init(hostKey: "builder", kind: .rex, address: rex.address)
        ))

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor {
            slowLocal.starts == 1 && fake.validationFailures.withLock { $0.isEmpty }
        }
        try await Task.sleep(for: .milliseconds(50))
        slowLocal.release()
        await launchSurface(model, store: store)

        #expect(model.activeBackendTerminalSelection == rex)
        await model.shutdown()
    }

    @Test("a reconnect that needs SSH approval asks for review and resumes after it")
    func reconnectNeedsApproval() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)

        fake.validationFailures.withLock {
            $0 = [.commandFailed(
                .rex, status: 255, stderr: "ghosthub-kwt-ssh-error:ssh_interaction_required"
            )]
        }
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        await waitUntilMainActor { model.sessionConnectionRecoveryRequest != nil }

        guard case .needsAttention(_, true) = model.activeBackendTerminalRecoveryState else {
            let state = String(describing: model.activeBackendTerminalRecoveryState)
            Issue.record("expected a connection review, got \(state)")
            await model.shutdown()
            return
        }
        #expect(!model.backendTerminalReconnectSupervisorIsRunning)
        let request = try #require(model.sessionConnectionRecoveryRequest)
        #expect(request.hostID == environment.host.id)

        model.resumeSessionReconnectAfterSSHRecovery(request)
        await launchSurface(model, store: store, after: 1)
        #expect(model.activeBackendTerminalSelection == rex)
        #expect(model.activeBackendTerminalRecoveryState == nil)
        await model.shutdown()
    }

    @Test("a Zellij session that fails to open leaves the open terminal")
    func failedZellijOpenKeepsTerminal() async throws {
        let environment = try environment(zellijSessions: [.init(name: "work")])
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(
            environment,
            store: store,
            // The session ended after the sidebar listed it.
            zellijSessionDiscovery: { _ in .available([]) }
        )
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)
        let key = try #require(store.requestedKeys.last)

        model.openBorrowedZellijSession(.init(hostID: environment.host.id, name: "work"))
        await waitUntilMainActor { model.pendingZellijPresentationSelection == nil }

        #expect(model.activeBackendTerminalSelection == rex)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(!store.removedKeys.contains(key))
        await model.shutdown()
    }

    @Test("repeated sibling shortcuts walk past a terminal that is still opening")
    func repeatedSiblingShortcuts() async throws {
        let terminals = ["01", "02", "03"].map {
            BackendTerminalSummary(kind: .rex, address: "block:\($0)", title: "shell \($0)")
        }
        let environment = try environment(terminals: terminals)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost(terminals)
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let first = environment.selection(terminals[0])
        try await model.openBackendTerminal(first)
        model.selection.select(
            .backendTerminal(hostID: first.hostID, kind: first.kind, address: first.address),
            in: environment.snapshot
        )
        model.isFocusedWindow = true
        let gate = AsyncGate()
        fake.validationGate.withLock { $0 = gate }

        #expect(model.performApplicationShortcut(.nextSibling))
        #expect(model.performApplicationShortcut(.nextSibling))
        gate.open()
        await waitUntilMainActor { model.activeBackendTerminalSelection != first }

        #expect(model.activeBackendTerminalSelection == environment.selection(terminals[2]))
        await model.shutdown()
    }

    @Test("navigating elsewhere cancels a terminal shortcut that has not opened yet")
    func navigationCancelsShortcut() async throws {
        let terminals = ["01", "02"].map {
            BackendTerminalSummary(kind: .rex, address: "block:\($0)", title: "shell \($0)")
        }
        let environment = try environment(terminals: terminals)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost(terminals)
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let first = environment.selection(terminals[0])
        try await model.openBackendTerminal(first)
        model.selection.select(
            .backendTerminal(hostID: first.hostID, kind: first.kind, address: first.address),
            in: environment.snapshot
        )
        model.isFocusedWindow = true
        let gate = AsyncGate()
        fake.validationGate.withLock { $0 = gate }

        #expect(model.performApplicationShortcut(.nextSibling))
        model.selectFromUser(WorkspaceSelection(selectedHostID: environment.host.id))
        gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.pendingBackendTerminalShortcutSelection == nil)
        #expect(model.activeBackendTerminalSelection == first)
        await model.shutdown()
    }
    @Test("closing a terminal that waits for SSH approval withdraws its request")
    func closeWithdrawsApprovalRequest() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)

        fake.validationFailures.withLock {
            $0 = [.commandFailed(
                .rex, status: 255, stderr: "ghosthub-kwt-ssh-error:ssh_interaction_required"
            )]
        }
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        await waitUntilMainActor { model.sessionConnectionRecoveryRequest != nil }

        model.closeBackendTerminal(rex)

        #expect(model.sessionConnectionRecoveryRequest == nil)
        await model.shutdown()
    }

    @Test("Cmd-W cancels a shortcut still checking the next terminal")
    func closeCancelsShortcut() async throws {
        let terminals = ["01", "02"].map {
            BackendTerminalSummary(kind: .rex, address: "block:\($0)", title: "shell \($0)")
        }
        let environment = try environment(terminals: terminals)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost(terminals)
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let first = environment.selection(terminals[0])
        try await model.openBackendTerminal(first)
        model.selection.select(
            .backendTerminal(hostID: first.hostID, kind: first.kind, address: first.address),
            in: environment.snapshot
        )
        model.isFocusedWindow = true
        let gate = AsyncGate()
        fake.validationGate.withLock { $0 = gate }

        #expect(model.performApplicationShortcut(.nextSibling))
        model.cancelPendingSessionOpens()
        model.closeBackendTerminal(first)
        gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.activeBackendTerminalSelection == nil)
        await model.shutdown()
    }

    @Test("a reconnect to a machine without the terminal keeps it for the user to reopen")
    func changedRouteWithoutTerminal() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.coreTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let core = environment.selection(Self.coreTerminal)
        try await model.openBackendTerminal(core)
        await launchSurface(model, store: store)

        // The SSH alias now names another machine, which has no "t7".
        fake.validationRoute.withLock { $0 = "sha256:route-b" }
        fake.terminals.withLock { $0 = [] }
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        await waitUntilMainActor { !model.backendTerminalReconnectSupervisorIsRunning }

        #expect(model.activeBackendTerminalSelection == core)
        #expect(model.activeBorrowedBackendTerminalConnectionState == .disconnected(
            reason: NativeBackendTerminalCoordinator.routeChangedReason
        ))
        await model.shutdown()
    }

    @Test("a reconnect waits while another terminal is checked and resumes if it fails")
    func reconnectWaitsForOtherCheck() async throws {
        let environment = try environment(
            terminals: [Self.rexTerminal, Self.coreTerminal], remote: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal, Self.coreTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)

        let gate = AsyncGate()
        fake.nextValidationGate.withLock { $0 = gate }
        let opening = Task { @MainActor in
            try await model.openBackendTerminal(environment.selection(Self.coreTerminal))
        }
        await waitUntilMainActor { fake.nextValidationGate.withLock { $0 == nil } }

        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.attaches.withLock { $0 } == 1)

        // The terminal being checked ended, so the open fails.
        fake.terminals.withLock { $0 = [Self.rexTerminal] }
        gate.open()
        await #expect(throws: BackendTerminalPresentationError.self) {
            try await opening.value
        }
        await launchSurface(model, store: store, after: 1)

        #expect(model.activeBackendTerminalSelection == rex)
        #expect(fake.attaches.withLock { $0 } == 2)
        await model.shutdown()
    }
    @Test("Cmd-W from a terminal cancels a shortcut still checking a Herdr session")
    func closeCancelsHerdrShortcut() async throws {
        let environment = try environment(
            terminals: [Self.rexTerminal],
            herdrSessions: [.init(name: "work", isDefault: false, state: .running)]
        )
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        model.selection.select(
            .backendTerminal(hostID: rex.hostID, kind: rex.kind, address: rex.address),
            in: environment.snapshot
        )
        model.isFocusedWindow = true
        let gate = AsyncGate()
        fake.nextHerdrValidationGate.withLock { $0 = gate }

        #expect(model.performApplicationShortcut(.nextSibling))
        #expect(model.pendingHerdrShortcutSelection?.name == "work")
        model.cancelPendingSessionOpens()
        model.closeBackendTerminal(rex)
        gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(model.activeBackendTerminalSelection == nil)
        await model.shutdown()
    }

    @Test("a terminal's reconnect waits while a Herdr session is checked")
    func reconnectWaitsForHerdrCheck() async throws {
        let environment = try environment(
            terminals: [Self.rexTerminal],
            herdrSessions: [.init(name: "work", isDefault: false, state: .running)],
            remote: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.rexTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let rex = environment.selection(Self.rexTerminal)
        try await model.openBackendTerminal(rex)
        await launchSurface(model, store: store)

        let gate = AsyncGate()
        fake.nextHerdrValidationGate.withLock { $0 = gate }
        let opening = Task { @MainActor in
            try await model.openBorrowedHerdrSession(
                .init(hostID: environment.localHostID, name: "work")
            )
        }
        await waitUntilMainActor { fake.nextHerdrValidationGate.withLock { $0 == nil } }

        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.attaches.withLock { $0 } == 1)

        // The Herdr session ended, so its open fails and the terminal
        // reconnects.
        fake.herdrSessions.withLock { $0 = [] }
        gate.open()
        await #expect(throws: (any Error).self) { try await opening.value }
        await launchSurface(model, store: store, after: 1)

        #expect(model.activeBackendTerminalSelection == rex)
        #expect(fake.attaches.withLock { $0 } == 2)
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
