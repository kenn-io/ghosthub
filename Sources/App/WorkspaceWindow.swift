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
        // An NSToolbar adds a second, 40-point-tall row on Tahoe even when its
        // controls use compact metrics. Keep controls in the standard
        // titlebar and give that single row an explicit uniform surface. A
        // transparent titlebar alone reveals whichever content happens to be
        // underneath it, so an active terminal would otherwise tint only the
        // detail side.
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
    @Binding var isFocused: Bool
    var isSidebarVisible: Bool
    var canCreateWorktree: Bool
    var sessionTitle: SessionTitlebarPresentation?
    var onToggleSidebar: () -> Void
    var onQuickLaunch: () -> Void
    var onSettings: () -> Void
    var onNewWorktree: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FocusTrackingView(
            applicationDelegate: applicationDelegate
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
        let titlebarController: CompactWorkspaceTitlebarController

        init(applicationDelegate: ApplicationDelegate) {
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
            window.tabbingMode = .disallowed
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
private final class DraggableTitlebarHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class WorkspaceWindowCloseController: NSObject {
    weak var applicationDelegate: ApplicationDelegate?
    weak var window: NSWindow?

    @objc func requestClose(_ sender: Any?) {
        applicationDelegate?.requestWorkspaceWindowClose(window)
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
    private let closeController = WorkspaceWindowCloseController()
    private weak var installedWindow: NSWindow?
    private var isSidebarVisible = true
    private var canCreateWorktree = false
    private var sessionTitle: SessionTitlebarPresentation?
    private var onToggleSidebar: () -> Void = {}
    private var onQuickLaunch: () -> Void = {}
    private var onSettings: () -> Void = {}
    private var onNewWorktree: () -> Void = {}

    init(applicationDelegate: ApplicationDelegate? = nil) {
        closeController.applicationDelegate = applicationDelegate
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

        guard let closeButton = window.standardWindowButton(.closeButton),
              let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebar = closeButton.superview
        else { return }
        if closeController.applicationDelegate != nil {
            closeController.window = window
            closeButton.target = closeController
            closeButton.action = #selector(
                WorkspaceWindowCloseController.requestClose(_:)
            )
        }
        guard installedWindow !== window
                || sidebarHost.superview !== titlebar
                || titleHost.superview !== titlebar
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
            titleHost.leadingAnchor.constraint(
                equalTo: sidebarHost.trailingAnchor,
                constant: 8
            ),
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

    func update(
        isSidebarVisible: Bool,
        canCreateWorktree: Bool,
        sessionTitle: SessionTitlebarPresentation?,
        onToggleSidebar: @escaping () -> Void,
        onQuickLaunch: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onNewWorktree: @escaping () -> Void
    ) {
        self.isSidebarVisible = isSidebarVisible
        self.canCreateWorktree = canCreateWorktree
        self.sessionTitle = sessionTitle
        self.onToggleSidebar = onToggleSidebar
        self.onQuickLaunch = onQuickLaunch
        self.onSettings = onSettings
        self.onNewWorktree = onNewWorktree
        refreshHosts()
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
        }
    }

    private func removeControlsFromInstalledWindow() {
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
    #endif
    @StateObject private var sceneModel = WorkspaceSceneModel()
    @EnvironmentObject private var terminalRuntime: LibghosttyRuntime
    @ObservedObject private var settingsStore = SettingsStore.shared
    @State private var visibleConfigReloadNotice:
        LibghosttyConfigReloadNotice?
    private let registry = WindowRegistry.shared

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
                activeTmuxSession:
                sceneModel.activeBorrowedTmuxSelection
            ),
            content: ContentBuilders(
                tmuxSessionContentBuilder: {
                    [sceneModel] host, sessionName in
                    sceneModel.borrowedTmuxSessionView(
                        host: host,
                        sessionName: sessionName
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
                                loadTailscalePeers: {
                                    await TailscaleDiscovery
                                        .discoverPeers()
                                        .peerLoadResult
                                },
                                reloadTerminalConfig: {
                                    terminalRuntime.reloadActiveConfig()
                                }
                            )
                        )
                    )
                },
                logViewerBuilder: { [sceneModel] in
                    sceneModel.logViewerTerminalView()
                }
            ),
            handlers: InteractionHandlers(
                closeWindow: { [applicationDelegate] in
                    applicationDelegate.requestWorkspaceWindowClose(
                        NSApplication.shared.keyWindow
                    )
                },
                dismissLogViewer: { [sceneModel] in
                    sceneModel.dismissLogViewer()
                },
                reloadTerminalConfig: {
                    terminalRuntime.reloadActiveConfig()
                },
                openTmuxSession: { [sceneModel] selection in
                    sceneModel.openBorrowedTmuxSession(selection)
                },
                closeTmuxSession: { [sceneModel] selection in
                    sceneModel.closeBorrowedTmuxSession(selection)
                },
                createTmuxSession: { [sceneModel] selection in
                    sceneModel.createTmuxSession(selection)
                },
                refreshWorkspaceInventory: { [sceneModel] in
                    sceneModel.refreshKwtInventory()
                },
                createWorktree: { [sceneModel] request in
                    try await sceneModel.createWorktree(request)
                }
            ),
            settingsStore: settingsStore,
            selection: $sceneModel.selection,
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
                    isFocused: Binding(
                        get: { sceneModel.isFocusedWindow },
                        set: { sceneModel.isFocusedWindow = $0 }
                    ),
                    isSidebarVisible:
                    sceneModel.columnVisibility != .detailOnly,
                    canCreateWorktree: canCreateWorktree,
                    sessionTitle: SessionTitlebarPresentation.resolve(
                        activeSession: sceneModel.activeBorrowedTmuxSelection,
                        in: sceneModel.snapshot
                    ),
                    onToggleSidebar: {
                        NotificationCenter.default.post(
                            name: .ghosthubToggleSidebar,
                            object: nil
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
            .onAppear {
                registry.register(sceneModel)
            }
            .onReceive(
                terminalRuntime.$configReloadNotice
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
                registry.unregister(sceneModel)
                Task { [sceneModel] in
                    await sceneModel.shutdown()
                }
            }
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
