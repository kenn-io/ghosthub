import AppKit
import GhosthubTerminalSupport

@MainActor
enum NativeTabCommands {
    static let previousBinding = try! ApplicationKeyBinding(
        parsing: "cmd+shift+["
    )
    static let nextBinding = try! ApplicationKeyBinding(
        parsing: "cmd+shift+]"
    )

    static func selectPrevious() {
        NSApp.sendAction(
            #selector(NSWindow.selectPreviousTab(_:)),
            to: nil,
            from: nil
        )
    }

    static func selectNext() {
        NSApp.sendAction(
            #selector(NSWindow.selectNextTab(_:)),
            to: nil,
            from: nil
        )
    }

    static func installBracketShortcuts(in menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }
        for item in menu.items {
            switch item.action {
            case #selector(NSWindow.selectPreviousTab(_:)):
                apply(previousBinding, to: item)
            case #selector(NSWindow.selectNextTab(_:)):
                apply(nextBinding, to: item)
            default:
                break
            }
            installBracketShortcuts(in: item.submenu)
        }
    }

    private static func apply(
        _ binding: ApplicationKeyBinding,
        to item: NSMenuItem
    ) {
        guard case let .character(character) = binding.key else { return }
        item.keyEquivalent = String(character)
        item.keyEquivalentModifierMask = binding.modifiers.appKit
    }
}
