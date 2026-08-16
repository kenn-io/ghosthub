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
            worktreePath: environment.worktree.path
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
                )
            }
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

        #expect(events == ["park:second", "unpark:second"])
        #expect(model.activeBorrowedTmuxSelection == first)
        #expect(!budget.granted.contains(LivePreviewRequestID(
            sceneID: previewCoordinator.sceneID,
            presentation: key
        )))
        await model.shutdown()
    }

    @MainActor
    @Test("only opened tmux sessions become previewable")
    func onlyOpenedTmuxSessionsBecomePreviewable() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let previewCoordinator = TmuxSessionPreviewCoordinator(
            mode: .efficient,
            budget: LivePreviewBudget(limit: 4),
            capture: { _, _ in nil }
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            sessionPreviewCoordinator: previewCoordinator
        )
        let opened = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "opened"
        )
        let unopened = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "unopened"
        )

        model.openBorrowedTmuxSession(opened)

        #expect(model.previewableTmuxSessionIDs == [opened.id])
        #expect(!model.previewableTmuxSessionIDs.contains(unopened.id))
        #expect(previewCoordinator.viewState(for: TmuxPreviewKey(
            hostID: opened.hostID,
            name: opened.name,
            socketName: opened.socketName
        )) != nil)
        #expect(surfaceStore.requestCount == 0)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)

        model.closeBorrowedTmuxSession(opened)

        #expect(model.previewableTmuxSessionIDs.isEmpty)
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("preview identity comes from the connected attachment")
    func previewIdentityComesFromConnectedAttachment() async throws {
        let environment = try setupHostEnvironment()
        var snapshot = environment.snapshot
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let captures = Counter()
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        snapshot.hosts[0].tmuxSessions = [.init(
            name: "opened",
            managed: false,
            windows: [],
            serverPID: identity.serverPID,
            sessionID: identity.sessionID,
            createdAt: identity.createdAt
        )]
        let previewCoordinator = TmuxSessionPreviewCoordinator(
            mode: .efficient,
            budget: LivePreviewBudget(limit: 4),
            capture: { _, _ in
                _ = captures.increment()
                return TerminalSurfaceSnapshot(
                    image: NSImage(size: CGSize(width: 32, height: 20)),
                    captureToken: TerminalSurfaceCaptureToken(
                        surfaceID: 1,
                        seed: 1
                    )
                )
            }
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
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "999",
                    sessionID: "$wrong",
                    createdAt: "9999"
                )
            },
            sessionPreviewCoordinator: previewCoordinator
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "opened"
        )
        let key = TmuxPreviewKey(
            hostID: selection.hostID,
            name: selection.name,
            socketName: selection.socketName
        )

        model.openBorrowedTmuxSession(selection)
        #expect(identityReads.count == 0)
        #expect(captures.count == 0)

        await launchActiveTmuxSurface(model, store: surfaceStore)
        #expect(identityReads.count == 0)
        #expect(captures.count == 0)

        previewCoordinator.setExpanded(true, for: key)
        await waitUntilMainActor {
            captures.count == 1
                && previewCoordinator.viewState(for: key)?.image != nil
        }

        #expect(identityReads.count == 0)
        #expect(previewCoordinator.viewState(for: key)?.image != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a switched tmux client cannot authorize preview pixels")
    func switchedClientCannotAuthorizePreviewPixels() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let clientLookups = Counter()
        let captures = Counter()
        let originalIdentity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let switchedIdentity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$2",
            createdAt: "2000"
        )
        let splitter = TmuxPaneSplitter { _, _, command in
            guard command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY")
            else { return (0, "") }
            let identity = clientLookups.increment() == 1
                ? originalIdentity
                : switchedIdentity
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t\(identity.serverPID)\t789\t321"
                    + "\t/dev/ttys001\t\(identity.sessionID)"
                    + "\t\(identity.createdAt)\t%9\n"
            )
        }
        let previewCoordinator = TmuxSessionPreviewCoordinator(
            mode: .efficient,
            budget: LivePreviewBudget(limit: 4),
            capture: { _, _ in
                _ = captures.increment()
                return TerminalSurfaceSnapshot(
                    image: NSImage(size: CGSize(width: 32, height: 20)),
                    captureToken: TerminalSurfaceCaptureToken(
                        surfaceID: 1,
                        seed: 1
                    )
                )
            }
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            sessionPreviewCoordinator: previewCoordinator
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "opened"
        )
        let key = TmuxPreviewKey(
            hostID: selection.hostID,
            name: selection.name,
            socketName: selection.socketName
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        previewCoordinator.setExpanded(true, for: key)
        await waitUntilMainActor {
            captures.count == 1
                && previewCoordinator.viewState(for: key)?.placeholder
                == .unavailable
        }

        #expect(captures.count == 1)
        #expect(previewCoordinator.viewState(for: key)?.image == nil)
        #expect(
            previewCoordinator.viewState(for: key)?.placeholder
                == .unavailable
        )
        await model.shutdown()
    }

    @MainActor
    @Test("leaving an opened tmux session captures its final frame")
    func leavingTmuxCapturesFinalFrame() async throws {
        let environment = try setupHostEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let captures = Counter()
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let previewCoordinator = TmuxSessionPreviewCoordinator(
            mode: .efficient,
            budget: LivePreviewBudget(limit: 4),
            capture: { _, _ in
                let sequence = captures.increment()
                return TerminalSurfaceSnapshot(
                    image: NSImage(size: CGSize(width: 32, height: 20)),
                    captureToken: TerminalSurfaceCaptureToken(
                        surfaceID: 1,
                        seed: UInt32(sequence)
                    )
                )
            }
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport.previewPaneSplitter(
                identity: identity
            ),
            sessionPreviewCoordinator: previewCoordinator
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "opened"
        )
        let key = TmuxPreviewKey(
            hostID: selection.hostID,
            name: selection.name,
            socketName: selection.socketName
        )

        model.openBorrowedTmuxSession(selection)
        previewCoordinator.setExpanded(true, for: key)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { captures.count == 1 }

        model.hideBorrowedTmuxSession(selection)
        await previewCoordinator.waitForPendingWork()

        #expect(captures.count == 2)
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.previewableTmuxSessionIDs == [selection.id])
        #expect(previewCoordinator.viewState(for: key)?.image != nil)
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
            name: sessionName
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
            tmuxReconnectIntervals: [.seconds(10)]
        )
        let canonical = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )
        let duplicate = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
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
            sshDestination: "wesm@second-builder",
            preferredTransport: .ssh,
            lastKnownReachable: true
        )
        snapshot.hosts.append(secondHost)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: secondHost.id,
            name: "deploy-work"
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
                return TerminalSurfaceSnapshot(
                    image: NSImage(size: CGSize(width: 32, height: 20)),
                    captureToken: TerminalSurfaceCaptureToken(
                        surfaceID: 1,
                        seed: 1
                    )
                )
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
            worktreePath: "/srv/ghosthub"
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
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "editor"
        snapshot.worktrees[0].generation =
            "fedcba9876543210fedcba9876543210"
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
            worktreeGeneration: "0123456789abcdef0123456789abcdef"
        )
        model.openBorrowedTmuxSession(observed)
        #expect(
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == "0123456789abcdef0123456789abcdef"
        )

        var reselection = model.selection
        reselection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        model.selectFromUser(reselection)

        #expect(
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == "fedcba9876543210fedcba9876543210"
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
            (
                "kwt-ghosthub-main",
                String?.none,
                "fedcba9876543210fedcba9876543210"
            ),
        ]
    )
    func returningToReplacedWorktreeInvalidatesRetainedClient(
        replacementName: String,
        replacementSocket: String?,
        replacementGeneration: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
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

        var replacement = worktree
        replacement.name = replacementName
        replacement.socketName = replacementSocket
        replacement.worktreeGeneration = replacementGeneration
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
    @Test("discovered worktree session attaches without managed kwt")
    func discoveredWorktreeSessionAttachesDirectly() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
        ]
        snapshot.hosts[0].remoteDiagnostics = [.missingKwtCapability]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'attach-session'"))
        #expect(!command.contains("'open'"))
        #expect(!command.contains("managed kwt is unavailable"))
    }

    @MainActor
    @Test("cached worktree session uses kwt when the helper is available")
    func cachedWorktreeSessionUsesKwt() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        snapshot.worktrees[0].tmuxSessionName = sessionName
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
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'open'"))
        #expect(command.contains(environment.worktree.path))
    }

    @MainActor
    @Test("kill carries the discovered session identity through confirmation")
    func killUsesConfirmedSessionIdentity() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "training",
                managed: false,
                windows: [],
                serverPID: "31415",
                sessionID: "$8",
                createdAt: "1721552400"
            ),
        ]
        let killedIdentity = LockedValue<TmuxSessionIdentity?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            tmuxSessionKiller: { _, identity, _ in
                killedIdentity.store(identity)
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "training"
        )

        let request = try await model.prepareTmuxSessionKill(selection)
        model.snapshot.hosts[0].tmuxSessions[0].serverPID = "31416"
        try await model.killTmuxSession(request)

        #expect(request.serverPID == "31415")
        #expect(request.sessionID == "$8")
        #expect(request.sessionCreatedAt == "1721552400")
        #expect(killedIdentity.load() == TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        ))
    }

    @MainActor
    @Test("reopening a killed local worktree restores its window count")
    func reopeningKilledLocalWorktreeRestoresWindowCount() async throws {
        let environment = try setupStandardEnvironment()
        let sessionName = "kwt-wt-ghosthub-main-12345678"
        let runningSession = DiscoveredTmuxSession(
            name: sessionName,
            windowCount: 1,
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400",
            managed: true
        )
        let restartedSession = DiscoveredTmuxSession(
            name: sessionName,
            windowCount: 3,
            serverPID: "31416",
            sessionID: "$9",
            createdAt: "1721552500",
            managed: true
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .success([runningSession]),
            .success([]),
            .success([restartedSession]),
        ])
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = sessionName
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxSessionKiller: { _, _, _ in },
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            discoveries.count == 1
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.first?.windows.count == 1
        }
        let worktree = try #require(model.snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let request = try await model.prepareTmuxSessionKill(selection)

        try await model.killTmuxSession(request)
        await waitUntilMainActor {
            discoveries.count == 2
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        }

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor(timeout: .seconds(1)) {
            discoveries.count == 3
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.first?.windows.count == 3
        }

        let host = try #require(
            model.snapshot.host(id: environment.host.id)
        )
        #expect(host.tmuxInventoryIsAuthoritative)
        #expect(host.tmuxSessions.first?.name == sessionName)
        #expect(host.tmuxSessions.first?.windows.count == 3)
        await model.shutdown()
    }

    @MainActor
    @Test("closing a worktree replaces the discovery its probe superseded")
    func closingWorktreeReplacesSupersededDiscovery() async throws {
        let environment = try setupStandardEnvironment()
        let sessionName = "kwt-wt-ghosthub-main-12345678"
        let attempts = Counter()
        let blockedRefresh = BlockingGate()
        let discovered = DiscoveredTmuxSession(
            name: sessionName,
            windowCount: 3,
            createdAt: "1721552500",
            managed: true
        )
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: [
                    TmuxWindowSummary(
                        id: "0",
                        index: 0,
                        name: "editor"
                    ),
                ]
            ),
        ]
        snapshot.hosts[0].tmuxInventoryIsAuthoritative = true
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                if attempts.increment() == 1 {
                    blockedRefresh.wait()
                }
                return .success([discovered])
            },
            createdSessionDiscoveryDelays: [.zero]
        )
        defer { blockedRefresh.release() }

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { blockedRefresh.didStart }
        let worktree = try #require(model.snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        model.closeBorrowedTmuxSession(selection)
        blockedRefresh.release()
        await waitUntilMainActor(timeout: .seconds(1)) {
            attempts.count >= 2
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.first?.windows.count == 3
        }

        #expect(attempts.count == 2)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.first?.windows.count == 3
        )
        await model.shutdown()
    }

    @MainActor
    @Test("a failed kill leaves the active session attached")
    func failedKillPreservesActiveSession() async throws {
        let environment = try setupStandardEnvironment()
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        let expectedError = TmuxSessionKillError.commandFailed(
            host: "localhost",
            session: selection.name,
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            tmuxSessionKiller: { _, _, _ in
                throw expectedError
            }
        )
        model.selection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        let originalSelection = model.selection
        model.openBorrowedTmuxSession(selection)
        let request = TmuxSessionKillRequest(
            session: selection,
            confirmedHost: try #require(
                model.snapshot.host(id: environment.host.id)
            ),
            serverPID: "31415",
            sessionID: "$42",
            sessionCreatedAt: "1721552400"
        )

        await #expect {
            try await model.killTmuxSession(request)
        } throws: { error in
            error as? TmuxSessionKillError == expectedError
        }

        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.selection == originalSelection)
    }

    @MainActor
    @Test("kill rejects a host endpoint changed after confirmation")
    func killRejectsChangedEndpoint() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let killCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            tmuxSessionKiller: { _, _, _ in
                _ = killCalls.increment()
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher: configuredHosts.eraseToAnyPublisher()
        )
        model.refreshHosts()
        let confirmedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "spark" }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: confirmedHost.id,
            name: "training",
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)
        let request = TmuxSessionKillRequest(
            session: selection,
            confirmedHost: confirmedHost,
            serverPID: "31415",
            sessionID: "$42",
            sessionCreatedAt: "1721552400"
        )

        configuredHosts.value = [
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()

        await #expect {
            try await model.killTmuxSession(request)
        } throws: { error in
            error as? TmuxSessionKillError == .hostChanged(
                session: selection.name
            )
        }
        #expect(killCalls.count == 0)
    }

    @MainActor
    @Test("kill preparation rejects a disconnected active attachment")
    func killPreparationRejectsDisconnectedAttachment() async throws {
        let environment = try setupStandardEnvironment()
        let identityReads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)

        await #expect {
            _ = try await model.prepareTmuxSessionKill(selection)
        } throws: { error in
            error as? TmuxSessionKillError == .sessionNotRunning(
                host: "localhost",
                session: selection.name
            )
        }
        #expect(identityReads.count == 0)
    }

    @MainActor
    @Test("connected attachment supplies protected-session identity")
    func connectedAttachmentSuppliesIdentity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { identityReads.count == 1 }
        let readsBeforeKill = identityReads.count

        let request = try await model.prepareTmuxSessionKill(selection)

        #expect(request.serverPID == "31415")
        #expect(request.sessionID == "$42")
        #expect(request.sessionCreatedAt == "1721552400")
        #expect(identityReads.count == readsBeforeKill + 1)
    }

    @MainActor
    @Test("connected attachment keeps retrying activity enrollment")
    func connectedAttachmentKeepsRetryingActivityEnrollment() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                let sample = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: sample == 1 ? "baseline" : "changed"
                )
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { selection, host in
                guard identityReads.increment() > 2 else {
                    throw TmuxSessionKillError.sessionNotRunning(
                        host: host.displayName,
                        session: selection.name
                    )
                }
                try await Task.sleep(for: .milliseconds(20))
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController,
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        await waitUntilMainActor {
            activityController.warmSessionIDs.contains(selection.id)
        }
        #expect(identityReads.count >= 3)
        let start = Date.now
        for tick in 1 ... 400
            where !model.workingTmuxSessionIDs.contains(selection.id) {
            await activityController.sampleWarmSessions(
                at: start.addingTimeInterval(Double(tick))
            )
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(model.workingTmuxSessionIDs == [selection.id])
        await model.shutdown()
    }

    @MainActor
    @Test("an occluded connected attachment still enrolls warm activity")
    func occludedConnectedAttachmentEnrollsWarmActivity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let identityAvailable = LockedValue(false)
        let sampleCounts = LockedValue<[String: Int]>([:])
        let activityController = TmuxSessionActivityController(
            sampler: { selection, _, _ in
                var count = 0
                sampleCounts.withLock { counts in
                    count = (counts[selection.name] ?? 0) + 1
                    counts[selection.name] = count
                }
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: "\(selection.name)-\(count)"
                )
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { selection, host in
                _ = identityReads.increment()
                guard identityAvailable.load() else {
                    throw TmuxSessionKillError.sessionNotRunning(
                        host: host.displayName,
                        session: selection.name
                    )
                }
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController,
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { identityReads.count >= 1 }

        let second = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor(timeout: .seconds(15)) {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        identityAvailable.store(true)

        await waitUntilMainActor(timeout: .seconds(15)) {
            activityController.warmSessionIDs.contains(first.id)
        }
        let start = Date.now
        await activityController.sampleWarmSessions(at: start)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )

        #expect(model.workingTmuxSessionIDs.contains(first.id))
        await model.shutdown()
    }

    @MainActor
    @Test("connected attachment validates stale discovered activity identity")
    func connectedAttachmentValidatesStaleActivityIdentity() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: selection.name,
                managed: false,
                windows: [],
                serverPID: "1111",
                sessionID: "$1",
                createdAt: "1721552300"
            ),
        ]
        let liveIdentity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$42",
            createdAt: "1721552400"
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let sampledIdentities = LockedValue<[TmuxSessionIdentity]>([])
        let activityController = TmuxSessionActivityController(
            sampler: { _, identity, _ in
                sampledIdentities.withLock { $0.append(identity) }
                return identity == liveIdentity
                    ? .sample(
                        paneID: "%2",
                        dimensions: "120x30",
                        fingerprint: "baseline"
                    )
                    : .ended
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return liveIdentity
            },
            tmuxSessionActivityController: activityController,
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        await waitUntilMainActor(timeout: .milliseconds(250)) {
            identityReads.count == 1
        }
        await activityController.sampleWarmSessions()

        #expect(identityReads.count == 1)
        #expect(sampledIdentities.load() == [liveIdentity])
        await model.shutdown()
    }

    @MainActor
    @Test("closing one attachment preserves shared warm activity")
    func closingOneAttachmentPreservesSharedWarmActivity() async throws {
        let environment = try setupStandardEnvironment()
        let firstSurfaceStore = SceneTmuxSurfaceStoreStub()
        let secondSurfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                let sample = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: sample == 1 ? "baseline" : "changed"
                )
            },
            automaticallyPolls: false
        )
        let firstModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: firstSurfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController
        )
        let secondModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: secondSurfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        firstModel.openBorrowedTmuxSession(selection)
        secondModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(
            firstModel,
            store: firstSurfaceStore
        )
        await launchActiveTmuxSurface(
            secondModel,
            store: secondSurfaceStore
        )
        await waitUntilMainActor { identityReads.count == 2 }
        let start = Date.now
        await activityController.sampleWarmSessions(at: start)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(firstModel.workingTmuxSessionIDs == [selection.id])
        #expect(secondModel.workingTmuxSessionIDs == [selection.id])

        let close = try #require(
            firstSurfaceStore.surface.closeObservers.values.first
        )
        close(false, 1)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(25)
        )

        #expect(firstModel.workingTmuxSessionIDs == [selection.id])
        #expect(secondModel.workingTmuxSessionIDs == [selection.id])
        #expect(activitySamples.count == 3)
        await firstModel.shutdown()
        await secondModel.shutdown()
    }

    @MainActor
    @Test("reopening an attachment preserves its warm activity baseline")
    func reopeningAttachmentPreservesWarmActivityBaseline() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                let sample = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: sample == 1 ? "baseline" : "changed"
                )
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            },
            tmuxSessionActivityController: activityController
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { identityReads.count == 1 }
        let start = Date.now
        await activityController.sampleWarmSessions(at: start)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(model.workingTmuxSessionIDs == [selection.id])

        let close = try #require(
            surfaceStore.surface.closeObservers.values.first
        )
        close(false, 1)
        model.closeBorrowedTmuxSession(selection)
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        await waitUntilMainActor { identityReads.count == 2 }
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(25)
        )

        #expect(model.workingTmuxSessionIDs == [selection.id])
        #expect(activitySamples.count == 3)
        await model.shutdown()
    }

    @MainActor
    @Test("protected kill availability survives a generation change")
    func protectedKillSurvivesGenerationChange() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        var selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef",
            socketName: "protected"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { identityReads.count == 1 }
        let readsBeforeKill = identityReads.count

        selection.worktreeGeneration =
            "fedcba9876543210fedcba9876543210"
        let request = try await model.prepareTmuxSessionKill(selection)

        #expect(request.serverPID == "31415")
        #expect(identityReads.count == readsBeforeKill + 1)
    }

    @MainActor
    @Test("kill closes the active attachment across a generation change")
    func killClosesAttachmentAcrossGenerationChange() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "kwt-ghosthub-main",
                managed: false,
                windows: [],
                serverPID: "31415",
                sessionID: "$8",
                createdAt: "1721552400"
            ),
        ]
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            tmuxSessionKiller: { _, _, _ in }
        )
        var selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            worktreeGeneration: "0123456789abcdef0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)

        selection.worktreeGeneration =
            "fedcba9876543210fedcba9876543210"
        let request = try await model.prepareTmuxSessionKill(selection)
        try await model.killTmuxSession(request)

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(
            model.selection.selectedHostID == environment.host.id
        )
    }

    @MainActor
    @Test("an exited tmux client refreshes stale session inventory")
    func exitedClientRefreshesSessionInventory() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let discoveryCalls = Counter()
        let discovered = DiscoveredTmuxSession(
            name: "release-work",
            windowCount: 1,
            serverPID: "31415",
            sessionID: "$42",
            createdAt: "1721552400",
            managed: true
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                discoveryCalls.increment() == 1
                    ? .success([discovered])
                    : .success([])
            }
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            discoveryCalls.count == 1
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map { $0.name } == ["release-work"]
        }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let close = try #require(
            surfaceStore.surface.closeObservers.values.first
        )
        close(true, nil)
        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)

        await waitUntilMainActor {
            discoveryCalls.count >= 2
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        }
        #expect(model.activeBorrowedTmuxSessionIsConfirmedEnded)

        model.retryBorrowedTmuxSession(selection)

        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
    }

    @MainActor
    @Test("a closed client reconnects when discovery finds the session")
    func exitedClientKeepsRunningSessionReconnectable() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let discoveryCalls = Counter()
        let discovered = DiscoveredTmuxSession(
            name: "release-work",
            windowCount: 1,
            serverPID: "31415",
            sessionID: "$42",
            createdAt: "1721552400",
            managed: true
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                _ = discoveryCalls.increment()
                return .success([discovered])
            }
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { discoveryCalls.count == 1 }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let close = try #require(
            surfaceStore.surface.closeObservers.values.first
        )
        close(true, nil)
        await waitUntilMainActor { discoveryCalls.count >= 2 }

        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        model.retryBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
    }

    @MainActor
    @Test("kill completion preserves a session selected while it runs")
    func killCompletionPreservesNewActiveSession() async throws {
        let environment = try setupStandardEnvironment()
        let killGate = KillGate()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            tmuxSessionKiller: { _, _, _ in
                await killGate.suspend()
            }
        )
        let killed = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "training"
        )
        let replacement = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(killed)
        let request = TmuxSessionKillRequest(
            session: killed,
            confirmedHost: try #require(
                model.snapshot.host(id: environment.host.id)
            ),
            serverPID: "31415",
            sessionID: "$42",
            sessionCreatedAt: "1721552400"
        )

        let killTask = Task {
            try await model.killTmuxSession(request)
        }
        await killGate.waitUntilStarted()
        model.openBorrowedTmuxSession(replacement)
        model.selection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        await killGate.release()
        try await killTask.value

        #expect(model.activeBorrowedTmuxSelection == replacement)
        #expect(model.selection.selectedWorktreeID == environment.worktree.id)
    }

    @MainActor
    @Test("kill completion closes the target selected while it runs")
    func killCompletionClosesNewlyActiveTarget() async throws {
        let environment = try setupStandardEnvironment()
        let killGate = KillGate()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "training",
                managed: false,
                windows: []
            ),
        ]
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            tmuxSessionKiller: { _, _, _ in
                await killGate.suspend()
            }
        )
        let killed = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "training"
        )
        let replacement = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(replacement)
        model.selection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        let request = TmuxSessionKillRequest(
            session: killed,
            confirmedHost: try #require(
                model.snapshot.host(id: environment.host.id)
            ),
            serverPID: "31415",
            sessionID: "$42",
            sessionCreatedAt: "1721552400"
        )

        let killTask = Task {
            try await model.killTmuxSession(request)
        }
        await killGate.waitUntilStarted()
        let activeTarget = WorkspaceTmuxSessionSelection(
            hostID: killed.hostID,
            name: killed.name,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(activeTarget)
        await killGate.release()
        try await killTask.value

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.selection.selectedWorktreeID == nil)
    }

    @MainActor
    @Test("explicit creation attaches when inventory already has the name")
    func knownSessionCreationUsesAttachMode() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "release-work",
                managed: false,
                windows: []
            ),
        ]
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "never-run-this"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("attach-session"))
        #expect(!command.contains("new-session"))
        #expect(!command.contains("never-run-this"))
    }

    @MainActor
    @Test("new named creation carries its launch profile command")
    func profileCreationCarriesInitialCommand() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "codex"
        )

        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)

        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("exec codex"))
        await model.shutdown()
    }

    @MainActor
    @Test("explicit close abandons an unlaunched profile creation")
    func explicitCloseAbandonsUnlaunchedProfileCreation() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "codex"
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))

        #expect(surfaceStore.requestCount == 0)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == [selection.name]
        )

        model.closeBorrowedTmuxSession(selection)

        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        )
        #expect(model.retainedBorrowedTmuxHandle(for: selection) == nil)
        #expect(!model.activeBorrowedTmuxRetryRequiresConfirmation)
        await model.shutdown()
    }

    @MainActor
    @Test("confirmed named creation retries in attach mode")
    func confirmedCreationDemotesToAttachMode() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            },
            createdSessionDiscoveryDelays: [.zero]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
        }

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        model.retryBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("creating a closed retained session launches a replacement")
    func creatingClosedRetainedSessionLaunchesReplacement() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let closedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        surfaceStore.surface.closeObservers[closedHandle.id]?(false, 0)

        model.createTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let replacementHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        let command = try #require(surfaceStore.lastConfiguration?.command)

        #expect(replacementHandle != closedHandle)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(command.contains("new-session"))
        await model.shutdown()
    }

    @MainActor
    @Test("reopening an optimistic session preserves creation intent")
    func reopeningCreatedSessionPreservesCreateMode() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: {
                .failure(.notFound(shell: "test"))
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        model.openBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)

        model.retryBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
    }

    @MainActor
    @Test("attachment failure publishes its disconnected state")
    func attachmentFailurePublishesDisconnectedState() async throws {
        let environment = try setupStandardEnvironment()
        let resolutionGate = BlockingGate()
        let resolutionFinished = Mutex(false)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: {
                resolutionGate.wait()
                resolutionFinished.withLock { $0 = true }
                return .failure(.notFound(shell: "test"))
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { resolutionGate.didStart }
        var updateCount = 0
        let updates = model.objectWillChange.sink { updateCount += 1 }
        resolutionGate.release()

        await waitUntilMainActor {
            resolutionFinished.withLock { $0 } && updateCount > 0
        }

        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        withExtendedLifetime(updates) {}
        await model.shutdown()
    }

    @MainActor
    @Test("failed remote provisioning removes the optimistic session")
    func failedRemoteProvisioningRemovesOptimisticSession() async throws {
        let environment = try setupRemoteEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            remoteTmuxPathProvider: { _, _ in
                .failure(.sshConnectionFailed(
                    host: "office-linux",
                    classification: SSHConnectionFailure.classify(
                        status: 255,
                        output: ""
                    )
                ))
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
        }

        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == []
        )
        await model.shutdown()
    }

    @MainActor
    @Test("launched remote creation reconciles before removing its session")
    func launchedRemoteCreationReconcilesBeforeRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        let attempts = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                guard attempts.increment() > 1 else {
                    return .failure(.sshConnectionFailed(
                        host: "office-linux",
                        classification: SSHConnectionFailure.classify(
                            status: 255,
                            output: ""
                        )
                    ))
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            },
            createdSessionDiscoveryDelays: [.milliseconds(100)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let close = try #require(
            surfaceStore.surface.closeObservers.values.first
        )
        close(false, 1)

        await waitUntilMainActor { attempts.count == 1 }
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )

        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
        }
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(attempts.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("protected workspaces never inherit default-server creation")
    func protectedWorkspaceDoesNotReusePendingDefaultSession() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxPathProvider: {
                .failure(.notFound(shell: "test"))
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let defaultSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-workspace-pr-32"
        )
        let protectedSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: defaultSelection.name,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            socketName: "kwt-pr-0123456789abcdef"
        )

        model.createTmuxSession(defaultSelection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)

        model.openBorrowedTmuxSession(protectedSelection)

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
    }

    @MainActor
    @Test("creation discovery follows automatic terminal command launch")
    func createdSessionDiscoveryFollowsAutomaticLaunch() async throws {
        let environment = try setupStandardEnvironment()
        let attempts = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { _ in
                _ = attempts.increment()
                return .success([])
            },
            createdSessionDiscoveryDelays: [.zero],
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState != .loading
        }
        let baselineAttempts = attempts.count

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        ))
        await waitUntilMainActor {
            surfaceStore.requestCount == 1
                && attempts.count > baselineAttempts
        }

        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
        await model.shutdown()
    }

    @MainActor
    @Test("inactive presentation launches when binary resolution completes")
    func inactivePresentationLaunchesAfterPathResolution() async throws {
        let environment = try setupStandardEnvironment()
        let path = DelayedTmuxPathState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: path.resolve
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await waitUntilMainActor { path.didStart }
        model.hideBorrowedTmuxSession(selection)
        path.release()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("path resolution publishes surface readiness for rerender")
    func pathResolutionPublishesSurfaceReadiness() async throws {
        let environment = try setupStandardEnvironment()
        let path = DelayedTmuxPathState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: path.resolve
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        model.prepareActiveBorrowedTmuxSurface()
        #expect(surfaceStore.requestCount == 0)
        await waitUntilMainActor { path.didStart }

        var updateCount = 0
        let updates = model.objectWillChange.sink { updateCount += 1 }
        path.release()
        await waitUntilMainActor { updateCount > 0 }

        model.prepareActiveBorrowedTmuxSurface()
        #expect(surfaceStore.requestCount == 1)
        withExtendedLifetime(updates) {}
        await model.shutdown()
    }

    @MainActor
    @Test("detaching a created session retries discovery before removal")
    func createdSessionReconcilesBeforeDetachRemoval() async throws {
        let environment = try setupStandardEnvironment()
        let attempts = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                guard attempts.increment() >= 3 else {
                    return .success([])
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)

        await waitUntilMainActor(timeout: .seconds(4)) {
            model.pendingCreatedTmuxSessionCount == 0
                && attempts.count >= 3
        }
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
        await model.shutdown()
    }

    @MainActor
    @Test("successful refresh removes an exhausted optimistic creation")
    func successfulRefreshRemovesExhaustedCreation() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = DiscoveryState(failuresRemaining: 100)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [
                .milliseconds(1),
                .milliseconds(2),
            ]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "failed-creation"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.exhaustedCreatedTmuxSessionCount == 1
                && discovery.attemptCount >= 3
        }
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["failed-creation"]
        )

        discovery.allowSuccess()
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        }
        #expect(model.exhaustedCreatedTmuxSessionCount == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("endpoint changes cancel detached creation discovery")
    func endpointChangeCancelsDetachedCreationDiscovery() async throws {
        let environment = try setupStandardEnvironment()
        let oldTarget = CommandHost.ssh(SSHHostInfo(
            user: "wesm",
            hostname: "old.example.com",
            port: nil
        ))
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let discovery = DiscoveryState(
            failuresRemaining: 0,
            delayedHost: oldTarget
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            configuredSSHHostsProvider: { configuredHosts.value },
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )
        model.refreshHosts()
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: remoteHost.id,
            name: "stale-session"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            discovery.hasStarted(on: oldTarget)
        }

        configuredHosts.value = [
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(model.exhaustedCreatedTmuxSessionCount == 0)
        let updatedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        #expect(updatedHost.sshDestination == "wesm@new.example.com")
        #expect(updatedHost.tmuxSessions.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("endpoint change invalidates only that host's retained presentations")
    func endpointChangeInvalidatesOnlyAffectedHostPresentations()
        async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "first-builder",
                name: "First Builder",
                platform: .linux,
                sshDestination: "wesm@first-builder"
            ),
            SSHHost(
                configKey: "second-builder",
                name: "Second Builder",
                platform: .linux,
                sshDestination: "wesm@second-builder"
            ),
        ])
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        model.refreshHosts()
        let firstHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "first-builder" }
        )
        let secondHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "second-builder" }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: firstHost.id,
            name: "first"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: secondHost.id,
            name: "second"
        )
        model.openBorrowedTmuxSession(first)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let secondHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: second)
        )

        configuredHosts.value = [
            SSHHost(
                configKey: "first-builder",
                name: "First Builder",
                platform: .linux,
                sshDestination: "wesm@replacement-builder"
            ),
            SSHHost(
                configKey: "second-builder",
                name: "Second Builder",
                platform: .linux,
                sshDestination: "wesm@second-builder"
            ),
        ]
        model.refreshHosts()

        #expect(model.retainedBorrowedTmuxHandle(for: first) == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: second) == secondHandle)
        #expect(model.activeBorrowedTmuxSelection == second)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("endpoint changes retire warm activity on the former host")
    func endpointChangeRetiresWarmActivity() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                let sample = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: sample == 1 ? "baseline" : "changed"
                )
            },
            automaticallyPolls: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            configuredSSHHostsProvider: { configuredHosts.value },
            tmuxSessionActivityController: activityController
        )
        model.refreshHosts()
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        let oldEndpoint = try #require(CommandHostResolver.resolve(remoteHost))
        let selection = WorkspaceTmuxSessionSelection(
            hostID: remoteHost.id,
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        activityController.warm(
            selection,
            identity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1721552400"
            ),
            on: oldEndpoint,
            at: start
        )
        await activityController.sampleWarmSessions(at: start)
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(model.workingTmuxSessionIDs == [selection.id])

        configuredHosts.value = [
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(40)
        )

        #expect(model.workingTmuxSessionIDs.isEmpty)
        #expect(activitySamples.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("a new scene retires warm activity for reconfigured endpoints")
    func newSceneRetiresWarmActivityForReconfiguredEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let activitySamples = Counter()
        let activityController = TmuxSessionActivityController(
            sampler: { _, _, _ in
                _ = activitySamples.increment()
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: "baseline"
                )
            },
            automaticallyPolls: false
        )
        let firstScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            configuredSSHHostsProvider: { configuredHosts.value },
            tmuxSessionActivityController: activityController
        )
        firstScene.refreshHosts()
        let remoteHost = try #require(
            firstScene.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        let oldEndpoint = try #require(CommandHostResolver.resolve(remoteHost))
        let selection = WorkspaceTmuxSessionSelection(
            hostID: remoteHost.id,
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        activityController.warm(
            selection,
            identity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1721552400"
            ),
            on: oldEndpoint,
            at: start
        )
        await activityController.sampleWarmSessions(at: start)
        #expect(activitySamples.count == 1)
        await firstScene.shutdown()

        configuredHosts.value = [
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        let secondScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            configuredSSHHostsProvider: { configuredHosts.value },
            tmuxSessionActivityController: activityController,
            startServices: true
        )
        await activityController.sampleWarmSessions(
            at: start.addingTimeInterval(40)
        )

        #expect(activitySamples.count == 1)
        await secondScene.shutdown()
    }

    @MainActor
    @Test("shutdown cancels detached creation discovery")
    func shutdownCancelsDetachedCreationDiscovery() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = CancellableProbeState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [.zero]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            discovery.didStart
        }

        await model.shutdown()
        await waitUntilMainActor {
            discovery.didCancel
        }
    }

    @MainActor
    @Test("stale global discovery cannot erase confirmed creation")
    func staleGlobalDiscoveryCannotEraseCreation() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = StaleDiscoveryState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [.milliseconds(1)],
            startServices: true
        )
        defer { discovery.releaseFirst() }
        await waitUntilMainActor {
            discovery.firstStarted
        }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )

        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        model.closeBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.pendingCreatedTmuxSessionCount == 0
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        }

        discovery.releaseFirst()
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["release-work"]
        )
        await model.shutdown()
    }

}
