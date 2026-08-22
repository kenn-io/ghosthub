import Combine
import Foundation
import GhosthubPersistence
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import GhosthubZellij
import Synchronization
import Testing
@testable import GhosthubApp

extension WorkspaceZellijTests {
    @Test("confirmed kill suppresses reconnect in another scene")
    func confirmedKillSuppressesPeerReconnect() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [],
            worktrees: []
        )
        let killCoordinator = ZellijSessionKillCoordinator()
        let reconnectStore = RecordingNativeSessionSurfaceStore()
        let reconnectProbes = Mutex(0)
        let reconnectProbeContinuation = Mutex<
            CheckedContinuation<Void, Never>?
        >(nil)
        let reconnectModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            nativeZellijSurfaceStore: reconnectStore,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                let attempt = reconnectProbes.withLock {
                    $0 += 1
                    return $0
                }
                if attempt == 2 {
                    await withCheckedContinuation { continuation in
                        reconnectProbeContinuation.withLock {
                            $0 = continuation
                        }
                    }
                }
                return .available(["api"])
            },
            tmuxReconnectIntervals: [.zero],
            tmuxReconnectProbeDeadline: .seconds(1)
        )
        let kills = Mutex(0)
        let killingModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
                return .success(())
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        reconnectModel.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            reconnectStore.requestedConfigurations.count == 1
                && !reconnectStore.surface.closeObservers.isEmpty
        }
        let close = try #require(
            reconnectStore.surface.closeObservers.values.first
        )
        close(false, 255)
        await waitUntilMainActor {
            reconnectProbeContinuation.withLock { $0 != nil }
        }

        let request = try await killingModel.prepareZellijSessionKill(
            selection
        )
        try await killingModel.killZellijSession(request)
        let continuation = reconnectProbeContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        continuation?.resume()
        try await Task.sleep(for: .milliseconds(100))

        #expect(kills.withLock { $0 } == 1)
        #expect(reconnectStore.requestedConfigurations.count == 1)
        #expect(reconnectModel.activeBorrowedZellijSelection == nil)
        #expect(reconnectStore.removedKeys.contains {
            $0.target == .zellijSession
        })
        await reconnectModel.shutdown()
        await killingModel.shutdown()
    }

    @Test("successful kill detaches before asynchronous reconciliation")
    func successfulKillDetachesBeforeReconciliation() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let killCoordinator = ZellijSessionKillCoordinator()
        let store = RecordingNativeSessionSurfaceStore()
        let connectionState = Mutex((calls: 0, blocked: false, released: false))
        defer { connectionState.withLock { $0.released = true } }
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in .available(["api"]) },
            zellijSSHConnectionSnapshotProvider: { _ in
                let call = connectionState.withLock {
                    $0.calls += 1
                    return $0.calls
                }
                if call == 3 {
                    connectionState.withLock { $0.blocked = true }
                    while !connectionState.withLock({ $0.released }) {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                return SSHConnectionArgumentsSnapshot(arguments: [])
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            model.activeBorrowedZellijSelection == selection
                && store.requestedConfigurations.count == 1
                && !store.surface.closeObservers.isEmpty
        }
        let close = try #require(store.surface.closeObservers.values.first)
        let resolvedHost = try #require(CommandHostResolver.resolve(host))
        let operation = try #require(killCoordinator.begin(
            key: .init(hostID: host.id, sessionName: selection.name),
            host: resolvedHost,
            connectionCacheKey: SSHConnectionArgumentsSnapshot(
                arguments: []
            ).cacheKey
        ))

        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(store.removedKeys.contains { $0.target == .zellijSession })
        killCoordinator.finish(operation, outcome: .succeeded)

        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(store.removedKeys.contains { $0.target == .zellijSession })
        close(false, 255)
        await waitUntilMainActor {
            connectionState.withLock { $0.blocked }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.requestedConfigurations.count == 1)

        connectionState.withLock { $0.released = true }
        await model.shutdown()
    }

    @Test("validation completed after a kill cannot attach")
    func staleValidationCannotAttachAfterKill() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [],
            worktrees: []
        )
        let killCoordinator = ZellijSessionKillCoordinator()
        let store = RecordingNativeSessionSurfaceStore()
        let validationContinuation = Mutex<
            CheckedContinuation<Void, Never>?
        >(nil)
        let validatingModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                await withCheckedContinuation { continuation in
                    validationContinuation.withLock { $0 = continuation }
                }
                return .available(["api"])
            }
        )
        let killingModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSessionKiller: { _, _, _ in .success(()) }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        validatingModel.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            validationContinuation.withLock { $0 != nil }
        }
        let request = try await killingModel.prepareZellijSessionKill(
            selection
        )
        try await killingModel.killZellijSession(request)
        let continuation = validationContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        continuation?.resume()
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.requestedConfigurations.isEmpty)
        #expect(validatingModel.activeBorrowedZellijSelection == nil)
        await validatingModel.shutdown()
        await killingModel.shutdown()
    }

    @Test("failed kill restarts a matching suspended open")
    func failedKillRestartsSuspendedOpen() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [],
            worktrees: []
        )
        let killCoordinator = ZellijSessionKillCoordinator()
        let store = RecordingNativeSessionSurfaceStore()
        let validationAttempts = Mutex(0)
        let firstValidationContinuation = Mutex<
            CheckedContinuation<Void, Never>?
        >(nil)
        let validatingModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                let attempt = validationAttempts.withLock {
                    $0 += 1
                    return $0
                }
                if attempt == 1 {
                    await withCheckedContinuation { continuation in
                        firstValidationContinuation.withLock {
                            $0 = continuation
                        }
                    }
                }
                return .available(["api"])
            }
        )
        let killingModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSessionKiller: { _, _, _ in
                .failure(.commandFailed(status: 1, stderr: "busy"))
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        validatingModel.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            firstValidationContinuation.withLock { $0 != nil }
        }
        let request = try await killingModel.prepareZellijSessionKill(
            selection
        )
        await #expect(throws: ZellijCommandError.self) {
            try await killingModel.killZellijSession(request)
        }
        await waitUntilMainActor {
            validationAttempts.withLock { $0 } >= 2
                && store.requestedConfigurations.count == 1
        }
        let continuation = firstValidationContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        continuation?.resume()

        #expect(validatingModel.activeBorrowedZellijSelection == selection)
        await validatingModel.shutdown()
        await killingModel.shutdown()
    }

    @Test("failed kill does not resume an open superseded by another session")
    func failedKillDoesNotResumeSupersededOpen() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [
                ZellijSessionSummary(name: "api"),
                ZellijSessionSummary(name: "shell"),
            ],
            zellijAvailable: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [],
            worktrees: []
        )
        let killCoordinator = ZellijSessionKillCoordinator()
        let store = RecordingNativeSessionSurfaceStore()
        let firstValidationContinuation = Mutex<
            CheckedContinuation<Void, Never>?
        >(nil)
        let apiValidationAttempts = Mutex(0)
        let validatingModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                let attempt = apiValidationAttempts.withLock {
                    $0 += 1
                    return $0
                }
                if attempt == 1 {
                    await withCheckedContinuation { continuation in
                        firstValidationContinuation.withLock {
                            $0 = continuation
                        }
                    }
                }
                return .available(["api", "shell"])
            }
        )
        let killContinuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let killingModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api", "shell"])
            },
            zellijSessionKiller: { _, _, _ in
                await withCheckedContinuation { continuation in
                    killContinuation.withLock { $0 = continuation }
                }
                return .failure(.commandFailed(status: 1, stderr: "busy"))
            }
        )
        let api = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )
        let shell = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "shell"
        )

        validatingModel.openBorrowedZellijSession(api)
        await waitUntilMainActor {
            firstValidationContinuation.withLock { $0 != nil }
        }
        let request = try await killingModel.prepareZellijSessionKill(api)
        let killTask = Task {
            try await killingModel.killZellijSession(request)
        }
        await waitUntilMainActor {
            killCoordinator.isPending(.init(
                hostID: host.id,
                sessionName: api.name
            ))
        }
        validatingModel.openBorrowedZellijSession(shell)
        await waitUntilMainActor {
            validatingModel.activeBorrowedZellijSelection == shell
                && killContinuation.withLock { $0 != nil }
        }
        let releaseKill = killContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        releaseKill?.resume()
        await #expect(throws: ZellijCommandError.self) {
            try await killTask.value
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(validatingModel.activeBorrowedZellijSelection == shell)
        let continuation = firstValidationContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        continuation?.resume()
        await validatingModel.shutdown()
        await killingModel.shutdown()
    }

    @Test("failed kill does not resume an open after host route drift")
    func failedKillDoesNotResumeOpenAfterHostDrift() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let configuredHost = Mutex(SSHHost(
            configKey: host.configKey,
            name: host.name,
            platform: .linux,
            sshDestination: host.sshDestination ?? ""
        ))
        let killCoordinator = ZellijSessionKillCoordinator()
        let store = RecordingNativeSessionSurfaceStore()
        let validations = Mutex(0)
        let model = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                validations.withLock { $0 += 1 }
                return .available(["api"])
            },
            configuredSSHHostsProvider: {
                [configuredHost.withLock { $0 }]
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )
        let confirmedHost = try #require(CommandHostResolver.resolve(host))
        let operation = try #require(killCoordinator.begin(
            key: .init(
                hostID: host.id,
                sessionName: selection.name
            ),
            host: confirmedHost,
            connectionCacheKey: SSHConnectionArgumentsSnapshot(
                arguments: []
            ).cacheKey
        ))

        model.openBorrowedZellijSession(selection)
        configuredHost.withLock {
            $0.sshDestination = "dev@other.example.test"
        }
        model.refreshHosts()
        killCoordinator.finish(operation, outcome: .failed)
        try await Task.sleep(for: .milliseconds(100))

        #expect(validations.withLock { $0 } == 0)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(store.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("successful kill rejects stale discovery in another scene")
    func successfulKillRejectsPeerDiscovery() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [],
            worktrees: []
        )
        let killCoordinator = ZellijSessionKillCoordinator()
        let probeCount = Mutex(0)
        let firstProbeStarted = Mutex(false)
        let releaseFirstProbe = AsyncGate()
        let inventoryModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionDiscovery: { _ in
                let attempt = probeCount.withLock {
                    $0 += 1
                    return $0
                }
                if attempt == 1 {
                    firstProbeStarted.withLock { $0 = true }
                    await releaseFirstProbe.wait()
                    return .available(["api"])
                }
                return .available([])
            }
        )
        let killingModel = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: UUID(),
            snapshot: snapshot,
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSessionKiller: { _, _, _ in .success(()) }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        inventoryModel.startZellijSessionDiscovery()
        await waitUntilMainActor { firstProbeStarted.withLock { $0 } }
        let request = try await killingModel.prepareZellijSessionKill(
            selection
        )
        try await killingModel.killZellijSession(request)

        await waitUntilMainActor {
            inventoryModel.snapshot.host(id: host.id)?
                .zellijSessions.isEmpty == true
        }

        releaseFirstProbe.open()
        await waitUntilMainActor {
            probeCount.withLock { $0 } >= 2
                && inventoryModel.snapshot.host(id: host.id)?
                .zellijSessions.isEmpty == true
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(probeCount.withLock { $0 } >= 2)
        #expect(inventoryModel.snapshot.host(id: host.id)?
            .zellijSessions.isEmpty == true)
        await inventoryModel.shutdown()
        await killingModel.shutdown()
    }

    @Test("successful kill does not close a newer same-name attachment")
    func successfulKillPreservesNewerAttachment() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let connectionState = Mutex((
            calls: 0,
            blocked: false,
            released: false
        ))
        defer { connectionState.withLock { $0.released = true } }
        let killCoordinator = ZellijSessionKillCoordinator()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                let call = connectionState.withLock {
                    $0.calls += 1
                    return $0.calls
                }
                if call == 1 {
                    connectionState.withLock { $0.blocked = true }
                    while !connectionState.withLock({ $0.released }) {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                return SSHConnectionArgumentsSnapshot(arguments: [])
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )
        let resolvedHost = try #require(CommandHostResolver.resolve(host))
        let operation = try #require(killCoordinator.begin(
            key: .init(hostID: host.id, sessionName: selection.name),
            host: resolvedHost,
            connectionCacheKey: SSHConnectionArgumentsSnapshot(
                arguments: []
            ).cacheKey
        ))

        killCoordinator.finish(operation, outcome: .succeeded)
        await waitUntilMainActor {
            connectionState.withLock { $0.blocked }
        }
        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            model.activeBorrowedZellijSelection == selection
                && store.requestedConfigurations.count == 1
        }
        connectionState.withLock { $0.released = true }
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.activeBorrowedZellijSelection == selection)
        #expect(model.snapshot.host(id: host.id)?.zellijSessions.map(\.name)
            == ["api"])
        await model.shutdown()
    }

    @Test("successful kill drops a queued same-name open despite a stale fence")
    func successfulKillDropsQueuedIntentDespiteStaleFence() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [
                ZellijSessionSummary(name: "api"),
                ZellijSessionSummary(name: "worker"),
            ],
            zellijAvailable: true
        )
        let connectionState = Mutex((
            calls: 0,
            blocked: false,
            released: false
        ))
        defer { connectionState.withLock { $0.released = true } }
        let killCoordinator = ZellijSessionKillCoordinator()
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api", "worker"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                let call = connectionState.withLock {
                    $0.calls += 1
                    return $0.calls
                }
                if call == 1 {
                    connectionState.withLock { $0.blocked = true }
                    while !connectionState.withLock({ $0.released }) {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                return SSHConnectionArgumentsSnapshot(arguments: [])
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )
        let resolvedHost = try #require(CommandHostResolver.resolve(host))
        let cacheKey = SSHConnectionArgumentsSnapshot(arguments: []).cacheKey
        let operation = try #require(killCoordinator.begin(
            key: .init(hostID: host.id, sessionName: selection.name),
            host: resolvedHost,
            connectionCacheKey: cacheKey
        ))

        model.openBorrowedZellijSession(selection)
        #expect(model.pendingZellijPresentationSelection == selection)
        killCoordinator.finish(operation, outcome: .succeeded)
        await waitUntilMainActor {
            connectionState.withLock { $0.blocked }
        }
        let workerOperation = try #require(killCoordinator.begin(
            key: .init(hostID: host.id, sessionName: "worker"),
            host: resolvedHost,
            connectionCacheKey: cacheKey
        ))
        killCoordinator.finish(workerOperation, outcome: .succeeded)
        connectionState.withLock { $0.released = true }

        await waitUntilMainActor {
            model.pendingZellijPresentationSelection == nil
        }
        await model.shutdown()
    }

    @Test("kill on a stale SSH route preserves the active attachment")
    func staleRouteKillPreservesActiveAttachment() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let currentConnection = SSHConnectionArgumentsSnapshot(
            testKwtSSHAttachment(
                arguments: ["-F", "/dev/null"],
                routeIdentity: "sha256:current-route"
            )
        )
        let staleConnection = SSHConnectionArgumentsSnapshot(
            testKwtSSHAttachment(
                arguments: ["-F", "/dev/null"],
                routeIdentity: "sha256:stale-route"
            )
        )
        let killCoordinator = ZellijSessionKillCoordinator()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in currentConnection },
            presentationSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(
                    routeIdentity: "sha256:current-route"
                )
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            model.activeBorrowedZellijSelection == selection
                && store.requestedConfigurations.count == 1
        }
        let resolvedHost = try #require(CommandHostResolver.resolve(host))
        let operation = try #require(killCoordinator.begin(
            key: .init(hostID: host.id, sessionName: selection.name),
            host: resolvedHost,
            connectionCacheKey: staleConnection.cacheKey
        ))

        #expect(model.activeBorrowedZellijSelection == selection)
        #expect(store.requestedConfigurations.count == 1)
        killCoordinator.finish(operation, outcome: .succeeded)
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.activeBorrowedZellijSelection == selection)
        #expect(store.removedKeys.contains { $0.target == .zellijSession }
            == false)
        await model.shutdown()
    }

    @Test("successful kill cancels in-flight inventory before fencing")
    func successfulKillCancelsInFlightInventory() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let resolvedHost = try #require(CommandHostResolver.resolve(host))
        let discoveryState = Mutex((
            attempts: 0,
            initialStarted: false,
            initialCancelled: false,
            releaseAll: false
        ))
        let connectionState = Mutex((blocked: false, released: false))
        defer {
            discoveryState.withLock { $0.releaseAll = true }
            connectionState.withLock { $0.released = true }
        }
        let killCoordinator = ZellijSessionKillCoordinator()
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            zellijSessionKillCoordinator: killCoordinator,
            zellijSessionDiscovery: { _ in
                let attempt = discoveryState.withLock {
                    $0.attempts += 1
                    if $0.attempts == 1 {
                        $0.initialStarted = true
                    }
                    return $0.attempts
                }
                while !discoveryState.withLock({ $0.releaseAll }) {
                    if Task.isCancelled {
                        if attempt == 1 {
                            discoveryState.withLock {
                                $0.initialCancelled = true
                            }
                        }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                connectionState.withLock { $0.blocked = true }
                while !connectionState.withLock({ $0.released }) {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return SSHConnectionArgumentsSnapshot(arguments: [])
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor {
            discoveryState.withLock { $0.initialStarted }
        }
        let operation = try #require(killCoordinator.begin(
            key: .init(hostID: host.id, sessionName: selection.name),
            host: resolvedHost,
            connectionCacheKey: SSHConnectionArgumentsSnapshot(
                arguments: []
            ).cacheKey
        ))
        killCoordinator.finish(operation, outcome: .succeeded)
        await waitUntilMainActor {
            connectionState.withLock { $0.blocked }
                && discoveryState.withLock { $0.initialCancelled }
        }
        #expect(discoveryState.withLock { $0.initialCancelled })
        discoveryState.withLock { $0.releaseAll = true }
        connectionState.withLock { $0.released = true }
        await model.shutdown()
    }

    @Test("successful kill ignores transient Zellij availability")
    func successfulKillIgnoresTransientAvailability() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: false
        )
        let killCoordinator = ZellijSessionKillCoordinator()
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            zellijSessionKillCoordinator: killCoordinator
        )
        let resolvedHost = try #require(CommandHostResolver.resolve(host))
        let operation = try #require(killCoordinator.begin(
            key: .init(hostID: host.id, sessionName: "api"),
            host: resolvedHost,
            connectionCacheKey: SSHConnectionArgumentsSnapshot(
                arguments: []
            ).cacheKey
        ))

        killCoordinator.finish(operation, outcome: .succeeded)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.snapshot.host(id: host.id)?.zellijSessions.isEmpty == true
        }

        #expect(model.snapshot.host(id: host.id)?.zellijSessions.isEmpty == true)
        await model.shutdown()
    }

    @Test("kill revalidates the live session and exact host")
    func killRevalidates() async throws {
        let environment = try zellijEnvironment(sessions: ["api"])
        let probes = Mutex(0)
        let kills = Mutex([(String, CommandHost)]())
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            zellijSessionDiscovery: { _ in
                probes.withLock { $0 += 1 }
                return .available(["api"])
            },
            zellijSessionKiller: { name, host, _ in
                kills.withLock { $0.append((name, host)) }
                return .success(())
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "api"
        )

        let request = try await model.prepareZellijSessionKill(selection)
        try await model.killZellijSession(request)

        #expect(probes.withLock { $0 } == 2)
        #expect(kills.withLock { $0.count } == 1)
        #expect(kills.withLock { $0.first?.0 } == "api")
        #expect(kills.withLock { $0.first?.1 } == .local)
        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?
                .zellijSessions.isEmpty == true
        }
        #expect(model.snapshot.host(id: environment.host.id)?
            .zellijSessions.isEmpty == true)
        await model.shutdown()
    }

    @Test(
        "kill preparation preserves validation failures",
        arguments: [
            ZellijKillValidationFailureCase(
                name: "unavailable executable",
                result: .unavailable,
                expectsUnavailable: true
            ),
            ZellijKillValidationFailureCase(
                name: "command failure",
                result: .failure(.commandFailed(
                    status: 23,
                    stderr: "probe failed"
                )),
                expectsUnavailable: false
            ),
        ]
    )
    func killPreparationPreservesValidationFailure(
        _ failure: ZellijKillValidationFailureCase
    ) async throws {
        let environment = try zellijEnvironment(sessions: ["api"])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            zellijSessionValidationDiscovery: { _, _ in failure.result }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "api"
        )

        do {
            _ = try await model.prepareZellijSessionKill(selection)
            Issue.record("Expected kill preparation to fail")
        } catch {
            if failure.expectsUnavailable {
                #expect(error as? ZellijSessionPresentationError == .unavailable)
            } else {
                #expect(error as? ZellijCommandError == .commandFailed(
                    status: 23,
                    stderr: "probe failed"
                ))
            }
        }
        await model.shutdown()
    }

    @Test(
        "final kill validation preserves failures",
        arguments: [
            ZellijKillValidationFailureCase(
                name: "unavailable executable",
                result: .unavailable,
                expectsUnavailable: true
            ),
            ZellijKillValidationFailureCase(
                name: "command failure",
                result: .failure(.commandFailed(
                    status: 23,
                    stderr: "probe failed"
                )),
                expectsUnavailable: false
            ),
        ]
    )
    func finalKillValidationPreservesFailure(
        _ failure: ZellijKillValidationFailureCase
    ) async throws {
        let environment = try zellijEnvironment(sessions: ["api"])
        let attempts = Mutex(0)
        let kills = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            zellijSessionValidationDiscovery: { _, _ in
                let attempt = attempts.withLock {
                    $0 += 1
                    return $0
                }
                return attempt == 1 ? .available(["api"]) : failure.result
            },
            zellijSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
                return .success(())
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "api"
        )
        let request = try await model.prepareZellijSessionKill(selection)

        do {
            try await model.killZellijSession(request)
            Issue.record("Expected final kill validation to fail")
        } catch {
            if failure.expectsUnavailable {
                #expect(error as? ZellijSessionPresentationError == .unavailable)
            } else {
                #expect(error as? ZellijCommandError == .commandFailed(
                    status: 23,
                    stderr: "probe failed"
                ))
            }
        }
        #expect(kills.withLock { $0 } == 0)
        await model.shutdown()
    }

    @Test("kill uses the confirmed SSH route for validation and mutation")
    func killUsesFrozenSSHRoute() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let frozen = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config",
        ])
        let validations = Mutex([[String]]())
        let killedWith = Mutex<[String]?>(nil)
        let model = try makeModel(
            database: database,
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            zellijSessionValidationDiscovery: { _, arguments in
                validations.withLock { $0.append(arguments) }
                return .available(["api"])
            },
            zellijSessionKiller: { _, _, arguments in
                killedWith.withLock { $0 = arguments }
                return .success(())
            },
            zellijSSHConnectionSnapshotProvider: { _ in frozen }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        let request = try await model.prepareZellijSessionKill(selection)
        try await model.killZellijSession(request)

        #expect(validations.withLock { $0 } == [
            frozen.arguments,
            frozen.arguments,
        ])
        #expect(killedWith.withLock { $0 } == frozen.arguments)
        await model.shutdown()
    }

    @Test("kill invalidates an unusable retained SSH connection")
    func killInvalidatesUnusableSSHConnection() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let invalidations = Mutex(0)
        let connection = SSHConnectionArgumentsSnapshot(
            KwtSSHConnection(
                arguments: ["-S", "/tmp/route.sock"],
                routeIdentity: "sha256:stable-route",
                generation: 1,
                invalidate: { invalidations.withLock { $0 += 1 } }
            )
        )
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSessionKiller: { _, _, _ in
                .failure(.commandFailed(
                    status: 255,
                    stderr: "Control socket connect(/tmp/route.sock): No such file or directory"
                ))
            },
            zellijSSHConnectionSnapshotProvider: { _ in connection }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )
        let request = try await model.prepareZellijSessionKill(selection)

        await #expect(throws: ZellijCommandError.self) {
            try await model.killZellijSession(request)
        }

        #expect(invalidations.withLock { $0 } == 1)
        await model.shutdown()
    }

    @Test("kill adopts a new lease generation for the confirmed route")
    func killAdoptsCurrentGeneration() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let acquisition = Mutex(0)
        let validations = Mutex([[String]]())
        let killedWith = Mutex<[String]?>(nil)
        let model = try makeModel(
            database: database,
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            zellijSessionValidationDiscovery: { _, arguments in
                validations.withLock { $0.append(arguments) }
                return .available(["api"])
            },
            zellijSessionKiller: { _, _, arguments in
                killedWith.withLock { $0 = arguments }
                return .success(())
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                let attempt = acquisition.withLock {
                    $0 += 1
                    return $0
                }
                let generation: UInt64 = attempt <= 2 ? 1 : 2
                let arguments = ["-S", "/tmp/route-\(generation).sock"]
                return SSHConnectionArgumentsSnapshot(
                    KwtSSHConnection(
                        arguments: arguments,
                        routeIdentity: "sha256:stable-route",
                        generation: generation,
                        release: {}
                    )
                )
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        let request = try await model.prepareZellijSessionKill(selection)
        try await model.killZellijSession(request)

        let currentArguments = ["-S", "/tmp/route-2.sock"]
        #expect(validations.withLock { $0 } == [
            ["-S", "/tmp/route-1.sock"],
            currentArguments,
        ])
        #expect(killedWith.withLock { $0 } == currentArguments)
        await model.shutdown()
    }

    @Test("kill rejects SSH route drift after confirmation")
    func killRejectsSSHRouteDrift() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let route = Mutex(0)
        let releases = Mutex(0)
        let kills = Mutex(0)
        let model = try makeModel(
            database: database,
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
                return .success(())
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                let attempt = route.withLock { value in
                    value += 1
                    return value
                }
                let number = attempt <= 2 ? 1 : 2
                let arguments = ["-F", "/dev/null"]
                let lease = KwtSSHConnection(
                    arguments: arguments,
                    routeIdentity: "route-\(number)",
                    generation: UInt64(number),
                    release: { releases.withLock { $0 += 1 } }
                )
                return SSHConnectionArgumentsSnapshot(
                    lease
                )
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        let request = try await model.prepareZellijSessionKill(selection)
        await waitUntilMainActor { releases.withLock { $0 } == 2 }

        await #expect(throws: ZellijSessionPresentationError.hostChanged(
            "api"
        )) {
            try await model.killZellijSession(request)
        }
        await waitUntilMainActor { releases.withLock { $0 } == 3 }
        #expect(releases.withLock { $0 } == 3)
        #expect(kills.withLock { $0 } == 0)
        await model.shutdown()
    }

    @Test("kill rejects SSH route drift during final discovery")
    func killRejectsSSHRouteDriftDuringFinalDiscovery() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let frozen = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config",
        ])
        let changed = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/changed-config",
        ])
        let current = Mutex(frozen)
        let validations = Mutex(0)
        let kills = Mutex(0)
        let model = try makeModel(
            database: database,
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            zellijSessionValidationDiscovery: { _, _ in
                let attempt = validations.withLock {
                    $0 += 1
                    return $0
                }
                if attempt == 2 {
                    try? await Task.sleep(for: .milliseconds(10))
                    current.withLock { $0 = changed }
                }
                return .available(["api"])
            },
            zellijSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
                return .success(())
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        let request = try await model.prepareZellijSessionKill(selection)

        await #expect(throws: ZellijSessionPresentationError.hostChanged(
            "api"
        )) {
            try await model.killZellijSession(request)
        }
        #expect(validations.withLock { $0 } == 2)
        #expect(kills.withLock { $0 } == 0)
        await model.shutdown()
    }
}
