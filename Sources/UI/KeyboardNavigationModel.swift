import Foundation
import GhosthubWorkspace

public enum KeyboardNavigationModel {
    public static func orderedWorktrees(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility = .default
    ) -> [WorktreeSummary] {
        WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility
        ).flatMap { section in
            section.projects.flatMap(\.worktrees)
        }
    }

    public static func steppedSelection(
        from selection: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        step: Int,
        visibility: WorktreeVisibility = .default
    ) -> WorkspaceSelection? {
        let worktrees = orderedWorktrees(in: snapshot, visibility: visibility)
        guard !worktrees.isEmpty else {
            return nil
        }

        let currentIndex = worktrees.firstIndex { $0.id == selection.selectedWorktreeID }
        let baseIndex = currentIndex ?? (step >= 0 ? -1 : 0)
        let wrappedIndex = (baseIndex + step).positiveModulo(worktrees.count)

        var updatedSelection = selection
        updatedSelection.select(
            .worktree(worktrees[wrappedIndex].id),
            in: snapshot,
            visibility: visibility
        )
        return updatedSelection
    }

    public static func selectionForShortcutIndex(
        _ index: Int,
        from selection: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility = .default
    ) -> WorkspaceSelection? {
        let worktrees = orderedWorktrees(in: snapshot, visibility: visibility)
        guard index > 0, index <= worktrees.count else {
            return nil
        }

        var updatedSelection = selection
        updatedSelection.select(
            .worktree(worktrees[index - 1].id),
            in: snapshot,
            visibility: visibility
        )
        return updatedSelection
    }
}

extension Int {
    func positiveModulo(_ modulus: Int) -> Int {
        let remainder = self % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}
