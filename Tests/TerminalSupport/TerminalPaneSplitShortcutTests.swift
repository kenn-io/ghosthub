import AppKit
import Testing
@testable import GhosthubTerminalSupport

@Suite("Pane split shortcuts")
struct TerminalPaneSplitShortcutTests {
    @Test("Ghostty split chords map to semantic directions")
    func splitDirections() throws {
        let cases: [(
            flags: NSEvent.ModifierFlags,
            shortcut: TerminalPaneSplitShortcut
        )] = [
            (NSEvent.ModifierFlags.command, .right),
            ([.command, .capsLock], .right),
            ([.command, .shift], .down),
            ([.command, .shift, .capsLock], .down),
        ]

        for testCase in cases {
            let shortcut = try #require(
                TerminalPaneSplitShortcut.matching(
                    flags: testCase.flags,
                    charactersIgnoringModifiers: "d"
                )
            )

            #expect(shortcut == testCase.shortcut)
        }
    }

    @Test("other Command chords remain terminal input")
    func unrelatedInput() {
        #expect(TerminalPaneSplitShortcut.matching(
            flags: [.command, .option],
            charactersIgnoringModifiers: "d"
        ) == nil)
        #expect(TerminalPaneSplitShortcut.matching(
            flags: .command,
            charactersIgnoringModifiers: "k"
        ) == nil)
    }
}
