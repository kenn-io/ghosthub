import Foundation
import Testing
@testable import GhosthubPersistence

struct PresentationStateRepositoryTests {
    private let referenceDate = TestConstants.referenceDate

    @Test
    func upsertAndFetchLastViewedAt() throws {
        let db = try WorkspaceDatabase.inMemory()
        let hostID = "host-abc"
        let scopedKey = "wt:main"

        try db.presentationState.upsertLastViewedAt(
            hostID: hostID, scopedKey: scopedKey, at: referenceDate
        )

        let record = try db.presentationState.fetch(hostID: hostID, scopedKey: scopedKey)
        #expect(record?.lastViewedAt == referenceDate)
        #expect(record?.lastAgentActivity == nil)
    }

    @Test
    func upsertAndFetchLastAgentActivity() throws {
        let db = try WorkspaceDatabase.inMemory()
        let hostID = "host-abc"
        let scopedKey = "wt:main"

        try db.presentationState.upsertLastAgentActivity(
            hostID: hostID, scopedKey: scopedKey, at: referenceDate
        )

        let record = try db.presentationState.fetch(hostID: hostID, scopedKey: scopedKey)
        #expect(record?.lastAgentActivity == referenceDate)
        #expect(record?.lastViewedAt == nil)
    }

    @Test
    func fetchAllReturnsAllRows() throws {
        let db = try WorkspaceDatabase.inMemory()
        let later = referenceDate.addingTimeInterval(60)

        try db.presentationState.upsertLastViewedAt(
            hostID: "host-a", scopedKey: "wt:alpha", at: referenceDate
        )
        try db.presentationState.upsertLastViewedAt(
            hostID: "host-b", scopedKey: "wt:beta", at: later
        )

        let all = try db.presentationState.fetchAll()
        #expect(all.count == 2)
        #expect(all.contains { $0.hostID == "host-a" && $0.scopedKey == "wt:alpha" })
        #expect(all.contains { $0.hostID == "host-b" && $0.scopedKey == "wt:beta" })
    }

    @Test
    func deleteByKeyRemovesRow() throws {
        let db = try WorkspaceDatabase.inMemory()

        try db.presentationState.upsertLastViewedAt(
            hostID: "host-x", scopedKey: "wt:gone", at: referenceDate
        )
        try db.presentationState.upsertLastViewedAt(
            hostID: "host-x", scopedKey: "wt:kept", at: referenceDate
        )

        try db.presentationState.delete(hostID: "host-x", scopedKey: "wt:gone")

        let all = try db.presentationState.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.scopedKey == "wt:kept")
    }

    @Test
    func deleteExceptKeepsLiveKeysAndRemovesOthers() throws {
        let db = try WorkspaceDatabase.inMemory()

        try db.presentationState.upsertLastViewedAt(
            hostID: "host-1", scopedKey: "wt:live", at: referenceDate
        )
        try db.presentationState.upsertLastViewedAt(
            hostID: "host-1", scopedKey: "wt:stale", at: referenceDate
        )
        try db.presentationState.upsertLastViewedAt(
            hostID: "host-2", scopedKey: "wt:other", at: referenceDate
        )

        try db.presentationState.deleteExcept(liveKeys: ["host-1/wt:live"])

        let all = try db.presentationState.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.hostID == "host-1")
        #expect(all.first?.scopedKey == "wt:live")
    }
}
