import Foundation
import GhosthubWorkspace

public struct SettingsPersistResult: Equatable, Sendable {
    public var shouldRefreshHosts: Bool
    public var shouldReloadTerminalConfig: Bool
    public var didPersistTmuxSessionPatterns: Bool

    public init(
        shouldRefreshHosts: Bool,
        shouldReloadTerminalConfig: Bool,
        didPersistTmuxSessionPatterns: Bool
    ) {
        self.shouldRefreshHosts = shouldRefreshHosts
        self.shouldReloadTerminalConfig = shouldReloadTerminalConfig
        self.didPersistTmuxSessionPatterns = didPersistTmuxSessionPatterns
    }
}

public struct SettingsViewDraft: Equatable {
    public var selectedDomain: SettingsDomain
    public var interfaceAppearance: AppearancePreference
    public var terminalTheme: TerminalTheme
    public var appliesTerminalThemeToTmuxSessions: Bool
    public var usesCustomTerminalFont: Bool
    public var terminalFontFamily: String
    public var terminalFontSize: Double
    public var cursorStyle: CursorStyle
    public var allowShellIntegrationToControlCursor: Bool
    public var hideMouseWhileTyping: Bool
    public var copySelectionToClipboard: Bool
    public var hideRootCheckout: Bool
    public var showHiddenWorktreesByDefault: Bool
    public var hiddenTmuxSessionPatterns: [String]
    public var showMacOSNotifications: Bool
    public var attentionSound: WorkspaceNotificationSound
    public var sshHosts: [SSHHostDraft]
    public var selectedSSHHostDraftID: UUID?

    @MainActor
    public init(store: SettingsStore) {
        let terminal = store.terminalPreferences
        let terminalAppearance = store.terminalAppearancePreferences
        let sshHosts = store.sshHosts.map(SSHHostDraft.init)

        selectedDomain = SettingsDomain.allCases.contains(
            store.selectedDomain
        ) ? store.selectedDomain : .appearance
        interfaceAppearance = store.interfaceAppearance
        terminalTheme = terminalAppearance.theme
        appliesTerminalThemeToTmuxSessions =
            terminalAppearance.appliesThemeToTmuxSessions
        usesCustomTerminalFont = terminalAppearance.usesCustomFont
        terminalFontFamily = terminalAppearance.fontFamily
        terminalFontSize = terminalAppearance.fontSize
        cursorStyle = terminal.cursorStyle
        allowShellIntegrationToControlCursor =
            terminal.allowShellIntegrationToControlCursor
        hideMouseWhileTyping = terminal.hideMouseWhileTyping
        copySelectionToClipboard = terminal.copySelectionToClipboard
        hideRootCheckout = store.worktreePreferences.hideRootCheckout
        showHiddenWorktreesByDefault = store.worktreePreferences
            .showHiddenWorktreesByDefault
        hiddenTmuxSessionPatterns = store.tmuxSessionPreferences
            .hiddenSessionPatterns
        showMacOSNotifications = store.notificationConfiguration
            .showMacOSNotifications
        attentionSound = store.notificationConfiguration.attentionSound
        self.sshHosts = sshHosts
        selectedSSHHostDraftID = sshHosts.first?.id
    }

    @MainActor
    public mutating func syncHosts(from store: SettingsStore) {
        let selectedConfigKey = sshHosts
            .first { $0.id == selectedSSHHostDraftID }?
            .configKey
        let drafts = store.sshHosts.map(SSHHostDraft.init)
        sshHosts = drafts
        selectedSSHHostDraftID = selectedConfigKey.flatMap { key in
            drafts.first { $0.configKey == key }?.id
        } ?? drafts.first?.id
    }

    @MainActor
    public func persist(to store: SettingsStore) -> SettingsPersistResult {
        let shouldReloadTerminalConfig = shouldReloadTerminalConfig(
            comparedWith: store
        )
        let hosts = SSHHostSanitizer.sshHosts(sshHosts.map(\.sshHost))
        let shouldRefreshHosts = hosts != store.sshHosts

        store.selectedDomain = selectedDomain
        store.setInterfaceAppearance(interfaceAppearance)
        store.setTerminalTheme(terminalTheme)
        store.setTerminalThemeAppliesToTmuxSessions(
            appliesTerminalThemeToTmuxSessions
        )
        store.setUseCustomTerminalFont(usesCustomTerminalFont)
        store.setTerminalFontFamily(terminalFontFamily)
        store.setTerminalFontSize(terminalFontSize)
        store.setCursorStyle(cursorStyle)
        store.setAllowShellIntegrationToControlCursor(
            allowShellIntegrationToControlCursor
        )
        store.setHideMouseWhileTyping(hideMouseWhileTyping)
        store.setCopySelectionToClipboard(copySelectionToClipboard)
        store.setHideRootCheckout(hideRootCheckout)
        store.setShowHiddenWorktreesByDefault(
            showHiddenWorktreesByDefault
        )
        let didPersistTmuxSessionPatterns = store
            .setHiddenTmuxSessionPatterns(hiddenTmuxSessionPatterns)
        store.setShowMacOSNotifications(showMacOSNotifications)
        store.setNotificationAttentionSound(attentionSound)

        if shouldRefreshHosts {
            store.setSSHHosts(hosts)
        }
        return SettingsPersistResult(
            shouldRefreshHosts: shouldRefreshHosts,
            shouldReloadTerminalConfig: shouldReloadTerminalConfig,
            didPersistTmuxSessionPatterns: didPersistTmuxSessionPatterns
        )
    }

    @MainActor
    private func shouldReloadTerminalConfig(
        comparedWith store: SettingsStore
    ) -> Bool {
        let terminalAppearance = store.terminalAppearancePreferences
        let terminal = store.terminalPreferences

        let terminalAppearanceChanged =
            terminalTheme != terminalAppearance.theme
                || usesCustomTerminalFont != terminalAppearance.usesCustomFont
                || terminalFontFamily != terminalAppearance.fontFamily
                || terminalFontSize != terminalAppearance.fontSize

        let terminalBehaviorChanged =
            cursorStyle != terminal.cursorStyle
                || allowShellIntegrationToControlCursor
                != terminal.allowShellIntegrationToControlCursor
                || hideMouseWhileTyping != terminal.hideMouseWhileTyping
                || copySelectionToClipboard != terminal.copySelectionToClipboard

        return terminalAppearanceChanged || terminalBehaviorChanged
    }
}
