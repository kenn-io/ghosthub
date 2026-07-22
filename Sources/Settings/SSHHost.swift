import GhosthubWorkspace

public struct SSHHost: Codable, Equatable, Sendable, Identifiable {
    public var configKey: String
    public var name: String
    public var platform: HostPlatform
    public var sshDestination: String

    public var id: String { configKey }

    public init(
        configKey: String,
        name: String,
        platform: HostPlatform,
        sshDestination: String
    ) {
        self.configKey = configKey
        self.name = name
        self.platform = platform
        self.sshDestination = sshDestination
    }
}
