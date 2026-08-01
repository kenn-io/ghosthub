import Foundation
import GhosthubUI
import GhosthubWorkspace

extension WorkspaceSceneModel {

    var selectedProject: ProjectSummary? {
        guard let project = WorkspaceSelectionResolver.selectedProject(
            in: snapshot,
            selection: selection
        ), snapshot.canCreateWorktree(in: project) else { return nil }
        return project
    }

    func installShortcutMonitor() {
        let monitor = ShortcutMonitor(
            callbacks: ShortcutMonitor.Callbacks(
                selectWorktreeByIndex: { [weak self] index in
                    guard self?.isFocusedWindow == true else {
                        return false
                    }
                    self?.selectIndexedWorktree(index)
                    return true
                },
                previousWorktree: { [weak self] in
                    guard self?.isFocusedWindow == true else {
                        return false
                    }
                    self?.stepWorktree(by: -1)
                    return true
                },
                nextWorktree: { [weak self] in
                    guard self?.isFocusedWindow == true else {
                        return false
                    }
                    self?.stepWorktree(by: 1)
                    return true
                },
                toggleSidebar: { false },
                openCommandPalette: { [weak self] in
                    guard self?.isFocusedWindow == true else {
                        return false
                    }
                    self?.isCommandPalettePresented = true
                    return true
                }
            )
        )
        monitor.install()
        shortcutMonitor = monitor
    }

    func selectIndexedWorktree(_ index: Int) {
        if let updated = KeyboardNavigationModel.selectionForShortcutIndex(
            index, from: selection, in: snapshot,
            visibility: worktreeVisibility
        ) {
            selectFromUser(updated)
        }
    }

    func stepWorktree(by step: Int) {
        if let updated = KeyboardNavigationModel.steppedSelection(
            from: selection, in: snapshot, step: step,
            visibility: worktreeVisibility
        ) {
            selectFromUser(updated)
        }
    }
}
