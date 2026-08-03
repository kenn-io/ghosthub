#if canImport(AppKit)
import AppKit
import GhosthubWorkspace

@MainActor
private func presentApplicationAlert(
    _ alert: NSAlert
) -> NSApplication.ModalResponse {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        return alert.runModal()
    }

    var response: NSApplication.ModalResponse?
    alert.beginSheetModal(for: window) { modalResponse in
        response = modalResponse
    }

    while response == nil {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.01)
        )
    }

    return response ?? .abort
}

@MainActor
private func presentApplicationAlertAsync(
    _ alert: NSAlert,
    completion: @escaping (NSApplication.ModalResponse) -> Void
) {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        completion(alert.runModal())
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

        init(parent: Window?) {
            self.parent = parent
        }
    }

    private var requests: [UUID: Request] = [:]

    func add(_ id: UUID, parent: Window?) {
        requests[id] = Request(parent: parent)
    }

    func consumeParent(
        for id: UUID?,
        window: Window
    ) -> Window? {
        guard let id,
              let request = requests.removeValue(forKey: id),
              let parent = request.parent,
              parent !== window
        else { return nil }
        return parent
    }
}

@MainActor
final class ApplicationDelegate: NSObject,
    NSApplicationDelegate {
    var confirmTermination: () -> Bool

    var requestTerminationConfirmation: (
        (@escaping (Bool) -> Void) -> Void
    )?

    var needsConfirmQuit: () -> Bool = { true }

    var terminateApplication: () -> Void = {
        NSApplication.shared.terminate(nil)
    }

    var openWorkspaceWindow: (WorkspaceWindowState) -> Void = { _ in }

    private let windowRequests = WorkspaceWindowRequests<NSWindow>()
    private var windowRestorationFinishedHandler: (Int) -> Void = { _ in }
    private var restoredWorkspaceWindowCount: Int?
    private(set) var terminationConfirmed = false
    private(set) var terminationConfirmationPending = false
    private var updaterTerminationAuthorized = false

    override init() {
        confirmTermination = { false }
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidFinishRestoringWindows(_:)),
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: nil
        )
        confirmTermination = { [weak self] in
            guard let self else { return false }
            return presentApplicationAlert(makeTerminationAlert())
                == .alertFirstButtonReturn
        }
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
        // Cmd-N must stay an independent window even when the user's system
        // preference normally groups newly opened windows into tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidBecomeActive(
        _ notification: Notification
    ) {
        TelemetryController.shared.applicationDidBecomeActive()
    }

    func applicationWillResignActive(
        _ notification: Notification
    ) {
        TelemetryController.shared.applicationWillResignActive()
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

    func adoptWorkspaceWindowAsTabIfRequested(
        _ window: NSWindow,
        requestID: UUID?
    ) {
        guard WorkspaceWindowIdentity.matches(window),
              let parent = windowRequests.consumeParent(
                  for: requestID,
                  window: window
              )
        else { return }
        guard !WorkspaceWindowIdentity.group(containing: parent)
            .contains(where: { $0 === window })
        else { return }
        parent.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    private func requestWorkspaceWindow(
        parent: NSWindow?
    ) -> WorkspaceWindowState {
        let state = WorkspaceWindowState.fresh()
        windowRequests.add(state.windowID, parent: parent)
        return state
    }

    @discardableResult
    func prepareUserInitiatedTermination(
        forceConfirmation: Bool = false
    ) -> Bool {
        if terminationConfirmed {
            return true
        }
        guard forceConfirmation || needsConfirmQuit() else {
            terminationConfirmed = true
            return true
        }
        guard confirmTermination() else {
            return false
        }
        terminationConfirmed = true
        return true
    }

    func requestUserInitiatedTermination(
        forceConfirmation: Bool = false,
        onConfirm: @escaping () -> Void
    ) {
        if terminationConfirmed {
            AppLogger.shared.info(
                "quit: already confirmed, terminating"
            )
            onConfirm()
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
            onConfirm()
            return
        }
        guard !terminationConfirmationPending else {
            AppLogger.shared.info(
                "quit: confirmation already pending"
            )
            return
        }
        terminationConfirmationPending = true

        if let requestTerminationConfirmation {
            requestTerminationConfirmation { [weak self] confirmed in
                guard let self else { return }
                terminationConfirmationPending = false
                guard confirmed else { return }
                terminationConfirmed = true
                onConfirm()
            }
            return
        }

        presentApplicationAlertAsync(makeTerminationAlert()) { [weak self] response in
            guard let self else { return }
            terminationConfirmationPending = false
            guard response == .alertFirstButtonReturn else { return }
            terminationConfirmed = true
            onConfirm()
        }
    }

    func requestApplicationTermination() {
        requestUserInitiatedTermination { [weak self] in
            self?.terminateApplication()
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
        // Shutdown, restart, logout, and ordinary quit requests intentionally
        // use the same confirmation gate. Only Sparkle receives the narrow
        // one-shot authorization above after the user accepts its relaunch.
        return prepareUserInitiatedTermination()
            ? .terminateNow : .terminateCancel
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
