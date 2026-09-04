import GhosthubTransport
import Combine
import Foundation
import Synchronization
import GhosthubSettings
import GhosthubTerminal
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubApp

extension WorkspaceTmuxDiscoveryTests {
    @MainActor
    @Test("unresolved protected worktree stays pending")
    func unresolvedProtectedWorktreeStaysPending() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/opt/homebrew/bin/tmux")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .protected
        )

        model.openBorrowedTmuxSession(selection)

        #expect(model.retainedBorrowedTmuxHandle(for: selection) == nil)
        #expect(model.activeBorrowedTmuxSelection == nil)
    }

    @MainActor
    @Test("created sessions publish into host inventory immediately")
    func createdSessionPublishesImmediately() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") }
        )

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        ))

        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        model.retryBorrowedTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        ))
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
    }

    @MainActor
    @Test("ordinary worktree navigation attaches without creating")
    func worktreeNavigationUsesAttachMode() throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .direct
        )

        model.openBorrowedTmuxSession(selection)

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == "0123456789abcdef0123456789abcdef"
        )
    }

    @MainActor
    @Test("switching sessions retains and reuses each presentation")
    func switchingSessionsReusesRetainedPresentations() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "first"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "second"
        )

        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            model.retainedBorrowedTmuxSessionIsConnected(first)
        }
        let firstHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: first)
        )
        #expect(model.connectedBorrowedTmuxSessionIDs == [first.id])

        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
                && model.retainedBorrowedTmuxSessionIsConnected(second)
        }
        let secondHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: second)
        )
        #expect(model.connectedBorrowedTmuxSessionIDs == [first.id, second.id])

        model.openBorrowedTmuxSession(first)
        model.prepareActiveBorrowedTmuxSurface()

        #expect(model.activeBorrowedTmuxSelection == first)
        #expect(model.retainedBorrowedTmuxHandle(for: first) == firstHandle)
        #expect(firstHandle.surfaceID != secondHandle.surfaceID)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(model.connectedBorrowedTmuxSessionIDs == [first.id, second.id])
        #expect(surfaceStore.requestCount == 2)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("hiding an ordinary tmux presentation disables client sizing")
    func hiddenTmuxPresentationDisablesClientSizing() async throws {
        let environment = try setupHostEnvironment()
        var snapshot = environment.snapshot
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let previewGrid = TmuxGridSize(columns: 120, rows: 37)
        snapshot.hosts[0].tmuxSessions = [.init(
            name: "ordinary",
            managed: false,
            windows: [],
            serverPID: identity.serverPID,
            sessionID: identity.sessionID,
            createdAt: identity.createdAt,
            previewClientSize: previewGrid
        )]
        let hideMutations = LockedValue(0)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hideMutations.withLock { $0 += 1 }
                }
                return (0, "")
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "ordinary"
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let handle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        model.hideBorrowedTmuxSession(selection)
        await waitUntilMainActor { hideMutations.load() == 1 }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) == handle)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("latest reopen wins while the hidden sizing transition is pending")
    func reopeningWaitsForHiddenSizingTransition() async throws {
        let environment = try setupHostEnvironment()
        var snapshot = environment.snapshot
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        snapshot.hosts[0].tmuxSessions = [.init(
            name: "ordinary",
            managed: false,
            windows: [],
            serverPID: identity.serverPID,
            sessionID: identity.sessionID,
            createdAt: identity.createdAt,
            previewClientSize: TmuxGridSize(columns: 120, rows: 37)
        )]
        let events = LockedValue<[String]>([])
        let hideStarted = LockedValue(false)
        let releaseHide = DispatchSemaphore(value: 0)
        defer { releaseHide.signal() }
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'!ignore-size'") {
                    events.withLock { $0.append("interactive") }
                } else if command.contains("'ignore-size'") {
                    events.withLock { $0.append("hidden-start") }
                    hideStarted.store(true)
                    _ = releaseHide.wait(timeout: .now() + 5)
                    events.withLock { $0.append("hidden-end") }
                }
                return (0, "")
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "ordinary"
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let handle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        model.hideBorrowedTmuxSession(selection)
        await waitUntilMainActor { hideStarted.load() }

        model.openBorrowedTmuxSession(selection)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(events.load() == ["hidden-start"])

        model.openBorrowedTmuxSession(selection)

        releaseHide.signal()
        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(events.load() == [
            "hidden-start", "hidden-end", "interactive",
        ])
        #expect(model.retainedBorrowedTmuxHandle(for: selection) == handle)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("hiding unsupported tmux detaches without a sizing command")
    func hidingUnsupportedTmuxSkipsSizingMutation() async throws {
        let environment = try setupHostEnvironment()
        let commands = LockedValue<[String]>([])
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution(
                    "/usr/bin/tmux",
                    version: "tmux 3.3"
                )
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                commands.withLock { $0.append(command) }
                return (1, "unsupported sizing command")
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "ordinary"
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.hideBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: selection) == nil
        }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(commands.load().allSatisfy { !$0.contains("ignore-size") })
        #expect(!surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("a socketless protected session never reaches default-server sizing")
    func socketlessProtectedSessionDoesNotReachSizing() async throws {
        let environment = try setupStandardEnvironment()
        let hiddenSizingMutations = LockedValue(0)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hiddenSizingMutations.withLock { $0 += 1 }
                }
                return (0, "")
            },
            localKwtPathProvider: { "/test/kwt" },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .protected
        )

        model.openBorrowedTmuxSession(selection)
        try await Task.sleep(for: .milliseconds(100))

        #expect(hiddenSizingMutations.load() == 0)
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) == nil)
        #expect(surfaceStore.requestCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("reopening during provisioning resumes activation when ready")
    func reopeningDuringProvisioningResumesActivation() async throws {
        let environment = try setupHostEnvironment()
        let resolutionStarted = LockedValue(false)
        let releaseResolution = DispatchSemaphore(value: 0)
        defer { releaseResolution.signal() }
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                resolutionStarted.store(true)
                _ = releaseResolution.wait(timeout: .now() + 5)
                return successfulTmuxResolution("/usr/bin/tmux")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "ordinary"
        )

        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { resolutionStarted.load() }

        model.hideBorrowedTmuxSession(selection)
        model.openBorrowedTmuxSession(selection)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)

        releaseResolution.signal()
        await waitUntilMainActor(timeout: .seconds(2)) {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test("hiding workspace provisioning preserves kwt establishment")
    func hidingWorkspaceProvisioningPreservesKwtEstablishment() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let resolutionStarted = LockedValue(false)
        let releaseResolution = DispatchSemaphore(value: 0)
        defer { releaseResolution.signal() }
        let hiddenSizingMutations = LockedValue(0)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                resolutionStarted.store(true)
                _ = releaseResolution.wait(timeout: .now() + 5)
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hiddenSizingMutations.withLock { $0 += 1 }
                }
                return (0, "")
            },
            localKwtPathProvider: { "/test/kwt" },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef",
            tmuxAttachMode: .direct
        )

        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { resolutionStarted.load() }
        model.hideBorrowedTmuxSession(selection)
        // Let the hide request record itself before kwt can launch.
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        releaseResolution.signal()
        await waitUntilMainActor(timeout: .seconds(2)) {
            surfaceStore.requestCount == 1
        }
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("/test/kwt"))
        #expect(command.contains("'open'"))
        #expect(!command.contains("ignore-size"))
        await waitUntilMainActor(timeout: .seconds(1)) {
            hiddenSizingMutations.load() == 1
        }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("hiding kwt provisioning survives discovery advancing the phase")
    func hidingKwtProvisioningSurvivesDiscoveryAdvancingPhase() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let resolutionStarted = LockedValue(false)
        let releaseResolution = DispatchSemaphore(value: 0)
        defer { releaseResolution.signal() }
        let hiddenSizingMutations = LockedValue(0)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                resolutionStarted.store(true)
                _ = releaseResolution.wait(timeout: .now() + 5)
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hiddenSizingMutations.withLock { $0 += 1 }
                }
                return (0, "")
            },
            localKwtPathProvider: { "/test/kwt" },
            tmuxSessionDiscovery: { _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "kwt-ghosthub-main",
                        windowCount: 1,
                        createdAt: nil,
                        managed: true
                    ),
                ])
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef",
            tmuxAttachMode: .direct
        )

        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { resolutionStarted.load() }
        // Discovery sees the session while kwt is still provisioning, which
        // completes workspace establishment before the client launches.
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.contains { $0.name == selection.name } == true
        }
        model.hideBorrowedTmuxSession(selection)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        releaseResolution.signal()
        await waitUntilMainActor(timeout: .seconds(2)) {
            surfaceStore.requestCount == 1
        }
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("/test/kwt"))
        #expect(command.contains("'open'"))
        #expect(!command.contains("ignore-size"))
        await waitUntilMainActor(timeout: .seconds(1)) {
            hiddenSizingMutations.load() == 1
        }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("hidden workspace provisioning detaches without a client identity")
    func hiddenWorkspaceProvisioningDetachesWithoutIdentity() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let resolutionStarted = LockedValue(false)
        let releaseResolution = DispatchSemaphore(value: 0)
        defer { releaseResolution.signal() }
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                resolutionStarted.store(true)
                _ = releaseResolution.wait(timeout: .now() + 5)
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, _ in
                (1, "client identity unavailable")
            },
            localKwtPathProvider: { "/test/kwt" },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef",
            tmuxAttachMode: .direct
        )

        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { resolutionStarted.load() }
        model.hideBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.retainedBorrowedTmuxSessionHasPendingHiddenSizing(selection)
        }
        releaseResolution.signal()

        await waitUntilMainActor(timeout: .seconds(5)) {
            model.retainedBorrowedTmuxHandle(for: selection) == nil
        }
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(!surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("a failed hidden sizing transition detaches the client")
    func failedHiddenSizingTransitionDetachesClient() async throws {
        let environment = try setupHostEnvironment()
        var snapshot = environment.snapshot
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        snapshot.hosts[0].tmuxSessions = [.init(
            name: "ordinary",
            managed: false,
            windows: [],
            serverPID: identity.serverPID,
            sessionID: identity.sessionID,
            createdAt: identity.createdAt,
            previewClientSize: TmuxGridSize(columns: 120, rows: 37)
        )]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    return (1, "tmux rejected the sizing change")
                }
                return (0, "")
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "ordinary"
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.hideBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: selection) == nil
        }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(!surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("retained tmux activation unparks before publishing the active handle")
    func retainedTmuxActivationUnparksBeforePublishingHandle() async throws {
        let environment = try setupHostEnvironment()
        var snapshot = environment.snapshot
        let budget = LivePreviewBudget(limit: 4)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        weak var weakModel: WorkspaceSceneModel?
        var events: [String] = []
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        snapshot.hosts[0].tmuxSessions = [.init(
            name: "first",
            managed: false,
            windows: [],
            serverPID: identity.serverPID,
            sessionID: identity.sessionID,
            createdAt: identity.createdAt
        )]
        let previewCoordinator = TmuxSessionPreviewCoordinator(
            mode: .live,
            budget: budget,
            capture: { _, _ in nil },
            park: { _ in
                events.append(
                    "park:\(weakModel?.activeBorrowedTmuxSelection?.name ?? "none")"
                )
            },
            unpark: { _ in
                events.append(
                    "unpark:\(weakModel?.activeBorrowedTmuxSelection?.name ?? "none")"
                        + ":\(weakModel?.activeBorrowedTmuxSessionIsConnected ?? false)"
                )
            },
            isKeyWindow: { true }
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport.previewPaneSplitter(
                identity: identity
            ),
            sessionPreviewCoordinator: previewCoordinator
        )
        weakModel = model
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "first"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "second"
        )
        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let key = TmuxPreviewKey(
            hostID: first.hostID,
            name: first.name,
            socketName: first.socketName
        )
        previewCoordinator.setExpanded(true, for: key)
        await waitUntilMainActor {
            model.retainedBorrowedTmuxSessionIsConnected(first)
                && !previewCoordinator.requiresIdentity(key)
        }
        model.openBorrowedTmuxSession(second)

        await waitUntilMainActor {
            events == ["park:second"]
        }
        #expect(events == ["park:second"])
        #expect(budget.granted.contains(LivePreviewRequestID(
            sceneID: previewCoordinator.sceneID,
            presentation: key
        )))

        model.openBorrowedTmuxSession(first)

        await waitUntilMainActor {
            events == ["park:second", "unpark:first:false"]
                && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(events == ["park:second", "unpark:first:false"])
        #expect(model.activeBorrowedTmuxSelection == first)
        #expect(!budget.granted.contains(LivePreviewRequestID(
            sceneID: previewCoordinator.sceneID,
            presentation: key
        )))
        await model.shutdown()
    }

    @MainActor
    @Test("duplicate directory endpoint rebinds retained ownership")
    func duplicateDirectoryEndpointRebindsRetainedOwnership() async throws {
        let environment = try setupHostEnvironment()
        let sessionName = "kwt-workspace-dir-hub"
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: environment.host.id,
            name: "hub",
            path: "/srv/hub",
            tmuxSessionName: sessionName,
            sessionLive: true
        )
        var snapshot = environment.snapshot
        snapshot.directoryWorkspaces = [directory]
        snapshot.hosts[0].tmuxSessions = [.init(
            name: sessionName,
            managed: false,
            windows: []
        )]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            }
        )
        let canonical = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )
        let duplicate = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            tmuxAttachMode: .direct
        )

        model.openBorrowedTmuxSession(canonical)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let handle = try #require(
            model.retainedBorrowedTmuxHandle(for: canonical)
        )

        model.openBorrowedTmuxSession(duplicate)
        model.prepareActiveBorrowedTmuxSurface()

        #expect(model.activeBorrowedTmuxSelection == duplicate)
        #expect(model.retainedBorrowedTmuxHandle(for: duplicate) == handle)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.requestCount == 1)
        #expect(surfaceStore.removedKeys.isEmpty)

        model.openBorrowedTmuxSession(canonical)
        #expect(model.activeBorrowedTmuxSelection == canonical)
        #expect(model.retainedBorrowedTmuxHandle(for: canonical) == handle)
        await model.shutdown()
    }

    @MainActor
    @Test("a direct worktree reuses and closes its unbound presentation")
    func directWorktreeReusesAndClosesUnboundPresentation() async throws {
        let environment = try setupStandardEnvironment()
        let sessionName = "kwt-ghosthub-main"
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.worktrees[0].tmuxAttachMode = .direct
        snapshot.hosts[0].tmuxSessions = [.init(
            name: sessionName,
            managed: false,
            windows: []
        )]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            }
        )
        let unbound = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName
        )
        let worktree = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )

        model.openBorrowedTmuxSession(unbound)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            model.retainedBorrowedTmuxSessionIsConnected(unbound)
        }
        let handle = try #require(
            model.retainedBorrowedTmuxHandle(for: unbound)
        )
        model.openBorrowedTmuxSession(worktree)

        #expect(model.retainedBorrowedTmuxHandle(for: worktree) == handle)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.requestCount == 1)
        #expect(model.activeBorrowedTmuxSelection == worktree)
        #expect(model.previewableTmuxSessionIDs == [worktree.id])
        #expect(model.connectedBorrowedTmuxSessionIDs == [worktree.id])

        model.closeBorrowedTmuxSession(worktree)

        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(surfaceStore.removedKeys.count == 1)

        model.openBorrowedTmuxSession(worktree)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let reopenedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: worktree)
        )

        #expect(reopenedHandle != handle)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.requestCount == 2)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("directory ownership rebind restarts an active reconnect")
    func directoryOwnershipRebindRestartsActiveReconnect() async throws {
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.probeTimedOut(shell: "build-box")),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work",
                    windowCount: 1,
                    createdAt: nil,
                    managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: environment.remoteHost.id,
            name: "hub",
            path: "/srv/hub",
            tmuxSessionName: "release-work",
            sessionLive: true
        )
        var snapshot = environment.snapshot
        snapshot.directoryWorkspaces = [directory]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.seconds(60)]
        )
        let canonical = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )
        let duplicate = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work",
            tmuxAttachMode: .direct
        )

        model.openBorrowedTmuxSession(canonical)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            discoveries.count == 1
                && model.activeBorrowedTmuxRecoveryState?.isReconnecting
                == true
        }

        model.openBorrowedTmuxSession(duplicate)
        model.reconnectActiveTmuxSessionNow()

        await waitUntilMainActor {
            discoveries.count == 2
                && surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(model.activeBorrowedTmuxSelection == duplicate)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("switching between remote hosts retains both presentations")
    func switchingRemoteHostsRetainsPresentations() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        let secondHost = HostSummary(
            id: UUID(),
            configKey: "second-builder",
            name: "Second Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "user-a@second-builder",
            preferredTransport: .ssh,
            lastKnownReachable: true
        )
        snapshot.hosts.append(secondHost)
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: secondHost.id,
            name: "deploy-work"
        )
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport.previewPaneSplitter(
                identity: identity
            ),
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") }
        )

        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let firstHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: first)
        )
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        model.openBorrowedTmuxSession(first)

        #expect(model.retainedBorrowedTmuxHandle(for: first) == firstHandle)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(surfaceStore.requestCount == 2)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("explicit close detaches only its retained presentation")
    func explicitCloseDetachesOnlyTargetPresentation() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "first"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "second"
        )
        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        model.closeBorrowedTmuxSession(first)

        #expect(model.retainedBorrowedTmuxHandle(for: first) == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: second) != nil)
        #expect(model.activeBorrowedTmuxSelection == second)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("closed worktree waits for explicit selection before reopening")
    func closedWorktreeWaitsForExplicitSelection() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        var userSelection = model.selection
        userSelection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        model.selectFromUser(userSelection)
        let tmuxSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(tmuxSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        model.closeBorrowedTmuxSession(tmuxSelection)

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(model.suppressesSelectedWorktreeSessionOpen)

        model.synchronizeSelection(userSelection)
        #expect(model.suppressesSelectedWorktreeSessionOpen)
        #expect(surfaceStore.requestCount == 1)

        model.selectFromUser(userSelection)
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        model.openBorrowedTmuxSession(tmuxSelection)
        await waitUntilMainActor { surfaceStore.requestCount == 2 }
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("closed directory waits for explicit selection before reopening")
    func closedDirectoryWaitsForExplicitSelection() async throws {
        let environment = try setupStandardEnvironment()
        let directoryID = UUID()
        var snapshot = environment.snapshot
        snapshot.directoryWorkspaces = [.init(
            id: directoryID,
            hostID: environment.host.id,
            name: "hub",
            path: "/srv/hub",
            tmuxSessionName: "kwt-workspace-dir-hub",
            sessionLive: true
        )]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            }
        )
        var userSelection = model.selection
        userSelection.select(
            .directoryWorkspace(directoryID),
            in: model.snapshot
        )
        model.selectFromUser(userSelection)
        let tmuxSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(tmuxSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        model.closeBorrowedTmuxSession(tmuxSelection)

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(model.suppressesSelectedWorktreeSessionOpen)

        model.synchronizeSelection(userSelection)
        #expect(model.suppressesSelectedWorktreeSessionOpen)
        #expect(surfaceStore.requestCount == 1)

        model.selectFromUser(userSelection)
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        model.openBorrowedTmuxSession(tmuxSelection)
        await waitUntilMainActor { surfaceStore.requestCount == 2 }
        await model.shutdown()
    }

    @MainActor
    @Test("directory workspace open guards the selected KWT session")
    func directoryWorkspaceOpenGuardsSelectedSession() async throws {
        let environment = try setupStandardEnvironment()
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: environment.host.id,
            name: "hub",
            path: "/srv/hub",
            tmuxSessionName: "kwt-workspace-dir-hub",
            sessionLive: false
        )
        var snapshot = environment.snapshot
        snapshot.directoryWorkspaces = [directory]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            localKwtPathProvider: { "/test/kwt" }
        )
        let selection = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'--expected-session'"))
        #expect(command.contains("'kwt-workspace-dir-hub'"))
        await model.shutdown()
    }

    @MainActor
    @Test("directory session drift does not launch KWT open")
    func directorySessionDriftDoesNotOpen() async throws {
        let environment = try setupStandardEnvironment()
        let directoryID = UUID()
        var snapshot = environment.snapshot
        snapshot.directoryWorkspaces = [.init(
            id: directoryID,
            hostID: environment.host.id,
            name: "hub",
            path: "/srv/hub",
            tmuxSessionName: "kwt-workspace-dir-renamed-hub",
            sessionLive: false
        )]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            }
        )
        let staleSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-workspace-dir-hub",
            directoryWorkspaceID: directoryID,
            workspacePath: "/srv/hub",
            tmuxAttachMode: .direct
        )

        model.openBorrowedTmuxSession(staleSelection)
        await Task.yield()

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(surfaceStore.requestCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("explicit close dismisses an unresolved-host presentation")
    func explicitCloseDismissesUnresolvedHostPresentation() throws {
        let environment = try setupStandardEnvironment()
        let unresolvedHost = HostSummary(
            id: UUID(),
            configKey: "unresolved-builder",
            name: "Unresolved Builder",
            kind: .remote,
            platform: .linux,
            preferredTransport: .ssh
        )
        var snapshot = environment.snapshot
        snapshot.hosts.append(unresolvedHost)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: unresolvedHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)

        model.closeBorrowedTmuxSession(selection)

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.activeBorrowedTmuxLaunchMode == nil)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
    }

    @MainActor
    @Test("selecting an unresolved host captures the outgoing tmux preview")
    func unresolvedHostSelectionCapturesOutgoingPreview() async throws {
        let environment = try setupHostEnvironment()
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let active = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "opened"
        )
        let unresolvedHost = HostSummary(
            id: UUID(),
            configKey: "unresolved-builder",
            name: "Unresolved Builder",
            kind: .remote,
            platform: .linux,
            preferredTransport: .ssh
        )
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [.init(
            name: active.name,
            managed: false,
            windows: [],
            serverPID: identity.serverPID,
            sessionID: identity.sessionID,
            createdAt: identity.createdAt
        )]
        snapshot.hosts.append(unresolvedHost)
        let captures = Counter()
        let previewCoordinator = TmuxSessionPreviewCoordinator(
            mode: .efficient,
            budget: LivePreviewBudget(limit: 4),
            capture: { _, _ in
                _ = captures.increment()
                return try makePreviewSnapshot()
            }
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport.previewPaneSplitter(
                identity: identity
            ),
            sessionPreviewCoordinator: previewCoordinator
        )
        model.openBorrowedTmuxSession(active)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let activeKey = TmuxPreviewKey(
            hostID: active.hostID,
            name: active.name,
            socketName: active.socketName
        )
        await waitUntilMainActor {
            model.retainedBorrowedTmuxSessionIsConnected(active)
                && !previewCoordinator.requiresIdentity(activeKey)
        }
        let unresolved = WorkspaceTmuxSessionSelection(
            hostID: unresolvedHost.id,
            name: "release-work"
        )

        model.openBorrowedTmuxSession(unresolved)
        await previewCoordinator.waitForPendingWork()

        #expect(captures.count == 1)
        #expect(model.activeBorrowedTmuxSelection == unresolved)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("workspace shutdown detaches every retained presentation")
    func shutdownDetachesEveryRetainedPresentation() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        for name in ["first", "second"] {
            model.openBorrowedTmuxSession(.init(
                hostID: environment.host.id,
                name: name
            ))
            await waitUntilMainActor {
                model.prepareActiveBorrowedTmuxSurface()
                return surfaceStore.requestCount ==
                    model.retainedBorrowedTmuxPresentationCount
            }
        }

        await model.shutdown()

        #expect(surfaceStore.removedKeys.count == 2)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
    }

    @MainActor
    @Test("reopening an ended worktree restores establishment mode")
    func endedWorktreeRetryRestoresEstablishmentMode() {
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "kwt-ghosthub-main",
            worktreeID: UUID(),
            worktreePath: "/srv/ghosthub",
            tmuxAttachMode: .direct
        )

        #expect(
            WorkspaceSceneModel.retryLaunchMode(
                for: selection,
                current: .attachOnly,
                sessionConfirmedEnded: true
            ) == .attach
        )
    }

    @MainActor
    @Test("explicit reselection attaches a replaced worktree's session")
    func explicitReselectionAttachesReplacedSession() throws {
        let environment = try setupStandardEnvironment()
        let originalGeneration = "0123456789abcdef0123456789abcdef"
        let replacementGeneration = "fedcba9876543210fedcba9876543210"
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "editor"
        snapshot.worktrees[0].generation = originalGeneration
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") }
        )
        let observed = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "editor",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: originalGeneration,
            tmuxAttachMode: .direct
        )
        model.openBorrowedTmuxSession(observed)
        #expect(
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == originalGeneration
        )

        var replacementSnapshot = model.snapshot
        replacementSnapshot.worktrees[0].generation = replacementGeneration
        model.snapshot = replacementSnapshot
        var reselection = model.selection
        reselection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        model.selectFromUser(reselection)

        #expect(
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == replacementGeneration
        )
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
    }

    @MainActor
    @Test(
        "returning to an inactive replaced worktree invalidates its retained client",
        arguments: [
            (
                "kwt-ghosthub-replacement",
                String?.none,
                "0123456789abcdef0123456789abcdef"
            ),
            (
                "kwt-ghosthub-main",
                Optional("replacement-socket"),
                "0123456789abcdef0123456789abcdef"
            ),
        ]
    )
    func returningToReplacedWorktreeInvalidatesRetainedClient(
        replacementName: String,
        replacementSocket: String?,
        replacementGeneration: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        let originalGeneration = "0123456789abcdef0123456789abcdef"
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].generation = originalGeneration
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let worktree = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: originalGeneration,
            tmuxAttachMode: .direct
        )
        let other = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "other"
        )
        model.openBorrowedTmuxSession(worktree)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let originalHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: worktree)
        )
        model.openBorrowedTmuxSession(other)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        var replacement = worktree
        replacement.name = replacementName
        replacement.socketName = replacementSocket
        replacement.worktreeGeneration = replacementGeneration
        var replacementSnapshot = model.snapshot
        replacementSnapshot.worktrees[0].tmuxSessionName = replacementName
        replacementSnapshot.worktrees[0].tmuxSocketName = replacementSocket
        replacementSnapshot.worktrees[0].generation = replacementGeneration
        model.snapshot = replacementSnapshot
        model.openBorrowedTmuxSession(replacement)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 3
        }

        #expect(
            model.retainedBorrowedTmuxHandle(for: replacement) != originalHandle
        )
        if replacement.name != worktree.name
            || replacement.socketName != worktree.socketName {
            #expect(model.retainedBorrowedTmuxHandle(for: worktree) == nil)
        }
        #expect(model.activeBorrowedTmuxSelection == replacement)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("returning after a generation refresh replaces the retained client")
    func returningAfterGenerationRefreshReplacesRetainedClient() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            }
        )
        let worktree = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef"
        )
        let other = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "other"
        )
        model.openBorrowedTmuxSession(worktree)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let originalHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: worktree)
        )
        model.openBorrowedTmuxSession(other)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        var refreshed = worktree
        refreshed.worktreeGeneration =
            "fedcba9876543210fedcba9876543210"
        model.openBorrowedTmuxSession(refreshed)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 3
        }

        #expect(
            model.retainedBorrowedTmuxHandle(for: refreshed) != originalHandle
        )
        #expect(model.activeBorrowedTmuxSelection == refreshed)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("discovered worktree session attaches without managed kwt")
    func discoveredWorktreeSessionAttachesDirectly() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        let remote = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(environment.host.sshDestination)
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            kwtRemoteProvisioner: { _ in
                throw KwtRemoteInstallError.bundleIncomplete
            },
            tmuxSessionDiscovery: { host in
                .success(host.isRemote ? [
                    DiscoveredTmuxSession(
                        name: sessionName,
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: true
                    ),
                ] : [])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )

        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
        }
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'attach-session'"))
        #expect(!command.contains("'open'"))
        #expect(!command.contains("managed kwt is unavailable"))
        #expect(model.snapshot.host(id: environment.host.id)?.primaryDiagnostic == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("repairing managed kwt restores workspace-aware attach")
    func repairedHelperRestoresWorkspaceOpen() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        let remote = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(environment.host.sshDestination)
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let provisioningShouldFail = LockedValue(true)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            kwtRemoteProvisioner: { _ in
                if provisioningShouldFail.load() {
                    throw KwtRemoteInstallError.bundleIncomplete
                }
            },
            kwtBranchLister: { _, _ in [] },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )

        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
        }
        provisioningShouldFail.store(false)
        _ = try await model.branches(for: environment.project.id)
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'open'"))
        #expect(command.contains(environment.worktree.path))
        await model.shutdown()
    }

    @MainActor
    @Test("cancelling kwt provisioning preserves workspace-aware attach")
    func cancelledProvisioningPreservesWorkspaceOpen() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtRemoteProvisioner: { _ in throw CancellationError() }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )

        await #expect(throws: CancellationError.self) {
            try await model.branches(for: environment.project.id)
        }
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'open'"))
        #expect(command.contains(environment.worktree.path))
        await model.shutdown()
    }

    @MainActor
    @Test("a generationless worktree attaches fenced to its discovered session")
    func generationlessWorktreeAttachesFencedToDiscoveredSession() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.worktrees[0].tmuxSocketName = nil
        snapshot.worktrees[0].tmuxAttachMode = .direct
        snapshot.worktrees[0].generation = nil
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: [],
                serverPID: "123",
                sessionID: "$7",
                createdAt: "1721552400"
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )
        #expect(selection.worktreeGeneration == nil)

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(!command.contains("'open'"))
        #expect(command.contains("'attach-session'"))
        #expect(command.contains("if-shell"))
        #expect(command.contains("#{pid},123"))
        #expect(command.contains("$7"))
        #expect(command.contains("#{session_created},1721552400"))
        #expect(command.contains("Ghosthub: tmux session identity changed"))
        await model.shutdown()
    }

    @MainActor
    @Test("a missing helper uses the captured named tmux endpoint")
    func missingHelperUsesCapturedNamedEndpoint() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.worktrees[0].tmuxSocketName = "kwt-main"
        snapshot.worktrees[0].tmuxAttachMode = .direct
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        let identity = TmuxSessionIdentity(
            serverPID: "123",
            sessionID: "$7",
            createdAt: "1721552400"
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let failure = KwtWorktreeError.commandFailed(
            host: environment.host.name,
            status: 127
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtBranchLister: { _, _ in throw failure },
            tmuxSessionIdentityReviewer: { reviewed, _, _ in
                #expect(reviewed == selection)
                return ReviewedTmuxSessionIdentity(
                    identity: identity,
                    routeIdentity: nil
                )
            }
        )

        await #expect(throws: failure) {
            try await model.branches(for: environment.project.id)
        }
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'attach-session'"))
        #expect(command.contains("-L"))
        #expect(command.contains("kwt-main"))
        #expect(!command.contains("'open'"))
        #expect(command.contains("if-shell"))
        #expect(command.contains("#{pid},123"))
        #expect(command.contains("#{session_id}"))
        #expect(command.contains("$7"))
        #expect(command.contains("#{session_created},1721552400"))
        #expect(command.contains("Ghosthub: tmux session identity changed"))
        await model.shutdown()
    }

    @MainActor
    @Test("a missing helper fails closed without named endpoint identity")
    func missingHelperRequiresCapturedNamedEndpointIdentity() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSocketName = "kwt-main"
        snapshot.worktrees[0].tmuxAttachMode = .direct
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let reviews = Mutex(0)
        let failure = KwtWorktreeError.commandFailed(
            host: environment.host.name,
            status: 127
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            kwtBranchLister: { _, _ in throw failure },
            tmuxSessionIdentityReviewer: { _, _, _ in
                reviews.withLock { $0 += 1 }
                throw TmuxSessionKillError.identityUnavailable(
                    host: environment.host.name,
                    session: "kwt-ghosthub-main"
                )
            }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )

        await #expect(throws: failure) {
            try await model.branches(for: environment.project.id)
        }
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { reviews.withLock { $0 } == 1 }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(surfaceStore.requestCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a missing helper during change status restores direct attach")
    func changeStatus127FallsBackToDirectAttach() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let failure = KwtWorktreeError.changeInspectionFailed(
            host: environment.host.name,
            status: 127,
            code: nil,
            message: nil,
            retryable: false,
            details: [:]
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtWorktreeChangeReader: { _, _, _, _ in throw failure }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .direct
        )

        await #expect(throws: failure) {
            try await model.prepareWorktreeRemoval(environment.worktree.id)
        }
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'attach-session'"))
        #expect(!command.contains("'open'"))
        await model.shutdown()
    }

    @MainActor
    @Test("cached worktree session uses kwt when the helper is available")
    func cachedWorktreeSessionUsesKwt() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") }
        )
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'open'"))
        #expect(command.contains(environment.worktree.path))
        #expect(command.contains("'--expected-repository'"))
        #expect(command.contains(environment.project.scopedKey))
        #expect(command.contains("'--expected-registration'"))
        #expect(command.contains("remote-registration"))
        #expect(command.contains("'--expected-generation'"))
        #expect(command.contains("0123456789abcdef0123456789abcdef"))
        #expect(command.contains("'--expected-session'"))
        #expect(command.contains(sessionName))
        await model.shutdown()
    }

    @MainActor
    @Test("replaced worktree at the same path does not launch kwt open")
    func replacedWorktreeAtSamePathDoesNotOpen() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].generation =
            "fedcba9876543210fedcba9876543210"
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            }
        )
        let stale = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            workspacePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef",
            tmuxAttachMode: .direct
        )

        model.openBorrowedTmuxSession(stale)
        await Task.yield()

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(surfaceStore.requestCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "stale direct worktree endpoint does not launch kwt open",
        arguments: ["path", "session", "socket", "attach mode", "generation"]
    )
    func staleDirectWorktreeEndpointDoesNotOpen(
        changedField: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        var selectedSnapshot = environment.snapshot
        selectedSnapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        selectedSnapshot.worktrees[0].tmuxSocketName = "kwt-main"
        selectedSnapshot.worktrees[0].tmuxAttachMode = .direct
        selectedSnapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        let stale = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: selectedSnapshot.worktrees[0]
            )
        )
        var currentSnapshot = selectedSnapshot
        switch changedField {
        case "path":
            currentSnapshot.worktrees[0].path = "/worktrees/replacement"
        case "session":
            currentSnapshot.worktrees[0].tmuxSessionName =
                "kwt-ghosthub-replacement"
        case "socket":
            currentSnapshot.worktrees[0].tmuxSocketName = "kwt-replacement"
        case "attach mode":
            currentSnapshot.worktrees[0].tmuxAttachMode = .protected
        case "generation":
            currentSnapshot.worktrees[0].generation = nil
        default:
            Issue.record("Unknown changed field: \(changedField)")
            return
        }
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: currentSnapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            }
        )

        model.openBorrowedTmuxSession(stale)
        await Task.yield()

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(surfaceStore.requestCount == 0)
        await model.shutdown()
    }

}

extension WorkspaceTmuxDiscoveryTests {
    @MainActor
    @Test("activating an unresolvable host hides the previous client")
    func unresolvableHostActivationHidesPreviousClient() async throws {
        let environment = try setupHostEnvironment()
        var snapshot = environment.snapshot
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        snapshot.hosts[0].tmuxSessions = [.init(
            name: "ordinary",
            managed: false,
            windows: [],
            serverPID: identity.serverPID,
            sessionID: identity.sessionID,
            createdAt: identity.createdAt,
            previewClientSize: TmuxGridSize(columns: 120, rows: 37)
        )]
        let hideMutations = LockedValue(0)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hideMutations.withLock { $0 += 1 }
                }
                return (0, "")
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(mode: .off)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "ordinary"
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let handle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        let unknownHost = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "elsewhere"
        )
        model.openBorrowedTmuxSession(unknownHost)
        await waitUntilMainActor { hideMutations.load() == 1 }

        #expect(model.activeBorrowedTmuxSelection == unknownHost)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) == handle)
        await model.shutdown()
    }
}
