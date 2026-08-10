import Foundation

extension Notification.Name {
    public static let ghosthubNewWorktree =
        Notification.Name("ghosthubNewWorktree")
    public static let ghosthubCloseTab =
        Notification.Name("ghosthubCloseTab")
    public static let ghosthubCommandPalette =
        Notification.Name("ghosthubCommandPalette")
    public static let ghosthubToggleSidebar =
        Notification.Name("ghosthubToggleSidebar")
    public static let ghosthubApplyThemeToCurrentSession =
        Notification.Name("ghosthubApplyThemeToCurrentSession")
    public static let ghosthubApplicationShortcutRequest =
        Notification.Name("ghosthubApplicationShortcutRequest")
}

public let applicationShortcutActionUserInfoKey = "action"
