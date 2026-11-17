import AppKit

/// Pure application-shortcut reservation logic.
///
/// A reserved shortcut is passed through to the application/menu instead of
/// being handled by the terminal.
public enum TerminalApplicationShortcut {
    public static func isReserved(
        flags: NSEvent.ModifierFlags,
        chars: String?,
        keyCode: UInt16,
        hasPaneCloseHandler: Bool,
        shortcuts: ResolvedApplicationShortcuts =
            ApplicationShortcutCatalog.compiledDefaults
    ) -> Bool {
        guard let binding = ApplicationKeyBinding(
            appKitModifierFlags: flags,
            charactersIgnoringModifiers: chars,
            keyCode: keyCode
        ) else {
            return false
        }

        if binding == commandW, hasPaneCloseHandler {
            return false
        }
        if terminalFixedBindings.contains(binding) {
            return true
        }

        return binding.modifiers.contains(.command)
            && shortcuts.action(for: binding) != nil
    }

    private static let commandW = try! ApplicationKeyBinding(
        parsing: "cmd+w"
    )

    private static let terminalFixedBindings = Set(
        ([
            "cmd+q",
            "cmd+,",
            "cmd+n",
            "cmd+t",
            "cmd+w",
            "cmd+shift+w",
            "cmd+shift+[",
            "cmd+shift+]",
        ] + (1 ... 9).map { "cmd+\($0)" })
            .map { try! ApplicationKeyBinding(parsing: $0) }
    )
}
