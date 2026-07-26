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
        hasPaneCloseHandler: Bool
    ) -> Bool {
        if flags == .command {
            switch chars {
            case "q", ",", "b", "n", "t":
                return true
            case "w":
                return !hasPaneCloseHandler
            default:
                return false
            }
        }
        if flags == [.command, .shift] {
            switch chars {
            case "n", "p", "w":
                return true
            default:
                return false
            }
        }
        return false
    }
}
