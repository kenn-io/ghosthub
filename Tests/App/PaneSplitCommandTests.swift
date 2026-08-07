#if canImport(AppKit)
import AppKit
import GhosthubTerminalSupport
import Testing
@testable import GhosthubApp

@MainActor
struct PaneSplitCommandTests {
    @Test("menu key equivalents require effective terminal focus")
    func menuKeyboardShortcutAvailability() {
        #expect(PaneSplitCommand.usesKeyboardShortcut(
            canSplit: true,
            hasEffectiveKeyboardFocus: true
        ))
        #expect(!PaneSplitCommand.usesKeyboardShortcut(
            canSplit: true,
            hasEffectiveKeyboardFocus: false
        ))
        #expect(!PaneSplitCommand.usesKeyboardShortcut(
            canSplit: false,
            hasEffectiveKeyboardFocus: true
        ))
    }

    @Test("only exact pane split chords require terminal focus")
    func focusRequirementMatchesPhysicalShortcut() throws {
        let splitRight = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ))
        let keyboardMenuSelection = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        #expect(PaneSplitCommand.requiresKeyboardFocus(
            .right,
            currentEvent: splitRight
        ))
        #expect(!PaneSplitCommand.requiresKeyboardFocus(
            .down,
            currentEvent: splitRight
        ))
        #expect(!PaneSplitCommand.requiresKeyboardFocus(
            .right,
            currentEvent: keyboardMenuSelection
        ))
    }
}
#endif
