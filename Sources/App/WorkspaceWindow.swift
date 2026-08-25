import SwiftUI
import Combine
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

struct TerminalKeyboardFocusKey: FocusedValueKey {
    typealias Value = Bool
}

struct SiblingShortcutAvailabilityKey: FocusedValueKey {
    typealias Value = Set<ApplicationShortcutAction>
}

extension FocusedValues {
    var sceneModel: WorkspaceSceneModel? {
        get { self[FocusedSceneModelKey.self] }
        set { self[FocusedSceneModelKey.self] = newValue }
    }

    var terminalHasEffectiveKeyboardFocus: Bool? {
        get { self[TerminalKeyboardFocusKey.self] }
        set { self[TerminalKeyboardFocusKey.self] = newValue }
    }

    var availableSiblingShortcuts: Set<ApplicationShortcutAction>? {
        get { self[SiblingShortcutAvailabilityKey.self] }
        set { self[SiblingShortcutAvailabilityKey.self] = newValue }
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
    var customTitle: String?
    var onToggleSidebar: () -> Void
    var onQuickLaunch: () -> Void
    var onSettings: () -> Void
    var onNewWorktree: () -> Void
    var onRenameWindow: () -> Void
    var onWindowChanged: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FocusTrackingView(
            applicationDelegate: applicationDelegate,
            requestID: requestID
        )
        view.onFocusChanged = { [self] focused in
            isFocused = focused
        }
        view.onWindowChanged = onWindowChanged
        configureTitlebar(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? FocusTrackingView else { return }
        view.onWindowChanged = onWindowChanged
        configureTitlebar(view)
    }

    private func configureTitlebar(_ view: FocusTrackingView) {
        let didUpdate = view.titlebarController.update(
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: sidebarWidth,
            canCreateWorktree: canCreateWorktree,
            sessionTitle: sessionTitle,
            customTitle: customTitle,
            onToggleSidebar: onToggleSidebar,
            onQuickLaunch: onQuickLaunch,
            onSettings: onSettings,
            onNewWorktree: onNewWorktree,
            onRenameWindow: onRenameWindow
        )
        if didUpdate, let window = view.window {
            view.titlebarController.install(on: window)
        }
    }

    private final class FocusTrackingView: NSView {
        nonisolated(unsafe) var onFocusChanged:
            ((Bool) -> Void)?
        nonisolated(unsafe) var onWindowChanged:
            ((NSWindow?) -> Void)?
        private nonisolated(unsafe) var observers:
            [NSObjectProtocol] = []
        private var tabObservation: NSKeyValueObservation?
        private weak var applicationDelegate: ApplicationDelegate?
        private let requestID: UUID?
        private let tabBadgeController = NativeTabBadgeController(
            shortcuts: SettingsStore.shared.$shortcutPreferences
                .map(\.resolved)
                .eraseToAnyPublisher()
        )
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
            onWindowChanged?(window)
            guard let window else {
                DispatchQueue.main.async { [weak self] in
                    self?.onFocusChanged?(false)
                }
                return
            }
            window.tabbingMode = .preferred
            window.tabbingIdentifier =
                WorkspaceWindowIdentity.tabbingIdentifier
            NativeTabCommands.installBracketShortcuts()
            tabBadgeController.install(on: window)
            tabObservation = window.observe(
                \.tabbedWindows,
                options: [.initial, .new]
            ) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    self?.titlebarController.install(on: window)
                    self?.tabBadgeController.refresh()
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
            tabBadgeController.invalidate()
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
    private struct Presentation: Equatable {
        let isSidebarVisible: Bool
        let sidebarWidth: CGFloat
        let canCreateWorktree: Bool
        let sessionTitle: SessionTitlebarPresentation?
        let customTitle: String?
    }

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
    private var customTitle: String?
    private var onToggleSidebar: () -> Void = {}
    private var onQuickLaunch: () -> Void = {}
    private var onSettings: () -> Void = {}
    private var onNewWorktree: () -> Void = {}
    private var onRenameWindow: () -> Void = {}
    private var renderedPresentation: Presentation?

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
        window.title = customTitle ?? sessionTitle?.title ?? "Ghosthub"
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

    @discardableResult
    func update(
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat = WorkspaceSidebarWidthPolicy.defaultWidth,
        canCreateWorktree: Bool,
        sessionTitle: SessionTitlebarPresentation?,
        customTitle: String? = nil,
        onToggleSidebar: @escaping () -> Void,
        onQuickLaunch: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onNewWorktree: @escaping () -> Void,
        onRenameWindow: @escaping () -> Void = {}
    ) -> Bool {
        let sidebarWidth = WorkspaceSidebarWidthPolicy.clampedWidth(
            sidebarWidth
        )
        let presentation = Presentation(
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: sidebarWidth,
            canCreateWorktree: canCreateWorktree,
            sessionTitle: sessionTitle,
            customTitle: customTitle
        )
        let sidebarVisibilityChanged = self.isSidebarVisible
            != isSidebarVisible
        self.onToggleSidebar = onToggleSidebar
        self.onQuickLaunch = onQuickLaunch
        self.onSettings = onSettings
        self.onNewWorktree = onNewWorktree
        self.onRenameWindow = onRenameWindow
        guard renderedPresentation != presentation else { return false }

        renderedPresentation = presentation
        self.isSidebarVisible = isSidebarVisible
        self.sidebarWidth = sidebarWidth
        self.canCreateWorktree = canCreateWorktree
        self.sessionTitle = sessionTitle
        self.customTitle = customTitle
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
        return true
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
            action: { [weak self] in self?.onToggleSidebar() }
        )
    }

    private var actionsView: some View {
        HStack(spacing: 10) {
            CompactToolbarButton(
                systemImage: "command",
                help: "Quick Launch (Cmd+Shift+P)",
                action: { [weak self] in self?.onQuickLaunch() }
            )
            CompactToolbarButton(
                systemImage: "gearshape",
                help: "Settings (Cmd+,)",
                action: { [weak self] in self?.onSettings() }
            )
            CompactToolbarButton(
                systemImage: "plus.rectangle.on.folder",
                help: canCreateWorktree
                    ? "New Worktree (Cmd+Shift+N)"
                    : "Select a kwt project to create a worktree",
                isEnabled: canCreateWorktree,
                action: { [weak self] in self?.onNewWorktree() }
            )
        }
    }

    private var titleView: some View {
        EditableWindowTitleView(
            customTitle: customTitle,
            sessionTitle: sessionTitle,
            onRename: { [weak self] in self?.onRenameWindow() }
        )
    }

    private func removeControlsFromInstalledWindow() {
        titleLeadingConstraint = nil
        sidebarHost.removeFromSuperview()
        titleHost.removeFromSuperview()
        actionsHost.removeFromSuperview()
    }
}

private struct EditableWindowTitleView: View {
    let customTitle: String?
    let sessionTitle: SessionTitlebarPresentation?
    let onRename: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onRename) {
            HStack(spacing: 5) {
                title
                if isHovered {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 16, height: 16)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename Window")
        .accessibilityLabel("Rename Window")
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var title: some View {
        if let customTitle {
            Text(customTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(customTitle)
                .accessibilityLabel(customTitle)
        } else if let sessionTitle {
            HStack(spacing: 5) {
                Image(systemName: sessionTitle.icon.systemImageName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sessionTitle.displayName)
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
    @State private var customWindowTitle: String?
    @State private var windowTitleRenameRequest:
        WorkspaceWindowTitleRenameRequest?
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
        _sceneModel = StateObject(wrappedValue: WorkspaceSceneModel())
    }
    #endif

    var body: some View {
        return RootView(
            display: WorkspaceDisplayState(
                snapshot: sceneModel.snapshot,
                sidebarSectionCache: sceneModel.sidebarSectionCache,
                sidebarSnapshotRevision:
                sceneModel.sidebarSnapshotRevision,
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
                sceneModel.suppressesSelectedWorktreeSessionOpen,
                activeTmuxSession:
                sceneModel.activeBorrowedTmuxSelection,
                activeTmuxSessionIsConnected:
                sceneModel.activeBorrowedTmuxSessionIsConnected,
                connectedTmuxSessionIDs:
                sceneModel.connectedBorrowedTmuxSessionIDs,
                activeTmuxSessionCanApplyTheme:
                sceneModel.canApplyThemeToActiveTmuxSession,
                availableApplicationShortcuts:
                sceneModel.availablePaletteApplicationShortcuts,
                activeHerdrSession:
                sceneModel.activeBorrowedHerdrSelection,
                activeZellijSession:
                sceneModel.activeBorrowedZellijSelection,
                pendingHerdrSessions:
                sceneModel.pendingHerdrSessionSelections,
                sessionConnectionRecoveryRequest:
                sceneModel.sessionConnectionRecoveryRequest,
                workingTmuxSessionIDs:
                sceneModel.workingTmuxSessionIDs,
                tmuxWindowCountsBySessionID:
                sceneModel.tmuxWindowCountsBySessionID,
                previewableTmuxSessionIDs:
                sceneModel.previewableTmuxSessionIDs,
                sessionPreviewMode: settingsStore.sessionPreviewMode
            ),
            content: ContentBuilders(
                tmuxSessionContentBuilder: {
                    [sceneModel]
                    host, sessionName, defersTerminalResize, actions in
                    sceneModel.borrowedTmuxSessionView(
                        host: host,
                        sessionName: sessionName,
                        defersTerminalResize: defersTerminalResize,
                        onReconnectNow: actions.reconnectNow,
                        onReviewConnection: actions.reviewConnection
                    )
                },
                herdrSessionContentBuilder: {
                    [sceneModel]
                    host, sessionName, defersTerminalResize, actions in
                    sceneModel.borrowedHerdrSessionView(
                        host: host,
                        sessionName: sessionName,
                        defersTerminalResize: defersTerminalResize,
                        onReconnectNow: actions.reconnectNow,
                        onReviewConnection: actions.reviewConnection
                    )
                },
                zellijSessionContentBuilder: {
                    [sceneModel]
                    host, sessionName, defersTerminalResize, actions in
                    sceneModel.borrowedZellijSessionView(
                        host: host,
                        sessionName: sessionName,
                        defersTerminalResize: defersTerminalResize,
                        onReconnectNow: actions.reconnectNow,
                        onReviewConnection: actions.reviewConnection
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
                                    reviewID, host in
                                    await sceneModel
                                        .probeSSHHost(
                                            host,
                                            reviewID: reviewID
                                        )
                                },
                                pendingSSHHostKeyConfirmation: {
                                    reviewID, host in
                                    await sceneModel
                                        .pendingSSHHostKeyConfirmation(
                                            for: host,
                                            reviewID: reviewID
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
                                retainSSHAuthenticationForHandoff: {
                                    surfaceID in
                                    sceneModel
                                        .retainSSHAuthenticationForHandoff(
                                            surfaceID: surfaceID
                                        )
                                },
                                loadTailscalePeers: {
                                    await TailscaleDiscovery
                                        .discoverPeers()
                                        .peerLoadResult
                                },
                                exeAccountStatusesPublisher:
                                ExeVMInventoryStore.shared.$statuses
                                    .eraseToAnyPublisher(),
                                probeExeAccountConnection: { account in
                                    await sceneModel
                                        .probeExeAccountConnection(account)
                                },
                                refreshExeAccounts: { accounts, prefetchedVMs in
                                    ExeVMInventoryStore.shared.refresh(
                                        accounts: accounts,
                                        persistedAccounts:
                                        settingsStore.exeAccounts,
                                        prefetchedVMs: prefetchedVMs
                                    )
                                },
                                cancelExeAccountRefresh: { refreshID in
                                    ExeVMInventoryStore.shared.cancelRefresh(
                                        refreshID,
                                        retaining: settingsStore.exeAccounts
                                    )
                                },
                                invalidateExeAccountRefresh: {
                                    refreshID, accounts in
                                    ExeVMInventoryStore.shared
                                        .invalidateRefresh(
                                            refreshID,
                                            currentAccounts: accounts
                                        )
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
                },
                tmuxSessionPreviewBuilder: {
                    [sceneModel] selection, activate in
                    AnyView(TmuxSessionPreviewTile(
                        coordinator:
                        sceneModel.tmuxSessionPreviewCoordinator,
                        key: TmuxPreviewKey(
                            hostID: selection.hostID,
                            name: selection.name,
                            socketName: selection.socketName
                        ),
                        sessionName: selection.name,
                        onActivate: activate
                    ))
                },
                tmuxSessionPreviewParkingBuilder: {
                    [sceneModel, settingsStore] in
                    guard settingsStore.sessionPreviewMode != .off else {
                        return nil
                    }
                    return AnyView(TmuxSessionPreviewParkingView(
                        previewCoordinator:
                        sceneModel.tmuxSessionPreviewCoordinator
                    ))
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
                performApplicationShortcut: { [sceneModel] action in
                    _ = sceneModel.performApplicationShortcut(
                        action,
                        invocation: .menu
                    )
                },
                selectWorkspace: { [sceneModel] selection in
                    sceneModel.selectFromUser(selection)
                },
                openTmuxSession: { [sceneModel] selection in
                    sceneModel.openBorrowedTmuxSession(selection)
                },
                hideTmuxSession: { [sceneModel] selection in
                    sceneModel.hideBorrowedTmuxSession(selection)
                },
                openHerdrSession: { [sceneModel] selection in
                    try await sceneModel.openBorrowedHerdrSession(selection)
                },
                createHerdrSession: { [sceneModel] selection in
                    try await sceneModel.createHerdrSession(selection)
                },
                restartHerdrSession: { [sceneModel] selection in
                    try await sceneModel.restartHerdrSession(selection)
                },
                closeTmuxSession: { [sceneModel] selection in
                    sceneModel.closeBorrowedTmuxSession(selection)
                },
                closeHerdrSession: { [sceneModel] selection in
                    sceneModel.closeBorrowedHerdrSession(selection)
                },
                openZellijSession: { [sceneModel] selection in
                    sceneModel.openBorrowedZellijSession(selection)
                },
                createZellijSession: { [sceneModel] selection in
                    try await sceneModel.createZellijSession(selection)
                },
                closeZellijSession: { [sceneModel] selection in
                    sceneModel.closeBorrowedZellijSession(selection)
                },
                cancelPendingZellijPresentation: { [sceneModel] in
                    sceneModel.cancelPendingZellijPresentation()
                },
                prepareZellijSessionKill: { [sceneModel] selection in
                    try await sceneModel.prepareZellijSessionKill(selection)
                },
                killZellijSession: { [sceneModel] request in
                    try await sceneModel.killZellijSession(request)
                },
                cancelZellijSessionKill: { [sceneModel] request in
                    sceneModel.cancelPreparedZellijSessionKill(request)
                },
                prepareHerdrSessionLifecycle: {
                    [sceneModel] selection, action in
                    try await sceneModel.prepareHerdrSessionLifecycle(
                        selection,
                        action: action
                    )
                },
                performHerdrSessionLifecycle: { [sceneModel] request in
                    try await sceneModel.performHerdrSessionLifecycle(request)
                },
                cancelHerdrSessionLifecycle: { [sceneModel] request in
                    sceneModel.cancelPreparedHerdrSessionLifecycle(request)
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
                createTmuxSession: { [sceneModel] request in
                    sceneModel.createTmuxSession(request)
                },
                currentWorkspaceSnapshot: { [sceneModel] in
                    sceneModel.snapshot
                },
                refreshWorkspaceInventory: { [sceneModel] in
                    sceneModel.refreshWorkspaceInventory()
                },
                reconnectActiveTmuxSessionNow: { [sceneModel] in
                    sceneModel.reconnectActiveTmuxSessionNow()
                },
                reconnectActiveHerdrSessionNow: { [sceneModel] in
                    sceneModel.reconnectActiveHerdrSessionNow()
                },
                reconnectActiveZellijSessionNow: { [sceneModel] in
                    sceneModel.reconnectActiveZellijSessionNow()
                },
                resumeSessionReconnectAfterSSHRecovery: {
                    [sceneModel] request in
                    sceneModel.resumeSessionReconnectAfterSSHRecovery(
                        request
                    )
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
                completeSSHAuthentication: {
                    [sceneModel] hostID, startingNextOwner in
                    await sceneModel.completeSSHAuthentication(
                        surfaceID: hostID,
                        startingNextOwner: startingNextOwner
                    )
                },
                registerProject: { [sceneModel] host, path in
                    await sceneModel.registerProject(path, on: host)
                },
                prepareProjectRemoval: { [sceneModel] project, host in
                    try await sceneModel.prepareProjectRemoval(
                        project,
                        confirmedHost: host
                    )
                },
                unregisterProject: { [sceneModel] request in
                    await sceneModel.unregisterProject(request)
                },
                openProjectWorktreesAsTabs: {
                    [applicationDelegate, sceneModel] project, worktrees in
                    guard let host = sceneModel.snapshot.host(
                        id: project.hostID
                    ),
                        let states = ProjectWorktreeWindowPlan.states(
                            project: project,
                            host: host,
                            worktrees: worktrees
                        )
                    else {
                        sceneModel.refreshWorkspaceInventory()
                        return
                    }
                    applicationDelegate.requestWorkspaceTabGroup(
                        states,
                        launchIntent: .openWorktree
                    )
                },
                canOpenProjectWorktreesAsTabs: {
                    [sceneModel] project, worktrees in
                    guard let host = sceneModel.snapshot.host(
                        id: project.hostID
                    ) else { return false }
                    return ProjectWorktreeWindowPlan.isAvailable(
                        project: project,
                        host: host,
                        worktrees: worktrees
                    )
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
                    try await sceneModel.resolveWorktreeRemoval(request)
                },
                setTmuxSessionPreviewExpanded: {
                    [sceneModel] selection, expanded in
                    sceneModel.tmuxSessionPreviewCoordinator.setExpanded(
                        expanded,
                        for: TmuxPreviewKey(
                            hostID: selection.hostID,
                            name: selection.name,
                            socketName: selection.socketName
                        )
                    )
                },
                setTmuxSessionPreviewSidebarVisible: { [sceneModel] visible in
                    sceneModel.tmuxSessionPreviewCoordinator.setSidebarVisible(
                        visible
                    )
                }
            ),
            sidebarToggleTarget: sceneModel,
            sidebarWidthChanged: { width in
                titlebarSidebarWidth = width
            },
            workspaceWindowProvider: { [weak sceneModel] in
                sceneModel?.workspaceWindow
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
        .focusedSceneValue(
            \.availableSiblingShortcuts,
            sceneModel.availableSiblingShortcuts
        )
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
                    activeTmuxSession:
                    sceneModel.activeBorrowedTmuxSelection,
                    activeHerdrSession:
                    sceneModel.activeBorrowedHerdrSelection,
                    activeZellijSession:
                    sceneModel.activeBorrowedZellijSelection,
                    in: sceneModel.snapshot
                ),
                customTitle: customWindowTitle,
                onToggleSidebar: {
                    NotificationCenter.default.post(
                        name: .ghosthubToggleSidebar,
                        object: sceneModel
                    )
                },
                onQuickLaunch: {
                    NotificationCenter.default.post(
                        name: .ghosthubCommandPalette,
                        object: sceneModel
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
                },
                onRenameWindow: requestWindowTitleRename,
                onWindowChanged: { window in
                    sceneModel.workspaceWindow = window
                }
            )
        )
        .onReceive(NotificationCenter.default.publisher(
            for: .ghosthubRenameWorkspaceWindow
        )) { notification in
            guard let requestedWindow = notification.object as? NSWindow,
                  requestedWindow === sceneModel.workspaceWindow
            else { return }
            requestWindowTitleRename()
        }
        .sheet(item: $windowTitleRenameRequest) { request in
            RenameWorkspaceWindowSheet(
                initialTitle: request.currentTitle,
                automaticTitle: request.automaticTitle,
                onSave: { title in
                    customWindowTitle = WorkspaceWindowTitle.normalized(title)
                    windowTitleRenameRequest = nil
                    refreshWindowState()
                },
                onCancel: {
                    windowTitleRenameRequest = nil
                }
            )
        }
        #endif
        .sheet(isPresented: Binding(
            get: { sceneModel.presentationSSHSession != nil },
            set: { isPresented in
                if !isPresented {
                    sceneModel.cancelPresentationSSHAcquisition()
                }
            }
        )) {
            if let session = sceneModel.presentationSSHSession {
                KwtSSHAuthenticationView(
                    session: session,
                    onCancel: {
                        sceneModel.cancelPresentationSSHAcquisition()
                    }
                )
                .id(ObjectIdentifier(session))
            }
        }
        .onChange(of: sceneModel.restorationState(
            windowID: resolvedWindowState.wrappedValue.windowID
        )) { _, state in
            resolvedWindowState.wrappedValue = state.withCustomTitle(
                customWindowTitle
            )
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
                   ).withCustomTitle(customWindowTitle)
               ) {
                resolvedWindowState.wrappedValue = replacement
                return
            }
            if let restoredState = windowStateBuffer.receive(state) {
                beginRestoration(restoredState)
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
            beginRestoration(state)
        }
    }

    private func beginRestoration(_ state: WorkspaceWindowState) {
        customWindowTitle = WorkspaceWindowTitle.normalized(
            state.customTitle
        )
        sceneModel.beginRestoration(
            state,
            launchIntent: applicationDelegate
                .consumeWorkspaceWindowLaunchIntent(for: state.windowID)
        )
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
        beginRestoration(state)
        updateRelaunchRestorer.didBeginRestoring(
            windowID: state.windowID
        )
        refreshWindowState()
    }
    #endif

    private func captureWindowState() -> WorkspaceWindowState {
        let state = sceneModel.restorationState(
            windowID: resolvedWindowState.wrappedValue.windowID
        ).withCustomTitle(customWindowTitle)
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

    private var automaticWindowTitle: String {
        SessionTitlebarPresentation.resolve(
            activeTmuxSession: sceneModel.activeBorrowedTmuxSelection,
            activeHerdrSession: sceneModel.activeBorrowedHerdrSelection,
            activeZellijSession: sceneModel.activeBorrowedZellijSelection,
            in: sceneModel.snapshot
        )?.title ?? "Ghosthub"
    }

    private func requestWindowTitleRename() {
        guard let window = sceneModel.workspaceWindow,
              window.isKeyWindow,
              window.attachedSheet == nil
        else { return }
        windowTitleRenameRequest = WorkspaceWindowTitleRenameRequest(
            currentTitle: customWindowTitle ?? "",
            automaticTitle: automaticWindowTitle
        )
    }
}

private struct WorkspaceWindowTitleRenameRequest: Identifiable {
    let id = UUID()
    let currentTitle: String
    let automaticTitle: String
}

private struct RenameWorkspaceWindowSheet: View {
    let automaticTitle: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @FocusState private var titleIsFocused: Bool

    init(
        initialTitle: String,
        automaticTitle: String,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _title = State(initialValue: initialTitle)
        self.automaticTitle = automaticTitle
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename window")
                .font(.headline)
            TextField("Custom title", text: $title)
                .focused($titleIsFocused)
                .onSubmit { onSave(title) }
            Text("Leave blank to use “\(automaticTitle)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(title)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { titleIsFocused = true }
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
