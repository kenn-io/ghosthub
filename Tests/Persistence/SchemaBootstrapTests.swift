import Foundation
import GRDB
import Testing
@testable import GhosthubPersistence

@Suite("SchemaBootstrap")
struct SchemaBootstrapTests {

    // MARK: - 1. Schema bootstrap

    @Test("Schema bootstrap creates expected tables")
    func schemaBootstrapTables() throws {
        let db = try WorkspaceDatabase.inMemory()
        let tables = try getSQLiteObjectNames(
            in: db, type: "table"
        )
        let expected: Set = [
            "terminal_sessions",
            "preferences",
            "presentation_state",
        ]
        for name in expected {
            #expect(
                tables.contains(name),
                "Missing table: \(name)"
            )
        }
        #expect(!tables.contains("worktree_layouts"))
        #expect(!tables.contains("console_layouts"))
    }

    @Test("version 18 layout schema is reset before release")
    func version18LayoutSchemaIsReset() throws {
        try withTempDatabaseURL { url in
            let old = try DatabaseQueue(path: url.path)
            try old.write { db in
                try db.execute(sql: "CREATE TABLE worktree_layouts (id TEXT)")
                try db.execute(sql: "CREATE TABLE console_layouts (id TEXT)")
                try db.execute(sql: "PRAGMA user_version = 18")
            }

            let database = try WorkspaceDatabase(url: url)
            let tables = try getSQLiteObjectNames(in: database, type: "table")
            let version = try database.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version")
            }

            #expect(!tables.contains("worktree_layouts"))
            #expect(!tables.contains("console_layouts"))
            #expect(tables.contains("terminal_sessions"))
            #expect(version == 19)
        }
    }

    // MARK: - 2. WAL journal mode

    @Test("File-backed database uses WAL journal mode")
    func walJournalMode() throws {
        try withTempDatabaseURL { url in
            let db = try WorkspaceDatabase(url: url)
            let mode: String = try db.read { db in
                try String.fetchOne(
                    db,
                    sql: "PRAGMA journal_mode"
                ) ?? ""
            }
            #expect(mode == "wal")
        }
    }
}
