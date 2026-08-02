import Testing
@testable import GhosthubUI

struct WorkspaceAlertTests {
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
