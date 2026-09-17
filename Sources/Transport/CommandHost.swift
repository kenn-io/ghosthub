import Foundation

public enum ConnectionState: Codable, Equatable, Sendable {
    case connecting
    case reconnecting(reason: String?)
    case connected
    case disconnected(reason: String?)
}

public struct SSHHostInfo: Codable, Hashable, Sendable {
    public enum Platform: String, Codable, Hashable, Sendable {
        case posix
        case windows
    }

    public let user: String?
    public let hostname: String
    public let port: Int?
    public let platform: Platform
    public let compression: Bool

    public init(
        user: String?,
        hostname: String,
        port: Int?,
        platform: Platform = .posix,
        compression: Bool = true
    ) {
        self.user = user
        self.hostname = hostname
        self.port = port
        self.platform = platform
        self.compression = compression
    }

    public var displayName: String {
        let destination = user.map { "\($0)@\(hostname)" } ?? hostname
        guard let port, port != 22 else { return destination }
        return "\(destination):\(port)"
    }
}

public enum CommandHost: Codable, Hashable, Sendable {
    case local
    case ssh(SSHHostInfo)

    public func hasSameEndpoint(as other: CommandHost) -> Bool {
        switch (self, other) {
        case (.local, .local):
            true
        case let (.ssh(lhs), .ssh(rhs)):
            lhs.user == rhs.user
                && lhs.hostname == rhs.hostname
                && lhs.port == rhs.port
                && lhs.platform == rhs.platform
        default:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .local:
            "localhost"
        case let .ssh(info):
            info.displayName
        }
    }

    public var isRemote: Bool {
        if case .ssh = self {
            return true
        }
        return false
    }
}
