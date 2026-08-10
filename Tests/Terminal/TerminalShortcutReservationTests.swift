import AppKit
import GhosthubTerminalSupport
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
        for chars in ["[", "]"] {
            #expect(TerminalSurfaceView.isReservedApplicationShortcut(
                flags: [.command, .shift],
                chars: chars,
                keyCode: 0,
                hasPaneCloseHandler: false
            ))
        }
    }

    @Test("unregistered Command chords are left to the terminal")
    func unregisteredCommandsAreNotReserved() {
        for chars in ["a", "t"] {
            #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
                flags: [.command, .shift],
                chars: chars,
                keyCode: 0,
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
        for chars in ["a", "c", "v", "x"] {
            #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
                flags: .command,
                chars: chars,
                keyCode: 0,
                hasPaneCloseHandler: false
            ))
        }
    }

    @Test("reservation follows the live resolved registry")
    func resolvedRegistry() throws {
        let shortcuts = try ApplicationShortcutCatalog.resolve(overrides: [
            .toggleSidebar: .binding(
                try ApplicationKeyBinding(parsing: "cmd+k")
            ),
            .splitRight: .unbound,
        ])

        #expect(TerminalSurfaceView.isReservedApplicationShortcut(
            flags: .command,
            chars: "k",
            keyCode: 40,
            hasPaneCloseHandler: false,
            shortcuts: shortcuts
        ))
        #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
            flags: .command,
            chars: "b",
            keyCode: 11,
            hasPaneCloseHandler: false,
            shortcuts: shortcuts
        ))
        #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
            flags: .command,
            chars: "d",
            keyCode: 2,
            hasPaneCloseHandler: false,
            shortcuts: shortcuts
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
