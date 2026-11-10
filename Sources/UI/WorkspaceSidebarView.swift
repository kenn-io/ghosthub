import Foundation
import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubWorkspace
import SwiftUI

private struct ProjectRemovalButton: View {
    let project: ProjectSummary
    let isRowHovered: Bool
    let onRemove: (ProjectSummary) -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        let presentation = WorkspaceProjectRemovalActionPresentation(
            isRemovable: true,
            isRowHovered: isRowHovered,
            isActionHovered: isHovered,
            isFocused: isFocused
        )
        Button {
            onRemove(project)
        } label: {
            ZStack {
                Color.clear
                if presentation.isVisible {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(
                width: presentation.hitTargetWidth,
                height: 30
            )
            .background {
                if presentation.isVisible {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            Color.primary.opacity(
                                isHovered ? 0.14 : 0.05
                            )
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help("Remove Project…")
        .accessibilityLabel(
            "Remove project \(project.sidebarTitle)"
        )
    }
}

private enum WorkspaceSidebarDragItem: Equatable {
    case host(String)
    case worktree(UUID)
    case tmuxSession(hostID: UUID, name: String, socketName: String?)
    case herdrSession(hostID: UUID, name: String, backend: HerdrBackend = .tui)
    case zellijSession(hostID: UUID, name: String)

    init?(rawValue: String) {
        if rawValue.hasPrefix("host:") {
            let id = String(rawValue.dropFirst(5))
            guard !id.isEmpty else { return nil }
            self = .host(id)
            return
        }
        let parts = rawValue.split(
            separator: ":",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard let kind = parts.first else { return nil }
        switch kind {
        case "worktree":
            guard parts.count == 2,
                  let id = UUID(uuidString: String(parts[1]))
            else { return nil }
            self = .worktree(id)
        case "tmux":
            guard parts.count == 3,
                  let hostID = UUID(uuidString: String(parts[1]))
            else { return nil }
            let endpoint = parts[2].split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard endpoint.count == 2 else { return nil }
            self = .tmuxSession(
                hostID: hostID,
                name: String(endpoint[1]),
                socketName: endpoint[0].isEmpty ? nil : String(endpoint[0])
            )
        case "herdr", "herdr-core":
            guard parts.count == 3,
                  let hostID = UUID(uuidString: String(parts[1]))
            else { return nil }
            self = .herdrSession(
                hostID: hostID,
                name: String(parts[2]),
                backend: kind == "herdr-core" ? .core : .tui
            )
        case "zellij":
            guard parts.count == 3,
                  let hostID = UUID(uuidString: String(parts[1]))
            else { return nil }
            self = .zellijSession(
                hostID: hostID,
                name: String(parts[2])
            )
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case let .host(id):
            return "host:\(id)"
        case let .worktree(id):
            return "worktree:\(id.uuidString)"
        case let .tmuxSession(hostID, name, socketName):
            return "tmux:\(hostID.uuidString):\(socketName ?? ""):\(name)"
        case let .herdrSession(hostID, name, backend):
            return WorkspaceSidebarModel.herdrSessionOrderID(
                hostID: hostID,
                name: name,
                backend: backend
            )
        case let .zellijSession(hostID, name):
            return "zellij:\(hostID.uuidString):\(name)"
        }
    }

    var orderID: String {
        switch self {
        case let .host(id):
            return id
        case let .worktree(id):
            return id.uuidString
        case let .tmuxSession(hostID, name, socketName):
            return WorkspaceSidebarModel.tmuxSessionOrderID(
                hostID: hostID,
                name: name,
                socketName: socketName
            )
        case let .herdrSession(hostID, name, backend):
            return WorkspaceSidebarModel.herdrSessionOrderID(
                hostID: hostID,
                name: name, backend: backend
            )
        case let .zellijSession(hostID, name):
            return WorkspaceSidebarModel.zellijSessionOrderID(
                hostID: hostID,
                name: name
            )
        }
    }
}

private struct WorkspaceSidebarReorderIndicator: Equatable {
    let item: WorkspaceSidebarDragItem
    let placement: WorkspaceSidebarDropPlacement
}

// MARK: - WorkspaceSidebarView

private struct WorktreeFlagContent<Content: View>: View {
    let state: WorktreeFlagState
    let content: (Bool) -> Content

    var body: some View {
        content(state.isFlagged)
    }
}

struct WorkspaceSidebarView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.terminalBackgroundAppearance)
    private var backgroundAppearance
    let snapshot: WorkspaceSnapshot
    let sectionCache: WorkspaceSidebarSectionCache?
    let snapshotRevision: UInt64
    private let worktreeFlagStore: WorktreeFlagStore
    private let onWorktreeFlagFailure: (WorktreeSummary, String) -> Void
    @Binding var selection: WorkspaceSelection
    let visibility: WorktreeVisibility
    let tmuxSessionVisibility: TmuxSessionVisibility
    let onOpen: (WorktreeSummary) -> Void
    let activeTmuxSession: WorkspaceTmuxSessionSelection?
    let activeHerdrSession: WorkspaceHerdrSessionSelection?
    let activeZellijSession: WorkspaceZellijSessionSelection?
    let activeTmuxSessionIsConnected: Bool
    let connectedTmuxSessionIDs: Set<String>
    let workingTmuxSessionIDs: Set<String>
    let agentAttentionByEndpoint: [String: AgentAttention]
    let tmuxWindowCountsBySessionID: [String: Int]
    let previewableTmuxSessionIDs: Set<String>
    let sessionPreviewMode: SessionPreviewMode
    let tmuxSessionPreviewBuilder:
        ((WorkspaceTmuxSessionSelection, @escaping () -> Void) -> AnyView?)?
    let onTmuxSessionPreviewExpanded:
        (WorkspaceTmuxSessionSelection, Bool) -> Void
    let onOpenTmuxSession:
        (WorkspaceTmuxSessionSelection, WorkspaceSelection) -> Void
    let onOpenHerdrSession: (WorkspaceHerdrSessionSelection) -> Void
    let onOpenZellijSession: (WorkspaceZellijSessionSelection) -> Void
    let pendingHerdrSessions: Set<WorkspaceHerdrSessionSelection>
    let onRestartHerdrSession: (WorkspaceHerdrSessionSelection) -> Void
    let onRequestHerdrSessionLifecycle:
        (WorkspaceHerdrSessionSelection, HerdrSessionDestructiveAction) -> Void
    let onNavigateAwayFromSession: () -> Void
    let onRequestKillTmuxSession: (WorkspaceTmuxSessionSelection) -> Void
    let onRequestRenameTmuxSession: (WorkspaceTmuxSessionSelection) -> Void
    let onRequestKillZellijSession: (WorkspaceZellijSessionSelection) -> Void
    let onRequestRemoveWorktree: (WorktreeSummary) -> Void
    let isWorktreeChangesPollingEligible: Bool
    let currentSnapshot: @MainActor () -> WorkspaceSnapshot
    let loadWorktreeChanges: WorktreeChangesLoader?
    let worktreeChangesSleep: WorktreeChangesSleep
    let onRequestRemoveProject: (ProjectSummary) -> Void
    let onLocateProject: (ProjectSummary) -> Void
    let onOpenProjectWorktreesAsTabs:
        (ProjectSummary, [WorktreeSummary]) -> Void
    let canOpenProjectWorktreesAsTabs:
        (ProjectSummary, [WorktreeSummary]) -> Bool
    let onNewWorktree: (ProjectSummary) -> Void
    let onImportPullRequest: (ProjectSummary) -> Void
    let onNewTmuxSession: (HostSummary) -> Void
    let onNewHerdrSession: (HostSummary) -> Void
    let onNewZellijSession: (HostSummary) -> Void
    let onAddProject: (HostSummary) -> Void
    let onRefreshInventory: () -> Void
    let onOpenHostSettings: () -> Void
    let onReviewSSHHostKey: (UUID, String) -> Void
    let inventoryWarning: String?
    let inventoryWarningsByHost: [UUID: String]
    let inventoryRefreshComplete: Bool
    @State private var presentedInventoryWarning:
        PresentedInventoryWarning?
    @State private var hoveredSessionActionRowID: WorkspaceNavigationTarget?
    @State private var hoveredSessionActionControlRowID:
        WorkspaceNavigationTarget?
    @State private var sessionActionHoverDismissTask: Task<Void, Never>?
    @State private var hoveredWorktreeID: UUID?
    @State private var hoveredWorktreeActionID: UUID?
    @FocusState private var focusedWorktreeActionID: UUID?
    @State private var worktreeHoverDismissTask: Task<Void, Never>?
    @State private var worktreeChanges = WorktreeChangesStore()
    @State private var hoveredProjectID: UUID?
    @State private var draggedSidebarItem: WorkspaceSidebarDragItem?
    @State private var reorderIndicator:
        WorkspaceSidebarReorderIndicator?
    @State private var tmuxPreviewExpansion =
        TmuxSessionPreviewExpansionState()
    @State private var tmuxPreviewMountState = TmuxSessionPreviewMountState()
    @State private var disclosureState = WorkspaceSidebarDisclosureState()
    @State private var hoveredHostID: UUID?
    @Binding private var hostOrderRawValue: String
    @Binding private var worktreeOrderRawValue: String
    @Binding private var sessionOrderRawValue: String
    let sidebarPreferences: SidebarPreferences
    let onSetSessionSort: (SidebarSessionSort) -> Void

    init(
        snapshot: WorkspaceSnapshot,
        sectionCache: WorkspaceSidebarSectionCache? = nil,
        snapshotRevision: UInt64 = 0,
        worktreeFlagStore: WorktreeFlagStore = .shared,
        selection: Binding<WorkspaceSelection>,
        visibility: WorktreeVisibility,
        tmuxSessionVisibility: TmuxSessionVisibility = TmuxSessionVisibility(),
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeHerdrSession: WorkspaceHerdrSessionSelection? = nil,
        activeZellijSession: WorkspaceZellijSessionSelection? = nil,
        activeTmuxSessionIsConnected: Bool = false,
        connectedTmuxSessionIDs: Set<String> = [],
        workingTmuxSessionIDs: Set<String> = [],
        agentAttentionByEndpoint: [String: AgentAttention] = [:],
        tmuxWindowCountsBySessionID: [String: Int] = [:],
        previewableTmuxSessionIDs: Set<String> = [],
        sessionPreviewMode: SessionPreviewMode = .off,
        tmuxSessionPreviewBuilder:
        ((WorkspaceTmuxSessionSelection, @escaping () -> Void) -> AnyView?)? = nil,
        onTmuxSessionPreviewExpanded: @escaping (
            WorkspaceTmuxSessionSelection,
            Bool
        ) -> Void = { _, _ in },
        onOpenTmuxSession: @escaping (
            WorkspaceTmuxSessionSelection,
            WorkspaceSelection
        ) -> Void = { _, _ in },
        onOpenHerdrSession: @escaping (
            WorkspaceHerdrSessionSelection
        ) -> Void = { _ in },
        onOpenZellijSession: @escaping (
            WorkspaceZellijSessionSelection
        ) -> Void = { _ in },
        pendingHerdrSessions: Set<WorkspaceHerdrSessionSelection> = [],
        onRestartHerdrSession: @escaping (
            WorkspaceHerdrSessionSelection
        ) -> Void = { _ in },
        onRequestHerdrSessionLifecycle: @escaping (
            WorkspaceHerdrSessionSelection,
            HerdrSessionDestructiveAction
        ) -> Void = { _, _ in },
        onNavigateAwayFromSession: @escaping () -> Void = {},
        onRequestKillTmuxSession: @escaping (
            WorkspaceTmuxSessionSelection
        ) -> Void = { _ in },
        onRequestRenameTmuxSession: @escaping (
            WorkspaceTmuxSessionSelection
        ) -> Void = { _ in },
        onRequestKillZellijSession: @escaping (
            WorkspaceZellijSessionSelection
        ) -> Void = { _ in },
        onRequestRemoveWorktree: @escaping (
            WorktreeSummary
        ) -> Void = { _ in },
        isWorktreeChangesPollingEligible: Bool = false,
        currentSnapshot: (@MainActor () -> WorkspaceSnapshot)? = nil,
        loadWorktreeChanges: WorktreeChangesLoader? = nil,
        worktreeChangesSleep: @escaping WorktreeChangesSleep = {
            try await Task.sleep(for: $0)
        },
        onRequestRemoveProject: @escaping (
            ProjectSummary
        ) -> Void = { _ in },
        onLocateProject: @escaping (ProjectSummary) -> Void = { _ in },
        onOpenProjectWorktreesAsTabs: @escaping (
            ProjectSummary,
            [WorktreeSummary]
        ) -> Void = { _, _ in },
        canOpenProjectWorktreesAsTabs: @escaping (
            ProjectSummary,
            [WorktreeSummary]
        ) -> Bool = { _, _ in false },
        onNewWorktree: @escaping (ProjectSummary) -> Void = { _ in },
        onImportPullRequest: @escaping (ProjectSummary) -> Void = { _ in },
        onNewTmuxSession: @escaping (HostSummary) -> Void = { _ in },
        onNewHerdrSession: @escaping (HostSummary) -> Void = { _ in },
        onNewZellijSession: @escaping (HostSummary) -> Void = { _ in },
        onAddProject: @escaping (HostSummary) -> Void = { _ in },
        onRefreshInventory: @escaping () -> Void = {},
        onOpenHostSettings: @escaping () -> Void = {},
        onReviewSSHHostKey: @escaping (UUID, String) -> Void = { _, _ in },
        inventoryWarning: String? = nil,
        inventoryWarningsByHost: [UUID: String] = [:],
        inventoryRefreshComplete: Bool = false,
        hostOrderRawValue: Binding<String> = .constant(WorkspaceSidebarOrderStorage
            .defaultHostOrder),
        worktreeOrderRawValue: Binding<String> = .constant(""),
        sessionOrderRawValue: Binding<String> = .constant(""),
        sidebarPreferences: SidebarPreferences = SidebarPreferences(),
        onSetSessionSort: @escaping (SidebarSessionSort) -> Void = { _ in },
        onWorktreeFlagFailure: @escaping (WorktreeSummary, String) -> Void = { _, _ in },
        onOpen: @escaping (WorktreeSummary) -> Void = { _ in }
    ) {
        self.worktreeFlagStore = worktreeFlagStore
        self.onWorktreeFlagFailure = onWorktreeFlagFailure
        self.snapshot = snapshot
        self.sectionCache = sectionCache
        self.snapshotRevision = snapshotRevision
        _selection = selection
        self.visibility = visibility
        self.tmuxSessionVisibility = tmuxSessionVisibility
        self.activeTmuxSession = activeTmuxSession
        self.activeHerdrSession = activeHerdrSession
        self.activeZellijSession = activeZellijSession
        self.activeTmuxSessionIsConnected = activeTmuxSessionIsConnected
        self.connectedTmuxSessionIDs = connectedTmuxSessionIDs
        self.workingTmuxSessionIDs = workingTmuxSessionIDs
        self.agentAttentionByEndpoint = agentAttentionByEndpoint
        self.tmuxWindowCountsBySessionID = tmuxWindowCountsBySessionID
        self.previewableTmuxSessionIDs = previewableTmuxSessionIDs
        self.sessionPreviewMode = sessionPreviewMode
        self.tmuxSessionPreviewBuilder = tmuxSessionPreviewBuilder
        self.onTmuxSessionPreviewExpanded = onTmuxSessionPreviewExpanded
        self.onOpenTmuxSession = onOpenTmuxSession
        self.onOpenHerdrSession = onOpenHerdrSession
        self.onOpenZellijSession = onOpenZellijSession
        self.pendingHerdrSessions = pendingHerdrSessions
        self.onRestartHerdrSession = onRestartHerdrSession
        self.onRequestHerdrSessionLifecycle = onRequestHerdrSessionLifecycle
        self.onNavigateAwayFromSession = onNavigateAwayFromSession
        self.onRequestKillTmuxSession = onRequestKillTmuxSession
        self.onRequestRenameTmuxSession = onRequestRenameTmuxSession
        self.onRequestKillZellijSession = onRequestKillZellijSession
        self.onRequestRemoveWorktree = onRequestRemoveWorktree
        self.isWorktreeChangesPollingEligible =
            isWorktreeChangesPollingEligible
        self.currentSnapshot = currentSnapshot ?? { snapshot }
        self.loadWorktreeChanges = loadWorktreeChanges
        self.worktreeChangesSleep = worktreeChangesSleep
        self.onRequestRemoveProject = onRequestRemoveProject
        self.onLocateProject = onLocateProject
        self.onOpenProjectWorktreesAsTabs = onOpenProjectWorktreesAsTabs
        self.canOpenProjectWorktreesAsTabs =
            canOpenProjectWorktreesAsTabs
        self.onNewWorktree = onNewWorktree
        self.onImportPullRequest = onImportPullRequest
        self.onNewTmuxSession = onNewTmuxSession
        self.onNewHerdrSession = onNewHerdrSession
        self.onNewZellijSession = onNewZellijSession
        self.onAddProject = onAddProject
        self.onRefreshInventory = onRefreshInventory
        self.onOpenHostSettings = onOpenHostSettings
        self.onReviewSSHHostKey = onReviewSSHHostKey
        self.inventoryWarning = inventoryWarning
        self.inventoryWarningsByHost = inventoryWarningsByHost
        self.inventoryRefreshComplete = inventoryRefreshComplete
        _hostOrderRawValue = hostOrderRawValue
        _worktreeOrderRawValue = worktreeOrderRawValue
        _sessionOrderRawValue = sessionOrderRawValue
        self.sidebarPreferences = sidebarPreferences
        self.onSetSessionSort = onSetSessionSort
        self.onOpen = onOpen
    }

    // MARK: - Computed

    private var sections: [WorkspaceSidebarSection] {
        if let sectionCache {
            sectionCache.sections(
                in: snapshot,
                snapshotRevision: snapshotRevision,
                visibility: visibility,
                tmuxSessionVisibility: tmuxSessionVisibility,
                connectedTmuxSessionIDs: connectedTmuxSessionIDs,
                liveTmuxWindowCounts: tmuxWindowCountsBySessionID,
                hostOrderRawValue: hostOrderRawValue,
                worktreeOrderRawValue: worktreeOrderRawValue,
                sessionOrderRawValue: sessionOrderRawValue,
                sessionSort: sidebarPreferences.sessionSort,
                agentAttentionByEndpoint: agentAttentionByEndpoint
            )
        } else {
            WorkspaceSidebarModel.sections(
                in: snapshot,
                visibility: visibility,
                tmuxSessionVisibility: tmuxSessionVisibility,
                connectedTmuxSessionIDs: connectedTmuxSessionIDs,
                liveTmuxWindowCounts: tmuxWindowCountsBySessionID,
                hostOrderRawValue: hostOrderRawValue,
                worktreeOrderRawValue: worktreeOrderRawValue,
                sessionOrderRawValue: sessionOrderRawValue,
                sessionSort: sidebarPreferences.sessionSort,
                agentAttentionByEndpoint: agentAttentionByEndpoint
            )
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(sections) { section in
                            hostSection(section)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .padding(.horizontal, 8)
                }
            }
        }
        .onChange(of: inventoryRefreshComplete) { _, isComplete in
            if isComplete {
                pruneSidebarOrders()
            }
        }
        .alert(
            "Workspace Inventory Issue",
            isPresented: inventoryWarningIsPresented,
            presenting: presentedInventoryWarning
        ) { warning in
            if warning.isHostScoped {
                Button("Host Settings") {
                    onOpenHostSettings()
                }
            }
            Button("Retry") {
                onRefreshInventory()
            }
            Button("Dismiss", role: .cancel) {}
        } message: { warning in
            Text(warning.message)
        }
    }

    private func hostSection(_ section: WorkspaceSidebarSection) -> some View {
        let hostKey = WorkspaceSidebarDisclosureState.host(section.host.id)
        let item = WorkspaceSidebarDragItem.host(
            WorkspaceSidebarModel.hostOrderID(section.host)
        )
        return reorderableRow(
            VStack(alignment: .leading, spacing: 1) {
                hostHeader(section, disclosureKey: hostKey)
                    .onDrag {
                        draggedSidebarItem = item
                        return NSItemProvider(object: item.rawValue as NSString)
                    }
                    .accessibilityAction(named: "Move host up") {
                        moveHost(section.host, by: -1)
                    }
                    .accessibilityAction(named: "Move host down") {
                        moveHost(section.host, by: 1)
                    }
                hostContents(section, disclosureKey: hostKey)
            },
            item: item,
            groupItems: sections.map { .host(WorkspaceSidebarModel.hostOrderID($0.host)) },
            orderRawValue: hostOrderRawValue,
            allowsDragging: false
        ) { hostOrderRawValue = $0 }
    }

    private func moveHost(_ host: HostSummary, by offset: Int) {
        let ids = sections.map { WorkspaceSidebarModel.hostOrderID($0.host) }
        let id = WorkspaceSidebarModel.hostOrderID(host)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset)
        else { return }
        var order = WorkspaceSidebarOrder(rawValue: hostOrderRawValue)
        if order.move(id, to: ids[index + offset], within: ids) {
            hostOrderRawValue = order.rawValue
        }
    }

    /// Host name, dimmed detail, and connection dot. The disclosure chevron
    /// and + menu appear on hover; the chevron stays while collapsed.
    private func hostHeader(
        _ section: WorkspaceSidebarSection,
        disclosureKey: String
    ) -> some View {
        let host = section.host
        let expanded = isExpanded(disclosureKey)
        let isHovered = hoveredHostID == host.id
        let warning = inventoryWarningsByHost[host.id]
        let isSelected = Self.isRowSelected(
            section.row,
            selection: selection,
            activeTmuxSession: activeTmuxSession,
            activeHerdrSession: activeHerdrSession,
            activeZellijSession: activeZellijSession
        )
        return HStack(spacing: 4) {
            Button {
                toggle(disclosureKey)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 26)
                    .contentShape(Rectangle())
                    .opacity(isHovered || !expanded ? 1 : 0)
            }
            .buttonStyle(.plain)
            .workspaceAccessibility(
                WorkspaceAccessibilityModel.disclosureDescriptor(
                    title: host.sidebarTitle,
                    isExpanded: expanded
                )
            )
            .accessibilityIdentifier("sidebar-host-disclosure-\(host.id.uuidString)")

            Button {
                onNavigateAwayFromSession()
                selection.select(
                    section.row.target,
                    in: snapshot,
                    visibility: visibility
                )
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            warning == nil && host.lastKnownReachable
                                ? Color.green : Color.orange
                        )
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(host.sidebarTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(
                            colorSchemeContrast == .increased || isSelected
                                ? Color.primary : Color.secondary
                        )
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let subtitle = host.sidebarSubtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .frame(height: 26)
                .background { SidebarRowSelectionBackground(isSelected: isSelected) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .workspaceAccessibility(
                WorkspaceAccessibilityModel.descriptor(
                    for: section.row,
                    isSelected: isSelected
                )
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("sidebar-host-\(host.id.uuidString)")

            if let warning {
                inventoryWarningButton(
                    warning,
                    host: host,
                    accessibilityLabel:
                    "Show connection issue for \(host.sidebarTitle)"
                )
            }

            hostMenuButton(host)
                .opacity(isHovered ? 1 : 0)
        }
        .onHover { hovering in
            if hovering {
                hoveredHostID = host.id
            } else if hoveredHostID == host.id {
                hoveredHostID = nil
            }
        }
        .contextMenu {
            ForEach(
                Array(WorkspaceSidebarHostMenuModel.entries(for: host).enumerated()),
                id: \.offset
            ) { index, group in
                if index > 0 {
                    Divider()
                }
                ForEach(group, id: \.title) { entry in
                    Button(entry.title) {
                        performHostMenuItem(entry.item, host: host)
                    }
                    .disabled(!entry.isEnabled)
                }
            }
        }
    }

    private func hostMenuButton(_ host: HostSummary) -> some View {
        NativePopupMenuButton(
            groups: WorkspaceSidebarHostMenuModel.entries(for: host).map { group in
                group.map { entry in
                    NativePopupMenuAction(
                        entry.title,
                        isEnabled: entry.isEnabled,
                        help: entry.help
                    ) {
                        performHostMenuItem(entry.item, host: host)
                    }
                }
            }
        ) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("New on \(host.sidebarTitle)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New session or project…")
        .accessibilityIdentifier("sidebar-host-menu-\(host.id.uuidString)")
    }

    private func performHostMenuItem(
        _ item: WorkspaceSidebarHostMenuItem,
        host: HostSummary
    ) {
        switch item {
        case .newTmuxSession: onNewTmuxSession(host)
        case .newZellijSession: onNewZellijSession(host)
        case .newHerdrSession: onNewHerdrSession(host)
        case .addProject: onAddProject(host)
        }
    }

    @ViewBuilder
    private func hostContents(
        _ section: WorkspaceSidebarSection,
        disclosureKey: String
    ) -> some View {
        if isExpanded(disclosureKey) {
            VStack(alignment: .leading, spacing: 1) {
                let groupItems = sidebarDragItems(section.sessionRows)
                let rows = ForEach(section.sessionRows) { row in
                    sessionButton(row, groupItems: groupItems)
                }
                if sessionPreviewMode == .off {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        rows
                    }
                } else {
                    rows
                }
                if !section.projects.isEmpty
                    || !section.directoryWorkspaceRows.isEmpty {
                    projectsGroup(section)
                }
            }
        }
    }

    @ViewBuilder
    private func projectsGroup(_ section: WorkspaceSidebarSection) -> some View {
        let projectsKey = WorkspaceSidebarDisclosureState
            .projects(section.host.id)
        let expanded = isExpanded(projectsKey)
        Button {
            toggle(projectsKey)
        } label: {
            HStack(spacing: 4) {
                Text("Projects")
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(
                colorSchemeContrast == .increased
                    ? Color.secondary : Color(nsColor: .tertiaryLabelColor)
            )
            .padding(.leading, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .workspaceAccessibility(
            WorkspaceAccessibilityModel.disclosureDescriptor(
                title: "Projects",
                isExpanded: expanded
            )
        )
        .accessibilityIdentifier("sidebar-section-disclosure-\(projectsKey)")
        if expanded {
            ForEach(section.projects) { project in
                projectGroup(project)
            }
            ForEach(section.directoryWorkspaceRows) { row in
                tmuxPreviewRow(
                    row,
                    content: AnyView(sidebarButton(row))
                )
            }
        }
    }

    @ViewBuilder
    private func projectGroup(_ project: WorkspaceSidebarProject) -> some View {
        let projectKey = WorkspaceSidebarDisclosureState
            .project(project.project.id)
        projectHierarchyRow(project, disclosureKey: projectKey)
            .contextMenu {
                Button("New Worktree…") {
                    onNewWorktree(project.project)
                }
                .disabled(!snapshot.canCreateWorktree(in: project.project))
                Button("Import Pull Request…") {
                    onImportPullRequest(project.project)
                }
                .disabled(!snapshot.canImportPullRequest(in: project.project))
                Divider()
                Button("Open All Worktrees as Tabs") {
                    onOpenProjectWorktreesAsTabs(
                        project.project,
                        project.worktrees
                    )
                }
                .disabled(
                    !canOpenProjectWorktreesAsTabs(
                        project.project,
                        project.worktrees
                    )
                )
                if snapshot.host(id: project.project.hostID)?
                    .canRegisterProjects == true {
                    Divider()
                    if project.project.pathIssue != nil {
                        Button("Locate Folder…") {
                            onLocateProject(project.project)
                        }
                    }
                    Button("Remove Project…", role: .destructive) {
                        onRequestRemoveProject(project.project)
                    }
                }
            }
        if isExpanded(projectKey) {
            let groupItems = sidebarDragItems(project.worktreeRows)
            let rows = ForEach(project.worktreeRows) { row in
                worktreeButton(row, groupItems: groupItems)
            }
            if sessionPreviewMode == .off {
                LazyVStack(alignment: .leading, spacing: 1) {
                    rows
                }
            } else {
                // Preview mounts control capture and parking eligibility;
                // retain them while expanded, including offscreen tiles.
                VStack(alignment: .leading, spacing: 1) {
                    rows
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Workspaces")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if let inventoryWarning {
                Button {
                    resolveInventoryWarning(
                        inventoryWarning,
                        host: nil
                    )
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show workspace inventory issue")
                .accessibilityLabel("Show workspace inventory issue")
                .accessibilityValue(inventoryWarning)
            }
            sessionSortMenu
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private var sessionSortMenu: some View {
        Menu {
            Picker(
                "Sort Sessions By",
                selection: Binding(
                    get: { sidebarPreferences.sessionSort },
                    set: { onSetSessionSort($0) }
                )
            ) {
                ForEach(SidebarSessionSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(sidebarPreferences.sessionSort.title, systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Sort sessions")
        .accessibilityLabel("Sort sessions")
        .accessibilityValue(sidebarPreferences.sessionSort.title)
        .accessibilityIdentifier("sidebar-session-sort")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No kwt projects, directory workspaces, or tmux sessions")
                .font(.callout.weight(.semibold))
            Text(
                "Register a project or directory in kwt, or start a tmux session, then refresh Ghosthub."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }

    // MARK: - Row builders

    private func sidebarDragItems(_ rows: [WorkspaceSidebarRow]) -> [WorkspaceSidebarDragItem] {
        let items: [WorkspaceSidebarDragItem] = rows.compactMap { row in
            switch row.target {
            case let .worktree(id): .worktree(id)
            case let .tmuxSession(hostID, name, socketName): .tmuxSession(
                    hostID: hostID,
                    name: name,
                    socketName: socketName
                )
            case let .herdrSession(hostID, name, backend): .herdrSession(
                    hostID: hostID,
                    name: name,
                    backend: backend
                )
            case let .zellijSession(hostID, name): .zellijSession(hostID: hostID, name: name)
            default: nil
            }
        }
        RenderWorkCounters.countSidebarDragItems(items.count)
        return items
    }

    /// One session row of any backend. Dragging reorders the host's shared
    /// session list and is available only in the Manual sort.
    private func sessionButton(
        _ row: WorkspaceSidebarRow,
        groupItems: [WorkspaceSidebarDragItem]
    ) -> AnyView {
        let item: WorkspaceSidebarDragItem? = switch row.target {
        case let .tmuxSession(hostID, name, socketName):
            .tmuxSession(hostID: hostID, name: name, socketName: socketName)
        case let .herdrSession(hostID, name, backend):
            .herdrSession(hostID: hostID, name: name, backend: backend)
        case let .zellijSession(hostID, name):
            .zellijSession(hostID: hostID, name: name)
        default:
            nil
        }
        guard let item else { return AnyView(sidebarButton(row)) }
        let content = AnyView(reorderableRow(
            sidebarButton(row),
            item: item,
            groupItems: groupItems,
            orderRawValue: sessionOrderRawValue,
            allowsDragging: sidebarPreferences.sessionSort == .manual
        ) { updatedRawValue in
            sessionOrderRawValue = updatedRawValue
        })
        guard case .tmuxSession = row.target else {
            return previewChevronSpacer(content)
        }
        return tmuxPreviewRow(row, content: content, reservesChevron: true)
    }

    /// Keeps names aligned with previewable rows while previews are on.
    private func previewChevronSpacer(_ content: AnyView) -> AnyView {
        guard sessionPreviewMode != .off else { return content }
        return AnyView(HStack(spacing: 0) {
            Color.clear.frame(width: 14)
            content
        })
    }

    private func sidebarButton(
        _ row: WorkspaceSidebarRow,
        reservedTrailingActionWidth: CGFloat = 0,
        isWorktreeFlagged: Bool = false
    ) -> some View {
        RenderWorkCounters.countSidebarRowEvaluation()
        let flagPresentation = WorktreeFlagPresentation(
            isFlagged: isWorktreeFlagged, isPrimary: row.icon == .primaryWorktree
        )
        let tmuxSession = tmuxSessionSelection(for: row)
        let ownsWorktreeActions = if case .worktree = row.target {
            true
        } else {
            false
        }
        let runningTmuxSession: WorkspaceTmuxSessionSelection? = tmuxSession.flatMap {
            guard !ownsWorktreeActions else { return nil }
            return WorkspaceSidebarModel.canRequestKill(
                $0,
                in: snapshot,
                activeSelection: activeTmuxSession,
                activeSelectionIsConnected:
                activeTmuxSessionIsConnected
            ) ? $0 : nil
        }
        let renamableTmuxSession = tmuxSession.flatMap {
            WorkspaceSidebarModel.canRequestRename($0, in: snapshot)
                ? $0 : nil
        }
        let herdrActions: [WorkspaceSidebarRowAction]
        if case .herdrSession = row.target {
            herdrActions = WorkspaceSidebarRowActionModel.actions(
                for: row,
                in: snapshot,
                pendingHerdrSessions: pendingHerdrSessions
            )
        } else {
            herdrActions = []
        }
        let herdrSelection: WorkspaceHerdrSessionSelection? = {
            guard case let .herdrSession(hostID, name, backend) = row.target else {
                return nil
            }
            return WorkspaceHerdrSessionSelection(hostID: hostID, name: name, backend: backend)
        }()
        let zellijSelection: WorkspaceZellijSessionSelection? = {
            guard case let .zellijSession(hostID, name) = row.target else {
                return nil
            }
            return WorkspaceZellijSessionSelection(hostID: hostID, name: name)
        }()
        let herdrOperationIsPending = herdrSelection.map {
            pendingHerdrSessions.contains($0)
        } ?? false
        let isSelected = Self.isRowSelected(
            row,
            selection: selection,
            rowTmuxSession: tmuxSession,
            activeTmuxSession: activeTmuxSession,
            activeHerdrSession: activeHerdrSession,
            activeZellijSession: activeZellijSession
        )
        let isTmuxSessionWorking = tmuxSession.map {
            workingTmuxSessionIDs.contains($0.id)
        } ?? false
        let agentAttention = tmuxSession.flatMap {
            agentAttentionByEndpoint[AgentAttentionStore.endpointKey(
                hostID: $0.hostID,
                name: $0.name,
                socketName: $0.socketName
            )]
        }
        let usesDirectKillAction: Bool
        if case .tmuxSession = row.target {
            usesDirectKillAction = true
        } else if case .zellijSession = row.target {
            usesDirectKillAction = true
        } else {
            usesDirectKillAction = false
        }
        let hasSessionActions = runningTmuxSession != nil
            || !herdrActions.isEmpty
            || zellijSelection != nil
        let isActionHovered = hasSessionActions
            && hoveredSessionActionControlRowID == row.id
        let actionPresentation = WorkspaceSessionActionPresentation(
            hasActions: hasSessionActions,
            isRowHovered: hoveredSessionActionRowID == row.id,
            isActionHovered: isActionHovered,
            isSelected: false
        )
        return HStack(spacing: 0) {
            Button {
                if case let .herdrSession(hostID, name, backend) = row.target {
                    let herdrSelection = WorkspaceHerdrSessionSelection(
                        hostID: hostID,
                        name: name, backend: backend
                    )
                    selection.select(
                        row.target,
                        in: snapshot,
                        visibility: visibility
                    )
                    if row.herdrSessionState == .stopped {
                        onRestartHerdrSession(herdrSelection)
                    } else {
                        onOpenHerdrSession(herdrSelection)
                    }
                    return
                }
                if case let .zellijSession(hostID, name) = row.target {
                    let zellijSelection = WorkspaceZellijSessionSelection(
                        hostID: hostID,
                        name: name
                    )
                    selection.select(
                        row.target,
                        in: snapshot,
                        visibility: visibility
                    )
                    onOpenZellijSession(zellijSelection)
                    return
                }
                if case let .tmuxSession(hostID, name, socketName) = row.target {
                    let tmuxSelection = WorkspaceTmuxSessionSelection(
                        hostID: hostID,
                        name: name,
                        socketName: socketName
                    )
                    Self.activateTmuxSession(
                        tmuxSelection,
                        rowTarget: row.target,
                        selection: $selection,
                        snapshot: snapshot,
                        visibility: visibility,
                        onOpen: onOpenTmuxSession
                    )
                    return
                }
                if case let .worktree(worktreeID) = row.target,
                   let worktree = snapshot.worktree(id: worktreeID),
                   let tmuxSelection = WorkspaceSidebarModel
                   .tmuxSessionSelection(for: worktree) {
                    Self.activateTmuxSession(
                        tmuxSelection,
                        rowTarget: row.target,
                        selection: $selection,
                        snapshot: snapshot,
                        visibility: visibility,
                        onOpen: onOpenTmuxSession
                    )
                    return
                }
                if case let .directoryWorkspace(directoryWorkspaceID) =
                    row.target,
                    let workspace = snapshot.directoryWorkspace(
                        id: directoryWorkspaceID
                    ) {
                    Self.activateTmuxSession(
                        WorkspaceSidebarModel.tmuxSessionSelection(
                            for: workspace
                        ),
                        rowTarget: row.target,
                        selection: $selection,
                        snapshot: snapshot,
                        visibility: visibility,
                        onOpen: onOpenTmuxSession
                    )
                    return
                }
                onNavigateAwayFromSession()
                selection.select(
                    row.target,
                    in: snapshot,
                    visibility: visibility
                )
            } label: {
                HStack(spacing: 6) {
                    if let backend = row.sessionBackend {
                        SidebarSessionRowContent(
                            title: row.title,
                            detail: row.sessionDetail,
                            backend: backend,
                            labelStyle: sidebarPreferences.backendLabelStyle,
                            agentAttention: agentAttention,
                            showsRecentOutput: isTmuxSessionWorking,
                            isStopped: row.herdrSessionState == .stopped,
                            isSelected: isSelected,
                            hidesBackendLabel: actionPresentation.isVisible,
                            trailingSlotWidth: actionPresentation.reservedWidth
                        )
                    } else {
                        if let status = row.worktreeStatus {
                            SidebarWorktreeRowContent(
                                title: row.title,
                                status: status,
                                titleColor: flagPresentation.titleColor,
                                isFlagged: isWorktreeFlagged
                            )
                        } else {
                            legacyRowContent(
                                title: row.title,
                                subtitle: row.subtitle,
                                sessionIsRunning: row.sessionIsRunning
                            )
                        }
                        if let agentAttention {
                            AgentStateBadge(attention: agentAttention)
                        } else if isTmuxSessionWorking {
                            tmuxSessionActivityIndicator
                        }
                    }
                    if isSelected, differentiateWithoutColor {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .padding(
                    .leading,
                    WorkspaceSidebarHierarchy.indent(
                        level: row.indentLevel
                    )
                )
                .padding(.horizontal, 8)
                .padding(.trailing, reservedTrailingActionWidth)
                .frame(minHeight: sidebarPreferences.rowHeight.points)
                .background {
                    SidebarRowSelectionBackground(isSelected: isSelected)
                }
            }
            .help(Self.rowHelp(row))
            .buttonStyle(.plain)
            .disabled(herdrOperationIsPending)
            .opacity(
                row.herdrSessionState == .stopped && !isSelected ? 0.68 : 1
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .workspaceAccessibility(
                WorkspaceAccessibilityModel.descriptor(
                    for: row,
                    isSelected: isSelected,
                    hasRecentTmuxOutput: isTmuxSessionWorking
                        && agentAttention == nil,
                    agentAttention: agentAttention,
                    isWorktreeFlagged: isWorktreeFlagged
                )
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .overlay(alignment: .trailing) {
            if hasSessionActions {
                Group {
                    if let tmuxSession = runningTmuxSession,
                       usesDirectKillAction {
                        Button {
                            onRequestKillTmuxSession(tmuxSession)
                        } label: {
                            sessionActionLabel(
                                actionPresentation,
                                isActionHovered: isActionHovered,
                                imageName: "xmark"
                            )
                        }
                        .accessibilityLabel(
                            "Kill tmux session \(tmuxSession.name)"
                        )
                        .accessibilityIdentifier(
                            "kill-tmux-session-\(tmuxSession.id)"
                        )
                    } else if let tmuxSession = runningTmuxSession {
                        NativePopupMenuButton(
                            groups: [
                                [
                                    NativePopupMenuAction(
                                        "Kill Session…",
                                        role: .destructive
                                    ) {
                                        onRequestKillTmuxSession(tmuxSession)
                                    },
                                ],
                            ]
                        ) {
                            sessionActionLabel(
                                actionPresentation,
                                isActionHovered: isActionHovered,
                                imageName: "ellipsis"
                            )
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                "Session actions for \(row.title)"
                            )
                        }
                        .accessibilityHint(
                            "Includes the option to kill this session."
                        )
                    } else if let zellijSelection {
                        Button {
                            onRequestKillZellijSession(zellijSelection)
                        } label: {
                            sessionActionLabel(
                                actionPresentation,
                                isActionHovered: isActionHovered,
                                imageName: "xmark"
                            )
                        }
                        .accessibilityLabel(
                            "Kill Zellij session \(zellijSelection.name)"
                        )
                    } else {
                        NativePopupMenuButton(
                            groups: [herdrActions.compactMap(
                                herdrPopupMenuAction
                            )]
                        ) {
                            sessionActionLabel(
                                actionPresentation,
                                isActionHovered: isActionHovered,
                                imageName: "ellipsis"
                            )
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                "Session actions for \(row.title)"
                            )
                        }
                        .accessibilityHint(
                            "Includes Herdr lifecycle actions."
                        )
                    }
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    if isHovered {
                        sessionActionHoverDismissTask?.cancel()
                        hoveredSessionActionControlRowID = row.id
                    } else if hoveredSessionActionControlRowID == row.id {
                        hoveredSessionActionControlRowID = nil
                        scheduleSessionActionHoverDismiss(row.id)
                    }
                }
                .help(
                    usesDirectKillAction ? "Kill session…" : "Session actions"
                )
                .padding(.trailing, 8 + reservedTrailingActionWidth)
            }
        }
        .onHover { isHovered in
            guard hasSessionActions else { return }
            if isHovered {
                sessionActionHoverDismissTask?.cancel()
                hoveredSessionActionRowID = row.id
            } else {
                scheduleSessionActionHoverDismiss(row.id)
            }
        }
        .contextMenu {
            if let renamableTmuxSession {
                Button("Rename Session…") {
                    onRequestRenameTmuxSession(renamableTmuxSession)
                }
            }
            if let tmuxSession = runningTmuxSession {
                Button("Kill Session…", role: .destructive) {
                    onRequestKillTmuxSession(tmuxSession)
                }
            }
            if let zellijSelection {
                Button("Kill Session…", role: .destructive) {
                    onRequestKillZellijSession(zellijSelection)
                }
            }
            ForEach(herdrActions, id: \.self) { action in
                herdrContextMenuButton(action)
            }
        }
        .accessibilityActions {
            if let renamableTmuxSession {
                Button("Rename Session") {
                    onRequestRenameTmuxSession(renamableTmuxSession)
                }
            }
            if let tmuxSession = runningTmuxSession {
                Button("Kill Session") {
                    onRequestKillTmuxSession(tmuxSession)
                }
            }
            if let zellijSelection {
                Button("Kill Session") {
                    onRequestKillZellijSession(zellijSelection)
                }
            }
            ForEach(herdrActions, id: \.self) { action in
                herdrAccessibilityButton(action)
            }
        }
    }

    @ViewBuilder
    private func herdrContextMenuButton(
        _ action: WorkspaceSidebarRowAction
    ) -> some View {
        switch action {
        case let .stopHerdrSession(selection):
            Button("Stop Session…", role: .destructive) {
                onRequestHerdrSessionLifecycle(selection, .stop)
            }
        case let .restartHerdrSession(selection):
            Button("Restart") {
                onRestartHerdrSession(selection)
            }
        case let .deleteHerdrSession(selection):
            Button("Delete Session…", role: .destructive) {
                onRequestHerdrSessionLifecycle(selection, .delete)
            }
        case .killTmuxSession:
            EmptyView()
        case let .killZellijSession(selection):
            Button("Kill Session…", role: .destructive) {
                onRequestKillZellijSession(selection)
            }
        }
    }

    private func herdrPopupMenuAction(
        _ action: WorkspaceSidebarRowAction
    ) -> NativePopupMenuAction? {
        switch action {
        case let .stopHerdrSession(selection):
            NativePopupMenuAction("Stop Session…", role: .destructive) {
                onRequestHerdrSessionLifecycle(selection, .stop)
            }
        case let .restartHerdrSession(selection):
            NativePopupMenuAction("Restart") {
                onRestartHerdrSession(selection)
            }
        case let .deleteHerdrSession(selection):
            NativePopupMenuAction("Delete Session…", role: .destructive) {
                onRequestHerdrSessionLifecycle(selection, .delete)
            }
        case .killTmuxSession:
            nil
        case let .killZellijSession(selection):
            NativePopupMenuAction("Kill Session…", role: .destructive) {
                onRequestKillZellijSession(selection)
            }
        }
    }

    @ViewBuilder
    private func herdrAccessibilityButton(
        _ action: WorkspaceSidebarRowAction
    ) -> some View {
        switch action {
        case let .stopHerdrSession(selection):
            Button("Stop Session") {
                onRequestHerdrSessionLifecycle(selection, .stop)
            }
        case let .restartHerdrSession(selection):
            Button("Restart") {
                onRestartHerdrSession(selection)
            }
        case let .deleteHerdrSession(selection):
            Button("Delete Session") {
                onRequestHerdrSessionLifecycle(selection, .delete)
            }
        case .killTmuxSession:
            EmptyView()
        case let .killZellijSession(selection):
            Button("Kill Session") {
                onRequestKillZellijSession(selection)
            }
        }
    }

    /// Details dropped from the one-line row, such as the window count.
    static func rowHelp(_ row: WorkspaceSidebarRow) -> String {
        [row.sessionBackend?.title, row.subtitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func isRowSelected(
        _ row: WorkspaceSidebarRow,
        selection: WorkspaceSelection,
        rowTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeTmuxSession: WorkspaceTmuxSessionSelection?,
        activeHerdrSession: WorkspaceHerdrSessionSelection?,
        activeZellijSession: WorkspaceZellijSessionSelection? = nil
    ) -> Bool {
        if case let .herdrSession(hostID, name, backend) = row.target {
            return activeHerdrSession == WorkspaceHerdrSessionSelection(
                hostID: hostID,
                name: name, backend: backend
            )
        }
        if case let .tmuxSession(hostID, name, socketName) = row.target {
            return activeTmuxSession == WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: name,
                socketName: socketName
            )
        }
        if case let .zellijSession(hostID, name) = row.target {
            return activeZellijSession == WorkspaceZellijSessionSelection(
                hostID: hostID,
                name: name
            )
        }
        if let rowTmuxSession, let activeTmuxSession,
           sameTmuxPresentationEndpoint(rowTmuxSession, activeTmuxSession) {
            return true
        }
        if case let .worktree(worktreeID) = row.target,
           activeTmuxSession?.worktreeID == worktreeID {
            return true
        }
        if case let .directoryWorkspace(directoryWorkspaceID) = row.target,
           activeTmuxSession?.directoryWorkspaceID == directoryWorkspaceID {
            return true
        }
        return activeTmuxSession == nil
            && activeHerdrSession == nil
            && activeZellijSession == nil
            && selection.navigationTarget == row.target
    }

    private static func sameTmuxPresentationEndpoint(
        _ lhs: WorkspaceTmuxSessionSelection,
        _ rhs: WorkspaceTmuxSessionSelection
    ) -> Bool {
        let lhsMode = lhs.tmuxAttachMode == .direct ? nil : lhs.tmuxAttachMode
        let rhsMode = rhs.tmuxAttachMode == .direct ? nil : rhs.tmuxAttachMode
        return lhs.hostID == rhs.hostID
            && lhs.name == rhs.name
            && lhs.socketName == rhs.socketName
            && lhsMode == rhsMode
    }

    private func sessionActionLabel(
        _ presentation: WorkspaceSessionActionPresentation,
        isActionHovered: Bool,
        imageName: String
    ) -> some View {
        ZStack {
            Color.clear
            if presentation.isVisible {
                Image(systemName: imageName)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .frame(
            width: presentation.hitTargetWidth,
            height: sidebarPreferences.rowHeight.points - 4
        )
        .background {
            if presentation.isVisible {
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        Color.primary.opacity(
                            isActionHovered ? 0.14 : 0.06
                        )
                    )
            }
        }
        .contentShape(Rectangle())
    }

    private func scheduleSessionActionHoverDismiss(
        _ rowID: WorkspaceNavigationTarget
    ) {
        sessionActionHoverDismissTask?.cancel()
        sessionActionHoverDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  hoveredSessionActionControlRowID != rowID,
                  hoveredSessionActionRowID == rowID
            else { return }
            hoveredSessionActionRowID = nil
        }
    }

    private func tmuxSessionSelection(
        for row: WorkspaceSidebarRow
    ) -> WorkspaceTmuxSessionSelection? {
        switch row.target {
        case let .tmuxSession(hostID, name, socketName):
            return WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: name,
                socketName: socketName
            )
        case let .worktree(worktreeID):
            guard let worktree = snapshot.worktree(id: worktreeID) else {
                return nil
            }
            return WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        case let .directoryWorkspace(directoryWorkspaceID):
            guard let workspace = snapshot.directoryWorkspace(
                id: directoryWorkspaceID
            ) else { return nil }
            return WorkspaceSidebarModel.tmuxSessionSelection(for: workspace)
        case .host, .project, .herdrSession, .zellijSession:
            return nil
        }
    }

    private func worktreeButton(
        _ row: WorkspaceSidebarRow,
        groupItems: [WorkspaceSidebarDragItem]
    ) -> some View {
        WorktreeFlagContent(state: worktreeFlagStore.state(for: row.worktreeFlagKey)) { isFlagged in
            worktreeContent(row, groupItems: groupItems, isFlagged: isFlagged)
        }
    }

    private func worktreeContent(
        _ row: WorkspaceSidebarRow,
        groupItems: [WorkspaceSidebarDragItem],
        isFlagged: Bool
    ) -> AnyView {
        guard case let .worktree(worktreeID) = row.target,
              let worktree = snapshot.worktree(id: worktreeID)
        else {
            return AnyView(sidebarButton(row))
        }
        let isRemovable = snapshot.canRemoveWorktree(worktree)
        let runningTmuxSession = WorkspaceSidebarModel.killableTmuxSession(
            for: worktree,
            in: snapshot,
            activeSelection: activeTmuxSession,
            activeSelectionIsConnected: activeTmuxSessionIsConnected
        )
        let isExpanded = worktreeChanges.isExpanded(worktreeID)
        let actionGroups = WorktreeMenuAction.groups(
            flagKey: row.worktreeFlagKey,
            isFlagged: isFlagged,
            isExpanded: isExpanded,
            canKill: runningTmuxSession != nil,
            canRemove: isRemovable
        )
        let performAction: (WorktreeMenuAction) -> Void = { action in
            performWorktreeAction(
                action,
                worktree: worktree,
                runningTmuxSession: runningTmuxSession
            )
        }
        let isActionHovered = hoveredWorktreeActionID == worktreeID
        let actionPresentation =
            WorkspaceWorktreeActionPresentation(
                isRowHovered: hoveredWorktreeID == worktreeID,
                isActionHovered: isActionHovered,
                isSelected: Self.isRowSelected(
                    row,
                    selection: selection,
                    rowTmuxSession: tmuxSessionSelection(for: row),
                    activeTmuxSession: activeTmuxSession,
                    activeHerdrSession: activeHerdrSession,
                    activeZellijSession: activeZellijSession
                ),
                isFocused: focusedWorktreeActionID == worktreeID
            )
        let disclosurePresentation =
            WorkspaceWorktreeDisclosurePresentation(
                rowIndentLevel: row.indentLevel
            )
        var contentRow = row
        contentRow.indentLevel = disclosurePresentation.contentIndentLevel
        let worktreeRow = AnyView(
            sidebarButton(
                contentRow,
                reservedTrailingActionWidth:
                actionPresentation.reservedWidth,
                isWorktreeFlagged: isFlagged
            )
            .overlay(alignment: .trailing) {
                NativePopupMenuButton(groups: actionGroups.map { group in
                    group.map { action in
                        NativePopupMenuAction(
                            action.title,
                            role: action.isDestructive ? .destructive : nil,
                            isEnabled: action.isEnabled
                        ) {
                            performAction(action)
                        }
                    }
                }) {
                    ZStack {
                        Color.clear
                        if actionPresentation.isVisible {
                            Image(systemName: "ellipsis")
                                .font(.system(
                                    size: 10,
                                    weight: .semibold
                                ))
                        }
                    }
                    .frame(
                        width: actionPresentation.hitTargetWidth,
                        height: 30
                    )
                    .background {
                        if actionPresentation.isVisible {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(
                                    isActionHovered ? 0.14 : 0.05
                                ))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focused(
                    $focusedWorktreeActionID,
                    equals: worktreeID
                )
                .onHover { isHovered in
                    if isHovered {
                        worktreeHoverDismissTask?.cancel()
                        hoveredWorktreeActionID = worktreeID
                    } else if hoveredWorktreeActionID == worktreeID {
                        hoveredWorktreeActionID = nil
                        scheduleWorktreeHoverDismiss(worktreeID)
                    }
                }
                .help(row.worktreeFlagKey == nil
                    ? "Refresh worktree inventory to enable flagging."
                    : "Worktree actions")
                .accessibilityLabel(
                    "Worktree actions for \(worktree.name)"
                )
                .accessibilityIdentifier(
                    "worktree-actions-\(worktree.id.uuidString)"
                )
                .accessibilityHint(row.worktreeFlagKey == nil
                    ? "Flagging requires a verified worktree identity from inventory."
                    : "Includes flagging and available worktree actions.")
            }
            .onHover { isHovered in
                if isHovered {
                    worktreeHoverDismissTask?.cancel()
                    hoveredWorktreeID = worktreeID
                } else {
                    scheduleWorktreeHoverDismiss(worktreeID)
                }
            }
            .contextMenu {
                ForEach(Array(actionGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Divider()
                    }
                    ForEach(group) { action in
                        Button(action.title, role: action.isDestructive ? .destructive : nil) {
                            performAction(action)
                        }
                        .disabled(!action.isEnabled)
                    }
                }
            }
            .accessibilityActions {
                ForEach(actionGroups.flatMap { $0 }) { action in
                    Button(action.title) { performAction(action) }
                        .disabled(!action.isEnabled)
                }
            }
            .modifier(
                WorkspaceSidebarReorderModifier(
                    item: .worktree(worktreeID),
                    groupItems: groupItems,
                    orderRawValue: worktreeOrderRawValue,
                    draggedItem: $draggedSidebarItem,
                    indicator: $reorderIndicator,
                    updateOrder: { updatedRawValue in
                        worktreeOrderRawValue = updatedRawValue
                    }
                )
            )
        )
        let content = AnyView(
            HStack(spacing: 0) {
                worktreeChangesDisclosureButton(
                    worktree,
                    isExpanded: isExpanded
                )
                worktreeRow
            }
            .padding(.leading, disclosurePresentation.leadingIndent)
        )
        let rowContent = tmuxPreviewRow(row, content: content)
        guard isExpanded else { return rowContent }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                rowContent
                worktreeChangesPanel(for: worktree)
                    .padding(.leading, 28)
                    .padding(.trailing, 6)
            }
        )
    }

    private func performWorktreeAction(
        _ action: WorktreeMenuAction,
        worktree: WorktreeSummary,
        runningTmuxSession: WorkspaceTmuxSessionSelection?
    ) {
        switch action {
        case let .setFlagged(key?, flagged):
            do {
                try worktreeFlagStore.setFlagged(
                    flagged, for: key, worktreeID: worktree.id, in: currentSnapshot()
                )
            } catch let error as WorktreeFlagUpdateError {
                onWorktreeFlagFailure(worktree, error.localizedDescription)
            } catch {
                onWorktreeFlagFailure(worktree, "The worktree flag couldn't be saved. Try again.")
            }
        case .setFlagged(nil, _):
            break
        case let .setChangesExpanded(expanded):
            worktreeChanges.setExpanded(expanded, worktreeID: worktree.id)
        case .killSession:
            if let runningTmuxSession {
                onRequestKillTmuxSession(runningTmuxSession)
            }
        case .removeWorktree:
            onRequestRemoveWorktree(worktree)
        }
    }

    private func worktreeChangesDisclosureButton(
        _ worktree: WorktreeSummary,
        isExpanded: Bool
    ) -> some View {
        Button {
            worktreeChanges.setExpanded(
                !isExpanded,
                worktreeID: worktree.id
            )
        } label: {
            hierarchyDisclosureIcon(isExpanded: isExpanded)
        }
        .buttonStyle(.plain)
        .workspaceAccessibility(
            WorkspaceAccessibilityModel.disclosureDescriptor(
                title: "Changes for \(worktree.name)",
                isExpanded: isExpanded
            )
        )
        .help(isExpanded ? "Hide changes" : "Show changes")
        .accessibilityIdentifier(
            "worktree-changes-disclosure-\(worktree.id.uuidString)"
        )
    }

    private func worktreeChangesPanel(
        for worktree: WorktreeSummary
    ) -> AnyView {
        guard let identity = WorktreeChangesIdentity.resolve(
            worktreeID: worktree.id,
            in: snapshot
        ) else {
            var entry = WorktreeChangesEntry()
            entry.errorMessage = "Changed files are unavailable for this worktree."
            return AnyView(WorktreeChangesView(
                entry: entry,
                onRefresh: onRefreshInventory
            ))
        }
        guard let loadWorktreeChanges else {
            var entry = WorktreeChangesEntry()
            entry.errorMessage = "Changed-file loading is unavailable."
            return AnyView(WorktreeChangesView(
                entry: entry,
                onRefresh: nil
            ))
        }
        return AnyView(WorktreeChangesPanel(
            identity: identity,
            worktree: worktree,
            store: worktreeChanges,
            isEligible: isWorktreeChangesPollingEligible,
            currentSnapshot: currentSnapshot,
            load: loadWorktreeChanges,
            sleep: worktreeChangesSleep,
            refreshInventory: onRefreshInventory
        ))
    }

    private func tmuxPreviewRow(
        _ row: WorkspaceSidebarRow,
        content: AnyView,
        reservesChevron: Bool = false
    ) -> AnyView {
        guard sessionPreviewMode != .off else { return content }
        guard let tmuxSession = tmuxSessionSelection(for: row),
              TmuxSessionPreviewRowPresentation.canDisclose(
                  mode: sessionPreviewMode,
                  sessionID: tmuxSession.id,
                  previewableSessionIDs: previewableTmuxSessionIDs
              )
        else {
            return reservesChevron ? previewChevronSpacer(content) : content
        }
        let isExpanded = TmuxSessionPreviewRowPresentation.isExpanded(
            mode: sessionPreviewMode,
            sessionID: tmuxSession.id,
            expansion: tmuxPreviewExpansion
        )
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Button {
                        tmuxPreviewExpansion.setExpanded(
                            !isExpanded,
                            sessionID: tmuxSession.id,
                            defaultExpanded:
                            sessionPreviewMode.expandsEverySession
                        )
                        onTmuxSessionPreviewExpanded(
                            tmuxSession,
                            !isExpanded
                        )
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(
                                width: 14,
                                height: sidebarPreferences.rowHeight.points
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isExpanded
                            ? "Hide session preview for \(tmuxSession.name)"
                            : "Show session preview for \(tmuxSession.name)"
                    )
                    .accessibilityIdentifier(
                        "tmux-preview-disclosure-\(tmuxSession.id)"
                    )

                    content
                }
                if TmuxSessionPreviewRowPresentation.isVisible(
                    mode: sessionPreviewMode,
                    sessionID: tmuxSession.id,
                    previewableSessionIDs: previewableTmuxSessionIDs,
                    expansion: tmuxPreviewExpansion
                ),
                    let preview = tmuxSessionPreviewBuilder?(
                        tmuxSession,
                        {
                            Self.activateTmuxSession(
                                tmuxSession,
                                rowTarget: row.target,
                                selection: $selection,
                                snapshot: snapshot,
                                visibility: visibility,
                                onOpen: onOpenTmuxSession
                            )
                        }
                    ) {
                    preview
                        .modifier(TmuxSessionPreviewMountModifier(
                            session: tmuxSession,
                            onMountChanged: tmuxSessionPreviewMountChanged
                        ))
                        .padding(.leading, 14)
                        .padding(.trailing, 8)
                        .accessibilityIdentifier(
                            "tmux-preview-\(tmuxSession.id)"
                        )
                }
            }
        )
    }

    private func tmuxSessionPreviewMountChanged(
        _ session: WorkspaceTmuxSessionSelection,
        mountID: UUID,
        mounted: Bool
    ) {
        guard let expanded = tmuxPreviewMountState.setMounted(
            mounted,
            sessionID: session.id,
            mountID: mountID
        ) else { return }
        onTmuxSessionPreviewExpanded(session, expanded)
    }

    static func activateTmuxSession(
        _ tmuxSession: WorkspaceTmuxSessionSelection,
        rowTarget: WorkspaceNavigationTarget,
        selection: Binding<WorkspaceSelection>,
        snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility,
        onOpen: (WorkspaceTmuxSessionSelection, WorkspaceSelection) -> Void
    ) {
        var routeSelection = selection.wrappedValue
        routeSelection.select(
            rowTarget,
            in: snapshot,
            visibility: visibility
        )
        selection.wrappedValue = routeSelection
        onOpen(tmuxSession, routeSelection)
    }

    private func reorderableRow<Content: View>(
        _ content: Content,
        item: WorkspaceSidebarDragItem,
        groupItems: [WorkspaceSidebarDragItem],
        orderRawValue: String,
        allowsDragging: Bool = true,
        updateOrder: @escaping (String) -> Void
    ) -> some View {
        content.modifier(
            WorkspaceSidebarReorderModifier(
                item: item,
                groupItems: groupItems,
                orderRawValue: orderRawValue,
                draggedItem: $draggedSidebarItem,
                indicator: $reorderIndicator,
                allowsDragging: allowsDragging,
                updateOrder: updateOrder
            )
        )
    }

    private struct WorkspaceSidebarReorderModifier: ViewModifier {
        let item: WorkspaceSidebarDragItem
        let groupItems: [WorkspaceSidebarDragItem]
        let orderRawValue: String
        @Binding var draggedItem: WorkspaceSidebarDragItem?
        @Binding var indicator: WorkspaceSidebarReorderIndicator?
        var allowsDragging = true
        let updateOrder: (String) -> Void

        func body(content: Content) -> some View {
            draggableContent(content)
                .dropDestination(for: String.self) { values, _ in
                    guard let rawValue = values.first,
                          let source = WorkspaceSidebarDragItem(
                              rawValue: rawValue
                          ), groupItems.contains(source)
                    else {
                        clearDragState()
                        return false
                    }
                    var order = WorkspaceSidebarOrder(
                        rawValue: orderRawValue
                    )
                    let moved = order.move(
                        source.orderID,
                        to: item.orderID,
                        within: groupItems.map(\.orderID)
                    )
                    if moved {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            updateOrder(order.rawValue)
                        }
                    }
                    clearDragState()
                    return moved
                } isTargeted: { isTargeted in
                    updateIndicator(isTargeted: isTargeted)
                }
                .overlay {
                    insertionIndicator
                }
        }

        @ViewBuilder
        private func draggableContent(_ content: Content) -> some View {
            if allowsDragging {
                content.onDrag {
                    draggedItem = item
                    return NSItemProvider(object: item.rawValue as NSString)
                }
            } else {
                content
            }
        }

        @ViewBuilder
        private var insertionIndicator: some View {
            if let indicator, indicator.item == item {
                VStack(spacing: 0) {
                    if indicator.placement == .after {
                        Spacer(minLength: 0)
                    }
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                    if indicator.placement == .before {
                        Spacer(minLength: 0)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }

        private func updateIndicator(isTargeted: Bool) {
            guard isTargeted else {
                if indicator?.item == item {
                    indicator = nil
                }
                return
            }
            guard let draggedItem,
                  let placement = WorkspaceSidebarDropPlacement.resolve(
                      sourceID: draggedItem.orderID,
                      targetID: item.orderID,
                      orderedIDs: groupItems.map(\.orderID)
                  )
            else {
                indicator = nil
                return
            }
            indicator = WorkspaceSidebarReorderIndicator(
                item: item,
                placement: placement
            )
        }

        private func clearDragState() {
            draggedItem = nil
            indicator = nil
        }
    }

    private func scheduleWorktreeHoverDismiss(_ worktreeID: UUID) {
        worktreeHoverDismissTask?.cancel()
        worktreeHoverDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  hoveredWorktreeActionID != worktreeID,
                  hoveredWorktreeID == worktreeID
            else { return }
            hoveredWorktreeID = nil
        }
    }

    private func projectHierarchyRow(
        _ project: WorkspaceSidebarProject,
        disclosureKey: String
    ) -> some View {
        let canCreate = snapshot.canCreateWorktree(in: project.project)
        let canImport = snapshot.canImportPullRequest(in: project.project)
        let canRemove = snapshot.host(
            id: project.project.hostID
        )?.canRegisterProjects == true
        return HStack(spacing: 0) {
            hierarchyDisclosureButton(
                project.row,
                disclosureKey: disclosureKey
            )

            sidebarButton(project.row)

            if project.project.pathIssue != nil {
                Button {
                    onLocateProject(project.project)
                } label: {
                    Image(systemName: "folder.badge.questionmark")
                        .foregroundStyle(.orange)
                        .frame(width: 28, height: 30)
                }
                .buttonStyle(.plain)
                .help("Folder unavailable. Locate its new location.")
                .accessibilityLabel("Locate folder for \(project.project.name)")
                .accessibilityIdentifier("locate-project-folder")
                .disabled(!canRemove)
            }

            NativePopupMenuButton(
                groups: [
                    [
                        NativePopupMenuAction(
                            "New Worktree…",
                            isEnabled: canCreate
                        ) {
                            onNewWorktree(project.project)
                        },
                        NativePopupMenuAction(
                            "Import Pull Request…",
                            isEnabled: canImport
                        ) {
                            onImportPullRequest(project.project)
                        },
                    ],
                ]
            ) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Project actions for \(project.project.sidebarTitle)"
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(projectActionHelp(for: project.project))
            .accessibilityHint(
                canCreate || canImport
                    ? "Create a kwt worktree or import a pull request."
                    : projectActionHelp(for: project.project)
            )
            .accessibilityIdentifier("project-actions")

            if canRemove {
                ProjectRemovalButton(
                    project: project.project,
                    isRowHovered:
                    hoveredProjectID == project.project.id,
                    onRemove: onRequestRemoveProject
                )
            }
        }
        .onHover { isHovered in
            if isHovered {
                hoveredProjectID = project.project.id
            } else if hoveredProjectID == project.project.id {
                hoveredProjectID = nil
            }
        }
    }

    private func hierarchyDisclosureButton(
        _ row: WorkspaceSidebarRow,
        disclosureKey: String
    ) -> some View {
        let expanded = isExpanded(disclosureKey)
        return Button {
            toggle(disclosureKey)
        } label: {
            hierarchyDisclosureIcon(isExpanded: expanded)
        }
        .buttonStyle(.plain)
        .workspaceAccessibility(
            WorkspaceAccessibilityModel.disclosureDescriptor(
                title: row.title,
                isExpanded: expanded
            )
        )
    }

    private func hierarchyDisclosureIcon(isExpanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .foregroundStyle(
                colorSchemeContrast == .increased
                    ? Color.primary : Color(nsColor: .tertiaryLabelColor)
            )
            .frame(width: 16, height: sidebarPreferences.rowHeight.points)
            .contentShape(Rectangle())
    }

    private func projectActionHelp(
        for project: ProjectSummary
    ) -> String {
        if snapshot.canCreateWorktree(in: project)
            || snapshot.canImportPullRequest(in: project) {
            return "Project actions for \(project.sidebarTitle)"
        }
        let host = snapshot.host(id: project.hostID)
        return host?.createWorktreeUnavailableReason
            ?? host?.importPullRequestUnavailableReason
            ?? "This project cannot create worktrees."
    }

    private func inventoryWarningButton(
        _ warning: String,
        host: HostSummary?,
        accessibilityLabel: String
    ) -> some View {
        Button {
            resolveInventoryWarning(warning, host: host)
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            host?.kind == .remote
                ? "Resolve connection issue"
                : "Show inventory issue details"
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            host?.kind == .remote
                ? "Connection needs attention." : warning
        )
        .accessibilityIdentifier("host-inventory-warning")
    }

    private var inventoryWarningIsPresented: Binding<Bool> {
        Binding(
            get: { presentedInventoryWarning != nil },
            set: { isPresented in
                if !isPresented {
                    presentedInventoryWarning = nil
                }
            }
        )
    }

    private func resolveInventoryWarning(
        _ message: String,
        host: HostSummary?
    ) {
        switch InventoryWarningDestination(message: message, host: host) {
        case let .connectionRecovery(hostID, inventoryWarning):
            onReviewSSHHostKey(hostID, inventoryWarning)
        case let .details(warning):
            presentedInventoryWarning = warning
        }
    }

    // MARK: - Row content

    private func isExpanded(_ key: String) -> Bool {
        disclosureState.isExpanded(key)
    }

    private func toggle(_ key: String) {
        disclosureState.toggle(key)
    }

    private func pruneSidebarOrders() {
        // Missing inventory is not proof of deletion. Preserve order while
        // any host is unreachable or reporting an inventory failure, and
        // prune only from a complete authoritative fleet snapshot.
        guard WorkspaceSidebarPruningPolicy.shouldPrune(
            refreshComplete: inventoryRefreshComplete,
            inventoryWarning: inventoryWarning,
            inventoryWarningsByHost: inventoryWarningsByHost
        )
        else { return }
        worktreeChanges.prune(in: snapshot)
        var worktreeOrder = WorkspaceSidebarOrder(
            rawValue: worktreeOrderRawValue
        )
        let worktreeIDs = Set(
            snapshot.worktrees
                .filter { !$0.isStale }
                .map { $0.id.uuidString }
        )
        if worktreeOrder.prune(keeping: worktreeIDs) {
            worktreeOrderRawValue = worktreeOrder.rawValue
        }

        var sessionOrder = WorkspaceSidebarOrder(
            rawValue: sessionOrderRawValue
        )
        let sessionIDs = Set(snapshot.hosts.flatMap { host in
            host.tmuxSessions.map {
                WorkspaceSidebarModel.tmuxSessionOrderID(
                    hostID: host.id,
                    name: $0.name,
                    socketName: $0.socketName
                )
            } + host.herdrSessions.map {
                WorkspaceSidebarModel.herdrSessionOrderID(
                    hostID: host.id,
                    name: $0.name,
                    backend: $0.backend
                )
            } + host.zellijSessions.map {
                WorkspaceSidebarModel.zellijSessionOrderID(
                    hostID: host.id,
                    name: $0.name
                )
            }
        })
        if sessionOrder.prune(keeping: sessionIDs) {
            sessionOrderRawValue = sessionOrder.rawValue
        }
    }

    /// Project and directory workspace rows: name plus dimmed path.
    private func legacyRowContent(
        title: String,
        subtitle: String?,
        sessionIsRunning: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if sessionIsRunning {
                Image(systemName: "play.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tmuxSessionActivityIndicator: some View {
        Image(
            systemName: differentiateWithoutColor
                ? "waveform" : "circle.fill"
        )
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .help("Recent tmux output")
        .accessibilityLabel("Recent tmux output")
    }
}

enum InventoryWarningDestination: Equatable {
    case connectionRecovery(UUID, String)
    case details(PresentedInventoryWarning)

    init(message: String, host: HostSummary?) {
        if let host, host.kind == .remote {
            self = .connectionRecovery(host.id, message)
        } else {
            self = .details(PresentedInventoryWarning(
                message: message,
                isHostScoped: host != nil
            ))
        }
    }
}

struct PresentedInventoryWarning: Equatable {
    let message: String
    let isHostScoped: Bool
}
