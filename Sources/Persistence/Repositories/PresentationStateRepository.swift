import Foundation
import GRDB

public struct PresentationStateRepository {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func fetch(hostID: String, scopedKey: String) throws -> PresentationStateRecord? {
        try dbQueue.read { db in
            try PresentationStateRecord.fetchOne(
                db,
                sql: """
                SELECT *
                FROM presentation_state
                WHERE host_id = ? AND scoped_key = ?
                """,
                arguments: [hostID, scopedKey]
            )
        }
    }

    public func fetchAll() throws -> [PresentationStateRecord] {
        try dbQueue.read { db in
            try PresentationStateRecord.fetchAll(
                db,
                sql: """
                SELECT *
                FROM presentation_state
                ORDER BY host_id, scoped_key
                """
            )
        }
    }

    public func upsertLastViewedAt(
        hostID: String,
        scopedKey: String,
        at date: Date
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO presentation_state (host_id, scoped_key, last_viewed_at)
                VALUES (?, ?, ?)
                ON CONFLICT(host_id, scoped_key) DO UPDATE SET
                    last_viewed_at = excluded.last_viewed_at
                """,
                arguments: [hostID, scopedKey, date]
            )
        }
    }

    public func upsertLastAgentActivity(
        hostID: String,
        scopedKey: String,
        at date: Date
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO presentation_state (host_id, scoped_key, last_agent_activity)
                VALUES (?, ?, ?)
                ON CONFLICT(host_id, scoped_key) DO UPDATE SET
                    last_agent_activity = excluded.last_agent_activity
                """,
                arguments: [hostID, scopedKey, date]
            )
        }
    }

    public func delete(hostID: String, scopedKey: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM presentation_state
                WHERE host_id = ? AND scoped_key = ?
                """,
                arguments: [hostID, scopedKey]
            )
        }
    }

    /// Deletes all rows whose composite key "hostID/scopedKey" is not in `liveKeys`.
    public func deleteExcept(liveKeys: Set<String>) throws {
        try dbQueue.write { db in
            if liveKeys.isEmpty {
                try db.execute(sql: "DELETE FROM presentation_state")
                return
            }

            let placeholders = liveKeys
                .map { _ in "?" }
                .joined(separator: ", ")
            let compositeKeys = liveKeys.map { DatabaseValue(value: $0) }
            try db.execute(
                sql: """
                DELETE FROM presentation_state
                WHERE (host_id || '/' || scoped_key) NOT IN (\(placeholders))
                """,
                arguments: StatementArguments(compositeKeys)
            )
        }
    }
}
