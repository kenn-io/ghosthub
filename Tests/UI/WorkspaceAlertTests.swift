import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

struct WorkspaceAlertTests {
    @Test("dirty worktree removal names discarded changes and force action")
    func dirtyWorktreeRemovalPresentation() {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let request = WorktreeRemovalRequest(
            worktree: .fixture(hostID: host.id, projectID: project.id),
            project: project,
            confirmedHost: host,
            changes: WorktreeChangeSummary(modified: 1, untracked: 2)
        )

        #expect(request.worktreeRemovalActionTitle == "Force Remove Worktree")
        #expect(request.worktreeRemovalMessage.contains("uncommitted changes"))
        #expect(request.worktreeRemovalMessage.contains("permanently discards"))
    }

    @Test("incomplete change inspection requires a precise force warning")
    func incompleteChangeInspectionPresentation() {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let request = WorktreeRemovalRequest(
            worktree: .fixture(hostID: host.id, projectID: project.id),
            project: project,
            confirmedHost: host,
            changeInspectionComplete: false
        )

        #expect(request.worktreeRemovalActionTitle == "Force Remove Worktree")
        #expect(request.worktreeRemovalMessage.contains("could not enumerate"))
        #expect(request.worktreeRemovalMessage.contains("may permanently discard"))
    }

    @Test("workspace actions share one alert identity domain")
    func workspaceActionsShareAlertIdentityDomain() {
        let session = WorkspaceAlert.sessionKillFailure(
            session: "release",
            message: "unavailable"
        )
        let theme = WorkspaceAlert.sessionThemeFailure(
            session: "review",
            message: "SSH failed"
        )
        let worktree = WorkspaceAlert.worktreeRemovalFailure(
            worktree: "docs",
            message: "unavailable"
        )

        #expect(session.id.hasPrefix("session:"))
        #expect(theme.id.hasPrefix("session-theme:"))
        #expect(worktree.id.hasPrefix("worktree:"))
        #expect(Set([session.id, theme.id, worktree.id]).count == 3)
    }
}
