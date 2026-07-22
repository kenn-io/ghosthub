import Foundation
import GRDB
import GhosthubWorkspace

public struct TerminalSessionRecord: Codable, FetchableRecord, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var worktreeID: UUID?
    public var scopedKey: String
    public var presetID: String?
    public var kind: SessionKind
    public var launchMode: LaunchMode
    public var backend: SessionBackendKind
    public var workingDirectory: String?
    public var command: String?
    public var childPID: Int32?
    public var remoteLocator: String?
    public var tmuxSessionName: String?
    public var isAlive: Bool
    public var restartPolicy: RestartPolicy
    public var lastExitCode: Int32?
    public var lastOutputAt: Date?
    public var lastSeenInSnapshotAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        hostID: UUID,
        worktreeID: UUID? = nil,
        scopedKey: String,
        presetID: String? = nil,
        kind: SessionKind,
        launchMode: LaunchMode,
        backend: SessionBackendKind,
        workingDirectory: String? = nil,
        command: String? = nil,
        childPID: Int32? = nil,
        remoteLocator: String? = nil,
        tmuxSessionName: String? = nil,
        isAlive: Bool,
        restartPolicy: RestartPolicy,
        lastExitCode: Int32? = nil,
        lastOutputAt: Date? = nil,
        lastSeenInSnapshotAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.hostID = hostID
        self.worktreeID = worktreeID
        self.scopedKey = scopedKey
        self.presetID = presetID
        self.kind = kind
        self.launchMode = launchMode
        self.backend = backend
        self.workingDirectory = workingDirectory
        self.command = command
        self.childPID = childPID
        self.remoteLocator = remoteLocator
        self.tmuxSessionName = tmuxSessionName
        self.isAlive = isAlive
        self.restartPolicy = restartPolicy
        self.lastExitCode = lastExitCode
        self.lastOutputAt = lastOutputAt
        self.lastSeenInSnapshotAt = lastSeenInSnapshotAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case hostID = "host_id"
        case worktreeID = "worktree_id"
        case scopedKey = "scoped_key"
        case presetID = "preset_id"
        case kind
        case launchMode = "launch_mode"
        case backend
        case workingDirectory = "working_directory"
        case command
        case childPID = "child_pid"
        case remoteLocator = "remote_locator"
        case tmuxSessionName = "tmux_session_name"
        case isAlive = "is_alive"
        case restartPolicy = "restart_policy"
        case lastExitCode = "last_exit_code"
        case lastOutputAt = "last_output_at"
        case lastSeenInSnapshotAt = "last_seen_in_snapshot_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension TerminalSessionRecord {
    public var activityHint: WorkspaceActivitySessionHint {
        WorkspaceActivitySessionHint(
            presetID: presetID,
            command: command
        )
    }
}

public struct PreferenceEntry: Codable, FetchableRecord, Equatable, Sendable {
    public var key: String
    public var valueJSON: String
    public var updatedAt: Date

    public init(key: String, valueJSON: String, updatedAt: Date) {
        self.key = key
        self.valueJSON = valueJSON
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case key
        case valueJSON = "value_json"
        case updatedAt = "updated_at"
    }
}

public struct PresentationStateRecord: Codable, FetchableRecord, Equatable, Sendable {
    public var hostID: String
    public var scopedKey: String
    public var lastViewedAt: Date?
    public var lastAgentActivity: Date?

    public init(
        hostID: String,
        scopedKey: String,
        lastViewedAt: Date? = nil,
        lastAgentActivity: Date? = nil
    ) {
        self.hostID = hostID
        self.scopedKey = scopedKey
        self.lastViewedAt = lastViewedAt
        self.lastAgentActivity = lastAgentActivity
    }

    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case scopedKey = "scoped_key"
        case lastViewedAt = "last_viewed_at"
        case lastAgentActivity = "last_agent_activity"
    }
}
