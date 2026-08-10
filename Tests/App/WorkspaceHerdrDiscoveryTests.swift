import Foundation
import GhosthubHerdr
import GhosthubPersistence
import GhosthubTestSupport
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private final class HerdrDiscoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts = [CommandHost]()

    func record(_ host: CommandHost) {
        lock.withLock { hosts.append(host) }
    }

    var snapshot: [CommandHost] { lock.withLock { hosts } }
}

private final class HerdrResultSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HerdrDiscoveryResult]

    init(_ results: [HerdrDiscoveryResult]) {
        self.results = results
    }

    func next() -> HerdrDiscoveryResult {
        lock.withLock { results.removeFirst() }
    }
}

private final class HerdrBlockingDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false

    func discover() -> HerdrDiscoveryResult {
        lock.withLock { started = true }
        semaphore.wait()
        return .available([])
    }

    var didStart: Bool { lock.withLock { started } }

    func release() {
        semaphore.signal()
    }
}

private final class HerdrCancellationDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    func discover() -> HerdrDiscoveryResult {
        let invocation = lock.withLock {
            starts += 1
            return starts
        }
        guard invocation == 1 else {
            return .available([
                HerdrSessionSummary(name: "replacement", isDefault: false, state: .running),
            ])
        }
        while !withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return .failure(.cancelled(host: "localhost"))
    }

    var count: Int { lock.withLock { starts } }
}

private final class HerdrLifecycleRaceDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var calls = 0

    func discover() -> HerdrDiscoveryResult {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 {
            semaphore.wait()
            return .available([
                HerdrSessionSummary(
                    name: "review",
                    isDefault: false,
                    state: .running
                ),
            ])
        }
        return .available([
            HerdrSessionSummary(
                name: "review",
                isDefault: false,
                state: .stopped
            ),
        ])
    }

    var count: Int { lock.withLock { calls } }

    func release() {
        semaphore.signal()
    }
}

@Suite("Workspace Herdr discovery", .serialized)
struct WorkspaceHerdrDiscoveryTests {
    @MainActor
    @Test("local Herdr inventory publishes while a remote probe is blocked")
    func localHerdrInventoryPublishesBeforeRemoteCompletes() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let remoteDiscovery = HerdrBlockingDiscovery()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            herdrSessionDiscovery: { host in
                guard host.isRemote else {
                    return .available([
                        HerdrSessionSummary(
                            name: "local-fast",
                            isDefault: false,
                            state: .running
                        ),
                    ])
                }
                return remoteDiscovery.discover()
            }
        )

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { remoteDiscovery.didStart }
        await waitUntilMainActor {
            model.snapshot.host(id: environment.localHostID)?
                .herdrSessions.map(\.name) == ["local-fast"]
        }
        let localSessions = model.snapshot.host(
            id: environment.localHostID
        )?.herdrSessions.map(\.name)

        remoteDiscovery.release()
        #expect(localSessions == ["local-fast"])
        await model.shutdown()
    }

    @MainActor
    @Test("scene shutdown prevents Herdr discovery from restarting")
    func shutdownPreventsHerdrDiscoveryRespawn() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary.fixture()
        let calls = LockedValue(0)
        let model = try makeModel(
            database: database,
            localHostID: host.id,
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            herdrSessionDiscovery: { _ in
                calls.withLock { $0 += 1 }
                return .failure(.cancelled(host: "superseded"))
            }
        )

        await model.shutdown()
        model.startHerdrSessionDiscovery()
        await Task.yield()

        #expect(calls.load() == 0)
    }

    @MainActor
    @Test("local and POSIX SSH hosts are probed while Windows is excluded")
    func supportedHostsOnly() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let posix = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder"
        )
        let windows = HostSummary(
            id: UUID(),
            configKey: "windows",
            name: "Windows",
            kind: .remote,
            platform: .windows,
            sshDestination: "dev@windows"
        )
        let recorder = HerdrDiscoveryRecorder()
        let model = try makeModel(
            database: database,
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local, posix, windows],
                projects: [],
                worktrees: []
            ),
            herdrSessionDiscovery: { host in
                recorder.record(host)
                return .available([
                    HerdrSessionSummary(
                        name: host.displayName,
                        isDefault: false,
                        state: .running
                    ),
                ])
            }
        )

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: local.id)?.herdrSessions.count == 1
                && model.snapshot.host(id: posix.id)?.herdrSessions.count == 1
        }

        #expect(Set(recorder.snapshot) == Set([
            CommandHost.local,
            CommandHost.ssh(SSHHostInfo(
                user: "dev",
                hostname: "builder",
                port: nil
            )),
        ]))
        #expect(model.snapshot.host(id: windows.id)?.herdrSessions.isEmpty == true)
        await model.shutdown()
    }

    @MainActor
    @Test("unavailable and failed Herdr probes clear rows without changing host usability")
    func additiveFailurePolicy() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let diagnostic = RemoteHostDiagnostic.missingKwtCapability
        let remote = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            lastKnownReachable: true,
            remoteDiagnostics: [diagnostic],
            tmuxSessions: [
                TmuxSessionSummary(
                    name: "tmux-kept",
                    managed: false,
                    windows: []
                ),
            ],
            herdrSessions: [
                HerdrSessionSummary(name: "stale", isDefault: false, state: .running),
            ]
        )
        let project = ProjectSummary.fixture(hostID: remote.id)
        let results = HerdrResultSequence([
            .available([HerdrSessionSummary(name: "live", isDefault: true, state: .running)]),
            .unavailable,
            .failure(.malformedJSON),
        ])
        let model = try makeModel(
            database: database,
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local, remote],
                projects: [project],
                worktrees: []
            ),
            herdrSessionDiscovery: { host in
                guard case .ssh = host else { return .unavailable }
                return results.next()
            }
        )

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: remote.id)?.herdrSessions.map(\.name)
                == ["live"]
        }
        #expect(model.snapshot.host(id: remote.id)?.herdrAvailable == true)

        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.snapshot.host(id: remote.id)?.herdrSessions.isEmpty == true
        }
        #expect(model.snapshot.host(id: remote.id)?.herdrAvailable == false)
        #expect(model.workspaceInventoryWarningsByHost[remote.id] == nil)

        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.workspaceInventoryWarningsByHost[remote.id] != nil
        }
        let retained = try #require(model.snapshot.host(id: remote.id))
        #expect(retained.herdrSessions.isEmpty)
        #expect(retained.tmuxSessions.map(\.name) == ["tmux-kept"])
        #expect(retained.lastKnownReachable)
        #expect(retained.remoteDiagnostics == [diagnostic])
        #expect(model.snapshot.projects.map(\.id) == [project.id])
        #expect(model.workspaceInventoryState == .loaded)
        #expect(model.workspaceInventoryWarning == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("explicit refresh invalidates and drains the in-flight Herdr probe")
    func refreshInvalidatesProbe() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = HerdrCancellationDiscovery()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            herdrSessionDiscovery: { _ in discovery.discover() }
        )

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { discovery.count == 1 }
        model.refreshWorkspaceInventory()
        await waitUntilMainActor {
            discovery.count == 2
                && model.snapshot.host(id: environment.host.id)?
                .herdrSessions.map(\.name) == ["replacement"]
        }

        #expect(discovery.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("exact validation cancellation does not clear Herdr inventory")
    func validationCancellationPreservesInventory() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].herdrSessions = [
            HerdrSessionSummary(
                name: "replacement",
                isDefault: false,
                state: .running
            ),
        ]
        snapshot.hosts[0].herdrAvailable = true
        let discovery = HerdrCancellationDiscovery()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            herdrSessionDiscovery: { _ in discovery.discover() }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.host.id,
            name: "replacement"
        )

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { discovery.count == 1 }
        try await model.openBorrowedHerdrSession(selection)
        await waitUntilMainActor {
            discovery.count >= 2
                && model.snapshot.host(id: environment.host.id)?
                .herdrSessions.map(\.name) == ["replacement"]
                && model.workspaceInventoryWarningsByHost[environment.host.id]
                == nil
        }

        let host = try #require(model.snapshot.host(id: environment.host.id))
        #expect(host.herdrAvailable)
        #expect(host.herdrSessions.map(\.name) == ["replacement"])
        #expect(model.workspaceInventoryWarningsByHost[environment.host.id] == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("Herdr failure cannot rescue an otherwise blocking local inventory")
    func failureDoesNotChangeBlockingState() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let model = try makeModel(
            database: database,
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local],
                projects: [],
                worktrees: []
            ),
            kwtInventoryLoader: { _ in
                throw KwtInventoryError.commandFailed(
                    host: "This Mac",
                    status: 42
                )
            },
            tmuxSessionDiscovery: { _ in
                .failure(.notFound(shell: "/bin/zsh"))
            },
            herdrSessionDiscovery: { _ in .failure(.malformedJSON) },
            startServices: true
        )

        await waitUntilMainActor {
            if case .failed = model.workspaceInventoryState {
                return model.workspaceInventoryWarningsByHost[local.id] != nil
            }
            return false
        }

        guard case .failed = model.workspaceInventoryState else {
            Issue.record("Expected the existing local failures to stay blocking")
            await model.shutdown()
            return
        }
        #expect(model.snapshot.host(id: local.id)?.herdrSessions.isEmpty == true)
        await model.shutdown()
    }

    @MainActor
    @Test("refresh completion waits for Herdr inventory")
    func completionWaitsForHerdr() async throws {
        let environment = try setupStandardEnvironment()
        let discovery = HerdrBlockingDiscovery()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { _ in .success([]) },
            herdrSessionDiscovery: { _ in discovery.discover() },
            startServices: true
        )

        await waitUntilMainActor { discovery.didStart }
        #expect(!model.isWorkspaceInventoryRefreshComplete)

        discovery.release()
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
        }
        #expect(model.isWorkspaceInventoryRefreshComplete)
        await model.shutdown()
    }

    @MainActor
    @Test("lifecycle completion fences stale running discovery")
    func lifecycleFencesStaleDiscovery() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].herdrSessions = [
            HerdrSessionSummary(
                name: "review",
                isDefault: false,
                state: .stopped
            ),
        ]
        let discovery = HerdrLifecycleRaceDiscovery()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            herdrLifecycleCoordinator: coordinator,
            herdrSessionDiscovery: { _ in discovery.discover() }
        )

        model.startHerdrSessionDiscovery()
        await waitUntilMainActor { discovery.count == 1 }
        let operation = try #require(coordinator.begin(
            .stop,
            key: .init(
                hostID: environment.host.id,
                sessionName: "review"
            )
        ))
        coordinator.finish(operation, outcome: .succeeded)
        discovery.release()

        await waitUntilMainActor {
            discovery.count >= 2
                && model.snapshot.host(id: environment.host.id)?
                .herdrSessions.first?.state == .stopped
        }
        #expect(discovery.count == 2)
        await model.shutdown()
    }
}
