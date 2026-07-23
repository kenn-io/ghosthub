import Foundation

public enum LibghosttyRuntimePhase: Equatable, Sendable {
    case unavailable
    case loadingConfig
    case ready
    case failed(String)
}

public struct LibghosttyConfigPaths: Equatable, Sendable {
    public var configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public static var live: Self {
        if let envPath = ProcessInfo.processInfo
            .environment["GHOSTHUB_CONFIG_HOME"],
            !envPath.isEmpty,
            envPath.hasPrefix("/") {
            return Self(
                configDirectory: URL(
                    fileURLWithPath: envPath,
                    isDirectory: true
                )
            )
        }

        let home = FileManager.default
            .homeDirectoryForCurrentUser
        let defaultDir = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghosthub", isDirectory: true)

        if let redirect = resolveInitTomlRedirect(
            in: defaultDir
        ) {
            return Self(configDirectory: redirect)
        }

        return Self(configDirectory: defaultDir)
    }

    static func resolveInitTomlRedirect(
        in directory: URL
    ) -> URL? {
        let initURL = directory.appendingPathComponent(
            "init.toml", isDirectory: false
        )
        guard let contents = try? String(
            contentsOf: initURL, encoding: .utf8
        ) else {
            return nil
        }

        for line in contents.split(
            whereSeparator: \.isNewline
        ) {
            let trimmed = line
                .trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"),
                  trimmed.hasPrefix("config_home")
            else { continue }

            let afterKey = trimmed
                .dropFirst("config_home".count)
                .trimmingCharacters(in: .whitespaces)
            guard afterKey.hasPrefix("=") else { continue }

            var raw = afterKey.dropFirst()
                .trimmingCharacters(in: .whitespaces)

            // Strip inline TOML comments to match ConfigHome and Go
            // resolver behavior.
            raw = Self.stripInlineComment(raw)

            let value: String
            if raw.hasPrefix("\""),
               raw.hasSuffix("\""),
               raw.count >= 2 {
                value = String(raw.dropFirst().dropLast())
            } else if raw.hasPrefix("'"),
                      raw.hasSuffix("'"),
                      raw.count >= 2 {
                value = String(raw.dropFirst().dropLast())
            } else {
                value = raw
            }
            guard !value.isEmpty,
                  value.hasPrefix("/")
            else { return nil }
            return URL(
                fileURLWithPath: value,
                isDirectory: true
            )
        }
        return nil
    }

    public var globalConfigFile: URL {
        configDirectory.appendingPathComponent("ghostty.conf", isDirectory: false)
    }

    public var terminalAppearanceConfigFile: URL {
        configDirectory.appendingPathComponent(
            "terminal-appearance.conf",
            isDirectory: false
        )
    }

    public func projectConfigFile(for projectRoot: URL) -> URL {
        projectRoot
            .appendingPathComponent(".ghosthub", isDirectory: true)
            .appendingPathComponent("terminal.conf", isDirectory: false)
    }

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

public struct LibghosttyConfigLoadPlan: Equatable, Sendable {
    public var globalConfigFile: URL
    public var projectConfigFile: URL?
    public var terminalAppearanceConfigFile: URL?
    public var orderedConfigFiles: [URL]
    public var createdGlobalConfig: Bool

    public init(
        globalConfigFile: URL,
        projectConfigFile: URL?,
        terminalAppearanceConfigFile: URL?,
        orderedConfigFiles: [URL],
        createdGlobalConfig: Bool
    ) {
        self.globalConfigFile = globalConfigFile
        self.projectConfigFile = projectConfigFile
        self.terminalAppearanceConfigFile = terminalAppearanceConfigFile
        self.orderedConfigFiles = orderedConfigFiles
        self.createdGlobalConfig = createdGlobalConfig
    }
}

public enum LibghosttyConfigPipelineError: LocalizedError, Equatable {
    case createConfigDirectory(URL, String)
    case writeDefaultConfig(URL, String)

    public var errorDescription: String? {
        switch self {
        case let .createConfigDirectory(url, message):
            return "Failed to create Ghosthub terminal config directory at \(url.path): \(message)"
        case let .writeDefaultConfig(url, message):
            return "Failed to write default Ghosthub terminal config at \(url.path): \(message)"
        }
    }
}

public struct LibghosttyConfigPipeline {
    public static let defaultGlobalConfigContents = """
    # ~/.config/ghosthub/ghostty.conf
    # Terminal configuration for Ghosthub (standard Ghostty config format)

    font-family = Berkeley Mono
    font-size = 13
    theme = dark:ghostty,light:ghostty-light
    background-opacity = 0.95
    scrollback-limit = 50000000
    term = xterm-256color
    cursor-style = block
    mouse-hide-while-typing = true
    copy-on-select = clipboard
    macos-option-as-alt = true
    shell-integration = detect

    # Ghosthub handles its own keybindings for splits, tabs, and navigation.
    # Terminal-level keybindings (e.g., for shell interaction) go here.
    """

    public static var live: Self {
        Self(paths: .live)
    }

    public var paths: LibghosttyConfigPaths
    public var fileManager: FileManager

    public init(paths: LibghosttyConfigPaths = .live, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    public func prepareGlobalConfig() throws -> Bool {
        let configFile = paths.globalConfigFile
        if fileManager.fileExists(atPath: configFile.path) {
            ensureManagedDefaults(in: configFile)
            return false
        }

        do {
            try fileManager.createDirectory(
                at: paths.configDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw LibghosttyConfigPipelineError.createConfigDirectory(
                paths.configDirectory,
                error.localizedDescription
            )
        }

        do {
            try Self.defaultGlobalConfigContents.write(
                to: configFile,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            throw LibghosttyConfigPipelineError.writeDefaultConfig(
                configFile,
                error.localizedDescription
            )
        }

        return true
    }

    private func ensureManagedDefaults(in configFile: URL) {
        let contents: String
        do {
            contents = try String(
                contentsOf: configFile, encoding: .utf8
            )
        } catch {
            return
        }

        let defaults: [(key: String, value: String)] = [
            ("scrollback-limit", "50000000"),
            ("term", "xterm-256color"),
            ("macos-option-as-alt", "true"),
            ("shell-integration", "detect"),
        ]

        let missingDefaults = defaults.filter { setting in
            !configContainsKey(setting.key, in: contents)
        }
        guard !missingDefaults.isEmpty else {
            return
        }

        var updated = contents
        if !updated.hasSuffix("\n") {
            updated.append("\n")
        }
        updated.append("\n")
        for setting in missingDefaults {
            updated.append("\(setting.key) = \(setting.value)\n")
        }

        try? updated.write(
            to: configFile, atomically: true, encoding: .utf8
        )
    }

    private func configContainsKey(
        _ key: String, in contents: String
    ) -> Bool {
        contents
            .split(whereSeparator: \.isNewline)
            .contains { rawLine in
                configValue(for: key, in: String(rawLine)) != nil
            }
    }

    private func configValue(
        for key: String,
        in line: String
    ) -> String? {
        let trimmed = line.trimmingCharacters(
            in: .whitespaces
        )
        guard !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(
            separator: "=",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return nil }
        guard parts[0].trimmingCharacters(
            in: .whitespaces
        ) == key else {
            return nil
        }
        return parts[1].trimmingCharacters(
            in: .whitespaces
        )
    }

    public func loadPlan(projectRoot: URL? = nil) throws -> LibghosttyConfigLoadPlan {
        let createdGlobalConfig = try prepareGlobalConfig()
        let projectConfigFile = projectRoot.map(paths.projectConfigFile(for:))
        let existingProjectConfig = projectConfigFile.flatMap { candidate in
            fileManager.fileExists(atPath: candidate.path) ? candidate : nil
        }
        let appearanceConfigFile = paths.terminalAppearanceConfigFile
        let existingAppearanceConfig = fileManager.fileExists(
            atPath: appearanceConfigFile.path
        ) ? appearanceConfigFile : nil

        var orderedConfigFiles = [paths.globalConfigFile]
        if let existingProjectConfig {
            orderedConfigFiles.append(existingProjectConfig)
        }
        if let existingAppearanceConfig {
            orderedConfigFiles.append(existingAppearanceConfig)
        }

        return LibghosttyConfigLoadPlan(
            globalConfigFile: paths.globalConfigFile,
            projectConfigFile: existingProjectConfig,
            terminalAppearanceConfigFile: existingAppearanceConfig,
            orderedConfigFiles: orderedConfigFiles,
            createdGlobalConfig: createdGlobalConfig
        )
    }
}
