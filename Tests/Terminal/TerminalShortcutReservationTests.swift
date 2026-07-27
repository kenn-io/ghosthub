import AppKit
import Testing
@testable import GhosthubTerminal

@Suite("Terminal application-shortcut reservation")
struct TerminalShortcutReservationTests {
    @Test("current application commands reach menus from a focused terminal")
    func currentApplicationCommandsAreReserved() {
        for chars in ["q", ",", "b", "n", "t"] {
            #expect(TerminalSurfaceView.isReservedApplicationShortcut(
                flags: .command,
                chars: chars,
                keyCode: 0,
                hasPaneCloseHandler: false
            ))
        }
        for chars in ["n", "p", "w"] {
            #expect(TerminalSurfaceView.isReservedApplicationShortcut(
                flags: [.command, .shift],
                chars: chars,
                keyCode: 0,
                hasPaneCloseHandler: false
            ))
        }
    }

    @Test("retired workspace commands are left to tmux")
    func retiredCommandsAreNotReserved() {
        for chars in ["a", "b", "i", "t", "["] {
            #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
                flags: [.command, .shift],
                chars: chars,
                keyCode: chars == "[" ? 33 : 0,
                hasPaneCloseHandler: false
            ))
        }
        #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
            flags: [.command, .shift],
            chars: "\u{7F}",
            keyCode: 51,
            hasPaneCloseHandler: false
        ))
        #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
            flags: [.command, .option],
            chars: "n",
            keyCode: 45,
            hasPaneCloseHandler: false
        ))
    }

    @Test("Cmd-W stays local when the tmux presentation handles close")
    func closeHandlerOwnsCommandW() {
        #expect(TerminalSurfaceView.isReservedApplicationShortcut(
            flags: .command,
            chars: "w",
            keyCode: 13,
            hasPaneCloseHandler: false
        ))
        #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
            flags: .command,
            chars: "w",
            keyCode: 13,
            hasPaneCloseHandler: true
        ))
    }
}
