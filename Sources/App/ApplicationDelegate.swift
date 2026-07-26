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

enum WorkspaceTabAdoptionAction: Equatable {
    case ignore
    case finish
    case adopt
}

enum WorkspaceTabAdoptionPolicy {
    static func action(
        hasPendingParent: Bool,
        isParentWindow: Bool,
        isAlreadyGrouped: Bool
    ) -> WorkspaceTabAdoptionAction {
        guard hasPendingParent, !isParentWindow else {
            return .ignore
        }
        return isAlreadyGrouped ? .finish : .adopt
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

    var workspaceWindowCount: () -> Int = {
        WindowRegistry.shared.workspaceWindowCount
    }

    var openWorkspaceWindow: () -> Void = {}

    private weak var pendingTabParent: NSWindow?
    private(set) var terminationConfirmed = false
    private(set) var terminationConfirmationPending = false

    override init() {
        confirmTermination = { false }
        super.init()
        confirmTermination = { [weak self] in
            guard let self else { return false }
            return presentApplicationAlert(makeTerminationAlert())
                == .alertFirstButtonReturn
        }
    }

    @objc func newWindowForTab(_ sender: Any?) {
        requestNewWorkspaceTab(from: NSApplication.shared.keyWindow)
    }

    func requestNewWorkspaceTab(from parent: NSWindow?) {
        pendingTabParent = parent
        openWorkspaceWindow()
    }

    func adoptWorkspaceWindowAsTabIfRequested(_ window: NSWindow) {
        let parent = pendingTabParent
        let isAlreadyGrouped = parent?.tabbedWindows?
            .contains { $0 === window } ?? false
        let action = WorkspaceTabAdoptionPolicy.action(
            hasPendingParent: parent != nil,
            isParentWindow: parent === window,
            isAlreadyGrouped: isAlreadyGrouped
        )

        switch action {
        case .ignore:
            return
        case .finish:
            pendingTabParent = nil
        case .adopt:
            pendingTabParent = nil
            parent?.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
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

    func requestWorkspaceWindowClose(_ window: NSWindow?) {
        guard let window, !window.isSheet else { return }
        guard workspaceWindowCount() <= 1 else {
            window.close()
            return
        }
        // The final red close button follows the same asynchronous path as
        // Command-Q. Keeping the window open while the sheet is presented
        // avoids a nested run loop and never re-enters NSWindow.close().
        requestApplicationTermination()
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
