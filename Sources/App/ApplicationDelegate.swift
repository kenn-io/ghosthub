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
private final class WorkspaceWindowDelegateProxy: NSObject,
    NSWindowDelegate {
    weak var owner: ApplicationDelegate?
    nonisolated(unsafe) weak var downstream: (any NSWindowDelegate)?

    init(
        owner: ApplicationDelegate,
        downstream: (any NSWindowDelegate)?
    ) {
        self.owner = owner
        self.downstream = downstream
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if downstream?.windowShouldClose?(sender) == false {
            return false
        }
        return owner?.windowShouldClose(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        downstream?.windowWillClose?(notification)
        guard let window = notification.object as? NSWindow else {
            return
        }
        owner?.workspaceWindowDidClose(window)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || downstream?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        guard downstream?.responds(to: selector) == true else {
            return super.forwardingTarget(for: selector)
        }
        return downstream
    }
}

@MainActor
final class ApplicationDelegate: NSObject,
    NSApplicationDelegate,
    NSWindowDelegate {
    var confirmTermination: () -> Bool

    var requestTerminationConfirmation: (
        (@escaping (Bool) -> Void) -> Void
    )?

    var needsConfirmQuit: () -> Bool = { true }

    private(set) var terminationConfirmed = false

    private var workspaceWindowDelegates:
        [ObjectIdentifier: WorkspaceWindowDelegateProxy] = [:]

    override init() {
        confirmTermination = { false }
        super.init()
        confirmTermination = { [weak self] in
            guard let self else { return false }
            return presentApplicationAlert(makeTerminationAlert())
                == .alertFirstButtonReturn
        }
    }

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        NSWindow.allowsAutomaticWindowTabbing = false
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

        if let requestTerminationConfirmation {
            requestTerminationConfirmation { [weak self] confirmed in
                guard let self, confirmed else { return }
                terminationConfirmed = true
                onConfirm()
            }
            return
        }

        presentApplicationAlertAsync(makeTerminationAlert()) { [weak self] response in
            guard let self,
                  response == .alertFirstButtonReturn
            else {
                return
            }
            terminationConfirmed = true
            onConfirm()
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if terminationConfirmed {
            return .terminateNow
        }
        // Shutdown, restart, logout, and system-update requests intentionally
        // use the same confirmation gate. Ghosthub must not silently disappear
        // while terminal presentations are still open.
        return prepareUserInitiatedTermination()
            ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        terminationConfirmed
    }

    func installCloseConfirmation(on window: NSWindow) {
        guard !window.isSheet else { return }
        let identifier = ObjectIdentifier(window)
        if let proxy = workspaceWindowDelegates[identifier] {
            guard window.delegate !== proxy else { return }
            proxy.downstream = window.delegate === self
                ? nil : window.delegate
            window.delegate = proxy
            return
        }

        let downstream = window.delegate === self
            ? nil : window.delegate
        let proxy = WorkspaceWindowDelegateProxy(
            owner: self,
            downstream: downstream
        )
        workspaceWindowDelegates[identifier] = proxy
        window.delegate = proxy
    }

    fileprivate func workspaceWindowDidClose(_ window: NSWindow) {
        workspaceWindowDelegates.removeValue(
            forKey: ObjectIdentifier(window)
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let hasOtherManagedWindows = NSApplication.shared.windows
            .contains {
                $0 !== sender
                    && !$0.isSheet
                    && isManagedWorkspaceWindow($0)
            }

        if !hasOtherManagedWindows {
            guard prepareUserInitiatedTermination() else {
                return false
            }
        }
        return true
    }

    private func isManagedWorkspaceWindow(_ window: NSWindow) -> Bool {
        if window.delegate === self {
            return true
        }
        guard let proxy = workspaceWindowDelegates[
            ObjectIdentifier(window)
        ] else {
            return false
        }
        return window.delegate === proxy
    }

    private func makeTerminationAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit Ghosthub?"
        alert.informativeText = "This will close Ghosthub "
            + "and all active terminal surfaces."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
#endif
