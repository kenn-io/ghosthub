import Foundation
import GhosthubWorkspace

public struct SSHHost: Codable, Equatable, Sendable, Identifiable {
    public var configKey: String
    public var name: String
    public var platform: HostPlatform
    public var sshDestination: String
    public var launchProfiles: [TmuxLaunchProfile]

    public var id: String { configKey }

    public init(
        configKey: String,
        name: String,
        platform: HostPlatform,
        sshDestination: String,
        launchProfiles: [TmuxLaunchProfile] = []
    ) {
        self.configKey = configKey
        self.name = name
        self.platform = platform
        self.sshDestination = sshDestination
        self.launchProfiles = launchProfiles
    }

    private enum CodingKeys: String, CodingKey {
        case configKey
        case name
        case platform
        case sshDestination
        case launchProfiles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configKey = try container.decode(String.self, forKey: .configKey)
        name = try container.decode(String.self, forKey: .name)
        platform = try container.decode(HostPlatform.self, forKey: .platform)
        sshDestination = try container.decode(
            String.self,
            forKey: .sshDestination
        )
        launchProfiles = try container.decodeIfPresent(
            [TmuxLaunchProfile].self,
            forKey: .launchProfiles
        ) ?? []
    }
}
