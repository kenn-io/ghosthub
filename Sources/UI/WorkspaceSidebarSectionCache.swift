import Foundation
import GhosthubWorkspace

@MainActor
public final class WorkspaceSidebarSectionCache {
    private struct Input: Equatable {
        var snapshotRevision: UInt64
        var visibility: WorktreeVisibility
        var tmuxSessionVisibility: TmuxSessionVisibility
        var connectedTmuxSessionIDs: Set<String>
        var liveTmuxWindowCounts: [String: Int]
        var worktreeOrderRawValue: String
        var tmuxSessionOrderRawValue: String
        var herdrSessionOrderRawValue: String
        var zellijSessionOrderRawValue: String
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
        worktreeOrderRawValue: String = "",
        tmuxSessionOrderRawValue: String = "",
        herdrSessionOrderRawValue: String = "",
        zellijSessionOrderRawValue: String = ""
    ) -> [WorkspaceSidebarSection] {
        let input = Input(
            snapshotRevision: snapshotRevision,
            visibility: visibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            connectedTmuxSessionIDs: connectedTmuxSessionIDs,
            liveTmuxWindowCounts: liveTmuxWindowCounts,
            worktreeOrderRawValue: worktreeOrderRawValue,
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue,
            herdrSessionOrderRawValue: herdrSessionOrderRawValue,
            zellijSessionOrderRawValue: zellijSessionOrderRawValue
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
            worktreeOrderRawValue: worktreeOrderRawValue,
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue,
            herdrSessionOrderRawValue: herdrSessionOrderRawValue,
            zellijSessionOrderRawValue: zellijSessionOrderRawValue
        )
        cached = (input, sections)
        return sections
    }
}
