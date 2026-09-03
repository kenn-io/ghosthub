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

    @Test("mutation publication updates every endpoint alias")
    func mutationPublicationUpdatesEveryEndpointAlias() async throws {
        let localID = UUID()
        let firstRemoteID = UUID()
        let secondRemoteID = UUID()
        let projectRecord = KwtProjectRecord(
            repository: "example/repository",
            name: "Repository",
            path: "/test/repository",
            lastTouched: nil,
            registrationFingerprint: "test-registration"
        )
        let initialInventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: projectRecord,
                worktrees: [],
                warning: nil
            ),
        ])
        let refreshedInventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: projectRecord,
                worktrees: [KwtWorktreeRecord(
                    path: "/test/repository/created",
                    branch: "feature/created",
                    commitHash: "abc123",
                    isMain: false,
                    createdAt: nil,
                    generation: "created-generation",
                    repository: projectRecord.repository,
                    sessionName: "kwt-feature-created"
                )],
                warning: nil
            ),
        ])
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
        let coordinator = WorktreeMutationCoordinator()
        let remoteLoads = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { host in
                guard host.isRemote else {
                    return KwtHostInventory(projects: [])
                }
                remoteLoads.withLock { $0 += 1 }
                return initialInventory
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let model = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: localID,
            snapshot: snapshot,
            workspaceInventoryStore: store,
            kwtInventoryLoader: { _ in refreshedInventory },
            kwtWorktreeCreator: { _, _, _ in },
            worktreeMutationCoordinator: coordinator
        )

        model.startKwtInventory()
        await waitUntilMainActor {
            model.snapshot.projects.filter {
                $0.scopedKey == projectRecord.repository
            }.count == 2
        }
        let firstProject = try #require(model.snapshot.projects.first {
            $0.hostID == firstRemoteID
        })

        try await model.createWorktree(WorktreeCreateRequest(
            projectID: firstProject.id,
            branchName: "feature/created",
            createsBranch: true
        ))

        #expect(Set(model.snapshot.worktrees.filter {
            $0.branch == "feature/created"
        }.map(\.hostID)) == [firstRemoteID, secondRemoteID])
        try await Task.sleep(for: .milliseconds(20))
        #expect(remoteLoads.load() == 1)
        await model.shutdown()
    }

    @Test("mutation publication reaches a second scene without a reload")
    func mutationPublicationReachesSecondSceneWithoutReload() async throws {
        let localID = UUID()
        let projectRecord = KwtProjectRecord(
            repository: "example/repository",
            name: "Repository",
            path: "/test/repository",
            lastTouched: nil,
            registrationFingerprint: "test-registration"
        )
        let initialInventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: projectRecord,
                worktrees: [],
                warning: nil
            ),
        ])
        let refreshedInventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: projectRecord,
                worktrees: [KwtWorktreeRecord(
                    path: "/test/repository/created",
                    branch: "feature/created",
                    commitHash: "abc123",
                    isMain: false,
                    createdAt: nil,
                    generation: "created-generation",
                    repository: projectRecord.repository,
                    sessionName: "kwt-feature-created"
                )],
                warning: nil
            ),
        ])
        let snapshot = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: localID,
                configKey: "local",
                name: "This Mac",
                kind: .selfHost,
                platform: .macOS,
                preferredTransport: .local,
                decodedConnectionState: .local
            )],
            projects: [],
            worktrees: []
        )
        let coordinator = WorktreeMutationCoordinator()
        let loads = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                loads.withLock { $0 += 1 }
                return initialInventory
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let first = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: localID,
            snapshot: snapshot,
            workspaceInventoryStore: store,
            kwtInventoryLoader: { _ in refreshedInventory },
            kwtWorktreeCreator: { _, _, _ in },
            worktreeMutationCoordinator: coordinator
        )
        let second = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: localID,
            snapshot: snapshot,
            workspaceInventoryStore: store,
            worktreeMutationCoordinator: coordinator
        )

        first.startKwtInventory()
        second.startKwtInventory()
        await waitUntilMainActor {
            first.snapshot.projects.contains {
                $0.scopedKey == projectRecord.repository
            } && second.snapshot.projects.contains {
                $0.scopedKey == projectRecord.repository
            }
        }
        #expect(loads.load() == 1)
        let project = try #require(first.snapshot.projects.first {
            $0.scopedKey == projectRecord.repository
        })

        try await first.createWorktree(WorktreeCreateRequest(
            projectID: project.id,
            branchName: "feature/created",
            createsBranch: true
        ))

        #expect(first.snapshot.worktrees.contains {
            $0.branch == "feature/created"
        })
        await waitUntilMainActor {
            second.snapshot.worktrees.contains {
                $0.branch == "feature/created"
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(loads.load() == 1)
        #expect(first.inventoryRefreshProgress.kwtCompleted)
        #expect(second.inventoryRefreshProgress.kwtCompleted)
        await first.shutdown()
        await second.shutdown()
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

    @Test("removal preflight keeps its inventory out of the shared cache")
    func removalPreflightStaysSceneLocal() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let coordinator = WorktreeMutationCoordinator()
        let newer: KwtHostInventory = {
            var inventory = fixture.beforeRemoval
            inventory.projects[0].worktrees.append(KwtWorktreeRecord(
                path: "/tmp/ghosthub-extra",
                branch: "feature/extra",
                commitHash: "abc123",
                isMain: false,
                createdAt: nil,
                generation: "extra-generation",
                repository: environment.project.scopedKey,
                sessionName: "kwt-ghosthub-extra"
            ))
            return inventory
        }()
        let removalGate = AsyncGate()
        defer { removalGate.open() }
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in newer },
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
            kwtWorktreeRemover: { _, _, _, _, _ in
                await removalGate.wait()
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
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
        first.startKwtInventory()
        second.startKwtInventory()
        await waitUntilMainActor {
            first.snapshot.worktrees.contains { $0.path == "/tmp/ghosthub-extra" }
                && second.snapshot.worktrees.contains {
                    $0.path == "/tmp/ghosthub-extra"
                }
        }

        let request = try await first.prepareWorktreeRemoval(
            fixture.removable.id
        )
        let removal = Task { try await first.removeWorktree(request) }
        await removalGate.waitUntilWaiting()

        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects[0]
                .worktrees.contains { $0.path == "/tmp/ghosthub-extra" }
                == true
        )
        #expect(second.snapshot.worktrees.contains {
            $0.path == "/tmp/ghosthub-extra"
        })

        removalGate.open()
        try await removal.value
        #expect(first.snapshot.worktree(id: fixture.removable.id) == nil)
        await first.shutdown()
        await second.shutdown()
    }

    @Test("project removal completion reloads shared inventory once")
    func projectRemovalReloadsSharedInventoryOnce() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: environment.snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let kwtLoads = LockedValue(0)
        let tmuxLoads = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                kwtLoads.withLock { $0 += 1 }
                return inventory
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                tmuxLoads.withLock { $0 += 1 }
                return .success([])
            },
            mutationCoordinator: coordinator
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            workspaceInventoryStore: store,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )
        model.startKwtInventory()
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { model.isWorkspaceInventoryRefreshComplete }
        #expect(kwtLoads.load() == 1)
        #expect(tmuxLoads.load() == 1)

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )
        #expect(result == .success(project.name))
        await waitUntilMainActor {
            kwtLoads.load() >= 2 && tmuxLoads.load() >= 2
                && model.isWorkspaceInventoryRefreshComplete
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(kwtLoads.load() == 2)
        #expect(tmuxLoads.load() == 2)
        #expect(model.snapshot.project(id: project.id) == nil)
        await model.shutdown()
    }

    @Test("re-registering a removed project clears its tombstones")
    func reregisteringRemovedProjectClearsTombstones() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        let project = try #require(fixture.snapshot.projects.first)
        let host = try #require(fixture.snapshot.hosts.first)
        let coordinator = WorktreeMutationCoordinator()
        let record = KwtProjectRecord(
            repository: project.scopedKey,
            name: project.name,
            path: project.rootPath,
            lastTouched: nil
        )
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in fixture.beforeRemoval },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            workspaceInventoryStore: store,
            kwtInventoryLoader: { _ in fixture.beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _, _ in },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRegistration: { _, _ in record },
            kwtProjectRemoval: { _, _, _, _, _ in record },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
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
        model.startKwtInventory()
        model.startTmuxSessionDiscovery()
        second.startKwtInventory()
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
                && second.snapshot.worktrees.contains {
                    $0.path == fixture.removable.path
                }
        }

        let request = try await model.prepareWorktreeRemoval(
            fixture.removable.id
        )
        try await model.removeWorktree(request)
        #expect(model.snapshot.worktree(id: fixture.removable.id) == nil)
        await waitUntilMainActor {
            !second.snapshot.worktrees.contains {
                $0.path == fixture.removable.path
            }
        }

        let removal = await model.unregisterProject(
            project,
            confirmedHost: host
        )
        #expect(removal == .success(project.name))
        await waitUntilMainActor {
            model.snapshot.project(id: project.id) == nil
        }

        let registration = await model.registerProject(
            project.rootPath,
            on: host
        )
        #expect(registration == .success(project.name))
        await waitUntilMainActor {
            model.snapshot.worktrees.contains {
                $0.path == fixture.removable.path
            }
        }
        #expect(model.snapshot.projects.contains {
            $0.scopedKey == project.scopedKey
        })
        #expect(model.snapshot.worktrees.contains {
            $0.path == fixture.removable.path
        })
        await waitUntilMainActor {
            second.snapshot.worktrees.contains {
                $0.path == fixture.removable.path
            }
        }
        #expect(second.snapshot.worktrees.contains {
            $0.path == fixture.removable.path
        })
        await model.shutdown()
        await second.shutdown()
    }

    @Test("scene-local loads honor shared removal tombstones")
    func sceneLocalLoadsHonorSharedRemovalTombstones() async throws {
        let fixture = try removalFixture()
        let environment = fixture.environment
        var other = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "/tmp/ghosthub-other",
            name: "feature/other",
            path: "/tmp/ghosthub-other",
            branch: "feature/other",
            generation: "fedcba9876543210fedcba9876543210"
        )
        other.tmuxSessionName = "kwt-ghosthub-other"
        var snapshot = fixture.snapshot
        snapshot.worktrees.append(other)
        var inventory = fixture.beforeRemoval
        inventory.projects[0].worktrees.append(KwtWorktreeRecord(
            path: other.path,
            branch: other.branch,
            commitHash: "abc123",
            isMain: false,
            createdAt: nil,
            generation: other.generation,
            repository: environment.project.scopedKey,
            sessionName: "kwt-ghosthub-other"
        ))
        let listing = inventory
        let otherPath = other.path
        let coordinator = WorktreeMutationCoordinator()
        let removalGate = AsyncGate()
        defer { removalGate.open() }
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in listing },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            workspaceInventoryStore: store,
            kwtInventoryLoader: { _ in listing },
            kwtWorktreeRemover: { path, _, _, _, _ in
                if path == otherPath {
                    await removalGate.wait()
                }
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        model.startKwtInventory()
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor { model.isWorkspaceInventoryRefreshComplete }

        let first = try await model.prepareWorktreeRemoval(
            fixture.removable.id
        )
        try await model.removeWorktree(first)
        await waitUntilMainActor {
            model.isWorkspaceInventoryRefreshComplete
                && model.snapshot.worktree(id: fixture.removable.id) == nil
        }

        let second = try await model.prepareWorktreeRemoval(other.id)
        let removal = Task { try await model.removeWorktree(second) }
        await removalGate.waitUntilWaiting()
        #expect(!model.snapshot.worktrees.contains {
            $0.path == fixture.removable.path
        })
        removalGate.open()
        try await removal.value
        #expect(!model.snapshot.worktrees.contains {
            $0.path == fixture.removable.path
        })
        await model.shutdown()
    }

    @Test("cached tombstone filtering preserves a KWT refresh failure")
    func cachedTombstoneFilteringPreservesRefreshFailure() async throws {
        enum RefreshFailure: LocalizedError {
            case failed

            var errorDescription: String? { "Inventory refresh failed" }
        }

        let fixture = try removalFixture()
        let environment = fixture.environment
        let coordinator = WorktreeMutationCoordinator()
        let postMutationLoad = AsyncGate()
        let loadCount = LockedValue(0)
        defer { postMutationLoad.open() }
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                let attempt = loadCount.load()
                loadCount.withLock { $0 += 1 }
                if attempt == 0 {
                    throw RefreshFailure.failed
                }
                await postMutationLoad.wait()
                return fixture.beforeRemoval
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        store.publishKwtInventory(
            fixture.beforeRemoval,
            on: .local,
            mutation: nil
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: fixture.snapshot,
            workspaceInventoryStore: store,
            worktreeMutationCoordinator: coordinator
        )
        model.startKwtInventory()
        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.workspaceInventoryWarningsByHost[environment.host.id]
                == "Inventory refresh failed"
        }

        #expect(coordinator.acquire(
            hostID: environment.host.id,
            projectIdentity: environment.project.scopedKey
        ))
        coordinator.release(
            hostID: environment.host.id,
            projectIdentity: environment.project.scopedKey,
            removalTombstones: [.init(
                path: fixture.removable.path,
                generation: fixture.removable.generation ?? ""
            )]
        )
        await waitUntilMainActor {
            model.snapshot.worktree(id: fixture.removable.id) == nil
        }

        #expect(
            model.workspaceInventoryWarningsByHost[environment.host.id]
                == "Inventory refresh failed"
        )
        await model.shutdown()
    }
}
