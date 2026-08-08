import AppKit
import GhosthubSettings
import SwiftUI
import GhosthubWorkspace

public struct RootView: View {
    private let display: WorkspaceDisplayState
    private let content: ContentBuilders
    private let handlers: InteractionHandlers
    private let sidebarToggleTarget: AnyObject
    private let sidebarWidthChanged: (CGFloat) -> Void
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
    @State private var sidebarVisibilityProgress: CGFloat
    @State private var isSidebarTransitioning = false
    @State private var sidebarTransitionID = UUID()
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var lastKnownWindowWidth: CGFloat = 0
    @State private var sidePanelAutoCollapsed = false
    @State private var sidePanelUserOverride = false
    @State private var tmuxSelectionBaseline: WorkspaceSelection?
    @State private var newWorktreeProject: ProjectSummary?
    @State private var newWorktreeMode: NewWorktreeMode = .branch
    @State private var newTmuxSessionHost: HostSummary?
    @State private var addProjectHost: HostSummary?
    @State private var workspaceAlert: WorkspaceAlert?
    @State private var tmuxRecoveryRequestRouter =
        TmuxConnectionRecoveryRequestRouter()
    @StateObject private var sshHostKeyReview =
        WorkspaceSSHHostKeyReviewModel()
    @AppStorage(WorkspaceSidebarOrderStorage.worktreeKey)
    private var worktreeOrderRawValue = ""
    @AppStorage(WorkspaceSidebarOrderStorage.tmuxSessionKey)
    private var tmuxSessionOrderRawValue = ""

    public init(
        display: WorkspaceDisplayState,
        content: ContentBuilders = ContentBuilders(),
        handlers: InteractionHandlers = InteractionHandlers(),
        sidebarToggleTarget: AnyObject = NSObject(),
        sidebarWidthChanged: @escaping (CGFloat) -> Void = { _ in },
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
        self.sidebarToggleTarget = sidebarToggleTarget
        self.sidebarWidthChanged = sidebarWidthChanged
        self.settingsStore = settingsStore
        _selection = selection
        _isSidePanelVisible = isSidePanelVisible
        _columnVisibility = columnVisibility
        _isCommandPalettePresented = isCommandPalettePresented
        _isLogViewerPresented = isLogViewerPresented
        _isSettingsPresented = isSettingsPresented
        _sidebarVisibilityProgress = State(
            initialValue: columnVisibility.wrappedValue == .detailOnly ? 0 : 1
        )
    }

    // MARK: - Convenience accessors

    private var snapshot: WorkspaceSnapshot { display.snapshot }
    private var activeTmuxSession: WorkspaceTmuxSessionSelection? {
        display.activeTmuxSession
    }
    public var body: some View {
        contentWithNotifications
            .onAppear {
                reviewTmuxConnectionRequestIfNeeded()
            }
            .onChange(
                of: display.tmuxConnectionRecoveryRequest?.id
            ) { _, _ in
                reviewTmuxConnectionRequestIfNeeded()
            }
            .onChange(of: sshHostKeyReview.isPresented) { wasPresented, isPresented in
                guard wasPresented, !isPresented else { return }
                tmuxRecoveryRequestRouter.reviewDidDismiss()
                reviewTmuxConnectionRequestIfNeeded()
            }
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
            .sheet(
                isPresented: Binding(
                    get: { sshHostKeyReview.isPresented },
                    set: {
                        if !$0 {
                            cancelSSHAuthenticationIfNeeded()
                            sshHostKeyReview.dismiss()
                        }
                    }
                )
            ) {
                SSHHostKeyReviewView(
                    model: sshHostKeyReview,
                    onTrust: trustReviewedSSHHostKey,
                    onRetry: retrySSHRecovery,
                    onOpenHostSettings: openHostSettings,
                    onCancel: cancelSSHRecovery,
                    authenticationContent:
                    sshAuthenticationContent
                )
                .task(id: activeSSHAuthenticationHostID) {
                    await monitorSSHAuthentication()
                }
                .interactiveDismissDisabled(
                    sshHostKeyReview.isTrusting
                        || sshHostKeyReview.presentation == .authentication
                )
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
                    configuredHosts: settingsStore.sshHosts,
                    onCreate: { selectedHost, name, initialCommand in
                        createTmuxSession(
                            on: selectedHost,
                            name: name,
                            initialCommand: initialCommand
                        )
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
            .alert(item: $workspaceAlert) { alert in
                workspaceAlertView(alert)
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
            .onChange(of: sidebarWidth) { _, width in
                sidebarWidthChanged(width)
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
                    hide: hideTmuxSession
                )
            )
            .onAppear {
                sidebarWidthChanged(sidebarWidth)
                normalizeSelectionForWorktreeVisibilityChanges()
                synchronizeSelectedWorktreeSession()
                initializeTmuxSelectionBaselineIfNeeded()
            }
            .onChange(of: worktreeVisibility) { _, _ in
                normalizeSelectionForWorktreeVisibilityChanges()
                synchronizeSelectedWorktreeSession()
            }
            .onChange(of: selection) { _, _ in
                synchronizeSelectedWorktreeSession()
            }
            .onChange(
                of: display.suppressesAutomaticWorktreeSessionOpen
            ) { wasSuppressed, isSuppressed in
                guard wasSuppressed, !isSuppressed else { return }
                synchronizeSelectedWorktreeSession()
            }
            .onChange(of: activeTmuxSession) { _, activeSession in
                guard activeSession != nil else {
                    tmuxSelectionBaseline = nil
                    return
                }
                initializeTmuxSelectionBaselineIfNeeded()
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
                    for: .ghosthubToggleSidebar,
                    object: sidebarToggleTarget
                )
            ) { _ in handleToggleSidebar() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .ghosthubApplyThemeToCurrentSession
                )
            ) { _ in handleApplyThemeNotification() }
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
    private static let sidebarAnimationDuration = 0.2

    private var workspaceContent: some View {
        workspaceColumns
            .background(WorkspaceSurfaceColor.color)
    }

    private var workspaceColumns: some View {
        GeometryReader { _ in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(
                            width: (sidebarWidth + Self.dividerHit)
                                * sidebarVisibilityProgress
                        )

                    terminalWorkspaceContent
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                }
                HStack(spacing: 0) {
                    workspaceSidebarColumn
                        .frame(width: sidebarWidth)

                    columnDivider
                        .gesture(sidebarDragGesture)
                }
                .offset(
                    x: -(sidebarWidth + Self.dividerHit)
                        * (1 - sidebarVisibilityProgress)
                )
                .opacity(sidebarVisibilityProgress)
                .allowsHitTesting(isSidebarVisible)
                .accessibilityHidden(!isSidebarVisible)
            }
            .coordinateSpace(name: Self.columnSpace)
            .onChange(of: isSidebarVisible) { _, visible in
                animateSidebarVisibility(visible)
            }
        }
    }

    private func animateSidebarVisibility(_ visible: Bool) {
        let transitionID = UUID()
        sidebarTransitionID = transitionID
        isSidebarTransitioning = true
        withAnimation(
            .easeInOut(duration: Self.sidebarAnimationDuration),
            completionCriteria: .logicallyComplete
        ) {
            sidebarVisibilityProgress = visible ? 1 : 0
        } completion: {
            guard sidebarTransitionID == transitionID else { return }
            isSidebarTransitioning = false
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
            selection: Binding(
                get: { selection },
                set: { selectWorkspace($0) }
            ),
            visibility: worktreeVisibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            activeTmuxSession: activeTmuxSession,
            activeTmuxSessionIsConnected:
            display.activeTmuxSessionIsConnected,
            workingTmuxSessionIDs:
            display.workingTmuxSessionIDs,
            onOpenTmuxSession: { session in
                activateTmuxSession(session)
            },
            onNavigateAwayFromTmuxSession: {
                hideTmuxSession()
            },
            onRequestKillTmuxSession: requestSessionKill,
            onRequestRemoveWorktree: requestWorktreeRemoval,
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
                openHostSettings()
            },
            onReviewSSHHostKey: { hostID, inventoryWarning in
                reviewSSHHostKey(
                    hostID,
                    inventoryWarning: inventoryWarning
                )
            },
            inventoryWarning: display.workspaceInventoryWarning,
            inventoryWarningsByHost:
            display.workspaceInventoryWarningsByHost,
            inventoryRefreshComplete:
            display.isWorkspaceInventoryRefreshComplete,
            worktreeOrderRawValue: $worktreeOrderRawValue,
            tmuxSessionOrderRawValue: $tmuxSessionOrderRawValue,
            onOpen: { worktree in
                selectWorkspace(.worktree(worktree.id))
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceSurfaceColor.color)
    }

    private func reviewSSHHostKey(
        _ hostID: UUID,
        inventoryWarning: String,
        tmuxRecoveryRequestID: UUID? = nil
    ) {
        guard let review = handlers.reviewSSHHostKey,
              let host = snapshot.host(id: hostID) else {
            openHostSettings()
            return
        }
        Task {
            await sshHostKeyReview.review(
                hostID: hostID,
                hostName: host.name,
                tmuxRecoveryRequestID: tmuxRecoveryRequestID,
                using: {
                    await review(hostID, inventoryWarning)
                }
            )
        }
    }

    private func tmuxRecoveryWarning(for hostID: UUID) -> String {
        if let request = display.tmuxConnectionRecoveryRequest,
           request.hostID == hostID {
            return request.message
        }
        return display.workspaceInventoryWarningsByHost[hostID]
            ?? "The remote tmux connection needs attention."
    }

    private func reviewTmuxConnectionRequestIfNeeded() {
        Task { @MainActor in
            await Task.yield()
            guard let request = tmuxRecoveryRequestRouter.take(
                display.tmuxConnectionRecoveryRequest,
                whileReviewIsPresented: sshHostKeyReview.isPresented
            )
            else { return }
            reviewSSHHostKey(
                request.hostID,
                inventoryWarning: request.message,
                tmuxRecoveryRequestID: request.id
            )
        }
    }

    private func retrySSHRecovery() {
        let recoveryRequest =
            sshHostKeyReview.presentation == .inventoryIssue
                ? tmuxRecoveryRequestRouter.recoveryRequestToResume(
                    reviewedHostID: sshHostKeyReview.hostID,
                    reviewRequestID: sshHostKeyReview.tmuxRecoveryRequestID
                )
                : nil
        cancelSSHAuthenticationIfNeeded()
        sshHostKeyReview.dismiss()
        if let recoveryRequest {
            handlers.resumeTmuxReconnectAfterSSHRecovery?(recoveryRequest)
        }
        handlers.refreshWorkspaceInventory?()
    }

    private func trustReviewedSSHHostKey() {
        guard let trust = handlers.trustSSHHostKey else {
            openHostSettings()
            return
        }
        Task {
            await sshHostKeyReview.trust(
                using: trust,
                onTrusted: {}
            )
        }
    }

    private var activeSSHAuthenticationHostID: UUID? {
        guard sshHostKeyReview.presentation == .authentication else {
            return nil
        }
        return sshHostKeyReview.hostID
    }

    private var sshAuthenticationContent: AnyView? {
        guard let hostID = activeSSHAuthenticationHostID else { return nil }
        return content.sshAuthenticationBuilder?(hostID)
    }

    private func monitorSSHAuthentication() async {
        guard let hostID = activeSSHAuthenticationHostID,
              let isReady = handlers.isSSHAuthenticationReady else { return }
        while !Task.isCancelled,
              activeSSHAuthenticationHostID == hostID {
            let readiness = await isReady(hostID)
            guard !Task.isCancelled,
                  activeSSHAuthenticationHostID == hostID
            else { return }
            switch readiness {
            case .pending:
                break
            case .reviewRequired:
                handlers.cancelSSHAuthentication?(hostID)
                reviewSSHHostKey(
                    hostID,
                    inventoryWarning:
                    display.workspaceInventoryWarningsByHost[hostID]
                        ?? "Remote inventory is unavailable.",
                    tmuxRecoveryRequestID:
                    sshHostKeyReview.tmuxRecoveryRequestID
                )
                return
            case .connected:
                let recoveryRequest =
                    tmuxRecoveryRequestRouter.recoveryRequestToResume(
                        reviewedHostID: hostID,
                        reviewRequestID: sshHostKeyReview.tmuxRecoveryRequestID
                    )
                handlers.cancelSSHAuthentication?(hostID)
                sshHostKeyReview.authenticationSucceeded {
                    if let recoveryRequest {
                        handlers.resumeTmuxReconnectAfterSSHRecovery?(
                            recoveryRequest
                        )
                    }
                }
                handlers.refreshWorkspaceInventory?()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func cancelSSHAuthenticationIfNeeded() {
        guard let hostID = activeSSHAuthenticationHostID else { return }
        handlers.cancelSSHAuthentication?(hostID)
    }

    private func cancelSSHRecovery() {
        cancelSSHAuthenticationIfNeeded()
        sshHostKeyReview.dismiss()
    }

    private func openHostSettings() {
        cancelSSHAuthenticationIfNeeded()
        sshHostKeyReview.dismiss()
        settingsStore.selectedDomain = .hosts
        Task { @MainActor in
            await Task.yield()
            isSettingsPresented = true
        }
    }

    private func activateTmuxSession(_ session: WorkspaceTmuxSessionSelection) {
        if activeTmuxSession == session {
            tmuxSelectionBaseline = selection
            handlers.openTmuxSession?(session)
            return
        }
        tmuxSelectionBaseline = selection
        handlers.openTmuxSession?(session)
    }

    private func initializeTmuxSelectionBaselineIfNeeded() {
        guard activeTmuxSession != nil,
              tmuxSelectionBaseline == nil else { return }
        tmuxSelectionBaseline = selection
    }

    private func createTmuxSession(
        on host: HostSummary,
        name: String,
        initialCommand: String?
    ) {
        let session = WorkspaceTmuxSessionSelection(
            hostID: host.id,
            name: name
        )
        selectWorkspace(Self.selectionForHostTmuxSession(
            session,
            from: selection,
            in: snapshot,
            visibility: worktreeVisibility
        ))
        tmuxSelectionBaseline = selection
        handlers.createTmuxSession?(WorkspaceTmuxSessionCreationRequest(
            selection: session,
            initialCommand: initialCommand
        ))
    }

    private func requestSessionKill(
        _ tmuxSession: WorkspaceTmuxSessionSelection
    ) {
        guard let prepare = handlers.prepareTmuxSessionKill else {
            workspaceAlert = .sessionKillFailure(
                session: tmuxSession.name,
                message: "Session termination is unavailable."
            )
            return
        }
        Task {
            do {
                workspaceAlert = await .sessionKillConfirmation(
                    try prepare(tmuxSession)
                )
            } catch {
                workspaceAlert = .sessionKillFailure(
                    session: tmuxSession.name,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func requestThemeApplication(
        _ tmuxSession: WorkspaceTmuxSessionSelection
    ) {
        Task {
            do {
                guard let applyTheme =
                    handlers.applyTmuxSessionTheme
                else {
                    throw SessionThemeUnavailableError()
                }
                try await applyTheme(tmuxSession)
            } catch {
                workspaceAlert = .sessionThemeFailure(
                    session: tmuxSession.name,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func workspaceAlertView(
        _ alert: WorkspaceAlert
    ) -> Alert {
        switch alert {
        case let .sessionKillConfirmation(request):
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
                            workspaceAlert = .sessionKillFailure(
                                session: tmuxSession.name,
                                message: error.localizedDescription
                            )
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        case let .sessionKillFailure(session, message):
            return Alert(
                title: Text("Could Not Kill “\(session)”"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        case let .sessionThemeFailure(session, message):
            return Alert(
                title: Text("Could Not Apply Theme to “\(session)”"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        case let .worktreeRemovalConfirmation(request):
            let sessionMessage = request.sessionKillRequest == nil
                ? ""
                : " Its live tmux session will be terminated first,"
                + " including every window, pane, and process."
            return Alert(
                title: Text("Remove “\(request.worktree.name)”?”"),
                message: Text(
                    "This removes the worktree at "
                        + "\(request.worktree.path)."
                        + sessionMessage
                        + " The Git branch will be kept."
                ),
                primaryButton: .destructive(Text("Remove Worktree")) {
                    Task {
                        do {
                            guard let remove = handlers.removeWorktree else {
                                throw WorktreeRemovalUnavailableError()
                            }
                            try await remove(request)
                        } catch {
                            workspaceAlert = .worktreeRemovalFailure(
                                worktree: request.worktree.name,
                                message: error.localizedDescription
                            )
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        case let .worktreeRemovalFailure(worktree, message):
            return Alert(
                title: Text("Could Not Remove “\(worktree)”"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func requestWorktreeRemoval(_ worktree: WorktreeSummary) {
        guard let prepare = handlers.prepareWorktreeRemoval else {
            workspaceAlert = .worktreeRemovalFailure(
                worktree: worktree.name,
                message: "Worktree removal is unavailable."
            )
            return
        }
        Task {
            do {
                workspaceAlert = await .worktreeRemovalConfirmation(
                    try prepare(worktree.id)
                )
            } catch {
                workspaceAlert = .worktreeRemovalFailure(
                    worktree: worktree.name,
                    message: error.localizedDescription
                )
            }
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

    private func hideTmuxSession() {
        guard let previous = activeTmuxSession else { return }
        tmuxSelectionBaseline = nil
        handlers.hideTmuxSession?(previous)
    }

    private var selectedWorktreeTmuxSession:
        WorkspaceTmuxSessionSelection? {
        let selected = WorkspaceSidebarModel.tmuxSessionSelection(
            for: selection,
            in: snapshot
        )
        guard let selected,
              let activeTmuxSession,
              selected.worktreeID == activeTmuxSession.worktreeID,
              selected.worktreeGeneration
              != activeTmuxSession.worktreeGeneration else {
            return selected
        }
        if activeTmuxSession.worktreeGeneration == nil {
            // A presentation opened before its canonical generation was
            // available is enriched, not replaced, as long as the tmux
            // endpoint is unchanged; keep the live terminal.
            guard selected.hostID == activeTmuxSession.hostID,
                  selected.name == activeTmuxSession.name,
                  selected.socketName == activeTmuxSession.socketName
            else { return selected }
            return activeTmuxSession
        }

        // Inventory may reuse a runtime worktree ID after a same-path
        // replacement or temporarily omit its generation. Keep the observed
        // presentation until the user explicitly selects a canonical target.
        return activeTmuxSession
    }

    private func synchronizeSelectedWorktreeSession() {
        guard !display.suppressesAutomaticWorktreeSessionOpen else { return }
        guard let session = selectedWorktreeTmuxSession else {
            if activeTmuxSession?.worktreeID != nil {
                hideTmuxSession()
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
                presentedSession.name,
                isSidebarTransitioning,
                TmuxSessionContentActions(
                    reconnectNow: {
                        handlers.reconnectActiveTmuxSessionNow?()
                    },
                    reviewConnection: {
                        reviewSSHHostKey(
                            host.id,
                            inventoryWarning: tmuxRecoveryWarning(
                                for: host.id
                            ),
                            tmuxRecoveryRequestID:
                            tmuxRecoveryRequestRouter.recoveryRequestID(
                                for: host.id,
                                activeRequest:
                                display.tmuxConnectionRecoveryRequest
                            )
                        )
                    }
                )
            ) {
            view
        } else if display.suppressesAutomaticWorktreeSessionOpen,
                  !display.isWorkspaceRestorationPending,
                  selectedWorktreeTmuxSession != nil {
            ContentUnavailableView {
                Label("Session detached", systemImage: "terminal")
            } description: {
                Text("Select this worktree to attach its tmux session.")
            }
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

    private var tmuxSessionVisibility: TmuxSessionVisibility {
        TmuxSessionVisibility(
            hiddenPatterns: settingsStore.tmuxSessionPreferences
                .hiddenSessionPatterns,
            hideKwtManagedSessions: settingsStore.worktreePreferences
                .hideKwtManagedSessions
        )
    }

    private var paletteCommands: [WorkspaceCommandItem] {
        CommandPaletteModel.commands(
            in: snapshot,
            selection: selection,
            activeTmuxSession: activeTmuxSession,
            activeTmuxSessionIsConnected:
            display.activeTmuxSessionIsConnected,
            activeTmuxSessionCanApplyTheme:
            display.activeTmuxSessionCanApplyTheme,
            isWorkspacesRoute: true,
            isSidebarVisible: isSidebarVisible,
            isSidePanelVisible: isSidePanelVisible,
            interfaceAppearance: settingsStore.interfaceAppearance,
            worktreeVisibility: worktreeVisibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            supportsSettings: content.settingsSheetBuilder != nil,
            worktreeOrderRawValue: worktreeOrderRawValue,
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue
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
                visibility: worktreeVisibility,
                worktreeOrderRawValue: worktreeOrderRawValue
            ) {
                selectWorkspace(updatedSelection)
            }
        case .nextWorktree:
            if let updatedSelection = KeyboardNavigationModel.steppedSelection(
                from: selection,
                in: snapshot,
                step: 1,
                visibility: worktreeVisibility,
                worktreeOrderRawValue: worktreeOrderRawValue
            ) {
                selectWorkspace(updatedSelection)
            }
        case let .newTmuxSession(hostID):
            guard let host = snapshot.host(id: hostID) else { return }
            newTmuxSessionHost = host
        case let .addProject(hostID):
            guard let host = snapshot.host(id: hostID) else { return }
            addProjectHost = host
        case let .openTmuxSession(tmuxSession):
            if let worktreeID = tmuxSession.worktreeID {
                selectWorkspace(.worktree(worktreeID))
            } else {
                selectWorkspace(Self.selectionForHostTmuxSession(
                    tmuxSession,
                    from: selection,
                    in: snapshot,
                    visibility: worktreeVisibility
                ))
            }
            activateTmuxSession(tmuxSession)
        case let .killTmuxSession(tmuxSession):
            requestSessionKill(tmuxSession)
        case let .applyThemeToCurrentTmuxSession(tmuxSession):
            requestThemeApplication(tmuxSession)
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
            selectWorkspace(target)
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
            visibility: worktreeVisibility,
            worktreeOrderRawValue: worktreeOrderRawValue
        ) {
            selectWorkspace(updatedSelection)
        }
    }

    private func selectWorkspace(_ target: WorkspaceNavigationTarget) {
        var updatedSelection = selection
        updatedSelection.select(
            target,
            in: snapshot,
            visibility: worktreeVisibility
        )
        selectWorkspace(updatedSelection)
    }

    private func selectWorkspace(_ updatedSelection: WorkspaceSelection) {
        if let selectWorkspace = handlers.selectWorkspace {
            selectWorkspace(updatedSelection)
        } else {
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

    private func handleApplyThemeNotification() {
        guard controlActiveState == .key,
              display.activeTmuxSessionCanApplyTheme,
              let activeTmuxSession
        else { return }
        requestThemeApplication(activeTmuxSession)
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

/// Hides the active tmux presentation when navigation leaves its route while
/// retaining the underlying attachment for a later return. Kept as a small
/// modifier so route behavior can be exercised without constructing the
/// entire sidebar hierarchy.
struct TmuxSessionPresentationLifecycleModifier: ViewModifier {
    let selection: WorkspaceSelection
    let selectionBaseline: WorkspaceSelection?
    let activeSession: WorkspaceTmuxSessionSelection?
    let hide: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, newSelection in
                if activeSession != nil,
                   let selectionBaseline,
                   newSelection != selectionBaseline {
                    hide()
                }
            }
    }
}

enum WorkspaceAlert: Identifiable {
    case sessionKillConfirmation(TmuxSessionKillRequest)
    case sessionKillFailure(session: String, message: String)
    case sessionThemeFailure(session: String, message: String)
    case worktreeRemovalConfirmation(WorktreeRemovalRequest)
    case worktreeRemovalFailure(worktree: String, message: String)

    var id: String {
        switch self {
        case let .sessionKillConfirmation(request):
            return "session:confirm:\(request.session.id)"
        case let .sessionKillFailure(session, message):
            return "session:failure:\(session):\(message)"
        case let .sessionThemeFailure(session, message):
            return "session-theme:failure:\(session):\(message)"
        case let .worktreeRemovalConfirmation(request):
            return "worktree:confirm:\(request.worktree.id.uuidString)"
        case let .worktreeRemovalFailure(worktree, message):
            return "worktree:failure:\(worktree):\(message)"
        }
    }
}

private struct SessionKillUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Session termination is unavailable."
    }
}

private struct SessionThemeUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Theme application is unavailable."
    }
}

private struct WorktreeRemovalUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Worktree removal is unavailable."
    }
}
