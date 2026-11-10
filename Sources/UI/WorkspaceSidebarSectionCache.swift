import Foundation
import GhosthubSettings
import GhosthubWorkspace

@MainActor
public final class WorkspaceSidebarSectionCache {
    private struct Input: Equatable {
        var snapshotRevision: UInt64
        var visibility: WorktreeVisibility
        var tmuxSessionVisibility: TmuxSessionVisibility
        var connectedTmuxSessionIDs: Set<String>
        var liveTmuxWindowCounts: [String: Int]
        var hostOrderRawValue: String
        var worktreeOrderRawValue: String
        var sessionOrderRawValue: String
        var sessionSort: SidebarSessionSort
        var agentAttentionByEndpoint: [String: AgentAttention]
    }

    private var cached: (input: Input, sections: [WorkspaceSidebarSection])?

    public init() {}

    public func sections(
        in snapshot: WorkspaceSnapshot,
        snapshotRevision: UInt64,
        visibility: WorktreeVisibility = .default,
        tmuxSessionVisibility: TmuxSessionVisibility = .init(),
        connectedTmuxSessionIDs: Set<String> = [],
        liveTmuxWindowCounts: [String: Int] = [:],
        hostOrderRawValue: String = "",
        worktreeOrderRawValue: String = "",
        sessionOrderRawValue: String = "",
        sessionSort: SidebarSessionSort = .manual,
        agentAttentionByEndpoint: [String: AgentAttention] = [:]
    ) -> [WorkspaceSidebarSection] {
        // Attention only orders rows in the attention sort; ignoring it
        // otherwise keeps agent state changes from rebuilding the sidebar.
        let attention = sessionSort == .attention
            ? agentAttentionByEndpoint : [:]
        let input = Input(
            snapshotRevision: snapshotRevision,
            visibility: visibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            connectedTmuxSessionIDs: connectedTmuxSessionIDs,
            liveTmuxWindowCounts: liveTmuxWindowCounts,
            hostOrderRawValue: hostOrderRawValue,
            worktreeOrderRawValue: worktreeOrderRawValue,
            sessionOrderRawValue: sessionOrderRawValue,
            sessionSort: sessionSort,
            agentAttentionByEndpoint: attention
        )
        if let cached, cached.input == input {
            return cached.sections
        }

        let sections = WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            connectedTmuxSessionIDs: connectedTmuxSessionIDs,
            liveTmuxWindowCounts: liveTmuxWindowCounts,
            hostOrderRawValue: hostOrderRawValue,
            worktreeOrderRawValue: worktreeOrderRawValue,
            sessionOrderRawValue: sessionOrderRawValue,
            sessionSort: sessionSort,
            agentAttentionByEndpoint: attention
        )
        cached = (input, sections)
        return sections
    }
}
