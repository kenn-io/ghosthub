import GhosthubTransport
import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

let stableWorktreeGeneration =
    "0123456789abcdef0123456789abcdef"

actor RemovalPreflightHold {
    private var callCount = 0
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func verify(
        selection: WorkspaceTmuxSessionSelection,
        host: CommandHost
    ) async throws -> TmuxSessionIdentity {
        callCount += 1
        if callCount == 1 {
            throw TmuxSessionKillError.sessionNotRunning(
                host: host.displayName,
                session: selection.name
            )
        }
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        throw TmuxSessionKillError.sessionNotRunning(
            host: host.displayName,
            session: selection.name
        )
    }

    func verifyStartedSession(
        selection: WorkspaceTmuxSessionSelection,
        host: CommandHost,
        identity: TmuxSessionIdentity
    ) async throws -> TmuxSessionIdentity {
        callCount += 1
        if callCount == 1 {
            throw TmuxSessionKillError.sessionNotRunning(
                host: host.displayName,
                session: selection.name
            )
        }
        if callCount == 2 {
            started = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return identity
    }

    func load(_ inventory: KwtHostInventory) async -> KwtHostInventory {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return inventory
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

func inventory(
    _ environment: StandardEnvironment,
    including worktree: WorktreeSummary? = nil,
    generation: String? = stableWorktreeGeneration
) -> KwtHostInventory {
    var worktrees = [
        KwtWorktreeRecord(
            path: environment.worktree.path,
            branch: environment.worktree.branch,
            commitHash: "",
            isMain: true,
            createdAt: nil,
            generation: nil,
            repository: environment.project.scopedKey,
            sessionName: "kwt-ghosthub-main",
            tmuxSocketName: nil
        ),
    ]
    if let worktree {
        worktrees.append(KwtWorktreeRecord(
            path: worktree.path,
            branch: worktree.branch,
            commitHash: "",
            isMain: worktree.isPrimary,
            createdAt: nil,
            generation: generation,
            repository: environment.project.scopedKey,
            sessionName: worktree.tmuxSessionName ?? "",
            tmuxSocketName: worktree.tmuxSocketName,
            tmuxAttachMode: worktree.tmuxAttachMode
        ))
    }
    return KwtHostInventory(projects: [
        KwtProjectInventory(
            project: KwtProjectRecord(
                repository: environment.project.scopedKey,
                name: environment.project.name,
                path: environment.project.rootPath,
                lastTouched: nil,
                registrationFingerprint:
                environment.snapshot.projects[0].registrationFingerprint
            ),
            worktrees: worktrees,
            warning: nil
        ),
    ])
}

func inventory(
    _ environment: RemoteEnvironment,
    including worktree: WorktreeSummary
) -> KwtHostInventory {
    KwtHostInventory(projects: [
        KwtProjectInventory(
            project: KwtProjectRecord(
                repository: environment.project.scopedKey,
                name: environment.project.name,
                path: environment.project.rootPath,
                lastTouched: nil,
                registrationFingerprint:
                environment.snapshot.projects[0].registrationFingerprint
            ),
            worktrees: [
                KwtWorktreeRecord(
                    path: worktree.path,
                    branch: worktree.branch,
                    commitHash: "",
                    isMain: worktree.isPrimary,
                    createdAt: worktree.createdAt,
                    generation: worktree.generation,
                    repository: environment.project.scopedKey,
                    sessionName: worktree.tmuxSessionName ?? "",
                    tmuxSocketName: worktree.tmuxSocketName,
                    tmuxAttachMode: worktree.tmuxAttachMode
                ),
            ],
            warning: nil
        ),
    ])
}

struct RemovalFixture {
    let environment: StandardEnvironment
    var removable: WorktreeSummary
    var snapshot: WorkspaceSnapshot
    var beforeRemoval: KwtHostInventory
}

/// Builds the standard local environment plus one removable worktree, the
/// snapshot that contains it, and the inventory that still reports it.
func removalFixture(
    path: String = "/tmp/ghosthub-feature",
    name: String = "feature/remove",
    branch: String = "feature/remove",
    sessionName: String? = "kwt-ghosthub-feature",
    socketName: String? = nil,
    tmuxAttachMode: TmuxAttachMode = .direct,
    sessionBackend: SessionBackendKind = .localPTY,
    runningSession: Bool = false
) throws -> RemovalFixture {
    let environment = try setupStandardEnvironment()
    var removable = WorktreeSummary.fixture(
        hostID: environment.host.id,
        projectID: environment.project.id,
        scopedKey: path,
        name: name,
        path: path,
        branch: branch,
        generation: stableWorktreeGeneration
    )
    removable.tmuxSessionName = sessionName
    removable.tmuxSocketName = socketName
    removable.tmuxAttachMode = tmuxAttachMode
    removable.sessionBackend = sessionBackend
    var snapshot = environment.snapshot
    snapshot.worktrees.append(removable)
    if runningSession, let sessionName {
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: [],
                serverPID: "31415",
                sessionID: "$8",
                createdAt: "1721552400"
            ),
        ]
    }
    return RemovalFixture(
        environment: environment,
        removable: removable,
        snapshot: snapshot,
        beforeRemoval: inventory(environment, including: removable)
    )
}
