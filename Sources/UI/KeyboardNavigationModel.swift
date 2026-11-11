import Foundation
import GhosthubSettings
import GhosthubWorkspace

public struct KeyboardNavigationContext: Sendable {
    public var snapshot: WorkspaceSnapshot
    public var sidebarSections: [WorkspaceSidebarSection]?
    public var visibility: WorktreeVisibility
    public var tmuxSessionVisibility: TmuxSessionVisibility
    public var worktreeOrderRawValue: String
    public var sessionOrderRawValue: String
    public var sessionSort: SidebarSessionSort
    public var agentAttentionByEndpoint: [String: AgentAttention]

    public init(
        snapshot: WorkspaceSnapshot,
        sidebarSections: [WorkspaceSidebarSection]? = nil,
        visibility: WorktreeVisibility = .default,
        tmuxSessionVisibility: TmuxSessionVisibility = .init(),
        worktreeOrderRawValue: String = "",
        sessionOrderRawValue: String = "",
        sessionSort: SidebarSessionSort = .manual,
        agentAttentionByEndpoint: [String: AgentAttention] = [:]
    ) {
        self.snapshot = snapshot
        self.sidebarSections = sidebarSections
        self.visibility = visibility
        self.tmuxSessionVisibility = tmuxSessionVisibility
        self.worktreeOrderRawValue = worktreeOrderRawValue
        self.sessionOrderRawValue = sessionOrderRawValue
        self.sessionSort = sessionSort
        self.agentAttentionByEndpoint = agentAttentionByEndpoint
    }
}

public enum KeyboardNavigationModel {
    public static func siblingTargets(
        for currentTarget: WorkspaceNavigationTarget,
        in context: KeyboardNavigationContext
    ) -> [WorkspaceNavigationTarget] {
        let sections = context.sidebarSections
            ?? WorkspaceSidebarModel.sections(
                in: context.snapshot,
                visibility: context.visibility,
                tmuxSessionVisibility: context.tmuxSessionVisibility,
                worktreeOrderRawValue: context.worktreeOrderRawValue,
                sessionOrderRawValue: context.sessionOrderRawValue,
                sessionSort: context.sessionSort,
                agentAttentionByEndpoint: context.agentAttentionByEndpoint
            )

        switch currentTarget {
        case .worktree:
            for section in sections {
                for project in section.projects {
                    if let targets = matchingTargets(
                        in: project.worktreeRows,
                        currentTarget: currentTarget
                    ) {
                        return targets
                    }
                }
            }
        case .directoryWorkspace:
            for section in sections {
                if let targets = matchingTargets(
                    in: section.directoryWorkspaceRows,
                    currentTarget: currentTarget
                ) {
                    return targets
                }
            }
        case .tmuxSession, .herdrSession, .backendTerminal, .zellijSession:
            // Sessions share one list per host; stopped Herdr sessions are
            // skipped because opening one restarts it.
            for section in sections {
                let openable = section.sessionRows.filter {
                    $0.herdrSessionState != .stopped
                }
                if let targets = matchingTargets(
                    in: openable,
                    currentTarget: currentTarget
                ) {
                    return targets
                }
            }
        case .host, .project:
            break
        }
        return []
    }

    static func matchingTargets(
        in rows: [WorkspaceSidebarRow],
        currentTarget: WorkspaceNavigationTarget
    ) -> [WorkspaceNavigationTarget]? {
        let targets = rows.map(\.target)
        return targets.contains(currentTarget) ? targets : nil
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
