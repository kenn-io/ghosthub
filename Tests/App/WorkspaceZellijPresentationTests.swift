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
    @Test("dead remote Zellij resolution invalidates before lease release")
    func deadResolutionInvalidatesConnection() async {
        let events = LockedValue<[String]>([])
        let coordinator = NativeZellijSessionCoordinator(
            terminalCoordinator: RecordingNativeSessionSurfaceStore(),
            zellijPathProvider: { _, _ in
                .failure(.commandFailed(
                    status: 255,
                    stderr: "Control socket connect(/tmp/dead): missing"
                ))
            },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment(
                    release: { events.withLock { $0.append("release") } },
                    invalidate: { events.withLock { $0.append("invalidate") } }
                )
            }
        )
        var disconnected = false
        coordinator.onStateChanged = { _, state in
            if case .disconnected = state {
                disconnected = true
            }
        }

        _ = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: .ssh(.init(
                user: "dev",
                hostname: "build.example.test",
                port: nil
            ))
        )

        await waitUntilMainActor {
            disconnected && events.load().count == 2
        }
        #expect(events.load() == ["invalidate", "release"])
    }

    @Test("remote attachment rejects route drift after validation")
    func remoteAttachmentRejectsRouteDrift() async {
        let expectedConnection = testKwtSSHAttachment(
            routeIdentity: "sha256:expected"
        )
        let expected = SSHConnectionArgumentsSnapshot(
            expectedConnection
        )
        let releases = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeZellijSessionCoordinator(
            terminalCoordinator: store,
            zellijPathProvider: { _, _ in .success("/usr/bin/zellij") },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment(routeIdentity: "sha256:changed") {
                    releases.withLock { $0 += 1 }
                }
            }
        )
        var state: ConnectionState?
        coordinator.onStateChanged = { _, newState in state = newState }

        _ = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: .ssh(.init(
                user: "dev",
                hostname: "build.example.test",
                port: 2222
            )),
            sshConnectionSnapshot: expected,
            resolvedZellijPath: "/usr/bin/zellij"
        )

        await waitUntilMainActor {
            state == .disconnected(
                reason: KwtSSHLeaseError.routeChanged.localizedDescription
            )
        }
        #expect(store.requestedConfigurations.isEmpty)
        #expect(releases.load() == 1)
    }

    @Test("new session presentation creates and attaches through Zellij")
    func createAndAttach() async throws {
        let environment = try zellijEnvironment(sessions: [])
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionValidationDiscovery: { _, _ in .available([]) }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release work"
        )

        try await model.createZellijSession(selection)
        await waitUntilMainActor { store.lastCommand != nil }

        let command = try #require(store.lastCommand)
        #expect(command.contains("--session"))
        #expect(command.contains("release work"))
        #expect(!command.contains("'attach'"))
        #expect(model.activeBorrowedZellijSelection == selection)
        await model.shutdown()
    }

    @Test(
        "failed creation retry follows the live Zellij session state",
        arguments: [false, true]
    )
    func failedCreationRetryUsesLiveState(
        sessionBecameActive: Bool
    ) async throws {
        let environment = try zellijEnvironment(sessions: [])
        let store = RecordingNativeSessionSurfaceStore(
            launchError: ZellijCommandError.unavailable
        )
        let validations = Mutex<[ZellijDiscoveryResult]>([
            .available([]),
            .available(sessionBecameActive ? ["release"] : []),
            .available([]),
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in .available([]) },
            zellijSessionValidationDiscovery: { _, _ in
                validations.withLock { $0.removeFirst() }
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release"
        )

        try await model.createZellijSession(selection)
        await waitUntilMainActor {
            store.requestedConfigurations.count == 1
                && model.activeBorrowedZellijConnectionState == .disconnected(
                    reason: ZellijCommandError.unavailable.localizedDescription
                )
        }

        model.retryBorrowedZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            store.requestedConfigurations.count == 2
        }

        let retryCommand = try #require(store.lastCommand)
        if sessionBecameActive {
            #expect(retryCommand.contains("'attach'"))
            #expect(!retryCommand.contains("--session=release"))

            await waitUntilMainActor {
                model.activeBorrowedZellijConnectionState == .disconnected(
                    reason: ZellijCommandError.unavailable.localizedDescription
                )
            }
            model.retryBorrowedZellijSession(selection)
            await waitUntilMainActor(timeout: .seconds(1)) {
                store.requestedConfigurations.count == 3
            }

            #expect(store.lastCommand?.contains("--session=release") == true)
            #expect(store.lastCommand?.contains("'attach'") == false)
        } else {
            #expect(retryCommand.contains("--session=release"))
            #expect(!retryCommand.contains("'attach'"))
        }
        await model.shutdown()
    }

    @Test("creation rejects a newly conflicting name without replacing tmux")
    func creationConflictPreservesTmux() async throws {
        var environment = try zellijEnvironment(sessions: [])
        environment.snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "tmux-work",
                managed: false,
                windows: []
            ),
        ]
        let zellijStore = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: zellijStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionValidationDiscovery: { _, _ in
                .available(["release"])
            }
        )
        let tmux = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "tmux-work"
        )
        let zellij = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release"
        )
        model.openBorrowedTmuxSession(tmux)

        await #expect(throws: ZellijSessionPresentationError.sessionExists(
            "release"
        )) {
            try await model.createZellijSession(zellij)
        }

        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(zellijStore.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("creation rejects executable failure without replacing tmux")
    func creationExecutableFailurePreservesTmux() async throws {
        var environment = try zellijEnvironment(sessions: [])
        environment.snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "tmux-work",
                managed: false,
                windows: []
            ),
        ]
        let zellijStore = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: zellijStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeZellijPathProvider: { _ in .failure(.unavailable) },
            zellijSessionValidationDiscovery: { _, _ in .available([]) }
        )
        let tmux = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "tmux-work"
        )
        let zellij = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release"
        )
        model.openBorrowedTmuxSession(tmux)

        await #expect(throws: ZellijSessionPresentationError.unavailable) {
            try await model.createZellijSession(zellij)
        }

        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(zellijStore.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("a delayed create cannot replace newer tmux navigation")
    func delayedCreateRespectsNewerNavigation() async throws {
        var environment = try zellijEnvironment(sessions: [])
        environment.snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "tmux-work",
                managed: false,
                windows: []
            ),
        ]
        let zellijStore = RecordingNativeSessionSurfaceStore()
        let probeStarted = Mutex(false)
        let probeContinuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: zellijStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionValidationDiscovery: { _, _ in
                probeStarted.withLock { $0 = true }
                await withCheckedContinuation { continuation in
                    probeContinuation.withLock { $0 = continuation }
                }
                return .available([])
            }
        )
        let createTarget = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release"
        )
        let newerTmux = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "tmux-work"
        )

        let create = Task {
            try await model.createZellijSession(createTarget)
        }
        await waitUntilMainActor { probeStarted.withLock { $0 } }
        model.openBorrowedTmuxSession(newerTmux)
        let continuation = probeContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        continuation?.resume()

        await #expect(throws: CancellationError.self) {
            try await create.value
        }
        #expect(model.activeBorrowedTmuxSelection == newerTmux)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(zellijStore.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("tmux and Zellij replace one another symmetrically")
    func presentationsAreExclusive() async throws {
        var environment = try zellijEnvironment(sessions: ["zellij-work"])
        environment.snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "tmux-work",
                managed: false,
                windows: []
            ),
        ]
        let zellijStore = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: zellijStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in .available(["zellij-work"]) }
        )
        let tmux = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "tmux-work"
        )
        let zellij = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "zellij-work"
        )

        model.openBorrowedTmuxSession(tmux)
        let tmuxHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: tmux)
        )
        model.openBorrowedZellijSession(zellij)
        await waitUntilMainActor {
            model.activeBorrowedZellijSelection == zellij
        }
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.activeBorrowedZellijSelection == zellij)
        #expect(model.retainedBorrowedTmuxHandle(for: tmux) == tmuxHandle)

        model.openBorrowedTmuxSession(tmux)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(model.retainedBorrowedTmuxHandle(for: tmux) == tmuxHandle)
        #expect(zellijStore.removedKeys.contains {
            $0.target == .zellijSession
        })
        await model.shutdown()
    }

    @Test("a delayed attachment cannot replace newer tmux navigation")
    func delayedAttachmentRespectsNewerNavigation() async throws {
        var environment = try zellijEnvironment(sessions: ["zellij-work"])
        environment.snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "tmux-work",
                managed: false,
                windows: []
            ),
        ]
        let zellijStore = RecordingNativeSessionSurfaceStore()
        let probeStarted = Mutex(false)
        let probeFinished = Mutex(false)
        let releaseProbe = AsyncGate()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: zellijStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in
                probeStarted.withLock { $0 = true }
                await releaseProbe.wait()
                probeFinished.withLock { $0 = true }
                return .available(["zellij-work"])
            }
        )
        let zellij = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "zellij-work"
        )
        let newerTmux = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "tmux-work"
        )

        model.openBorrowedZellijSession(zellij)
        await waitUntilMainActor { probeStarted.withLock { $0 } }
        model.openBorrowedTmuxSession(newerTmux)
        releaseProbe.open()
        await waitUntilMainActor { probeFinished.withLock { $0 } }
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.activeBorrowedTmuxSelection == newerTmux)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(zellijStore.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("same-host sidebar navigation cancels delayed Zellij validation")
    func sameHostSidebarNavigationCancelsDelayedValidation() async throws {
        let environment = try zellijEnvironment(sessions: ["zellij-work"])
        let zellijStore = RecordingNativeSessionSurfaceStore()
        let probeStarted = Mutex(false)
        let probeFinished = Mutex(false)
        let executableResolutions = Mutex(0)
        let probeContinuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: zellijStore,
            nativeZellijPathProvider: { _ in
                executableResolutions.withLock { $0 += 1 }
                return .success("/usr/bin/zellij")
            },
            zellijSessionValidationDiscovery: { _, _ in
                probeStarted.withLock { $0 = true }
                await withCheckedContinuation { continuation in
                    probeContinuation.withLock { $0 = continuation }
                }
                probeFinished.withLock { $0 = true }
                return .available(["zellij-work"])
            }
        )
        let zellij = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "zellij-work"
        )

        model.openBorrowedZellijSession(zellij)
        await waitUntilMainActor { probeStarted.withLock { $0 } }
        model.cancelPendingZellijPresentation()
        model.synchronizeSelection(WorkspaceSelection(
            selectedHostID: environment.host.id
        ))
        let continuation = probeContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        continuation?.resume()
        await waitUntilMainActor { probeFinished.withLock { $0 } }
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(zellijStore.requestedConfigurations.isEmpty)
        #expect(executableResolutions.withLock { $0 } == 0)
        await model.shutdown()
    }

    @Test("navigation cancellation terminates Zellij executable resolution")
    func navigationCancelsExecutableResolution() async throws {
        let environment = try zellijEnvironment(sessions: ["zellij-work"])
        let zellijStore = RecordingNativeSessionSurfaceStore()
        let resolverState = Mutex((
            started: false,
            cancelled: false,
            released: false
        ))
        defer { resolverState.withLock { $0.released = true } }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: zellijStore,
            nativeZellijPathProvider: { _ in
                resolverState.withLock { $0.started = true }
                while !resolverState.withLock({ $0.released }) {
                    if Task.isCancelled {
                        resolverState.withLock { $0.cancelled = true }
                        return .failure(.unavailable)
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return .failure(.unavailable)
            },
            zellijSessionValidationDiscovery: { _, _ in
                .available(["zellij-work"])
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "zellij-work"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            resolverState.withLock { $0.started }
        }
        model.cancelPendingZellijPresentation()
        await waitUntilMainActor {
            resolverState.withLock { $0.cancelled }
        }

        #expect(zellijStore.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("runner timeout retries an active Zellij reconnect")
    func runnerTimeoutRetriesReconnect() async throws {
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
        let store = RecordingNativeSessionSurfaceStore()
        let results = Mutex<[ZellijDiscoveryResult]>([
            .available(["api"]),
            .failure(.commandFailed(
                status: AccountCommandRunner.timedOutStatus,
                stderr: "SSH command timed out."
            )),
            .available(["api"]),
        ])
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [], worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in
                results.withLock { $0.removeFirst() }
            },
            tmuxReconnectIntervals: [.zero, .zero],
            tmuxReconnectProbeDeadline: .seconds(1)
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            store.requestedConfigurations.count == 1
                && !store.surface.closeObservers.isEmpty
        }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor(timeout: .seconds(1)) {
            store.requestedConfigurations.count == 2
        }

        #expect(model.activeBorrowedZellijConnectionState == .connected)
        #expect(results.withLock { $0.isEmpty })
        await model.shutdown()
    }

    @Test("Reconnect Now interrupts the Zellij retry delay")
    func reconnectNowInterruptsRetryDelay() async throws {
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
        let store = RecordingNativeSessionSurfaceStore()
        let results = Mutex<[ZellijDiscoveryResult]>([
            .available(["api"]),
            .failure(.commandFailed(
                status: 255,
                stderr: "Connection timed out."
            )),
            .available(["api"]),
        ])
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [], worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in
                results.withLock { $0.removeFirst() }
            },
            tmuxReconnectIntervals: [.seconds(30)],
            tmuxReconnectProbeDeadline: .seconds(1)
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            store.requestedConfigurations.count == 1
                && !store.surface.closeObservers.isEmpty
        }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            model.activeBorrowedZellijRecoveryState?.isReconnecting == true
                && results.withLock { $0.count } == 1
        }
        try await Task.sleep(for: .milliseconds(20))

        model.reconnectActiveZellijSessionNow()

        await waitUntilMainActor {
            store.requestedConfigurations.count == 2
                && model.activeBorrowedZellijConnectionState == .connected
        }
        #expect(model.activeBorrowedZellijRecoveryState == nil)
        await model.shutdown()
    }

    @Test("initial validation retains an actionable failure", arguments: [
        ZellijValidationFailureCase(
            name: "missing session",
            result: .available([]),
            reason: "The Zellij session is no longer running."
        ),
        ZellijValidationFailureCase(
            name: "unavailable executable",
            result: .unavailable,
            reason: "Zellij is unavailable on this host."
        ),
        ZellijValidationFailureCase(
            name: "command failure",
            result: .failure(.commandFailed(
                status: 255,
                stderr: "Permission denied (publickey)."
            )),
            reason: "Zellij exited with status 255: Permission denied (publickey)."
        ),
    ])
    func initialValidationRetainsFailure(
        _ failure: ZellijValidationFailureCase
    ) async throws {
        let environment = try zellijEnvironment(sessions: ["api"])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: RecordingNativeSessionSurfaceStore(),
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in failure.result }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.activeBorrowedZellijConnectionState
                == .disconnected(reason: failure.reason)
        }

        #expect(model.activeBorrowedZellijSelection == selection)
        #expect(model.activeBorrowedZellijConnectionState
            == .disconnected(reason: failure.reason))
        await model.shutdown()
    }

    @Test("retry probes a retained session after inventory becomes unavailable")
    func retryIgnoresCachedAvailability() async throws {
        let environment = try zellijEnvironment(sessions: ["api"])
        let validations = Mutex<[ZellijDiscoveryResult]>([
            .unavailable,
            .available(["api"]),
        ])
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in .unavailable },
            zellijSessionValidationDiscovery: { _, _ in
                validations.withLock { $0.removeFirst() }
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.activeBorrowedZellijConnectionState == .disconnected(
                reason: "Zellij is unavailable on this host."
            )
        }
        model.startZellijSessionDiscovery()
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.snapshot.host(id: environment.host.id)?
                .zellijAvailable == false
        }

        model.retryBorrowedZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.activeBorrowedZellijConnectionState == .connected
        }

        #expect(validations.withLock { $0.isEmpty })
        #expect(store.requestedConfigurations.count == 1)
        await model.shutdown()
    }

    @Test("failed validation preserves a healthy tmux presentation")
    func failedValidationPreservesTmux() async throws {
        var environment = try zellijEnvironment(sessions: ["api"])
        environment.snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "tmux-work",
                managed: false,
                windows: []
            ),
        ]
        let zellijStore = RecordingNativeSessionSurfaceStore()
        let probes = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: zellijStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in
                probes.withLock { $0 += 1 }
                return .available([])
            },
            zellijSessionValidationDiscovery: { _, _ in .available([]) }
        )
        let tmux = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "tmux-work"
        )
        let zellij = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "api"
        )

        model.openBorrowedTmuxSession(tmux)
        model.openBorrowedZellijSession(zellij)
        await waitUntilMainActor {
            model.pendingZellijPresentationSelection == nil
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(zellijStore.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("reopening an attached session does not revalidate it")
    func reopeningAttachedSessionDoesNotRevalidate() async throws {
        let environment = try zellijEnvironment(sessions: ["api"])
        let store = RecordingNativeSessionSurfaceStore()
        let result = Mutex<ZellijDiscoveryResult>(.available(["api"]))
        let probes = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in
                probes.withLock { $0 += 1 }
                return result.withLock { $0 }
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            model.activeBorrowedZellijConnectionState == .connected
        }
        result.withLock {
            $0 = .failure(.commandFailed(
                status: 1,
                stderr: "transient inventory failure"
            ))
        }

        model.openBorrowedZellijSession(selection)
        try await Task.sleep(for: .milliseconds(50))

        #expect(probes.withLock { $0 } == 1)
        #expect(model.activeBorrowedZellijConnectionState == .connected)
        #expect(store.requestedConfigurations.count == 1)
        await model.shutdown()
    }

    @Test("validation and presentation keep independent SSH ownership")
    func attachmentUsesKwtPresentationRoute() async throws {
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
            "-F", "/tmp/frozen-zellij-config",
        ])
        let validations = Mutex([[String]]())
        let releases = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: database,
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in .available(["api"]) },
            zellijSessionValidationDiscovery: { _, arguments in
                validations.withLock { $0.append(arguments) }
                return .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in frozen },
            presentationSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(arguments: [
                    "-F", "/tmp/kwt-zellij-config",
                ]) {
                    releases.withLock { $0 += 1 }
                }
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor { store.lastCommand != nil }

        #expect(validations.withLock { $0 } == [frozen.arguments])
        #expect(store.lastCommand?.contains("/tmp/kwt-zellij-config") == true)
        #expect(store.lastCommand?.contains("/tmp/frozen-zellij-config") == false)
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 0)
        await waitUntilMainActor { releases.load() == 1 }
        await model.shutdown()
    }

    @Test("demo presentation bypasses kwt SSH acquisition")
    func demoPresentationBypassesKwtSSH() async throws {
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
        let acquisitions = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let scratch = "/tmp/ghosthub-demo"
        let demoEnvironment = [
            "GHOSTHUB_DEMO_SCRATCH": scratch,
            "GHOSTHUB_DEMO_SSH_DIR": "\(scratch)/ssh",
        ]
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
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { info in
                SSHConnectionArgumentsSnapshot(KwtSSHConnection(
                    arguments: demoSSHIsolationArguments(
                        environment: demoEnvironment
                    ),
                    routeIdentity: SSHDestination.demoRouteIdentity(info),
                    generation: 0
                ))
            },
            presentationSSHConnectionProvider: { _, _ in
                acquisitions.withLock { $0 += 1 }
                return testKwtSSHAttachment()
            },
            presentationSSHEnvironment: demoEnvironment
        )

        model.openBorrowedZellijSession(.init(
            hostID: host.id,
            name: "api"
        ))
        await waitUntilMainActor { store.lastCommand != nil }

        #expect(acquisitions.load() == 0)
        #expect(store.lastCommand?.contains("\(scratch)/ssh/config") == true)
        await model.shutdown()
    }

    @Test("attachment rejects SSH route drift after validation")
    func attachmentRejectsSSHRouteDrift() async throws {
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
            "-F", "/tmp/frozen-zellij-config",
        ])
        let changed = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/changed-zellij-config",
        ])
        let current = Mutex(frozen)
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: database,
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in .available(["api"]) },
            zellijSessionValidationDiscovery: { _, _ in
                current.withLock { $0 = changed }
                return .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.activeBorrowedZellijConnectionState == .disconnected(
                reason: "The SSH connection changed while Ghosthub was checking the Zellij session. Reopen it to use the current connection."
            )
        }

        #expect(store.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("endpoint changes detach the active Zellij client")
    func endpointChangeDetaches() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@old.example.test",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let configured = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: host.configKey,
                name: host.name,
                platform: .linux,
                sshDestination: "dev@old.example.test"
            ),
        ])
        let store = RecordingNativeSessionSurfaceStore()
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
            zellijSessionDiscovery: { _ in .available(["api"]) },
            configuredSSHHostsProvider: { configured.value }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            model.activeBorrowedZellijSelection == selection
                && store.lastCommand != nil
        }
        configured.value = [
            SSHHost(
                configKey: host.configKey,
                name: host.name,
                platform: .linux,
                sshDestination: "dev@new.example.test"
            ),
        ]
        model.refreshHosts()

        #expect(model.activeBorrowedZellijSelection == nil)
        #expect(store.removedKeys.contains { $0.target == .zellijSession })
        await model.shutdown()
    }

    @Test("new sessions remain visible through initial empty discovery")
    func creationPublishesOptimistically() async throws {
        let environment = try zellijEnvironment(sessions: [])
        let store = RecordingNativeSessionSurfaceStore()
        let probes = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in
                probes.withLock { $0 += 1 }
                return .available([])
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release"
        )

        model.startZellijSessionDiscovery()
        try await model.createZellijSession(selection)
        await waitUntilMainActor {
            store.lastCommand != nil && probes.withLock { $0 } >= 2
        }

        #expect(model.snapshot.host(id: environment.host.id)?
            .zellijSessions.map(\.name) == ["release"])
        await model.shutdown()
    }

    @Test(
        "pending creation survives transient discovery and retries",
        arguments: [
            ZellijPendingDiscoveryFailureCase(
                name: "unavailable executable",
                result: .unavailable
            ),
            ZellijPendingDiscoveryFailureCase(
                name: "command failure",
                result: .failure(.commandFailed(
                    status: 1,
                    stderr: "temporary inventory failure"
                ))
            ),
        ]
    )
    func creationSurvivesTransientDiscovery(
        _ failure: ZellijPendingDiscoveryFailureCase
    ) async throws {
        let environment = try zellijEnvironment(sessions: [])
        let store = RecordingNativeSessionSurfaceStore()
        let probes = Mutex(0)
        let releaseConfirmation = AsyncGate()
        defer { releaseConfirmation.open() }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { _ in
                let attempt = probes.withLock {
                    $0 += 1
                    return $0
                }
                switch attempt {
                case 1:
                    return .available([])
                case 2:
                    return failure.result
                default:
                    await releaseConfirmation.wait()
                    return .available(["release", "confirmed"])
                }
            },
            zellijSessionValidationDiscovery: { _, _ in .available([]) },
            createdSessionDiscoveryDelays: [.zero]
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release"
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor { probes.withLock { $0 } >= 1 }
        try await model.createZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            probes.withLock { $0 } >= 3
        }

        #expect(model.snapshot.host(id: environment.host.id)?
            .zellijSessions.map(\.name) == ["release"])
        #expect(model.snapshot.host(id: environment.host.id)?
            .zellijAvailable == true)

        releaseConfirmation.open()
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.snapshot.host(id: environment.host.id)?
                .zellijSessions.map(\.name) == ["release", "confirmed"]
        }
        await model.shutdown()
    }

    @Test("creation retries wait for the fleet and back off on pending hosts")
    func creationRetriesAfterFleetCompletion() async throws {
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            zellijAvailable: true
        )
        let remote = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijAvailable: true
        )
        let localHost = CommandHost.local
        let remoteHost = CommandHost.ssh(SSHHostInfo(
            user: "dev",
            hostname: "builder",
            port: nil
        ))
        let probes = Mutex([CommandHost: Int]())
        let releaseLocal = AsyncGate()
        let releaseRemote = AsyncGate()
        defer {
            releaseLocal.open()
            releaseRemote.open()
        }
        let model = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local, remote],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: RecordingNativeSessionSurfaceStore(),
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { host in
                let attempt = probes.withLock {
                    $0[host, default: 0] += 1
                    return $0[host] ?? 0
                }
                if attempt == 1 {
                    switch host {
                    case .local:
                        await releaseLocal.wait()
                    case .ssh:
                        await releaseRemote.wait()
                    }
                }
                return .available([])
            },
            zellijSessionValidationDiscovery: { _, _ in .available([]) },
            createdSessionDiscoveryDelays: [
                .milliseconds(20),
                .seconds(60),
            ]
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: local.id,
            name: "release"
        )

        try await model.createZellijSession(selection)
        await waitUntilMainActor {
            model.activeBorrowedZellijConnectionState == .connected
        }
        model.startZellijSessionDiscovery()
        await waitUntilMainActor(timeout: .seconds(1)) {
            probes.withLock {
                $0[localHost] == 1 && $0[remoteHost] == 1
            }
        }
        releaseLocal.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(probes.withLock { $0[localHost] } == 1)
        #expect(probes.withLock { $0[remoteHost] } == 1)

        releaseRemote.open()
        await waitUntilMainActor(timeout: .seconds(1)) {
            probes.withLock { $0[localHost] == 2 }
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(probes.withLock { $0[localHost] } == 2)
        #expect(probes.withLock { $0[remoteHost] } == 1)
        await model.shutdown()
    }

    @Test("creation retry does not cancel an overlapping fleet refresh")
    func creationRetryPreservesFleetRefresh() async throws {
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            zellijAvailable: true
        )
        let remote = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "old")],
            zellijAvailable: true
        )
        let localProbes = Mutex(0)
        let remoteProbes = Mutex(0)
        let releaseInitialLocal = AsyncGate()
        let releaseInitialRemote = AsyncGate()
        let releaseRetryLocal = AsyncGate()
        let releaseManualRemote = AsyncGate()
        let retryTimedOut = Mutex(false)
        defer {
            releaseInitialLocal.open()
            releaseInitialRemote.open()
            releaseRetryLocal.open()
            releaseManualRemote.open()
        }
        let model = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local, remote],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: RecordingNativeSessionSurfaceStore(),
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: { host in
                let isRemote = host.isRemote
                let attempt = if isRemote {
                    remoteProbes.withLock {
                        $0 += 1
                        return $0
                    }
                } else {
                    localProbes.withLock {
                        $0 += 1
                        return $0
                    }
                }
                if attempt == 1 {
                    if isRemote {
                        await releaseInitialRemote.wait()
                    } else {
                        await releaseInitialLocal.wait()
                    }
                } else if !isRemote, attempt == 3 {
                    if await releaseRetryLocal.wait(
                        timeout: .seconds(1)
                    ) == false {
                        retryTimedOut.withLock { $0 = true }
                    }
                } else if isRemote, attempt == 3 {
                    await releaseManualRemote.wait()
                }
                if isRemote {
                    let names = switch attempt {
                    case 1: ["initial"]
                    case 2: ["intermediate"]
                    default: ["new"]
                    }
                    return .available(names)
                }
                return .available([])
            },
            zellijSessionValidationDiscovery: { _, _ in .available([]) },
            createdSessionDiscoveryDelays: [
                .milliseconds(100),
                .seconds(60),
            ]
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: local.id,
            name: "release"
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor {
            localProbes.withLock { $0 } == 1
                && remoteProbes.withLock { $0 } == 1
        }
        releaseInitialLocal.open()
        releaseInitialRemote.open()
        await waitUntilMainActor {
            model.snapshot.host(id: remote.id)?.zellijSessions.map(\.name)
                == ["initial"]
        }
        try await model.createZellijSession(selection)
        await waitUntilMainActor {
            localProbes.withLock { $0 } == 2
                && remoteProbes.withLock { $0 } == 2
                && model.snapshot.host(id: remote.id)?
                .zellijSessions.map(\.name) == ["intermediate"]
        }
        await waitUntilMainActor {
            localProbes.withLock { $0 } == 3
                && remoteProbes.withLock { $0 } == 2
        }
        model.refreshKwtInventory()
        await waitUntilMainActor {
            remoteProbes.withLock { $0 } == 3
        }
        #expect(!retryTimedOut.withLock { $0 })
        releaseRetryLocal.open()
        releaseManualRemote.open()
        await waitUntilMainActor {
            model.snapshot.host(id: remote.id)?.zellijSessions.map(\.name)
                == ["new"]
        }

        #expect(model.snapshot.host(id: remote.id)?
            .zellijSessions.map(\.name) == ["new"])
        await model.shutdown()
    }

}
