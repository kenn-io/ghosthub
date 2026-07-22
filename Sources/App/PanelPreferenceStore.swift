import Foundation
import GhosthubPersistence

@MainActor
final class PanelPreferenceStore {
    private struct State: Codable, Equatable, Sendable {
        var isVisible: Bool
    }

    private static let preferenceKey = "workspace.consolePanelState"
    private let database: WorkspaceDatabase

    init(database: WorkspaceDatabase) {
        self.database = database
    }

    func loadVisibility() throws -> Bool {
        try database.preferences.value(
            forKey: Self.preferenceKey,
            as: State.self
        )?.isVisible ?? false
    }

    func persistVisibility(_ isVisible: Bool) throws {
        guard isVisible else {
            try database.preferences.delete(key: Self.preferenceKey)
            return
        }
        try database.preferences.set(
            State(isVisible: true),
            forKey: Self.preferenceKey
        )
    }
}
