import Foundation
import GRDB
import GhosthubWorkspace

public final class WorkspaceDatabase: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public let terminalSessions: TerminalSessionRepository
    public let preferences: PreferenceRepository
    public let presentationState: PresentationStateRepository

    public convenience init(path: String) throws {
        try self.init(url: URL(fileURLWithPath: path))
    }

    public convenience init(url: URL, fileManager: FileManager = .default) throws {
        let directoryURL = url.deletingLastPathComponent()

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let dbQueue = try DatabaseQueue(path: url.path)
        try Self.prepareDatabase(dbQueue)
        try DatabaseSchema.bootstrap(dbQueue)
        self.init(dbQueue: dbQueue)
    }

    public static func inMemory() throws -> WorkspaceDatabase {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        try Self.prepareDatabase(dbQueue)
        try DatabaseSchema.bootstrap(dbQueue)
        return WorkspaceDatabase(dbQueue: dbQueue)
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let ghosthubDirectory = StateHome.resolved(fileManager: fileManager)
        try fileManager.createDirectory(at: ghosthubDirectory, withIntermediateDirectories: true)
        return ghosthubDirectory.appendingPathComponent("ghosthub.db")
    }

    public func read<Value>(_ value: (Database) throws -> Value) throws -> Value {
        try dbQueue.read(value)
    }

    public func write<Value>(_ updates: (Database) throws -> Value) throws -> Value {
        try dbQueue.write(updates)
    }

    /// Stub snapshot assembly from session-only tables.
    /// Full snapshot assembly from daemon data is a future task.
    public func fetchSessionSnapshot() throws -> WorkspaceSnapshot {
        try dbQueue.read { db in
            let sessions = try TerminalSessionRecord.fetchAll(
                db,
                sql: """
                SELECT *
                FROM terminal_sessions
                ORDER BY updated_at DESC, created_at DESC
                """
            )
            return WorkspaceSnapshot(
                hosts: [],
                projects: [],
                worktrees: [],
                sessions: sessions.map { session in
                    TerminalSessionSummary(
                        id: session.id,
                        hostID: session.hostID,
                        worktreeID: session.worktreeID,
                        childPID: session.childPID,
                        isAlive: session.isAlive,
                        lastOutputAt: session.lastOutputAt
                    )
                }
            )
        }
    }

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        terminalSessions = TerminalSessionRepository(dbQueue: dbQueue)
        preferences = PreferenceRepository(dbQueue: dbQueue)
        presentationState = PresentationStateRepository(dbQueue: dbQueue)
    }

    private static func prepareDatabase(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }
}
