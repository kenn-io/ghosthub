import AppKit
import Foundation
import GhosthubBackendTerminal
import GhosthubHerdr
import GhosthubPersistence
import GhosthubTestSupport
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("Workspace backend terminals", .serialized)
@MainActor
struct WorkspaceBackendTerminalTests {
    /// A terminal Ghosthub attaches on its own. Rex windows have their own
    /// tests, so these use a Herdr Core terminal.
    private nonisolated static let attachedTerminal = BackendTerminalSummary(
        kind: .herdrCore, address: "t9", title: "vim"
    )
    private nonisolated static let rexWindow = BackendTerminalSummary(
        kind: .rex, address: "window:01aa", title: "vim", detail: "work · 1 pane"
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
        terminals: [BackendTerminalSummary] = [attachedTerminal, coreTerminal],
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
        rexChannels: RexChannels = RexChannels(),
        herdrTabChannelFactory: @escaping HerdrTabChannelFactory = { _, _, _ in
            FakeRexControlChannel()
        },
        rexWindowCreation: @escaping WorkspaceSceneModel.RexWindowCreation = { _, _, _ in
            .failure(.unavailable(.rex))
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
            nativeTmuxSurfaceStore: store,
            nativeHerdrSurfaceStore: herdrStore,
            nativeZellijSurfaceStore: store,
            nativeBackendTerminalSurfaceStore: store,
            nativeBackendTerminalExecutableProvider: { kind, _, _ in fake.executable(kind) },
            rexControlChannelFactory: { command in
                let channel = FakeRexControlChannel()
                rexChannels.started.append((command, channel))
                return channel
            },
            herdrTabChannelFactory: herdrTabChannelFactory,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            nativeHerdrPathProvider: { _ in .success("/opt/test/herdr") },
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
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
            rexWindowCreation: rexWindowCreation,
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

    @Test("a terminal the host does not list is not opened")
    func unlistedTerminal() async throws {
        let environment = try environment(terminals: [])
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store)

        await #expect(throws: BackendTerminalPresentationError.self) {
            try await model.openBackendTerminal(environment.selection(Self.attachedTerminal))
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
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)
        let key = try #require(store.requestedKeys.last)

        model.closeBackendTerminal(opened)

        #expect(model.activeBackendTerminalSelection == nil)
        #expect(store.removedKeys.contains(key))
        #expect(model.snapshot.host(id: environment.host.id)?.backendTerminals
            .contains(Self.attachedTerminal) == true)
        await model.shutdown()
    }

    @Test("reconnecting reattaches a live terminal and retires an ended one")
    func reconnect() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)

        // The attach client exits after a detach; the terminal still runs.
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 0)
        #expect(model.activeBackendTerminalSelection == opened)
        #expect(model.activeBorrowedBackendTerminalConnectionState != .connected)
        let attachments = store.requestedKeys.count
        model.reconnectActiveBackendTerminalNow()
        await launchSurface(model, store: store, after: attachments)
        #expect(model.activeBackendTerminalSelection == opened)

        // The program ended, so Herdr Core no longer lists it.
        try closeNewestSurface(store, closed: &closed, exitCode: 1)
        fake.terminals.withLock { $0 = [] }
        model.reconnectActiveBackendTerminalNow()
        await waitUntilMainActor { model.activeBackendTerminalSelection == nil }
        #expect(model.snapshot.host(id: environment.host.id)?.backendTerminals
            .contains(Self.attachedTerminal) == false)
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
                    .rex: .available([Self.rexWindow]),
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
            == [Self.rexWindow])
        let warning = try #require(model.workspaceInventoryWarningsByHost[environment.host.id])
        #expect(warning.contains("server busy"))
        await model.shutdown()
    }

    @Test("a restored window reopens the terminal once fresh inventory lists it")
    func restoration() async throws {
        let environment = try environment(terminals: [])
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(
            environment, store: store, fake: FakeHost([Self.attachedTerminal])
        )
        let opened = environment.selection(Self.attachedTerminal)
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(hostKey: "local", projectKey: nil, worktreeGeneration: nil),
            tmux: nil,
            backendTerminal: .init(hostKey: "local", kind: .herdrCore, address: opened.address)
        ))
        #expect(model.activeBackendTerminalSelection == nil)

        model.startHerdrSessionDiscovery()
        await launchSurface(model, store: store)

        #expect(model.activeBackendTerminalSelection == opened)
        #expect(model.restorationState(windowID: UUID()).backendTerminal?.address == opened.address)
        await model.shutdown()
    }

    @Test("a failed open leaves the terminal that is already open")
    func failedOpenKeepsCurrentView() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal, Self.coreTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)
        let key = try #require(store.requestedKeys.last)

        fake.failure.withLock {
            $0 = .commandFailed(.herdrCore, status: 255, stderr: "Connection refused")
        }
        await #expect(throws: BackendTerminalCommandError.self) {
            try await model.openBackendTerminal(environment.selection(Self.coreTerminal))
        }

        #expect(model.activeBackendTerminalSelection == opened)
        #expect(!store.removedKeys.contains(key))
        #expect(model.activeBorrowedBackendTerminalConnectionState == .connected)
        await model.shutdown()
    }

    @Test("a terminal whose program ends closes; one still listed keeps Reconnect")
    func programEnds() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)

        // The attach client exits, but Herdr Core still lists the terminal.
        var closed: Set<UUID> = []
        let attachments = store.requestedKeys.count
        try closeNewestSurface(store, closed: &closed, exitCode: 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.activeBackendTerminalSelection == opened)
        #expect(model.activeBorrowedBackendTerminalConnectionState != .connected)
        #expect(store.requestedKeys.count == attachments, "No attach starts by itself")

        model.reconnectActiveBackendTerminalNow()
        await launchSurface(model, store: store, after: attachments)

        // The program ended, so Herdr Core no longer lists the terminal.
        fake.terminals.withLock { $0 = [] }
        try closeNewestSurface(store, closed: &closed, exitCode: 0)
        await waitUntilMainActor { model.activeBackendTerminalSelection == nil }
        #expect(model.snapshot.host(id: environment.host.id)?.backendTerminals
            .contains(Self.attachedTerminal) == false)
        await model.shutdown()
    }

    @Test("a dropped SSH connection reattaches by itself and a clean detach stays detached")
    func automaticReconnect() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)

        // OpenSSH exits with status 255 when the connection drops.
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        await launchSurface(model, store: store, after: 1)
        #expect(model.activeBackendTerminalSelection == opened)

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
        let discovery = BlockingBackendDiscovery(listing: [.rex: .available([Self.rexWindow])])
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
                == [Self.rexWindow]
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
        try await model.openBackendTerminal(environment.selection(Self.attachedTerminal))
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
        let fake = FakeHost([Self.attachedTerminal])
        fake.executableFailures.withLock {
            $0 = [.commandFailed(
                .herdrCore, status: 255,
                stderr: "ssh: connect to host builder port 22: Connection refused"
            )]
        }
        let model = try makeTerminalModel(environment, store: store, fake: fake)

        try await model.openBackendTerminal(environment.selection(Self.attachedTerminal))
        await launchSurface(model, store: store)

        #expect(fake.attaches.withLock { $0 } == 2)
        await model.shutdown()
    }

    @Test("a saved terminal is restored after a transient validation failure")
    func restorationRetriesTransientFailure() async throws {
        let environment = try environment(terminals: [])
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        fake.validationFailures.withLock {
            $0 = [.commandFailed(.herdrCore, status: 1, stderr: "server busy")]
        }
        // No scheduled refresh lists the host again, so the retry must.
        let model = try makeTerminalModel(
            environment,
            store: store,
            fake: fake,
            workspaceInventoryStore: makeCadenceInventoryStore(cadence: AsyncGate())
        )
        let opened = environment.selection(Self.attachedTerminal)
        let windowID = UUID()
        model.beginRestoration(WorkspaceWindowState(
            windowID: windowID,
            navigation: .init(hostKey: "local", projectKey: nil, worktreeGeneration: nil),
            tmux: nil,
            backendTerminal: .init(hostKey: "local", kind: .herdrCore, address: opened.address)
        ))

        model.startHerdrSessionDiscovery()
        await launchSurface(model, store: store)

        #expect(model.activeBackendTerminalSelection == opened)
        #expect(model.restorationState(windowID: windowID).backendTerminal?.address
            == opened.address)
        await model.shutdown()
    }

    @Test("a restoration retry waits out a sweep still listing another host")
    func restorationRetryDuringSweep() async throws {
        let environment = try environment(terminals: [Self.attachedTerminal], remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        fake.validationFailures.withLock {
            $0 = [.commandFailed(.herdrCore, status: 1, stderr: "server busy")]
        }
        // This Mac's listing stays slow while the remote one is restored.
        let slowLocal = BlockingBackendDiscovery(listing: [:])
        let model = try makeTerminalModel(
            environment,
            store: store,
            fake: fake,
            discovery: { host in
                host == .local ? slowLocal.discover() : [.herdrCore: fake.listing(.herdrCore)]
            }
        )
        let opened = environment.selection(Self.attachedTerminal)
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(hostKey: "builder", projectKey: nil, worktreeGeneration: nil),
            tmux: nil,
            backendTerminal: .init(hostKey: "builder", kind: .herdrCore, address: opened.address)
        ))

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor {
            slowLocal.starts == 1 && fake.validationFailures.withLock { $0.isEmpty }
        }
        try await Task.sleep(for: .milliseconds(50))
        slowLocal.release()
        await launchSurface(model, store: store)

        #expect(model.activeBackendTerminalSelection == opened)
        await model.shutdown()
    }

    @Test("a restoration retry lists its host again after a sweep that already listed it")
    func restorationRetryAfterListedHost() async throws {
        // Only fresh inventory can confirm the saved terminal on the remote.
        let environment = try environment(terminals: [], remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        fake.validationFailures.withLock {
            $0 = [.commandFailed(.herdrCore, status: 1, stderr: "server busy")]
        }
        // This Mac's listing keeps the sweep running after the remote one,
        // and no scheduled refresh lists the remote again.
        let slowLocal = BlockingBackendDiscovery(listing: [:])
        let model = try makeTerminalModel(
            environment,
            store: store,
            fake: fake,
            discovery: { host in
                host == .local ? slowLocal.discover() : [.herdrCore: fake.listing(.herdrCore)]
            },
            workspaceInventoryStore: makeCadenceInventoryStore(cadence: AsyncGate())
        )
        let opened = environment.selection(Self.attachedTerminal)
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(hostKey: "builder", projectKey: nil, worktreeGeneration: nil),
            tmux: nil,
            backendTerminal: .init(hostKey: "builder", kind: .herdrCore, address: opened.address)
        ))

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor {
            slowLocal.starts == 1 && fake.validationFailures.withLock { $0.isEmpty }
        }
        try await Task.sleep(for: .milliseconds(50))
        slowLocal.release()
        await launchSurface(model, store: store)

        #expect(model.activeBackendTerminalSelection == opened)
        await model.shutdown()
    }

    @Test("a reconnect that needs SSH approval asks for review and resumes after it")
    func reconnectNeedsApproval() async throws {
        let environment = try environment(remote: true)
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)

        fake.validationFailures.withLock {
            $0 = [.commandFailed(
                .herdrCore, status: 255, stderr: "ghosthub-kwt-ssh-error:ssh_interaction_required"
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
        #expect(model.activeBackendTerminalSelection == opened)
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
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)
        let key = try #require(store.requestedKeys.last)

        model.openBorrowedZellijSession(.init(hostID: environment.host.id, name: "work"))
        await waitUntilMainActor { model.pendingZellijPresentationSelection == nil }

        #expect(model.activeBackendTerminalSelection == opened)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(!store.removedKeys.contains(key))
        await model.shutdown()
    }

    @Test("repeated sibling shortcuts walk past a terminal that is still opening")
    func repeatedSiblingShortcuts() async throws {
        let terminals = ["01", "02", "03"].map {
            BackendTerminalSummary(kind: .herdrCore, address: "t\($0)", title: "shell \($0)")
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
            BackendTerminalSummary(kind: .herdrCore, address: "t\($0)", title: "shell \($0)")
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
        let fake = FakeHost([Self.attachedTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)

        fake.validationFailures.withLock {
            $0 = [.commandFailed(
                .herdrCore, status: 255, stderr: "ghosthub-kwt-ssh-error:ssh_interaction_required"
            )]
        }
        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        await waitUntilMainActor { model.sessionConnectionRecoveryRequest != nil }

        model.closeBackendTerminal(opened)

        #expect(model.sessionConnectionRecoveryRequest == nil)
        await model.shutdown()
    }

    @Test("Cmd-W cancels a shortcut still checking the next terminal")
    func closeCancelsShortcut() async throws {
        let terminals = ["01", "02"].map {
            BackendTerminalSummary(kind: .herdrCore, address: "t\($0)", title: "shell \($0)")
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
            terminals: [Self.attachedTerminal, Self.coreTerminal], remote: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal, Self.coreTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
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
        fake.terminals.withLock { $0 = [Self.attachedTerminal] }
        gate.open()
        await #expect(throws: BackendTerminalPresentationError.self) {
            try await opening.value
        }
        await launchSurface(model, store: store, after: 1)

        #expect(model.activeBackendTerminalSelection == opened)
        #expect(fake.attaches.withLock { $0 } == 2)
        await model.shutdown()
    }
    @Test("Cmd-W from a terminal cancels a shortcut still checking a Herdr session")
    func closeCancelsHerdrShortcut() async throws {
        let environment = try environment(
            terminals: [Self.attachedTerminal],
            herdrSessions: [.init(name: "work", isDefault: false, state: .running)]
        )
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        model.selection.select(
            .backendTerminal(hostID: opened.hostID, kind: opened.kind, address: opened.address),
            in: environment.snapshot
        )
        model.isFocusedWindow = true
        let gate = AsyncGate()
        fake.nextHerdrValidationGate.withLock { $0 = gate }

        #expect(model.performApplicationShortcut(.nextSibling))
        #expect(model.pendingHerdrShortcutSelection?.name == "work")
        model.cancelPendingSessionOpens()
        model.closeBackendTerminal(opened)
        gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(model.activeBackendTerminalSelection == nil)
        await model.shutdown()
    }

    @Test("a terminal's reconnect waits while a Herdr session is checked")
    func reconnectWaitsForHerdrCheck() async throws {
        let environment = try environment(
            terminals: [Self.attachedTerminal],
            herdrSessions: [.init(name: "work", isDefault: false, state: .running)],
            remote: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
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

        #expect(model.activeBackendTerminalSelection == opened)
        #expect(fake.attaches.withLock { $0 } == 2)
        await model.shutdown()
    }

    @Test("a terminal takes no input and holds its reconnect while a Zellij session is checked")
    func zellijCheckHoldsTerminal() async throws {
        let environment = try environment(
            terminals: [Self.attachedTerminal],
            zellijSessions: [.init(name: "work")],
            remote: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        let gate = AsyncGate()
        let gated = Mutex(false)
        let model = try makeTerminalModel(
            environment,
            store: store,
            fake: fake,
            zellijSessionDiscovery: { _ in
                if gated.withLock({ $0 }) {
                    await gate.wait()
                }
                // The session ended after the sidebar listed it.
                return .available([])
            }
        )
        let opened = environment.selection(Self.attachedTerminal)
        try await model.openBackendTerminal(opened)
        await launchSurface(model, store: store)

        gated.withLock { $0 = true }
        model.openBorrowedZellijSession(.init(hostID: environment.localHostID, name: "work"))
        #expect(model.isCheckingSessionPresentation)
        #expect(store.surface.isKeyboardInteractionSuspended)

        var closed: Set<UUID> = []
        try closeNewestSurface(store, closed: &closed, exitCode: 255)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.attaches.withLock { $0 } == 1)

        gate.open()
        await waitUntilMainActor { model.pendingZellijPresentationSelection == nil }
        await launchSurface(model, store: store, after: 1)

        #expect(model.activeBackendTerminalSelection == opened)
        #expect(fake.attaches.withLock { $0 } == 2)
        #expect(!store.surface.isKeyboardInteractionSuspended)
        await model.shutdown()
    }

    @Test("a tmux session takes no input until the terminal replacing it is checked")
    func terminalCheckHoldsTmux() async throws {
        let environment = try environment(terminals: [Self.attachedTerminal])
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        let model = try makeTerminalModel(environment, store: store, fake: fake)
        let tmux = WorkspaceTmuxSessionSelection(hostID: environment.host.id, name: "tmux-work")
        model.openBorrowedTmuxSession(tmux)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return store.requestedKeys.contains { $0.target == .tmuxSession }
        }

        let gate = AsyncGate()
        fake.nextValidationGate.withLock { $0 = gate }
        let opening = Task { @MainActor in
            try await model.openBackendTerminal(environment.selection(Self.attachedTerminal))
        }
        await waitUntilMainActor { fake.nextValidationGate.withLock { $0 == nil } }
        #expect(store.surface.isKeyboardInteractionSuspended)

        // The terminal ended, so the open fails and tmux stays.
        fake.terminals.withLock { $0 = [] }
        gate.open()
        await #expect(throws: (any Error).self) { try await opening.value }

        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(!store.surface.isKeyboardInteractionSuspended)
        await model.shutdown()
    }

    @Test(
        "a tmux session takes focus back when a Zellij open fails, unless focus moved",
        arguments: [false, true]
    )
    func failedZellijOpenRestoresTmuxFocus(focusMoved: Bool) async throws {
        let environment = try environment(terminals: [], zellijSessions: [.init(name: "work")])
        let store = RecordingNativeSessionSurfaceStore()
        let gate = AsyncGate()
        let model = try makeTerminalModel(
            environment,
            store: store,
            zellijSessionDiscovery: { _ in
                await gate.wait()
                // The session ended after the sidebar listed it.
                return .available([])
            }
        )
        let tmux = WorkspaceTmuxSessionSelection(hostID: environment.host.id, name: "tmux-work")
        model.openBorrowedTmuxSession(tmux)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return store.requestedKeys.contains { $0.target == .tmuxSession }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let elsewhere = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = elsewhere
        model.workspaceWindow = window

        model.openBorrowedZellijSession(.init(hostID: environment.host.id, name: "work"))
        #expect(window.firstResponder === window)
        if focusMoved {
            #expect(window.makeFirstResponder(elsewhere))
        }
        let requestsBeforeFailure = store.surface.keyboardFocusRequestCount
        gate.open()
        await waitUntilMainActor { model.pendingZellijPresentationSelection == nil }

        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(!store.surface.isKeyboardInteractionSuspended)
        #expect(
            store.surface.keyboardFocusRequestCount
                == requestsBeforeFailure + (focusMoved ? 0 : 1)
        )
        await model.shutdown()
    }

    @Test("a Zellij session takes no input until the terminal replacing it is checked")
    func terminalCheckHoldsZellij() async throws {
        let environment = try environment(
            terminals: [Self.attachedTerminal],
            zellijSessions: [.init(name: "work")]
        )
        let store = RecordingNativeSessionSurfaceStore()
        let fake = FakeHost([Self.attachedTerminal])
        let model = try makeTerminalModel(
            environment,
            store: store,
            fake: fake,
            zellijSessionDiscovery: { _ in .available(["work"]) }
        )
        let zellij = WorkspaceZellijSessionSelection(hostID: environment.host.id, name: "work")
        model.openBorrowedZellijSession(zellij)
        await waitUntilMainActor {
            model.prepareActiveBorrowedZellijSurface()
            return store.requestedKeys.contains { $0.target == .zellijSession }
        }

        let gate = AsyncGate()
        fake.nextValidationGate.withLock { $0 = gate }
        let opening = Task { @MainActor in
            try await model.openBackendTerminal(environment.selection(Self.attachedTerminal))
        }
        await waitUntilMainActor { fake.nextValidationGate.withLock { $0 == nil } }
        #expect(store.surface.isKeyboardInteractionSuspended)

        fake.terminals.withLock { $0 = [] }
        gate.open()
        await #expect(throws: (any Error).self) { try await opening.value }

        #expect(model.activeBorrowedZellijSelection == zellij)
        #expect(!store.surface.isKeyboardInteractionSuspended)
        await model.shutdown()
    }

    // MARK: Rex windows

    /// The `kwt rex control` channels the scene started, newest last.
    @MainActor
    final class RexChannels {
        var started: [(command: String, channel: FakeRexControlChannel)] = []
        var latest: FakeRexControlChannel? { started.last?.channel }
    }

    private static let twoPanes = #"""
    {"split":{"split_id":"split:1","direction":"horizontal","ratio":0.5,
     "before":{"block_id":"block:a"},"after":{"block_id":"block:b"}}}
    """#

    /// Opens the Rex window row and delivers a two-pane view.
    private func openRexWindow(
        _ model: WorkspaceSceneModel,
        _ environment: Environment,
        channels: RexChannels,
        store: RecordingNativeSessionSurfaceStore
    ) async throws -> FakeRexControlChannel {
        try await model.openBackendTerminal(environment.selection(Self.rexWindow))
        await waitUntilMainActor { channels.latest != nil }
        let channel = try #require(channels.latest)
        try channel.deliver(layout: Self.twoPanes, focused: "block:a", window: "window:01aa")
        await waitUntilMainActor {
            model.shownRexWindow != nil && store.requestedKeys.count == 2
        }
        model.shownRexWindow?.container.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        return channel
    }

    private func waitForRequest(
        _ channel: FakeRexControlChannel,
        count: Int
    ) async -> (method: String, params: NSDictionary)? {
        await waitUntilMainActor { channel.requests.count >= count }
        return channel.requests.last
    }

    @Test("a Rex window row follows the window with kwt rex control and attaches each pane")
    func rexWindowOpens() async throws {
        let environment = try environment(terminals: [Self.rexWindow])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let model = try makeTerminalModel(environment, store: store, rexChannels: channels)

        _ = try await openRexWindow(model, environment, channels: channels, store: store)

        let command = try #require(channels.started.first?.command)
        #expect(command.contains("/opt/test/kwt"))
        #expect(command.contains("control"))
        #expect(command.contains("window:01aa"))
        #expect(model.activeBorrowedBackendTerminalConnectionState == .connected)
        #expect(store.requestedConfigurations.allSatisfy {
            $0.command?.contains("attach") == true
        })
        #expect(store.requestedConfigurations.contains { $0.command?.contains("block:a") == true })
        #expect(store.requestedConfigurations.contains { $0.command?.contains("block:b") == true })
        await model.shutdown()
    }

    @Test("a new Rex session's window is listed for the sidebar to open")
    func rexSessionCreation() async throws {
        let environment = try environment(terminals: [Self.rexWindow])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let fake = FakeHost([Self.rexWindow])
        let created = BackendTerminalSummary(
            kind: .rex, address: "window:02bb", title: "zsh ~", detail: "work · 1 pane"
        )
        let requests = Mutex<[RexWindowRequest]>([])
        let model = try makeTerminalModel(
            environment, store: store, fake: fake,
            rexWindowCreation: { _, request, _ in
                requests.withLock { $0.append(request) }
                fake.terminals.withLock { $0.append(created) }
                return .success(created.address)
            }
        )

        let selection = try await model.createRexWindow(
            RexWindowRequest(label: "work"), hostID: environment.host.id
        )

        #expect(selection == environment.selection(created))
        #expect(requests.withLock { $0 } == [RexWindowRequest(label: "work")])
        #expect(model.snapshot.host(id: environment.host.id)?.backendTerminals
            .contains(created) == true)
        #expect(model.snapshot.host(id: environment.host.id)?.rexAvailable == true)

        fake.failure.withLock { $0 = .commandFailed(.rex, status: 1, stderr: "no server") }
        await #expect(throws: BackendTerminalCommandError.self) {
            _ = try await model.createRexWindow(RexWindowRequest(), hostID: environment.host.id)
        }
        await model.shutdown()
    }

    @Test("Rex refusing a new window reports its message")
    func rexCreationFailure() async throws {
        let environment = try environment(terminals: [Self.rexWindow])
        let model = try makeTerminalModel(
            environment, store: RecordingNativeSessionSurfaceStore(),
            rexWindowCreation: { _, _, _ in
                .failure(.commandFailed(.rex, status: 1, stderr: "the Rex server is not running"))
            }
        )
        await #expect {
            _ = try await model.createRexWindow(RexWindowRequest(), hostID: environment.host.id)
        } throws: { error in
            error.localizedDescription.contains("the Rex server is not running")
        }
        await model.shutdown()
    }

    @Test("New Rex Window opens in the shown window's session, where its focused pane is")
    func rexNewWindowBesideShown() async throws {
        let environment = try environment(terminals: [Self.rexWindow, Self.coreTerminal])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let model = try makeTerminalModel(environment, store: store, rexChannels: channels)
        #expect(model.newRexWindowRequest == nil)
        #expect(!model.performApplicationShortcut(.newRexWindow, invocation: .menu))

        let channel = try await openRexWindow(model, environment, channels: channels, store: store)
        try channel.deliver(
            layout: Self.twoPanes, focused: "block:b", window: "window:01aa",
            terminals: #"{"block:b":{"name":"zsh ~/src","cwd":"/home/user-a/src"}}"#
        )

        let pending = try #require(model.newRexWindowRequest)
        #expect(pending.hostID == environment.host.id)
        #expect(pending.request == RexWindowRequest(
            sessionID: "session:s", cwd: "/home/user-a/src"
        ))
        #expect(model.availablePaletteApplicationShortcuts.contains(.newRexWindow))
        #expect(model.performApplicationShortcut(.newRexWindow, invocation: .menu))
        await model.shutdown()
    }

    @Test("pane shortcuts reach Rex only while a Rex window is shown")
    func rexWindowShortcuts() async throws {
        let environment = try environment(terminals: [Self.rexWindow, Self.coreTerminal])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let model = try makeTerminalModel(environment, store: store, rexChannels: channels)
        #expect(!model.performApplicationShortcut(.focusPaneRight, invocation: .menu))
        #expect(!model.performApplicationShortcut(.zoomPane, invocation: .menu))

        let channel = try await openRexWindow(model, environment, channels: channels, store: store)

        #expect(model.performApplicationShortcut(.splitRight, invocation: .menu))
        #expect(await waitForRequest(channel, count: 1)?.method == "session.new_split")
        #expect(model.performApplicationShortcut(.focusPaneRight, invocation: .menu))
        let focus = await waitForRequest(channel, count: 2)
        #expect(focus?.method == "session.focus_block")
        #expect(focus?.params == ["block_id": "block:b"] as NSDictionary)
        #expect(!model.performApplicationShortcut(.focusPaneRight, invocation: .menu))
        #expect(model.performApplicationShortcut(.zoomPane, invocation: .menu))
        #expect(await waitForRequest(channel, count: 3)?.method == "session.zoom_block")

        // A tiled pane can float; only a floating one can be minimized.
        #expect(model.availablePaletteApplicationShortcuts.isSuperset(
            of: [.newFloatingPane, .toggleFloatingPane]
        ))
        #expect(!model.availablePaletteApplicationShortcuts.contains(.minimizeFloatingWindow))
        #expect(model.performApplicationShortcut(.toggleFloatingPane, invocation: .menu))
        #expect(await waitForRequest(channel, count: 4)?.method == "session.float_block")
        #expect(model.performApplicationShortcut(.newFloatingPane, invocation: .menu))
        #expect(await waitForRequest(channel, count: 5)?.method == "session.new_layer")

        try await model.openBackendTerminal(environment.selection(Self.coreTerminal))
        #expect(channel.isStopped)
        #expect(!model.performApplicationShortcut(.focusPaneRight, invocation: .menu))
        await model.shutdown()
    }

    private static let twoBlocks = #"[{"block_id":"block:a","label":"shell"},{"block_id":"block:b","label":"shell"}]"#

    @Test("the open Rex window's sidebar row follows its live view")
    func rexWindowLiveRow() async throws {
        let environment = try environment(terminals: [Self.rexWindow])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let model = try makeTerminalModel(environment, store: store, rexChannels: channels)
        let channel = try await openRexWindow(model, environment, channels: channels, store: store)
        func row() -> BackendTerminalSummary? {
            model.snapshot.hosts.flatMap(\.backendTerminals).first { $0.address == "window:01aa" }
        }

        try channel.deliver(
            layout: Self.twoPanes, focused: "block:b", window: "window:01aa",
            terminals: #"{"block:a":{"name":"vim notes"},"block:b":{"name":"htop"}}"#,
            windowLabel: "Window 01aa0000", blocks: Self.twoBlocks
        )
        await waitUntilMainActor { row()?.title == "htop" }
        #expect(row()?.detail == "work · 2 panes")

        try channel.deliver(
            layout: Self.twoPanes, focused: "block:a", window: "window:01aa",
            terminals: #"{"block:a":{"name":"vim notes"},"block:b":{"name":"htop"}}"#,
            windowLabel: "Window 01aa0000", blocks: Self.twoBlocks
        )
        await waitUntilMainActor { row()?.title == "vim notes" }
        await model.shutdown()
    }

    @Test("a split key reaches Rex only from a Rex pane with keyboard focus")
    func rexWindowSplitKeyNeedsFocus() async throws {
        let environment = try environment(terminals: [Self.rexWindow])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let model = try makeTerminalModel(environment, store: store, rexChannels: channels)
        let channel = try await openRexWindow(model, environment, channels: channels, store: store)

        // Typing elsewhere, such as in the Console Panel.
        model.splitActivePane(.right, requiresKeyboardFocus: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(channel.requests.isEmpty)

        let index = try #require(store.requestedConfigurations.firstIndex {
            $0.command?.contains("block:b") == true
        })
        let pane = try #require(
            store.paneSurfaceIfPresent(for: store.requestedKeys[index])
                as? RecordingNativeSessionPaneSurface
        )
        pane.hasEffectiveKeyboardFocus = true
        model.splitActivePane(.right, requiresKeyboardFocus: true)
        #expect(await waitForRequest(channel, count: 1)?.method == "session.new_split")
        await model.shutdown()
    }

    @Test("Close Pane asks first; closing the view leaves every pane running")
    func rexWindowClose() async throws {
        let environment = try environment(terminals: [Self.rexWindow])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let model = try makeTerminalModel(environment, store: store, rexChannels: channels)
        let channel = try await openRexWindow(model, environment, channels: channels, store: store)

        #expect(model.performApplicationShortcut(.closePane, invocation: .menu))
        let request = try #require(model.rexPaneCloseRequest)
        #expect(request.blockID == "block:a")
        try await Task.sleep(for: .milliseconds(50))
        #expect(channel.requests.isEmpty)
        model.confirmRexPaneClose(request)
        let close = await waitForRequest(channel, count: 1)
        #expect(close?.method == "block.close")
        #expect(close?.params == ["block_id": "block:a"] as NSDictionary)

        model.closeBackendTerminal(environment.selection(Self.rexWindow))
        #expect(channel.isStopped)
        model.confirmRexPaneClose(request)
        try await Task.sleep(for: .milliseconds(50))
        #expect(channel.requests.count == 1)
        #expect(store.removedKeys.count == 2)
        await model.shutdown()
    }

    @Test("a Rex window's panes take no input while another session is checked")
    func rexWindowHeldDuringCheck() async throws {
        let environment = try environment(terminals: [Self.rexWindow, Self.coreTerminal])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let fake = FakeHost([Self.rexWindow, Self.coreTerminal])
        let model = try makeTerminalModel(
            environment, store: store, fake: fake, rexChannels: channels
        )
        _ = try await openRexWindow(model, environment, channels: channels, store: store)
        let panes = store.requestedKeys.compactMap {
            store.paneSurfaceIfPresent(for: $0) as? RecordingNativeSessionPaneSurface
        }
        #expect(panes.count == 2)

        let gate = AsyncGate()
        fake.nextValidationGate.withLock { $0 = gate }
        let opening = Task { @MainActor in
            try await model.openBackendTerminal(environment.selection(Self.coreTerminal))
        }
        await waitUntilMainActor { fake.nextValidationGate.withLock { $0 == nil } }
        #expect(panes.allSatisfy { $0.isKeyboardInteractionSuspended })

        // The terminal ended, so the open fails and the Rex window stays.
        fake.terminals.withLock { $0 = [Self.rexWindow] }
        gate.open()
        await #expect(throws: (any Error).self) { try await opening.value }
        #expect(model.shownRexWindow != nil)
        #expect(panes.allSatisfy { !$0.isKeyboardInteractionSuspended })
        await model.shutdown()
    }

    @Test("a Rex window reconnects when SSH drops while Ghosthub finds kwt")
    func rexWindowDroppedLookupReconnects() async throws {
        let environment = try environment(terminals: [Self.rexWindow], remote: true)
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let fake = FakeHost([Self.rexWindow])
        fake.executableFailures.withLock {
            $0 = [.commandFailed(
                .rex, status: 255,
                stderr: "ssh: connect to host builder port 22: Connection refused"
            )]
        }
        let model = try makeTerminalModel(
            environment, store: store, fake: fake, rexChannels: channels
        )

        try await model.openBackendTerminal(environment.selection(Self.rexWindow))

        await waitUntilMainActor { channels.latest != nil }
        #expect(channels.started.count == 1)
        await model.shutdown()
    }

    // MARK: Herdr desktop tabs

    private nonisolated static let herdrTab = BackendTerminalSummary(
        kind: .herdrCore, address: "tab:tb1", title: "ready", detail: "Review · 2 panes"
    )

    @Test("a Herdr desktop tab shows its panes together, and only Herdr changes its layout")
    func herdrTabOpens() async throws {
        let environment = try environment(terminals: [Self.herdrTab, Self.coreTerminal])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        var commands: [String] = []
        let events = FakeHerdrCoreEvents()
        let model = try makeTerminalModel(
            environment, store: store,
            herdrTabChannelFactory: { address, command, _ in
                commands.append(command)
                return HerdrTabChannel(tabAddress: address, events: events) {
                    .success(HerdrCoreListing(
                        rows: [Self.herdrTab],
                        tabs: [HerdrCoreTab(
                            address: "tab:tb1", name: "ready", spaceName: "Review",
                            root: .split(
                                id: "r#0", axis: .horizontal, ratio: 0.5,
                                first: .pane("t1"), second: .pane("t2")
                            )
                        )],
                        paneNames: ["t1": "sh", "t2": "build-watch"],
                        paneDirectories: [:]
                    ))
                }
            }
        )

        try await model.openBackendTerminal(environment.selection(Self.herdrTab))
        await waitUntilMainActor {
            model.shownRexWindow != nil && store.requestedKeys.count == 2
        }
        let window = try #require(model.shownRexWindow)
        window.container.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)

        let command = try #require(commands.first)
        #expect(command.contains("/opt/test/herdr-core"))
        #expect(command.contains("connect"))
        #expect(command.contains("GHOSTHUB_HC_EVENTS"))
        let attaches = store.requestedConfigurations.compactMap(\.command)
        #expect(attaches
            .contains {
                $0.contains("/opt/test/herdr-core") && $0.contains("attach") && $0.contains("t1")
            })
        #expect(attaches.contains { $0.contains("t2") })
        #expect(model.activeBorrowedBackendTerminalConnectionState == .connected)

        #expect(!model.canSplitActivePane)
        #expect(!window.container.isLayoutEditable)
        #expect(model.availablePaletteApplicationShortcuts.contains(.zoomPane))
        #expect(model.availablePaletteApplicationShortcuts.isDisjoint(
            with: [.splitRight, .splitDown, .closePane, .newFloatingPane, .toggleFloatingPane]
        ))
        #expect(!model.performApplicationShortcut(.closePane, invocation: .menu))
        #expect(!model.performApplicationShortcut(.toggleFloatingPane, invocation: .menu))

        #expect(model.performApplicationShortcut(.focusPaneRight, invocation: .menu))
        await waitUntilMainActor { model.shownRexWindow?.tree?.focusedPaneID == "t2" }
        #expect(model.performApplicationShortcut(.zoomPane, invocation: .menu))
        await waitUntilMainActor { model.shownRexWindow?.tree?.zoomedPaneID == "t2" }
        await model.shutdown()
        #expect(events.stopped)
    }

    @Test("a Rex window whose session ends closes")
    func rexWindowEnds() async throws {
        let environment = try environment(terminals: [Self.rexWindow])
        let store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
        let channels = RexChannels()
        let model = try makeTerminalModel(environment, store: store, rexChannels: channels)
        let channel = try await openRexWindow(model, environment, channels: channels, store: store)

        channel.onExit?(.ended)

        #expect(model.activeBackendTerminalSelection == nil)
        #expect(store.removedKeys.count == 2)
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
