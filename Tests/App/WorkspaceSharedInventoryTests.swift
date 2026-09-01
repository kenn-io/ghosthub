import Foundation
import GhosthubPersistence
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Shared workspace inventory", .serialized)
@MainActor
struct WorkspaceSharedInventoryTests {
    @Test("endpoint aliases each receive the shared cached result")
    func endpointAliasesReceiveSharedResult() async throws {
        let localID = UUID()
        let firstRemoteID = UUID()
        let secondRemoteID = UUID()
        let project = KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "example/repository",
                name: "Repository",
                path: "/test/repository",
                lastTouched: nil,
                registrationFingerprint: "test-registration"
            ),
            worktrees: [],
            warning: nil
        )
        let remoteLoads = LockedValue(0)
        let snapshot = WorkspaceSnapshot(
            hosts: [
                HostSummary(
                    id: localID,
                    configKey: "local",
                    name: "This Mac",
                    kind: .selfHost,
                    platform: .macOS,
                    preferredTransport: .local,
                    decodedConnectionState: .local
                ),
                HostSummary(
                    id: firstRemoteID,
                    configKey: "alias-a",
                    name: "Alias A",
                    kind: .remote,
                    platform: .linux,
                    sshDestination: "test@example.invalid"
                ),
                HostSummary(
                    id: secondRemoteID,
                    configKey: "alias-b",
                    name: "Alias B",
                    kind: .remote,
                    platform: .linux,
                    sshDestination: "test@example.invalid"
                ),
            ],
            projects: [],
            worktrees: []
        )
        let store = WorkspaceInventoryStore(
            kwtLoader: { host in
                guard host.isRemote else {
                    return KwtHostInventory(projects: [])
                }
                remoteLoads.withLock { $0 += 1 }
                return KwtHostInventory(projects: [project])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let model = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: localID,
            snapshot: snapshot,
            workspaceInventoryStore: store
        )

        model.startKwtInventory()
        await waitUntilMainActor {
            Set(model.snapshot.projects.map(\.hostID))
                == [firstRemoteID, secondRemoteID]
        }

        #expect(remoteLoads.load() == 1)
        await model.shutdown()
    }

    @Test("external additions and removals converge across scenes")
    func externalChangesConvergeAcrossScenes() async throws {
        let environment = try setupStandardEnvironment()
        let secondDatabase = try WorkspaceDatabase.inMemory()
        let kwtLoads = LockedValue(0)
        let tmuxLoads = LockedValue(0)
        var worktree = environment.snapshot.worktrees[0]
        worktree.tmuxSessionName = "external-worktree"
        let populatedInventory = WorkspaceTmuxTestSupport.inventory(
            project: environment.snapshot.projects[0],
            worktrees: [worktree]
        )
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                let attempt = kwtLoads.load()
                kwtLoads.withLock { $0 += 1 }
                return attempt == 1
                    ? populatedInventory
                    : KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                let attempt = tmuxLoads.load()
                tmuxLoads.withLock { $0 += 1 }
                return .success(attempt == 1 ? [
                    DiscoveredTmuxSession(
                        name: "external-session",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ] : [])
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let emptySnapshot = WorkspaceSnapshot(
            hosts: environment.snapshot.hosts,
            projects: [],
            worktrees: []
        )
        let first = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: emptySnapshot,
            workspaceInventoryStore: store
        )
        let second = try makeModel(
            database: secondDatabase,
            localHostID: environment.host.id,
            snapshot: emptySnapshot,
            workspaceInventoryStore: store
        )
        first.startKwtInventory()
        first.startTmuxSessionDiscovery()
        second.startKwtInventory()
        second.startTmuxSessionDiscovery()
        await waitUntil {
            kwtLoads.load() == 1 && tmuxLoads.load() == 1
        }

        first.refreshKwtInventory()
        await waitUntilMainActor {
            first.snapshot.worktrees.map(\.path) == [worktree.path]
                && second.snapshot.worktrees.map(\.path) == [worktree.path]
                && first.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["external-session"]
                && second.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["external-session"]
        }
        #expect(kwtLoads.load() == 2)
        #expect(tmuxLoads.load() == 2)

        first.refreshKwtInventory()
        await waitUntilMainActor {
            first.snapshot.worktrees.isEmpty
                && second.snapshot.worktrees.isEmpty
                && first.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
                && second.snapshot.host(id: environment.host.id)?
                .tmuxSessions.isEmpty == true
        }
        #expect(kwtLoads.load() == 3)
        #expect(tmuxLoads.load() == 3)

        await first.shutdown()
        await second.shutdown()
    }

    @Test("two scenes share live loads and a later scene reuses the cache")
    func scenesShareLiveAndCachedInventory() async throws {
        let environment = try setupStandardEnvironment()
        let secondDatabase = try WorkspaceDatabase.inMemory()
        let thirdDatabase = try WorkspaceDatabase.inMemory()
        let kwtLoads = LockedValue(0)
        let tmuxLoads = LockedValue(0)
        var worktree = environment.snapshot.worktrees[0]
        worktree.tmuxSessionName = "worktree-session"
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: environment.snapshot.projects[0],
            worktrees: [worktree]
        )
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                kwtLoads.withLock { $0 += 1 }
                return inventory
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                tmuxLoads.withLock { $0 += 1 }
                return .success([DiscoveredTmuxSession(
                    name: "external-session",
                    windowCount: 2,
                    createdAt: "1721552400",
                    managed: false
                )])
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let emptySnapshot = WorkspaceSnapshot(
            hosts: environment.snapshot.hosts,
            projects: [],
            worktrees: []
        )
        let first = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: emptySnapshot,
            workspaceInventoryStore: store
        )
        let second = try makeModel(
            database: secondDatabase,
            localHostID: environment.host.id,
            snapshot: emptySnapshot,
            workspaceInventoryStore: store
        )

        first.startKwtInventory()
        first.startTmuxSessionDiscovery()
        second.startKwtInventory()
        second.startTmuxSessionDiscovery()

        await waitUntilMainActor {
            first.snapshot.worktrees.map(\.path) == [worktree.path]
                && second.snapshot.worktrees.map(\.path) == [worktree.path]
                && first.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name)
                == ["external-session"]
                && second.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name)
                == ["external-session"]
                && first.isWorkspaceInventoryRefreshComplete
                && second.isWorkspaceInventoryRefreshComplete
        }
        #expect(kwtLoads.load() == 1)
        #expect(tmuxLoads.load() == 1)

        let third = try makeModel(
            database: thirdDatabase,
            localHostID: environment.host.id,
            snapshot: emptySnapshot,
            workspaceInventoryStore: store
        )
        third.startKwtInventory()
        third.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            third.snapshot.worktrees.map(\.path) == [worktree.path]
                && third.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name)
                == ["external-session"]
                && third.isWorkspaceInventoryRefreshComplete
        }
        #expect(kwtLoads.load() == 1)
        #expect(tmuxLoads.load() == 1)

        await first.shutdown()
        await second.shutdown()
        await third.shutdown()
    }

    @Test("removed worktrees stay excluded for a later scene")
    func removedWorktreeStaysExcludedForLaterScene() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let coordinator = WorktreeMutationCoordinator()
        let sharedLoads = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                sharedLoads.withLock { $0 += 1 }
                return fixture.beforeRemoval
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let first = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            workspaceInventoryStore: store,
            kwtInventoryLoader: { _ in fixture.beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _, _ in },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let request = try await first.prepareWorktreeRemoval(
            fixture.removable.id
        )
        try await first.removeWorktree(request)
        #expect(first.snapshot.worktree(id: fixture.removable.id) == nil)

        let second = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: environment.host.id,
            snapshot: WorkspaceSnapshot(
                hosts: fixture.snapshot.hosts,
                projects: [],
                worktrees: []
            ),
            workspaceInventoryStore: store,
            worktreeMutationCoordinator: coordinator
        )
        second.startKwtInventory()
        await waitUntilMainActor {
            !second.snapshot.projects.isEmpty
        }

        #expect(second.snapshot.worktrees.contains {
            $0.path == fixture.removable.path
        } == false)
        #expect(sharedLoads.load() == 0)
        await first.shutdown()
        await second.shutdown()
    }
}
