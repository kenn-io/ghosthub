import AppKit
import Foundation
import GhosthubSettings
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("Workspace inventory store", .serialized)
@MainActor
struct WorkspaceInventoryStoreTests {
    @Test("starting a KWT refresh revokes cached freshness")
    func startingKwtRefreshRevokesFreshness() async {
        let loadGate = AsyncGate()
        let cadenceGate = AsyncGate()
        let sleepCount = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                await loadGate.wait()
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            sleep: { _ in
                let attempt = sleepCount.load()
                sleepCount.withLock { $0 += 1 }
                if attempt == 0 {
                    await cadenceGate.wait()
                } else {
                    try await Task.sleep(for: .seconds(3_600))
                }
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let subscriberID = UUID()
        defer {
            loadGate.open()
            store.removeSubscriber(id: subscriberID)
        }
        store.publishKwtInventory(
            KwtHostInventory(projects: []),
            on: .local,
            mutation: nil
        )
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )

        await cadenceGate.waitUntilWaiting()
        cadenceGate.open()
        await waitUntilMainActor {
            guard let entry = store.snapshot.kwtByHost[.local] else {
                return false
            }
            if case .loading = entry.state {
                return true
            }
            return false
        }

        guard let entry = store.snapshot.kwtByHost[.local] else {
            Issue.record("Expected cached KWT inventory")
            return
        }
        guard case .loading = entry.state else {
            Issue.record("Expected a loading KWT entry")
            return
        }
        #expect(entry.isFresh == false)
    }

    @Test("application activity monitoring refreshes once on reactivation")
    func applicationActivityMonitoringIsProcessWide() async throws {
        let center = NotificationCenter()
        let kwtCount = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                kwtCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        store.startApplicationActivityMonitoring(
            center: center,
            initialIsActive: false
        )
        store.startApplicationActivityMonitoring(
            center: center,
            initialIsActive: false
        )
        store.updateSubscriber(
            id: UUID(),
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(kwtCount.load() == 0)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { kwtCount.load() == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(kwtCount.load() == 1)
    }

    @Test("cadence pauses inactive and refreshes once on reactivation")
    func cadenceFollowsApplicationActivity() async throws {
        let kwtCount = LockedValue(0)
        let tmuxCount = LockedValue(0)
        let sleepDurations = LockedValue<[Duration]>([])
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                kwtCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                tmuxCount.withLock { $0 += 1 }
                return .success([])
            },
            sleep: { duration in
                sleepDurations.withLock { $0.append(duration) }
                try await Task.sleep(for: .seconds(3_600))
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let subscriberID = UUID()
        store.setApplicationActive(false)
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: true
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(kwtCount.load() == 0)
        #expect(tmuxCount.load() == 0)

        store.setApplicationActive(true)
        await waitUntil {
            kwtCount.load() == 1 && tmuxCount.load() == 1
                && sleepDurations.load() == [.seconds(30)]
        }

        store.setApplicationActive(false)
        store.setApplicationActive(true)
        await waitUntil {
            kwtCount.load() == 2 && tmuxCount.load() == 2
                && sleepDurations.load().count == 2
        }
    }

    @Test("reactivation replaces loads started before inactivity")
    func reactivationReplacesInFlightLoads() async {
        let staleKwt = KwtHostInventory(
            projects: [],
            projectsWarning: "stale"
        )
        let freshKwt = KwtHostInventory(projects: [])
        let staleTmux = DiscoveredTmuxSession(
            name: "stale",
            windowCount: 1,
            createdAt: nil,
            managed: false
        )
        let kwtCount = LockedValue(0)
        let tmuxCount = LockedValue(0)
        let firstKwtLoad = AsyncGate()
        let firstTmuxLoad = AsyncGate()
        defer {
            firstKwtLoad.open()
            firstTmuxLoad.open()
        }
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                let attempt = kwtCount.load()
                kwtCount.withLock { $0 += 1 }
                if attempt == 0 {
                    await firstKwtLoad.wait()
                    return staleKwt
                }
                return freshKwt
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                let attempt = tmuxCount.load()
                tmuxCount.withLock { $0 += 1 }
                if attempt == 0 {
                    await firstTmuxLoad.wait()
                    return .success([staleTmux])
                }
                return .success([])
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        store.updateSubscriber(
            id: UUID(),
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: true
        )
        await waitUntil {
            kwtCount.load() == 1 && tmuxCount.load() == 1
        }

        store.setApplicationActive(false)
        store.setApplicationActive(true)

        await waitUntil {
            kwtCount.load() == 2 && tmuxCount.load() == 2
        }
        #expect(store.snapshot.kwtByHost[.local]?.inventory == freshKwt)
        #expect(store.snapshot.tmuxByHost[.local]?.sessions == [])
    }

    @Test("remote KWT loads provision the configured host once")
    func remoteLoadsProvisionOnce() async {
        let events = LockedValue<[String]>([])
        let commandHost = CommandHost.ssh(.init(
            user: "test",
            hostname: "example.invalid",
            port: nil,
            platform: .posix
        ))
        let configuredHost = SSHHost(
            configKey: "test-linux",
            name: "Test Linux",
            platform: .linux,
            sshDestination: "test@example.invalid"
        )
        let store = WorkspaceInventoryStore(
            kwtLoader: { host in
                #expect(host == commandHost)
                events.withLock { $0.append("load") }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { host in
                #expect(host == configuredHost)
                events.withLock { $0.append("provision") }
            },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let registrations = [
            WorkspaceInventoryStore.HostRegistration(
                hostID: UUID(),
                commandHost: commandHost,
                provisioningHost: configuredHost
            ),
            WorkspaceInventoryStore.HostRegistration(
                hostID: UUID(),
                commandHost: commandHost,
                provisioningHost: configuredHost
            ),
        ]

        store.updateSubscriber(
            id: UUID(),
            registrations: registrations,
            wantsKwt: true,
            wantsTmux: false
        )

        await waitUntil { events.load().count == 2 }
        #expect(events.load() == ["provision", "load"])
    }

    @Test("provisioning failure leaves KWT unread and tmux independent")
    func provisioningFailureDoesNotBlockTmux() async {
        enum ProvisioningFailure: Error {
            case failed
        }
        let kwtCount = LockedValue(0)
        let tmuxCount = LockedValue(0)
        let commandHost = CommandHost.ssh(.init(
            user: "test",
            hostname: "example.invalid",
            port: nil,
            platform: .posix
        ))
        let configuredHost = SSHHost(
            configKey: "test-linux",
            name: "Test Linux",
            platform: .linux,
            sshDestination: "test@example.invalid"
        )
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                kwtCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in throw ProvisioningFailure.failed },
            tmuxLoader: { _ in
                tmuxCount.withLock { $0 += 1 }
                return .success([])
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )

        store.updateSubscriber(
            id: UUID(),
            registrations: [.init(
                hostID: UUID(),
                commandHost: commandHost,
                provisioningHost: configuredHost
            )],
            wantsKwt: true,
            wantsTmux: true
        )

        await waitUntilMainActor {
            guard let kwt = store.snapshot.kwtByHost[commandHost],
                  let tmux = store.snapshot.tmuxByHost[commandHost],
                  case .provisioningFailed = kwt.state
            else { return false }
            return tmux.isFresh
        }
        #expect(kwtCount.load() == 0)
        #expect(tmuxCount.load() == 1)
        #expect(store.snapshot.kwtByHost[commandHost]?.isFresh == false)
    }

    @Test("late results from a replaced endpoint are rejected")
    func replacementRejectsLateResult() async throws {
        let oldHost = CommandHost.ssh(.init(
            user: "test",
            hostname: "old.invalid",
            port: nil,
            platform: .posix
        ))
        let newHost = CommandHost.ssh(.init(
            user: "test",
            hostname: "new.invalid",
            port: nil,
            platform: .posix
        ))
        let oldGate = AsyncGate()
        let oldCount = LockedValue(0)
        let newCount = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { host in
                if host == oldHost {
                    oldCount.withLock { $0 += 1 }
                    await oldGate.wait()
                } else {
                    #expect(host == newHost)
                    newCount.withLock { $0 += 1 }
                }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let subscriberID = UUID()
        let hostID = UUID()
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: oldHost,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        await waitUntil { oldCount.load() == 1 }

        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: newHost,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        await waitUntilMainActor {
            store.snapshot.kwtByHost[newHost]?.isFresh == true
        }
        oldGate.open()
        try await Task.sleep(for: .milliseconds(20))

        #expect(oldCount.load() == 1)
        #expect(newCount.load() == 1)
        #expect(store.snapshot.kwtByHost[oldHost]?.inventory == nil)
    }

    @Test("mutation scopes fence commands until one reconciliation load")
    func mutationScopesFenceCommands() async throws {
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let projectIdentity = "example/repository"
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: projectIdentity
        ))
        store.updateSubscriber(
            id: UUID(),
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(loadCount.load() == 0)

        coordinator.release(
            hostID: hostID,
            projectIdentity: projectIdentity
        )

        await waitUntil { loadCount.load() == 1 }
    }

    @Test("project removal cancels an old load and reconciles once")
    func projectRemovalCancelsOldLoad() async throws {
        let coordinator = WorktreeMutationCoordinator()
        let firstLoad = AsyncGate()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let projectIdentity = "example/repository"
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                let count = loadCount.load()
                if count == 1 {
                    await firstLoad.wait()
                }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        await waitUntil { loadCount.load() == 1 }

        #expect(coordinator.acquireProjectRemoval(
            hostID: hostID,
            projectIdentity: projectIdentity,
            registryHost: .init(target: .local)
        ))
        store.refreshKwt(for: subscriberID)
        firstLoad.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(loadCount.load() == 1)

        coordinator.release(
            hostID: hostID,
            projectIdentity: projectIdentity,
            removesProject: true
        )
        await waitUntilMainActor {
            loadCount.load() == 2
                && store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        #expect(loadCount.load() == 2)
    }

    @Test("authoritative mutation publication satisfies fence-end refresh")
    func publicationSatisfiesFenceEndRefresh() async throws {
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let projectIdentity = "example/repository"
        let project = KwtProjectRecord(
            repository: projectIdentity,
            name: "Repository",
            path: "/test/repository",
            lastTouched: nil,
            registrationFingerprint: "test-registration"
        )
        let registered = KwtHostInventory(projects: [KwtProjectInventory(
            project: project,
            worktrees: [],
            warning: nil
        )])
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: projectIdentity
        ))
        store.updateSubscriber(
            id: UUID(),
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        store.publishKwtInventory(
            KwtHostInventory(projects: []),
            on: .local,
            mutation: .init(
                hostID: hostID,
                host: .local,
                epoch: store.kwtMutationEpoch(on: .local)
            )
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: projectIdentity,
            removesProject: true
        )

        try await Task.sleep(for: .milliseconds(20))
        #expect(loadCount.load() == 0)
        #expect(store.snapshot.kwtByHost[.local]?.isFresh == true)

        store.publishKwtInventory(
            registered,
            on: .local,
            mutation: nil
        )
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects
                == registered.projects
        )
    }

    @Test("removal exclusions survive stale refreshes until confirmed absent")
    func removalExclusionsSurviveStaleRefreshes() async {
        let repository = "example/repository"
        let worktree = KwtWorktreeRecord(
            path: "/test/repository/removed",
            branch: "feature/removed",
            commitHash: "abc123",
            isMain: false,
            createdAt: nil,
            generation: "removed-generation",
            repository: repository,
            sessionName: "kwt-feature-removed"
        )
        let project = KwtProjectRecord(
            repository: repository,
            name: "Repository",
            path: "/test/repository",
            lastTouched: nil,
            registrationFingerprint: "test-registration"
        )
        let containing = KwtHostInventory(projects: [KwtProjectInventory(
            project: project,
            worktrees: [worktree],
            warning: nil
        )])
        let absent = KwtHostInventory(projects: [KwtProjectInventory(
            project: project,
            worktrees: [],
            warning: nil
        )])
        let loadCount = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                let count = loadCount.load()
                return count == 2 ? absent : containing
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let identity = KwtWorktreeIdentity(
            path: worktree.path,
            generation: worktree.generation ?? ""
        )
        store.publishKwtInventory(
            containing,
            on: .local,
            excludingWorktrees: [repository: [identity]],
            mutation: nil
        )
        let subscriberID = UUID()
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 1
                && store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees.isEmpty == true
        }

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 2
                && store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees.isEmpty == true
        }

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 3
                && store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees.count == 1
        }
    }

    @Test("mutation-end tombstones survive stale refreshes")
    func mutationEndTombstonesSurviveStaleRefreshes() async {
        enum RefreshFailure: Error {
            case failed
        }
        let repository = "example/repository"
        let worktree = KwtWorktreeRecord(
            path: "/test/repository/removed",
            branch: "feature/removed",
            commitHash: "abc123",
            isMain: false,
            createdAt: nil,
            generation: "removed-generation",
            repository: repository,
            sessionName: "kwt-feature-removed"
        )
        let project = KwtProjectRecord(
            repository: repository,
            name: "Repository",
            path: "/test/repository",
            lastTouched: nil,
            registrationFingerprint: "test-registration"
        )
        let containing = KwtHostInventory(projects: [KwtProjectInventory(
            project: project,
            worktrees: [worktree],
            warning: nil
        )])
        let absent = KwtHostInventory(projects: [KwtProjectInventory(
            project: project,
            worktrees: [],
            warning: nil
        )])
        let coordinator = WorktreeMutationCoordinator()
        let firstLoad = AsyncGate()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                switch loadCount.load() {
                case 1:
                    await firstLoad.wait()
                    throw RefreshFailure.failed
                case 2:
                    return absent
                default:
                    return containing
                }
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let identity = KwtWorktreeIdentity(
            path: worktree.path,
            generation: worktree.generation ?? ""
        )
        store.publishKwtInventory(
            containing,
            on: .local,
            mutation: nil
        )
        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: repository
        ))
        let subscriberID = UUID()
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )

        coordinator.release(
            hostID: hostID,
            projectIdentity: repository,
            removalTombstones: [identity]
        )
        await waitUntil { loadCount.load() == 1 }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees.isEmpty == true
        )

        firstLoad.open()
        await waitUntilMainActor {
            guard let entry = store.snapshot.kwtByHost[.local] else {
                return false
            }
            guard case .failed = entry.state else { return false }
            return true
        }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees.isEmpty == true
        )

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 2
                && store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees.isEmpty == true
        }

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 3
                && store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees == [worktree]
        }
    }

    @Test("project mutation-end tombstones survive stale refreshes")
    func projectMutationEndTombstonesSurviveStaleRefreshes() async {
        let repository = "example/repository"
        let worktree = KwtWorktreeRecord(
            path: "/test/repository/main",
            branch: "main",
            commitHash: "abc123",
            isMain: true,
            createdAt: nil,
            generation: "main-generation",
            repository: repository,
            sessionName: "kwt-main"
        )
        let project = KwtProjectRecord(
            repository: repository,
            name: "Repository",
            path: "/test/repository",
            lastTouched: nil,
            registrationFingerprint: "test-registration"
        )
        let containing = KwtHostInventory(projects: [KwtProjectInventory(
            project: project,
            worktrees: [worktree],
            warning: nil
        )])
        let absent = KwtHostInventory(projects: [])
        let coordinator = WorktreeMutationCoordinator()
        let firstLoad = AsyncGate()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                if loadCount.load() == 1 {
                    await firstLoad.wait()
                }
                return loadCount.load() == 2 ? absent : containing
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        store.publishKwtInventory(
            containing,
            on: .local,
            mutation: nil
        )
        #expect(coordinator.acquireProjectRemoval(
            hostID: hostID,
            projectIdentity: repository,
            registryHost: .init(target: .local)
        ))
        let subscriberID = UUID()
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )

        coordinator.release(
            hostID: hostID,
            projectIdentity: repository,
            removesProject: true
        )
        await waitUntil { loadCount.load() == 1 }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?
                .projects.isEmpty == true
        )
        firstLoad.open()
        await waitUntilMainActor {
            loadCount.load() == 1
                && store.snapshot.kwtByHost[.local]?.inventory?
                .projects.isEmpty == true
        }

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 2
                && store.snapshot.kwtByHost[.local]?.inventory?
                .projects.isEmpty == true
        }

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 3
                && store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first == containing.projects.first
        }
    }

    @Test("concurrent mutations preserve one fence-end reconciliation load")
    func concurrentMutationsPreserveFenceEndRefresh() async {
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: "example/first"
        ))
        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: "example/second"
        ))
        store.updateSubscriber(
            id: UUID(),
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        store.publishKwtInventory(
            KwtHostInventory(projects: []),
            on: .local,
            mutation: .init(
                hostID: hostID,
                host: .local,
                epoch: store.kwtMutationEpoch(on: .local)
            )
        )

        coordinator.release(
            hostID: hostID,
            projectIdentity: "example/first"
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: "example/second"
        )

        await waitUntilMainActor {
            loadCount.load() == 1
        }
        #expect(loadCount.load() == 1)
    }

    @Test("explicit refresh replaces in-flight loads")
    func explicitRefreshReplacesInFlightLoads() async throws {
        let staleKwt = KwtHostInventory(
            projects: [],
            projectsWarning: "stale"
        )
        let freshKwt = KwtHostInventory(projects: [])
        let staleTmux = DiscoveredTmuxSession(
            name: "stale",
            windowCount: 1,
            createdAt: nil,
            managed: false
        )
        let kwtCount = LockedValue(0)
        let tmuxCount = LockedValue(0)
        let firstKwtLoad = AsyncGate()
        let firstTmuxLoad = AsyncGate()
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                let attempt = kwtCount.load()
                kwtCount.withLock { $0 += 1 }
                if attempt == 0 {
                    await firstKwtLoad.wait()
                    return staleKwt
                }
                return freshKwt
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                let attempt = tmuxCount.load()
                tmuxCount.withLock { $0 += 1 }
                if attempt == 0 {
                    await firstTmuxLoad.wait()
                    return .success([staleTmux])
                }
                return .success([])
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let subscriberID = UUID()
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: true
        )
        await waitUntil {
            kwtCount.load() == 1 && tmuxCount.load() == 1
        }

        store.refreshAll(for: subscriberID)
        await waitUntilMainActor {
            kwtCount.load() == 2 && tmuxCount.load() == 2
        }
        firstKwtLoad.open()
        firstTmuxLoad.open()

        await waitUntilMainActor {
            store.snapshot.kwtByHost[.local]?.inventory == freshKwt
                && store.snapshot.tmuxByHost[.local]?.sessions == []
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.snapshot.kwtByHost[.local]?.inventory == freshKwt)
        #expect(store.snapshot.tmuxByHost[.local]?.sessions == [])
    }

    @Test("subscribers for one endpoint share one load per lane")
    func subscribersShareLoads() async throws {
        let kwtCount = LockedValue(0)
        let tmuxCount = LockedValue(0)
        let kwtGate = AsyncGate()
        let tmuxGate = AsyncGate()
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                kwtCount.withLock { $0 += 1 }
                await kwtGate.wait()
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                tmuxCount.withLock { $0 += 1 }
                await tmuxGate.wait()
                return .success([])
            },
            sleep: { duration in
                try await Task.sleep(for: duration)
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let registration = WorkspaceInventoryStore.HostRegistration(
            hostID: UUID(),
            commandHost: .local,
            provisioningHost: nil
        )

        store.updateSubscriber(
            id: UUID(),
            registrations: [registration],
            wantsKwt: true,
            wantsTmux: true
        )
        store.updateSubscriber(
            id: UUID(),
            registrations: [registration],
            wantsKwt: true,
            wantsTmux: true
        )

        await waitUntil {
            kwtCount.load() == 1 && tmuxCount.load() == 1
        }
        kwtGate.open()
        tmuxGate.open()
        await waitUntilMainActor {
            store.snapshot.kwtByHost[.local]?.isFresh == true
                && store.snapshot.tmuxByHost[.local]?.isFresh == true
        }

        store.updateSubscriber(
            id: UUID(),
            registrations: [registration],
            wantsKwt: true,
            wantsTmux: true
        )
        try await Task.sleep(for: .milliseconds(20))

        #expect(kwtCount.load() == 1)
        #expect(tmuxCount.load() == 1)
    }

    @Test("a new subscriber restarts loads cancelled with the last subscriber")
    func cancelledLastSubscriberLoadsRestart() async {
        let kwtCount = LockedValue(0)
        let tmuxCount = LockedValue(0)
        let kwtGate = AsyncGate()
        let tmuxGate = AsyncGate()
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                kwtCount.withLock { $0 += 1 }
                await kwtGate.wait()
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                tmuxCount.withLock { $0 += 1 }
                await tmuxGate.wait()
                return .success([])
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let registration = WorkspaceInventoryStore.HostRegistration(
            hostID: UUID(),
            commandHost: .local,
            provisioningHost: nil
        )
        let firstSubscriberID = UUID()
        store.updateSubscriber(
            id: firstSubscriberID,
            registrations: [registration],
            wantsKwt: true,
            wantsTmux: true
        )
        await waitUntil {
            kwtCount.load() == 1 && tmuxCount.load() == 1
        }

        store.removeSubscriber(id: firstSubscriberID)
        store.updateSubscriber(
            id: UUID(),
            registrations: [registration],
            wantsKwt: true,
            wantsTmux: true
        )

        await waitUntil(timeout: .seconds(1)) {
            kwtCount.load() == 2 && tmuxCount.load() == 2
        }
        kwtGate.open()
        tmuxGate.open()
    }

    @Test("a new subscriber refreshes completed and failed cache entries")
    func newSubscriberRefreshesInactiveCache() async {
        let kwtCount = LockedValue(0)
        let tmuxCount = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                kwtCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                let attempt = tmuxCount.load()
                tmuxCount.withLock { $0 += 1 }
                return attempt == 0
                    ? .failure(.notFound(shell: "test"))
                    : .success([])
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let registration = WorkspaceInventoryStore.HostRegistration(
            hostID: UUID(),
            commandHost: .local,
            provisioningHost: nil
        )
        let firstSubscriberID = UUID()
        store.updateSubscriber(
            id: firstSubscriberID,
            registrations: [registration],
            wantsKwt: true,
            wantsTmux: true
        )
        await waitUntilMainActor {
            guard store.snapshot.kwtByHost[.local]?.isFresh == true,
                  let tmux = store.snapshot.tmuxByHost[.local]
            else { return false }
            guard case .failed = tmux.state else { return false }
            return true
        }

        store.removeSubscriber(id: firstSubscriberID)
        store.updateSubscriber(
            id: UUID(),
            registrations: [registration],
            wantsKwt: true,
            wantsTmux: true
        )
        await waitUntilMainActor {
            kwtCount.load() == 2 && tmuxCount.load() == 2
        }

        #expect(kwtCount.load() == 2)
        #expect(tmuxCount.load() == 2)
    }

    @Test("partial project failure stays merged in the shared cache")
    func partialProjectFailureRetainsSharedWorktrees() async {
        let project = KwtProjectRecord(
            repository: "example/repository",
            name: "Repository",
            path: "/test/repository",
            lastTouched: nil,
            registrationFingerprint: "test-registration"
        )
        let retained = KwtWorktreeRecord(
            path: "/test/repository-retained",
            branch: "feature/retained",
            commitHash: "retained",
            isMain: false,
            createdAt: nil,
            generation: "11111111111111111111111111111111",
            repository: project.repository,
            sessionName: "retained",
            tmuxSocketName: nil
        )
        let refreshed = KwtWorktreeRecord(
            path: "/test/repository-refreshed",
            branch: "feature/refreshed",
            commitHash: "refreshed",
            isMain: false,
            createdAt: nil,
            generation: "22222222222222222222222222222222",
            repository: project.repository,
            sessionName: "refreshed",
            tmuxSocketName: nil
        )
        let complete = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [retained, refreshed],
                warning: nil
            ),
        ])
        let partial = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [refreshed],
                warning: "inventory unavailable"
            ),
        ])
        let loadCount = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                let attempt = loadCount.load()
                loadCount.withLock { $0 += 1 }
                return attempt == 0 ? complete : partial
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let subscriberID = UUID()
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        await waitUntilMainActor {
            store.snapshot.kwtByHost[.local]?.inventory == complete
        }

        store.refreshKwt(for: subscriberID)

        await waitUntilMainActor {
            loadCount.load() == 2
                && store.snapshot.kwtByHost[.local]?.inventoryRevision != 1
        }
        #expect(Set(
            store.snapshot.kwtByHost[.local]?.inventory?.projects
                .first?.worktrees.map(\.path) ?? []
        ) == [retained.path, refreshed.path])
    }

    @Test("a failed refresh retains cached rows and revokes freshness")
    func failureRetainsCache() async {
        enum RefreshFailure: Error {
            case failed
        }
        let kwtCount = LockedValue(0)
        let store = WorkspaceInventoryStore(
            kwtLoader: { _ in
                let attempt = kwtCount.load()
                kwtCount.withLock { $0 += 1 }
                if attempt == 0 {
                    return KwtHostInventory(projects: [])
                }
                throw RefreshFailure.failed
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let subscriberID = UUID()
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        await waitUntilMainActor {
            store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        let cachedRevision = store.snapshot.kwtByHost[.local]?
            .inventoryRevision

        store.refreshKwt(for: subscriberID)

        await waitUntilMainActor {
            guard let entry = store.snapshot.kwtByHost[.local] else {
                return false
            }
            guard case .failed = entry.state else { return false }
            return true
        }
        guard let entry = store.snapshot.kwtByHost[.local] else {
            Issue.record("KWT refresh did not publish a terminal entry")
            return
        }
        #expect(entry.inventory != nil)
        #expect(entry.inventoryRevision == cachedRevision)
        #expect(entry.isFresh == false)
    }

    @Test("stale scene probe publication yields to a newer shared refresh")
    func staleProbePublicationYieldsToNewerRefresh() async throws {
        let firstLoad = AsyncGate()
        let secondLoad = AsyncGate()
        let loadCount = LockedValue(0)
        let fresh = DiscoveredTmuxSession(
            name: "fresh",
            windowCount: 1,
            createdAt: nil,
            managed: false
        )
        let probed = DiscoveredTmuxSession(
            name: "probed",
            windowCount: 1,
            createdAt: nil,
            managed: false
        )
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in KwtHostInventory(projects: []) },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                let attempt = loadCount.load()
                loadCount.withLock { $0 += 1 }
                if attempt == 0 {
                    await firstLoad.wait()
                } else {
                    await secondLoad.wait()
                }
                return .success([fresh])
            },
            mutationCoordinator: WorktreeMutationCoordinator()
        )
        let subscriberID = UUID()
        defer {
            firstLoad.open()
            secondLoad.open()
            store.removeSubscriber(id: subscriberID)
        }

        let staleEpoch = store.tmuxRefreshEpoch(on: .local)
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: UUID(),
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: false,
            wantsTmux: true
        )
        store.publishTmuxSessions([probed], on: .local, epoch: staleEpoch)
        #expect(store.snapshot.tmuxByHost[.local]?.sessions == nil)

        firstLoad.open()
        await waitUntilMainActor {
            store.snapshot.tmuxByHost[.local]?.sessions == [fresh]
        }
        #expect(store.snapshot.tmuxByHost[.local]?.isFresh == true)

        store.refreshTmux(for: subscriberID)
        let currentEpoch = store.tmuxRefreshEpoch(on: .local)
        await secondLoad.waitUntilWaiting()
        store.publishTmuxSessions([probed], on: .local, epoch: currentEpoch)
        #expect(store.snapshot.tmuxByHost[.local]?.sessions == [probed])
        #expect(store.snapshot.tmuxByHost[.local]?.isFresh == true)

        secondLoad.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.snapshot.tmuxByHost[.local]?.sessions == [probed])
    }

    @Test("mutation end replaces in-flight shared tmux inventory")
    func mutationEndReplacesInFlightTmux() async throws {
        let coordinator = WorktreeMutationCoordinator()
        let firstLoad = AsyncGate()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let stale = DiscoveredTmuxSession(
            name: "stale",
            windowCount: 1,
            createdAt: nil,
            managed: false
        )
        let fresh = DiscoveredTmuxSession(
            name: "fresh",
            windowCount: 1,
            createdAt: nil,
            managed: false
        )
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in KwtHostInventory(projects: []) },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in
                let attempt = loadCount.load()
                loadCount.withLock { $0 += 1 }
                guard attempt == 0 else { return .success([fresh]) }
                await firstLoad.wait()
                return .success([stale])
            },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer {
            firstLoad.open()
            store.removeSubscriber(id: subscriberID)
        }
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: true
        )
        await firstLoad.waitUntilWaiting()

        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: "example/repository"
        ))
        store.publishKwtInventory(
            KwtHostInventory(projects: []),
            on: .local,
            mutation: .init(
                hostID: hostID,
                host: .local,
                epoch: store.kwtMutationEpoch(on: .local)
            )
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: "example/repository"
        )
        firstLoad.open()

        await waitUntilMainActor {
            store.snapshot.tmuxByHost[.local]?.sessions == [fresh]
        }
        #expect(loadCount.load() == 2)
        #expect(store.snapshot.tmuxByHost[.local]?.isFresh == true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.snapshot.tmuxByHost[.local]?.sessions == [fresh])
    }

    @Test("stale mutation publication yields to a newer mutation")
    func staleMutationPublicationYieldsToNewerMutation() async {
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let project = KwtProjectRecord(
            repository: "example/repository",
            name: "Repository",
            path: "/test/repository",
            lastTouched: nil,
            registrationFingerprint: "test-registration"
        )
        let registered = KwtHostInventory(projects: [KwtProjectInventory(
            project: project,
            worktrees: [],
            warning: nil
        )])
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer { store.removeSubscriber(id: subscriberID) }
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        await waitUntilMainActor {
            store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        #expect(loadCount.load() == 1)

        #expect(coordinator.acquire(hostID: hostID, projectIdentity: "x"))
        let staleEpoch = store.kwtMutationEpoch(on: .local)
        #expect(coordinator.acquire(hostID: hostID, projectIdentity: "y"))
        let currentEpoch = store.kwtMutationEpoch(on: .local)
        #expect(staleEpoch != currentEpoch)

        store.publishKwtInventory(
            registered,
            on: .local,
            mutation: .init(hostID: hostID, host: .local, epoch: currentEpoch)
        )
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects
                == registered.projects
        )
        store.publishKwtInventory(
            KwtHostInventory(projects: []),
            on: .local,
            mutation: .init(hostID: hostID, host: .local, epoch: staleEpoch)
        )
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects
                == registered.projects
        )

        coordinator.release(hostID: hostID, projectIdentity: "y")
        coordinator.release(hostID: hostID, projectIdentity: "x")
        await waitUntilMainActor { loadCount.load() == 2 }
        #expect(loadCount.load() == 2)
    }

    @Test("warning-bearing publication leaves the fence-end refresh pending")
    func warningPublicationLeavesFenceEndRefreshPending() async {
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer { store.removeSubscriber(id: subscriberID) }
        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: "example/repository"
        ))
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        store.publishKwtInventory(
            KwtHostInventory(
                projects: [],
                projectsWarning: "kwt list failed"
            ),
            on: .local,
            mutation: .init(
                hostID: hostID,
                host: .local,
                epoch: store.kwtMutationEpoch(on: .local)
            )
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: "example/repository"
        )

        await waitUntilMainActor { loadCount.load() == 1 }
        #expect(loadCount.load() == 1)
    }

    @Test("legacy-empty repository identity keeps removed worktrees hidden")
    func legacyEmptyIdentityKeepsRemovedWorktreesHidden() async {
        let repository = "example/repository"
        let worktree = KwtWorktreeRecord(
            path: "/test/repository/removed",
            branch: "feature/removed",
            commitHash: "abc123",
            isMain: false,
            createdAt: nil,
            generation: "removed-generation",
            repository: "",
            sessionName: "kwt-feature-removed"
        )
        let legacy = KwtHostInventory(projects: [KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "",
                name: "Repository",
                path: "/test/repository",
                lastTouched: nil,
                registrationFingerprint: "test-registration"
            ),
            worktrees: [worktree],
            warning: nil
        )])
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return legacy
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer { store.removeSubscriber(id: subscriberID) }
        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: repository
        ))
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: repository,
            removalTombstones: [KwtWorktreeIdentity(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )]
        )
        await waitUntilMainActor {
            loadCount.load() == 1
                && store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees.isEmpty == true
        )

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 2
                && store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?
                .projects.first?.worktrees.isEmpty == true
        )
    }

    @Test(
        "registration during a mutation forces the fence-end reload",
        arguments: [true, false]
    )
    func registrationDuringMutationForcesReload(
        publishesBeforeRegistration: Bool
    ) async {
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return KwtHostInventory(projects: [])
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer { store.removeSubscriber(id: subscriberID) }
        #expect(coordinator.acquire(hostID: hostID, projectIdentity: "x"))
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        let mutation = WorkspaceInventoryStore.MutationPublication(
            hostID: hostID,
            host: .local,
            epoch: store.kwtMutationEpoch(on: .local)
        )
        let publish = {
            store.publishKwtInventory(
                KwtHostInventory(projects: []),
                on: .local,
                mutation: mutation
            )
        }
        if publishesBeforeRegistration {
            publish()
        }
        coordinator.noteProjectRegistration(
            hostID: hostID,
            projectIdentity: "y",
            projectPath: "/test/y"
        )
        if !publishesBeforeRegistration {
            publish()
        }
        coordinator.release(hostID: hostID, projectIdentity: "x")

        await waitUntilMainActor { loadCount.load() == 1 }
        #expect(loadCount.load() == 1)
    }

    @Test("mutation publication for another endpoint is rejected")
    func mutationPublicationForAnotherEndpointIsRejected() {
        let coordinator = WorktreeMutationCoordinator()
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in KwtHostInventory(projects: []) },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer { store.removeSubscriber(id: subscriberID) }
        #expect(coordinator.acquire(hostID: hostID, projectIdentity: "x"))
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        let registered = KwtHostInventory(projects: [KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "example/repository",
                name: "Repository",
                path: "/test/repository",
                lastTouched: nil,
                registrationFingerprint: "test-registration"
            ),
            worktrees: [],
            warning: nil
        )])
        store.publishKwtInventory(
            registered,
            on: .local,
            mutation: .init(
                hostID: hostID,
                host: .ssh(SSHHostInfo(
                    user: "test",
                    hostname: "example.invalid",
                    port: nil,
                    platform: .posix
                )),
                epoch: store.kwtMutationEpoch(on: .local)
            )
        )
        #expect(store.snapshot.kwtByHost[.local]?.inventory == nil)
        coordinator.release(hostID: hostID, projectIdentity: "x")
    }

    @Test("legacy-empty repository identity keeps a removed project hidden")
    func legacyEmptyIdentityKeepsRemovedProjectHidden() async {
        let repository = "example/repository"
        let path = "/test/repository"
        let registered = KwtHostInventory(projects: [KwtProjectInventory(
            project: KwtProjectRecord(
                repository: repository,
                name: "Repository",
                path: path,
                lastTouched: nil,
                registrationFingerprint: "test-registration"
            ),
            worktrees: [],
            warning: nil
        )])
        let legacy = KwtHostInventory(projects: [KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "",
                name: "Repository",
                path: path,
                lastTouched: nil,
                registrationFingerprint: "test-registration"
            ),
            worktrees: [],
            warning: nil
        )])
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return legacy
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer { store.removeSubscriber(id: subscriberID) }
        store.publishKwtInventory(registered, on: .local, mutation: nil)
        #expect(coordinator.acquire(
            hostID: hostID,
            projectIdentity: repository
        ))
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: repository,
            removesProject: true
        )
        await waitUntilMainActor {
            loadCount.load() == 1
                && store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects.isEmpty
                == true
        )

        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 2
                && store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects.isEmpty
                == true
        )

        coordinator.noteProjectRegistration(
            hostID: hostID,
            projectIdentity: repository,
            projectPath: path
        )
        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 3
                && store.snapshot.kwtByHost[.local]?.inventory?.projects
                == legacy.projects
        }
    }

    private func legacyProject(
        name: String,
        path: String,
        repository: String = ""
    ) -> KwtProjectInventory {
        KwtProjectInventory(
            project: KwtProjectRecord(
                repository: repository,
                name: name,
                path: path,
                lastTouched: nil,
                registrationFingerprint: "test-registration"
            ),
            worktrees: [],
            warning: nil
        )
    }

    @Test("an empty-identity project tombstone hides only its own path")
    func emptyIdentityTombstoneHidesOnlyItsOwnPath() async {
        let removed = legacyProject(name: "Removed", path: "/test/removed")
        let kept = legacyProject(name: "Kept", path: "/test/kept")
        let inventory = KwtHostInventory(projects: [removed, kept])
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return inventory
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer { store.removeSubscriber(id: subscriberID) }
        #expect(coordinator.acquire(hostID: hostID, projectIdentity: ""))
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: "",
            removesProject: true,
            projectPath: removed.project.path
        )
        await waitUntilMainActor {
            loadCount.load() == 1
                && store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects == [kept]
        )
    }

    @Test("re-registration clears a project tombstone by path")
    func reregistrationClearsProjectTombstoneByPath() async {
        let path = "/test/repository"
        let legacy = KwtHostInventory(projects: [
            legacyProject(name: "Repository", path: path),
        ])
        let canonical = KwtHostInventory(projects: [
            legacyProject(
                name: "Repository",
                path: path,
                repository: "example/repository"
            ),
        ])
        let coordinator = WorktreeMutationCoordinator()
        let loadCount = LockedValue(0)
        let hostID = UUID()
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return canonical
            },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let subscriberID = UUID()
        defer { store.removeSubscriber(id: subscriberID) }
        store.publishKwtInventory(legacy, on: .local, mutation: nil)
        #expect(coordinator.acquire(hostID: hostID, projectIdentity: ""))
        store.updateSubscriber(
            id: subscriberID,
            registrations: [.init(
                hostID: hostID,
                commandHost: .local,
                provisioningHost: nil
            )],
            wantsKwt: true,
            wantsTmux: false
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: "",
            removesProject: true,
            projectPath: path
        )
        await waitUntilMainActor {
            loadCount.load() == 1
                && store.snapshot.kwtByHost[.local]?.isFresh == true
        }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects.isEmpty
                == true
        )

        coordinator.noteProjectRegistration(
            hostID: hostID,
            projectIdentity: "example/repository",
            projectPath: path
        )
        store.refreshKwt(for: subscriberID)
        await waitUntilMainActor {
            loadCount.load() == 2
                && store.snapshot.kwtByHost[.local]?.inventory?.projects
                == canonical.projects
        }
        #expect(
            store.snapshot.kwtByHost[.local]?.inventory?.projects
                == canonical.projects
        )
    }
}
