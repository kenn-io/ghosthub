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
    @Test("reconnect validation probe cancellation reaches detached work")
    func reconnectValidationProbeCancellation() async throws {
        let started = Mutex(false)
        let observedCancellation = Mutex(false)
        let probe = Task {
            await WorkspaceSceneModel.runReconnectValidationProbe {
                started.withLock { $0 = true }
                let deadline = Date().addingTimeInterval(0.5)
                while !Task.isCancelled, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                observedCancellation.withLock { $0 = Task.isCancelled }
            }
        }
        for _ in 0 ..< 100 where !started.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(started.withLock { $0 })

        probe.cancel()
        await probe.value

        #expect(observedCancellation.withLock { $0 })
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
    @Test("immediate transport exit retains the acquired SSH route")
    func immediateTransportExitRetainsAcquiredRoute() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = RecordingNativeSessionSurfaceStore(
            closeOnRegistrationCode: 255
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionValidationDiscovery: { _, _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            presentationSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(routeIdentity: "sha256:stable-route")
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )

        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            surfaceStore.requestedConfigurations.count >= 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(surfaceStore.requestedConfigurations.count >= 2)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test("dead tmux reconnect lease is invalidated before retry")
    func deadTmuxReconnectLeaseIsInvalidatedBeforeRetry() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let generation = Mutex(UInt64(1))
        let probedGenerations = Mutex([UInt64]())
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionValidationDiscovery: { _, _ in
                let value = generation.withLock { $0 }
                probedGenerations.withLock { $0.append(value) }
                guard value == 2 else {
                    return .success([
                        DiscoveredTmuxSession(
                            name: "release-work",
                            windowCount: 1,
                            createdAt: nil,
                            managed: false
                        ),
                    ])
                }
                return .failure(.sshConnectionFailed(
                    host: "build.example.test",
                    classification: SSHConnectionFailure.classify(
                        status: 255,
                        output: "Control socket connect(/tmp/dead): missing"
                    )
                ))
            },
            presentationSSHConnectionProvider: { _, _ in
                let value = generation.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: ["-F", "/tmp/tmux-generation-\(value)-config"],
                    routeIdentity: "sha256:stable-route",
                    generation: value,
                    invalidate: {
                        generation.withLock { current in
                            if current == value {
                                current = 3
                            }
                        }
                    }
                )
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        generation.withLock { $0 = 2 }
        probedGenerations.withLock { $0.removeAll() }
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor(timeout: .seconds(1)) {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(probedGenerations.withLock { $0.prefix(2) } == [2, 3])
        #expect(surfaceStore.lastConfiguration?.command?.contains(
            "/tmp/tmux-generation-3-config"
        ) == true)
        await model.shutdown()
    }

    @MainActor
    @Test("SSH acquisition failure ends a tmux reconnect handoff")
    func sshAcquisitionFailureEndsTmuxReconnect() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let acquisitions = Mutex(0)
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
            presentationSSHConnectionProvider: { _, _ in
                let attempt = acquisitions.withLock {
                    $0 += 1
                    return $0
                }
                guard attempt == 1 else {
                    throw KwtSSHLeaseError.helperUnavailable
                }
                return testKwtSSHAttachment()
            },
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
            acquisitions.withLock { $0 } == 2
                && model.activeBorrowedTmuxRecoveryState == nil
        }

        #expect(surfaceStore.requestCount == 1)
        #expect(!model.anyTmuxReconnectSupervisorIsRunning)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "initial SSH transport failure starts tmux reconnect",
        arguments: [
            KwtSSHLeaseError.operationFailed(
                code: "ssh_connection_failed",
                message: "ssh: connect to host build.example.test port 22: No route to host",
                retryable: true
            ),
            .acquisitionTimedOut,
            .commandFailed(status: 255),
        ]
    )
    func initialSSHTransportFailureStartsTmuxReconnect(
        transportError: KwtSSHLeaseError
    ) async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let acquisitions = Mutex(0)
        let transportUnavailable = Mutex(true)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            sshRouteIdentityResolver: { _ in
                "sha256:recovered-route"
            },
            tmuxSessionValidationDiscovery: { _, _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            presentationSSHConnectionProvider: { _, _ in
                acquisitions.withLock { $0 += 1 }
                if transportUnavailable.withLock({ $0 }) {
                    throw transportError
                }
                return testKwtSSHAttachment(
                    routeIdentity: "sha256:recovered-route"
                )
            },
            tmuxReconnectIntervals: [.seconds(30)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )

        model.openBorrowedTmuxSession(selection)
        model.prepareActiveBorrowedTmuxSurface()
        await waitUntilMainActor(timeout: .seconds(1)) {
            acquisitions.withLock { $0 } >= 2
        }

        #expect(acquisitions.withLock { $0 } >= 2)
        #expect(model.activeBorrowedTmuxRecoveryState?.isReconnecting == true)
        #expect(model.activeBorrowedTmuxRecoveryState?.allowsReconnectNow == true)
        #expect(model.anyTmuxReconnectSupervisorIsRunning)
        #expect(model.presentationSSHSession == nil)
        #expect(surfaceStore.requestCount == 0)

        transportUnavailable.withLock { $0 = false }
        model.reconnectActiveTmuxSessionNow()
        await waitUntilMainActor(timeout: .seconds(1)) {
            surfaceStore.requestCount == 1
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(surfaceStore.requestCount == 1)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(!model.anyTmuxReconnectSupervisorIsRunning)
        await model.shutdown()
    }

    @MainActor
    @Test("retryable SSH transport acquisition keeps tmux reconnecting")
    func retryableSSHTransportAcquisitionKeepsTmuxReconnect() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let acquisitions = Mutex(0)
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
            presentationSSHConnectionProvider: { _, _ in
                let attempt = acquisitions.withLock {
                    $0 += 1
                    return $0
                }
                guard attempt == 1 else {
                    throw KwtSSHLeaseError.operationFailed(
                        code: "ssh_connection_failed",
                        message: "ssh: connect to host build.example.test port 22: No route to host",
                        retryable: true
                    )
                }
                return testKwtSSHAttachment()
            },
            tmuxReconnectIntervals: [.seconds(30)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            acquisitions.withLock { $0 } == 2
        }

        guard case .reconnecting = model.activeBorrowedTmuxRecoveryState else {
            Issue.record("expected automatic tmux reconnect to remain active")
            await model.shutdown()
            return
        }
        #expect(model.anyTmuxReconnectSupervisorIsRunning)
        #expect(model.presentationSSHSession == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("initial tmux resolution transport failure reconnects")
    func initialTmuxResolutionTransportFailureReconnects() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let resolutions = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { host, _ in
                let attempt = resolutions.withLock {
                    $0 += 1
                    return $0
                }
                guard attempt > 1 else {
                    return .failure(.sshConnectionFailed(
                        host: host.hostname,
                        classification: SSHConnectionFailure.classify(
                            status: 255,
                            output: "ssh: connect to host build.example.test port 22: Network is unreachable"
                        )
                    ))
                }
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionValidationDiscovery: { _, _ in
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
        model.prepareActiveBorrowedTmuxSurface()
        await waitUntilMainActor(timeout: .seconds(1)) {
            surfaceStore.requestCount == 1
                && model.activeBorrowedTmuxSessionIsConnected
        }

        #expect(resolutions.withLock { $0 } == 2)
        #expect(surfaceStore.requestCount == 1)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(model.presentationSSHSession == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("initial tmux recovery anchors its SSH route before probing")
    func initialTmuxRecoveryAnchorsRouteBeforeProbing() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let acquisitions = Mutex(0)
        let routeResolutions = Mutex(0)
        let probes = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            sshRouteIdentityResolver: { _ in
                routeResolutions.withLock { $0 += 1 }
                return "sha256:original-route"
            },
            tmuxSessionValidationDiscovery: { _, _ in
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
            presentationSSHConnectionProvider: { _, _ in
                let attempt = acquisitions.withLock {
                    $0 += 1
                    return $0
                }
                guard attempt > 1 else {
                    throw KwtSSHLeaseError.operationFailed(
                        code: "ssh_connection_failed",
                        message: "ssh: connect to host build.example.test port 22: Network is unreachable",
                        retryable: true
                    )
                }
                return testKwtSSHAttachment(
                    routeIdentity: "sha256:replacement-route"
                )
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )

        model.openBorrowedTmuxSession(selection)
        model.prepareActiveBorrowedTmuxSurface()
        await waitUntilMainActor(timeout: .seconds(1)) {
            acquisitions.withLock { $0 } >= 2
                && !model.anyTmuxReconnectSupervisorIsRunning
        }

        #expect(routeResolutions.withLock { $0 } == 1)
        #expect(acquisitions.withLock { $0 } == 2)
        #expect(probes.withLock { $0 } == 0)
        #expect(surfaceStore.requestCount == 0)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(!model.anyTmuxReconnectSupervisorIsRunning)
        await model.shutdown()
    }

    @MainActor
    @Test("reconnect rejects a different SSH route before probing")
    func reconnectRejectsDifferentSSHRouteBeforeProbing() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let currentRoute = Mutex("sha256:original-route")
        let probes = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
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
            presentationSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(
                    routeIdentity: currentRoute.withLock { $0 }
                )
            },
            tmuxReconnectIntervals: [.zero]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        probes.withLock { $0 = 0 }
        currentRoute.withLock { $0 = "sha256:replacement-route" }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            model.anyTmuxReconnectSupervisorIsRunning
        }
        await waitUntilMainActor {
            probes.withLock { $0 } > 0
                || !model.anyTmuxReconnectSupervisorIsRunning
        }

        #expect(probes.withLock { $0 } == 0)
        #expect(surfaceStore.requestCount == 1)
        #expect(!model.anyTmuxReconnectSupervisorIsRunning)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test("reconnect discards a probe when the SSH route changes during it")
    func reconnectRejectsRouteChangeDuringProbe() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let currentRoute = Mutex("sha256:original-route")
        let probedArguments = Mutex([[String]]())
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionValidationDiscovery: { _, arguments in
                probedArguments.withLock { $0.append(arguments) }
                currentRoute.withLock {
                    $0 = "sha256:replacement-route"
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "replacement-only",
                        windowCount: 1,
                        createdAt: nil,
                        managed: false
                    ),
                ])
            },
            presentationSSHConnectionProvider: { _, _ in
                let route = currentRoute.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: ["-F", "/tmp/\(route)-config"],
                    routeIdentity: route
                )
            },
            tmuxReconnectIntervals: [.zero]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor {
            probedArguments.withLock { !$0.isEmpty }
                && !model.anyTmuxReconnectSupervisorIsRunning
        }

        #expect(probedArguments.withLock { $0.count } == 1)
        #expect(
            probedArguments.withLock { $0.first }?
                .contains("/tmp/sha256:original-route-config") == true
        )
        #expect(
            model.snapshot.host(id: environment.remoteHost.id)?
                .tmuxSessions.contains(where: {
                    $0.name == "replacement-only"
                }) == false
        )
        #expect(surfaceStore.requestCount == 1)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
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
        await waitUntilMainActor { surfaceStore.requestCount >= 2 }

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
        await waitUntilMainActor(timeout: .seconds(5)) {
            model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(model.activeBorrowedTmuxSessionIsConnected)

        // A transient surface failure, then a successful reconnect.
        surfaceStore.surface.launchError = SceneSurfaceLaunchError.rejected
        surfaceStore.surface.launchFailureIsRetryable = true
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor { surfaceStore.requestCount >= 2 }
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
        let hiddenSizingMutations = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hiddenSizingMutations.withLock { $0 += 1 }
                }
                return (0, "")
            },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { host in
                if host.isRemote {
                    return .success([
                        DiscoveredTmuxSession(
                            name: "release-work",
                            windowCount: 1,
                            serverPID: "101",
                            sessionID: "$1",
                            createdAt: "1000",
                            previewClientSize: TmuxGridSize(
                                columns: 120,
                                rows: 37
                            ),
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
        await waitUntilMainActor { hiddenSizingMutations.load() == 1 }

        remoteClose(false, 255)

        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.retainedBorrowedTmuxSessionIsConnected(remote)
        }
        #expect(model.activeBorrowedTmuxSelection == local)
        #expect(model.retainedBorrowedTmuxHandle(for: remote) == remoteHandle)
        #expect(
            try #require(surfaceStore.lastConfiguration?.command)
                .contains("ignore-size")
        )

        model.openBorrowedTmuxSession(remote)
        model.prepareActiveBorrowedTmuxSurface()
        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(surfaceStore.requestCount == 3)
        await model.shutdown()
    }

    @MainActor
    @Test("named-socket hidden reconnect ignores default-server preview grid")
    func namedSocketHiddenReconnectIgnoresDefaultPreviewGrid() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        let remoteIndex = try #require(snapshot.hosts.firstIndex {
            $0.id == environment.remoteHost.id
        })
        snapshot.hosts[remoteIndex].tmuxSessions = [
            TmuxSessionSummary(
                name: "release-work",
                managed: false,
                windows: [],
                previewClientSize: TmuxGridSize(columns: 132, rows: 41)
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let hiddenSizingMutations = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hiddenSizingMutations.withLock { $0 += 1 }
                }
                return (0, "")
            },
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxExactSessionProbe: { _ in .success(true) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let remote = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work",
            socketName: "private-build"
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
                && hiddenSizingMutations.load() == 1
        }

        remoteClose(false, 255)

        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.retainedBorrowedTmuxSessionIsConnected(remote)
        }
        let reconnectCommand = try #require(
            surfaceStore.lastConfiguration?.command
        )
        #expect(reconnectCommand.contains("ignore-size"))
        #expect(!reconnectCommand.contains("stty columns 132 rows 41"))
        #expect(surfaceStore.surface.previewGridSizes.isEmpty)
        #expect(model.activeBorrowedTmuxSelection == local)
        await model.shutdown()
    }

    @MainActor
    @Test("disconnect during hidden sizing resumes through reconnect readiness")
    func disconnectDuringHiddenSizingResumesOnReconnect() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        let remoteIndex = try #require(snapshot.hosts.firstIndex {
            $0.id == environment.remoteHost.id
        })
        let previewGrid = TmuxGridSize(columns: 120, rows: 37)
        snapshot.hosts[remoteIndex].tmuxSessions = [
            TmuxSessionSummary(
                name: "release-work",
                managed: false,
                windows: [],
                serverPID: "101",
                sessionID: "$1",
                createdAt: "1000",
                previewClientSize: previewGrid
            ),
        ]
        let hideStarted = LockedValue(false)
        let hideFinished = LockedValue(false)
        let releaseHide = DispatchSemaphore(value: 0)
        let reconnectGate = BlockingGate()
        defer {
            releaseHide.signal()
            reconnectGate.release()
        }
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hideStarted.store(true)
                    _ = releaseHide.wait(timeout: .now() + 5)
                    hideFinished.store(true)
                }
                return (0, "")
            },
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionValidationDiscovery: { _, _ in
                reconnectGate.wait()
                return .success([
                    DiscoveredTmuxSession(
                        name: "release-work",
                        windowCount: 1,
                        serverPID: "101",
                        sessionID: "$1",
                        createdAt: "1000",
                        previewClientSize: previewGrid,
                        managed: false
                    ),
                ])
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
            return surfaceStore.requestCount == 2 && hideStarted.load()
        }

        remoteClose(false, 255)
        await waitUntilMainActor { reconnectGate.didStart }
        releaseHide.signal()
        await waitUntilMainActor { hideFinished.load() }
        try await Task.sleep(for: .milliseconds(25))

        #expect(model.retainedBorrowedTmuxHandle(for: remote) != nil)

        reconnectGate.release()
        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.retainedBorrowedTmuxSessionIsConnected(remote)
        }
        #expect(model.activeBorrowedTmuxSelection == local)
        #expect(
            model.retainedBorrowedTmuxHandle(for: remote) == remoteHandle
        )
        #expect(surfaceStore.surface.previewGridSizes == [previewGrid])
        #expect(
            try #require(surfaceStore.lastConfiguration?.command)
                .contains("ignore-size")
        )
        await model.shutdown()
    }

    @MainActor
    @Test("local disconnect during hidden sizing resumes on reconnect")
    func localDisconnectDuringHiddenSizingResumesOnReconnect() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let previewGrid = TmuxGridSize(columns: 120, rows: 37)
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "kwt-ghosthub-main",
                managed: true,
                windows: [],
                serverPID: "101",
                sessionID: "$1",
                createdAt: "1000",
                previewClientSize: previewGrid
            ),
        ]
        let hideStarted = LockedValue(false)
        let hideFinished = LockedValue(false)
        let releaseHide = DispatchSemaphore(value: 0)
        let reconnectGate = BlockingGate()
        let blocksDiscovery = LockedValue(false)
        defer {
            releaseHide.signal()
            reconnectGate.release()
        }
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                            + "\t101\t789\t321\t/dev/ttys001\t$1\t1000\t%9\n"
                    )
                }
                if command.contains("'ignore-size'"),
                   !command.contains("'!ignore-size'") {
                    hideStarted.store(true)
                    _ = releaseHide.wait(timeout: .now() + 5)
                    hideFinished.store(true)
                }
                return (0, "")
            },
            localKwtPathProvider: { "/test/kwt" },
            tmuxSessionDiscovery: { _ in
                if blocksDiscovery.load() {
                    reconnectGate.wait()
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "kwt-ghosthub-main",
                        windowCount: 1,
                        serverPID: "101",
                        sessionID: "$1",
                        createdAt: "1000",
                        previewClientSize: previewGrid,
                        managed: true
                    ),
                ])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let worktree = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "kwt-ghosthub-main",
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .direct
        )
        let other = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "other"
        )

        model.openBorrowedTmuxSession(worktree)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let worktreeHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: worktree)
        )
        let worktreeClose = try #require(
            surfaceStore.surface.closeObservers[worktreeHandle.id]
        )
        model.openBorrowedTmuxSession(other)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2 && hideStarted.load()
        }

        blocksDiscovery.store(true)
        worktreeClose(false, 255)
        await waitUntilMainActor(timeout: .seconds(2)) {
            reconnectGate.didStart
        }
        releaseHide.signal()
        await waitUntilMainActor { hideFinished.load() }
        try await Task.sleep(for: .milliseconds(25))

        let retainedHandle = model.retainedBorrowedTmuxHandle(for: worktree)
        #expect(retainedHandle != nil)

        reconnectGate.release()
        if retainedHandle != nil {
            await waitUntilMainActor {
                surfaceStore.requestCount == 3
                    && model.retainedBorrowedTmuxSessionIsConnected(worktree)
            }
            #expect(model.activeBorrowedTmuxSelection == other)
            #expect(
                model.retainedBorrowedTmuxHandle(for: worktree)
                    == worktreeHandle
            )
            #expect(surfaceStore.surface.previewGridSizes == [previewGrid])
            #expect(
                try #require(surfaceStore.lastConfiguration?.command)
                    .contains("ignore-size")
            )
        }
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
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 1
        }
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
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .direct
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
    @Test("missing kwt during workspace open falls back to direct attach")
    func missingKwtDuringWorkspaceOpenFallsBackToDirectAttach() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let sessionName = "kwt-ghosthub-main"
        let otherSessionName = "kwt-ghosthub-other"
        snapshot.worktrees[0].tmuxSessionName = sessionName
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: sessionName,
                managed: true,
                windows: []
            ),
            TmuxSessionSummary(
                name: otherSessionName,
                managed: true,
                windows: []
            ),
        ]
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let provisioningCalls = Counter()
        let discoveryCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtRemoteProvisioner: { _ in
                _ = provisioningCalls.increment()
            },
            tmuxSessionDiscovery: { _ in
                _ = discoveryCalls.increment()
                return .success([
                    DiscoveredTmuxSession(
                        name: sessionName,
                        windowCount: 1,
                        createdAt: nil,
                        managed: true
                    ),
                    DiscoveredTmuxSession(
                        name: otherSessionName,
                        windowCount: 1,
                        createdAt: nil,
                        managed: true
                    ),
                ])
            },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .direct
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        #expect(
            surfaceStore.lastConfiguration?.command?.contains("'open'")
                == true
        )
        await waitUntilMainActor { discoveryCalls.count >= 1 }

        surfaceStore.surface.closeObservers.values.first?(false, 127)
        await waitUntilMainActor {
            surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        let command = try #require(surfaceStore.lastConfiguration?.command)
        #expect(command.contains("'attach-session'"))
        #expect(!command.contains("'open'"))
        #expect(provisioningCalls.count == 0)

        let otherSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: otherSessionName,
            worktreePath: "/srv/ghosthub-other",
            tmuxAttachMode: .direct
        )
        model.openBorrowedTmuxSession(otherSelection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 3
        }
        let otherCommand = try #require(
            surfaceStore.lastConfiguration?.command
        )
        #expect(otherCommand.contains("'attach-session'"))
        #expect(!otherCommand.contains("'open'"))
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
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .direct
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
                && model.activeBorrowedTmuxSessionIsConnected
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
    @Test("superseded reconnect probes stay read-only and retry")
    func supersededReconnectProbesStayReadOnlyAndRetry() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        var snapshot = environment.snapshot
        let hostIndex = try #require(snapshot.hosts.firstIndex {
            $0.id == environment.remoteHost.id
        })
        snapshot.hosts[hostIndex].tmuxSessions = [
            TmuxSessionSummary(
                name: "release-work",
                managed: false,
                windows: [
                    TmuxWindowSummary(id: "0", index: 0, name: "editor"),
                    TmuxWindowSummary(id: "1", index: 1, name: "tests"),
                ]
            ),
        ]
        snapshot.hosts[hostIndex].tmuxInventoryIsAuthoritative = true
        let attempts = Counter()
        let reconnectGate = BlockingGate()
        let creationGate = BlockingGate()
        let retryGate = BlockingGate()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let discovered = [
            DiscoveredTmuxSession(
                name: "release-work",
                windowCount: 2,
                createdAt: nil,
                managed: false
            ),
            DiscoveredTmuxSession(
                name: "created-work",
                windowCount: 1,
                createdAt: nil,
                managed: false
            ),
        ]
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                switch attempts.increment() {
                case 1:
                    reconnectGate.wait()
                    return .success([])
                case 2:
                    creationGate.wait()
                    return .success(discovered)
                default:
                    retryGate.wait()
                    return .success(discovered)
                }
            },
            createdSessionDiscoveryDelays: [.zero],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        defer {
            reconnectGate.release()
            creationGate.release()
            retryGate.release()
        }

        let reconnectSelection = WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(reconnectSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        surfaceStore.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor { reconnectGate.didStart }

        model.createTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: environment.remoteHost.id,
            name: "created-work"
        ))
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { creationGate.didStart }

        reconnectGate.release()
        await waitUntilMainActor {
            guard let host = model.snapshot.host(
                id: environment.remoteHost.id
            ) else { return false }
            return attempts.count >= 3
                || !host.tmuxSessions.contains { $0.name == "release-work" }
        }

        let host = try #require(
            model.snapshot.host(id: environment.remoteHost.id)
        )
        #expect(attempts.count >= 3)
        #expect(
            host.tmuxSessions.first { $0.name == "release-work" }?
                .windows.count == 2
        )

        creationGate.release()
        retryGate.release()
        await model.shutdown()
    }

    @MainActor
    @Test("older creation result cannot invalidate newer reconnect")
    func olderCreationResultCannotInvalidateNewerReconnect() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let attempts = Counter()
        let creationGate = BlockingGate()
        let reconnectGate = BlockingGate()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: { _ in
                switch attempts.increment() {
                case 1:
                    creationGate.wait()
                case 2:
                    reconnectGate.wait()
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
        defer {
            creationGate.release()
            reconnectGate.release()
        }
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
        await waitUntilMainActor { reconnectGate.didStart }

        creationGate.release()
        reconnectGate.release()

        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(attempts.count == 2)
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
            tmuxSessionValidationExactProbe: { target, _ in
                switch attempts.increment() {
                case 1:
                    return await probe.probe(target)
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
        await waitUntilMainActor {
            model.activeBorrowedTmuxSessionIsConnected
        }
        surfaceStore.surface.closeObservers.values.first?(false, 255)

        await waitUntilMainActor {
            probe.didCancel
                && surfaceStore.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        // A slow scheduler can let the deadline cancel a second probe
        // before its instant success lands, so the retry count is a
        // lower bound rather than an exact value.
        #expect(attempts.count >= 2)
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
        var snapshot = environment.snapshot
        let hostIndex = try #require(snapshot.hosts.firstIndex {
            $0.id == environment.remoteHost.id
        })
        snapshot.hosts[hostIndex].tmuxSessions[0].windows = [
            TmuxWindowSummary(id: "0", index: 0, name: "editor"),
            TmuxWindowSummary(id: "1", index: 1, name: "tests"),
        ]
        snapshot.hosts[hostIndex].tmuxInventoryIsAuthoritative = true
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: snapshot,
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
        let host = try #require(
            model.snapshot.host(id: environment.remoteHost.id)
        )
        #expect(surfaceStore.requestCount == 1)
        #expect(host.tmuxInventoryIsAuthoritative)
        #expect(host.tmuxSessions.isEmpty)
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
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .direct
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
            tmuxSessionValidationDiscovery: { _, _ in
                discoveries.removeFirst()
            },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: sessionName,
            worktreeID: environment.worktree.id,
            worktreePath: environment.worktree.path,
            tmuxAttachMode: .direct
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
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected
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
    @Test("inactive protected reconnect publishes sidebar running state")
    func inactiveProtectedReconnectPublishesRunningState() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        let worktreeIndex = try #require(snapshot.worktrees.indices.first)
        snapshot.worktrees[worktreeIndex].tmuxSessionName =
            "kwt-ghosthub-pr-94"
        snapshot.worktrees[worktreeIndex].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[worktreeIndex].tmuxAttachMode = .protected
        let worktree = snapshot.worktrees[worktreeIndex]
        let protected = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let other = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "release-work"
        )
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport
                .previewPaneSplitter(identity: identity),
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxExactSessionProbe: { _ in .success(true) },
            tmuxReconnectIntervals: [.milliseconds(1)]
        )

        model.openBorrowedTmuxSession(protected)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor {
            model.connectedBorrowedTmuxSessionIDs.contains(protected.id)
        }
        let protectedHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: protected)
        )
        model.openBorrowedTmuxSession(other)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return surfaceStore.requestCount == 2
                && model.retainedBorrowedTmuxSessionIsConnected(other)
        }

        var updateCount = 0
        let updates = model.objectWillChange.sink { updateCount += 1 }
        let updatesBeforeDisconnect = updateCount
        surfaceStore.surface.closeObservers[protectedHandle.id]?(false, 255)

        #expect(updateCount > updatesBeforeDisconnect)
        #expect(!model.connectedBorrowedTmuxSessionIDs.contains(protected.id))
        let disconnectedRow = try #require(
            WorkspaceSidebarModel.sections(
                in: model.snapshot,
                connectedTmuxSessionIDs:
                model.connectedBorrowedTmuxSessionIDs
            ).flatMap(\.projects).flatMap(\.worktreeRows).first {
                $0.target == .worktree(environment.worktree.id)
            }
        )
        #expect(disconnectedRow.worktreeStatus?.isRunning == false)

        let updatesAfterDisconnect = updateCount
        await waitUntilMainActor {
            surfaceStore.requestCount == 3
                && model.connectedBorrowedTmuxSessionIDs
                .contains(protected.id)
                && updateCount > updatesAfterDisconnect
        }
        let reconnectedRow = try #require(
            WorkspaceSidebarModel.sections(
                in: model.snapshot,
                connectedTmuxSessionIDs:
                model.connectedBorrowedTmuxSessionIDs
            ).flatMap(\.projects).flatMap(\.worktreeRows).first {
                $0.target == .worktree(environment.worktree.id)
            }
        )
        #expect(reconnectedRow.worktreeStatus?.isRunning == true)
        #expect(model.activeBorrowedTmuxSelection == other)
        withExtendedLifetime(updates) {}
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

}
