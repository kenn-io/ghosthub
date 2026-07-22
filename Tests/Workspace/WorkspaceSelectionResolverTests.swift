import Foundation
import Testing
@testable import GhosthubWorkspace

struct WorkspaceSelectionResolverTests {
    @Test("initial selection prefers a local active repository without selecting a worktree")
    func initialSelectionPrefersLocalRepository() {
        let host = HostSummary.localFixture()
        let project = ProjectSummary.fixture(for: host)
        let worktree = WorktreeSummary.fixture(
            for: project,
            isPrimary: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [project],
            worktrees: [worktree]
        )

        let selection = WorkspaceSelectionResolver.initialSelection(
            in: snapshot,
            localHostID: host.id
        )

        #expect(selection.selectedHostID == host.id)
        #expect(selection.selectedProjectID == project.id)
        #expect(selection.selectedWorktreeID == nil)
    }

    @Test("initial selection falls back to the first active repository")
    func initialSelectionFallsBackToFirstActiveRepository() {
        let localHost = HostSummary.fixture(kind: .selfHost)
        let remoteHost = HostSummary.fixture(kind: .remote)
        let staleLocalProject = ProjectSummary.fixture(
            for: localHost,
            isStale: true
        )
        let remoteProject = ProjectSummary.fixture(
            for: remoteHost,
            name: "remote",
            rootPath: "/code/remote"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [localHost, remoteHost],
            projects: [staleLocalProject, remoteProject],
            worktrees: []
        )

        let selection = WorkspaceSelectionResolver.initialSelection(
            in: snapshot,
            localHostID: localHost.id
        )

        #expect(selection.selectedHostID == remoteHost.id)
        #expect(selection.selectedProjectID == remoteProject.id)
        #expect(selection.selectedWorktreeID == nil)
    }

    @Test("initial selection uses local host when no repositories are active")
    func initialSelectionUsesLocalHostWhenNoRepositoriesAreActive() {
        let localHostID = UUID()
        let snapshot = WorkspaceSnapshot(
            hosts: [],
            projects: [],
            worktrees: []
        )

        let selection = WorkspaceSelectionResolver.initialSelection(
            in: snapshot,
            localHostID: localHostID
        )

        #expect(selection == WorkspaceSelection(
            selectedHostID: localHostID
        ))
    }

    @Test("selected project resolves directly selected projects")
    func selectedProjectResolvesDirectProjectSelection() {
        let setup = makeSetup()
        let selection = WorkspaceSelection(
            selectedHostID: setup.host.id,
            selectedProjectID: setup.project.id
        )

        #expect(
            WorkspaceSelectionResolver.selectedProject(
                in: setup.snapshot,
                selection: selection
            )?.id == setup.project.id
        )
    }

    @Test("selected project resolves selected worktree owners")
    func selectedProjectResolvesWorktreeOwner() {
        let setup = makeSetup()
        let selection = WorkspaceSelection(
            selectedHostID: setup.host.id,
            selectedWorktreeID: setup.worktree.id
        )

        #expect(
            WorkspaceSelectionResolver.selectedProject(
                in: setup.snapshot,
                selection: selection
            )?.id == setup.project.id
        )
    }

    @Test("explicit project resolves selected worktree owners")
    func explicitProjectResolvesWorktreeOwner() {
        let setup = makeSetup()
        let selection = WorkspaceSelection(
            selectedHostID: setup.host.id,
            selectedWorktreeID: setup.worktree.id
        )

        #expect(
            WorkspaceSelectionResolver.explicitlySelectedProject(
                in: setup.snapshot,
                selection: selection
            )?.id == setup.project.id
        )
    }

    @Test("selected project falls back to the selected host")
    func selectedProjectFallsBackToSelectedHost() {
        let setup = makeSetup()
        let selection = WorkspaceSelection(selectedHostID: setup.host.id)

        #expect(
            WorkspaceSelectionResolver.selectedProject(
                in: setup.snapshot,
                selection: selection
            )?.id == setup.project.id
        )
    }

    @Test("explicit project does not use host fallback")
    func explicitProjectDoesNotUseHostFallback() {
        let setup = makeSetup()
        let selection = WorkspaceSelection(selectedHostID: setup.host.id)

        #expect(
            WorkspaceSelectionResolver.explicitlySelectedProject(
                in: setup.snapshot,
                selection: selection
            ) == nil
        )
    }

    @Test("selection resolver ignores stale project and worktree selections")
    func selectionResolverIgnoresStaleSelections() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let activeProject = ProjectSummary.fixture(
            for: host,
            name: "active",
            rootPath: "/code/active"
        )
        let staleProject = ProjectSummary.fixture(
            for: host,
            name: "stale",
            rootPath: "/code/stale",
            isStale: true
        )
        let staleWorktree = WorktreeSummary.fixture(
            for: staleProject,
            name: "stale-branch",
            isStale: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [activeProject, staleProject],
            worktrees: [staleWorktree]
        )
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: staleProject.id,
            selectedWorktreeID: staleWorktree.id
        )

        #expect(
            WorkspaceSelectionResolver.selectedProject(
                in: snapshot,
                selection: selection
            )?.id == activeProject.id
        )
        #expect(
            WorkspaceSelectionResolver.explicitlySelectedProject(
                in: snapshot,
                selection: selection
            ) == nil
        )
    }

    private func makeSetup() -> (
        host: HostSummary,
        project: ProjectSummary,
        worktree: WorktreeSummary,
        snapshot: WorkspaceSnapshot
    ) {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let project = ProjectSummary.fixture(
            for: host,
            name: "ghosthub",
            rootPath: "/code/ghosthub"
        )
        let worktree = WorktreeSummary.fixture(
            for: project,
            name: "main",
            path: "/code/ghosthub"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [project],
            worktrees: [worktree]
        )
        return (host, project, worktree, snapshot)
    }
}
