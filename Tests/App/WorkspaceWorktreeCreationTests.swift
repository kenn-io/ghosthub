import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private actor KwtInventoryRaceStub {
    private let stale: KwtHostInventory
    private let refreshed: KwtHostInventory
    private var callCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    init(stale: KwtHostInventory, refreshed: KwtHostInventory) {
        self.stale = stale
        self.refreshed = refreshed
    }

    var firstCallStarted: Bool { callCount > 0 }

    func load() async -> KwtHostInventory {
        callCount += 1
        guard callCount == 1 else { return refreshed }
        await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
        return stale
    }

    func releaseFirstCall() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

@Suite("Workspace worktree creation")
struct WorkspaceWorktreeCreationTests {
    @Test("selecting a kwt worktree preserves the authoritative inventory")
    @MainActor
    func selectionPreservesKwtInventory() async throws {
        let environment = try setupStandardEnvironment()
        let expectedPath = environment.worktree.path
        let loadedInventory = inventory(
            project: environment.project,
            worktrees: [
                worktree(
                    path: expectedPath,
                    branch: environment.worktree.branch,
                    isMain: true
                ),
            ]
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in loadedInventory }
        )

        model.startKwtInventory()
        for _ in 0 ..< 1_000 {
            if model.snapshot.worktrees.count == 1 {
                break
            }
            await Task.yield()
        }

        let loadedWorktree = try #require(model.snapshot.worktrees.first)
        model.selection.select(
            .worktree(loadedWorktree.id),
            in: model.snapshot,
            visibility: .default
        )

        #expect(model.snapshot.hosts.count == 1)
        #expect(model.snapshot.projects.count == 1)
        #expect(model.snapshot.worktrees.count == 1)
        #expect(model.snapshot.worktree(id: loadedWorktree.id)?.lastViewedAt != nil)
        #expect(model.selection.selectedWorktreeID == loadedWorktree.id)
        await model.shutdown()
    }

    @Test("a pre-creation inventory refresh cannot overwrite the result")
    @MainActor
    func staleRefreshCannotOverwriteCreation() async throws {
        let environment = try setupStandardEnvironment()
        let stale = inventory(
            project: environment.project,
            worktrees: [
                worktree(
                    path: environment.worktree.path,
                    branch: environment.worktree.branch,
                    isMain: true
                ),
            ]
        )
        let createdBranch = "feature/native-tmux"
        let createdPath = "/tmp/ghosthub-native-tmux"
        let refreshed = inventory(
            project: environment.project,
            worktrees: [
                worktree(
                    path: environment.worktree.path,
                    branch: environment.worktree.branch,
                    isMain: true
                ),
                worktree(
                    path: createdPath,
                    branch: createdBranch,
                    isMain: false
                ),
            ]
        )
        let loader = KwtInventoryRaceStub(
            stale: stale,
            refreshed: refreshed
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in await loader.load() },
            kwtWorktreeCreator: { _, _, _ in }
        )

        model.startKwtInventory()
        for _ in 0 ..< 1_000 {
            if await loader.firstCallStarted {
                break
            }
            await Task.yield()
        }
        #expect(await loader.firstCallStarted)

        try await model.createWorktree(WorktreeCreateRequest(
            projectID: environment.project.id,
            branchName: createdBranch,
            createsBranch: true
        ))
        await loader.releaseFirstCall()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(model.snapshot.worktrees.contains {
            $0.branch == createdBranch && $0.path == createdPath
        })
        let selectedID = try #require(model.selection.selectedWorktreeID)
        #expect(
            model.snapshot.worktree(id: selectedID)?
                .branch == createdBranch
        )
        await model.shutdown()
    }

    private func inventory(
        project: ProjectEnv,
        worktrees: [KwtWorktreeRecord]
    ) -> KwtHostInventory {
        KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "github.com/kenn-io/ghosthub",
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil
                ),
                worktrees: worktrees,
                warning: nil
            ),
        ])
    }

    private func worktree(
        path: String,
        branch: String,
        isMain: Bool
    ) -> KwtWorktreeRecord {
        KwtWorktreeRecord(
            path: path,
            branch: branch,
            commitHash: "abc123",
            isMain: isMain,
            createdAt: nil,
            repository: "github.com/kenn-io/ghosthub",
            sessionName: "kwt-\(branch.replacingOccurrences(of: "/", with: "-"))"
        )
    }
}
