import Foundation

public struct WorkspaceConfiguration: Equatable, Sendable {
    public var notifications: NotificationsConfiguration
    public var presets: [PresetConfiguration]

    public init(
        notifications: NotificationsConfiguration,
        presets: [PresetConfiguration]
    ) {
        self.notifications = notifications
        self.presets = presets
    }

    public static func defaults() -> WorkspaceConfiguration {
        let presets = [
            PresetConfiguration(
                id: "claude",
                name: "Claude Code",
                command: "claude",
                icon: "brain",
                shortcut: 1,
                idleThresholdSeconds: 15
            ),
            PresetConfiguration(
                id: "codex",
                name: "Codex",
                command: "codex",
                icon: "terminal",
                shortcut: 2,
                idleThresholdSeconds: 15
            ),
            PresetConfiguration(
                id: "shell",
                name: "Shell",
                command: "",
                icon: "terminal.fill",
                shortcut: 3,
                idleThresholdSeconds: 0
            ),
        ]

        return WorkspaceConfiguration(
            notifications: NotificationsConfiguration(
                idleThresholdSeconds: 30,
                showMacOSNotifications: true,
                showDockBadge: true,
                attentionSound: .systemDefault
            ),
            presets: presets
        )
    }

    public func preset(id: String) -> PresetConfiguration? {
        presets.first { $0.id == id }
    }
}

public enum AppearancePreference: String, CaseIterable, Equatable, Sendable {
    case system
    case light
    case dark
}

public enum WorkspaceNotificationSound: String, CaseIterable, Equatable, Sendable {
    case systemDefault = "default"
    case none
    case basso
    case blow
    case bottle
    case frog
    case funk
    case glass
    case hero
    case morse
    case ping
    case pop
    case purr
    case sosumi
    case submarine
    case tink

    public var title: String {
        switch self {
        case .systemDefault:
            return "Default"
        case .none:
            return "None"
        case .basso:
            return "Basso"
        case .blow:
            return "Blow"
        case .bottle:
            return "Bottle"
        case .frog:
            return "Frog"
        case .funk:
            return "Funk"
        case .glass:
            return "Glass"
        case .hero:
            return "Hero"
        case .morse:
            return "Morse"
        case .ping:
            return "Ping"
        case .pop:
            return "Pop"
        case .purr:
            return "Purr"
        case .sosumi:
            return "Sosumi"
        case .submarine:
            return "Submarine"
        case .tink:
            return "Tink"
        }
    }

    public var appKitSoundName: String? {
        switch self {
        case .systemDefault, .none:
            return nil
        case .basso:
            return "Basso"
        case .blow:
            return "Blow"
        case .bottle:
            return "Bottle"
        case .frog:
            return "Frog"
        case .funk:
            return "Funk"
        case .glass:
            return "Glass"
        case .hero:
            return "Hero"
        case .morse:
            return "Morse"
        case .ping:
            return "Ping"
        case .pop:
            return "Pop"
        case .purr:
            return "Purr"
        case .sosumi:
            return "Sosumi"
        case .submarine:
            return "Submarine"
        case .tink:
            return "Tink"
        }
    }

    public static var supportedValuesDescription: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

public struct NotificationsConfiguration: Equatable, Sendable {
    public var idleThresholdSeconds: Int
    public var showMacOSNotifications: Bool
    public var showDockBadge: Bool
    public var attentionSound: WorkspaceNotificationSound
    public var presetOverrides: [String: PresetNotificationConfiguration]

    public init(
        idleThresholdSeconds: Int,
        showMacOSNotifications: Bool,
        showDockBadge: Bool,
        attentionSound: WorkspaceNotificationSound = .systemDefault,
        presetOverrides: [String: PresetNotificationConfiguration] = [:]
    ) {
        self.idleThresholdSeconds = idleThresholdSeconds
        self.showMacOSNotifications = showMacOSNotifications
        self.showDockBadge = showDockBadge
        self.attentionSound = attentionSound
        self.presetOverrides = presetOverrides
    }
}

public struct PresetNotificationConfiguration: Equatable, Sendable {
    public var idleThresholdSeconds: Int

    public init(idleThresholdSeconds: Int) {
        self.idleThresholdSeconds = idleThresholdSeconds
    }
}

public struct PresetConfiguration: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var command: String
    public var icon: String?
    public var shortcut: Int?
    public var idleThresholdSeconds: Int?
    public var environment: [String: String]

    public init(
        id: String,
        name: String,
        command: String,
        icon: String? = nil,
        shortcut: Int? = nil,
        idleThresholdSeconds: Int? = nil,
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.shortcut = shortcut
        self.idleThresholdSeconds = idleThresholdSeconds
        self.environment = environment
    }
}
