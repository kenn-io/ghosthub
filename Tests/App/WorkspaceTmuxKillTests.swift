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
                sshDestination: "user-a@old.example.com"
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
                sshDestination: "user-a@new.example.com"
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

}
