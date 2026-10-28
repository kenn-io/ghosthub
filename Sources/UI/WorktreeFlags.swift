import Foundation
import GhosthubWorkspace

/// App-owned preference identity, independent of inventory UUIDs and paths.
public struct WorktreeFlagKey: Codable, Hashable, Sendable {
    public let hostKey: String
    public let projectKey: String
    public let generation: String

    init?(hostKey: String, projectKey: String, generation: String) {
        guard !hostKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !projectKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              generation.utf8.count == 32,
              generation.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
        else { return nil }
        self.hostKey = hostKey
        self.projectKey = projectKey
        self.generation = generation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = try Self(
            hostKey: values.decode(String.self, forKey: .hostKey),
            projectKey: values.decode(String.self, forKey: .projectKey),
            generation: values.decode(String.self, forKey: .generation)
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid worktree flag identity"
            ))
        }
        self = key
    }

    static func resolve(
        worktree: WorktreeSummary,
        host: HostSummary,
        project: ProjectSummary
    ) -> Self? {
        guard worktree.hostID == host.id,
              worktree.projectID == project.id,
              project.hostID == host.id,
              let generation = worktree.generation
        else { return nil }
        return Self(
            hostKey: host.kind == .selfHost ? "local" : host.configKey,
            projectKey: project.scopedKey,
            generation: generation
        )
    }

    /// Used only for explicit actions. Rendering uses the row's cached key.
    public static func resolve(worktreeID: UUID, in snapshot: WorkspaceSnapshot) -> Self? {
        guard let worktree = snapshot.worktree(id: worktreeID),
              let host = snapshot.host(id: worktree.hostID),
              let project = snapshot.project(id: worktree.projectID)
        else { return nil }
        return resolve(worktree: worktree, host: host, project: project)
    }
}
