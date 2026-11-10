import Foundation
import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

struct TmuxSessionPreviewExpansionState: Equatable {
    private(set) var expandedSessionIDs: Set<String> = []
    private(set) var collapsedSessionIDs: Set<String> = []

    func isExpanded(
        _ sessionID: String,
        defaultExpanded: Bool = false
    ) -> Bool {
        if expandedSessionIDs.contains(sessionID) {
            return true
        }
        if collapsedSessionIDs.contains(sessionID) {
            return false
        }
        return defaultExpanded
    }

    mutating func setExpanded(
        _ expanded: Bool,
        sessionID: String,
        defaultExpanded: Bool = false
    ) {
        expandedSessionIDs.remove(sessionID)
        collapsedSessionIDs.remove(sessionID)
        if expanded != defaultExpanded {
            if expanded {
                expandedSessionIDs.insert(sessionID)
            } else {
                collapsedSessionIDs.insert(sessionID)
            }
        }
    }
}

struct TmuxSessionPreviewMountState {
    private var mountIDsBySessionID: [String: Set<UUID>] = [:]

    mutating func setMounted(
        _ mounted: Bool,
        sessionID: String,
        mountID: UUID
    ) -> Bool? {
        let wasMounted = mountIDsBySessionID[sessionID]?.isEmpty == false
        if mounted {
            mountIDsBySessionID[sessionID, default: []].insert(mountID)
        } else {
            mountIDsBySessionID[sessionID]?.remove(mountID)
            if mountIDsBySessionID[sessionID]?.isEmpty == true {
                mountIDsBySessionID.removeValue(forKey: sessionID)
            }
        }
        let isMounted = mountIDsBySessionID[sessionID]?.isEmpty == false
        return wasMounted == isMounted ? nil : isMounted
    }
}

enum TmuxSessionPreviewRowPresentation {
    static func canDisclose(
        mode: SessionPreviewMode,
        sessionID: String,
        previewableSessionIDs: Set<String>
    ) -> Bool {
        mode != .off && previewableSessionIDs.contains(sessionID)
    }

    static func isVisible(
        mode: SessionPreviewMode,
        sessionID: String,
        previewableSessionIDs: Set<String>,
        expansion: TmuxSessionPreviewExpansionState
    ) -> Bool {
        canDisclose(
            mode: mode,
            sessionID: sessionID,
            previewableSessionIDs: previewableSessionIDs
        ) && isExpanded(
            mode: mode,
            sessionID: sessionID,
            expansion: expansion
        )
    }

    static func isExpanded(
        mode: SessionPreviewMode,
        sessionID: String,
        expansion: TmuxSessionPreviewExpansionState
    ) -> Bool {
        expansion.isExpanded(
            sessionID,
            defaultExpanded: mode.expandsEverySession
        )
    }
}

struct TmuxSessionPreviewMountModifier: ViewModifier {
    @State private var mountID = UUID()
    let session: WorkspaceTmuxSessionSelection
    let onMountChanged: (
        WorkspaceTmuxSessionSelection,
        UUID,
        Bool
    ) -> Void

    func body(content: Content) -> some View {
        content.onAppear {
            onMountChanged(session, mountID, true)
        }
        .onDisappear {
            onMountChanged(session, mountID, false)
        }
    }
}

struct WorkspaceSessionActionPresentation: Equatable {
    static let controlWidth: CGFloat = 28

    let isVisible: Bool
    let reservedWidth: CGFloat
    let hitTargetWidth: CGFloat

    init(
        hasActions: Bool,
        isRowHovered: Bool,
        isActionHovered: Bool,
        isSelected: Bool
    ) {
        isVisible = hasActions
            && (isRowHovered || isActionHovered || isSelected)
        reservedWidth = hasActions ? Self.controlWidth : 0
        hitTargetWidth = hasActions ? Self.controlWidth : 0
    }
}

struct WorkspaceWorktreeActionPresentation: Equatable {
    static let controlWidth: CGFloat = 30

    let isVisible: Bool
    let reservedWidth: CGFloat
    let hitTargetWidth: CGFloat

    init(
        isRowHovered: Bool,
        isActionHovered: Bool,
        isSelected: Bool,
        isFocused: Bool
    ) {
        isVisible = isRowHovered || isActionHovered || isSelected || isFocused
        reservedWidth = Self.controlWidth
        hitTargetWidth = Self.controlWidth
    }
}

struct WorkspaceProjectRemovalActionPresentation: Equatable {
    static let controlWidth: CGFloat = 30

    let isVisible: Bool
    let reservedWidth: CGFloat
    let hitTargetWidth: CGFloat

    init(
        isRemovable: Bool,
        isRowHovered: Bool,
        isActionHovered: Bool,
        isFocused: Bool
    ) {
        isVisible = isRemovable
            && (isRowHovered || isActionHovered || isFocused)
        reservedWidth = isRemovable ? Self.controlWidth : 0
        hitTargetWidth = isRemovable ? Self.controlWidth : 0
    }
}

struct WorktreeStatusCluster: View {
    let status: WorktreeRowStatus

    var body: some View {
        if hasStatus {
            HStack(spacing: 3) {
                if let added = status.diffAdded {
                    Text("+\(added)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.green)
                }
                if let removed = status.diffRemoved {
                    Text("−\(removed)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.red)
                }
                if let ahead = status.syncAhead {
                    Text("↑\(ahead)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let behind = status.syncBehind {
                    Text("↓\(behind)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if status.isRunning, status.isAgentRunning {
                    Image(systemName: "cpu")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                if let count = status.tmuxWindowCount,
                   let label = status.tmuxWindowLabel {
                    Label {
                        Text("\(count)")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "rectangle.stack.fill")
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .help(label)
                    .accessibilityHidden(true)
                } else if status.showsGenericRunningIndicator {
                    Image(systemName: "play.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .fixedSize()
        }
    }

    private var hasStatus: Bool {
        status.diffAdded != nil
            || status.diffRemoved != nil
            || status.syncAhead != nil
            || status.syncBehind != nil
            || status.isRunning
    }
}

struct WorktreeFlagPresentation {
    static let flagColor = Color.orange
    let isFlagged: Bool
    let isPrimary: Bool

    var systemImageName: String {
        isFlagged ? "flag.fill" : (isPrimary
            ? WorkspaceSidebarRowIcon.primaryWorktree.systemImageName
            : WorkspaceSidebarRowIcon.worktree.systemImageName)
    }

    var titleColor: Color { isFlagged ? Self.flagColor : .primary }
}

enum WorktreeMenuAction: Equatable, Identifiable {
    case setFlagged(WorktreeFlagKey?, Bool)
    case setChangesExpanded(Bool)
    case killSession
    case removeWorktree

    var id: String {
        switch self {
        case .setFlagged: "flag"
        case .setChangesExpanded: "changes"
        case .killSession: "kill"
        case .removeWorktree: "remove"
        }
    }

    var title: String {
        switch self {
        case let .setFlagged(_, flagged): flagged ? "Flag Worktree" : "Unflag Worktree"
        case let .setChangesExpanded(expanded): expanded ? "Show Changes" : "Hide Changes"
        case .killSession: "Kill Session…"
        case .removeWorktree: "Remove Worktree…"
        }
    }

    var isEnabled: Bool {
        if case let .setFlagged(key, _) = self {
            return key != nil
        }
        return true
    }

    var isDestructive: Bool {
        self == .killSession || self == .removeWorktree
    }

    static func groups(
        flagKey: WorktreeFlagKey?,
        isFlagged: Bool,
        isExpanded: Bool,
        canKill: Bool,
        canRemove: Bool
    ) -> [[Self]] {
        var groups: [[Self]] = [[
            .setFlagged(flagKey, !isFlagged), .setChangesExpanded(!isExpanded),
        ]]
        var destructive: [Self] = []
        if canKill {
            destructive.append(.killSession)
        }
        if canRemove {
            destructive.append(.removeWorktree)
        }
        if !destructive.isEmpty {
            groups.append(destructive)
        }
        return groups
    }
}

enum WorkspaceSidebarRowAction: Hashable {
    case killTmuxSession(WorkspaceTmuxSessionSelection)
    case stopHerdrSession(WorkspaceHerdrSessionSelection)
    case restartHerdrSession(WorkspaceHerdrSessionSelection)
    case deleteHerdrSession(WorkspaceHerdrSessionSelection)
    case killZellijSession(WorkspaceZellijSessionSelection)
}

enum WorkspaceSidebarRowActionModel {
    static func actions(
        for row: WorkspaceSidebarRow,
        in snapshot: WorkspaceSnapshot,
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeTmuxSessionIsConnected: Bool = false,
        pendingHerdrSessions: Set<WorkspaceHerdrSessionSelection> = []
    ) -> [WorkspaceSidebarRowAction] {
        if case let .herdrSession(hostID, name, backend) = row.target {
            let selection = WorkspaceHerdrSessionSelection(
                hostID: hostID,
                name: name, backend: backend
            )
            guard backend == .tui, !pendingHerdrSessions.contains(selection),
                  let session = snapshot.host(id: hostID)?.herdrSessions
                  .first(where: { $0.matches(selection) })
            else { return [] }
            switch session.state {
            case .running:
                return [.stopHerdrSession(selection)]
            case .stopped:
                return session.isDefault
                    ? [.restartHerdrSession(selection)]
                    : [
                        .restartHerdrSession(selection),
                        .deleteHerdrSession(selection),
                    ]
            }
        }
        if case let .zellijSession(hostID, name) = row.target {
            let selection = WorkspaceZellijSessionSelection(
                hostID: hostID,
                name: name
            )
            guard snapshot.host(id: hostID)?.zellijSessions.contains(
                where: { $0.name == name }
            ) == true else { return [] }
            return [.killZellijSession(selection)]
        }
        guard case let .tmuxSession(hostID, name, socketName) = row.target else {
            return []
        }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: name,
            socketName: socketName
        )
        guard WorkspaceSidebarModel.canRequestKill(
            selection,
            in: snapshot,
            activeSelection: activeTmuxSession,
            activeSelectionIsConnected: activeTmuxSessionIsConnected
        ) else { return [] }
        return [.killTmuxSession(selection)]
    }
}

enum WorkspaceSidebarHierarchy {
    private static let step: CGFloat = 14

    static func indent(level: Int) -> CGFloat {
        CGFloat(max(0, level)) * step
    }
}

struct WorkspaceWorktreeDisclosurePresentation: Equatable {
    let leadingIndent: CGFloat
    let contentIndentLevel: Int

    init(rowIndentLevel: Int) {
        leadingIndent = WorkspaceSidebarHierarchy.indent(
            level: rowIndentLevel
        )
        contentIndentLevel = 0
    }
}
