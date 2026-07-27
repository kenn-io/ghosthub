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
        store.setHideRootCheckout(true)
        store.setShowHiddenWorktreesByDefault(true)
        store.setShowMacOSNotifications(false)
        store.setNotificationAttentionSound(.glass)
        store.setShareAnonymousUsageData(false)
        store.setSSHHosts([host(configKey: "epyc", name: "EPYC")])

        let draft = SettingsViewDraft(store: store)

        #expect(draft.selectedDomain == .hosts)
        #expect(draft.interfaceAppearance == .dark)
        #expect(draft.terminalTheme == .homebrew)
        #expect(draft.hideRootCheckout)
        #expect(draft.showHiddenWorktreesByDefault)
        #expect(!draft.showMacOSNotifications)
        #expect(draft.attentionSound == .glass)
        #expect(!draft.shareAnonymousUsageData)
        #expect(draft.sshHosts.map(\.configKey) == ["epyc"])
        #expect(draft.selectedSSHHostDraftID == draft.sshHosts.first?.id)
    }

    @Test("persist restores worktree and agent settings")
    func persistRestoresProductSettings() {
        let store = makeStore()
        var draft = SettingsViewDraft(store: store)
        draft.hideRootCheckout = true
        draft.showHiddenWorktreesByDefault = true
        draft.showMacOSNotifications = false
        draft.attentionSound = .ping
        draft.shareAnonymousUsageData = false

        _ = draft.persist(to: store)

        #expect(store.worktreePreferences.hideRootCheckout)
        #expect(store.worktreePreferences.showHiddenWorktreesByDefault)
        #expect(!store.notificationConfiguration.showMacOSNotifications)
        #expect(store.notificationConfiguration.attentionSound == .ping)
        #expect(!store.shareAnonymousUsageData)
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
