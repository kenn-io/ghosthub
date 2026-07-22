import Foundation

public enum ExpectedPaths {
    public static var stateHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".ghosthub", isDirectory: true
            )
    }

    public static var worktrees: URL {
        stateHome.appendingPathComponent(
            "worktrees", isDirectory: true
        )
    }

    public static var configHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".config", isDirectory: true
            )
            .appendingPathComponent(
                "ghosthub", isDirectory: true
            )
    }

    public static var database: URL {
        stateHome.appendingPathComponent(
            "ghosthub.db", isDirectory: false
        )
    }
}
