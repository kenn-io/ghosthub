#if canImport(AppKit)
import AppKit
import GhosthubTerminal
import GhosthubWorkspace

@MainActor
private func presentApplicationAlertAsync(
    _ alert: NSAlert,
    completion: @escaping (NSApplication.ModalResponse) -> Void
) {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        DispatchQueue.main.async {
            completion(alert.runModal())
        }
        return
    }

    alert.beginSheetModal(for: window, completionHandler: completion)
}

@MainActor
enum WorkspaceWindowIdentity {
    static let tabbingIdentifier = "workspace"

    static func matches(_ window: NSWindow) -> Bool {
        window.tabbingIdentifier == tabbingIdentifier
    }

    static func count(in windows: [NSWindow]) -> Int {
        windows.count(where: matches)
    }

    static func group(containing window: NSWindow) -> [NSWindow] {
        window.tabGroup?.windows ?? [window]
    }
}

enum WorkspaceWindowResolver {
    static func workspaceWindow<Window: AnyObject>(
        from candidate: Window?,
        sheetParent: (Window) -> Window?,
        isWorkspace: (Window) -> Bool
    ) -> Window? {
        guard var window = candidate else { return nil }
        while let parent = sheetParent(window) {
            window = parent
        }
        return isWorkspace(window) ? window : nil
    }
}

final class WorkspaceWindowRequests<Window: AnyObject> {
    private final class Request {
        weak var parent: Window?
        let remainingStates: [WorkspaceWindowState]

        init(
            parent: Window?,
            remainingStates: [WorkspaceWindowState]
        ) {
            self.parent = parent
            self.remainingStates = remainingStates
        }
    }

    private var requests: [UUID: Request] = [:]

    func add(
        _ id: UUID,
        parent: Window?,
        remainingStates: [WorkspaceWindowState] = []
    ) {
        requests[id] = Request(
            parent: parent,
            remainingStates: remainingStates
        )
    }

    func consume(
        for id: UUID?,
        window: Window
    ) -> (
        parent: Window?,
        remainingStates: [WorkspaceWindowState]
    )? {
        guard let id,
              let request = requests.removeValue(forKey: id)
        else { return nil }
        return (
            request.parent === window ? nil : request.parent,
            request.remainingStates
        )
    }
}

final class WorkspaceWindowLaunchIntents {
    private var intents: [UUID: WorkspaceWindowLaunchIntent] = [:]

    func add(
        _ intent: WorkspaceWindowLaunchIntent,
        for windowIDs: [UUID]
    ) {
        for windowID in windowIDs {
            intents[windowID] = intent
        }
    }

    func consume(for windowID: UUID) -> WorkspaceWindowLaunchIntent? {
        intents.removeValue(forKey: windowID)
    }
}

@MainActor
final class ApplicationDelegate: NSObject,
    NSApplicationDelegate {
    let sshAuthenticationCoordinator = SSHAuthenticationCoordinator()

    var requestTerminationConfirmation: (
        (@escaping (Bool) -> Void) -> Void
    )?

    var needsConfirmQuit: () -> Bool = { true }

    var terminateApplication: () -> Void = {
        NSApplication.shared.terminate(nil)
    }

    var replyToApplicationShouldTerminate: (Bool) -> Void = { confirmed in
        NSApplication.shared.reply(
            toApplicationShouldTerminate: confirmed
        )
    }

    var openWorkspaceWindow: (WorkspaceWindowState) -> Void = { _ in }

    private let windowRequests = WorkspaceWindowRequests<NSWindow>()
    private let windowLaunchIntents = WorkspaceWindowLaunchIntents()
    private var windowRestorationFinishedHandler: (Int) -> Void = { _ in }
    private var restoredWorkspaceWindowCount: Int?
    private(set) var terminationConfirmed = false
    private(set) var terminationConfirmationPending = false
    private var pendingTerminationDecisions: [(Bool) -> Void] = []
    private var applicationTerminationRequestPending = false
    private var updaterTerminationAuthorized = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidFinishRestoringWindows(_:)),
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: nil
        )
    }

    func setWindowRestorationFinishedHandler(
        _ handler: @escaping (Int) -> Void
    ) {
        windowRestorationFinishedHandler = handler
        if let restoredWorkspaceWindowCount {
            handler(restoredWorkspaceWindowCount)
        }
    }

    @objc func applicationDidFinishRestoringWindows(
        _ notification: Notification
    ) {
        guard restoredWorkspaceWindowCount == nil else { return }
        let count = WorkspaceWindowIdentity.count(
            in: NSApplication.shared.windows
        )
        restoredWorkspaceWindowCount = count
        windowRestorationFinishedHandler(count)
    }

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        if Bundle.main.bundleURL.pathExtension == "app" {
            SSHConnectionPool.removeStaleControlSockets()
        }
        // Cmd-N must stay an independent window even when the user's system
        // preference normally groups newly opened windows into tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        DispatchQueue.main.async {
            NativeTabCommands.installBracketShortcuts()
        }
    }

    func applicationDidBecomeActive(
        _ notification: Notification
    ) {
        TelemetryController.shared.applicationDidBecomeActive()
        NativeTabCommands.installBracketShortcuts()
    }

    func applicationWillResignActive(
        _ notification: Notification
    ) {
        TelemetryController.shared.applicationWillResignActive()
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {
        sshAuthenticationCoordinator.shutdown()
    }

    @objc func newWindowForTab(_ sender: Any?) {
        requestNewWorkspaceTab()
    }

    func requestNewWorkspaceWindow() {
        openWorkspaceWindow(requestWorkspaceWindow(parent: nil))
    }

    func requestNewWorkspaceTab() {
        requestNewWorkspaceTab(from: NSApplication.shared.keyWindow)
    }

    func requestNewWorkspaceTab(from candidate: NSWindow?) {
        let parent = WorkspaceWindowResolver.workspaceWindow(
            from: candidate,
            sheetParent: \.sheetParent,
            isWorkspace: WorkspaceWindowIdentity.matches
        )
        openWorkspaceWindow(requestWorkspaceWindow(parent: parent))
    }

    func requestWorkspaceTabGroup(
        _ states: [WorkspaceWindowState],
        launchIntent: WorkspaceWindowLaunchIntent
    ) {
        guard let first = states.first else { return }
        windowLaunchIntents.add(
            launchIntent,
            for: states.map(\.windowID)
        )
        windowRequests.add(
            first.windowID,
            parent: nil,
            remainingStates: Array(states.dropFirst())
        )
        openWorkspaceWindow(first)
    }

    func consumeWorkspaceWindowLaunchIntent(
        for windowID: UUID
    ) -> WorkspaceWindowLaunchIntent? {
        windowLaunchIntents.consume(for: windowID)
    }

    func adoptWorkspaceWindowAsTabIfRequested(
        _ window: NSWindow,
        requestID: UUID?
    ) {
        guard WorkspaceWindowIdentity.matches(window),
              let request = windowRequests.consume(
                  for: requestID,
                  window: window
              )
        else { return }
        let groupWindow: NSWindow
        let adoptedParent: NSWindow?
        let preservedFrame: NSRect?
        if let parent = request.parent {
            guard !WorkspaceWindowIdentity.group(containing: parent)
                .contains(where: { $0 === window })
            else { return }
            let parentFrame = parent.frame
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            NativeTabCommands.installBracketShortcuts()
            window.setFrame(parentFrame, display: true)
            groupWindow = parent
            adoptedParent = parent
            preservedFrame = parentFrame
        } else {
            groupWindow = window
            adoptedParent = nil
            preservedFrame = nil
        }
        DispatchQueue.main.async {
            [weak self, weak groupWindow, weak window, weak adoptedParent] in
            guard let self,
                  let groupWindow,
                  let window
            else { return }
            if let adoptedParent {
                guard let group = adoptedParent.tabGroup,
                      group === window.tabGroup
                else { return }
                if let preservedFrame {
                    window.setFrame(preservedFrame, display: true)
                }
            }
            openNextWorkspaceTab(
                request.remainingStates,
                parent: groupWindow
            )
        }
    }

    private func openNextWorkspaceTab(
        _ states: [WorkspaceWindowState],
        parent: NSWindow
    ) {
        guard let next = states.first else { return }
        windowRequests.add(
            next.windowID,
            parent: parent,
            remainingStates: Array(states.dropFirst())
        )
        openWorkspaceWindow(next)
    }

    private func requestWorkspaceWindow(
        parent: NSWindow?
    ) -> WorkspaceWindowState {
        let state = WorkspaceWindowState.fresh()
        windowRequests.add(state.windowID, parent: parent)
        return state
    }

    func requestUserInitiatedTermination(
        forceConfirmation: Bool = false,
        onConfirm: @escaping () -> Void
    ) {
        requestTerminationDecision(
            forceConfirmation: forceConfirmation
        ) { confirmed in
            guard confirmed else { return }
            onConfirm()
        }
    }

    private func requestTerminationDecision(
        forceConfirmation: Bool = false,
        onDecision: @escaping (Bool) -> Void
    ) {
        if terminationConfirmed {
            AppLogger.shared.info(
                "quit: already confirmed, terminating"
            )
            onDecision(true)
            return
        }

        if terminationConfirmationPending {
            AppLogger.shared.info(
                "quit: joining pending confirmation"
            )
            pendingTerminationDecisions.append(onDecision)
            return
        }

        let surfaceCount = WindowRegistry.shared
            .totalOpenTerminalSurfaceCount
        let needs = needsConfirmQuit()
        AppLogger.shared.info(
            "quit: needsConfirmQuit=\(needs)"
                + " surfaces=\(surfaceCount)"
                + " force=\(forceConfirmation)"
        )

        guard forceConfirmation || needs else {
            terminationConfirmed = true
            onDecision(true)
            return
        }
        terminationConfirmationPending = true
        pendingTerminationDecisions = [onDecision]

        let finish: (Bool) -> Void = { [weak self] confirmed in
            guard let self else { return }
            terminationConfirmationPending = false
            let decisions = pendingTerminationDecisions
            pendingTerminationDecisions.removeAll()
            if confirmed {
                terminationConfirmed = true
            }
            decisions.forEach { $0(confirmed) }
        }

        if let requestTerminationConfirmation {
            requestTerminationConfirmation(finish)
            return
        }

        presentApplicationAlertAsync(makeTerminationAlert()) { response in
            finish(response == .alertFirstButtonReturn)
        }
    }

    func requestApplicationTermination() {
        guard !applicationTerminationRequestPending else {
            AppLogger.shared.info(
                "quit: application termination already requested"
            )
            return
        }
        applicationTerminationRequestPending = true
        requestTerminationDecision { [weak self] confirmed in
            guard let self else { return }
            applicationTerminationRequestPending = false
            if confirmed {
                terminateApplication()
            }
        }
    }

    func bindQuitRequests(from source: ApplicationQuitRequestSource) {
        source.quitRequestHandler = { [weak self] in
            self?.requestApplicationTermination()
        }
    }

    func authorizeNextUpdaterTermination() {
        updaterTerminationAuthorized = true
    }

    func clearUpdaterTerminationAuthorization() {
        updaterTerminationAuthorized = false
    }

    private func consumeUpdaterTerminationAuthorization() -> Bool {
        guard updaterTerminationAuthorized else { return false }
        updaterTerminationAuthorized = false
        return true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if consumeUpdaterTerminationAuthorization() {
            return .terminateNow
        }
        if terminationConfirmed {
            return .terminateNow
        }
        guard needsConfirmQuit() else {
            terminationConfirmed = true
            return .terminateNow
        }
        // Shutdown, restart, logout, and ordinary quit requests intentionally
        // use the same confirmation gate. Only Sparkle receives the narrow
        // one-shot authorization above after the user accepts its relaunch.
        requestTerminationDecision { [weak self] confirmed in
            self?.replyToApplicationShouldTerminate(confirmed)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func requestWorkspaceTabClose(_ window: NSWindow?) {
        guard let window, !window.isSheet else { return }
        window.close()
    }

    func requestWorkspaceWindowClose(_ window: NSWindow?) {
        guard let window, !window.isSheet else { return }
        let group = WorkspaceWindowIdentity.group(containing: window)
        group.forEach { $0.close() }
    }

    private func makeTerminationAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit Ghosthub?"
        alert.informativeText = "Ghosthub will close its terminal "
            + "presentations. Your tmux sessions will remain running."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
#endif
