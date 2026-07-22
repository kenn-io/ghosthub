import Foundation
import GRDB
import GhosthubWorkspace

public struct TerminalSessionRepository {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func fetchAll(
        hostID: UUID? = nil,
        worktreeID: UUID? = nil,
        aliveOnly: Bool = false
    ) throws -> [TerminalSessionRecord] {
        try dbQueue.read { db in
            switch (hostID, worktreeID, aliveOnly) {
            case let (.some(hostID), .some(worktreeID), true):
                return try TerminalSessionRecord.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM terminal_sessions
                    WHERE host_id = ? AND worktree_id = ? AND is_alive = 1
                    ORDER BY updated_at DESC, created_at DESC
                    """,
                    arguments: [hostID.uuidString, worktreeID.uuidString]
                )
            case let (.some(hostID), .some(worktreeID), false):
                return try TerminalSessionRecord.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM terminal_sessions
                    WHERE host_id = ? AND worktree_id = ?
                    ORDER BY updated_at DESC, created_at DESC
                    """,
                    arguments: [hostID.uuidString, worktreeID.uuidString]
                )
            case let (.some(hostID), .none, true):
                return try TerminalSessionRecord.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM terminal_sessions
                    WHERE host_id = ? AND is_alive = 1
                    ORDER BY updated_at DESC, created_at DESC
                    """,
                    arguments: [hostID.uuidString]
                )
            case let (.some(hostID), .none, false):
                return try TerminalSessionRecord.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM terminal_sessions
                    WHERE host_id = ?
                    ORDER BY updated_at DESC, created_at DESC
                    """,
                    arguments: [hostID.uuidString]
                )
            case (.none, .none, true):
                return try TerminalSessionRecord.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM terminal_sessions
                    WHERE is_alive = 1
                    ORDER BY updated_at DESC, created_at DESC
                    """
                )
            case (.none, .none, false):
                return try TerminalSessionRecord.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM terminal_sessions
                    ORDER BY updated_at DESC, created_at DESC
                    """
                )
            case (.none, .some, _):
                preconditionFailure("worktreeID filtering requires a hostID")
            }
        }
    }

    public func fetch(id: UUID, hostID: UUID) throws -> TerminalSessionRecord? {
        try dbQueue.read { db in
            try TerminalSessionRecord.fetchOne(
                db,
                sql: """
                SELECT *
                FROM terminal_sessions
                WHERE host_id = ? AND id = ?
                """,
                arguments: [hostID.uuidString, id.uuidString]
            )
        }
    }

    public func fetch(hostID: UUID, scopedKey: String) throws -> TerminalSessionRecord? {
        try dbQueue.read { db in
            try TerminalSessionRecord.fetchOne(
                db,
                sql: """
                SELECT *
                FROM terminal_sessions
                WHERE host_id = ? AND scoped_key = ?
                """,
                arguments: [hostID.uuidString, scopedKey]
            )
        }
    }

    public func fetch(
        hostID: UUID,
        scopedKey: String,
        backend: SessionBackendKind
    ) throws -> TerminalSessionRecord? {
        try dbQueue.read { db in
            try TerminalSessionRecord.fetchOne(
                db,
                sql: """
                SELECT *
                FROM terminal_sessions
                WHERE host_id = ? AND scoped_key = ? AND backend = ?
                """,
                arguments: [hostID.uuidString, scopedKey, backend.rawValue]
            )
        }
    }

    @discardableResult
    public func upsert(_ session: TerminalSessionRecord) throws -> TerminalSessionRecord {
        try dbQueue.write { db in
            try Self.upsert(session, in: db)
        }
    }

    static func upsert(
        _ session: TerminalSessionRecord,
        in db: Database
    ) throws -> TerminalSessionRecord {
        let existing = try TerminalSessionRecord.fetchOne(
            db,
            sql: """
            SELECT *
            FROM terminal_sessions
            WHERE host_id = ? AND scoped_key = ? AND backend = ?
            """,
            arguments: [session.hostID.uuidString, session.scopedKey, session.backend.rawValue]
        )

        var merged = session
        if let existing {
            merged.id = existing.id
            merged.createdAt = existing.createdAt
        }

        try db.execute(
            sql: """
            INSERT INTO terminal_sessions (
                id,
                host_id,
                worktree_id,
                scoped_key,
                preset_id,
                kind,
                launch_mode,
                backend,
                working_directory,
                command,
                child_pid,
                remote_locator,
                tmux_session_name,
                is_alive,
                restart_policy,
                last_exit_code,
                last_output_at,
                last_seen_in_snapshot_at,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                host_id = excluded.host_id,
                worktree_id = excluded.worktree_id,
                scoped_key = excluded.scoped_key,
                preset_id = excluded.preset_id,
                kind = excluded.kind,
                launch_mode = excluded.launch_mode,
                backend = excluded.backend,
                working_directory = excluded.working_directory,
                command = excluded.command,
                child_pid = excluded.child_pid,
                remote_locator = excluded.remote_locator,
                tmux_session_name = excluded.tmux_session_name,
                is_alive = excluded.is_alive,
                restart_policy = excluded.restart_policy,
                last_exit_code = excluded.last_exit_code,
                last_output_at = excluded.last_output_at,
                last_seen_in_snapshot_at = excluded.last_seen_in_snapshot_at,
                updated_at = excluded.updated_at
            """,
            arguments: [
                merged.id.uuidString,
                merged.hostID.uuidString,
                merged.worktreeID?.uuidString,
                merged.scopedKey,
                merged.presetID,
                merged.kind.rawValue,
                merged.launchMode.rawValue,
                merged.backend.rawValue,
                merged.workingDirectory,
                merged.command,
                merged.childPID,
                merged.remoteLocator,
                merged.tmuxSessionName,
                merged.isAlive,
                merged.restartPolicy.rawValue,
                merged.lastExitCode,
                merged.lastOutputAt,
                merged.lastSeenInSnapshotAt,
                merged.createdAt,
                merged.updatedAt,
            ]
        )

        return merged
    }

    public func delete(id: UUID, hostID: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM terminal_sessions
                WHERE host_id = ? AND id = ?
                """,
                arguments: [hostID.uuidString, id.uuidString]
            )
        }
    }

    public func updateLastOutputAt(
        sessionID: UUID,
        at date: Date
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE terminal_sessions
                SET last_output_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [date, date, sessionID.uuidString]
            )
        }
    }

    public func markLocalSessionsOffline(at updatedAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE terminal_sessions
                SET is_alive = 0,
                    child_pid = NULL,
                    updated_at = ?
                WHERE backend = ? AND is_alive = 1
                """,
                arguments: [updatedAt, SessionBackendKind.localPTY.rawValue]
            )
        }
    }

    /// Marks local tmux sessions offline for any scoped key not in `aliveScopedKeys`.
    ///
    /// Called on app launch to purge records for tmux sessions that exited while
    /// the app was closed. Sessions present in `aliveScopedKeys` are left untouched.
    public func markLocalTmuxSessionsOffline(
        aliveScopedKeys: Set<String>,
        at updatedAt: Date
    ) throws {
        try dbQueue.write { db in
            let sessions = try TerminalSessionRecord.fetchAll(
                db,
                sql: """
                SELECT *
                FROM terminal_sessions
                WHERE backend = ? AND is_alive = 1
                """,
                arguments: [SessionBackendKind.localTmux.rawValue]
            )

            for session in sessions where !aliveScopedKeys.contains(session.scopedKey) {
                try db.execute(
                    sql: """
                    UPDATE terminal_sessions
                    SET is_alive = 0,
                        remote_locator = NULL,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [updatedAt, session.id.uuidString]
                )
            }
        }
    }
}
