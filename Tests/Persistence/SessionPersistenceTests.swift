import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubPersistence

@Suite("SessionPersistence")
struct SessionPersistenceTests {
    private let hostID = UUID()
    private let referenceDate = TestConstants.referenceDate

    private func makeSession(
        worktreeID: UUID? = nil,
        backend: SessionBackendKind = .remoteTmux
    ) -> TerminalSessionRecord {
        TerminalSessionRecord.fixture(
            hostID: hostID,
            worktreeID: worktreeID,
            backend: backend,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
    }

    @Test("Upsert and fetch terminal session")
    func terminalSessionCRUD() throws {
        let db = try WorkspaceDatabase.inMemory()
        let worktreeID = UUID()
        let saved = try db.terminalSessions.upsert(
            makeSession(worktreeID: worktreeID, backend: .localPTY)
        )

        let result = try #require(
            try db.terminalSessions.fetch(id: saved.id, hostID: hostID)
        )
        #expect(result.worktreeID == worktreeID)
        #expect(result.backend == .localPTY)
        #expect(result.isAlive)
    }

    @Test("updateLastOutputAt changes timestamp")
    func terminalSessionLastOutputAt() throws {
        let db = try WorkspaceDatabase.inMemory()
        let saved = try db.terminalSessions.upsert(makeSession())
        let outputDate = referenceDate.addingTimeInterval(300)

        try db.terminalSessions.updateLastOutputAt(
            sessionID: saved.id,
            at: outputDate
        )

        let fetched = try #require(
            try db.terminalSessions.fetch(id: saved.id, hostID: hostID)
        )
        try expectDatesClose(fetched.lastOutputAt, outputDate)
    }
}
