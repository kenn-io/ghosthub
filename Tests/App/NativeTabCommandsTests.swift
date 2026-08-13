import AppKit
import Testing
@testable import GhosthubApp

@MainActor
struct NativeTabCommandsTests {
    private final class Window {
        var group: [Window] = []
        var hasAttachedSheet = false
        var isWorkspace = true
    }

    private final class WindowOrder {
        var windows: [NSWindow]

        init(_ windows: [NSWindow]) {
            self.windows = windows
        }
    }

    @Test(
        "numbered shortcuts match Ghostty tab selection",
        arguments: [
            (1, 1, 0),
            (3, 1, 0),
            (3, 2, 1),
            (3, 8, 2),
            (3, 9, 2),
        ]
    )
    func numberedSelection(
        windowCount: Int,
        shortcut: Int,
        expectedIndex: Int
    ) {
        let windows = (0 ..< windowCount).map { _ in Window() }
        windows.forEach { $0.group = windows }

        let target = NativeTabCommands.target(
            for: shortcut,
            candidate: windows[0],
            isWorkspace: \.isWorkspace,
            hasAttachedSheet: \.hasAttachedSheet,
            group: \.group
        )

        #expect(target === windows[expectedIndex])
    }

    @Test("numbered shortcuts stay within the candidate window group")
    func keyWindowGroup() {
        let firstGroup = (0 ..< 2).map { _ in Window() }
        let secondGroup = (0 ..< 2).map { _ in Window() }
        firstGroup.forEach { $0.group = firstGroup }
        secondGroup.forEach { $0.group = secondGroup }

        let target = NativeTabCommands.target(
            for: 9,
            candidate: firstGroup[0],
            isWorkspace: \.isWorkspace,
            hasAttachedSheet: \.hasAttachedSheet,
            group: \.group
        )

        #expect(target === firstGroup[1])
    }

    @Test("attached sheets keep native tab selection modal")
    func attachedSheet() {
        let window = Window()
        window.group = [window]
        window.hasAttachedSheet = true

        let target = NativeTabCommands.target(
            for: 1,
            candidate: window,
            isWorkspace: \.isWorkspace,
            hasAttachedSheet: \.hasAttachedSheet,
            group: \.group
        )

        #expect(target == nil)
    }

    @Test("numbered shortcuts ignore non-workspace windows")
    func nonWorkspaceWindow() {
        let window = Window()
        window.group = [window]
        window.isWorkspace = false

        let target = NativeTabCommands.target(
            for: 1,
            candidate: window,
            isWorkspace: \.isWorkspace,
            hasAttachedSheet: \.hasAttachedSheet,
            group: \.group
        )

        #expect(target == nil)
    }

    @Test("tab shortcut badges follow current native tab order")
    func shortcutBadges() {
        let windows = (0 ..< 10).map { _ in NSWindow() }

        NativeTabCommands.refreshBadges(in: windows)

        #expect(badgeText(in: windows[0]) == "⌘1")
        #expect(badgeText(in: windows[7]) == "⌘8")
        #expect(badgeText(in: windows[8]) == nil)
        #expect(badgeText(in: windows[9]) == nil)

        NativeTabCommands.refreshBadges(in: windows.reversed())

        #expect(badgeText(in: windows[9]) == "⌘1")
        #expect(badgeText(in: windows[0]) == nil)
    }

    @Test("tab shortcut badges refresh after AppKit reorders tabs")
    func reorderedShortcutBadges() {
        let first = NSWindow()
        let second = NSWindow()
        let third = NSWindow()
        let order = WindowOrder([first, second, third])
        let controller = NativeTabBadgeController { _ in order.windows }
        controller.install(on: first)
        order.windows = [second, third, first]

        NotificationCenter.default.post(
            name: NSView.frameDidChangeNotification,
            object: first.tab.accessoryView
        )

        #expect(badgeText(in: second) == "⌘1")
        #expect(badgeText(in: third) == "⌘2")
        #expect(badgeText(in: first) == "⌘3")
    }

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

    private func badgeText(in window: NSWindow) -> String? {
        (window.tab.accessoryView as? NSTextField)?.stringValue
    }
}
