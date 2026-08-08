@preconcurrency import Dispatch
import Foundation
import GhosthubHerdr
import GhosthubPersistence
import GhosthubTestSupport
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("Workspace Herdr presentation", .serialized)
@MainActor
struct WorkspaceHerdrPresentationTests {
    enum SupersedingIntent: Sendable {
        case anotherHerdrSession
        case navigationAway
    }

    @Test("tmux and Herdr replace one another symmetrically")
    func presentationsAreExclusive() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(environment, store: store)
        let tmux = WorkspaceTmuxSessionSelection(
            hostID: environment.hostID,
            name: "tmux-work"
        )
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )

        model.openBorrowedTmuxSession(tmux)
        try await model.openBorrowedHerdrSession(herdr)
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.activeBorrowedHerdrSelection == herdr)

        model.openBorrowedTmuxSession(tmux)
        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(store.removedKeys.contains { $0.target == .herdrSession })
        await model.shutdown()
    }

    @Test("active capable Herdr presentation routes pane splits")
    func activeHerdrPaneSplitRouting() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let commands = Mutex<[String]>([])
        let model = try makeHerdrModel(
            environment,
            store: store,
            paneSplitCapabilityProvider: { _, _, _, name in
                .success(HerdrPaneSplitCapability(
                    version: .paneSplitting,
                    session: HerdrSessionRecord(
                        name: name,
                        isDefault: true,
                        state: .running,
                        sessionDirectory: "/tmp/herdr/\(name)",
                        socketPath: "/tmp/herdr/\(name)/herdr.sock"
                    )
                ))
            },
            paneSplitter: HerdrPaneSplitter { _, _, command in
                commands.withLock { $0.append(command) }
                return (0, "")
            }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )

        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        await waitUntilMainActor { model.canSplitActivePane }
        model.splitActivePane(.down)
        await waitUntilMainActor { commands.withLock(\.count) == 1 }

        #expect(commands.withLock { $0[0] }.contains("'--direction' 'down'"))
        await model.shutdown()
    }

    @Test("another Herdr session replaces the client; reselecting preserves it")
    func herdrIdentity() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(environment, store: store)
        let first = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        let second = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "worker"
        )
        try await model.openBorrowedHerdrSession(first)
        await launchHerdrSurface(model, store: store)
        let firstKey = try #require(store.requestedKeys.last)

        try await model.openBorrowedHerdrSession(first)
        model.prepareActiveBorrowedHerdrSurface()
        #expect(store.requestedKeys.last == firstKey)
        #expect(!store.removedKeys.contains(firstKey))

        try await model.openBorrowedHerdrSession(second)
        #expect(model.activeBorrowedHerdrSelection == second)
        #expect(store.removedKeys.contains(firstKey))
        await model.shutdown()
    }

    @Test("ordinary open rejects stopped inventory")
    func stoppedSessionDoesNotAttach() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrSessions.append(
            HerdrSessionSummary(
                name: "sleeping",
                isDefault: false,
                state: .stopped
            )
        )
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(environment, store: store)
        await #expect(throws: HerdrSessionPresentationError.self) {
            try await model.openBorrowedHerdrSession(.init(
                hostID: environment.hostID,
                name: "sleeping"
            ))
        }

        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(store.requestedKeys.isEmpty)
        await model.shutdown()
    }

    @Test("open revalidates running state after the displayed snapshot")
    func openRevalidatesRunningState() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let stopped = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .stopped
        )
        let discoveries = HerdrDiscoveryQueue([.available([stopped])])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )

        await #expect(throws: HerdrSessionPresentationError.self) {
            try await model.openBorrowedHerdrSession(.init(
                hostID: environment.hostID,
                name: "api"
            ))
        }

        #expect(discoveries.callCount == 1)
        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(store.requestedKeys.isEmpty)
        await model.shutdown()
    }

    @Test(
        "a delayed Herdr activation cannot override newer navigation",
        arguments: [
            SupersedingIntent.anotherHerdrSession,
            .navigationAway,
        ]
    )
    func delayedActivationRespectsNewerIntent(
        intent: SupersedingIntent
    ) async throws {
        var environment = try environment()
        let otherHostID = UUID()
        environment.snapshot.hosts.append(.fixture(
            id: otherHostID,
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@build.example.test",
            herdrSessions: [
                HerdrSessionSummary(
                    name: "review",
                    isDefault: false,
                    state: .running
                ),
            ],
            herdrAvailable: true
        ))
        let store = RecordingNativeSessionSurfaceStore()
        let localProbeStarted = Mutex(false)
        let releaseLocalProbe = DispatchSemaphore(value: 0)
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { host in
                if host == .local {
                    localProbeStarted.withLock { $0 = true }
                    releaseLocalProbe.wait()
                    return .available([
                        HerdrSessionSummary(
                            name: "api",
                            isDefault: true,
                            state: .running
                        ),
                    ])
                }
                return .available([
                    HerdrSessionSummary(
                        name: "review",
                        isDefault: false,
                        state: .running
                    ),
                ])
            }
        )
        let delayed = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        let replacement = WorkspaceHerdrSessionSelection(
            hostID: otherHostID,
            name: "review"
        )

        let delayedActivation = Task {
            try? await model.openBorrowedHerdrSession(delayed)
        }
        await waitUntilMainActor {
            localProbeStarted.withLock { $0 }
        }
        model.selectFromUser(WorkspaceSelection(selectedHostID: otherHostID))
        if intent == .anotherHerdrSession {
            try await model.openBorrowedHerdrSession(replacement)
            #expect(model.activeBorrowedHerdrSelection == replacement)
        }

        releaseLocalProbe.signal()
        await delayedActivation.value

        #expect(model.activeBorrowedHerdrSelection == (
            intent == .anotherHerdrSession ? replacement : nil
        ))
        await model.shutdown()
    }

    @Test("create revalidates absence after the displayed snapshot")
    func createRevalidatesAbsence() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let store = RecordingNativeSessionSurfaceStore()
        let replacement = HerdrSessionSummary(
            name: "new-review",
            isDefault: false,
            state: .running
        )
        let discoveries = HerdrDiscoveryQueue([.available([replacement])])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )

        await #expect(throws: HerdrSessionPresentationError.self) {
            try await model.createHerdrSession(.init(
                hostID: environment.hostID,
                name: "new-review"
            ))
        }

        #expect(discoveries.callCount == 1)
        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(store.requestedKeys.isEmpty)
        await model.shutdown()
    }

    @Test("restart revalidates stopped state after the displayed snapshot")
    func restartRevalidatesStoppedState() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        environment.snapshot.hosts[0].herdrSessions.append(
            HerdrSessionSummary(
                name: "sleeping",
                isDefault: false,
                state: .stopped
            )
        )
        let store = RecordingNativeSessionSurfaceStore()
        let discoveries = HerdrDiscoveryQueue([.available([])])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )

        await #expect(throws: HerdrSessionPresentationError.self) {
            try await model.restartHerdrSession(.init(
                hostID: environment.hostID,
                name: "sleeping"
            ))
        }

        #expect(discoveries.callCount == 1)
        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(store.requestedKeys.isEmpty)
        await model.shutdown()
    }

    @Test("a delayed restart cannot replace newer tmux navigation")
    func delayedRestartRespectsNewerNavigation() async throws {
        var environment = try environment()
        let stopped = HerdrSessionSummary(
            name: "sleeping",
            isDefault: false,
            state: .stopped
        )
        environment.snapshot.hosts[0].herdrAvailable = true
        environment.snapshot.hosts[0].herdrSessions.append(stopped)
        let store = RecordingNativeSessionSurfaceStore()
        let probeStarted = Mutex(false)
        let releaseProbe = DispatchSemaphore(value: 0)
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                probeStarted.withLock { $0 = true }
                releaseProbe.wait()
                return .available([stopped])
            }
        )
        let restartTarget = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: stopped.name
        )
        let newerTmux = WorkspaceTmuxSessionSelection(
            hostID: environment.hostID,
            name: "tmux-work"
        )

        let restart = Task {
            try await model.restartHerdrSession(restartTarget)
        }
        await waitUntilMainActor { probeStarted.withLock { $0 } }
        model.openBorrowedTmuxSession(newerTmux)
        releaseProbe.signal()

        await #expect(throws: CancellationError.self) {
            try await restart.value
        }
        #expect(model.activeBorrowedTmuxSelection == newerTmux)
        #expect(model.activeBorrowedHerdrSelection == nil)
        await model.shutdown()
    }

    @Test("a delayed create cannot replace newer tmux navigation")
    func delayedCreateRespectsNewerNavigation() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let store = RecordingNativeSessionSurfaceStore()
        let probeStarted = Mutex(false)
        let releaseProbe = DispatchSemaphore(value: 0)
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                probeStarted.withLock { $0 = true }
                releaseProbe.wait()
                return .available([])
            }
        )
        let createTarget = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "new-agent"
        )
        let newerTmux = WorkspaceTmuxSessionSelection(
            hostID: environment.hostID,
            name: "tmux-work"
        )

        let create = Task {
            try await model.createHerdrSession(createTarget)
        }
        await waitUntilMainActor { probeStarted.withLock { $0 } }
        model.openBorrowedTmuxSession(newerTmux)
        releaseProbe.signal()

        await #expect(throws: CancellationError.self) {
            try await create.value
        }
        #expect(model.activeBorrowedTmuxSelection == newerTmux)
        #expect(model.activeBorrowedHerdrSelection == nil)
        await model.shutdown()
    }

    @Test("create rejects collisions and restart launches stopped sessions")
    func createAndRestartPreconditions() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        environment.snapshot.hosts[0].herdrSessions.append(
            HerdrSessionSummary(
                name: "sleeping",
                isDefault: false,
                state: .stopped
            )
        )
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(environment, store: store)

        await #expect(throws: HerdrSessionPresentationError.self) {
            try await model.createHerdrSession(.init(
                hostID: environment.hostID,
                name: "api"
            ))
        }
        try await model.restartHerdrSession(.init(
            hostID: environment.hostID,
            name: "sleeping"
        ))
        await launchHerdrSurface(model, store: store)
        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("--session"))
        #expect(command.contains("sleeping"))
        await model.shutdown()
    }

    @Test("create launches a new named session")
    func createLaunchesNamedSession() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(environment, store: store)

        try await model.createHerdrSession(.init(
            hostID: environment.hostID,
            name: "new-review"
        ))
        await launchHerdrSurface(model, store: store)

        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("--session"))
        #expect(command.contains("new-review"))
        await model.shutdown()
    }

    @Test("create stays pending until discovery confirms it is running")
    func createWaitsForRunningDiscovery() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let running = HerdrSessionSummary(
            name: "new-review",
            isDefault: false,
            state: .running
        )
        let discoveries = HerdrDiscoveryQueue([
            .available([]),
            .available([running]),
            .available([running]),
        ])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() },
            coordinator: coordinator,
            createdSessionDiscoveryDelays: [.milliseconds(100)]
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "new-review"
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )

        try await model.createHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        await waitUntilMainActor { discoveries.callCount == 1 }

        #expect(coordinator.isPending(key))
        await waitUntilMainActor { !coordinator.isPending(key) }
        #expect(discoveries.callCount >= 2)
        await model.shutdown()
    }

    @Test(
        "failed constructive launches retry with lifecycle intent",
        arguments: [
            HerdrSessionLifecycleCoordinator.OperationKind.create,
            .restart,
        ]
    )
    func constructiveRetryPreservesLaunchIntent(
        kind: HerdrSessionLifecycleCoordinator.OperationKind
    ) async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let sessionName = kind == .create ? "new-review" : "sleeping"
        if kind == .restart {
            environment.snapshot.hosts[0].herdrSessions.append(
                HerdrSessionSummary(
                    name: sessionName,
                    isDefault: false,
                    state: .stopped
                )
            )
        }
        let store = RecordingNativeSessionSurfaceStore(
            launchError: HerdrCommandError.unavailable
        )
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeHerdrModel(
            environment,
            store: store,
            coordinator: coordinator
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: sessionName
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )

        if kind == .create {
            try await model.createHerdrSession(selection)
        } else {
            try await model.restartHerdrSession(selection)
        }
        await launchHerdrSurface(model, store: store)
        await waitUntilMainActor { !coordinator.isPending(key) }

        await model.retryBorrowedHerdrSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return store.requestedConfigurations.count == 2
        }

        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("--session"))
        #expect(!command.contains("session attach"))
        #expect(coordinator.isPending(key))
        await model.shutdown()
    }

    @Test(
        "constructive retry revalidates the original launch state",
        arguments: [
            HerdrSessionLifecycleCoordinator.OperationKind.create,
            .restart,
        ]
    )
    func constructiveRetryRevalidatesLaunchState(
        kind: HerdrSessionLifecycleCoordinator.OperationKind
    ) async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let sessionName = kind == .create ? "new-review" : "sleeping"
        let stopped = HerdrSessionSummary(
            name: sessionName,
            isDefault: false,
            state: .stopped
        )
        if kind == .restart {
            environment.snapshot.hosts[0].herdrSessions.append(stopped)
        }
        let desiredState: HerdrDiscoveryResult = kind == .create
            ? .available([])
            : .available([stopped])
        let changedState: HerdrDiscoveryResult = kind == .create
            ? .available([
                HerdrSessionSummary(
                    name: sessionName,
                    isDefault: false,
                    state: .running
                ),
            ])
            : .available([])
        let discoveries = HerdrDiscoveryQueue([desiredState, changedState])
        let store = RecordingNativeSessionSurfaceStore(
            launchError: HerdrCommandError.unavailable
        )
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() },
            coordinator: coordinator
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: sessionName
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )

        if kind == .create {
            try await model.createHerdrSession(selection)
        } else {
            try await model.restartHerdrSession(selection)
        }
        await launchHerdrSurface(model, store: store)
        await waitUntilMainActor { !coordinator.isPending(key) }
        let configurationCount = store.requestedConfigurations.count

        await model.retryBorrowedHerdrSession(selection)

        #expect(discoveries.callCount == 2)
        #expect(store.requestedConfigurations.count == configurationCount)
        #expect(!coordinator.isPending(key))
        await model.shutdown()
    }

    @Test(
        "constructive retry recovers from path-resolution failure",
        arguments: [
            HerdrSessionLifecycleCoordinator.OperationKind.create,
            .restart,
        ]
    )
    func constructiveRetryAfterResolutionFailure(
        kind: HerdrSessionLifecycleCoordinator.OperationKind
    ) async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let sessionName = kind == .create ? "new-review" : "sleeping"
        if kind == .restart {
            environment.snapshot.hosts[0].herdrSessions.append(
                HerdrSessionSummary(
                    name: sessionName,
                    isDefault: false,
                    state: .stopped
                )
            )
        }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let resolutionCount = Mutex(0)
        let running = HerdrSessionSummary(
            name: sessionName,
            isDefault: false,
            state: .running
        )
        let discoveries = HerdrDiscoveryQueue([
            .available(kind == .create ? [] : [
                HerdrSessionSummary(
                    name: sessionName,
                    isDefault: false,
                    state: .stopped
                ),
            ]),
            .available(kind == .create ? [] : [
                HerdrSessionSummary(
                    name: sessionName,
                    isDefault: false,
                    state: .stopped
                ),
            ]),
            .available([running]),
        ])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() },
            coordinator: coordinator,
            nativeHerdrPathProvider: { _ in
                let count = resolutionCount.withLock { count in
                    count += 1
                    return count
                }
                return count == 1
                    ? .failure(.unavailable)
                    : .success("/new/bin/herdr")
            }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: sessionName
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )

        if kind == .create {
            try await model.createHerdrSession(selection)
        } else {
            try await model.restartHerdrSession(selection)
        }
        await waitUntilMainActor { !coordinator.isPending(key) }

        await model.retryBorrowedHerdrSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.prepareActiveBorrowedHerdrSurface()
            return resolutionCount.withLock { $0 } == 2
                && !store.requestedConfigurations.isEmpty
        }
        await waitUntilMainActor { !coordinator.isPending(key) }

        #expect(resolutionCount.withLock { $0 } == 2)
        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("/new/bin/herdr"))
        #expect(command.contains("--session"))
        await model.shutdown()
    }

    @Test("manual retry respects destructive lifecycle fences")
    func manualRetryRespectsLifecycleFence() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                .available([
                    HerdrSessionSummary(
                        name: "api",
                        isDefault: true,
                        state: .running
                    ),
                ])
            },
            coordinator: coordinator
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 9)
        let operation = try #require(coordinator.begin(.stop, key: key))

        await model.retryBorrowedHerdrSession(selection)
        #expect(store.removedKeys.count == 1)

        coordinator.willStop(operation)
        coordinator.finish(operation, outcome: .failed)
        await model.retryBorrowedHerdrSession(selection)
        #expect(store.removedKeys.count == 1)
        await model.shutdown()
    }

    @Test("manual retry probes the exact running session before attaching")
    func manualRetryRequiresRunningSession() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let discoveries = HerdrDiscoveryQueue([
            .available([
                HerdrSessionSummary(
                    name: "api",
                    isDefault: true,
                    state: .running
                ),
            ]),
            .available([]),
        ])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 9)

        await model.retryBorrowedHerdrSession(selection)

        #expect(discoveries.callCount == 2)
        #expect(store.removedKeys.count == 1)
        await model.shutdown()
    }

    @Test("leaving session navigation detaches Herdr")
    func navigationClosesHerdr() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(environment, store: store)
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(herdr)

        model.closeBorrowedHerdrSession(herdr)
        model.selectFromUser(WorkspaceSelection(
            selectedHostID: environment.hostID,
            selectedProjectID: environment.projectID,
            selectedWorktreeID: environment.worktreeID
        ))

        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(model.selection.selectedWorktreeID == environment.worktreeID)
        await model.shutdown()
    }

    @Test("manual detach does not enter automatic recovery")
    func manualDetachDoesNotRetry() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(environment, store: store)
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)

        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 0)
        try? await Task.sleep(for: .milliseconds(25))

        #expect(store.requestedKeys.count == 1)
        #expect(model.activeBorrowedHerdrRecoveryState == nil)
        await model.shutdown()
    }

    @Test("non-transport Herdr exit refreshes running inventory")
    func nonTransportExitRefreshesInventory() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let discoveries = HerdrDiscoveryQueue([
            .available([running]),
            .available([running]),
            .available([]),
        ])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )
        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { discoveries.callCount == 1 }
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        let close = try #require(store.surface.closeObservers.values.first)

        close(false, 9)

        await waitUntilMainActor(timeout: .seconds(1)) {
            discoveries.callCount == 3
        }
        #expect(model.snapshot.host(id: environment.hostID)?
            .herdrSessions.contains(where: { $0.name == "api" }) == false)
        await model.shutdown()
    }

    @Test("remote transport loss probes the exact session before relaunch")
    func remoteTransportRecovery() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let discoveries = HerdrDiscoveryQueue([
            .available([
                HerdrSessionSummary(name: "api", isDefault: true, state: .running),
            ]),
            .available([
                HerdrSessionSummary(name: "api", isDefault: true, state: .running),
            ]),
        ])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)

        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            store.requestedKeys.count == 2
        }

        #expect(discoveries.callCount == 2)
        #expect(model.activeBorrowedHerdrSelection == herdr)
        await model.shutdown()
    }

    @Test(
        "missing session and unavailable Herdr stop recovery",
        arguments: [
            HerdrDiscoveryResult.available([]),
            HerdrDiscoveryResult.unavailable,
        ]
    )
    func recoveryStopConditions(result: HerdrDiscoveryResult) async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let discoveries = HerdrDiscoveryQueue([
            .available([running]),
            .available([running]),
            result,
            result,
        ])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )
        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { discoveries.callCount == 1 }
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)

        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedHerdrRecoveryState == nil
        }
        await waitUntilMainActor(timeout: .seconds(1)) {
            discoveries.callCount == 4
        }

        #expect(store.requestedKeys.count == 1)
        switch result {
        case .available:
            #expect(model.snapshot.host(id: environment.hostID)?
                .herdrSessions.contains(where: { $0.name == "api" }) == false)
        case .unavailable:
            #expect(model.snapshot.host(id: environment.hostID)?
                .herdrAvailable == false)
        case .failure:
            Issue.record("Unexpected recovery stop fixture")
        }
        await model.shutdown()
    }

    @Test("Herdr authentication failure enters shared connection review")
    func authenticationRecovery() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let discoveries = HerdrDiscoveryQueue([
            .available([running]),
            .failure(.commandFailed(
                status: 255,
                stderr: "Permission denied (publickey,password)."
            )),
        ])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)

        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            model.sessionConnectionRecoveryRequest?.hostID
                == environment.hostID
        }

        guard case .needsAttention(_, true) =
            model.activeBorrowedHerdrRecoveryState
        else {
            Issue.record("Expected recoverable SSH attention state")
            return
        }
        await model.shutdown()
    }

    @Test("scene shutdown removes the Herdr client")
    func shutdownRemovesClient() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(environment, store: store)
        try await model.openBorrowedHerdrSession(WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        ))
        await launchHerdrSurface(model, store: store)
        let key = try #require(store.requestedKeys.last)

        await model.shutdown()

        #expect(store.removedKeys.contains(key))
    }

    private struct Environment {
        var database: WorkspaceDatabase
        var snapshot: WorkspaceSnapshot
        var hostID: UUID
        var projectID: UUID
        var worktreeID: UUID
    }

    private func environment() throws -> Environment {
        let database = try WorkspaceDatabase.inMemory()
        let hostID = UUID()
        let project = ProjectSummary.fixture(hostID: hostID)
        let worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id
        )
        return Environment(
            database: database,
            snapshot: .fixture(
                hosts: [
                    .fixture(
                        id: hostID,
                        tmuxSessions: [
                            TmuxSessionSummary(
                                name: "tmux-work",
                                managed: false,
                                windows: []
                            ),
                        ],
                        herdrSessions: [
                            HerdrSessionSummary(name: "api", isDefault: true, state: .running),
                            HerdrSessionSummary(
                                name: "worker",
                                isDefault: false,
                                state: .running
                            ),
                        ]
                    ),
                ],
                projects: [project],
                worktrees: [worktree]
            ),
            hostID: hostID,
            projectID: project.id,
            worktreeID: worktree.id
        )
    }

    private func remoteEnvironment() throws -> Environment {
        var environment = try environment()
        environment.snapshot.hosts[0] = .fixture(
            id: environment.hostID,
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@build.example.test",
            herdrSessions: [
                HerdrSessionSummary(name: "api", isDefault: true, state: .running),
            ]
        )
        return environment
    }

    private func makeHerdrModel(
        _ environment: Environment,
        store: RecordingNativeSessionSurfaceStore,
        discovery: WorkspaceSceneModel.HerdrSessionDiscovery? = nil,
        coordinator: HerdrSessionLifecycleCoordinator =
            HerdrSessionLifecycleCoordinator(),
        nativeHerdrPathProvider: @escaping @Sendable (CommandHost)
            -> Result<String, HerdrCommandError> = {
                _ in .success("/usr/bin/herdr")
            },
        paneSplitCapabilityProvider: @escaping NativeHerdrSessionCoordinator
            .PaneSplitCapabilityProvider = { _, _, _, _ in .success(nil) },
        paneSplitter: HerdrPaneSplitter = HerdrPaneSplitter(),
        createdSessionDiscoveryDelays: [Duration] = [
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
        ]
    ) throws -> WorkspaceSceneModel {
        let displayedSessions = environment.snapshot.host(id: environment.hostID)?
            .herdrSessions ?? []
        return try makeModel(
            database: environment.database,
            localHostID: environment.hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeHerdrSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeHerdrPathProvider: nativeHerdrPathProvider,
            herdrPaneSplitCapabilityProvider: paneSplitCapabilityProvider,
            herdrPaneSplitter: paneSplitter,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            herdrLifecycleCoordinator: coordinator,
            herdrSessionDiscovery: discovery ?? { _ in
                .available(displayedSessions)
            },
            createdSessionDiscoveryDelays: createdSessionDiscoveryDelays,
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
    }

    private func launchHerdrSurface(
        _ model: WorkspaceSceneModel,
        store: RecordingNativeSessionSurfaceStore
    ) async {
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return store.requestedKeys.last?.target == .herdrSession
        }
    }
}

final class HerdrDiscoveryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HerdrDiscoveryResult]
    private(set) var callCount = 0

    init(_ results: [HerdrDiscoveryResult]) {
        self.results = results
    }

    func removeFirst() -> HerdrDiscoveryResult {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return results.isEmpty ? .unavailable : results.removeFirst()
    }
}
