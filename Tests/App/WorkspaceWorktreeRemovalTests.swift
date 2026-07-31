import Foundation
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private let stableWorktreeGeneration =
    "0123456789abcdef0123456789abcdef"

private actor RemovalPreflightHold {
    private var callCount = 0
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func verify(
        selection: WorkspaceTmuxSessionSelection,
        host: TmuxHost
    ) async throws -> TmuxSessionIdentity {
        callCount += 1
        if callCount == 1 {
            throw TmuxSessionKillError.sessionNotRunning(
                host: host.displayName,
                session: selection.name
            )
        }
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        throw TmuxSessionKillError.sessionNotRunning(
            host: host.displayName,
            session: selection.name
        )
    }

    func load(_ inventory: KwtHostInventory) async -> KwtHostInventory {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return inventory
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func inventory(
    _ environment: StandardEnvironment,
    including worktree: WorktreeSummary? = nil,
    generation: String? = stableWorktreeGeneration
) -> KwtHostInventory {
    var worktrees = [
        KwtWorktreeRecord(
            path: environment.worktree.path,
            branch: environment.worktree.branch,
            commitHash: "",
            isMain: true,
            createdAt: nil,
            generation: nil,
            repository: environment.project.scopedKey,
            sessionName: "kwt-ghosthub-main",
            tmuxSocketName: nil
        ),
    ]
    if let worktree {
        worktrees.append(KwtWorktreeRecord(
            path: worktree.path,
            branch: worktree.branch,
            commitHash: "",
            isMain: worktree.isPrimary,
            createdAt: nil,
            generation: generation,
            repository: environment.project.scopedKey,
            sessionName: worktree.tmuxSessionName ?? "",
            tmuxSocketName: worktree.tmuxSocketName
        ))
    }
    return KwtHostInventory(projects: [
        KwtProjectInventory(
            project: KwtProjectRecord(
                repository: environment.project.scopedKey,
                name: environment.project.name,
                path: environment.project.rootPath,
                lastTouched: nil
            ),
            worktrees: worktrees,
            warning: nil
        ),
    ])
}

private func inventory(
    _ environment: RemoteEnvironment,
    including worktree: WorktreeSummary
) -> KwtHostInventory {
    KwtHostInventory(projects: [
        KwtProjectInventory(
            project: KwtProjectRecord(
                repository: environment.project.scopedKey,
                name: environment.project.name,
                path: environment.project.rootPath,
                lastTouched: nil
            ),
            worktrees: [
                KwtWorktreeRecord(
                    path: worktree.path,
                    branch: worktree.branch,
                    commitHash: "",
                    isMain: worktree.isPrimary,
                    createdAt: worktree.createdAt,
                    generation: worktree.generation,
                    repository: environment.project.scopedKey,
                    sessionName: worktree.tmuxSessionName ?? "",
                    tmuxSocketName: worktree.tmuxSocketName
                ),
            ],
            warning: nil
        ),
    ])
}

@Suite("Workspace worktree removal")
struct WorkspaceWorktreeRemovalTests {
    @MainActor
    @Test("removal reconciles worktree and session state in other scenes")
    func removalReconcilesOtherScenes() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: stableWorktreeGeneration
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "kwt-ghosthub-feature",
                managed: true,
                windows: [],
                serverPID: "31415",
                sessionID: "$8",
                createdAt: "1721552400"
            ),
        ]
        let beforeRemoval = inventory(environment, including: removable)
        let afterRemoval = inventory(environment)
        let warningAfterRemoval: KwtHostInventory = {
            var inventory = beforeRemoval
            inventory.projects[0].worktrees = []
            inventory.projects[0].warning = "inventory unavailable"
            return inventory
        }()
        let coordinator = WorktreeMutationCoordinator()
        let firstLoads = LockedValue(0)
        let secondLoads = LockedValue(0)
        let secondDiscoveries = LockedValue(0)
        let firstModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                firstLoads.withLock { $0 += 1 }
                return firstLoads.load() == 1
                    ? beforeRemoval
                    : afterRemoval
            },
            kwtWorktreeRemover: { _, _, _, _ in },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionKiller: { _, _, _ in }
        )
        let secondModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                secondLoads.withLock { $0 += 1 }
                return secondLoads.load() == 1
                    ? beforeRemoval
                    : warningAfterRemoval
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionDiscovery: { _ in
                secondDiscoveries.withLock { $0 += 1 }
                return secondDiscoveries.load() == 1
                    ? .success([
                        DiscoveredTmuxSession(
                            name: "kwt-ghosthub-feature",
                            windowCount: 1,
                            serverPID: "31415",
                            sessionID: "$8",
                            createdAt: "1721552400",
                            managed: true
                        ),
                    ])
                    : .success([])
            }
        )
        secondModel.startKwtInventory()
        secondModel.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            secondLoads.load() == 1
                && secondDiscoveries.load() == 1
        }

        let request = try await firstModel.prepareWorktreeRemoval(removable.id)
        try await firstModel.removeWorktree(request)

        await waitUntilMainActor {
            secondLoads.load() >= 2
                && secondDiscoveries.load() >= 2
        }
        #expect(secondModel.snapshot.worktree(id: removable.id) == nil)
        #expect(
            secondModel.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        )
        await firstModel.shutdown()
        await secondModel.shutdown()
    }

    @MainActor
    @Test(
        "live session removal leaves a same-path worktree on another host"
    )
    func liveSessionIsKilledFirst() async throws {
        let environment = try setupStandardEnvironment()
        let feature = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: stableWorktreeGeneration
        )
        var removable = feature
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        removable.tmuxSocketName = "kwt-pr-0123456789abcdef"
        removable.sessionBackend = .localTmux

        var snapshot = environment.snapshot
        let otherHost = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "build-box"
        )
        let otherProject = ProjectSummary.fixture(
            hostID: otherHost.id,
            name: "Ghosthub",
            rootPath: "/srv/ghosthub"
        )
        let samePath = WorktreeSummary.fixture(
            hostID: otherHost.id,
            projectID: otherProject.id,
            scopedKey: removable.path,
            name: "other-host",
            path: removable.path,
            branch: "other-host"
        )
        snapshot.hosts.append(otherHost)
        snapshot.projects.append(otherProject)
        snapshot.worktrees += [removable, samePath]
        let events = LockedValue<[String]>([])
        let loads = LockedValue(0)
        let beforeRemoval = inventory(environment, including: removable)
        let afterRemoval = inventory(environment)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                events.withLock { $0.append("refresh") }
                loads.withLock { $0 += 1 }
                return loads.load() == 1 ? beforeRemoval : afterRemoval
            },
            kwtWorktreeRemover: { path, _, projectPath, _ in
                events.withLock {
                    $0.append("remove:\(projectPath):\(path)")
                }
            },
            tmuxSessionKiller: { selection, _, _ in
                events.withLock { $0.append("kill:\(selection.name)") }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )
        model.selection.select(
            .worktree(removable.id),
            in: model.snapshot
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest != nil)
        try await model.removeWorktree(request)

        #expect(events.load() == [
            "refresh",
            "kill:kwt-ghosthub-feature",
            "remove:/tmp/ghosthub:/tmp/ghosthub-feature",
            "refresh",
        ])
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        #expect(model.snapshot.worktree(id: samePath.id) == samePath)
        #expect(
            model.selection.selectedWorktreeID
                == environment.worktree.id
        )
        await model.shutdown()
    }

    @MainActor
    @Test("known missing kwt makes a cached worktree non-removable")
    func unavailableKwtDisablesRemoval() throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.hosts[0].remoteDiagnostics = [.missingKwtCapability]
        let worktree = try #require(snapshot.worktrees.first)

        #expect(!snapshot.canRemoveWorktree(worktree))
    }

    @MainActor
    @Test("an already-absent worktree completes cached removal")
    func alreadyAbsentWorktreeCompletesRemoval() async throws {
        let environment = try setupStandardEnvironment()
        let removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: stableWorktreeGeneration
        )
        let session = TerminalSessionSummary(
            id: UUID(),
            hostID: environment.host.id,
            worktreeID: removable.id,
            scopedKey: removable.scopedKey,
            isAlive: false
        )
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        snapshot.sessions.append(session)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        try await model.removeWorktree(request)

        #expect(removals.load() == 0)
        #expect(kills.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        #expect(model.snapshot.sessions.contains { $0.id == session.id } == false)
        await model.shutdown()
    }

    @MainActor
    @Test("an already-absent worktree still kills its confirmed session")
    func alreadyAbsentWorktreeKillsConfirmedSession() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: stableWorktreeGeneration
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        removable.tmuxSocketName = "kwt-pr-0123456789abcdef"
        removable.sessionBackend = .localTmux
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let events = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _ in
                events.withLock { $0.append("remove") }
            },
            tmuxSessionKiller: { selection, _, _ in
                events.withLock { $0.append("kill:\(selection.name)") }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest != nil)
        try await model.removeWorktree(request)

        #expect(events.load() == ["kill:kwt-ghosthub-feature"])
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a session starting for an absent worktree requires confirmation again")
    func newlyStartedSessionForAbsentWorktreeAbortsRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: stableWorktreeGeneration
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        removable.tmuxSocketName = "kwt-pr-0123456789abcdef"
        removable.sessionBackend = .localTmux
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                reads.withLock { $0 += 1 }
                if reads.load() == 1 {
                    throw TmuxSessionKillError.sessionNotRunning(
                        host: host.displayName,
                        session: selection.name
                    )
                }
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest == nil)
        await #expect(
            throws: KwtWorktreeError.sessionStartedAfterConfirmation(
                session: "kwt-ghosthub-feature"
            )
        ) {
            try await model.removeWorktree(request)
        }

        #expect(removals.load() == 0)
        #expect(kills.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "removal requires a canonical worktree generation",
        arguments: [
            nil,
            "",
            "   ",
            "not-a-generation",
            "0123456789abcdef",
            "0123456789ABCDEF0123456789ABCDEF",
        ] as [String?]
    )
    func invalidGenerationAbortsPreparation(
        generation: String?
    ) async throws {
        let environment = try setupStandardEnvironment()
        let removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: generation
        )
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot
        )

        await #expect(
            throws: KwtWorktreeError.removalIdentityUnavailable
        ) {
            try await model.prepareWorktreeRemoval(removable.id)
        }
        await model.shutdown()
    }

    @MainActor
    @Test("kwt availability is checked before terminating a session")
    func unavailableKwtDoesNotKillSession() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let events = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                throw KwtInventoryError.commandFailed(
                    host: "Office Linux",
                    status: 127
                )
            },
            kwtWorktreeRemover: { _, _, _, _ in
                events.withLock { $0.append("remove") }
            },
            tmuxSessionKiller: { _, _, _ in
                events.withLock { $0.append("kill") }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        await #expect(throws: KwtInventoryError.self) {
            try await model.removeWorktree(request)
        }

        #expect(events.load().isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("removal rejects a host endpoint changed after confirmation")
    func changedHostEndpointAbortsRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        #expect(
            request.confirmedHost.sshDestination
                == environment.host.sshDestination
        )
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"

        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await model.removeWorktree(request)
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("removal rechecks the confirmed host after preflight")
    func hostEndpointChangedDuringPreflightAbortsRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.scopedKey = worktree.path
        worktree.tmuxSessionName = "kwt-remote-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let hold = RemovalPreflightHold()
        let preflight = inventory(environment, including: worktree)
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                try await hold.verify(selection: selection, host: host)
            }
        )
        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        for _ in 0 ..< 1_000 {
            if await hold.started {
                break
            }
            await Task.yield()
        }
        #expect(await hold.started)
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("an absent preflight cannot clear state for a changed host endpoint")
    func absentPreflightWithChangedHostEndpointAbortsRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let absentPreflight: KwtHostInventory = {
            var value = inventory(environment, including: worktree)
            value.projects[0].worktrees = []
            return value
        }()
        let hold = RemovalPreflightHold()
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                await hold.load(absentPreflight)
            },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )
        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        for _ in 0 ..< 1_000 {
            if await hold.started {
                break
            }
            await Task.yield()
        }
        #expect(await hold.started)
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: worktree.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a session starting after confirmation requires confirmation again")
    func newlyStartedSessionAbortsRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        removable.generation = stableWorktreeGeneration
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let beforeRemoval = inventory(environment, including: removable)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                reads.withLock { $0 += 1 }
                let attempt = reads.load()
                if attempt == 1 {
                    throw TmuxSessionKillError.sessionNotRunning(
                        host: host.displayName,
                        session: selection.name
                    )
                }
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest == nil)
        do {
            try await model.removeWorktree(request)
            Issue.record("Removal should require a new confirmation")
        } catch {
            #expect(
                error as? KwtWorktreeError
                    == .sessionStartedAfterConfirmation(
                        session: "kwt-ghosthub-feature"
                    )
            )
        }

        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("refresh failure after removal is a reconciliation warning")
    func refreshFailureDoesNotUndoRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        removable.generation = stableWorktreeGeneration
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let loads = LockedValue(0)
        let removals = LockedValue(0)
        let beforeRemoval = inventory(environment, including: removable)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                let attempt = loads.load()
                if attempt == 1 {
                    return beforeRemoval
                }
                throw KwtInventoryError.commandFailed(
                    host: "this Mac",
                    status: 23
                )
            },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        try await model.removeWorktree(request)

        #expect(removals.load() == 1)
        #expect(loads.load() == 2)
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[
                environment.host.id
            ] != nil
        )
        await model.shutdown()
    }

    @MainActor
    @Test(
        "changed target metadata invalidates the removal confirmation",
        arguments: [
            (
                branch: "feature/replacement",
                session: "kwt-ghosthub-feature"
            ),
            (
                branch: "feature/remove",
                session: "kwt-ghosthub-replacement"
            ),
        ]
    )
    func changedTargetAbortsRemoval(
        replacementBranch: String,
        replacementSession: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: stableWorktreeGeneration
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var replacement = removable
        replacement.branch = replacementBranch
        replacement.name = replacementBranch
        replacement.tmuxSessionName = replacementSession
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let events = LockedValue<[String]>([])
        let replacementInventory = inventory(
            environment,
            including: replacement
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in replacementInventory },
            kwtWorktreeRemover: { _, _, _, _ in
                events.withLock { $0.append("remove") }
            },
            tmuxSessionKiller: { _, _, _ in
                events.withLock { $0.append("kill") }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        do {
            try await model.removeWorktree(request)
            Issue.record("Changed worktree metadata should require confirmation")
        } catch {
            #expect(
                error as? KwtWorktreeError
                    == KwtWorktreeError.removalTargetChanged
            )
        }

        #expect(events.load().isEmpty)
        #expect(
            model.snapshot.worktree(id: removable.id)?.branch
                == replacementBranch
        )
        #expect(
            model.snapshot.worktree(id: removable.id)?.tmuxSessionName
                == replacementSession
        )
        await model.shutdown()
    }

    @MainActor
    @Test("a recreated worktree invalidates removal confirmation")
    func recreatedWorktreeAbortsRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var removable = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-feature",
            name: "feature/remove",
            path: "/tmp/ghosthub-feature",
            branch: "feature/remove",
            generation: stableWorktreeGeneration
        )
        removable.tmuxSessionName = "kwt-ghosthub-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removable)
        let removals = LockedValue(0)
        let recreatedInventory = inventory(
            environment,
            including: removable,
            generation: "fedcba9876543210fedcba9876543210"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in recreatedInventory },
            kwtWorktreeRemover: { _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await model.removeWorktree(request)
        }

        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("removal completion preserves newer navigation")
    func removalPreservesCurrentSelection() throws {
        let environment = try setupStandardEnvironment()
        let removed = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removed)
        var current = WorkspaceSelection(
            selectedHostID: environment.host.id
        )
        current.select(
            WorkspaceNavigationTarget.worktree(environment.worktree.id),
            in: snapshot
        )
        snapshot.worktrees.removeAll { $0.id == removed.id }

        let resolved = WorkspaceSceneModel.selectionAfterWorktreeRemoval(
            current,
            in: snapshot,
            visibility: WorktreeVisibility.default
        )

        #expect(resolved.selectedWorktreeID == environment.worktree.id)
    }
}
