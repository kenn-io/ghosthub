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

struct ZellijValidationFailureCase:
    Sendable, CustomTestStringConvertible {
    var name: String
    var result: ZellijDiscoveryResult
    var reason: String

    var testDescription: String { name }
}

struct ZellijPendingDiscoveryFailureCase:
    Sendable, CustomTestStringConvertible {
    var name: String
    var result: ZellijDiscoveryResult

    var testDescription: String { name }
}

struct ZellijTerminalReconnectFailureCase:
    Sendable, CustomTestStringConvertible {
    var name: String
    var result: ZellijDiscoveryResult
    var reason: String

    var testDescription: String { name }
}

struct ZellijKillValidationFailureCase:
    Sendable, CustomTestStringConvertible {
    var name: String
    var result: ZellijDiscoveryResult
    var expectsUnavailable: Bool

    var testDescription: String { name }
}

private final class CancellableZellijDiscoveryProbe: @unchecked Sendable {
    private struct State {
        var calls = 0
        var cancelled = false
        var released = false
    }

    private let blockingCall: Int
    private let state = Mutex(State())

    init(blockingCall: Int) {
        self.blockingCall = blockingCall
    }

    func discover(_: CommandHost) -> ZellijDiscoveryResult {
        let call = state.withLock {
            $0.calls += 1
            return $0.calls
        }
        guard call == blockingCall else {
            return .available(call > blockingCall ? ["replacement"] : [])
        }
        while !state.withLock({ $0.released }) {
            if Task.isCancelled {
                state.withLock { $0.cancelled = true }
                return .failure(.commandFailed(
                    status: -1,
                    stderr: "cancelled"
                ))
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return .available([])
    }

    var calls: Int { state.withLock { $0.calls } }
    var didCancel: Bool { state.withLock { $0.cancelled } }

    func release() {
        state.withLock { $0.released = true }
    }
}

@Suite("Workspace Zellij support", .serialized)
@MainActor
struct WorkspaceZellijTests {
    @Test("application activation does not refresh Zellij inventory")
    func applicationActivationDoesNotRefreshZellijInventory() async throws {
        let environment = try zellijEnvironment(sessions: [])
        let discoveries = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            zellijSessionDiscovery: { _ in
                discoveries.withLock { $0 += 1 }
                return .available([])
            }
        )
        model.startZellijSessionDiscovery()
        await waitUntilMainActor { discoveries.withLock { $0 } == 1 }

        model.handleApplicationDidBecomeActiveForResourceMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        #expect(discoveries.withLock { $0 } == 1)
        await model.shutdown()
    }

    @Test("explicit refresh cancels the superseded Zellij probe")
    func refreshCancelsSupersededDiscovery() async throws {
        let environment = try zellijEnvironment(sessions: [])
        let discovery = CancellableZellijDiscoveryProbe(blockingCall: 1)
        defer { discovery.release() }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            zellijSessionDiscovery: discovery.discover
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor { discovery.calls == 1 }
        model.refreshWorkspaceInventory()
        await waitUntilMainActor {
            discovery.didCancel
                && discovery.calls == 2
                && model.snapshot.host(id: environment.host.id)?
                .zellijSessions.map(\.name) == ["replacement"]
        }

        #expect(discovery.didCancel)
        await model.shutdown()
    }

    @Test("shutdown cancels detached Zellij creation retry discovery")
    func shutdownCancelsCreationRetryDiscovery() async throws {
        let environment = try zellijEnvironment(sessions: [])
        let discovery = CancellableZellijDiscoveryProbe(blockingCall: 3)
        defer { discovery.release() }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: RecordingNativeSessionSurfaceStore(),
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: discovery.discover,
            zellijSessionValidationDiscovery: { _, _ in .available([]) },
            createdSessionDiscoveryDelays: [.zero]
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release"
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor { discovery.calls == 1 }
        try await model.createZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            discovery.calls == 3
        }

        await model.shutdown()
        await waitUntilMainActor { discovery.didCancel }

        #expect(discovery.didCancel)
    }

    @Test("multi-host discovery publishes one completed Zellij inventory")
    func multiHostDiscoveryPublishesOnce() async throws {
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let remote = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder"
        )
        let model = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local, remote],
                projects: [],
                worktrees: []
            ),
            zellijSessionDiscovery: { host in
                .available([host.displayName])
            }
        )
        let publications = Mutex<[WorkspaceSnapshot]>([])
        let updates = model.$snapshot.dropFirst().sink { snapshot in
            guard snapshot.hosts.contains(where: {
                !$0.zellijSessions.isEmpty
            }) else { return }
            publications.withLock { $0.append(snapshot) }
        }

        model.startZellijSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts.allSatisfy {
                $0.zellijSessions.count == 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(publications.withLock { $0.count } == 1)
        #expect(publications.withLock { snapshots in
            snapshots.first?.hosts.allSatisfy {
                $0.zellijSessions.count == 1
            } == true
        })
        withExtendedLifetime(updates) {}
        await model.shutdown()
    }

    @Test("discovery probes local and POSIX hosts but excludes Windows")
    func supportedDiscoveryHosts() async throws {
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let linux = HostSummary(
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
        let hosts = Mutex(Set<CommandHost>())
        let database = try WorkspaceDatabase.inMemory()
        let model = try makeModel(
            database: database,
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local, linux, windows],
                projects: [],
                worktrees: []
            ),
            zellijSessionDiscovery: { host in
                _ = hosts.withLock { $0.insert(host) }
                return .available([host.displayName])
            }
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: local.id)?.zellijSessions.count == 1
                && model.snapshot.host(id: linux.id)?.zellijSessions.count == 1
        }

        #expect(hosts.withLock { $0 } == Set([
            CommandHost.local,
            CommandHost.ssh(SSHHostInfo(
                user: "dev",
                hostname: "builder",
                port: nil
            )),
        ]))
        #expect(model.snapshot.host(id: local.id)?.zellijAvailable == true)
        #expect(model.snapshot.host(id: windows.id)?.zellijAvailable == false)
        await model.shutdown()
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
        let releaseProbe = DispatchSemaphore(value: 0)
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
                releaseProbe.wait()
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
        releaseProbe.signal()
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
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.activeBorrowedZellijRecoveryState?.isReconnecting == true
                && results.withLock { $0.count } == 1
        }
        try await Task.sleep(for: .milliseconds(20))

        model.reconnectActiveZellijSessionNow()

        await waitUntilMainActor(timeout: .seconds(1)) {
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

    @Test("validated remote attachment uses one frozen SSH route")
    func attachmentUsesValidatedSSHRoute() async throws {
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
            zellijSSHConnectionSnapshotProvider: { _ in frozen }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        model.openBorrowedZellijSession(selection)
        await waitUntilMainActor { store.lastCommand != nil }

        #expect(validations.withLock { $0 } == [frozen.arguments])
        #expect(store.lastCommand?.contains("/tmp/frozen-zellij-config") == true)
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
        let releaseConfirmation = DispatchSemaphore(value: 0)
        defer { releaseConfirmation.signal() }
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
                    releaseConfirmation.wait()
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

        releaseConfirmation.signal()
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
        let releaseLocal = DispatchSemaphore(value: 0)
        let releaseRemote = DispatchSemaphore(value: 0)
        defer {
            releaseLocal.signal()
            releaseRemote.signal()
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
                        releaseLocal.wait()
                    case .ssh:
                        releaseRemote.wait()
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
        releaseLocal.signal()
        try await Task.sleep(for: .milliseconds(100))

        #expect(probes.withLock { $0[localHost] } == 1)
        #expect(probes.withLock { $0[remoteHost] } == 1)

        releaseRemote.signal()
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
        let releaseInitialLocal = DispatchSemaphore(value: 0)
        let releaseInitialRemote = DispatchSemaphore(value: 0)
        let releaseRetryLocal = DispatchSemaphore(value: 0)
        let releaseManualRemote = DispatchSemaphore(value: 0)
        let retryTimedOut = Mutex(false)
        defer {
            releaseInitialLocal.signal()
            releaseInitialRemote.signal()
            releaseRetryLocal.signal()
            releaseManualRemote.signal()
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
                        releaseInitialRemote.wait()
                    } else {
                        releaseInitialLocal.wait()
                    }
                } else if !isRemote, attempt == 3 {
                    if releaseRetryLocal.wait(
                        timeout: .now() + .seconds(1)
                    ) == .timedOut {
                        retryTimedOut.withLock { $0 = true }
                    }
                } else if isRemote, attempt == 3 {
                    releaseManualRemote.wait()
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
        releaseInitialLocal.signal()
        releaseInitialRemote.signal()
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
        releaseRetryLocal.signal()
        releaseManualRemote.signal()
        await waitUntilMainActor {
            model.snapshot.host(id: remote.id)?.zellijSessions.map(\.name)
                == ["new"]
        }

        #expect(model.snapshot.host(id: remote.id)?
            .zellijSessions.map(\.name) == ["new"])
        await model.shutdown()
    }

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
        let releaseFirstProbe = DispatchSemaphore(value: 0)
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
                    releaseFirstProbe.wait()
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

        releaseFirstProbe.signal()
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
                        Thread.sleep(forTimeInterval: 0.001)
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
                        Thread.sleep(forTimeInterval: 0.001)
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
        let currentConnection = SSHConnectionArgumentsSnapshot(arguments: [
            "-p", "2222",
        ])
        let staleConnection = SSHConnectionArgumentsSnapshot(arguments: [
            "-p", "2200",
        ])
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
            zellijSSHConnectionSnapshotProvider: { _ in currentConnection }
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
        killCoordinator.finish(operation, outcome: .failed)
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
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return .available(["api"])
            },
            zellijSSHConnectionSnapshotProvider: { _ in
                connectionState.withLock { $0.blocked = true }
                while !connectionState.withLock({ $0.released }) {
                    Thread.sleep(forTimeInterval: 0.001)
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

    @Test("reconnect rejects SSH route drift before probing")
    func reconnectRejectsSSHRouteDrift() async throws {
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
            zellijSessionValidationDiscovery: { _, _ in .available(["api"]) },
            zellijSSHConnectionSnapshotProvider: { _ in
                current.withLock { $0 }
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
        current.withLock { $0 = changed }
        let close = try #require(store.surface.closeObservers.values.first)
        close(false, 255)
        await waitUntilMainActor(timeout: .seconds(1)) {
            model.activeBorrowedZellijConnectionState == .disconnected(
                reason: "The SSH connection changed while Ghosthub was checking the Zellij session. Reopen it to use the current connection."
            )
        }

        #expect(store.requestedConfigurations.count == 1)
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
        let frozen = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config",
        ])
        let changed = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/changed-config",
        ])
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

    @Test("an immediate creation transport exit keeps its frozen SSH route")
    func immediateCreationExitKeepsSSHRoute() async throws {
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

        #expect(store.lastCommand?.contains("/tmp/frozen-zellij-config") == true)
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
        let frozen = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config",
        ])
        let changed = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/changed-config",
        ])
        let current = Mutex(frozen)
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
                current.withLock { $0 }
            }
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        let request = try await model.prepareZellijSessionKill(selection)
        current.withLock { $0 = changed }

        await #expect(throws: ZellijSessionPresentationError.hostChanged(
            "api"
        )) {
            try await model.killZellijSession(request)
        }
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

    private func zellijEnvironment(
        sessions: [String]
    ) throws -> (database: WorkspaceDatabase, host: HostSummary, snapshot: WorkspaceSnapshot) {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            zellijSessions: sessions.map(ZellijSessionSummary.init(name:)),
            zellijAvailable: true
        )
        return (
            database,
            host,
            WorkspaceSnapshot(hosts: [host], projects: [], worktrees: [])
        )
    }
}
