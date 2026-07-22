import Testing
@testable import GhosthubWorkspace

struct WorktreeVisibilityTests {
    let host = HostSummary.localFixture()
    let project: ProjectSummary

    init() {
        project = .fixture(
            for: host, name: "ghosthub",
            rootPath: "/tmp/ghosthub"
        )
    }

    private let hiddenOff = WorktreeVisibility(
        showHiddenWorktrees: false
    )

    @Test("normalization clears hidden worktrees when hidden rows are excluded")
    func normalizationClearsHiddenWorktreeSelection() {
        let hiddenWorktree = WorktreeSummary.fixture(
            for: project,
            name: "feature/hidden",
            branch: "feature/hidden",
            isHidden: true
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [hiddenWorktree]
        )
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: hiddenWorktree.id
        )

        let normalized = selection.normalized(
            in: snapshot, visibility: hiddenOff
        )

        #expect(normalized.selectedHostID == host.id)
        #expect(normalized.selectedProjectID == project.id)
        #expect(normalized.selectedWorktreeID == nil)
    }

    @Test("programmatic worktree selection respects hidden-worktree visibility")
    func selectingHiddenWorktreeRespectsVisibility() {
        let hiddenWorktree = WorktreeSummary.fixture(
            for: project,
            name: "feature/hidden",
            branch: "feature/hidden",
            isHidden: true
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [hiddenWorktree]
        )
        var selection = WorkspaceSelection(selectedHostID: host.id)

        selection.select(
            .worktree(hiddenWorktree.id),
            in: snapshot,
            visibility: hiddenOff
        )

        #expect(selection.selectedHostID == host.id)
        #expect(selection.selectedProjectID == project.id)
        #expect(selection.selectedWorktreeID == nil)
    }

    @Test("selection falls forward to next visible worktree when current becomes hidden")
    func fallbackPrefersNextVisibleSibling() {
        let first = WorktreeSummary.fixture(
            for: project,
            name: "feature/one",
            branch: "feature/one"
        )
        let hiddenCurrent = WorktreeSummary.fixture(
            for: project,
            name: "feature/two",
            branch: "feature/two",
            isHidden: true
        )
        let last = WorktreeSummary.fixture(
            for: project,
            name: "feature/three",
            branch: "feature/three"
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [first, hiddenCurrent, last]
        )
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: hiddenCurrent.id
        )

        let normalized =
            selection.normalizedBySelectingVisibleFallback(
                in: snapshot, visibility: hiddenOff
            )

        #expect(normalized.selectedProjectID == project.id)
        #expect(normalized.selectedWorktreeID == last.id)
    }

    @Test("selection falls back to project row when hidden worktree has no visible siblings")
    func fallbackPrefersProjectWhenNoVisibleSiblingsRemain() {
        let hiddenWorktree = WorktreeSummary.fixture(
            for: project,
            name: "feature/hidden",
            branch: "feature/hidden",
            isHidden: true
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [hiddenWorktree]
        )
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: hiddenWorktree.id
        )

        let normalized =
            selection.normalizedBySelectingVisibleFallback(
                in: snapshot, visibility: hiddenOff
            )

        #expect(normalized.selectedProjectID == project.id)
        #expect(normalized.selectedWorktreeID == nil)
    }
}
