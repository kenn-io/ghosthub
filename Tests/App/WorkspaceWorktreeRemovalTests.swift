import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private let stableWorktreeCreatedAt = "2026-07-29T19:00:00Z"

private func inventory(
    _ environment: StandardEnvironment,
    including worktree: WorktreeSummary? = nil,
    createdAt: String? = stableWorktreeCreatedAt
) -> KwtHostInventory {
    var worktrees = [
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
    ]
    if let worktree {
        worktrees.append(KwtWorktreeRecord(
            path: worktree.path,
            branch: worktree.branch,
            commitHash: "",
            isMain: worktree.isPrimary,
            createdAt: createdAt,
            repository: environment.project.scopedKey,
            sessionName: worktree.tmuxSessionName ?? "",
            tmuxSocketName: worktree.tmuxSocketName
        ))
    }
    return KwtHostInventory(projects: [
        KwtProjectInventory(
            project: KwtProjectRecord(
                repository: environment.project.scopedKey,
                name: environment.project.name,
                path: environment.project.rootPath,
                lastTouched: nil
            ),
            worktrees: worktrees,
            warning: nil
        ),
    ])
}

@Suite("Workspace worktree removal")
struct WorkspaceWorktreeRemovalTests {
    @MainActor
    @Test(
        "live session removal leaves a same-path worktree on another host"
    )
    func liveSessionIsKilledFirst() async throws {
        let environment = try setupStandardEnvironment()
        let feature = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            createdAt: stableWorktreeCreatedAt
        )
        var removable = feature
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        removable.tmuxSocketName = "kwt-pr-0123456789abcdef"
        removable.sessionBackend = .localTmux

        var snapshot = environment.snapshot
        let otherHost = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "build-box"
        )
        let otherProject = ProjectSummary.fixture(
            hostID: otherHost.id,
            name: "Ghosthub",
            rootPath: "/srv/ghosthub"
        )
        let samePath = WorktreeSummary.fixture(
            hostID: otherHost.id,
            projectID: otherProject.id,
            scopedKey: removable.path,
            name: "other-host",
            path: removable.path,
            branch: "other-host"
        )
        snapshot.hosts.append(otherHost)
        snapshot.projects.append(otherProject)
        snapshot.worktrees += [removable, samePath]
        let events = LockedValue<[String]>([])
        let loads = LockedValue(0)
        let beforeRemoval = inventory(environment, including: removable)
        let afterRemoval = inventory(environment)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                events.withLock { $0.append("refresh") }
                loads.withLock { $0 += 1 }
                return loads.load() == 1 ? beforeRemoval : afterRemoval
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
        #expect(model.snapshot.worktree(id: samePath.id) == samePath)
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
    @Test("removal requires a stable worktree creation identity")
    func missingCreationIdentityAbortsPreparation() async throws {
        let environment = try setupStandardEnvironment()
        let removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove"
        )
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot
        )

        await #expect(
            throws: KwtWorktreeError.removalIdentityUnavailable
        ) {
            try await model.prepareWorktreeRemoval(removable.id)
        }
        await model.shutdown()
    }

    @MainActor
    @Test("kwt availability is checked before terminating a session")
    func unavailableKwtDoesNotKillSession() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.createdAt = stableWorktreeCreatedAt
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
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        removable.createdAt = stableWorktreeCreatedAt
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let beforeRemoval = inventory(environment, including: removable)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
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
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        removable.createdAt = stableWorktreeCreatedAt
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let loads = LockedValue(0)
        let removals = LockedValue(0)
        let beforeRemoval = inventory(environment, including: removable)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                let attempt = loads.load()
                if attempt == 1 {
                    return beforeRemoval
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

    @MainActor
    @Test(
        "changed target metadata invalidates the removal confirmation",
        arguments: [
            (
                branch: "feature/replacement",
                session: "kwt-ghosthub-feature"
            ),
            (
                branch: "feature/remove",
                session: "kwt-ghosthub-replacement"
            ),
        ]
    )
    func changedTargetAbortsRemoval(
        replacementBranch: String,
        replacementSession: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            createdAt: stableWorktreeCreatedAt
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var replacement = removable
        replacement.branch = replacementBranch
        replacement.name = replacementBranch
        replacement.tmuxSessionName = replacementSession
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let events = LockedValue<[String]>([])
        let replacementInventory = inventory(
            environment,
            including: replacement
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in replacementInventory },
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

        let request = try await model.prepareWorktreeRemoval(removable.id)
        do {
            try await model.removeWorktree(request)
            Issue.record("Changed worktree metadata should require confirmation")
        } catch {
            #expect(
                error as? KwtWorktreeError
                    == KwtWorktreeError.removalTargetChanged
            )
        }

        #expect(events.load().isEmpty)
        #expect(
            model.snapshot.worktree(id: removable.id)?.branch
                == replacementBranch
        )
        #expect(
            model.snapshot.worktree(id: removable.id)?.tmuxSessionName
                == replacementSession
        )
        await model.shutdown()
    }

    @MainActor
    @Test("a recreated worktree invalidates removal confirmation")
    func recreatedWorktreeAbortsRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            createdAt: stableWorktreeCreatedAt
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let removals = LockedValue(0)
        let recreatedInventory = inventory(
            environment,
            including: removable,
            createdAt: "2026-07-29T19:05:00Z"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in recreatedInventory },
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
        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await model.removeWorktree(request)
        }

        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("removal completion preserves newer navigation")
    func removalPreservesCurrentSelection() throws {
        let environment = try setupStandardEnvironment()
        let removed = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removed)
        var current = WorkspaceSelection(
            selectedHostID: environment.host.id
        )
        current.select(
            WorkspaceNavigationTarget.worktree(environment.worktree.id),
            in: snapshot
        )
        snapshot.worktrees.removeAll { $0.id == removed.id }

        let resolved = WorkspaceSceneModel.selectionAfterWorktreeRemoval(
            current,
            in: snapshot,
            visibility: WorktreeVisibility.default
        )

        #expect(resolved.selectedWorktreeID == environment.worktree.id)
    }
}
