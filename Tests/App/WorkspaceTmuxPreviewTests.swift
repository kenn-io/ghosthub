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
                return try makePreviewSnapshot()
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
                && previewCoordinator.viewState(for: key)?.frame != nil
        }

        #expect(identityReads.count == 0)
        #expect(previewCoordinator.viewState(for: key)?.frame != nil)
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
                return try makePreviewSnapshot()
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
        #expect(previewCoordinator.viewState(for: key)?.frame == nil)
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
                return try makePreviewSnapshot(seed: UInt32(sequence))
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
        #expect(previewCoordinator.viewState(for: key)?.frame != nil)
        await model.shutdown()
    }

}
