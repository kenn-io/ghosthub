import AppKit
import Testing
@testable import GhosthubApp

@MainActor
struct NativeTabCommandsTests {
    @Test("native tab commands use fixed bracket shortcuts")
    func bracketShortcuts() {
        let root = NSMenu()
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu()
        let previous = NSMenuItem(
            title: "Show Previous Tab",
            action: #selector(NSWindow.selectPreviousTab(_:)),
            keyEquivalent: "\t"
        )
        previous.keyEquivalentModifierMask = [.control, .shift]
        let next = NSMenuItem(
            title: "Show Next Tab",
            action: #selector(NSWindow.selectNextTab(_:)),
            keyEquivalent: "\t"
        )
        next.keyEquivalentModifierMask = .control
        windowMenu.addItem(previous)
        windowMenu.addItem(next)
        windowItem.submenu = windowMenu
        root.addItem(windowItem)

        NativeTabCommands.installBracketShortcuts(in: root)

        #expect(previous.keyEquivalent == "[")
        #expect(previous.keyEquivalentModifierMask == [.command, .shift])
        #expect(next.keyEquivalent == "]")
        #expect(next.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test("unrelated menu shortcuts remain unchanged")
    func unrelatedMenuItem() {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Other",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)

        NativeTabCommands.installBracketShortcuts(in: menu)

        #expect(item.keyEquivalent == "w")
        #expect(item.keyEquivalentModifierMask == .command)
    }
}
