import GhosthubTransport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace

enum WorktreeChangesLoaderAuthority {
    typealias Reader = @Sendable (
        _ path: String,
        _ repository: String,
        _ generation: String,
        _ expectedRouteIdentity: String?,
        _ host: CommandHost
    ) async throws -> WorktreeFileChanges
    typealias RouteIdentityResolver = @Sendable (
        _ host: CommandHost
    ) async throws -> String?

    static func load(
        requested: WorktreeSummary,
        in snapshot: WorkspaceSnapshot,
        coordinator: WorktreeChangesReadCoordinator = .shared,
        resolveRouteIdentity: @escaping RouteIdentityResolver = { host in
            switch host {
            case .local:
                nil
            case let .ssh(info):
                try await BlockingTask.runThrowing(
                    priority: .userInitiated
                ) {
                    try KwtSSHRouteClient().resolve(info).routeIdentity
                }
            }
        },
        read: @escaping Reader = {
            path, repository, generation, routeIdentity, host in
            try await KwtWorktreeClient().changes(
                worktreePath: path,
                expectedRepository: repository,
                expectedGeneration: generation,
                expectedRouteIdentity: routeIdentity,
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
            let routeIdentity = try await resolveRouteIdentity(host)
            return try await read(
                worktree.path,
                project.scopedKey,
                generation,
                routeIdentity,
                host
            )
        }
    }
}

extension KwtRemoteInstallError: WorktreeChangesRetryClassifying {
    var isRetryable: Bool {
        let status: Int32
        switch self {
        case let .targetProbeFailed(value),
             let .prepareFailed(value),
             let .uploadFailed(value, _),
             let .installFailed(value):
            status = value
        case .invalidHost, .bundleIncomplete, .unsupportedTarget,
             .malformedResponse:
            return false
        }
        return status == 255
            || status == AccountCommandRunner.timedOutStatus
    }
}

extension KwtSSHLeaseError: WorktreeChangesRetryClassifying {
    var isRetryable: Bool {
        SSHConnectionFailure.retryableTransportFailure(self) != nil
    }
}

extension KwtSSHRouteError: WorktreeChangesRetryClassifying {
    var isRetryable: Bool {
        guard case let .commandFailed(status) = self else { return false }
        return status == AccountCommandRunner.timedOutStatus
    }
}
