import Foundation
import GhosthubTestSupport
import Testing
import GhosthubWorkspace
@testable import GhosthubUI

struct KeyboardNavigationModelTests {
    @Test("keyboard navigation uses sidebar order and wraps")
    func keyboardNavigationUsesSidebarOrderAndWraps() {
        let bootstrap = WorkspaceBootstrap.preview()

        let orderedWorktrees = KeyboardNavigationModel.orderedWorktrees(
            in: bootstrap.snapshot
        )
        #expect(
            orderedWorktrees.map(\.name) == [
                "primary checkout",
                "sidebar-nav",
                "review-fixes",
                "release",
                "worker-rollout",
            ]
        )

        let nextSelection = KeyboardNavigationModel.steppedSelection(
            from: bootstrap.selection,
            in: bootstrap.snapshot,
            step: 1
        )
        #expect(nextSelection?.selectedWorktreeID == orderedWorktrees[1].id)

        let previousSelection = KeyboardNavigationModel.steppedSelection(
            from: bootstrap.selection,
            in: bootstrap.snapshot,
            step: -1
        )
        #expect(
            previousSelection?.selectedWorktreeID == orderedWorktrees[4].id
        )

        let indexedSelection = KeyboardNavigationModel
            .selectionForShortcutIndex(
                3,
                from: bootstrap.selection,
                in: bootstrap.snapshot
            )
        #expect(
            indexedSelection?.selectedWorktreeID == orderedWorktrees[2].id
        )
    }

    @Test("keyboard navigation follows sidebar row order")
    func keyboardNavigationFollowsSidebarRowOrder() {
        let bootstrap = WorkspaceBootstrap.preview()
        let visibility = WorktreeVisibility(showHiddenWorktrees: false)

        let sidebarWorktreeIDs = WorkspaceSidebarModel.sections(
            in: bootstrap.snapshot,
            visibility: visibility
        )
        .flatMap { section in
            section.projects.flatMap(\.worktreeRows)
        }
        .compactMap { row -> UUID? in
            guard case let .worktree(id) = row.target else {
                return nil
            }
            return id
        }

        let keyboardWorktreeIDs = KeyboardNavigationModel
            .orderedWorktrees(
                in: bootstrap.snapshot,
                visibility: visibility
            )
            .map(\.id)

        #expect(keyboardWorktreeIDs == sidebarWorktreeIDs)
    }

    @Test("keyboard navigation follows persisted worktree reordering")
    func keyboardNavigationFollowsPersistedOrder() throws {
        let bootstrap = WorkspaceBootstrap.preview()
        let project = try #require(
            WorkspaceSidebarModel.sections(in: bootstrap.snapshot)
                .flatMap(\.projects)
                .first(where: { $0.worktrees.count >= 2 })
        )
        let first = project.worktrees[0]
        let second = project.worktrees[1]
        let rawOrder = [second.id, first.id]
            .map(\.uuidString)
            .joined(separator: "\n")
        var selection = bootstrap.selection
        selection.select(.worktree(second.id), in: bootstrap.snapshot)

        let next = KeyboardNavigationModel.steppedSelection(
            from: selection,
            in: bootstrap.snapshot,
            step: 1,
            worktreeOrderRawValue: rawOrder
        )

        #expect(next?.selectedWorktreeID == first.id)
    }

    @Test("keyboard navigation excludes stale rows")
    func keyboardNavigationExcludesStaleRows() {
        let host = HostSummary.fixture(
            id: UUID(uuidString: "6F0934D0-7D80-45AE-BDB4-13A765827902")!,
            name: "Build Box"
        )
        let activeProject = ProjectSummary.fixture(
            id: UUID(uuidString: "64134145-FEDE-4170-976C-69EF6D4DDB4D")!,
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/srv/ghosthub"
        )
        let staleProject = ProjectSummary.fixture(
            id: UUID(uuidString: "BF0A2603-9C1C-4757-9002-4A45AB83C841")!,
            hostID: host.id,
            name: "ghosthub-old",
            rootPath: "/srv/ghosthub-old",
            isStale: true
        )
        let activeWorktree = WorktreeSummary.fixture(
            id: UUID(uuidString: "FC0CC6CC-7F55-49A0-B6E4-A33D7065C60D")!,
            hostID: host.id,
            projectID: activeProject.id,
            name: "main",
            path: "/srv/ghosthub",
            branch: "main"
        )
        let staleWorktree = WorktreeSummary.fixture(
            id: UUID(uuidString: "7DEB2666-B27B-456F-B0FE-19CC58A170B1")!,
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

        #expect(
            KeyboardNavigationModel.orderedWorktrees(in: snapshot)
                .map(\.name) == ["main"]
        )
    }
}
