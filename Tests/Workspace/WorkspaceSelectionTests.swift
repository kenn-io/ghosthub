import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubWorkspace

struct WorkspaceSelectionTests {
    @Test("directory workspace navigation is first class")
    func selectsDirectoryWorkspace() {
        let hostID = UUID()
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: hostID,
            name: "jibot",
            path: "/workspaces/jibot",
            tmuxSessionName: "kwt-workspace-dir-jibot-abc",
            sessionLive: false
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: [],
            worktrees: [],
            directoryWorkspaces: [directory]
        )
        var selection = WorkspaceSelection(selectedHostID: hostID)

        selection.select(.directoryWorkspace(directory.id), in: snapshot)

        #expect(selection.selectedHostID == hostID)
        #expect(selection.selectedProjectID == nil)
        #expect(selection.selectedWorktreeID == nil)
        #expect(selection.selectedDirectoryWorkspaceID == directory.id)
        #expect(selection.navigationTarget == .directoryWorkspace(directory.id))
    }

    @Test("navigation target prefers worktree then project then host")
    func navigationTargetPrefersWorktreeThenProjectThenHost() {
        let hostID = UUID()
        let projectID = UUID()
        let worktreeID = UUID()

        #expect(
            WorkspaceSelection(
                selectedHostID: hostID,
                selectedProjectID: projectID,
                selectedWorktreeID: worktreeID
            ).navigationTarget == .worktree(worktreeID)
        )
        #expect(
            WorkspaceSelection(
                selectedHostID: hostID,
                selectedProjectID: projectID
            ).navigationTarget == .project(projectID)
        )
        #expect(
            WorkspaceSelection(selectedHostID: hostID).navigationTarget
                == .host(hostID)
        )
    }

    @Test("bound console host follows the selected host by default")
    func boundConsoleHostFollowsSelectedHostByDefault() {
        let selectedHostID = UUID()
        let pinnedHostID = UUID()

        let selection = WorkspaceSelection(
            selectedHostID: selectedHostID,
            consoleBindingMode: .followSelectedHost,
            pinnedConsoleHostID: pinnedHostID
        )

        #expect(selection.boundConsoleHostID == selectedHostID)
    }

    @Test("bound console host uses the pinned host when console is pinned")
    func boundConsoleHostUsesPinnedHostWhenConsoleIsPinned() {
        let selectedHostID = UUID()
        let pinnedHostID = UUID()

        let selection = WorkspaceSelection(
            selectedHostID: selectedHostID,
            consoleBindingMode: .pinHost,
            pinnedConsoleHostID: pinnedHostID
        )

        #expect(selection.boundConsoleHostID == pinnedHostID)
    }

    @Test("init normalizes pin mode without a pinned host back to follow mode")
    func initNormalizesToFollowModeWhenPinModeHasNoPinnedHost() {
        let selectedHostID = UUID()
        let selection = WorkspaceSelection(
            selectedHostID: selectedHostID,
            consoleBindingMode: .pinHost
        )

        #expect(selection.consoleBindingMode == .followSelectedHost)
        #expect(selection.boundConsoleHostID == selectedHostID)
    }

    @Test("selecting a project also selects its owning host and clears worktree selection")
    func selectingProjectAlsoSelectsItsOwningHostAndClearsWorktree() {
        let setup = makeStandardWorkspaceSetup()
        var selection = setup.makeSelection(
            host: setup.localHost,
            project: setup.remoteProject,
            worktree: setup.remoteWorktree
        )

        selection.select(.project(setup.remoteProject.id), in: setup.snapshot)

        #expect(selection.selectedHostID == setup.remoteHost.id)
        #expect(selection.selectedProjectID == setup.remoteProject.id)
        #expect(selection.selectedWorktreeID == nil)
    }

    @Test("selecting a host clears project and worktree selection")
    func selectingHostClearsProjectAndWorktreeSelection() {
        let setup = makeStandardWorkspaceSetup()
        var selection = setup.makeSelection(
            host: setup.remoteHost,
            project: setup.remoteProject,
            worktree: setup.remoteWorktree
        )

        selection.select(.host(setup.localHost.id), in: setup.snapshot)

        #expect(selection.selectedHostID == setup.localHost.id)
        #expect(selection.selectedProjectID == nil)
        #expect(selection.selectedWorktreeID == nil)
    }

    @Test("selecting a worktree also selects its owning project and host")
    func selectingWorktreeAlsoSelectsItsOwningProjectAndHost() {
        let setup = makeStandardWorkspaceSetup()
        var selection = setup.makeSelection()

        selection.select(.worktree(setup.remoteWorktree.id), in: setup.snapshot)

        #expect(selection.selectedHostID == setup.remoteHost.id)
        #expect(selection.selectedProjectID == setup.remoteProject.id)
        #expect(selection.selectedWorktreeID == setup.remoteWorktree.id)
    }

    @Test("normalization repairs host and project from the selected worktree")
    func normalizationRepairsHostAndProjectFromSelectedWorktree() {
        let setup = makeStandardWorkspaceSetup()
        let selection = WorkspaceSelection(
            selectedHostID: setup.localHost.id,
            selectedProjectID: nil,
            selectedWorktreeID: setup.remoteWorktree.id
        )

        let normalized = selection.normalized(in: setup.snapshot)

        #expect(normalized.selectedHostID == setup.remoteHost.id)
        #expect(normalized.selectedProjectID == setup.remoteProject.id)
        #expect(normalized.selectedWorktreeID == setup.remoteWorktree.id)
    }

    @Test("fallback selects remaining worktree after selected worktree disappears")
    func fallbackSelectsRemainingWorktreeAfterSelectedWorktreeDisappears() {
        let host = HostSummary.localFixture()
        let project = ProjectSummary.fixture(
            for: host,
            name: "api"
        )
        let removed = WorktreeSummary.fixture(
            for: project,
            name: "feature/auth",
            branch: "feature/auth"
        )
        let remaining = WorktreeSummary.fixture(
            for: project,
            name: "main",
            branch: "main"
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [remaining]
        )
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: removed.id
        )

        let normalized = selection.normalizedBySelectingVisibleFallback(
            in: snapshot,
            visibility: .default
        )

        #expect(normalized.selectedHostID == host.id)
        #expect(normalized.selectedProjectID == project.id)
        #expect(normalized.selectedWorktreeID == remaining.id)
    }

    @Test("normalization returns to follow mode when the pinned host is nil")
    func normalizationReturnsToFollowModeWhenPinnedHostIsNil() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let snapshot = WorkspaceSnapshot(hosts: [host], projects: [], worktrees: [])
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            consoleBindingMode: .pinHost
        )

        let normalized = selection.normalized(in: snapshot)

        #expect(normalized.consoleBindingMode == .followSelectedHost)
        #expect(normalized.pinnedConsoleHostID == nil)
        #expect(normalized.boundConsoleHostID == host.id)
    }

    @Test("normalization returns to follow mode when the pinned host is missing")
    func normalizationReturnsToFollowModeWhenPinnedHostIsMissing() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let missingPinnedHostID = UUID()
        let snapshot = WorkspaceSnapshot(hosts: [host], projects: [], worktrees: [])
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            consoleBindingMode: .pinHost,
            pinnedConsoleHostID: missingPinnedHostID
        )

        let normalized = selection.normalized(in: snapshot)

        #expect(normalized.consoleBindingMode == .followSelectedHost)
        #expect(normalized.pinnedConsoleHostID == nil)
        #expect(normalized.boundConsoleHostID == host.id)
    }

    @Test("bound console host falls back when pin mode has no pinned host")
    func boundConsoleHostFallsBackWhenPinModeHasNoPinnedHost() {
        let hostID = UUID()
        var selection = WorkspaceSelection(selectedHostID: hostID)

        selection.consoleBindingMode = .pinHost
        selection.pinnedConsoleHostID = nil

        #expect(selection.boundConsoleHostID == hostID)
    }

    @Test("setConsoleBinding requires a pinned host in pin mode")
    func setConsoleBindingPinModeRequiresPinnedHostID() {
        let hostID = UUID()
        let pinnedID = UUID()
        var selection = WorkspaceSelection(selectedHostID: hostID)

        selection.setConsoleBinding(mode: .pinHost, pinnedHostID: pinnedID)
        #expect(selection.consoleBindingMode == .pinHost)
        #expect(selection.pinnedConsoleHostID == pinnedID)
        #expect(selection.boundConsoleHostID == pinnedID)

        selection.setConsoleBinding(mode: .pinHost)
        #expect(selection.consoleBindingMode == .followSelectedHost)
        #expect(selection.pinnedConsoleHostID == nil)
        #expect(selection.boundConsoleHostID == hostID)

        selection.setConsoleBinding(
            mode: .followSelectedHost,
            pinnedHostID: pinnedID
        )
        #expect(selection.consoleBindingMode == .followSelectedHost)
        #expect(selection.pinnedConsoleHostID == nil)
    }

    @Test("preview bootstrap seeds the selected worktree hierarchy")
    func previewBootstrapSeedsSelectedWorktreeHierarchy() {
        let bootstrap = WorkspaceBootstrap.preview()

        #expect(bootstrap.snapshot.hosts.count == 2)
        #expect(bootstrap.snapshot.hosts.first?.name == "This Mac")
        #expect(
            bootstrap.selection.selectedHostID == bootstrap.snapshot.hosts.first?.id
        )
        #expect(bootstrap.selection.selectedProjectID != nil)
        #expect(bootstrap.selection.selectedWorktreeID != nil)
    }

    @Test("terminal config root prefers the selected worktree path")
    func terminalConfigRootPrefersSelectedWorktreePath() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let project = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/Users/wesm/code/ghosthub"
        )
        let worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id,
            name: "feature",
            path: "/Users/wesm/code/ghosthub-feature",
            branch: "feature"
        )
        let (snapshot, selection) = makeSnapshotAndSelection(
            host: host, project: project, worktree: worktree
        )

        #expect(
            selection.terminalConfigRoot(in: snapshot)?.path
                == "/Users/wesm/code/ghosthub-feature"
        )
    }

    @Test("terminal config root skips an imported pull request checkout")
    func terminalConfigRootSkipsProtectedWorktree() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let project = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/Users/wesm/code/ghosthub",
            repositoryKind: .standard
        )
        var worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id,
            name: "pr-32",
            path: "/Users/wesm/code/ghosthub-pr-32",
            branch: "contributor/pr-32"
        )
        worktree.tmuxSocketName = "kwt-pr-0123456789abcdef"
        let (snapshot, selection) = makeSnapshotAndSelection(
            host: host, project: project, worktree: worktree
        )

        #expect(
            selection.terminalConfigRoot(in: snapshot)?.path
                == "/Users/wesm/code/ghosthub"
        )
    }

    @Test("terminal config root falls back to the standard project root")
    func terminalConfigRootFallsBackToStandardProjectRoot() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let project = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/Users/wesm/code/ghosthub",
            repositoryKind: .standard
        )
        let (snapshot, selection) = makeSnapshotAndSelection(
            host: host, project: project
        )

        #expect(
            selection.terminalConfigRoot(in: snapshot)?.path
                == "/Users/wesm/code/ghosthub"
        )
    }

    @Test("terminal config root is nil for a remote worktree selection")
    func terminalConfigRootIsNilForRemoteWorktreeSelection() {
        let host = HostSummary.fixture(
            name: "Office Studio", kind: .remote, platform: .linux
        )
        let project = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/srv/ghosthub"
        )
        let worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id,
            name: "feature",
            path: "/srv/worktrees/feature",
            branch: "feature"
        )
        let (snapshot, selection) = makeSnapshotAndSelection(
            host: host, project: project, worktree: worktree
        )

        #expect(selection.terminalConfigRoot(in: snapshot) == nil)
    }

    @Test("terminal config root is nil for a remote project selection")
    func terminalConfigRootIsNilForRemoteProjectSelection() {
        let host = HostSummary.fixture(
            name: "Office Studio", kind: .remote, platform: .linux
        )
        let project = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/srv/ghosthub",
            repositoryKind: .standard
        )
        let (snapshot, selection) = makeSnapshotAndSelection(
            host: host, project: project
        )

        #expect(selection.terminalConfigRoot(in: snapshot) == nil)
    }

    @Test("terminal config root is nil for a synthesized project")
    func terminalConfigRootIsNilForSynthesizedProject() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        // A synthesized project decodes repositoryKind as .standard with an
        // empty rootPath, so without the isSynthesized guard it would yield a
        // bogus terminal cwd of "".
        let project = ProjectSummary.fixture(
            hostID: host.id,
            name: "orphan",
            rootPath: "",
            repositoryKind: .standard,
            isSynthesized: true
        )
        let (snapshot, selection) = makeSnapshotAndSelection(
            host: host, project: project
        )

        #expect(selection.terminalConfigRoot(in: snapshot) == nil)
    }

    @Test("terminal config root is nil for a bare project without a selected worktree")
    func terminalConfigRootIsNilForBareProjectWithoutSelectedWorktree() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let project = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub.git",
            rootPath: "/Users/wesm/code/ghosthub.git",
            repositoryKind: .bare
        )
        let (snapshot, selection) = makeSnapshotAndSelection(
            host: host, project: project
        )

        #expect(selection.terminalConfigRoot(in: snapshot) == nil)
    }

    @Test("selecting a stale project or worktree does not change selection")
    func selectingStaleProjectOrWorktreeDoesNotChangeSelection() {
        let host = HostSummary.fixture(
            name: "Build Box", kind: .remote, platform: .linux
        )
        let activeProject = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/srv/ghosthub"
        )
        let staleProject = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub-old",
            rootPath: "/srv/ghosthub-old",
            isStale: true
        )
        let activeWorktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: activeProject.id,
            name: "main",
            path: "/srv/ghosthub",
            branch: "main"
        )
        let staleWorktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: staleProject.id,
            name: "legacy",
            path: "/srv/ghosthub-old",
            branch: "legacy",
            isStale: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [activeProject, staleProject],
            worktrees: [activeWorktree, staleWorktree]
        )
        var selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: activeProject.id,
            selectedWorktreeID: activeWorktree.id
        )

        selection.select(.project(staleProject.id), in: snapshot)
        #expect(selection.selectedProjectID == activeProject.id)
        #expect(selection.selectedWorktreeID == activeWorktree.id)

        selection.select(.worktree(staleWorktree.id), in: snapshot)
        #expect(selection.selectedProjectID == activeProject.id)
        #expect(selection.selectedWorktreeID == activeWorktree.id)
    }
}
