import Foundation

/// Composite key addressing an entity within a host.
public struct HostScopedKey: Hashable, Sendable {
    public let hostID: UUID
    public let scopedKey: String

    public init(hostID: UUID, scopedKey: String) {
        self.hostID = hostID
        self.scopedKey = scopedKey
    }
}

public enum HostKind: String, Codable, Equatable, Sendable {
    case selfHost = "self"
    case remote
}

public enum HostTransport: String, Codable, Equatable, Sendable {
    case local
    case ssh
    case mosh
    case http
}

public enum HostPlatform: String, Equatable, Sendable {
    case macOS
    case linux
    case windows
}

extension HostPlatform: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer()
            .decode(String.self)
        switch raw {
        case "macos", "macOS": self = .macOS
        case "linux": self = .linux
        case "windows": self = .windows
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                    "Unknown platform: \(raw)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Encode as lowercase for wire compatibility.
        var container = encoder.singleValueContainer()
        switch self {
        case .macOS: try container.encode("macos")
        case .linux: try container.encode("linux")
        case .windows: try container.encode("windows")
        }
    }
}

extension HostPlatform {
    /// Parse a platform string (e.g. "macos-arm64", "linux",
    /// "darwin") into a HostPlatform value. Defaults to
    /// `.linux` for nil or unrecognized strings.
    public static func from(
        platformString: String?
    ) -> HostPlatform {
        guard let platform = platformString else {
            return .linux
        }
        let lower = platform.lowercased()
        if lower.hasPrefix("macos")
            || lower.hasPrefix("darwin") {
            return .macOS
        }
        if lower.hasPrefix("windows") {
            return .windows
        }
        return .linux
    }
}

/// Lifecycle status of a host-reported terminal session, matching the
/// host inventory session vocabulary (replaces the old alive/dead pair).
public enum HostSessionStatus: String, Codable, Equatable, Sendable {
    case starting
    case running
    case exited
    case error
}

public enum HostConnectionState: String, Codable, Equatable, Sendable {
    case local
    case connecting
    case reconnecting
    case online
    case degraded
    case offline
}

public enum RemoteHostDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case warning
    case error
}

public enum RemoteHostDiagnosticCode: String, Codable, Equatable, Sendable {
    case missingGit
    case missingGh
    case missingKwt
    case ghNotAuthenticated
    case missingTmux
    case missingInstallDependencies
    case bootstrapFailure
    case configurationFailure
    case sshAuthenticationFailed
    case sshConnectionFailed
    case probeFailure
}

public struct RemoteHostDiagnostic: Codable, Equatable, Sendable, Identifiable {
    public var code: RemoteHostDiagnosticCode
    public var severity: RemoteHostDiagnosticSeverity
    public var summary: String
    public var recoverySuggestion: String

    public init(
        code: RemoteHostDiagnosticCode,
        severity: RemoteHostDiagnosticSeverity,
        summary: String,
        recoverySuggestion: String
    ) {
        self.code = code
        self.severity = severity
        self.summary = summary
        self.recoverySuggestion = recoverySuggestion
    }

    public var id: String {
        "\(code.rawValue):\(summary)"
    }

    public var blocksWorktreeCreate: Bool {
        switch code {
        case .missingGit,
             .missingKwt,
             .missingInstallDependencies,
             .bootstrapFailure,
             .configurationFailure,
             .sshAuthenticationFailed,
             .sshConnectionFailed,
             .probeFailure:
            return true
        case .missingGh, .ghNotAuthenticated, .missingTmux:
            return false
        }
    }

    public var blocksPullRequestImport: Bool {
        blocksWorktreeCreate || code == .missingGh || code == .ghNotAuthenticated
    }

    public var blocksDurableSessions: Bool {
        switch code {
        case .missingTmux,
             .missingInstallDependencies,
             .bootstrapFailure,
             .configurationFailure,
             .sshAuthenticationFailed,
             .sshConnectionFailed,
             .probeFailure:
            return true
        case .missingGit, .missingGh, .missingKwt, .ghNotAuthenticated:
            return false
        }
    }

    public static var missingKwtCapability: Self {
        RemoteHostDiagnostic(
            code: .missingKwt,
            severity: .warning,
            summary: "Git worktree support is not installed (optional).",
            recoverySuggestion:
            "Use Install kwt Worktree Helper in Host Settings to show "
                + "projects and worktrees from this host. "
                + "Tmux sessions remain available."
        )
    }

    public static var missingTmuxCapability: Self {
        RemoteHostDiagnostic(
            code: .missingTmux,
            severity: .error,
            summary: "tmux is not installed.",
            recoverySuggestion:
            "Install tmux on the remote host, then test the connection again."
        )
    }

    public static var tmuxDiscoveryUnavailable: Self {
        RemoteHostDiagnostic(
            code: .probeFailure,
            severity: .error,
            summary: "Tmux could not be reached.",
            recoverySuggestion:
            "Verify the SSH destination and that tmux is installed, "
                + "then retry workspace discovery."
        )
    }
}

public struct RemoteHostCommandCapabilities: Codable, Equatable, Sendable {
    public var worktreeCreate: Bool
    public var worktreeImportPullRequest: Bool
    public var worktreeDelete: Bool
    public var sessionEnsure: Bool
    public var sessionKill: Bool

    public init(
        worktreeCreate: Bool,
        worktreeImportPullRequest: Bool,
        worktreeDelete: Bool,
        sessionEnsure: Bool,
        sessionKill: Bool
    ) {
        self.worktreeCreate = worktreeCreate
        self.worktreeImportPullRequest = worktreeImportPullRequest
        self.worktreeDelete = worktreeDelete
        self.sessionEnsure = sessionEnsure
        self.sessionKill = sessionKill
    }

    private enum CodingKeys: String, CodingKey {
        case worktreeCreate
        case worktreeImportPullRequest
        case worktreeDelete
        case sessionEnsure
        case sessionKill
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        worktreeCreate = try container.decode(
            Bool.self, forKey: .worktreeCreate
        )
        worktreeImportPullRequest = try container.decode(
            Bool.self, forKey: .worktreeImportPullRequest
        )
        worktreeDelete = try container.decode(
            Bool.self, forKey: .worktreeDelete
        )
        sessionEnsure = try container.decode(
            Bool.self, forKey: .sessionEnsure
        )
        sessionKill = try container.decode(
            Bool.self, forKey: .sessionKill
        )
    }
}

public struct RemoteHostDependencyCapabilities: Codable, Equatable, Sendable {
    public var git: Bool
    public var gh: Bool
    public var platformAuthenticated: Bool?
    public var tmux: Bool

    public init(git: Bool, gh: Bool, platformAuthenticated: Bool? = nil, tmux: Bool) {
        self.git = git
        self.gh = gh
        self.platformAuthenticated = platformAuthenticated
        self.tmux = tmux
    }
}

public struct RemoteHostFeatureCapabilities: Codable, Equatable, Sendable {
    public var resourceMetrics: Bool
    public var setupHook: Bool
    public var teardownHook: Bool
    public var moshAttach: Bool

    public init(
        resourceMetrics: Bool,
        setupHook: Bool,
        teardownHook: Bool,
        moshAttach: Bool
    ) {
        self.resourceMetrics = resourceMetrics
        self.setupHook = setupHook
        self.teardownHook = teardownHook
        self.moshAttach = moshAttach
    }
}

public struct RemoteHostCapabilities: Codable, Equatable, Sendable {
    public var commands: RemoteHostCommandCapabilities
    public var dependencies: RemoteHostDependencyCapabilities
    public var features: RemoteHostFeatureCapabilities

    public init(
        commands: RemoteHostCommandCapabilities,
        dependencies: RemoteHostDependencyCapabilities,
        features: RemoteHostFeatureCapabilities
    ) {
        self.commands = commands
        self.dependencies = dependencies
        self.features = features
    }
}

/// Build dependency diagnostics from host capabilities.
/// Used by both SessionStore (SSH snapshot import) and
/// SSHHostProbeService (probe).
public func buildHostDiagnostics(
    for capabilities: RemoteHostCapabilities?
) -> [RemoteHostDiagnostic] {
    guard let capabilities else { return [] }
    var diagnostics: [RemoteHostDiagnostic] = []
    if !capabilities.dependencies.git {
        diagnostics.append(RemoteHostDiagnostic(
            code: .missingGit,
            severity: .error,
            summary: "Missing git",
            recoverySuggestion:
            "Install git on the remote host."
        ))
    }
    if !capabilities.dependencies.gh {
        diagnostics.append(RemoteHostDiagnostic(
            code: .missingGh,
            severity: .warning,
            summary: "Missing gh",
            recoverySuggestion:
            "Install GitHub CLI (`gh`) on the"
                + " remote host to import pull"
                + " requests."
        ))
    } else if capabilities.dependencies.platformAuthenticated
        == false {
        diagnostics.append(RemoteHostDiagnostic(
            code: .ghNotAuthenticated,
            severity: .warning,
            summary: "gh not authenticated",
            recoverySuggestion:
            "Run `gh auth login` on the remote"
                + " host to enable pull request"
                + " import."
        ))
    }
    if !capabilities.dependencies.tmux {
        diagnostics.append(.missingTmuxCapability)
    }
    return diagnostics
}
public struct OperationAvailabilityEntry:
    Codable, Equatable, Sendable {
    public var available: Bool
    public var unavailableReason: String?

    public init(
        available: Bool,
        unavailableReason: String? = nil
    ) {
        self.available = available
        self.unavailableReason = unavailableReason
    }
}

public struct HostSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var configKey: String
    public var name: String
    public var kind: HostKind
    public var platform: HostPlatform
    public var sshDestination: String?
    public var preferredTransport: HostTransport
    public var lastKnownReachable: Bool
    public var lastSeenAt: Date?
    public var remoteHostname: String?
    public var version: String?
    public var lastSnapshotAt: Date?
    public var remoteCapabilities: RemoteHostCapabilities?
    public var remoteDiagnostics: [RemoteHostDiagnostic]
    public var tmuxSessions: [TmuxSessionSummary]
    public var decodedConnectionState: HostConnectionState?
    public var transientOverride: HostConnectionState?
    public var operationAvailability:
        [String: OperationAvailabilityEntry]?

    public init(
        id: UUID,
        configKey: String = "",
        name: String,
        kind: HostKind,
        platform: HostPlatform,
        sshDestination: String? = nil,
        preferredTransport: HostTransport = .ssh,
        lastKnownReachable: Bool = true,
        lastSeenAt: Date? = nil,
        remoteHostname: String? = nil,
        version: String? = nil,
        lastSnapshotAt: Date? = nil,
        remoteCapabilities: RemoteHostCapabilities? = nil,
        remoteDiagnostics: [RemoteHostDiagnostic] = [],
        tmuxSessions: [TmuxSessionSummary] = [],
        decodedConnectionState: HostConnectionState? = nil,
        transientOverride: HostConnectionState? = nil,
        operationAvailability:
        [String: OperationAvailabilityEntry]? = nil
    ) {
        self.id = id
        self.configKey = configKey
        self.name = name
        self.kind = kind
        self.platform = platform
        self.sshDestination = sshDestination
        self.preferredTransport = preferredTransport
        self.lastKnownReachable = lastKnownReachable
        self.lastSeenAt = lastSeenAt
        self.remoteHostname = remoteHostname
        self.version = version
        self.lastSnapshotAt = lastSnapshotAt
        self.remoteCapabilities = remoteCapabilities
        self.remoteDiagnostics = remoteDiagnostics
        self.tmuxSessions = tmuxSessions
        self.decodedConnectionState = decodedConnectionState
        self.transientOverride = transientOverride
        self.operationAvailability = operationAvailability
    }

    public var connectionState: HostConnectionState {
        if let transientOverride {
            return transientOverride
        }
        if let decodedConnectionState {
            return decodedConnectionState
        }
        if kind == .selfHost {
            return .local
        }
        if !lastKnownReachable {
            return lastSeenAt == nil
                && lastSnapshotAt == nil
                && remoteDiagnostics.isEmpty
                ? .connecting
                : .offline
        }
        if !remoteDiagnostics.isEmpty {
            return .degraded
        }
        return lastSeenAt != nil
            || lastSnapshotAt != nil
            ? .online : .connecting
    }

    public var primaryDiagnostic: RemoteHostDiagnostic? {
        remoteDiagnostics.first
    }

    public var canRegisterProjects: Bool {
        platform != .windows
    }

    public var canCreateWorktree: Bool {
        if kind == .remote, connectionState == .offline {
            return false
        }
        if remoteDiagnostics.contains(
            where: \.blocksWorktreeCreate
        ) {
            return false
        }
        if let avail = operationAvailability?[
            "worktreeCreate"
        ] {
            return avail.available
        }
        return remoteCapabilities?.commands
            .worktreeCreate ?? true
    }

    public var canDeleteWorktree: Bool {
        if kind == .remote, connectionState == .offline {
            return false
        }
        if remoteDiagnostics.contains(
            where: {
                $0.blocksWorktreeCreate
                    || $0.blocksDurableSessions
            }
        ) {
            return false
        }
        guard let commands = remoteCapabilities?.commands else {
            return true
        }
        return commands.worktreeDelete && commands.sessionKill
    }

    public var canImportPullRequest: Bool {
        if let avail = operationAvailability?[
            "pullRequestImport"
        ] {
            return avail.available
        }
        if kind == .remote, connectionState == .offline {
            return false
        }
        if remoteDiagnostics.contains(
            where: \.blocksPullRequestImport
        ) {
            return false
        }
        return remoteCapabilities?.commands
            .worktreeImportPullRequest ?? true
    }

    public var createWorktreeUnavailableReason: String? {
        guard !canCreateWorktree else {
            return nil
        }
        if let avail = operationAvailability?[
            "worktreeCreate"
        ], !avail.available {
            return avail.unavailableReason
                ?? "Worktree creation is unavailable."
        }
        if connectionState == .offline {
            return "Reconnect the remote host over SSH"
                + " before creating worktrees."
        }
        return remoteDiagnostics
            .first(where: \.blocksWorktreeCreate)?
            .recoverySuggestion
            ?? "Remote host is not ready for worktree"
            + " creation."
    }

    public var importPullRequestUnavailableReason: String? {
        guard !canImportPullRequest else {
            return nil
        }
        if let avail = operationAvailability?[
            "pullRequestImport"
        ], !avail.available {
            return avail.unavailableReason
                ?? "Pull request import is unavailable."
        }
        if connectionState == .offline {
            return "Reconnect the remote host over SSH"
                + " before importing pull requests."
        }
        return remoteDiagnostics
            .first(where: \.blocksPullRequestImport)?
            .recoverySuggestion
            ?? "Remote host is not ready for pull"
            + " request import."
    }

}
