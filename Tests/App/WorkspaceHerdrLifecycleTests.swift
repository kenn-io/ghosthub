import Combine
@preconcurrency import Dispatch
import Foundation
import GhosthubHerdr
import GhosthubPersistence
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("Workspace Herdr lifecycle", .serialized)
@MainActor
struct WorkspaceHerdrLifecycleTests {
    @Test("stop detaches every scene and retains a stopped row")
    func stopAcrossScenes() async throws {
        let environment = try environment()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let client = LifecycleClientStub(records: [
            "agent": Self.record(name: "agent", state: .running),
        ])
        let first = try makeHerdrModel(
            environment,
            coordinator: coordinator,
            client: client
        )
        let second = try makeHerdrModel(
            environment,
            coordinator: coordinator,
            client: client
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "agent"
        )
        try await first.openBorrowedHerdrSession(selection)
        try await second.openBorrowedHerdrSession(selection)

        let request = try await first.prepareHerdrSessionLifecycle(
            selection,
            action: .stop
        )
        try await first.performHerdrSessionLifecycle(request)

        #expect(first.activeBorrowedHerdrSelection == nil)
        #expect(second.activeBorrowedHerdrSelection == nil)
        #expect(!first.herdrReconnectSupervisorIsRunning)
        #expect(!second.herdrReconnectSupervisorIsRunning)
        #expect(first.snapshot.host(id: environment.hostID)?
            .herdrSessions.first(where: { $0.name == "agent" })?.state
            == .stopped)
        #expect(second.snapshot.host(id: environment.hostID)?
            .herdrSessions.first(where: { $0.name == "agent" })?.state
            == .stopped)
        await first.shutdown()
        await second.shutdown()
    }

    @Test("delete removes a stopped named session")
    func deleteStoppedSession() async throws {
        let environment = try environment()
        let client = LifecycleClientStub(records: [
            "sleeping": Self.record(name: "sleeping", state: .stopped),
        ])
        let model = try makeHerdrModel(environment, client: client)
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "sleeping"
        )

        let request = try await model.prepareHerdrSessionLifecycle(
            selection,
            action: .delete
        )
        try await model.performHerdrSessionLifecycle(request)

        #expect(model.snapshot.host(id: environment.hostID)?
            .herdrSessions.contains(where: { $0.name == "sleeping" })
            == false)
        await model.shutdown()
    }

    @Test("the default session can never be deleted")
    func defaultDeleteRejected() async throws {
        let environment = try environment()
        let client = LifecycleClientStub(records: [
            "default": Self.record(
                name: "default",
                isDefault: true,
                state: .stopped
            ),
        ])
        let model = try makeHerdrModel(environment, client: client)

        await #expect(throws: HerdrSessionLifecycleError.self) {
            _ = try await model.prepareHerdrSessionLifecycle(
                .init(hostID: environment.hostID, name: "default"),
                action: .delete
            )
        }
        #expect(client.mutationCount == 0)
        await model.shutdown()
    }

    @Test("a failed stop retains the running row")
    func failedStopRetainsInventory() async throws {
        let environment = try environment()
        let client = LifecycleClientStub(
            records: [
                "agent": Self.record(name: "agent", state: .running),
            ],
            mutationResult: .failure(.commandFailed(
                status: 1,
                code: "session_stop_failed",
                message: "still busy"
            ))
        )
        let model = try makeHerdrModel(environment, client: client)
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "agent"
        )
        try await model.openBorrowedHerdrSession(selection)
        let request = try await model.prepareHerdrSessionLifecycle(
            selection,
            action: .stop
        )

        await #expect(throws: HerdrSessionLifecycleError.self) {
            try await model.performHerdrSessionLifecycle(request)
        }

        #expect(model.snapshot.host(id: environment.hostID)?
            .herdrSessions.first(where: { $0.name == "agent" })?.state
            == .running)
        await model.shutdown()
    }

    @Test("a newer stop fences failed-stop reconciliation")
    func newerStopFencesFailedStopReconciliation() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0] = .fixture(
            id: environment.hostID,
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@build.example.test",
            herdrSessions: [
                .init(name: "agent", isDefault: false, state: .running),
            ],
            herdrAvailable: true
        )
        let coordinator = HerdrSessionLifecycleCoordinator()
        let client = LifecycleClientStub(
            records: [
                "agent": Self.record(name: "agent", state: .running),
            ],
            mutationResult: .failure(.commandFailed(
                status: 1,
                code: "session_stop_failed",
                message: "still busy"
            ))
        )
        let store = RecordingNativeSessionSurfaceStore()
        let calls = Mutex(0)
        let reconciliationGate = BlockingGate()
        let connection = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config", "dev@build.example.test",
        ])
        let probedArguments = Mutex<[String]?>(nil)
        let running = HerdrSessionSummary(
            name: "agent",
            isDefault: false,
            state: .running
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.hostID,
            snapshot: environment.snapshot,
            nativeHerdrSurfaceStore: store,
            nativeHerdrPathProvider: { _ in .success("/usr/bin/herdr") },
            herdrLifecycleCoordinator: coordinator,
            herdrSessionRecordReader: { name, _, _ in
                client.record(named: name)
            },
            herdrSessionMutator: { action, confirmed, _, _ in
                client.mutate(action, confirmed: confirmed)
            },
            herdrSSHConnectionSnapshotProvider: { _ in connection },
            herdrSessionDiscovery: { _ in
                calls.withLock { value in
                    value += 1
                }
                return .available([running])
            },
            herdrSessionExactProbe: { _, _, arguments in
                probedArguments.withLock { $0 = arguments }
                return await Task.detached {
                    reconciliationGate.block()
                    return HerdrSessionProbeOutcome.absent
                }.value
            }
        )
        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { calls.withLock { $0 } == 1 }
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "agent"
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        try await model.openBorrowedHerdrSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return store.requestedConfigurations.count == 1
        }
        let request = try await model.prepareHerdrSessionLifecycle(
            selection,
            action: .stop
        )

        await #expect(throws: HerdrSessionLifecycleError.self) {
            try await model.performHerdrSessionLifecycle(request)
        }
        await reconciliationGate.waitUntilBlocked()
        #expect(probedArguments.withLock { $0 } == connection.arguments)
        let newerStop = try #require(coordinator.begin(.stop, key: key))
        coordinator.willStop(newerStop)
        reconciliationGate.open()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(store.requestedConfigurations.count == 1)
        #expect(model.activeBorrowedHerdrSelection == selection)
        coordinator.finish(newerStop, outcome: .failed)
        await model.shutdown()
    }

    @Test("a changed host endpoint invalidates a confirmed request")
    func hostEndpointChange() async throws {
        let environment = try environment()
        let client = LifecycleClientStub(records: [
            "agent": Self.record(name: "agent", state: .running),
        ])
        let model = try makeHerdrModel(environment, client: client)
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "agent"
        )
        let request = try await model.prepareHerdrSessionLifecycle(
            selection,
            action: .stop
        )
        model.snapshot.hosts[0].kind = .remote
        model.snapshot.hosts[0].platform = .linux
        model.snapshot.hosts[0].sshDestination = "agent@new-host.test"

        await #expect(throws: HerdrSessionLifecycleRequestError.self) {
            try await model.performHerdrSessionLifecycle(request)
        }
        #expect(client.mutationCount == 0)
        await model.shutdown()
    }

    @Test("effective SSH route drift invalidates a confirmed request")
    func effectiveSSHRouteChange() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0] = .fixture(
            id: environment.hostID,
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@build-alias",
            herdrSessions: [
                .init(name: "agent", isDefault: false, state: .running),
            ],
            herdrAvailable: true
        )
        let client = LifecycleClientStub(records: [
            "agent": Self.record(name: "agent", state: .running),
        ])
        let route = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.hostID,
            snapshot: environment.snapshot,
            nativeHerdrPathProvider: { _ in .success("/usr/bin/herdr") },
            herdrSessionRecordReader: { name, _, _ in
                client.record(named: name)
            },
            herdrSessionMutator: { action, confirmed, _, _ in
                client.mutate(action, confirmed: confirmed)
            },
            herdrSSHConnectionSnapshotProvider: { _ in
                let number = route.withLock { value in
                    value += 1
                    return value
                }
                return SSHConnectionArgumentsSnapshot(arguments: [
                    "-o", "HostName=route-\(number).example.test",
                ])
            }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "agent"
        )
        let request = try await model.prepareHerdrSessionLifecycle(
            selection,
            action: .stop
        )

        await #expect(throws: HerdrSessionLifecycleRequestError.self) {
            try await model.performHerdrSessionLifecycle(request)
        }
        #expect(client.mutationCount == 0)
        await model.shutdown()
    }

    @Test("a replacement at the confirmed name is never mutated")
    func replacementLocationChange() async throws {
        let environment = try environment()
        let client = LifecycleClientStub(records: [
            "agent": Self.record(name: "agent", state: .running),
        ])
        let model = try makeHerdrModel(environment, client: client)
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "agent"
        )
        let request = try await model.prepareHerdrSessionLifecycle(
            selection,
            action: .stop
        )
        client.replaceRecord(HerdrSessionRecord(
            name: "agent",
            isDefault: false,
            state: .running,
            sessionDirectory: "/tmp/replacement/agent",
            socketPath: "/tmp/replacement/agent/herdr.sock"
        ))

        await #expect(throws: HerdrSessionLifecycleError.self) {
            try await model.performHerdrSessionLifecycle(request)
        }

        #expect(client.mutationCount == 0)
        await model.shutdown()
    }

    @Test(
        "constructive lifecycle events refresh every scene",
        arguments: [
            HerdrSessionLifecycleCoordinator.OperationKind.create,
            .restart,
        ], [
            HerdrSessionLifecycleCoordinator.Outcome.succeeded,
            .failed,
        ]
    )
    func constructiveEventsRefreshEveryScene(
        kind: HerdrSessionLifecycleCoordinator.OperationKind,
        outcome: HerdrSessionLifecycleCoordinator.Outcome
    ) async throws {
        let environment = try environment()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let discoveries = HerdrDiscoveryQueue([
            .available([]),
            .available([
                HerdrSessionSummary(
                    name: "new-agent",
                    isDefault: false,
                    state: .running
                ),
            ]),
        ])
        let model = try makeHerdrModel(
            environment,
            coordinator: coordinator,
            client: LifecycleClientStub(records: [:]),
            discovery: { _ in discoveries.removeFirst() }
        )
        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { discoveries.callCount == 1 }
        var changeCount = 0
        let cancellable = model.objectWillChange.sink { changeCount += 1 }
        defer { cancellable.cancel() }
        let operation = try #require(coordinator.begin(
            kind,
            key: .init(
                hostID: environment.hostID,
                sessionName: "new-agent"
            )
        ))

        #expect(changeCount > 0)
        coordinator.finish(operation, outcome: outcome)
        await waitUntilMainActor {
            model.snapshot.host(id: environment.hostID)?.herdrSessions
                .contains(where: {
                    $0.name == "new-agent" && $0.state == .running
                }) == true
        }

        #expect(discoveries.callCount == 2)
        await model.shutdown()
    }

    @Test("shutdown releases an in-flight launch for every scene")
    func shutdownReleasesPendingLaunch() async throws {
        let environment = try environment()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeHerdrModel(
            environment,
            coordinator: coordinator,
            client: LifecycleClientStub(records: [:])
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "new-agent"
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )

        try await model.createHerdrSession(selection)
        #expect(coordinator.isPending(key))

        await model.shutdown()

        #expect(!coordinator.isPending(key))
        let nextSceneOperation = coordinator.begin(.create, key: key)
        #expect(nextSceneOperation != nil)
        if let nextSceneOperation {
            coordinator.finish(nextSceneOperation, outcome: .failed)
        }
    }

    @Test("endpoint invalidation releases only that host's in-flight launch")
    func endpointInvalidationReleasesAffectedLaunch() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: .linux,
                sshDestination: "dev@old-builder.test"
            ),
        ])
        let host = HostSummary.fixture(
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@old-builder.test",
            herdrAvailable: true
        )
        let model = try makeModel(
            database: database,
            localHostID: UUID(),
            snapshot: .fixture(hosts: [host]),
            nativeHerdrPathProvider: { _ in .success("/usr/bin/herdr") },
            herdrLifecycleCoordinator: coordinator,
            herdrSessionDiscovery: { _ in .available([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher: configuredHosts.eraseToAnyPublisher()
        )
        let invalidatedKey = HerdrSessionLifecycleCoordinator.Key(
            hostID: host.id,
            sessionName: "new-agent"
        )
        let otherKey = HerdrSessionLifecycleCoordinator.Key(
            hostID: UUID(),
            sessionName: "other-agent"
        )
        let otherOperation = try #require(
            coordinator.begin(.create, key: otherKey)
        )

        try await model.createHerdrSession(.init(
            hostID: host.id,
            name: invalidatedKey.sessionName
        ))
        #expect(coordinator.isPending(invalidatedKey))

        configuredHosts.value = [
            SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: .linux,
                sshDestination: "dev@new-builder.test"
            ),
        ]
        model.refreshHosts()

        #expect(!coordinator.isPending(invalidatedKey))
        #expect(coordinator.isPending(otherKey))
        coordinator.finish(otherOperation, outcome: .failed)
        await model.shutdown()
    }

    private struct Environment {
        var database: WorkspaceDatabase
        var snapshot: WorkspaceSnapshot
        var hostID: UUID
    }

    private func environment() throws -> Environment {
        let database = try WorkspaceDatabase.inMemory()
        let hostID = UUID()
        return Environment(
            database: database,
            snapshot: .fixture(hosts: [
                .fixture(
                    id: hostID,
                    herdrSessions: [
                        .init(name: "agent", isDefault: false, state: .running),
                        .init(name: "sleeping", isDefault: false, state: .stopped),
                        .init(name: "default", isDefault: true, state: .stopped),
                    ],
                    herdrAvailable: true
                ),
            ]),
            hostID: hostID
        )
    }

    private func makeHerdrModel(
        _ environment: Environment,
        coordinator: HerdrSessionLifecycleCoordinator =
            HerdrSessionLifecycleCoordinator(),
        client: LifecycleClientStub,
        discovery: WorkspaceSceneModel.HerdrSessionDiscovery? = nil
    ) throws -> WorkspaceSceneModel {
        let displayedSessions = environment.snapshot.host(id: environment.hostID)?
            .herdrSessions ?? []
        return try makeModel(
            database: environment.database,
            localHostID: environment.hostID,
            snapshot: environment.snapshot,
            nativeHerdrPathProvider: { _ in .success("/usr/bin/herdr") },
            herdrLifecycleCoordinator: coordinator,
            herdrSessionRecordReader: { name, _, _ in
                client.record(named: name)
            },
            herdrSessionMutator: { action, confirmed, _, _ in
                client.mutate(action, confirmed: confirmed)
            },
            herdrSessionDiscovery: discovery ?? { _ in
                .available(displayedSessions)
            }
        )
    }

    private static func record(
        name: String,
        isDefault: Bool = false,
        state: HerdrSessionState
    ) -> HerdrSessionRecord {
        HerdrSessionRecord(
            name: name,
            isDefault: isDefault,
            state: state,
            sessionDirectory: "/tmp/herdr/\(name)",
            socketPath: "/tmp/herdr/\(name)/herdr.sock"
        )
    }
}

private final class LifecycleClientStub: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: HerdrSessionRecord]
    private let mutationResult:
        Result<HerdrSessionRecord, HerdrSessionLifecycleError>?
    private var storedMutationCount = 0

    var mutationCount: Int {
        lock.withLock { storedMutationCount }
    }

    init(
        records: [String: HerdrSessionRecord],
        mutationResult:
        Result<HerdrSessionRecord, HerdrSessionLifecycleError>? = nil
    ) {
        self.records = records
        self.mutationResult = mutationResult
    }

    func record(
        named name: String
    ) -> Result<HerdrSessionRecord, HerdrSessionLifecycleError> {
        lock.withLock {
            records[name].map(Result.success)
                ?? .failure(.sessionMissing(name))
        }
    }

    func mutate(
        _ action: HerdrSessionLifecycleAction,
        confirmed: HerdrSessionRecord
    ) -> Result<HerdrSessionRecord, HerdrSessionLifecycleError> {
        lock.withLock {
            storedMutationCount += 1
            if let mutationResult {
                return mutationResult
            }
            switch action {
            case .stop:
                let stopped = HerdrSessionRecord(
                    name: confirmed.name,
                    isDefault: confirmed.isDefault,
                    state: .stopped,
                    sessionDirectory: confirmed.sessionDirectory,
                    socketPath: confirmed.socketPath
                )
                records[confirmed.name] = stopped
                return .success(stopped)
            case .delete:
                records.removeValue(forKey: confirmed.name)
                return .success(confirmed)
            }
        }
    }

    func replaceRecord(_ record: HerdrSessionRecord) {
        lock.withLock {
            records[record.name] = record
        }
    }
}
