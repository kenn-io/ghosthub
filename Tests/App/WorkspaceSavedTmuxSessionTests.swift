import Foundation
import GhosthubTmux
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

extension WorkspaceTmuxDiscoveryTests {
    @MainActor
    @Test("saved sessions are listed, restored, and forgotten after a kill")
    func savedTmuxSessionLifecycle() async throws {
        let environment = try setupStandardEnvironment()
        let commands = Mutex<[String]>([])
        let client = KwtSessionClient(
            localRunner: { command in
                commands.withLock { $0.append(command) }
                let marker = "GHOSTHUB_KWT_SESSION_JSON\n"
                if command.contains("'snapshot'") {
                    return (0, marker + """
                    {"entries": [
                      {"id": "a1", "socket": {"path": "/tmp/tmux-501/default", "name": "default"},
                       "session": "api", "windows": 1, "panes": 2, "agents": ["claude"],
                       "name_taken": false},
                      {"id": "c3", "socket": {"path": "/srv/sockets/build"},
                       "session": "ci", "windows": 1, "panes": 1, "agents": null,
                       "name_taken": false}
                    ]}
                    """)
                }
                if command.contains("'restore'") {
                    return (1, marker + """
                    {"entries": [{"id": "a1", "session": "api", "outcome": "failed",
                                  "reason": "tmux exited"}]}
                    """)
                }
                return (0, marker)
            },
            localBinaryPath: "/opt/kwt"
        )
        let discovered = DiscoveredTmuxSession(
            name: "desk",
            socketName: "kwt",
            windowCount: 1,
            serverPID: "202",
            sessionID: "$1",
            createdAt: "1000",
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { _ in .success([discovered]) },
            kwtSessionClient: client,
            tmuxSessionKiller: { _, _, _ in },
            tmuxSessionIdentityReviewer: { _, identity, _ in
                ReviewedTmuxSessionIdentity(identity: try #require(identity), routeIdentity: nil)
            }
        )
        model.startTmuxSessionDiscovery()
        model.startKwtInventory()
        await waitUntilMainActor {
            !model.snapshot.hosts[0].savedTmuxSessions.isEmpty
                && !model.snapshot.hosts[0].tmuxSessions.isEmpty
        }
        // Ghosthub cannot attach the custom socket, so it does not offer it.
        #expect(model.snapshot.hosts[0].savedTmuxSessions.map(\.session) == ["api"])

        // A failed session still comes back as a report, not an error.
        let report = try await model.restoreSavedTmuxSessions(
            ["a1", "c3"], hostID: environment.host.id
        )
        #expect(report.problems == ["api: failed (tmux exited)"])
        #expect(commands.withLock { $0 }.contains {
            $0.hasSuffix("session 'restore' '--json' 'a1'")
        })

        let request = try await model.prepareTmuxSessionKill(
            WorkspaceTmuxSessionSelection(
                hostID: environment.host.id, name: "desk", socketName: "kwt"
            )
        )
        try await model.killTmuxSession(request)
        await waitUntilMainActor {
            commands.withLock { $0 }.contains {
                $0.hasSuffix(
                    "session 'forget' '--socket-name' 'kwt' '--session-id' '$1'"
                        + " '--server-pid' '202' '--created' '1000'"
                )
            }
        }
        await model.shutdown()
    }

    @MainActor
    @Test("a saved session is restored once at a time and can be dismissed")
    func savedTmuxSessionRestoresOnceAndDismisses() async throws {
        let environment = try setupStandardEnvironment()
        let commands = Mutex<[String]>([])
        let restoreStarted = DispatchSemaphore(value: 0)
        let finishRestore = DispatchSemaphore(value: 0)
        let client = KwtSessionClient(
            localRunner: { command in
                commands.withLock { $0.append(command) }
                let marker = "GHOSTHUB_KWT_SESSION_JSON\n"
                if command.contains("'snapshot'") {
                    return (0, marker + """
                    {"entries": [
                      {"id": "a1", "socket": {"path": "/tmp/tmux-501/default", "name": "default"},
                       "session": "api"},
                      {"id": "b2", "socket": {"path": "/tmp/tmux-501/default", "name": "default"},
                       "session": "docs"}
                    ]}
                    """)
                }
                if command.contains("'restore'") {
                    restoreStarted.signal()
                    finishRestore.wait()
                    return (0, marker + """
                    {"entries": [{"id": "a1", "session": "api", "outcome": "restored"}]}
                    """)
                }
                return (0, marker)
            },
            localBinaryPath: "/opt/kwt"
        )
        // Two workspace windows share the app's restore tracking.
        let sharedRestores = SavedTmuxSessionRestores()
        func openWindow() throws -> WorkspaceSceneModel {
            try makeModel(
                database: environment.database,
                localHostID: environment.host.id,
                snapshot: environment.snapshot,
                kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
                kwtSessionClient: client,
                savedTmuxSessionRestores: sharedRestores
            )
        }
        let model = try openWindow()
        let otherWindow = try openWindow()
        model.startKwtInventory()
        otherWindow.startKwtInventory()
        await waitUntilMainActor {
            model.snapshot.hosts[0].savedTmuxSessions.count == 2
                && otherWindow.snapshot.hosts[0].savedTmuxSessions.count == 2
        }
        let hostID = environment.host.id
        func restores() -> [String] {
            commands.withLock { $0 }.filter { $0.contains("'restore'") }
        }

        // Restoring one session restores only that one, and the sidebar shows
        // it as restoring until kwt finishes.
        let first = Task { try await model.restoreSavedTmuxSessions(["a1"], hostID: hostID) }
        await BlockingTask.run { restoreStarted.wait() }
        #expect(model.snapshot.hosts[0].savedTmuxSessions.filter(\.isRestoring).map(\.id) == ["a1"])

        // A second click while kwt rebuilds it must not start another
        // restore, which would tear down the half-built session.
        let second = try await model.restoreSavedTmuxSessions(["a1"], hostID: hostID)
        #expect(second.entries.isEmpty)
        // The same holds for a click in another window.
        let fromOtherWindow = try await otherWindow.restoreSavedTmuxSessions(
            ["a1"], hostID: hostID
        )
        #expect(fromOtherWindow.entries.isEmpty)
        // An entry kwt no longer lists is not passed to it.
        let stale = try await model.restoreSavedTmuxSessions(["gone"], hostID: hostID)
        #expect(stale.entries.isEmpty)

        finishRestore.signal()
        let report = try await first.value
        #expect(report.entries.map(\.outcome) == ["restored"])
        #expect(restores().count == 1)
        #expect(restores().first?.hasSuffix("session 'restore' '--json' 'a1'") == true)
        let stillRestoring = model.snapshot.hosts[0].savedTmuxSessions.filter(\.isRestoring)
        #expect(stillRestoring.isEmpty)

        try await model.dismissSavedTmuxSession("b2", hostID: hostID)
        #expect(commands.withLock { $0 }.contains { $0.hasSuffix("session 'dismiss' 'b2'") })
        await model.shutdown()
        await otherWindow.shutdown()
    }

    /// kwt lists one saved session once `hasSaved` is true; until then it
    /// fails with status 127, as a host without the managed kwt does.
    private static func savedSessionClient(
        calls: LockedValue<Int>,
        hasSaved: @escaping @Sendable () -> Bool
    ) -> KwtSessionClient {
        KwtSessionClient(
            localRunner: { _ in
                calls.withLock { $0 += 1 }
                guard hasSaved() else { return (127, "") }
                return (0, "GHOSTHUB_KWT_SESSION_JSON\n" + """
                {"entries": [{"id": "a1", "session": "api",
                  "socket": {"path": "/tmp/tmux-501/default", "name": "default"}}]}
                """)
            },
            localBinaryPath: "/opt/kwt"
        )
    }

    @MainActor
    @Test("a host that reboots while Ghosthub is open offers restore without a manual refresh")
    func savedSessionsFollowScheduledRefresh() async throws {
        let environment = try setupStandardEnvironment()
        let calls = LockedValue(0)
        let rebooted = Mutex(false)
        let store = WorkspaceInventoryStore(
            refreshInterval: .milliseconds(20),
            kwtLoader: { _ in KwtHostInventory(projects: []) },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            workspaceInventoryStore: store,
            kwtSessionClient: Self.savedSessionClient(calls: calls) {
                rebooted.withLock { $0 }
            }
        )
        model.startKwtInventory()
        // Several scheduled refreshes list again before the host reboots.
        await waitUntilMainActor { calls.load() >= 6 }
        #expect(model.snapshot.hosts[0].savedTmuxSessions.isEmpty)

        rebooted.withLock { $0 = true }
        await waitUntilMainActor { !model.snapshot.hosts[0].savedTmuxSessions.isEmpty }
        await model.shutdown()
    }

    @MainActor
    @Test("saved sessions are listed again once the host's kwt first answers")
    func savedSessionsRetryAfterKwtBecomesAvailable() async throws {
        let environment = try setupStandardEnvironment()
        let calls = LockedValue(0)
        let installed = Mutex(false)
        let install = AsyncGate()
        defer { install.open() }
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3600),
            kwtLoader: { _ in
                await install.wait()
                installed.withLock { $0 = true }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            workspaceInventoryStore: store,
            kwtSessionClient: Self.savedSessionClient(calls: calls) {
                installed.withLock { $0 }
            }
        )
        model.startKwtInventory()
        await waitUntilMainActor { calls.load() >= 1 }
        // Let every listing started before kwt answered fail first.
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.snapshot.hosts[0].savedTmuxSessions.isEmpty)

        install.open()
        await waitUntilMainActor(timeout: .seconds(5)) {
            !model.snapshot.hosts[0].savedTmuxSessions.isEmpty
        }
        await model.shutdown()
    }
}
