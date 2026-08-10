import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("Application shortcut routing")
struct ApplicationShortcutRoutingTests {
    @Test("project shortcuts fall back to the selected host's project")
    func projectShortcutFallsBackToHostProject() {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [project],
            worktrees: []
        )
        let selection = WorkspaceSelection(selectedHostID: host.id)

        #expect(
            RootView.applicationShortcutProject(
                in: snapshot,
                selection: selection
            )?.id == project.id
        )
    }
}
