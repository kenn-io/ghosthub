import Foundation
import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubUI
import GhosthubWorkspace

enum ApplicationShortcutInvocation: Equatable {
    case keyEvent
    case menu
}

extension WorkspaceSceneModel {

    var selectedProject: ProjectSummary? {
        guard let project = WorkspaceSelectionResolver.selectedProject(
            in: snapshot,
            selection: selection
        ), snapshot.canCreateWorktree(in: project) else { return nil }
        return project
    }

    var canCreateWorktreeInSelectedProject: Bool {
        selectedProject != nil
    }

    var canImportPullRequestInSelectedProject: Bool {
        guard let project = WorkspaceSelectionResolver.selectedProject(
            in: snapshot,
            selection: selection
        ) else { return false }
        return snapshot.canImportPullRequest(in: project)
    }

    func installShortcutMonitor() {
        let monitor = ShortcutMonitor(
            shortcuts: {
                SettingsStore.shared.shortcutPreferences.resolved
            },
            perform: { [weak self] action in
                self?.performApplicationShortcut(
                    action,
                    invocation: .keyEvent
                ) == true
            }
        )
        monitor.install()
        shortcutMonitor = monitor
    }

    func performApplicationShortcut(
        _ action: ApplicationShortcutAction,
        invocation: ApplicationShortcutInvocation = .keyEvent
    ) -> Bool {
        guard invocation == .menu || isFocusedWindow else { return false }
        switch action {
        case .nextSibling:
            return navigateSibling(step: 1)
        case .previousSibling:
            return navigateSibling(step: -1)
        case .selectSibling1, .selectSibling2, .selectSibling3,
             .selectSibling4, .selectSibling5, .selectSibling6,
             .selectSibling7, .selectSibling8, .selectSibling9:
            guard let index = action.siblingIndex else { return false }
            return navigateSibling(index: index)
        case .commandPalette:
            isCommandPalettePresented = true
            return true
        case .toggleSidebar:
            return postShortcutRequest(action)
        case .newWorktree:
            guard let project = selectedProject,
                  snapshot.canCreateWorktree(in: project) else { return false }
            return postShortcutRequest(action)
        case .importPullRequest:
            guard let project = WorkspaceSelectionResolver.selectedProject(
                in: snapshot,
                selection: selection
            ),
                snapshot.canImportPullRequest(in: project) else {
                return false
            }
            return postShortcutRequest(action)
        case .newTmuxSession:
            guard snapshot.host(id: selection.selectedHostID) != nil else {
                return false
            }
            return postShortcutRequest(action)
        case .newHerdrSession:
            guard snapshot.host(id: selection.selectedHostID)?
                .herdrAvailable == true else { return false }
            return postShortcutRequest(action)
        case .splitRight:
            guard canSplitActivePane,
                  invocation == .menu || hasFocusedTerminalSurface
            else { return false }
            splitActivePane(
                .right,
                requiresKeyboardFocus: invocation == .keyEvent
            )
            return true
        case .splitDown:
            guard canSplitActivePane,
                  invocation == .menu || hasFocusedTerminalSurface
            else { return false }
            splitActivePane(
                .down,
                requiresKeyboardFocus: invocation == .keyEvent
            )
            return true
        case .reloadConfiguration:
            reloadTerminalConfig()
            return true
        case .openApplicationLog:
            isLogViewerPresented = true
            return true
        }
    }

    private var hasFocusedTerminalSurface: Bool {
        terminalCoordinator.surfaceEntries().contains {
            $0.view.hasEffectiveKeyboardFocus
        }
    }

    private var activeNavigationTarget: WorkspaceNavigationTarget {
        if let pending = pendingHerdrShortcutSelection {
            return .herdrSession(
                hostID: pending.hostID,
                name: pending.name
            )
        }
        if let active = activeBorrowedHerdrSelection {
            return .herdrSession(hostID: active.hostID, name: active.name)
        }
        if let active = activeBorrowedTmuxSelection {
            if let worktreeID = active.worktreeID {
                return .worktree(worktreeID)
            }
            if let directoryID = active.directoryWorkspaceID {
                return .directoryWorkspace(directoryID)
            }
            return .tmuxSession(hostID: active.hostID, name: active.name)
        }
        return selection.navigationTarget
    }

    private var keyboardNavigationContext: KeyboardNavigationContext {
        KeyboardNavigationContext(
            snapshot: snapshot,
            visibility: worktreeVisibility,
            tmuxSessionVisibility: TmuxSessionVisibility(
                hiddenPatterns: SettingsStore.shared.tmuxSessionPreferences
                    .hiddenSessionPatterns,
                hideKwtManagedSessions: SettingsStore.shared
                    .worktreePreferences.hideKwtManagedSessions
            ),
            worktreeOrderRawValue: WorkspaceSidebarOrderStorage
                .worktreeRawValue(),
            tmuxSessionOrderRawValue: WorkspaceSidebarOrderStorage
                .tmuxSessionRawValue(),
            herdrSessionOrderRawValue: WorkspaceSidebarOrderStorage
                .herdrSessionRawValue()
        )
    }

    func canPerformSiblingShortcut(
        _ action: ApplicationShortcutAction
    ) -> Bool {
        availableSiblingShortcuts.contains(action)
    }

    var availableSiblingShortcuts: Set<ApplicationShortcutAction> {
        let targets = KeyboardNavigationModel.siblingTargets(
            for: activeNavigationTarget,
            in: keyboardNavigationContext
        )
        guard targets.count >= 2 else { return [] }
        return Set(ApplicationShortcutAction.allCases.filter { action in
            switch action {
            case .nextSibling, .previousSibling:
                true
            default:
                action.siblingIndex.map { $0 <= targets.count } == true
            }
        })
    }

    var availablePaletteApplicationShortcuts:
        Set<ApplicationShortcutAction> {
        var actions = availableSiblingShortcuts
        if canSplitActivePane {
            actions.formUnion([.splitRight, .splitDown])
        }
        return actions
    }

    private func navigateSibling(step: Int) -> Bool {
        guard let target = KeyboardNavigationModel.steppedTarget(
            from: activeNavigationTarget,
            step: step,
            in: keyboardNavigationContext
        ) else { return false }
        return openKeyboardNavigationTarget(target)
    }

    private func navigateSibling(index: Int) -> Bool {
        guard let target = KeyboardNavigationModel.targetForShortcutIndex(
            index,
            from: activeNavigationTarget,
            in: keyboardNavigationContext
        ) else { return false }
        return openKeyboardNavigationTarget(target)
    }

    private func openKeyboardNavigationTarget(
        _ target: WorkspaceNavigationTarget
    ) -> Bool {
        switch target {
        case .worktree, .directoryWorkspace:
            var updated = selection
            updated.select(target, in: snapshot, visibility: worktreeVisibility)
            selectFromUser(updated)
            return true
        case let .tmuxSession(hostID, name):
            var updated = selection
            updated.select(target, in: snapshot, visibility: worktreeVisibility)
            selectFromUser(updated)
            openBorrowedTmuxSession(.init(hostID: hostID, name: name))
            return true
        case let .herdrSession(hostID, name):
            guard snapshot.host(id: hostID)?.herdrSessions.contains(
                where: { $0.name == name && $0.state == .running }
            ) == true else { return false }
            var updated = selection
            updated.select(target, in: snapshot, visibility: worktreeVisibility)
            selectFromUser(updated)
            startHerdrShortcutNavigation(.init(
                hostID: hostID,
                name: name
            ))
            return true
        case .host, .project:
            return false
        }
    }

    private func startHerdrShortcutNavigation(
        _ selection: WorkspaceHerdrSessionSelection
    ) {
        herdrShortcutNavigationTask?.cancel()
        let navigationID = UUID()
        herdrShortcutNavigationID = navigationID
        pendingHerdrShortcutSelection = selection
        herdrShortcutNavigationTask = Task { @MainActor [weak self] in
            try? await self?.openBorrowedHerdrSession(selection)
            guard self?.herdrShortcutNavigationID == navigationID else {
                return
            }
            self?.pendingHerdrShortcutSelection = nil
            self?.herdrShortcutNavigationTask = nil
            self?.herdrShortcutNavigationID = nil
        }
    }

    func cancelPendingHerdrShortcutNavigation() {
        herdrShortcutNavigationTask?.cancel()
        herdrShortcutNavigationTask = nil
        herdrShortcutNavigationID = nil
        pendingHerdrShortcutSelection = nil
    }

    private func postShortcutRequest(
        _ action: ApplicationShortcutAction
    ) -> Bool {
        NotificationCenter.default.post(
            name: .ghosthubApplicationShortcutRequest,
            object: self,
            userInfo: [applicationShortcutActionUserInfoKey: action.rawValue]
        )
        return true
    }

}
