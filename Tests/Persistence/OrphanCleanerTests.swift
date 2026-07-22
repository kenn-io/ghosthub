import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubPersistence

@Suite("OrphanCleaner")
struct OrphanCleanerTests {
    @Test("runtime removal marks worktree sessions dead")
    func runtimeWorktreeRemoval() throws {
        let db = try WorkspaceDatabase.inMemory()
        let host = makePersistenceHost()
        let worktree = makePersistenceWorktree(scopedKey: "repo/feature")
        let session = try insertWorktreeSession(
            db: db,
            hostID: worktree.hostID,
            worktreeID: worktree.id
        )

        try OrphanCleaner.cleanupDiff(
            previous: makePersistenceSnapshot(
                hosts: [host],
                worktrees: [worktree]
            ),
            current: makePersistenceSnapshot(hosts: [host]),
            database: db
        )

        #expect(
            try db.terminalSessions.fetch(
                id: session.id,
                hostID: session.hostID
            )?.isAlive == false
        )
    }

    @Test("runtime host removal marks its console sessions dead")
    func runtimeHostRemoval() throws {
        let db = try WorkspaceDatabase.inMemory()
        let host = makePersistenceHost(configKey: "builder", kind: .remote)
        let session = try insertConsoleSession(db: db, hostID: host.id)

        try OrphanCleaner.cleanupDiff(
            previous: makePersistenceSnapshot(hosts: [host]),
            current: .empty,
            database: db
        )

        #expect(
            try db.terminalSessions.fetch(
                id: session.id,
                hostID: session.hostID
            )?.isAlive == false
        )
    }

    @Test("cold start preserves live worktree sessions")
    func coldStartPreservesLiveWorktree() throws {
        let db = try WorkspaceDatabase.inMemory()
        let host = makePersistenceHost()
        let worktree = makePersistenceWorktree(scopedKey: "repo/main")
        let session = try insertWorktreeSession(
            db: db,
            hostID: worktree.hostID,
            worktreeID: worktree.id
        )

        try OrphanCleaner.cleanupColdStart(
            snapshot: makePersistenceSnapshot(
                hosts: [host],
                worktrees: [worktree]
            ),
            database: db
        )

        #expect(
            try db.terminalSessions.fetch(
                id: session.id,
                hostID: session.hostID
            )?.isAlive == true
        )
    }

    @Test("cold start marks an absent worktree session dead")
    func coldStartRemovesAbsentWorktree() throws {
        let db = try WorkspaceDatabase.inMemory()
        let host = makePersistenceHost()
        let worktree = makePersistenceWorktree(scopedKey: "repo/gone")
        let session = try insertWorktreeSession(
            db: db,
            hostID: worktree.hostID,
            worktreeID: worktree.id
        )

        try OrphanCleaner.cleanupColdStart(
            snapshot: makePersistenceSnapshot(hosts: [host]),
            database: db
        )

        #expect(
            try db.terminalSessions.fetch(
                id: session.id,
                hostID: session.hostID
            )?.isAlive == false
        )
    }

    @Test("cold start preserves a console session for a present host")
    func coldStartPreservesLiveConsole() throws {
        let db = try WorkspaceDatabase.inMemory()
        let host = makePersistenceHost(configKey: "builder", kind: .remote)
        let session = try insertConsoleSession(db: db, hostID: host.id)

        try OrphanCleaner.cleanupColdStart(
            snapshot: makePersistenceSnapshot(hosts: [host]),
            database: db
        )

        #expect(
            try db.terminalSessions.fetch(
                id: session.id,
                hostID: session.hostID
            )?.isAlive == true
        )
    }

    @Test("cold start removes stale presentation rows")
    func coldStartRemovesPresentationRows() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.presentationState.upsertLastViewedAt(
            hostID: "gone",
            scopedKey: "repo/gone",
            at: Date()
        )

        try OrphanCleaner.cleanupColdStart(
            snapshot: .empty,
            database: db
        )

        #expect(try db.presentationState.fetchAll().isEmpty)
    }

    @Test("cold start preserves only presentation rows in inventory")
    func coldStartSelectivelyPreservesPresentationRows() throws {
        let db = try WorkspaceDatabase.inMemory()
        let host = makePersistenceHost(configKey: "builder", kind: .remote)
        let worktree = makePersistenceWorktree(
            hostConfigKey: "builder",
            scopedKey: "repo/live"
        )
        try db.presentationState.upsertLastViewedAt(
            hostID: host.configKey,
            scopedKey: worktree.scopedKey,
            at: Date()
        )
        try db.presentationState.upsertLastViewedAt(
            hostID: host.configKey,
            scopedKey: "repo/gone",
            at: Date()
        )

        try OrphanCleaner.cleanupColdStart(
            snapshot: makePersistenceSnapshot(
                hosts: [host],
                worktrees: [worktree]
            ),
            database: db
        )

        let remaining = try db.presentationState.fetchAll()
        #expect(remaining.map(\.scopedKey) == [worktree.scopedKey])
    }
}
