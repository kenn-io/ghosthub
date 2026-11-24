import Foundation

/// Validates user-entered POSIX project paths before sending them to kwt.
public enum ProjectPath {
    /// Returns whether `path` is an absolute POSIX path (`/...`) or rooted at
    /// the target account's home directory (`~` or `~/...`).
    public static func isValidUserInput(_ path: String) -> Bool {
        path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
    }
}
