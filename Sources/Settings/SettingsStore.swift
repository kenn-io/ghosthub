import Combine
import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace

private extension Double {
    var roundedFontSize: Double {
        (self * 2.0).rounded() / 2.0
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    private enum DefaultsKey {
        static let showPaneResourceUsage = "ghosthub.settings.terminal.showPaneResourceUsage"
        static let confirmPaneClose = "ghosthub.settings.terminal.confirmPaneClose"
        static let confirmBeforeQuitting =
            "ghosthub.settings.application.confirmBeforeQuitting"
        static let hideRootCheckout = "ghosthub.settings.worktrees.hideRootCheckout"
        static let showHiddenWorktreesByDefault = "ghosthub.settings.worktrees.showHiddenWorktreesByDefault"
        static let hideKwtManagedSessions =
            "ghosthub.settings.worktrees.hideKwtManagedSessions"
        static let interfaceAppearance = "ghosthub.settings.appearance.interfaceAppearance"
        static let showMacOSNotifications =
            "ghosthub.settings.notifications.showMacOSNotifications"
        static let attentionSound =
            "ghosthub.settings.notifications.attentionSound"
        static let shareAnonymousUsageData =
            "ghosthub.settings.privacy.shareAnonymousUsageData"
        static let terminalTheme =
            "ghosthub.settings.terminalAppearance.theme"
        static let terminalAppliesThemeToTmuxSessions =
            "ghosthub.settings.terminalAppearance.appliesThemeToTmuxSessions"
        static let terminalUsesCustomFont =
            "ghosthub.settings.terminalAppearance.usesCustomFont"
        static let terminalFontFamily =
            "ghosthub.settings.terminalAppearance.fontFamily"
        static let terminalFontSize =
            "ghosthub.settings.terminalAppearance.fontSize"
        static let sshHosts = "ghosthub.settings.hosts.ssh"
        static let exeAccounts = "ghosthub.settings.hosts.exeAccounts"
    }

    public static let shared = SettingsStore(
        configPipeline: LibghosttyConfigPipeline(
            paths: LibghosttyConfigPaths(
                configDirectory: ConfigHome.resolved()
            )
        )
    )

    public static let defaultTerminalPreferences = TerminalPreferences(
        cursorStyle: .block,
        allowShellIntegrationToControlCursor: false,
        hideMouseWhileTyping: true,
        copySelectionToClipboard: true,
        showPaneResourceUsage: true,
        confirmPaneClose: true
    )

    public static let defaultTerminalAppearancePreferences =
        TerminalAppearancePreferences(
            theme: .followConfig,
            appliesThemeToTmuxSessions: false,
            usesCustomFont: false,
            fontFamily: "Berkeley Mono",
            fontSize: 13
        )

    public static let defaultWorktreePreferences = WorktreePreferences(
        hideRootCheckout: false,
        showHiddenWorktreesByDefault: false,
        hideKwtManagedSessions: true
    )

    public static let defaultTmuxSessionPreferences = TmuxSessionPreferences()

    public static let defaultAgentPreferences = AgentPreferences()

    @Published public var selectedDomain: SettingsDomain = .appearance
    @Published public private(set) var confirmBeforeQuitting: Bool
    @Published public private(set) var interfaceAppearance: AppearancePreference
    @Published public private(set) var notificationConfiguration: NotificationsConfiguration
    @Published public private(
        set
    ) var terminalAppearancePreferences: TerminalAppearancePreferences
    @Published public private(set) var terminalPreferences: TerminalPreferences
    @Published public private(set) var worktreePreferences: WorktreePreferences
    @Published public private(set) var tmuxSessionPreferences: TmuxSessionPreferences
    @Published public private(set) var agentPreferences: AgentPreferences
    @Published public private(set) var shareAnonymousUsageData: Bool
    @Published public private(set) var sshHosts: [SSHHost]
    @Published public private(set) var exeAccounts: [ExeAccount]
    @Published public private(set) var lastErrorMessage: String?

    private let configPipeline: LibghosttyConfigPipeline
    private let userDefaults: UserDefaults

    public var terminalConfigFile: URL {
        configPipeline.paths.globalConfigFile
    }

    public var terminalAppearanceConfigFile: URL {
        configPipeline.paths.terminalAppearanceConfigFile
    }

    public var appConfigFile: URL {
        configPipeline.paths.configDirectory.appendingPathComponent(
            "config.toml",
            isDirectory: false
        )
    }

    public init(
        configPipeline: LibghosttyConfigPipeline = .live,
        userDefaults: UserDefaults = .standard
    ) {
        self.configPipeline = configPipeline
        self.userDefaults = userDefaults

        let loadedConfirmBeforeQuitting = Self.loadConfirmBeforeQuitting(
            using: userDefaults
        )
        let loadedAppearance = Self.loadInterfaceAppearance(
            using: userDefaults
        )
        let loadedNotifications = Self.loadNotificationConfiguration(
            using: userDefaults
        )
        let loadedTerminalAppearance =
            Self.loadTerminalAppearancePreferences(
                using: userDefaults
            )
        let loadedTerminal = Self.loadTerminalPreferences(
            using: configPipeline,
            userDefaults: userDefaults
        )
        let loadedWorktrees = Self.loadWorktreePreferences(
            using: userDefaults
        )
        let loadedTmuxSessions = Self.loadTmuxSessionPreferences(
            from: configPipeline.paths.configDirectory.appendingPathComponent(
                "config.toml",
                isDirectory: false
            )
        )
        let loadedAgents = Self.loadAgentPreferences(
            using: userDefaults
        )
        let loadedShareAnonymousUsageData =
            Self.loadShareAnonymousUsageData(
                using: userDefaults
            )
        let loadedSSHHosts = Self.loadSSHHosts(using: userDefaults)
        let loadedExeAccounts = Self.loadExeAccounts(using: userDefaults)

        confirmBeforeQuitting = loadedConfirmBeforeQuitting
        interfaceAppearance = loadedAppearance
        notificationConfiguration = loadedNotifications
        terminalAppearancePreferences = loadedTerminalAppearance
        terminalPreferences = loadedTerminal
        worktreePreferences = loadedWorktrees
        tmuxSessionPreferences = loadedTmuxSessions
        agentPreferences = loadedAgents
        shareAnonymousUsageData = loadedShareAnonymousUsageData
        sshHosts = loadedSSHHosts
        exeAccounts = loadedExeAccounts
        persistTerminalPreferences()
        persistTerminalAppearancePreferences()
    }

    public func reload() {
        confirmBeforeQuitting = Self.loadConfirmBeforeQuitting(
            using: userDefaults
        )
        interfaceAppearance = Self.loadInterfaceAppearance(
            using: userDefaults
        )
        notificationConfiguration =
            Self.loadNotificationConfiguration(
                using: userDefaults
            )
        terminalAppearancePreferences =
            Self.loadTerminalAppearancePreferences(
                using: userDefaults
            )
        terminalPreferences = Self.loadTerminalPreferences(
            using: configPipeline,
            userDefaults: userDefaults
        )
        worktreePreferences = Self.loadWorktreePreferences(using: userDefaults)
        tmuxSessionPreferences = Self.loadTmuxSessionPreferences(
            from: appConfigFile
        )
        agentPreferences = Self.loadAgentPreferences(using: userDefaults)
        shareAnonymousUsageData =
            Self.loadShareAnonymousUsageData(
                using: userDefaults
            )

        sshHosts = Self.loadSSHHosts(using: userDefaults)
        exeAccounts = Self.loadExeAccounts(using: userDefaults)
        lastErrorMessage = nil
    }

    public func setInterfaceAppearance(
        _ appearance: AppearancePreference
    ) {
        interfaceAppearance = appearance
        userDefaults.set(
            appearance.rawValue,
            forKey: DefaultsKey.interfaceAppearance
        )
    }

    public func setConfirmBeforeQuitting(_ enabled: Bool) {
        confirmBeforeQuitting = enabled
        userDefaults.set(
            enabled,
            forKey: DefaultsKey.confirmBeforeQuitting
        )
    }

    public func setShowMacOSNotifications(_ enabled: Bool) {
        var updated = notificationConfiguration
        updated.showMacOSNotifications = enabled
        updated.showDockBadge = enabled
        notificationConfiguration = updated
        userDefaults.set(
            enabled,
            forKey: DefaultsKey.showMacOSNotifications
        )
    }

    public func setNotificationAttentionSound(
        _ sound: WorkspaceNotificationSound
    ) {
        var updated = notificationConfiguration
        updated.attentionSound = sound
        notificationConfiguration = updated
        userDefaults.set(
            sound.rawValue,
            forKey: DefaultsKey.attentionSound
        )
    }

    public func setShareAnonymousUsageData(_ enabled: Bool) {
        shareAnonymousUsageData = enabled
        userDefaults.set(
            enabled,
            forKey: DefaultsKey.shareAnonymousUsageData
        )
    }

    @discardableResult
    public func refreshShareAnonymousUsageData() -> Bool {
        _ = userDefaults.synchronize()
        let enabled = Self.loadShareAnonymousUsageData(
            using: userDefaults
        )
        shareAnonymousUsageData = enabled
        return enabled
    }

    public func setTerminalTheme(_ theme: TerminalTheme) {
        updateTerminalAppearancePreferences { preferences in
            preferences.theme = theme
        }
        persistTerminalAppearanceDefaults()
        persistTerminalAppearancePreferences()
    }

    public func setTerminalThemeAppliesToTmuxSessions(_ enabled: Bool) {
        updateTerminalAppearancePreferences { preferences in
            preferences.appliesThemeToTmuxSessions = enabled
        }
        persistTerminalAppearanceDefaults()
    }

    public func setUseCustomTerminalFont(_ enabled: Bool) {
        updateTerminalAppearancePreferences { preferences in
            preferences.usesCustomFont = enabled
            if enabled {
                seedFontFromTerminalConfig(&preferences)
            }
        }
        persistTerminalAppearanceDefaults()
        persistTerminalAppearancePreferences()
    }

    private func seedFontFromTerminalConfig(
        _ preferences: inout TerminalAppearancePreferences
    ) {
        let defaults = Self.defaultTerminalAppearancePreferences
        let familyIsDefault =
            preferences.fontFamily == defaults.fontFamily
        let sizeIsDefault =
            preferences.fontSize == defaults.fontSize
        guard familyIsDefault || sizeIsDefault else { return }

        guard let contents = try? String(
            contentsOf: terminalConfigFile,
            encoding: .utf8
        ) else { return }

        if familyIsDefault,
           let raw = TOMLConfigParser.parseConfigValue(
               for: "font-family", in: contents
           ) {
            let family = TOMLConfigParser.unquoteTOMLString(raw)
            if !family.isEmpty {
                preferences.fontFamily = family
            }
        }
        if sizeIsDefault,
           let sizeStr = TOMLConfigParser.parseConfigValue(
               for: "font-size", in: contents
           ),
           let size = Double(sizeStr) {
            preferences.fontSize = min(
                max(size.roundedFontSize, 8), 32
            )
        }
    }

    public func setTerminalFontFamily(_ family: String) {
        updateTerminalAppearancePreferences { preferences in
            preferences.fontFamily = family
        }
        persistTerminalAppearanceDefaults()
        persistTerminalAppearancePreferences()
    }

    public func setTerminalFontSize(_ size: Double) {
        updateTerminalAppearancePreferences { preferences in
            preferences.fontSize = min(max(size.roundedFontSize, 8), 32)
        }
        persistTerminalAppearanceDefaults()
        persistTerminalAppearancePreferences()
    }

    public func setCursorStyle(_ cursorStyle: CursorStyle) {
        updateTerminalPreferences { preferences in
            preferences.cursorStyle = cursorStyle
        }
        persistTerminalPreferences()
    }

    public func setAllowShellIntegrationToControlCursor(_ enabled: Bool) {
        updateTerminalPreferences { preferences in
            preferences.allowShellIntegrationToControlCursor = enabled
        }
        persistTerminalPreferences()
    }

    public func setHideMouseWhileTyping(_ enabled: Bool) {
        updateTerminalPreferences { preferences in
            preferences.hideMouseWhileTyping = enabled
        }
        persistTerminalPreferences()
    }

    public func setCopySelectionToClipboard(_ enabled: Bool) {
        updateTerminalPreferences { preferences in
            preferences.copySelectionToClipboard = enabled
        }
        persistTerminalPreferences()
    }

    public func setShowPaneResourceUsage(_ enabled: Bool) {
        updateTerminalPreferences { preferences in
            preferences.showPaneResourceUsage = enabled
        }
        userDefaults.set(enabled, forKey: DefaultsKey.showPaneResourceUsage)
    }

    public func setConfirmPaneClose(_ enabled: Bool) {
        updateTerminalPreferences { preferences in
            preferences.confirmPaneClose = enabled
        }
        userDefaults.set(enabled, forKey: DefaultsKey.confirmPaneClose)
    }

    public func setHideRootCheckout(_ enabled: Bool) {
        updateWorktreePreferences { preferences in
            preferences.hideRootCheckout = enabled
        }
        userDefaults.set(enabled, forKey: DefaultsKey.hideRootCheckout)
    }

    public func setShowHiddenWorktreesByDefault(_ enabled: Bool) {
        updateWorktreePreferences { preferences in
            preferences.showHiddenWorktreesByDefault = enabled
        }
        userDefaults.set(enabled, forKey: DefaultsKey.showHiddenWorktreesByDefault)
    }

    public func setHideKwtManagedSessions(_ enabled: Bool) {
        updateWorktreePreferences { preferences in
            preferences.hideKwtManagedSessions = enabled
        }
        userDefaults.set(enabled, forKey: DefaultsKey.hideKwtManagedSessions)
    }

    @discardableResult
    public func setHiddenTmuxSessionPatterns(_ patterns: [String]) -> Bool {
        let updated = TmuxSessionPreferences(
            hiddenSessionPatterns: Self.normalizedPatterns(patterns)
        )
        guard updated != tmuxSessionPreferences else { return true }
        do {
            try persistTmuxSessionPreferences(updated)
            tmuxSessionPreferences = updated
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    public func setSSHHosts(_ sshHosts: [SSHHost]) {
        self.sshHosts =
            SSHHostSanitizer.sshHosts(sshHosts)
        persistSSHHosts()
    }

    public func setExeAccounts(_ accounts: [ExeAccount]) {
        exeAccounts = ExeAccountSanitizer.storedAccounts(accounts)
        persistExeAccounts()
    }

    private func updateTerminalPreferences(
        _ update: (inout TerminalPreferences) -> Void
    ) {
        var updated = terminalPreferences
        update(&updated)
        terminalPreferences = updated
    }

    private func updateTerminalAppearancePreferences(
        _ update: (inout TerminalAppearancePreferences) -> Void
    ) {
        var updated = terminalAppearancePreferences
        update(&updated)
        terminalAppearancePreferences = updated
    }

    private func updateWorktreePreferences(
        _ update: (inout WorktreePreferences) -> Void
    ) {
        var updated = worktreePreferences
        update(&updated)
        worktreePreferences = updated
    }

    private func updateAgentPreferences(
        _ update: (inout AgentPreferences) -> Void
    ) {
        var updated = agentPreferences
        update(&updated)
        agentPreferences = updated
    }

    private func persistTerminalPreferences() {
        do {
            let didCreate = try configPipeline.prepareGlobalConfig()
            var contents = try String(
                contentsOf: terminalConfigFile,
                encoding: .utf8
            )

            if didCreate, contents.isEmpty {
                contents = LibghosttyConfigPipeline.defaultGlobalConfigContents
            }

            let managedBlock = ManagedBlockEditor.renderManagedTerminalBlock(
                for: terminalPreferences
            )
            contents = ManagedBlockEditor.replacingManagedTerminalBlock(
                in: contents,
                with: managedBlock
            )

            try contents.write(
                to: terminalConfigFile,
                atomically: true,
                encoding: .utf8
            )
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func persistTerminalAppearancePreferences() {
        do {
            try configPipeline.fileManager.createDirectory(
                at: configPipeline.paths.configDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let overlay = ConfigSectionEditor.renderTerminalAppearanceOverlay(
                for: terminalAppearancePreferences
            )
            let overlayFile = terminalAppearanceConfigFile
            if let overlay {
                try overlay.write(
                    to: overlayFile,
                    atomically: true,
                    encoding: .utf8
                )
            } else if configPipeline.fileManager.fileExists(
                atPath: overlayFile.path
            ) {
                try configPipeline.fileManager.removeItem(at: overlayFile)
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Persist the app-native terminal appearance values to
    /// UserDefaults.
    private func persistTerminalAppearanceDefaults() {
        let ta = terminalAppearancePreferences
        userDefaults.set(
            ta.theme.rawValue,
            forKey: DefaultsKey.terminalTheme
        )
        userDefaults.set(
            ta.appliesThemeToTmuxSessions,
            forKey: DefaultsKey.terminalAppliesThemeToTmuxSessions
        )
        userDefaults.set(
            ta.usesCustomFont,
            forKey: DefaultsKey.terminalUsesCustomFont
        )
        userDefaults.set(
            ta.fontFamily,
            forKey: DefaultsKey.terminalFontFamily
        )
        userDefaults.set(
            ta.fontSize.roundedFontSize,
            forKey: DefaultsKey.terminalFontSize
        )
    }

    private func persistSSHHosts() {
        do {
            let data = try JSONEncoder().encode(sshHosts)
            userDefaults.set(data, forKey: DefaultsKey.sshHosts)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func persistExeAccounts() {
        do {
            let data = try JSONEncoder().encode(exeAccounts)
            userDefaults.set(data, forKey: DefaultsKey.exeAccounts)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Could not save exe.dev accounts: \(error.localizedDescription)"
        }
    }

    private func persistTmuxSessionPreferences(
        _ preferences: TmuxSessionPreferences
    ) throws {
        try configPipeline.fileManager.createDirectory(
            at: configPipeline.paths.configDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let contents = if configPipeline.fileManager.fileExists(
            atPath: appConfigFile.path
        ) {
            try String(contentsOf: appConfigFile, encoding: .utf8)
        } else {
            ""
        }
        let updated = AppConfigEditor.replacingStringArray(
            sectionName: "tmux",
            key: "hidden_session_patterns",
            values: preferences.hiddenSessionPatterns,
            in: contents
        )
        try updated.write(
            to: appConfigFile,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func loadSSHHosts(
        using userDefaults: UserDefaults
    ) -> [SSHHost] {
        guard let data = userDefaults.data(forKey: DefaultsKey.sshHosts),
              let hosts = try? JSONDecoder().decode(
                  [SSHHost].self,
                  from: data
              )
        else { return [] }
        return SSHHostSanitizer.sshHosts(hosts)
    }

    private static func loadExeAccounts(
        using userDefaults: UserDefaults
    ) -> [ExeAccount] {
        guard let data = userDefaults.data(forKey: DefaultsKey.exeAccounts),
              let accounts = try? JSONDecoder().decode(
                  [ExeAccount].self,
                  from: data
              )
        else { return [] }
        return ExeAccountSanitizer.storedAccounts(accounts)
    }

    private static func loadTerminalPreferences(
        using configPipeline: LibghosttyConfigPipeline,
        userDefaults: UserDefaults
    ) -> TerminalPreferences {
        let defaults = defaultTerminalPreferences
        let confirmPaneClose = userDefaults.object(
            forKey: DefaultsKey.confirmPaneClose
        ) as? Bool ?? defaults.confirmPaneClose
        let contents: String
        do {
            _ = try configPipeline.prepareGlobalConfig()
            contents = try String(
                contentsOf: configPipeline.paths.globalConfigFile,
                encoding: .utf8
            )
        } catch {
            return TerminalPreferences(
                cursorStyle: defaults.cursorStyle,
                allowShellIntegrationToControlCursor: defaults.allowShellIntegrationToControlCursor,
                hideMouseWhileTyping: defaults.hideMouseWhileTyping,
                copySelectionToClipboard: defaults.copySelectionToClipboard,
                showPaneResourceUsage: defaults.showPaneResourceUsage,
                confirmPaneClose: confirmPaneClose
            )
        }

        let cursorStyle = TOMLConfigParser.parseConfigValue(
            for: "cursor-style",
            in: contents
        )
        .flatMap(CursorStyle.init(rawValue:))
        ?? defaults.cursorStyle
        let allowShellIntegrationToControlCursor =
            TOMLConfigParser.parseShellIntegrationCursorBehavior(
                in: contents
            ) ?? defaults.allowShellIntegrationToControlCursor
        let hideMouseWhileTyping = TOMLConfigParser.parseBoolConfigValue(
            for: "mouse-hide-while-typing",
            in: contents
        ) ?? defaults.hideMouseWhileTyping
        let copySelectionToClipboard = TOMLConfigParser.parseCopyOnSelect(
            in: contents
        ) ?? defaults.copySelectionToClipboard
        let showPaneResourceUsage = userDefaults.object(
            forKey: DefaultsKey.showPaneResourceUsage
        ) as? Bool ?? defaults.showPaneResourceUsage

        return TerminalPreferences(
            cursorStyle: cursorStyle,
            allowShellIntegrationToControlCursor: allowShellIntegrationToControlCursor,
            hideMouseWhileTyping: hideMouseWhileTyping,
            copySelectionToClipboard: copySelectionToClipboard,
            showPaneResourceUsage: showPaneResourceUsage,
            confirmPaneClose: confirmPaneClose
        )
    }

    private static func loadInterfaceAppearance(
        using userDefaults: UserDefaults
    ) -> AppearancePreference {
        userDefaults.string(
            forKey: DefaultsKey.interfaceAppearance
        )
        .flatMap(AppearancePreference.init(rawValue:))
        ?? .system
    }

    private static func loadConfirmBeforeQuitting(
        using userDefaults: UserDefaults
    ) -> Bool {
        userDefaults.object(
            forKey: DefaultsKey.confirmBeforeQuitting
        ) as? Bool ?? true
    }

    private static func loadNotificationConfiguration(
        using userDefaults: UserDefaults
    ) -> NotificationsConfiguration {
        var configuration =
            WorkspaceConfiguration.defaults().notifications
        if let showMacOS = userDefaults.object(
            forKey: DefaultsKey.showMacOSNotifications
        ) as? Bool {
            configuration.showMacOSNotifications = showMacOS
            configuration.showDockBadge = showMacOS
        }
        if let sound = userDefaults.string(
            forKey: DefaultsKey.attentionSound
        )
        .flatMap(WorkspaceNotificationSound.init(rawValue:)) {
            configuration.attentionSound = sound
        }
        return configuration
    }

    private static func loadTerminalAppearancePreferences(
        using userDefaults: UserDefaults
    ) -> TerminalAppearancePreferences {
        var preferences = defaultTerminalAppearancePreferences
        if let theme = userDefaults.string(
            forKey: DefaultsKey.terminalTheme
        )
        .flatMap(TerminalTheme.init(rawValue:)) {
            preferences.theme = theme
        }
        if let appliesThemeToTmuxSessions = userDefaults.object(
            forKey: DefaultsKey.terminalAppliesThemeToTmuxSessions
        ) as? Bool {
            preferences.appliesThemeToTmuxSessions =
                appliesThemeToTmuxSessions
        }
        if let usesCustomFont = userDefaults.object(
            forKey: DefaultsKey.terminalUsesCustomFont
        ) as? Bool {
            preferences.usesCustomFont = usesCustomFont
        }
        if let family = userDefaults.string(
            forKey: DefaultsKey.terminalFontFamily
        ), !family.isEmpty {
            preferences.fontFamily = family
        }
        if let size = userDefaults.object(
            forKey: DefaultsKey.terminalFontSize
        ) as? Double, size > 0 {
            preferences.fontSize = min(
                max(size.roundedFontSize, 8), 32
            )
        }
        return preferences
    }

    private static func loadWorktreePreferences(
        using userDefaults: UserDefaults
    ) -> WorktreePreferences {
        let defaults = defaultWorktreePreferences
        return WorktreePreferences(
            hideRootCheckout: userDefaults.object(
                forKey: DefaultsKey.hideRootCheckout
            ) as? Bool ?? defaults.hideRootCheckout,
            showHiddenWorktreesByDefault: userDefaults.object(
                forKey: DefaultsKey.showHiddenWorktreesByDefault
            ) as? Bool ?? defaults.showHiddenWorktreesByDefault,
            hideKwtManagedSessions: userDefaults.object(
                forKey: DefaultsKey.hideKwtManagedSessions
            ) as? Bool ?? defaults.hideKwtManagedSessions
        )
    }

    private static func loadTmuxSessionPreferences(
        from configFile: URL
    ) -> TmuxSessionPreferences {
        guard let contents = try? String(
            contentsOf: configFile,
            encoding: .utf8
        ),
            let patterns = TOMLConfigParser.parseAppConfigStringArrayValue(
                sectionName: "tmux",
                key: "hidden_session_patterns",
                in: contents
            )
        else {
            return defaultTmuxSessionPreferences
        }
        return TmuxSessionPreferences(
            hiddenSessionPatterns: normalizedPatterns(patterns)
        )
    }

    private static func normalizedPatterns(_ patterns: [String]) -> [String] {
        var seen: Set<String> = []
        return patterns.compactMap { pattern in
            let trimmed = pattern.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }

    private static func loadAgentPreferences(
        using _: UserDefaults
    ) -> AgentPreferences {
        AgentPreferences()
    }

    private static func loadShareAnonymousUsageData(
        using userDefaults: UserDefaults
    ) -> Bool {
        userDefaults.object(
            forKey: DefaultsKey.shareAnonymousUsageData
        ) as? Bool ?? true
    }

}

extension WorkspaceConfiguration {
    /// Build the workspace configuration from the app-native
    /// settings store. Presets remain built in while notification
    /// preferences come from UserDefaults.
    @MainActor
    public static func fromSettings(
        _ store: SettingsStore
    ) -> WorkspaceConfiguration {
        var configuration = WorkspaceConfiguration.defaults()
        configuration.notifications =
            store.notificationConfiguration
        return configuration
    }
}
