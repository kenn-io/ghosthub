import Foundation
import GhosthubWorkspace

/// Removes persisted local state (sessions and presentation state) for
/// worktrees and hosts that no longer appear in a daemon snapshot.
public enum OrphanCleaner {

    // MARK: - Runtime Diff

    /// Runtime orphan cleanup: diff previous and new snapshot.
    ///
    /// Call this on every snapshot update. Compares the previous and current
    /// snapshots and marks sessions dead for any entity that
    /// disappeared from the daemon.
    public static func cleanupDiff(
        previous: WorkspaceSnapshot,
        current: WorkspaceSnapshot,
        database: WorkspaceDatabase
    ) throws {
        try cleanupRemovedWorktrees(
            previous: previous,
            current: current,
            database: database
        )
        try cleanupRemovedHosts(
            previous: previous,
            current: current,
            database: database
        )
    }

    // MARK: - Cold-Start Reconciliation

    /// Cold-start cleanup: reconcile persisted state against first snapshot
    /// after launch.
    ///
    /// Call this once on startup, after the first daemon snapshot arrives.
    /// Walks all three storage tables and removes any row whose referenced
    /// entity is absent from `snapshot`.
    public static func cleanupColdStart(
        snapshot: WorkspaceSnapshot,
        database: WorkspaceDatabase
    ) throws {
        try coldStartWorktreeCleanup(snapshot: snapshot, database: database)
        try coldStartHostCleanup(snapshot: snapshot, database: database)
        try coldStartPresentationStateCleanup(
            snapshot: snapshot,
            database: database
        )
    }

    // MARK: - Runtime helpers

    private static func cleanupRemovedWorktrees(
        previous: WorkspaceSnapshot,
        current: WorkspaceSnapshot,
        database: WorkspaceDatabase
    ) throws {
        let currentIDs = Set(current.worktrees.map(\.id))
        let hostsByID = current.hostsByID
        let removed = previous.worktrees.filter {
            !currentIDs.contains($0.id)
        }
        for wt in removed {
            try markWorktreeSessionsDead(
                hostID: wt.hostID,
                worktreeID: wt.id,
                database: database
            )
            let hostKey = hostsByID[wt.hostID]?
                .configKey ?? ""
            try database.presentationState.delete(
                hostID: hostKey,
                scopedKey: wt.scopedKey
            )
        }
    }

    private static func cleanupRemovedHosts(
        previous: WorkspaceSnapshot,
        current: WorkspaceSnapshot,
        database: WorkspaceDatabase
    ) throws {
        let currentIDs = Set(current.hosts.map(\.id))
        let removed = previous.hosts.filter {
            !currentIDs.contains($0.id)
        }
        for host in removed {
            try markConsoleSessionsDead(
                hostID: host.id, database: database
            )
            // Clean up all presentation_state rows
            // for this host's worktrees.
            let hostWorktrees = previous.worktrees
                .filter { $0.hostID == host.id }
            for wt in hostWorktrees {
                try database.presentationState.delete(
                    hostID: host.configKey,
                    scopedKey: wt.scopedKey
                )
            }
        }
    }

    // MARK: - Cold-start helpers

    private static func coldStartWorktreeCleanup(
        snapshot: WorkspaceSnapshot,
        database: WorkspaceDatabase
    ) throws {
        let liveKeys = Set(
            snapshot.worktrees.map { LiveWorktreeKey(hostID: $0.hostID, worktreeID: $0.id) }
        )

        let allSessions = try database.terminalSessions.fetchAll()
        for session in allSessions where session.worktreeID != nil {
            guard let wtID = session.worktreeID else { continue }
            let key = LiveWorktreeKey(
                hostID: session.hostID,
                worktreeID: wtID
            )
            if !liveKeys.contains(key), session.isAlive {
                var dead = session
                dead.isAlive = false
                try database.terminalSessions.upsert(dead)
            }
        }
    }

    private static func coldStartHostCleanup(
        snapshot: WorkspaceSnapshot,
        database: WorkspaceDatabase
    ) throws {
        let liveHostIDs = Set(snapshot.hosts.map(\.id))

        let allSessions = try database.terminalSessions.fetchAll()
        for session in allSessions
            where session.worktreeID == nil
            && !liveHostIDs.contains(session.hostID)
            && session.isAlive {
            var dead = session
            dead.isAlive = false
            try database.terminalSessions.upsert(dead)
        }
    }

    private static func coldStartPresentationStateCleanup(
        snapshot: WorkspaceSnapshot,
        database: WorkspaceDatabase
    ) throws {
        let hostsByID = snapshot.hostsByID
        let liveKeys: Set<String> = Set(
            snapshot.worktrees.compactMap { wt -> String? in
                guard let host = hostsByID[wt.hostID] else { return nil }
                return "\(host.configKey)/\(wt.scopedKey)"
            }
        )
        try database.presentationState.deleteExcept(liveKeys: liveKeys)
    }

    // MARK: - Low-level operations

    private static func markWorktreeSessionsDead(
        hostID: UUID,
        worktreeID: UUID,
        database: WorkspaceDatabase
    ) throws {
        let sessions = try database.terminalSessions.fetchAll(
            hostID: hostID,
            worktreeID: worktreeID
        )
        for session in sessions where session.isAlive {
            var dead = session
            dead.isAlive = false
            try database.terminalSessions.upsert(dead)
        }
    }

    private static func markConsoleSessionsDead(
        hostID: UUID,
        database: WorkspaceDatabase
    ) throws {
        let sessions = try database.terminalSessions.fetchAll(hostID: hostID)
        for session in sessions where session.worktreeID == nil && session.isAlive {
            var dead = session
            dead.isAlive = false
            try database.terminalSessions.upsert(dead)
        }
    }
}

// MARK: - Private helpers

private struct LiveWorktreeKey: Hashable {
    let hostID: UUID
    let worktreeID: UUID
}
