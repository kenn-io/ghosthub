import GhosthubTransport
import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private let stableWorktreeGeneration =
    "0123456789abcdef0123456789abcdef"

private actor RemovalPreflightHold {
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

private func inventory(
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

private func inventory(
    _ environment: RemoteEnvironment,
    including worktree: WorktreeSummary
) -> KwtHostInventory {
    KwtHostInventory(projects: [
        KwtProjectInventory(
            project: KwtProjectRecord(
                repository: environment.project.scopedKey,
                name: environment.project.name,
                path: environment.project.rootPath,
                lastTouched: nil
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
                    tmuxSocketName: worktree.tmuxSocketName
                ),
            ],
            warning: nil
        ),
    ])
}

private struct RemovalFixture {
    let environment: StandardEnvironment
    var removable: WorktreeSummary
    var snapshot: WorkspaceSnapshot
    var beforeRemoval: KwtHostInventory
}

/// Builds the standard local environment plus one removable worktree, the
/// snapshot that contains it, and the inventory that still reports it.
private func removalFixture(
    path: String = "/tmp/ghosthub-feature",
    name: String = "feature/remove",
    branch: String = "feature/remove",
    sessionName: String? = "kwt-ghosthub-feature",
    socketName: String? = nil,
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

@Suite("Workspace worktree removal", .serialized)
struct WorkspaceWorktreeRemovalTests {
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
        await waitUntilMainActor(timeout: .seconds(10)) {
            secondLoads.load() >= 1
                && secondDiscoveries.load() >= 1
        }

        let request = try await firstModel.prepareWorktreeRemoval(removable.id)
        try await firstModel.removeWorktree(request)

        // Wait on the reconciled snapshot itself: the load and discovery
        // counters increment when the closures are entered, before their
        // results are applied, so counter-based waits race the assertion.
        await waitUntilMainActor(timeout: .seconds(10)) {
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

    @MainActor
    @Test(
        "live session removal leaves a same-path worktree on another host"
    )
    func liveSessionIsKilledFirst() async throws {
        let fixture = try removalFixture(
            socketName: "kwt-pr-0123456789abcdef",
            sessionBackend: .localTmux
        )
        let environment = fixture.environment
        let removable = fixture.removable
        var snapshot = fixture.snapshot
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
        snapshot.worktrees.append(samePath)
        let events = LockedValue<[String]>([])
        let loads = LockedValue(0)
        let beforeRemoval = fixture.beforeRemoval
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
            kwtWorktreeRemover: { path, _, projectPath, _ in
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
        #expect(model.selection.selectedProjectID == environment.project.id)
        #expect(model.selection.selectedWorktreeID == nil)
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
    @Test("an already-absent worktree completes cached removal")
    func alreadyAbsentWorktreeCompletesRemoval() async throws {
        let fixture = try removalFixture(sessionName: nil)
        let environment = fixture.environment
        let removable = fixture.removable
        let session = TerminalSessionSummary(
            id: UUID(),
            hostID: environment.host.id,
            worktreeID: removable.id,
            scopedKey: removable.scopedKey,
            isAlive: false
        )
        var snapshot = fixture.snapshot
        snapshot.sessions.append(session)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        try await model.removeWorktree(request)

        #expect(removals.load() == 0)
        #expect(kills.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        #expect(model.snapshot.sessions.contains { $0.id == session.id } == false)
        await model.shutdown()
    }

    @MainActor
    @Test("an already-absent worktree still kills its confirmed session")
    func alreadyAbsentWorktreeKillsConfirmedSession() async throws {
        let fixture = try removalFixture(
            socketName: "kwt-pr-0123456789abcdef",
            sessionBackend: .localTmux
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let events = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _ in
                events.withLock { $0.append("remove") }
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

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest != nil)
        try await model.removeWorktree(request)

        #expect(events.load() == ["kill:kwt-ghosthub-feature"])
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a session starting for an absent worktree requires confirmation again")
    func newlyStartedSessionForAbsentWorktreeAbortsRemoval() async throws {
        let fixture = try removalFixture(
            socketName: "kwt-pr-0123456789abcdef",
            sessionBackend: .localTmux
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                reads.withLock { $0 += 1 }
                if reads.load() == 1 {
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
        await #expect(
            throws: KwtWorktreeError.sessionStartedAfterConfirmation(
                session: "kwt-ghosthub-feature"
            )
        ) {
            try await model.removeWorktree(request)
        }

        #expect(removals.load() == 0)
        #expect(kills.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "removal requires a canonical worktree generation",
        arguments: [
            nil,
            "",
            "   ",
            "not-a-generation",
            "0123456789abcdef",
            "0123456789ABCDEF0123456789ABCDEF",
        ] as [String?]
    )
    func invalidGenerationAbortsPreparation(
        generation: String?
    ) async throws {
        let environment = try setupStandardEnvironment()
        let removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: generation
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
        worktree.generation = stableWorktreeGeneration
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
            kwtWorktreeRemover: { _, _, _, _ in
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
    @Test("removal rejects a host endpoint changed after confirmation")
    func changedHostEndpointAbortsRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        #expect(
            request.confirmedHost.sshDestination
                == environment.host.sshDestination
        )
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await model.removeWorktree(request)
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a changed host endpoint cannot refresh removal confirmation")
    func changedHostEndpointIsNotRecoverable() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await model.resolveWorktreeRemoval(request)
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a changed target cannot redirect confirmation to a new host")
    func changedTargetAndHostEndpointAreNotRecoverable() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        model.snapshot.worktrees[0].branch = "feature/replacement"
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await model.resolveWorktreeRemoval(request)
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("removal rechecks the confirmed host after preflight")
    func hostEndpointChangedDuringPreflightAbortsRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.scopedKey = worktree.path
        worktree.tmuxSessionName = "kwt-remote-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let hold = RemovalPreflightHold()
        let preflight = inventory(environment, including: worktree)
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                try await hold.verify(selection: selection, host: host)
            }
        )
        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.resolveWorktreeRemoval(request)
        }
        await waitUntilMainActor { await hold.started }
        #expect(await hold.started)
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("failed removal re-establishes after endpoint changes during kill")
    func endpointChangeDuringKillReestablishesPresentation() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.scopedKey = worktree.path
        worktree.tmuxSessionName = "kwt-remote-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let beforeRemoval = inventory(environment, including: worktree)
        let killHold = RemovalPreflightHold()
        let surfaces = RecordingNativeSessionSurfaceStore()
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxSessionKiller: { _, _, _ in
                _ = await killHold.load(beforeRemoval)
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: try #require(worktree.tmuxSessionName)
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }
        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor { await killHold.started }

        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await killHold.release()
        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }

        #expect(removals.load() == 0)
        #expect(surfaces.lastCommand?.contains("'open'") == true)
        await model.shutdown()
    }

    @MainActor
    @Test("a session start cannot redirect removal recovery to a new host")
    func sessionStartRecoveryRejectsChangedHostEndpoint() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.scopedKey = worktree.path
        worktree.tmuxSessionName = "kwt-remote-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let hold = RemovalPreflightHold()
        let preflight = inventory(environment, including: worktree)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                try await hold.verifyStartedSession(
                    selection: selection,
                    host: host,
                    identity: identity
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.resolveWorktreeRemoval(request)
        }
        await waitUntilMainActor { await hold.started }
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a replaced session cannot redirect removal recovery to a new host")
    func sessionChangeRecoveryRejectsChangedHostEndpoint() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.scopedKey = worktree.path
        worktree.tmuxSessionName = "kwt-remote-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "kwt-remote-feature",
                managed: true,
                windows: [],
                serverPID: "31415",
                sessionID: "$8",
                createdAt: "1721552400"
            ),
        ]
        let hold = RemovalPreflightHold()
        let preflight = inventory(environment, including: worktree)
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { selection, _, host in
                _ = await hold.load(preflight)
                throw TmuxSessionKillError.sessionChanged(
                    host: host.displayName,
                    session: selection.name
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "27182",
                    sessionID: "$13",
                    createdAt: "1786136400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.resolveWorktreeRemoval(request)
        }
        await waitUntilMainActor { await hold.started }
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("an absent preflight cannot clear state for a changed host endpoint")
    func absentPreflightWithChangedHostEndpointAbortsRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let absentPreflight: KwtHostInventory = {
            var value = inventory(environment, including: worktree)
            value.projects[0].worktrees = []
            return value
        }()
        let hold = RemovalPreflightHold()
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                await hold.load(absentPreflight)
            },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )
        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor { await hold.started }
        #expect(await hold.started)
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: worktree.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a session starting after confirmation requires confirmation again")
    func newlyStartedSessionAbortsRemoval() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            branch: "main",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let beforeRemoval = fixture.beforeRemoval
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
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
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(
            updatedRequest.sessionKillRequest?.session.name
                == "kwt-project-a-feature"
        )
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a replaced session requires a fresh removal confirmation")
    func replacedSessionRequiresFreshConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            branch: "main",
            sessionName: "kwt-project-a-feature",
            runningSession: true
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let replacementIdentity = TmuxSessionIdentity(
            serverPID: "27182",
            sessionID: "$13",
            createdAt: "1786136400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { selection, _, _ in
                kills.withLock { $0 += 1 }
                throw TmuxSessionKillError.sessionChanged(
                    host: "localhost",
                    session: selection.name
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                reads.withLock { $0 += 1 }
                return replacementIdentity
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest?.serverPID == "31415")
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Replacement should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.sessionKillRequest?.serverPID == "27182")
        #expect(updatedRequest.sessionKillRequest?.sessionID == "$13")
        #expect(
            updatedRequest.sessionKillRequest?.sessionCreatedAt
                == "1786136400"
        )
        #expect(reads.load() == 1)
        #expect(kills.load() == 1)
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a confirmed session ending requires a fresh removal confirmation")
    func endedSessionRequiresFreshConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            branch: "main",
            sessionName: "kwt-project-a-feature",
            runningSession: true
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { selection, _, host in
                kills.withLock { $0 += 1 }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                reads.withLock { $0 += 1 }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest?.serverPID == "31415")
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Ended session should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.sessionKillRequest == nil)
        #expect(reads.load() == 1)
        #expect(kills.load() == 1)
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("refresh failure after removal is a reconciliation warning")
    func refreshFailureDoesNotUndoRemoval() async throws {
        let fixture = try removalFixture(branch: "main")
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let loads = LockedValue(0)
        let removals = LockedValue(0)
        let beforeRemoval = fixture.beforeRemoval
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
            kwtWorktreeRemover: { _, _, _, _ in
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
    @Test("successful removal cancels pending window restoration")
    func removalCancelsPendingRestoration() async throws {
        let fixture = try removalFixture(
            path: "/tmp/ghosthub-restoration-boundary",
            name: "feature/restoration-boundary",
            branch: "feature/restoration-boundary",
            sessionName: "kwt-ghosthub-restoration-boundary"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let loads = LockedValue(0)
        let beforeRemoval = fixture.beforeRemoval
        let afterRemoval = inventory(environment)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1 ? beforeRemoval : afterRemoval
            },
            kwtWorktreeRemover: { _, _, _, _ in },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
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

        let request = try await model.prepareWorktreeRemoval(removable.id)
        try await model.removeWorktree(request)

        #expect(!model.isWorkspaceRestorationPending)
        #expect(model.snapshot.worktree(id: removable.id) == nil)
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
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var replacement = removable
        replacement.branch = replacementBranch
        replacement.name = replacementBranch
        replacement.tmuxSessionName = replacementSession
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
            kwtWorktreeRemover: { _, _, _, _ in
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
    @Test("a moved worktree outranks a replacement reusing its runtime ID")
    func movedWorktreeRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var moved = removable
        moved.path = "/tmp/project-a-moved"
        moved.scopedKey = moved.path
        let replacementGeneration = "fedcba9876543210fedcba9876543210"
        var inventoryAfterMove = inventory(environment, including: moved)
        inventoryAfterMove.projects[0].worktrees.append(KwtWorktreeRecord(
            path: removable.path,
            branch: "feature/replacement",
            commitHash: "",
            isMain: false,
            createdAt: nil,
            generation: replacementGeneration,
            repository: environment.project.scopedKey,
            sessionName: "kwt-project-a-replacement",
            tmuxSocketName: nil
        ))
        let movedInventory = inventoryAfterMove
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in movedInventory },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in identity }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.id != request.worktree.id)
        #expect(updatedRequest.worktree.path == moved.path)
        #expect(
            updatedRequest.worktree.generation
                == stableWorktreeGeneration
        )
        #expect(kills.load() == 0)
        #expect(removals.load() == 0)
        #expect(
            model.snapshot.worktree(id: removable.id)?.generation
                == replacementGeneration
        )
        #expect(model.snapshot.worktree(id: updatedRequest.worktree.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a moved worktree retains its protected socket identity")
    func movedWorktreeRetainsProtectedSocket() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var moved = removable
        moved.path = "/tmp/project-a-moved"
        moved.scopedKey = moved.path
        var inventoryAfterMove = inventory(environment, including: moved)
        let recordIndex = try #require(
            inventoryAfterMove.projects[0].worktrees.firstIndex {
                $0.path == moved.path
            }
        )
        inventoryAfterMove.projects[0]
            .worktrees[recordIndex].tmuxSocketName = nil
        let movedInventory = inventoryAfterMove
        let probes = LockedValue<[String?]>([])
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in movedInventory },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                probes.withLock { $0.append(selection.socketName) }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.path == moved.path)
        #expect(updatedRequest.worktree.tmuxSocketName == "protected")
        #expect(probes.load() == ["protected", "protected"])
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "a replacement claiming the confirmed tmux endpoint requires confirmation",
        arguments: ["protected", nil] as [String?]
    )
    func replacementClaimingTmuxEndpointRequiresConfirmation(
        replacementSocket: String?
    ) async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var replacement = WorktreeSummary.fixture(
            hostID: removable.hostID,
            projectID: removable.projectID,
            scopedKey: "/tmp/project-a-replacement",
            name: removable.name,
            path: "/tmp/project-a-replacement",
            branch: removable.branch,
            generation: "fedcba9876543210fedcba9876543210"
        )
        replacement.tmuxSessionName = removable.tmuxSessionName
        replacement.tmuxSocketName = replacementSocket
        let replacementInventory = inventory(
            environment,
            including: replacement,
            generation: replacement.generation
        )
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in replacementInventory },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in identity }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Replacement should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.path == replacement.path)
        #expect(updatedRequest.worktree.generation == replacement.generation)
        #expect(updatedRequest.worktree.tmuxSocketName == replacementSocket)
        #expect(kills.load() == 0)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "a different project claiming removal identity fails closed",
        arguments: [true, false]
    )
    func differentProjectClaimingRemovalIdentityFailsClosed(
        claimsGeneration: Bool
    ) async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var conflictingInventory = inventory(environment)
        conflictingInventory.projects.append(KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "/tmp/project-b",
                name: "project-b",
                path: "/tmp/project-b",
                lastTouched: nil
            ),
            worktrees: [
                KwtWorktreeRecord(
                    path: "/tmp/project-b-feature",
                    branch: "feature/other",
                    commitHash: "",
                    isMain: false,
                    createdAt: nil,
                    generation: claimsGeneration
                        ? stableWorktreeGeneration
                        : "fedcba9876543210fedcba9876543210",
                    repository: "/tmp/project-b",
                    sessionName: claimsGeneration
                        ? "kwt-project-b-feature"
                        : removable.tmuxSessionName ?? "",
                    tmuxSocketName: claimsGeneration
                        ? nil
                        : removable.tmuxSocketName
                ),
            ],
            warning: nil
        ))
        let preflightInventory = conflictingInventory
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflightInventory },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in identity }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.worktreeUnavailable) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(kills.load() == 0)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a snapshot-moved worktree requires a refreshed confirmation")
    func snapshotMovedWorktreeRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _ in
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
        var moved = WorktreeSummary.fixture(
            hostID: removable.hostID,
            projectID: removable.projectID,
            scopedKey: "/tmp/project-a-moved",
            name: removable.name,
            path: "/tmp/project-a-moved",
            branch: removable.branch,
            generation: stableWorktreeGeneration
        )
        moved.tmuxSessionName = removable.tmuxSessionName
        model.snapshot.worktrees.removeAll { $0.id == removable.id }
        model.snapshot.worktrees.append(moved)

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.id == moved.id)
        #expect(updatedRequest.worktree.path == moved.path)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a snapshot-moved project requires a refreshed confirmation")
    func snapshotMovedProjectRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _ in
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
        let movedPath = "/tmp/project-a-moved"
        model.snapshot.projects[0].rootPath = movedPath

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.project.rootPath == movedPath)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a snapshot-removed worktree remains unavailable")
    func snapshotRemovedWorktreeRemainsUnavailable() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.snapshot.worktrees.removeAll { $0.id == removable.id }

        await #expect(throws: KwtWorktreeError.worktreeUnavailable) {
            try await model.resolveWorktreeRemoval(request)
        }
        await model.shutdown()
    }

    @MainActor
    @Test("a snapshot-recreated endpoint owner requires confirmation")
    func snapshotRecreatedEndpointOwnerRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _ in
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
        let index = try #require(
            model.snapshot.worktrees.firstIndex { $0.id == removable.id }
        )
        model.snapshot.worktrees[index].generation =
            "fedcba9876543210fedcba9876543210"

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Replacement should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.id == removable.id)
        #expect(
            updatedRequest.worktree.generation
                == "fedcba9876543210fedcba9876543210"
        )
        #expect(updatedRequest.worktree.tmuxSocketName == "protected")
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a recreated worktree requires a refreshed confirmation")
    func recreatedWorktreeRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let removals = LockedValue(0)
        let recreatedInventory = inventory(
            environment,
            including: removable,
            generation: "fedcba9876543210fedcba9876543210"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in recreatedInventory },
            kwtWorktreeRemover: { _, _, _, _ in
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
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(
            updatedRequest.worktree.generation
                == "fedcba9876543210fedcba9876543210"
        )
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("an omitted preflight socket preserves the protected identity")
    func omittedPreflightSocketUsesProtectedIdentity() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var preflight = fixture.beforeRemoval
        let recordIndex = try #require(
            preflight.projects[0].worktrees.firstIndex {
                $0.path == removable.path
            }
        )
        preflight.projects[0].worktrees[recordIndex].tmuxSocketName = nil
        let omissionPreflight = preflight
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in omissionPreflight },
            kwtWorktreeRemover: { _, _, _, _ in
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
        let result = try await model.resolveWorktreeRemoval(request)

        #expect(result == .removed)
        #expect(removals.load() == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("an unchanged recovery request remains an error")
    func unchangedRecoveryRequestRemainsAnError() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let expected = KwtWorktreeError.removalTargetChanged
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in throw expected },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        await model.shutdown()
    }

    @MainActor
    @Test("an unrelated removal failure is not recoverable")
    func unrelatedFailureRemainsAnError() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let expected = KwtWorktreeError.removalFailed(
            host: "this Mac",
            status: 42
        )
        let beforeRemoval = fixture.beforeRemoval
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in throw expected },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        await model.shutdown()
    }

    @MainActor
    @Test("a missing project invalidates cached removal state")
    func missingProjectInvalidatesCachedState() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.worktreeUnavailable) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(model.snapshot.worktree(id: removable.id) == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a warning-bearing preflight cannot trigger reconfirmation")
    func warningPreflightRemainsAnError() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let hostSummary = try #require(snapshot.host(id: environment.host.id))
        let warning = "Project inventory is temporarily unavailable."
        var warningInventory = inventory(environment)
        warningInventory.projects[0].warning = warning
        let preflight = warningInventory
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let expected = KwtWorktreeError.removalPreflightUnavailable(
            host: hostSummary.name,
            message: warning
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("an unrelated project warning prevents absent-target removal")
    func unrelatedProjectWarningPreventsAbsentTargetRemoval() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let hostSummary = try #require(snapshot.host(id: environment.host.id))
        let warning = "Another project inventory is temporarily unavailable."
        var warningInventory = inventory(environment)
        warningInventory.projects.append(KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "example.com/acme/unavailable",
                name: "unavailable",
                path: "/tmp/project-b",
                lastTouched: nil
            ),
            worktrees: [],
            warning: warning
        ))
        let preflight = warningInventory
        let kills = LockedValue(0)
        let removals = LockedValue(0)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in identity }
        )
        let expected = KwtWorktreeError.removalPreflightUnavailable(
            host: hostSummary.name,
            message: warning
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(kills.load() == 0)
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a failed project-list preflight cannot trigger reconfirmation")
    func projectListWarningPreflightRemainsAnError() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let hostSummary = try #require(snapshot.host(id: environment.host.id))
        let warning = "Project listing is temporarily unavailable."
        let preflight = KwtHostInventory(
            projects: [],
            projectsWarning: warning
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let expected = KwtWorktreeError.removalPreflightUnavailable(
            host: hostSummary.name,
            message: warning
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a changed project path refreshes removal confirmation")
    func changedProjectPathRefreshesConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let movedPath = "/tmp/project-a-moved"
        var movedInventory = fixture.beforeRemoval
        movedInventory.projects[0].project.path = movedPath
        let preflight = movedInventory
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.project.rootPath == movedPath)
        #expect(model.snapshot.project(id: environment.project.id)?.rootPath == movedPath)
        await model.shutdown()
    }

    @MainActor
    @Test("project path reuse refreshes confirmation for the moved repository")
    func projectPathReuseRefreshesMovedRepositoryConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot

        let movedPath = "/tmp/project-a-moved"
        var movedProject = fixture.beforeRemoval.projects[0]
        movedProject.project.path = movedPath
        let replacementRepository = "example.com/acme/replacement"
        let replacementProject = KwtProjectInventory(
            project: KwtProjectRecord(
                repository: replacementRepository,
                name: "replacement",
                path: environment.project.rootPath,
                lastTouched: nil
            ),
            worktrees: [
                KwtWorktreeRecord(
                    path: environment.project.rootPath,
                    branch: "main",
                    commitHash: "",
                    isMain: true,
                    createdAt: nil,
                    generation: nil,
                    repository: replacementRepository,
                    sessionName: "kwt-replacement-main",
                    tmuxSocketName: nil
                ),
            ],
            warning: nil
        )
        let preflight = KwtHostInventory(projects: [
            replacementProject,
            movedProject,
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.project.id == environment.project.id)
        #expect(updatedRequest.project.scopedKey == environment.project.scopedKey)
        #expect(updatedRequest.project.rootPath == movedPath)
        #expect(updatedRequest.worktree.generation == stableWorktreeGeneration)
        let hostProjects = model.snapshot.projects.filter {
            $0.hostID == environment.host.id
        }
        #expect(Set(hostProjects.map(\.id)).count == hostProjects.count)
        #expect(
            hostProjects.first { $0.scopedKey == replacementRepository }?.id
                != environment.project.id
        )
        await model.shutdown()
    }

    @MainActor
    @Test("removal completion keeps the owning project selected")
    func removalKeepsOwningProjectSelected() throws {
        let environment = try setupStandardEnvironment()
        let removed = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            name: "feature/remove",
            path: "/tmp/project-a-feature"
        )
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removed)
        var current = WorkspaceSelection(
            selectedHostID: environment.host.id
        )
        current.select(
            WorkspaceNavigationTarget.worktree(removed.id),
            in: snapshot
        )
        snapshot.worktrees.removeAll { $0.id == removed.id }

        let resolved = WorkspaceSceneModel.selectionAfterWorktreeRemoval(
            current,
            in: snapshot,
            visibility: WorktreeVisibility.default
        )

        #expect(resolved.selectedProjectID == environment.project.id)
        #expect(resolved.selectedWorktreeID == nil)
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
