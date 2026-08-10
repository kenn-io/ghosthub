import AppKit
import GhosthubTerminalSupport
import Testing
@testable import GhosthubTerminal

@Suite("Terminal application-shortcut reservation")
struct TerminalShortcutReservationTests {
    @Test("current application commands reach menus from a focused terminal")
    func currentApplicationCommandsAreReserved() {
        for (chars, keyCode): (String, UInt16) in [
            ("q", 12), (",", 43), ("b", 11), ("n", 45), ("t", 17),
        ] {
            #expect(TerminalSurfaceView.isReservedApplicationShortcut(
                flags: .command,
                chars: chars,
                keyCode: keyCode,
                hasPaneCloseHandler: false
            ))
        }
        for (chars, keyCode): (String, UInt16) in [
            ("n", 45), ("p", 35), ("w", 13),
        ] {
            #expect(TerminalSurfaceView.isReservedApplicationShortcut(
                flags: [.command, .shift],
                chars: chars,
                keyCode: keyCode,
                hasPaneCloseHandler: false
            ))
        }
        for (chars, keyCode): (String, UInt16) in [("{", 33), ("}", 30)] {
            #expect(TerminalSurfaceView.isReservedApplicationShortcut(
                flags: [.command, .shift],
                chars: chars,
                keyCode: keyCode,
                hasPaneCloseHandler: false
            ))
        }
        #expect(TerminalSurfaceView.isReservedApplicationShortcut(
            flags: [.command, .shift],
            chars: "<",
            keyCode: 43,
            hasPaneCloseHandler: false
        ))
    }

    @Test("unregistered Command chords are left to the terminal")
    func unregisteredCommandsAreNotReserved() {
        for (chars, keyCode): (String, UInt16) in [("a", 0), ("t", 17)] {
            #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
                flags: [.command, .shift],
                chars: chars,
                keyCode: keyCode,
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
        for (chars, keyCode): (String, UInt16) in [
            ("a", 0), ("c", 8), ("v", 9), ("x", 7),
        ] {
            #expect(!TerminalSurfaceView.isReservedApplicationShortcut(
                flags: .command,
                chars: chars,
                keyCode: keyCode,
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
