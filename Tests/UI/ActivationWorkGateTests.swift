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
@Suite(.serialized)
@MainActor
struct ActivationWorkGateTests {
    @Test("activation preference refresh does not redraw unchanged windows", arguments: [100, 500])
    func activationPreferenceRefreshDoesNotRedrawWindows(sessionCount: Int) {
        let gate = GateEnvironment(sessionCount: sessionCount)
        defer { gate.close() }

        RenderWorkCounters.beginRecording()
        for _ in 0 ..< Budget.switches {
            // Telemetry reloads this shared preference on application activation.
            gate.settingsStore.refreshShareAnonymousUsageData()
            gate.settle()
        }
        let counts = RenderWorkCounters.endRecording()
        #expect(counts.rootBodyEvaluations == 0)
        #expect(counts.sidebarSectionComputations == 0)
    }

    @Test("collapsing a sidebar group affects only its window")
    func sidebarDisclosureIsWindowLocal() throws {
        let app = NSApplication.shared
        let wasEnhanced = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(wasEnhanced, forKey: "accessibilityEnhancedUserInterface") }
        let gate = GateEnvironment()
        defer { gate.close() }
        let identifier = "sidebar-section-disclosure-sessions:\(gate.snapshot.hosts[0].id.uuidString)"
        /// SwiftUI nodes expose these accessors without adopting the full
        /// NSAccessibilityProtocol, so traverse them through Cocoa's KVC API.
        func disclosure(in element: NSObject) -> NSObject? {
            let id = element.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                ? element.value(forKey: "accessibilityIdentifier") as? String : nil
            if id == identifier {
                return element
            }
            let children = element.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? element.value(forKey: "accessibilityChildren") as? [NSObject] : nil
            for child in children ?? [] {
                if let match = disclosure(in: child) {
                    return match
                }
            }
            return nil
        }
        let first = try #require(disclosure(in: gate.hostingViews[0]))
        let second = try #require(disclosure(in: gate.hostingViews[1]))
        #expect(first.value(forKey: "accessibilityValue") as? String == "Expanded")
        #expect(second.value(forKey: "accessibilityValue") as? String == "Expanded")

        _ = first.perform(NSSelectorFromString("accessibilityPerformPress"))
        gate.activateWindow(1)

        #expect(first.value(forKey: "accessibilityValue") as? String == "Collapsed")
        #expect(second.value(forKey: "accessibilityValue") as? String == "Expanded")
    }

    @Test("session selection builds sibling drag items once per group", arguments: [100, 500])
    func sidebarSelectionWork(sessionCount: Int) {
        let gate = GateEnvironment(sessionCount: sessionCount)
        defer { gate.close() }
        var samples: [Double] = []
        RenderWorkCounters.beginRecording()
        for index in 0 ..< 10 {
            let start = ProcessInfo.processInfo.systemUptime
            gate.selectSession(index + 2)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let counts = RenderWorkCounters.endRecording()
        samples.sort()
        print(
            "SIDEBAR rows=\(sessionCount) selection_ms p50=\(samples[4]) p95=\(samples[9]) rows_built=\(counts.sidebarRowEvaluations) drag_items=\(counts.sidebarDragItems)"
        )
        #expect(counts.sidebarRowEvaluations > 0)
        #expect(counts.sidebarSectionComputations == 0)
        #expect(counts.sidebarDragItems <= counts.sidebarRowEvaluations * 2)
    }

    /// Budgets are a ratchet at the measured baseline plus 30%: 10 switches
    /// cost exactly 20 root body evaluations (one per window per switch)
    /// and no sidebar section recomputation. The headroom absorbs a stray
    /// framework re-evaluation, while any new per-switch invalidation source
    /// adds at least one root evaluation per switch (+10 here) and trips the
    /// gate. The section budget has no headroom because activation changes
    /// none of its inputs. Lower the budgets when render work shrinks; never
    /// raise them without profiling why the work grew.
    private enum Budget {
        static let switches = 10
        static let rootBodyEvaluations = 26
        static let sidebarSectionComputations = 0
    }

    @Test("key-window switching stays within the render work budget", arguments: [100, 500])
    func keyWindowSwitchingStaysWithinRenderWorkBudget(sessionCount: Int) {
        let gate = GateEnvironment(sessionCount: sessionCount)
        defer { gate.close() }

        RenderWorkCounters.beginRecording()
        for index in 0 ..< Budget.switches {
            gate.activateWindow(index.isMultiple(of: 2) ? 1 : 0)
        }
        let counts = RenderWorkCounters.endRecording()

        #expect(
            counts.rootBodyEvaluations <= Budget.rootBodyEvaluations
        )
        #expect(
            counts.sidebarSectionComputations
                <= Budget.sidebarSectionComputations
        )
    }

    @Test("gate counters register render work")
    func gateCountersRegisterRenderWork() {
        let gate = GateEnvironment()
        defer { gate.close() }

        RenderWorkCounters.beginRecording()
        gate.activateWindow(1)
        #expect(RenderWorkCounters.endRecording().rootBodyEvaluations > 0)

        RenderWorkCounters.beginRecording()
        _ = WorkspaceSidebarModel.sections(in: gate.snapshot)
        #expect(
            RenderWorkCounters.endRecording().sidebarSectionComputations == 1
        )
    }
}

// MARK: - Harness

@MainActor
private final class GateEnvironment {
    let snapshot: WorkspaceSnapshot

    private let windowModels: [GateWindowModel]
    private let windows: [NSWindow]
    let hostingViews: [NSHostingView<GateHarness>]
    let settingsStore: SettingsStore
    private let tempRoot: URL
    private let defaults: UserDefaults
    private let defaultsSuiteName: String
    private let sidebarToggleTarget = NSObject()

    init(sessionCount: Int = 4) {
        let sessionNames = (0 ..< sessionCount).map { "session-\($0)" }
        let environment = makeWorkspaceEnvironment(
            hostConfig: { host in
                host.tmuxSessions = sessionNames.enumerated().map { index, name in
                    TmuxSessionSummary(
                        name: name,
                        managed: false,
                        windows: [],
                        serverPID: "101",
                        sessionID: "$\(index)",
                        createdAt: "1000"
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

    func selectSession(_ index: Int) {
        let model = windowModels[0]
        let session = WorkspaceTmuxSessionSelection(
            hostID: snapshot.hosts[0].id,
            name: "session-\(index)"
        )
        model.selection.select(
            .tmuxSession(hostID: session.hostID, name: session.name),
            in: snapshot
        )
        model.activeSession = session
        settle(for: 0.001)
    }

    func close() {
        for window in windows {
            window.orderOut(nil)
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func settle(for duration: TimeInterval = 0.05) {
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
    let sidebarSectionCache = WorkspaceSidebarSectionCache()
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
                sidebarSectionCache: model.sidebarSectionCache,
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
