import Foundation

/// Saved tmux sessions that some workspace window is restoring now. Every
/// window shares one tracker, because kwt treats a second restore of an
/// entry as an interrupted one: it tears down the half-built session and
/// starts over, killing the agents the first restore just started.
@MainActor
final class SavedTmuxSessionRestores {
    static let shared = SavedTmuxSessionRestores()

    private struct Key: Hashable {
        var hostID: UUID
        var entryID: String
    }

    private var active: Set<Key> = []

    /// Claims the entries no window is restoring and returns them.
    func begin(_ entryIDs: [String], hostID: UUID) -> [String] {
        var claimed: [String] = []
        for entryID in entryIDs
            where active.insert(Key(hostID: hostID, entryID: entryID)).inserted {
            claimed.append(entryID)
        }
        return claimed
    }

    func end(_ entryIDs: [String], hostID: UUID) {
        for entryID in entryIDs {
            active.remove(Key(hostID: hostID, entryID: entryID))
        }
    }

    func contains(_ entryID: String, hostID: UUID) -> Bool {
        active.contains(Key(hostID: hostID, entryID: entryID))
    }
}
