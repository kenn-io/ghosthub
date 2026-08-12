import AppKit
import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubUI

/// Activation work gate: bounds the render work a key-window switch may
/// trigger, so regressions that route focus changes through broad view
/// invalidation (the 0.8.0 window-switch lag class) fail CI immediately.
///
/// The harness hosts two real `RootView` windows and flips the
/// `controlActiveState` environment between them, which is the mechanism
/// AppKit uses to deliver key-window changes to SwiftUI content. Driving it
/// directly keeps the gate deterministic on headless CI runners, where real
/// key-window transitions are not reliable. App-scene invalidation (e.g.
/// focused-value reads on the `App` itself) happens above any hostable
/// view, so it stays outside this gate's reach.
@MainActor
struct ActivationWorkGateTests {
    /// Budgets are a ratchet at 2x the measured baseline: 10 switches cost
    /// 20 root body evaluations (one per window per switch) and 40 sidebar
    /// section computations (two call sites per root evaluation until the
    /// sections result is memoized; kata 4rqt). Lower the budgets when
    /// render work shrinks; never raise them without profiling why the
    /// work grew.
    private enum Budget {
        static let switches = 10
        static let rootBodyEvaluations = 40
        static let sidebarSectionComputations = 80
    }

    @Test("key-window switching stays within the render work budget")
    func keyWindowSwitchingStaysWithinRenderWorkBudget() {
        let gate = GateEnvironment()
        defer { gate.close() }

        RenderWorkCounters.reset()
        for index in 0 ..< Budget.switches {
            gate.activateWindow(index.isMultiple(of: 2) ? 1 : 0)
        }

        #expect(
            RenderWorkCounters.rootBodyEvaluations
                <= Budget.rootBodyEvaluations
        )
        #expect(
            RenderWorkCounters.sidebarSectionComputations
                <= Budget.sidebarSectionComputations
        )
    }

    @Test("gate counters register render work")
    func gateCountersRegisterRenderWork() {
        let gate = GateEnvironment()
        defer { gate.close() }

        RenderWorkCounters.reset()
        gate.activateWindow(1)

        #expect(RenderWorkCounters.rootBodyEvaluations > 0)

        RenderWorkCounters.reset()
        _ = WorkspaceSidebarModel.sections(in: gate.snapshot)
        #expect(RenderWorkCounters.sidebarSectionComputations == 1)
    }
}

// MARK: - Harness

@MainActor
private final class GateEnvironment {
    let snapshot: WorkspaceSnapshot

    private let windowModels: [GateWindowModel]
    private let windows: [NSWindow]
    private let hostingViews: [NSHostingView<GateHarness>]
    private let settingsStore: SettingsStore
    private let tempRoot: URL
    private let defaults: UserDefaults
    private let defaultsSuiteName: String
    private let sidebarToggleTarget = NSObject()

    init() {
        let sessionNames = ["alpha", "beta", "gamma", "delta"]
        let environment = makeWorkspaceEnvironment(
            hostConfig: { host in
                host.tmuxSessions = sessionNames.map {
                    TmuxSessionSummary(
                        name: $0,
                        managed: false,
                        windows: []
                    )
                }
            },
            worktrees: [
                { $0.name = "main"
                    $0.branch = "main" },
                { $0.name = "feature-a"
                    $0.branch = "feature-a" },
                { $0.name = "feature-b"
                    $0.branch = "feature-b" },
            ]
        )
        snapshot = environment.snapshot

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        defaultsSuiteName = "ActivationWorkGate-\(UUID().uuidString)"
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

        var models: [GateWindowModel] = []
        var hostingViews: [NSHostingView<GateHarness>] = []
        var windows: [NSWindow] = []
        for index in 0 ..< 2 {
            let model = GateWindowModel(
                snapshot: environment.snapshot,
                selection: environment.selection,
                activeSession: WorkspaceTmuxSessionSelection(
                    hostID: environment.host.id,
                    name: sessionNames[index]
                ),
                isActive: index == 0
            )
            let hostingView = NSHostingView(
                rootView: GateHarness(
                    model: model,
                    settingsStore: settingsStore,
                    defaults: defaults,
                    sidebarToggleTarget: sidebarToggleTarget
                )
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.orderFront(nil)
            models.append(model)
            hostingViews.append(hostingView)
            windows.append(window)
        }
        windowModels = models
        self.hostingViews = hostingViews
        self.windows = windows
        settle()
    }

    func activateWindow(_ index: Int) {
        for (modelIndex, model) in windowModels.enumerated() {
            model.isActive = modelIndex == index
        }
        settle()
    }

    func close() {
        for window in windows {
            window.orderOut(nil)
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func settle(for duration: TimeInterval = 0.05) {
        for hostingView in hostingViews {
            hostingView.layoutSubtreeIfNeeded()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
        for hostingView in hostingViews {
            hostingView.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
private final class GateWindowModel: ObservableObject {
    let snapshot: WorkspaceSnapshot
    @Published var selection: WorkspaceSelection
    @Published var activeSession: WorkspaceTmuxSessionSelection?
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var isCommandPalettePresented = false
    @Published var isActive: Bool

    init(
        snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection,
        activeSession: WorkspaceTmuxSessionSelection,
        isActive: Bool
    ) {
        self.snapshot = snapshot
        self.selection = selection
        self.activeSession = activeSession
        self.isActive = isActive
    }
}

private struct GateHarness: View {
    @ObservedObject var model: GateWindowModel
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
                tmuxSessionContentBuilder: { _, _, _, _ in
                    AnyView(Color.clear)
                }
            ),
            sidebarToggleTarget: sidebarToggleTarget,
            settingsStore: settingsStore,
            selection: $model.selection,
            columnVisibility: $model.columnVisibility,
            isCommandPalettePresented: $model.isCommandPalettePresented
        )
        .defaultAppStorage(defaults)
        .environment(
            \.controlActiveState,
            model.isActive ? .key : .inactive
        )
    }
}
