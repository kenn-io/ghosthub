import AppKit
import GhosthubTerminalSupport

@MainActor
final class ShortcutMonitor {
    private nonisolated(unsafe) var monitor: Any?
    private let shortcuts: () -> ResolvedApplicationShortcuts
    private let perform: (ApplicationShortcutAction) -> Bool
    private var handledKeyCodes: Set<UInt16> = []

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
            matching: [.keyDown, .keyUp]
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
        if event.type == .keyUp {
            return handledKeyCodes.remove(event.keyCode) == nil ? event : nil
        }
        guard event.type == .keyDown else { return event }

        guard let binding = ApplicationKeyBinding(
            appKitModifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        ),
            let action = shortcuts().action(for: binding)
        else { return event }

        if event.isARepeat, !action.definition.allowsKeyRepeat {
            return handledKeyCodes.contains(event.keyCode) ? nil : event
        }

        let handled = perform(action)
        if !event.isARepeat {
            if handled {
                handledKeyCodes.insert(event.keyCode)
            } else {
                handledKeyCodes.remove(event.keyCode)
            }
        }
        return handled ? nil : event
    }
}
