import Foundation
import GhosthubTmux
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

/// A host whose tmux server can stop, as in a reboot, and whose kwt then
/// lists the stopped session as a saved copy.
private final class RebootingHost: Sendable {
    let serverRunning = LockedValue(true)
    let hasSavedCopy = LockedValue(false)
    let restoreOutcome: String
    let commands = Mutex<[String]>([])

    init(restoreOutcome: String = "restored") {
        self.restoreOutcome = restoreOutcome
    }

    var restores: [String] {
        commands.withLock { $0 }.filter { $0.contains("'restore'") }
    }

    func reboot() {
        serverRunning.withLock { $0 = false }
        hasSavedCopy.withLock { $0 = true }
    }

    var discovery: @Sendable (CommandHost) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        { [self] _ in
            guard serverRunning.load() else { return .success([]) }
            return .success([DiscoveredTmuxSession(
                name: "api", windowCount: 1, serverPID: "101",
                sessionID: "$1", createdAt: "1000", managed: false
            )])
        }
    }

    var client: KwtSessionClient {
        KwtSessionClient(
            localRunner: { [self] command in
                commands.withLock { $0.append(command) }
                let marker = "GHOSTHUB_KWT_SESSION_JSON\n"
                if command.contains("'snapshot'") {
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
                        serverRunning.withLock { $0 = true }
                    }
                    return (0, marker + """
                    {"entries": [{"id": "a1", "session": "api",
                      "outcome": "\(restoreOutcome)", "reason": "tmux exited"}]}
                    """)
                }
                return (0, marker)
            },
            localBinaryPath: "/opt/kwt"
        )
    }
}

extension WorkspaceTmuxDiscoveryTests {
    /// Opens `api` in a window, then stops its server.
    @MainActor
    private func windowOnRebootedHost(
        _ host: RebootingHost,
        clientExit: UInt32 = 1
    ) async throws -> (WorkspaceSceneModel, SceneTmuxSurfaceStoreStub) {
        let environment = try setupStandardEnvironment()
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: host.discovery,
            kwtSessionClient: host.client
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
        let (model, _) = try await windowOnRebootedHost(host, clientExit: clientExit)

        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return !host.restores.isEmpty && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(host.restores.count == 1)
        #expect(host.restores.first?.hasSuffix("session 'restore' '--json' 'a1'") == true)
        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        #expect(model.activeBorrowedTmuxSavedRestore == nil)
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
}
