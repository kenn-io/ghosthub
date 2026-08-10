import AppKit
import GhosthubTerminalSupport

@MainActor
final class ShortcutMonitor {
    private nonisolated(unsafe) var monitor: Any?
    private let shortcuts: () -> ResolvedApplicationShortcuts
    private let perform: (ApplicationShortcutAction) -> Bool
    private var handledBindings: Set<ApplicationKeyBinding> = []

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
            let action = shortcuts().action(for: binding)
        else { return event }

        if event.isARepeat, !action.definition.allowsKeyRepeat {
            return handledBindings.contains(binding) ? nil : event
        }

        let handled = perform(action)
        if !event.isARepeat {
            if handled {
                handledBindings.insert(binding)
            } else {
                handledBindings.remove(binding)
            }
        }
        return handled ? nil : event
    }
}
