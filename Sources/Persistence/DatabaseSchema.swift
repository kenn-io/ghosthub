import GRDB

enum DatabaseSchema {
    static let preReleaseSchemaVersion = 19

    private static let managedTableNames = [
        "worktree_layouts",
        "console_layouts",
        "terminal_sessions",
        "preferences",
        "presentation_state",
        "grdb_migrations",
    ]

    static func bootstrap(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try reconcilePreReleaseSchema(in: db)
            try createSessionPersistenceTables(in: db)
            try createSupportTables(in: db)
            try db.execute(sql: "PRAGMA user_version = \(preReleaseSchemaVersion)")
        }
    }

    private static func reconcilePreReleaseSchema(in db: Database) throws {
        try db.execute(sql: "DROP TABLE IF EXISTS grdb_migrations")
        guard try shouldResetManagedSchema(in: db) else {
            return
        }

        for tableName in managedTableNames {
            try db.execute(sql: "DROP TABLE IF EXISTS \(tableName)")
        }
    }

    private static func shouldResetManagedSchema(in db: Database) throws -> Bool {
        let managedTableCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%'
              AND name != 'grdb_migrations'
            """
        ) ?? 0

        guard managedTableCount > 0 else {
            return false
        }

        let existingVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        return existingVersion < preReleaseSchemaVersion
    }

    private static func createSessionPersistenceTables(in db: Database) throws {
        try execute(
            [
                """
                CREATE TABLE IF NOT EXISTS terminal_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    host_id TEXT NOT NULL,
                    worktree_id TEXT,
                    scoped_key TEXT NOT NULL,
                    preset_id TEXT,
                    kind TEXT NOT NULL,
                    launch_mode TEXT NOT NULL,
                    backend TEXT NOT NULL,
                    working_directory TEXT,
                    command TEXT,
                    child_pid INTEGER,
                    remote_locator TEXT,
                    tmux_session_name TEXT,
                    is_alive INTEGER NOT NULL,
                    restart_policy TEXT NOT NULL,
                    last_exit_code INTEGER,
                    last_output_at DATETIME,
                    last_seen_in_snapshot_at DATETIME,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE(host_id, id),
                    UNIQUE(host_id, scoped_key, backend)
                )
                """,
                """
                CREATE INDEX IF NOT EXISTS terminal_sessions_host_worktree_alive_idx
                ON terminal_sessions(host_id, worktree_id, is_alive)
                """,
            ],
            in: db
        )
    }

    private static func createSupportTables(in db: Database) throws {
        try execute(
            [
                """
                CREATE TABLE IF NOT EXISTS preferences (
                    key TEXT PRIMARY KEY NOT NULL,
                    value_json TEXT NOT NULL,
                    updated_at DATETIME NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS presentation_state (
                    host_id TEXT NOT NULL,
                    scoped_key TEXT NOT NULL,
                    last_viewed_at DATETIME,
                    last_agent_activity DATETIME,
                    PRIMARY KEY (host_id, scoped_key)
                )
                """,
            ],
            in: db
        )
    }

    private static func execute(_ statements: [String], in db: Database) throws {
        for statement in statements {
            try db.execute(sql: statement)
        }
    }
}
