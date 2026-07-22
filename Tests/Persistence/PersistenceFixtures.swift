import Foundation
import GRDB
import GhosthubTestSupport
import Testing
@testable import GhosthubPersistence
import GhosthubWorkspace

enum TestConstants {
    static let referenceDate = Date(
        timeIntervalSince1970: 1_700_000_000
    )
}

// MARK: - Temp Database URL

func withTempDatabaseURL<T>(
    perform body: (URL) throws -> T
) throws -> T {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: tempDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let databaseURL = tempDirectory
        .appendingPathComponent("ghosthub.db")
    return try body(databaseURL)
}

// MARK: - SQLite Schema Introspection

func getSQLiteObjectNames(
    in database: WorkspaceDatabase,
    type: String
) throws -> [String] {
    try database.read { db in
        try Row.fetchAll(
            db,
            sql: """
            SELECT name
            FROM sqlite_master
            WHERE type = ? AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """,
            arguments: [type]
        ).compactMap { row in
            row["name"] as String?
        }
    }
}

func getTableColumns(
    in database: WorkspaceDatabase,
    table: String
) throws -> [String] {
    try database.read { db in
        try Row.fetchAll(
            db,
            sql: "PRAGMA table_info(\(table))"
        ).compactMap { row in
            row["name"] as String?
        }
    }
}

func expectDatesClose(
    _ date1: Date?,
    _ date2: Date?,
    tolerance: TimeInterval = 1.0,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let d1 = try #require(
        date1, sourceLocation: sourceLocation
    )
    let d2 = try #require(
        date2, sourceLocation: sourceLocation
    )
    #expect(
        abs(d1.timeIntervalSince1970 - d2.timeIntervalSince1970)
            < tolerance,
        sourceLocation: sourceLocation
    )
}

// MARK: - Model Builders

/// Stable UUID namespace for persistence test fixtures.
/// Deterministic IDs are now daemon-owned; tests use
/// a simple hash-based derivation for consistency.
private func testUUID(_ seed: String) -> UUID {
    var hash = seed.utf8.reduce(UInt64(0)) {
        acc, byte in
        var h = acc &* 31 &+ UInt64(byte)
        h ^= h >> 16
        return h
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in 0 ..< 8 {
        bytes[i] = UInt8(hash & 0xFF)
        hash >>= 8
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
        uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
    )
}

/// Creates a minimal HostSummary for testing.
func makePersistenceHost(
    configKey: String = "",
    kind: HostKind = .selfHost
) -> HostSummary {
    HostSummary(
        id: testUUID("host:\(configKey)"),
        configKey: configKey,
        name: "Test Host",
        kind: kind,
        platform: .macOS
    )
}

/// Creates a WorktreeSummary with a stable test ID.
func makePersistenceWorktree(
    hostConfigKey: String = "",
    scopedKey: String
) -> WorktreeSummary {
    let hostID = testUUID("host:\(hostConfigKey)")
    let wtID = testUUID(
        "\(hostConfigKey)\0\(scopedKey)"
    )
    return WorktreeSummary(
        id: wtID,
        hostID: hostID,
        projectID: UUID(),
        scopedKey: scopedKey,
        name: scopedKey,
        path: "/tmp/\(scopedKey)",
        branch: "main"
    )
}

func makePersistenceSnapshot(
    hosts: [HostSummary] = [],
    worktrees: [WorktreeSummary] = []
) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
        hosts: hosts, projects: [], worktrees: worktrees
    )
}

@discardableResult
func insertWorktreeSession(
    db: WorkspaceDatabase,
    hostID: UUID,
    worktreeID: UUID,
    scopedKey: String? = nil,
    isAlive: Bool = true
) throws -> TerminalSessionRecord {
    let record = TerminalSessionRecord.fixture(
        hostID: hostID,
        worktreeID: worktreeID,
        scopedKey: scopedKey,
        isAlive: isAlive
    )
    return try db.terminalSessions.upsert(record)
}

@discardableResult
func insertConsoleSession(
    db: WorkspaceDatabase,
    hostID: UUID,
    scopedKey: String? = nil,
    isAlive: Bool = true
) throws -> TerminalSessionRecord {
    let record = TerminalSessionRecord.fixture(
        hostID: hostID,
        worktreeID: nil,
        scopedKey: scopedKey,
        isAlive: isAlive
    )
    return try db.terminalSessions.upsert(record)
}
