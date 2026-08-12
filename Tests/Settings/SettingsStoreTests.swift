import Combine
import Foundation
import Testing
@testable import GhosthubTerminalSupport
@testable import GhosthubSettings
import GhosthubWorkspace

@MainActor
final class SettingsStoreTests {
    private let tempRoot: URL
    private let suiteName: String
    private let defaults: UserDefaults
    private let paths: LibghosttyConfigPaths

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString, isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
        let configDir = tempRoot
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghosthub", isDirectory: true)
        paths = LibghosttyConfigPaths(configDirectory: configDir)

        suiteName = "ghosthub.settings.tests.\(UUID().uuidString)"
        defaults = try #require(
            UserDefaults(suiteName: suiteName)
        )
    }

    deinit {
        UserDefaults(suiteName: suiteName)?
            .removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Fixture Helpers

    private func makeSUT() -> SettingsStore {
        SettingsStore(
            configPipeline: LibghosttyConfigPipeline(paths: paths),
            userDefaults: defaults
        )
    }

    private func writeAppConfig(toml: String) throws {
        try FileManager.default.createDirectory(
            at: paths.configDirectory,
            withIntermediateDirectories: true
        )
        let configToml = paths.configDirectory
            .appendingPathComponent("config.toml")
        try toml.write(
            to: configToml, atomically: true, encoding: .utf8
        )
    }

    private func writeGlobalConfig(_ content: String) throws {
        try FileManager.default.createDirectory(
            at: paths.configDirectory,
            withIntermediateDirectories: true
        )
        try content.write(
            to: paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
    }

    private func readAppConfig() throws -> String {
        let configToml = paths.configDirectory
            .appendingPathComponent("config.toml")
        return try String(contentsOf: configToml, encoding: .utf8)
    }

    private func readGlobalConfig() throws -> String {
        try String(
            contentsOf: paths.globalConfigFile, encoding: .utf8
        )
    }

    private func readTerminalAppearanceConfig() throws -> String {
        try String(
            contentsOf: paths.terminalAppearanceConfigFile,
            encoding: .utf8
        )
    }

    private func assertFileContains(
        _ content: String,
        at url: URL,
        message: @autoclosure () -> String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let renderedMessage = message()
        if !text.contains(content) {
            Issue.record(
                Comment(rawValue: renderedMessage.isEmpty
                    ? "Expected \(url.path) to contain '\(content)'."
                    : renderedMessage),
                sourceLocation: sourceLocation
            )
        }
        #expect(text.contains(content), sourceLocation: sourceLocation)
    }

    private func assertContainsAll(
        _ text: String,
        _ substrings: String...,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for substring in substrings {
            #expect(
                text.contains(substring),
                "Expected text to contain '\(substring)'",
                sourceLocation: sourceLocation
            )
        }
    }

    private func extractManagedBlock(
        from contents: String
    ) -> String {
        contents.components(
            separatedBy: "# >>> Ghosthub managed terminal settings >>>"
        ).last?.components(
            separatedBy: "# <<< Ghosthub managed terminal settings <<<"
        ).first ?? ""
    }

    // MARK: - Tests

    @Test("session previews default to off and persist stable raw values")
    func sessionPreviewModePersistence() {
        let store = makeSUT()

        #expect(store.sessionPreviewMode == .off)

        for mode in SessionPreviewMode.allCases {
            store.setSessionPreviewMode(mode)
            #expect(makeSUT().sessionPreviewMode == mode)
        }
    }

    @Test("unknown session preview modes fall back to off")
    func unknownSessionPreviewModeFallsBackToOff() {
        defaults.set(
            "future-mode",
            forKey: "ghosthub.settings.terminal.sessionPreviewMode"
        )

        #expect(makeSUT().sessionPreviewMode == .off)
    }

    @Test
    func testLoadingDefaultsReflectsGhosthubTerminalDefaults() {
        let store = makeSUT()

        #expect(store.interfaceAppearance == .system)
        #expect(store.notificationConfiguration.showMacOSNotifications)
        #expect(
            store.notificationConfiguration.attentionSound
                == .systemDefault
        )
        #expect(store.terminalPreferences.cursorStyle == .block)
        #expect(!store.terminalPreferences.allowShellIntegrationToControlCursor)
        #expect(store.terminalPreferences.hideMouseWhileTyping)
        #expect(store.terminalPreferences.copySelectionToClipboard)
        #expect(store.terminalPreferences.showPaneResourceUsage)
        #expect(
            store.terminalAppearancePreferences
                == SettingsStore.defaultTerminalAppearancePreferences
        )
        #expect(
            !store.terminalAppearancePreferences
                .appliesThemeToTmuxSessions
        )
        #expect(!store.worktreePreferences.hideRootCheckout)
        #expect(store.worktreePreferences.hideKwtManagedSessions)
        #expect(store.tmuxSessionPreferences.hiddenSessionPatterns.isEmpty)
        #expect(store.shareAnonymousUsageData)
        #expect(
            store.shortcutPreferences.resolved
                == ApplicationShortcutCatalog.compiledDefaults
        )
    }

    @Test("startup uses defaults and reports invalid shortcut config")
    func invalidStartupShortcutConfigUsesDefaults() throws {
        try writeAppConfig(toml: """
        [keyboard.shortcuts]
        next-sibling = "shift+tab"
        """)

        let store = makeSUT()

        #expect(
            store.shortcutPreferences.resolved
                == ApplicationShortcutCatalog.compiledDefaults
        )
        #expect(store.shortcutConfigurationIssue?.action == .nextSibling)

        #expect(store.setShortcutOverrides(
            store.shortcutPreferences.overrides
        ))
        #expect(try !readAppConfig().contains("next-sibling"))
        #expect(store.shortcutConfigurationIssue == nil)
    }

    @Test("invalid live reload retains the last valid registry")
    func invalidLiveReloadRetainsShortcuts() throws {
        try writeAppConfig(toml: """
        [keyboard.shortcuts]
        next-sibling = "cmd+k"
        """)
        let store = makeSUT()
        let valid = store.shortcutPreferences
        try writeAppConfig(toml: """
        [keyboard.shortcuts]
        next-sibling = 42
        """)

        store.reloadShortcutConfiguration()

        #expect(store.shortcutPreferences == valid)
        #expect(store.shortcutConfigurationIssue?.action == .nextSibling)
    }

    @Test("shortcut persistence validates before changing disk or state")
    func invalidShortcutPersistenceIsAtomic() throws {
        try writeAppConfig(toml: """
        [keyboard.shortcuts]
        future-action = "future"
        """)
        let store = makeSUT()
        let original = try readAppConfig()
        let originalPreferences = store.shortcutPreferences

        let didPersist = store.setShortcutOverrides([
            .nextSibling: .binding(
                try ApplicationKeyBinding(parsing: "cmd+k")
            ),
            .previousSibling: .binding(
                try ApplicationKeyBinding(parsing: "cmd+k")
            ),
        ])

        #expect(!didPersist)
        #expect(try readAppConfig() == original)
        #expect(store.shortcutPreferences == originalPreferences)
    }

    @Test("shortcut persistence writes normalized values once")
    func persistsShortcutOverrides() throws {
        try writeAppConfig(toml: """
        [keyboard.shortcuts]
        next-sibling = "ctrl+tab"
        future-action = "future"
        """)
        let store = makeSUT()

        let didPersist = store.setShortcutOverrides([
            .nextSibling: .binding(
                try ApplicationKeyBinding(parsing: "CMD+K")
            ),
            .splitRight: .unbound,
        ])

        #expect(didPersist)
        #expect(store.shortcutConfigurationIssue == nil)
        let contents = try readAppConfig()
        #expect(contents.contains("next-sibling = \"cmd+k\""))
        #expect(contents.contains("split-right = \"none\""))
        #expect(contents.contains("future-action = \"future\""))
    }

    @Test("quit confirmation is enabled by default")
    func quitConfirmationDefaultsToEnabled() {
        #expect(makeSUT().confirmBeforeQuitting)
    }

    @Test("quit confirmation preference persists")
    func quitConfirmationPreferencePersists() {
        let store = makeSUT()
        store.setConfirmBeforeQuitting(false)

        let reloaded = makeSUT()

        #expect(!reloaded.confirmBeforeQuitting)
    }

    @Test("duplicate exe.dev destinations remain available for correction")
    func duplicateExeDestinationsRemainInSettings() {
        let accounts = [
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev"
            ),
            ExeAccount(
                configKey: "work",
                name: "Work",
                sshDestination: "exe.dev"
            ),
        ]
        makeSUT().setExeAccounts(accounts)

        let reloaded = makeSUT()

        #expect(reloaded.exeAccounts == accounts)
        #expect(
            ExeAccountSanitizer.discoverableAccounts(
                reloaded.exeAccounts
            ).isEmpty
        )
    }

    @Test
    func exeAccountsStoredBeforeTagFiltersStillLoad() {
        let legacy = Data("""
        [{"configKey":"personal","name":"Personal","sshDestination":"exe.dev","isEnabled":true}]
        """.utf8)
        defaults.set(legacy, forKey: "ghosthub.settings.hosts.exeAccounts")

        #expect(makeSUT().exeAccounts == [ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )])
    }

    @Test
    func exeAccountTagFiltersSurviveAReload() {
        makeSUT().setExeAccounts([ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev",
            tagFilter: "dev, prod"
        )])

        #expect(makeSUT().exeAccounts.first?.tagFilter == "dev, prod")
    }

    @Test
    func testLoadingHiddenTmuxSessionPatternsFromAppConfig() throws {
        try writeAppConfig(toml: """
        [tmux]
        hidden_session_patterns = ["forge-*", "scratch-?"]
        """)

        let store = makeSUT()

        #expect(
            store.tmuxSessionPreferences.hiddenSessionPatterns
                == ["forge-*", "scratch-?"]
        )
    }

    @Test
    func testUpdatingHiddenTmuxSessionPatternsPreservesAppConfig() throws {
        try writeAppConfig(toml: """
        [general]
        default_shell = "/bin/bash"
        """)
        let store = makeSUT()

        store.setHiddenTmuxSessionPatterns([
            " forge-* ", "", "scratch-?", "forge-*",
        ])

        #expect(
            store.tmuxSessionPreferences.hiddenSessionPatterns
                == ["forge-*", "scratch-?"]
        )
        let contents = try readAppConfig()
        #expect(contents.contains("default_shell = \"/bin/bash\""))

        let reloaded = makeSUT()
        #expect(
            reloaded.tmuxSessionPreferences.hiddenSessionPatterns
                == ["forge-*", "scratch-?"]
        )
    }

    @Test
    func testUnchangedHiddenTmuxSessionPatternsDoNotCreateAppConfig() {
        let store = makeSUT()

        store.setHiddenTmuxSessionPatterns([])

        #expect(
            !FileManager.default.fileExists(
                atPath: store.appConfigFile.path
            )
        )
    }

    @Test
    func testFailedHiddenTmuxSessionPatternWriteCanBeRetried() throws {
        try FileManager.default.createDirectory(
            at: paths.configDirectory,
            withIntermediateDirectories: true
        )
        let configFile = paths.configDirectory
            .appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: configFile,
            withIntermediateDirectories: false
        )
        let store = makeSUT()

        #expect(!store.setHiddenTmuxSessionPatterns(["forge-*"]))
        #expect(store.tmuxSessionPreferences.hiddenSessionPatterns.isEmpty)
        #expect(store.lastErrorMessage != nil)

        try FileManager.default.removeItem(at: configFile)
        #expect(store.setHiddenTmuxSessionPatterns(["forge-*"]))
        #expect(
            store.tmuxSessionPreferences.hiddenSessionPatterns
                == ["forge-*"]
        )
        #expect(store.lastErrorMessage == nil)
    }

    @Test
    func testRefreshingAnonymousUsageDataReadsPersistedPreference() {
        let store = makeSUT()
        let otherStore = makeSUT()

        otherStore.setShareAnonymousUsageData(false)

        #expect(store.shareAnonymousUsageData)
        #expect(!store.refreshShareAnonymousUsageData())
        #expect(!store.shareAnonymousUsageData)
    }

    @Test
    func testUpdatingTerminalPreferencesWritesManagedConfigBlock() throws {
        let store = makeSUT()

        store.setCursorStyle(.underline)
        store.setAllowShellIntegrationToControlCursor(false)
        store.setHideMouseWhileTyping(false)
        store.setCopySelectionToClipboard(false)
        store.setShowPaneResourceUsage(false)

        let contents = try readGlobalConfig()

        assertContainsAll(
            contents,
            "# >>> Ghosthub managed terminal settings >>>",
            "term = xterm-256color",
            "cursor-style = underline",
            "mouse-hide-while-typing = false",
            "copy-on-select = false",
            "shell-integration = detect",
            "shell-integration-features = no-cursor"
        )

        // macos-option-as-alt = true exists from the default config
        // template but is NOT in the managed block, so user overrides
        // placed outside the managed section survive rewrites.
        #expect(contents.contains("macos-option-as-alt = true"))
        let managedBlock = extractManagedBlock(from: contents)
        #expect(managedBlock.contains("macos-option-as-alt") == false)
        #expect(managedBlock.contains("shell-integration-features = no-cursor"))
        #expect(!store.terminalPreferences.showPaneResourceUsage)
        #expect(store.lastErrorMessage == nil)
    }

    @Test
    func testUpdatingTerminalAppearanceWritesOverlayWithoutMutatingConfig() throws {
        let store = makeSUT()

        store.setTerminalTheme(.homebrew)
        store.setUseCustomTerminalFont(true)
        store.setTerminalFontFamily("Monaco")
        store.setTerminalFontSize(14.5)

        let overlay = try readTerminalAppearanceConfig()
        let globalConfig = try readGlobalConfig()

        assertContainsAll(
            overlay,
            "font-family = \"Monaco\"",
            "font-size = 14.5"
        )
        #expect(!overlay.contains("background = "))
        #expect(!overlay.contains("foreground = "))

        assertContainsAll(
            globalConfig,
            "font-family = Berkeley Mono"
        )
        #expect(globalConfig.contains("theme =") == false)
        #expect(globalConfig.contains("background = #000000") == false)
        #expect(globalConfig.contains("font-family = \"Monaco\"") == false)
    }

    @Test
    func testTmuxThemeDoesNotCreateTerminalAppearanceOverlay() {
        let store = makeSUT()

        store.setTerminalTheme(.ocean)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.terminalAppearanceConfigFile.path
            ) == false
        )

        store.setUseCustomTerminalFont(true)
        #expect(FileManager.default.fileExists(
            atPath: paths.terminalAppearanceConfigFile.path
        ))
    }

    @Test
    func testWorktreePreferencesPersistAcrossStoreReload() {
        let pipeline = LibghosttyConfigPipeline(paths: paths)
        let store = SettingsStore(
            configPipeline: pipeline,
            userDefaults: defaults
        )

        store.setInterfaceAppearance(.dark)
        store.setShowMacOSNotifications(false)
        store.setNotificationAttentionSound(.glass)
        store.setShareAnonymousUsageData(false)
        store.setHideRootCheckout(true)
        store.setShowHiddenWorktreesByDefault(true)
        store.setHideKwtManagedSessions(false)
        store.setShowPaneResourceUsage(false)
        store.setTerminalTheme(.clearDark)
        store.setTerminalThemeAppliesToTmuxSessions(true)
        store.setUseCustomTerminalFont(true)
        store.setTerminalFontFamily("Monaco")
        store.setTerminalFontSize(15.5)
        let reloaded = SettingsStore(
            configPipeline: pipeline,
            userDefaults: defaults
        )

        #expect(reloaded.interfaceAppearance == .dark)
        #expect(!reloaded.notificationConfiguration.showMacOSNotifications)
        #expect(reloaded.notificationConfiguration.attentionSound == .glass)
        #expect(!reloaded.shareAnonymousUsageData)
        #expect(reloaded.worktreePreferences.hideRootCheckout)
        #expect(reloaded.worktreePreferences.showHiddenWorktreesByDefault)
        #expect(!reloaded.worktreePreferences.hideKwtManagedSessions)
        #expect(!reloaded.terminalPreferences.showPaneResourceUsage)
        #expect(reloaded.terminalAppearancePreferences.theme == .clearDark)
        #expect(
            reloaded.terminalAppearancePreferences
                .appliesThemeToTmuxSessions
        )
        #expect(reloaded.terminalAppearancePreferences.usesCustomFont)
        #expect(reloaded.terminalAppearancePreferences.fontFamily == "Monaco")
        #expect(reloaded.terminalAppearancePreferences.fontSize == 15.5)
    }

    @Test
    func testUpdatingInterfaceAppearanceDoesNotTouchAppConfigToml() throws {
        try writeAppConfig(toml: """
        [general]
        default_shell = "/bin/bash"
        """)

        let store = makeSUT()
        store.setInterfaceAppearance(.light)

        // Appearance remains in UserDefaults. config.toml owns only explicit
        // file-backed settings such as standalone tmux session visibility.
        let contents = try readAppConfig()
        #expect(contents.contains("appearance") == false)

        let reloaded = makeSUT()
        #expect(reloaded.interfaceAppearance == .light)
    }

    @Test
    func testNotificationPreferencesPersistInUserDefaults() {
        let store = makeSUT()
        store.setShowMacOSNotifications(false)
        store.setNotificationAttentionSound(.glass)

        #expect(
            !store.notificationConfiguration.showMacOSNotifications
        )
        #expect(!store.notificationConfiguration.showDockBadge)

        let reloaded = makeSUT()
        #expect(
            !reloaded.notificationConfiguration
                .showMacOSNotifications
        )
        #expect(
            reloaded.notificationConfiguration.attentionSound
                == .glass
        )
    }

    @Test
    func testSSHHostConfigurationPersistsOutsideAppConfig() throws {
        try writeAppConfig(toml: """
        [[hosts]]
        config_key = "local"
        name = "This Mac"
        workspace_root = "/Users/wesm/code"

        [general]
        appearance = "system"
        """)

        let store = makeSUT()
        store.setSSHHosts([
            SSHHost(
                configKey: "office",
                name: "Office Studio",
                platform: .linux,
                sshDestination: "office"
            ),
        ])

        let contents = try readAppConfig()
        #expect(contents.contains("config_key = \"local\""))
        #expect(contents.contains("workspace_root = \"/Users/wesm/code\""))
        #expect(!contents.contains("config_key = \"office\""))
        #expect(store.lastErrorMessage == nil)
        let reloaded = makeSUT()
        #expect(reloaded.sshHosts.map(\.configKey) == ["office"])
    }

    @Test
    func testSSHHostsIgnoreLegacyAppConfig() throws {
        try writeAppConfig(toml: """
        # >>> Ghosthub managed remote hosts >>>
        [[hosts]]
        config_key = "office"
        name = "Office Studio"
        platform = "linux"
        ssh_destination = ["not", "valid"]
        # <<< Ghosthub managed remote hosts <<<
        """)

        let store = makeSUT()

        #expect(store.sshHosts.isEmpty)
    }

    @Test
    func testSSHHostConfigurationPersistsLocally() {
        let store = makeSUT()
        store.setSSHHosts([
            SSHHost(
                configKey: "office",
                name: "Office Studio",
                platform: .macOS,
                sshDestination: "wesm@office-studio"
            ),
            SSHHost(
                configKey: "lab",
                name: "Lab Box",
                platform: .linux,
                sshDestination: "lab-box"
            ),
        ])

        let reloaded = makeSUT()
        let hostUpdates = reloaded.sshHosts
        #expect(hostUpdates.count == 2)
        #expect(hostUpdates[0].configKey == "office")
        #expect(hostUpdates[0].sshDestination == "wesm@office-studio")
        #expect(store.sshHosts.count == 2)
    }

    @Test
    func testAllowingShellIntegrationToControlCursorPreservesManualValue() throws {
        try writeGlobalConfig("""
        shell-integration-features = title,cursor
        """)

        let store = makeSUT()
        #expect(
            store.terminalPreferences.allowShellIntegrationToControlCursor
        )

        store.setCursorStyle(.underline)

        let contents = try readGlobalConfig()
        #expect(contents.contains("shell-integration-features = title,cursor"))
        let managedBlock = extractManagedBlock(from: contents)
        #expect(managedBlock.contains("shell-integration-features") == false)
    }

    @Test
    func testAllowingShellIntegrationToControlCursorRemovesLegacyManagedNoCursorOverride() throws {
        try writeGlobalConfig("""
        shell-integration = detect

        # >>> Ghosthub managed terminal settings >>>
        cursor-style = block
        shell-integration-features = no-cursor
        # <<< Ghosthub managed terminal settings <<<
        """)

        let store = makeSUT()
        #expect(
            store.terminalPreferences.allowShellIntegrationToControlCursor == false
        )

        store.setAllowShellIntegrationToControlCursor(true)

        let contents = try readGlobalConfig()
        #expect(contents.contains("shell-integration-features = no-cursor") == false)
        let managedBlock = extractManagedBlock(from: contents)
        #expect(managedBlock.contains("shell-integration-features") == false)
        #expect(contents.contains("shell-integration = detect"))
    }

    @Test
    func testAllowingShellIntegrationToControlCursorPreservesManualNoCursorOverrideOutsideManagedBlock(
    ) throws {
        try writeGlobalConfig("""
        shell-integration = detect
        shell-integration-features = no-cursor
        """)

        let store = makeSUT()
        store.setAllowShellIntegrationToControlCursor(true)

        let contents = try readGlobalConfig()
        #expect(contents.contains("shell-integration-features = no-cursor"))
        let managedBlock = extractManagedBlock(from: contents)
        #expect(managedBlock.contains("shell-integration-features") == false)
    }

    @Test
    func testHideRootCheckoutPublishesUpdatedPreferences() {
        let store = makeSUT()
        var receivedHideRootCheckout = false

        let cancellable = store.$worktreePreferences
            .dropFirst()
            .sink { preferences in
                if preferences.hideRootCheckout {
                    receivedHideRootCheckout = true
                }
            }

        store.setHideRootCheckout(true)

        withExtendedLifetime(cancellable) {
            #expect(receivedHideRootCheckout)
        }
        #expect(store.worktreePreferences.hideRootCheckout)
    }

    @Test
    func testManagedBlockOverridesTrailingManualSettings() throws {
        let pipeline = LibghosttyConfigPipeline(paths: paths)

        // Bootstrap the config file with a managed block, then
        // append a manual override after it.
        let store = SettingsStore(
            configPipeline: pipeline,
            userDefaults: defaults
        )
        store.setCursorStyle(.bar)

        var contents = try readGlobalConfig()
        contents.append("\ncursor-style = underline\n")
        try contents.write(
            to: paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )

        // Now update cursor style through the store again. The
        // managed block should be appended at EOF so it wins over
        // the manual override.
        store.setCursorStyle(.block)

        let updatedContents = try readGlobalConfig()

        // The managed block must appear after the manual override.
        let managedRange = try #require(
            updatedContents.range(of: "# >>> Ghosthub managed terminal settings >>>")
        )
        let manualRange = try #require(
            updatedContents.range(of: "cursor-style = underline")
        )

        #expect(managedRange.lowerBound > manualRange.lowerBound)

        // Reload should read the managed value (last-wins = block).
        let reloaded = SettingsStore(
            configPipeline: pipeline,
            userDefaults: defaults
        )
        #expect(reloaded.terminalPreferences.cursorStyle == .block)
    }

    @Test
    func testEnablingFontOverrideSeedsFromTerminalConfig() throws {
        try writeGlobalConfig("""
        font-family = JetBrains Mono
        font-size = 16
        """)

        let store = makeSUT()

        #expect(
            store.terminalAppearancePreferences.fontFamily
                == "Berkeley Mono"
        )
        #expect(
            store.terminalAppearancePreferences.fontSize == 13
        )

        store.setUseCustomTerminalFont(true)

        #expect(
            store.terminalAppearancePreferences.fontFamily
                == "JetBrains Mono"
        )
        #expect(
            store.terminalAppearancePreferences.fontSize == 16
        )

        let overlay = try readTerminalAppearanceConfig()
        #expect(overlay.contains("font-family = \"JetBrains Mono\""))
        #expect(overlay.contains("font-size = 16"))
    }

    @Test
    func testEnablingFontOverrideSeedsFromQuotedTerminalConfig() throws {
        try writeGlobalConfig("""
        font-family = "Fira Code"
        font-size = 14
        """)

        let store = makeSUT()
        store.setUseCustomTerminalFont(true)

        #expect(
            store.terminalAppearancePreferences.fontFamily
                == "Fira Code"
        )
        #expect(
            store.terminalAppearancePreferences.fontSize == 14
        )

        let overlay = try readTerminalAppearanceConfig()
        #expect(overlay.contains("font-family = \"Fira Code\""))
    }

    @Test
    func testEnablingFontOverrideSeedsFromSingleQuotedTerminalConfig() throws {
        try writeGlobalConfig("""
        font-family = 'IBM Plex Mono'
        font-size = 15
        """)

        let store = makeSUT()
        store.setUseCustomTerminalFont(true)

        #expect(
            store.terminalAppearancePreferences.fontFamily
                == "IBM Plex Mono"
        )
        #expect(
            store.terminalAppearancePreferences.fontSize == 15
        )
    }

}
