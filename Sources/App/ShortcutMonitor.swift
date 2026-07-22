import AppKit

@MainActor
final class ShortcutMonitor {
    enum InterceptedShortcutAction: Equatable {
        case selectWorktreeByIndex(Int)
        case previousWorktree
        case nextWorktree
        case toggleSidebar
        case openCommandPalette
    }

    /// Each callback returns `true` when it handled the event,
    /// `false` to let the event propagate to another window.
    struct Callbacks {
        var selectWorktreeByIndex: (Int) -> Bool
        var previousWorktree: () -> Bool
        var nextWorktree: () -> Bool
        var toggleSidebar: () -> Bool
        var openCommandPalette: () -> Bool
    }

    private nonisolated(unsafe) var monitor: Any?
    private let callbacks: Callbacks

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    nonisolated func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let action = Self.interceptedAction(
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers:
            event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        ) else {
            return event
        }

        let handled: Bool
        switch action {
        case let .selectWorktreeByIndex(index):
            handled = callbacks.selectWorktreeByIndex(index)
        case .previousWorktree:
            handled = callbacks.previousWorktree()
        case .nextWorktree:
            handled = callbacks.nextWorktree()
        case .toggleSidebar:
            handled = callbacks.toggleSidebar()
        case .openCommandPalette:
            handled = callbacks.openCommandPalette()
        }
        return handled ? nil : event
    }

    static func interceptedAction(
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        keyCode: UInt16
    ) -> InterceptedShortcutAction? {
        let flags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        let charactersIgnoringModifiers =
            charactersIgnoringModifiers?.lowercased()

        // Cmd+Shift+P → command palette
        if flags == [.command, .shift],
           charactersIgnoringModifiers == "p" {
            return .openCommandPalette
        }

        // Cmd+B and Cmd+Shift+B are handled by the SwiftUI menu
        // keyboard shortcuts (View > Toggle Sidebar / Toggle Side
        // Panel). Do NOT intercept here — doing so causes a
        // double-toggle that flashes the panel.

        // Cmd+Opt+Up → previous worktree
        if flags == [.command, .option],
           keyCode == 126 {
            return .previousWorktree
        }

        // Cmd+Opt+Down → next worktree
        if flags == [.command, .option],
           keyCode == 125 {
            return .nextWorktree
        }

        // Cmd+1..9 → select worktree by index
        if flags == .command,
           let chars = charactersIgnoringModifiers,
           let digit = chars.first?.wholeNumberValue,
           (1 ... 9).contains(digit) {
            return .selectWorktreeByIndex(digit)
        }

        return nil
    }
}
