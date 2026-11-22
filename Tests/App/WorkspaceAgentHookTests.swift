import Foundation
import GhosthubSettings
import GhosthubUI
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

extension WorkspaceTmuxDiscoveryTests {
    enum EditedAddressAction: CaseIterable, Sendable {
        case hookStatus
        case addProject
    }

    @MainActor
    @Test(
        "a Settings action on an edited address leaves the saved host's kwt alone",
        arguments: EditedAddressAction.allCases
    )
    func settingsActionOnEditedAddressKeepsSavedHostKwt(
        action: EditedAddressAction
    ) async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSocketName = "kwt-main"
        snapshot.worktrees[0].tmuxAttachMode = .direct
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        // Ghosthub reviews a named session's identity before attaching only
        // when it believes the host has no managed kwt.
        let reviews = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            kwtRemoteProvisioner: { host in
                throw KwtInventoryError.commandFailed(
                    host: host.sshDestination, status: 255
                )
            },
            tmuxSessionIdentityReviewer: { _, _, _ in
                reviews.withLock { $0 += 1 }
                throw TmuxSessionKillError.identityUnavailable(
                    host: environment.host.name, session: "kwt-ghosthub-main"
                )
            }
        )

        // Settings shows the saved host with an unreachable address typed
        // but not saved.
        let edited = SSHHost(
            configKey: environment.host.configKey, name: environment.host.name,
            platform: .linux, sshDestination: "typo.example.test"
        )
        let failed = switch action {
        case .hookStatus:
            if case .failure = await model.agentHooks(.status, on: edited) {
                true
            } else {
                false
            }
        case .addProject:
            if case .failure = await model.registerRemoteProject(
                "/srv/repo", on: edited
            ) {
                true
            } else {
                false
            }
        }
        guard failed else {
            Issue.record("The unreachable address should fail the action")
            await model.shutdown()
            return
        }

        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: snapshot.worktrees[0])
        )
        model.openBorrowedTmuxSession(selection)
        // Believing kwt is missing, Ghosthub would ask for the review at once.
        try await Task.sleep(for: .milliseconds(500))

        #expect(reviews.withLock { $0 } == 0)
        await model.shutdown()
    }
}
