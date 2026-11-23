import Foundation
import GhosthubWorkspace

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

    private struct Fence: Hashable {
        var hostID: UUID
        var session: String
    }

    private var active: [Key: Task<TmuxRestoreReport, Error>] = [:]
    private var fenced: Set<Fence> = []

    /// Restores the entries. An entry another window is restoring is not
    /// restored again: this caller waits for that restore and shares its
    /// outcome, success or failure.
    func restore(
        _ entryIDs: [String],
        hostID: UUID,
        using run: @escaping @MainActor ([String]) async throws -> TmuxRestoreReport
    ) async throws -> TmuxRestoreReport {
        var restores: [Task<TmuxRestoreReport, Error>] = []
        var claimed: [String] = []
        for entryID in entryIDs {
            if let running = active[Key(hostID: hostID, entryID: entryID)] {
                if !restores.contains(running) {
                    restores.append(running)
                }
            } else {
                claimed.append(entryID)
            }
        }
        if !claimed.isEmpty {
            let keys = claimed.map { Key(hostID: hostID, entryID: $0) }
            let restore = Task { @MainActor [weak self] in
                defer {
                    for key in keys {
                        self?.active.removeValue(forKey: key)
                    }
                }
                return try await run(claimed)
            }
            for key in keys {
                active[key] = restore
            }
            restores.append(restore)
        }
        var entries: [TmuxRestoreReport.Entry] = []
        for restore in restores {
            entries += try await restore.value.entries.filter { entryIDs.contains($0.id) }
        }
        return TmuxRestoreReport(entries: entries)
    }

    func contains(_ entryID: String, hostID: UUID) -> Bool {
        active[Key(hostID: hostID, entryID: entryID)] != nil
    }

    /// Keeps windows from restoring a session someone chose to kill, from
    /// before the kill until kwt has forgotten its saved copy.
    func fence(session: String, hostID: UUID) {
        fenced.insert(Fence(hostID: hostID, session: session))
    }

    func lift(session: String, hostID: UUID) {
        fenced.remove(Fence(hostID: hostID, session: session))
    }

    func isFenced(session: String, hostID: UUID) -> Bool {
        fenced.contains(Fence(hostID: hostID, session: session))
    }
}
