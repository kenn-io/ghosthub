import AppKit

/// Ghostty-style pane splitting requested from an attached tmux surface.
public enum TerminalTmuxSplitShortcut: Equatable, Sendable {
    case right
    case down

    public static func matching(
        flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> Self? {
        let flags = flags.intersection([
            .command,
            .shift,
            .control,
            .option,
        ])
        guard charactersIgnoringModifiers?.lowercased() == "d" else {
            return nil
        }

        switch flags {
        case .command:
            return .right
        case [.command, .shift]:
            return .down
        default:
            return nil
        }
    }
}
