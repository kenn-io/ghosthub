import Foundation
import Testing
@testable import GhosthubPersistence

@Suite("PreferencePersistence")
struct PreferencePersistenceTests {

    // MARK: - 10. Preference round-trip

    @Test("Preference set and fetch round-trip")
    func preferenceRoundTrip() throws {
        let db = try WorkspaceDatabase.inMemory()
        let key = "ui.sidebarWidth"
        let value = 280

        try db.preferences.set(value, forKey: key)

        let fetched = try db.preferences.value(
            forKey: key, as: Int.self
        )
        #expect(fetched == value)
    }
}
