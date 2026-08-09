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

    public init(
        user: String?,
        hostname: String,
        port: Int?,
        platform: Platform = .posix
    ) {
        self.user = user
        self.hostname = hostname
        self.port = port
        self.platform = platform
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
