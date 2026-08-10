import AppKit

/// Pure application-shortcut reservation logic shared by the real and
/// unavailable terminal targets.
///
/// A reserved shortcut is passed through to the application/menu instead of
/// being handled by the terminal.
///
/// Living in `GhosthubTerminalSupport` keeps a single source of truth that both
/// `GhosthubTerminal` variants forward to, so an unbootstrapped checkout (which
/// swaps in the terminal stub) still reserves identical shortcuts and its tests
/// compile.
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

    private static let terminalFixedBindings = Set([
        "cmd+q",
        "cmd+,",
        "cmd+n",
        "cmd+t",
        "cmd+w",
        "cmd+shift+w",
        "cmd+shift+[",
        "cmd+shift+]",
    ].map { try! ApplicationKeyBinding(parsing: $0) })
}
