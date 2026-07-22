import Foundation

/// Resolves the Ghosthub configuration directory.
///
/// Resolution order:
/// 1. `GHOSTHUB_CONFIG_HOME` environment variable (absolute path)
/// 2. `GHOSTHUB_HOME` environment variable + `/config`
/// 3. `~/.config/ghosthub/init.toml` containing `config_home = "/path"`
/// 4. Default: `~/.config/ghosthub/`
public enum ConfigHome {
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let envPath = environment["GHOSTHUB_CONFIG_HOME"],
           !envPath.isEmpty,
           envPath.hasPrefix("/") {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }

        if let homePath = environment["GHOSTHUB_HOME"],
           !homePath.isEmpty {
            return URL(
                fileURLWithPath: homePath, isDirectory: true
            ).appendingPathComponent("config", isDirectory: true)
        }

        let defaultDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghosthub", isDirectory: true)

        if let redirect = readInitToml(
            in: defaultDirectory,
            fileManager: fileManager
        ) {
            return redirect
        }

        return defaultDirectory
    }

    static func readInitToml(
        in directory: URL,
        fileManager: FileManager
    ) -> URL? {
        let initURL = directory.appendingPathComponent(
            "init.toml",
            isDirectory: false
        )

        guard fileManager.fileExists(atPath: initURL.path) else {
            return nil
        }

        guard let contents = try? String(
            contentsOf: initURL,
            encoding: .utf8
        ) else {
            return nil
        }

        return parseConfigHome(from: contents)
    }

    static func parseConfigHome(from contents: String) -> URL? {
        for line in contents.split(
            whereSeparator: \.isNewline
        ) {
            let trimmed = line
                .trimmingCharacters(in: .whitespaces)

            guard !trimmed.hasPrefix("#") else {
                continue
            }

            guard trimmed.hasPrefix("config_home") else {
                continue
            }

            let afterKey = trimmed.dropFirst("config_home".count)
                .trimmingCharacters(in: .whitespaces)

            guard afterKey.hasPrefix("=") else {
                continue
            }

            var rawValue = afterKey.dropFirst()
                .trimmingCharacters(in: .whitespaces)

            // Strip inline TOML comments (# ...) to match the Go
            // resolver's behavior.
            rawValue = Self.stripInlineComment(rawValue)

            let value: String
            if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""),
               rawValue.count >= 2 {
                value = String(
                    rawValue.dropFirst().dropLast()
                )
            } else if rawValue.hasPrefix("'"),
                      rawValue.hasSuffix("'"),
                      rawValue.count >= 2 {
                value = String(
                    rawValue.dropFirst().dropLast()
                )
            } else {
                value = rawValue
            }

            guard !value.isEmpty,
                  value.hasPrefix("/") else {
                return nil
            }

            return URL(fileURLWithPath: value, isDirectory: true)
        }

        return nil
    }

    /// Strips a trailing TOML inline comment from a value string.
    /// For quoted values, strips everything after the closing quote.
    /// For unquoted values, strips from the first `#`.
    private static func stripInlineComment(_ s: String) -> String {
        if s.hasPrefix("\"") || s.hasPrefix("'") {
            let quote = s.first!
            if let closeIdx = s.dropFirst().firstIndex(of: quote) {
                return String(s[s.startIndex ... closeIdx])
            }
            return s
        }
        if let hashIdx = s.firstIndex(of: "#") {
            return s[s.startIndex ..< hashIdx]
                .trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}

/// Resolves the Ghosthub application-state directory.
///
/// Resolution order:
/// 1. `GHOSTHUB_STATE_HOME` environment variable
/// 2. `GHOSTHUB_HOME` environment variable + `/state`
/// 3. Default: `~/.ghosthub/`
///
/// This is intentionally separate from `ConfigHome`: configuration
/// remains under `~/.config/ghosthub`, while mutable app-owned state lives
/// under `~/.ghosthub`.
public enum StateHome {
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let statePath = environment["GHOSTHUB_STATE_HOME"],
           !statePath.isEmpty {
            return URL(
                fileURLWithPath: statePath, isDirectory: true
            )
        }
        if let homePath = environment["GHOSTHUB_HOME"],
           !homePath.isEmpty {
            return URL(
                fileURLWithPath: homePath, isDirectory: true
            ).appendingPathComponent("state", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghosthub", isDirectory: true)
    }

    public static func defaultWorktreesDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        resolved(
            environment: environment, fileManager: fileManager
        ).appendingPathComponent("worktrees", isDirectory: true)
    }
}
