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
    var calls: Int { callCount }

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

private actor WorktreeMutationHold {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum WorktreeMutationProbeError: Error, Equatable {
    case firstFinished
    case invoked(projectPath: String)
}

@Suite("Workspace worktree creation", .serialized)
struct WorkspaceWorktreeCreationTests {
    @Test("separate scene models serialize mutations by host and project")
    @MainActor
    func separateModelsShareMutationGate() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let otherProject = ProjectSummary.fixture(
            hostID: environment.host.id,
            name: "Other",
            rootPath: "/tmp/other"
        )
        snapshot.projects.append(otherProject)
        let hold = WorktreeMutationHold()
        let mutationCoordinator = WorktreeMutationCoordinator()
        let firstModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeCreator: { _, _, _ in
                await hold.wait()
                throw WorktreeMutationProbeError.firstFinished
            },
            worktreeMutationCoordinator: mutationCoordinator
        )
        let secondModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeCreator: { _, projectPath, _ in
                throw WorktreeMutationProbeError.invoked(
                    projectPath: projectPath
                )
            },
            worktreeMutationCoordinator: mutationCoordinator
        )

        let firstMutation = Task { @MainActor in
            do {
                try await firstModel.createWorktree(
                    WorktreeCreateRequest(
                        projectID: environment.project.id,
                        branchName: "feature/first",
                        createsBranch: true
                    )
                )
                return nil as WorktreeMutationProbeError?
            } catch {
                return error as? WorktreeMutationProbeError
            }
        }
        for _ in 0 ..< 1_000 {
            if await hold.started {
                break
            }
            await Task.yield()
        }
        #expect(await hold.started)

        await #expect(throws: KwtWorktreeError.creationInProgress) {
            try await secondModel.createWorktree(
                WorktreeCreateRequest(
                    projectID: environment.project.id,
                    branchName: "feature/second",
                    createsBranch: true
                )
            )
        }
        await #expect {
            try await secondModel.createWorktree(
                WorktreeCreateRequest(
                    projectID: otherProject.id,
                    branchName: "feature/other",
                    createsBranch: true
                )
            )
        } throws: { error in
            error as? WorktreeMutationProbeError
                == .invoked(projectPath: otherProject.rootPath)
        }

        await hold.release()
        #expect(await firstMutation.value == .firstFinished)
        await firstModel.shutdown()
        await secondModel.shutdown()
    }

    @Test("mutation completion refreshes inventory in other scene models")
    @MainActor
    func separateModelsFenceAndRefreshInventory() async throws {
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
        let refreshed = inventory(
            project: environment.project,
            worktrees: [
                worktree(
                    path: environment.worktree.path,
                    branch: environment.worktree.branch,
                    isMain: true
                ),
                worktree(
                    path: "/tmp/ghosthub-refreshed",
                    branch: "feature/refreshed",
                    isMain: false
                ),
            ]
        )
        let inventoryRace = KwtInventoryRaceStub(
            stale: stale,
            refreshed: refreshed
        )
        let mutationHold = WorktreeMutationHold()
        let mutationCoordinator = WorktreeMutationCoordinator()
        let firstModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtWorktreeCreator: { _, _, _ in
                await mutationHold.wait()
                throw WorktreeMutationProbeError.firstFinished
            },
            worktreeMutationCoordinator: mutationCoordinator
        )
        let secondModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                await inventoryRace.load()
            },
            worktreeMutationCoordinator: mutationCoordinator
        )

        secondModel.startKwtInventory()
        for _ in 0 ..< 1_000 {
            if await inventoryRace.firstCallStarted {
                break
            }
            await Task.yield()
        }
        #expect(await inventoryRace.firstCallStarted)

        let mutation = Task { @MainActor in
            try? await firstModel.createWorktree(
                WorktreeCreateRequest(
                    projectID: environment.project.id,
                    branchName: "feature/first",
                    createsBranch: true
                )
            )
        }
        for _ in 0 ..< 1_000 {
            if await mutationHold.started {
                break
            }
            await Task.yield()
        }
        #expect(await mutationHold.started)
        await inventoryRace.releaseFirstCall()
        await mutationHold.release()
        await mutation.value

        for _ in 0 ..< 10_000 {
            if await inventoryRace.calls >= 2,
               secondModel.snapshot.worktrees.contains(where: {
                   $0.branch == "feature/refreshed"
               }) {
                break
            }
            await Task.yield()
        }
        #expect(await inventoryRace.calls >= 2)
        #expect(secondModel.snapshot.worktrees.contains {
            $0.branch == "feature/refreshed"
        })
        await firstModel.shutdown()
        await secondModel.shutdown()
    }

    @Test("removal excludes concurrent create and import mutations")
    @MainActor
    func removalExcludesOtherMutations() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.projects[0].scopedKey =
            "github.com/kenn-io/ghosthub"
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-remove",
            name: "feature/remove",
            path: "/tmp/ghosthub-remove",
            branch: "feature/remove",
            generation: "0123456789abcdef0123456789abcdef"
        )
        removable.tmuxSessionName = "kwt-feature-remove"
        snapshot.worktrees.append(removable)
        let beforeRemoval = inventory(
            project: environment.project,
            worktrees: [
                worktree(
                    path: environment.worktree.path,
                    branch: environment.worktree.branch,
                    isMain: true
                ),
                worktree(
                    path: removable.path,
                    branch: removable.branch,
                    isMain: false,
                    generation: "0123456789abcdef0123456789abcdef"
                ),
            ]
        )
        let afterRemoval = inventory(
            project: environment.project,
            worktrees: [
                worktree(
                    path: environment.worktree.path,
                    branch: environment.worktree.branch,
                    isMain: true
                ),
            ]
        )
        let loader = KwtInventoryRaceStub(
            stale: beforeRemoval,
            refreshed: afterRemoval
        )
        let attemptedMutations = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in await loader.load() },
            kwtWorktreeCreator: { _, _, _ in
                attemptedMutations.withLock { $0.append("create") }
            },
            kwtWorktreeRemover: { _, _, _, _, _ in },
            kwtPullRequestImporter: { _, _, _ in
                attemptedMutations.withLock { $0.append("import") }
                throw KwtPullRequestError.malformedOutput(host: "test")
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let request = try await model.prepareWorktreeRemoval(removable.id)
        let removal = Task {
            try await model.removeWorktree(request)
        }
        for _ in 0 ..< 1_000 {
            if await loader.firstCallStarted {
                break
            }
            await Task.yield()
        }
        #expect(await loader.firstCallStarted)

        await #expect(throws: KwtWorktreeError.creationInProgress) {
            try await model.createWorktree(WorktreeCreateRequest(
                projectID: environment.project.id,
                branchName: "feature/create",
                createsBranch: true
            ))
        }
        await #expect(throws: KwtPullRequestError.importInProgress) {
            try await model.importPullRequest(PullRequestImportRequest(
                projectID: environment.project.id,
                pullRequestID: "github:github.com/kenn-io/ghosthub#47"
            ))
        }

        await loader.releaseFirstCall()
        try await removal.value
        #expect(attemptedMutations.load().isEmpty)
        await model.shutdown()
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

    @Test("successful creation cancels pending window restoration")
    @MainActor
    func creationCancelsPendingRestoration() async throws {
        let environment = try setupStandardEnvironment()
        let createdBranch = "feature/restoration-boundary"
        let loadedInventory = inventory(
            project: environment.project,
            worktrees: [
                worktree(
                    path: environment.worktree.path,
                    branch: environment.worktree.branch,
                    isMain: true
                ),
                worktree(
                    path: "/tmp/ghosthub-restoration-boundary",
                    branch: createdBranch,
                    isMain: false
                ),
            ]
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in loadedInventory },
            kwtWorktreeCreator: { _, _, _ in }
        )
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "unavailable-host",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil
        ))

        try await model.createWorktree(WorktreeCreateRequest(
            projectID: environment.project.id,
            branchName: createdBranch,
            createsBranch: true
        ))

        #expect(!model.isWorkspaceRestorationPending)
        let selectedID = try #require(model.selection.selectedWorktreeID)
        #expect(model.snapshot.worktree(id: selectedID)?.branch == createdBranch)
        await model.shutdown()
    }

    @Test("successful PR import cancels pending window restoration")
    @MainActor
    func pullRequestImportCancelsPendingRestoration() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.projects[0].scopedKey = "github.com/kenn-io/ghosthub"
        let workspace = PullRequestWorkspace(
            id: "workspace-43",
            repository: "github.com/kenn-io/ghosthub",
            branch: "pr-43-restoration-boundary",
            path: "/tmp/ghosthub-pr-43",
            state: "ready",
            sessionName: "kwt-workspace-pr-43",
            tmuxSocketName: "kwt-pr-fedcba9876543210",
            tmuxAttachMode: .protected
        )
        let candidate = PullRequestCandidate(
            id: "github:github.com/kenn-io/ghosthub#43",
            number: 43,
            url: "https://github.com/kenn-io/ghosthub/pull/43",
            title: "Preserve user mutation authority",
            author: "wesm",
            sourceBranch: "feature/restoration-boundary",
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
            kwtPullRequestImporter: { _, _, _ in
                KwtPullRequestImportResult(
                    status: "created",
                    pullRequest: candidate,
                    workspace: workspace
                )
            }
        )
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "unavailable-host",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil
        ))

        try await model.importPullRequest(PullRequestImportRequest(
            projectID: environment.project.id,
            pullRequestID: candidate.id
        ))

        #expect(!model.isWorkspaceRestorationPending)
        let selectedID = try #require(model.selection.selectedWorktreeID)
        #expect(model.snapshot.worktree(id: selectedID)?.path == workspace.path)
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
            tmuxSocketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected
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
        #expect(imported.tmuxAttachMode == .protected)
        let selectedSession = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: imported)
        )
        #expect(selectedSession.socketName == workspace.tmuxSocketName)
        #expect(selectedSession.tmuxAttachMode == .protected)
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
        isMain: Bool,
        createdAt: String? = nil,
        generation: String? = nil
    ) -> KwtWorktreeRecord {
        KwtWorktreeRecord(
            path: path,
            branch: branch,
            commitHash: "abc123",
            isMain: isMain,
            createdAt: createdAt,
            generation: generation,
            repository: "github.com/kenn-io/ghosthub",
            sessionName: "kwt-\(branch.replacingOccurrences(of: "/", with: "-"))"
        )
    }
}
