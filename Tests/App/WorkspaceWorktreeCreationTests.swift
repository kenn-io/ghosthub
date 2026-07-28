import Foundation
import GhosthubUI
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
    @Test(
        "workspace mutations fence background kwt inventory",
        arguments: [
            (creating: true, importing: false),
            (creating: false, importing: true),
        ]
    )
    @MainActor
    func workspaceMutationsFenceInventory(
        creating: Bool,
        importing: Bool
    ) {
        #expect(!WorkspaceSceneModel.canScheduleKwtInventory(
            isWorktreeCreationInProgress: creating,
            isPullRequestImportInProgress: importing
        ))
    }

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

    @Test("PR import survives a failed inventory refresh")
    @MainActor
    func pullRequestSurvivesInventoryFailure() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.projects[0].scopedKey =
            "github.com/kenn-io/ghosthub"
        let unrelatedProjectID = UUID()
        let unrelatedWorktreeID = UUID()
        snapshot.projects.append(ProjectSummary(
            id: unrelatedProjectID,
            hostID: environment.host.id,
            scopedKey: "github.com/kenn-io/kwt",
            name: "kwt",
            rootPath: "/tmp/kwt"
        ))
        snapshot.worktrees.append(WorktreeSummary(
            id: unrelatedWorktreeID,
            hostID: environment.host.id,
            projectID: unrelatedProjectID,
            scopedKey: "/tmp/kwt",
            name: "main",
            path: "/tmp/kwt",
            branch: "main",
            isPrimary: true,
            tmuxSessionName: "kwt-workspace-kwt"
        ))
        let workspace = PullRequestWorkspace(
            id: "workspace-32",
            repository: "github.com/kenn-io/ghosthub",
            branch: "pr-32-feature",
            path: "/tmp/ghosthub-pr-32",
            state: "ready",
            sessionName: "kwt-workspace-pr-32",
            tmuxSocketName: "kwt-pr-0123456789abcdef"
        )
        let candidate = PullRequestCandidate(
            id: "github:github.com/kenn-io/ghosthub#32",
            number: 32,
            url: "https://github.com/kenn-io/ghosthub/pull/32",
            title: "Import pull requests",
            author: "wesm",
            sourceBranch: "feature/pr-import",
            targetBranch: "main",
            isDraft: false,
            state: "open",
            isImported: true,
            workspace: workspace
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                throw KwtInventoryError.commandFailed(
                    host: "this Mac",
                    status: 1
                )
            },
            kwtPullRequestImporter: { id, identity, _ in
                #expect(id == candidate.id)
                #expect(identity == "github.com/kenn-io/ghosthub")
                return KwtPullRequestImportResult(
                    status: "created",
                    pullRequest: candidate,
                    workspace: workspace
                )
            }
        )

        try await model.importPullRequest(PullRequestImportRequest(
            projectID: environment.project.id,
            pullRequestID: candidate.id
        ))

        let selectedID = try #require(model.selection.selectedWorktreeID)
        let imported = try #require(
            model.snapshot.worktree(id: selectedID)
        )
        #expect(imported.path == workspace.path)
        #expect(imported.tmuxSessionName == workspace.sessionName)
        #expect(imported.tmuxSocketName == workspace.tmuxSocketName)
        let selectedSession = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: imported)
        )
        #expect(selectedSession.socketName == workspace.tmuxSocketName)
        #expect(imported.linkedPullRequestNumber == 32)
        #expect(imported.pullRequestTitle == candidate.title)
        #expect(imported.pullRequestState == .open)
        #expect(model.snapshot.project(id: unrelatedProjectID) != nil)
        #expect(model.snapshot.worktree(id: unrelatedWorktreeID) != nil)
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
