import SwiftUI
import GhosthubWorkspace

// MARK: - WorkspaceSidebarView

struct WorkspaceSidebarView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let snapshot: WorkspaceSnapshot
    @Binding var selection: WorkspaceSelection
    let visibility: WorktreeVisibility
    let onOpen: (WorktreeSummary) -> Void
    let activeTmuxSession: WorkspaceTmuxSessionSelection?
    let onOpenTmuxSession: (WorkspaceTmuxSessionSelection) -> Void
    let onNavigateAwayFromTmuxSession: () -> Void
    let onNewWorktree: (ProjectSummary) -> Void
    let onImportPullRequest: (ProjectSummary) -> Void
    let onNewTmuxSession: (HostSummary) -> Void
    let onRefreshInventory: () -> Void
    let inventoryWarning: String?
    let inventoryWarningsByHost: [UUID: String]
    @AppStorage("workspaceSidebarDisclosureStateV2")
    private var disclosureState = ""
    @AppStorage("workspaceSidebarCollapsedItems")
    private var legacyCollapsedItems = ""

    init(
        snapshot: WorkspaceSnapshot,
        selection: Binding<WorkspaceSelection>,
        visibility: WorktreeVisibility,
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        onOpenTmuxSession: @escaping (
            WorkspaceTmuxSessionSelection
        ) -> Void = { _ in },
        onNavigateAwayFromTmuxSession: @escaping () -> Void = {},
        onNewWorktree: @escaping (ProjectSummary) -> Void = { _ in },
        onImportPullRequest: @escaping (ProjectSummary) -> Void = { _ in },
        onNewTmuxSession: @escaping (HostSummary) -> Void = { _ in },
        onRefreshInventory: @escaping () -> Void = {},
        inventoryWarning: String? = nil,
        inventoryWarningsByHost: [UUID: String] = [:],
        onOpen: @escaping (WorktreeSummary) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        _selection = selection
        self.visibility = visibility
        self.activeTmuxSession = activeTmuxSession
        self.onOpenTmuxSession = onOpenTmuxSession
        self.onNavigateAwayFromTmuxSession = onNavigateAwayFromTmuxSession
        self.onNewWorktree = onNewWorktree
        self.onImportPullRequest = onImportPullRequest
        self.onNewTmuxSession = onNewTmuxSession
        self.onRefreshInventory = onRefreshInventory
        self.inventoryWarning = inventoryWarning
        self.inventoryWarningsByHost = inventoryWarningsByHost
        self.onOpen = onOpen
    }

    // MARK: - Computed

    private var sections: [WorkspaceSidebarSection] {
        WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility
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
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            let hostKey = WorkspaceSidebarDisclosureState.host(
                                section.host.id
                            )
                            hierarchyRow(
                                section.row,
                                disclosureKey: hostKey,
                                addAction: {
                                    onNewTmuxSession(section.host)
                                },
                                addHelp: "New tmux session on "
                                    + section.host.sidebarTitle,
                                inventoryWarning:
                                inventoryWarningsByHost[section.host.id]
                            )
                            .contextMenu {
                                Button("New tmux session…") {
                                    onNewTmuxSession(section.host)
                                }
                            }
                            if isExpanded(hostKey) {
                                if !section.tmuxSessionRows.isEmpty {
                                    let sessionsKey =
                                        WorkspaceSidebarDisclosureState
                                            .sessions(section.host.id)
                                    sidebarGroupLabel(
                                        "Tmux Sessions",
                                        disclosureKey: sessionsKey
                                    )
                                    if isExpanded(sessionsKey) {
                                        ForEach(section.tmuxSessionRows) { row in
                                            sidebarButton(row)
                                        }
                                    }
                                }
                                if !section.projects.isEmpty {
                                    let projectsKey =
                                        WorkspaceSidebarDisclosureState
                                            .projects(section.host.id)
                                    sidebarGroupLabel(
                                        "Projects",
                                        disclosureKey: projectsKey
                                    )
                                    if isExpanded(projectsKey) {
                                        ForEach(section.projects) { project in
                                            let projectKey =
                                                WorkspaceSidebarDisclosureState
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
                                                    onImportPullRequest(
                                                        project.project
                                                    )
                                                }
                                                .disabled(
                                                    !snapshot.canImportPullRequest(
                                                        in: project.project
                                                    )
                                                )
                                            }
                                            if isExpanded(projectKey) {
                                                ForEach(
                                                    project.worktreeRows
                                                ) { row in
                                                    worktreeButton(row)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }
        }
        .onAppear(perform: migrateDisclosureStateIfNeeded)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Workspaces")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if let inventoryWarning {
                Button(action: onRefreshInventory) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("\(inventoryWarning)\nClick to retry.")
                .accessibilityLabel("Retry workspace inventory")
                .accessibilityValue(inventoryWarning)
            }
            Menu {
                Button("New tmux session…") {
                    guard let host = preferredNewSessionHost else { return }
                    onNewTmuxSession(host)
                }
                Divider()
                Button("New worktree…") {
                    guard let project = selectedProject else { return }
                    onNewWorktree(project)
                }
                .disabled(selectedProject == nil)
                Button("Import pull request…") {
                    guard let project = selectedImportProject else {
                        return
                    }
                    onImportPullRequest(project)
                }
                .disabled(selectedImportProject == nil)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .help("Create a tmux session or kwt worktree")
            .accessibilityLabel("Create workspace")
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

    // MARK: - Row builders

    private func sidebarButton(_ row: WorkspaceSidebarRow) -> some View {
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
        return Button {
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
                    legacyRowContent(title: row.title, subtitle: row.subtitle)
                }
                Spacer(minLength: 0)
                if isSelected, differentiateWithoutColor {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.leading, CGFloat(row.indentLevel) * 14)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(
                                colorSchemeContrast == .increased ? 0.42 : 0.28
                            )
                            : Color.clear
                    )
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            Color.primary.opacity(
                                colorSchemeContrast == .increased ? 0.55 : 0.24
                            ),
                            lineWidth: colorSchemeContrast == .increased
                                ? 1.5 : 1
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .workspaceAccessibility(
            WorkspaceAccessibilityModel.descriptor(
                for: row,
                isSelected: isSelected
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func worktreeButton(_ row: WorkspaceSidebarRow) -> some View {
        sidebarButton(row)
    }

    private func hierarchyRow(
        _ row: WorkspaceSidebarRow,
        disclosureKey: String,
        addAction: (() -> Void)? = nil,
        addHelp: String? = nil,
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
                    accessibilityLabel:
                    "Retry inventory for \(row.title)"
                )
            }

            if let addAction, let addHelp {
                Button(action: addAction) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(addHelp)
                .accessibilityLabel(addHelp)
                .accessibilityIdentifier("new-tmux-session")
            }
        }
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

            Menu {
                Button("New Worktree…") {
                    onNewWorktree(project.project)
                }
                .disabled(!canCreate)
                Button("Import Pull Request…") {
                    onImportPullRequest(project.project)
                }
                .disabled(!canImport)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .help(projectActionHelp(for: project.project))
            .accessibilityLabel(
                "Project actions for \(project.project.sidebarTitle)"
            )
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
            Image(
                systemName: expanded
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
        .buttonStyle(.plain)
        .workspaceAccessibility(
            WorkspaceAccessibilityModel.disclosureDescriptor(
                title: row.title,
                isExpanded: expanded
            )
        )
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
        accessibilityLabel: String
    ) -> some View {
        Button(action: onRefreshInventory) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(warning)\nClick to retry.")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(warning)
        .accessibilityIdentifier("host-inventory-warning")
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
