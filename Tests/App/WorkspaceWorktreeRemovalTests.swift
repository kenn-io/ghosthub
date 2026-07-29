import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Workspace worktree removal")
struct WorkspaceWorktreeRemovalTests {
    @MainActor
    @Test("a live kwt session is killed before its worktree is removed")
    func liveSessionIsKilledFirst() async throws {
        let environment = try setupStandardEnvironment()
        let feature = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove"
        )
        var removable = feature
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        removable.tmuxSocketName = "kwt-pr-0123456789abcdef"
        removable.sessionBackend = .localTmux

        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let events = LockedValue<[String]>([])
        let refreshedInventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: environment.project.scopedKey,
                    name: environment.project.name,
                    path: environment.project.rootPath,
                    lastTouched: nil
                ),
                worktrees: [
                    KwtWorktreeRecord(
                        path: environment.worktree.path,
                        branch: environment.worktree.branch,
                        commitHash: "",
                        isMain: true,
                        createdAt: nil,
                        repository: environment.project.scopedKey,
                        sessionName: "kwt-ghosthub-main",
                        tmuxSocketName: nil
                    ),
                ],
                warning: nil
            ),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                events.withLock { $0.append("refresh") }
                return refreshedInventory
            },
            kwtWorktreeRemover: { path, projectPath, _ in
                events.withLock {
                    $0.append("remove:\(projectPath):\(path)")
                }
            },
            tmuxSessionKiller: { selection, _, _ in
                events.withLock { $0.append("kill:\(selection.name)") }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )
        model.selection.select(
            .worktree(removable.id),
            in: model.snapshot
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest != nil)
        try await model.removeWorktree(request)

        #expect(events.load() == [
            "refresh",
            "kill:kwt-ghosthub-feature",
            "remove:/tmp/ghosthub:/tmp/ghosthub-feature",
            "refresh",
        ])
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        #expect(
            model.selection.selectedWorktreeID
                == environment.worktree.id
        )
        await model.shutdown()
    }

    @MainActor
    @Test("known missing kwt makes a cached worktree non-removable")
    func unavailableKwtDisablesRemoval() throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].remoteDiagnostics = [.missingKwtCapability]
        let worktree = try #require(snapshot.worktrees.first)

        #expect(!snapshot.canRemoveWorktree(worktree))
    }

    @MainActor
    @Test("kwt availability is checked before terminating a session")
    func unavailableKwtDoesNotKillSession() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let events = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                throw KwtInventoryError.commandFailed(
                    host: "Office Linux",
                    status: 127
                )
            },
            kwtWorktreeRemover: { _, _, _ in
                events.withLock { $0.append("remove") }
            },
            tmuxSessionKiller: { _, _, _ in
                events.withLock { $0.append("kill") }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        await #expect(throws: KwtInventoryError.self) {
            try await model.removeWorktree(request)
        }

        #expect(events.load().isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("a session starting after confirmation requires confirmation again")
    func newlyStartedSessionAbortsRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            kwtWorktreeRemover: { _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                reads.withLock { $0 += 1 }
                let attempt = reads.load()
                if attempt == 1 {
                    throw TmuxSessionKillError.sessionNotRunning(
                        host: host.displayName,
                        session: selection.name
                    )
                }
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest == nil)
        do {
            try await model.removeWorktree(request)
            Issue.record("Removal should require a new confirmation")
        } catch {
            #expect(
                error as? KwtWorktreeError
                    == .sessionStartedAfterConfirmation(
                        session: "kwt-ghosthub-feature"
                    )
            )
        }

        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("refresh failure after removal is a reconciliation warning")
    func refreshFailureDoesNotUndoRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let loads = LockedValue(0)
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                let attempt = loads.load()
                if attempt == 1 {
                    return KwtHostInventory(projects: [])
                }
                throw KwtInventoryError.commandFailed(
                    host: "this Mac",
                    status: 23
                )
            },
            kwtWorktreeRemover: { _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        try await model.removeWorktree(request)

        #expect(removals.load() == 1)
        #expect(loads.load() == 2)
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[
                environment.host.id
            ] != nil
        )
        await model.shutdown()
    }
}
