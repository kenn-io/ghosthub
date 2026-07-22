import Foundation
import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubWorkspace
import Testing

@MainActor
struct SettingsStoreWorkspaceConfigurationTests {
    @Test("workspace configuration overlays settings onto defaults")
    func workspaceConfigurationOverlaysSettings() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let suiteName = "ghosthub.settings.workspace.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = SettingsStore(
            configPipeline: GhosttyConfigPipeline(
                paths: GhosttyConfigPaths(configDirectory: tempRoot)
            ),
            userDefaults: defaults
        )
        store.setShowMacOSNotifications(false)
        store.setNotificationAttentionSound(.glass)

        let configuration = WorkspaceConfiguration.fromSettings(store)
        let defaultsConfiguration = WorkspaceConfiguration.defaults()

        #expect(!configuration.notifications.showMacOSNotifications)
        #expect(!configuration.notifications.showDockBadge)
        #expect(configuration.notifications.attentionSound == .glass)
        #expect(configuration.presets == defaultsConfiguration.presets)
    }
}
