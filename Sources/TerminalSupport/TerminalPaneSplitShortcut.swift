/// Ghostty-style pane splitting requested from a capable session surface.
public enum TerminalPaneSplitShortcut: Equatable, Sendable {
    case right
    case down

    public init?(
        applicationShortcutAction action: ApplicationShortcutAction
    ) {
        switch action {
        case .splitRight:
            self = .right
        case .splitDown:
            self = .down
        default:
            return nil
        }
    }
}
