import Foundation
@testable import GhosthubTerminalSupport
@testable import GhosthubSettings
import GhosthubWorkspace
import Testing

@MainActor
struct SettingsViewDraftTests {
    @Test("draft snapshots app-owned host and terminal values")
    func draftSnapshotsStoreValues() {
        let store = makeStore()
        store.selectedDomain = .hosts
        store.setInterfaceAppearance(.dark)
        store.setTerminalTheme(.homebrew)
        store.setTerminalThemeAppliesToTmuxSessions(true)
        store.setHideRootCheckout(true)
        store.setShowHiddenWorktreesByDefault(true)
        store.setHiddenTmuxSessionPatterns(["forge-*", "scratch-?"])
        store.setShowMacOSNotifications(false)
        store.setNotificationAttentionSound(.glass)
        store.setSSHHosts([host(configKey: "epyc", name: "EPYC")])
        store.setExeAccounts([
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev"
            ),
        ])

        let draft = SettingsViewDraft(store: store)

        #expect(draft.selectedDomain == .hosts)
        #expect(draft.interfaceAppearance == .dark)
        #expect(draft.terminalTheme == .homebrew)
        #expect(draft.appliesTerminalThemeToTmuxSessions)
        #expect(draft.hideRootCheckout)
        #expect(draft.showHiddenWorktreesByDefault)
        #expect(
            draft.hiddenTmuxSessionPatterns == ["forge-*", "scratch-?"]
        )
        #expect(!draft.showMacOSNotifications)
        #expect(draft.attentionSound == .glass)
        #expect(draft.sshHosts.map(\.configKey) == ["epyc"])
        #expect(draft.selectedSSHHostDraftID == draft.sshHosts.first?.id)
        #expect(draft.exeAccounts.map(\.configKey) == ["personal"])
    }

    @Test("tmux theme opt-in persists without reloading libghostty")
    func tmuxThemeOptInDoesNotReloadTerminalConfig() {
        let store = makeStore()
        var draft = SettingsViewDraft(store: store)
        draft.terminalTheme = .pro
        _ = draft.persist(to: store)
        draft = SettingsViewDraft(store: store)
        draft.appliesTerminalThemeToTmuxSessions = true

        let result = draft.persist(to: store)

        #expect(!result.shouldReloadTerminalConfig)
        #expect(
            store.terminalAppearancePreferences
                .appliesThemeToTmuxSessions
        )
    }

    @Test("persist restores worktree and agent settings")
    func persistRestoresProductSettings() {
        let store = makeStore()
        var draft = SettingsViewDraft(store: store)
        draft.hideRootCheckout = true
        draft.showHiddenWorktreesByDefault = true
        draft.hiddenTmuxSessionPatterns = ["forge-*", "scratch-?"]
        draft.showMacOSNotifications = false
        draft.attentionSound = .ping

        _ = draft.persist(to: store)

        #expect(store.worktreePreferences.hideRootCheckout)
        #expect(store.worktreePreferences.showHiddenWorktreesByDefault)
        #expect(
            store.tmuxSessionPreferences.hiddenSessionPatterns
                == ["forge-*", "scratch-?"]
        )
        #expect(!store.notificationConfiguration.showMacOSNotifications)
        #expect(store.notificationConfiguration.attentionSound == .ping)
    }

    @Test("persist reports a failed tmux pattern write")
    func persistReportsFailedTmuxPatternWrite() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.appConfigFile,
            withIntermediateDirectories: true
        )
        var draft = SettingsViewDraft(store: store)
        draft.hiddenTmuxSessionPatterns = ["forge-*"]

        let result = draft.persist(to: store)

        #expect(!result.didPersistTmuxSessionPatterns)
        #expect(store.tmuxSessionPreferences.hiddenSessionPatterns.isEmpty)
    }

    @Test("persist reports terminal reload for terminal settings")
    func persistReportsTerminalReloadForTerminalSettings() {
        let store = makeStore()
        var draft = SettingsViewDraft(store: store)
        draft.terminalTheme = .pro
        draft.usesCustomTerminalFont = true
        draft.terminalFontFamily = "SF Mono"
        draft.terminalFontSize = 13.5

        let result = draft.persist(to: store)

        #expect(result.shouldReloadTerminalConfig)
        #expect(store.terminalAppearancePreferences.theme == .pro)
        #expect(store.terminalAppearancePreferences.fontFamily == "SF Mono")
    }

    @Test("persist writes app-owned SSH hosts")
    func persistWritesHosts() {
        let store = makeStore()
        var draft = SettingsViewDraft(store: store)
        draft.sshHosts = [SSHHostDraft(host(configKey: "lab", name: "Lab"))]

        let result = draft.persist(to: store)

        #expect(result.shouldRefreshHosts)
        #expect(store.sshHosts.map(\.configKey) == ["lab"])
    }

    @Test("persist writes exe.dev accounts and requests host refresh")
    func persistWritesExeAccounts() {
        let store = makeStore()
        var draft = SettingsViewDraft(store: store)
        draft.exeAccounts = [ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )]

        let result = draft.persist(to: store)

        #expect(result.shouldRefreshHosts)
        #expect(store.exeAccounts == draft.exeAccounts)
    }

    @Test("invalid exe.dev drafts preserve values and apply revocations")
    func invalidExeAccountDraftsPreserveValuesAndApplyRevocations() {
        let originalAccounts = [
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev"
            ),
            ExeAccount(
                configKey: "work",
                name: "Work",
                sshDestination: "work-exe"
            ),
        ]
        let store = makeStore()
        store.setExeAccounts(originalAccounts)
        var draft = SettingsViewDraft(store: store)
        draft.exeAccounts[1].name = ""

        let emptyNameResult = draft.persist(to: store)

        #expect(!emptyNameResult.shouldRefreshHosts)
        #expect(store.exeAccounts == originalAccounts)

        draft.exeAccounts[1].name = "Work"
        draft.exeAccounts[1].sshDestination = "exe.dev"

        let duplicateDestinationResult = draft.persist(to: store)

        #expect(!duplicateDestinationResult.shouldRefreshHosts)
        #expect(store.exeAccounts == originalAccounts)

        draft.exeAccounts[1].sshDestination = "work-exe"
        draft.exeAccounts[1].name = ""
        draft.exeAccounts.removeFirst()

        let removalResult = draft.persist(to: store)

        #expect(removalResult.shouldRefreshHosts)
        #expect(store.exeAccounts == [originalAccounts[1]])

        var disabledDraft = SettingsViewDraft(store: store)
        disabledDraft.exeAccounts[0].isEnabled = false
        disabledDraft.exeAccounts[0].name = ""
        disabledDraft.exeAccounts[0].sshDestination = ""

        let disableResult = disabledDraft.persist(to: store)

        var disabledAccount = originalAccounts[1]
        disabledAccount.isEnabled = false
        #expect(disableResult.shouldRefreshHosts)
        #expect(store.exeAccounts == [disabledAccount])
    }

    @Test("host sync preserves selection by stable key")
    func hostSyncPreservesSelection() throws {
        let store = makeStore()
        store.setSSHHosts([
            host(configKey: "studio", name: "Studio"),
            host(configKey: "epyc", name: "EPYC"),
        ])
        var draft = SettingsViewDraft(store: store)
        draft.selectedSSHHostDraftID = try #require(
            draft.sshHosts.first { $0.configKey == "epyc" }
        ).id
        store.setSSHHosts([
            host(configKey: "studio", name: "New Studio"),
            host(configKey: "epyc", name: "New EPYC"),
        ])

        draft.syncHosts(from: store)

        let selected = try #require(draft.selectedSSHHost)
        #expect(selected.configKey == "epyc")
        #expect(selected.name == "New EPYC")
    }

    private func makeStore() -> SettingsStore {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(
            suiteName: "ghosthub.settings.draft.\(UUID().uuidString)"
        )!
        return SettingsStore(
            configPipeline: LibghosttyConfigPipeline(
                paths: LibghosttyConfigPaths(configDirectory: tempRoot)
            ),
            userDefaults: defaults
        )
    }

    private func host(configKey: String, name: String) -> SSHHost {
        SSHHost(
            configKey: configKey,
            name: name,
            platform: .linux,
            sshDestination: "\(configKey).example.com"
        )
    }
}

private extension SettingsViewDraft {
    var selectedSSHHost: SSHHostDraft? {
        sshHosts.first { $0.id == selectedSSHHostDraftID }
    }
}
