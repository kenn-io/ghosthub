import Foundation
import GhosthubPersistence
import GhosthubSettings
import GhosthubWorkspace

@MainActor
enum WorkspaceSceneBootstrap {
    struct Resources {
        let database: WorkspaceDatabase
        let workspaceConfiguration: WorkspaceConfiguration
        let notificationService: NotificationService
        let tmuxSessionActivityController: TmuxSessionActivityController
        let localHostID: UUID
    }

    /// Well-known ID for the app-owned local host row.
    nonisolated static let fallbackLocalHostID = UUID(
        uuidString: "B5EA95AB-51A3-4F17-B6C3-8A4C1004BFA1"
    )!

    private static var sharedResources: Resources?

    static func ensureBootstrapped() {
        guard sharedResources == nil else { return }
        do {
            _ = try resources()
        } catch {
            fatalError(
                "Failed to bootstrap workspace scene: \(error)"
            )
        }
    }

    static func resources() throws -> Resources {
        if let existing = sharedResources {
            return Resources(
                database: existing.database,
                workspaceConfiguration:
                existing.workspaceConfiguration,
                notificationService:
                existing.notificationService,
                tmuxSessionActivityController:
                existing.tmuxSessionActivityController,
                localHostID: existing.localHostID
            )
        }

        let databaseURL = try WorkspaceDatabase.defaultDatabaseURL()
        let database = try WorkspaceDatabase(url: databaseURL)

        let workspaceConfiguration =
            WorkspaceConfiguration.fromSettings(
                SettingsStore.shared
            )
        let notificationService = LiveNotificationService(
            configProvider: {
                SettingsStore.shared.notificationConfiguration
            }
        )

        try database.terminalSessions.markLocalSessionsOffline(
            at: Date()
        )

        let result = Resources(
            database: database,
            workspaceConfiguration: workspaceConfiguration,
            notificationService: notificationService,
            tmuxSessionActivityController:
            TmuxSessionActivityController(),
            localHostID: fallbackLocalHostID
        )
        sharedResources = result
        return result
    }
}
