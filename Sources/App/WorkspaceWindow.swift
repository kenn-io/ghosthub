import SwiftUI
import GhosthubSettings
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubUI
import GhosthubWorkspace
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Focused value for menu commands

struct FocusedSceneModelKey: FocusedValueKey {
    typealias Value = WorkspaceSceneModel
}

extension FocusedValues {
    var sceneModel: WorkspaceSceneModel? {
        get { self[FocusedSceneModelKey.self] }
        set { self[FocusedSceneModelKey.self] = newValue }
    }
}

// MARK: - Window focus tracking

#if canImport(AppKit)
@MainActor
enum WorkspaceWindowChrome {
    static func apply(to window: NSWindow) {
        // Keep workspace controls in the standard titlebar. Native window tabs
        // add their own AppKit-managed row when a tab group is present.
        window.toolbar = nil
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // SwiftUI otherwise derives a workspace-sized floor from the root
        // view hierarchy. A terminal window must remain free to shrink to the
        // compact dimensions AppKit's standard titlebar permits.
        window.contentMinSize = .zero
        window.backgroundColor = WorkspaceSurfaceColor.nsColor
        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebar = closeButton.superview
        else { return }
        titlebar.wantsLayer = true
        titlebar.effectiveAppearance.performAsCurrentDrawingAppearance {
            titlebar.layer?.backgroundColor =
                WorkspaceSurfaceColor.nsColor.cgColor
        }
    }

}

/// Invisible NSView that reports its hosting window's key
/// status via a binding, so SwiftUI can track which window
/// is focused.
private struct WindowFocusTracker: NSViewRepresentable {
    let applicationDelegate: ApplicationDelegate
    let requestID: UUID?
    @Binding var isFocused: Bool
    var isSidebarVisible: Bool
    var sidebarWidth: CGFloat
    var canCreateWorktree: Bool
    var sessionTitle: SessionTitlebarPresentation?
    var onToggleSidebar: () -> Void
    var onQuickLaunch: () -> Void
    var onSettings: () -> Void
    var onNewWorktree: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FocusTrackingView(
            applicationDelegate: applicationDelegate,
            requestID: requestID
        )
        view.onFocusChanged = { [self] focused in
            isFocused = focused
        }
        configureTitlebar(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? FocusTrackingView else { return }
        configureTitlebar(view)
    }

    private func configureTitlebar(_ view: FocusTrackingView) {
        view.titlebarController.update(
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: sidebarWidth,
            canCreateWorktree: canCreateWorktree,
            sessionTitle: sessionTitle,
            onToggleSidebar: onToggleSidebar,
            onQuickLaunch: onQuickLaunch,
            onSettings: onSettings,
            onNewWorktree: onNewWorktree
        )
        if let window = view.window {
            view.titlebarController.install(on: window)
        }
    }

    private final class FocusTrackingView: NSView {
        nonisolated(unsafe) var onFocusChanged:
            ((Bool) -> Void)?
        private nonisolated(unsafe) var observers:
            [NSObjectProtocol] = []
        private var tabObservation: NSKeyValueObservation?
        private weak var applicationDelegate: ApplicationDelegate?
        private let requestID: UUID?
        let titlebarController: CompactWorkspaceTitlebarController

        init(
            applicationDelegate: ApplicationDelegate,
            requestID: UUID?
        ) {
            self.applicationDelegate = applicationDelegate
            self.requestID = requestID
            titlebarController = CompactWorkspaceTitlebarController(
                applicationDelegate: applicationDelegate
            )
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else {
                DispatchQueue.main.async { [weak self] in
                    self?.onFocusChanged?(false)
                }
                return
            }
            window.tabbingMode = .preferred
            window.tabbingIdentifier =
                WorkspaceWindowIdentity.tabbingIdentifier
            tabObservation = window.observe(
                \.tabbedWindows,
                options: [.initial, .new]
            ) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    self?.titlebarController.install(on: window)
                }
            }
            applicationDelegate?
                .adoptWorkspaceWindowAsTabIfRequested(
                    window,
                    requestID: requestID
                )
            titlebarController.install(on: window)
            DispatchQueue.main.async { [weak self] in
                self?.titlebarController.install(on: window)
                self?.onFocusChanged?(
                    self?.window?.isKeyWindow ?? false
                )
            }
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onFocusChanged?(true)
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onFocusChanged?(false)
                }
            )
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            guard let window else { return }
            titlebarController.install(on: window)
        }

        private func removeObservers() {
            tabObservation?.invalidate()
            tabObservation = nil
            for observer in observers {
                NotificationCenter.default
                    .removeObserver(observer)
            }
            observers.removeAll()
        }

        deinit {
            for observer in observers {
                NotificationCenter.default
                    .removeObserver(observer)
            }
        }
    }
}

@MainActor
private final class DraggableTitlebarHostingView:
    NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class WorkspaceWindowCloseDelegate: NSObject,
    NSWindowDelegate {
    weak var applicationDelegate: ApplicationDelegate?
    private weak var installedWindow: NSWindow?
    private weak var installedCloseButton: NSButton?
    private nonisolated(unsafe) weak var forwardingCloseTarget:
        AnyObject?
    private var forwardingCloseAction: Selector?
    private nonisolated(unsafe) weak var forwardingDelegate:
        NSWindowDelegate?

    func install(on window: NSWindow) {
        if installedWindow !== window {
            restoreInstalledWindow()
            installedWindow = window
        }
        if window.delegate !== self {
            forwardingDelegate = window.delegate
            window.delegate = self
        }
        guard let closeButton = window.standardWindowButton(.closeButton)
        else { return }
        if installedCloseButton !== closeButton {
            restoreInstalledCloseButton()
            installedCloseButton = closeButton
            forwardingCloseTarget = closeButton.target as AnyObject?
            forwardingCloseAction = closeButton.action
        }
        closeButton.target = self
        closeButton.action = #selector(requestWindowClose(_:))
    }

    @objc private func requestWindowClose(_ sender: Any?) {
        applicationDelegate?.requestWorkspaceWindowClose(installedWindow)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        applicationDelegate?.requestWorkspaceTabClose(sender)
        return false
    }

    override nonisolated func responds(
        to selector: Selector!
    ) -> Bool {
        super.responds(to: selector)
            || forwardingDelegate?.responds(to: selector) == true
    }

    override nonisolated func forwardingTarget(
        for selector: Selector!
    ) -> Any? {
        guard forwardingDelegate?.responds(to: selector) == true
        else {
            return super.forwardingTarget(for: selector)
        }
        return forwardingDelegate
    }

    private func restoreInstalledWindow() {
        restoreInstalledCloseButton()
        guard let installedWindow,
              installedWindow.delegate === self
        else { return }
        installedWindow.delegate = forwardingDelegate
    }

    private func restoreInstalledCloseButton() {
        guard let installedCloseButton,
              installedCloseButton.target === self
        else { return }
        installedCloseButton.target = forwardingCloseTarget
        installedCloseButton.action = forwardingCloseAction
        self.installedCloseButton = nil
        forwardingCloseTarget = nil
        forwardingCloseAction = nil
    }
}

@MainActor
final class CompactWorkspaceTitlebarController {
    private static let sidebarIdentifier = NSUserInterfaceItemIdentifier(
        "GhosthubCompactSidebarControl"
    )
    private static let actionsIdentifier = NSUserInterfaceItemIdentifier(
        "GhosthubCompactWorkspaceActions"
    )
    private static let titleIdentifier = NSUserInterfaceItemIdentifier(
        "GhosthubCompactSessionTitle"
    )

    private let sidebarHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let titleHost = DraggableTitlebarHostingView(
        rootView: AnyView(EmptyView())
    )
    private let actionsHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let closeDelegate = WorkspaceWindowCloseDelegate()
    private weak var installedWindow: NSWindow?
    private var titleLeadingConstraint: NSLayoutConstraint?
    private var isSidebarVisible = true
    private var sidebarWidth = WorkspaceSidebarWidthPolicy.defaultWidth
    private var canCreateWorktree = false
    private var sessionTitle: SessionTitlebarPresentation?
    private var onToggleSidebar: () -> Void = {}
    private var onQuickLaunch: () -> Void = {}
    private var onSettings: () -> Void = {}
    private var onNewWorktree: () -> Void = {}

    init(applicationDelegate: ApplicationDelegate? = nil) {
        closeDelegate.applicationDelegate = applicationDelegate
        sidebarHost.identifier = Self.sidebarIdentifier
        titleHost.identifier = Self.titleIdentifier
        actionsHost.identifier = Self.actionsIdentifier
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        titleHost.translatesAutoresizingMaskIntoConstraints = false
        actionsHost.translatesAutoresizingMaskIntoConstraints = false
        titleHost.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
    }

    func install(on window: NSWindow) {
        WorkspaceWindowChrome.apply(to: window)
        window.title = sessionTitle?.title ?? "Ghosthub"
        titleHost.isHidden = !Self.showsTitle(
            tabCount: window.tabbedWindows?.count ?? 1
        )
        if closeDelegate.applicationDelegate != nil {
            closeDelegate.install(on: window)
        }

        guard let closeButton = window.standardWindowButton(.closeButton),
              let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebar = closeButton.superview
        else { return }
        guard installedWindow !== window
            || sidebarHost.superview !== titlebar
            || titleHost.superview !== titlebar
            || actionsHost.superview !== titlebar
        else { return }

        removeControlsFromInstalledWindow()
        titlebar.subviews
            .filter {
                ($0.identifier == Self.sidebarIdentifier
                    || $0.identifier == Self.titleIdentifier
                    || $0.identifier == Self.actionsIdentifier)
                    && $0 !== sidebarHost
                    && $0 !== titleHost
                    && $0 !== actionsHost
            }
            .forEach { $0.removeFromSuperview() }
        titlebar.addSubview(sidebarHost)
        titlebar.addSubview(titleHost)
        titlebar.addSubview(actionsHost)
        let titleLeadingConstraint = titleHost.leadingAnchor.constraint(
            equalTo: titlebar.leadingAnchor,
            constant: Self.titleLeadingOffset(
                isSidebarVisible: isSidebarVisible,
                sidebarWidth: sidebarWidth
            )
        )
        self.titleLeadingConstraint = titleLeadingConstraint
        NSLayoutConstraint.activate([
            sidebarHost.leadingAnchor.constraint(
                equalTo: zoomButton.trailingAnchor,
                constant: 12
            ),
            sidebarHost.centerYAnchor.constraint(
                equalTo: closeButton.centerYAnchor
            ),
            sidebarHost.widthAnchor.constraint(equalToConstant: 22),
            sidebarHost.heightAnchor.constraint(equalToConstant: 22),
            titleLeadingConstraint,
            titleHost.trailingAnchor.constraint(
                lessThanOrEqualTo: actionsHost.leadingAnchor,
                constant: -12
            ),
            titleHost.centerYAnchor.constraint(
                equalTo: closeButton.centerYAnchor
            ),
            titleHost.heightAnchor.constraint(equalToConstant: 22),
            actionsHost.trailingAnchor.constraint(
                equalTo: titlebar.trailingAnchor,
                constant: -10
            ),
            actionsHost.centerYAnchor.constraint(
                equalTo: closeButton.centerYAnchor
            ),
            actionsHost.widthAnchor.constraint(equalToConstant: 82),
            actionsHost.heightAnchor.constraint(equalToConstant: 22),
        ])
        installedWindow = window
    }

    static func showsTitle(tabCount: Int) -> Bool {
        tabCount <= 1
    }

    static func titleLeadingOffset(
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat
    ) -> CGFloat {
        guard isSidebarVisible else { return 120 }
        return max(120, sidebarWidth + 12)
    }

    func update(
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat = WorkspaceSidebarWidthPolicy.defaultWidth,
        canCreateWorktree: Bool,
        sessionTitle: SessionTitlebarPresentation?,
        onToggleSidebar: @escaping () -> Void,
        onQuickLaunch: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onNewWorktree: @escaping () -> Void
    ) {
        let sidebarVisibilityChanged = self.isSidebarVisible
            != isSidebarVisible
        self.isSidebarVisible = isSidebarVisible
        self.sidebarWidth = WorkspaceSidebarWidthPolicy.clampedWidth(
            sidebarWidth
        )
        self.canCreateWorktree = canCreateWorktree
        self.sessionTitle = sessionTitle
        self.onToggleSidebar = onToggleSidebar
        self.onQuickLaunch = onQuickLaunch
        self.onSettings = onSettings
        self.onNewWorktree = onNewWorktree
        refreshHosts()
        let titleLeadingOffset = Self.titleLeadingOffset(
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: self.sidebarWidth
        )
        if sidebarVisibilityChanged,
           let titleLeadingConstraint {
            let container = titleHost.superview
            container?.layoutSubtreeIfNeeded()
            titleLeadingConstraint.constant = titleLeadingOffset
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(
                    name: .easeInEaseOut
                )
                container?.animator().layoutSubtreeIfNeeded()
            }
        } else {
            titleLeadingConstraint?.constant = titleLeadingOffset
        }
    }

    private func refreshHosts() {
        sidebarHost.rootView = AnyView(sidebarView)
        titleHost.rootView = AnyView(titleView)
        actionsHost.rootView = AnyView(actionsView)
    }

    private var sidebarView: some View {
        CompactToolbarButton(
            systemImage: isSidebarVisible ? "sidebar.left" : "sidebar.right",
            help: isSidebarVisible
                ? "Hide Sidebar (Cmd+B)" : "Show Sidebar (Cmd+B)",
            action: onToggleSidebar
        )
    }

    private var actionsView: some View {
        HStack(spacing: 10) {
            CompactToolbarButton(
                systemImage: "command",
                help: "Quick Launch (Cmd+Shift+P)",
                action: onQuickLaunch
            )
            CompactToolbarButton(
                systemImage: "gearshape",
                help: "Settings (Cmd+,)",
                action: onSettings
            )
            CompactToolbarButton(
                systemImage: "plus.rectangle.on.folder",
                help: canCreateWorktree
                    ? "New Worktree (Cmd+Shift+N)"
                    : "Select a kwt project to create a worktree",
                isEnabled: canCreateWorktree,
                action: onNewWorktree
            )
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if let sessionTitle {
            HStack(spacing: 5) {
                Image(systemName: sessionTitle.icon.systemImageName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sessionTitle.sessionName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(sessionTitle.hostname)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(sessionTitle.title)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(sessionTitle.title)
        } else {
            Text("Ghosthub")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Ghosthub")
        }
    }

    private func removeControlsFromInstalledWindow() {
        titleLeadingConstraint = nil
        sidebarHost.removeFromSuperview()
        titleHost.removeFromSuperview()
        actionsHost.removeFromSuperview()
    }
}

private struct CompactToolbarButton: View {
    var systemImage: String
    var help: String
    var isEnabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif

// MARK: - Per-window view

struct WorkspaceWindow: View {
    #if canImport(AppKit)
    let applicationDelegate: ApplicationDelegate
    @Binding var windowState: WorkspaceWindowState?
    let updateRelaunchRestorer: UpdateRelaunchRestorer
    let openRelaunchWindow: (WorkspaceWindowState) -> Void
    #endif
    @State private var windowStateBuffer = WorkspaceWindowStateBuffer()
    @State private var updateRelaunchSceneID = UUID()
    @State private var updateRelaunchWindowID: UUID?
    @StateObject private var sceneModel: WorkspaceSceneModel
    @EnvironmentObject private var terminalRuntime: LibghosttyRuntime
    @ObservedObject private var settingsStore = SettingsStore.shared
    @State private var visibleConfigReloadNotice:
        LibghosttyConfigReloadNotice?
    @State private var titlebarSidebarWidth =
        WorkspaceSidebarWidthPolicy.defaultWidth
    private let registry = WindowRegistry.shared

    #if canImport(AppKit)
    init(
        applicationDelegate: ApplicationDelegate,
        windowState: Binding<WorkspaceWindowState?>,
        updateRelaunchRestorer: UpdateRelaunchRestorer,
        openRelaunchWindow: @escaping (WorkspaceWindowState) -> Void
    ) {
        self.applicationDelegate = applicationDelegate
        _windowState = windowState
        self.updateRelaunchRestorer = updateRelaunchRestorer
        self.openRelaunchWindow = openRelaunchWindow
        _sceneModel = StateObject(wrappedValue: WorkspaceSceneModel(
            sshAuthenticationCoordinator:
            applicationDelegate.sshAuthenticationCoordinator
        ))
    }
    #endif

    var body: some View {
        return RootView(
            display: WorkspaceDisplayState(
                snapshot: sceneModel.snapshot,
                workspaceResourceSummary:
                sceneModel.workspaceResourceSummary,
                activatedWorktreeIDs:
                sceneModel.activatedWorktreeIDs,
                activeAgentWorktreeIDs:
                sceneModel.activeAgentWorktreeIDs,
                activeProcessWorktreeIDs:
                sceneModel.activeProcessWorktreeIDs,
                paneResourceSamples:
                sceneModel.paneResourceSamples,
                paneAgentActivities:
                sceneModel.paneAgentActivities,
                activityReferenceDate:
                sceneModel.activityReferenceDate,
                idleThresholdsBySessionID:
                sceneModel.sessionIdleThresholdsByID,
                defaultIdleThresholdSeconds:
                sceneModel.defaultIdleThresholdSeconds,
                isWorkspaceInventoryLoading:
                sceneModel.workspaceInventoryState == .loading,
                isWorkspaceInventoryRefreshComplete:
                sceneModel.isWorkspaceInventoryRefreshComplete,
                workspaceInventoryError: {
                    if case let .failed(message) =
                        sceneModel.workspaceInventoryState {
                        return message
                    }
                    return nil
                }(),
                workspaceInventoryWarning:
                sceneModel.workspaceInventoryWarning,
                workspaceInventoryWarningsByHost:
                sceneModel.workspaceInventoryWarningsByHost,
                isWorkspaceRestorationPending:
                sceneModel.isWorkspaceRestorationPending,
                suppressesAutomaticWorktreeSessionOpen:
                sceneModel.suppressesAutomaticWorktreeSessionOpen,
                activeTmuxSession:
                sceneModel.activeBorrowedTmuxSelection,
                activeTmuxSessionIsConnected:
                sceneModel.activeBorrowedTmuxSessionIsConnected,
                activeTmuxSessionCanApplyTheme:
                sceneModel.canApplyThemeToActiveTmuxSession
            ),
            content: ContentBuilders(
                tmuxSessionContentBuilder: {
                    [sceneModel] host, sessionName, defersTerminalResize in
                    sceneModel.borrowedTmuxSessionView(
                        host: host,
                        sessionName: sessionName,
                        defersTerminalResize: defersTerminalResize
                    )
                },
                settingsSheetBuilder: { settingsStore in
                    AnyView(
                        SettingsView(
                            store: settingsStore,
                            actions: SettingsActions(
                                refreshHosts: {
                                    sceneModel
                                        .refreshHosts()
                                },
                                probeSSHHost: {
                                    host in
                                    await sceneModel
                                        .probeSSHHost(
                                            host
                                        )
                                },
                                pendingSSHHostKeyConfirmation: {
                                    host in
                                    await sceneModel
                                        .pendingSSHHostKeyConfirmation(
                                            for: host
                                        )
                                },
                                trustSSHHostKey: {
                                    confirmation, host in
                                    await sceneModel
                                        .trustSSHHostKey(
                                            confirmation,
                                            for: host
                                        )
                                },
                                sshAuthenticationView: {
                                    surfaceID, host in
                                    sceneModel.sshAuthenticationView(
                                        surfaceID: surfaceID,
                                        for: host
                                    )
                                },
                                isSSHAuthenticationReady: { host in
                                    await sceneModel
                                        .isSSHAuthenticationReady(for: host)
                                },
                                cancelSSHAuthentication: { surfaceID in
                                    sceneModel.cancelSSHAuthentication(
                                        surfaceID: surfaceID
                                    )
                                },
                                loadTailscalePeers: {
                                    await TailscaleDiscovery
                                        .discoverPeers()
                                        .peerLoadResult
                                },
                                installRemoteKwt: {
                                    host in
                                    await sceneModel
                                        .installRemoteKwt(
                                            on: host
                                        )
                                },
                                registerRemoteProject: {
                                    host, path in
                                    await sceneModel
                                        .registerRemoteProject(
                                            path,
                                            on: host
                                        )
                                },
                                installWindowsKwt: {
                                    host in
                                    await sceneModel
                                        .installWindowsKwt(
                                            on: host
                                        )
                                },
                                reloadTerminalConfig: {
                                    sceneModel.reloadTerminalConfig()
                                }
                            )
                        )
                    )
                },
                logViewerBuilder: { [sceneModel] in
                    sceneModel.logViewerTerminalView()
                },
                sshAuthenticationBuilder: { [sceneModel] hostID in
                    sceneModel.sshAuthenticationView(
                        forHostID: hostID
                    )
                }
            ),
            handlers: InteractionHandlers(
                closeWindow: { [applicationDelegate] in
                    applicationDelegate.requestWorkspaceTabClose(
                        NSApplication.shared.keyWindow
                    )
                },
                dismissLogViewer: { [sceneModel] in
                    sceneModel.dismissLogViewer()
                },
                reloadTerminalConfig: {
                    sceneModel.reloadTerminalConfig()
                },
                selectWorkspace: { [sceneModel] selection in
                    sceneModel.selectFromUser(selection)
                },
                openTmuxSession: { [sceneModel] selection in
                    sceneModel.openBorrowedTmuxSession(selection)
                },
                closeTmuxSession: { [sceneModel] selection in
                    sceneModel.closeBorrowedTmuxSession(selection)
                },
                prepareTmuxSessionKill: { [sceneModel] selection in
                    try await sceneModel.prepareTmuxSessionKill(selection)
                },
                killTmuxSession: { [sceneModel] request in
                    try await sceneModel.killTmuxSession(request)
                },
                applyTmuxSessionTheme: { [sceneModel] selection in
                    try await sceneModel.applyTheme(to: selection)
                },
                createTmuxSession: { [sceneModel] selection in
                    sceneModel.createTmuxSession(selection)
                },
                refreshWorkspaceInventory: { [sceneModel] in
                    sceneModel.refreshKwtInventory()
                },
                reviewSSHHostKey: { [sceneModel] hostID, inventoryWarning in
                    await sceneModel.sshConnectionRecovery(
                        forHostID: hostID,
                        inventoryWarning: inventoryWarning
                    )
                },
                trustSSHHostKey: { [sceneModel] hostID, confirmation in
                    await sceneModel.trustSSHHostKey(
                        confirmation,
                        forHostID: hostID
                    )
                },
                isSSHAuthenticationReady: { [sceneModel] hostID in
                    await sceneModel.isSSHAuthenticationReady(
                        forHostID: hostID
                    )
                },
                cancelSSHAuthentication: { [sceneModel] hostID in
                    sceneModel.cancelSSHAuthentication(
                        surfaceID: hostID
                    )
                },
                registerProject: { [sceneModel] host, path in
                    await sceneModel.registerProject(path, on: host)
                },
                createWorktree: { [sceneModel] request in
                    try await sceneModel.createWorktree(request)
                },
                listBranches: { [sceneModel] projectID in
                    try await sceneModel.branches(for: projectID)
                },
                listPullRequests: { [sceneModel] projectID in
                    try await sceneModel.pullRequests(for: projectID)
                },
                importPullRequest: { [sceneModel] request in
                    try await sceneModel.importPullRequest(request)
                },
                prepareWorktreeRemoval: { [sceneModel] worktreeID in
                    try await sceneModel.prepareWorktreeRemoval(worktreeID)
                },
                removeWorktree: { [sceneModel] request in
                    try await sceneModel.removeWorktree(request)
                }
            ),
            sidebarToggleTarget: sceneModel,
            sidebarWidthChanged: { width in
                titlebarSidebarWidth = width
            },
            settingsStore: settingsStore,
            selection: Binding(
                get: { sceneModel.selection },
                set: { sceneModel.synchronizeSelection($0) }
            ),
            isSidePanelVisible: Binding(
                get: { sceneModel.isSidePanelVisible },
                set: { sceneModel.setSidePanelVisible($0) }
            ),
            columnVisibility: Binding(
                get: { sceneModel.columnVisibility },
                set: { sceneModel.columnVisibility = $0 }
            ),
            isCommandPalettePresented: Binding(
                get: { sceneModel.isCommandPalettePresented },
                set: {
                    sceneModel.isCommandPalettePresented = $0
                }
            ),
            isLogViewerPresented: Binding(
                get: { sceneModel.isLogViewerPresented },
                set: { sceneModel.isLogViewerPresented = $0 }
            ),
            isSettingsPresented: Binding(
                get: { sceneModel.isSettingsPresented },
                set: { sceneModel.isSettingsPresented = $0 }
            )
        )
        .focusedSceneValue(\.sceneModel, sceneModel)
        .background(WorkspaceSurfaceColor.color.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let notice = visibleConfigReloadNotice {
                ConfigReloadNoticeView(
                    notice: notice,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            visibleConfigReloadNotice = nil
                        }
                    }
                )
                .padding(.top, 8)
                .padding(.horizontal, 12)
                .transition(
                    .move(edge: .top).combined(with: .opacity)
                )
            }
        }
        #if canImport(AppKit)
        .background(
            WindowFocusTracker(
                applicationDelegate: applicationDelegate,
                requestID: resolvedWindowState.wrappedValue.windowID,
                isFocused: Binding(
                    get: { sceneModel.isFocusedWindow },
                    set: { sceneModel.isFocusedWindow = $0 }
                ),
                isSidebarVisible:
                sceneModel.columnVisibility != .detailOnly,
                sidebarWidth: titlebarSidebarWidth,
                canCreateWorktree: canCreateWorktree,
                sessionTitle: SessionTitlebarPresentation.resolve(
                    activeSession: sceneModel.activeBorrowedTmuxSelection,
                    in: sceneModel.snapshot
                ),
                onToggleSidebar: {
                    NotificationCenter.default.post(
                        name: .ghosthubToggleSidebar,
                        object: sceneModel
                    )
                },
                onQuickLaunch: {
                    NotificationCenter.default.post(
                        name: .ghosthubCommandPalette,
                        object: nil
                    )
                },
                onSettings: {
                    sceneModel.isSettingsPresented = true
                },
                onNewWorktree: {
                    NotificationCenter.default.post(
                        name: .ghosthubNewWorktree,
                        object: nil
                    )
                }
            )
        )
        #endif
        .onChange(of: sceneModel.restorationState(
            windowID: resolvedWindowState.wrappedValue.windowID
        )) { _, state in
            resolvedWindowState.wrappedValue = state
        }
        .onChange(of: windowState) { _, state in
            #if canImport(AppKit)
            switch updateRelaunchRestorer.receivePresentedState(
                sceneID: updateRelaunchSceneID,
                presented: state
            ) {
            case .ordinary:
                break
            case .waitingForNativeRestoration:
                if updateRelaunchWindowID != nil {
                    refreshWindowState()
                }
                updateRelaunchRestorer
                    .reconcileIfNativeRestorationFinished()
                return
            case let .restore(savedState):
                restoreForUpdateRelaunch(savedState)
                updateRelaunchRestorer
                    .reconcileIfNativeRestorationFinished()
                return
            }
            updateRelaunchRestorer
                .reconcileIfNativeRestorationFinished()
            #endif
            if let updateRelaunchWindowID,
               let replacement = UpdateRelaunchStatePolicy.replacement(
                   presented: state,
                   current: sceneModel.restorationState(
                       windowID: updateRelaunchWindowID
                   )
               ) {
                resolvedWindowState.wrappedValue = replacement
                return
            }
            if let restoredState = windowStateBuffer.receive(state) {
                sceneModel.beginRestoration(restoredState)
            }
        }
        .onAppear {
            #if canImport(AppKit)
            switch updateRelaunchRestorer.registerScene(
                id: updateRelaunchSceneID,
                presented: windowState,
                restore: restoreForUpdateRelaunch,
                openWindow: openRelaunchWindow
            ) {
            case .ordinary:
                beginPresentedRestoration(windowState)
                refreshWindowState()
            case .waitingForNativeRestoration:
                beginPresentedRestoration(nil)
            case let .restore(savedState):
                restoreForUpdateRelaunch(savedState)
            }
            updateRelaunchRestorer
                .reconcileIfNativeRestorationFinished()
            #else
            beginPresentedRestoration(nil)
            refreshWindowState()
            #endif
            registry.register(
                sceneModel,
                captureRestorationState: captureWindowState
            )
            if terminalRuntime.configReloadNotice?.kind == .error {
                visibleConfigReloadNotice =
                    terminalRuntime.configReloadNotice
            }
        }
        .onReceive(
            terminalRuntime.configReloadNotices
        ) { notice in
            withAnimation(.easeOut(duration: 0.15)) {
                visibleConfigReloadNotice = notice
            }
        }
        .task(id: visibleConfigReloadNotice?.id) {
            guard visibleConfigReloadNotice?.kind == .success
            else { return }
            try? await Task.sleep(
                nanoseconds: 2_500_000_000
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                visibleConfigReloadNotice = nil
            }
        }
        .onDisappear {
            sceneModel.cancelPendingRestoration()
            registry.unregister(sceneModel)
            #if canImport(AppKit)
            updateRelaunchRestorer.unregisterScene(
                id: updateRelaunchSceneID
            )
            #endif
            Task { [sceneModel] in
                await sceneModel.shutdown()
            }
        }
    }

    private func beginPresentedRestoration(
        _ state: WorkspaceWindowState?
    ) {
        if let state = windowStateBuffer.beginAppearance(with: state) {
            sceneModel.beginRestoration(state)
        }
    }

    #if canImport(AppKit)
    private func restoreForUpdateRelaunch(
        _ state: WorkspaceWindowState
    ) {
        updateRelaunchWindowID = state.windowID
        _ = windowStateBuffer.beginAppearance(with: state)
        if windowState != state {
            windowStateBuffer.prepareToPresent(state)
            windowState = state
        }
        sceneModel.beginRestoration(state)
        updateRelaunchRestorer.didBeginRestoring(
            windowID: state.windowID
        )
        refreshWindowState()
    }
    #endif

    private func captureWindowState() -> WorkspaceWindowState {
        let state = sceneModel.restorationState(
            windowID: resolvedWindowState.wrappedValue.windowID
        )
        resolvedWindowState.wrappedValue = state
        return state
    }

    private func refreshWindowState() {
        _ = captureWindowState()
    }

    private var resolvedWindowState: Binding<WorkspaceWindowState> {
        Binding(
            get: {
                windowStateBuffer.resolved(windowState)
            },
            set: { state in
                windowStateBuffer.prepareToPresent(state)
                windowState = state
            }
        )
    }

    private var canCreateWorktree: Bool {
        guard let project = WorkspaceSelectionResolver.selectedProject(
            in: sceneModel.snapshot,
            selection: sceneModel.selection
        ) else { return false }
        return sceneModel.snapshot.canCreateWorktree(in: project)
    }
}

private struct ConfigReloadNoticeView: View {
    let notice: LibghosttyConfigReloadNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: notice.kind == .success
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(
                notice.kind == .success ? .green : .orange
            )

            Text(notice.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(3)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss configuration message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(
            cornerRadius: 8,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.7), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.message)
    }
}
