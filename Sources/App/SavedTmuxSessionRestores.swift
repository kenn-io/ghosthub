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
        /// nil for the default tmux server.
        var socketName: String?
    }

    private struct Restore {
        var task: Task<TmuxRestoreReport, Error>
        var continuing: Bool
    }

    private var active: [Key: Restore] = [:]
    /// Each kill in progress holds its own fence, so a duplicate kill that
    /// fails lifts only its own.
    private var fenced: [Fence: Int] = [:]

    /// Restores the entries. An entry another window is restoring is not
    /// restored again: this caller waits for that restore and shares its
    /// outcome, success or failure. When this caller asked to continue
    /// interrupted agents and that restore does not, the shared entry says
    /// its agents were not continued.
    func restore(
        _ entryIDs: [String],
        hostID: UUID,
        continuing: Bool = false,
        using run: @escaping @MainActor ([String]) async throws -> TmuxRestoreReport
    ) async throws -> TmuxRestoreReport {
        var restores: [Restore] = []
        var claimed: [String] = []
        for entryID in entryIDs {
            if let running = active[Key(hostID: hostID, entryID: entryID)] {
                if !restores.contains(where: { $0.task == running.task }) {
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
            let claim = Restore(task: restore, continuing: continuing)
            for key in keys {
                active[key] = claim
            }
            restores.append(claim)
        }
        var entries: [TmuxRestoreReport.Entry] = []
        for restore in restores {
            var shared = try await restore.task.value.entries.filter { entryIDs.contains($0.id) }
            if continuing, !restore.continuing {
                for index in shared.indices {
                    shared[index].notes = (shared[index].notes ?? [])
                        + ["another window restored it without continuing its agents"]
                }
            }
            entries += shared
        }
        return TmuxRestoreReport(entries: entries)
    }

    func contains(_ entryID: String, hostID: UUID) -> Bool {
        active[Key(hostID: hostID, entryID: entryID)] != nil
    }

    /// Keeps windows from restoring a session someone chose to kill, from
    /// before the kill until kwt has forgotten its saved copy.
    func fence(session: String, socketName: String?, hostID: UUID) {
        fenced[Fence(hostID: hostID, session: session, socketName: socketName), default: 0] += 1
    }

    func lift(session: String, socketName: String?, hostID: UUID) {
        let key = Fence(hostID: hostID, session: session, socketName: socketName)
        guard let count = fenced[key] else { return }
        fenced[key] = count > 1 ? count - 1 : nil
    }

    func isFenced(session: String, socketName: String?, hostID: UUID) -> Bool {
        fenced[Fence(hostID: hostID, session: session, socketName: socketName)] != nil
    }
}
