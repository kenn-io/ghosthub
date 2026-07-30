import Testing
@testable import GhosthubUI

struct WorkspaceDestructiveAlertTests {
    @Test("session and worktree actions share one alert identity domain")
    func destructiveActionsShareAlertIdentityDomain() {
        let session = WorkspaceDestructiveAlert.sessionKillFailure(
            session: "release",
            message: "unavailable"
        )
        let worktree = WorkspaceDestructiveAlert.worktreeRemovalFailure(
            worktree: "docs",
            message: "unavailable"
        )

        #expect(session.id.hasPrefix("session:"))
        #expect(worktree.id.hasPrefix("worktree:"))
        #expect(session.id != worktree.id)
    }
}
