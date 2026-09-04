import GhosthubTransport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace

enum WorktreeChangesLoaderAuthority {
    typealias Reader = @Sendable (
        _ path: String,
        _ repository: String,
        _ generation: String,
        _ host: CommandHost
    ) async throws -> WorktreeFileChanges

    static func load(
        requested: WorktreeSummary,
        in snapshot: WorkspaceSnapshot,
        coordinator: WorktreeChangesReadCoordinator = .shared,
        read: @escaping Reader = { path, repository, generation, host in
            try await KwtWorktreeClient().changes(
                worktreePath: path,
                expectedRepository: repository,
                expectedGeneration: generation,
                on: host
            )
        }
    ) async throws -> WorktreeFileChanges {
        guard let worktree = snapshot.worktree(id: requested.id),
              !worktree.isStale,
              worktree.hostID == requested.hostID,
              worktree.projectID == requested.projectID,
              worktree.path == requested.path,
              worktree.generation == requested.generation,
              let generation = WorktreeGeneration.canonical(
                  worktree.generation
              ),
              let project = snapshot.project(id: worktree.projectID),
              !project.isStale,
              project.hostID == worktree.hostID,
              !project.scopedKey.isEmpty,
              let hostSummary = snapshot.host(id: worktree.hostID),
              let host = CommandHostResolver.resolve(hostSummary),
              let identity = WorktreeChangesIdentity.resolve(
                  worktreeID: worktree.id,
                  in: snapshot
              )
        else {
            throw KwtWorktreeError.worktreeUnavailable
        }
        return try await coordinator.load(identity: identity) {
            try await read(
                worktree.path,
                project.scopedKey,
                generation,
                host
            )
        }
    }
}
