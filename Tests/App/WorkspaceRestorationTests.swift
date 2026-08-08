import GhosthubTransport
import Foundation
import GhosthubHerdr
import GhosthubTerminal
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import GhosthubSettings
import Testing
@testable import GhosthubApp

private let restorationWorktreeGeneration =
    "0123456789abcdef0123456789abcdef"

final class RestorationInventoryState: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionName: String
    private var isReachable: Bool
    private var isPublished = false
    private var attempts = 0

    init(sessionName: String, initiallyReachable: Bool = true) {
        self.sessionName = sessionName
        isReachable = initiallyReachable
    }

    func publishExactSession() {
        lock.lock()
        isReachable = true
        isPublished = true
        lock.unlock()
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func discover(
        _ host: CommandHost
    ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        lock.lock()
        attempts += 1
        let reachable = isReachable
        let published = isPublished
        lock.unlock()
        guard reachable else {
            return .failure(.sshConnectionFailed(
                host: host.displayName,
                classification: SSHConnectionFailure.classify(
                    status: 255,
                    output: ""
                )
            ))
        }
        return .success(published ? [
            DiscoveredTmuxSession(
                name: sessionName,
                windowCount: 1,
                createdAt: "1721552400",
                managed: false
            ),
        ] : [])
    }
}

private final class HerdrRestorationInventoryState: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionName: String
    private var publishesExactSession = false
    private var attempts = 0

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    func publishExactSession() {
        lock.withLock { publishesExactSession = true }
    }

    var attemptCount: Int { lock.withLock { attempts } }

    func discover(_ host: CommandHost) -> HerdrDiscoveryResult {
        lock.withLock {
            attempts += 1
            return .available(publishesExactSession ? [
                HerdrSessionSummary(name: sessionName, isDefault: false, state: .running),
            ] : [])
        }
    }
}

@MainActor
private struct RemoteRestorationHarness {
    let model: WorkspaceSceneModel
    let inventory: RestorationInventoryState
    let surfaceStore: RecordingNativeSessionSurfaceStore
    let savedState: WorkspaceWindowState

    static func make(
        publishSession: Bool,
        additionalHost: HostSummary? = nil
    ) throws -> Self {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "editor"
        snapshot.worktrees[0].generation = restorationWorktreeGeneration
        if let additionalHost {
            snapshot.hosts.append(additionalHost)
        }
        let inventory = RestorationInventoryState(
            sessionName: "editor",
            initiallyReachable: publishSession
        )
        if publishSession {
            inventory.publishExactSession()
        }
        let surfaceStore = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionDiscovery: inventory.discover
        )
        let savedState = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: environment.host.configKey,
                projectKey: environment.project.scopedKey,
                worktreeGeneration: restorationWorktreeGeneration
            ),
            tmux: .init(
                hostKey: environment.host.configKey,
                sessionName: "editor",
                socketName: nil,
                owner: .worktree(
                    generation: restorationWorktreeGeneration
                )
            )
        )
        return Self(
            model: model,
            inventory: inventory,
            surfaceStore: surfaceStore,
            savedState: savedState
        )
    }
}

private final class ProtectedProbeSpy: @unchecked Sendable {
    enum Outcome: Sendable {
        case present
        case absent
        case failed
    }

    private let lock = NSLock()
    private var outcome: Outcome
    private var recordedSelections: [WorkspaceTmuxSessionSelection] = []
    private var completedReads = 0

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    var selections: [WorkspaceTmuxSessionSelection] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSelections
    }

    var completionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedReads
    }

    func setOutcome(_ outcome: Outcome) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    func read(
        _ selection: WorkspaceTmuxSessionSelection,
        _ host: CommandHost
    ) async throws -> TmuxSessionIdentity {
        let current = record(selection)
        defer { recordCompletion() }
        switch current {
        case .present:
            return TmuxSessionIdentity(
                serverPID: "123",
                sessionID: "$7",
                createdAt: "1721552400"
            )
        case .absent:
            throw TmuxSessionKillError.sessionNotRunning(
                host: host.displayName,
                session: selection.name
            )
        case .failed:
            throw TmuxSessionKillError.identityCommandFailed(
                host: host.displayName,
                session: selection.name,
                status: 255
            )
        }
    }

    private func record(
        _ selection: WorkspaceTmuxSessionSelection
    ) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        recordedSelections.append(selection)
        return outcome
    }

    private func recordCompletion() {
        lock.lock()
        completedReads += 1
        lock.unlock()
    }
}

private final class ControlledProtectedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedHosts: [CommandHost] = []
    private var recordedSelections: [WorkspaceTmuxSessionSelection] = []
    private var continuations:
        [Int: CheckedContinuation<TmuxSessionIdentity, any Error>] = [:]
    private var completedReads = 0

    var hosts: [CommandHost] {
        lock.lock()
        defer { lock.unlock() }
        return recordedHosts
    }

    var selections: [WorkspaceTmuxSessionSelection] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSelections
    }

    var completionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedReads
    }

    func read(
        _ selection: WorkspaceTmuxSessionSelection,
        _ host: CommandHost
    ) async throws -> TmuxSessionIdentity {
        defer { recordCompletion() }
        return try await withCheckedThrowingContinuation {
            continuation in
            lock.lock()
            let index = recordedHosts.count
            recordedHosts.append(host)
            recordedSelections.append(selection)
            continuations[index] = continuation
            lock.unlock()
        }
    }

    func complete(_ index: Int) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: index)
        lock.unlock()
        continuation?.resume(returning: TmuxSessionIdentity(
            serverPID: "123",
            sessionID: "$7",
            createdAt: "1721552400"
        ))
    }

    func fail(_ index: Int) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: index)
        let host = recordedHosts[index]
        let selection = recordedSelections[index]
        lock.unlock()
        continuation?.resume(throwing: TmuxSessionKillError
            .identityCommandFailed(
                host: host.displayName,
                session: selection.name,
                status: 255
            ))
    }

    private func recordCompletion() {
        lock.lock()
        completedReads += 1
        lock.unlock()
    }
}

@MainActor
private struct ProtectedRestorationHarness {
    let model: WorkspaceSceneModel
    let probe: ProtectedProbeSpy
    let savedState: WorkspaceWindowState

    static func make(outcome: ProtectedProbeSpy.Outcome) throws -> Self {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "pr-42"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-0123456789abcdef"
        snapshot.worktrees[0].generation = restorationWorktreeGeneration
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(name: "pr-42", managed: false, windows: []),
        ]
        let probe = ProtectedProbeSpy(outcome: outcome)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: probe.read
        )
        let savedState = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: environment.host.configKey,
                projectKey: environment.project.scopedKey,
                worktreeGeneration: restorationWorktreeGeneration
            ),
            tmux: .init(
                hostKey: environment.host.configKey,
                sessionName: "pr-42",
                socketName: "kwt-pr-0123456789abcdef",
                owner: .worktree(
                    generation: restorationWorktreeGeneration
                )
            )
        )
        return Self(model: model, probe: probe, savedState: savedState)
    }
}

@MainActor
@Suite("Workspace restoration", .serialized)
struct WorkspaceRestorationTests {
    @Test("Herdr restoration waits for fresh exact discovery")
    func herdrRestorationWaitsForFreshExactDiscovery() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].herdrSessions = [
            HerdrSessionSummary(name: "editor", isDefault: false, state: .running),
        ]
        let inventory = HerdrRestorationInventoryState(
            sessionName: "editor"
        )
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeHerdrSurfaceStore: store,
            nativeHerdrPathProvider: { _ in .success("/usr/bin/herdr") },
            herdrSessionDiscovery: inventory.discover
        )
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: environment.host.configKey,
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil,
            herdr: WorkspaceHerdrDescriptor(
                hostKey: environment.host.configKey,
                sessionName: "editor"
            )
        )

        model.startHerdrSessionDiscovery()
        model.beginRestoration(state)
        #expect(model.activeBorrowedHerdrSelection == nil)
        await waitUntilMainActor {
            inventory.attemptCount >= 1
                && model.snapshot.host(id: environment.host.id)?
                .herdrSessions.isEmpty == true
        }
        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(model.restorationState(windowID: state.windowID) == state)

        inventory.publishExactSession()
        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.activeBorrowedHerdrSelection?.name == "editor"
        }
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return store.lastCommand != nil
        }

        let command = try #require(store.lastCommand)
        let expectedCommand = try HerdrAttachmentInfo(
            sessionName: "editor",
            host: .local
        ).attachCommand(herdrPath: "/usr/bin/herdr")
        #expect(command == expectedCommand)
        #expect(!model.isWorkspaceRestorationPending)
        await model.shutdown()
    }

    @Test("Herdr restoration waits for lifecycle completion and rediscovery")
    func herdrRestorationWaitsForLifecycleCompletion() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].herdrSessions = [
            HerdrSessionSummary(
                name: "editor",
                isDefault: false,
                state: .running
            ),
        ]
        let inventory = HerdrRestorationInventoryState(
            sessionName: "editor"
        )
        inventory.publishExactSession()
        let coordinator = HerdrSessionLifecycleCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeHerdrPathProvider: { _ in .success("/usr/bin/herdr") },
            herdrLifecycleCoordinator: coordinator,
            herdrSessionDiscovery: inventory.discover
        )
        let target = WorkspaceHerdrSessionSelection(
            hostID: environment.host.id,
            name: "editor"
        )
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: environment.host.configKey,
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil,
            herdr: WorkspaceHerdrDescriptor(
                hostKey: environment.host.configKey,
                sessionName: target.name
            )
        )

        model.startHerdrSessionDiscovery()
        model.beginRestoration(state)
        await waitUntilMainActor {
            model.activeBorrowedHerdrSelection == target
        }
        model.closeBorrowedHerdrSession(target)
        let operation = try #require(coordinator.begin(.stop, key: .init(
            hostID: target.hostID,
            sessionName: target.name
        )))

        model.beginRestoration(state)
        #expect(model.activeBorrowedHerdrSelection == nil)
        let attemptsBeforeCompletion = inventory.attemptCount

        coordinator.finish(operation, outcome: .failed)
        await waitUntilMainActor {
            model.activeBorrowedHerdrSelection == target
        }
        #expect(inventory.attemptCount > attemptsBeforeCompletion)
        await model.shutdown()
    }

    @Test("explicit navigation cancels pending Herdr restoration")
    func navigationCancelsPendingHerdrRestoration() async throws {
        let environment = try setupStandardEnvironment()
        let inventory = HerdrRestorationInventoryState(
            sessionName: "editor"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeHerdrPathProvider: { _ in .success("/usr/bin/herdr") },
            herdrSessionDiscovery: inventory.discover
        )
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: environment.host.configKey,
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil,
            herdr: WorkspaceHerdrDescriptor(
                hostKey: environment.host.configKey,
                sessionName: "editor"
            )
        )

        model.startHerdrSessionDiscovery()
        model.beginRestoration(state)
        await waitUntil { inventory.attemptCount >= 1 }
        model.selectFromUser(WorkspaceSelection(
            selectedHostID: environment.host.id
        ))
        inventory.publishExactSession()
        model.refreshKwtInventory()
        await waitUntil { inventory.attemptCount >= 2 }

        #expect(model.activeBorrowedHerdrSelection == nil)
        #expect(!model.isWorkspaceRestorationPending)
        await model.shutdown()
    }

    @Test("ordinary restoration waits for exact direct discovery then attaches only")
    func ordinaryRestorationIsAttachOnly() async throws {
        let inventory = RestorationInventoryState(sessionName: "editor")
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "editor"
        snapshot.worktrees[0].generation = restorationWorktreeGeneration
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            tmuxSessionDiscovery: inventory.discover
        )
        model.startTmuxSessionDiscovery()
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: environment.host.configKey,
                projectKey: environment.project.scopedKey,
                worktreeGeneration: restorationWorktreeGeneration
            ),
            tmux: .init(
                hostKey: environment.host.configKey,
                sessionName: "editor",
                socketName: nil,
                owner: .worktree(
                    generation: restorationWorktreeGeneration
                )
            )
        ))

        #expect(model.activeBorrowedTmuxSelection == nil)
        await waitUntilMainActor(timeout: .seconds(15)) {
            inventory.attemptCount >= 1
                && model.snapshot.host(id: environment.host.id)?.lastSeenAt
                != nil
        }
        inventory.publishExactSession()
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.activeBorrowedTmuxSelection?.name == "editor"
        }
        #expect(!model.suppressesAutomaticWorktreeSessionOpen)

        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return store.lastCommand != nil
        }
        let command = try #require(store.lastCommand)
        #expect(command.contains("attach-session"))
        #expect(command.contains("'=editor'"))
        #expect(!command.contains("kwt"))
        #expect(!command.contains("new-session"))
    }

    @Test("remote restoration keeps SSH reconnect while avoiding kwt open")
    func remoteRestorationIsAttachOnly() async throws {
        let harness = try RemoteRestorationHarness.make(publishSession: true)
        harness.model.startTmuxSessionDiscovery()
        harness.model.beginRestoration(harness.savedState)
        await waitUntilMainActor {
            harness.model.prepareActiveBorrowedTmuxSurface()
            return harness.surfaceStore.lastCommand != nil
        }

        let command = try #require(harness.surfaceStore.lastCommand)
        #expect(command.contains("ServerAliveInterval=15"))
        #expect(command.contains("attach-session"))
        #expect(!command.contains("'open'"))
        #expect(!command.contains("new-session"))
    }

    @Test("protected restoration probes exact socket before kwt attach")
    func protectedRestorationProbesBeforeAttach() async throws {
        let harness = try ProtectedRestorationHarness.make(outcome: .present)

        harness.model.beginRestoration(harness.savedState)
        await waitUntil { harness.probe.selections.count == 1 }

        let selection = try #require(harness.probe.selections.first)
        #expect(selection.name == "pr-42")
        #expect(
            selection.socketName
                == "kwt-pr-0123456789abcdef"
        )
        await waitUntilMainActor {
            harness.model.activeBorrowedTmuxSelection != nil
        }
        #expect(
            harness.model.activeBorrowedTmuxSelection?.socketName
                == "kwt-pr-0123456789abcdef"
        )
        #expect(!harness.model.suppressesAutomaticWorktreeSessionOpen)
    }

    @Test("absent protected session remains pending without fallback")
    func protectedAbsenceStaysPending() async throws {
        let harness = try ProtectedRestorationHarness.make(outcome: .absent)

        harness.model.beginRestoration(harness.savedState)
        await waitUntil { harness.probe.completionCount >= 1 }

        #expect(harness.model.activeBorrowedTmuxSelection == nil)
        #expect(
            harness.model.restorationState(
                windowID: harness.savedState.windowID
            ) == harness.savedState
        )
    }

    @Test("failed protected probe retries only after inventory refresh")
    func protectedFailureRetriesOnRefresh() async throws {
        let harness = try ProtectedRestorationHarness.make(outcome: .failed)

        harness.model.beginRestoration(harness.savedState)
        await waitUntil { harness.probe.completionCount >= 1 }
        #expect(harness.model.activeBorrowedTmuxSelection == nil)

        harness.probe.setOutcome(.present)
        harness.model.startTmuxSessionDiscovery()
        harness.model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            harness.model.activeBorrowedTmuxSelection != nil
        }

        let secondSelection = try #require(harness.probe.selections.last)
        #expect(secondSelection.name == "pr-42")
        #expect(
            secondSelection.socketName
                == "kwt-pr-0123456789abcdef"
        )
    }

    @Test("offline remote restoration retries after inventory refresh")
    func offlineRemoteRetries() async throws {
        let harness = try RemoteRestorationHarness.make(publishSession: false)
        harness.model.startTmuxSessionDiscovery()
        harness.model.beginRestoration(harness.savedState)
        #expect(harness.model.activeBorrowedTmuxSelection == nil)
        await waitUntilMainActor {
            harness.inventory.attemptCount >= 1
                && harness.model.snapshot.hosts.contains {
                    $0.kind == .remote && $0.connectionState == .offline
                }
        }
        #expect(
            harness.model.restorationState(
                windowID: harness.savedState.windowID
            ) == harness.savedState
        )

        harness.inventory.publishExactSession()
        harness.model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            harness.model.activeBorrowedTmuxSelection?.name == "editor"
        }
    }

    @Test("explicit navigation cancels pending remote restoration")
    func navigationCancelsPendingRestoration() async throws {
        let otherHostID = UUID()
        let otherHost = HostSummary(
            id: otherHostID,
            configKey: "other-host",
            name: "Other Host",
            kind: .remote,
            platform: .linux,
            sshDestination: "other.example.test"
        )
        let harness = try RemoteRestorationHarness.make(
            publishSession: false,
            additionalHost: otherHost
        )
        harness.model.startTmuxSessionDiscovery()
        harness.model.beginRestoration(harness.savedState)
        await waitUntilMainActor {
            harness.inventory.attemptCount >= 1
                && harness.model.snapshot.hosts.contains {
                    $0.kind == .remote && $0.connectionState == .offline
                }
        }
        #expect(
            harness.model.restorationState(
                windowID: harness.savedState.windowID
            ) == harness.savedState
        )

        var userSelection = harness.model.selection
        userSelection.select(.host(otherHostID), in: harness.model.snapshot)
        harness.model.selectFromUser(userSelection)
        #expect(
            harness.model.restorationState(
                windowID: harness.savedState.windowID
            ) != harness.savedState
        )
        let attemptsBeforeRefresh = harness.inventory.attemptCount
        harness.inventory.publishExactSession()
        harness.model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            harness.inventory.attemptCount > attemptsBeforeRefresh
                && harness.model.workspaceInventoryState == .loaded
        }

        #expect(harness.model.selection.selectedHostID == otherHostID)
        #expect(harness.model.activeBorrowedTmuxSelection == nil)
    }

    @Test("indexed worktree shortcut cancels pending restoration")
    func indexedShortcutCancelsPendingRestoration() throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let secondWorktree = WorktreeSummary(
            id: UUID(),
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "worktree:/tmp/ghosthub-second",
            name: "second",
            path: "/tmp/ghosthub-second",
            branch: "second"
        )
        snapshot.worktrees.append(secondWorktree)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot
        )
        let pending = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "unavailable-host",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil
        )
        model.beginRestoration(pending)

        model.selectIndexedWorktree(2)

        #expect(model.selection.selectedWorktreeID == secondWorktree.id)
        #expect(
            model.restorationState(windowID: pending.windowID) != pending
        )
    }

    @Test(
        "previous and next worktree shortcuts cancel pending restoration",
        arguments: [-1, 1]
    )
    func steppedShortcutCancelsPendingRestoration(_ step: Int) throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let secondWorktree = WorktreeSummary(
            id: UUID(),
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "worktree:/tmp/ghosthub-second",
            name: "second",
            path: "/tmp/ghosthub-second",
            branch: "second"
        )
        snapshot.worktrees.append(secondWorktree)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot
        )
        model.synchronizeSelection(WorkspaceSelection(
            selectedHostID: environment.host.id,
            selectedProjectID: environment.project.id,
            selectedWorktreeID: environment.worktree.id
        ))
        let pending = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "unavailable-host",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil
        )
        model.beginRestoration(pending)

        model.stepWorktree(by: step)

        #expect(model.selection.selectedWorktreeID == secondWorktree.id)
        #expect(
            model.restorationState(windowID: pending.windowID) != pending
        )
    }

    @Test("automatic selection normalization preserves pending restoration")
    func automaticSelectionPreservesPendingRestoration() throws {
        let harness = try RemoteRestorationHarness.make(publishSession: false)
        harness.model.beginRestoration(harness.savedState)
        var normalizedSelection = harness.model.selection
        normalizedSelection.selectedProjectID = nil
        normalizedSelection.selectedWorktreeID = nil

        harness.model.synchronizeSelection(normalizedSelection)

        #expect(
            harness.model.restorationState(
                windowID: harness.savedState.windowID
            ) == harness.savedState
        )
    }

    @Test("navigation-only restoration suppression lasts until explicit navigation")
    func navigationOnlySuppressionRequiresNavigation() throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation = restorationWorktreeGeneration
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot
        )
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: environment.host.configKey,
                projectKey: environment.project.scopedKey,
                worktreeGeneration: restorationWorktreeGeneration
            ),
            tmux: nil
        )

        model.beginRestoration(state)

        #expect(model.selection.selectedWorktreeID == environment.worktree.id)
        #expect(!model.isWorkspaceRestorationPending)
        #expect(model.suppressesAutomaticWorktreeSessionOpen)

        model.selectFromUser(model.selection)

        #expect(!model.suppressesAutomaticWorktreeSessionOpen)
    }

    @Test("protected restoration retries inventory changed during its probe")
    func protectedInventoryRefreshRetriesAfterProbe() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "pr-42"
        snapshot.worktrees[0].tmuxSocketName =
            "kwt-pr-0123456789abcdef"
        snapshot.worktrees[0].generation = restorationWorktreeGeneration
        let probe = ControlledProtectedProbe()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: probe.read
        )
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: environment.host.configKey,
                projectKey: environment.project.scopedKey,
                worktreeGeneration: restorationWorktreeGeneration
            ),
            tmux: .init(
                hostKey: environment.host.configKey,
                sessionName: "pr-42",
                socketName: "kwt-pr-0123456789abcdef",
                owner: .worktree(
                    generation: restorationWorktreeGeneration
                )
            )
        )

        model.beginRestoration(state)
        await waitUntil { probe.selections.count == 1 }
        var updatedSnapshot = model.snapshot
        updatedSnapshot.worktrees[0].path = "/tmp/ghosthub-refreshed"
        model.snapshot = updatedSnapshot
        guard case .needsProtectedProbe = WorkspaceWindowRestorationResolver
            .resolve(state, in: model.snapshot) else {
            Issue.record("updated target should still require a probe")
            return
        }
        probe.complete(0)
        await waitUntil { probe.completionCount == 1 }

        await waitUntil { probe.selections.count == 2 }
        #expect(
            probe.selections.last?.workspacePath
                == "/tmp/ghosthub-refreshed"
        )
        probe.complete(1)
        await waitUntil { probe.completionCount == 2 }
        await waitUntilMainActor {
            model.activeBorrowedTmuxSelection != nil
        }

        #expect(model.activeBorrowedTmuxSelection?.name == "pr-42")
        #expect(
            model.activeBorrowedTmuxSelection?.workspacePath
                == "/tmp/ghosthub-refreshed"
        )
    }

    @Test("failed protected probe retries an inventory refresh queued during the probe")
    func failedProtectedProbeRetriesQueuedRefresh() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "pr-42"
        snapshot.worktrees[0].tmuxSocketName =
            "kwt-pr-0123456789abcdef"
        snapshot.worktrees[0].generation = restorationWorktreeGeneration
        let probe = ControlledProtectedProbe()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: probe.read
        )
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: environment.host.configKey,
                projectKey: environment.project.scopedKey,
                worktreeGeneration: restorationWorktreeGeneration
            ),
            tmux: .init(
                hostKey: environment.host.configKey,
                sessionName: "pr-42",
                socketName: "kwt-pr-0123456789abcdef",
                owner: .worktree(
                    generation: restorationWorktreeGeneration
                )
            )
        )

        model.beginRestoration(state)
        await waitUntil { probe.selections.count == 1 }
        var updatedSnapshot = model.snapshot
        updatedSnapshot.worktrees[0].path = "/tmp/ghosthub-refreshed"
        model.snapshot = updatedSnapshot
        probe.fail(0)
        await waitUntil { probe.completionCount == 1 }

        await waitUntil { probe.selections.count == 2 }
        probe.complete(1)
        await waitUntil { probe.completionCount == 2 }
        await waitUntilMainActor {
            model.activeBorrowedTmuxSelection != nil
        }

        #expect(model.activeBorrowedTmuxSelection?.name == "pr-42")
        #expect(
            model.activeBorrowedTmuxSelection?.workspacePath
                == "/tmp/ghosthub-refreshed"
        )
    }

    @Test("protected restoration rejects worktree ownership changed during its probe")
    func protectedWorktreeOwnershipMustRemainStable() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "pr-42"
        snapshot.worktrees[0].tmuxSocketName =
            "kwt-pr-0123456789abcdef"
        snapshot.worktrees[0].generation = restorationWorktreeGeneration
        let probe = ControlledProtectedProbe()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: probe.read
        )
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: environment.host.configKey,
                projectKey: environment.project.scopedKey,
                worktreeGeneration: restorationWorktreeGeneration
            ),
            tmux: .init(
                hostKey: environment.host.configKey,
                sessionName: "pr-42",
                socketName: "kwt-pr-0123456789abcdef",
                owner: .worktree(
                    generation: restorationWorktreeGeneration
                )
            )
        )

        model.beginRestoration(state)
        await waitUntil { probe.hosts.count == 1 }
        model.snapshot.worktrees[0].tmuxSessionName = "replacement"
        probe.complete(0)
        await waitUntil { probe.completionCount == 1 }

        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(model.restorationState(windowID: state.windowID) == state)
    }

    @Test("a canceled protected probe cannot authorize restarted restoration")
    func canceledProtectedProbeCannotAttach() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "pr-42"
        snapshot.worktrees[0].tmuxSocketName =
            "kwt-pr-0123456789abcdef"
        snapshot.worktrees[0].generation = restorationWorktreeGeneration
        let probe = ControlledProtectedProbe()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxSessionIdentityReader: probe.read
        )
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: environment.host.configKey,
                projectKey: environment.project.scopedKey,
                worktreeGeneration: restorationWorktreeGeneration
            ),
            tmux: .init(
                hostKey: environment.host.configKey,
                sessionName: "pr-42",
                socketName: "kwt-pr-0123456789abcdef",
                owner: .worktree(
                    generation: restorationWorktreeGeneration
                )
            )
        )

        model.beginRestoration(state)
        await waitUntil { probe.hosts.count == 1 }
        model.cancelPendingRestoration()
        model.beginRestoration(state)
        await waitUntil { probe.hosts.count == 2 }

        probe.complete(0)
        await waitUntil { probe.completionCount == 1 }
        #expect(model.activeBorrowedTmuxSelection == nil)

        probe.complete(1)
        await waitUntil { probe.completionCount == 2 }
        await waitUntilMainActor {
            model.activeBorrowedTmuxSelection != nil
        }
    }
}
