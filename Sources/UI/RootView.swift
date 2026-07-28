import AppKit
import GhosthubSettings
import SwiftUI
import GhosthubWorkspace

public struct RootView: View {
    private let display: WorkspaceDisplayState
    private let content: ContentBuilders
    private let handlers: InteractionHandlers
    @Binding private var selection: WorkspaceSelection
    @Binding private var isSidePanelVisible: Bool
    @Binding private var columnVisibility: NavigationSplitViewVisibility
    @Binding private var isCommandPalettePresented: Bool
    @Binding private var isLogViewerPresented: Bool
    @Binding private var isSettingsPresented: Bool
    @ObservedObject private var settingsStore: SettingsStore
    /// Tracks whether the sidebar was auto-collapsed due to narrow
    /// window width so we can auto-expand it when the window grows.
    @State private var sidebarAutoCollapsed = false
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var lastKnownWindowWidth: CGFloat = 0
    @State private var sidePanelAutoCollapsed = false
    @State private var sidePanelUserOverride = false
    @State private var tmuxSelectionBaseline: WorkspaceSelection?
    @State private var newWorktreeProject: ProjectSummary?
    @State private var newWorktreeMode: NewWorktreeMode = .branch
    @State private var newTmuxSessionHost: HostSummary?
    @State private var addProjectHost: HostSummary?
    @State private var sessionKillAlert: SessionKillAlert?

    public init(
        display: WorkspaceDisplayState,
        content: ContentBuilders = ContentBuilders(),
        handlers: InteractionHandlers = InteractionHandlers(),
        settingsStore: SettingsStore = .shared,
        selection: Binding<WorkspaceSelection>,
        isSidePanelVisible: Binding<Bool> = .constant(false),
        columnVisibility: Binding<NavigationSplitViewVisibility> = .constant(.all),
        isCommandPalettePresented: Binding<Bool> = .constant(false),
        isLogViewerPresented: Binding<Bool> = .constant(false),
        isSettingsPresented: Binding<Bool> = .constant(false)
    ) {
        self.display = display
        self.content = content
        self.handlers = handlers
        self.settingsStore = settingsStore
        _selection = selection
        _isSidePanelVisible = isSidePanelVisible
        _columnVisibility = columnVisibility
        _isCommandPalettePresented = isCommandPalettePresented
        _isLogViewerPresented = isLogViewerPresented
        _isSettingsPresented = isSettingsPresented
    }

    // MARK: - Convenience accessors

    private var snapshot: WorkspaceSnapshot { display.snapshot }
    private var activeTmuxSession: WorkspaceTmuxSessionSelection? {
        display.activeTmuxSession
    }
    public var body: some View {
        contentWithNotifications
            .sheet(isPresented: $isCommandPalettePresented) {
                CommandPaletteView(
                    commands: paletteCommands,
                    onSelect: perform
                )
            }
            .sheet(isPresented: $isSettingsPresented) {
                if let settingsSheetBuilder = content.settingsSheetBuilder {
                    settingsSheetBuilder(settingsStore)
                }
            }
            .sheet(isPresented: $isLogViewerPresented) {
                logViewerSheet
            }
            .sheet(item: $newWorktreeProject) { project in
                NewWorktreeSheet(
                    project: project,
                    projects: workspaceActionProjects,
                    hosts: snapshot.hosts,
                    initialMode: newWorktreeMode,
                    onCreate: { request in
                        guard let create = handlers.createWorktree else {
                            return
                        }
                        try await create(request)
                    },
                    onListBranches: { projectID in
                        guard let list = handlers.listBranches else {
                            return []
                        }
                        return try await list(projectID)
                    },
                    onListPullRequests: { projectID in
                        guard let list = handlers.listPullRequests else {
                            return []
                        }
                        return try await list(projectID)
                    },
                    onImportPullRequest: { request in
                        guard let importPullRequest =
                            handlers.importPullRequest
                        else {
                            return
                        }
                        try await importPullRequest(request)
                    },
                    onCancel: { newWorktreeProject = nil }
                )
            }
            .sheet(item: $newTmuxSessionHost) { host in
                NewTmuxSessionSheet(
                    host: host,
                    hosts: snapshot.hosts,
                    onCreate: { selectedHost, name in
                        createTmuxSession(on: selectedHost, name: name)
                        newTmuxSessionHost = nil
                    },
                    onCancel: { newTmuxSessionHost = nil }
                )
            }
            .sheet(item: $addProjectHost) { host in
                AddProjectSheet(
                    host: host,
                    onAdd: { path in
                        guard let registerProject =
                            handlers.registerProject
                        else {
                            return .failure(.message(
                                "Project registration is unavailable."
                            ))
                        }
                        return await registerProject(host, path)
                    },
                    onCancel: { addProjectHost = nil },
                    onAdded: { addProjectHost = nil }
                )
            }
            .alert(item: $sessionKillAlert) { alert in
                sessionKillAlertView(alert)
            }
    }

    private var contentWithNotifications: some View {
        workspaceContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                lastKnownWindowWidth = width
                applySidebarAutoCollapse(windowWidth: width)
                applySidePanelAutoCollapse(windowWidth: width)
            }
            .onChange(of: sidebarWidth) { _, _ in
                guard lastKnownWindowWidth > 0 else { return }
                applySidePanelAutoCollapse(
                    windowWidth: lastKnownWindowWidth
                )
            }
            .onChange(of: snapshot) { _, updatedSnapshot in
                selection = selection.normalizedBySelectingVisibleFallback(
                    in: updatedSnapshot,
                    visibility: worktreeVisibility
                )
                synchronizeSelectedWorktreeSession()
            }
            .modifier(
                TmuxSessionPresentationLifecycleModifier(
                    selection: selection,
                    selectionBaseline: tmuxSelectionBaseline,
                    activeSession: activeTmuxSession,
                    isWorkspaceVisible: true,
                    deactivate: deactivateTmuxSession
                )
            )
            .onAppear {
                normalizeSelectionForWorktreeVisibilityChanges()
                synchronizeSelectedWorktreeSession()
            }
            .onChange(of: worktreeVisibility) { _, _ in
                normalizeSelectionForWorktreeVisibilityChanges()
                synchronizeSelectedWorktreeSession()
            }
            .onChange(of: selection) { _, _ in
                synchronizeSelectedWorktreeSession()
            }
            .onChange(of: activeTmuxSession) { _, activeSession in
                if activeSession == nil {
                    tmuxSelectionBaseline = nil
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .ghosthubNewWorktree
                )
            ) { _ in handleNewWorktreeNotification() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .ghosthubCloseTab
                )
            ) { _ in handleCloseTabNotification() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .ghosthubCommandPalette
                )
            ) { _ in handleCommandPalette() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .ghosthubToggleSidebar
                )
            ) { _ in handleToggleSidebar() }
    }

    private var logViewerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Application Log")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") {
                    handlers.dismissLogViewer?()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                if let view = content.logViewerBuilder?() {
                    view
                } else {
                    ContentUnavailableView(
                        "Log viewer unavailable",
                        systemImage: "doc.text",
                        description: Text(
                            "Terminal runtime is not ready."
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 400, idealHeight: 500)
        .onDisappear {
            handlers.dismissLogViewer?()
        }
    }

    @State private var sidebarWidth =
        WorkspaceSidebarWidthPolicy.defaultWidth
    /// Absolute X where the sidebar drag started (in the
    /// workspace coordinate space).
    @State private var sidebarDragStartX: CGFloat?
    @State private var sidebarDragStartWidth: CGFloat?

    private static let dividerVisual =
        WorkspaceSidebarWidthPolicy.dividerVisualWidth
    private static let dividerHit =
        WorkspaceSidebarWidthPolicy.dividerHitWidth
    private static let columnSpace = "workspaceColumns"

    private var workspaceContent: some View {
        workspaceColumns
            .background(WorkspaceSurfaceColor.color)
    }

    private var workspaceColumns: some View {
        GeometryReader { _ in
            HStack(spacing: 0) {
                if isSidebarVisible {
                    workspaceSidebarColumn
                        .frame(width: sidebarWidth)

                    columnDivider
                        .gesture(sidebarDragGesture)
                }

                terminalWorkspaceContent
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )

            }
            .coordinateSpace(name: Self.columnSpace)
        }
    }

    private var columnDivider: some View {
        ResizeCursorView()
            .frame(width: Self.dividerHit)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: Self.dividerVisual)
            }
            .contentShape(Rectangle())
    }

    /// NSView that registers a cursor rect so the resize
    /// cursor shows reliably regardless of adjacent views.
    private struct ResizeCursorView: NSViewRepresentable {
        func makeNSView(context: Context) -> CursorRectView {
            CursorRectView()
        }

        func updateNSView(
            _ nsView: CursorRectView,
            context: Context
        ) {
            nsView.window?.invalidateCursorRects(for: nsView)
        }
    }

    private final class CursorRectView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    private var sidebarDragGesture: some Gesture {
        DragGesture(
            minimumDistance: 1,
            coordinateSpace: .named(Self.columnSpace)
        )
        .onChanged { value in
            if sidebarDragStartX == nil {
                sidebarDragStartX = value.startLocation.x
                sidebarDragStartWidth = sidebarWidth
            }
            guard let startX = sidebarDragStartX,
                  let startW = sidebarDragStartWidth
            else { return }
            sidebarWidth = WorkspaceSidebarWidthPolicy.draggedWidth(
                startWidth: startW,
                startX: startX,
                currentX: value.location.x
            )
        }
        .onEnded { _ in
            sidebarDragStartX = nil
            sidebarDragStartWidth = nil
        }
    }

    private var workspaceSidebarColumn: some View {
        WorkspaceSidebarView(
            snapshot: snapshot,
            selection: $selection,
            visibility: worktreeVisibility,
            activeTmuxSession: activeTmuxSession,
            activeTmuxSessionIsConnected:
            display.activeTmuxSessionIsConnected,
            onOpenTmuxSession: { session in
                activateTmuxSession(session)
            },
            onNavigateAwayFromTmuxSession: {
                deactivateTmuxSession()
            },
            onRequestKillTmuxSession: requestSessionKill,
            onNewWorktree: openNewWorktree,
            onImportPullRequest: openImportPullRequest,
            onNewTmuxSession: { host in
                newTmuxSessionHost = host
            },
            onAddProject: { host in
                addProjectHost = host
            },
            onRefreshInventory: {
                handlers.refreshWorkspaceInventory?()
            },
            onOpenHostSettings: {
                settingsStore.selectedDomain = .hosts
                isSettingsPresented = true
            },
            inventoryWarning: display.workspaceInventoryWarning,
            inventoryWarningsByHost:
            display.workspaceInventoryWarningsByHost,
            onOpen: { worktree in
                selection.select(
                    .worktree(worktree.id),
                    in: snapshot,
                    visibility: worktreeVisibility
                )
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceSurfaceColor.color)
    }

    private func activateTmuxSession(_ session: WorkspaceTmuxSessionSelection) {
        if activeTmuxSession == session {
            tmuxSelectionBaseline = selection
            handlers.openTmuxSession?(session)
            return
        }
        if let previous = activeTmuxSession {
            handlers.closeTmuxSession?(previous)
        }
        tmuxSelectionBaseline = selection
        handlers.openTmuxSession?(session)
    }

    private func createTmuxSession(on host: HostSummary, name: String) {
        let session = WorkspaceTmuxSessionSelection(
            hostID: host.id,
            name: name
        )
        if let previous = activeTmuxSession {
            handlers.closeTmuxSession?(previous)
        }
        selection = Self.selectionForHostTmuxSession(
            session,
            from: selection,
            in: snapshot,
            visibility: worktreeVisibility
        )
        tmuxSelectionBaseline = selection
        handlers.createTmuxSession?(session)
    }

    private func requestSessionKill(
        _ tmuxSession: WorkspaceTmuxSessionSelection
    ) {
        guard let prepare = handlers.prepareTmuxSessionKill else {
            sessionKillAlert = .failure(
                session: tmuxSession.name,
                message: "Session termination is unavailable."
            )
            return
        }
        Task {
            do {
                sessionKillAlert = await .confirmation(
                    try prepare(tmuxSession)
                )
            } catch {
                sessionKillAlert = .failure(
                    session: tmuxSession.name,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func sessionKillAlertView(_ alert: SessionKillAlert) -> Alert {
        switch alert {
        case let .confirmation(request):
            let tmuxSession = request.session
            let recreation = tmuxSession.worktreeID == nil
                ? ""
                : " Reopening this worktree may create the session again."
            return Alert(
                title: Text("Kill “\(tmuxSession.name)”?”"),
                message: Text(
                    "This permanently terminates every window, pane, and"
                        + " process in this tmux session on "
                        + "\(request.confirmedHost.sidebarTitle)."
                        + recreation
                ),
                primaryButton: .destructive(Text("Kill Session")) {
                    Task {
                        do {
                            guard let kill = handlers.killTmuxSession else {
                                throw SessionKillUnavailableError()
                            }
                            try await kill(request)
                        } catch {
                            sessionKillAlert = .failure(
                                session: tmuxSession.name,
                                message: error.localizedDescription
                            )
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        case let .failure(session, message):
            return Alert(
                title: Text("Could Not Kill “\(session)”"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    static func selectionForHostTmuxSession(
        _ session: WorkspaceTmuxSessionSelection,
        from current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility
    ) -> WorkspaceSelection {
        var updated = current
        updated.select(
            .tmuxSession(hostID: session.hostID, name: session.name),
            in: snapshot,
            visibility: visibility
        )
        return updated
    }

    private func deactivateTmuxSession() {
        guard let previous = activeTmuxSession else { return }
        tmuxSelectionBaseline = nil
        handlers.closeTmuxSession?(previous)
    }

    private var selectedWorktreeTmuxSession:
        WorkspaceTmuxSessionSelection? {
        WorkspaceSidebarModel.tmuxSessionSelection(
            for: selection,
            in: snapshot
        )
    }

    private func synchronizeSelectedWorktreeSession() {
        guard let session = selectedWorktreeTmuxSession else {
            if activeTmuxSession?.worktreeID != nil {
                deactivateTmuxSession()
            }
            return
        }
        guard activeTmuxSession != session else { return }
        activateTmuxSession(session)
    }

    @ViewBuilder
    private var terminalWorkspaceContent: some View {
        if let presentedSession = selectedWorktreeTmuxSession
            ?? activeTmuxSession,
            let host = snapshot.host(id: presentedSession.hostID),
            activeTmuxSession == presentedSession,
            let view = content.tmuxSessionContentBuilder?(
                host,
                presentedSession.name
            ) {
            view
        } else if let pendingSession = selectedWorktreeTmuxSession {
            ProgressView("Opening \(displayName(for: pendingSession))…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selection.selectedWorktreeID != nil {
            ContentUnavailableView {
                Label("No tmux session", systemImage: "terminal")
            } description: {
                Text(
                    "This kwt workspace does not currently report a tmux session."
                )
            } actions: {
                if let refresh = handlers.refreshWorkspaceInventory {
                    Button("Refresh", action: refresh)
                }
            }
        } else if display.isWorkspaceInventoryLoading {
            ProgressView("Loading workspaces…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = display.workspaceInventoryError {
            ContentUnavailableView {
                Label(
                    "Unable to refresh workspaces",
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(error)
            } actions: {
                if let refresh = handlers.refreshWorkspaceInventory {
                    Button("Retry", action: refresh)
                }
            }
        } else if snapshot.projects.isEmpty,
                  snapshot.hosts.allSatisfy(\.tmuxSessions.isEmpty) {
            VStack(spacing: 14) {
                Text("Welcome to Ghosthub")
                    .font(.system(size: 24, weight: .semibold))
                Text(
                    "Your kwt workspaces and tmux sessions will appear in the sidebar."
                )
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                Text(
                    "Register projects with kwt, or add an SSH host in Settings. Ghosthub attaches without taking over tmux windows, panes, or history."
                )
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Active Session",
                systemImage: "terminal",
                description: Text(
                    "Select a tmux session or kwt workspace from the sidebar."
                )
            )
        }
    }

    private var worktreeVisibility: WorktreeVisibility {
        WorktreeVisibility(
            hideRootWorktrees: settingsStore.worktreePreferences.hideRootCheckout,
            showHiddenWorktrees: settingsStore.worktreePreferences.showHiddenWorktreesByDefault
        )
    }

    private var paletteCommands: [WorkspaceCommandItem] {
        CommandPaletteModel.commands(
            in: snapshot,
            selection: selection,
            activeTmuxSession: activeTmuxSession,
            activeTmuxSessionIsConnected:
            display.activeTmuxSessionIsConnected,
            isWorkspacesRoute: true,
            isSidebarVisible: isSidebarVisible,
            isSidePanelVisible: isSidePanelVisible,
            interfaceAppearance: settingsStore.interfaceAppearance,
            worktreeVisibility: worktreeVisibility,
            supportsSettings: content.settingsSheetBuilder != nil
        )
    }

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    private var workspaceActionProjects: [ProjectSummary] {
        snapshot.projects.filter {
            snapshot.canCreateWorktree(in: $0)
                || snapshot.canImportPullRequest(in: $0)
        }
    }

    private func displayName(
        for session: WorkspaceTmuxSessionSelection
    ) -> String {
        guard let worktreeID = session.worktreeID,
              let worktree = snapshot.worktree(id: worktreeID)
        else { return session.name }
        return worktree.name
    }

    private func perform(_ action: WorkspaceCommandAction) {
        switch action {
        case .toggleSidebar:
            toggleSidebar()
        case .openConfigDirectory:
            openConfigDirectory()
        case .reloadTerminalConfig:
            handlers.reloadTerminalConfig?()
        case .previousWorktree:
            if let updatedSelection = KeyboardNavigationModel.steppedSelection(
                from: selection,
                in: snapshot,
                step: -1,
                visibility: worktreeVisibility
            ) {
                selection = updatedSelection
            }
        case .nextWorktree:
            if let updatedSelection = KeyboardNavigationModel.steppedSelection(
                from: selection,
                in: snapshot,
                step: 1,
                visibility: worktreeVisibility
            ) {
                selection = updatedSelection
            }
        case let .newTmuxSession(hostID):
            guard let host = snapshot.host(id: hostID) else { return }
            newTmuxSessionHost = host
        case let .addProject(hostID):
            guard let host = snapshot.host(id: hostID) else { return }
            addProjectHost = host
        case let .openTmuxSession(tmuxSession):
            if let worktreeID = tmuxSession.worktreeID {
                selection.select(
                    .worktree(worktreeID),
                    in: snapshot,
                    visibility: worktreeVisibility
                )
            } else {
                selection = Self.selectionForHostTmuxSession(
                    tmuxSession,
                    from: selection,
                    in: snapshot,
                    visibility: worktreeVisibility
                )
            }
            activateTmuxSession(tmuxSession)
        case let .killTmuxSession(tmuxSession):
            requestSessionKill(tmuxSession)
        case let .newWorktree(projectID):
            guard let project = snapshot.project(id: projectID) else { return }
            openNewWorktree(project)
        case let .importPullRequest(projectID):
            guard let project = snapshot.project(id: projectID) else { return }
            openImportPullRequest(project)
        case let .openSettings(domain):
            guard content.settingsSheetBuilder != nil else { return }
            settingsStore.selectedDomain = domain
            isSettingsPresented = true
        case let .setInterfaceAppearance(appearance):
            settingsStore.setInterfaceAppearance(appearance)
        case let .select(target):
            selection.select(
                target,
                in: snapshot,
                visibility: worktreeVisibility
            )
        case .showLogViewer:
            isLogViewerPresented = true
        }
    }

    private func toggleSidebar() {
        let willCollapse = isSidebarVisible
        columnVisibility = willCollapse ? .detailOnly : .all
        if !willCollapse {
            sidebarAutoCollapsed = false
        }
        applySidePanelAutoCollapse(
            windowWidth: lastKnownWindowWidth
        )
    }

    private func applySidebarAutoCollapse(windowWidth: CGFloat) {
        let action = SidebarAutoCollapseModel.evaluate(
            windowWidth: windowWidth,
            isSidebarVisible: isSidebarVisible,
            wasAutoCollapsed: sidebarAutoCollapsed
        )
        switch action {
        case .collapse:
            columnVisibility = .detailOnly
            sidebarAutoCollapsed = true
        case .restore:
            columnVisibility = .all
            sidebarAutoCollapsed = false
        case .noChange:
            break
        }
    }

    private func applySidePanelAutoCollapse(
        windowWidth: CGFloat
    ) {
        let action = SidePanelAutoCollapseModel.evaluate(
            windowWidth: windowWidth,
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: sidebarWidth,
            isSidePanelVisible: isSidePanelVisible,
            wasAutoCollapsed: sidePanelAutoCollapsed,
            userOverride: sidePanelUserOverride
        )
        switch action {
        case .collapse:
            isSidePanelVisible = false
            sidePanelAutoCollapsed = true
        case .restore:
            isSidePanelVisible = true
            sidePanelAutoCollapsed = false
            sidePanelUserOverride = false
        case .clearOverride:
            sidePanelUserOverride = false
        case .noChange:
            break
        }
    }

    private func openConfigDirectory() {
        let directory = ConfigHome.resolved()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(directory)
        } catch {}
    }

    private func normalizeSelectionForWorktreeVisibilityChanges() {
        selection = selection.normalizedBySelectingVisibleFallback(
            in: snapshot,
            visibility: worktreeVisibility
        )
    }

    private func selectIndexedWorktree(_ index: Int) {
        if let updatedSelection = KeyboardNavigationModel.selectionForShortcutIndex(
            index,
            from: selection,
            in: snapshot,
            visibility: worktreeVisibility
        ) {
            selection = updatedSelection
        }
    }

    // MARK: - Notification handlers

    private func handleCloseTabNotification() {
        guard controlActiveState == .key else { return }
        handleCloseTab()
    }

    private func handleNewWorktreeNotification() {
        guard controlActiveState == .key,
              let project = WorkspaceSelectionResolver.selectedProject(
                  in: snapshot,
                  selection: selection
              )
        else { return }
        openNewWorktree(project)
    }

    private func openNewWorktree(_ project: ProjectSummary) {
        guard handlers.createWorktree != nil,
              snapshot.canCreateWorktree(in: project)
        else {
            return
        }
        newWorktreeMode = .branch
        newWorktreeProject = project
    }

    private func openImportPullRequest(_ project: ProjectSummary) {
        guard handlers.listPullRequests != nil,
              handlers.importPullRequest != nil,
              snapshot.canImportPullRequest(in: project)
        else {
            return
        }
        newWorktreeMode = .pullRequest
        newWorktreeProject = project
    }

    private func handleCommandPalette() {
        guard controlActiveState == .key else { return }
        isCommandPalettePresented = true
    }

    private func handleToggleSidebar() {
        guard controlActiveState == .key else { return }
        toggleSidebar()
    }

    private func handleCloseTab() {
        if Self.closeBorrowedSessionIfActive(
            activeTmuxSession,
            deactivate: deactivateTmuxSession
        ) {
            return
        }
        handlers.closeWindow?()
    }

    /// Borrowed sessions are presentation attachments rather than owned tmux
    /// tabs. Cmd-W and pane-originated close requests detach that presentation
    /// as one unit; they must never locally remove a leaf from tmux's
    /// authoritative layout or kill the borrowed pane.
    static func closeBorrowedSessionIfActive(
        _ activeSession: WorkspaceTmuxSessionSelection?,
        deactivate: () -> Void
    ) -> Bool {
        guard activeSession != nil else { return false }
        deactivate()
        return true
    }

}

/// Keeps a borrowed tmux attachment scoped to the workspace presentation.
/// Kept as a small modifier so route and removal lifecycle behavior can be
/// exercised without constructing the entire sidebar hierarchy.
struct TmuxSessionPresentationLifecycleModifier: ViewModifier {
    let selection: WorkspaceSelection
    let selectionBaseline: WorkspaceSelection?
    let activeSession: WorkspaceTmuxSessionSelection?
    let isWorkspaceVisible: Bool
    let deactivate: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, newSelection in
                if activeSession != nil,
                   let selectionBaseline,
                   newSelection != selectionBaseline {
                    deactivate()
                }
            }
            .onChange(of: isWorkspaceVisible) { _, isVisible in
                if !isVisible {
                    deactivate()
                }
            }
            .onDisappear {
                deactivate()
            }
    }
}

private enum SessionKillAlert: Identifiable {
    case confirmation(TmuxSessionKillRequest)
    case failure(session: String, message: String)

    var id: String {
        switch self {
        case let .confirmation(request):
            return "confirm:\(request.session.id)"
        case let .failure(session, message):
            return "failure:\(session):\(message)"
        }
    }
}

private struct SessionKillUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Session termination is unavailable."
    }
}
