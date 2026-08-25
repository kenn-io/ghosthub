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
    enum DelayedHerdrIntent: Sendable {
        case open
        case create
        case restart
    }

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
        let tmuxHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: tmux)
        )
        try await model.openBorrowedHerdrSession(herdr)
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.activeBorrowedHerdrSelection == herdr)
        #expect(model.retainedBorrowedTmuxHandle(for: tmux) == tmuxHandle)

        model.openBorrowedTmuxSession(tmux)
        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(model.activeBorrowedTmuxSelection == tmux)
        #expect(model.retainedBorrowedTmuxHandle(for: tmux) == tmuxHandle)
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
        model.isFocusedWindow = false
        #expect(model.performApplicationShortcut(
            .splitDown,
            invocation: .menu
        ))
        await waitUntilMainActor { commands.withLock(\.count) == 1 }

        let recordedCommand = commands.withLock { $0.first }
        let command = try #require(recordedCommand)
        #expect(command.contains("'--direction' 'down'"))
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

    @Test("repeated sibling shortcuts advance pending Herdr navigation")
    func repeatedSiblingShortcutsAdvancePendingHerdrNavigation() async throws {
        var environment = try environment()
        let third = HerdrSessionSummary(
            name: "zeta",
            isDefault: false,
            state: .running
        )
        environment.snapshot.hosts[0].herdrSessions.append(third)
        let model = try makeHerdrModel(
            environment,
            store: RecordingNativeSessionSurfaceStore()
        )
        let first = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(first)
        model.selection.select(
            .herdrSession(hostID: first.hostID, name: first.name),
            in: environment.snapshot
        )
        model.isFocusedWindow = true

        #expect(model.performApplicationShortcut(.nextSibling))
        #expect(model.performApplicationShortcut(.nextSibling))
        await waitUntilMainActor {
            model.activeBorrowedHerdrSelection != first
        }
        #expect(model.activeBorrowedHerdrSelection == .init(
            hostID: environment.hostID,
            name: third.name
        ))
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
        let releaseLocalProbe = AsyncGate()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { host in
                if host == .local {
                    localProbeStarted.withLock { $0 = true }
                    await releaseLocalProbe.wait()
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

        releaseLocalProbe.open()
        await delayedActivation.value

        #expect(model.activeBorrowedHerdrSelection == (
            intent == .anotherHerdrSession ? replacement : nil
        ))
        await model.shutdown()
    }

    @Test("automatic selection normalization preserves Herdr activation")
    func automaticSelectionPreservesHerdrActivation() async throws {
        var environment = try environment()
        let project = ProjectSummary.fixture(hostID: environment.hostID)
        environment.snapshot.projects.append(project)
        let store = RecordingNativeSessionSurfaceStore()
        let probeStarted = Mutex(false)
        let releaseProbe = AsyncGate()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                probeStarted.withLock { $0 = true }
                await releaseProbe.wait()
                return .available([
                    HerdrSessionSummary(
                        name: "api",
                        isDefault: true,
                        state: .running
                    ),
                ])
            }
        )
        model.selection = WorkspaceSelection(
            selectedHostID: environment.hostID,
            selectedProjectID: project.id
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )

        let activation = Task {
            try await model.openBorrowedHerdrSession(selection)
        }
        await waitUntilMainActor { probeStarted.withLock { $0 } }
        model.synchronizeSelection(WorkspaceSelection(
            selectedHostID: environment.hostID
        ))
        releaseProbe.open()
        try await activation.value

        #expect(model.activeBorrowedHerdrSelection == selection)
        await model.shutdown()
    }

    @Test(
        "scene shutdown fences delayed Herdr intents",
        arguments: [
            DelayedHerdrIntent.open,
            .create,
            .restart,
        ]
    )
    func shutdownFencesDelayedHerdrIntent(
        intent: DelayedHerdrIntent
    ) async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let name: String
        let result: HerdrDiscoveryResult
        switch intent {
        case .open:
            name = "api"
            result = .available([
                HerdrSessionSummary(
                    name: name,
                    isDefault: true,
                    state: .running
                ),
            ])
        case .create:
            name = "late"
            result = .available([])
        case .restart:
            name = "sleeping"
            let stopped = HerdrSessionSummary(
                name: name,
                isDefault: false,
                state: .stopped
            )
            environment.snapshot.hosts[0].herdrSessions.append(stopped)
            result = .available([stopped])
        }
        let gate = AsyncGate()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeHerdrModel(
            environment,
            store: RecordingNativeSessionSurfaceStore(),
            discovery: { _ in
                await gate.wait()
                return result
            },
            coordinator: coordinator
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: name
        )
        let operation = Task {
            switch intent {
            case .open:
                try await model.openBorrowedHerdrSession(selection)
            case .create:
                try await model.createHerdrSession(selection)
            case .restart:
                try await model.restartHerdrSession(selection)
            }
        }
        await gate.waitUntilWaiting()

        await model.shutdown()
        gate.open()
        _ = try? await operation.value

        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(coordinator.pendingKeys.isEmpty)
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
        let releaseProbe = AsyncGate()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                probeStarted.withLock { $0 = true }
                await releaseProbe.wait()
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
        releaseProbe.open()

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
        let releaseProbe = AsyncGate()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                probeStarted.withLock { $0 = true }
                await releaseProbe.wait()
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
        releaseProbe.open()

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

    @Test("restart replaces a stale attach-only presentation")
    func restartReplacesStaleAttachOnlyPresentation() async throws {
        var environment = try environment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let stopped = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .stopped
        )
        let discoveries = HerdrDiscoveryQueue([
            .available([running]),
            .available([stopped]),
            .available([stopped]),
            .available([running]),
        ])
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() },
            coordinator: coordinator,
            createdSessionDiscoveryDelays: []
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )

        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        model.startHerdrSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: environment.hostID)?
                .herdrSessions.first?.state == .stopped
        }

        try await model.restartHerdrSession(selection)
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return store.requestedConfigurations.count == 2
        }

        #expect(store.requestedConfigurations.count == 2)
        #expect(store.requestedConfigurations.last?.command?.contains(
            "--session"
        ) == false)
        await model.shutdown()
    }

    @Test("constructive confirmation uses the attachment lease route")
    func constructiveConfirmationUsesAttachmentLease() async throws {
        var environment = try remoteEnvironment()
        environment.snapshot.hosts[0].herdrAvailable = true
        environment.snapshot.hosts[0].herdrSessions = [
            HerdrSessionSummary(
                name: "api",
                isDefault: true,
                state: .stopped
            ),
        ]
        let snapshot = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config", "dev@build.example.test",
        ])
        let leaseArguments = [
            "-F", "/tmp/lease-config", "dev@build.example.test",
        ]
        let received = Mutex<(CommandHost, [String])?>(nil)
        let displayedSessions = environment.snapshot.hosts[0].herdrSessions
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                .available(displayedSessions)
            },
            exactProbe: { _, host, arguments in
                received.withLock { $0 = (host, arguments) }
                return .present
            },
            sshConnectionSnapshotProvider: { _ in snapshot },
            presentationSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(arguments: leaseArguments)
            },
            coordinator: coordinator,
            createdSessionDiscoveryDelays: []
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )

        try await model.restartHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        await waitUntilMainActor { !coordinator.isPending(key) }

        let route = try #require(received.withLock { $0 })
        #expect(route.0 == CommandHostResolver.resolve(
            environment.snapshot.hosts[0]
        ))
        #expect(route.1 == leaseArguments)
        #expect(store.requestedConfigurations.last?.command?.contains(
            "--session"
        ) == false)
        await model.shutdown()
    }

    @Test("demo presentation accepts its validated route")
    func demoPresentationUsesCanonicalRoute() async throws {
        var environment = try remoteEnvironment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let running = try #require(
            environment.snapshot.hosts[0].herdrSessions.first
        )
        let scratch = "/tmp/ghosthub-demo"
        let demoEnvironment = [
            "GHOSTHUB_DEMO_SCRATCH": scratch,
            "GHOSTHUB_DEMO_SSH_DIR": "\(scratch)/ssh",
        ]
        let acquisitions = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in .available([running]) },
            sshConnectionSnapshotProvider: { info in
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
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: running.name
        )

        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)

        #expect(acquisitions.load() == 0)
        #expect(store.requestedConfigurations.last?.command?.contains(
            "\(scratch)/ssh/config"
        ) == true)
        await model.shutdown()
    }

    @Test("reopening an active remote session preserves its lease")
    func reopeningActiveRemoteSessionPreservesLease() async throws {
        var environment = try remoteEnvironment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let running = try #require(
            environment.snapshot.hosts[0].herdrSessions.first
        )
        let validation = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/validation-config", "dev@build.example.test",
        ])
        let leaseArguments = [
            "-F", "/tmp/lease-config", "dev@build.example.test",
        ]
        let acquisitionCount = LockedValue(0)
        let releaseCount = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in .available([running]) },
            sshConnectionSnapshotProvider: { _ in validation },
            presentationSSHConnectionProvider: { _, _ in
                acquisitionCount.withLock { $0 += 1 }
                return testKwtSSHAttachment(
                    arguments: leaseArguments,
                    release: {
                        releaseCount.withLock { $0 += 1 }
                    }
                )
            }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: running.name
        )

        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)

        try await model.openBorrowedHerdrSession(selection)
        model.prepareActiveBorrowedHerdrSurface()

        #expect(model.activeBorrowedHerdrSelection == selection)
        #expect(acquisitionCount.load() == 1)
        #expect(releaseCount.load() == 0)
        await model.shutdown()
        #expect(releaseCount.load() == 1)
    }

    @Test("opening rejects SSH route drift during validation")
    func openRejectsRouteDriftDuringValidation() async throws {
        var environment = try remoteEnvironment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let running = try #require(
            environment.snapshot.hosts[0].herdrSessions.first
        )
        let frozen = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/frozen-config"],
            routeIdentity: "sha256:original-route",
            generation: 1
        ))
        let changed = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/changed-config"],
            routeIdentity: "sha256:replacement-route",
            generation: 2
        ))
        let currentRoute = LockedValue(frozen)
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in
                currentRoute.store(changed)
                return .available([running])
            },
            sshConnectionSnapshotProvider: { _ in currentRoute.load() }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: running.name
        )

        await #expect(throws: HerdrSessionPresentationError.self) {
            try await model.openBorrowedHerdrSession(selection)
        }

        #expect(store.requestedConfigurations.isEmpty)
        await model.shutdown()
    }

    @Test("constructive launch rejects kwt lease route drift")
    func constructiveLaunchRejectsLeaseRouteDrift() async throws {
        var environment = try remoteEnvironment()
        environment.snapshot.hosts[0].herdrAvailable = true
        let stopped = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .stopped
        )
        environment.snapshot.hosts[0].herdrSessions = [stopped]
        let frozen = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config", "dev@build.example.test",
        ])
        let coordinator = HerdrSessionLifecycleCoordinator()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in .available([stopped]) },
            sshConnectionSnapshotProvider: { _ in frozen },
            presentationSSHConnectionProvider: { _, _ in
                throw KwtSSHLeaseError.routeChanged
            },
            coordinator: coordinator,
            createdSessionDiscoveryDelays: []
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )

        try await model.restartHerdrSession(selection)
        await waitUntilMainActor { !coordinator.isPending(key) }

        #expect(!coordinator.isPending(key))
        #expect(store.requestedConfigurations.isEmpty)
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
        "constructive retry attaches when the target is already running",
        arguments: [
            HerdrSessionLifecycleCoordinator.OperationKind.create,
            .restart,
        ]
    )
    func constructiveRetryAttachesRunningSession(
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
        let running = HerdrSessionSummary(
            name: sessionName,
            isDefault: false,
            state: .running
        )
        let discoveries = HerdrDiscoveryQueue([
            desiredState,
            .available([running]),
        ])
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
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return store.requestedConfigurations.count
                == configurationCount + 1
        }

        #expect(discoveries.callCount == 2)
        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("'session'"))
        #expect(command.contains("'attach'"))
        #expect(!command.contains("--session"))
        #expect(!coordinator.isPending(key))
        await model.shutdown()
    }

    @Test(
        "invalid constructive retry state is visible and retires the intent",
        arguments: [
            HerdrSessionLifecycleCoordinator.OperationKind.create,
            .restart,
        ]
    )
    func constructiveRetryRetiresInvalidState(
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
        let invalidState: HerdrDiscoveryResult = kind == .create
            ? .available([stopped])
            : .available([])
        let discoveries = HerdrDiscoveryQueue([
            desiredState,
            invalidState,
            desiredState,
        ])
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

        let expectedError: HerdrSessionPresentationError = kind == .create
            ? .sessionExists(sessionName)
            : .sessionMissing(sessionName)
        #expect(
            model.activeBorrowedHerdrConnectionState
                == .disconnected(reason: expectedError.localizedDescription)
        )

        await model.retryBorrowedHerdrSession(selection)

        #expect(discoveries.callCount == 3)
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

    @Test("confirmed Herdr stop suppresses delayed surface recovery")
    func confirmedStopSuppressesDelayedSurfaceRecovery() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let probes = Mutex(0)
        let model = try makeHerdrModel(
            environment,
            store: store,
            exactProbe: { _, _, _ in
                probes.withLock { $0 += 1 }
                return .present
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
        let probeCountBeforeStop = probes.withLock { $0 }

        let operation = try #require(coordinator.begin(.stop, key: key))
        coordinator.willStop(operation)
        store.surface.launchError = HerdrSurfaceLaunchTestError.rejected
        store.surface.launchFailureIsRetryable = true

        model.prepareActiveBorrowedHerdrSurface()
        try await Task.sleep(for: .milliseconds(100))

        #expect(probes.withLock { $0 } == probeCountBeforeStop)
        #expect(!model.herdrReconnectSupervisorIsRunning)
        coordinator.finish(operation, outcome: .succeeded)
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

    @Test("manual retry preserves its exact remote SSH route")
    func manualRetryUsesFrozenRoute() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let connection = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config", "dev@build.example.test",
        ])
        let leaseArguments = [
            "-F", "/tmp/reacquired-config", "dev@build.example.test",
        ]
        let probedArguments = Mutex<[String]?>(nil)
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in .available([running]) },
            exactProbe: { _, _, arguments in
                probedArguments.withLock { $0 = arguments }
                return .present
            },
            sshConnectionSnapshotProvider: { _ in connection },
            presentationSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(arguments: leaseArguments)
            }
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
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return store.requestedConfigurations.count == 2
        }

        #expect(probedArguments.withLock { $0 } == connection.arguments)
        #expect(store.requestedConfigurations.last?.command?.contains(
            "/tmp/reacquired-config"
        ) == true)
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

        await waitUntilMainActor {
            model.snapshot.host(id: environment.hostID)?
                .herdrSessions.contains(where: { $0.name == "api" }) == false
        }
        #expect(discoveries.callCount == 3)
        #expect(model.snapshot.host(id: environment.hostID)?
            .herdrSessions.contains(where: { $0.name == "api" }) == false)
        await model.shutdown()
    }

    @Test("remote transport loss probes the exact session before relaunch")
    func remoteTransportRecovery() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let connection = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config", "dev@build.example.test",
        ])
        let leaseArguments = [
            "-F", "/tmp/reacquired-config", "dev@build.example.test",
        ]
        let probedConnectionArguments = Mutex<[String]?>(nil)
        let discoveries = HerdrDiscoveryQueue([
            .available([
                HerdrSessionSummary(name: "api", isDefault: true, state: .running),
            ]),
        ])
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in discoveries.removeFirst() },
            exactProbe: { _, _, arguments in
                probedConnectionArguments.withLock { $0 = arguments }
                return .present
            },
            sshConnectionSnapshotProvider: { _ in connection },
            presentationSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(arguments: leaseArguments)
            }
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

        #expect(discoveries.callCount == 1)
        #expect(probedConnectionArguments.withLock { $0 } == connection.arguments)
        #expect(store.requestedConfigurations.last?.command?.contains(
            "/tmp/reacquired-config"
        ) == true)
        #expect(model.activeBorrowedHerdrSelection == herdr)
        await model.shutdown()
    }

    @Test("reconnect accepts same-route lease rollover during validation")
    func reconnectAcceptsSameRouteLeaseRollover() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let original = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/original-herdr-config"],
            routeIdentity: "sha256:stable-route",
            generation: 1
        ))
        let probing = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/probing-herdr-config"],
            routeIdentity: "sha256:stable-route",
            generation: 2
        ))
        let rolledOver = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/rolled-over-herdr-config"],
            routeIdentity: "sha256:stable-route",
            generation: 3
        ))
        let current = Mutex(original)
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in .available([running]) },
            exactProbe: { _, _, _ in
                current.withLock { $0 = rolledOver }
                return .present
            },
            sshConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
            },
            presentationSSHConnectionProvider: { _, _ in
                let connection = current.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )

        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
        current.withLock { $0 = probing }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)

        await waitUntilMainActor(timeout: .seconds(1)) {
            store.requestedConfigurations.count == 2
                && model.activeBorrowedHerdrConnectionState == .connected
        }

        #expect(store.requestedConfigurations.last?.command?.contains(
            "/tmp/rolled-over-herdr-config"
        ) == true)
        await model.shutdown()
    }

    @Test("dead Herdr reconnect lease is invalidated before retry")
    func deadHerdrReconnectLeaseIsInvalidatedBeforeRetry() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let original = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/original-herdr-config"],
            routeIdentity: "sha256:stable-route",
            generation: 1
        ))
        let replacement = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/replacement-herdr-config"],
            routeIdentity: "sha256:stable-route",
            generation: 3
        ))
        let current = Mutex(original)
        let invalidations = Mutex(0)
        let deadAttempts = Mutex(0)
        let deadConnection = testKwtSSHAttachment(
            arguments: ["-F", "/tmp/dead-herdr-config"],
            routeIdentity: "sha256:stable-route",
            generation: 2,
            invalidate: {
                invalidations.withLock { $0 += 1 }
                current.withLock { $0 = replacement }
            }
        )
        let dead = SSHConnectionArgumentsSnapshot(deadConnection)
        let model = try makeHerdrModel(
            environment,
            store: store,
            exactProbe: { _, _, arguments in
                guard arguments == dead.arguments else { return .present }
                deadAttempts.withLock { $0 += 1 }
                return .failure(.commandFailed(
                    status: 255,
                    stderr: "Control socket connect(/tmp/dead): No such file or directory"
                ))
            },
            sshConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
            },
            presentationSSHConnectionProvider: { _, _ in
                let connection = current.withLock { $0 }
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )

        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)
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
                && model.activeBorrowedHerdrConnectionState == .connected
        }

        #expect(deadAttempts.withLock { $0 } == 1)
        #expect(store.requestedConfigurations.last?.command?.contains(
            "/tmp/replacement-herdr-config"
        ) == true)
        await model.shutdown()
        withExtendedLifetime(deadConnection) {}
    }

    @Test("SSH acquisition failure ends a Herdr reconnect handoff")
    func sshAcquisitionFailureEndsHerdrReconnect() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let acquisitions = Mutex(0)
        let model = try makeHerdrModel(
            environment,
            store: store,
            exactProbe: { _, _, _ in .present },
            presentationSSHConnectionProvider: { _, _ in
                let attempt = acquisitions.withLock {
                    $0 += 1
                    return $0
                }
                guard attempt == 1 else {
                    throw KwtSSHLeaseError.helperUnavailable
                }
                return testKwtSSHAttachment()
            }
        )
        let selection = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(selection)
        await launchHerdrSurface(model, store: store)

        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor {
            acquisitions.withLock { $0 } == 2
                && model.activeBorrowedHerdrRecoveryState == nil
        }

        #expect(store.requestedKeys.count == 1)
        #expect(!model.herdrReconnectSupervisorIsRunning)
        guard case .disconnected = model.activeBorrowedHerdrConnectionState
        else {
            Issue.record("Expected the failed relaunch to disconnect")
            await model.shutdown()
            return
        }
        await model.shutdown()
    }

    @Test("retryable Herdr surface failure keeps recovering instead of latching")
    func retryableHerdrSurfaceFailureKeepsRecovering() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(
            environment,
            store: store,
            exactProbe: { _, _, _ in .present }
        )
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)

        // Displays vanished between the gate and surface creation. Recovery
        // must re-arm each time rather than latching after the first failure,
        // so attempts keep accumulating.
        store.surface.launchError = HerdrSurfaceLaunchTestError.rejected
        store.surface.launchFailureIsRetryable = true
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor(timeout: .seconds(5)) {
            store.requestedKeys.count >= 3
        }

        store.surface.launchError = nil
        store.surface.launchFailureIsRetryable = false
        await waitUntilMainActor(timeout: .seconds(5)) {
            model.activeBorrowedHerdrSelection == herdr
                && !model.herdrReconnectSupervisorIsRunning
        }

        #expect(model.activeBorrowedHerdrSelection == herdr)
        await model.shutdown()
    }

    @Test("recovered Herdr surface failure does not excuse a later exit")
    func recoveredHerdrSurfaceFailureDoesNotExcuseLaterExit() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeHerdrModel(
            environment,
            store: store,
            exactProbe: { _, _, _ in .present }
        )
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)

        // A transient surface failure, then a successful reconnect.
        store.surface.launchError = HerdrSurfaceLaunchTestError.rejected
        store.surface.launchFailureIsRetryable = true
        store.surface.closeObservers.values.first?(false, 255)
        await waitUntilMainActor(timeout: .seconds(5)) {
            store.requestedKeys.count >= 2
        }
        store.surface.launchError = nil
        store.surface.launchFailureIsRetryable = false
        await waitUntilMainActor(timeout: .seconds(5)) {
            !model.herdrReconnectSupervisorIsRunning
                && model.activeBorrowedHerdrSelection == herdr
        }
        let recoveredCount = store.requestedKeys.count

        // A normal client exit is not a transport failure and must not inherit
        // the earlier transient failure's licence to retry.
        store.surface.closeObservers.values.first?(false, 0)
        try await Task.sleep(for: .milliseconds(150))

        #expect(store.requestedKeys.count == recoveredCount)
        #expect(!model.herdrReconnectSupervisorIsRunning)
        await model.shutdown()
    }

    @Test("no active display holds Herdr recovery without probing the host")
    func zeroDisplaysHoldsHerdrRecovery() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let probes = Mutex(0)
        let displays = Mutex(1)
        let model = try makeHerdrModel(
            environment,
            store: store,
            exactProbe: { _, _, _ in
                probes.withLock { $0 += 1 }
                return .present
            },
            activeDisplayCount: { displays.withLock { $0 } }
        )
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )
        try await model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)
        probes.withLock { $0 = 0 }

        displays.withLock { $0 = 0 }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor { model.herdrReconnectSupervisorIsRunning }
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.requestedKeys.count == 1)
        #expect(probes.withLock { $0 } == 0)
        #expect(model.herdrReconnectSupervisorIsRunning)

        displays.withLock { $0 = 1 }
        model.handleDisplayParametersChanged()
        await waitUntilMainActor { store.requestedKeys.count == 2 }

        #expect(model.activeBorrowedHerdrSelection == herdr)
        await model.shutdown()
    }

    @Test("reconnect rejects SSH route drift after its exact probe")
    func remoteTransportRecoveryRejectsRouteDrift() async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let frozen = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/frozen-config"],
            routeIdentity: "sha256:original-route",
            generation: 1
        ))
        let changed = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/changed-config"],
            routeIdentity: "sha256:replacement-route",
            generation: 2
        ))
        let currentConnection = LockedValue(frozen)
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in .available([running]) },
            exactProbe: { _, _, _ in
                currentConnection.store(changed)
                return .present
            },
            sshConnectionSnapshotProvider: { _ in currentConnection.load() },
            presentationSSHConnectionProvider: { _, _ in
                let connection = currentConnection.load()
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            }
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
            if case let .disconnected(reason) = model
                .activeBorrowedHerdrConnectionState {
                return reason?.contains("SSH connection changed") == true
            }
            return false
        }

        #expect(store.requestedKeys.count == 1)
        await model.shutdown()
    }

    @Test("reconnect rejects a different SSH route before probing")
    func remoteTransportRecoveryRejectsDifferentRouteBeforeProbe()
        async throws {
        let environment = try remoteEnvironment()
        let store = RecordingNativeSessionSurfaceStore()
        let original = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/original-herdr-config"],
            routeIdentity: "sha256:original-route",
            generation: 1
        ))
        let replacement = SSHConnectionArgumentsSnapshot(testKwtSSHAttachment(
            arguments: ["-F", "/tmp/replacement-herdr-config"],
            routeIdentity: "sha256:replacement-route",
            generation: 2
        ))
        let currentConnection = LockedValue(original)
        let probes = LockedValue(0)
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let model = try makeHerdrModel(
            environment,
            store: store,
            discovery: { _ in .available([running]) },
            exactProbe: { _, _, _ in
                probes.withLock { $0 += 1 }
                return .present
            },
            sshConnectionSnapshotProvider: { _ in
                currentConnection.load()
            },
            presentationSSHConnectionProvider: { _, _ in
                let connection = currentConnection.load()
                return testKwtSSHAttachment(
                    arguments: connection.arguments,
                    routeIdentity: connection.routeIdentity ?? "",
                    generation: connection.generation ?? 0
                )
            }
        )
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: environment.hostID,
            name: "api"
        )

        try await model.openBorrowedHerdrSession(herdr)
        await launchHerdrSurface(model, store: store)
        probes.store(0)
        currentConnection.store(replacement)

        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        let changedConnectionReason =
            "The SSH connection changed while Ghosthub was checking the Herdr session. Reopen it to use the current connection."
        await waitUntilMainActor {
            probes.load() > 0
                || model.activeBorrowedHerdrConnectionState
                == .disconnected(reason: changedConnectionReason)
        }

        #expect(probes.load() == 0)
        #expect(store.requestedKeys.count == 1)
        #expect(
            model.activeBorrowedHerdrConnectionState
                == .disconnected(reason: changedConnectionReason)
        )
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
            guard discoveries.callCount == 4,
                  let host = model.snapshot.host(id: environment.hostID)
            else { return false }
            switch result {
            case .available:
                return !host.herdrSessions.contains { $0.name == "api" }
            case .unavailable:
                return !host.herdrAvailable
            case .failure:
                return false
            }
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
        exactProbe: WorkspaceSceneModel.HerdrSessionExactProbe? = nil,
        sshConnectionSnapshotProvider:
        @escaping WorkspaceSceneModel.SSHConnectionSnapshotProvider = {
            _ in SSHConnectionArgumentsSnapshot(arguments: [])
        },
        presentationSSHConnectionProvider:
        @MainActor @escaping @Sendable (UUID, SSHHostInfo) async throws
            -> KwtSSHConnection = { _, _ in
                testKwtSSHAttachment()
            },
        presentationSSHEnvironment: [String: String] = [:],
        coordinator: HerdrSessionLifecycleCoordinator =
            HerdrSessionLifecycleCoordinator(),
        nativeHerdrPathProvider: @escaping @Sendable (CommandHost)
            -> Result<String, HerdrCommandError> = {
                _ in .success("/usr/bin/herdr")
            },
        paneSplitCapabilityProvider: @escaping NativeHerdrSessionCoordinator
            .PaneSplitCapabilityProvider = { _, _, _, _ in .success(nil) },
        paneSplitter: HerdrPaneSplitter = HerdrPaneSplitter(),
        activeDisplayCount: @escaping @Sendable () -> Int = { 1 },
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
            activeDisplayCount: activeDisplayCount,
            herdrLifecycleCoordinator: coordinator,
            herdrSSHConnectionSnapshotProvider:
            sshConnectionSnapshotProvider,
            herdrSessionDiscovery: discovery ?? { _ in
                .available(displayedSessions)
            },
            presentationSSHConnectionProvider:
            presentationSSHConnectionProvider,
            presentationSSHEnvironment: presentationSSHEnvironment,
            herdrSessionExactProbe: exactProbe,
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

private enum HerdrSurfaceLaunchTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Surface launch rejected" }
}
