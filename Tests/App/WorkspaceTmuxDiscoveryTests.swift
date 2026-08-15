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
    private static let probeNonce = "TEST-NONCE"

    private static func previewPaneSplitter(
        identity: TmuxSessionIdentity
    ) -> TmuxPaneSplitter {
        TmuxPaneSplitter { _, _, command in
            guard command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY")
            else { return (0, "") }
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t\(identity.serverPID)\t789\t321"
                    + "\t/dev/ttys001\t\(identity.sessionID)"
                    + "\t\(identity.createdAt)\t%9\n"
            )
        }
    }

    private static func inventory(
        project: ProjectSummary,
        worktrees: [WorktreeSummary]
    ) -> KwtHostInventory {
        KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil,
                    registrationFingerprint:
                    project.registrationFingerprint
                ),
                worktrees: worktrees.map { worktree in
                    KwtWorktreeRecord(
                        path: worktree.path,
                        branch: worktree.branch,
                        commitHash: "",
                        isMain: worktree.isPrimary,
                        createdAt: worktree.createdAt,
                        generation: worktree.generation,
                        repository: project.scopedKey,
                        sessionName: worktree.tmuxSessionName ?? "",
                        tmuxSocketName: worktree.tmuxSocketName
                    )
                },
                warning: nil
            ),
        ])
    }

    private static func probeOutput(
        _ lines: [String],
        startupOutput: String? = nil
    ) -> String {
        ([startupOutput].compactMap { $0 }
            + ["GHOSTHUB_SSH_PROBE_\(probeNonce)_START"]
            + lines
            + ["GHOSTHUB_SSH_PROBE_\(probeNonce)_END", ""])
            .joined(separator: "\n")
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
    @Test("authoritative inventory latches a retained canonical generation")
    func authoritativeInventoryLatchesRetainedGeneration() async throws {
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
                && model.retainedBorrowedTmuxPresentationCount == 0
        }
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
            (
                "kwt-ghosthub-main",
                "fedcba9876543210fedcba9876543210"
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

    private enum CreationKwtFailurePhase: CaseIterable, Sendable {
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

    private final class Counter: @unchecked Sendable {
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

    private final class BlockingGate: @unchecked Sendable {
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

    private actor KillGate {
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

    private final class KwtAvailabilityState: @unchecked Sendable {
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

    private final class TmuxReachabilityState: @unchecked Sendable {
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

    private final class DelayedTmuxPathState: @unchecked Sendable {
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

    private final class DiscoveryState: @unchecked Sendable {
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

    private final class StaleDiscoveryState: @unchecked Sendable {
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

    private final class CancellableProbeState: @unchecked Sendable {
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

    private final class ProfileReconciliationDiscoveryState:
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
        let firstHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: first)
        )

        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        let secondHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: second)
        )

        model.openBorrowedTmuxSession(first)
        model.prepareActiveBorrowedTmuxSurface()

        #expect(model.activeBorrowedTmuxSelection == first)
        #expect(model.retainedBorrowedTmuxHandle(for: first) == firstHandle)
        #expect(firstHandle.surfaceID != secondHandle.surfaceID)
        #expect(model.retainedBorrowedTmuxPresentationCount == 2)
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
            nativeTmuxPaneSplitter: Self.previewPaneSplitter(
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
            nativeTmuxPaneSplitter: Self.previewPaneSplitter(
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
            nativeTmuxPaneSplitter: Self.previewPaneSplitter(
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
            nativeTmuxPaneSplitter: Self.previewPaneSplitter(
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

    @MainActor
    private func launchActiveTmuxSurface(
        _ model: WorkspaceSceneModel,
        store: SceneTmuxSurfaceStoreStub
    ) async {
        await waitUntilMainActor(timeout: .seconds(15)) {
            model.prepareActiveBorrowedTmuxSurface()
            return store.requestCount > 0
        }
    }

    @MainActor
    @Test("transport loss automatically reattaches when the session returns")
    func transportLossAutomaticallyReattaches() async throws {
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "ssh: connect to host build-box port 22: Network is unreachable"
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box",
                classification: transport
            )),
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
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remoteSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(remoteSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("attach-session")
                == true
        )
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'") == false
        )
        await model.shutdown()
    }

    @MainActor
    @Test("no active display holds recovery without probing the host")
    func zeroDisplaysHoldsRecoveryUntilDisplayReturns() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let displays = Mutex(1)
        let probes = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            activeDisplayCount: { displays.withLock { $0 } },
            tmuxSessionDiscovery: { _ in
                probes.withLock { $0 += 1 }
                return .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remoteSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(remoteSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        probes.withLock { $0 = 0 }

        // The lid closes, then the transport dies: recovery must hold rather
        // than burn its one attempt on a surface that cannot be created.
        displays.withLock { $0 = 0 }
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(surfaceStore.requestCount == 1)
        #expect(probes.withLock { $0 } == 0)
        #expect(model.anyTmuxReconnectSupervisorIsRunning)

        // The lid opens.
        displays.withLock { $0 = 1 }
        model.handleDisplayParametersChanged()
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test("retryable surface failure keeps recovering instead of latching")
    func retryableSurfaceFailureKeepsRecovering() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remoteSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(remoteSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        // Displays vanished between the gate and surface creation, so the
        // relaunch fails transiently. Recovery must re-arm, not latch.
        surfaceStore.surface.launchError = SceneSurfaceLaunchError.rejected
        surfaceStore.surface.launchFailureIsRetryable = true
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor { surfaceStore.requestCount == 2 }

        // Not latched: recovery stays armed. `isRunning` is deliberately not
        // asserted — a tmux supervisor stops each time it hands off a relaunch,
        // so it is false at arbitrary moments while recovery is still healthy.
        #expect(model.activeBorrowedTmuxRecoveryState?.isReconnecting == true)

        surfaceStore.surface.launchError = nil
        surfaceStore.surface.launchFailureIsRetryable = false
        await waitUntilMainActor(timeout: .seconds(5)) {
            model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test("recovered surface failure does not excuse a later normal exit")
    func recoveredSurfaceFailureDoesNotExcuseLaterNormalExit() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remoteSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(remoteSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        // A transient surface failure, then a successful reconnect.
        surfaceStore.surface.launchError = SceneSurfaceLaunchError.rejected
        surfaceStore.surface.launchFailureIsRetryable = true
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor { surfaceStore.requestCount == 2 }
        surfaceStore.surface.launchError = nil
        surfaceStore.surface.launchFailureIsRetryable = false
        await waitUntilMainActor(timeout: .seconds(5)) {
            model.activeBorrowedTmuxSessionIsConnected
        }
        let recoveredRequestCount = surfaceStore.requestCount

        // The client now exits normally. That is not a transport failure, so
        // it must be reported rather than retried: the earlier transient
        // failure cannot keep excusing later exits.
        surfaceStore.surface.closeObservers.values.first?(false, 0)
        try await Task.sleep(for: .milliseconds(100))

        #expect(surfaceStore.requestCount == recoveredRequestCount)
        #expect(model.activeBorrowedTmuxRecoveryState?.isReconnecting != true)
        await model.shutdown()
    }

    @MainActor
    @Test("inactive retained presentation continues automatic recovery")
    func inactivePresentationContinuesAutomaticRecovery() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "local-work",
                managed: false,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                if host.isRemote {
                    return .success([
                        DiscoveredTmuxSession(
                            name: "release-work",
                            windowCount: 1,
                            createdAt: nil,
                            managed: false
                        ),
                    ])
                }
                return .success([])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remote = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let local = WorkspaceTmuxSessionSelection(
            hostID: environment.localHostID,
            name: "local-work"
        )
        model.openBorrowedTmuxSession(remote)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let remoteHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: remote)
        )
        let remoteClose = try #require(
            surfaceStore.surface.closeObservers[remoteHandle.id]
        )
        model.openBorrowedTmuxSession(local)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        remoteClose(false, 255)

        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.retainedBorrowedTmuxSessionIsConnected(remote)
        }
        #expect(model.activeBorrowedTmuxSelection == local)
        #expect(model.retainedBorrowedTmuxHandle(for: remote) == remoteHandle)

        model.openBorrowedTmuxSession(remote)
        model.prepareActiveBorrowedTmuxSurface()
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(surfaceStore.requestCount == 3)
        await model.shutdown()
    }

    @MainActor
    @Test("interrupted profile creation never replays its command automatically")
    func interruptedProfileCreationRequiresExplicitRetry() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "codex"
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState == nil
        }

        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(surfaceStore.requestCount == 1)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxRetryRequiresConfirmation)
        #expect(model.activeBorrowedTmuxRetryCommand == "exec codex")

        model.retryBorrowedTmuxSession(selection)
        for _ in 0 ..< 20 {
            model.prepareActiveBorrowedTmuxSurface()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(surfaceStore.requestCount == 1)

        model.retryBorrowedTmuxSessionAfterProfileCommandConfirmation(
            selection
        )
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        #expect(!model.activeBorrowedTmuxRetryRequiresConfirmation)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("exec codex"))
        await model.shutdown()
    }

    @MainActor
    @Test("returning to interrupted profile creation preserves confirmation")
    func returningToInterruptedProfileCreationPreservesConfirmation()
        async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            createdSessionDiscoveryDelays: [
                .milliseconds(10),
                .milliseconds(20),
            ],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "codex"
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "exec codex"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let interruptedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState == nil
        }
        #expect(model.activeBorrowedTmuxRetryRequiresConfirmation)

        let replacement = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(replacement)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        model.openBorrowedTmuxSession(selection)
        #expect(model.activeBorrowedTmuxSelection == selection)
        #expect(model.activeBorrowedTmuxLaunchMode == .create)
        #expect(
            model.retainedBorrowedTmuxHandle(for: selection)
                == interruptedHandle
        )
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        model.prepareActiveBorrowedTmuxSurface()
        try await Task.sleep(for: .milliseconds(100))

        #expect(surfaceStore.requestCount == 2)
        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(model.activeBorrowedTmuxRetryRequiresConfirmation)
        #expect(model.activeBorrowedTmuxRetryCommand == "exec codex")

        model.retryBorrowedTmuxSessionAfterProfileCommandConfirmation(
            selection
        )
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 3
        }
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("exec codex"))
        await model.shutdown()
    }

    @MainActor
    @Test("a pre-launch failure preserves a safe profile command retry")
    func preLaunchFailurePreservesProfileCommand() async throws {
        let environment = try setupStandardEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        surfaceStore.returnsSurface = false
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
        await launchActiveTmuxSurface(model, store: surfaceStore)
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.pendingCreatedTmuxSessionCount == 1)
        #expect(!model.activeBorrowedTmuxRetryRequiresConfirmation)

        surfaceStore.returnsSurface = true
        model.retryBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("exec codex"))
        #expect(!model.activeBorrowedTmuxRetryRequiresConfirmation)
        await model.shutdown()
    }

    @MainActor
    @Test("reconciled profile creation never reruns its command")
    func reconciledProfileCreationDoesNotRerunCommand() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "profile-work"
        )
        let discovery = ProfileReconciliationDiscoveryState(
            sessionName: selection.name
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [.milliseconds(20)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "printf ready"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { discovery.didStartFirst }
        await waitUntilMainActor {
            discovery.didCancelFirst
                && model.pendingCreatedTmuxSessionCount == 0
        }

        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(surfaceStore.requestCount == 1)
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            discovery.count == 3
                && (model.activeBorrowedTmuxSessionIsConfirmedEnded
                    || surfaceStore.requestCount > 1)
        }

        #expect(discovery.count == 3)
        #expect(surfaceStore.requestCount == 1)
        #expect(model.activeBorrowedTmuxLaunchMode == .attach)
        #expect(model.activeBorrowedTmuxSessionIsConfirmedEnded)
        await model.shutdown()
    }

    @MainActor
    @Test("interrupted profile creation attaches when its session is present")
    func interruptedProfileCreationAttachesWhenPresent() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "profile-work"
        )
        let discovery = ProfileReconciliationDiscoveryState(
            sessionName: selection.name
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        model.createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection,
            initialCommand: "printf ready"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { discovery.didStartFirst }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(discovery.didCancelFirst)
        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(model.activeBorrowedTmuxLaunchMode == .attachOnly)
        #expect(surfaceStore.requestCount == 2)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("attach-session"))
        #expect(!command.contains("new-session"))
        #expect(!command.contains("printf ready"))
        await model.shutdown()
    }

    @MainActor
    @Test("cached worktree kwt interruption retries establishment")
    func cachedWorktreeInterruptionRetriesEstablishment() async throws {
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
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == true
        )

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("retryable surface failure relaunches an absent workspace")
    func retryableSurfaceFailureRelaunchesAbsentWorkspace() async throws {
        let environment = try setupRemoteEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionName = "kwt-ghosthub-main"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.launchError = SceneSurfaceLaunchError.rejected
        surfaceStore.surface.launchFailureIsRetryable = true
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        model.reconnectActiveTmuxSessionNow()
        await waitUntilMainActor { surfaceStore.requestCount == 2 }

        surfaceStore.surface.launchError = nil
        surfaceStore.surface.launchFailureIsRetryable = false
        model.reconnectActiveTmuxSessionNow()
        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                || model.activeBorrowedTmuxRecoveryState == nil
        }

        #expect(surfaceStore.requestCount == 3)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("resolver timeout remains retryable")
    func resolverTimeoutRemainsRetryable() async throws {
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
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(discoveries.count == 2)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("default-socket probe deadline preserves reconnecting state")
    func defaultSocketProbeDeadlinePreservesReconnectingState() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let discovery = CancellableProbeState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: discovery.discover,
            tmuxReconnectIntervals: [.seconds(10)],
            tmuxReconnectProbeDeadline: .milliseconds(20)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor { discovery.didCancel }

        #expect(
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        )
        #expect(
            model.snapshot.host(id: environment.remoteHost.id)?
                .lastKnownReachable == true
        )
        #expect(
            model.workspaceInventoryWarningsByHost[
                environment.remoteHost.id
            ] == nil
        )
        await model.shutdown()
    }

    @MainActor
    @Test("creation reconciliation invalidation keeps reconnecting")
    func creationReconciliationInvalidationKeepsReconnecting() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let attempts = Counter()
        let creationGate = BlockingGate()
        let reconnectProbe = CancellableProbeState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                switch attempts.increment() {
                case 1:
                    creationGate.wait()
                case 2:
                    return reconnectProbe.discover(host)
                default:
                    break
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "created-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        defer { creationGate.release() }
        let createdSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "created-work"
        )
        model.createTmuxSession(createdSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let createdObserverIDs = Set(
            surfaceStore.surface.closeObservers.keys
        )
        model.closeBorrowedTmuxSession(createdSelection)
        await waitUntilMainActor { creationGate.didStart }

        let reconnectSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
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
        await waitUntilMainActor { reconnectProbe.didStart }

        creationGate.release()

        await waitUntilMainActor {
            reconnectProbe.didCancel
                && attempts.count == 3
                && surfaceStore.requestCount == 3
                && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(attempts.count == 3)
        #expect(surfaceStore.requestCount == 3)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[
                environment.remoteHost.id
            ] == nil
        )
        #expect(
            model.snapshot.host(id: environment.remoteHost.id)?
                .lastKnownReachable == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("exact probe deadline retries automatically")
    func exactProbeDeadlineRetriesAutomatically() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let attempts = Counter()
        let probe = CancellableProbeState()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxExactSessionProbe: { target in
                switch attempts.increment() {
                case 1:
                    return probe.probe(target)
                default:
                    return .success(true)
                }
            },
            tmuxReconnectIntervals: [.milliseconds(1)],
            tmuxReconnectProbeDeadline: .milliseconds(20)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "protected-work",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            probe.didCancel
                && attempts.count == 2
                && surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(attempts.count == 2)
        #expect(surfaceStore.requestCount == 2)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("stale reconnect discovery cannot mutate a replacement endpoint")
    func staleReconnectDiscoveryCannotMutateReplacementEndpoint()
        async throws {
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
        let discoveryGate = BlockingGate()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                #expect(host == oldTarget)
                discoveryGate.wait()
                return .success([
                    DiscoveredTmuxSession(
                        name: "stale-session",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        defer { discoveryGate.release() }
        model.refreshHosts()
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: remoteHost.id,
            name: "stale-session"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor { discoveryGate.didStart }

        configuredHosts.value = [
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()
        discoveryGate.release()
        try await Task.sleep(for: .milliseconds(100))

        let updatedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        #expect(updatedHost.sshDestination == "wesm@new.example.com")
        #expect(updatedHost.tmuxSessions.isEmpty)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("Reconnect Now interrupts the scene supervisor wait")
    func reconnectNowInterruptsSceneWait() async throws {
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "Network is unreachable"
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box", classification: transport
            )),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work", windowCount: 1,
                    createdAt: nil, managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor { discoveries.count == 1 }

        model.reconnectActiveTmuxSessionNow()

        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }
        await model.shutdown()
    }

    @MainActor
    @Test("default-socket absence ends a confirmed session")
    func defaultSocketAbsenceEndsSession() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConfirmedEnded
        }
        #expect(surfaceStore.requestCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("interrupted establishment clears provisional ended state")
    func interruptedEstablishmentClearsEndedState() async throws {
        let environment = try setupRemoteEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionName = "kwt-ghosthub-main"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("recovery continues when discovery confirms establishment")
    func discoveryConfirmationContinuesEstablishmentRecovery() async throws {
        let environment = try setupRemoteEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let sessionName = "kwt-ghosthub-main"
        let discoveries = TmuxDiscoveryResultQueue([
            .success([]),
            .success([
                DiscoveredTmuxSession(
                    name: sessionName,
                    windowCount: 1,
                    createdAt: nil,
                    managed: true
                ),
            ]),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { discoveries.count == 1 }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            discoveries.count == 2
                && surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(
            surfaceStore.lastConfiguration?.command?
                .contains("attach-session") == true
        )
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == false
        )
        await model.shutdown()
    }

    @MainActor
    @Test("a failed replacement stops promising automatic recovery")
    func failedReplacementStopsAutomaticRecovery() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.launchError = SceneSurfaceLaunchError.rejected

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState?.isReconnecting == true
        }
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxRecoveryState == nil
        }

        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        model.reconnectActiveTmuxSessionNow()
        try await Task.sleep(for: .milliseconds(25))
        #expect(surfaceStore.requestCount == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("protected-socket absence ends without probing through a surface")
    func protectedSocketAbsenceEndsWithoutSurface() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let probes = TmuxExactProbeResultQueue([.success(false)])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxExactSessionProbe: { _ in probes.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "protected-work",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let endedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: selection)
        )
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConfirmedEnded
        }
        #expect(probes.count == 1)
        #expect(surfaceStore.requestCount == 1)

        let local = WorkspaceTmuxSessionSelection(
            hostID: environment.localHostID,
            name: "local-work"
        )
        model.openBorrowedTmuxSession(local)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        model.openBorrowedTmuxSession(selection)
        model.prepareActiveBorrowedTmuxSurface()

        #expect(model.retainedBorrowedTmuxHandle(for: selection) == endedHandle)
        #expect(model.activeBorrowedTmuxSessionIsConfirmedEnded)
        #expect(surfaceStore.requestCount == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("protected kwt interruption retries establishment")
    func protectedKwtInterruptionRetriesEstablishment() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let probes = TmuxExactProbeResultQueue([
            .success(false),
            .success(false),
            .success(false),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxExactSessionProbe: { _ in probes.removeFirst() },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "protected-work",
            worktreePath: "/srv/ghosthub-pr-42",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConnected
        }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(!model.activeBorrowedTmuxSessionIsConfirmedEnded)
        await model.shutdown()
    }

    @MainActor
    @Test("protected recovery stays direct and attach-only")
    func protectedRecoveryUsesAttachOnly() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let probes = TmuxExactProbeResultQueue([.success(true)])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxExactSessionProbe: { _ in probes.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "protected-work",
            socketName: "kwt-pr-0123456789abcdef"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }
        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("attach-session"))
        #expect(command.contains("kwt-pr-0123456789abcdef"))
        #expect(!command.contains(" pr attach "))
        await model.shutdown()
    }

    @MainActor
    @Test("authentication failure pauses and requests native recovery")
    func authenticationFailureRequestsRecovery() async throws {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "Permission denied (publickey,password)."
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box", classification: classification
            )),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            model.sessionConnectionRecoveryRequest != nil
        }
        #expect(
            model.sessionConnectionRecoveryRequest?.hostID
                == environment.remoteHost.id
        )
        guard case .needsAttention(_, true) =
            model.activeBorrowedTmuxRecoveryState
        else {
            Issue.record("Expected reviewable attention state")
            await model.shutdown()
            return
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(discoveries.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("successful SSH recovery resumes its inactive presentation")
    func sshRecoveryResumesInactivePresentation() async throws {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "Permission denied (publickey,password)."
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box", classification: classification
            )),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work", windowCount: 1,
                    createdAt: nil, managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "local-work",
                managed: false,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                host.isRemote ? discoveries.removeFirst() : .success([])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remote = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let local = WorkspaceTmuxSessionSelection(
            hostID: environment.localHostID,
            name: "local-work"
        )
        model.openBorrowedTmuxSession(remote)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let remoteHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: remote)
        )
        surfaceStore.surface.closeObservers[remoteHandle.id]?(false, 255)
        await waitUntilMainActor {
            model.sessionConnectionRecoveryRequest != nil
        }
        let recoveryRequest = try #require(
            model.sessionConnectionRecoveryRequest
        )

        model.openBorrowedTmuxSession(local)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }
        model.resumeSessionReconnectAfterSSHRecovery(recoveryRequest)

        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.retainedBorrowedTmuxSessionIsConnected(remote)
        }
        #expect(model.activeBorrowedTmuxSelection == local)
        #expect(model.retainedBorrowedTmuxHandle(for: remote) == remoteHandle)
        await model.shutdown()
    }

    @MainActor
    @Test("unresolved host does not inherit retained recovery state")
    func unresolvedHostDoesNotInheritRetainedRecoveryState() async throws {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "Permission denied (publickey,password)."
        )
        let environment = try setupRemoteTmuxEnvironment()
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
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                .failure(.sshConnectionFailed(
                    host: "build-box",
                    classification: classification
                ))
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let retained = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(retained)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let retainedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: retained)
        )
        surfaceStore.surface.closeObservers[retainedHandle.id]?(false, 255)
        await waitUntilMainActor {
            model.sessionConnectionRecoveryRequest != nil
        }

        let unresolved = WorkspaceTmuxSessionSelection(
            hostID: unresolvedHost.id,
            name: "unavailable-work"
        )
        model.openBorrowedTmuxSession(unresolved)

        #expect(model.activeBorrowedTmuxSelection == unresolved)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(model.sessionConnectionRecoveryRequest == nil)

        model.openBorrowedTmuxSession(retained)
        #expect(model.sessionConnectionRecoveryRequest?.hostID == retained.hostID)
        guard case .needsAttention(_, true) =
            model.activeBorrowedTmuxRecoveryState
        else {
            Issue.record("Expected retained recovery state")
            await model.shutdown()
            return
        }
        await model.shutdown()
    }

    @MainActor
    @Test("changed host key can reconnect after manual remediation")
    func changedHostKeyRequiresManualRemediation() async throws {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "REMOTE HOST IDENTIFICATION HAS CHANGED!"
        )
        let discoveries = TmuxDiscoveryResultQueue([
            .failure(.sshConnectionFailed(
                host: "build-box", classification: classification
            )),
            .success([
                DiscoveredTmuxSession(
                    name: "release-work", windowCount: 1,
                    createdAt: nil, managed: false
                ),
            ]),
        ])
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in discoveries.removeFirst() },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            model.activeBorrowedTmuxRecoveryState != nil
                && model.activeBorrowedTmuxRecoveryState?.isReconnecting == false
        }
        guard case let .needsAttention(message, false) =
            model.activeBorrowedTmuxRecoveryState
        else {
            Issue.record("Expected manual attention state")
            await model.shutdown()
            return
        }
        #expect(message.contains("known-hosts"))
        #expect(model.sessionConnectionRecoveryRequest == nil)

        model.resumeSessionReconnectAfterSSHRecovery(
            SessionConnectionRecoveryRequest(
                hostID: environment.remoteHost.id,
                message: message
            )
        )
        #expect(
            model.activeBorrowedTmuxRecoveryState == .needsAttention(
                message: message,
                canReviewConnection: false
            )
        )

        model.reconnectActiveTmuxSessionNow()

        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(discoveries.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("clean detach never starts automatic recovery")
    func cleanDetachDoesNotReconnect() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(surfaceStore.requestCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("returning to a cleanly detached retained session does not reopen it")
    func cleanlyDetachedRetainedSessionDoesNotReopen() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remote = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        let local = WorkspaceTmuxSessionSelection(
            hostID: environment.localHostID,
            name: "local-work"
        )
        model.openBorrowedTmuxSession(remote)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let remoteHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: remote)
        )
        surfaceStore.surface.closeObservers[remoteHandle.id]?(false, 0)
        model.openBorrowedTmuxSession(local)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
        }

        model.openBorrowedTmuxSession(remote)
        model.prepareActiveBorrowedTmuxSurface()

        #expect(model.retainedBorrowedTmuxHandle(for: remote) == remoteHandle)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(surfaceStore.requestCount == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("startup publishes existing local tmux sessions")
    func startupPublishesExistingSessions() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { host in
                #expect(host == .local)
                return .success([
                    DiscoveredTmuxSession(
                        name: "docbank",
                        windowCount: 4,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
        }

        let session = try #require(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.first
        )
        #expect(session.windows.count == 4)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "automatic kwt provisioning follows the remote platform policy",
        arguments: [
            (HostPlatform.macOS, true),
            (HostPlatform.linux, true),
            (HostPlatform.windows, false),
        ]
    )
    func automaticKwtProvisioning(
        platform: HostPlatform,
        expected: Bool
    ) async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "remote",
            name: "Remote",
            platform: platform,
            sshDestination: "remote"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let provisioningAttempts = Counter()
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                    #expect((provisioningAttempts.count > 0) == expected)
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                #expect(host.platform == platform)
                _ = provisioningAttempts.increment()
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect((provisioningAttempts.count > 0) == expected)
        await model.shutdown()
    }

    @MainActor
    @Test("automatic kwt provisioning includes exe.dev hosts")
    func automaticKwtProvisioningIncludesExeHosts() async throws {
        let environment = try setupStandardEnvironment()
        let exeHost = ExeConfiguredHost(
            sshHost: SSHHost(
                configKey: "exe-dev.personal.build",
                name: "build",
                platform: .linux,
                sshDestination: "vm+build@exe.dev"
            ),
            metadata: ExeVMMetadata(
                accountConfigKey: "personal",
                accountName: "Personal",
                vmName: "build"
            )
        )
        let provisionedHost = LockedValue<SSHHost?>(nil)
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                provisionedHost.store(host)
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredExeHostsProvider: { [exeHost] },
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect(provisionedHost.load() == exeHost.sshHost)
        await model.shutdown()
    }

    @MainActor
    @Test("manual SSH hosts retain kwt provisioning precedence")
    func manualHostsRetainKwtProvisioningPrecedence() async throws {
        let environment = try setupStandardEnvironment()
        let manualHost = SSHHost(
            configKey: "manual-build",
            name: "Manual Build",
            platform: .linux,
            sshDestination: "build.exe.xyz"
        )
        let exeHost = ExeConfiguredHost(
            sshHost: SSHHost(
                configKey: "exe-dev.personal.build",
                name: "build",
                platform: .linux,
                sshDestination: manualHost.sshDestination
            ),
            metadata: ExeVMMetadata(
                accountConfigKey: "personal",
                accountName: "Personal",
                vmName: "build"
            )
        )
        let provisionedHost = LockedValue<SSHHost?>(nil)
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                provisionedHost.store(host)
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { [manualHost] },
            configuredExeHostsProvider: { [exeHost] },
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect(provisionedHost.load() == manualHost)
        await model.shutdown()
    }

    @MainActor
    @Test("kwt provisioning failure leaves remote tmux inventory available")
    func provisioningFailureDoesNotBlockTmux() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { _ in
                throw KwtRemoteInstallError.bundleIncomplete
            },
            tmuxSessionDiscovery: { host in
                .success(host.isRemote ? [
                    DiscoveredTmuxSession(
                        name: "build",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ] : [])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.tmuxSessions.map(\.name) == ["build"]
                }
                && !model.workspaceInventoryWarningsByHost.isEmpty
        }

        #expect(remoteInventoryLoads.count == 0)
        let remoteSummary = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        #expect(remoteSummary.primaryDiagnostic?.code == .missingKwt)
        #expect(!remoteSummary.canCreateWorktree)
        await model.shutdown()
    }

    @MainActor
    @Test("an unreachable SSH host does not block local inventory")
    func unreachableRemoteDoesNotBlockLocalInventory() async throws {
        let environment = try setupStandardEnvironment()
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "ssh: connect to host wesm-mbp port 22: Network is unreachable"
        )
        let remote = SSHHost(
            configKey: "wesm-mbp",
            name: "Wes MBP",
            platform: .macOS,
            sshDestination: "wesm@wesm-mbp"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                switch host {
                case .local:
                    return KwtHostInventory(projects: [])
                case let .ssh(info):
                    throw KwtInventoryError.commandFailed(
                        host: info.displayName,
                        status: 255
                    )
                }
            },
            tmuxSessionDiscovery: { host in
                switch host {
                case .local:
                    return .success([
                        DiscoveredTmuxSession(
                            name: "docbank",
                            windowCount: 4,
                            createdAt: "1721552400",
                            managed: false
                        ),
                    ])
                case .ssh:
                    return .failure(.sshConnectionFailed(
                        host: remote.name,
                        classification: transport
                    ))
                }
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
                && model.workspaceInventoryWarningsByHost.values.contains {
                    $0.contains("Wes MBP")
                }
        }

        #expect(model.workspaceInventoryState == .loaded)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
        )
        #expect(model.workspaceInventoryWarning == nil)
        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        let remoteSummary = try #require(
            model.snapshot.host(id: remoteHostID)
        )
        #expect(remoteSummary.connectionState == .offline)
        #expect(remoteSummary.primaryDiagnostic?.code == .probeFailure)
        #expect(remoteSummary.lastSeenAt == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[remoteHostID]?
                .contains("could not reach") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("missing tmux does not make a Herdr-capable host offline")
    func missingTmuxKeepsHerdrHostReachable() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "herdr-box",
            name: "Herdr Box",
            platform: .linux,
            sshDestination: "dev@herdr-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { host in
                switch host {
                case .local:
                    return .success([])
                case .ssh:
                    return .failure(.notFound(shell: remote.name))
                }
            },
            herdrSessionDiscovery: { host in
                switch host {
                case .local:
                    return .unavailable
                case .ssh:
                    return .available([running])
                }
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.herdrSessions == [running]
                }
        }

        let summary = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        #expect(summary.lastKnownReachable)
        #expect(summary.connectionState != .offline)
        #expect(summary.herdrAvailable)
        #expect(model.workspaceInventoryWarningsByHost[summary.id]?
            .contains("tmux was not found") == true)
        await model.shutdown()
    }

    @MainActor
    @Test("fresh failure of every inventory source is retryable")
    func allSourcesFailWithoutInventory() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: 1
                )
            },
            tmuxSessionDiscovery: { _ in
                .failure(.shellFailed(status: 1))
            },
            startServices: true
        )

        await waitUntilMainActor {
            if case .failed = model.workspaceInventoryState {
                return true
            }
            return false
        }

        guard case let .failed(message) = model.workspaceInventoryState else {
            Issue.record("Expected total inventory failure")
            await model.shutdown()
            return
        }
        #expect(message.contains("status 1"))
        #expect(model.workspaceInventoryWarning == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[environment.host.id]?
                .contains("status 1") == true
        )
        #expect(model.snapshot.projects.isEmpty)
        #expect(
            model.snapshot.hosts.allSatisfy { $0.tmuxSessions.isEmpty }
        )
        await model.shutdown()
    }

    @MainActor
    @Test("missing kwt does not block an SSH host's tmux inventory")
    func remoteWithoutKwtDoesNotBlockTmux() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "tmux-only",
            name: "Tmux Only",
            platform: .linux,
            sshDestination: "tmux-only"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                guard host.isRemote else {
                    return KwtHostInventory(projects: [])
                }
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: 127
                )
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
        }

        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        #expect(model.workspaceInventoryWarningsByHost[remoteHostID] == nil)
        let remoteSummary = try #require(
            model.snapshot.host(id: remoteHostID)
        )
        #expect(remoteSummary.primaryDiagnostic?.code == .missingKwt)
        #expect(remoteSummary.lastKnownReachable)
        #expect(remoteSummary.connectionState == .degraded)
        #expect(!remoteSummary.canCreateWorktree)
        await model.shutdown()
    }

    @MainActor
    @Test("losing remote kwt retains cached inventory but disables creation")
    func remoteKwtLossDisablesCreation() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let availability = KwtAvailabilityState(
            remoteInventory: KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: "github.com/kenn-io/docbank",
                        name: "docbank",
                        path: "/srv/docbank",
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        )
        let creationAttempts = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                try availability.load(host)
            },
            kwtWorktreeCreator: { _, _, _ in
                _ = creationAttempts.increment()
            },
            tmuxSessionDiscovery: { host in
                .success(host.isRemote ? [
                    DiscoveredTmuxSession(
                        name: "docbank",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ] : [])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.projects.contains { $0.name == "docbank" }
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.tmuxSessions.contains { $0.name == "docbank" }
                }
        }
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.name == "docbank" }
        )
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))

        availability.markRemoteKwtUnavailable()
        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.snapshot.host(id: cachedProject.hostID)?
                .primaryDiagnostic?.code == .missingKwt
        }

        let unavailableHost = try #require(
            model.snapshot.host(id: cachedProject.hostID)
        )
        #expect(!unavailableHost.canCreateWorktree)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(unavailableHost.tmuxSessions.map(\.name) == ["docbank"])
        #expect(model.workspaceInventoryWarningsByHost[unavailableHost.id] == nil)

        do {
            try await model.createWorktree(WorktreeCreateRequest(
                projectID: cachedProject.id,
                branchName: "feature/should-not-run",
                createsBranch: true
            ))
            Issue.record("Expected unavailable kwt to reject creation")
        } catch let error as KwtWorktreeError {
            #expect(error == .projectUnavailable)
        }
        #expect(creationAttempts.count == 0)

        availability.markRemoteKwtAvailable()
        model.refreshKwtInventory()
        await waitUntilMainActor {
            let host = model.snapshot.host(id: cachedProject.hostID)
            return host?.primaryDiagnostic?.code != .missingKwt
                && host?.canCreateWorktree == true
        }
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))
        await model.shutdown()
    }

    @MainActor
    @Test(
        "status 127 during creation disables kwt and schedules discovery",
        arguments: CreationKwtFailurePhase.allCases
    )
    private func creationKwtLossDisablesCapability(
        phase: CreationKwtFailurePhase
    ) async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let availability = KwtAvailabilityState(
            remoteInventory: KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: "github.com/kenn-io/docbank",
                        name: "docbank",
                        path: "/srv/docbank",
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        )
        let creationAttempts = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                try availability.load(host)
            },
            kwtWorktreeCreator: { _, _, host in
                _ = creationAttempts.increment()
                if phase == .command {
                    throw KwtWorktreeError.commandFailed(
                        host: host.displayName,
                        status: 127
                    )
                }
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.projects.contains { $0.name == "docbank" }
        }
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.name == "docbank" }
        )
        availability.markRemoteKwtUnavailable()

        do {
            try await model.createWorktree(WorktreeCreateRequest(
                projectID: cachedProject.id,
                branchName: "feature/kwt-disappeared",
                createsBranch: true
            ))
            Issue.record("Expected status 127 from worktree creation")
        } catch {
            switch (phase, error) {
            case let (.command, worktreeError as KwtWorktreeError):
                #expect(
                    worktreeError == .commandFailed(
                        host: "build-box",
                        status: 127
                    )
                )
            case let (.inventoryRefresh, inventoryError as KwtInventoryError):
                #expect(
                    inventoryError == .commandFailed(
                        host: "build-box",
                        status: 127
                    )
                )
            default:
                Issue.record("Unexpected status-127 error: \(error)")
            }
        }

        await waitUntilMainActor {
            availability.remoteLoadCount >= 2
                && model.snapshot.host(id: cachedProject.hostID)?
                .primaryDiagnostic?.code == .missingKwt
        }
        #expect(creationAttempts.count == 1)
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
        await model.shutdown()
    }

    @MainActor
    @Test("tmux discovery failure invalidates prior host reachability")
    func tmuxFailureMarksPreviouslyReachableHostOffline() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let availability = KwtAvailabilityState(
            remoteInventory: KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: "github.com/kenn-io/docbank",
                        name: "docbank",
                        path: "/srv/docbank",
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        )
        let reachability = TmuxReachabilityState()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                try availability.load(host)
            },
            tmuxSessionDiscovery: reachability.discover,
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.hosts.contains {
                $0.configKey == remote.configKey
                    && $0.lastKnownReachable
                    && $0.tmuxSessions.map(\.name) == ["docbank"]
            }
        }
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        let lastSeenAt = try #require(remoteHost.lastSeenAt)
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.hostID == remoteHost.id }
        )
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))

        reachability.markRemoteUnreachable()
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: remoteHost.id)?.connectionState == .offline
        }

        let offlineHost = try #require(model.snapshot.host(id: remoteHost.id))
        #expect(!offlineHost.lastKnownReachable)
        #expect(offlineHost.lastSeenAt == lastSeenAt)
        #expect(offlineHost.tmuxSessions.map(\.name) == ["docbank"])
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
        #expect(
            model.workspaceInventoryWarningsByHost[offlineHost.id]?
                .contains("could not reach") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe accepts a tmux-only SSH host")
    func connectionProbeAcceptsRemoteWithoutKwt() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, command in
                #expect(command.contains("command -v tmux"))
                #expect(command.contains(
                    "GHOSTHUB_SSH_PROBE_TEST-NONCE_START"
                ))
                return (
                    status: 0,
                    stdout: Self.probeOutput(
                        [
                            "GHOSTHUB_SSH_REACHED",
                            "GHOSTHUB_TMUX_AVAILABLE",
                            "GHOSTHUB_KWT_UNAVAILABLE",
                        ],
                        startupOutput: "unterminated startup output"
                    ),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "tmux-only",
            name: "Tmux Only",
            platform: .linux,
            sshDestination: "tmux-only"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .online)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.diagnostics.count == 1)
        #expect(summary.diagnostics.first?.code == .missingKwt)
        #expect(summary.diagnostics.first?.severity == .warning)
        #expect(
            summary.diagnostics.first?.recoverySuggestion
                .contains("Tmux sessions remain available") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe distinguishes a reachable host without tmux")
    func connectionProbeReportsMissingTmux() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: 127,
                    stdout: Self.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_UNAVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "host-a",
            name: "Host A",
            platform: .linux,
            sshDestination: "user-a@host-a.example"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.diagnostics.map(\.code) == [.missingTmux])
        #expect(
            summary.diagnostics.first?.summary
                == "tmux is not available."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe requires its nonce-framed protocol block")
    func connectionProbeReportsSSHFailure() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: 255,
                    stdout:
                    "GHOSTHUB_SSH_REACHED\n"
                        + "GHOSTHUB_TMUX_AVAILABLE\n",
                    stderr:
                    "GHOSTHUB_SSH_REACHED\n"
                        + "GHOSTHUB_TMUX_AVAILABLE\n"
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "offline",
            name: "Offline",
            platform: .linux,
            sshDestination: "offline"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .offline)
        #expect(!summary.host.lastKnownReachable)
        #expect(summary.diagnostics.map(\.code) == [
            .sshConnectionFailed,
        ])
        #expect(
            summary.diagnostics.first?.summary
                == "SSH could not connect to the host."
        )
        await model.shutdown()
    }

    @MainActor
    @Test(
        "connection probe keeps non-SSH command failures reachable",
        arguments: [Int32(1), Int32(127)]
    )
    func connectionProbeReportsProbeFailure(status: Int32) async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: status,
                    stdout: Self.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_AVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "misconfigured-shell",
            name: "Misconfigured Shell",
            platform: .linux,
            sshDestination: "misconfigured-shell"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.host.lastSeenAt != nil)
        #expect(summary.diagnostics.map(\.code) == [.probeFailure])
        #expect(
            summary.diagnostics.first?.summary
                == "tmux did not respond successfully."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe treats an unconfirmed SSH timeout as offline")
    func connectionProbeReportsUnconfirmedTimeout() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: -124,
                    stdout: "",
                    stderr: "SSH wrapper output\n"
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "timed-out",
            name: "Timed Out",
            platform: .linux,
            sshDestination: "timed-out"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .offline)
        #expect(!summary.host.lastKnownReachable)
        #expect(summary.host.lastSeenAt == nil)
        #expect(summary.diagnostics.map(\.code) == [.sshConnectionFailed])
        #expect(
            summary.diagnostics.first?.summary
                == "The SSH connection timed out."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("Add Project rejects a host endpoint changed while its sheet is open")
    func addProjectRejectsChangedEndpoint() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let registrationCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtProjectRegistration: { _, _ in
                _ = registrationCalls.increment()
                return KwtProjectRecord(
                    repository: "github.com/kenn-io/ghosthub",
                    name: "ghosthub",
                    path: "/srv/ghosthub",
                    lastTouched: nil
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher()
        )
        model.refreshHosts()
        let capturedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "spark" }
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
        let result = await model.registerProject(
            "/srv/ghosthub",
            on: capturedHost
        )

        #expect(
            result == .failure(.message(
                "The host connection changed. "
                    + "Close Add Project and try again."
            ))
        )
        #expect(registrationCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Host Settings registers a project on an unsaved host draft")
    func hostSettingsRegistersProjectOnUnsavedDraft() async throws {
        let environment = try setupHostEnvironment()
        let draft = SSHHost(
            configKey: "new-builder",
            name: "New Builder",
            platform: .linux,
            sshDestination: " \nwesm@builder.example.com:2222\t"
        )
        let capturedTarget = LockedValue<CommandHost?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtProjectRegistration: { path, target in
                capturedTarget.store(target)
                return KwtProjectRecord(
                    repository: "github.com/kenn-io/ghosthub",
                    name: "ghosthub",
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let result = await model.registerRemoteProject(
            "/srv/ghosthub",
            on: draft
        )

        #expect(result == .success("ghosthub"))
        #expect(capturedTarget.load() == .ssh(SSHHostInfo(
            user: "wesm",
            hostname: "builder.example.com",
            port: 2222,
            platform: .posix
        )))
        await model.shutdown()
    }

    @MainActor
    @Test("Host aliases cannot overlap project registry changes")
    func addProjectRejectsConcurrentRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let draft = SSHHost(
            configKey: "builder-alias",
            name: "Builder Alias",
            platform: host.platform,
            sshDestination: "wesm@OFFICE-LINUX:22"
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: environment.snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let removalGate = KillGate()
        let registrationCalls = Counter()
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                await removalGate.suspend()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )
        let registrationModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            worktreeMutationCoordinator: coordinator,
            kwtProjectRegistration: { path, _ in
                _ = registrationCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let removalTask = Task {
            await removalModel.unregisterProject(
                project,
                confirmedHost: host
            )
        }
        await removalGate.waitUntilStarted()

        let registrationResult = await registrationModel
            .registerRemoteProject(
                project.rootPath,
                on: draft
            )
        #expect(removalModel.snapshot.project(id: project.id) != nil)

        await removalGate.release()
        let removalResult = await removalTask.value
        #expect(registrationResult == .failure(.message(
            "Another project or worktree change is already in progress."
        )))
        #expect(registrationCalls.count == 0)
        #expect(removalResult == .success(project.name))
        await waitUntilMainActor {
            removalModel.snapshot.project(id: project.id) == nil
        }
        await removalModel.shutdown()
        await registrationModel.shutdown()
    }

    @MainActor
    @Test("Refreshed endpoint identity replaces an unresolved retired entry")
    func refreshedEndpointReconcilesRetiredUnresolvedEntry() throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let worktree = try #require(environment.snapshot.worktrees.first)
        let selection = WorkspaceTmuxSessionSelection(
            hostID: project.hostID,
            name: "kwt-ghosthub-pr-94",
            worktreeID: worktree.id,
            workspacePath: worktree.path,
            worktreeGeneration: worktree.generation,
            socketName: "kwt-pr-94"
        )
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        let identity = KwtWorktreeIdentity(
            path: worktree.path,
            generation: worktree.generation ?? ""
        )
        let retiredParticipant = UUID()
        let refreshedParticipant = UUID()
        let coordinator = WorktreeMutationCoordinator()

        coordinator.replaceProtectedEndpoints([
            scope: [WorktreeMutationCoordinator.ProtectedEndpoint(
                worktreeName: "stale-label",
                worktreeIdentity: identity,
                selection: nil
            )],
        ], for: retiredParticipant)
        coordinator.retireProtectedEndpoints(for: retiredParticipant)
        coordinator.replaceProtectedEndpoints([
            scope: [WorktreeMutationCoordinator.ProtectedEndpoint(
                worktreeName: "current-label",
                worktreeIdentity: identity,
                selection: selection
            )],
        ], for: refreshedParticipant)

        #expect(coordinator.protectedEndpoints(in: scope) == [
            WorktreeMutationCoordinator.ProtectedEndpoint(
                worktreeName: "current-label",
                worktreeIdentity: identity,
                selection: selection
            ),
        ])
    }

    @MainActor
    @Test("Generationless inventory preserves a matching retired endpoint")
    func generationlessInventoryPreservesRetiredEndpoint() throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        var worktree = try #require(environment.snapshot.worktrees.first)
        let canonicalGeneration =
            "0123456789abcdef0123456789abcdef01234567"
        worktree.generation = nil
        let identity = KwtWorktreeIdentity(
            path: worktree.path,
            generation: canonicalGeneration
        )
        let endpoint = WorktreeMutationCoordinator.ProtectedEndpoint(
            worktreeName: worktree.name,
            worktreeIdentity: identity,
            selection: WorkspaceTmuxSessionSelection(
                hostID: project.hostID,
                name: "kwt-ghosthub-pr-94",
                worktreeID: worktree.id,
                workspacePath: worktree.path,
                worktreeGeneration: canonicalGeneration,
                socketName: "kwt-pr-94"
            )
        )
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        let participant = UUID()
        let coordinator = WorktreeMutationCoordinator()
        coordinator.replaceProtectedEndpoints(
            [scope: [endpoint]],
            for: participant
        )
        coordinator.retireProtectedEndpoints(for: participant)

        coordinator.reconcileRetiredProtectedEndpoints(
            after: Self.inventory(project: project, worktrees: [worktree]),
            hostID: project.hostID
        )

        #expect(coordinator.protectedEndpoints(in: scope) == [endpoint])
    }

    @MainActor
    @Test("Complete inventory prunes a vanished unresolved retired endpoint")
    func completeInventoryPrunesVanishedRetiredEndpoint() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        let retiredParticipant = UUID()
        let coordinator = WorktreeMutationCoordinator()
        coordinator.replaceProtectedEndpoints([
            scope: [WorktreeMutationCoordinator.ProtectedEndpoint(
                worktreeName: "vanished",
                worktreeIdentity: KwtWorktreeIdentity(
                    path: "/worktrees/vanished",
                    generation: "0123456789abcdef0123456789abcdef"
                ),
                selection: nil
            )],
        ], for: retiredParticipant)
        coordinator.retireProtectedEndpoints(for: retiredParticipant)
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                Self.inventory(
                    project: project,
                    worktrees: environment.snapshot.worktrees
                )
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )
        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(coordinator.protectedEndpoints(in: scope).isEmpty)
        #expect(removalCalls.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project unregisters the current project path on its host")
    func removeProjectTargetsCurrentProject() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let removal = LockedValue<(
            String, String, String, CommandHost
        )?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                Self.inventory(
                    project: project,
                    worktrees: environment.snapshot.worktrees
                )
            },
            kwtProjectRemoval: {
                path, expectedRepository, expectedRegistration, host in
                removal.store((
                    path, expectedRepository, expectedRegistration, host
                ))
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )
        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(removal.load()?.0 == project.rootPath)
        #expect(removal.load()?.1 == project.scopedKey)
        #expect(
            removal.load()?.2 == project.registrationFingerprint
        )
        #expect(removal.load()?.3 == .local)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project never retries with a refreshed registration")
    func removeProjectDoesNotRetryRegistrationChanged() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        var refreshedProject = project
        refreshedProject.registrationFingerprint = "replacement-registration"
        let refreshedInventory = Self.inventory(
            project: refreshedProject,
            worktrees: environment.snapshot.worktrees
        )
        let inventoryLoads = Counter()
        let removals = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                _ = inventoryLoads.increment()
                return refreshedInventory
            },
            kwtProjectRemoval: { _, _, expectedRegistration, _ in
                removals.withLock { $0.append(expectedRegistration) }
                throw KwtProjectCommandError.commandFailed(
                    host: "this Mac",
                    status: 1,
                    code: "registration_changed",
                    message: "project registration changed",
                    retryable: true,
                    details: [:]
                )
            }
        )
        model.startKwtInventory()
        await waitUntilMainActor { inventoryLoads.count == 1 }

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "project registration changed Try again."
        )))
        await waitUntilMainActor { inventoryLoads.count >= 3 }
        #expect(removals.load() == [project.registrationFingerprint])
        #expect(model.snapshot.projects.count == 1)
        #expect(
            model.snapshot.projects.first?.registrationFingerprint
                == "replacement-registration"
        )
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Definitive kwt removal rejections restore without reconciliation",
        arguments: [
            "protected_session_live",
            "protected_endpoint_inventory_incomplete",
        ]
    )
    func definitiveRemovalRejectionRestoresImmediately(
        code: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-root"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let inventoryLoads = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalError = KwtProjectCommandError.commandFailed(
            host: "this Mac",
            status: 1,
            code: code,
            message: "kwt rejected project removal",
            retryable: false,
            details: [:]
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                guard inventoryLoads.increment() == 1 else {
                    throw KwtInventoryError.commandFailed(
                        host: "this Mac",
                        status: 75
                    )
                }
                return inventory
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _ in throw removalError }
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            removalError.localizedDescription
        )))
        #expect(coordinator.scopes.isEmpty)
        #expect(model.activeBorrowedTmuxSelection == selection)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Remove Project rejects live protected sessions",
        arguments: [false, true]
    )
    func removeProjectRejectsLiveProtectedSession(
        attached: Bool
    ) async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let currentInventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in currentInventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        if attached {
            model.openBorrowedTmuxSession(selection)
            await launchActiveTmuxSurface(model, store: surfaceStore)
            #expect(model.retainedBorrowedTmuxSessionIsConnected(selection))
        }

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-pr-94” is still running on its protected "
                + "tmux server. Kill it before removing project “Ghosthub”."
        )))
        #expect(removalCalls.count == 0)
        #expect(coordinator.scopes.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project probes protected endpoints from another scene")
    func removeProjectProbesDivergentSceneEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        var removalSnapshot = environment.snapshot
        removalSnapshot.worktrees[0].tmuxSocketName = nil
        let project = try #require(removalSnapshot.projects.first)
        let host = try #require(removalSnapshot.hosts.first)
        let protectedWorktree = WorktreeSummary(
            id: UUID(),
            hostID: host.id,
            projectID: project.id,
            scopedKey: "worktree:/tmp/ghosthub-divergent-protected",
            name: "divergent-protected",
            path: "/tmp/ghosthub-divergent-protected",
            branch: "feature/divergent-protected",
            generation: "0123456789abcdef0123456789abcdef",
            tmuxSessionName: "kwt-ghosthub-divergent-protected",
            tmuxSocketName: "kwt-divergent-protected"
        )
        let protectedSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: protectedWorktree
            )
        )
        var divergentSnapshot = removalSnapshot
        divergentSnapshot.worktrees.append(protectedWorktree)
        let currentInventory = Self.inventory(
            project: project,
            worktrees: removalSnapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let probedSelections = LockedValue<
            Set<WorkspaceTmuxSessionSelection>
        >([])
        let otherScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: divergentSnapshot,
            worktreeMutationCoordinator: coordinator
        )
        let removalScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: removalSnapshot,
            kwtInventoryLoader: { _ in currentInventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                probedSelections.withLock { $0.insert(selection) }
                if selection == protectedSelection {
                    return TmuxSessionIdentity(
                        serverPID: "31415",
                        sessionID: "$42",
                        createdAt: "1721552400"
                    )
                }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let result = await removalScene.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-divergent-protected” is still running "
                + "on its protected tmux server. Kill it before removing "
                + "project “Ghosthub”."
        )))
        #expect(probedSelections.load().contains(protectedSelection))
        #expect(removalCalls.count == 0)
        await otherScene.shutdown()
        await removalScene.shutdown()
    }

    @MainActor
    @Test("Remove Project probes endpoints replaced by an active scene")
    func removeProjectProbesEndpointReplacedByActiveScene() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-current"
        snapshot.worktrees[0].tmuxSocketName = "kwt-current"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var previousSnapshot = snapshot
        previousSnapshot.worktrees[0].tmuxSessionName =
            "kwt-ghosthub-retired"
        previousSnapshot.worktrees[0].tmuxSocketName = "kwt-retired"
        let liveRetiredSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: previousSnapshot.worktrees[0]
            )
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let probedSelections = LockedValue<
            Set<WorkspaceTmuxSessionSelection>
        >([])
        let activeScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: previousSnapshot,
            worktreeMutationCoordinator: coordinator
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                probedSelections.withLock { $0.insert(selection) }
                if selection == liveRetiredSelection {
                    return TmuxSessionIdentity(
                        serverPID: "31415",
                        sessionID: "$42",
                        createdAt: "1721552400"
                    )
                }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        activeScene.snapshot = snapshot

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-retired” is still running on its "
                + "protected tmux server. Kill it before removing project "
                + "“Ghosthub”."
        )))
        #expect(probedSelections.load().contains(liveRetiredSelection))
        #expect(removalCalls.count == 0)
        await activeScene.shutdown()
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project allows an absent protected session")
    func removeProjectAllowsAbsentProtectedSession() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let currentInventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in currentInventory },
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(removalCalls.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project reprobes cached endpoints after partial inventory")
    func removeProjectReprobesCachedEndpointsAfterPartialInventory()
        async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let missingCheckout = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-partial-checkout-\(UUID().uuidString)",
                isDirectory: true
            )
        snapshot.projects[0].rootPath = missingCheckout.path
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-visible"
        snapshot.worktrees[0].tmuxSocketName = "kwt-visible"
        let omittedWorktree = WorktreeSummary(
            id: UUID(),
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "worktree:\(missingCheckout.path)/omitted",
            name: "omitted",
            path: "\(missingCheckout.path)/omitted",
            branch: "feature/omitted",
            generation: "0123456789abcdef0123456789abcdef",
            tmuxSessionName: "kwt-ghosthub-omitted",
            tmuxSocketName: nil
        )
        snapshot.worktrees.append(omittedWorktree)
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var partialInventory = Self.inventory(
            project: project,
            worktrees: [snapshot.worktrees[0]]
        )
        partialInventory.projects[0].warning = "kwt worktree inventory failed"
        let inventory = partialInventory
        let removalCalls = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in inventory },
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                if selection.name == "kwt-ghosthub-visible" {
                    return TmuxSessionIdentity(
                        serverPID: "31415",
                        sessionID: "$42",
                        createdAt: "1721552400"
                    )
                }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let omittedSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: omittedWorktree)
        )
        model.openBorrowedTmuxSession(omittedSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)

        let firstResult = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(firstResult == .failure(.message(
            "Session “kwt-ghosthub-visible” is still running on its protected "
                + "tmux server. Kill it before removing project “Ghosthub”."
        )))
        #expect(removalCalls.count == 0)
        #expect(model.snapshot.worktree(id: omittedWorktree.id) != nil)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(model.activeBorrowedTmuxSelection == omittedSelection)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project probes each protected endpoint once")
    func removeProjectDeduplicatesProtectedEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let missingCheckout = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-deduplicated-checkout-\(UUID().uuidString)",
                isDirectory: true
            )
        snapshot.projects[0].rootPath = missingCheckout.path
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-protected"
        snapshot.worktrees[0].tmuxSocketName = "kwt-protected"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var refreshedWorktree = try #require(snapshot.worktrees.first)
        refreshedWorktree.scopedKey = "worktree:/tmp/refreshed-protected"
        refreshedWorktree.path = "/tmp/refreshed-protected"
        refreshedWorktree.generation =
            "fedcba9876543210fedcba9876543210"
        let inventory = Self.inventory(
            project: project,
            worktrees: [refreshedWorktree]
        )
        let identityReads = Counter()
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                _ = identityReads.increment()
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(identityReads.count == 1)
        #expect(removalCalls.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project probes protected endpoints from refreshed inventory")
    func removeProjectProbesRefreshedProtectedEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-cached"
        snapshot.worktrees[0].tmuxSocketName = nil
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var refreshedWorktree = try #require(snapshot.worktrees.first)
        refreshedWorktree.scopedKey = "worktree:/tmp/refreshed-protected"
        refreshedWorktree.path = "/tmp/refreshed-protected"
        refreshedWorktree.generation =
            "fedcba9876543210fedcba9876543210"
        refreshedWorktree.tmuxSessionName = "kwt-ghosthub-refreshed"
        refreshedWorktree.tmuxSocketName = "kwt-refreshed"
        let inventory = Self.inventory(
            project: project,
            worktrees: [refreshedWorktree]
        )
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-refreshed” is still running on its "
                + "protected tmux server. Kill it before removing project "
                + "“Ghosthub”."
        )))
        #expect(removalCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Refreshed endpoint replaces the same unresolved cached identity")
    func refreshedEndpointReplacesCachedUnresolvedIdentity() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = nil
        snapshot.worktrees[0].tmuxSocketName = "kwt-stale"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var refreshedWorktree = try #require(snapshot.worktrees.first)
        refreshedWorktree.tmuxSessionName = "kwt-ghosthub-refreshed"
        refreshedWorktree.tmuxSocketName = "kwt-refreshed"
        let inventory = Self.inventory(
            project: project,
            worktrees: [refreshedWorktree]
        )
        let probedSelection = LockedValue<
            WorkspaceTmuxSessionSelection?
        >(nil)
        let removalCalls = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                probedSelection.store(selection)
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(probedSelection.load()?.name == "kwt-ghosthub-refreshed")
        #expect(probedSelection.load()?.socketName == "kwt-refreshed")
        #expect(removalCalls.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project releases its fence after inventory failure")
    func removeProjectReleasesFenceAfterInventoryFailure() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let inventoryError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in throw inventoryError },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            inventoryError.localizedDescription
        )))
        #expect(removalCalls.count == 0)
        #expect(coordinator.scopes.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project delegates warned missing checkout to guarded kwt")
    func removeProjectDelegatesWarnedMissingCheckout() async throws {
        let environment = try setupStandardEnvironment()
        let missingCheckout = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-uncached-checkout-\(UUID().uuidString)",
                isDirectory: true
            )
        var snapshot = environment.snapshot
        snapshot.projects[0].rootPath = missingCheckout.path
        snapshot.worktrees = []
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var inventory = Self.inventory(project: project, worktrees: [])
        inventory.projects[0].warning = "worktree lookup failed"
        let warnedInventory = inventory
        let removal = LockedValue<(String, String)?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in warnedInventory },
            kwtProjectRemoval: { path, expectedRepository, _, _ in
                removal.store((path, expectedRepository))
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(removal.load()?.0 == missingCheckout.path)
        #expect(removal.load()?.1 == project.scopedKey)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Remove Project reconciles a lost removal response",
        arguments: ProjectRemovalReconciliationCase.allCases
    )
    func removeProjectReconcilesLostResponse(
        reconciliation: ProjectRemovalReconciliationCase
    ) async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let inventoryLoads = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                switch inventoryLoads.increment() {
                case 1:
                    return inventory
                default:
                    switch reconciliation {
                    case .confirmedPresent:
                        return inventory
                    case .confirmedAbsent:
                        return KwtHostInventory(projects: [])
                    case .unavailable:
                        throw KwtInventoryError.commandFailed(
                            host: "this Mac",
                            status: 75
                        )
                    case .globalWarning:
                        var warned = inventory
                        warned.projectsWarning = "project lookup failed"
                        return warned
                    case .projectWarning:
                        var warned = inventory
                        warned.projects[0].warning = "worktree lookup failed"
                        return warned
                    case .pathDrift:
                        var moved = inventory
                        moved.projects[0].project.path = "/tmp/ghosthub-moved"
                        return moved
                    }
                }
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _ in throw removalError },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let attachedModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        attachedModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(attachedModel, store: surfaceStore)
        await waitUntilMainActor { coordinator.scopes.isEmpty }

        let result = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        switch reconciliation {
        case .confirmedPresent:
            #expect(result == .failure(.message(
                removalError.localizedDescription
            )))
            #expect(attachedModel.activeBorrowedTmuxSelection == selection)
            #expect(attachedModel.snapshot.project(id: project.id) != nil)
        case .confirmedAbsent:
            #expect(result == .success(project.name))
            #expect(attachedModel.activeBorrowedTmuxSelection == nil)
            #expect(attachedModel.snapshot.project(id: project.id) == nil)
        case .unavailable, .globalWarning, .projectWarning, .pathDrift:
            #expect(result == .failure(.message(
                removalError.localizedDescription
            )))
            #expect(attachedModel.activeBorrowedTmuxSelection == nil)
            #expect(attachedModel.snapshot.project(id: project.id) != nil)
        }
        #expect(inventoryLoads.count == 2)
        switch reconciliation {
        case .confirmedPresent, .confirmedAbsent:
            #expect(coordinator.scopes.isEmpty)
        case .unavailable, .globalWarning, .projectWarning, .pathDrift:
            #expect(!coordinator.scopes.isEmpty)
        }
        await removalModel.shutdown()
        await attachedModel.shutdown()
    }

    @MainActor
    @Test("Warned missing checkout releases quarantine for removal retry")
    func warnedMissingCheckoutReleasesQuarantineForRetry() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let missingCheckout = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-missing-retry-\(UUID().uuidString)",
                isDirectory: true
            )
        snapshot.projects[0].rootPath = missingCheckout.path
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        var warnedInventory = Self.inventory(
            project: project,
            worktrees: []
        )
        warnedInventory.projects[0].warning = "worktree lookup failed"
        let authoritativeInventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        var warnedDriftInventory = warnedInventory
        warnedDriftInventory.projects[0].project.path = missingCheckout
            .appendingPathComponent("moved", isDirectory: true).path
        let inventory = LockedValue(warnedInventory)
        let inventoryLoads = Counter()
        let removalCalls = Counter()
        let openedSessions = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                guard inventoryLoads.increment() > 1 else {
                    return authoritativeInventory
                }
                return inventory.load()
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                guard removalCalls.increment() > 1 else {
                    throw removalError
                }
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let attachedModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        var selectedWorktree = attachedModel.selection
        selectedWorktree.select(
            .worktree(worktree.id),
            in: attachedModel.snapshot,
            visibility: .default
        )
        attachedModel.selectFromUser(selectedWorktree)
        attachedModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(attachedModel, store: surfaceStore)
        await waitUntilMainActor { coordinator.scopes.isEmpty }

        let firstResult = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(firstResult == .failure(.message(
            removalError.localizedDescription
        )))
        let lateModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            worktreeMutationCoordinator: coordinator
        )
        var lateSelection = lateModel.selection
        lateSelection.select(
            .worktree(worktree.id),
            in: lateModel.snapshot,
            visibility: .default
        )
        lateModel.selectFromUser(lateSelection)
        #expect(lateModel.suppressesSelectedWorktreeSessionOpen)
        let hostingView = hostView(rootView: AnyView(
            SceneModelRootHarness(
                model: lateModel,
                onOpenTmuxSession: { _ in
                    _ = openedSessions.increment()
                }
            )
        ))
        inventory.store(warnedDriftInventory)
        let loadsBeforeDriftRefresh = inventoryLoads.count
        removalModel.startKwtInventory()
        await waitUntilMainActor {
            inventoryLoads.count > loadsBeforeDriftRefresh
                && removalModel.workspaceInventoryWarning != nil
        }
        #expect(!coordinator.scopes.isEmpty)
        #expect(removalCalls.count == 1)

        inventory.store(warnedInventory)
        removalModel.refreshKwtInventory()
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(coordinator.scopes.isEmpty)
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(openedSessions.count == 0)
        #expect(attachedModel.activeBorrowedTmuxSelection == nil)
        #expect(attachedModel.suppressesSelectedWorktreeSessionOpen)
        #expect(lateModel.suppressesSelectedWorktreeSessionOpen)

        inventory.store(authoritativeInventory)
        let secondResult = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(secondResult == .success(project.name))
        #expect(removalCalls.count == 2)
        withExtendedLifetime(hostingView) {}
        await removalModel.shutdown()
        await attachedModel.shutdown()
        await lateModel.shutdown()
    }

    @MainActor
    @Test("Unverified project removal keeps Root from reopening")
    func unverifiedProjectRemovalSuppressesRootOpen() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let inventoryLoads = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let openedSessions = Counter()
        let removalGate = KillGate()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                switch inventoryLoads.increment() {
                case 1:
                    return inventory
                case 2:
                    throw KwtInventoryError.commandFailed(
                        host: "this Mac",
                        status: 75
                    )
                default:
                    return inventory
                }
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _ in
                await removalGate.suspend()
                throw removalError
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let attachedModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        var selectedWorktree = attachedModel.selection
        selectedWorktree.select(
            .worktree(worktree.id),
            in: attachedModel.snapshot,
            visibility: .default
        )
        attachedModel.selectFromUser(selectedWorktree)
        attachedModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(attachedModel, store: surfaceStore)
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        let hostingView = hostView(rootView: AnyView(
            SceneModelRootHarness(
                model: attachedModel,
                onOpenTmuxSession: { _ in
                    _ = openedSessions.increment()
                }
            )
        ))

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await removalModel.unregisterProject(
                project,
                confirmedHost: host
            )
        }
        await removalGate.waitUntilStarted()
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(attachedModel.selection.selectedWorktreeID == worktree.id)
        #expect(attachedModel.suppressesSelectedWorktreeSessionOpen)
        await removalGate.release()
        let result = await removalTask.value

        #expect(result == .failure(.message(
            removalError.localizedDescription
        )))
        #expect(attachedModel.activeBorrowedTmuxSelection == nil)
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        #expect(openedSessions.count == 0)
        #expect(attachedModel.suppressesSelectedWorktreeSessionOpen)
        #expect(!coordinator.scopes.isEmpty)
        withExtendedLifetime(hostingView) {}

        removalModel.startKwtInventory()
        await waitUntilMainActor {
            inventoryLoads.count >= 3 && coordinator.scopes.isEmpty
        }
        await removalModel.shutdown()
        await attachedModel.shutdown()
    }

    @MainActor
    @Test("Scene opened during quarantine can resolve it")
    func sceneOpenedDuringQuarantineResolvesInventory() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let inventoryLoads = Counter()
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )],
            presentationTargets: [selection]
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: .local
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                _ = inventoryLoads.increment()
                return inventory
            },
            worktreeMutationCoordinator: coordinator
        )
        var selectedWorktree = model.selection
        selectedWorktree.select(
            .worktree(worktree.id),
            in: model.snapshot,
            visibility: .default
        )
        model.selectFromUser(selectedWorktree)

        #expect(model.suppressesSelectedWorktreeSessionOpen)
        model.startKwtInventory()

        await waitUntilMainActor { inventoryLoads.count >= 1 }
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Quarantine releases after a terminal registration change",
        arguments: QuarantinedProjectRegistrationChange.allCases
    )
    func quarantineReleasesAfterRegistrationChange(
        change: QuarantinedProjectRegistrationChange
    ) async throws {
        let environment = try setupStandardEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let coordinator = WorktreeMutationCoordinator()
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )],
            presentationTargets: []
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: .local
        )
        let expectedRepository: String
        let expectedPath: String
        let inventory: KwtHostInventory
        switch change {
        case .sameIdentityMoved:
            expectedRepository = project.scopedKey
            expectedPath = "/tmp/ghosthub-moved"
            var moved = project
            moved.rootPath = expectedPath
            inventory = Self.inventory(project: moved, worktrees: [])
        case .replacementAtOriginalPath:
            expectedRepository = "repo:/tmp/ghosthub-replacement"
            expectedPath = project.rootPath
            inventory = KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: expectedRepository,
                        name: "Ghosthub Replacement",
                        path: expectedPath,
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator
        )

        model.startKwtInventory()

        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(model.snapshot.projects.contains {
            $0.scopedKey == expectedRepository
                && $0.rootPath == expectedPath
        })
        await model.shutdown()
    }

    @MainActor
    @Test("Replacement endpoint cannot classify an old quarantine as removed")
    func replacementEndpointDoesNotResolveOldQuarantine() async throws {
        let environment = try setupRemoteEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let oldHost = try #require(environment.snapshot.hosts.first)
        let oldTarget = try #require(CommandHostResolver.resolve(oldHost))
        let coordinator = WorktreeMutationCoordinator()
        #expect(coordinator.acquireProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            registryHost: .init(target: oldTarget)
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [],
            presentationTargets: []
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: oldTarget
        )
        let peer = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            worktreeMutationCoordinator: coordinator
        )
        var replacementSnapshot = environment.snapshot
        replacementSnapshot.hosts[0].sshDestination = "wesm@replacement"
        let replacement = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: replacementSnapshot,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            worktreeMutationCoordinator: coordinator
        )

        replacement.startKwtInventory()

        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(peer.snapshot.project(id: project.id) != nil)
        await replacement.shutdown()
        await peer.shutdown()
    }

    @MainActor
    @Test("Deleting a host releases an existing removal quarantine")
    func deletedHostReleasesExistingRemovalQuarantine() async throws {
        let environment = try setupRemoteEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let oldHost = try #require(environment.snapshot.hosts.first)
        let oldTarget = try #require(CommandHostResolver.resolve(oldHost))
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: environment.host.configKey,
                name: environment.host.name,
                platform: environment.host.platform,
                sshDestination: try #require(
                    environment.host.sshDestination
                )
            ),
        ])
        let coordinator = WorktreeMutationCoordinator()
        let registryHost = WorktreeMutationCoordinator.ProjectRegistryHost(
            target: oldTarget
        )
        #expect(coordinator.acquireProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            registryHost: registryHost
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [],
            presentationTargets: []
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: oldTarget
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: environment.snapshot,
            worktreeMutationCoordinator: coordinator,
            configuredSSHHostsProvider: { configuredHosts.value }
        )

        configuredHosts.send([])
        model.refreshHosts()

        #expect(coordinator.scopes.isEmpty)
        #expect(coordinator.acquireProjectRegistry(host: registryHost))
        coordinator.releaseProjectRegistry(host: registryHost)
        await model.shutdown()
    }

    @MainActor
    @Test("Nested restoration acquisition keeps later scenes fenced")
    func nestedRestorationAcquisitionKeepsLaterScenesFenced() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let restoringSurfaces = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let establishmentGate = KillGate()
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let restoringModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: restoringSurfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { _, _ in
                if identityReads.increment() > 1 {
                    await establishmentGate.suspend()
                }
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        let inventoryLoads = Counter()
        let observerModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                _ = inventoryLoads.increment()
                return inventory
            },
            worktreeMutationCoordinator: coordinator
        )
        restoringModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(
            restoringModel,
            store: restoringSurfaces
        )
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )],
            presentationTargets: [selection]
        )
        #expect(restoringModel.activeBorrowedTmuxSelection == nil)

        coordinator.release(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            reconciledRestorationTargets: [selection],
            requiresWorkspaceReestablishment: true
        )

        await establishmentGate.waitUntilStarted()
        #expect(restoringModel.activeBorrowedTmuxSelection == selection)
        #expect(!coordinator.scopes.isEmpty)
        observerModel.startKwtInventory()
        try await Task.sleep(for: .milliseconds(100))
        #expect(inventoryLoads.count == 0)

        await establishmentGate.release()
        await waitUntilMainActor {
            inventoryLoads.count >= 1 && coordinator.scopes.isEmpty
        }
        await restoringModel.shutdown()
        await observerModel.shutdown()
    }

    @MainActor
    @Test("Empty project can resolve an uncertain removal")
    func emptyProjectResolvesUncertainRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees = []
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let inventory = Self.inventory(project: project, worktrees: [])
        let coordinator = WorktreeMutationCoordinator()
        let inventoryLoads = Counter()
        let removalError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                switch inventoryLoads.increment() {
                case 1:
                    return inventory
                case 2:
                    throw KwtInventoryError.commandFailed(
                        host: "this Mac",
                        status: 75
                    )
                default:
                    return inventory
                }
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _ in throw removalError }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            removalError.localizedDescription
        )))
        #expect(inventoryLoads.count == 2)
        #expect(!coordinator.scopes.isEmpty)

        model.startKwtInventory()
        await waitUntilMainActor {
            inventoryLoads.count >= 3 && coordinator.scopes.isEmpty
        }
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Remove Project fences worktree changes and protected attachment"
    )
    func removeProjectFencesProjectOperationsAcrossScenes() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.projects[0].scopedKey = "github.com/kenn-io/ghosthub"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let removableWorktree = WorktreeSummary(
            id: UUID(),
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "worktree:/tmp/ghosthub-concurrent",
            registryID: "mm-wt-concurrent",
            name: "concurrent",
            path: "/tmp/ghosthub-concurrent",
            branch: "feature/removable",
            isPrimary: false,
            generation: "0123456789abcdef0123456789abcdef"
        )
        snapshot.worktrees.append(removableWorktree)
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let probeGate = KillGate()
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let creationCalls = Counter()
        let worktreeRemovalCalls = Counter()
        let importCalls = Counter()
        let pathResolutions = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                await probeGate.suspend()
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let competingModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                _ = pathResolutions.increment()
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtWorktreeCreator: { _, _, _ in
                _ = creationCalls.increment()
            },
            kwtWorktreeRemover: { _, _, _, _ in
                _ = worktreeRemovalCalls.increment()
            },
            worktreeMutationCoordinator: coordinator,
            kwtPullRequestImporter: { _, _, _ in
                _ = importCalls.increment()
                throw KwtPullRequestError.malformedOutput(host: "This Mac")
            }
        )
        let worktreeRemovalRequest = try await competingModel
            .prepareWorktreeRemoval(removableWorktree.id)

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await removalModel.unregisterProject(
                project,
                confirmedHost: host
            )
        }
        await probeGate.waitUntilStarted()

        await #expect(throws: KwtWorktreeError.creationInProgress) {
            try await competingModel.createWorktree(
                WorktreeCreateRequest(
                    projectID: project.id,
                    branchName: "feature/concurrent",
                    createsBranch: true
                )
            )
        }
        await #expect(throws: KwtPullRequestError.importInProgress) {
            try await competingModel.importPullRequest(
                PullRequestImportRequest(
                    projectID: project.id,
                    pullRequestID: "github:github.com/kenn-io/ghosthub#94"
                )
            )
        }
        await #expect(throws: KwtWorktreeError.removalInProgress) {
            try await competingModel.removeWorktree(worktreeRemovalRequest)
        }
        competingModel.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { pathResolutions.count == 1 }
        competingModel.prepareActiveBorrowedTmuxSurface()

        #expect(creationCalls.count == 0)
        #expect(worktreeRemovalCalls.count == 0)
        #expect(importCalls.count == 0)
        #expect(surfaceStore.requestCount == 0)
        #expect(removalCalls.count == 0)

        await probeGate.release()
        #expect(await removalTask.value == .success(project.name))
        #expect(removalCalls.count == 1)
        competingModel.prepareActiveBorrowedTmuxSurface()
        #expect(surfaceStore.requestCount == 0)
        #expect(competingModel.snapshot.project(id: project.id) == nil)
        #expect(competingModel.snapshot.worktree(id: worktree.id) == nil)
        #expect(coordinator.scopes.isEmpty)
        await removalModel.shutdown()
        await competingModel.shutdown()
    }

    @MainActor
    @Test("Protected attachment fences before its view renders")
    func protectedAttachmentFencesBeforeRendering() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator
        )

        model.openBorrowedTmuxSession(selection)

        #expect(coordinator.scopes == [
            WorktreeMutationCoordinator.Scope(
                hostID: project.hostID,
                projectIdentity: project.scopedKey
            ),
        ])
        let hostingView = hostView(rootView: AnyView(
            SceneModelRootHarness(model: model)
        ))
        #expect(coordinator.scopes.count == 1)
        withExtendedLifetime(hostingView) {}
        await model.shutdown()
    }

    @MainActor
    @Test("Protected attachment retries after a competing mutation")
    func protectedAttachmentRetriesAfterMutation() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let pathResolutions = Counter()
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        #expect(coordinator.acquire(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        ))
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                _ = pathResolutions.increment()
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator
        )

        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            pathResolutions.count == 1
                && model.activeBorrowedTmuxSelection == selection
        }
        model.prepareActiveBorrowedTmuxSurface()

        #expect(surfaceStore.requestCount == 0)
        #expect(coordinator.scopes == [scope])

        coordinator.release(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        )

        await waitUntilMainActor {
            surfaceStore.requestCount == 1
                && coordinator.scopes == [scope]
        }
        await model.shutdown()
    }

    @MainActor
    @Test("Disconnected protected attachment waits for reconnect")
    func disconnectedProtectedAttachmentWaitsForReconnect() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let establishmentGate = BlockingGate()
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in
                establishmentGate.wait()
                return .success(false)
            },
            tmuxReconnectIntervals: [.seconds(10)]
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { establishmentGate.didStart }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        establishmentGate.release()
        await waitUntilMainActor { coordinator.scopes.isEmpty }

        #expect(coordinator.acquire(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        ))
        coordinator.release(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        )
        try await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.scopes.isEmpty)
        #expect(surfaceStore.requestCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Protected reconnect fences renewed establishment")
    func protectedReconnectFencesEstablishment() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let probeAttempts = Counter()
        let initialEstablishmentGate = BlockingGate()
        let reconnectEstablishmentGate = BlockingGate()
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let attachmentModel = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in
                switch probeAttempts.increment() {
                case 1:
                    initialEstablishmentGate.wait()
                    return .success(false)
                case 2:
                    return .success(false)
                default:
                    reconnectEstablishmentGate.wait()
                    return .success(true)
                }
            },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        attachmentModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(
            attachmentModel,
            store: surfaceStore
        )
        await waitUntilMainActor { initialEstablishmentGate.didStart }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        initialEstablishmentGate.release()
        await waitUntilMainActor { reconnectEstablishmentGate.didStart }

        let result = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Another project or worktree change is already in progress."
        )))
        #expect(removalCalls.count == 0)
        #expect(!coordinator.scopes.isEmpty)
        reconnectEstablishmentGate.release()
        await attachmentModel.shutdown()
        await removalModel.shutdown()
    }

    @MainActor
    @Test(
        "Remove Project waits for protected establishment confirmation"
    )
    func removeProjectWaitsForProtectedEstablishment() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let establishmentGate = BlockingGate()
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let attachmentModel = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in
                establishmentGate.wait()
                return .success(true)
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        attachmentModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(
            attachmentModel,
            store: surfaceStore
        )
        await waitUntilMainActor { establishmentGate.didStart }
        #expect(attachmentModel.activeBorrowedTmuxSessionIsConnected)

        let result = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Another project or worktree change is already in progress."
        )))
        #expect(removalCalls.count == 0)
        #expect(!coordinator.scopes.isEmpty)

        establishmentGate.release()
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        await attachmentModel.shutdown()
        await removalModel.shutdown()
    }

    @MainActor
    @Test("Protected establishment keeps probing while connected")
    func protectedEstablishmentKeepsProbing() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let probes = TmuxExactProbeResultQueue([
            .success(false),
            .success(false),
            .success(true),
        ])
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in probes.removeFirst() },
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { probes.count >= 2 }
        try await Task.sleep(for: .milliseconds(20))

        #expect(probes.count == 3)
        #expect(coordinator.scopes.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("Default-socket establishment keeps a finite probe schedule")
    func defaultSocketEstablishmentStopsProbing() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let probes = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                _ = probes.increment()
                return .success([])
            },
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { probes.count >= 2 }
        try await Task.sleep(for: .milliseconds(20))

        #expect(probes.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("Pathless rebind releases protected establishment fence")
    func pathlessRebindReleasesProtectedEstablishmentFence() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let establishmentGate = BlockingGate()
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in
                establishmentGate.wait()
                return .success(true)
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { establishmentGate.didStart }
        #expect(!coordinator.scopes.isEmpty)

        var reboundSelection = selection
        reboundSelection.workspacePath = nil
        model.openBorrowedTmuxSession(reboundSelection)

        #expect(coordinator.scopes.isEmpty)
        establishmentGate.release()
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project refreshes protected endpoints before removal")
    func removeProjectRefreshesProtectedEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        var refreshedWorktree = try #require(
            environment.snapshot.worktrees.first
        )
        refreshedWorktree.tmuxSessionName = "kwt-ghosthub-pr-94"
        refreshedWorktree.tmuxSocketName = "kwt-pr-94"
        let refreshedInventory = Self.inventory(
            project: project,
            worktrees: [refreshedWorktree]
        )
        let identityReads = Counter()
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in refreshedInventory },
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-pr-94” is still running on its protected "
                + "tmux server. Kill it before removing project “Ghosthub”."
        )))
        #expect(identityReads.count == 1)
        #expect(removalCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project revalidates the host after protected probes")
    func removeProjectRevalidatesHostAfterProtectedProbe() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let currentInventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let staleRepository = "repo:old-probe-endpoint-only"
        var staleInventory = currentInventory
        staleInventory.projects.append(KwtProjectInventory(
            project: KwtProjectRecord(
                repository: staleRepository,
                name: "Old Probe Endpoint Only",
                path: "/tmp/old-probe-endpoint-only",
                lastTouched: nil
            ),
            worktrees: [],
            warning: nil
        ))
        let oldEndpointInventory = staleInventory
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let probeGate = KillGate()
        let inventoryLoads = Counter()
        let servesOldEndpointInventory = LockedValue(false)
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                let inventory = servesOldEndpointInventory.load()
                    ? oldEndpointInventory : currentInventory
                _ = inventoryLoads.increment()
                return inventory
            },
            kwtProjectRemoval: { path, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                await probeGate.suspend()
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        model.startKwtInventory()
        await waitUntilMainActor { inventoryLoads.count >= 1 }
        let loadsBeforeRemoval = inventoryLoads.count
        servesOldEndpointInventory.store(true)
        let publishedRepositories = LockedValue<[Set<String>]>([])
        let snapshotObservation = model.$snapshot.sink { snapshot in
            publishedRepositories.withLock {
                $0.append(Set(snapshot.projects.map(\.scopedKey)))
            }
        }

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await probeGate.waitUntilStarted()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "wesm@replacement-office-linux"
            ),
        ])
        servesOldEndpointInventory.store(false)
        model.refreshHosts()
        await probeGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        await waitUntilMainActor {
            inventoryLoads.count >= loadsBeforeRemoval + 2
        }
        #expect(!publishedRepositories.load().contains {
            $0.contains(staleRepository)
        })
        #expect(removalCalls.count == 0)
        withExtendedLifetime(snapshotObservation) {}
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project revalidates the host after unregistration")
    func removeProjectRevalidatesHostAfterUnregistration() async throws {
        let environment = try setupRemoteEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let removalGate = KillGate()
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                await removalGate.suspend()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await removalGate.waitUntilStarted()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "wesm@replacement-office-linux"
            ),
        ])
        model.refreshHosts()
        await removalGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        #expect(coordinator.scopes.isEmpty)
        let registryHost = WorktreeMutationCoordinator.ProjectRegistryHost(
            target: .ssh(SSHHostInfo(
                user: "wesm",
                hostname: "office-linux",
                port: 22,
                platform: .posix
            ))
        )
        #expect(coordinator.acquireProjectRegistry(host: registryHost))
        coordinator.releaseProjectRegistry(host: registryHost)
        await model.shutdown()
    }

    @MainActor
    @Test("Registration change cannot restore on a replacement host")
    func registrationChangeDoesNotRestoreOnReplacementHost() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-root"
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let removalGate = KillGate()
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _ in
                await removalGate.suspend()
                throw KwtProjectCommandError.commandFailed(
                    host: initialHost.name,
                    status: 1,
                    code: "registration_changed",
                    message: "project registration changed",
                    retryable: true,
                    details: [:]
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let initialRequestCount = surfaceStore.requestCount

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await removalGate.waitUntilStarted()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "wesm@replacement-office-linux"
            ),
        ])
        model.refreshHosts()
        await removalGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        #expect(coordinator.scopes.isEmpty)
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(surfaceStore.requestCount == initialRequestCount)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Host deletion releases removal coordination",
        arguments: ProjectRemovalHostDeletionPhase.allCases
    )
    func hostDeletionReleasesRemovalCoordination(
        phase: ProjectRemovalHostDeletionPhase
    ) async throws {
        let environment = try setupRemoteEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let inventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let suspensionGate = KillGate()
        let inventoryLoads = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let removalError = KwtInventoryError.commandFailed(
            host: initialHost.name,
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                if phase == .reconciliation,
                   inventoryLoads.increment() == 2 {
                    await suspensionGate.suspend()
                }
                return inventory
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _ in
                switch phase {
                case .unregistration:
                    await suspensionGate.suspend()
                    return KwtProjectRecord(
                        repository: project.scopedKey,
                        name: project.name,
                        path: path,
                        lastTouched: nil
                    )
                case .reconciliation:
                    throw removalError
                }
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await suspensionGate.waitUntilStarted()
        configuredHosts.send([])
        model.refreshHosts()
        await suspensionGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        #expect(coordinator.scopes.isEmpty)
        let registryHost = WorktreeMutationCoordinator.ProjectRegistryHost(
            target: .ssh(SSHHostInfo(
                user: "wesm",
                hostname: "office-linux",
                port: 22,
                platform: .posix
            ))
        )
        #expect(coordinator.acquireProjectRegistry(host: registryHost))
        coordinator.releaseProjectRegistry(host: registryHost)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project discards reconciliation from a changed host")
    func removeProjectDiscardsReconciliationFromChangedHost() async throws {
        let environment = try setupRemoteEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let currentInventory = Self.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let staleRepository = "repo:old-endpoint-only"
        var staleInventory = currentInventory
        staleInventory.projects.append(KwtProjectInventory(
            project: KwtProjectRecord(
                repository: staleRepository,
                name: "Old Endpoint Only",
                path: "/tmp/old-endpoint-only",
                lastTouched: nil
            ),
            worktrees: [],
            warning: nil
        ))
        let staleEndpointInventory = staleInventory
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let reconciliationGate = KillGate()
        let inventoryLoads = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let removalError = KwtInventoryError.commandFailed(
            host: initialHost.name,
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                switch inventoryLoads.increment() {
                case 1:
                    return currentInventory
                case 2:
                    await reconciliationGate.suspend()
                    return staleEndpointInventory
                default:
                    return currentInventory
                }
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _ in throw removalError },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        let publishedRepositories = LockedValue<[Set<String>]>([])
        let snapshotObservation = model.$snapshot.sink { snapshot in
            publishedRepositories.withLock {
                $0.append(Set(snapshot.projects.map(\.scopedKey)))
            }
        }

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await reconciliationGate.waitUntilStarted()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "wesm@replacement-office-linux"
            ),
        ])
        model.refreshHosts()
        await reconciliationGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        model.startKwtInventory()
        await waitUntilMainActor {
            inventoryLoads.count >= 3 && coordinator.scopes.isEmpty
        }
        #expect(!publishedRepositories.load().contains {
            $0.contains(staleRepository)
        })
        withExtendedLifetime(snapshotObservation) {}
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project authority rejects project identity drift")
    func removeProjectAuthorityRejectsProjectIdentityDrift() throws {
        let environment = try setupStandardEnvironment()
        let confirmedProject = try #require(
            environment.snapshot.projects.first
        )
        let currentHost = try #require(environment.snapshot.hosts.first)

        var movedProject = confirmedProject
        movedProject.rootPath = "/tmp/ghosthub-moved"
        #expect(WorkspaceSceneModel.validatedProjectRemovalTarget(
            confirmedProject,
            confirmedHostID: currentHost.id,
            capturedTarget: .local,
            currentProject: movedProject,
            currentHost: currentHost
        ) == nil)

        var replacedProject = confirmedProject
        replacedProject.scopedKey = "github.com/kenn-io/replacement"
        #expect(WorkspaceSceneModel.validatedProjectRemovalTarget(
            confirmedProject,
            confirmedHostID: currentHost.id,
            capturedTarget: .local,
            currentProject: replacedProject,
            currentHost: currentHost
        ) == nil)
    }

    @MainActor
    @Test("connection probe uses native PowerShell for Windows hosts")
    func connectionProbeUsesWindowsPowerShell() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { host, command in
                #expect(host.platform == .windows)
                #expect(command.contains("Get-Command tmux.exe"))
                #expect(command.contains("[Console]::Out.WriteLine()"))
                #expect(command.contains("GHOSTHUB_KWT_AVAILABLE"))
                if let managedPath =
                    KwtBinaryLocator.windowsRemoteManagedRelativePath(
                        revision:
                        KwtBinaryLocator.bundledRemoteRevision()
                    ) {
                    #expect(command.contains(
                        powerShellEncodedArgument(managedPath)
                    ))
                } else {
                    #expect(command.contains(
                        "$ghosthubKwtAvailable = $false"
                    ))
                }
                #expect(!command.contains("Get-Command kwt.exe"))
                #expect(!command.contains("command -v"))
                return (
                    status: 0,
                    stdout: Self.probeOutput(
                        [
                            "GHOSTHUB_SSH_REACHED",
                            "GHOSTHUB_TMUX_AVAILABLE",
                            "GHOSTHUB_KWT_AVAILABLE",
                        ],
                        startupOutput: "unterminated startup output"
                    ),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "arm-builder",
            name: "ARM Builder",
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .online)
        #expect(summary.platform == .windows)
        #expect(summary.diagnostics.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe distinguishes missing psmux from SSH failure")
    func connectionProbeReportsMissingPsmux() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
                (
                    status: 127,
                    stdout: Self.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_UNAVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "arm-builder",
            name: "ARM Builder",
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        ), protocolNonce: Self.probeNonce)
        let summary = try result.get()
        let diagnostic = try #require(summary.diagnostics.first)

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(diagnostic.code == .missingTmux)
        #expect(diagnostic.summary == "psmux is not available.")
        #expect(diagnostic.recoverySuggestion.contains("tmux.exe alias"))
        await model.shutdown()
    }

    @MainActor
    @Test("remote failures do not enter the workspace-wide error")
    func remoteFailureStaysHostScopedWhenLocalAlsoFails() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "offline",
            name: "Offline Host",
            platform: .linux,
            sshDestination: "offline"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: host.isRemote ? 127 : 1
                )
            },
            tmuxSessionDiscovery: { host in
                .failure(.shellFailed(status: host.isRemote ? 255 : 1))
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            if case .failed = model.workspaceInventoryState {
                return true
            }
            return false
        }

        guard case let .failed(message) = model.workspaceInventoryState else {
            Issue.record("Expected local inventory failure")
            await model.shutdown()
            return
        }
        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        #expect(!message.contains("Offline Host"))
        #expect(!message.contains("status 255"))
        #expect(
            model.workspaceInventoryWarningsByHost[remoteHostID]?
                .contains("status 255") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("duplicate project warnings appear once")
    func duplicateProjectWarningsAreDeduplicated() async throws {
        let environment = try setupStandardEnvironment()
        let warning = "project: temporary kwt failure"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in
                KwtHostInventory(projects: [
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: "first",
                            name: "project",
                            path: "/first",
                            lastTouched: nil
                        ),
                        worktrees: [],
                        warning: "temporary kwt failure"
                    ),
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: "second",
                            name: "project",
                            path: "/second",
                            lastTouched: nil
                        ),
                        worktrees: [],
                        warning: "temporary kwt failure"
                    ),
                ])
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.workspaceInventoryWarning != nil
        }
        #expect(model.workspaceInventoryWarning == warning)
        await model.shutdown()
    }
}

@MainActor
private struct SceneModelRootHarness: View {
    @ObservedObject var model: WorkspaceSceneModel
    let onOpenTmuxSession: (WorkspaceTmuxSessionSelection) -> Void
    @State private var selection: WorkspaceSelection

    init(
        model: WorkspaceSceneModel,
        onOpenTmuxSession: @escaping (
            WorkspaceTmuxSessionSelection
        ) -> Void = { _ in }
    ) {
        self.model = model
        self.onOpenTmuxSession = onOpenTmuxSession
        _selection = State(initialValue: model.selection)
    }

    var body: some View {
        RootView(
            display: WorkspaceDisplayState(
                snapshot: model.snapshot,
                suppressesAutomaticWorktreeSessionOpen:
                model.suppressesSelectedWorktreeSessionOpen,
                activeTmuxSession: model.activeBorrowedTmuxSelection,
                activeTmuxSessionIsConnected:
                model.activeBorrowedTmuxSessionIsConnected
            ),
            handlers: InteractionHandlers(
                openTmuxSession: onOpenTmuxSession
            ),
            selection: $selection
        )
    }
}

@MainActor
private final class SceneTmuxPaneSurfaceStub: NativeSessionPaneSurfacing {
    var blocksClipboardReads = false
    var launchError: Error?
    var launchFailureIsRetryable = false
    var childExitCode: UInt32?
    private(set) var closeObservers: [UUID: (Bool, UInt32?) -> Void] = [:]
    private(set) var lastObserverID: UUID?

    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool, UInt32?) -> Void
    ) {
        closeObservers[id] = onSurfaceClosed
        lastObserverID = id
    }
}

private enum SceneSurfaceLaunchError: LocalizedError {
    case rejected

    var errorDescription: String? {
        "The terminal rejected the replacement surface."
    }
}

@MainActor
private final class SceneTmuxSurfaceStoreStub: NativeSessionSurfaceStoring {
    let surface = SceneTmuxPaneSurfaceStub()
    var returnsSurface = true
    private(set) var requestCount = 0
    private(set) var lastConfiguration: TerminalSurfaceConfiguration?
    private(set) var requestedKeys: [SurfaceKey] = []
    private(set) var removedKeys: [SurfaceKey] = []
    private var retainedKeys: Set<SurfaceKey> = []

    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> (any NativeSessionPaneSurfacing)? {
        guard !retainedKeys.contains(key) else { return surface }
        retainedKeys.insert(key)
        requestCount += 1
        lastConfiguration = configuration
        requestedKeys.append(key)
        return returnsSurface ? surface : nil
    }

    func removeSurface(for key: SurfaceKey) {
        retainedKeys.remove(key)
        removedKeys.append(key)
    }
}

private final class TmuxDiscoveryResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values:
        [Result<[DiscoveredTmuxSession], TmuxBinaryError>]
    private var removalCount = 0

    init(_ values: [Result<[DiscoveredTmuxSession], TmuxBinaryError>]) {
        self.values = values
    }

    func removeFirst()
        -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        lock.withLock {
            removalCount += 1
            return values.removeFirst()
        }
    }

    var count: Int {
        lock.withLock { removalCount }
    }
}

private final class TmuxExactProbeResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<Bool, TmuxBinaryError>]
    private var removalCount = 0

    init(_ values: [Result<Bool, TmuxBinaryError>]) {
        self.values = values
    }

    func removeFirst() -> Result<Bool, TmuxBinaryError> {
        lock.withLock {
            removalCount += 1
            return values.removeFirst()
        }
    }

    var count: Int {
        lock.withLock { removalCount }
    }
}
