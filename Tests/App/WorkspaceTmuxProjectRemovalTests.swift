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
    @MainActor
    @Test("Add Project rejects a host endpoint changed while its sheet is open")
    func addProjectRejectsChangedEndpoint() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@old.example.com"
            ),
        ])
        let registrationCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtProjectRegistration: { _, _ in
                _ = registrationCalls.increment()
                return KwtProjectRecord(
                    repository: "github.com/kenn-io/ghosthub",
                    name: "ghosthub",
                    path: "/srv/ghosthub",
                    lastTouched: nil
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher()
        )
        model.refreshHosts()
        let capturedHost = try #require(
            model.snapshot.hosts.first { $0.configKey == "spark" }
        )

        configuredHosts.value = [
            SSHHost(
                configKey: "spark",
                name: "DGX Spark",
                platform: .linux,
                sshDestination: "wesm@new.example.com"
            ),
        ]
        model.refreshHosts()
        let result = await model.registerProject(
            "/srv/ghosthub",
            on: capturedHost
        )

        #expect(
            result == .failure(.message(
                "The host connection changed. "
                    + "Close Add Project and try again."
            ))
        )
        #expect(registrationCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Add Project rejects an endpoint changed during kwt provisioning")
    func addProjectRejectsEndpointChangedDuringProvisioning() async throws {
        let environment = try setupRemoteEnvironment()
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(environment.host.sshDestination)
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let provisioningGate = AsyncGate()
        let registrationCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: environment.snapshot,
            kwtRemoteProvisioner: { _ in
                await provisioningGate.wait()
            },
            kwtProjectRegistration: { _, _ in
                _ = registrationCalls.increment()
                return KwtProjectRecord(
                    repository: environment.project.scopedKey,
                    name: environment.project.name,
                    path: environment.project.rootPath,
                    lastTouched: nil
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        let capturedHost = try #require(
            model.snapshot.host(id: environment.host.id)
        )

        let registration = Task { @MainActor in
            await model.registerProject(
                environment.project.rootPath,
                on: capturedHost
            )
        }
        await provisioningGate.waitUntilWaiting()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "user-a@host-b.example.com"
            ),
        ])
        model.refreshHosts()
        provisioningGate.open()

        #expect(await registration.value == .failure(.message(
            "The host connection changed. "
                + "Close Add Project and try again."
        )))
        #expect(registrationCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Host Settings Add Project rejects an endpoint changed during kwt provisioning")
    func hostSettingsAddProjectRejectsEndpointChangedDuringProvisioning() async throws {
        let environment = try setupRemoteEnvironment()
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(environment.host.sshDestination)
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let provisioningGate = AsyncGate()
        let registrationCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: environment.snapshot,
            kwtRemoteProvisioner: { _ in
                await provisioningGate.wait()
            },
            kwtProjectRegistration: { _, _ in
                _ = registrationCalls.increment()
                return KwtProjectRecord(
                    repository: environment.project.scopedKey,
                    name: environment.project.name,
                    path: environment.project.rootPath,
                    lastTouched: nil
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )

        let registration = Task { @MainActor in
            await model.registerRemoteProject(
                environment.project.rootPath,
                on: initialHost
            )
        }
        await provisioningGate.waitUntilWaiting()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "user-a@host-b.example.com"
            ),
        ])
        model.refreshHosts()
        provisioningGate.open()

        #expect(await registration.value == .failure(.message(
            "The host connection changed. "
                + "Close Add Project and try again."
        )))
        #expect(registrationCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project stops when provisioning changes the endpoint")
    func removeProjectStopsAfterProvisioningEndpointChange() async throws {
        let environment = try setupRemoteEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let confirmedHost = try #require(environment.snapshot.hosts.first)
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(environment.host.sshDestination)
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let provisioningGate = AsyncGate()
        let inventoryLoads = Counter()
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                _ = inventoryLoads.increment()
                return WorkspaceTmuxTestSupport.inventory(
                    project: project,
                    worktrees: environment.snapshot.worktrees
                )
            },
            kwtRemoteProvisioner: { _ in
                await provisioningGate.wait()
            },
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )

        let removal = Task { @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await provisioningGate.waitUntilWaiting()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "user-a@host-b.example.com"
            ),
        ])
        model.refreshHosts()
        provisioningGate.open()

        #expect(await removal.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        #expect(inventoryLoads.count == 0)
        #expect(removalCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Host Settings registers a project on an unsaved host draft")
    func hostSettingsRegistersProjectOnUnsavedDraft() async throws {
        let environment = try setupHostEnvironment()
        let draft = SSHHost(
            configKey: "new-builder",
            name: "New Builder",
            platform: .linux,
            sshDestination: " \noperator@builder.example.com:2222\t"
        )
        let capturedTarget = LockedValue<CommandHost?>(nil)
        let provisionedHost = LockedValue<SSHHost?>(nil)
        let events = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtRemoteProvisioner: { host in
                provisionedHost.store(host)
                events.withLock { $0.append("provision") }
            },
            kwtProjectRegistration: { path, target in
                capturedTarget.store(target)
                events.withLock { $0.append("register") }
                return KwtProjectRecord(
                    repository: "github.com/kenn-io/ghosthub",
                    name: "ghosthub",
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let result = await model.registerRemoteProject(
            "/srv/ghosthub",
            on: draft
        )

        #expect(result == .success("ghosthub"))
        #expect(provisionedHost.load() == SSHHost(
            configKey: draft.configKey,
            name: draft.name,
            platform: draft.platform,
            sshDestination: "operator@builder.example.com:2222"
        ))
        #expect(events.load() == ["provision", "register"])
        #expect(capturedTarget.load() == .ssh(SSHHostInfo(
            user: "operator",
            hostname: "builder.example.com",
            port: 2222,
            platform: .posix
        )))
        await model.shutdown()
    }

    @MainActor
    @Test("Host Settings reinstall bypasses passive kwt provisioning")
    func hostSettingsReinstallBypassesPassiveProvisioning() async throws {
        let environment = try setupHostEnvironment()
        let draft = SSHHost(
            configKey: "new-builder",
            name: "New Builder",
            platform: .linux,
            sshDestination: ""
        )
        let passiveProvisioningCalls = Counter()
        let installedHost = LockedValue<SSHHost?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtRemoteProvisioner: { _ in
                _ = passiveProvisioningCalls.increment()
            },
            kwtRemoteInstaller: { host in
                installedHost.store(host)
            }
        )

        let result = await model.installRemoteKwt(on: draft)

        guard case .success = result else {
            Issue.record("Expected managed kwt provisioning to succeed")
            await model.shutdown()
            return
        }
        #expect(passiveProvisioningCalls.count == 0)
        #expect(installedHost.load() == draft)
        await model.shutdown()
    }

    @MainActor
    @Test("Host aliases cannot overlap project registry changes")
    func addProjectRejectsConcurrentRemoval() async throws {
        let environment = try setupRemoteEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let draft = SSHHost(
            configKey: "builder-alias",
            name: "Builder Alias",
            platform: host.platform,
            sshDestination: "wesm@OFFICE-LINUX:22"
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: environment.snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let removalGate = KillGate()
        let registrationCalls = Counter()
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                await removalGate.suspend()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )
        let registrationModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            worktreeMutationCoordinator: coordinator,
            kwtProjectRegistration: { path, _ in
                _ = registrationCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let removalTask = Task {
            await removalModel.unregisterProject(
                project,
                confirmedHost: host
            )
        }
        await removalGate.waitUntilStarted()

        let registrationResult = await registrationModel
            .registerRemoteProject(
                project.rootPath,
                on: draft
            )
        #expect(removalModel.snapshot.project(id: project.id) != nil)

        await removalGate.release()
        let removalResult = await removalTask.value
        #expect(registrationResult == .failure(.message(
            "Another project or worktree change is already in progress."
        )))
        #expect(registrationCalls.count == 0)
        #expect(removalResult == .success(project.name))
        await waitUntilMainActor {
            removalModel.snapshot.project(id: project.id) == nil
        }
        await removalModel.shutdown()
        await registrationModel.shutdown()
    }

    @MainActor
    @Test("Refreshed endpoint identity replaces an unresolved retired entry")
    func refreshedEndpointReconcilesRetiredUnresolvedEntry() throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let worktree = try #require(environment.snapshot.worktrees.first)
        let selection = WorkspaceTmuxSessionSelection(
            hostID: project.hostID,
            name: "kwt-ghosthub-pr-94",
            worktreeID: worktree.id,
            workspacePath: worktree.path,
            worktreeGeneration: worktree.generation,
            socketName: "kwt-pr-94"
        )
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        let identity = KwtWorktreeIdentity(
            path: worktree.path,
            generation: worktree.generation ?? ""
        )
        let retiredParticipant = UUID()
        let refreshedParticipant = UUID()
        let coordinator = WorktreeMutationCoordinator()

        coordinator.replaceProtectedEndpoints([
            scope: [WorktreeMutationCoordinator.ProtectedEndpoint(
                worktreeName: "stale-label",
                worktreeIdentity: identity,
                selection: nil
            )],
        ], for: retiredParticipant)
        coordinator.retireProtectedEndpoints(for: retiredParticipant)
        coordinator.replaceProtectedEndpoints([
            scope: [WorktreeMutationCoordinator.ProtectedEndpoint(
                worktreeName: "current-label",
                worktreeIdentity: identity,
                selection: selection
            )],
        ], for: refreshedParticipant)

        #expect(coordinator.protectedEndpoints(in: scope) == [
            WorktreeMutationCoordinator.ProtectedEndpoint(
                worktreeName: "current-label",
                worktreeIdentity: identity,
                selection: selection
            ),
        ])
    }

    @MainActor
    @Test("Generationless inventory preserves a matching retired endpoint")
    func generationlessInventoryPreservesRetiredEndpoint() throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        var worktree = try #require(environment.snapshot.worktrees.first)
        let canonicalGeneration =
            "0123456789abcdef0123456789abcdef01234567"
        worktree.generation = nil
        let identity = KwtWorktreeIdentity(
            path: worktree.path,
            generation: canonicalGeneration
        )
        let endpoint = WorktreeMutationCoordinator.ProtectedEndpoint(
            worktreeName: worktree.name,
            worktreeIdentity: identity,
            selection: WorkspaceTmuxSessionSelection(
                hostID: project.hostID,
                name: "kwt-ghosthub-pr-94",
                worktreeID: worktree.id,
                workspacePath: worktree.path,
                worktreeGeneration: canonicalGeneration,
                socketName: "kwt-pr-94"
            )
        )
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        let participant = UUID()
        let coordinator = WorktreeMutationCoordinator()
        coordinator.replaceProtectedEndpoints(
            [scope: [endpoint]],
            for: participant
        )
        coordinator.retireProtectedEndpoints(for: participant)

        coordinator.reconcileRetiredProtectedEndpoints(
            after: WorkspaceTmuxTestSupport.inventory(project: project, worktrees: [worktree]),
            hostID: project.hostID
        )

        #expect(coordinator.protectedEndpoints(in: scope) == [endpoint])
    }

    @MainActor
    @Test("Complete inventory prunes a vanished unresolved retired endpoint")
    func completeInventoryPrunesVanishedRetiredEndpoint() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        let retiredParticipant = UUID()
        let coordinator = WorktreeMutationCoordinator()
        coordinator.replaceProtectedEndpoints([
            scope: [WorktreeMutationCoordinator.ProtectedEndpoint(
                worktreeName: "vanished",
                worktreeIdentity: KwtWorktreeIdentity(
                    path: "/worktrees/vanished",
                    generation: "0123456789abcdef0123456789abcdef"
                ),
                selection: nil
            )],
        ], for: retiredParticipant)
        coordinator.retireProtectedEndpoints(for: retiredParticipant)
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                WorkspaceTmuxTestSupport.inventory(
                    project: project,
                    worktrees: environment.snapshot.worktrees
                )
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )
        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(coordinator.protectedEndpoints(in: scope).isEmpty)
        #expect(removalCalls.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project unregisters the current project path on its host")
    func removeProjectTargetsCurrentProject() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let removal = LockedValue<(
            String, String, String, CommandHost
        )?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                WorkspaceTmuxTestSupport.inventory(
                    project: project,
                    worktrees: environment.snapshot.worktrees
                )
            },
            kwtProjectRemoval: {
                path, expectedRepository, expectedRegistration, _, host in
                removal.store((
                    path, expectedRepository, expectedRegistration, host
                ))
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )
        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(removal.load()?.0 == project.rootPath)
        #expect(removal.load()?.1 == project.scopedKey)
        #expect(
            removal.load()?.2 == project.registrationFingerprint
        )
        #expect(removal.load()?.3 == .local)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project never retries with a refreshed registration")
    func removeProjectDoesNotRetryRegistrationChanged() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        var refreshedProject = project
        refreshedProject.registrationFingerprint = "replacement-registration"
        let refreshedInventory = WorkspaceTmuxTestSupport.inventory(
            project: refreshedProject,
            worktrees: environment.snapshot.worktrees
        )
        let inventoryLoads = Counter()
        let removals = LockedValue<[String]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                _ = inventoryLoads.increment()
                return refreshedInventory
            },
            kwtProjectRemoval: { _, _, expectedRegistration, _, _ in
                removals.withLock { $0.append(expectedRegistration) }
                throw KwtProjectCommandError.commandFailed(
                    host: "this Mac",
                    status: 1,
                    code: "registration_changed",
                    message: "project registration changed",
                    retryable: true,
                    details: [:]
                )
            }
        )
        model.startKwtInventory()
        await waitUntilMainActor { inventoryLoads.count == 1 }

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "project registration changed Try again."
        )))
        await waitUntilMainActor { inventoryLoads.count >= 3 }
        #expect(removals.load() == [project.registrationFingerprint])
        #expect(model.snapshot.projects.count == 1)
        #expect(
            model.snapshot.projects.first?.registrationFingerprint
                == "replacement-registration"
        )
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Definitive kwt removal rejections restore without reconciliation",
        arguments: [
            "protected_session_live",
            "protected_endpoint_inventory_incomplete",
        ]
    )
    func definitiveRemovalRejectionRestoresImmediately(
        code: String
    ) async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-root"
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let inventoryLoads = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalError = KwtProjectCommandError.commandFailed(
            host: "this Mac",
            status: 1,
            code: code,
            message: "kwt rejected project removal",
            retryable: false,
            details: [:]
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in
                guard inventoryLoads.increment() == 1 else {
                    throw KwtInventoryError.commandFailed(
                        host: "this Mac",
                        status: 75
                    )
                }
                return inventory
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _, _ in throw removalError }
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            removalError.localizedDescription
        )))
        #expect(coordinator.scopes.isEmpty)
        #expect(model.activeBorrowedTmuxSelection == selection)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Remove Project rejects live protected sessions",
        arguments: [false, true]
    )
    func removeProjectRejectsLiveProtectedSession(
        attached: Bool
    ) async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let currentInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in currentInventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        if attached {
            model.openBorrowedTmuxSession(selection)
            await launchActiveTmuxSurface(model, store: surfaceStore)
            #expect(model.retainedBorrowedTmuxSessionIsConnected(selection))
        }

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-pr-94” is still running on its protected "
                + "tmux server. Kill it before removing project “Ghosthub”."
        )))
        #expect(removalCalls.count == 0)
        #expect(coordinator.scopes.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project probes protected endpoints from another scene")
    func removeProjectProbesDivergentSceneEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        var removalSnapshot = environment.snapshot
        removalSnapshot.worktrees[0].tmuxSocketName = nil
        let project = try #require(removalSnapshot.projects.first)
        let host = try #require(removalSnapshot.hosts.first)
        let protectedWorktree = WorktreeSummary(
            id: UUID(),
            hostID: host.id,
            projectID: project.id,
            scopedKey: "worktree:/tmp/ghosthub-divergent-protected",
            name: "divergent-protected",
            path: "/tmp/ghosthub-divergent-protected",
            branch: "feature/divergent-protected",
            generation: "0123456789abcdef0123456789abcdef",
            tmuxSessionName: "kwt-ghosthub-divergent-protected",
            tmuxSocketName: "kwt-divergent-protected",
            tmuxAttachMode: .protected
        )
        let protectedSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: protectedWorktree
            )
        )
        var divergentSnapshot = removalSnapshot
        divergentSnapshot.worktrees.append(protectedWorktree)
        let currentInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: removalSnapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let probedSelections = LockedValue<
            Set<WorkspaceTmuxSessionSelection>
        >([])
        let otherScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: divergentSnapshot,
            worktreeMutationCoordinator: coordinator
        )
        let removalScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: removalSnapshot,
            kwtInventoryLoader: { _ in currentInventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                probedSelections.withLock { $0.insert(selection) }
                if selection == protectedSelection {
                    return TmuxSessionIdentity(
                        serverPID: "31415",
                        sessionID: "$42",
                        createdAt: "1721552400"
                    )
                }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let result = await removalScene.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-divergent-protected” is still running "
                + "on its protected tmux server. Kill it before removing "
                + "project “Ghosthub”."
        )))
        #expect(probedSelections.load().contains(protectedSelection))
        #expect(removalCalls.count == 0)
        await otherScene.shutdown()
        await removalScene.shutdown()
    }

    @MainActor
    @Test("Remove Project probes endpoints replaced by an active scene")
    func removeProjectProbesEndpointReplacedByActiveScene() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-current"
        snapshot.worktrees[0].tmuxSocketName = "kwt-current"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var previousSnapshot = snapshot
        previousSnapshot.worktrees[0].tmuxSessionName =
            "kwt-ghosthub-retired"
        previousSnapshot.worktrees[0].tmuxSocketName = "kwt-retired"
        previousSnapshot.worktrees[0].tmuxAttachMode = .protected
        let liveRetiredSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: previousSnapshot.worktrees[0]
            )
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let probedSelections = LockedValue<
            Set<WorkspaceTmuxSessionSelection>
        >([])
        let activeScene = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: previousSnapshot,
            worktreeMutationCoordinator: coordinator
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                probedSelections.withLock { $0.insert(selection) }
                if selection == liveRetiredSelection {
                    return TmuxSessionIdentity(
                        serverPID: "31415",
                        sessionID: "$42",
                        createdAt: "1721552400"
                    )
                }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        activeScene.snapshot = snapshot

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-retired” is still running on its "
                + "protected tmux server. Kill it before removing project "
                + "“Ghosthub”."
        )))
        #expect(probedSelections.load().contains(liveRetiredSelection))
        #expect(removalCalls.count == 0)
        await activeScene.shutdown()
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project allows an absent protected session")
    func removeProjectAllowsAbsentProtectedSession() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let currentInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in currentInventory },
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(removalCalls.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project reprobes cached endpoints after partial inventory")
    func removeProjectReprobesCachedEndpointsAfterPartialInventory()
        async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let missingCheckout = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-partial-checkout-\(UUID().uuidString)",
                isDirectory: true
            )
        snapshot.projects[0].rootPath = missingCheckout.path
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-visible"
        snapshot.worktrees[0].tmuxSocketName = "kwt-visible"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let omittedWorktree = WorktreeSummary(
            id: UUID(),
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "worktree:\(missingCheckout.path)/omitted",
            name: "omitted",
            path: "\(missingCheckout.path)/omitted",
            branch: "feature/omitted",
            generation: "0123456789abcdef0123456789abcdef",
            tmuxSessionName: "kwt-ghosthub-omitted",
            tmuxSocketName: nil
        )
        snapshot.worktrees.append(omittedWorktree)
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var partialInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: [snapshot.worktrees[0]]
        )
        partialInventory.projects[0].warning = "kwt worktree inventory failed"
        let inventory = partialInventory
        let removalCalls = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in inventory },
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                if selection.name == "kwt-ghosthub-visible" {
                    return TmuxSessionIdentity(
                        serverPID: "31415",
                        sessionID: "$42",
                        createdAt: "1721552400"
                    )
                }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let omittedSelection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: omittedWorktree)
        )
        model.openBorrowedTmuxSession(omittedSelection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)

        let firstResult = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(firstResult == .failure(.message(
            "Session “kwt-ghosthub-visible” is still running on its protected "
                + "tmux server. Kill it before removing project “Ghosthub”."
        )))
        #expect(removalCalls.count == 0)
        #expect(model.snapshot.worktree(id: omittedWorktree.id) != nil)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(model.activeBorrowedTmuxSelection == omittedSelection)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project probes each protected endpoint once")
    func removeProjectDeduplicatesProtectedEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let missingCheckout = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-deduplicated-checkout-\(UUID().uuidString)",
                isDirectory: true
            )
        snapshot.projects[0].rootPath = missingCheckout.path
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-protected"
        snapshot.worktrees[0].tmuxSocketName = "kwt-protected"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var refreshedWorktree = try #require(snapshot.worktrees.first)
        refreshedWorktree.scopedKey = "worktree:/tmp/refreshed-protected"
        refreshedWorktree.path = "/tmp/refreshed-protected"
        refreshedWorktree.generation =
            "fedcba9876543210fedcba9876543210"
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: [refreshedWorktree]
        )
        let identityReads = Counter()
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                _ = identityReads.increment()
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(identityReads.count == 1)
        #expect(removalCalls.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project probes protected endpoints from refreshed inventory")
    func removeProjectProbesRefreshedProtectedEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-cached"
        snapshot.worktrees[0].tmuxSocketName = nil
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var refreshedWorktree = try #require(snapshot.worktrees.first)
        refreshedWorktree.scopedKey = "worktree:/tmp/refreshed-protected"
        refreshedWorktree.path = "/tmp/refreshed-protected"
        refreshedWorktree.generation =
            "fedcba9876543210fedcba9876543210"
        refreshedWorktree.tmuxSessionName = "kwt-ghosthub-refreshed"
        refreshedWorktree.tmuxSocketName = "kwt-refreshed"
        refreshedWorktree.tmuxAttachMode = .protected
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: [refreshedWorktree]
        )
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-refreshed” is still running on its "
                + "protected tmux server. Kill it before removing project "
                + "“Ghosthub”."
        )))
        #expect(removalCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Refreshed endpoint replaces the same unresolved cached identity")
    func refreshedEndpointReplacesCachedUnresolvedIdentity() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = nil
        snapshot.worktrees[0].tmuxSocketName = "kwt-stale"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var refreshedWorktree = try #require(snapshot.worktrees.first)
        refreshedWorktree.tmuxSessionName = "kwt-ghosthub-refreshed"
        refreshedWorktree.tmuxSocketName = "kwt-refreshed"
        refreshedWorktree.tmuxAttachMode = .protected
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: [refreshedWorktree]
        )
        let probedSelection = LockedValue<
            WorkspaceTmuxSessionSelection?
        >(nil)
        let removalCalls = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                probedSelection.store(selection)
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(probedSelection.load()?.name == "kwt-ghosthub-refreshed")
        #expect(probedSelection.load()?.socketName == "kwt-refreshed")
        #expect(removalCalls.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project releases its fence after inventory failure")
    func removeProjectReleasesFenceAfterInventoryFailure() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let inventoryError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in throw inventoryError },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            inventoryError.localizedDescription
        )))
        #expect(removalCalls.count == 0)
        #expect(coordinator.scopes.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project delegates warned missing checkout to guarded kwt")
    func removeProjectDelegatesWarnedMissingCheckout() async throws {
        let environment = try setupStandardEnvironment()
        let missingCheckout = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-uncached-checkout-\(UUID().uuidString)",
                isDirectory: true
            )
        var snapshot = environment.snapshot
        snapshot.projects[0].rootPath = missingCheckout.path
        snapshot.worktrees = []
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        var inventory = WorkspaceTmuxTestSupport.inventory(project: project, worktrees: [])
        inventory.projects[0].warning = "worktree lookup failed"
        let warnedInventory = inventory
        let removal = LockedValue<(String, String)?>(nil)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in warnedInventory },
            kwtProjectRemoval: { path, expectedRepository, _, _, _ in
                removal.store((path, expectedRepository))
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .success(project.name))
        #expect(removal.load()?.0 == missingCheckout.path)
        #expect(removal.load()?.1 == project.scopedKey)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Remove Project reconciles a lost removal response",
        arguments: ProjectRemovalReconciliationCase.allCases
    )
    func removeProjectReconcilesLostResponse(
        reconciliation: ProjectRemovalReconciliationCase
    ) async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let coordinator = WorktreeMutationCoordinator()
        let inventoryLoads = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                switch inventoryLoads.increment() {
                case 1:
                    return inventory
                default:
                    switch reconciliation {
                    case .confirmedPresent:
                        return inventory
                    case .confirmedAbsent:
                        return KwtHostInventory(projects: [])
                    case .unavailable:
                        throw KwtInventoryError.commandFailed(
                            host: "this Mac",
                            status: 75
                        )
                    case .globalWarning:
                        var warned = inventory
                        warned.projectsWarning = "project lookup failed"
                        return warned
                    case .projectWarning:
                        var warned = inventory
                        warned.projects[0].warning = "worktree lookup failed"
                        return warned
                    case .pathDrift:
                        var moved = inventory
                        moved.projects[0].project.path = "/tmp/ghosthub-moved"
                        return moved
                    }
                }
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _, _ in throw removalError },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let attachedModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        attachedModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(attachedModel, store: surfaceStore)
        await waitUntilMainActor { coordinator.scopes.isEmpty }

        let result = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        switch reconciliation {
        case .confirmedPresent:
            #expect(result == .failure(.message(
                removalError.localizedDescription
            )))
            #expect(attachedModel.activeBorrowedTmuxSelection == selection)
            #expect(attachedModel.snapshot.project(id: project.id) != nil)
        case .confirmedAbsent:
            #expect(result == .success(project.name))
            #expect(attachedModel.activeBorrowedTmuxSelection == nil)
            #expect(attachedModel.snapshot.project(id: project.id) == nil)
        case .unavailable, .globalWarning, .projectWarning, .pathDrift:
            #expect(result == .failure(.message(
                removalError.localizedDescription
            )))
            #expect(attachedModel.activeBorrowedTmuxSelection == nil)
            #expect(attachedModel.snapshot.project(id: project.id) != nil)
        }
        #expect(inventoryLoads.count == 2)
        switch reconciliation {
        case .confirmedPresent, .confirmedAbsent:
            #expect(coordinator.scopes.isEmpty)
        case .unavailable, .globalWarning, .projectWarning, .pathDrift:
            #expect(!coordinator.scopes.isEmpty)
        }
        await removalModel.shutdown()
        await attachedModel.shutdown()
    }

    @MainActor
    @Test("Warned missing checkout releases quarantine for removal retry")
    func warnedMissingCheckoutReleasesQuarantineForRetry() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let missingCheckout = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-missing-retry-\(UUID().uuidString)",
                isDirectory: true
            )
        snapshot.projects[0].rootPath = missingCheckout.path
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        var warnedInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: []
        )
        warnedInventory.projects[0].warning = "worktree lookup failed"
        let authoritativeInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        var warnedDriftInventory = warnedInventory
        warnedDriftInventory.projects[0].project.path = missingCheckout
            .appendingPathComponent("moved", isDirectory: true).path
        let inventory = LockedValue(warnedInventory)
        let inventoryLoads = Counter()
        let removalCalls = Counter()
        let openedSessions = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                guard inventoryLoads.increment() > 1 else {
                    return authoritativeInventory
                }
                return inventory.load()
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                guard removalCalls.increment() > 1 else {
                    throw removalError
                }
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let attachedModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        var selectedWorktree = attachedModel.selection
        selectedWorktree.select(
            .worktree(worktree.id),
            in: attachedModel.snapshot,
            visibility: .default
        )
        attachedModel.selectFromUser(selectedWorktree)
        attachedModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(attachedModel, store: surfaceStore)
        await waitUntilMainActor { coordinator.scopes.isEmpty }

        let firstResult = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(firstResult == .failure(.message(
            removalError.localizedDescription
        )))
        let lateModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            worktreeMutationCoordinator: coordinator
        )
        var lateSelection = lateModel.selection
        lateSelection.select(
            .worktree(worktree.id),
            in: lateModel.snapshot,
            visibility: .default
        )
        lateModel.selectFromUser(lateSelection)
        #expect(lateModel.suppressesSelectedWorktreeSessionOpen)
        let hostingView = hostView(rootView: AnyView(
            SceneModelRootHarness(
                model: lateModel,
                onOpenTmuxSession: { _ in
                    _ = openedSessions.increment()
                }
            )
        ))
        inventory.store(warnedDriftInventory)
        let loadsBeforeDriftRefresh = inventoryLoads.count
        removalModel.startKwtInventory()
        await waitUntilMainActor {
            inventoryLoads.count > loadsBeforeDriftRefresh
                && removalModel.workspaceInventoryWarning != nil
        }
        #expect(!coordinator.scopes.isEmpty)
        #expect(removalCalls.count == 1)

        inventory.store(warnedInventory)
        removalModel.refreshKwtInventory()
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(coordinator.scopes.isEmpty)
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(openedSessions.count == 0)
        #expect(attachedModel.activeBorrowedTmuxSelection == nil)
        #expect(attachedModel.suppressesSelectedWorktreeSessionOpen)
        #expect(lateModel.suppressesSelectedWorktreeSessionOpen)

        inventory.store(authoritativeInventory)
        let secondResult = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(secondResult == .success(project.name))
        #expect(removalCalls.count == 2)
        withExtendedLifetime(hostingView) {}
        await removalModel.shutdown()
        await attachedModel.shutdown()
        await lateModel.shutdown()
    }

    @MainActor
    @Test("Unverified project removal keeps Root from reopening")
    func unverifiedProjectRemovalSuppressesRootOpen() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let inventoryLoads = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let openedSessions = Counter()
        let removalGate = KillGate()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                switch inventoryLoads.increment() {
                case 1:
                    return inventory
                case 2:
                    throw KwtInventoryError.commandFailed(
                        host: "this Mac",
                        status: 75
                    )
                default:
                    return inventory
                }
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _, _ in
                await removalGate.suspend()
                throw removalError
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let attachedModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        var selectedWorktree = attachedModel.selection
        selectedWorktree.select(
            .worktree(worktree.id),
            in: attachedModel.snapshot,
            visibility: .default
        )
        attachedModel.selectFromUser(selectedWorktree)
        attachedModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(attachedModel, store: surfaceStore)
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        let hostingView = hostView(rootView: AnyView(
            SceneModelRootHarness(
                model: attachedModel,
                onOpenTmuxSession: { _ in
                    _ = openedSessions.increment()
                }
            )
        ))

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await removalModel.unregisterProject(
                project,
                confirmedHost: host
            )
        }
        await removalGate.waitUntilStarted()
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(attachedModel.selection.selectedWorktreeID == worktree.id)
        #expect(attachedModel.suppressesSelectedWorktreeSessionOpen)
        await removalGate.release()
        let result = await removalTask.value

        #expect(result == .failure(.message(
            removalError.localizedDescription
        )))
        #expect(attachedModel.activeBorrowedTmuxSelection == nil)
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        #expect(openedSessions.count == 0)
        #expect(attachedModel.suppressesSelectedWorktreeSessionOpen)
        #expect(!coordinator.scopes.isEmpty)
        withExtendedLifetime(hostingView) {}

        removalModel.startKwtInventory()
        await waitUntilMainActor {
            inventoryLoads.count >= 3 && coordinator.scopes.isEmpty
        }
        await removalModel.shutdown()
        await attachedModel.shutdown()
    }

    @MainActor
    @Test("Scene opened during quarantine can resolve it")
    func sceneOpenedDuringQuarantineResolvesInventory() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let inventoryLoads = Counter()
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )],
            presentationTargets: [selection]
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: .local
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                _ = inventoryLoads.increment()
                return inventory
            },
            worktreeMutationCoordinator: coordinator
        )
        var selectedWorktree = model.selection
        selectedWorktree.select(
            .worktree(worktree.id),
            in: model.snapshot,
            visibility: .default
        )
        model.selectFromUser(selectedWorktree)

        #expect(model.suppressesSelectedWorktreeSessionOpen)
        model.startKwtInventory()

        await waitUntilMainActor { inventoryLoads.count >= 1 }
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(!model.suppressesSelectedWorktreeSessionOpen)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Quarantine releases after a terminal registration change",
        arguments: QuarantinedProjectRegistrationChange.allCases
    )
    func quarantineReleasesAfterRegistrationChange(
        change: QuarantinedProjectRegistrationChange
    ) async throws {
        let environment = try setupStandardEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let coordinator = WorktreeMutationCoordinator()
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )],
            presentationTargets: []
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: .local
        )
        let expectedRepository: String
        let expectedPath: String
        let inventory: KwtHostInventory
        switch change {
        case .sameIdentityMoved:
            expectedRepository = project.scopedKey
            expectedPath = "/tmp/ghosthub-moved"
            var moved = project
            moved.rootPath = expectedPath
            inventory = WorkspaceTmuxTestSupport.inventory(project: moved, worktrees: [])
        case .replacementAtOriginalPath:
            expectedRepository = "repo:/tmp/ghosthub-replacement"
            expectedPath = project.rootPath
            inventory = KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: expectedRepository,
                        name: "Ghosthub Replacement",
                        path: expectedPath,
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator
        )

        model.startKwtInventory()

        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(model.snapshot.projects.contains {
            $0.scopedKey == expectedRepository
                && $0.rootPath == expectedPath
        })
        await model.shutdown()
    }

    @MainActor
    @Test("Quarantine resolution hides a legacy-identity record at the removed path")
    func quarantineResolutionHidesLegacyRecordAtRemovedPath() async throws {
        let environment = try setupStandardEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let coordinator = WorktreeMutationCoordinator()
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )],
            presentationTargets: []
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: .local
        )
        let legacy = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "",
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil
                ),
                worktrees: [],
                warning: nil
            ),
        ])
        let store = WorkspaceInventoryStore(
            refreshInterval: .seconds(3_600),
            kwtLoader: { _ in legacy },
            kwtProvisioner: { _ in },
            tmuxLoader: { _ in .success([]) },
            mutationCoordinator: coordinator
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            workspaceInventoryStore: store,
            kwtInventoryLoader: { _ in legacy },
            worktreeMutationCoordinator: coordinator
        )

        model.startKwtInventory()

        await waitUntilMainActor { coordinator.scopes.isEmpty }
        await waitUntilMainActor {
            !model.snapshot.projects.contains {
                $0.rootPath == project.rootPath
            }
        }
        #expect(!model.snapshot.projects.contains {
            $0.rootPath == project.rootPath
        })
        await model.shutdown()
    }

    @MainActor
    @Test("Removing a legacy-identity project keeps other legacy projects")
    func removingLegacyProjectKeepsOtherLegacyProjects() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let removed = ProjectSummary(
            id: UUID(),
            hostID: environment.host.id,
            scopedKey: "",
            name: "Removed",
            rootPath: "/tmp/legacy-removed"
        )
        let kept = ProjectSummary(
            id: UUID(),
            hostID: environment.host.id,
            scopedKey: "",
            name: "Kept",
            rootPath: "/tmp/legacy-kept"
        )
        snapshot.projects.append(contentsOf: [removed, kept])
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            worktreeMutationCoordinator: coordinator
        )
        #expect(coordinator.acquire(
            hostID: environment.host.id,
            projectIdentity: ""
        ))

        coordinator.release(
            hostID: environment.host.id,
            projectIdentity: "",
            removesProject: true,
            allowsRemovalRestoration: false,
            projectPath: removed.rootPath
        )

        #expect(model.snapshot.project(id: removed.id) == nil)
        #expect(model.snapshot.project(id: kept.id) != nil)
        #expect(model.snapshot.project(id: environment.project.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("Removing a canonical project removes its legacy-identity record")
    func removingCanonicalProjectRemovesLegacyRecord() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let legacyTwin = ProjectSummary(
            id: UUID(),
            hostID: environment.host.id,
            scopedKey: "",
            name: project.name,
            rootPath: project.rootPath
        )
        let other = ProjectSummary(
            id: UUID(),
            hostID: environment.host.id,
            scopedKey: "",
            name: "Other",
            rootPath: "/tmp/legacy-other"
        )
        snapshot.projects.append(contentsOf: [legacyTwin, other])
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            worktreeMutationCoordinator: coordinator
        )
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))

        coordinator.release(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            removesProject: true,
            allowsRemovalRestoration: false,
            projectPath: project.rootPath
        )

        #expect(model.snapshot.project(id: project.id) == nil)
        #expect(model.snapshot.project(id: legacyTwin.id) == nil)
        #expect(model.snapshot.project(id: other.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("Removing a project keeps the same repository registered elsewhere")
    func removingProjectKeepsSameRepositoryElsewhere() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let elsewhere = ProjectSummary(
            id: UUID(),
            hostID: environment.host.id,
            scopedKey: project.scopedKey,
            name: project.name,
            rootPath: "/tmp/ghosthub-elsewhere"
        )
        snapshot.projects.append(elsewhere)
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            worktreeMutationCoordinator: coordinator
        )
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))

        coordinator.release(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            removesProject: true,
            allowsRemovalRestoration: false,
            projectPath: project.rootPath
        )

        #expect(model.snapshot.project(id: project.id) == nil)
        #expect(model.snapshot.project(id: elsewhere.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("Quarantine resolution ignores the same repository at another path")
    func quarantineResolutionIgnoresSameRepositoryElsewhere() async throws {
        let environment = try setupStandardEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let coordinator = WorktreeMutationCoordinator()
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )],
            presentationTargets: []
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: .local
        )
        var elsewhere = project
        elsewhere.rootPath = "/tmp/ghosthub-elsewhere"
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: elsewhere,
            worktrees: []
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator
        )

        model.startKwtInventory()

        await waitUntilMainActor { coordinator.scopes.isEmpty }
        await waitUntilMainActor {
            !model.snapshot.projects.contains {
                $0.rootPath == project.rootPath
            }
        }
        #expect(!model.snapshot.projects.contains {
            $0.rootPath == project.rootPath
        })
        #expect(model.snapshot.projects.contains {
            $0.rootPath == elsewhere.rootPath
        })
        await model.shutdown()
    }

    @MainActor
    @Test("Replacement endpoint cannot classify an old quarantine as removed")
    func replacementEndpointDoesNotResolveOldQuarantine() async throws {
        let environment = try setupRemoteEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let oldHost = try #require(environment.snapshot.hosts.first)
        let oldTarget = try #require(CommandHostResolver.resolve(oldHost))
        let coordinator = WorktreeMutationCoordinator()
        #expect(coordinator.acquireProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            registryHost: .init(target: oldTarget)
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [],
            presentationTargets: []
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: oldTarget
        )
        let peer = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            worktreeMutationCoordinator: coordinator
        )
        var replacementSnapshot = environment.snapshot
        replacementSnapshot.hosts[0].sshDestination = "wesm@replacement"
        let replacement = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: replacementSnapshot,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            worktreeMutationCoordinator: coordinator
        )

        replacement.startKwtInventory()

        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(peer.snapshot.project(id: project.id) != nil)
        await replacement.shutdown()
        await peer.shutdown()
    }

    @MainActor
    @Test("Deleting a host releases an existing removal quarantine")
    func deletedHostReleasesExistingRemovalQuarantine() async throws {
        let environment = try setupRemoteEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let oldHost = try #require(environment.snapshot.hosts.first)
        let oldTarget = try #require(CommandHostResolver.resolve(oldHost))
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: environment.host.configKey,
                name: environment.host.name,
                platform: environment.host.platform,
                sshDestination: try #require(
                    environment.host.sshDestination
                )
            ),
        ])
        let coordinator = WorktreeMutationCoordinator()
        let registryHost = WorktreeMutationCoordinator.ProjectRegistryHost(
            target: oldTarget
        )
        #expect(coordinator.acquireProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            registryHost: registryHost
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [],
            presentationTargets: []
        )
        coordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: oldTarget
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: environment.snapshot,
            worktreeMutationCoordinator: coordinator,
            configuredSSHHostsProvider: { configuredHosts.value }
        )

        configuredHosts.send([])
        model.refreshHosts()

        #expect(coordinator.scopes.isEmpty)
        #expect(coordinator.acquireProjectRegistry(host: registryHost))
        coordinator.releaseProjectRegistry(host: registryHost)
        await model.shutdown()
    }

    @MainActor
    @Test("Nested restoration acquisition keeps later scenes fenced")
    func nestedRestorationAcquisitionKeepsLaterScenesFenced() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].generation =
            "0123456789abcdef0123456789abcdef"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let restoringSurfaces = SceneTmuxSurfaceStoreStub()
        let identityReads = Counter()
        let establishmentGate = KillGate()
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let restoringModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: restoringSurfaces,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxSessionIdentityReader: { _, _ in
                if identityReads.increment() > 1 {
                    await establishmentGate.suspend()
                }
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )
        let inventoryLoads = Counter()
        let observerModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                _ = inventoryLoads.increment()
                return inventory
            },
            worktreeMutationCoordinator: coordinator
        )
        restoringModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(
            restoringModel,
            store: restoringSurfaces
        )
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        #expect(coordinator.acquire(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        ))
        coordinator.prepareRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            worktrees: [WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: worktree.generation ?? ""
            )],
            presentationTargets: [selection]
        )
        #expect(restoringModel.activeBorrowedTmuxSelection == nil)

        coordinator.release(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            reconciledRestorationTargets: [selection],
            requiresWorkspaceReestablishment: true
        )

        await establishmentGate.waitUntilStarted()
        #expect(restoringModel.activeBorrowedTmuxSelection == selection)
        #expect(!coordinator.scopes.isEmpty)
        observerModel.startKwtInventory()
        try await Task.sleep(for: .milliseconds(100))
        #expect(inventoryLoads.count == 0)

        await establishmentGate.release()
        await waitUntilMainActor {
            inventoryLoads.count >= 1 && coordinator.scopes.isEmpty
        }
        await restoringModel.shutdown()
        await observerModel.shutdown()
    }

    @MainActor
    @Test("Empty project can resolve an uncertain removal")
    func emptyProjectResolvesUncertainRemoval() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees = []
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let inventory = WorkspaceTmuxTestSupport.inventory(project: project, worktrees: [])
        let coordinator = WorktreeMutationCoordinator()
        let inventoryLoads = Counter()
        let removalError = KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                switch inventoryLoads.increment() {
                case 1:
                    return inventory
                case 2:
                    throw KwtInventoryError.commandFailed(
                        host: "this Mac",
                        status: 75
                    )
                default:
                    return inventory
                }
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _, _ in throw removalError }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            removalError.localizedDescription
        )))
        #expect(inventoryLoads.count == 2)
        #expect(!coordinator.scopes.isEmpty)

        model.startKwtInventory()
        await waitUntilMainActor {
            inventoryLoads.count >= 3 && coordinator.scopes.isEmpty
        }
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Remove Project fences worktree changes and protected attachment"
    )
    func removeProjectFencesProjectOperationsAcrossScenes() async throws {
        let environment = try setupStandardEnvironment()
        var snapshot = environment.snapshot
        snapshot.projects[0].scopedKey = "github.com/kenn-io/ghosthub"
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let removableWorktree = WorktreeSummary(
            id: UUID(),
            hostID: environment.host.id,
            projectID: environment.project.id,
            scopedKey: "worktree:/tmp/ghosthub-concurrent",
            registryID: "mm-wt-concurrent",
            name: "concurrent",
            path: "/tmp/ghosthub-concurrent",
            branch: "feature/removable",
            isPrimary: false,
            generation: "0123456789abcdef0123456789abcdef"
        )
        snapshot.worktrees.append(removableWorktree)
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let probeGate = KillGate()
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let creationCalls = Counter()
        let worktreeRemovalCalls = Counter()
        let importCalls = Counter()
        let pathResolutions = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                await probeGate.suspend()
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let competingModel = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            nativeTmuxPathProvider: {
                _ = pathResolutions.increment()
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtWorktreeCreator: { _, _, _ in
                _ = creationCalls.increment()
            },
            kwtWorktreeRemover: { _, _, _, _, _ in
                _ = worktreeRemovalCalls.increment()
            },
            worktreeMutationCoordinator: coordinator,
            kwtPullRequestImporter: { _, _, _ in
                _ = importCalls.increment()
                throw KwtPullRequestError.malformedOutput(host: "This Mac")
            }
        )
        let worktreeRemovalRequest = try await competingModel
            .prepareWorktreeRemoval(removableWorktree.id)

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await removalModel.unregisterProject(
                project,
                confirmedHost: host
            )
        }
        await probeGate.waitUntilStarted()

        await #expect(throws: KwtWorktreeError.creationInProgress) {
            try await competingModel.createWorktree(
                WorktreeCreateRequest(
                    projectID: project.id,
                    branchName: "feature/concurrent",
                    createsBranch: true
                )
            )
        }
        await #expect(throws: KwtPullRequestError.importInProgress) {
            try await competingModel.importPullRequest(
                PullRequestImportRequest(
                    projectID: project.id,
                    pullRequestID: "github:github.com/kenn-io/ghosthub#94"
                )
            )
        }
        await #expect(throws: KwtWorktreeError.removalInProgress) {
            try await competingModel.removeWorktree(worktreeRemovalRequest)
        }
        competingModel.openBorrowedTmuxSession(selection)
        await waitUntilMainActor { pathResolutions.count == 1 }
        competingModel.prepareActiveBorrowedTmuxSurface()

        #expect(creationCalls.count == 0)
        #expect(worktreeRemovalCalls.count == 0)
        #expect(importCalls.count == 0)
        #expect(surfaceStore.requestCount == 0)
        #expect(removalCalls.count == 0)

        await probeGate.release()
        #expect(await removalTask.value == .success(project.name))
        #expect(removalCalls.count == 1)
        competingModel.prepareActiveBorrowedTmuxSurface()
        #expect(surfaceStore.requestCount == 0)
        #expect(competingModel.snapshot.project(id: project.id) == nil)
        #expect(competingModel.snapshot.worktree(id: worktree.id) == nil)
        #expect(coordinator.scopes.isEmpty)
        await removalModel.shutdown()
        await competingModel.shutdown()
    }

    @MainActor
    @Test("Protected attachment fences before its view renders")
    func protectedAttachmentFencesBeforeRendering() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator
        )

        model.openBorrowedTmuxSession(selection)

        #expect(coordinator.scopes == [
            WorktreeMutationCoordinator.Scope(
                hostID: project.hostID,
                projectIdentity: project.scopedKey
            ),
        ])
        let hostingView = hostView(rootView: AnyView(
            SceneModelRootHarness(model: model)
        ))
        #expect(coordinator.scopes.count == 1)
        withExtendedLifetime(hostingView) {}
        await model.shutdown()
    }

    @MainActor
    @Test("Protected attachment retries after a competing mutation")
    func protectedAttachmentRetriesAfterMutation() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let pathResolutions = Counter()
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        #expect(coordinator.acquire(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        ))
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                _ = pathResolutions.increment()
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator
        )

        model.openBorrowedTmuxSession(selection)
        await waitUntilMainActor {
            pathResolutions.count == 1
                && model.activeBorrowedTmuxSelection == selection
        }
        model.prepareActiveBorrowedTmuxSurface()

        #expect(surfaceStore.requestCount == 0)
        #expect(coordinator.scopes == [scope])

        coordinator.release(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        )

        await waitUntilMainActor {
            surfaceStore.requestCount == 1
                && coordinator.scopes == [scope]
        }
        await model.shutdown()
    }

    @MainActor
    @Test("Disconnected protected attachment waits for reconnect")
    func disconnectedProtectedAttachmentWaitsForReconnect() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let establishmentGate = BlockingGate()
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in
                establishmentGate.wait()
                return .success(false)
            },
            tmuxReconnectIntervals: [.seconds(10)]
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { establishmentGate.didStart }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        establishmentGate.release()
        await waitUntilMainActor { coordinator.scopes.isEmpty }

        #expect(coordinator.acquire(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        ))
        coordinator.release(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        )
        try await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.scopes.isEmpty)
        #expect(surfaceStore.requestCount == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Protected reconnect fences renewed establishment")
    func protectedReconnectFencesEstablishment() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let probeAttempts = Counter()
        let initialEstablishmentGate = BlockingGate()
        let reconnectEstablishmentGate = BlockingGate()
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let attachmentModel = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in
                switch probeAttempts.increment() {
                case 1:
                    initialEstablishmentGate.wait()
                    return .success(false)
                case 2:
                    return .success(false)
                default:
                    reconnectEstablishmentGate.wait()
                    return .success(true)
                }
            },
            createdSessionDiscoveryDelays: [.seconds(10)],
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        attachmentModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(
            attachmentModel,
            store: surfaceStore
        )
        await waitUntilMainActor { initialEstablishmentGate.didStart }

        surfaceStore.surface.closeObservers.values.first?(false, 255)
        initialEstablishmentGate.release()
        await waitUntilMainActor { reconnectEstablishmentGate.didStart }

        let result = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Another project or worktree change is already in progress."
        )))
        #expect(removalCalls.count == 0)
        #expect(!coordinator.scopes.isEmpty)
        reconnectEstablishmentGate.release()
        await attachmentModel.shutdown()
        await removalModel.shutdown()
    }

    @MainActor
    @Test(
        "Remove Project waits for protected establishment confirmation"
    )
    func removeProjectWaitsForProtectedEstablishment() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let establishmentGate = BlockingGate()
        let coordinator = WorktreeMutationCoordinator()
        let removalCalls = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let attachmentModel = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in
                establishmentGate.wait()
                return .success(true)
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )
        let removalModel = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        attachmentModel.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(
            attachmentModel,
            store: surfaceStore
        )
        await waitUntilMainActor { establishmentGate.didStart }
        #expect(attachmentModel.activeBorrowedTmuxSessionIsConnected)

        let result = await removalModel.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Another project or worktree change is already in progress."
        )))
        #expect(removalCalls.count == 0)
        #expect(!coordinator.scopes.isEmpty)

        establishmentGate.release()
        await waitUntilMainActor { coordinator.scopes.isEmpty }
        await attachmentModel.shutdown()
        await removalModel.shutdown()
    }

    @MainActor
    @Test("Protected establishment keeps probing while connected")
    func protectedEstablishmentKeepsProbing() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let probes = TmuxExactProbeResultQueue([
            .success(false),
            .success(false),
            .success(true),
        ])
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in probes.removeFirst() },
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { probes.count >= 2 }
        try await Task.sleep(for: .milliseconds(20))

        #expect(probes.count == 3)
        #expect(coordinator.scopes.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("Default-socket establishment keeps a finite probe schedule")
    func defaultSocketEstablishmentStopsProbing() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-main"
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let probes = Counter()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                _ = probes.increment()
                return .success([])
            },
            createdSessionDiscoveryDelays: [.milliseconds(1)]
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { probes.count >= 2 }
        try await Task.sleep(for: .milliseconds(20))

        #expect(probes.count == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("Pathless rebind releases protected establishment fence")
    func pathlessRebindReleasesProtectedEstablishmentFence() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let establishmentGate = BlockingGate()
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            worktreeMutationCoordinator: coordinator,
            tmuxExactSessionProbe: { _ in
                establishmentGate.wait()
                return .success(true)
            },
            createdSessionDiscoveryDelays: [.seconds(10)]
        )

        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        await waitUntilMainActor { establishmentGate.didStart }
        #expect(!coordinator.scopes.isEmpty)

        var reboundSelection = selection
        reboundSelection.workspacePath = nil
        model.openBorrowedTmuxSession(reboundSelection)

        #expect(coordinator.scopes.isEmpty)
        establishmentGate.release()
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project refreshes protected endpoints before removal")
    func removeProjectRefreshesProtectedEndpoints() async throws {
        let environment = try setupStandardEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        var refreshedWorktree = try #require(
            environment.snapshot.worktrees.first
        )
        refreshedWorktree.tmuxSessionName = "kwt-ghosthub-pr-94"
        refreshedWorktree.tmuxSocketName = "kwt-pr-94"
        refreshedWorktree.tmuxAttachMode = .protected
        let refreshedInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: [refreshedWorktree]
        )
        let identityReads = Counter()
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in refreshedInventory },
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { _, _ in
                _ = identityReads.increment()
                return TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1721552400"
                )
            }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            "Session “kwt-ghosthub-pr-94” is still running on its protected "
                + "tmux server. Kill it before removing project “Ghosthub”."
        )))
        #expect(identityReads.count == 1)
        #expect(removalCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project revalidates the host after protected probes")
    func removeProjectRevalidatesHostAfterProtectedProbe() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-pr-94"
        snapshot.worktrees[0].tmuxSocketName = "kwt-pr-94"
        snapshot.worktrees[0].tmuxAttachMode = .protected
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let currentInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let staleRepository = "repo:old-probe-endpoint-only"
        var staleInventory = currentInventory
        staleInventory.projects.append(KwtProjectInventory(
            project: KwtProjectRecord(
                repository: staleRepository,
                name: "Old Probe Endpoint Only",
                path: "/tmp/old-probe-endpoint-only",
                lastTouched: nil
            ),
            worktrees: [],
            warning: nil
        ))
        let oldEndpointInventory = staleInventory
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let probeGate = KillGate()
        let inventoryLoads = Counter()
        let servesOldEndpointInventory = LockedValue(false)
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                let inventory = servesOldEndpointInventory.load()
                    ? oldEndpointInventory : currentInventory
                _ = inventoryLoads.increment()
                return inventory
            },
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            tmuxSessionIdentityReader: { selection, host in
                await probeGate.suspend()
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        model.startKwtInventory()
        await waitUntilMainActor { inventoryLoads.count >= 1 }
        let loadsBeforeRemoval = inventoryLoads.count
        servesOldEndpointInventory.store(true)
        let publishedRepositories = LockedValue<[Set<String>]>([])
        let snapshotObservation = model.$snapshot.sink { snapshot in
            publishedRepositories.withLock {
                $0.append(Set(snapshot.projects.map(\.scopedKey)))
            }
        }

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await probeGate.waitUntilStarted()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "wesm@replacement-office-linux"
            ),
        ])
        servesOldEndpointInventory.store(false)
        model.refreshHosts()
        await probeGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        await waitUntilMainActor {
            inventoryLoads.count >= loadsBeforeRemoval + 2
        }
        #expect(!publishedRepositories.load().contains {
            $0.contains(staleRepository)
        })
        #expect(removalCalls.count == 0)
        withExtendedLifetime(snapshotObservation) {}
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project rejects SSH route drift after confirmation")
    func removeProjectRejectsRouteDrift() async throws {
        let environment = try setupRemoteEnvironment()
        let project = try #require(environment.snapshot.projects.first)
        let host = try #require(environment.snapshot.hosts.first)
        let route = LockedValue("sha256:reviewed-route")
        let removalCalls = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtInventoryLoader: { _ in
                WorkspaceTmuxTestSupport.inventory(
                    project: project,
                    worktrees: environment.snapshot.worktrees
                )
            },
            sshRouteIdentityResolver: { _ in route.load() },
            kwtProjectRemoval: { path, _, _, _, _ in
                _ = removalCalls.increment()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            }
        )

        let request = try await model.prepareProjectRemoval(
            project,
            confirmedHost: host
        )
        route.store("sha256:replacement-route")
        let result = await model.unregisterProject(request)

        #expect(result == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        #expect(removalCalls.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project does not reconcile through a changed SSH route")
    func removeProjectRejectsReconciliationRouteDrift() async throws {
        let environment = try setupRemoteEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let host = try #require(snapshot.hosts.first)
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let inventoryLoads = Counter()
        let reconciliationLoads = Counter()
        let removalError = KwtInventoryError.commandFailed(
            host: environment.host.name,
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                inventoryLoads.increment() == 1
                    ? inventory
                    : KwtHostInventory(projects: [])
            },
            kwtConditionalInventoryLoader: { _, _ in
                _ = reconciliationLoads.increment()
                throw KwtSSHLeaseError.routeChanged
            },
            sshRouteIdentityResolver: { _ in "sha256:reviewed-route" },
            kwtProjectRemoval: { _, _, _, _, _ in throw removalError }
        )

        let result = await model.unregisterProject(
            project,
            confirmedHost: host
        )

        #expect(result == .failure(.message(
            removalError.localizedDescription
        )))
        #expect(model.snapshot.project(id: project.id) != nil)
        #expect(reconciliationLoads.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project revalidates the host after unregistration")
    func removeProjectRevalidatesHostAfterUnregistration() async throws {
        let environment = try setupRemoteEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let removalGate = KillGate()
        let coordinator = WorktreeMutationCoordinator()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                await removalGate.suspend()
                return KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: path,
                    lastTouched: nil
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await removalGate.waitUntilStarted()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "wesm@replacement-office-linux"
            ),
        ])
        model.refreshHosts()
        await removalGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        #expect(coordinator.scopes.isEmpty)
        let registryHost = WorktreeMutationCoordinator.ProjectRegistryHost(
            target: .ssh(SSHHostInfo(
                user: "wesm",
                hostname: "office-linux",
                port: 22,
                platform: .posix
            ))
        )
        #expect(coordinator.acquireProjectRegistry(host: registryHost))
        coordinator.releaseProjectRegistry(host: registryHost)
        await model.shutdown()
    }

    @MainActor
    @Test("Registration change cannot restore on a replacement host")
    func registrationChangeDoesNotRestoreOnReplacementHost() async throws {
        let environment = try setupRemoteEnvironment()
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "kwt-ghosthub-root"
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let worktree = try #require(snapshot.worktrees.first)
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let removalGate = KillGate()
        let coordinator = WorktreeMutationCoordinator()
        let surfaceStore = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            nativeTmuxSurfaceStore: surfaceStore,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            kwtInventoryLoader: { _ in inventory },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _, _ in
                await removalGate.suspend()
                throw KwtProjectCommandError.commandFailed(
                    host: initialHost.name,
                    status: 1,
                    code: "registration_changed",
                    message: "project registration changed",
                    retryable: true,
                    details: [:]
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: surfaceStore)
        let initialRequestCount = surfaceStore.requestCount

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await removalGate.waitUntilStarted()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "wesm@replacement-office-linux"
            ),
        ])
        model.refreshHosts()
        await removalGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        #expect(coordinator.scopes.isEmpty)
        #expect(model.activeBorrowedTmuxSelection == nil)
        #expect(surfaceStore.requestCount == initialRequestCount)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Host deletion releases removal coordination",
        arguments: ProjectRemovalHostDeletionPhase.allCases
    )
    func hostDeletionReleasesRemovalCoordination(
        phase: ProjectRemovalHostDeletionPhase
    ) async throws {
        let environment = try setupRemoteEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let suspensionGate = KillGate()
        let inventoryLoads = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let removalError = KwtInventoryError.commandFailed(
            host: initialHost.name,
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                if phase == .reconciliation,
                   inventoryLoads.increment() == 2 {
                    await suspensionGate.suspend()
                }
                return inventory
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { path, _, _, _, _ in
                switch phase {
                case .unregistration:
                    await suspensionGate.suspend()
                    return KwtProjectRecord(
                        repository: project.scopedKey,
                        name: project.name,
                        path: path,
                        lastTouched: nil
                    )
                case .reconciliation:
                    throw removalError
                }
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await suspensionGate.waitUntilStarted()
        configuredHosts.send([])
        model.refreshHosts()
        await suspensionGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        #expect(coordinator.scopes.isEmpty)
        let registryHost = WorktreeMutationCoordinator.ProjectRegistryHost(
            target: .ssh(SSHHostInfo(
                user: "wesm",
                hostname: "office-linux",
                port: 22,
                platform: .posix
            ))
        )
        #expect(coordinator.acquireProjectRegistry(host: registryHost))
        coordinator.releaseProjectRegistry(host: registryHost)
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project discards reconciliation from a changed host")
    func removeProjectDiscardsReconciliationFromChangedHost() async throws {
        let environment = try setupRemoteEnvironment()
        let snapshot = environment.snapshot
        let project = try #require(snapshot.projects.first)
        let confirmedHost = try #require(snapshot.hosts.first)
        let currentInventory = WorkspaceTmuxTestSupport.inventory(
            project: project,
            worktrees: snapshot.worktrees
        )
        let staleRepository = "repo:old-endpoint-only"
        var staleInventory = currentInventory
        staleInventory.projects.append(KwtProjectInventory(
            project: KwtProjectRecord(
                repository: staleRepository,
                name: "Old Endpoint Only",
                path: "/tmp/old-endpoint-only",
                lastTouched: nil
            ),
            worktrees: [],
            warning: nil
        ))
        let staleEndpointInventory = staleInventory
        let initialHost = SSHHost(
            configKey: environment.host.configKey,
            name: environment.host.name,
            platform: environment.host.platform,
            sshDestination: try #require(
                environment.host.sshDestination
            )
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            initialHost,
        ])
        let reconciliationGate = KillGate()
        let inventoryLoads = Counter()
        let coordinator = WorktreeMutationCoordinator()
        let removalError = KwtInventoryError.commandFailed(
            host: initialHost.name,
            status: 1
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                switch inventoryLoads.increment() {
                case 1:
                    return currentInventory
                case 2:
                    await reconciliationGate.suspend()
                    return staleEndpointInventory
                default:
                    return currentInventory
                }
            },
            worktreeMutationCoordinator: coordinator,
            kwtProjectRemoval: { _, _, _, _, _ in throw removalError },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        let publishedRepositories = LockedValue<[Set<String>]>([])
        let snapshotObservation = model.$snapshot.sink { snapshot in
            publishedRepositories.withLock {
                $0.append(Set(snapshot.projects.map(\.scopedKey)))
            }
        }

        let removalTask: Task<Result<String, HostProbeError>, Never> = Task {
            @MainActor in
            await model.unregisterProject(
                project,
                confirmedHost: confirmedHost
            )
        }
        await reconciliationGate.waitUntilStarted()
        configuredHosts.send([
            SSHHost(
                configKey: initialHost.configKey,
                name: initialHost.name,
                platform: initialHost.platform,
                sshDestination: "wesm@replacement-office-linux"
            ),
        ])
        model.refreshHosts()
        await reconciliationGate.release()

        #expect(await removalTask.value == .failure(.message(
            "The project or host connection changed. Try removing it again."
        )))
        model.startKwtInventory()
        await waitUntilMainActor {
            inventoryLoads.count >= 3 && coordinator.scopes.isEmpty
        }
        #expect(!publishedRepositories.load().contains {
            $0.contains(staleRepository)
        })
        withExtendedLifetime(snapshotObservation) {}
        await model.shutdown()
    }

    @MainActor
    @Test("Remove Project authority rejects project identity drift")
    func removeProjectAuthorityRejectsProjectIdentityDrift() throws {
        let environment = try setupStandardEnvironment()
        let confirmedProject = try #require(
            environment.snapshot.projects.first
        )
        let currentHost = try #require(environment.snapshot.hosts.first)

        var movedProject = confirmedProject
        movedProject.rootPath = "/tmp/ghosthub-moved"
        #expect(WorkspaceSceneModel.validatedProjectRemovalTarget(
            confirmedProject,
            confirmedHostID: currentHost.id,
            capturedTarget: .local,
            currentProject: movedProject,
            currentHost: currentHost
        ) == nil)

        var replacedProject = confirmedProject
        replacedProject.scopedKey = "github.com/kenn-io/replacement"
        #expect(WorkspaceSceneModel.validatedProjectRemovalTarget(
            confirmedProject,
            confirmedHostID: currentHost.id,
            capturedTarget: .local,
            currentProject: replacedProject,
            currentHost: currentHost
        ) == nil)
    }

}
