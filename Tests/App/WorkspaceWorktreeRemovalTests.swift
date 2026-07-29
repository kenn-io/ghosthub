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
}
