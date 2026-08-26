import GhosthubTransport
import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

extension WorkspaceWorktreeRemovalTests {
    @MainActor
    @Test("remote removal carries its reviewed SSH route into execution")
    func remoteRemovalUsesReviewedRoute() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.scopedKey = worktree.path
        worktree.generation = stableWorktreeGeneration
        worktree.tmuxSessionName = "kwt-office-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let reviewedWorktree = worktree
        let executedRoute = LockedValue<String?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                inventory(environment, including: reviewedWorktree)
            },
            kwtWorktreeRemover: { _, _, _, routeIdentity, _ in
                executedRoute.withLock { $0 = routeIdentity }
            },
            sshRouteIdentityResolver: { host in
                #expect(host.hostname == "office-linux")
                return "sha256:reviewed-route"
            },
            tmuxSessionIdentityReader: { _, _ in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: "Office Linux",
                    session: "kwt-office-feature"
                )
            },
            tmuxSessionIdentityReviewer: { _, _, _ in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: "Office Linux",
                    session: "kwt-office-feature"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        #expect(request.routeIdentity == "sha256:reviewed-route")

        try await model.removeWorktree(request)

        #expect(executedRoute.load() == "sha256:reviewed-route")
        await model.shutdown()
    }

    @MainActor
    @Test(
        "live session removal leaves a same-path worktree on another host"
    )
    func liveSessionIsKilledFirst() async throws {
        let fixture = try removalFixture(
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected,
            sessionBackend: .localTmux
        )
        let environment = fixture.environment
        let removable = fixture.removable
        var snapshot = fixture.snapshot
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
        snapshot.worktrees.append(samePath)
        let events = LockedValue<[String]>([])
        let loads = LockedValue(0)
        let beforeRemoval = fixture.beforeRemoval
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
            kwtWorktreeRemover: { path, _, projectPath, _, _ in
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
        #expect(model.selection.selectedProjectID == environment.project.id)
        #expect(model.selection.selectedWorktreeID == nil)
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
        let fixture = try removalFixture(sessionName: nil)
        let environment = fixture.environment
        let removable = fixture.removable
        let session = TerminalSessionSummary(
            id: UUID(),
            hostID: environment.host.id,
            worktreeID: removable.id,
            scopedKey: removable.scopedKey,
            isAlive: false
        )
        var snapshot = fixture.snapshot
        snapshot.sessions.append(session)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _, _ in
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
    @Test("an absent remote worktree still requires the reviewed SSH route")
    func absentRemoteWorktreeRejectsRouteDrift() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.scopedKey = worktree.path
        worktree.generation = stableWorktreeGeneration
        worktree.tmuxSessionName = nil
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let route = LockedValue("sha256:reviewed-route")
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                KwtHostInventory(projects: [
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: environment.project.scopedKey,
                            name: environment.project.name,
                            path: environment.project.rootPath,
                            lastTouched: nil
                        ),
                        worktrees: [],
                        warning: nil
                    ),
                ])
            },
            sshRouteIdentityResolver: { _ in route.load() }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        route.store("sha256:replacement-route")

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await model.removeWorktree(request)
        }
        #expect(model.snapshot.worktree(id: worktree.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("failed remote removal does not reconcile through a changed route")
    func failedRemoteRemovalRejectsReconciliationRouteDrift() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.scopedKey = worktree.path
        worktree.generation = stableWorktreeGeneration
        worktree.tmuxSessionName = "kwt-office-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let beforeRemoval = inventory(environment, including: worktree)
        let reconciliationLoads = LockedValue(0)
        let removalCalls = LockedValue(0)
        let removalError = KwtWorktreeError.removalFailed(
            host: environment.host.name,
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtConditionalInventoryLoader: { _, _ in
                reconciliationLoads.withLock { $0 += 1 }
                throw KwtSSHLeaseError.routeChanged
            },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removalCalls.withLock { $0 += 1 }
                throw removalError
            },
            sshRouteIdentityResolver: { _ in "sha256:reviewed-route" },
            tmuxSessionIdentityReader: { _, _ in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: environment.host.name,
                    session: "kwt-office-feature"
                )
            },
            tmuxSessionIdentityReviewer: { _, _, _ in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: environment.host.name,
                    session: "kwt-office-feature"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        await #expect(throws: KwtWorktreeError.removalTargetChanged) {
            try await model.removeWorktree(request)
        }

        #expect(model.snapshot.worktree(id: worktree.id) != nil)
        #expect(removalCalls.load() == 1)
        #expect(reconciliationLoads.load() == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("an already-absent worktree still kills its confirmed session")
    func alreadyAbsentWorktreeKillsConfirmedSession() async throws {
        let fixture = try removalFixture(
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected,
            sessionBackend: .localTmux
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let events = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _, _ in
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
        let fixture = try removalFixture(
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected,
            sessionBackend: .localTmux
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory(environment) },
            kwtWorktreeRemover: { _, _, _, _, _ in
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
            kwtWorktreeRemover: { _, _, _, _, _ in
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
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        #expect(
            request.confirmedHost.sshDestination
                == environment.host.sshDestination
        )
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await model.removeWorktree(request)
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a changed host endpoint cannot refresh removal confirmation")
    func changedHostEndpointIsNotRecoverable() async throws {
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
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await model.resolveWorktreeRemoval(request)
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a changed target cannot redirect confirmation to a new host")
    func changedTargetAndHostEndpointAreNotRecoverable() async throws {
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
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        model.snapshot.worktrees[0].branch = "feature/replacement"
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await model.resolveWorktreeRemoval(request)
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
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                try await hold.verify(selection: selection, host: host)
            }
        )
        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.resolveWorktreeRemoval(request)
        }
        await waitUntilMainActor { await hold.started }
        #expect(await hold.started)
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("failed removal re-establishes after endpoint changes during kill")
    func endpointChangeDuringKillReestablishesPresentation() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.scopedKey = worktree.path
        worktree.tmuxSessionName = "kwt-remote-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let beforeRemoval = inventory(environment, including: worktree)
        let killHold = RemovalPreflightHold()
        let surfaces = RecordingNativeSessionSurfaceStore()
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaces,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            tmuxSessionKiller: { _, _, _ in
                _ = await killHold.load(beforeRemoval)
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: try #require(worktree.tmuxSessionName),
            tmuxAttachMode: .direct
        )
        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 1
        }
        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor { await killHold.started }

        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await killHold.release()
        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        await waitUntilMainActor {
            surfaces.requestedConfigurations.count == 2
        }

        #expect(removals.load() == 0)
        #expect(surfaces.lastCommand?.contains("'open'") == true)
        await model.shutdown()
    }

    @MainActor
    @Test("a session start cannot redirect removal recovery to a new host")
    func sessionStartRecoveryRejectsChangedHostEndpoint() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.scopedKey = worktree.path
        worktree.tmuxSessionName = "kwt-remote-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        let hold = RemovalPreflightHold()
        let preflight = inventory(environment, including: worktree)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                try await hold.verifyStartedSession(
                    selection: selection,
                    host: host,
                    identity: identity
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.resolveWorktreeRemoval(request)
        }
        await waitUntilMainActor { await hold.started }
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a replaced session cannot redirect removal recovery to a new host")
    func sessionChangeRecoveryRejectsChangedHostEndpoint() async throws {
        let environment = try setupRemoteEnvironment()
        var worktree = try #require(environment.snapshot.worktrees.first)
        worktree.generation = stableWorktreeGeneration
        worktree.scopedKey = worktree.path
        worktree.tmuxSessionName = "kwt-remote-feature"
        var snapshot = environment.snapshot
        snapshot.worktrees = [worktree]
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "kwt-remote-feature",
                managed: true,
                windows: [],
                serverPID: "31415",
                sessionID: "$8",
                createdAt: "1721552400"
            ),
        ]
        let hold = RemovalPreflightHold()
        let preflight = inventory(environment, including: worktree)
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { selection, _, host in
                _ = await hold.load(preflight)
                throw TmuxSessionKillError.sessionChanged(
                    host: host.displayName,
                    session: selection.name
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "27182",
                    sessionID: "$13",
                    createdAt: "1786136400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.resolveWorktreeRemoval(request)
        }
        await waitUntilMainActor { await hold.started }
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
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
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            }
        )
        let request = try await model.prepareWorktreeRemoval(worktree.id)
        let removal = Task { @MainActor in
            try await model.removeWorktree(request)
        }
        await waitUntilMainActor { await hold.started }
        #expect(await hold.started)
        model.snapshot.hosts[0].sshDestination = "replacement.example.com"
        await hold.release()

        await #expect(throws: KwtWorktreeError.removalHostChanged) {
            try await removal.value
        }
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: worktree.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a session starting after confirmation requires confirmation again")
    func newlyStartedSessionAbortsRemoval() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            branch: "main",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let beforeRemoval = fixture.beforeRemoval
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _, _ in
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
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(
            updatedRequest.sessionKillRequest?.session.name
                == "kwt-project-a-feature"
        )
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a replaced session requires a fresh removal confirmation")
    func replacedSessionRequiresFreshConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            branch: "main",
            sessionName: "kwt-project-a-feature",
            runningSession: true
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let replacementIdentity = TmuxSessionIdentity(
            serverPID: "27182",
            sessionID: "$13",
            createdAt: "1786136400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { selection, _, _ in
                kills.withLock { $0 += 1 }
                throw TmuxSessionKillError.sessionChanged(
                    host: "localhost",
                    session: selection.name
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                reads.withLock { $0 += 1 }
                return replacementIdentity
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest?.serverPID == "31415")
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Replacement should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.sessionKillRequest?.serverPID == "27182")
        #expect(updatedRequest.sessionKillRequest?.sessionID == "$13")
        #expect(
            updatedRequest.sessionKillRequest?.sessionCreatedAt
                == "1786136400"
        )
        #expect(reads.load() == 1)
        #expect(kills.load() == 1)
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a confirmed session ending requires a fresh removal confirmation")
    func endedSessionRequiresFreshConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            branch: "main",
            sessionName: "kwt-project-a-feature",
            runningSession: true
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let reads = LockedValue(0)
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { selection, _, host in
                kills.withLock { $0 += 1 }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                reads.withLock { $0 += 1 }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        #expect(request.sessionKillRequest?.serverPID == "31415")
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Ended session should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.sessionKillRequest == nil)
        #expect(reads.load() == 1)
        #expect(kills.load() == 1)
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

}
