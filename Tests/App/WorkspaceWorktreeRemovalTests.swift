import GhosthubTransport
import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Workspace worktree removal", .serialized)
struct WorkspaceWorktreeRemovalTests {
    @MainActor
    @Test("changes found after confirmation require explicit force removal")
    func changesFoundAfterConfirmationRequireForce() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let reads = LockedValue(0)
        let loads = LockedValue(0)
        let normalRemovals = LockedValue(0)
        let forcedRemovals = LockedValue(0)
        let afterRemoval = inventory(environment)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() < 3
                    ? fixture.beforeRemoval
                    : afterRemoval
            },
            kwtWorktreeRemover: { _, _, _, _ in
                normalRemovals.withLock { $0 += 1 }
            },
            kwtForceWorktreeRemover: { _, _, _, _ in
                forcedRemovals.withLock { $0 += 1 }
            },
            kwtWorktreeChangeReader: { _, _, _ in
                reads.withLock { $0 += 1 }
                return reads.load() == 1
                    ? .clean
                    : WorktreeChangeSummary(untracked: 1)
            }
        )

        let request = try await model.prepareWorktreeRemoval(
            fixture.removable.id
        )
        #expect(request.forceRemoval == false)

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require force confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.forceRemoval)
        #expect(updatedRequest.changes.untracked == 1)
        #expect(normalRemovals.load() == 0)
        #expect(forcedRemovals.load() == 0)

        #expect(try await model.resolveWorktreeRemoval(updatedRequest) == .removed)
        #expect(normalRemovals.load() == 0)
        #expect(forcedRemovals.load() == 1)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "removal reconciles worktree and session state in other scenes",
        arguments: [false, true]
    )
    func removalReconcilesOtherScenes(
        checkoutAlreadyAbsent: Bool
    ) async throws {
        let fixture = try removalFixture(runningSession: true)
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let afterRemoval = inventory(environment)
        let warningAfterRemoval: KwtHostInventory = {
            var inventory = beforeRemoval
            inventory.projects[0].worktrees = []
            inventory.projects[0].warning = "inventory unavailable"
            return inventory
        }()
        let coordinator = WorktreeMutationCoordinator()
        let firstLoads = LockedValue(0)
        let secondLoads = LockedValue(0)
        let secondDiscoveries = LockedValue(0)
        let firstModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                firstLoads.withLock { $0 += 1 }
                if checkoutAlreadyAbsent {
                    return afterRemoval
                }
                return firstLoads.load() == 1
                    ? beforeRemoval
                    : afterRemoval
            },
            kwtWorktreeRemover: { _, _, _, _ in },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionKiller: { _, _, _ in }
        )
        let secondModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                secondLoads.withLock { $0 += 1 }
                return secondLoads.load() == 1
                    ? beforeRemoval
                    : warningAfterRemoval
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionDiscovery: { _ in
                secondDiscoveries.withLock { $0 += 1 }
                return secondDiscoveries.load() == 1
                    ? .success([
                        DiscoveredTmuxSession(
                            name: "kwt-ghosthub-feature",
                            windowCount: 1,
                            serverPID: "31415",
                            sessionID: "$8",
                            createdAt: "1721552400",
                            managed: true
                        ),
                    ])
                    : .success([])
            }
        )
        secondModel.startKwtInventory()
        secondModel.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            secondLoads.load() >= 1
                && secondDiscoveries.load() >= 1
        }

        let request = try await firstModel.prepareWorktreeRemoval(removable.id)
        try await firstModel.removeWorktree(request)

        // Wait on the reconciled snapshot itself: the load and discovery
        // counters increment when the closures are entered, before their
        // results are applied, so counter-based waits race the assertion.
        await waitUntilMainActor {
            secondModel.snapshot.worktree(id: removable.id) == nil
                && secondModel.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        }
        await firstModel.shutdown()
        await secondModel.shutdown()
    }

    @MainActor
    @Test("removal cancels pending presentations in every scene")
    func removalCancelsPendingPresentationsInEveryScene() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var staleSnapshot = snapshot
        let staleIndex = try #require(
            staleSnapshot.worktrees.firstIndex { $0.id == removable.id }
        )
        staleSnapshot.worktrees[staleIndex].generation = nil

        let beforeRemoval = fixture.beforeRemoval
        let afterRemoval = inventory(environment)
        let coordinator = WorktreeMutationCoordinator()
        let pathGate = DispatchSemaphore(value: 0)
        let removerHold = RemovalPreflightHold()
        let pathResolutions = LockedValue(0)
        let completedPathResolutions = LockedValue(0)
        let resolveTmuxPath: @Sendable ()
            -> Result<ResolvedTmuxBinary, TmuxBinaryError> = {
                pathResolutions.withLock { $0 += 1 }
                pathGate.wait()
                completedPathResolutions.withLock { $0 += 1 }
                return successfulTmuxResolution("/usr/bin/tmux")
            }
        defer {
            pathGate.signal()
            pathGate.signal()
        }

        let firstLoads = LockedValue(0)
        let firstSurfaces = RecordingNativeSessionSurfaceStore()
        let secondSurfaces = RecordingNativeSessionSurfaceStore()
        let firstModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: firstSurfaces,
            nativeTmuxPathProvider: resolveTmuxPath,
            kwtInventoryLoader: { _ in
                firstLoads.withLock { $0 += 1 }
                return firstLoads.load() == 1
                    ? beforeRemoval
                    : afterRemoval
            },
            kwtWorktreeRemover: { _, _, _, _ in
                _ = await removerHold.load(afterRemoval)
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let secondModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: staleSnapshot,
            nativeTmuxSurfaceStore: secondSurfaces,
            nativeTmuxPathProvider: resolveTmuxPath,
            kwtInventoryLoader: { _ in beforeRemoval },
            worktreeMutationCoordinator: coordinator
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: removable)
        )
        let staleSelection = try #require(
            staleSnapshot.worktree(id: removable.id).flatMap(
                WorkspaceSidebarModel.tmuxSessionSelection(for:)
            )
        )
        var navigation = firstModel.selection
        navigation.select(.worktree(removable.id), in: firstModel.snapshot)
        firstModel.selectFromUser(navigation)
        secondModel.selectFromUser(navigation)

        firstModel.openBorrowedTmuxSession(selection)
        secondModel.openBorrowedTmuxSession(staleSelection)
        await waitUntilMainActor { pathResolutions.load() == 2 }
        #expect(firstModel.retainedBorrowedTmuxPresentationCount == 1)
        #expect(secondModel.retainedBorrowedTmuxPresentationCount == 1)

        let request = try await firstModel.prepareWorktreeRemoval(removable.id)
        let removal = Task { @MainActor in
            try await firstModel.removeWorktree(request)
        }
        await waitUntilMainActor { await removerHold.started }
        #expect(await removerHold.started)

        #expect(firstModel.retainedBorrowedTmuxPresentationCount == 0)
        #expect(secondModel.retainedBorrowedTmuxPresentationCount == 0)
        #expect(firstModel.suppressesSelectedWorktreeSessionOpen)
        #expect(secondModel.suppressesSelectedWorktreeSessionOpen)

        firstModel.openBorrowedTmuxSession(selection)
        secondModel.openBorrowedTmuxSession(staleSelection)
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(firstModel.retainedBorrowedTmuxPresentationCount == 0)
        #expect(secondModel.retainedBorrowedTmuxPresentationCount == 0)
        #expect(pathResolutions.load() == 2)

        pathGate.signal()
        pathGate.signal()
        await waitUntilMainActor {
            completedPathResolutions.load() == 2
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(firstSurfaces.requestedConfigurations.isEmpty)
        #expect(secondSurfaces.requestedConfigurations.isEmpty)

        await removerHold.release()
        try await removal.value
        #expect(firstModel.snapshot.worktree(id: removable.id) == nil)
        #expect(secondModel.snapshot.worktree(id: removable.id) == nil)
        await firstModel.shutdown()
        await secondModel.shutdown()
    }

    @MainActor
    @Test("a successful removal strips scenes with legacy project identity")
    func successfulRemovalStripsLegacyIdentityScene() async throws {
        struct InventoryUnavailable: Error {}
        let fixture = try removalFixture()
        let environment = fixture.environment
        let removable = fixture.removable
        var legacySnapshot = fixture.snapshot
        for index in legacySnapshot.projects.indices
            where legacySnapshot.projects[index].id == removable.projectID {
            legacySnapshot.projects[index].scopedKey = ""
        }
        let beforeRemoval = fixture.beforeRemoval
        let afterRemoval = inventory(environment)
        let loads = LockedValue(0)
        let coordinator = WorktreeMutationCoordinator()
        let currentModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1
                    ? beforeRemoval
                    : afterRemoval
            },
            kwtWorktreeRemover: { _, _, _, _ in },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let legacyModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: legacySnapshot,
            kwtInventoryLoader: { _ in throw InventoryUnavailable() },
            worktreeMutationCoordinator: coordinator
        )
        #expect(legacyModel.snapshot.worktree(id: removable.id) != nil)

        let request = try await currentModel.prepareWorktreeRemoval(
            removable.id
        )
        try await currentModel.removeWorktree(request)

        #expect(currentModel.snapshot.worktree(id: removable.id) == nil)
        #expect(legacyModel.snapshot.worktree(id: removable.id) == nil)
        await currentModel.shutdown()
        await legacyModel.shutdown()
    }

}
