import Foundation

public enum WorkspaceKeyResolver {
    private static let worktreeKeyPrefix = "worktree:"

    public static func hostKey(for host: HostSummary) -> String {
        host.configKey.isEmpty
            ? host.id.uuidString
            : host.configKey
    }

    public static func worktreeKey(
        for worktree: WorktreeSummary
    ) -> String {
        worktree.scopedKey.isEmpty
            ? worktree.id.uuidString
            : worktree.scopedKey
    }

    public static func worktreeKey(path: String) -> String {
        worktreeKeyPrefix + path
    }

    public static func worktreePath(fromKey key: String) -> String {
        guard key.hasPrefix(worktreeKeyPrefix) else {
            return key
        }
        return String(key.dropFirst(worktreeKeyPrefix.count))
    }

    public static func host(
        matching key: String,
        in snapshot: WorkspaceSnapshot
    ) -> HostSummary? {
        snapshot.hosts.first {
            hostKey(for: $0) == key
        }
    }

    public static func worktree(
        matching key: String,
        hostKey: String?,
        in snapshot: WorkspaceSnapshot
    ) -> WorktreeSummary? {
        if let hostKey {
            guard let host = host(
               matching: hostKey,
               in: snapshot
            ) else {
                return nil
            }
            return snapshot.worktrees.first {
                $0.hostID == host.id
                    && worktreeKey(for: $0) == key
            }
        }
        return snapshot.worktrees.first {
            worktreeKey(for: $0) == key
        }
    }

    public static func project(
        registryID: String,
        hostKey: String?,
        in snapshot: WorkspaceSnapshot
    ) -> ProjectSummary? {
        snapshot.projects.first { project in
            guard project.registryID == registryID else {
                return false
            }
            guard let hostKey else { return true }
            guard let host = snapshot.host(id: project.hostID)
            else { return false }
            return self.hostKey(for: host) == hostKey
        }
    }
}
