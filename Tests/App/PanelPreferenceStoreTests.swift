import Testing
@testable import GhosthubApp
import GhosthubPersistence

@MainActor
struct PanelPreferenceStoreTests {
    @Test("panel visibility persists")
    func visibilityPersists() throws {
        let database = try WorkspaceDatabase.inMemory()
        let store = PanelPreferenceStore(database: database)

        #expect(try !store.loadVisibility())
        try store.persistVisibility(true)
        #expect(try store.loadVisibility())
        try store.persistVisibility(false)
        #expect(try !store.loadVisibility())
    }
}
