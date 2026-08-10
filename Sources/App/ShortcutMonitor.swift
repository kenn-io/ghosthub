import AppKit
import GhosthubTerminalSupport

@MainActor
final class ShortcutMonitor {
    private nonisolated(unsafe) var monitor: Any?
    private let shortcuts: () -> ResolvedApplicationShortcuts
    private let perform: (ApplicationShortcutAction) -> Bool

    init(
        shortcuts: @escaping () -> ResolvedApplicationShortcuts,
        perform: @escaping (ApplicationShortcutAction) -> Bool
    ) {
        self.shortcuts = shortcuts
        self.perform = perform
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            self?.process(event) ?? event
        }
    }

    nonisolated func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    func processForTesting(_ event: NSEvent) -> NSEvent? {
        process(event)
    }

    private func process(_ event: NSEvent) -> NSEvent? {
        guard let binding = ApplicationKeyBinding(
            appKitModifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        ),
            let action = shortcuts().action(for: binding),
            !event.isARepeat || action.definition.allowsKeyRepeat,
            perform(action)
        else { return event }
        return nil
    }
}
