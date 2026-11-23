import Foundation
import GhosthubTmux
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

/// A host whose tmux server can stop, as in a reboot, and whose kwt then
/// lists the stopped session as a saved copy. A restored session runs on a
/// new server, so it has a new server PID, session ID, and creation time.
private final class RebootingHost: Sendable {
    let serverRunning = LockedValue(true)
    let hasSavedCopy = LockedValue(false)
    let listingFails = LockedValue(false)
    /// How many times the server has been started again.
    let generation = LockedValue(0)
    let restoreOutcome: String
    /// When set, a restore creates the session, then waits for this before
    /// it reports, as kwt does while panes start their programs.
    let restoreGate: DispatchSemaphore?
    /// When set, `kwt session forget` waits for this.
    let forgetGate: DispatchSemaphore?
    let commands = Mutex<[String]>([])

    init(
        restoreOutcome: String = "restored",
        restoreGate: DispatchSemaphore? = nil,
        forgetGate: DispatchSemaphore? = nil
    ) {
        self.restoreOutcome = restoreOutcome
        self.restoreGate = restoreGate
        self.forgetGate = forgetGate
    }

    var restores: [String] {
        commands.withLock { $0 }.filter { $0.contains("'restore'") }
    }

    var forgets: [String] {
        commands.withLock { $0 }.filter { $0.contains("'forget'") }
    }

    func reboot() {
        serverRunning.withLock { $0 = false }
        hasSavedCopy.withLock { $0 = true }
    }

    var discovery: @Sendable (CommandHost) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        { [self] _ in
            guard serverRunning.load() else { return .success([]) }
            let generation = generation.load()
            return .success([DiscoveredTmuxSession(
                name: "api", windowCount: 1,
                serverPID: String(101 + generation * 100),
                sessionID: "$\(1 + generation)",
                createdAt: String(1000 + generation * 1000), managed: false
            )])
        }
    }

    var client: KwtSessionClient {
        KwtSessionClient(
            localRunner: { [self] command in
                commands.withLock { $0.append(command) }
                let marker = "GHOSTHUB_KWT_SESSION_JSON\n"
                if command.contains("'snapshot'") {
                    if listingFails.load() {
                        return (1, "")
                    }
                    guard hasSavedCopy.load() else {
                        return (0, marker + #"{"entries": []}"#)
                    }
                    return (0, marker + """
                    {"entries": [{"id": "a1", "session": "api",
                      "socket": {"path": "/tmp/tmux-501/default", "name": "default"}}]}
                    """)
                }
                if command.contains("'restore'") {
                    if restoreOutcome == "restored" {
                        hasSavedCopy.withLock { $0 = false }
                        generation.withLock { $0 += 1 }
                        serverRunning.withLock { $0 = true }
                    }
                    restoreGate?.wait()
                    return (0, marker + """
                    {"entries": [{"id": "a1", "session": "api",
                      "outcome": "\(restoreOutcome)", "reason": "tmux exited"}]}
                    """)
                }
                if command.contains("'forget'") {
                    forgetGate?.wait()
                    hasSavedCopy.withLock { $0 = false }
                }
                return (0, marker)
            },
            localBinaryPath: "/opt/kwt"
        )
    }
}

extension WorkspaceTmuxDiscoveryTests {
    /// Opens `api` in a window.
    @MainActor
    private func windowOn(
        _ host: RebootingHost,
        environment: StandardEnvironment? = nil,
        restores: SavedTmuxSessionRestores? = nil
    ) async throws -> (WorkspaceSceneModel, SceneTmuxSurfaceStoreStub, BorrowedTmuxSessionHandle) {
        let environment = try environment ?? setupStandardEnvironment()
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: host.discovery,
            kwtSessionClient: host.client,
            savedTmuxSessionRestores: restores,
            // Killing the server's last session stops the server.
            tmuxSessionKiller: { _, _, _ in host.reboot() }
        )
        model.startTmuxSessionDiscovery()
        model.startKwtInventory()
        await waitUntilMainActor { !model.snapshot.hosts[0].tmuxSessions.isEmpty }
        let api = WorkspaceTmuxSessionSelection(hostID: environment.host.id, name: "api")
        model.openBorrowedTmuxSession(api)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSessionIsConnected
        }
        let handle = try #require(model.retainedBorrowedTmuxHandle(for: api))
        return (model, store, handle)
    }

    /// Opens `api` in a window, then stops its server.
    @MainActor
    private func windowOnRebootedHost(
        _ host: RebootingHost,
        clientExit: UInt32 = 1
    ) async throws -> (WorkspaceSceneModel, SceneTmuxSurfaceStoreStub) {
        let (model, store, handle) = try await windowOn(host)
        host.reboot()
        store.surface.closeObservers[handle.id]?(false, clientExit)
        model.refreshTmuxSessionDiscovery()
        return (model, store)
    }

    /// Status 255 is the SSH connection dropping, which the reconnect probe
    /// follows up; status 1 is tmux reporting the session gone, which
    /// discovery confirms.
    @MainActor
    @Test(
        "a window whose host rebooted restores its session and attaches",
        arguments: [UInt32(1), 255]
    )
    func endedWindowRestoresSavedCopy(clientExit: UInt32) async throws {
        let host = RebootingHost()
        let (model, store) = try await windowOnRebootedHost(host, clientExit: clientExit)

        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return !host.restores.isEmpty && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(host.restores.count == 1)
        #expect(host.restores.first?.hasSuffix("session 'restore' '--json' 'a1'") == true)
        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        #expect(model.activeBorrowedTmuxSavedRestore == nil)
        // The attach expects the restored session's new identity, not the
        // one it had before the reboot.
        let attach = try #require(store.launchCommands.load().last)
        #expect(attach.contains("201"))
        #expect(!attach.contains("101"))
        await model.shutdown()
    }

    @MainActor
    @Test("a window attaches when discovery sees its restored session before kwt reports")
    func discoveryBeforeRestoreFinishes() async throws {
        let gate = DispatchSemaphore(value: 0)
        let host = RebootingHost(restoreGate: gate)
        let (model, _) = try await windowOnRebootedHost(host)
        await waitUntilMainActor { !host.restores.isEmpty }

        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSessionIsConnected
        }
        gate.signal()
        try await Task.sleep(for: .milliseconds(200))

        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxSavedRestore == nil)
        #expect(host.restores.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("a window whose session ended with no saved copy offers Reopen")
    func endedWindowWithoutSavedCopy() async throws {
        let host = RebootingHost()
        let (model, _) = try await windowOnRebootedHost(host)
        // The session was killed rather than lost with its server.
        host.hasSavedCopy.withLock { $0 = false }

        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConfirmedEnded
                && model.activeBorrowedTmuxSavedRestore == nil
        }

        #expect(host.restores.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("a failed saved-copy check shows an error instead of Reopen")
    func failedListingWaitsForRetry() async throws {
        let host = RebootingHost()
        let (model, store, handle) = try await windowOn(host)
        host.listingFails.withLock { $0 = true }
        host.reboot()
        store.surface.closeObservers[handle.id]?(false, 1)
        model.refreshTmuxSessionDiscovery()

        await waitUntilMainActor {
            if case .failed = model.activeBorrowedTmuxSavedRestore {
                return true
            }
            return false
        }
        #expect(host.restores.isEmpty)

        host.listingFails.withLock { $0 = false }
        model.retryActiveBorrowedTmuxSavedRestore()
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(host.restores.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("a failed restore shows why and waits for Retry Restore")
    func failedWindowRestoreWaitsForRetry() async throws {
        let host = RebootingHost(restoreOutcome: "failed")
        let (model, _) = try await windowOnRebootedHost(host)

        await waitUntilMainActor {
            model.activeBorrowedTmuxSavedRestore == .failed("api: failed (tmux exited)")
        }
        // A later inventory refresh must not restore it again on its own.
        model.refreshKwtInventory()
        model.refreshTmuxSessionDiscovery()
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.restores.count == 1)

        model.retryActiveBorrowedTmuxSavedRestore()
        await waitUntilMainActor { host.restores.count == 2 }
        #expect(host.restores.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("Kill Session keeps other windows from restoring the killed session")
    func killedSessionIsNotRestoredElsewhere() async throws {
        let forgetGate = DispatchSemaphore(value: 0)
        let host = RebootingHost(forgetGate: forgetGate)
        let environment = try setupStandardEnvironment()
        let restores = SavedTmuxSessionRestores()
        let (killer, _, _) = try await windowOn(host, environment: environment, restores: restores)
        let (watcher, watcherStore, watcherHandle) = try await windowOn(
            host, environment: environment, restores: restores
        )
        let request = TmuxSessionKillRequest(
            session: WorkspaceTmuxSessionSelection(hostID: environment.host.id, name: "api"),
            confirmedHost: killer.snapshot.hosts[0],
            serverPID: "101", sessionID: "$1", sessionCreatedAt: "1000"
        )

        // Killing the server's last session stops the server, and kwt saves
        // it as restorable before Ghosthub tells kwt to forget it.
        let kill = Task { try await killer.killTmuxSession(request) }
        await waitUntilMainActor { !host.forgets.isEmpty }
        watcherStore.surface.closeObservers[watcherHandle.id]?(false, 1)
        watcher.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            watcher.activeBorrowedTmuxSessionIsConfirmedEnded
                && watcher.activeBorrowedTmuxSavedRestore == nil
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.restores.isEmpty)

        forgetGate.signal()
        try await kill.value
        watcher.refreshKwtInventory()
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.restores.isEmpty)
        await killer.shutdown()
        await watcher.shutdown()
    }
}
