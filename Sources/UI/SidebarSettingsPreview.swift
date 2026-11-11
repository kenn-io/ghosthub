import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

/// Sample sidebar drawn from unsaved Settings values. It runs the sample
/// rows through the sidebar's own ordering and row views, so it shows each
/// setting exactly as the sidebar will apply it.
struct SidebarSettingsPreview: View {
    let preferences: SidebarPreferences
    let hideWorktreeSessions: Bool
    let hideRootCheckout: Bool
    let showHiddenWorktrees: Bool

    @State private var highlightedRowIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            hostHeader
            ForEach(Sample.orderedSessions(
                sort: preferences.sessionSort,
                hideWorktreeSessions: hideWorktreeSessions
            )) { session in
                sessionRow(session)
            }
            Text("Projects")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            HStack(spacing: 6) {
                Text("web-app")
                    .font(.system(size: 13))
                Text("~/code/web-app")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: preferences.rowHeight.points)
            ForEach(Sample.worktrees.filter(isWorktreeVisible)) { worktree in
                worktreeRow(worktree)
            }
        }
        .padding(8)
        .frame(width: 272, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar preview with sample sessions")
        .onChange(of: preferences.backendLabelStyle) { _, _ in
            highlight(Set(Sample.sessions.map(\.id)))
        }
        .onChange(of: preferences.sessionSort) { _, _ in
            highlight(Set(Sample.sessions.map(\.id)))
        }
        .onChange(of: preferences.rowHeight) { _, _ in
            highlight(Set(Sample.sessions.map(\.id) + Sample.worktrees.map(\.id)))
        }
        .onChange(of: hideWorktreeSessions) { _, _ in
            highlight([Sample.worktreeSessionID])
        }
        .onChange(of: hideRootCheckout) { _, _ in
            highlight([Sample.rootCheckoutID])
        }
        .onChange(of: showHiddenWorktrees) { _, _ in
            highlight([Sample.hiddenWorktreeID])
        }
    }

    private var hostHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text("studio.local")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("This Mac")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
    }

    private func sessionRow(_ session: Sample.Session) -> some View {
        SidebarSessionRowContent(
            title: session.row.title,
            detail: session.row.sessionDetail,
            backend: session.row.sessionBackend ?? .tmux,
            labelStyle: preferences.backendLabelStyle,
            agentAttention: session.attention,
            isStopped: session.row.herdrSessionState == .stopped,
            isSelected: session.isSelected
        )
        .padding(.trailing, WorkspaceSessionActionPresentation.columnWidth)
        .padding(.horizontal, 8)
        .frame(minHeight: preferences.rowHeight.points)
        .background { rowBackground(session.id, isSelected: session.isSelected) }
    }

    private func worktreeRow(_ worktree: Sample.Worktree) -> some View {
        SidebarWorktreeRowContent(title: worktree.name, status: worktree.status)
            .opacity(worktree.isHidden ? 0.55 : 1)
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .frame(minHeight: preferences.rowHeight.points)
            .background { rowBackground(worktree.id, isSelected: false) }
    }

    private func rowBackground(_ id: String, isSelected: Bool) -> some View {
        ZStack {
            SidebarRowSelectionBackground(isSelected: isSelected)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(
                    highlightedRowIDs.contains(id) ? 0.22 : 0
                ))
        }
    }

    private func isWorktreeVisible(_ worktree: Sample.Worktree) -> Bool {
        if worktree.isRootCheckout, hideRootCheckout {
            return false
        }
        if worktree.isHidden, !showHiddenWorktrees {
            return false
        }
        return true
    }

    /// Briefly marks the rows the last change affected.
    private func highlight(_ ids: Set<String>) {
        guard !reduceMotion else { return }
        highlightedRowIDs = ids
        withAnimation(.easeOut(duration: 0.7).delay(0.15)) {
            highlightedRowIDs = []
        }
    }
}

private enum Sample {
    struct Session: Identifiable {
        let row: WorkspaceSidebarRow
        var attention: AgentAttention?
        var isSelected = false
        var isWorktreeSession = false

        var id: String { row.sessionOrderID ?? row.title }
    }

    struct Worktree: Identifiable {
        let id: String
        let name: String
        let status: WorktreeRowStatus
        var isRootCheckout = false
        var isHidden = false
    }

    static let hostID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11C")!

    static func tmux(_ name: String) -> WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .tmuxSession(hostID: hostID, name: name, socketName: nil),
            icon: .tmuxSession,
            title: name
        )
    }

    static func herdr(
        _ name: String,
        title: String? = nil,
        backend: HerdrBackend,
        state: HerdrSessionState = .running
    ) -> WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .herdrSession(hostID: hostID, name: name, backend: backend),
            icon: backend == .core ? .herdrTerminal : .herdrSession,
            title: title ?? name,
            subtitle: backend == .core ? name : nil,
            herdrSessionState: state
        )
    }

    static let sessions: [Session] = [
        Session(row: tmux("scratch"), attention: .working(agent: "Claude")),
        Session(
            row: WorkspaceSidebarRow(
                target: .zellijSession(hostID: hostID, name: "docs-preview"),
                icon: .zellijSession,
                title: "docs-preview"
            ),
            isSelected: true
        ),
        Session(row: herdr("t7", title: "web-app / desktop-review", backend: .core)),
        Session(row: tmux("release-watch"), attention: .approval(agent: "Codex")),
        Session(row: tmux("web-app-feat-checkout"), isWorktreeSession: true),
        Session(row: herdr("release-review", backend: .tui)),
        Session(row: herdr("archived", backend: .tui, state: .stopped)),
    ]

    static let worktreeSessionID = sessions[4].id

    /// Manual order is the order listed above.
    static func orderedSessions(
        sort: SidebarSessionSort,
        hideWorktreeSessions: Bool
    ) -> [Session] {
        let visible = sessions.filter {
            !(hideWorktreeSessions && $0.isWorktreeSession)
        }
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        let attention = Dictionary(uniqueKeysWithValues: visible.compactMap { session in
            session.attention.map {
                (AgentAttentionStore.endpointKey(
                    hostID: hostID,
                    name: session.row.title,
                    socketName: nil
                ), $0)
            }
        })
        return WorkspaceSidebarSessionOrdering.ordered(
            visible.map(\.row),
            sort: sort,
            manualOrder: WorkspaceSidebarOrder(
                rawValue: visible.map(\.id).joined(separator: "\n")
            ),
            agentAttentionByEndpoint: attention
        )
        .compactMap { byID[$0.sessionOrderID ?? $0.title] }
    }

    static let rootCheckoutID = "worktree:main"
    static let hiddenWorktreeID = "worktree:spike"

    static let worktrees: [Worktree] = [
        Worktree(
            id: rootCheckoutID,
            name: "main",
            status: status(),
            isRootCheckout: true
        ),
        Worktree(
            id: "worktree:checkout",
            name: "feat/checkout",
            status: status(added: 42, removed: 7, pr: 482, checks: .success)
        ),
        Worktree(
            id: hiddenWorktreeID,
            name: "spike/old-cart",
            status: status(),
            isHidden: true
        ),
    ]

    static func status(
        added: Int? = nil,
        removed: Int? = nil,
        pr: Int? = nil,
        checks: ChecksGlyph? = nil
    ) -> WorktreeRowStatus {
        WorktreeRowStatus(
            diffAdded: added,
            diffRemoved: removed,
            syncAhead: nil,
            syncBehind: nil,
            tmuxWindowCount: nil,
            isRunning: false,
            isAgentRunning: false,
            prNumber: pr,
            prTitle: pr.map { _ in "Show delivery estimate at checkout" },
            isDraft: false,
            checks: checks,
            showsSecondLine: pr != nil
        )
    }
}
