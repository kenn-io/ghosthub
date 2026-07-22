import Foundation
import GRDB

public struct PreferenceRepository {
    private let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func fetchAll() throws -> [PreferenceEntry] {
        try dbQueue.read { db in
            try PreferenceEntry.fetchAll(
                db,
                sql: """
                SELECT *
                FROM preferences
                ORDER BY key
                """
            )
        }
    }

    public func value<Value: Decodable>(
        forKey key: String,
        as type: Value.Type = Value.self
    ) throws -> Value? {
        let entry = try dbQueue.read { db in
            try PreferenceEntry.fetchOne(
                db,
                sql: """
                SELECT *
                FROM preferences
                WHERE key = ?
                """,
                arguments: [key]
            )
        }

        guard let entry else {
            return nil
        }

        let data = Data(entry.valueJSON.utf8)
        return try decoder.decode(type, from: data)
    }

    public func set<Value: Encodable>(
        _ value: Value,
        forKey key: String,
        updatedAt: Date = Date()
    ) throws {
        let data = try encoder.encode(value)
        let valueJSON = String(decoding: data, as: UTF8.self)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO preferences (
                    key,
                    value_json,
                    updated_at
                ) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [key, valueJSON, updatedAt]
            )
        }
    }

    public func delete(key: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM preferences
                WHERE key = ?
                """,
                arguments: [key]
            )
        }
    }
}
