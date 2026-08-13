import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("Session titlebar presentation")
struct SessionTitlebarPresentationTests {
    @Test("unbound local tmux session shows terminal icon and hostname")
    func unboundLocalSession() {
        let hostID = UUID()
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(
                    id: hostID,
                    name: "studio-mac",
                    kind: .selfHost
                ),
            ]
        )

        let presentation = SessionTitlebarPresentation.resolve(
            activeSession: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "docbank"
            ),
            in: snapshot
        )

        #expect(presentation?.title == "docbank · studio-mac")
        #expect(presentation?.icon == .tmuxSession)
        #expect(presentation?.icon.systemImageName == "terminal")
    }

    @Test("workspace session shows project and worktree names")
    func linkedWorktreeSession() {
        let hostID = UUID()
        let projectID = UUID()
        let worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "feature/api"
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(
                    id: hostID,
                    name: "Build Box",
                    kind: .remote,
                    sshDestination: "builder@build.example:2222"
                ),
            ],
            projects: [
                .fixture(
                    id: projectID,
                    hostID: hostID,
                    name: "ghosthub"
                ),
            ],
            worktrees: [worktree]
        )

        let presentation = SessionTitlebarPresentation.resolve(
            activeSession: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "kwt-wt-ghosthub-feature-api-deadbeef",
                worktreeID: worktree.id
            ),
            in: snapshot
        )

        #expect(presentation?.title == "ghosthub / feature/api · build.example")
        #expect(presentation?.icon == .worktree)
    }

    @Test("primary worktree and remote-reported hostname take precedence")
    func primaryRemoteWorkspaceSession() {
        let hostID = UUID()
        let projectID = UUID()
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "main"
        )
        worktree.isPrimary = true
        var host = HostSummary.fixture(
            id: hostID,
            name: "Build Box",
            kind: .remote,
            sshDestination: "ssh-alias"
        )
        host.remoteHostname = "builder.internal"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [
                .fixture(
                    id: projectID,
                    hostID: hostID,
                    name: "ghosthub"
                ),
            ],
            worktrees: [worktree]
        )

        let presentation = SessionTitlebarPresentation.resolve(
            activeSession: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "kwt-main",
                worktreeID: worktree.id
            ),
            in: snapshot
        )

        #expect(presentation?.title == "ghosthub / main · builder.internal")
        #expect(presentation?.icon == .primaryWorktree)
    }

    @Test("workspace title falls back without parsing its session name")
    func workspaceTitleFallbacks() {
        let hostID = UUID()
        let worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: UUID(),
            name: "feature/api"
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID, name: "studio-mac")],
            worktrees: [worktree]
        )

        let projectless = SessionTitlebarPresentation.resolve(
            activeSession: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "kwt-wt-ghosthub-feature-api-deadbeef",
                worktreeID: worktree.id
            ),
            in: snapshot
        )
        #expect(projectless?.title == "feature/api · studio-mac")

        let missingWorktree = SessionTitlebarPresentation.resolve(
            activeSession: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "kwt-wt-ghosthub-feature-api-deadbeef",
                worktreeID: UUID()
            ),
            in: snapshot
        )
        #expect(
            missingWorktree?.title
                == "kwt-wt-ghosthub-feature-api-deadbeef · studio-mac"
        )
    }

    @Test("missing active session or host has no title")
    func missingSessionOrHost() {
        #expect(
            SessionTitlebarPresentation.resolve(
                activeSession: nil,
                in: .fixture()
            ) == nil
        )
        #expect(
            SessionTitlebarPresentation.resolve(
                activeSession: WorkspaceTmuxSessionSelection(
                    hostID: UUID(),
                    name: "orphan"
                ),
                in: .fixture()
            ) == nil
        )
    }

    @Test("Herdr sessions use their own icon and host title")
    func herdrSession() {
        let hostID = UUID()
        let snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(id: hostID, name: "studio-mac", kind: .selfHost),
        ])

        let presentation = SessionTitlebarPresentation.resolve(
            activeHerdrSession: WorkspaceHerdrSessionSelection(
                hostID: hostID,
                name: "api"
            ),
            in: snapshot
        )

        #expect(presentation?.title == "api · studio-mac")
        #expect(presentation?.icon == .herdrSession)
    }

    @Test("mutually exclusive titlebar refuses contradictory sessions")
    func contradictorySessions() {
        let hostID = UUID()
        let snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(id: hostID),
        ])

        #expect(SessionTitlebarPresentation.resolve(
            activeTmuxSession: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "tmux"
            ),
            activeHerdrSession: WorkspaceHerdrSessionSelection(
                hostID: hostID,
                name: "herdr"
            ),
            in: snapshot
        ) == nil)
    }
}
