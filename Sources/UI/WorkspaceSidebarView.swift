import Foundation
import GhosthubWorkspace
import SwiftUI

struct WorkspaceTmuxSessionActionPresentation: Equatable {
    static let controlWidth: CGFloat = 30

    let isVisible: Bool
    let reservedWidth: CGFloat
    let hitTargetWidth: CGFloat

    init(
        hasTmuxSession: Bool,
        isRowHovered: Bool,
        isActionHovered: Bool
    ) {
        isVisible = hasTmuxSession
            && (isRowHovered || isActionHovered)
        reservedWidth = hasTmuxSession ? Self.controlWidth : 0
        hitTargetWidth = hasTmuxSession ? Self.controlWidth : 0
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

enum WorkspaceSidebarHierarchy {
    private static let step: CGFloat = 14

    static func indent(level: Int) -> CGFloat {
        CGFloat(max(0, level)) * step
    }
}

private enum WorkspaceSidebarDragItem: Equatable {
    case worktree(UUID)
    case tmuxSession(hostID: UUID, name: String)

    init?(rawValue: String) {
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
            self = .tmuxSession(
                hostID: hostID,
                name: String(parts[2])
            )
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case let .worktree(id):
            return "worktree:\(id.uuidString)"
        case let .tmuxSession(hostID, name):
            return "tmux:\(hostID.uuidString):\(name)"
        }
    }

    var orderID: String {
        switch self {
        case let .worktree(id):
            return id.uuidString
        case let .tmuxSession(hostID, name):
            return WorkspaceSidebarModel.tmuxSessionOrderID(
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

struct WorkspaceSidebarView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let snapshot: WorkspaceSnapshot
    @Binding var selection: WorkspaceSelection
    let visibility: WorktreeVisibility
    let tmuxSessionVisibility: TmuxSessionVisibility
    let onOpen: (WorktreeSummary) -> Void
    let activeTmuxSession: WorkspaceTmuxSessionSelection?
    let activeTmuxSessionIsConnected: Bool
    let onOpenTmuxSession: (WorkspaceTmuxSessionSelection) -> Void
    let onNavigateAwayFromTmuxSession: () -> Void
    let onRequestKillTmuxSession: (WorkspaceTmuxSessionSelection) -> Void
    let onRequestRemoveWorktree: (WorktreeSummary) -> Void
    let onNewWorktree: (ProjectSummary) -> Void
    let onImportPullRequest: (ProjectSummary) -> Void
    let onNewTmuxSession: (HostSummary) -> Void
    let onAddProject: (HostSummary) -> Void
    let onRefreshInventory: () -> Void
    let onOpenHostSettings: () -> Void
    let onReviewSSHHostKey: (UUID) -> Void
    let inventoryWarning: String?
    let inventoryWarningsByHost: [UUID: String]
    @State private var presentedInventoryWarning:
        PresentedInventoryWarning?
    @State private var hoveredTmuxSessionID: String?
    @State private var hoveredTmuxSessionActionID: String?
    @State private var tmuxSessionHoverDismissTask: Task<Void, Never>?
    @State private var hoveredWorktreeID: UUID?
    @State private var hoveredWorktreeActionID: UUID?
    @State private var worktreeHoverDismissTask: Task<Void, Never>?
    @State private var draggedSidebarItem: WorkspaceSidebarDragItem?
    @State private var reorderIndicator:
        WorkspaceSidebarReorderIndicator?
    @AppStorage("workspaceSidebarDisclosureStateV2")
    private var disclosureState = ""
    @AppStorage("workspaceSidebarCollapsedItems")
    private var legacyCollapsedItems = ""
    @AppStorage("workspaceSidebarWorktreeOrderV1")
    private var worktreeOrderRawValue = ""
    @AppStorage("workspaceSidebarTmuxSessionOrderV1")
    private var tmuxSessionOrderRawValue = ""

    init(
        snapshot: WorkspaceSnapshot,
        selection: Binding<WorkspaceSelection>,
        visibility: WorktreeVisibility,
        tmuxSessionVisibility: TmuxSessionVisibility = TmuxSessionVisibility(),
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeTmuxSessionIsConnected: Bool = false,
        onOpenTmuxSession: @escaping (
            WorkspaceTmuxSessionSelection
        ) -> Void = { _ in },
        onNavigateAwayFromTmuxSession: @escaping () -> Void = {},
        onRequestKillTmuxSession: @escaping (
            WorkspaceTmuxSessionSelection
        ) -> Void = { _ in },
        onRequestRemoveWorktree: @escaping (
            WorktreeSummary
        ) -> Void = { _ in },
        onNewWorktree: @escaping (ProjectSummary) -> Void = { _ in },
        onImportPullRequest: @escaping (ProjectSummary) -> Void = { _ in },
        onNewTmuxSession: @escaping (HostSummary) -> Void = { _ in },
        onAddProject: @escaping (HostSummary) -> Void = { _ in },
        onRefreshInventory: @escaping () -> Void = {},
        onOpenHostSettings: @escaping () -> Void = {},
        onReviewSSHHostKey: @escaping (UUID) -> Void = { _ in },
        inventoryWarning: String? = nil,
        inventoryWarningsByHost: [UUID: String] = [:],
        onOpen: @escaping (WorktreeSummary) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        _selection = selection
        self.visibility = visibility
        self.tmuxSessionVisibility = tmuxSessionVisibility
        self.activeTmuxSession = activeTmuxSession
        self.activeTmuxSessionIsConnected = activeTmuxSessionIsConnected
        self.onOpenTmuxSession = onOpenTmuxSession
        self.onNavigateAwayFromTmuxSession = onNavigateAwayFromTmuxSession
        self.onRequestKillTmuxSession = onRequestKillTmuxSession
        self.onRequestRemoveWorktree = onRequestRemoveWorktree
        self.onNewWorktree = onNewWorktree
        self.onImportPullRequest = onImportPullRequest
        self.onNewTmuxSession = onNewTmuxSession
        self.onAddProject = onAddProject
        self.onRefreshInventory = onRefreshInventory
        self.onOpenHostSettings = onOpenHostSettings
        self.onReviewSSHHostKey = onReviewSSHHostKey
        self.inventoryWarning = inventoryWarning
        self.inventoryWarningsByHost = inventoryWarningsByHost
        self.onOpen = onOpen
    }

    // MARK: - Computed

    private var sections: [WorkspaceSidebarSection] {
        WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            worktreeOrderRawValue: worktreeOrderRawValue,
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: 2
                    ) {
                        ForEach(sections) { section in
                            let hostKey = WorkspaceSidebarDisclosureState.host(
                                section.host.id
                            )
                            Section {
                                hostContents(
                                    section,
                                    disclosureKey: hostKey
                                )
                            } header: {
                                hostHeader(
                                    section,
                                    disclosureKey: hostKey
                                )
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }
        }
        .onAppear(perform: migrateDisclosureStateIfNeeded)
        .alert(
            "Workspace Inventory Issue",
            isPresented: inventoryWarningIsPresented,
            presenting: presentedInventoryWarning
        ) { warning in
            if let hostID = warning.hostID {
                Button("Review Host Key") {
                    onReviewSSHHostKey(hostID)
                }
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

    private func hostHeader(
        _ section: WorkspaceSidebarSection,
        disclosureKey: String
    ) -> some View {
        hierarchyRow(
            section.row,
            disclosureKey: disclosureKey,
            actionHost: section.host,
            inventoryWarning: inventoryWarningsByHost[section.host.id]
        )
        .padding(.vertical, 1)
        .background {
            ZStack {
                WorkspaceSurfaceColor.color
                Color.primary.opacity(
                    colorSchemeContrast == .increased ? 0.08 : 0.035
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    Color.primary.opacity(
                        colorSchemeContrast == .increased ? 0.35 : 0.12
                    )
                )
                .frame(height: 0.5)
        }
        .contextMenu {
            Button("New tmux session…") {
                onNewTmuxSession(section.host)
            }
            if section.host.canRegisterProjects {
                Button("Add Project…") {
                    onAddProject(section.host)
                }
            }
        }
    }

    @ViewBuilder
    private func hostContents(
        _ section: WorkspaceSidebarSection,
        disclosureKey: String
    ) -> some View {
        if isExpanded(disclosureKey) {
            VStack(alignment: .leading, spacing: 2) {
                if section.isEmpty {
                    emptyHostRow(section.host)
                }
                if !section.tmuxSessionRows.isEmpty {
                    let sessionsKey = WorkspaceSidebarDisclosureState
                        .sessions(section.host.id)
                    sidebarGroupLabel(
                        "Tmux Sessions",
                        disclosureKey: sessionsKey
                    )
                    if isExpanded(sessionsKey) {
                        ForEach(section.tmuxSessionRows) { row in
                            tmuxSessionButton(
                                row,
                                orderedRows: section.tmuxSessionRows
                            )
                        }
                    }
                }
                if !section.projects.isEmpty {
                    let projectsKey = WorkspaceSidebarDisclosureState
                        .projects(section.host.id)
                    sidebarGroupLabel(
                        "Projects",
                        disclosureKey: projectsKey
                    )
                    if isExpanded(projectsKey) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(section.projects) { project in
                                let projectKey = WorkspaceSidebarDisclosureState
                                    .project(project.project.id)
                                projectHierarchyRow(
                                    project,
                                    disclosureKey: projectKey
                                )
                                .contextMenu {
                                    Button("New Worktree…") {
                                        onNewWorktree(project.project)
                                    }
                                    .disabled(
                                        !snapshot.canCreateWorktree(
                                            in: project.project
                                        )
                                    )
                                    Button("Import Pull Request…") {
                                        onImportPullRequest(project.project)
                                    }
                                    .disabled(
                                        !snapshot.canImportPullRequest(
                                            in: project.project
                                        )
                                    )
                                }
                                if isExpanded(projectKey) {
                                    ForEach(project.worktreeRows) { row in
                                        worktreeButton(
                                            row,
                                            projectWorktreeIDs:
                                            project.worktrees.map(\.id)
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    Color.primary.opacity(
                                        colorSchemeContrast == .increased
                                            ? 0.09 : 0.035
                                    )
                                )
                        }
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(
                                    Color.primary.opacity(
                                        colorSchemeContrast == .increased
                                            ? 0.5 : 0.2
                                    )
                                )
                                .frame(width: 2)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(
                .leading,
                WorkspaceSidebarHierarchy.indent(level: 1)
            )
            .padding(.bottom, 6)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(
                        Color.primary.opacity(
                            colorSchemeContrast == .increased ? 0.38 : 0.14
                        )
                    )
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 9)
                    .padding(.vertical, 3)
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
                    presentInventoryWarning(
                        inventoryWarning,
                        hostID: nil
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
            NativePopupMenuButton(
                groups: [
                    preferredNewSessionHost.map {
                        hostActionMenuItems(for: $0)
                    } ?? [],
                    [
                        NativePopupMenuAction(
                            "New worktree…",
                            isEnabled: selectedProject != nil
                        ) {
                            guard let project = selectedProject else {
                                return
                            }
                            onNewWorktree(project)
                        },
                        NativePopupMenuAction(
                            "Import pull request…",
                            isEnabled: selectedImportProject != nil
                        ) {
                            guard let project = selectedImportProject else {
                                return
                            }
                            onImportPullRequest(project)
                        },
                    ],
                ]
            ) {
                Image(systemName: "plus")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Create workspace")
            }
            .buttonStyle(.plain)
            .help("Create a tmux session or kwt worktree")
            .accessibilityHint("Create a tmux session or kwt worktree.")
            .disabled(preferredNewSessionHost == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var selectedProject: ProjectSummary? {
        guard let project = WorkspaceSelectionResolver.selectedProject(
            in: snapshot,
            selection: selection
        ), snapshot.canCreateWorktree(in: project) else { return nil }
        return project
    }

    private var selectedImportProject: ProjectSummary? {
        guard let project = WorkspaceSelectionResolver.selectedProject(
            in: snapshot,
            selection: selection
        ), snapshot.canImportPullRequest(in: project) else { return nil }
        return project
    }

    private var preferredNewSessionHost: HostSummary? {
        snapshot.host(id: selection.selectedHostID)
            ?? snapshot.hosts.first(where: { $0.kind == .selfHost })
            ?? snapshot.hosts.first
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No kwt projects or tmux sessions")
                .font(.callout.weight(.semibold))
            Text("Register projects in kwt or start a tmux session, then refresh Ghosthub.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }

    private func emptyHostRow(_ host: HostSummary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "tray")
                .font(.system(size: 11, weight: .medium))
            Text("No projects or tmux sessions yet")
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary.opacity(0.78))
        .padding(.leading, 28)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "No projects or tmux sessions on \(host.sidebarTitle)"
        )
    }

    // MARK: - Row builders

    private func tmuxSessionButton(
        _ row: WorkspaceSidebarRow,
        orderedRows: [WorkspaceSidebarRow]
    ) -> some View {
        guard case let .tmuxSession(hostID, name) = row.target else {
            return AnyView(sidebarButton(row))
        }
        let item = WorkspaceSidebarDragItem.tmuxSession(
            hostID: hostID,
            name: name
        )
        let groupItems: [WorkspaceSidebarDragItem] = orderedRows.compactMap {
            orderedRow in
            guard case let .tmuxSession(orderedHostID, orderedName) =
                orderedRow.target
            else { return nil }
            return WorkspaceSidebarDragItem.tmuxSession(
                hostID: orderedHostID,
                name: orderedName
            )
        }
        return AnyView(
            reorderableRow(
                sidebarButton(row),
                item: item,
                groupItems: groupItems,
                orderRawValue: tmuxSessionOrderRawValue
            ) { updatedRawValue in
                tmuxSessionOrderRawValue = updatedRawValue
            }
        )
    }

    private func sidebarButton(
        _ row: WorkspaceSidebarRow,
        reservedTrailingActionWidth: CGFloat = 0
    ) -> some View {
        let tmuxSession = tmuxSessionSelection(for: row)
        let runningTmuxSession = tmuxSession.flatMap {
            WorkspaceSidebarModel.canRequestKill(
                $0,
                in: snapshot,
                activeSelection: activeTmuxSession,
                activeSelectionIsConnected:
                activeTmuxSessionIsConnected
            ) ? $0 : nil
        }
        let isSelected: Bool
        if case let .tmuxSession(hostID, name) = row.target {
            isSelected = activeTmuxSession
                == WorkspaceTmuxSessionSelection(hostID: hostID, name: name)
        } else if case let .worktree(worktreeID) = row.target,
                  activeTmuxSession?.worktreeID == worktreeID {
            isSelected = true
        } else {
            isSelected = activeTmuxSession == nil
                && selection.navigationTarget == row.target
        }
        let isActionHovered = runningTmuxSession.map {
            hoveredTmuxSessionActionID == $0.id
        } ?? false
        let actionPresentation = WorkspaceTmuxSessionActionPresentation(
            hasTmuxSession: runningTmuxSession != nil,
            isRowHovered: runningTmuxSession.map {
                hoveredTmuxSessionID == $0.id
            } ?? false,
            isActionHovered: isActionHovered
        )
        let usesDirectKillAction: Bool
        if case .tmuxSession = row.target {
            usesDirectKillAction = true
        } else {
            usesDirectKillAction = false
        }
        return HStack(spacing: 0) {
            Button {
                if case let .tmuxSession(hostID, name) = row.target {
                    let tmuxSelection = WorkspaceTmuxSessionSelection(
                        hostID: hostID,
                        name: name
                    )
                    selection.select(
                        row.target,
                        in: snapshot,
                        visibility: visibility
                    )
                    onOpenTmuxSession(tmuxSelection)
                    return
                }
                if case let .worktree(worktreeID) = row.target,
                   let worktree = snapshot.worktree(id: worktreeID),
                   let tmuxSelection = WorkspaceSidebarModel
                   .tmuxSessionSelection(for: worktree) {
                    selection.select(
                        row.target,
                        in: snapshot,
                        visibility: visibility
                    )
                    onOpenTmuxSession(tmuxSelection)
                    return
                }
                onNavigateAwayFromTmuxSession()
                selection.select(
                    row.target,
                    in: snapshot,
                    visibility: visibility
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: row.icon.systemImageName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(width: 18)
                    if let status = row.worktreeStatus {
                        worktreeRowContent(row.title, status: status)
                    } else {
                        legacyRowContent(
                            title: row.title,
                            subtitle: row.subtitle
                        )
                    }
                    Spacer(minLength: 0)
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
                .padding(
                    .trailing,
                    actionPresentation.reservedWidth
                        + reservedTrailingActionWidth
                )
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(
                                    colorSchemeContrast == .increased
                                        ? 0.42 : 0.28
                                )
                                : Color.clear
                        )
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                Color.primary.opacity(
                                    colorSchemeContrast == .increased
                                        ? 0.55 : 0.24
                                ),
                                lineWidth: colorSchemeContrast == .increased
                                    ? 1.5 : 1
                            )
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .workspaceAccessibility(
                WorkspaceAccessibilityModel.descriptor(
                    for: row,
                    isSelected: isSelected
                )
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .overlay(alignment: .trailing) {
            if let tmuxSession = runningTmuxSession {
                Group {
                    if usesDirectKillAction {
                        Button {
                            onRequestKillTmuxSession(tmuxSession)
                        } label: {
                            tmuxSessionActionLabel(
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
                    } else {
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
                            tmuxSessionActionLabel(
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
                    }
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    if isHovered {
                        tmuxSessionHoverDismissTask?.cancel()
                        hoveredTmuxSessionActionID = tmuxSession.id
                    } else if hoveredTmuxSessionActionID == tmuxSession.id {
                        hoveredTmuxSessionActionID = nil
                        scheduleTmuxSessionHoverDismiss(tmuxSession.id)
                    }
                }
                .help(
                    usesDirectKillAction ? "Kill session…" : "Session actions"
                )
                .padding(.trailing, reservedTrailingActionWidth)
            }
        }
        .onHover { isHovered in
            guard let tmuxSession = runningTmuxSession else { return }
            if isHovered {
                tmuxSessionHoverDismissTask?.cancel()
                hoveredTmuxSessionID = tmuxSession.id
            } else {
                scheduleTmuxSessionHoverDismiss(tmuxSession.id)
            }
        }
        .contextMenu {
            if let tmuxSession = runningTmuxSession {
                Button("Kill Session…", role: .destructive) {
                    onRequestKillTmuxSession(tmuxSession)
                }
            }
        }
        .accessibilityAction(named: "Kill Session") {
            if let tmuxSession = runningTmuxSession {
                onRequestKillTmuxSession(tmuxSession)
            }
        }
    }

    private func tmuxSessionActionLabel(
        _ presentation: WorkspaceTmuxSessionActionPresentation,
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
            height: 30
        )
        .background {
            if presentation.isVisible {
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        Color.primary.opacity(
                            isActionHovered ? 0.14 : 0.05
                        )
                    )
            }
        }
        .contentShape(Rectangle())
    }

    private func scheduleTmuxSessionHoverDismiss(_ sessionID: String) {
        tmuxSessionHoverDismissTask?.cancel()
        tmuxSessionHoverDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  hoveredTmuxSessionActionID != sessionID,
                  hoveredTmuxSessionID == sessionID
            else { return }
            hoveredTmuxSessionID = nil
        }
    }

    private func tmuxSessionSelection(
        for row: WorkspaceSidebarRow
    ) -> WorkspaceTmuxSessionSelection? {
        switch row.target {
        case let .tmuxSession(hostID, name):
            return WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: name
            )
        case let .worktree(worktreeID):
            guard let worktree = snapshot.worktree(id: worktreeID) else {
                return nil
            }
            return WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        case .host, .project:
            return nil
        }
    }

    private func worktreeButton(
        _ row: WorkspaceSidebarRow,
        projectWorktreeIDs: [UUID]
    ) -> some View {
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
        let isActionHovered = hoveredWorktreeActionID == worktreeID
        let actionPresentation =
            WorkspaceWorktreeRemovalActionPresentation(
                isRemovable: isRemovable,
                isRowHovered: hoveredWorktreeID == worktreeID,
                isActionHovered: isActionHovered
            )
        return AnyView(
            sidebarButton(
                row,
                reservedTrailingActionWidth:
                actionPresentation.reservedWidth
            )
            .overlay(alignment: .trailing) {
                if isRemovable {
                    Button {
                        onRequestRemoveWorktree(worktree)
                    } label: {
                        ZStack {
                            Color.clear
                            if actionPresentation.isVisible {
                                Image(systemName: "xmark")
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
                                    .fill(
                                        Color.primary.opacity(
                                            isActionHovered ? 0.14 : 0.05
                                        )
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .onHover { isHovered in
                        if isHovered {
                            worktreeHoverDismissTask?.cancel()
                            hoveredWorktreeActionID = worktreeID
                        } else if hoveredWorktreeActionID == worktreeID {
                            hoveredWorktreeActionID = nil
                            scheduleWorktreeHoverDismiss(worktreeID)
                        }
                    }
                    .help("Remove worktree…")
                    .accessibilityLabel(
                        "Remove worktree \(worktree.name)"
                    )
                    .accessibilityIdentifier(
                        "remove-worktree-\(worktree.id.uuidString)"
                    )
                }
            }
            .onHover { isHovered in
                guard isRemovable else { return }
                if isHovered {
                    worktreeHoverDismissTask?.cancel()
                    hoveredWorktreeID = worktreeID
                } else {
                    scheduleWorktreeHoverDismiss(worktreeID)
                }
            }
            .contextMenu {
                if let runningTmuxSession {
                    Button("Kill Session…", role: .destructive) {
                        onRequestKillTmuxSession(runningTmuxSession)
                    }
                }
                if isRemovable {
                    Button("Remove Worktree…", role: .destructive) {
                        onRequestRemoveWorktree(worktree)
                    }
                }
            }
            .accessibilityAction(named: "Remove Worktree") {
                if isRemovable {
                    onRequestRemoveWorktree(worktree)
                }
            }
            .accessibilityAction(named: "Kill Session") {
                if let runningTmuxSession {
                    onRequestKillTmuxSession(runningTmuxSession)
                }
            }
            .modifier(
                WorkspaceSidebarReorderModifier(
                    item: .worktree(worktreeID),
                    groupItems: projectWorktreeIDs.map {
                        .worktree($0)
                    },
                    orderRawValue: worktreeOrderRawValue,
                    draggedItem: $draggedSidebarItem,
                    indicator: $reorderIndicator,
                    updateOrder: { updatedRawValue in
                        worktreeOrderRawValue = updatedRawValue
                    }
                )
            )
        )
    }

    private func reorderableRow<Content: View>(
        _ content: Content,
        item: WorkspaceSidebarDragItem,
        groupItems: [WorkspaceSidebarDragItem],
        orderRawValue: String,
        updateOrder: @escaping (String) -> Void
    ) -> some View {
        content.modifier(
            WorkspaceSidebarReorderModifier(
                item: item,
                groupItems: groupItems,
                orderRawValue: orderRawValue,
                draggedItem: $draggedSidebarItem,
                indicator: $reorderIndicator,
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
        let updateOrder: (String) -> Void

        func body(content: Content) -> some View {
            content
                .onDrag {
                    draggedItem = item
                    return NSItemProvider(
                        object: item.rawValue as NSString
                    )
                }
                .dropDestination(for: String.self) { values, _ in
                    guard let rawValue = values.first,
                          let source = WorkspaceSidebarDragItem(
                              rawValue: rawValue
                          )
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

    private func hierarchyRow(
        _ row: WorkspaceSidebarRow,
        disclosureKey: String,
        actionHost: HostSummary? = nil,
        inventoryWarning: String? = nil
    ) -> some View {
        return HStack(spacing: 0) {
            hierarchyDisclosureButton(
                row,
                disclosureKey: disclosureKey
            )

            sidebarButton(row)

            if let inventoryWarning {
                inventoryWarningButton(
                    inventoryWarning,
                    hostID: actionHost?.id,
                    accessibilityLabel:
                    "Show connection issue for \(row.title)"
                )
            }

            if let actionHost {
                NativePopupMenuButton(
                    groups: [
                        hostActionMenuItems(for: actionHost),
                    ]
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "Actions for \(actionHost.sidebarTitle)"
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Actions for \(actionHost.sidebarTitle)")
                .accessibilityIdentifier("host-actions")
            }
        }
    }

    private func hostActionMenuItems(
        for host: HostSummary
    ) -> [NativePopupMenuAction] {
        var actions = [
            NativePopupMenuAction("New tmux session…") {
                onNewTmuxSession(host)
            },
        ]
        if host.canRegisterProjects {
            actions.append(
                NativePopupMenuAction("Add Project…") {
                    onAddProject(host)
                }
            )
        }
        return actions
    }

    private func projectHierarchyRow(
        _ project: WorkspaceSidebarProject,
        disclosureKey: String
    ) -> some View {
        let canCreate = snapshot.canCreateWorktree(in: project.project)
        let canImport = snapshot.canImportPullRequest(in: project.project)
        return HStack(spacing: 0) {
            hierarchyDisclosureButton(
                project.row,
                disclosureKey: disclosureKey
            )

            sidebarButton(project.row)

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
        Image(
            systemName: isExpanded
                ? "chevron.down" : "chevron.right"
        )
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(
            colorSchemeContrast == .increased
                ? Color.primary : Color.secondary
        )
        .frame(width: 20, height: 30)
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
        hostID: UUID?,
        accessibilityLabel: String
    ) -> some View {
        Button {
            presentInventoryWarning(warning, hostID: hostID)
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show connection issue details")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(warning)
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

    private func presentInventoryWarning(
        _ message: String,
        hostID: UUID?
    ) {
        presentedInventoryWarning = PresentedInventoryWarning(
            message: message,
            hostID: hostID
        )
    }

    // MARK: - Row content

    private func sidebarGroupLabel(
        _ title: String,
        disclosureKey: String
    ) -> some View {
        let expanded = isExpanded(disclosureKey)
        return Button {
            toggle(disclosureKey)
        } label: {
            HStack(spacing: 5) {
                Image(
                    systemName: expanded
                        ? "chevron.down" : "chevron.right"
                )
                .font(.system(size: 10, weight: .bold))
                .frame(width: 12)
                Text(title.uppercased())
                    .tracking(0.35)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                colorSchemeContrast == .increased
                    ? Color.primary : Color.secondary
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.top, 9)
            .padding(.bottom, 4)
            .frame(minHeight: 30)
        }
        .buttonStyle(.plain)
        .workspaceAccessibility(
            WorkspaceAccessibilityModel.disclosureDescriptor(
                title: title,
                isExpanded: expanded
            )
        )
    }

    private func isExpanded(_ key: String) -> Bool {
        WorkspaceSidebarDisclosureState(rawValue: resolvedDisclosureState)
            .isExpanded(key)
    }

    private func toggle(_ key: String) {
        var state = WorkspaceSidebarDisclosureState(
            rawValue: resolvedDisclosureState
        )
        state.toggle(key)
        disclosureState = state.rawValue
    }

    private var resolvedDisclosureState: String {
        WorkspaceSidebarDisclosureState.migratedRawValue(
            current: disclosureState,
            legacyCollapsedKeys: legacyCollapsedItems
        )
    }

    private func migrateDisclosureStateIfNeeded() {
        let migrated = resolvedDisclosureState
        guard migrated != disclosureState else { return }
        disclosureState = migrated
        legacyCollapsedItems = ""
    }

    /// Two-line status row for worktrees: title + trailing status cluster on
    /// line 1; optional PR info on line 2.
    private func worktreeRowContent(
        _ title: String,
        status: WorktreeRowStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                worktreeStatusCluster(status)
            }
            worktreePRLine(status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trailing status cluster: diff, sync, and running indicator.
    @ViewBuilder
    private func worktreeStatusCluster(_ status: WorktreeRowStatus) -> some View {
        if hasStatusCluster(status) {
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
                if status.isRunning {
                    Image(
                        systemName: status.isAgentRunning
                            ? "cpu" : "play.circle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        status.isAgentRunning
                            ? Color.accentColor : Color.secondary
                    )
                }
            }
            .fixedSize()
        }
    }

    private func hasStatusCluster(_ status: WorktreeRowStatus) -> Bool {
        status.diffAdded != nil
            || status.diffRemoved != nil
            || status.syncAhead != nil
            || status.syncBehind != nil
            || status.isRunning
    }

    /// Second line: PR number + truncated title, draft badge, CI glyph.
    @ViewBuilder
    private func worktreePRLine(_ status: WorktreeRowStatus) -> some View {
        if status.showsSecondLine {
            HStack(spacing: 4) {
                if let num = status.prNumber {
                    Label {
                        Text("PR #\(num)")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Color.accentColor.opacity(0.14),
                        in: Capsule()
                    )
                }
                if let title = status.prTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if status.isDraft {
                    Text("draft")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let glyph = status.checks {
                    checksGlyphView(glyph)
                }
            }
        }
    }

    @ViewBuilder
    private func checksGlyphView(_ glyph: ChecksGlyph) -> some View {
        switch glyph {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.red)
        case .pending:
            Image(systemName: "clock.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Legacy single-line rendering for host and project rows.
    private func legacyRowContent(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct PresentedInventoryWarning {
    let message: String
    let hostID: UUID?
}
