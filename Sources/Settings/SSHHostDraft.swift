import Foundation
import GhosthubWorkspace

public struct SSHHostDraft: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var configKey: String
    public var name: String
    public var platform: HostPlatform
    public var sshDestination: String

    public init(
        id: UUID = UUID(),
        configKey: String,
        name: String,
        platform: HostPlatform,
        sshDestination: String
    ) {
        self.id = id
        self.configKey = configKey
        self.name = name
        self.platform = platform
        self.sshDestination = sshDestination
    }

    public init(_ host: SSHHost) {
        self.init(
            configKey: host.configKey,
            name: host.name,
            platform: host.platform,
            sshDestination: host.sshDestination
        )
    }

    public var sshHost: SSHHost {
        SSHHost(
            configKey: configKey,
            name: name,
            platform: platform,
            sshDestination: sshDestination
        )
    }

    public var listDisplayName: String {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmedName.isEmpty ? "Untitled Host" : name
    }

    public var listSubtitle: String {
        let sshDestination = sshDestination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return sshDestination.isEmpty
            ? "SSH address required"
            : sshDestination
    }
}
