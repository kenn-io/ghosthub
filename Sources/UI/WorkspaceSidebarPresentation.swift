import Foundation
import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubWorkspace
import SwiftUI

struct TmuxSessionPreviewExpansionState: Equatable {
    private(set) var expandedSessionIDs: Set<String> = []

    func isExpanded(_ sessionID: String) -> Bool {
        expandedSessionIDs.contains(sessionID)
    }

    mutating func setExpanded(_ expanded: Bool, sessionID: String) {
        if expanded {
            expandedSessionIDs.insert(sessionID)
        } else {
            expandedSessionIDs.remove(sessionID)
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
    static let placeholderAspectRatio =
        TerminalPreviewGeometry.placeholderAspectRatio

    static func aspectRatio(for imageSize: CGSize?) -> CGFloat {
        TerminalPreviewGeometry.aspectRatio(for: imageSize)
    }

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
        ) && expansion.isExpanded(sessionID)
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
    static let controlWidth: CGFloat = 30

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

struct WorkspaceWorktreeRemovalActionPresentation: Equatable {
    static let controlWidth: CGFloat = 30

    let isVisible: Bool
    let reservedWidth: CGFloat
    let hitTargetWidth: CGFloat

    init(
        isRemovable: Bool,
        isRowHovered: Bool,
        isActionHovered: Bool
    ) {
        isVisible = isRemovable
            && (isRowHovered || isActionHovered)
        reservedWidth = isRemovable ? Self.controlWidth : 0
        hitTargetWidth = isRemovable ? Self.controlWidth : 0
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

struct WorktreeRowLine: View {
    let title: String
    let status: WorktreeRowStatus

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            WorktreeStatusCluster(status: status)
        }
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
    static func allowsInlineControl(
        for target: WorkspaceNavigationTarget
    ) -> Bool {
        if case .worktree = target {
            return false
        }
        return true
    }

    static func actions(
        for row: WorkspaceSidebarRow,
        in snapshot: WorkspaceSnapshot,
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeTmuxSessionIsConnected: Bool = false,
        pendingHerdrSessions: Set<WorkspaceHerdrSessionSelection> = []
    ) -> [WorkspaceSidebarRowAction] {
        if case let .herdrSession(hostID, name) = row.target {
            let selection = WorkspaceHerdrSessionSelection(
                hostID: hostID,
                name: name
            )
            guard !pendingHerdrSessions.contains(selection),
                  let session = snapshot.host(id: hostID)?.herdrSessions
                  .first(where: { $0.name == name })
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
        guard case let .tmuxSession(hostID, name) = row.target else {
            return []
        }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: name
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

enum WorkspaceSidebarInventorySection: Hashable {
    case tmuxSessions
    case herdrSessions
    case zellijSessions
    case projects
}

struct WorkspaceSidebarSectionAction {
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let help: String
    let perform: () -> Void
}

enum WorkspaceSidebarSectionActionModel {
    static func isVisible(
        _ section: WorkspaceSidebarInventorySection,
        host: HostSummary,
        hasProjects: Bool
    ) -> Bool {
        switch section {
        case .tmuxSessions:
            true
        case .herdrSessions:
            host.herdrAvailable
        case .zellijSessions:
            host.zellijAvailable
        case .projects:
            hasProjects || host.canRegisterProjects
        }
    }

    static func action(
        for section: WorkspaceSidebarInventorySection,
        host: HostSummary,
        onNewTmuxSession: @escaping (HostSummary) -> Void,
        onNewHerdrSession: @escaping (HostSummary) -> Void,
        onNewZellijSession: @escaping (HostSummary) -> Void,
        onAddProject: @escaping (HostSummary) -> Void
    ) -> WorkspaceSidebarSectionAction? {
        switch section {
        case .tmuxSessions:
            return WorkspaceSidebarSectionAction(
                accessibilityIdentifier:
                "sidebar-section-action-tmux-\(host.id.uuidString)",
                accessibilityLabel:
                "New tmux session on \(host.sidebarTitle)",
                help: "New tmux session…",
                perform: { onNewTmuxSession(host) }
            )
        case .herdrSessions:
            guard host.herdrAvailable else { return nil }
            return WorkspaceSidebarSectionAction(
                accessibilityIdentifier:
                "sidebar-section-action-herdr-\(host.id.uuidString)",
                accessibilityLabel:
                "New Herdr session on \(host.sidebarTitle)",
                help: "New Herdr session…",
                perform: { onNewHerdrSession(host) }
            )
        case .zellijSessions:
            guard host.zellijAvailable else { return nil }
            return WorkspaceSidebarSectionAction(
                accessibilityIdentifier:
                "sidebar-section-action-zellij-\(host.id.uuidString)",
                accessibilityLabel:
                "New Zellij session on \(host.sidebarTitle)",
                help: "New Zellij session…",
                perform: { onNewZellijSession(host) }
            )
        case .projects:
            guard host.canRegisterProjects else { return nil }
            return WorkspaceSidebarSectionAction(
                accessibilityIdentifier:
                "sidebar-section-action-projects-\(host.id.uuidString)",
                accessibilityLabel:
                "Add project on \(host.sidebarTitle)",
                help: "Add Project…",
                perform: { onAddProject(host) }
            )
        }
    }
}
