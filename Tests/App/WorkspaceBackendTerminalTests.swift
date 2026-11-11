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
        var host: HostSummary
        var snapshot: WorkspaceSnapshot

        func selection(_ terminal: BackendTerminalSummary) -> WorkspaceBackendTerminalSelection {
            .init(hostID: host.id, kind: terminal.kind, address: terminal.address)
        }
    }

    private func environment(
        terminals: [BackendTerminalSummary] = [rexTerminal, coreTerminal],
        herdrSessions: [HerdrSessionSummary] = []
    ) throws -> Environment {
        let host = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            herdrSessions: herdrSessions,
            herdrAvailable: !herdrSessions.isEmpty,
            backendTerminals: terminals
        )
        return try Environment(
            database: WorkspaceDatabase.inMemory(),
            host: host,
            snapshot: WorkspaceSnapshot(hosts: [host], projects: [], worktrees: [])
        )
    }

    private func makeTerminalModel(
        _ environment: Environment,
        store: RecordingNativeSessionSurfaceStore,
        discovery: @escaping WorkspaceSceneModel.BackendTerminalDiscovery = { _ in [:] },
        herdrStore: RecordingNativeSessionSurfaceStore? = nil
    ) throws -> WorkspaceSceneModel {
        try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeHerdrSurfaceStore: herdrStore,
            nativeBackendTerminalSurfaceStore: store,
            nativeBackendTerminalExecutableProvider: { kind, _, _ in
                .success(kind == .rex ? "/opt/test/kwt" : "/opt/test/herdr-core")
            },
            nativeHerdrPathProvider: { _ in .success("/opt/test/herdr") },
            herdrPaneSplitCapabilityProvider: { _, _, _, _ in .success(nil) },
            herdrSessionDiscovery: { _ in .available(environment.host.herdrSessions) },
            backendTerminalDiscovery: discovery
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

    @Test("a local Rex terminal attaches through Ghosthub's kwt in its own surface")
    func localRexAttach() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeTerminalModel(environment, store: store)
        let rex = environment.selection(Self.rexTerminal)

        model.openBackendTerminal(rex)
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

        model.openBackendTerminal(environment.selection(Self.rexTerminal))

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
        model.openBackendTerminal(core)
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
        model.openBackendTerminal(rex)
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
        let listed = Mutex<[BackendTerminalSummary]>([Self.rexTerminal])
        let model = try makeTerminalModel(environment, store: store, discovery: { _ in
            [.rex: .available(listed.withLock { $0 })]
        })
        let rex = environment.selection(Self.rexTerminal)
        model.openBackendTerminal(rex)
        await launchSurface(model, store: store)

        // The attach client exits after a detach; the terminal still runs.
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 0)
        #expect(model.activeBackendTerminalSelection == rex)
        #expect(model.activeBorrowedBackendTerminalConnectionState != .connected)
        let attachments = store.requestedKeys.count
        model.reconnectActiveBackendTerminalNow()
        await launchSurface(model, store: store, after: attachments)
        #expect(model.activeBackendTerminalSelection == rex)

        // The program ended, so Rex no longer lists the block.
        let reattached = try #require(store.surface.closeObservers.values.first)
        reattached(false, 1)
        listed.withLock { $0 = [] }
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
        let model = try makeTerminalModel(environment, store: store, discovery: { _ in
            [.rex: .available([Self.rexTerminal])]
        })
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
}
