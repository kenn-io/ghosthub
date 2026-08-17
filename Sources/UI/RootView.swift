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
    private let workspaceWindowProvider: () -> NSWindow?
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
    @State private var peerTakeoverNavigationSelection: WorkspaceSelection?
    @StateObject private var herdrPresentationIntent =
        HerdrPresentationIntentController()
    @StateObject private var herdrLifecyclePreparation =
        SessionPreparationController<HerdrSessionLifecycleRequest>()
    @StateObject private var zellijKillPreparation =
        SessionPreparationController<ZellijSessionKillRequest>()
    @State private var newWorktreeProject: ProjectSummary?
    @State private var newWorktreeMode: NewWorktreeMode = .branch
    @State private var newTmuxSessionHost: HostSummary?
    @State private var newHerdrSessionHost: HostSummary?
    @State private var newZellijSessionHost: HostSummary?
    @State private var herdrCreationTask: Task<Void, Never>?
    @State private var herdrCreationRevision: UInt64 = 0
    @State private var zellijCreationTask: Task<Void, Never>?
    @State private var zellijCreationRevision: UInt64 = 0
    @State private var addProjectHost: HostSummary?
    @State private var workspaceAlert: WorkspaceAlert?
    @State private var pendingWorktreeRemoval: WorktreeRemovalRequest?
    // Retain the first confirmed generation for every runtime ID encountered
    // while reconfirming so ID reuse cannot disguise a displaced target.
    @State private var pendingWorktreeRemovals:
        [UUID: WorkspacePresentationLifecycle.PendingWorktreeRemovalIdentity] = [:]
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
    @AppStorage(WorkspaceSidebarOrderStorage.zellijSessionKey)
    private var zellijSessionOrderRawValue = ""

    public init(
        display: WorkspaceDisplayState,
        content: ContentBuilders = ContentBuilders(),
        handlers: InteractionHandlers = InteractionHandlers(),
        sidebarToggleTarget: AnyObject = NSObject(),
        sidebarWidthChanged: @escaping (CGFloat) -> Void = { _ in },
        workspaceWindowProvider: @escaping () -> NSWindow? = { nil },
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
        self.workspaceWindowProvider = workspaceWindowProvider
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

    private var activeZellijSession: WorkspaceZellijSessionSelection? {
        display.activeZellijSession
    }
    public var body: some View {
        let _ = RenderWorkCounters.countRootBodyEvaluation()
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
            .sheet(
                item: $newZellijSessionHost,
                onDismiss: {
                    cancelZellijCreation(dismissSheet: false)
                }
            ) { host in
                NewZellijSessionSheet(
                    host: host,
                    hosts: snapshot.hosts,
                    isCreating: zellijCreationTask != nil,
                    onCreate: { selectedHost, name in
                        createZellijSession(on: selectedHost, name: name)
                    },
                    onCancel: { cancelZellijCreation() }
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
                cancelZellijCreation()
                cancelHerdrLifecyclePreparation()
                cancelZellijKillPreparation()
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
                selection = WorkspacePresentationLifecycle
                    .selectionAfterSnapshotChange(
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
                    suppressesHide:
                    WorkspacePresentationLifecycle.isPeerTakeoverNavigation(
                        selection,
                        pending: peerTakeoverNavigationSelection
                    ),
                    hide: hideTmuxSession
                )
            )
            .modifier(
                HerdrSessionPresentationLifecycleModifier(
                    selection: selection,
                    activeSession: activeHerdrSession,
                    suppressesDeactivation:
                    WorkspacePresentationLifecycle.isPeerTakeoverNavigation(
                        selection,
                        pending: peerTakeoverNavigationSelection
                    ),
                    deactivate: deactivateHerdrSession(_:)
                )
            )
            .modifier(
                ZellijSessionPresentationLifecycleModifier(
                    selection: selection,
                    activeSession: activeZellijSession,
                    suppressesDeactivation:
                    WorkspacePresentationLifecycle.isPeerTakeoverNavigation(
                        selection,
                        pending: peerTakeoverNavigationSelection
                    ),
                    deactivate: { _ in deactivateZellijSession() }
                )
            )
            .onChange(of: selection) { _, newSelection in
                guard !WorkspacePresentationLifecycle.isPeerTakeoverNavigation(
                    newSelection,
                    pending: peerTakeoverNavigationSelection
                ) else {
                    return
                }
                peerTakeoverNavigationSelection = nil
            }
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
                    for: .ghosthubCloseTab,
                    object: sidebarToggleTarget
                )
            ) { _ in
                guard let window = workspaceWindowProvider(),
                      window.isKeyWindow,
                      window.attachedSheet == nil
                else { return }
                handleCloseTab()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .ghosthubCommandPalette
                )
            ) { notification in
                let matchesTarget =
                    notification.object as AnyObject? === sidebarToggleTarget
                let isFocusedBroadcast =
                    notification.object == nil && controlActiveState == .key
                guard matchesTarget || isFocusedBroadcast else {
                    return
                }
                handleCommandPalette()
            }
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

                    terminalWorkspaceWithPreviewParking
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
                handlers.setTmuxSessionPreviewSidebarVisible?(visible)
            }
            .onAppear {
                handlers.setTmuxSessionPreviewSidebarVisible?(
                    isSidebarVisible
                )
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
            sectionCache: display.sidebarSectionCache,
            snapshotRevision: display.sidebarSnapshotRevision,
            selection: Binding(
                get: { selection },
                set: { selectWorkspace($0) }
            ),
            visibility: worktreeVisibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            activeTmuxSession: activeTmuxSession,
            activeHerdrSession: activeHerdrSession,
            activeZellijSession: activeZellijSession,
            activeTmuxSessionIsConnected:
            display.activeTmuxSessionIsConnected,
            connectedTmuxSessionIDs:
            display.connectedTmuxSessionIDs,
            workingTmuxSessionIDs:
            display.workingTmuxSessionIDs,
            tmuxWindowCountsBySessionID:
            display.tmuxWindowCountsBySessionID,
            previewableTmuxSessionIDs:
            display.previewableTmuxSessionIDs,
            sessionPreviewMode: display.sessionPreviewMode,
            tmuxSessionPreviewBuilder:
            content.tmuxSessionPreviewBuilder,
            onTmuxSessionPreviewExpanded: { session, expanded in
                handlers.setTmuxSessionPreviewExpanded?(session, expanded)
            },
            onOpenTmuxSession: { session, routeSelection in
                activateTmuxSession(
                    session,
                    selectionBaseline: routeSelection
                )
            },
            onOpenHerdrSession: { session in
                activateHerdrSession(session)
            },
            onOpenZellijSession: { session in
                activateZellijSession(session)
            },
            pendingHerdrSessions: display.pendingHerdrSessions,
            onRestartHerdrSession: restartHerdrSession,
            onRequestHerdrSessionLifecycle: requestHerdrSessionLifecycle,
            onNavigateAwayFromSession: {
                hideTmuxSession()
                deactivateHerdrSession()
                handlers.cancelPendingZellijPresentation?()
                deactivateZellijSession()
            },
            onRequestKillTmuxSession: requestSessionKill,
            onRequestKillZellijSession: requestZellijSessionKill,
            onRequestRemoveWorktree: requestWorktreeRemoval,
            onRequestRemoveProject: requestProjectRemoval,
            onOpenProjectWorktreesAsTabs: { project, worktrees in
                handlers.openProjectWorktreesAsTabs?(project, worktrees)
            },
            canOpenProjectWorktreesAsTabs: { project, worktrees in
                handlers.canOpenProjectWorktreesAsTabs?(
                    project,
                    worktrees
                ) ?? false
            },
            onNewWorktree: openNewWorktree,
            onImportPullRequest: openImportPullRequest,
            onNewTmuxSession: { host in
                newTmuxSessionHost = host
            },
            onNewHerdrSession: { host in
                newHerdrSessionHost = host
            },
            onNewZellijSession: { host in
                newZellijSessionHost = host
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
            zellijSessionOrderRawValue: $zellijSessionOrderRawValue,
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

    private func activateTmuxSession(
        _ session: WorkspaceTmuxSessionSelection,
        selectionBaseline: WorkspaceSelection? = nil
    ) {
        deactivateHerdrSession()
        deactivateZellijSession()
        if activeTmuxSession == session {
            tmuxSelectionBaseline = selectionBaseline ?? selection
            handlers.openTmuxSession?(session)
            return
        }
        tmuxSelectionBaseline = selectionBaseline ?? selection
        handlers.openTmuxSession?(session)
    }

    private func activateHerdrSession(
        _ session: WorkspaceHerdrSessionSelection
    ) {
        peerTakeoverNavigationSelection = WorkspaceSelection(
            selectedHostID: session.hostID
        )
        // The scene model closes the current peer only after validation.
        WorkspacePresentationLifecycle.transitionHerdrSession(
            to: session,
            from: activeHerdrSession,
            deactivate: deactivateHerdrSession(_:)
        ) {
            startHerdrSessionActivation(session)
        }
    }

    private func activateZellijSession(
        _ session: WorkspaceZellijSessionSelection
    ) {
        peerTakeoverNavigationSelection = WorkspaceSelection(
            selectedHostID: session.hostID
        )
        // The scene model closes the current peer only after validation.
        WorkspacePresentationLifecycle.startZellijSessionActivation(
            session,
            open: { handlers.openZellijSession?($0) }
        )
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
                _ = try await WorkspacePresentationLifecycle.openHerdrSession(
                    session,
                    replacing: replacedTmuxSession,
                    open: open,
                    isCurrent: isCurrent,
                    hideTmux: { replaced in
                        handlers.hideTmuxSession?(replaced)
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
        let routeSelection = WorkspacePresentationLifecycle
            .selectionForHostTmuxSession(
                session,
                from: selection,
                in: snapshot,
                visibility: worktreeVisibility
            )
        selectWorkspace(routeSelection)
        tmuxSelectionBaseline = routeSelection
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

    private func createZellijSession(
        on host: HostSummary,
        name: String
    ) {
        guard zellijCreationTask == nil else { return }
        let session = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: name
        )
        zellijCreationRevision &+= 1
        let creationRevision = zellijCreationRevision
        zellijCreationTask = Task { @MainActor in
            do {
                guard let create = handlers.createZellijSession else {
                    throw ZellijLifecycleUnavailableError()
                }
                try await create(session)
                guard zellijCreationRevision == creationRevision else {
                    return
                }
                zellijCreationTask = nil
                newZellijSessionHost = nil
                selectWorkspace(.zellijSession(
                    hostID: host.id,
                    name: name
                ))
            } catch {
                guard zellijCreationRevision == creationRevision else {
                    return
                }
                zellijCreationTask = nil
                guard !(error is CancellationError) else { return }
                presentNonWorktreeWorkspaceAlert(.zellijCreationFailure(
                    session: name,
                    message: error.localizedDescription
                ))
            }
        }
    }

    private func cancelZellijCreation(dismissSheet: Bool = true) {
        zellijCreationRevision &+= 1
        zellijCreationTask?.cancel()
        zellijCreationTask = nil
        if dismissSheet {
            newZellijSessionHost = nil
        }
    }

    private func restartHerdrSession(
        _ session: WorkspaceHerdrSessionSelection
    ) {
        WorkspacePresentationLifecycle.transitionHerdrSession(
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

    private func requestZellijSessionKill(
        _ session: WorkspaceZellijSessionSelection
    ) {
        cancelZellijKillPreparation()
        guard let prepare = handlers.prepareZellijSessionKill else {
            presentNonWorktreeWorkspaceAlert(.zellijKillFailure(
                session: session.name,
                message: "Zellij session termination is unavailable."
            ))
            return
        }
        zellijKillPreparation.start(
            prepare: {
                try await prepare(session)
            },
            cancelPrepared: { request in
                handlers.cancelZellijSessionKill?(request)
            },
            onPrepared: { request in
                presentNonWorktreeWorkspaceAlert(
                    .zellijKillConfirmation(request)
                )
            },
            onFailure: { error in
                presentNonWorktreeWorkspaceAlert(.zellijKillFailure(
                    session: session.name,
                    message: error.localizedDescription
                ))
            }
        )
    }

    private func cancelZellijKillPreparation() {
        zellijKillPreparation.cancel()
        WorkspacePresentationLifecycle.cancelPreparedZellijKill(
            workspaceAlert: &workspaceAlert,
            cancel: { request in
                handlers.cancelZellijSessionKill?(request)
            }
        )
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
        WorkspacePresentationLifecycle.cancelPreparedZellijKill(
            workspaceAlert: &workspaceAlert,
            cancel: { request in
                handlers.cancelZellijSessionKill?(request)
            }
        )
        WorkspacePresentationLifecycle.presentNonWorktreeWorkspaceAlert(
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
        case let .zellijKillConfirmation(request):
            return Alert(
                title: Text("Kill “\(request.session.name)”?”"),
                message: Text(
                    "This permanently terminates every tab, pane, and process in this Zellij session on \(request.confirmedHost.sidebarTitle)."
                ),
                primaryButton: .destructive(Text("Kill Session")) {
                    Task {
                        do {
                            guard let kill = handlers.killZellijSession else {
                                throw SessionKillUnavailableError()
                            }
                            try await kill(request)
                        } catch {
                            presentNonWorktreeWorkspaceAlert(
                                .zellijKillFailure(
                                    session: request.session.name,
                                    message: error.localizedDescription
                                )
                            )
                        }
                    }
                },
                secondaryButton: .cancel {
                    handlers.cancelZellijSessionKill?(request)
                }
            )
        case let .zellijKillFailure(session, message):
            return Alert(
                title: Text("Could Not Kill “\(session)”"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        case let .zellijCreationFailure(session, message):
            return Alert(
                title: Text("Could Not Create “\(session)”"),
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
                title: Text("Remove “\(request.worktree.name)”?"),
                message: Text(
                    "This removes the worktree at "
                        + "\(request.worktree.path)."
                        + sessionMessage
                        + " The Git branch will be kept."
                ),
                primaryButton: .destructive(Text("Remove Worktree")) {
                    WorkspacePresentationLifecycle
                        .beginWorktreeRemovalResolution(
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
                                WorkspacePresentationLifecycle
                                    .transitionWorktreeRemovalConfirmation(
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
                            selection = WorkspacePresentationLifecycle
                                .finishFailedWorktreeRemoval(
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
        case let .projectRemovalConfirmation(project, host):
            return Alert(
                title: Text("Remove “\(project.name)”?"),
                message: Text(
                    "This unregisters the project from kwt on "
                        + "\(host.sidebarTitle). The repository, its"
                        + " worktrees, and tmux sessions will not be deleted."
                ),
                primaryButton: .destructive(Text("Remove Project")) {
                    Task {
                        guard let unregister = handlers.unregisterProject
                        else {
                            presentNonWorktreeWorkspaceAlert(
                                .projectRemovalFailure(
                                    project: project.name,
                                    message: "Project removal is unavailable."
                                )
                            )
                            return
                        }
                        switch await unregister(project, host) {
                        case .success:
                            break
                        case let .failure(error):
                            presentNonWorktreeWorkspaceAlert(
                                .projectRemovalFailure(
                                    project: project.name,
                                    message: error.localizedDescription
                                )
                            )
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        case let .projectRemovalFailure(project, message):
            return Alert(
                title: Text("Could Not Remove “\(project)”"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func requestProjectRemoval(_ project: ProjectSummary) {
        guard let host = snapshot.host(id: project.hostID) else {
            presentNonWorktreeWorkspaceAlert(.projectRemovalFailure(
                project: project.name,
                message: "The project host is no longer available."
            ))
            return
        }
        presentNonWorktreeWorkspaceAlert(
            .projectRemovalConfirmation(project: project, host: host)
        )
    }

    private func requestWorktreeRemoval(_ worktree: WorktreeSummary) {
        guard WorkspacePresentationLifecycle
            .reserveWorktreeRemovalPreparation(
                worktree,
                pendingWorktrees: &pendingWorktreeRemovals
            ) else { return }
        guard let prepare = handlers.prepareWorktreeRemoval else {
            WorkspacePresentationLifecycle.clearWorktreeRemovalPreparation(
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
                let request = try await WorkspacePresentationLifecycle
                    .prepareWorktreeRemoval(
                        worktree,
                        using: prepare
                    )
                guard WorkspacePresentationLifecycle
                    .holdsWorktreeRemovalReservation(
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
                guard WorkspacePresentationLifecycle
                    .holdsWorktreeRemovalReservation(
                        worktree,
                        pendingWorktrees: pendingWorktreeRemovals
                    ) else { return }
                selection = WorkspacePresentationLifecycle
                    .finishFailedWorktreeRemoval(
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

    private func deactivateZellijSession() {
        guard let previous = activeZellijSession else { return }
        handlers.closeZellijSession?(previous)
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

    private var terminalWorkspaceWithPreviewParking: some View {
        ZStack {
            if let parkingView = content.tmuxSessionPreviewParkingBuilder?() {
                parkingView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            WorkspaceSurfaceColor.color
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            terminalWorkspaceContent
        }
    }

    @ViewBuilder
    private var terminalWorkspaceContent: some View {
        if activeTmuxSession == nil,
           activeHerdrSession == nil,
           let activeZellijSession,
           let host = snapshot.host(id: activeZellijSession.hostID),
           let view = content.zellijSessionContentBuilder?(
               host,
               activeZellijSession.name,
               isSidebarTransitioning,
               NativeSessionContentActions(
                   reconnectNow: {
                       handlers.reconnectActiveZellijSessionNow?()
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
        } else if activeTmuxSession == nil,
                  activeZellijSession == nil,
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
                  activeZellijSession == nil,
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
                  snapshot.hosts.allSatisfy({
                      $0.tmuxSessions.isEmpty
                          && $0.herdrSessions.isEmpty
                          && $0.zellijSessions.isEmpty
                  }) {
            VStack(spacing: 14) {
                Text("Welcome to Ghosthub")
                    .font(.system(size: 24, weight: .semibold))
                Text(
                    "Your kwt workspaces and multiplexer sessions will appear in the sidebar."
                )
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                Text(
                    "Register projects with kwt, or add an SSH host in Settings. Ghosthub attaches without taking over multiplexer tabs, panes, layouts, or history."
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
                    "Select a multiplexer session or kwt workspace from the sidebar."
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
            zellijSessionOrderRawValue: zellijSessionOrderRawValue,
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
        case let .newZellijSession(hostID):
            guard let host = snapshot.host(id: hostID) else { return }
            newZellijSessionHost = host
        case let .addProject(hostID):
            guard let host = snapshot.host(id: hostID) else { return }
            addProjectHost = host
        case let .openTmuxSession(tmuxSession):
            let routeSelection = WorkspacePresentationLifecycle
                .selectionForTmuxCommand(
                    tmuxSession,
                    from: selection,
                    in: snapshot,
                    visibility: worktreeVisibility
                )
            selectWorkspace(routeSelection)
            activateTmuxSession(
                tmuxSession,
                selectionBaseline: routeSelection
            )
        case let .openHerdrSession(herdrSession):
            selectWorkspace(.herdrSession(
                hostID: herdrSession.hostID,
                name: herdrSession.name
            ))
            activateHerdrSession(herdrSession)
        case let .openZellijSession(zellijSession):
            selectWorkspace(.zellijSession(
                hostID: zellijSession.hostID,
                name: zellijSession.name
            ))
            activateZellijSession(zellijSession)
        case let .restartHerdrSession(herdrSession):
            restartHerdrSession(herdrSession)
        case let .stopHerdrSession(herdrSession):
            requestHerdrSessionLifecycle(herdrSession, action: .stop)
        case let .deleteHerdrSession(herdrSession):
            requestHerdrSessionLifecycle(herdrSession, action: .delete)
        case let .killTmuxSession(tmuxSession):
            requestSessionKill(tmuxSession)
        case let .killZellijSession(zellijSession):
            requestZellijSessionKill(zellijSession)
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
            WorkspacePresentationLifecycle.deactivateSessionsForNavigation(
                hideTmux: hideTmuxSession,
                deactivateHerdr: deactivateHerdrSession,
                deactivateZellij: deactivateZellijSession
            )
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
        if zellijCreationTask != nil {
            cancelZellijCreation()
        }
        cancelHerdrPresentationIntents()
        if let selectWorkspace = handlers.selectWorkspace {
            selectWorkspace(updatedSelection)
        } else {
            selection = updatedSelection
        }
    }

    // MARK: - Notification handlers

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
        if activeZellijSession != nil {
            deactivateZellijSession()
            return
        }
        if WorkspacePresentationLifecycle.closeBorrowedSessionIfActive(
            activeTmuxSession,
            deactivate: deactivateTmuxSession
        ) {
            return
        }
        handlers.closeWindow?()
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

private struct ZellijLifecycleUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Zellij session creation is unavailable."
    }
}

private struct WorktreeRemovalUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Worktree removal is unavailable."
    }
}
