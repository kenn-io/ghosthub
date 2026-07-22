import Foundation
import GhosthubWorkspace
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

@MainActor
protocol NotificationService: AnyObject {
    func requestAuthorization() async
    func postAgentFinished(
        worktreeName: String,
        projectName: String
    )
    func postWorktreeBecameIdle(
        worktreeName: String,
        projectName: String
    )
    func postAgentsNeedAttention(
        worktreeName: String,
        projectName: String
    )
    func updateDockBadge(unseenCount: Int)
    func playCompletionSound()
}

@MainActor
protocol UserNotificationCentering: AnyObject {
    func requestAuthorization(
        options: UNAuthorizationOptions
    ) async throws -> Bool
    func add(_ request: UNNotificationRequest)
}

extension UNUserNotificationCenter: UserNotificationCentering {
    func add(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }
}

@MainActor
final class LiveNotificationService: NotificationService {
    private let configProvider: @MainActor () -> NotificationsConfiguration
    private let bundle: Bundle
    private let notificationCenterProvider: @MainActor () -> UserNotificationCentering
    private let soundPlayer: @MainActor (WorkspaceNotificationSound) -> Void
    private let fileManager: FileManager
    private let librarySoundsDirectoryProvider: @MainActor () -> URL?
    private let systemSoundsDirectory: URL
    private var cachedNotificationCenter: UserNotificationCentering?
    private var authorized = false

    init(
        config: NotificationsConfiguration,
        bundle: Bundle = .main,
        notificationCenter: UserNotificationCentering? = nil,
        notificationCenterProvider: @escaping @MainActor () -> UserNotificationCentering = {
            UNUserNotificationCenter.current()
        },
        fileManager: FileManager = .default,
        librarySoundsDirectoryProvider: @escaping @MainActor () -> URL? = {
            FileManager.default.urls(
                for: .libraryDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("Sounds", isDirectory: true)
        },
        systemSoundsDirectory: URL = URL(
            fileURLWithPath: "/System/Library/Sounds",
            isDirectory: true
        ),
        soundPlayer: @escaping @MainActor (WorkspaceNotificationSound)
            -> Void = LiveNotificationService.play
    ) {
        configProvider = { config }
        self.bundle = bundle
        self.soundPlayer = soundPlayer
        self.fileManager = fileManager
        self.librarySoundsDirectoryProvider = librarySoundsDirectoryProvider
        self.systemSoundsDirectory = systemSoundsDirectory
        if let notificationCenter {
            self.notificationCenterProvider = { notificationCenter }
            cachedNotificationCenter = notificationCenter
        } else {
            self.notificationCenterProvider = notificationCenterProvider
        }
    }

    init(
        configProvider: @escaping @MainActor () -> NotificationsConfiguration,
        bundle: Bundle = .main,
        notificationCenter: UserNotificationCentering? = nil,
        notificationCenterProvider: @escaping @MainActor () -> UserNotificationCentering = {
            UNUserNotificationCenter.current()
        },
        fileManager: FileManager = .default,
        librarySoundsDirectoryProvider: @escaping @MainActor () -> URL? = {
            FileManager.default.urls(
                for: .libraryDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("Sounds", isDirectory: true)
        },
        systemSoundsDirectory: URL = URL(
            fileURLWithPath: "/System/Library/Sounds",
            isDirectory: true
        ),
        soundPlayer: @escaping @MainActor (WorkspaceNotificationSound)
            -> Void = LiveNotificationService.play
    ) {
        self.configProvider = configProvider
        self.bundle = bundle
        self.soundPlayer = soundPlayer
        self.fileManager = fileManager
        self.librarySoundsDirectoryProvider = librarySoundsDirectoryProvider
        self.systemSoundsDirectory = systemSoundsDirectory
        if let notificationCenter {
            self.notificationCenterProvider = { notificationCenter }
            cachedNotificationCenter = notificationCenter
        } else {
            self.notificationCenterProvider = notificationCenterProvider
        }
    }

    static func supportsUserNotifications(bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "app"
    }

    func requestAuthorization() async {
        guard Self.supportsUserNotifications(bundle: bundle) else {
            return
        }

        do {
            authorized = try await resolvedNotificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        } catch {
            AppLogger.shared.error(
                "notification authorization failed: \(error)"
            )
        }
    }

    func postAgentFinished(
        worktreeName: String,
        projectName: String
    ) {
        let config = currentConfig
        guard config.showMacOSNotifications, authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Agent Finished"
        content.body = "\(worktreeName) in \(projectName)"
        configureSound(for: content, using: config)

        let request = UNNotificationRequest(
            identifier: "agent-finished-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        resolvedNotificationCenter.add(request)
    }

    func postWorktreeBecameIdle(
        worktreeName: String,
        projectName: String
    ) {
        let config = currentConfig
        guard config.showMacOSNotifications, authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Session Idle"
        content.body = "\(worktreeName) in \(projectName) needs attention"
        configureSound(for: content, using: config)

        let request = UNNotificationRequest(
            identifier: "worktree-idle-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        resolvedNotificationCenter.add(request)
    }

    func postAgentsNeedAttention(
        worktreeName: String,
        projectName: String
    ) {
        let config = currentConfig
        guard config.showMacOSNotifications, authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Agents Need Attention"
        content.body = "\(worktreeName) in \(projectName) has an idle agent pane"
        configureSound(for: content, using: config)

        let request = UNNotificationRequest(
            identifier: "agent-idle-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        resolvedNotificationCenter.add(request)
    }

    func updateDockBadge(unseenCount: Int) {
        #if canImport(AppKit)
        let config = currentConfig
        guard config.showDockBadge else {
            NSApp?.dockTile.badgeLabel = nil
            return
        }
        NSApp?.dockTile.badgeLabel = unseenCount > 0
            ? "\(unseenCount)" : nil
        #endif
    }

    func playCompletionSound() {
        soundPlayer(currentConfig.attentionSound)
    }

    private var resolvedNotificationCenter: UserNotificationCentering {
        if let cachedNotificationCenter {
            return cachedNotificationCenter
        }

        let notificationCenter = notificationCenterProvider()
        cachedNotificationCenter = notificationCenter
        return notificationCenter
    }

    private var currentConfig: NotificationsConfiguration {
        configProvider()
    }

    private func configureSound(
        for content: UNMutableNotificationContent,
        using config: NotificationsConfiguration
    ) {
        content.sound = resolvedNotificationSound(for: config.attentionSound)
    }

    private func resolvedNotificationSound(
        for sound: WorkspaceNotificationSound
    ) -> UNNotificationSound? {
        switch sound {
        case .systemDefault:
            return .default
        case .none:
            return nil
        default:
            guard let fileName = installNotificationSoundIfNeeded(sound)
            else {
                return .default
            }
            return UNNotificationSound(
                named: UNNotificationSoundName(rawValue: fileName)
            )
        }
    }

    private func installNotificationSoundIfNeeded(
        _ sound: WorkspaceNotificationSound
    ) -> String? {
        guard let sourceName = sound.appKitSoundName,
              let librarySoundsDirectory = librarySoundsDirectoryProvider()
        else {
            return nil
        }

        let fileName = "Ghosthub-\(sourceName).aiff"
        let destinationURL = librarySoundsDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return fileName
        }

        let sourceURL = systemSoundsDirectory
            .appendingPathComponent("\(sourceName).aiff")
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: librarySoundsDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return fileName
        } catch {
            AppLogger.shared.error(
                "failed to install notification sound \(sourceName): \(error)"
            )
            return nil
        }
    }

    private static func play(
        sound: WorkspaceNotificationSound
    ) {
        #if canImport(AppKit)
        guard let soundName = sound.appKitSoundName else {
            return
        }
        NSSound(named: NSSound.Name(soundName))?.play()
        #endif
    }
}
