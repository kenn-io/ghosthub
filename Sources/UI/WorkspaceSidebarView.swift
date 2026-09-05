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
    case worktree(UUID)
    case tmuxSession(hostID: UUID, name: String)
    case herdrSession(hostID: UUID, name: String)
    case zellijSession(hostID: UUID, name: String)

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
        case "herdr":
            guard parts.count == 3,
                  let hostID = UUID(uuidString: String(parts[1]))
            else { return nil }
            self = .herdrSession(
                hostID: hostID,
                name: String(parts[2])
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
        case let .worktree(id):
            return "worktree:\(id.uuidString)"
        case let .tmuxSession(hostID, name):
            return "tmux:\(hostID.uuidString):\(name)"
        case let .herdrSession(hostID, name):
            return "herdr:\(hostID.uuidString):\(name)"
        case let .zellijSession(hostID, name):
            return "zellij:\(hostID.uuidString):\(name)"
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
        case let .herdrSession(hostID, name):
            return WorkspaceSidebarModel.herdrSessionOrderID(
                hostID: hostID,
                name: name
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

private struct WorktreeChangesTaskID: Hashable {
    let identity: WorktreeChangesIdentity
    let isEligible: Bool
    let manualRefreshRevision: UInt64
    let resumeRevision: UInt64
}

// MARK: - WorkspaceSidebarView

struct WorkspaceSidebarView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.terminalBackgroundAppearance)
    private var backgroundAppearance
    let snapshot: WorkspaceSnapshot
    let sectionCache: WorkspaceSidebarSectionCache?
    let snapshotRevision: UInt64
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
    let onRequestKillZellijSession: (WorkspaceZellijSessionSelection) -> Void
    let onRequestRemoveWorktree: (WorktreeSummary) -> Void
    let isWorktreeChangesPollingEligible: Bool
    let currentSnapshot: @MainActor () -> WorkspaceSnapshot
    let loadWorktreeChanges: WorktreeChangesLoader?
    let worktreeChangesSleep: WorktreeChangesSleep
    let onRequestRemoveProject: (ProjectSummary) -> Void
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
    @StateObject private var worktreeChanges = WorktreeChangesStore()
    @State private var hoveredProjectID: UUID?
    @State private var draggedSidebarItem: WorkspaceSidebarDragItem?
    @State private var reorderIndicator:
        WorkspaceSidebarReorderIndicator?
    @State private var tmuxPreviewExpansion =
        TmuxSessionPreviewExpansionState()
    @State private var tmuxPreviewMountState = TmuxSessionPreviewMountState()
    @AppStorage("workspaceSidebarDisclosureStateV2")
    private var disclosureState = ""
    @AppStorage("workspaceSidebarCollapsedItems")
    private var legacyCollapsedItems = ""
    @Binding private var worktreeOrderRawValue: String
    @Binding private var tmuxSessionOrderRawValue: String
    @Binding private var herdrSessionOrderRawValue: String
    @Binding private var zellijSessionOrderRawValue: String

    init(
        snapshot: WorkspaceSnapshot,
        sectionCache: WorkspaceSidebarSectionCache? = nil,
        snapshotRevision: UInt64 = 0,
        selection: Binding<WorkspaceSelection>,
        visibility: WorktreeVisibility,
        tmuxSessionVisibility: TmuxSessionVisibility = TmuxSessionVisibility(),
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeHerdrSession: WorkspaceHerdrSessionSelection? = nil,
        activeZellijSession: WorkspaceZellijSessionSelection? = nil,
        activeTmuxSessionIsConnected: Bool = false,
        connectedTmuxSessionIDs: Set<String> = [],
        workingTmuxSessionIDs: Set<String> = [],
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
        worktreeOrderRawValue: Binding<String> = .constant(""),
        tmuxSessionOrderRawValue: Binding<String> = .constant(""),
        herdrSessionOrderRawValue: Binding<String> = .constant(""),
        zellijSessionOrderRawValue: Binding<String> = .constant(""),
        onOpen: @escaping (WorktreeSummary) -> Void = { _ in }
    ) {
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
        self.onRequestKillZellijSession = onRequestKillZellijSession
        self.onRequestRemoveWorktree = onRequestRemoveWorktree
        self.isWorktreeChangesPollingEligible =
            isWorktreeChangesPollingEligible
        self.currentSnapshot = currentSnapshot ?? { snapshot }
        self.loadWorktreeChanges = loadWorktreeChanges
        self.worktreeChangesSleep = worktreeChangesSleep
        self.onRequestRemoveProject = onRequestRemoveProject
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
        _worktreeOrderRawValue = worktreeOrderRawValue
        _tmuxSessionOrderRawValue = tmuxSessionOrderRawValue
        _herdrSessionOrderRawValue = herdrSessionOrderRawValue
        _zellijSessionOrderRawValue = zellijSessionOrderRawValue
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
                worktreeOrderRawValue: worktreeOrderRawValue,
                tmuxSessionOrderRawValue: tmuxSessionOrderRawValue,
                herdrSessionOrderRawValue: herdrSessionOrderRawValue,
                zellijSessionOrderRawValue: zellijSessionOrderRawValue
            )
        } else {
            WorkspaceSidebarModel.sections(
                in: snapshot,
                visibility: visibility,
                tmuxSessionVisibility: tmuxSessionVisibility,
                connectedTmuxSessionIDs: connectedTmuxSessionIDs,
                liveTmuxWindowCounts: tmuxWindowCountsBySessionID,
                worktreeOrderRawValue: worktreeOrderRawValue,
                tmuxSessionOrderRawValue: tmuxSessionOrderRawValue,
                herdrSessionOrderRawValue: herdrSessionOrderRawValue,
                zellijSessionOrderRawValue: zellijSessionOrderRawValue
            )
        }
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
        .onAppear {
            migrateDisclosureStateIfNeeded()
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

    private func hostHeader(
        _ section: WorkspaceSidebarSection,
        disclosureKey: String
    ) -> some View {
        hierarchyRow(
            section.row,
            disclosureKey: disclosureKey,
            host: section.host,
            inventoryWarning: inventoryWarningsByHost[section.host.id]
        )
        .padding(.vertical, 1)
        .background {
            ZStack {
                // The sidebar column already paints the tinted surface when
                // transparent; repainting it here would compound the alpha
                // and make the header block more opaque than the rest.
                WorkspaceSurfaceColor.behindTerminal(backgroundAppearance)
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
    }

    @ViewBuilder
    private func hostContents(
        _ section: WorkspaceSidebarSection,
        disclosureKey: String
    ) -> some View {
        if isExpanded(disclosureKey) {
            VStack(alignment: .leading, spacing: 2) {
                let sessionsKey = WorkspaceSidebarDisclosureState
                    .sessions(section.host.id)
                sidebarGroupLabel(
                    "Tmux Sessions",
                    disclosureKey: sessionsKey,
                    action: sectionAction(
                        for: .tmuxSessions,
                        host: section.host
                    )
                )
                if isExpanded(sessionsKey) {
                    ForEach(section.tmuxSessionRows) { row in
                        tmuxSessionButton(
                            row,
                            orderedRows: section.tmuxSessionRows
                        )
                    }
                }
                if WorkspaceSidebarSectionActionModel.isVisible(
                    .herdrSessions,
                    host: section.host,
                    hasProjects: !section.projects.isEmpty
                ) {
                    let herdrSessionsKey = WorkspaceSidebarDisclosureState
                        .herdrSessions(section.host.id)
                    sidebarGroupLabel(
                        "Herdr Sessions",
                        disclosureKey: herdrSessionsKey,
                        action: sectionAction(
                            for: .herdrSessions,
                            host: section.host
                        )
                    )
                    if isExpanded(herdrSessionsKey) {
                        ForEach(section.herdrSessionRows) { row in
                            herdrSessionButton(
                                row,
                                orderedRows: section.herdrSessionRows
                            )
                        }
                    }
                }
                if WorkspaceSidebarSectionActionModel.isVisible(
                    .zellijSessions,
                    host: section.host,
                    hasProjects: !section.projects.isEmpty
                ) {
                    let zellijSessionsKey = WorkspaceSidebarDisclosureState
                        .zellijSessions(section.host.id)
                    sidebarGroupLabel(
                        "Zellij Sessions",
                        disclosureKey: zellijSessionsKey,
                        action: sectionAction(
                            for: .zellijSessions,
                            host: section.host
                        )
                    )
                    if isExpanded(zellijSessionsKey) {
                        ForEach(section.zellijSessionRows) { row in
                            zellijSessionButton(
                                row,
                                orderedRows: section.zellijSessionRows
                            )
                        }
                    }
                }
                if WorkspaceSidebarSectionActionModel.isVisible(
                    .projects,
                    host: section.host,
                    hasProjects: !section.projects.isEmpty
                        || !section.directoryWorkspaceRows.isEmpty
                ) {
                    let projectsKey = WorkspaceSidebarDisclosureState
                        .projects(section.host.id)
                    sidebarGroupLabel(
                        "Projects",
                        disclosureKey: projectsKey,
                        action: sectionAction(
                            for: .projects,
                            host: section.host
                        )
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
                                    Divider()
                                    Button(
                                        "Open All Worktrees as Tabs"
                                    ) {
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
                                    if snapshot.host(
                                        id: project.project.hostID
                                    )?.canRegisterProjects == true {
                                        Divider()
                                        Button(
                                            "Remove Project…",
                                            role: .destructive
                                        ) {
                                            onRequestRemoveProject(
                                                project.project
                                            )
                                        }
                                    }
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
                            ForEach(section.directoryWorkspaceRows) { row in
                                tmuxPreviewRow(
                                    row,
                                    content: AnyView(sidebarButton(row))
                                )
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        let content = AnyView(reorderableRow(
            sidebarButton(row),
            item: item,
            groupItems: groupItems,
            orderRawValue: tmuxSessionOrderRawValue
        ) { updatedRawValue in
            tmuxSessionOrderRawValue = updatedRawValue
        })
        return tmuxPreviewRow(row, content: content)
    }

    private func herdrSessionButton(
        _ row: WorkspaceSidebarRow,
        orderedRows: [WorkspaceSidebarRow]
    ) -> some View {
        guard case let .herdrSession(hostID, name) = row.target else {
            return AnyView(sidebarButton(row))
        }
        let item = WorkspaceSidebarDragItem.herdrSession(
            hostID: hostID,
            name: name
        )
        let groupItems: [WorkspaceSidebarDragItem] = orderedRows.compactMap {
            orderedRow in
            guard case let .herdrSession(orderedHostID, orderedName) =
                orderedRow.target
            else { return nil }
            return WorkspaceSidebarDragItem.herdrSession(
                hostID: orderedHostID,
                name: orderedName
            )
        }
        return AnyView(
            reorderableRow(
                sidebarButton(row),
                item: item,
                groupItems: groupItems,
                orderRawValue: herdrSessionOrderRawValue
            ) { updatedRawValue in
                herdrSessionOrderRawValue = updatedRawValue
            }
        )
    }

    private func zellijSessionButton(
        _ row: WorkspaceSidebarRow,
        orderedRows: [WorkspaceSidebarRow]
    ) -> some View {
        guard case let .zellijSession(hostID, name) = row.target else {
            return AnyView(sidebarButton(row))
        }
        let item = WorkspaceSidebarDragItem.zellijSession(
            hostID: hostID,
            name: name
        )
        let groupItems: [WorkspaceSidebarDragItem] = orderedRows.compactMap {
            orderedRow in
            guard case let .zellijSession(orderedHostID, orderedName) =
                orderedRow.target
            else { return nil }
            return WorkspaceSidebarDragItem.zellijSession(
                hostID: orderedHostID,
                name: orderedName
            )
        }
        return AnyView(
            reorderableRow(
                sidebarButton(row),
                item: item,
                groupItems: groupItems,
                orderRawValue: zellijSessionOrderRawValue
            ) { updatedRawValue in
                zellijSessionOrderRawValue = updatedRawValue
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
        let herdrActions = WorkspaceSidebarRowActionModel.actions(
            for: row,
            in: snapshot,
            pendingHerdrSessions: pendingHerdrSessions
        ).filter {
            if case .killTmuxSession = $0 {
                return false
            }
            if case .killZellijSession = $0 {
                return false
            }
            return true
        }
        let herdrSelection: WorkspaceHerdrSessionSelection? = {
            guard case let .herdrSession(hostID, name) = row.target else {
                return nil
            }
            return WorkspaceHerdrSessionSelection(hostID: hostID, name: name)
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
            isSelected: herdrSelection != nil && isSelected
        )
        return HStack(spacing: 0) {
            Button {
                if case let .herdrSession(hostID, name) = row.target {
                    let herdrSelection = WorkspaceHerdrSessionSelection(
                        hostID: hostID,
                        name: name
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
                if case let .tmuxSession(hostID, name) = row.target {
                    let tmuxSelection = WorkspaceTmuxSessionSelection(
                        hostID: hostID,
                        name: name
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
                            subtitle: row.subtitle,
                            sessionIsRunning: row.sessionIsRunning
                        )
                    }
                    Spacer(minLength: 0)
                    if isTmuxSessionWorking {
                        tmuxSessionActivityIndicator
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
                .padding(.trailing, reservedTrailingActionWidth)
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

    static func isRowSelected(
        _ row: WorkspaceSidebarRow,
        selection: WorkspaceSelection,
        rowTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeTmuxSession: WorkspaceTmuxSessionSelection?,
        activeHerdrSession: WorkspaceHerdrSessionSelection?,
        activeZellijSession: WorkspaceZellijSessionSelection? = nil
    ) -> Bool {
        if case let .herdrSession(hostID, name) = row.target {
            return activeHerdrSession == WorkspaceHerdrSessionSelection(
                hostID: hostID,
                name: name
            )
        }
        if case let .tmuxSession(hostID, name) = row.target {
            return activeTmuxSession == WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: name
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
        let isExpanded = worktreeChanges.isExpanded(worktreeID)
        let isActionHovered = hoveredWorktreeActionID == worktreeID
        let actionPresentation =
            WorkspaceWorktreeRemovalActionPresentation(
                isRemovable: isRemovable,
                isRowHovered: hoveredWorktreeID == worktreeID,
                isActionHovered: isActionHovered,
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
                Button(isExpanded ? "Hide Changes" : "Show Changes") {
                    worktreeChanges.setExpanded(
                        !isExpanded,
                        worktreeID: worktreeID
                    )
                }
                if let runningTmuxSession {
                    Divider()
                    Button("Kill Session…", role: .destructive) {
                        onRequestKillTmuxSession(runningTmuxSession)
                    }
                }
                if isRemovable {
                    if runningTmuxSession == nil {
                        Divider()
                    }
                    Button("Remove Worktree…", role: .destructive) {
                        onRequestRemoveWorktree(worktree)
                    }
                }
            }
            .accessibilityAction(
                named: isExpanded ? "Hide Changes" : "Show Changes"
            ) {
                worktreeChanges.setExpanded(
                    !isExpanded,
                    worktreeID: worktreeID
                )
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
        let entry = worktreeChanges.entry(for: identity)
        let taskID = WorktreeChangesTaskID(
            identity: identity,
            isEligible: isWorktreeChangesPollingEligible,
            manualRefreshRevision: entry.manualRefreshRevision,
            resumeRevision: entry.resumeRevision
        )
        return AnyView(
            WorktreeChangesView(
                entry: entry,
                onRefresh: {
                    worktreeChanges.requestManualRefresh(
                        for: identity,
                        refreshInventory: onRefreshInventory
                    )
                }
            )
            .task(id: taskID) {
                await WorktreeChangesPollLoop.run(
                    identity: identity,
                    worktree: worktree,
                    store: worktreeChanges,
                    currentSnapshot: currentSnapshot,
                    isEligible: { isWorktreeChangesPollingEligible },
                    load: loadWorktreeChanges,
                    sleep: worktreeChangesSleep
                )
            }
        )
    }

    private func tmuxPreviewRow(
        _ row: WorkspaceSidebarRow,
        content: AnyView
    ) -> AnyView {
        guard let tmuxSession = tmuxSessionSelection(for: row),
              TmuxSessionPreviewRowPresentation.canDisclose(
                  mode: sessionPreviewMode,
                  sessionID: tmuxSession.id,
                  previewableSessionIDs: previewableTmuxSessionIDs
              )
        else { return content }
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
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 18, height: 28)
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
                        .padding(.leading, 18)
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
        host: HostSummary? = nil,
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
                    host: host,
                    accessibilityLabel:
                    "Show connection issue for \(row.title)"
                )
            }
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

    private func sectionAction(
        for section: WorkspaceSidebarInventorySection,
        host: HostSummary
    ) -> WorkspaceSidebarSectionAction? {
        WorkspaceSidebarSectionActionModel.action(
            for: section,
            host: host,
            onNewTmuxSession: onNewTmuxSession,
            onNewHerdrSession: onNewHerdrSession,
            onNewZellijSession: onNewZellijSession,
            onAddProject: onAddProject
        )
    }

    private func sidebarGroupLabel(
        _ title: String,
        disclosureKey: String,
        action: WorkspaceSidebarSectionAction? = nil
    ) -> some View {
        let expanded = isExpanded(disclosureKey)
        return HStack(spacing: 0) {
            Button {
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
                .contentShape(Rectangle())
                .padding(.leading, 8)
                .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            .workspaceAccessibility(
                WorkspaceAccessibilityModel.disclosureDescriptor(
                    title: title,
                    isExpanded: expanded
                )
            )
            .accessibilityIdentifier(
                "sidebar-section-disclosure-\(disclosureKey)"
            )

            if let action {
                Button(action: action.perform) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(action.help)
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityIdentifier(
                    action.accessibilityIdentifier
                )
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(
            colorSchemeContrast == .increased
                ? Color.primary : Color.secondary
        )
        .padding(.top, 5)
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
        let hostsByID = snapshot.hostsByID
        let projectsByID = snapshot.projectsByID
        let worktreeChangeIdentities = Set(
            snapshot.worktrees.compactMap { worktree in
                WorktreeChangesIdentity.resolve(
                    worktree: worktree,
                    host: hostsByID[worktree.hostID],
                    project: projectsByID[worktree.projectID]
                )
            }
        )
        worktreeChanges.prune(keeping: worktreeChangeIdentities)
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

        var tmuxSessionOrder = WorkspaceSidebarOrder(
            rawValue: tmuxSessionOrderRawValue
        )
        let tmuxSessionIDs = Set(snapshot.hosts.flatMap { host in
            host.tmuxSessions.map {
                WorkspaceSidebarModel.tmuxSessionOrderID(
                    hostID: host.id,
                    name: $0.name
                )
            }
        })
        if tmuxSessionOrder.prune(keeping: tmuxSessionIDs) {
            tmuxSessionOrderRawValue = tmuxSessionOrder.rawValue
        }

        var herdrSessionOrder = WorkspaceSidebarOrder(
            rawValue: herdrSessionOrderRawValue
        )
        let herdrSessionIDs = Set(snapshot.hosts.flatMap { host in
            host.herdrSessions.map {
                WorkspaceSidebarModel.herdrSessionOrderID(
                    hostID: host.id,
                    name: $0.name
                )
            }
        })
        if herdrSessionOrder.prune(keeping: herdrSessionIDs) {
            herdrSessionOrderRawValue = herdrSessionOrder.rawValue
        }

        var zellijSessionOrder = WorkspaceSidebarOrder(
            rawValue: zellijSessionOrderRawValue
        )
        let zellijSessionIDs = Set(snapshot.hosts.flatMap { host in
            host.zellijSessions.map {
                WorkspaceSidebarModel.zellijSessionOrderID(
                    hostID: host.id,
                    name: $0.name
                )
            }
        })
        if zellijSessionOrder.prune(keeping: zellijSessionIDs) {
            zellijSessionOrderRawValue = zellijSessionOrder.rawValue
        }
    }

    /// Two-line status row for worktrees: title + trailing status cluster on
    /// line 1; optional PR info on line 2.
    private func worktreeRowContent(
        _ title: String,
        status: WorktreeRowStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            WorktreeRowLine(title: title, status: status)
            worktreePRLine(status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    private func legacyRowContent(
        title: String,
        subtitle: String?,
        sessionIsRunning: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if sessionIsRunning {
                    Image(systemName: "play.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
