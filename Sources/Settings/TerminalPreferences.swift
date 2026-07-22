import Foundation

public enum CursorStyle: String, CaseIterable, Identifiable, Sendable {
    case block
    case bar
    case underline

    public var id: Self { self }

    public var title: String {
        switch self {
        case .block:
            return "Block"
        case .bar:
            return "Line"
        case .underline:
            return "Underline"
        }
    }
}

public struct TerminalPreferences: Equatable, Sendable {
    public var cursorStyle: CursorStyle
    public var allowShellIntegrationToControlCursor: Bool
    public var hideMouseWhileTyping: Bool
    public var copySelectionToClipboard: Bool
    public var showPaneResourceUsage: Bool
    public var confirmPaneClose: Bool

    public init(
        cursorStyle: CursorStyle,
        allowShellIntegrationToControlCursor: Bool,
        hideMouseWhileTyping: Bool,
        copySelectionToClipboard: Bool,
        showPaneResourceUsage: Bool,
        confirmPaneClose: Bool = true
    ) {
        self.cursorStyle = cursorStyle
        self.allowShellIntegrationToControlCursor =
            allowShellIntegrationToControlCursor
        self.hideMouseWhileTyping = hideMouseWhileTyping
        self.copySelectionToClipboard = copySelectionToClipboard
        self.showPaneResourceUsage = showPaneResourceUsage
        self.confirmPaneClose = confirmPaneClose
    }
}
