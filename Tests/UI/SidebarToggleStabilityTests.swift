import AppKit
import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubUI

/// Verifies that sidebar session switching stays synchronized and that
/// toggling workspace panels preserves terminal content identity.
@MainActor
struct SidebarToggleStabilityTests {
    @Test("sidebar-mounted tmux switching keeps presentation synchronized")
    func sidebarMountedTmuxSwitchingKeepsPresentationSynchronized() {
        let env = StabilityTestEnvironment()
        defer { env.close() }

        #expect(env.columnVisibility == .all)

        for index in 0 ..< 12 {
            let session = index.isMultiple(of: 2)
                ? env.firstSession : env.secondSession
            env.switchToSession(session)

            #expect(env.activeSession == session)
            #expect(env.selectedHostID == session.hostID)
            #expect(env.selectedProjectID == nil)
            #expect(env.selectedWorktreeID == nil)
            #expect(env.columnVisibility == .all)
            #expect(env.isPresentingSession(named: session.name))
        }
    }

    @Test("left sidebar toggle preserves terminal content view identity")
    func leftSidebarTogglePreservesTerminalContent() {
        let env = StabilityTestEnvironment()
        defer { env.close() }

        let viewBefore = env.findStableContent()
        #expect(viewBefore != nil, "stable content should exist initially")

        env.isSidebarVisible = false
        env.settle()

        let viewAfter = env.findStableContent()
        #expect(viewAfter != nil, "stable content should exist after hiding sidebar")
        #expect(
            viewBefore === viewAfter,
            "terminal content view must be the same instance after sidebar toggle"
        )

        env.isSidebarVisible = true
        env.settle()

        let viewRestored = env.findStableContent()
        #expect(viewRestored != nil, "stable content should exist after restoring sidebar")
        #expect(
            viewBefore === viewRestored,
            "terminal content view must be the same instance after sidebar restore"
        )
    }

    @Test("sidebar command toggles only its targeted window")
    func sidebarCommandTogglesOnlyTargetedWindow() {
        let firstTarget = SidebarToggleTarget()
        let secondTarget = SidebarToggleTarget()
        let first = StabilityTestEnvironment(
            sidebarToggleTarget: firstTarget
        )
        let second = StabilityTestEnvironment(
            sidebarToggleTarget: secondTarget
        )
        defer {
            first.close()
            second.close()
        }

        #expect(first.columnVisibility == .all)
        #expect(second.columnVisibility == .all)

        NotificationCenter.default.post(
            name: .ghosthubToggleSidebar,
            object: firstTarget
        )
        first.settle()
        second.settle()

        #expect(first.columnVisibility == .detailOnly)
        #expect(second.columnVisibility == .all)
    }

    @Test("right side panel toggle preserves main column view identity")
    func rightSidePanelTogglePreservesMainColumn() {
        let env = SidePanelStabilityTestEnvironment()

        let viewBefore = env.findStableContent()
        #expect(viewBefore != nil, "stable content should exist initially")

        env.isSidePanelVisible = true
        env.settle()

        let viewAfter = env.findStableContent()
        #expect(viewAfter != nil, "stable content should exist after showing side panel")
        #expect(
            viewBefore === viewAfter,
            "main column view must be the same instance after side panel toggle"
        )

        env.isSidePanelVisible = false
        env.settle()

        let viewRestored = env.findStableContent()
        #expect(viewRestored != nil, "stable content should exist after hiding side panel")
        #expect(
            viewBefore === viewRestored,
            "main column view must be the same instance after side panel hide"
        )
    }
}

// MARK: - Test Helpers

private final class SidebarToggleTarget {}

@MainActor
private final class StabilityTestEnvironment {
    let firstSession: WorkspaceTmuxSessionSelection
    let secondSession: WorkspaceTmuxSessionSelection

    private let model: StabilityTestModel
    private let window: NSWindow
    private let hostingView: NSHostingView<StabilityTestHarness>
    private let settingsStore: SettingsStore
    private let tempRoot: URL
    private let defaults: UserDefaults
    private let defaultsSuiteName: String
    private let sidebarToggleTarget: AnyObject

    var isSidebarVisible: Bool {
        get { model.columnVisibility != .detailOnly }
        set {
            model.columnVisibility = newValue ? .all : .detailOnly
        }
    }

    var activeSession: WorkspaceTmuxSessionSelection? {
        model.activeSession
    }

    var selectedHostID: UUID {
        model.selection.selectedHostID
    }

    var selectedProjectID: UUID? {
        model.selection.selectedProjectID
    }

    var selectedWorktreeID: UUID? {
        model.selection.selectedWorktreeID
    }

    var columnVisibility: NavigationSplitViewVisibility {
        model.columnVisibility
    }

    init(sidebarToggleTarget: AnyObject = SidebarToggleTarget()) {
        self.sidebarToggleTarget = sidebarToggleTarget
        let hostID = UUID()
        firstSession = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "alpha"
        )
        secondSession = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "beta"
        )
        let host = HostSummary(
            id: hostID,
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            tmuxSessions: [
                TmuxSessionSummary(
                    name: firstSession.name,
                    managed: false,
                    windows: []
                ),
                TmuxSessionSummary(
                    name: secondSession.name,
                    managed: false,
                    windows: []
                ),
            ]
        )
        model = StabilityTestModel(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            selection: WorkspaceSelection(selectedHostID: hostID),
            activeSession: firstSession
        )

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        defaultsSuiteName = "SidebarStability-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        settingsStore = SettingsStore(
            configPipeline: LibghosttyConfigPipeline(
                paths: LibghosttyConfigPaths(
                    configDirectory: tempRoot.appendingPathComponent(
                        ".config",
                        isDirectory: true
                    )
                )
            ),
            userDefaults: defaults
        )
        hostingView = NSHostingView(
            rootView: StabilityTestHarness(
                model: model,
                settingsStore: settingsStore,
                defaults: defaults,
                sidebarToggleTarget: sidebarToggleTarget
            )
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    func switchToSession(_ session: WorkspaceTmuxSessionSelection) {
        model.selection = RootView.selectionForHostTmuxSession(
            session,
            from: model.selection,
            in: model.snapshot,
            visibility: .default
        )
        model.activeSession = session
        settle()
    }

    func isPresentingSession(named name: String) -> Bool {
        viewByAccessibilityID(
            "presented-tmux-\(name)",
            in: hostingView
        ) != nil
    }

    func findStableContent() -> NSView? {
        guard let sessionName = activeSession?.name else { return nil }
        return viewByAccessibilityID(
            "presented-tmux-\(sessionName)",
            in: hostingView
        )
    }

    func close() {
        window.orderOut(nil)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func settle() {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
private final class StabilityTestModel: ObservableObject {
    let snapshot: WorkspaceSnapshot
    @Published var selection: WorkspaceSelection
    @Published var activeSession: WorkspaceTmuxSessionSelection?
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    init(
        snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection,
        activeSession: WorkspaceTmuxSessionSelection
    ) {
        self.snapshot = snapshot
        self.selection = selection
        self.activeSession = activeSession
    }
}

private struct StabilityTestHarness: View {
    @ObservedObject var model: StabilityTestModel
    let settingsStore: SettingsStore
    let defaults: UserDefaults
    let sidebarToggleTarget: AnyObject

    var body: some View {
        RootView(
            display: WorkspaceDisplayState(
                snapshot: model.snapshot,
                activeTmuxSession: model.activeSession
            ),
            content: ContentBuilders(
                tmuxSessionContentBuilder: { _, sessionName in
                    AnyView(
                        PresentedTmuxSessionMarker(sessionName: sessionName)
                    )
                }
            ),
            sidebarToggleTarget: sidebarToggleTarget,
            settingsStore: settingsStore,
            selection: $model.selection,
            columnVisibility: $model.columnVisibility
        )
        .defaultAppStorage(defaults)
        .environment(\.controlActiveState, .key)
    }
}

private struct PresentedTmuxSessionMarker: NSViewRepresentable {
    let sessionName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier("presented-tmux-\(sessionName)")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.setAccessibilityIdentifier("presented-tmux-\(sessionName)")
    }
}

/// Exercises the former right-side-panel stability pattern.
@MainActor
private final class SidePanelStabilityTestEnvironment {
    var isSidePanelVisible = false {
        didSet { updateView() }
    }
    private let window: NSWindow
    private let hostingView: NSHostingView<AnyView>
    private let stableID = "stability-test-main-column"

    init() {
        let view = AnyView(
            SidePanelStableContentTestView(
                isSidePanelVisible: false,
                stableID: stableID
            )
        )
        hostingView = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    func settle() {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func findStableContent() -> NSView? {
        findView(id: stableID, in: window.contentView!)
    }

    private func updateView() {
        hostingView.rootView = AnyView(
            SidePanelStableContentTestView(
                isSidePanelVisible: isSidePanelVisible,
                stableID: stableID
            )
        )
        settle()
    }

    private func findView(id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id {
            return view
        }
        for subview in view.subviews {
            if let found = findView(id: id, in: subview) {
                return found
            }
        }
        return nil
    }
}

/// Mimics the right side panel pattern. The main column
/// is always inside the HStack; only the side panel
/// conditionally appears.
private struct SidePanelStableContentTestView: View {
    let isSidePanelVisible: Bool
    let stableID: String

    var body: some View {
        HStack(spacing: 0) {
            StableContentView(stableID: stableID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isSidePanelVisible {
                Color.blue
                    .frame(width: 320)
            }
        }
    }
}

/// A view that embeds a persistent NSView via
/// NSViewRepresentable, simulating a terminal surface.
/// If SwiftUI destroys and recreates this, the underlying
/// NSView instance changes.
private struct StableContentView: NSViewRepresentable {
    let stableID: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier(stableID)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
