import AppKit
import Testing
@testable import GhosthubTerminalSupport

@Suite("Tmux pane split shortcuts")
struct TerminalTmuxSplitShortcutTests {
    @Test("Ghostty split chords map to semantic directions")
    func splitDirections() throws {
        let cases: [(
            flags: NSEvent.ModifierFlags,
            shortcut: TerminalTmuxSplitShortcut
        )] = [
            (NSEvent.ModifierFlags.command, .right),
            ([.command, .capsLock], .right),
            ([.command, .shift], .down),
            ([.command, .shift, .capsLock], .down),
        ]

        for testCase in cases {
            let shortcut = try #require(
                TerminalTmuxSplitShortcut.matching(
                    flags: testCase.flags,
                    charactersIgnoringModifiers: "d"
                )
            )

            #expect(shortcut == testCase.shortcut)
        }
    }

    @Test("other Command chords remain terminal input")
    func unrelatedInput() {
        #expect(TerminalTmuxSplitShortcut.matching(
            flags: [.command, .option],
            charactersIgnoringModifiers: "d"
        ) == nil)
        #expect(TerminalTmuxSplitShortcut.matching(
            flags: .command,
            charactersIgnoringModifiers: "k"
        ) == nil)
    }
}
