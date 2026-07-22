#if canImport(AppKit)
import AppKit
import Testing
@testable import GhosthubApp

@MainActor
struct ShortcutMonitorTests {
    @Test(
        "intercepts supported app shortcuts",
        arguments: [
            ShortcutCase(
                [.command, .shift], "p", 35,
                expected: .openCommandPalette
            ),
            ShortcutCase(
                [.command, .option], nil, 126,
                expected: .previousWorktree
            ),
            ShortcutCase(
                [.command, .option], nil, 125,
                expected: .nextWorktree
            ),
        ]
    )
    func interceptedActionMatchesSupportedShortcut(
        _ shortcut: ShortcutCase
    ) {
        shortcut.expectAction()
    }

    @Test(
        "does not intercept unrelated shortcuts",
        arguments: [
            ShortcutCase(
                .command, "t", 17, expected: nil
            ),
            ShortcutCase(
                .command, "b", 11, expected: nil
            ),
            ShortcutCase(
                [.command, .shift], "b", 11, expected: nil
            ),
            ShortcutCase(
                .command, "k", 40, expected: nil
            ),
            ShortcutCase(
                [.command, .option], nil, 123,
                expected: nil
            ),
            ShortcutCase(
                [.command, .option], nil, 124,
                expected: nil
            ),
            ShortcutCase(
                [.command, .option], "2", 19,
                expected: nil
            ),
            ShortcutCase(
                [.command, .shift], nil, 30,
                expected: nil
            ),
            ShortcutCase(
                [.command, .shift], nil, 33,
                expected: nil
            ),
        ]
    )
    func interceptedActionIgnoresUnrelatedShortcut(
        _ shortcut: ShortcutCase
    ) {
        shortcut.expectAction()
    }
}

struct ShortcutCase: Sendable, CustomTestStringConvertible {
    let modifierFlags: UInt
    let characters: String?
    let keyCode: UInt16
    let expected: ShortcutMonitor.InterceptedShortcutAction?

    init(
        _ modifiers: NSEvent.ModifierFlags,
        _ characters: String?,
        _ keyCode: UInt16,
        expected: ShortcutMonitor.InterceptedShortcutAction?
    ) {
        modifierFlags = modifiers.rawValue
        self.characters = characters
        self.keyCode = keyCode
        self.expected = expected
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    var testDescription: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("command") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(characters ?? "keyCode(\(keyCode))")
        return parts.joined(separator: "-")
    }

    @MainActor
    func expectAction(
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let action = ShortcutMonitor.interceptedAction(
            modifierFlags: modifiers,
            charactersIgnoringModifiers: characters,
            keyCode: keyCode
        )
        #expect(
            action == expected,
            sourceLocation: sourceLocation
        )
    }
}
#endif
