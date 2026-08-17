import Foundation
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

    @Test("command palette tmux routes match session ownership")
    @MainActor
    func commandPaletteTmuxRoutesMatchSessionOwnership() throws {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        var worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id
        )
        worktree.tmuxSessionName = "worktree-session"
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: host.id,
            name: "notes",
            path: "/tmp/notes",
            tmuxSessionName: "directory-session",
            sessionLive: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [project],
            worktrees: [worktree],
            directoryWorkspaces: [directory]
        )
        let current = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: worktree.id
        )
        let worktreeSession = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let directorySession = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )
        let standaloneSession = WorkspaceTmuxSessionSelection(
            hostID: host.id,
            name: "standalone"
        )

        let worktreeRoute = WorkspacePresentationLifecycle.selectionForTmuxCommand(
            worktreeSession,
            from: current,
            in: snapshot,
            visibility: .default
        )
        #expect(worktreeRoute.selectedProjectID == project.id)
        #expect(worktreeRoute.selectedWorktreeID == worktree.id)

        let directoryRoute = WorkspacePresentationLifecycle.selectionForTmuxCommand(
            directorySession,
            from: current,
            in: snapshot,
            visibility: .default
        )
        #expect(directoryRoute.selectedProjectID == nil)
        #expect(directoryRoute.selectedWorktreeID == nil)
        #expect(directoryRoute.selectedDirectoryWorkspaceID == directory.id)

        let standaloneRoute = WorkspacePresentationLifecycle.selectionForTmuxCommand(
            standaloneSession,
            from: current,
            in: snapshot,
            visibility: .default
        )
        #expect(standaloneRoute.selectedHostID == host.id)
        #expect(standaloneRoute.selectedProjectID == nil)
        #expect(standaloneRoute.selectedWorktreeID == nil)
        #expect(standaloneRoute.selectedDirectoryWorkspaceID == nil)
    }
}
