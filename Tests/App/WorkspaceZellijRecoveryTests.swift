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
    @Test("remote transport loss reconnects an active Zellij session")
    func remoteReconnect() async throws {
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
        let store = RecordingNativeSessionSurfaceStore()
        let probes = Mutex(0)
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
            zellijSessionDiscovery: { _ in
                probes.withLock { $0 += 1 }
                return .available(["api"])
            },
            tmuxReconnectIntervals: [.zero],
            tmuxReconnectProbeDeadline: .seconds(1)
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
        close(false, 255)
        await waitUntilMainActor {
            probes.withLock { $0 } >= 1
                && store.requestedConfigurations.count == 2
        }

        #expect(model.activeBorrowedZellijSelection == selection)
        #expect(store.lastCommand?.contains("dev@builder") == true)
        await model.shutdown()
    }

    @Test("retryable Zellij surface failure keeps recovering instead of latching")
    func retryableZellijSurfaceFailureKeepsRecovering() async throws {
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
            tmuxReconnectIntervals: [.milliseconds(1)],
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

        // Displays vanished between the gate and surface creation. Recovery
        // must re-arm each time rather than latching after the first failure,
        // so attempts keep accumulating.
        store.surface.launchError = ZellijSurfaceLaunchTestError.rejected
        store.surface.launchFailureIsRetryable = true
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.requestedConfigurations.count >= 3)
        #expect(model.zellijReconnectSupervisorIsRunning)

        store.surface.launchError = nil
        store.surface.launchFailureIsRetryable = false
        await waitUntilMainActor(timeout: .seconds(5)) {
            model.activeBorrowedZellijSelection == selection
                && !model.zellijReconnectSupervisorIsRunning
        }

        #expect(model.activeBorrowedZellijSelection == selection)
        await model.shutdown()
    }

    @Test("recovered Zellij surface failure does not excuse a later exit")
    func recoveredZellijSurfaceFailureDoesNotExcuseLaterExit() async throws {
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
            tmuxReconnectIntervals: [.milliseconds(1)],
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

        // A transient surface failure, then a successful reconnect.
        store.surface.launchError = ZellijSurfaceLaunchTestError.rejected
        store.surface.launchFailureIsRetryable = true
        store.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor(timeout: .seconds(5)) {
            store.requestedConfigurations.count >= 2
        }
        store.surface.launchError = nil
        store.surface.launchFailureIsRetryable = false
        await waitUntilMainActor(timeout: .seconds(5)) {
            !model.zellijReconnectSupervisorIsRunning
                && model.activeBorrowedZellijSelection == selection
        }
        let recoveredCount = store.requestedConfigurations.count

        // A normal client exit is not a transport failure and must not inherit
        // the earlier transient failure's licence to retry.
        store.surface.closeObservers.values.first?(false, 0)
        try await Task.sleep(for: .milliseconds(150))

        #expect(store.requestedConfigurations.count == recoveredCount)
        #expect(!model.zellijReconnectSupervisorIsRunning)
        await model.shutdown()
    }

    @Test("no active display holds Zellij recovery without probing the host")
    func zeroDisplaysHoldsZellijRecovery() async throws {
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
        let store = RecordingNativeSessionSurfaceStore()
        let probes = Mutex(0)
        let displays = Mutex(1)
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
            activeDisplayCount: { displays.withLock { $0 } },
            zellijSessionDiscovery: { _ in
                probes.withLock { $0 += 1 }
                return .available(["api"])
            },
            tmuxReconnectIntervals: [.milliseconds(1)],
            tmuxReconnectProbeDeadline: .seconds(1)
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
        probes.withLock { $0 = 0 }

        displays.withLock { $0 = 0 }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor { model.zellijReconnectSupervisorIsRunning }
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.requestedConfigurations.count == 1)
        #expect(probes.withLock { $0 } == 0)
        #expect(model.zellijReconnectSupervisorIsRunning)

        displays.withLock { $0 = 1 }
        model.handleDisplayParametersChanged()
        await waitUntilMainActor {
            store.requestedConfigurations.count == 2
        }

        #expect(model.activeBorrowedZellijSelection == selection)
        await model.shutdown()
    }

    @Test("reconnect accepts same-route lease rollover during validation")
    func reconnectAcceptsSameRouteLeaseRollover() async throws {
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
        let frozen = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/frozen-zellij-config"],
            routeIdentity: "sha256:stable-route",
            generation: 1
        ))
        let probing = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/probing-zellij-config"],
            routeIdentity: "sha256:stable-route",
            generation: 2
        ))
        let rolledOver = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/rolled-over-zellij-config"],
            routeIdentity: "sha256:stable-route",
            generation: 3
        ))
        let current = Mutex(frozen)
        let validations = Mutex(0)
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
                let validation = validations.withLock {
                    $0 += 1
                    return $0
                }
                if validation == 2 {
                    current.withLock { $0 = rolledOver }
                }
                return .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
            },
            presentationSSHConnectionProvider: { _, _ in
                let connection = current.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            },
            tmuxReconnectIntervals: [.zero],
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
        current.withLock { $0 = probing }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor(timeout: .seconds(1)) {
            store.requestedConfigurations.count == 2
                && model.activeBorrowedZellijConnectionState == .connected
        }

        #expect(store.requestedConfigurations.count == 2)
        #expect(store.requestedConfigurations.last?.command?.contains(
            "/tmp/rolled-over-zellij-config"
        ) == true)
        await model.shutdown()
    }

    @Test(
        "dead Zellij reconnect lease is invalidated before retry",
        arguments: [false, true]
    )
    func deadZellijReconnectLeaseIsInvalidatedBeforeRetry(
        failsDuringResolution: Bool
    ) async throws {
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
        let original = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/original-zellij-config"],
            routeIdentity: "sha256:stable-route",
            generation: 1
        ))
        let replacement = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/replacement-zellij-config"],
            routeIdentity: "sha256:stable-route",
            generation: 3
        ))
        let current = Mutex(original)
        let invalidations = Mutex(0)
        let deadAttempts = Mutex(0)
        let deadConnection = testKwtSSHAttachment(
            arguments: ["-F", "/tmp/dead-zellij-config"],
            routeIdentity: "sha256:stable-route",
            generation: 2,
            invalidate: {
                invalidations.withLock { $0 += 1 }
                current.withLock { $0 = replacement }
            }
        )
        let dead = SSHConnectionArgumentsSnapshot(deadConnection)
        let deadDiagnostic =
            "Control socket connect(/tmp/dead): No such file or directory"
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
            nativeZellijPathProvider: { _ in
                let connection = current.withLock { $0 }
                guard failsDuringResolution,
                      connection.arguments == dead.arguments
                else { return .success("/usr/bin/zellij") }
                deadAttempts.withLock { $0 += 1 }
                return .failure(.commandFailed(
                    status: 255,
                    stderr: deadDiagnostic
                ))
            },
            zellijSessionDiscovery: { _ in .available(["api"]) },
            zellijSessionValidationDiscovery: { _, arguments in
                guard !failsDuringResolution,
                      arguments == dead.arguments
                else { return .available(["api"]) }
                deadAttempts.withLock { $0 += 1 }
                return .failure(.commandFailed(
                    status: 255,
                    stderr: deadDiagnostic
                ))
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
            },
            presentationSSHConnectionProvider: { _, _ in
                let connection = current.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            },
            tmuxReconnectIntervals: [.milliseconds(1)],
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
        current.withLock { $0 = dead }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor(timeout: .seconds(1)) {
            invalidations.withLock { $0 } == 1
                || deadAttempts.withLock { $0 } >= 3
        }

        guard invalidations.withLock({ $0 }) == 1 else {
            Issue.record("Expected the dead pooled connection to be invalidated")
            await model.shutdown()
            withExtendedLifetime(deadConnection) {}
            return
        }
        await waitUntilMainActor(timeout: .seconds(1)) {
            store.requestedConfigurations.count == 2
                && model.activeBorrowedZellijConnectionState == .connected
        }

        #expect(deadAttempts.withLock { $0 } == 1)
        #expect(store.requestedConfigurations.last?.command?.contains(
            "/tmp/replacement-zellij-config"
        ) == true)
        await model.shutdown()
        withExtendedLifetime(deadConnection) {}
    }

    @Test("reconnect rejects a different SSH route before probing")
    func reconnectRejectsDifferentSSHRouteBeforeProbing() async throws {
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
        let original = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/original-zellij-config"],
            routeIdentity: "sha256:original-route",
            generation: 1
        ))
        let replacement = SSHConnectionArgumentsSnapshot(
            testKwtSSHAttachment(
                arguments: ["-F", "/tmp/replacement-zellij-config"],
                routeIdentity: "sha256:replacement-route",
                generation: 2
            )
        )
        let current = Mutex(original)
        let probes = Mutex(0)
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
                probes.withLock { $0 += 1 }
                return .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
            },
            presentationSSHConnectionProvider: { _, _ in
                let connection = current.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            },
            tmuxReconnectIntervals: [.zero],
            tmuxReconnectProbeDeadline: .seconds(1)
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor {
            probes.withLock { $0 } == 1
                && store.requestedConfigurations.count == 1
                && !store.surface.closeObservers.isEmpty
        }
        current.withLock { $0 = replacement }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        let changedConnectionReason =
            "The SSH connection changed while Ghosthub was checking the Zellij session. Reopen it to use the current connection."
        await waitUntilMainActor {
            probes.withLock { $0 } > 1
                || model.activeBorrowedZellijConnectionState
                == .disconnected(reason: changedConnectionReason)
        }

        #expect(probes.withLock { $0 } == 1)
        #expect(store.requestedConfigurations.count == 1)
        #expect(
            model.activeBorrowedZellijConnectionState
                == .disconnected(reason: changedConnectionReason)
        )
        await model.shutdown()
    }

    @Test("successful SSH recovery resumes Zellij reconnect")
    func sshRecoveryResumesReconnect() async throws {
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
        let store = RecordingNativeSessionSurfaceStore()
        let original = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/original-zellij-config"],
            routeIdentity: "sha256:stable-route",
            generation: 1
        ))
        let failed = SSHConnectionArgumentsSnapshot.failClosed(
            KwtSSHLeaseError.helperUnavailable
        )
        let current = Mutex(original)
        let discoveries = Mutex<[ZellijDiscoveryResult]>([
            .available(["api"]),
            .failure(.commandFailed(
                status: 255,
                stderr: "Permission denied (publickey,password)."
            )),
            .available(["api"]),
        ])
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
            zellijSessionDiscovery: { _ in
                discoveries.withLock { $0.removeFirst() }
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
            },
            presentationSSHConnectionProvider: { _, _ in
                let connection = current.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            },
            tmuxReconnectIntervals: [.zero],
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
        current.withLock { $0 = failed }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            model.sessionConnectionRecoveryRequest?.hostID == host.id
        }
        guard case let .needsAttention(message, canReviewConnection) =
            model.activeBorrowedZellijRecoveryState
        else {
            Issue.record("Expected Zellij SSH recovery to need attention")
            await model.shutdown()
            return
        }
        #expect(message.contains("SSH authentication"))
        #expect(canReviewConnection)
        let recoveryRequest = try #require(
            model.sessionConnectionRecoveryRequest
        )

        current.withLock { $0 = original }
        model.resumeSessionReconnectAfterSSHRecovery(recoveryRequest)

        await waitUntilMainActor(timeout: .seconds(1)) {
            store.requestedConfigurations.count == 2
                && model.activeBorrowedZellijConnectionState == .connected
        }
        #expect(model.sessionConnectionRecoveryRequest == nil)
        #expect(model.activeBorrowedZellijRecoveryState == nil)
        #expect(model.activeBorrowedZellijConnectionState == .connected)
        await model.shutdown()
    }

    @Test("Zellij resolver transport failure retries reconnect")
    func resolverTransportFailureRetriesReconnect() async throws {
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
        let resolutions = Mutex(0)
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in
                let attempt = resolutions.withLock {
                    $0 += 1
                    return $0
                }
                return attempt == 2
                    ? .failure(.commandFailed(
                        status: 255,
                        stderr: "ssh: connect to host builder port 22: Network is unreachable"
                    ))
                    : .success("/usr/bin/zellij")
            },
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            tmuxReconnectIntervals: [.zero],
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
            resolutions.withLock { $0 } >= 3
                && store.requestedConfigurations.count == 2
        }

        #expect(model.activeBorrowedZellijConnectionState == .connected)
        #expect(model.sessionConnectionRecoveryRequest == nil)
        await model.shutdown()
    }

    @Test(
        "Zellij resolver SSH failure publishes connection recovery",
        arguments: [
            (
                "Permission denied (publickey,password).",
                true
            ),
            (
                "Host key verification failed.",
                true
            ),
            (
                "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!",
                false
            ),
        ]
    )
    func resolverSSHFailurePublishesRecovery(
        stderr: String,
        canReviewConnection: Bool
    ) async throws {
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
        let resolutions = Mutex(0)
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in
                let attempt = resolutions.withLock {
                    $0 += 1
                    return $0
                }
                return attempt == 1
                    ? .success("/usr/bin/zellij")
                    : .failure(.commandFailed(status: 255, stderr: stderr))
            },
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            tmuxReconnectIntervals: [.zero],
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
            if case .needsAttention = model.activeBorrowedZellijRecoveryState {
                return true
            }
            return false
        }

        guard case let .needsAttention(_, allowsReview) =
            model.activeBorrowedZellijRecoveryState
        else {
            Issue.record("Expected Zellij resolver recovery state")
            await model.shutdown()
            return
        }
        #expect(allowsReview == canReviewConnection)
        #expect(
            (model.sessionConnectionRecoveryRequest != nil)
                == canReviewConnection
        )
        await model.shutdown()
    }

    @Test("Zellij resolver failure rejects SSH connection drift")
    func resolverFailureRejectsSSHConnectionDrift() async throws {
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
        let frozen = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/frozen-config"],
            routeIdentity: "sha256:frozen-route"
        ))
        let changed = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/changed-config"],
            routeIdentity: "sha256:changed-route"
        ))
        let currentConnection = Mutex(frozen)
        let resolverState = Mutex((calls: 0, blocked: false, released: false))
        defer { resolverState.withLock { $0.released = true } }
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
            nativeZellijPathProvider: { _ in
                let call = resolverState.withLock {
                    $0.calls += 1
                    return $0.calls
                }
                guard call > 1 else { return .success("/usr/bin/zellij") }
                resolverState.withLock { $0.blocked = true }
                while !resolverState.withLock({ $0.released }) {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return .failure(.commandFailed(
                    status: 255,
                    stderr: "Permission denied (publickey)."
                ))
            },
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                currentConnection.withLock { $0 }
            },
            presentationSSHConnectionProvider: { _, _ in
                let connection = currentConnection.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            },
            tmuxReconnectIntervals: [.zero],
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
            resolverState.withLock { $0.blocked }
        }
        currentConnection.withLock { $0 = changed }
        resolverState.withLock { $0.released = true }
        let changedConnectionReason =
            "The SSH connection changed while Ghosthub was checking the Zellij session. Reopen it to use the current connection."
        await waitUntilMainActor {
            model.activeBorrowedZellijConnectionState == .disconnected(
                reason: changedConnectionReason
            )
        }

        #expect(model.sessionConnectionRecoveryRequest == nil)
        #expect(model.activeBorrowedZellijRecoveryState == nil)
        await model.shutdown()
    }

    @Test("Zellij resolver deadline keeps reconnect retryable")
    func resolverDeadlineKeepsReconnectRetryable() async throws {
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
        let resolverState = Mutex((calls: 0, cancellations: 0))
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in
                let call = resolverState.withLock {
                    $0.calls += 1
                    return $0.calls
                }
                guard call > 1 else { return .success("/usr/bin/zellij") }
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                resolverState.withLock { $0.cancellations += 1 }
                return .failure(.unavailable)
            },
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api"])
            },
            tmuxReconnectIntervals: [.seconds(1)],
            tmuxReconnectProbeDeadline: .milliseconds(20)
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
            resolverState.withLock { $0.cancellations } >= 1
        }

        #expect(model.zellijReconnectSupervisorIsRunning)
        if case .reconnecting = model.activeBorrowedZellijConnectionState {
            // Expected: the supervisor remains responsible for recovery.
        } else {
            Issue.record("Expected Zellij reconnect to remain retryable")
        }
        await model.shutdown()
    }

    @Test("superseded Zellij resolver cannot disconnect replacement")
    func supersededResolverPreservesReplacement() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [
                ZellijSessionSummary(name: "api"),
                ZellijSessionSummary(name: "replacement"),
            ],
            zellijAvailable: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let connectionReads = Mutex(0)
        let resolverState = Mutex((
            calls: 0,
            blocked: false,
            cancelled: false,
            released: false
        ))
        defer { resolverState.withLock { $0.released = true } }
        let model = try makeModel(
            database: .inMemory(),
            localHostID: UUID(),
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in
                let call = resolverState.withLock {
                    $0.calls += 1
                    return $0.calls
                }
                guard call == 2 else { return .success("/usr/bin/zellij") }
                resolverState.withLock { $0.blocked = true }
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                resolverState.withLock { $0.cancelled = true }
                while !resolverState.withLock({ $0.released }) {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return .failure(.unavailable)
            },
            zellijSessionValidationDiscovery: { _, _ in
                .available(["api", "replacement"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                connectionReads.withLock { $0 += 1 }
                return SSHConnectionArgumentsSnapshot(arguments: [])
            },
            tmuxReconnectIntervals: [.zero],
            tmuxReconnectProbeDeadline: .seconds(1)
        )
        let initial = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )
        let replacement = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "replacement"
        )

        model.openBorrowedZellijSession(initial)
        await waitUntilMainActor {
            store.requestedConfigurations.count == 1
                && !store.surface.closeObservers.isEmpty
        }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            resolverState.withLock { $0.blocked }
        }

        model.openBorrowedZellijSession(replacement)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.activeBorrowedZellijSelection == replacement
                && store.requestedConfigurations.count == 2
                && resolverState.withLock { $0.cancelled }
        }
        let readsBeforeRelease = connectionReads.withLock { $0 }
        resolverState.withLock { $0.released = true }
        try await Task.sleep(for: .milliseconds(50))

        #expect(connectionReads.withLock { $0 } == readsBeforeRelease)
        #expect(model.activeBorrowedZellijSelection == replacement)
        #expect(model.activeBorrowedZellijConnectionState == .connected)
        #expect(model.activeBorrowedZellijRecoveryState == nil)
        await model.shutdown()
    }

    @Test("failed remote creation disappears when reconnect confirms absence")
    func failedRemoteCreationDisappears() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijAvailable: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let probes = Mutex(0)
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
            zellijSessionDiscovery: { _ in
                probes.withLock { $0 += 1 }
                return .available([])
            },
            zellijSessionValidationDiscovery: { _, _ in .available([]) },
            tmuxReconnectIntervals: [.zero],
            tmuxReconnectProbeDeadline: .seconds(1)
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor { probes.withLock { $0 } >= 1 }
        let initialProbeCount = probes.withLock { $0 }
        try await model.createZellijSession(selection)
        await waitUntilMainActor {
            store.requestedConfigurations.count == 1
                && !store.surface.closeObservers.isEmpty
        }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor(timeout: .seconds(1)) {
            probes.withLock { $0 } >= initialProbeCount + 2
                && model.snapshot.host(id: host.id)?
                .zellijSessions.isEmpty == true
        }

        #expect(model.snapshot.host(id: host.id)?.zellijSessions.isEmpty == true)
        await model.shutdown()
    }

    @Test("an immediate creation transport exit reacquires its kwt route")
    func immediateCreationExitReacquiresKwtRoute() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijAvailable: true
        )
        let frozen = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-zellij-config",
        ])
        let store = RecordingNativeSessionSurfaceStore(
            closeOnRegistrationCode: 255
        )
        let probes = Mutex(0)
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
                let attempt = probes.withLock {
                    $0 += 1
                    return $0
                }
                return attempt == 1
                    ? .available([]) : .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in frozen },
            presentationSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(arguments: [
                    "-F", "/tmp/kwt-zellij-config",
                ])
            },
            tmuxReconnectIntervals: [.zero],
            tmuxReconnectProbeDeadline: .seconds(1)
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        try await model.createZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            probes.withLock { $0 } >= 1
                && store.requestedConfigurations.count == 2
        }

        #expect(store.lastCommand?.contains("/tmp/kwt-zellij-config") == true)
        await model.shutdown()
    }

    @Test(
        "terminal reconnect failure retires pending creation",
        arguments: [
            ZellijTerminalReconnectFailureCase(
                name: "unavailable executable",
                result: .unavailable,
                reason: "Zellij is no longer available on this host."
            ),
            ZellijTerminalReconnectFailureCase(
                name: "non-retryable command failure",
                result: .failure(.commandFailed(
                    status: 1,
                    stderr: "invalid session state"
                )),
                reason: "Zellij exited with status 1: invalid session state"
            ),
        ]
    )
    func terminalReconnectFailureRetiresPendingCreation(
        _ failure: ZellijTerminalReconnectFailureCase
    ) async throws {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijAvailable: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let probes = Mutex(0)
        let validations = Mutex(0)
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
            zellijSessionDiscovery: { _ in
                let attempt = probes.withLock {
                    $0 += 1
                    return $0
                }
                return attempt == 1 ? failure.result : .available([])
            },
            zellijSessionValidationDiscovery: { _, _ in
                let attempt = validations.withLock {
                    $0 += 1
                    return $0
                }
                return attempt == 1 ? .available([]) : failure.result
            },
            tmuxReconnectIntervals: [.zero],
            tmuxReconnectProbeDeadline: .seconds(1)
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        try await model.createZellijSession(selection)
        await waitUntilMainActor {
            store.requestedConfigurations.count == 1
                && !store.surface.closeObservers.isEmpty
        }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.activeBorrowedZellijConnectionState
                == .disconnected(reason: failure.reason)
        }

        model.startZellijSessionDiscovery()
        await waitUntilMainActor(timeout: .seconds(1)) {
            probes.withLock { $0 } >= 2
        }

        #expect(model.snapshot.host(id: host.id)?.zellijSessions.isEmpty == true)
        await model.shutdown()
    }

}
