import AppKit
import GhosthubSettings
import GhosthubTerminalSupport
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
    @StateObject private var herdrPresentationIntent =
        HerdrPresentationIntentController()
    @StateObject private var herdrLifecyclePreparation =
        HerdrLifecyclePreparationController()
    @State private var newWorktreeProject: ProjectSummary?
    @State private var newWorktreeMode: NewWorktreeMode = .branch
    @State private var newTmuxSessionHost: HostSummary?
    @State private var newHerdrSessionHost: HostSummary?
    @State private var herdrCreationTask: Task<Void, Never>?
    @State private var herdrCreationRevision: UInt64 = 0
    @State private var addProjectHost: HostSummary?
    @State private var workspaceAlert: WorkspaceAlert?
    @State private var pendingWorktreeRemoval: WorktreeRemovalRequest?
    // Retain the first confirmed generation for every runtime ID encountered
    // while reconfirming so ID reuse cannot disguise a displaced target.
    @State private var pendingWorktreeRemovals:
        [UUID: PendingWorktreeRemovalIdentity] = [:]
    @State private var sessionRecoveryRequestRouter =
        SessionConnectionRecoveryRequestRouter()
    @StateObject private var sshHostKeyReview =
        WorkspaceSSHHostKeyReviewModel()
    @AppStorage(WorkspaceSidebarOrderStorage.worktreeKey)
    private var worktreeOrderRawValue = ""
    @AppStorage(WorkspaceSidebarOrderStorage.tmuxSessionKey)
    private var tmuxSessionOrderRawValue = ""
    @AppStorage(WorkspaceSidebarOrderStorage.herdrSessionKey)
    private var herdrSessionOrderRawValue = ""

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
    private var activeHerdrSession: WorkspaceHerdrSessionSelection? {
        display.activeHerdrSession
    }

    nonisolated static func applicationShortcutProject(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) -> ProjectSummary? {
        WorkspaceSelectionResolver.selectedProject(
            in: snapshot,
            selection: selection
        )
    }

    public var body: some View {
        contentWithNotifications
            .onAppear {
                reviewSessionConnectionRequestIfNeeded()
            }
            .onChange(
                of: display.sessionConnectionRecoveryRequest?.id
            ) { _, _ in
                reviewSessionConnectionRequestIfNeeded()
            }
            .onChange(of: sshHostKeyReview.isPresented) { wasPresented, isPresented in
                guard wasPresented, !isPresented else { return }
                sessionRecoveryRequestRouter.reviewDidDismiss()
                reviewSessionConnectionRequestIfNeeded()
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
            .sheet(
                item: $newHerdrSessionHost,
                onDismiss: {
                    cancelHerdrCreation(dismissSheet: false)
                }
            ) { host in
                NewHerdrSessionSheet(
                    host: host,
                    hosts: snapshot.hosts,
                    isCreating: herdrCreationTask != nil,
                    onCreate: { selectedHost, name in
                        createHerdrSession(on: selectedHost, name: name)
                    },
                    onCancel: { cancelHerdrCreation() }
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
            .onDisappear {
                cancelHerdrPresentationIntents()
                cancelHerdrCreation()
                cancelHerdrLifecyclePreparation()
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
                selection = Self.selectionAfterSnapshotChange(
                    selection,
                    in: updatedSnapshot,
                    visibility: worktreeVisibility,
                    pendingRemovals: pendingWorktreeRemovals
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
            .modifier(
                HerdrSessionPresentationLifecycleModifier(
                    selection: selection,
                    activeSession: activeHerdrSession,
                    deactivate: deactivateHerdrSession(_:)
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
                    for: .ghosthubApplicationShortcutRequest,
                    object: sidebarToggleTarget
                )
            ) { notification in
                handleApplicationShortcut(notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .ghosthubApplyThemeToCurrentSession
                )
            ) { _ in handleApplyThemeNotification() }
    }

    private func handleApplicationShortcut(_ notification: Notification) {
        guard let rawAction = notification.userInfo?[
            applicationShortcutActionUserInfoKey
        ] as? String,
            let action = ApplicationShortcutAction(rawValue: rawAction)
        else { return }

        switch action {
        case .toggleSidebar:
            handleToggleSidebar()
        case .newWorktree:
            if let project = Self.applicationShortcutProject(
                in: snapshot,
                selection: selection
            ) {
                openNewWorktree(project)
            }
        case .importPullRequest:
            if let project = Self.applicationShortcutProject(
                in: snapshot,
                selection: selection
            ) {
                openImportPullRequest(project)
            }
        case .newTmuxSession:
            newTmuxSessionHost = snapshot.host(id: selection.selectedHostID)
        case .newHerdrSession:
            let host = snapshot.host(id: selection.selectedHostID)
            if host?.herdrAvailable == true {
                newHerdrSessionHost = host
            }
        default:
            break
        }
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
            activeHerdrSession: activeHerdrSession,
            activeTmuxSessionIsConnected:
            display.activeTmuxSessionIsConnected,
            workingTmuxSessionIDs:
            display.workingTmuxSessionIDs,
            onOpenTmuxSession: { session in
                activateTmuxSession(session)
            },
            onOpenHerdrSession: { session in
                activateHerdrSession(session)
            },
            pendingHerdrSessions: display.pendingHerdrSessions,
            onRestartHerdrSession: restartHerdrSession,
            onRequestHerdrSessionLifecycle: requestHerdrSessionLifecycle,
            onNavigateAwayFromSession: {
                hideTmuxSession()
                deactivateHerdrSession()
            },
            onRequestKillTmuxSession: requestSessionKill,
            onRequestRemoveWorktree: requestWorktreeRemoval,
            onNewWorktree: openNewWorktree,
            onImportPullRequest: openImportPullRequest,
            onNewTmuxSession: { host in
                newTmuxSessionHost = host
            },
            onNewHerdrSession: { host in
                newHerdrSessionHost = host
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
            herdrSessionOrderRawValue: $herdrSessionOrderRawValue,
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
        sessionRecoveryRequestID: UUID? = nil
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
                sessionRecoveryRequestID: sessionRecoveryRequestID,
                using: {
                    await review(hostID, inventoryWarning)
                }
            )
        }
    }

    private func sessionRecoveryWarning(for hostID: UUID) -> String {
        if let request = display.sessionConnectionRecoveryRequest,
           request.hostID == hostID {
            return request.message
        }
        return display.workspaceInventoryWarningsByHost[hostID]
            ?? "The remote session connection needs attention."
    }

    private func reviewSessionConnectionRequestIfNeeded() {
        Task { @MainActor in
            await Task.yield()
            guard let request = sessionRecoveryRequestRouter.take(
                display.sessionConnectionRecoveryRequest,
                whileReviewIsPresented: sshHostKeyReview.isPresented
            )
            else { return }
            reviewSSHHostKey(
                request.hostID,
                inventoryWarning: request.message,
                sessionRecoveryRequestID: request.id
            )
        }
    }

    private func retrySSHRecovery() {
        let recoveryRequest =
            sshHostKeyReview.presentation == .inventoryIssue
                ? sessionRecoveryRequestRouter.recoveryRequestToResume(
                    reviewedHostID: sshHostKeyReview.hostID,
                    reviewRequestID:
                    sshHostKeyReview.sessionRecoveryRequestID
                )
                : nil
        cancelSSHAuthenticationIfNeeded()
        sshHostKeyReview.dismiss()
        if let recoveryRequest {
            handlers.resumeSessionReconnectAfterSSHRecovery?(recoveryRequest)
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
                    sessionRecoveryRequestID:
                    sshHostKeyReview.sessionRecoveryRequestID
                )
                return
            case .connected:
                let recoveryRequest =
                    sessionRecoveryRequestRouter.recoveryRequestToResume(
                        reviewedHostID: hostID,
                        reviewRequestID:
                        sshHostKeyReview.sessionRecoveryRequestID
                    )
                handlers.cancelSSHAuthentication?(hostID)
                sshHostKeyReview.authenticationSucceeded {
                    if let recoveryRequest {
                        handlers.resumeSessionReconnectAfterSSHRecovery?(
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
        deactivateHerdrSession()
        if activeTmuxSession == session {
            tmuxSelectionBaseline = selection
            handlers.openTmuxSession?(session)
            return
        }
        tmuxSelectionBaseline = selection
        handlers.openTmuxSession?(session)
    }

    private func activateHerdrSession(
        _ session: WorkspaceHerdrSessionSelection
    ) {
        Self.transitionHerdrSession(
            to: session,
            from: activeHerdrSession,
            deactivate: deactivateHerdrSession(_:)
        ) {
            startHerdrSessionActivation(session)
        }
    }

    private func startHerdrSessionActivation(
        _ session: WorkspaceHerdrSessionSelection
    ) {
        let replacedTmuxSession = activeTmuxSession
        herdrPresentationIntent.start(
            operation: { isCurrent in
                guard let open = handlers.openHerdrSession else {
                    throw HerdrLifecycleUnavailableError()
                }
                _ = try await Self.openHerdrSession(
                    session,
                    replacing: replacedTmuxSession,
                    open: open,
                    isCurrent: isCurrent,
                    closeTmux: { replaced in
                        handlers.closeTmuxSession?(replaced)
                    }
                )
            },
            onFailure: { error in
                presentNonWorktreeWorkspaceAlert(.herdrLifecycleFailure(
                    session: session.name,
                    action: "open",
                    message: error.localizedDescription
                ))
            }
        )
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

    private func createHerdrSession(
        on host: HostSummary,
        name: String
    ) {
        guard herdrCreationTask == nil else { return }
        let session = WorkspaceHerdrSessionSelection(
            hostID: host.id,
            name: name
        )
        herdrCreationRevision &+= 1
        let creationRevision = herdrCreationRevision
        herdrCreationTask = Task { @MainActor in
            do {
                guard let create = handlers.createHerdrSession else {
                    throw HerdrLifecycleUnavailableError()
                }
                try await create(session)
                guard herdrCreationRevision == creationRevision else {
                    return
                }
                herdrCreationTask = nil
                newHerdrSessionHost = nil
                selectWorkspace(.herdrSession(hostID: host.id, name: name))
            } catch {
                guard herdrCreationRevision == creationRevision else {
                    return
                }
                herdrCreationTask = nil
                guard !(error is CancellationError) else { return }
                presentNonWorktreeWorkspaceAlert(.herdrLifecycleFailure(
                    session: name,
                    action: "create",
                    message: error.localizedDescription
                ))
            }
        }
    }

    private func cancelHerdrCreation(dismissSheet: Bool = true) {
        herdrCreationRevision &+= 1
        herdrCreationTask?.cancel()
        herdrCreationTask = nil
        if dismissSheet {
            newHerdrSessionHost = nil
        }
    }

    private func restartHerdrSession(
        _ session: WorkspaceHerdrSessionSelection
    ) {
        Self.transitionHerdrSession(
            to: session,
            from: activeHerdrSession,
            deactivate: deactivateHerdrSession(_:)
        ) {
            startHerdrSessionRestart(session)
        }
    }

    private func startHerdrSessionRestart(
        _ session: WorkspaceHerdrSessionSelection
    ) {
        herdrPresentationIntent.start(
            operation: { isCurrent in
                guard let restart = handlers.restartHerdrSession else {
                    throw HerdrLifecycleUnavailableError()
                }
                try await restart(session)
                guard isCurrent() else { return }
                selectWorkspace(.herdrSession(
                    hostID: session.hostID,
                    name: session.name
                ))
            },
            onFailure: { error in
                presentNonWorktreeWorkspaceAlert(.herdrLifecycleFailure(
                    session: session.name,
                    action: "restart",
                    message: error.localizedDescription
                ))
            }
        )
    }

    private func requestHerdrSessionLifecycle(
        _ session: WorkspaceHerdrSessionSelection,
        action: HerdrSessionDestructiveAction
    ) {
        if case let .herdrLifecycleConfirmation(request) = workspaceAlert {
            handlers.cancelHerdrSessionLifecycle?(request)
            workspaceAlert = nil
        }
        guard let prepare = handlers.prepareHerdrSessionLifecycle else {
            herdrLifecyclePreparation.cancel()
            presentNonWorktreeWorkspaceAlert(.herdrLifecycleFailure(
                session: session.name,
                action: action == .stop ? "stop" : "delete",
                message: "Herdr session lifecycle actions are unavailable."
            ))
            return
        }
        herdrLifecyclePreparation.start(
            prepare: {
                try await prepare(session, action)
            },
            cancelPrepared: { request in
                handlers.cancelHerdrSessionLifecycle?(request)
            },
            onPrepared: { request in
                presentNonWorktreeWorkspaceAlert(
                    .herdrLifecycleConfirmation(request)
                )
            },
            onFailure: { error in
                presentNonWorktreeWorkspaceAlert(.herdrLifecycleFailure(
                    session: session.name,
                    action: action == .stop ? "stop" : "delete",
                    message: error.localizedDescription
                ))
            }
        )
    }

    private func cancelHerdrLifecyclePreparation() {
        herdrLifecyclePreparation.cancel()
        guard case let .herdrLifecycleConfirmation(request) = workspaceAlert
        else { return }
        handlers.cancelHerdrSessionLifecycle?(request)
        workspaceAlert = nil
    }

    private func requestSessionKill(
        _ tmuxSession: WorkspaceTmuxSessionSelection
    ) {
        guard let prepare = handlers.prepareTmuxSessionKill else {
            presentNonWorktreeWorkspaceAlert(.sessionKillFailure(
                session: tmuxSession.name,
                message: "Session termination is unavailable."
            ))
            return
        }
        Task {
            do {
                await presentNonWorktreeWorkspaceAlert(.sessionKillConfirmation(
                    try prepare(tmuxSession)
                ))
            } catch {
                presentNonWorktreeWorkspaceAlert(.sessionKillFailure(
                    session: tmuxSession.name,
                    message: error.localizedDescription
                ))
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
                presentNonWorktreeWorkspaceAlert(.sessionThemeFailure(
                    session: tmuxSession.name,
                    message: error.localizedDescription
                ))
            }
        }
    }

    private func presentNonWorktreeWorkspaceAlert(_ alert: WorkspaceAlert) {
        Self.presentNonWorktreeWorkspaceAlert(
            alert,
            workspaceAlert: &workspaceAlert,
            pendingWorktreeRemoval: &pendingWorktreeRemoval,
            pendingWorktrees: &pendingWorktreeRemovals
        )
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
                            presentNonWorktreeWorkspaceAlert(.sessionKillFailure(
                                session: tmuxSession.name,
                                message: error.localizedDescription
                            ))
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
        case let .herdrLifecycleConfirmation(request):
            let actionName = request.action == .stop ? "Stop" : "Delete"
            let message: String
            if request.action == .stop {
                message = "This terminates shells, agents, servers, tests, and every other process in this Herdr session on \(request.confirmedHost.sidebarTitle). Herdr keeps only the saved shape for a later restart."
            } else {
                message = "This permanently removes the saved layout and state for this stopped Herdr session on \(request.confirmedHost.sidebarTitle)."
            }
            return Alert(
                title: Text("\(actionName) “\(request.session.name)”?”"),
                message: Text(message),
                primaryButton: .destructive(Text("\(actionName) Session")) {
                    Task {
                        do {
                            guard let perform =
                                handlers.performHerdrSessionLifecycle
                            else { throw HerdrLifecycleUnavailableError() }
                            try await perform(request)
                        } catch {
                            presentNonWorktreeWorkspaceAlert(
                                .herdrLifecycleFailure(
                                    session: request.session.name,
                                    action: request.action == .stop
                                        ? "stop" : "delete",
                                    message: error.localizedDescription
                                )
                            )
                        }
                    }
                },
                secondaryButton: .cancel {
                    handlers.cancelHerdrSessionLifecycle?(request)
                }
            )
        case let .herdrLifecycleFailure(session, action, message):
            return Alert(
                title: Text("Could Not \(action.capitalized) “\(session)”"),
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
                    Self.beginWorktreeRemovalResolution(
                        pendingWorktreeRemoval: &pendingWorktreeRemoval
                    )
                    Task {
                        do {
                            guard let remove = handlers.removeWorktree else {
                                throw WorktreeRemovalUnavailableError()
                            }
                            switch try await remove(request) {
                            case .removed:
                                pendingWorktreeRemoval = nil
                                pendingWorktreeRemovals.removeAll()
                            case let .confirmationRequired(updatedRequest):
                                Self.transitionWorktreeRemovalConfirmation(
                                    to: updatedRequest,
                                    pendingWorktreeRemoval: &pendingWorktreeRemoval,
                                    pendingWorktrees: &pendingWorktreeRemovals
                                )
                                workspaceAlert = .worktreeRemovalConfirmation(
                                    updatedRequest
                                )
                            }
                        } catch {
                            pendingWorktreeRemoval = nil
                            selection = Self.finishFailedWorktreeRemoval(
                                selection,
                                in: snapshot,
                                currentSnapshot:
                                handlers.currentWorkspaceSnapshot,
                                visibility: worktreeVisibility,
                                pendingWorktrees: &pendingWorktreeRemovals
                            )
                            workspaceAlert = .worktreeRemovalFailure(
                                worktree: request.worktree.name,
                                message: error.localizedDescription
                            )
                        }
                    }
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    pendingWorktreeRemoval = nil
                    pendingWorktreeRemovals.removeAll()
                }
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
        guard Self.reserveWorktreeRemovalPreparation(
            worktree,
            pendingWorktrees: &pendingWorktreeRemovals
        ) else { return }
        guard let prepare = handlers.prepareWorktreeRemoval else {
            Self.clearWorktreeRemovalPreparation(
                worktree,
                pendingWorktrees: &pendingWorktreeRemovals
            )
            workspaceAlert = .worktreeRemovalFailure(
                worktree: worktree.name,
                message: "Worktree removal is unavailable."
            )
            return
        }
        Task {
            do {
                let request = try await Self.prepareWorktreeRemoval(
                    worktree,
                    using: prepare
                )
                guard Self.holdsWorktreeRemovalReservation(
                    worktree,
                    pendingWorktrees: pendingWorktreeRemovals
                ) else {
                    return
                }
                pendingWorktreeRemoval = request
                workspaceAlert = .worktreeRemovalConfirmation(
                    request
                )
            } catch {
                guard Self.holdsWorktreeRemovalReservation(
                    worktree,
                    pendingWorktrees: pendingWorktreeRemovals
                ) else { return }
                selection = Self.finishFailedWorktreeRemoval(
                    selection,
                    in: snapshot,
                    currentSnapshot: handlers.currentWorkspaceSnapshot,
                    visibility: worktreeVisibility,
                    pendingWorktrees: &pendingWorktreeRemovals
                )
                pendingWorktreeRemoval = nil
                if !(error is CancellationError) {
                    workspaceAlert = .worktreeRemovalFailure(
                        worktree: worktree.name,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    @MainActor
    static func prepareWorktreeRemoval(
        _ worktree: WorktreeSummary,
        using prepare: (UUID) async throws -> WorktreeRemovalRequest
    ) async throws -> WorktreeRemovalRequest {
        try await prepare(worktree.id)
    }

    struct PendingWorktreeRemovalIdentity: Equatable {
        let generation: String?

        init(_ worktree: WorktreeSummary) {
            generation = worktree.generation
        }
    }

    @MainActor
    static func reserveWorktreeRemovalPreparation(
        _ worktree: WorktreeSummary,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) -> Bool {
        guard pendingWorktrees.isEmpty else { return false }
        pendingWorktrees[worktree.id] = PendingWorktreeRemovalIdentity(
            worktree
        )
        return true
    }

    @MainActor
    static func holdsWorktreeRemovalReservation(
        _ worktree: WorktreeSummary,
        pendingWorktrees: [UUID: PendingWorktreeRemovalIdentity]
    ) -> Bool {
        pendingWorktrees == [
            worktree.id: PendingWorktreeRemovalIdentity(worktree),
        ]
    }

    @MainActor
    @discardableResult
    static func clearWorktreeRemovalPreparation(
        _ worktree: WorktreeSummary,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) -> Bool {
        guard holdsWorktreeRemovalReservation(
            worktree,
            pendingWorktrees: pendingWorktrees
        ) else { return false }
        pendingWorktrees.removeAll()
        return true
    }

    @MainActor
    static func presentNonWorktreeWorkspaceAlert(
        _ alert: WorkspaceAlert,
        workspaceAlert: inout WorkspaceAlert?,
        pendingWorktreeRemoval: inout WorktreeRemovalRequest?,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) {
        if pendingWorktreeRemoval != nil {
            pendingWorktreeRemoval = nil
            pendingWorktrees.removeAll()
        }
        workspaceAlert = alert
    }

    @MainActor
    static func beginWorktreeRemovalResolution(
        pendingWorktreeRemoval: inout WorktreeRemovalRequest?
    ) {
        pendingWorktreeRemoval = nil
    }

    @MainActor
    static func transitionWorktreeRemovalConfirmation(
        to request: WorktreeRemovalRequest,
        pendingWorktreeRemoval: inout WorktreeRemovalRequest?,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) {
        pendingWorktreeRemoval = request
        if pendingWorktrees[request.worktree.id] == nil {
            pendingWorktrees[request.worktree.id] =
                PendingWorktreeRemovalIdentity(request.worktree)
        }
    }

    @MainActor
    static func finishFailedWorktreeRemoval(
        _ current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        currentSnapshot: (() -> WorkspaceSnapshot)? = nil,
        visibility: WorktreeVisibility,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) -> WorkspaceSelection {
        let updated = selectionAfterSnapshotChange(
            current,
            in: currentSnapshot?() ?? snapshot,
            visibility: visibility,
            pendingRemovals: pendingWorktrees
        )
        pendingWorktrees.removeAll()
        return updated
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

    private func deactivateHerdrSession() {
        guard let previous = activeHerdrSession else { return }
        deactivateHerdrSession(previous)
    }

    private func deactivateHerdrSession(
        _ expected: WorkspaceHerdrSessionSelection
    ) {
        guard activeHerdrSession == expected else { return }
        cancelHerdrPresentationIntents()
        let previous = expected
        handlers.closeHerdrSession?(previous)
    }

    private func cancelHerdrPresentationIntents() {
        herdrPresentationIntent.cancel()
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
        guard let session = selectedWorktreeTmuxSession else { return }
        guard activeTmuxSession != session else { return }
        activateTmuxSession(session)
    }

    @ViewBuilder
    private var terminalWorkspaceContent: some View {
        if activeTmuxSession == nil,
           let activeHerdrSession,
           let host = snapshot.host(id: activeHerdrSession.hostID),
           let view = content.herdrSessionContentBuilder?(
               host,
               activeHerdrSession.name,
               isSidebarTransitioning,
               NativeSessionContentActions(
                   reconnectNow: {
                       handlers.reconnectActiveHerdrSessionNow?()
                   },
                   reviewConnection: {
                       reviewSSHHostKey(
                           host.id,
                           inventoryWarning: sessionRecoveryWarning(
                               for: host.id
                           ),
                           sessionRecoveryRequestID:
                           sessionRecoveryRequestRouter.recoveryRequestID(
                               for: host.id,
                               activeRequest:
                               display.sessionConnectionRecoveryRequest
                           )
                       )
                   }
               )
           ) {
            view
        } else if activeHerdrSession == nil,
                  let presentedSession = selectedWorktreeTmuxSession
                  ?? activeTmuxSession,
                  let host = snapshot.host(id: presentedSession.hostID),
                  activeTmuxSession == presentedSession,
                  let view = content.tmuxSessionContentBuilder?(
                      host,
                      presentedSession.name,
                      isSidebarTransitioning,
                      NativeSessionContentActions(
                          reconnectNow: {
                              handlers.reconnectActiveTmuxSessionNow?()
                          },
                          reviewConnection: {
                              reviewSSHHostKey(
                                  host.id,
                                  inventoryWarning: sessionRecoveryWarning(
                                      for: host.id
                                  ),
                                  sessionRecoveryRequestID:
                                  sessionRecoveryRequestRouter.recoveryRequestID(
                                      for: host.id,
                                      activeRequest:
                                      display.sessionConnectionRecoveryRequest
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
                Text("Select this workspace to attach its tmux session.")
            }
        } else if let pendingSession = selectedWorktreeTmuxSession {
            ProgressView("Opening \(displayName(for: pendingSession))…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selection.selectedWorktreeID != nil
            || selection.selectedDirectoryWorkspaceID != nil {
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
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue,
            availableApplicationShortcuts:
            display.availableApplicationShortcuts,
            herdrSessionOrderRawValue: herdrSessionOrderRawValue,
            pendingHerdrSessions: display.pendingHerdrSessions,
            shortcuts: settingsStore.shortcutPreferences.resolved
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
        if let worktreeID = session.worktreeID,
           let worktree = snapshot.worktree(id: worktreeID) {
            return worktree.name
        }
        if let directoryWorkspaceID = session.directoryWorkspaceID,
           let workspace = snapshot.directoryWorkspace(
               id: directoryWorkspaceID
           ) {
            return workspace.name
        }
        return session.name
    }

    private func perform(_ action: WorkspaceCommandAction) {
        switch action {
        case .toggleSidebar:
            toggleSidebar()
        case .openConfigDirectory:
            openConfigDirectory()
        case .reloadTerminalConfig:
            handlers.reloadTerminalConfig?()
        case let .newTmuxSession(hostID):
            guard let host = snapshot.host(id: hostID) else { return }
            newTmuxSessionHost = host
        case let .newHerdrSession(hostID):
            guard let host = snapshot.host(id: hostID),
                  host.herdrAvailable else { return }
            newHerdrSessionHost = host
        case let .addProject(hostID):
            guard let host = snapshot.host(id: hostID) else { return }
            addProjectHost = host
        case let .openTmuxSession(tmuxSession):
            if let worktreeID = tmuxSession.worktreeID {
                selectWorkspace(.worktree(worktreeID))
            } else if let directoryID = tmuxSession.directoryWorkspaceID {
                selectWorkspace(.directoryWorkspace(directoryID))
            } else {
                selectWorkspace(Self.selectionForHostTmuxSession(
                    tmuxSession,
                    from: selection,
                    in: snapshot,
                    visibility: worktreeVisibility
                ))
            }
            activateTmuxSession(tmuxSession)
        case let .openHerdrSession(herdrSession):
            selectWorkspace(.herdrSession(
                hostID: herdrSession.hostID,
                name: herdrSession.name
            ))
            activateHerdrSession(herdrSession)
        case let .restartHerdrSession(herdrSession):
            restartHerdrSession(herdrSession)
        case let .stopHerdrSession(herdrSession):
            requestHerdrSessionLifecycle(herdrSession, action: .stop)
        case let .deleteHerdrSession(herdrSession):
            requestHerdrSessionLifecycle(herdrSession, action: .delete)
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
            hideTmuxSession()
            deactivateHerdrSession()
            selectWorkspace(target)
        case .showLogViewer:
            isLogViewerPresented = true
        case let .applicationShortcut(action):
            handlers.performApplicationShortcut?(action)
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

    static func selectionAfterSnapshotChange(
        _ current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility,
        pendingRemovals: [UUID: PendingWorktreeRemovalIdentity]
    ) -> WorkspaceSelection {
        if let selectedWorktreeID = current.selectedWorktreeID,
           let pending = pendingRemovals[selectedWorktreeID],
           let projectID = current.selectedProjectID,
           snapshot.project(id: projectID) != nil {
            let worktree = snapshot.worktree(id: selectedWorktreeID)
            let generationChanged = pending.generation.map {
                worktree?.generation != $0
            } ?? false
            guard worktree == nil || generationChanged else {
                return current.normalizedBySelectingVisibleFallback(
                    in: snapshot,
                    visibility: visibility
                )
            }
            var updated = current
            updated.select(
                .project(projectID),
                in: snapshot,
                visibility: visibility
            )
            return updated
        }
        return current.normalizedBySelectingVisibleFallback(
            in: snapshot,
            visibility: visibility
        )
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
        if herdrCreationTask != nil {
            cancelHerdrCreation()
        }
        cancelHerdrPresentationIntents()
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
        guard controlActiveState == .key || permitsBackgroundDemoControl else {
            return
        }
        isCommandPalettePresented = true
    }

    private var permitsBackgroundDemoControl: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["GHOSTHUB_DEMO_ROOT"],
              let scratch = environment["GHOSTHUB_DEMO_SCRATCH"]
        else { return false }
        guard root.hasPrefix("/"), scratch.hasPrefix("/"),
              root != "/", scratch != "/"
        else { return false }
        var rootIsDirectory = ObjCBool(false)
        var scratchIsDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: root,
            isDirectory: &rootIsDirectory
        ) && rootIsDirectory.boolValue
            && FileManager.default.fileExists(
                atPath: scratch,
                isDirectory: &scratchIsDirectory
            ) && scratchIsDirectory.boolValue
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
        cancelHerdrPresentationIntents()
        if activeHerdrSession != nil {
            deactivateHerdrSession()
            return
        }
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

    static func openHerdrSession(
        _ session: WorkspaceHerdrSessionSelection,
        replacing tmuxSession: WorkspaceTmuxSessionSelection?,
        open: (WorkspaceHerdrSessionSelection) async throws -> Void,
        isCurrent: () -> Bool = { true },
        closeTmux: (WorkspaceTmuxSessionSelection) -> Void
    ) async throws -> Bool {
        try await open(session)
        guard isCurrent() else { return false }
        if let tmuxSession {
            closeTmux(tmuxSession)
        }
        return true
    }

    static func transitionHerdrSession(
        to target: WorkspaceHerdrSessionSelection,
        from active: WorkspaceHerdrSessionSelection?,
        deactivate: (WorkspaceHerdrSessionSelection) -> Void,
        start: () -> Void
    ) {
        if let active, active.hostID != target.hostID {
            deactivate(active)
        }
        start()
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

@MainActor
final class HerdrPresentationIntentController: ObservableObject {
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?

    func start(
        operation: @escaping @MainActor (
            @escaping @MainActor @Sendable () -> Bool
        ) async throws -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) {
        cancel()
        let currentRevision = revision
        task = Task { @MainActor [weak self] in
            let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && revision == currentRevision
            }
            defer {
                if let self, revision == currentRevision {
                    task = nil
                }
            }
            do {
                try await operation(isCurrent)
            } catch {
                guard isCurrent(), !(error is CancellationError) else { return }
                onFailure(error)
            }
        }
    }

    func cancel() {
        revision &+= 1
        task?.cancel()
        task = nil
    }
}

@MainActor
final class HerdrLifecyclePreparationController: ObservableObject {
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?

    func start(
        prepare: @escaping () async throws -> HerdrSessionLifecycleRequest,
        cancelPrepared: @escaping (HerdrSessionLifecycleRequest) -> Void,
        onPrepared: @escaping (HerdrSessionLifecycleRequest) -> Void,
        onFailure: @escaping (any Error) -> Void
    ) {
        cancel()
        let currentRevision = revision
        task = Task { @MainActor [weak self] in
            do {
                let request = try await prepare()
                guard let self else {
                    cancelPrepared(request)
                    return
                }
                guard !Task.isCancelled,
                      revision == currentRevision else {
                    cancelPrepared(request)
                    return
                }
                task = nil
                onPrepared(request)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      revision == currentRevision,
                      !(error is CancellationError)
                else { return }
                task = nil
                onFailure(error)
            }
        }
    }

    func cancel() {
        revision &+= 1
        task?.cancel()
        task = nil
    }
}

/// Closes an active Herdr presentation only when navigation leaves the
/// host-level route used by Herdr sessions.
struct HerdrSessionPresentationLifecycleModifier: ViewModifier {
    let selection: WorkspaceSelection
    let activeSession: WorkspaceHerdrSessionSelection?
    let deactivate: (WorkspaceHerdrSessionSelection) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, newSelection in
                guard let activeSession,
                      newSelection.selectedHostID != activeSession.hostID
                      || newSelection.selectedProjectID != nil
                      || newSelection.selectedWorktreeID != nil
                      || newSelection.selectedDirectoryWorkspaceID != nil
                else { return }
                deactivate(activeSession)
            }
    }
}

enum WorkspaceAlert: Identifiable {
    case sessionKillConfirmation(TmuxSessionKillRequest)
    case sessionKillFailure(session: String, message: String)
    case herdrLifecycleConfirmation(HerdrSessionLifecycleRequest)
    case herdrLifecycleFailure(
        session: String,
        action: String,
        message: String
    )
    case sessionThemeFailure(session: String, message: String)
    case worktreeRemovalConfirmation(WorktreeRemovalRequest)
    case worktreeRemovalFailure(worktree: String, message: String)

    var id: String {
        switch self {
        case let .sessionKillConfirmation(request):
            return "session:confirm:\(request.session.id)"
        case let .sessionKillFailure(session, message):
            return "session:failure:\(session):\(message)"
        case let .herdrLifecycleConfirmation(request):
            return "herdr:confirm:\(request.session.id):\(request.action)"
        case let .herdrLifecycleFailure(session, action, message):
            return "herdr:failure:\(action):\(session):\(message)"
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

private struct HerdrLifecycleUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Herdr session lifecycle actions are unavailable."
    }
}

private struct WorktreeRemovalUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Worktree removal is unavailable."
    }
}
