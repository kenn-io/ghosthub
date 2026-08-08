import Foundation
import GhosthubHerdr
import GhosthubPersistence
import GhosthubTestSupport
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Workspace Herdr presentation", .serialized)
@MainActor
struct WorkspaceHerdrPresentationTests {
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
        model.openBorrowedHerdrSession(herdr)
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.activeBorrowedHerdrSelection == herdr)

        model.openBorrowedTmuxSession(tmux)
        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(store.removedKeys.contains { $0.target == .herdrSession })
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
        model.openBorrowedHerdrSession(first)
        await launchHerdrSurface(model, store: store)
        let firstKey = try #require(store.requestedKeys.last)

        model.openBorrowedHerdrSession(first)
        model.prepareActiveBorrowedHerdrSurface()
        #expect(store.requestedKeys.last == firstKey)
        #expect(!store.removedKeys.contains(firstKey))

        model.openBorrowedHerdrSession(second)
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
        model.openBorrowedHerdrSession(.init(
            hostID: environment.hostID,
            name: "sleeping"
        ))

        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(store.requestedKeys.isEmpty)
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

        #expect(throws: HerdrSessionPresentationError.self) {
            try model.createHerdrSession(.init(
                hostID: environment.hostID,
                name: "api"
            ))
        }
        try model.restartHerdrSession(.init(
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

        try model.createHerdrSession(.init(
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

        try model.createHerdrSession(selection)
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
            try model.createHerdrSession(selection)
        } else {
            try model.restartHerdrSession(selection)
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

    @Test("manual retry respects destructive lifecycle fences")
    func manualRetryRespectsLifecycleFence() async throws {
        let environment = try environment()
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in .failure(.cancelled(host: "Local Mac")) },
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
        model.openBorrowedHerdrSession(selection)
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
        let discoveries = HerdrDiscoveryQueue([.available([])])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 9)

        await model.retryBorrowedHerdrSession(selection)

        #expect(discoveries.callCount == 1)
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
        model.openBorrowedHerdrSession(herdr)

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
        model.openBorrowedHerdrSession(herdr)
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
        model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        let close = try #require(store.surface.closeObservers.values.first)

        close(false, 9)

        await waitUntilMainActor(timeout: .seconds(1)) {
            discoveries.callCount == 2
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
        model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)

        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            store.requestedKeys.count == 2
        }

        #expect(discoveries.callCount == 1)
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
        model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)

        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedHerdrRecoveryState == nil
        }
        await waitUntilMainActor(timeout: .seconds(1)) {
            discoveries.callCount == 3
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
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                .failure(.commandFailed(
                    status: 255,
                    stderr: "Permission denied (publickey,password)."
                ))
            }
        )
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        model.openBorrowedHerdrSession(herdr)
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
        model.openBorrowedHerdrSession(WorkspaceHerdrSessionSelection(
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
        discovery: @escaping WorkspaceSceneModel.HerdrSessionDiscovery = {
            _ in .available([])
        },
        coordinator: HerdrSessionLifecycleCoordinator =
            HerdrSessionLifecycleCoordinator(),
        createdSessionDiscoveryDelays: [Duration] = [
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
        ]
    ) throws -> WorkspaceSceneModel {
        try makeModel(
            database: environment.database,
            localHostID: environment.hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeHerdrSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeHerdrPathProvider: { _ in .success("/usr/bin/herdr") },
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            herdrLifecycleCoordinator: coordinator,
            herdrSessionDiscovery: discovery,
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
