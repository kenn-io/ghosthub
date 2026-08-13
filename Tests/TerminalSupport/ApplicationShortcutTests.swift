import AppKit
import Testing
@testable import GhosthubTerminalSupport

@Suite("Application shortcuts")
struct ApplicationShortcutTests {
    @Test("AppKit translation removes Shift from punctuation keys")
    func translatesShiftedPunctuation() throws {
        let nextTab = ApplicationKeyBinding(
            appKitModifierFlags: [.command, .shift],
            charactersIgnoringModifiers: "}",
            keyCode: 30
        )
        let reloadConfiguration = ApplicationKeyBinding(
            appKitModifierFlags: [.command, .shift],
            charactersIgnoringModifiers: "<",
            keyCode: 43
        )

        #expect(
            nextTab
                == (try ApplicationKeyBinding(parsing: "cmd+shift+]"))
        )
        #expect(
            reloadConfiguration
                == (try ApplicationKeyBinding(parsing: "cmd+shift+,"))
        )
    }

    @Test("plus normalizes its physical Shift-equals chord")
    func normalizesPlus() throws {
        let configured = try ApplicationKeyBinding(parsing: "cmd+plus")
        let physical = try ApplicationKeyBinding(parsing: "cmd+shift+=")
        let translated = ApplicationKeyBinding(
            appKitModifierFlags: [.command, .shift],
            charactersIgnoringModifiers: "=",
            keyCode: 24
        )

        #expect(physical == configured)
        #expect(physical.configValue == "cmd+plus")
        #expect(translated == configured)
    }

    @Test("catalog exposes the complete stable action set and defaults")
    func catalogDefaults() {
        #expect(ApplicationShortcutCatalog.definitions.map(\.action) == ApplicationShortcutAction
            .allCases)

        let expected: [ApplicationShortcutAction: String?] = [
            .nextSibling: "ctrl+tab",
            .previousSibling: "ctrl+shift+tab",
            .selectSibling1: nil,
            .selectSibling2: nil,
            .selectSibling3: nil,
            .selectSibling4: nil,
            .selectSibling5: nil,
            .selectSibling6: nil,
            .selectSibling7: nil,
            .selectSibling8: nil,
            .selectSibling9: nil,
            .commandPalette: "cmd+shift+p",
            .toggleSidebar: "cmd+b",
            .newWorktree: "cmd+shift+n",
            .importPullRequest: "cmd+shift+i",
            .newTmuxSession: nil,
            .newHerdrSession: nil,
            .splitRight: "cmd+d",
            .splitDown: "cmd+shift+d",
            .reloadConfiguration: "cmd+shift+,",
            .openApplicationLog: "cmd+opt+l",
        ]

        let resolved = ApplicationShortcutCatalog.compiledDefaults
        for action in ApplicationShortcutAction.allCases {
            #expect(resolved[action]?.configValue == expected[action]!)
        }
    }

    @Test(
        "parser normalizes supported bindings",
        arguments: [
            ("Control+SHIFT+Tab", "ctrl+shift+tab", "⌃⇧⇥"),
            ("command+option+L", "cmd+opt+l", "⌥⌘L"),
            ("cmd+shift+,", "cmd+shift+,", "⇧⌘,"),
            ("cmd+plus", "cmd+plus", "⌘+"),
            ("ctrl+left", "ctrl+left", "⌃←"),
            ("opt+return", "opt+return", "⌥↩"),
            ("cmd+f12", "cmd+f12", "⌘F12"),
            ("ctrl+\\", "ctrl+\\", "⌃\\"),
        ]
    )
    func parsesBinding(
        source: String,
        normalized: String,
        display: String
    ) throws {
        let binding = try ApplicationKeyBinding(parsing: source)
        #expect(binding.configValue == normalized)
        #expect(binding.displayText == display)
    }

    @Test("none is an explicit unbound override")
    func explicitUnboundOverride() throws {
        #expect(try ApplicationShortcutOverride(parsing: "none") == .unbound)
        #expect(
            try ApplicationShortcutOverride(parsing: "ctrl+tab")
                == .binding(ApplicationKeyBinding(
                    modifiers: [.control],
                    key: .tab
                ))
        )
    }

    @Test(
        "unsafe and malformed bindings are rejected",
        arguments: [
            "a", "shift+a", "tab", "shift+tab", "left", "shift+f1",
            "cmd", "cmd+ctrl", "cmd+unknown", "cmd+p+p", "cmd+cmd+p",
        ]
    )
    func rejectsUnsafeBinding(_ source: String) {
        #expect(throws: ApplicationShortcutParseError.self) {
            try ApplicationKeyBinding(parsing: source)
        }
    }

    @Test("resolution rejects a fixed system shortcut")
    func fixedShortcutCollision() throws {
        let binding = try ApplicationKeyBinding(parsing: "cmd+shift+[")
        #expect(throws: ApplicationShortcutResolutionError.self) {
            try ApplicationShortcutCatalog.resolve(overrides: [
                .nextSibling: .binding(binding),
            ])
        }
    }

    @Test(
        "configurable shortcuts can supersede numbered native tabs",
        arguments: ["cmd+1", "cmd+8", "cmd+9"]
    )
    func numberedNativeTabOverride(source: String) throws {
        let binding = try ApplicationKeyBinding(parsing: source)

        #expect(ApplicationShortcutCatalog.validationMessage(
            for: binding,
            action: .selectSibling1,
            overrides: [:]
        ) == nil)
        let resolved = try ApplicationShortcutCatalog.resolve(overrides: [
            .selectSibling1: .binding(binding),
        ])
        #expect(resolved[.selectSibling1] == binding)
    }

    @Test(
        "numbered native tab commands never enter the terminal",
        arguments: [
            ("1", UInt16(18)),
            ("2", UInt16(19)),
            ("3", UInt16(20)),
            ("4", UInt16(21)),
            ("5", UInt16(23)),
            ("6", UInt16(22)),
            ("7", UInt16(26)),
            ("8", UInt16(28)),
            ("9", UInt16(25)),
        ]
    )
    func numberedNativeTabsAreTerminalReserved(
        character: String,
        keyCode: UInt16
    ) {
        #expect(TerminalApplicationShortcut.isReserved(
            flags: .command,
            chars: character,
            keyCode: keyCode,
            hasPaneCloseHandler: false
        ))
    }

    @Test(
        "standard macOS menu shortcuts remain reserved",
        arguments: [
            ("cmd+z", "Undo"),
            ("cmd+shift+z", "Redo"),
            ("cmd+h", "Hide Ghosthub"),
            ("cmd+opt+h", "Hide Others"),
            ("cmd+m", "Minimize"),
            ("cmd+opt+m", "Minimize All"),
            ("ctrl+cmd+f", "Enter Full Screen"),
            ("cmd+`", "Next Window"),
            ("cmd+shift+`", "Previous Window"),
            ("cmd+opt+w", "Close All"),
        ]
    )
    func standardMenuShortcutCollision(
        source: String,
        owner: String
    ) throws {
        let binding = try ApplicationKeyBinding(parsing: source)

        #expect(ApplicationShortcutCatalog.validationMessage(
            for: binding,
            action: .nextSibling,
            overrides: [:]
        ) == "Reserved for \(owner).")
    }

    @Test("resolution rejects duplicate effective bindings atomically")
    func duplicateBinding() throws {
        let binding = try ApplicationKeyBinding(parsing: "ctrl+tab")
        #expect(throws: ApplicationShortcutResolutionError.self) {
            try ApplicationShortcutCatalog.resolve(overrides: [
                .previousSibling: .binding(binding),
            ])
        }
    }

    @Test("unbinding one action permits moving its default to another")
    func atomicUnbindAndRebind() throws {
        let binding = try ApplicationKeyBinding(parsing: "ctrl+tab")
        let resolved = try ApplicationShortcutCatalog.resolve(overrides: [
            .nextSibling: .unbound,
            .previousSibling: .binding(binding),
        ])

        #expect(resolved[.nextSibling] == nil)
        #expect(resolved[.previousSibling] == binding)
        #expect(resolved.action(for: binding) == .previousSibling)
    }
}
