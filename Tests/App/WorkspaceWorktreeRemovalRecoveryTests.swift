import GhosthubTransport
import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

extension WorkspaceWorktreeRemovalTests {
    @MainActor
    @Test("failed removal restores the canonical endpoint in a stale scene")
    func failedRemovalRestoresCanonicalEndpointAcrossScenes() async throws {
        let fixture = try removalFixture(sessionName: "kwt-ghosthub-stale")
        let environment = fixture.environment
        let stale = fixture.removable
        let staleSnapshot = fixture.snapshot
        var canonical = stale
        canonical.tmuxSessionName = "kwt-ghosthub-canonical"
        var currentSnapshot = environment.snapshot
        currentSnapshot.worktrees.append(canonical)
        let currentInventory = inventory(
            environment,
            including: canonical
        )
        let coordinator = WorktreeMutationCoordinator()
        let staleSurfaces = RecordingNativeSessionSurfaceStore()
        let currentModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: currentSnapshot,
            kwtInventoryLoader: { _ in currentInventory },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let staleModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: staleSnapshot,
            nativeTmuxSurfaceStore: staleSurfaces,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            worktreeMutationCoordinator: coordinator
        )
        let staleSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: stale)
        )
        let canonicalSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: canonical)
        )
        staleModel.openBorrowedTmuxSession(staleSelection)
        await waitUntilMainActor {
            staleSurfaces.requestedConfigurations.count == 1
        }

        let request = try await currentModel.prepareWorktreeRemoval(
            canonical.id
        )
        await #expect(throws: KwtWorktreeError.self) {
            try await currentModel.removeWorktree(request)
        }
        await waitUntilMainActor {
            staleSurfaces.requestedConfigurations.count == 2
        }

        #expect(
            staleModel.retainedBorrowedTmuxHandle(for: staleSelection) == nil
        )
        #expect(
            staleModel.retainedBorrowedTmuxHandle(for: canonicalSelection)
                != nil
        )
        #expect(staleModel.activeBorrowedTmuxSelection == canonicalSelection)
        await currentModel.shutdown()
        await staleModel.shutdown()
    }

    @MainActor
    @Test(
        "a replacement racing a failed remove suppresses stale restoration"
    )
    func replacementAfterFailedRemoveRequiresConfirmation() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var replacement = removable
        replacement.generation = "fedcba9876543210fedcba9876543210"
        let beforeRemoval = fixture.beforeRemoval
        let afterReplacement = inventory(
            environment,
            including: replacement,
            generation: replacement.generation
        )
        let loads = LockedValue(0)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterReplacement
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: WorktreeMutationCoordinator(),
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Replacement should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.generation == replacement.generation)
        #expect(loads.load() == 2)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(surfaces.requestedConfigurations.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "a same-generation metadata change after a failed remove keeps the worktree"
    )
    func metadataChangeAfterFailedRemoveKeepsWorktree() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var changed = removable
        changed.branch = "feature/renamed"
        let beforeRemoval = fixture.beforeRemoval
        let afterMetadataChange = inventory(environment, including: changed)
        let loads = LockedValue(0)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterMetadataChange
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: WorktreeMutationCoordinator(),
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Metadata change should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.branch == changed.branch)
        #expect(
            updatedRequest.worktree.generation == stableWorktreeGeneration
        )
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)

        model.startKwtInventory()
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            loads.load() >= 3 && model.isWorkspaceInventoryRefreshComplete
        }
        #expect(model.snapshot.worktrees.contains {
            $0.path == removable.path
                && $0.generation == stableWorktreeGeneration
        })
        await model.shutdown()
    }

    @MainActor
    @Test(
        "failed removal restores the refreshed same-generation endpoint",
        arguments: [true, false]
    )
    func failedRemovalRestoresRefreshedEndpoint(
        sessionNameChanged: Bool
    ) async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var changed = removable
        if sessionNameChanged {
            changed.tmuxSessionName = "kwt-ghosthub-renamed"
        } else {
            changed.tmuxSocketName = "kwt-ghosthub-socket"
        }
        let beforeRemoval = fixture.beforeRemoval
        let afterEndpointChange = inventory(environment, including: changed)
        let loads = LockedValue(0)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterEndpointChange
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: WorktreeMutationCoordinator(),
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let changedSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: changed)
        )
        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }

        let result = try await model.resolveWorktreeRemoval(request)
        guard case .confirmationRequired = result else {
            Issue.record("Endpoint change should require a new confirmation")
            await model.shutdown()
            return
        }

        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) == nil)
        #expect(
            model.retainedBorrowedTmuxHandle(for: changedSelection) != nil
        )
        #expect(
            model.activeBorrowedTmuxSelection?.name
                == changedSelection.name
        )
        #expect(
            model.activeBorrowedTmuxSelection?.socketName
                == changedSelection.socketName
        )
        await model.shutdown()
    }

    @MainActor
    @Test(
        "an absent target after a failed remove suppresses restoration"
    )
    func absentTargetAfterFailedRemoveSuppressesRestoration() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let afterRemoval = inventory(environment)
        let loads = LockedValue(0)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterRemoval
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: WorktreeMutationCoordinator(),
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }

        await #expect(
            throws: KwtWorktreeError.removalFailed(
                host: "Local",
                status: 1
            )
        ) {
            try await model.removeWorktree(request)
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(loads.load() == 2)
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(surfaces.requestedConfigurations.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "a cross-project reassignment after a failed remove suppresses restoration"
    )
    func crossProjectReassignmentSuppressesRestoration() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let afterReassignment = KwtHostInventory(projects: [
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
                        generation: nil,
                        repository: environment.project.scopedKey,
                        sessionName: "kwt-ghosthub-main",
                        tmuxSocketName: nil
                    ),
                ],
                warning: nil
            ),
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "/tmp/ghosthub-other",
                    name: "other",
                    path: "/tmp/ghosthub-other",
                    lastTouched: nil
                ),
                worktrees: [
                    KwtWorktreeRecord(
                        path: removable.path,
                        branch: removable.branch,
                        commitHash: "",
                        isMain: false,
                        createdAt: nil,
                        generation: stableWorktreeGeneration,
                        repository: "/tmp/ghosthub-other",
                        sessionName: "kwt-ghosthub-other-feature",
                        tmuxSocketName: nil
                    ),
                ],
                warning: nil
            ),
        ])
        let loads = LockedValue(0)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterReassignment
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: WorktreeMutationCoordinator(),
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }

        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await model.removeWorktree(request)
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(loads.load() == 2)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(surfaces.requestedConfigurations.count == 1)
        #expect(model.snapshot.worktrees.contains { worktree in
            worktree.path == removable.path
                && worktree.generation == stableWorktreeGeneration
                && model.snapshot.project(id: worktree.projectID)?.scopedKey
                == "/tmp/ghosthub-other"
        })
        await model.shutdown()
    }

    @MainActor
    @Test(
        "a cross-project reassignment closes stale-scene presentations"
    )
    func crossProjectReassignmentClosesStaleScenePresentation() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let beforeRemoval = fixture.beforeRemoval
        let afterReassignment = KwtHostInventory(projects: [
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
                        generation: nil,
                        repository: environment.project.scopedKey,
                        sessionName: "kwt-ghosthub-main",
                        tmuxSocketName: nil
                    ),
                ],
                warning: nil
            ),
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "/tmp/ghosthub-other",
                    name: "other",
                    path: "/tmp/ghosthub-other",
                    lastTouched: nil
                ),
                worktrees: [
                    KwtWorktreeRecord(
                        path: removable.path,
                        branch: removable.branch,
                        commitHash: "",
                        isMain: false,
                        createdAt: nil,
                        generation: stableWorktreeGeneration,
                        repository: "/tmp/ghosthub-other",
                        sessionName: "kwt-ghosthub-other-feature",
                        tmuxSocketName: nil
                    ),
                ],
                warning: nil
            ),
        ])
        let loads = LockedValue(0)
        let coordinator = WorktreeMutationCoordinator()
        let staleSurfaces = RecordingNativeSessionSurfaceStore()
        let currentModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterReassignment
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let staleModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            nativeTmuxSurfaceStore: staleSurfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        staleModel.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            staleSurfaces.requestedConfigurations.count == 1
        }

        let request = try await currentModel.prepareWorktreeRemoval(
            removable.id
        )
        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await currentModel.removeWorktree(request)
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(staleModel.retainedBorrowedTmuxPresentationCount == 0)
        #expect(staleSurfaces.requestedConfigurations.count == 1)
        #expect(staleModel.snapshot.worktree(id: removable.id) == nil)
        await currentModel.shutdown()
        await staleModel.shutdown()
    }

    @MainActor
    @Test(
        "an incomplete owning repository keeps failed-removal identity"
    )
    func incompleteOwningRepositoryKeepsFailedRemovalIdentity() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let movedRootPath = "/tmp/ghosthub-moved-root"
        let conflictedRefresh = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: environment.project.scopedKey,
                    name: environment.project.name,
                    path: movedRootPath,
                    lastTouched: nil
                ),
                worktrees: [],
                warning: "kwt could not enumerate worktrees"
            ),
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "/tmp/ghosthub-occupant",
                    name: "occupant",
                    path: environment.project.rootPath,
                    lastTouched: nil
                ),
                worktrees: [],
                warning: nil
            ),
        ])
        let loads = LockedValue(0)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : conflictedRefresh
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: WorktreeMutationCoordinator(),
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }

        await #expect(
            throws: KwtWorktreeError.removalFailed(
                host: "Local",
                status: 1
            )
        ) {
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }

        #expect(loads.load() == 2)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) != nil)
        #expect(model.snapshot.worktrees.contains {
            $0.path == removable.path
                && $0.generation == stableWorktreeGeneration
        })
        await model.shutdown()
    }

    @MainActor
    @Test(
        "a stale scene restores the endpoint reconciled during recovery"
    )
    func staleSceneRestoresRecoveryReconciledEndpoint() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        var renamed = removable
        renamed.tmuxSessionName = "kwt-ghosthub-renamed"
        let beforeRemoval = fixture.beforeRemoval
        let afterRename = inventory(environment, including: renamed)
        let loads = LockedValue(0)
        let coordinator = WorktreeMutationCoordinator()
        let staleSurfaces = RecordingNativeSessionSurfaceStore()
        let currentModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterRename
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let staleModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            nativeTmuxSurfaceStore: staleSurfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator
        )
        let saved = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let renamedSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: renamed)
        )
        staleModel.openBorrowedTmuxSession(saved)
        await waitUntilMainActor {
            staleSurfaces.requestedConfigurations.count == 1
        }

        let request = try await currentModel.prepareWorktreeRemoval(
            removable.id
        )
        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await currentModel.removeWorktree(request)
        }
        await waitUntilMainActor {
            staleSurfaces.requestedConfigurations.count == 2
        }

        #expect(
            staleModel.retainedBorrowedTmuxHandle(for: saved) == nil
        )
        #expect(
            staleModel.retainedBorrowedTmuxHandle(for: renamedSelection)
                != nil
        )
        #expect(
            staleModel.activeBorrowedTmuxSelection?.name
                == renamedSelection.name
        )
        await currentModel.shutdown()
        await staleModel.shutdown()
    }

    @MainActor
    @Test(
        "a same-repository move after a failed remove restores the moved endpoint"
    )
    func sameRepositoryMoveRestoresMovedEndpoint() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var moved = removable
        moved.path = "/tmp/ghosthub-feature-moved"
        moved.scopedKey = moved.path
        let beforeRemoval = fixture.beforeRemoval
        let afterMove = inventory(environment, including: moved)
        let loads = LockedValue(0)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterMove
            },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: WorktreeMutationCoordinator(),
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("A moved target should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.path == moved.path)
        #expect(
            updatedRequest.worktree.generation == stableWorktreeGeneration
        )
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(
            model.activeBorrowedTmuxSelection?.workspacePath == moved.path
        )
        #expect(model.snapshot.worktrees.contains {
            $0.path == moved.path
                && $0.generation == stableWorktreeGeneration
        })
        await model.shutdown()
    }

    @MainActor
    @Test("post-removal refresh ignores a generationless stale record")
    func postRemovalRefreshIgnoresGenerationlessRecord() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let staleRefresh = inventory(
            environment,
            including: removable,
            generation: nil
        )
        let loads = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1 ? beforeRemoval : staleRefresh
            },
            kwtWorktreeRemover: { _, _, _, _ in },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        try await model.removeWorktree(request)
        model.startKwtInventory()
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            loads.load() >= 3 && model.isWorkspaceInventoryRefreshComplete
        }

        #expect(loads.load() == 3)
        #expect(!model.snapshot.worktrees.contains {
            $0.hostID == removable.hostID && $0.path == removable.path
        })
        await model.shutdown()
    }

    @MainActor
    @Test("failed removal restores an inactive retained presentation")
    func failedRemovalRestoresInactivePresentation() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let removerHold = RemovalPreflightHold()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                _ = await removerHold.load(beforeRemoval)
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            worktreeMutationCoordinator: WorktreeMutationCoordinator(),
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        var navigation = model.selection
        navigation.select(.worktree(removable.id), in: model.snapshot)
        model.selectFromUser(navigation)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let other = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "other"
        )
        model.openBorrowedTmuxSession(selection)
        let removedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        model.openBorrowedTmuxSession(other)
        let activeHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: other)
        )
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(model.activeBorrowedTmuxSelection == other)

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor { await removerHold.started }
        #expect(await removerHold.started)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(model.suppressesSelectedWorktreeSessionOpen)

        model.openBorrowedTmuxSession(selection)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)

        await removerHold.release()
        await #expect(
            throws: KwtWorktreeError.removalFailed(
                host: "Local",
                status: 1
            )
        ) {
            try await removal.value
        }
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(
            model.retainedBorrowedTmuxHandle(for: selection) != removedHandle
        )
        #expect(model.retainedBorrowedTmuxHandle(for: other) == activeHandle)
        #expect(model.activeBorrowedTmuxSelection == other)
        await model.shutdown()
    }

    @MainActor
    @Test("failed removal does not replace newer active presentation")
    func failedRemovalPreservesNewerActivePresentation() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let removerHold = RemovalPreflightHold()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                _ = await removerHold.load(beforeRemoval)
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let removed = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let newer = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "newer"
        )
        model.openBorrowedTmuxSession(removed)

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor { await removerHold.started }
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)

        model.openBorrowedTmuxSession(newer)
        let newerHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: newer)
        )
        await removerHold.release()
        await #expect(throws: KwtWorktreeError.self) {
            try await removal.value
        }

        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(model.activeBorrowedTmuxSelection == newer)
        #expect(model.retainedBorrowedTmuxHandle(for: newer) == newerHandle)
        await model.shutdown()
    }

    @MainActor
    @Test("failed removal re-establishes a terminated worktree session")
    func failedRemovalReestablishesTerminatedSession() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let surfaces = RecordingNativeSessionSurfaceStore()
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            localKwtPathProvider: { "/test/kwt" },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            !surfaces.requestedConfigurations.isEmpty
        }
        let initialRequestCount = surfaces.requestedConfigurations.count

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.removalFailed(
            host: "Local",
            status: 1
        )) {
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count > initialRequestCount
        }

        #expect(kills.load() == 1)
        let restoredCommand = try #require(
            surfaces.requestedConfigurations.last?.command
        )
        #expect(restoredCommand.contains("kwt"))
        #expect(restoredCommand.contains("open"))
        #expect(!restoredCommand.contains("attach-session"))
        await model.shutdown()
    }

    @MainActor
    @Test("a dirty rejection after session termination requires force confirmation")
    func dirtyRejectionAfterSessionTerminationRequiresForce() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let surfaces = RecordingNativeSessionSurfaceStore()
        let reads = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            localKwtPathProvider: { "/test/kwt" },
            kwtInventoryLoader: { _ in fixture.beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            kwtWorktreeChangeReader: { _, _, _ in
                reads.withLock { $0 += 1 }
                return reads.load() < 3
                    ? .clean
                    : WorktreeChangeSummary(untracked: 1)
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            !surfaces.requestedConfigurations.isEmpty
        }
        let initialRequestCount = surfaces.requestedConfigurations.count

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Dirty removal should require force confirmation")
            await model.shutdown()
            return
        }
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count > initialRequestCount
        }

        #expect(updatedRequest.forceRemoval)
        #expect(kills.load() == 1)
        let restoredCommand = try #require(
            surfaces.requestedConfigurations.last?.command
        )
        #expect(restoredCommand.contains("kwt"))
        #expect(restoredCommand.contains("open"))
        await model.shutdown()
    }

    @MainActor
    @Test("failed removal preserves pending workspace establishment")
    func failedRemovalPreservesPendingEstablishment() async throws {
        let environment = try setupRemoteEnvironment()
        var removable = try #require(environment.snapshot.worktrees.first)
        removable.generation = stableWorktreeGeneration
        removable.scopedKey = removable.path
        removable.tmuxSessionName = "kwt-ghosthub-main"
        var snapshot = environment.snapshot
        snapshot.worktrees = [removable]
        let beforeRemoval = inventory(environment, including: removable)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Office Linux",
                    status: 1
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            !surfaces.requestedConfigurations.isEmpty
        }
        #expect(surfaces.lastCommand?.contains("'open'") == true)
        model.openBorrowedTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "other-session"
        ))
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }
        let initialRequestCount = surfaces.requestedConfigurations.count

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.self) {
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count > initialRequestCount
        }

        #expect(surfaces.lastCommand?.contains("'open'") == true)
        await model.shutdown()
    }

    @MainActor
    @Test("failed removal preserves interrupted local establishment")
    func failedRemovalPreservesInterruptedLocalEstablishment() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let surfaces = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            localKwtPathProvider: { "/test/kwt" },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            !surfaces.requestedConfigurations.isEmpty
        }
        #expect(surfaces.lastCommand?.contains("kwt") == true)
        model.openBorrowedTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "other-session"
        ))
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }
        let initialRequestCount = surfaces.requestedConfigurations.count

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.self) {
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count > initialRequestCount
        }

        #expect(surfaces.lastCommand?.contains("kwt") == true)
        #expect(surfaces.lastCommand?.contains("open") == true)
        await model.shutdown()
    }

    @MainActor
    @Test("failed removal restores a pathless matching endpoint")
    func failedRemovalRestoresPathlessMatchingEndpoint() async throws {
        let fixture = try removalFixture(socketName: "kwt-pr-0123456789abcdef")
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let surfaces = RecordingNativeSessionSurfaceStore()
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            localKwtPathProvider: { "/test/kwt" },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                throw KwtWorktreeError.removalFailed(
                    host: "Local",
                    status: 1
                )
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )
        let pathless = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-feature",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(pathless)
        await waitUntilMainActor {
            !surfaces.requestedConfigurations.isEmpty
        }
        let initialRequestCount = surfaces.requestedConfigurations.count

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.self) {
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count > initialRequestCount
        }

        #expect(kills.load() == 1)
        #expect(
            model.activeBorrowedTmuxSelection?.workspacePath == removable.path
        )
        #expect(surfaces.lastCommand?.contains("kwt") == true)
        #expect(surfaces.lastCommand?.contains("pr") == true)
        #expect(surfaces.lastCommand?.contains("attach") == true)
        await model.shutdown()
    }

    @MainActor
    @Test("endpoint changes discard pending removal restoration")
    func endpointChangeDiscardsPendingRemovalRestoration() async throws {
        let environment = try setupRemoteEnvironment()
        var removable = try #require(environment.snapshot.worktrees.first)
        removable.generation = stableWorktreeGeneration
        removable.scopedKey = removable.path
        removable.tmuxSessionName = "kwt-ghosthub-main"
        var snapshot = environment.snapshot
        snapshot.worktrees = [removable]
        let beforeRemoval = inventory(environment, including: removable)
        let surfaces = RecordingNativeSessionSurfaceStore()
        let removerHold = RemovalPreflightHold()
        let originalDestination = try #require(
            environment.host.sshDestination
        )
        let configuredHosts = LockedValue([
            SSHHost(
                configKey: environment.host.configKey,
                name: environment.host.name,
                platform: .linux,
                sshDestination: originalDestination
            ),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                _ = await removerHold.load(beforeRemoval)
                throw KwtWorktreeError.removalFailed(
                    host: "Office Linux",
                    status: 1
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            },
            configuredSSHHostsProvider: { configuredHosts.load() }
        )
        model.refreshHosts()
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            !surfaces.requestedConfigurations.isEmpty
        }
        model.openBorrowedTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "other-session"
        ))
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }
        let initialRequestCount = surfaces.requestedConfigurations.count

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor { await removerHold.started }
        configuredHosts.withLock {
            $0 = [
                SSHHost(
                    configKey: environment.host.configKey,
                    name: environment.host.name,
                    platform: .linux,
                    sshDestination: "wesm@replacement.example.com"
                ),
            ]
        }
        model.refreshHosts()
        await removerHold.release()
        await #expect(throws: KwtWorktreeError.self) {
            try await removal.value
        }

        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(
            surfaces.requestedConfigurations.count == initialRequestCount
        )
        await model.shutdown()
    }

    @MainActor
    @Test("removal preflight invalidates a replaced retained endpoint")
    func removalPreflightInvalidatesReplacedPresentation() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var replacement = removable
        replacement.tmuxSessionName = "kwt-ghosthub-replacement"
        let replacementInventory = inventory(
            environment,
            including: replacement
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in replacementInventory },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        model.openBorrowedTmuxSession(selection)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await model.removeWorktree(request)
        }

        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        await model.shutdown()
    }

}
