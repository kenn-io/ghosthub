import Foundation
import GhosthubWorkspace

public struct KeyboardNavigationContext: Sendable {
    public var snapshot: WorkspaceSnapshot
    public var visibility: WorktreeVisibility
    public var tmuxSessionVisibility: TmuxSessionVisibility
    public var worktreeOrderRawValue: String
    public var tmuxSessionOrderRawValue: String
    public var herdrSessionOrderRawValue: String
    public var zellijSessionOrderRawValue: String

    public init(
        snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility = .default,
        tmuxSessionVisibility: TmuxSessionVisibility = .init(),
        worktreeOrderRawValue: String = "",
        tmuxSessionOrderRawValue: String = "",
        herdrSessionOrderRawValue: String = "",
        zellijSessionOrderRawValue: String = ""
    ) {
        self.snapshot = snapshot
        self.visibility = visibility
        self.tmuxSessionVisibility = tmuxSessionVisibility
        self.worktreeOrderRawValue = worktreeOrderRawValue
        self.tmuxSessionOrderRawValue = tmuxSessionOrderRawValue
        self.herdrSessionOrderRawValue = herdrSessionOrderRawValue
        self.zellijSessionOrderRawValue = zellijSessionOrderRawValue
    }
}

public enum KeyboardNavigationModel {
    public static func siblingTargets(
        for currentTarget: WorkspaceNavigationTarget,
        in context: KeyboardNavigationContext
    ) -> [WorkspaceNavigationTarget] {
        let sections = WorkspaceSidebarModel.sections(
            in: context.snapshot,
            visibility: context.visibility,
            tmuxSessionVisibility: context.tmuxSessionVisibility,
            worktreeOrderRawValue: context.worktreeOrderRawValue,
            tmuxSessionOrderRawValue: context.tmuxSessionOrderRawValue,
            herdrSessionOrderRawValue: context.herdrSessionOrderRawValue,
            zellijSessionOrderRawValue: context.zellijSessionOrderRawValue
        )

        switch currentTarget {
        case .worktree:
            for project in sections.flatMap(\.projects) where
                project.worktreeRows.contains(where: {
                    $0.target == currentTarget
                }) {
                return project.worktreeRows.map(\.target)
            }
        case .directoryWorkspace:
            for section in sections where
                section.directoryWorkspaceRows.contains(where: {
                    $0.target == currentTarget
                }) {
                return section.directoryWorkspaceRows.map(\.target)
            }
        case .tmuxSession:
            for section in sections where
                section.tmuxSessionRows.contains(where: {
                    $0.target == currentTarget
                }) {
                return section.tmuxSessionRows.map(\.target)
            }
        case .herdrSession:
            for section in sections {
                let running = section.herdrSessionRows.filter {
                    $0.herdrSessionState == .running
                }
                if running.contains(where: { $0.target == currentTarget }) {
                    return running.map(\.target)
                }
            }
        case .zellijSession:
            for section in sections where
                section.zellijSessionRows.contains(where: {
                    $0.target == currentTarget
                }) {
                return section.zellijSessionRows.map(\.target)
            }
        case .host, .project:
            break
        }
        return []
    }

    public static func steppedTarget(
        from currentTarget: WorkspaceNavigationTarget,
        step: Int,
        in context: KeyboardNavigationContext
    ) -> WorkspaceNavigationTarget? {
        let targets = siblingTargets(for: currentTarget, in: context)
        guard targets.count >= 2,
              let currentIndex = targets.firstIndex(of: currentTarget)
        else { return nil }
        return targets[(currentIndex + step).positiveModulo(targets.count)]
    }

    public static func targetForShortcutIndex(
        _ index: Int,
        from currentTarget: WorkspaceNavigationTarget,
        in context: KeyboardNavigationContext
    ) -> WorkspaceNavigationTarget? {
        let targets = siblingTargets(for: currentTarget, in: context)
        guard targets.count >= 2,
              index > 0,
              index <= targets.count
        else { return nil }
        return targets[index - 1]
    }

}

extension Int {
    func positiveModulo(_ modulus: Int) -> Int {
        let remainder = self % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}
