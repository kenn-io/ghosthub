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
                .failure(.notFound(shell: "office-linux"))
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
            user: "user-a",
            hostname: "old.example.com",
            port: nil
        ))
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "laptop",
                name: "Laptop",
                platform: .macOS,
                sshDestination: "user-a@old.example.com"
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
                sshDestination: "user-a@new.example.com"
            ),
        ]
        model.refreshHosts()
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.pendingCreatedTmuxSessionCount == 0)
        #expect(model.exhaustedCreatedTmuxSessionCount == 0)
        let updatedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "laptop" }
        )
        #expect(updatedHost.sshDestination == "user-a@new.example.com")
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
                sshDestination: "user-a@first-builder"
            ),
            SSHHost(
                configKey: "second-builder",
                name: "Second Builder",
                platform: .linux,
                sshDestination: "user-a@second-builder"
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
                sshDestination: "user-a@replacement-builder"
            ),
            SSHHost(
                configKey: "second-builder",
                name: "Second Builder",
                platform: .linux,
                sshDestination: "user-a@second-builder"
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
                sshDestination: "user-a@old.example.com"
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
                sshDestination: "user-a@new.example.com"
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
                sshDestination: "user-a@old.example.com"
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
                sshDestination: "user-a@new.example.com"
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
