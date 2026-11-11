import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace

public struct SettingsPersistResult: Equatable, Sendable {
    public var shouldRefreshHosts: Bool
    public var shouldReloadTerminalConfig: Bool
    public var didPersistTmuxSessionPatterns: Bool
    public var didPersistShortcuts: Bool

    public init(
        shouldRefreshHosts: Bool,
        shouldReloadTerminalConfig: Bool,
        didPersistTmuxSessionPatterns: Bool,
        didPersistShortcuts: Bool
    ) {
        self.shouldRefreshHosts = shouldRefreshHosts
        self.shouldReloadTerminalConfig = shouldReloadTerminalConfig
        self.didPersistTmuxSessionPatterns = didPersistTmuxSessionPatterns
        self.didPersistShortcuts = didPersistShortcuts
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
    public var sessionPreviewMode: SessionPreviewMode
    public var sidebar: SidebarPreferences
    /// The sidebar's options menu can change these while Settings is open.
    /// Closing Settings keeps each such choice unless this draft changed
    /// the same option itself.
    private var loadedSidebar: SidebarPreferences
    private var loadedWorktreePreferences: WorktreePreferences
    public var hideRootCheckout: Bool
    public var showHiddenWorktreesByDefault: Bool
    public var hideKwtManagedSessions: Bool
    public var hiddenTmuxSessionPatterns: [String]
    public var showMacOSNotifications: Bool
    public var attentionSound: WorkspaceNotificationSound
    public var sshHosts: [SSHHostDraft]
    public var selectedSSHHostDraftID: UUID?
    public var exeAccounts: [ExeAccount]
    public var shortcutOverrides:
        [ApplicationShortcutAction: ApplicationShortcutOverride]

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
        sessionPreviewMode = store.sessionPreviewMode
        sidebar = store.sidebarPreferences
        loadedSidebar = store.sidebarPreferences
        loadedWorktreePreferences = store.worktreePreferences
        hideRootCheckout = store.worktreePreferences.hideRootCheckout
        showHiddenWorktreesByDefault = store.worktreePreferences
            .showHiddenWorktreesByDefault
        hideKwtManagedSessions = store.worktreePreferences
            .hideKwtManagedSessions
        hiddenTmuxSessionPatterns = store.tmuxSessionPreferences
            .hiddenSessionPatterns
        showMacOSNotifications = store.notificationConfiguration
            .showMacOSNotifications
        attentionSound = store.notificationConfiguration.attentionSound
        self.sshHosts = sshHosts
        selectedSSHHostDraftID = sshHosts.first?.id
        exeAccounts = store.exeAccounts
        shortcutOverrides = store.shortcutPreferences.overrides
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

    /// The draft's value when this draft changed it, else the store's.
    private static func edited<Value: Equatable>(
        _ draft: Value,
        loaded: Value,
        current: Value
    ) -> Value {
        draft == loaded ? current : draft
    }

    @MainActor
    public func persist(to store: SettingsStore) -> SettingsPersistResult {
        let shouldReloadTerminalConfig = shouldReloadTerminalConfig(
            comparedWith: store
        )
        let hosts = SSHHostSanitizer.sshHosts(sshHosts.map(\.sshHost))
        let exeAccountsToPersist = ExeAccountSanitizer
            .accountsForPersistence(
                exeAccounts,
                previous: store.exeAccounts
            )
        let shouldRefreshHosts = hosts != store.sshHosts
            || exeAccountsToPersist != store.exeAccounts
        let didPersistShortcuts = store.setShortcutOverrides(
            shortcutOverrides
        )

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
        store.setSessionPreviewMode(sessionPreviewMode)
        let currentSidebar = store.sidebarPreferences
        let currentWorktree = store.worktreePreferences
        store.setSidebarPreferences(SidebarPreferences(
            sessionSort: Self.edited(
                sidebar.sessionSort,
                loaded: loadedSidebar.sessionSort,
                current: currentSidebar.sessionSort
            ),
            backendLabelStyle: Self.edited(
                sidebar.backendLabelStyle,
                loaded: loadedSidebar.backendLabelStyle,
                current: currentSidebar.backendLabelStyle
            ),
            rowHeight: Self.edited(
                sidebar.rowHeight,
                loaded: loadedSidebar.rowHeight,
                current: currentSidebar.rowHeight
            )
        ))
        store.setHideRootCheckout(Self.edited(
            hideRootCheckout,
            loaded: loadedWorktreePreferences.hideRootCheckout,
            current: currentWorktree.hideRootCheckout
        ))
        store.setShowHiddenWorktreesByDefault(Self.edited(
            showHiddenWorktreesByDefault,
            loaded: loadedWorktreePreferences.showHiddenWorktreesByDefault,
            current: currentWorktree.showHiddenWorktreesByDefault
        ))
        store.setHideKwtManagedSessions(Self.edited(
            hideKwtManagedSessions,
            loaded: loadedWorktreePreferences.hideKwtManagedSessions,
            current: currentWorktree.hideKwtManagedSessions
        ))
        let didPersistTmuxSessionPatterns = store
            .setHiddenTmuxSessionPatterns(hiddenTmuxSessionPatterns)
        store.setShowMacOSNotifications(showMacOSNotifications)
        store.setNotificationAttentionSound(attentionSound)

        if shouldRefreshHosts {
            store.setSSHHosts(hosts)
            store.setExeAccounts(exeAccountsToPersist)
        }
        return SettingsPersistResult(
            shouldRefreshHosts: shouldRefreshHosts,
            shouldReloadTerminalConfig: shouldReloadTerminalConfig,
            didPersistTmuxSessionPatterns: didPersistTmuxSessionPatterns,
            didPersistShortcuts: didPersistShortcuts
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
