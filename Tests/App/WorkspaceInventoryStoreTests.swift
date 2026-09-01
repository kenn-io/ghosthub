import AppKit
import Foundation
import GhosthubSettings
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("Workspace inventory store", .serialized)
@MainActor
struct WorkspaceInventoryStoreTests {
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
            mutationHostID: hostID
        )
        coordinator.release(
            hostID: hostID,
            projectIdentity: projectIdentity
        )

        try await Task.sleep(for: .milliseconds(20))
        #expect(loadCount.load() == 0)
        #expect(store.snapshot.kwtByHost[.local]?.isFresh == true)
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
            mutationHostID: nil
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
            mutationHostID: hostID
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
}
