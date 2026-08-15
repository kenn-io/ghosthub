import Foundation
import GhosthubWorkspace

/// Glyph representing the CI checks state for a worktree PR.
public enum ChecksGlyph: Equatable, Sendable {
    case success
    case failure
    case pending
}

/// Derived status for a worktree sidebar row.
///
/// Computed from a `WorktreeSummary` and its active sessions.
/// All nil fields are omitted from the rendered row.
public struct WorktreeRowStatus: Equatable, Sendable {
    /// Non-zero lines added in the working tree diff; nil means omit.
    public var diffAdded: Int?
    /// Non-zero lines removed in the working tree diff; nil means omit.
    public var diffRemoved: Int?
    /// Commits ahead of the upstream remote; nil or 0 means omit.
    public var syncAhead: Int?
    /// Commits behind the upstream remote; nil or 0 means omit.
    public var syncBehind: Int?
    /// Positive default-server tmux window count; nil means omit.
    public var tmuxWindowCount: Int?
    /// True when any session for this worktree is alive.
    public var isRunning: Bool
    /// True when a running session has `runtimeKind == .agent`.
    public var isAgentRunning: Bool
    /// Linked PR number, if any.
    public var prNumber: Int?
    /// Linked PR title, if any.
    public var prTitle: String?
    /// True when the linked PR is in draft state.
    public var isDraft: Bool
    /// CI checks glyph; nil when no checks status is available.
    public var checks: ChecksGlyph?
    /// True when a second line (PR info) should be rendered.
    public var showsSecondLine: Bool

    public var tmuxWindowLabel: String? {
        guard let tmuxWindowCount else { return nil }
        return tmuxWindowCount == 1
            ? "1 window"
            : "\(tmuxWindowCount) windows"
    }

    public var showsGenericRunningIndicator: Bool {
        isRunning && !isAgentRunning && tmuxWindowCount == nil
    }

    /// Derives a `WorktreeRowStatus` from a worktree summary and its sessions.
    ///
    /// - Parameters:
    ///   - w: The worktree summary to derive status from.
    ///   - sessions: The active sessions associated with this worktree.
    ///   - hasLiveTmuxSession: Whether direct discovery found the worktree's
    ///     canonical tmux session.
    /// - Returns: A fully derived `WorktreeRowStatus`.
    public static func make(
        for w: WorktreeSummary,
        sessions: [TerminalSessionSummary],
        hasLiveTmuxSession: Bool = false,
        tmuxWindowCount: Int? = nil
    ) -> WorktreeRowStatus {
        let added = (w.diffAdded ?? 0) > 0 ? w.diffAdded : nil
        let removed = (w.diffRemoved ?? 0) > 0 ? w.diffRemoved : nil
        let ahead = (w.syncAhead ?? 0) > 0 ? w.syncAhead : nil
        let behind = (w.syncBehind ?? 0) > 0 ? w.syncBehind : nil
        let windowCount = (tmuxWindowCount ?? 0) > 0
            ? tmuxWindowCount
            : nil
        let running = hasLiveTmuxSession || sessions.contains { $0.isAlive }
        let agentRunning = sessions.contains { $0.isAlive && $0.runtimeKind == .agent }
        let checksGlyph = checksGlyph(from: w.checksStatus)

        return WorktreeRowStatus(
            diffAdded: added,
            diffRemoved: removed,
            syncAhead: ahead,
            syncBehind: behind,
            tmuxWindowCount: windowCount,
            isRunning: running,
            isAgentRunning: agentRunning,
            prNumber: w.linkedPullRequestNumber,
            prTitle: w.pullRequestTitle,
            isDraft: w.pullRequestState == .draft,
            checks: checksGlyph,
            showsSecondLine: w.linkedPullRequestNumber != nil
        )
    }

    private static func checksGlyph(from status: ChecksStatus?) -> ChecksGlyph? {
        guard let status else { return nil }
        switch status {
        case .success: return .success
        case .failure: return .failure
        case .pending: return .pending
        case .none: return nil
        }
    }
}
