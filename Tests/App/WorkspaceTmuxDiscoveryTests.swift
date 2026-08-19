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

@Suite("Workspace tmux discovery", .serialized)
struct WorkspaceTmuxDiscoveryTests {
    @Test("Always Live activation does not wait for sizing promotion")
    @MainActor
    func alwaysLiveActivationDoesNotWaitForSizingPromotion() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let promotionStarted = LockedValue(false)
        let releasePromotion = DispatchSemaphore(value: 0)
        defer { releasePromotion.signal() }
        let session = DiscoveredTmuxSession(
            name: "build",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let splitter = TmuxPaneSplitter { _, _, command in
            if command.contains("'!ignore-size'") {
                promotionStarted.withLock { $0 = true }
                releasePromotion.wait()
                return (0, "")
            }
            guard command.contains(
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
            ) else { return (0, "") }
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t101\t789\t321\t/dev/ttys001\t$1\t1001\t%9\n"
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: session.name
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { promotionStarted.load() }

        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.retainedBorrowedTmuxHandle(for: selection) != nil)

        releasePromotion.signal()
        await model.shutdown()
    }

    @Test("failed Always Live promotion retries an interactive attachment")
    @MainActor
    func failedAlwaysLivePromotionRetriesInteractiveAttachment() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let session = DiscoveredTmuxSession(
            name: "build",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let splitter = TmuxPaneSplitter { _, _, command in
            if command.contains("'!ignore-size'") {
                return (1, "promotion rejected")
            }
            guard command.contains(
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
            ) else { return (0, "") }
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t101\t789\t321\t/dev/ttys001\t$1\t1001\t%9\n"
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: session.name
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSelection == selection
                && surfaceStore.requestCount == 2
        }

        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.removedKeys.count == 1)
        #expect(surfaceStore.lastConfiguration?.command?.contains(
            "ignore-size"
        ) == false)
        await model.shutdown()
    }

    @Test("host changes immediately detach Always Live clients")
    @MainActor
    func hostChangesDetachAlwaysLiveClients() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let removedHost = HostSummary(
            id: UUID(),
            configKey: "removed-builder",
            name: "Removed Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "user@removed-builder",
            preferredTransport: .ssh
        )
        var snapshot = environment.snapshot
        snapshot.hosts.append(removedHost)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let session = DiscoveredTmuxSession(
            name: "build",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport
                .previewPaneSplitter(identity: TmuxSessionIdentity(
                    serverPID: "101",
                    sessionID: "$1",
                    createdAt: "1001"
                )),
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { host in
                host.isRemote ? .success([session]) : .success([])
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxPresentationCount == 2
                && surfaceStore.requestCount == 2
        }

        var updatedSnapshot = model.snapshot
        updatedSnapshot.hosts.removeAll { $0.id == removedHost.id }
        let changedIndex = try #require(updatedSnapshot.hosts.firstIndex {
            $0.id == environment.remoteHost.id
        })
        updatedSnapshot.hosts[changedIndex].sshDestination =
            "user@replacement-builder"
        model.snapshot = updatedSnapshot

        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(surfaceStore.removedKeys.count == 2)
        await model.shutdown()
    }

    @Test("Always Live replaces a retained client when identity changes")
    @MainActor
    func alwaysLiveReplacesMismatchedRetainedIdentity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionID = LockedValue("$1")
        let identityReads = Counter()
        let splitter = TmuxPaneSplitter { _, _, command in
            guard command.contains(
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
            ) else { return (0, "") }
            let currentSessionID = sessionID.load()
            _ = identityReads.increment()
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t101\t789\t321\t/dev/ttys001"
                    + "\t\(currentSessionID)"
                    + "\t\(currentSessionID == "$1" ? "1001" : "2002")"
                    + "\t%9\n"
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            tmuxSessionDiscovery: { _ in
                let currentSessionID = sessionID.load()
                return .success([DiscoveredTmuxSession(
                    name: "build",
                    windowCount: 1,
                    serverPID: "101",
                    sessionID: currentSessionID,
                    createdAt: currentSessionID == "$1" ? "1001" : "2002",
                    activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
                    previewClientSize: TmuxGridSize(columns: 120, rows: 37),
                    managed: false
                )])
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            surfaceStore.requestCount == 1 && identityReads.count >= 1
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        let initialHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )

        sessionID.withLock { $0 = "$2" }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.retainedBorrowedTmuxHandle(for: selection)
                != initialHandle
        }

        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @Test("Always Live replaces a pending client when identity changes")
    @MainActor
    func alwaysLiveReplacesMismatchedPendingIdentity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionID = LockedValue("$1")
        let identityReads = Counter()
        let initialIdentityGate = BlockingGate()
        defer { initialIdentityGate.release() }
        let splitter = TmuxPaneSplitter { _, _, command in
            guard command.contains(
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
            ) else { return (0, "") }
            let currentSessionID = sessionID.load()
            if identityReads.increment() == 1 {
                initialIdentityGate.wait()
            }
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t101\t789\t321\t/dev/ttys001"
                    + "\t\(currentSessionID)"
                    + "\t\(currentSessionID == "$1" ? "1001" : "2002")"
                    + "\t%9\n"
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            tmuxSessionDiscovery: { _ in
                let currentSessionID = sessionID.load()
                return .success([DiscoveredTmuxSession(
                    name: "pending-identity",
                    windowCount: 1,
                    serverPID: "101",
                    sessionID: currentSessionID,
                    createdAt: currentSessionID == "$1" ? "1001" : "2002",
                    activeWindowSize: TmuxGridSize(columns: 100, rows: 30),
                    previewClientSize: TmuxGridSize(columns: 100, rows: 31),
                    managed: false
                )])
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            surfaceStore.requestCount == 1 && initialIdentityGate.didStart
        }
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "pending-identity"
        )
        let initialHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )

        sessionID.withLock { $0 = "$2" }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.first?.sessionID == "$2"
        }
        model.tmuxAttachedSessionIdentityBecameUnavailable(initialHandle)
        await waitUntilMainActor(timeout: .seconds(5)) {
            surfaceStore.requestCount == 2
                && model.retainedBorrowedTmuxHandle(for: selection)
                != initialHandle
        }

        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(surfaceStore.removedKeys.count == 1)
        initialIdentityGate.release()
        await model.shutdown()
    }

    @Test("Always Live retries an excluded name when identity changes")
    @MainActor
    func alwaysLiveRetriesExcludedReplacementIdentity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionID = LockedValue("$1")
        let resolutionCount = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                let attempt = resolutionCount.load()
                resolutionCount.withLock { $0 += 1 }
                return attempt == 0
                    ? .failure(.notFound(shell: "/bin/zsh"))
                    : successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport
                .previewPaneSplitter(identity: TmuxSessionIdentity(
                    serverPID: "101",
                    sessionID: "$2",
                    createdAt: "2002"
                )),
            tmuxSessionDiscovery: { _ in
                let currentSessionID = sessionID.load()
                return .success([DiscoveredTmuxSession(
                    name: "retry",
                    windowCount: 1,
                    serverPID: "101",
                    sessionID: currentSessionID,
                    createdAt: currentSessionID == "$1" ? "1001" : "2002",
                    activeWindowSize: TmuxGridSize(columns: 100, rows: 30),
                    previewClientSize: TmuxGridSize(columns: 100, rows: 31),
                    managed: false
                )])
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            resolutionCount.load() == 1
                && model.retainedBorrowedTmuxPresentationCount == 0
        }

        sessionID.withLock { $0 = "$2" }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            resolutionCount.load() == 2
                && model.retainedBorrowedTmuxPresentationCount == 1
                && surfaceStore.requestCount == 1
        }

        #expect(surfaceStore.lastConfiguration?.command?.contains(
            "ignore-size"
        ) == true)
        await model.shutdown()
    }

    @Test("Always Live detaches unavailable identity and recovers a replacement")
    @MainActor
    func alwaysLiveDetachesUnavailableIdentity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionID = LockedValue("$1")
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "identity-retry"
        )
        let splitter = TmuxPaneSplitter { _, _, command in
            guard command.contains(
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
            ) else { return (0, "") }
            let currentSessionID = sessionID.load()
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t101\t789\t321"
                    + "\t/dev/ttys001\t\(currentSessionID)"
                    + "\t\(currentSessionID == "$1" ? "1001" : "2002")"
                    + "\t%9\n"
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            tmuxSessionDiscovery: { _ in
                let currentSessionID = sessionID.load()
                return .success([DiscoveredTmuxSession(
                    name: "identity-retry",
                    windowCount: 1,
                    serverPID: "101",
                    sessionID: currentSessionID,
                    createdAt: currentSessionID == "$1" ? "1001" : "2002",
                    activeWindowSize: TmuxGridSize(columns: 100, rows: 30),
                    previewClientSize: TmuxGridSize(columns: 100, rows: 31),
                    managed: false
                )])
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxPresentationCount == 1
        }
        let initialHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        model.tmuxAttachedSessionIdentityBecameUnavailable(initialHandle)

        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(surfaceStore.removedKeys.count == 1)

        sessionID.withLock { $0 = "$2" }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxPresentationCount == 1
                && model.retainedBorrowedTmuxHandle(for: selection)
                != initialHandle
        }

        await model.shutdown()
    }

    @Test("stale Always Live promotion cannot activate after navigation")
    @MainActor
    func staleAlwaysLivePromotionRestoresPreviewSizing() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let promotionStarted = LockedValue(false)
        let restoreCount = LockedValue(0)
        let releasePromotion = DispatchSemaphore(value: 0)
        defer { releasePromotion.signal() }
        let session = DiscoveredTmuxSession(
            name: "build",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let splitter = TmuxPaneSplitter { _, _, command in
            if command.contains("'!ignore-size'") {
                promotionStarted.withLock { $0 = true }
                releasePromotion.wait()
                return (0, "")
            }
            if command.contains("ignore-size"),
               !command.contains("!ignore-size") {
                restoreCount.withLock { $0 += 1 }
                return (0, "")
            }
            guard command.contains(
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
            ) else { return (0, "") }
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t101\t789\t321\t/dev/ttys001\t$1\t1001\t%9\n"
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }
        model.openBorrowedTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: session.name
        ))
        await waitUntilMainActor { promotionStarted.load() }

        model.selectFromUser(WorkspaceSelection(
            selectedHostID: environment.host.id
        ))
        releasePromotion.signal()
        await waitUntilMainActor { restoreCount.load() == 1 }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(surfaceStore.surface.clearPreviewGridCount == 2)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @Test("reopening during stale promotion restoration serializes sizing")
    @MainActor
    func reopeningDuringPromotionRestorationSerializesSizing() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let promotionCount = LockedValue(0)
        let restoreStarted = LockedValue(false)
        let restoreFinished = LockedValue(false)
        let releasePromotion = DispatchSemaphore(value: 0)
        let releaseRestore = DispatchSemaphore(value: 0)
        defer {
            releasePromotion.signal()
            releaseRestore.signal()
        }
        let session = DiscoveredTmuxSession(
            name: "build",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let splitter = TmuxPaneSplitter { _, _, command in
            if command.contains("'!ignore-size'") {
                promotionCount.withLock { $0 += 1 }
                if promotionCount.load() == 1 {
                    releasePromotion.wait()
                }
                return (0, "")
            }
            if command.contains("ignore-size"),
               !command.contains("!ignore-size") {
                restoreStarted.withLock { $0 = true }
                releaseRestore.wait()
                restoreFinished.withLock { $0 = true }
                return (0, "")
            }
            guard command.contains(
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
            ) else { return (0, "") }
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t101\t789\t321\t/dev/ttys001\t$1\t1001\t%9\n"
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: session.name
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { promotionCount.load() == 1 }

        model.selectFromUser(WorkspaceSelection(
            selectedHostID: environment.host.id
        ))
        releasePromotion.signal()
        await waitUntilMainActor { restoreStarted.load() }

        model.openBorrowedTmuxSession(selection)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(promotionCount.load() == 1)

        releaseRestore.signal()
        await waitUntilMainActor { restoreFinished.load() }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(promotionCount.load() == 2)
        #expect(surfaceStore.surface.clearPreviewGridCount == 4)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @Test("failed stale promotion restoration detaches the hidden client")
    @MainActor
    func failedStalePromotionRestorationDetachesClient() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let promotionStarted = LockedValue(false)
        let releasePromotion = DispatchSemaphore(value: 0)
        defer { releasePromotion.signal() }
        let session = DiscoveredTmuxSession(
            name: "build",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let splitter = TmuxPaneSplitter { _, _, command in
            if command.contains("'!ignore-size'") {
                promotionStarted.withLock { $0 = true }
                releasePromotion.wait()
                return (0, "")
            }
            if command.contains("ignore-size"),
               !command.contains("!ignore-size") {
                return (1, "restore rejected")
            }
            guard command.contains(
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
            ) else { return (0, "") }
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t101\t789\t321\t/dev/ttys001\t$1\t1001\t%9\n"
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: splitter,
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }
        model.openBorrowedTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: session.name
        ))
        await waitUntilMainActor { promotionStarted.load() }

        model.selectFromUser(WorkspaceSelection(
            selectedHostID: environment.host.id
        ))
        releasePromotion.signal()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxPresentationCount == 0
                && surfaceStore.removedKeys.count == 1
        }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.previewableTmuxSessionIDs.isEmpty)
        model.refreshTmuxSessionDiscovery()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(surfaceStore.requestCount == 1)
        await model.shutdown()
    }

    @Test("Always Live promotes an opened client to normal sizing in place")
    @MainActor
    func alwaysLiveConnectsEveryDiscoveredSession() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let mode = CurrentValueSubject<SessionPreviewMode, Never>(.alwaysLive)
        let previewCoordinator = TmuxSessionPreviewCoordinator(
            mode: .alwaysLive,
            budget: LivePreviewBudget(limit: 0),
            capture: { _, _ in nil }
        )
        let sessions = ["build", "review"].enumerated().map { index, name in
            DiscoveredTmuxSession(
                name: name,
                windowCount: index + 1,
                serverPID: "101",
                sessionID: "$\(index + 1)",
                createdAt: "100\(index)",
                activeWindowSize: TmuxGridSize(
                    columns: 120 + index * 20,
                    rows: 36 + index * 4
                ),
                previewClientSize: TmuxGridSize(
                    columns: 120 + index * 20,
                    rows: 37 + index * 4
                ),
                managed: false
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport
                .previewPaneSplitter(identity: TmuxSessionIdentity(
                    serverPID: "101",
                    sessionID: "$1",
                    createdAt: "1000"
                )),
            tmuxSessionDiscovery: { _ in .success(sessions) },
            sessionPreviewCoordinator: previewCoordinator,
            sessionPreviewModePublisher: mode.eraseToAnyPublisher()
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxPresentationCount == 2
                && surfaceStore.requestCount == 2
        }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.previewableTmuxSessionIDs.count == 2)
        #expect(surfaceStore.lastConfiguration?.command?.contains(
            "ignore-size"
        ) == true)
        #expect(model.snapshot.host(id: environment.host.id)?
            .tmuxSessions.map(\.activeWindowSize) == [
                TmuxGridSize(columns: 120, rows: 36),
                TmuxGridSize(columns: 140, rows: 40),
            ])

        let opened = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "build"
        )
        model.openBorrowedTmuxSession(opened)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSelection == opened
                && surfaceStore.surface.clearPreviewGridCount == 2
        }

        #expect(surfaceStore.requestCount == 2)
        #expect(surfaceStore.removedKeys.isEmpty)

        mode.send(.live)
        await waitUntilMainActor {
            model.retainedBorrowedTmuxPresentationCount == 1
        }

        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @Test("restoration promotes a policy-owned preview client before activation")
    @MainActor
    func restorationPromotesAlwaysLiveClient() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let session = DiscoveredTmuxSession(
            name: "review",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport
                .previewPaneSplitter(identity: TmuxSessionIdentity(
                    serverPID: "101",
                    sessionID: "$1",
                    createdAt: "1001"
                )),
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }
        #expect(surfaceStore.lastConfiguration?.command?.contains(
            "ignore-size"
        ) == true)

        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(hostKey: environment.host.configKey),
            tmux: .init(
                hostKey: environment.host.configKey,
                sessionName: session.name,
                socketName: nil,
                owner: .unbound
            )
        ))
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSelection?.name == session.name
                && surfaceStore.surface.clearPreviewGridCount == 2
        }

        #expect(surfaceStore.requestCount == 1)
        #expect(surfaceStore.removedKeys.isEmpty)
        await model.shutdown()
    }

    @Test("Always Live leaves a closed client detached until identity changes")
    @MainActor
    func alwaysLiveClosedClientRelaunchesOnlyForNewIdentity() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let discoveries = Counter()
        let sessionID = LockedValue("$1")
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                _ = discoveries.increment()
                return .success([
                    DiscoveredTmuxSession(
                        name: "review",
                        windowCount: 1,
                        serverPID: "101",
                        sessionID: sessionID.load(),
                        createdAt: sessionID.load() == "$1"
                            ? "1001"
                            : "2002",
                        activeWindowSize: TmuxGridSize(
                            columns: 120,
                            rows: 36
                        ),
                        previewClientSize: TmuxGridSize(
                            columns: 120,
                            rows: 37
                        ),
                        managed: false
                    ),
                ])
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            surfaceStore.requestCount == 1
                && !surfaceStore.surface.closeObservers.isEmpty
        }

        surfaceStore.surface.closeObservers.values.first?(false, 0)
        await waitUntilMainActor { discoveries.count >= 2 }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(surfaceStore.requestCount == 1)

        sessionID.withLock { $0 = "$2" }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor { surfaceStore.requestCount == 2 }
        #expect(surfaceStore.removedKeys.count == 1)
        await model.shutdown()
    }

    @Test("removing a preview client preserves unrelated pending restoration")
    @MainActor
    func previewRemovalPreservesPendingRestoration() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let session = DiscoveredTmuxSession(
            name: "review",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .success([session]),
            .success([]),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }
        let pending = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(hostKey: "unavailable-host"),
            tmux: nil
        )
        model.beginRestoration(pending)

        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            discoveries.count == 2
                && model.retainedBorrowedTmuxPresentationCount == 0
        }

        #expect(model.restorationState(windowID: pending.windowID) == pending)
        await model.shutdown()
    }

    @Test("Always Live waits for a display before creating terminal surfaces")
    @MainActor
    func alwaysLiveWaitsForDisplayBeforeCreatingSurfaces() async throws {
        let environment = try setupStandardEnvironment()
        let displays = Mutex(0)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let mode = CurrentValueSubject<SessionPreviewMode, Never>(.alwaysLive)
        let session = DiscoveredTmuxSession(
            name: "build",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 120, rows: 36),
            previewClientSize: TmuxGridSize(columns: 120, rows: 37),
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            activeDisplayCount: { displays.withLock { $0 } },
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            ),
            sessionPreviewModePublisher: mode.eraseToAnyPublisher()
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxPresentationCount == 1
                && model.snapshot.host(id: environment.host.id)?
                .tmuxInventoryIsAuthoritative == true
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(surfaceStore.requestCount == 0)

        displays.withLock { $0 = 1 }
        model.handleDisplayParametersChanged()
        await waitUntilMainActor { surfaceStore.requestCount == 1 }

        await model.shutdown()
    }

    @Test("Always Live does not attach Windows psmux sessions")
    @MainActor
    func alwaysLiveExcludesWindowsSessions() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].platform = .windows
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let session = DiscoveredTmuxSession(
            name: "windows-work",
            windowCount: 1,
            createdAt: "1001",
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("C:\\tools\\psmux.exe")
            },
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?
                .tmuxInventoryIsAuthoritative == true
        }

        #expect(model.snapshot.host(id: environment.host.id)?
            .tmuxSessions.map(\.name) == [session.name])
        #expect(model.retainedBorrowedTmuxPresentationCount == 0)
        #expect(model.previewableTmuxSessionIDs.isEmpty)
        #expect(surfaceStore.requestCount == 0)
        await model.shutdown()
    }

    @Test("Always Live excludes tmux clients without safe identity support")
    @MainActor
    func alwaysLiveExcludesUnsupportedTmuxBeforeLaunch() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let resolutionCount = LockedValue(0)
        let session = DiscoveredTmuxSession(
            name: "legacy",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 100, rows: 30),
            previewClientSize: TmuxGridSize(columns: 100, rows: 31),
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                resolutionCount.withLock { $0 += 1 }
                return successfulTmuxResolution(
                    "/usr/bin/tmux",
                    version: "tmux 3.3a"
                )
            },
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            resolutionCount.load() == 1
                && model.retainedBorrowedTmuxPresentationCount == 0
        }
        #expect(surfaceStore.requestCount == 0)

        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: session.name
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSelection == selection
                && surfaceStore.requestCount == 1
        }

        #expect(surfaceStore.lastConfiguration?.command?.contains(
            "ignore-size"
        ) == false)
        await model.shutdown()
    }

    @Test("failed Always Live setup does not strand a later manual open")
    @MainActor
    func alwaysLiveProvisioningFailureAllowsManualRetry() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let resolutionCount = LockedValue(0)
        let session = DiscoveredTmuxSession(
            name: "retry",
            windowCount: 1,
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1001",
            activeWindowSize: TmuxGridSize(columns: 100, rows: 30),
            previewClientSize: TmuxGridSize(columns: 100, rows: 31),
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                let attempt = resolutionCount.load()
                resolutionCount.withLock { $0 += 1 }
                return attempt == 0
                    ? .failure(.notFound(shell: "/bin/zsh"))
                    : successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in .success([session]) },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            resolutionCount.load() == 1
                && model.retainedBorrowedTmuxPresentationCount == 0
        }

        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: session.name
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return resolutionCount.load() == 2
                && model.activeBorrowedTmuxSelection == selection
                && surfaceStore.requestCount == 1
        }

        #expect(surfaceStore.lastConfiguration?.command?.contains(
            "ignore-size"
        ) == false)
        await model.shutdown()
    }

    @Test("application activation does not refresh tmux inventory")
    @MainActor
    func applicationActivationDoesNotRefreshTmuxInventory() async throws {
        let environment = try setupStandardEnvironment()
        let discoveries = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            tmuxSessionDiscovery: { _ in
                _ = discoveries.increment()
                return .success([])
            }
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { discoveries.count == 1 }

        model.handleApplicationDidBecomeActiveForResourceMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        #expect(discoveries.count == 1)
        await model.shutdown()
    }

    @Test("failed tmux refresh hides a retained worktree window count")
    @MainActor
    func failedTmuxRefreshHidesRetainedWorktreeWindowCount() async throws {
        let environment = try setupStandardEnvironment()
        let sessionName = "kwt-wt-ghosthub-main-12345678"
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = sessionName
        let discoveries = TmuxDiscoveryResultQueue([
            .success([
                DiscoveredTmuxSession(
                    name: sessionName,
                    windowCount: 3,
                    createdAt: "1721552400",
                    managed: true
                ),
            ]),
            .failure(.shellFailed(status: 1)),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() }
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            WorkspaceSidebarModel.sections(in: model.snapshot)[0]
                .projects[0].worktreeRows[0]
                .worktreeStatus?.tmuxWindowCount == 3
        }

        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            discoveries.count == 2
                && WorkspaceSidebarModel.sections(in: model.snapshot)[0]
                .projects[0].worktreeRows[0]
                .worktreeStatus?.tmuxWindowCount == nil
        }

        let host = try #require(model.snapshot.host(id: environment.host.id))
        #expect(host.lastKnownReachable)
        #expect(host.tmuxSessions.first?.windows.count == 3)
        #expect(
            WorkspaceSidebarModel.sections(in: model.snapshot)[0]
                .projects[0].worktreeRows[0]
                .worktreeStatus?.tmuxWindowCount == nil
        )
        await model.shutdown()
    }

    @Test("failed creation reconciliation hides a retained worktree window count")
    @MainActor
    func failedCreationReconciliationHidesRetainedWorktreeWindowCount()
        async throws {
        let environment = try setupStandardEnvironment()
        let sessionName = "kwt-wt-project-main-12345678"
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = sessionName
        let discoveries = Counter()
        let rediscoveryGate = BlockingGate()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        defer { rediscoveryGate.release() }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                switch discoveries.increment() {
                case 1:
                    return .success([
                        DiscoveredTmuxSession(
                            name: sessionName,
                            windowCount: 3,
                            createdAt: "1721552400",
                            managed: true
                        ),
                    ])
                case 2:
                    return .failure(.shellFailed(status: 1))
                default:
                    rediscoveryGate.wait()
                    return .failure(.shellFailed(status: 1))
                }
            },
            createdSessionDiscoveryDelays: [.zero]
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            WorkspaceSidebarModel.sections(in: model.snapshot)[0]
                .projects[0].worktreeRows[0]
                .worktreeStatus?.tmuxWindowCount == 3
        }

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { rediscoveryGate.didStart }

        #expect(
            WorkspaceSidebarModel.sections(in: model.snapshot)[0]
                .projects[0].worktreeRows[0]
                .worktreeStatus?.tmuxWindowCount == nil
        )
        rediscoveryGate.release()
        await model.shutdown()
    }

    @Test("successful creation reconciliation restores host discovery state")
    @MainActor
    func successfulCreationReconciliationRestoresHostDiscoveryState()
        async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let discoveries = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                _ = discoveries.increment()
                return .success([
                    DiscoveredTmuxSession(
                        name: "created-work",
                        windowCount: 2,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            },
            createdSessionDiscoveryDelays: [.zero]
        )

        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "created-work"
        )
        model.createTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            guard discoveries.count == 1,
                  let host = model.snapshot.host(
                      id: environment.remoteHost.id
                  )
            else { return false }
            return host.lastSeenAt != nil
                && host.tmuxInventoryIsAuthoritative
                && host.tmuxSessions.first(where: {
                    $0.name == "created-work"
                })?.windows.count == 2
        }

        let host = try #require(
            model.snapshot.host(id: environment.remoteHost.id)
        )
        #expect(host.lastKnownReachable)
        #expect(host.lastSeenAt != nil)
        #expect(host.tmuxInventoryIsAuthoritative)
        #expect(host.tmuxSessions.first(where: {
            $0.name == "created-work"
        })?.windows.count == 2)
        await model.shutdown()
    }

    @Test("failed creation reconciliation marks a lost host offline")
    @MainActor
    func failedCreationReconciliationMarksLostHostOffline() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let discoveries = Counter()
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "ssh: connect to host host-a.example: Network is unreachable"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                _ = discoveries.increment()
                return .failure(.sshConnectionFailed(
                    host: "Host A",
                    classification: transport
                ))
            },
            createdSessionDiscoveryDelays: [.zero]
        )

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "created-work"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            discoveries.count == 1
                && model.snapshot.host(id: environment.remoteHost.id)?
                .lastKnownReachable == false
        }

        let host = try #require(
            model.snapshot.host(id: environment.remoteHost.id)
        )
        #expect(!host.lastKnownReachable)
        #expect(!host.tmuxInventoryIsAuthoritative)
        await model.shutdown()
    }

    @Test("older creation failure cannot overwrite newer discovery")
    @MainActor
    func olderCreationFailureCannotOverwriteNewerDiscovery() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let calls = Counter()
        let creationGate = BlockingGate()
        let recoveryGate = BlockingGate()
        let creationCompleted = Counter()
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "ssh: connect to host host-a.example: Network is unreachable"
        )
        let newerSession = DiscoveredTmuxSession(
            name: "newer-session",
            windowCount: 2,
            createdAt: "1721552400",
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { host in
                guard host.isRemote else { return .success([]) }
                switch calls.increment() {
                case 1:
                    creationGate.wait()
                    _ = creationCompleted.increment()
                    return .failure(.sshConnectionFailed(
                        host: "Host A",
                        classification: transport
                    ))
                case 2:
                    return .success([newerSession])
                default:
                    recoveryGate.wait()
                    return .success([newerSession])
                }
            },
            createdSessionDiscoveryDelays: [.zero]
        )
        defer {
            creationGate.release()
            recoveryGate.release()
        }

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "created-work"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { creationGate.didStart }

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            guard calls.count >= 2,
                  let host = model.snapshot.host(
                      id: environment.remoteHost.id
                  )
            else { return false }
            return host.lastKnownReachable
                && host.tmuxInventoryIsAuthoritative
                && host.tmuxSessions.contains { $0.name == newerSession.name }
        }

        creationGate.release()
        await waitUntilMainActor {
            creationCompleted.count == 1
                && calls.count >= 3
        }

        let host = try #require(
            model.snapshot.host(id: environment.remoteHost.id)
        )
        #expect(calls.count == 3)
        #expect(host.lastKnownReachable)
        #expect(host.tmuxInventoryIsAuthoritative)
        #expect(host.tmuxSessions.contains { $0.name == newerSession.name })

        recoveryGate.release()
        await model.shutdown()
    }

    @Test("older creation failure cannot overwrite newer reconnect")
    @MainActor
    func olderCreationFailureCannotOverwriteNewerReconnect() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let calls = Counter()
        let creationGate = BlockingGate()
        let creationCompleted = Counter()
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "ssh: connect to host host-a.example: Network is unreachable"
        )
        let releaseSession = DiscoveredTmuxSession(
            name: "release-work",
            windowCount: 2,
            createdAt: "1721552400",
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { host in
                guard host.isRemote else { return .success([]) }
                switch calls.increment() {
                case 1:
                    creationGate.wait()
                    _ = creationCompleted.increment()
                    return .failure(.sshConnectionFailed(
                        host: "Host A",
                        classification: transport
                    ))
                default:
                    return .success([releaseSession])
                }
            },
            createdSessionDiscoveryDelays: [.zero],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        defer { creationGate.release() }

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "created-work"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { creationGate.didStart }
        let createdObserverIDs = Set(
            surfaceStore.surface.closeObservers.keys
        )

        let reconnectSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: releaseSession.name
        )
        model.openBorrowedTmuxSession(reconnectSelection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let reconnectObserverID = try #require(
            Set(surfaceStore.surface.closeObservers.keys)
                .subtracting(createdObserverIDs).first
        )
        let reconnectObserver = try #require(
            surfaceStore.surface.closeObservers[reconnectObserverID]
        )
        reconnectObserver(false, 255)

        await waitUntilMainActor {
            guard calls.count >= 2,
                  surfaceStore.requestCount == 3,
                  model.activeBorrowedTmuxSessionIsConnected,
                  let host = model.snapshot.host(
                      id: environment.remoteHost.id
                  )
            else { return false }
            return host.lastKnownReachable
                && host.tmuxInventoryIsAuthoritative
                && host.tmuxSessions.first(where: {
                    $0.name == releaseSession.name
                })?.windows.count == 2
        }

        creationGate.release()
        await waitUntilMainActor {
            creationCompleted.count == 1
                && model.exhaustedCreatedTmuxSessionCount == 1
        }

        let host = try #require(
            model.snapshot.host(id: environment.remoteHost.id)
        )
        #expect(host.lastKnownReachable)
        #expect(host.tmuxInventoryIsAuthoritative)
        #expect(host.tmuxSessions.first(where: {
            $0.name == releaseSession.name
        })?.windows.count == 2)
        await model.shutdown()
    }

    @Test("superseded final creation probe triggers cleanup discovery")
    @MainActor
    func supersededFinalCreationProbeTriggersCleanupDiscovery() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let calls = Counter()
        let initialCreationGate = BlockingGate()
        let finalCreationGate = BlockingGate()
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "ssh: connect to host host-a.example: Network is unreachable"
        )
        let newerSession = DiscoveredTmuxSession(
            name: "newer-session",
            windowCount: 2,
            createdAt: "1721552400",
            managed: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { host in
                guard host.isRemote else { return .success([]) }
                switch calls.increment() {
                case 1:
                    initialCreationGate.wait()
                    return .failure(.sshConnectionFailed(
                        host: "Host A",
                        classification: transport
                    ))
                case 2:
                    return .failure(.sshConnectionFailed(
                        host: "Host A",
                        classification: transport
                    ))
                case 3:
                    finalCreationGate.wait()
                    return .failure(.sshConnectionFailed(
                        host: "Host A",
                        classification: transport
                    ))
                default:
                    return .success([newerSession])
                }
            },
            createdSessionDiscoveryDelays: [.zero]
        )
        defer {
            initialCreationGate.release()
            finalCreationGate.release()
        }

        let createdSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "created-work"
        )
        model.createTmuxSession(createdSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { initialCreationGate.didStart }

        model.closeBorrowedTmuxSession(createdSelection)
        await waitUntilMainActor { finalCreationGate.didStart }

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            guard calls.count >= 4,
                  let host = model.snapshot.host(
                      id: environment.remoteHost.id
                  )
            else { return false }
            return host.lastKnownReachable
                && host.tmuxInventoryIsAuthoritative
                && host.tmuxSessions.contains { $0.name == newerSession.name }
        }

        finalCreationGate.release()
        await waitUntilMainActor {
            calls.count >= 5 && model.pendingCreatedTmuxSessionCount == 0
        }

        let host = try #require(
            model.snapshot.host(id: environment.remoteHost.id)
        )
        #expect(calls.count >= 5)
        #expect(model.exhaustedCreatedTmuxSessionCount == 0)
        #expect(host.lastKnownReachable)
        #expect(host.tmuxInventoryIsAuthoritative)
        #expect(host.tmuxSessions.map(\.name) == [newerSession.name])

        await model.shutdown()
    }

    @Test("local tmux inventory publishes while a remote probe is blocked")
    @MainActor
    func localTmuxInventoryPublishesBeforeRemoteCompletes() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let remoteGate = BlockingGate()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            tmuxSessionDiscovery: { host in
                guard host.isRemote else {
                    return .success([
                        DiscoveredTmuxSession(
                            name: "local-fast",
                            windowCount: 1,
                            createdAt: "1721552400",
                            managed: false
                        ),
                    ])
                }
                remoteGate.wait()
                return .success([])
            }
        )

        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { remoteGate.didStart }
        await waitUntilMainActor {
            model.snapshot.host(id: environment.localHostID)?
                .tmuxSessions.map(\.name) == ["local-fast"]
        }
        let localSessions = model.snapshot.host(
            id: environment.localHostID
        )?.tmuxSessions.map(\.name)

        remoteGate.release()
        #expect(localSessions == ["local-fast"])
        await model.shutdown()
    }

    @Test("local kwt inventory publishes while a remote load is blocked")
    @MainActor
    func localKwtInventoryPublishesBeforeRemoteCompletes() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let remoteGate = BlockingGate()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { host in
                guard host.isRemote else {
                    return KwtHostInventory(projects: [])
                }
                remoteGate.wait()
                return KwtHostInventory(projects: [])
            }
        )

        model.startKwtInventory()
        await waitUntilMainActor { remoteGate.didStart }
        await waitUntilMainActor {
            model.snapshot.projects.allSatisfy {
                $0.hostID != environment.localHostID
            }
        }
        let hasLocalProject = model.snapshot.projects.contains {
            $0.hostID == environment.localHostID
        }

        remoteGate.release()
        #expect(!hasLocalProject)
        await model.shutdown()
    }

    @Test("workspace refresh includes exe.dev inventory")
    @MainActor
    func workspaceRefreshIncludesExeInventory() async throws {
        let environment = try setupStandardEnvironment()
        let exeRefreshes = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            refreshExeHosts: {
                _ = exeRefreshes.increment()
            }
        )

        model.refreshWorkspaceInventory()

        #expect(exeRefreshes.count == 1)
        await model.shutdown()
    }

    @Test("inventory refresh completion waits for kwt and tmux")
    @MainActor
    func inventoryRefreshCompletionWaitsForBothSources() async throws {
        let environment = try setupStandardEnvironment()
        let kwtGate = KillGate()
        let kwtCompletions = Counter()
        let tmuxGate = KillGate()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in
                await kwtGate.suspend()
                _ = kwtCompletions.increment()
                return KwtHostInventory(projects: [])
            },
            tmuxSessionDiscovery: { _ in
                await tmuxGate.suspend()
                return .success([])
            },
            startServices: true
        )

        await kwtGate.waitUntilStarted()
        await tmuxGate.waitUntilStarted()
        #expect(!model.isWorkspaceInventoryRefreshComplete)

        await kwtGate.release()
        await waitUntilMainActor(timeout: .seconds(15)) {
            kwtCompletions.count == 1
        }
        #expect(!model.isWorkspaceInventoryRefreshComplete)

        await tmuxGate.release()
        await waitUntilMainActor(timeout: .seconds(15)) {
            model.isWorkspaceInventoryRefreshComplete
        }
        #expect(model.isWorkspaceInventoryRefreshComplete)
        await model.shutdown()
    }

    @MainActor
    @Test("authoritative inventory removal closes retained presentation")
    func authoritativeInventoryRemovalClosesRetainedPresentation() async throws {
        let environment = try setupStandardEnvironment()
        let generation = "0123456789abcdef0123456789abcdef"
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation = generation
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let inventoryRemoved = LockedValue(false)
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in
                KwtHostInventory(projects: [
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: environment.project.scopedKey,
                            name: environment.project.name,
                            path: environment.project.rootPath,
                            lastTouched: nil
                        ),
                        worktrees: inventoryRemoved.load() ? [] : [
                            KwtWorktreeRecord(
                                path: environment.worktree.path,
                                branch: environment.worktree.branch,
                                commitHash: "",
                                isMain: true,
                                createdAt: nil,
                                generation: generation,
                                repository: environment.project.scopedKey,
                                sessionName: "kwt-ghosthub-main",
                                tmuxSocketName: nil
                            ),
                        ],
                        warning: nil
                    ),
                ])
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
                && model.snapshot.worktrees.count == 1
        }
        let worktree = try #require(model.snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)

        inventoryRemoved.withLock { $0 = true }
        model.refreshKwtInventory()

        await waitUntilMainActor {
            model.snapshot.worktree(id: worktree.id) == nil
                && model.retainedBorrowedTmuxPresentationCount == 0
        }
        #expect(surfaceStore.removedKeys.count == 1)
        #expect(model.activeBorrowedTmuxSelection == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("directory unregistration closes its retained presentation")
    func directoryUnregistrationClosesRetainedPresentation() async throws {
        let environment = try setupStandardEnvironment()
        let directoryID = UUID()
        let directoryPath = "/srv/hub"
        let sessionName = "kwt-workspace-dir-hub"
        let inventoryRemoved = LockedValue(false)
        var snapshot = environment.snapshot
        snapshot.directoryWorkspaces = [.init(
            id: directoryID,
            hostID: environment.host.id,
            name: "hub",
            path: directoryPath,
            tmuxSessionName: sessionName,
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
            },
            kwtInventoryLoader: { _ in
                KwtHostInventory(
                    projects: [],
                    directoryWorkspaces: inventoryRemoved.load() ? [] : [
                        .init(
                            name: "hub",
                            path: directoryPath,
                            sessionName: sessionName,
                            sessionLive: true
                        ),
                    ]
                )
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
                && model.snapshot.directoryWorkspaces.count == 1
        }
        let directory = try #require(
            model.snapshot.directoryWorkspace(id: directoryID)
        )
        let tmuxSelection = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )
        model.openBorrowedTmuxSession(tmuxSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        inventoryRemoved.withLock { $0 = true }
        model.refreshKwtInventory()

        await waitUntilMainActor {
            model.snapshot.directoryWorkspaces.isEmpty
                && model.retainedBorrowedTmuxPresentationCount == 0
        }
        #expect(surfaceStore.removedKeys.count == 1)
        #expect(model.activeBorrowedTmuxSelection == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("directory endpoint replacement waits for explicit reselection")
    func directoryEndpointReplacementWaitsForReselection() async throws {
        let environment = try setupStandardEnvironment()
        let directoryID = UUID()
        let directoryPath = "/srv/hub"
        let originalSession = "kwt-workspace-dir-hub"
        let replacementSession = "kwt-workspace-dir-renamed-hub"
        let replacementActive = LockedValue(false)
        var snapshot = environment.snapshot
        snapshot.directoryWorkspaces = [.init(
            id: directoryID,
            hostID: environment.host.id,
            name: "hub",
            path: directoryPath,
            tmuxSessionName: originalSession,
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
            },
            kwtInventoryLoader: { _ in
                KwtHostInventory(
                    projects: [],
                    directoryWorkspaces: [.init(
                        name: "hub",
                        path: directoryPath,
                        sessionName: replacementActive.load()
                            ? replacementSession
                            : originalSession,
                        sessionLive: true
                    )]
                )
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
                && model.snapshot.directoryWorkspaces.count == 1
        }
        var userSelection = model.selection
        userSelection.select(
            .directoryWorkspace(directoryID),
            in: model.snapshot
        )
        model.selectFromUser(userSelection)
        let original = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(original)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        replacementActive.withLock { $0 = true }
        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.snapshot.directoryWorkspace(id: directoryID)?
                .tmuxSessionName == replacementSession
                && model.retainedBorrowedTmuxPresentationCount == 0
        }

        #expect(model.suppressesSelectedWorktreeSessionOpen)
        #expect(surfaceStore.requestCount == 1)

        model.selectFromUser(userSelection)
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        let replacement = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(replacement)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        await model.shutdown()
    }

    @MainActor
    @Test(
        "authoritative inventory enriches missing generation and invalidates changes"
    )
    func authoritativeInventoryReconcilesRetainedGeneration() async throws {
        let environment = try setupStandardEnvironment()
        let firstGeneration = "0123456789abcdef0123456789abcdef"
        let replacementGeneration = "fedcba9876543210fedcba9876543210"
        let publishedGeneration = LockedValue(firstGeneration)
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation = nil
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in
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
                                path: environment.worktree.path,
                                branch: environment.worktree.branch,
                                commitHash: "",
                                isMain: true,
                                createdAt: nil,
                                generation: publishedGeneration.load(),
                                repository: environment.project.scopedKey,
                                sessionName: "kwt-ghosthub-main",
                                tmuxSocketName: nil
                            ),
                        ],
                        warning: nil
                    ),
                ])
            },
            startServices: false
        )
        let initial = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: snapshot.worktrees[0]
            )
        )
        model.openBorrowedTmuxSession(initial)
        let originalHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: initial)
        )

        model.startKwtInventory()
        await waitUntilMainActor {
            model.activeBorrowedTmuxSelection?.worktreeGeneration
                == firstGeneration
        }
        let enriched = try #require(model.activeBorrowedTmuxSelection)
        #expect(
            model.retainedBorrowedTmuxHandle(for: enriched) == originalHandle
        )

        publishedGeneration.withLock { $0 = replacementGeneration }
        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.snapshot.worktrees[0].generation == replacementGeneration
                && model.activeBorrowedTmuxSelection == nil
                && model.retainedBorrowedTmuxPresentationCount == 0
        }
        #expect(model.retainedBorrowedTmuxHandle(for: enriched) == nil)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "authoritative replacement waits for explicit reselection",
        arguments: [
            (
                "kwt-ghosthub-replacement",
                "0123456789abcdef0123456789abcdef"
            ),
        ]
    )
    func authoritativeReplacementWaitsForExplicitReselection(
        replacementName: String,
        replacementGeneration: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        let originalGeneration = "0123456789abcdef0123456789abcdef"
        let replacementActive = LockedValue(false)
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation = originalGeneration
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in
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
                                path: environment.worktree.path,
                                branch: environment.worktree.branch,
                                commitHash: "",
                                isMain: true,
                                createdAt: nil,
                                generation: replacementActive.load()
                                    ? replacementGeneration
                                    : originalGeneration,
                                repository: environment.project.scopedKey,
                                sessionName: replacementActive.load()
                                    ? replacementName
                                    : "kwt-ghosthub-main",
                                tmuxSocketName: nil
                            ),
                        ],
                        warning: nil
                    ),
                ])
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
                && model.snapshot.worktrees.count == 1
        }
        var userSelection = model.selection
        userSelection.select(
            .worktree(environment.worktree.id),
            in: model.snapshot
        )
        model.selectFromUser(userSelection)
        let original = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(original)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        replacementActive.withLock { $0 = true }
        model.refreshKwtInventory()
        await waitUntilMainActor {
            guard let worktree = model.snapshot.worktree(
                id: environment.worktree.id
            ) else { return false }
            return worktree.tmuxSessionName == replacementName
                && worktree.generation == replacementGeneration
                && model.retainedBorrowedTmuxPresentationCount == 0
        }

        #expect(model.suppressesSelectedWorktreeSessionOpen)
        #expect(surfaceStore.requestCount == 1)

        model.selectFromUser(userSelection)
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        let replacement = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: userSelection,
                in: model.snapshot
            )
        )
        model.openBorrowedTmuxSession(replacement)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        await model.shutdown()
    }

    enum CreationKwtFailurePhase: CaseIterable, Sendable {
        case command
        case inventoryRefresh
    }

    enum ProjectRemovalReconciliationCase: CaseIterable, Sendable {
        case confirmedPresent
        case confirmedAbsent
        case unavailable
        case globalWarning
        case projectWarning
        case pathDrift
    }

    enum QuarantinedProjectRegistrationChange: CaseIterable, Sendable {
        case sameIdentityMoved
        case replacementAtOriginalPath
    }

    enum ProjectRemovalHostDeletionPhase: CaseIterable, Sendable {
        case unregistration
        case reconciliation
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    final class BlockingGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var started = false

        func wait() {
            lock.lock()
            started = true
            lock.unlock()
            semaphore.wait()
        }

        var didStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        func release() {
            semaphore.signal()
        }
    }

    actor KillGate {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            started = true
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    final class KwtAvailabilityState: @unchecked Sendable {
        private let lock = NSLock()
        private let remoteInventory: KwtHostInventory
        private var remoteKwtAvailable = true
        private var remoteLoads = 0

        init(remoteInventory: KwtHostInventory) {
            self.remoteInventory = remoteInventory
        }

        func load(_ host: CommandHost) throws -> KwtHostInventory {
            guard host.isRemote else {
                return KwtHostInventory(projects: [])
            }
            lock.lock()
            remoteLoads += 1
            let isAvailable = remoteKwtAvailable
            lock.unlock()
            guard isAvailable else {
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: 127
                )
            }
            return remoteInventory
        }

        func markRemoteKwtUnavailable() {
            lock.lock()
            remoteKwtAvailable = false
            lock.unlock()
        }

        func markRemoteKwtAvailable() {
            lock.lock()
            remoteKwtAvailable = true
            lock.unlock()
        }

        var remoteLoadCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return remoteLoads
        }
    }

    final class TmuxReachabilityState: @unchecked Sendable {
        private let lock = NSLock()
        private var remoteReachable = true

        func discover(
            _ host: CommandHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            guard host.isRemote else { return .success([]) }
            lock.lock()
            let isReachable = remoteReachable
            lock.unlock()
            guard isReachable else {
                return .failure(.sshConnectionFailed(
                    host: "build-box",
                    classification: SSHConnectionFailure.classify(
                        status: 255,
                        output: "Network is unreachable"
                    )
                ))
            }
            return .success([
                DiscoveredTmuxSession(
                    name: "docbank",
                    windowCount: 1,
                    createdAt: "1721552400",
                    managed: false
                ),
            ])
        }

        func markRemoteUnreachable() {
            lock.lock()
            remoteReachable = false
            lock.unlock()
        }
    }

    final class DelayedTmuxPathState: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var started = false

        func resolve() -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
            lock.lock()
            started = true
            lock.unlock()
            gate.wait()
            return successfulTmuxResolution("/usr/bin/tmux")
        }

        var didStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        func release() {
            gate.signal()
        }
    }

    final class DiscoveryState: @unchecked Sendable {
        private let lock = NSLock()
        private var failuresRemaining: Int
        private var attempts = 0
        private var startedHosts: [CommandHost] = []
        private let delayedHost: CommandHost?

        init(failuresRemaining: Int, delayedHost: CommandHost? = nil) {
            self.failuresRemaining = failuresRemaining
            self.delayedHost = delayedHost
        }

        func discover(
            _ host: CommandHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            lock.lock()
            attempts += 1
            startedHosts.append(host)
            let shouldFail = failuresRemaining > 0
            if shouldFail {
                failuresRemaining -= 1
            }
            let shouldDelay = host == delayedHost
            lock.unlock()
            if shouldDelay {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if shouldFail {
                return .failure(.shellFailed(status: 255))
            }
            if shouldDelay {
                return .success([
                    DiscoveredTmuxSession(
                        name: "stale-session",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            }
            return .success([])
        }

        func allowSuccess() {
            lock.lock()
            failuresRemaining = 0
            lock.unlock()
        }

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        func hasStarted(on host: CommandHost) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return startedHosts.contains(host)
        }
    }

    final class StaleDiscoveryState: @unchecked Sendable {
        private let lock = NSLock()
        private let firstGate = DispatchSemaphore(value: 0)
        private var calls = 0
        private var didStartFirst = false

        func discover(
            _ host: CommandHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            lock.lock()
            calls += 1
            let call = calls
            if call == 1 {
                didStartFirst = true
            }
            lock.unlock()
            if call == 1 {
                firstGate.wait()
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

        var firstStarted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didStartFirst
        }

        func releaseFirst() {
            firstGate.signal()
        }
    }

    final class CancellableProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var cancelled = false

        func discover(
            _ host: CommandHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            .failure(waitForCancellation())
        }

        func probe(
            _ target: TmuxSessionProbeTarget
        ) -> Result<Bool, TmuxBinaryError> {
            .failure(waitForCancellation())
        }

        private func waitForCancellation() -> TmuxBinaryError {
            lock.lock()
            started = true
            lock.unlock()
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.001)
            }
            lock.lock()
            cancelled = true
            lock.unlock()
            return .probeCancelled(shell: "test")
        }

        var didStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        var didCancel: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    final class ProfileReconciliationDiscoveryState:
        @unchecked Sendable {
        private let lock = NSLock()
        private let sessionName: String
        private var calls = 0
        private var firstStarted = false
        private var firstCancelled = false

        init(sessionName: String) {
            self.sessionName = sessionName
        }

        func discover(
            _ host: CommandHost
        ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
            lock.lock()
            calls += 1
            let call = calls
            if call == 1 {
                firstStarted = true
            }
            lock.unlock()

            switch call {
            case 1:
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                lock.lock()
                firstCancelled = true
                lock.unlock()
                return .failure(.probeCancelled(shell: host.displayName))
            case 2:
                return .success([
                    DiscoveredTmuxSession(
                        name: sessionName,
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            default:
                return .success([])
            }
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        var didStartFirst: Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstStarted
        }

        var didCancelFirst: Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstCancelled
        }
    }

}
