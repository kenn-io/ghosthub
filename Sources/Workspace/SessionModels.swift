import Foundation

public enum SessionBackendKind: String, CaseIterable, Equatable, Sendable {
    case localPTY
    case localTmux
    case remoteTmux
    /// Legacy persistence value retained so old databases can be cleaned up.
    /// New sessions never resolve to this backend.
    case controlModeTmux
}

extension SessionBackendKind: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer()
            .decode(String.self)
        switch raw.lowercased() {
        // A registered worktree with no active session carries no explicit
        // backend; legacy snapshots may emit an empty string. Treat the
        // absence as the default local-PTY backend rather than a decode error.
        case "", "localpty": self = .localPTY
        case "localtmux": self = .localTmux
        case "remotetmux": self = .remoteTmux
        case "controlmodetmux": self = .controlModeTmux
        default:
            // Fall back to exact raw value match.
            guard let v = SessionBackendKind(
                rawValue: raw
            ) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription:
                        "Unknown session backend:"
                            + " \(raw)"
                    )
                )
            }
            self = v
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public enum WorkspaceSessionBackendResolver {
    public static func backend(
        hostID: UUID,
        worktreeID: UUID?,
        in snapshot: WorkspaceSnapshot
    ) -> SessionBackendKind {
        if let worktreeID,
           let worktree = snapshot.worktree(id: worktreeID) {
            return worktree.sessionBackend
        }
        guard snapshot.host(id: hostID)?.kind == .remote else {
            return .localPTY
        }
        return .remoteTmux
    }
}

/// Session intent reported by host inventory's `runtimeKind` field:
/// what the session is for, distinct from ``SessionBackendKind`` (how it is
/// hosted). Legacy snapshots may still contain this vocabulary.
public enum SessionRuntimeKind: String, CaseIterable, Equatable, Sendable {
    case tmux
    case agent
    case plainShell = "plain_shell"
}

public struct TmuxWindowSummary: Codable, Equatable, Sendable {
    public var id: String
    public var index: Int
    public var name: String
    public var activity: String?

    public init(
        id: String, index: Int,
        name: String, activity: String? = nil
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.activity = activity
    }
}

public struct TmuxSessionSummary: Codable, Equatable, Sendable {
    public var name: String
    public var managed: Bool
    public var worktreeKey: String?
    public var windows: [TmuxWindowSummary]
    public var serverPID: String?
    public var sessionID: String?
    public var createdAt: String?

    public init(
        name: String, managed: Bool,
        worktreeKey: String? = nil,
        windows: [TmuxWindowSummary],
        serverPID: String? = nil,
        sessionID: String? = nil,
        createdAt: String? = nil
    ) {
        self.name = name
        self.managed = managed
        self.worktreeKey = worktreeKey
        self.windows = windows
        self.serverPID = serverPID
        self.sessionID = sessionID
        self.createdAt = createdAt
    }

    public var hasStableIdentity: Bool {
        guard let serverPID, let sessionID, let createdAt else {
            return false
        }
        return Self.isNumericIdentity(serverPID)
            && sessionID.utf8.first == 36
            && sessionID.utf8.count > 1
            && Self.isNumericIdentity(String(sessionID.dropFirst()))
            && Self.isNumericIdentity(createdAt)
    }

    private static func isNumericIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte >= 48 && byte <= 57
        }
    }
}
public struct TerminalSessionSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var hostID: UUID
    public var worktreeID: UUID?
    public var scopedKey: String?
    public var childPID: Int32?
    public var runtimeKind: SessionRuntimeKind?
    public var status: HostSessionStatus?
    public var isAlive: Bool
    public var cpuPercent: Double?
    public var residentMB: Int?
    public var processCount: Int?
    public var lastOutputAt: Date?
    public var lastActiveAt: Date?

    public init(
        id: UUID,
        hostID: UUID,
        worktreeID: UUID? = nil,
        scopedKey: String? = nil,
        childPID: Int32? = nil,
        runtimeKind: SessionRuntimeKind? = nil,
        status: HostSessionStatus? = nil,
        isAlive: Bool,
        cpuPercent: Double? = nil,
        residentMB: Int? = nil,
        processCount: Int? = nil,
        lastOutputAt: Date? = nil,
        lastActiveAt: Date? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.worktreeID = worktreeID
        self.scopedKey = scopedKey
        self.childPID = childPID
        self.runtimeKind = runtimeKind
        self.status = status
        self.isAlive = isAlive
        self.cpuPercent = cpuPercent
        self.residentMB = residentMB
        self.processCount = processCount
        self.lastOutputAt = lastOutputAt
        self.lastActiveAt = lastActiveAt
    }
}
