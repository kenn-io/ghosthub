import GhosttyKit
import Testing
import UIKit
@testable import RendererSpike

@Suite("iOS keyboard mapping")
struct IOSKeyboardMapperTests {
    private struct KeyRouteCase: Sendable {
        let usage: UIKeyboardHIDUsage
        let characters: String
        let unmodified: String
        let modifiers: UIKeyModifierFlags
        let expectedKeycode: UInt32
        let expectedModifiers: UInt32
        let expectedText: String?
    }

    @Test(
        "HID usages map to Darwin virtual keycodes",
        arguments: [
            (UIKeyboardHIDUsage.keyboardA, UInt32(0x00)),
            (.keyboardD, UInt32(0x02)),
            (.keyboardZ, UInt32(0x06)),
            (.keyboardReturnOrEnter, UInt32(0x24)),
            (.keyboardEscape, UInt32(0x35)),
            (.keyboardDeleteOrBackspace, UInt32(0x33)),
            (.keyboardTab, UInt32(0x30)),
            (.keyboardSpacebar, UInt32(0x31)),
            (.keyboardLeftArrow, UInt32(0x7B)),
            (.keyboardRightArrow, UInt32(0x7C)),
            (.keyboardDownArrow, UInt32(0x7D)),
            (.keyboardUpArrow, UInt32(0x7E)),
        ]
    )
    func virtualKeycode(usage: UIKeyboardHIDUsage, expected: UInt32) {
        #expect(IOSKeyboardMapper.virtualKeycode(for: usage) == expected)
    }

    @Test("unknown HID usages are not guessed")
    func unknownUsage() {
        #expect(IOSKeyboardMapper.virtualKeycode(for: .keyboardF1) == nil)
    }

    @Test("UIKit modifiers map to libghostty modifiers")
    func modifiers() {
        let mapped = IOSKeyboardMapper.modifiers(
            for: [.shift, .control, .alternate, .command, .alphaShift]
        )
        let expected = GHOSTTY_MODS_SHIFT.rawValue
            | GHOSTTY_MODS_CTRL.rawValue
            | GHOSTTY_MODS_ALT.rawValue
            | GHOSTTY_MODS_SUPER.rawValue
            | GHOSTTY_MODS_CAPS.rawValue

        #expect(mapped.rawValue == expected)
    }

    @Test("ordinary hardware text defers to UIKeyInput")
    func ordinaryTextRoute() {
        let route = IOSKeyboardMapper.pressRoute(
            usage: .keyboardA,
            characters: "a",
            charactersIgnoringModifiers: "a",
            modifiers: []
        )

        #expect(route == .deferToTextInput)
        #expect(IOSKeyboardMapper.textInputRoute("hello") == .text("hello"))
    }

    @Test(
        "modified and special keys route through libghostty",
        arguments: [
            KeyRouteCase(
                usage: .keyboardA,
                characters: "\u{01}",
                unmodified: "a",
                modifiers: .control,
                expectedKeycode: 0x00,
                expectedModifiers: GHOSTTY_MODS_CTRL.rawValue,
                expectedText: "a"
            ),
            KeyRouteCase(
                usage: .keyboardD,
                characters: "∂",
                unmodified: "d",
                modifiers: .alternate,
                expectedKeycode: 0x02,
                expectedModifiers: GHOSTTY_MODS_ALT.rawValue,
                expectedText: "∂"
            ),
            KeyRouteCase(
                usage: .keyboardLeftArrow,
                characters: UIKeyCommand.inputLeftArrow,
                unmodified: UIKeyCommand.inputLeftArrow,
                modifiers: [],
                expectedKeycode: 0x7B,
                expectedModifiers: GHOSTTY_MODS_NONE.rawValue,
                expectedText: nil
            ),
        ]
    )
    private func keyRoute(testCase: KeyRouteCase) {
        let route = IOSKeyboardMapper.pressRoute(
            usage: testCase.usage,
            characters: testCase.characters,
            charactersIgnoringModifiers: testCase.unmodified,
            modifiers: testCase.modifiers
        )

        guard case let .key(key) = route else {
            Issue.record("Expected libghostty key route")
            return
        }
        #expect(key.keycode == testCase.expectedKeycode)
        #expect(key.modifiers.rawValue == testCase.expectedModifiers)
        #expect(key.text == testCase.expectedText)
        let expectedCodepoint = testCase.expectedText == nil
            ? 0
            : testCase.unmodified.unicodeScalars.first?.value
        #expect(key.unshiftedCodepoint == expectedCodepoint)
    }

    @Test("software delete maps to the backspace key")
    func softwareDeleteRoute() {
        guard case let .key(key) = IOSKeyboardMapper.deleteRoute() else {
            Issue.record("Expected backspace key route")
            return
        }

        #expect(key.keycode == 0x33)
        #expect(key.text == nil)
        #expect(key.unshiftedCodepoint == 0x08)
    }
}
