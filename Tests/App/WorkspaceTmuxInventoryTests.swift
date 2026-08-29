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
    @Test("startup publishes existing local tmux sessions")
    func startupPublishesExistingSessions() async throws {
        let environment = try setupStandardEnvironment()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { host in
                #expect(host == .local)
                return .success([
                    DiscoveredTmuxSession(
                        name: "docbank",
                        windowCount: 4,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ])
            },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
        }

        let session = try #require(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.first
        )
        #expect(session.windows.count == 4)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "automatic kwt provisioning follows the remote platform policy",
        arguments: [
            (HostPlatform.macOS, true),
            (HostPlatform.linux, true),
            (HostPlatform.windows, false),
        ]
    )
    func automaticKwtProvisioning(
        platform: HostPlatform,
        expected: Bool
    ) async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "remote",
            name: "Remote",
            platform: platform,
            sshDestination: "remote"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let provisioningAttempts = Counter()
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                    #expect((provisioningAttempts.count > 0) == expected)
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                #expect(host.platform == platform)
                _ = provisioningAttempts.increment()
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect((provisioningAttempts.count > 0) == expected)
        await model.shutdown()
    }

    @MainActor
    @Test("automatic kwt provisioning includes exe.dev hosts")
    func automaticKwtProvisioningIncludesExeHosts() async throws {
        let environment = try setupStandardEnvironment()
        let exeHost = ExeConfiguredHost(
            sshHost: SSHHost(
                configKey: "exe-dev.personal.build",
                name: "build",
                platform: .linux,
                sshDestination: "vm+build@exe.dev"
            ),
            metadata: ExeVMMetadata(
                accountConfigKey: "personal",
                accountName: "Personal",
                vmName: "build"
            )
        )
        let provisionedHost = LockedValue<SSHHost?>(nil)
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                provisionedHost.store(host)
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredExeHostsProvider: { [exeHost] },
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect(provisionedHost.load() == exeHost.sshHost)
        await model.shutdown()
    }

    @MainActor
    @Test("manual SSH hosts retain kwt provisioning precedence")
    func manualHostsRetainKwtProvisioningPrecedence() async throws {
        let environment = try setupStandardEnvironment()
        let manualHost = SSHHost(
            configKey: "manual-build",
            name: "Manual Build",
            platform: .linux,
            sshDestination: "build.exe.xyz"
        )
        let exeHost = ExeConfiguredHost(
            sshHost: SSHHost(
                configKey: "exe-dev.personal.build",
                name: "build",
                platform: .linux,
                sshDestination: manualHost.sshDestination
            ),
            metadata: ExeVMMetadata(
                accountConfigKey: "personal",
                accountName: "Personal",
                vmName: "build"
            )
        )
        let provisionedHost = LockedValue<SSHHost?>(nil)
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { host in
                provisionedHost.store(host)
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { [manualHost] },
            configuredExeHostsProvider: { [exeHost] },
            startServices: true
        )

        await waitUntilMainActor {
            remoteInventoryLoads.count > 0
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect(provisionedHost.load() == manualHost)
        await model.shutdown()
    }

    @MainActor
    @Test("kwt provisioning failure leaves remote tmux inventory available")
    func provisioningFailureDoesNotBlockTmux() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let remoteInventoryLoads = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                if host.isRemote {
                    _ = remoteInventoryLoads.increment()
                }
                return KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { _ in
                throw KwtRemoteInstallError.bundleIncomplete
            },
            tmuxSessionDiscovery: { host in
                .success(host.isRemote ? [
                    DiscoveredTmuxSession(
                        name: "build",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ] : [])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.tmuxSessions.map(\.name) == ["build"]
                }
                && model.isWorkspaceInventoryRefreshComplete
        }

        #expect(remoteInventoryLoads.count == 0)
        let remoteSummary = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        #expect(model.workspaceInventoryWarningsByHost[remoteSummary.id] == nil)
        #expect(remoteSummary.primaryDiagnostic == nil)
        #expect(remoteSummary.connectionState == .online)
        #expect(remoteSummary.lastKnownReachable)
        await model.shutdown()
    }

    @MainActor
    @Test("Windows kwt inventory failure preserves the actual error")
    func windowsKwtInventoryFailurePreservesError() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .windows,
            sshDestination: "build-box"
        )
        let inventoryFailure = KwtInventoryError.commandFailed(
            host: remote.sshDestination,
            status: 1
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                guard host.isRemote else {
                    return KwtHostInventory(projects: [])
                }
                throw inventoryFailure
            },
            tmuxSessionDiscovery: { host in
                .success(host.isRemote ? [
                    DiscoveredTmuxSession(
                        name: "build",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ] : [])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryWarningsByHost.values.contains(
                inventoryFailure.localizedDescription
            )
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.tmuxSessions.map(\.name) == ["build"]
                }
        }

        let remoteSummary = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        #expect(remoteSummary.tmuxSessions.map(\.name) == ["build"])
        #expect(remoteSummary.primaryDiagnostic == nil)
        #expect(remoteSummary.canCreateWorktree)
        #expect(
            model.workspaceInventoryWarningsByHost[remoteSummary.id]
                == inventoryFailure.localizedDescription
        )
        await model.shutdown()
    }

    @MainActor
    @Test("an unreachable SSH host does not block local inventory")
    func unreachableRemoteDoesNotBlockLocalInventory() async throws {
        let environment = try setupStandardEnvironment()
        let transport = SSHConnectionFailure.classify(
            status: 255,
            output: "ssh: connect to host wesm-mbp port 22: Network is unreachable"
        )
        let remote = SSHHost(
            configKey: "wesm-mbp",
            name: "Wes MBP",
            platform: .macOS,
            sshDestination: "wesm@wesm-mbp"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                switch host {
                case .local:
                    return KwtHostInventory(projects: [])
                case let .ssh(info):
                    throw KwtInventoryError.commandFailed(
                        host: info.displayName,
                        status: 255
                    )
                }
            },
            tmuxSessionDiscovery: { host in
                switch host {
                case .local:
                    return .success([
                        DiscoveredTmuxSession(
                            name: "docbank",
                            windowCount: 4,
                            createdAt: "1721552400",
                            managed: false
                        ),
                    ])
                case .ssh:
                    return .failure(.sshConnectionFailed(
                        host: remote.name,
                        classification: transport
                    ))
                }
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
                && model.workspaceInventoryWarningsByHost.values.contains {
                    $0.contains("Wes MBP")
                }
        }

        #expect(model.workspaceInventoryState == .loaded)
        #expect(
            model.snapshot.host(id: environment.host.id)?
                .tmuxSessions.map(\.name) == ["docbank"]
        )
        #expect(model.workspaceInventoryWarning == nil)
        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        let remoteSummary = try #require(
            model.snapshot.host(id: remoteHostID)
        )
        #expect(remoteSummary.connectionState == .offline)
        #expect(remoteSummary.primaryDiagnostic?.code == .probeFailure)
        #expect(remoteSummary.lastSeenAt == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[remoteHostID]?
                .contains("could not reach") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("missing tmux does not make a Herdr-capable host offline")
    func missingTmuxKeepsHerdrHostReachable() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "herdr-box",
            name: "Herdr Box",
            platform: .linux,
            sshDestination: "dev@herdr-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let running = HerdrSessionSummary(
            name: "api",
            isDefault: true,
            state: .running
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionDiscovery: { host in
                switch host {
                case .local:
                    return .success([])
                case .ssh:
                    return .failure(.notFound(shell: remote.name))
                }
            },
            herdrSessionDiscovery: { host in
                switch host {
                case .local:
                    return .unavailable
                case .ssh:
                    return .available([running])
                }
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.herdrSessions == [running]
                }
        }

        let summary = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        #expect(summary.lastKnownReachable)
        #expect(summary.connectionState != .offline)
        #expect(summary.herdrAvailable)
        #expect(model.workspaceInventoryWarningsByHost[summary.id]?
            .contains("tmux was not found") == true)
        await model.shutdown()
    }

    @MainActor
    @Test("fresh failure of every inventory source is retryable")
    func allSourcesFailWithoutInventory() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: 1
                )
            },
            tmuxSessionDiscovery: { _ in
                .failure(.shellFailed(status: 1))
            },
            startServices: true
        )

        await waitUntilMainActor {
            if case .failed = model.workspaceInventoryState {
                return true
            }
            return false
        }

        guard case let .failed(message) = model.workspaceInventoryState else {
            Issue.record("Expected total inventory failure")
            await model.shutdown()
            return
        }
        #expect(message.contains("status 1"))
        #expect(model.workspaceInventoryWarning == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[environment.host.id]?
                .contains("status 1") == true
        )
        #expect(model.snapshot.projects.isEmpty)
        #expect(
            model.snapshot.hosts.allSatisfy { $0.tmuxSessions.isEmpty }
        )
        await model.shutdown()
    }

    @MainActor
    @Test("missing kwt does not block an SSH host's tmux inventory")
    func remoteWithoutKwtDoesNotBlockTmux() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "tmux-only",
            name: "Tmux Only",
            platform: .linux,
            sshDestination: "tmux-only"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                guard host.isRemote else {
                    return KwtHostInventory(projects: [])
                }
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: 127
                )
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
        }

        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        #expect(model.workspaceInventoryWarningsByHost[remoteHostID] == nil)
        let remoteSummary = try #require(
            model.snapshot.host(id: remoteHostID)
        )
        #expect(remoteSummary.primaryDiagnostic == nil)
        #expect(remoteSummary.lastKnownReachable)
        #expect(remoteSummary.connectionState == .online)
        #expect(remoteSummary.canCreateWorktree)
        await model.shutdown()
    }

    @MainActor
    @Test("losing remote kwt repairs before branch listing")
    func remoteKwtLossRepairsBeforeBranchListing() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let inventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "github.com/kenn-io/docbank",
                    name: "docbank",
                    path: "/srv/docbank",
                    lastTouched: nil
                ),
                worktrees: [],
                warning: nil
            ),
        ])
        let provisioningShouldFail = LockedValue(false)
        let provisioningAttempts = Counter()
        let branchListAttempts = Counter()
        let branch = WorktreeBranchCandidate(
            name: "feature/repaired",
            source: "feature/repaired",
            isRemote: false
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                host.isRemote ? inventory : KwtHostInventory(projects: [])
            },
            kwtRemoteProvisioner: { _ in
                _ = provisioningAttempts.increment()
                if provisioningShouldFail.load() {
                    throw KwtRemoteInstallError.bundleIncomplete
                }
            },
            kwtBranchLister: { _, _ in
                _ = branchListAttempts.increment()
                return [branch]
            },
            tmuxSessionDiscovery: { host in
                .success(host.isRemote ? [
                    DiscoveredTmuxSession(
                        name: "docbank",
                        windowCount: 1,
                        createdAt: "1721552400",
                        managed: false
                    ),
                ] : [])
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.projects.contains { $0.name == "docbank" }
                && model.snapshot.hosts.contains {
                    $0.configKey == remote.configKey
                        && $0.tmuxSessions.contains { $0.name == "docbank" }
                }
        }
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.name == "docbank" }
        )
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))

        provisioningShouldFail.store(true)
        let attemptsBeforeFailure = provisioningAttempts.count
        model.refreshKwtInventory()
        await waitUntilMainActor {
            provisioningAttempts.count > attemptsBeforeFailure
                && model.isWorkspaceInventoryRefreshComplete
        }

        let unavailableHost = try #require(
            model.snapshot.host(id: cachedProject.hostID)
        )
        #expect(unavailableHost.canCreateWorktree)
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(unavailableHost.tmuxSessions.map(\.name) == ["docbank"])
        #expect(unavailableHost.primaryDiagnostic == nil)
        #expect(model.workspaceInventoryWarningsByHost[unavailableHost.id] == nil)

        provisioningShouldFail.store(false)
        let attemptsBeforeAction = provisioningAttempts.count
        let branches = try await model.branches(for: cachedProject.id)

        #expect(provisioningAttempts.count == attemptsBeforeAction + 1)
        #expect(branches == [branch])
        #expect(branchListAttempts.count == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("repair failure prevents branch listing")
    func repairFailurePreventsBranchListing() async throws {
        let environment = try setupRemoteEnvironment()
        let branchListAttempts = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            kwtRemoteProvisioner: { _ in
                throw KwtRemoteInstallError.bundleIncomplete
            },
            kwtBranchLister: { _, _ in
                _ = branchListAttempts.increment()
                return [
                    WorktreeBranchCandidate(
                        name: "feature/should-not-run",
                        source: "feature/should-not-run",
                        isRemote: false
                    ),
                ]
            }
        )

        await #expect(throws: KwtRemoteInstallError.bundleIncomplete) {
            try await model.branches(for: environment.project.id)
        }
        #expect(branchListAttempts.count == 0)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "status 127 during creation keeps repair actions available",
        arguments: CreationKwtFailurePhase.allCases
    )
    private func creationKwtLossKeepsCapability(
        phase: CreationKwtFailurePhase
    ) async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let availability = KwtAvailabilityState(
            remoteInventory: KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: "github.com/kenn-io/docbank",
                        name: "docbank",
                        path: "/srv/docbank",
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        )
        let creationAttempts = Counter()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                try availability.load(host)
            },
            kwtWorktreeCreator: { _, _, host in
                _ = creationAttempts.increment()
                if phase == .command {
                    throw KwtWorktreeError.commandFailed(
                        host: host.displayName,
                        status: 127
                    )
                }
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.projects.contains { $0.name == "docbank" }
        }
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.name == "docbank" }
        )
        availability.markRemoteKwtUnavailable()

        do {
            try await model.createWorktree(WorktreeCreateRequest(
                projectID: cachedProject.id,
                branchName: "feature/kwt-disappeared",
                createsBranch: true
            ))
            Issue.record("Expected status 127 from worktree creation")
        } catch {
            switch (phase, error) {
            case let (.command, worktreeError as KwtWorktreeError):
                #expect(
                    worktreeError == .commandFailed(
                        host: "build-box",
                        status: 127
                    )
                )
            case let (.inventoryRefresh, inventoryError as KwtInventoryError):
                #expect(
                    inventoryError == .commandFailed(
                        host: "build-box",
                        status: 127
                    )
                )
            default:
                Issue.record("Unexpected status-127 error: \(error)")
            }
        }

        await waitUntilMainActor {
            availability.remoteLoadCount >= 2
        }
        #expect(creationAttempts.count == 1)
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))
        #expect(
            model.snapshot.host(id: cachedProject.hostID)?
                .primaryDiagnostic == nil
        )
        await model.shutdown()
    }

    @MainActor
    @Test("tmux discovery failure invalidates prior host reachability")
    func tmuxFailureMarksPreviouslyReachableHostOffline() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "build-box",
            name: "Build Box",
            platform: .linux,
            sshDestination: "build-box"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let availability = KwtAvailabilityState(
            remoteInventory: KwtHostInventory(projects: [
                KwtProjectInventory(
                    project: KwtProjectRecord(
                        repository: "github.com/kenn-io/docbank",
                        name: "docbank",
                        path: "/srv/docbank",
                        lastTouched: nil
                    ),
                    worktrees: [],
                    warning: nil
                ),
            ])
        )
        let reachability = TmuxReachabilityState()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                try availability.load(host)
            },
            tmuxSessionDiscovery: reachability.discover,
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            model.snapshot.hosts.contains {
                $0.configKey == remote.configKey
                    && $0.lastKnownReachable
                    && $0.tmuxSessions.map(\.name) == ["docbank"]
            }
        }
        let remoteHost = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        let lastSeenAt = try #require(remoteHost.lastSeenAt)
        let cachedProject = try #require(
            model.snapshot.projects.first { $0.hostID == remoteHost.id }
        )
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))

        reachability.markRemoteUnreachable()
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: remoteHost.id)?.connectionState == .offline
        }

        let offlineHost = try #require(model.snapshot.host(id: remoteHost.id))
        #expect(!offlineHost.lastKnownReachable)
        #expect(offlineHost.lastSeenAt == lastSeenAt)
        #expect(offlineHost.tmuxSessions.map(\.name) == ["docbank"])
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
        #expect(
            model.workspaceInventoryWarningsByHost[offlineHost.id]?
                .contains("could not reach") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe accepts a tmux-only SSH host")
    func connectionProbeAcceptsRemoteWithoutKwt() async throws {
        let environment = try setupStandardEnvironment()
        let released = LockedValue(false)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, connectionArguments, command in
                #expect(connectionArguments == ["-test-connection"])
                #expect(command.contains("command -v tmux"))
                #expect(command.contains(
                    "GHOSTHUB_SSH_PROBE_TEST-NONCE_START"
                ))
                return (
                    status: 0,
                    stdout: WorkspaceTmuxTestSupport.probeOutput(
                        [
                            "GHOSTHUB_SSH_REACHED",
                            "GHOSTHUB_TMUX_AVAILABLE",
                            "GHOSTHUB_KWT_UNAVAILABLE",
                        ],
                        startupOutput: "unterminated startup output"
                    ),
                    stderr: ""
                )
            },
            hostSSHConnectionProvider: { host, destination in
                #expect(host.hostname == "tmux-only")
                #expect(destination == "tmux-only")
                return testKwtSSHAttachment(
                    arguments: ["-test-connection"],
                    release: { released.store(true) }
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "tmux-only",
            name: "Tmux Only",
            platform: .linux,
            sshDestination: "tmux-only"
        ), protocolNonce: WorkspaceTmuxTestSupport.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .online)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.diagnostics.isEmpty)
        #expect(released.load())
        await model.shutdown()
    }

    @MainActor
    @Test("successful authentication keeps its lease for the follow-up probe")
    func authenticationLeaseFeedsFollowUpProbe() async throws {
        let environment = try setupStandardEnvironment()
        let acquisitions = LockedValue(0)
        let releases = LockedValue(0)
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(hostname: "password-only"),
            targets: [
                KwtSSHResolvedTarget(
                    logicalTarget: KwtSSHTarget(hostname: "password-only"),
                    effectiveTarget: KwtSSHTarget(hostname: "password-only"),
                    displayTarget: "password-only",
                    hostKeyAlias: nil,
                    strictHostKeyChecking: "ask",
                    projection: KwtSSHExecutionProjection(
                        arguments: ["-F", "/dev/null"],
                        privateConfig: []
                    )
                ),
            ]
        )
        let host = SSHHost(
            configKey: "password-only",
            name: "Password Only",
            platform: .linux,
            sshDestination: "password-only"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, arguments, _ in
                #expect(arguments == ["-S", "/tmp/password-only.sock"])
                return (
                    status: 0,
                    stdout: WorkspaceTmuxTestSupport.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_AVAILABLE",
                        "GHOSTHUB_KWT_AVAILABLE",
                    ]),
                    stderr: ""
                )
            },
            hostSSHConnectionProvider: nil,
            hostSSHSessionProvider: { sessionHost, destination in
                KwtSSHConnectionSession(
                    route: route,
                    host: sessionHost,
                    destination: destination,
                    pool: KwtSSHConnectionPool { route, _ in
                        acquisitions.withLock { $0 += 1 }
                        return KwtSSHTestLease(
                            routeIdentity: route.routeIdentity,
                            arguments: ["-S", "/tmp/password-only.sock"],
                            releaseCount: releases
                        )
                    }
                )
            }
        )

        let requirement = await model.pendingSSHHostKeyConfirmation(for: host)
        #expect(try requirement.get() == .none)
        let surfaceID = UUID()
        _ = model.sshAuthenticationView(surfaceID: surfaceID, for: host)
        #expect(await model.isSSHAuthenticationReady(for: host) == .connected)

        model.retainSSHAuthenticationForHandoff(surfaceID: surfaceID)
        let probe = await model.probeSSHHost(
            host,
            protocolNonce: WorkspaceTmuxTestSupport.probeNonce
        )

        #expect(try probe.get().connectionState == .online)
        #expect(acquisitions.load() == 1)
        #expect(releases.load() == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("canceling connected authentication releases instead of retaining")
    func cancelingConnectedAuthenticationReleasesLease() async throws {
        let environment = try setupStandardEnvironment()
        let acquisitions = LockedValue(0)
        let releases = LockedValue(0)
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(hostname: "cancel.example.test")
        )
        let host = SSHHost(
            configKey: "cancel",
            name: "Cancel",
            platform: .linux,
            sshDestination: "cancel.example.test"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            hostSSHSessionProvider: { sessionHost, destination in
                KwtSSHConnectionSession(
                    route: route,
                    host: sessionHost,
                    destination: destination,
                    pool: KwtSSHConnectionPool { route, _ in
                        acquisitions.withLock { $0 += 1 }
                        return KwtSSHTestLease(
                            routeIdentity: route.routeIdentity,
                            releaseCount: releases
                        )
                    }
                )
            }
        )

        let requirement = await model.pendingSSHHostKeyConfirmation(for: host)
        #expect(try requirement.get() == .none)
        let surfaceID = UUID()
        _ = model.sshAuthenticationView(surfaceID: surfaceID, for: host)
        #expect(await model.isSSHAuthenticationReady(for: host) == .connected)

        model.cancelSSHAuthentication(surfaceID: surfaceID)
        await waitUntil { releases.load() == 1 }

        #expect(model.hostSSHSession == nil)
        let retry = await model.pendingSSHHostKeyConfirmation(for: host)
        #expect(try retry.get() == .none)
        #expect(acquisitions.load() == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("exe.dev discovery consumes and releases its reviewed lease")
    func exeDiscoveryConsumesAuthenticationLease() async throws {
        let environment = try setupStandardEnvironment()
        let releases = LockedValue(0)
        let capturedArguments = LockedValue<[String]?>(nil)
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(hostname: "exe.dev")
        )
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )
        let host = SSHHost(
            configKey: "exe-control.personal",
            name: "Personal",
            platform: .linux,
            sshDestination: account.sshDestination
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            hostSSHSessionProvider: { sessionHost, destination in
                KwtSSHConnectionSession(
                    route: route,
                    host: sessionHost,
                    destination: destination,
                    pool: KwtSSHConnectionPool { route, _ in
                        KwtSSHTestLease(
                            routeIdentity: route.routeIdentity,
                            arguments: ["-S", "/tmp/exe-reviewed.sock"],
                            releaseCount: releases
                        )
                    }
                )
            }
        )

        let requirement = await model.pendingSSHHostKeyConfirmation(for: host)
        #expect(try requirement.get() == .none)
        let surfaceID = UUID()
        _ = model.sshAuthenticationView(surfaceID: surfaceID, for: host)
        model.retainSSHAuthenticationForHandoff(surfaceID: surfaceID)

        let result = await model.probeExeAccountConnection(account) {
            _, connection in
            capturedArguments.store(connection?.arguments)
            return .connected([])
        }

        #expect(result == .connected([]))
        #expect(
            capturedArguments.load() == ["-S", "/tmp/exe-reviewed.sock"]
        )
        #expect(releases.load() == 1)
        #expect(model.hostSSHSession == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("canceling host-key review cancels its pending SSH prompt")
    func cancelingHostKeyReviewCancelsPrompt() async throws {
        let environment = try setupStandardEnvironment()
        let sessions = LockedValue(0)
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(hostname: "review.example.test"),
            targets: [
                KwtSSHResolvedTarget(
                    logicalTarget: KwtSSHTarget(
                        hostname: "review.example.test"
                    ),
                    effectiveTarget: KwtSSHTarget(
                        hostname: "review.example.test"
                    ),
                    displayTarget: "review.example.test",
                    hostKeyAlias: nil,
                    strictHostKeyChecking: "ask",
                    projection: KwtSSHExecutionProjection(
                        arguments: ["-F", "/dev/null"],
                        privateConfig: []
                    )
                ),
            ]
        )
        let prompt = KwtSSHLeasePrompt.fixture(
            id: "host-key-review",
            kind: .hostKey,
            message: "Review this host key.",
            route: route,
            hopIndex: 0,
            hostKey: KwtSSHHostKeyReview(
                host: "review.example.test",
                algorithm: "ED25519",
                fingerprint: "SHA256:review"
            )
        )
        let host = SSHHost(
            configKey: "review",
            name: "Review",
            platform: .linux,
            sshDestination: "review.example.test"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            hostSSHSessionProvider: { sessionHost, destination in
                sessions.withLock { $0 += 1 }
                let attempt = sessions.load()
                return KwtSSHConnectionSession(
                    route: route,
                    host: sessionHost,
                    destination: destination,
                    pool: KwtSSHConnectionPool { _, answer in
                        if attempt == 1 {
                            _ = try await answer(prompt)
                        }
                        return KwtSSHTestLease(
                            routeIdentity: route.routeIdentity
                        )
                    }
                )
            }
        )

        let reviewID = UUID()
        let requirement = await model.pendingSSHHostKeyConfirmation(
            for: host,
            reviewID: reviewID
        )
        guard case .success(.confirmation) = requirement else {
            Issue.record("Expected a host-key review requirement")
            await model.shutdown()
            return
        }

        model.cancelSSHAuthentication(surfaceID: reviewID)
        let retry = await model.pendingSSHHostKeyConfirmation(for: host)

        #expect(try retry.get() == .none)
        #expect(sessions.load() == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("stale review cancellation preserves the current SSH owner")
    func staleReviewCancellationPreservesCurrentOwner() async throws {
        let environment = try setupStandardEnvironment()
        let releases = LockedValue(0)
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(hostname: "owner.example.test")
        )
        let host = SSHHost(
            configKey: "owner",
            name: "Owner",
            platform: .linux,
            sshDestination: "owner.example.test"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            hostSSHSessionProvider: { sessionHost, destination in
                KwtSSHConnectionSession(
                    route: route,
                    host: sessionHost,
                    destination: destination,
                    pool: KwtSSHConnectionPool { route, _ in
                        KwtSSHTestLease(
                            routeIdentity: route.routeIdentity,
                            releaseCount: releases
                        )
                    }
                )
            }
        )
        let staleReviewID = UUID()
        let currentReviewID = UUID()

        #expect(try await model.pendingSSHHostKeyConfirmation(
            for: host,
            reviewID: staleReviewID
        ).get() == .none)
        #expect(try await model.pendingSSHHostKeyConfirmation(
            for: host,
            reviewID: currentReviewID
        ).get() == .none)

        model.cancelSSHAuthentication(surfaceID: staleReviewID)
        #expect(model.hostSSHSession != nil)
        #expect(releases.load() == 0)

        model.cancelSSHAuthentication(surfaceID: currentReviewID)
        await waitUntil { releases.load() == 1 }
        #expect(model.hostSSHSession == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("completed recovery authentication hands off its lease")
    func completedRecoveryAuthenticationHandsOffLease() async throws {
        let environment = try setupStandardEnvironment()
        let releases = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                releaseCount: releases
            )
        }
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(hostname: "recovery.example.test")
        )
        let host = SSHHost(
            configKey: "recovery",
            name: "Recovery",
            platform: .linux,
            sshDestination: "recovery.example.test"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            hostSSHSessionProvider: { sessionHost, destination in
                KwtSSHConnectionSession(
                    route: route,
                    host: sessionHost,
                    destination: destination,
                    pool: pool
                )
            }
        )

        let requirement = await model.pendingSSHHostKeyConfirmation(for: host)
        #expect(try requirement.get() == .none)
        let surfaceID = UUID()
        _ = model.sshAuthenticationView(surfaceID: surfaceID, for: host)

        var nextOwner: Task<KwtSSHConnection, Error>?
        await model.completeSSHAuthentication(
            surfaceID: surfaceID,
            startingNextOwner: {
                nextOwner = Task {
                    try await pool.acquire(
                        route: route,
                        prompt: { _ in "" }
                    )
                }
            }
        )
        let task = try #require(nextOwner)
        let connection = try await task.value

        #expect(releases.load() == 0)
        #expect(model.hostSSHSession == nil)
        try await connection.release()
        #expect(releases.load() == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("a new host check replaces a failed SSH session")
    func hostCheckReplacesFailedSSHSession() async throws {
        let environment = try setupStandardEnvironment()
        let sessions = LockedValue(0)
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(hostname: "build.example.test")
        )
        let host = SSHHost(
            configKey: "builder",
            name: "Builder",
            platform: .linux,
            sshDestination: "build.example.test"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            hostSSHSessionProvider: { sessionHost, destination in
                sessions.withLock { $0 += 1 }
                let attempt = sessions.load()
                return KwtSSHConnectionSession(
                    route: route,
                    host: sessionHost,
                    destination: destination,
                    pool: KwtSSHConnectionPool { route, _ in
                        if attempt == 1 {
                            throw KwtSSHLeaseError.operationFailed(
                                code: "ssh_connection_failed",
                                message: "Connection failed.",
                                retryable: true
                            )
                        }
                        return KwtSSHTestLease(
                            routeIdentity: route.routeIdentity
                        )
                    }
                )
            }
        )

        let first = await model.pendingSSHHostKeyConfirmation(for: host)
        guard case .failure = first else {
            Issue.record("Expected the first host check to fail")
            return
        }
        let second = await model.pendingSSHHostKeyConfirmation(for: host)

        #expect(try second.get() == .none)
        #expect(sessions.load() == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("concurrent presentation acquisitions do not cancel each other")
    func concurrentPresentationAcquisitionsRemainIndependent() async throws {
        let environment = try setupStandardEnvironment()
        let firstGate = BlockingGate()
        let secondGate = BlockingGate()
        defer {
            firstGate.release()
            secondGate.release()
        }
        let releases = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            if route.logicalTarget.hostname == "first.example.test" {
                firstGate.wait()
            } else {
                secondGate.wait()
            }
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                releaseCount: releases
            )
        }
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { request in
                KwtSSHRouteSnapshot.fixture(
                    logicalTarget: KwtSSHTarget(
                        hostname: request.host.hostname,
                        user: request.host.user,
                        port: request.host.port
                    ),
                    routeIdentity: "sha256:\(request.host.hostname)"
                )
            },
            pool: pool
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            presentationSSHConnectionProvider: nil,
            presentationSSHAcquisitionCoordinator: coordinator
        )
        let firstHost = SSHHostInfo(
            user: "dev",
            hostname: "first.example.test",
            port: nil
        )
        let secondHost = SSHHostInfo(
            user: "dev",
            hostname: "second.example.test",
            port: nil
        )

        let first = Task {
            try await model.acquirePresentationSSHConnection(
                hostID: UUID(),
                info: firstHost
            )
        }
        await waitUntil { firstGate.didStart }
        let second = Task {
            try await model.acquirePresentationSSHConnection(
                hostID: UUID(),
                info: secondHost
            )
        }
        await waitUntil { secondGate.didStart }
        firstGate.release()
        secondGate.release()

        let firstConnection = try await first.value
        let secondConnection = try await second.value
        #expect(firstConnection.routeIdentity == "sha256:first.example.test")
        #expect(secondConnection.routeIdentity == "sha256:second.example.test")
        try await firstConnection.release()
        try await secondConnection.release()
        #expect(releases.load() == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("transport failures do not request SSH presentation")
    func transportFailureDoesNotRequestSSHPresentation() async throws {
        let environment = try setupStandardEnvironment()
        let host = SSHHostInfo(
            user: "dev",
            hostname: "offline.example.test",
            port: nil
        )
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(
                hostname: host.hostname,
                user: host.user
            )
        )
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in route },
            pool: KwtSSHConnectionPool { _, _ in
                throw KwtSSHLeaseError.operationFailed(
                    code: "ssh_connection_failed",
                    message: "ssh: connect to host offline.example.test port 22: No route to host",
                    retryable: true
                )
            }
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            presentationSSHConnectionProvider: nil,
            presentationSSHAcquisitionCoordinator: coordinator
        )

        let acquisitionFailed = LockedValue(false)
        let acquisition = Task {
            do {
                _ = try await model.acquirePresentationSSHConnection(
                    hostID: UUID(),
                    info: host
                )
                Issue.record("offline SSH acquisition unexpectedly succeeded")
            } catch {
                acquisitionFailed.store(true)
            }
        }
        await waitUntilMainActor {
            acquisitionFailed.load()
                || model.presentationSSHSession != nil
        }

        #expect(model.presentationSSHSession == nil)
        #expect(acquisitionFailed.load())
        acquisition.cancel()
        await acquisition.value
        await model.shutdown()
    }

    @MainActor
    @Test(
        "failed presentation acquisitions resume after retry",
        arguments: [true, false]
    )
    func failedPresentationAcquisitionResumesAfterRetry(
        promptsBeforeFailure: Bool
    ) async throws {
        let environment = try setupStandardEnvironment()
        let host = SSHHostInfo(
            user: "dev",
            hostname: "builder.example.test",
            port: nil
        )
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(
                hostname: host.hostname,
                user: host.user
            ),
            targets: [KwtSSHResolvedTarget(
                logicalTarget: KwtSSHTarget(
                    hostname: host.hostname,
                    user: host.user
                ),
                effectiveTarget: KwtSSHTarget(
                    hostname: host.hostname,
                    user: host.user
                ),
                displayTarget: SSHDestination.render(host),
                hostKeyAlias: nil,
                strictHostKeyChecking: "ask",
                projection: KwtSSHExecutionProjection(
                    arguments: ["-F", "/dev/null"]
                )
            )]
        )
        let attempts = LockedValue(0)
        let releases = LockedValue(0)
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in route },
            pool: KwtSSHConnectionPool { route, prompt in
                attempts.withLock { $0 += 1 }
                if attempts.load() == 1, promptsBeforeFailure {
                    _ = try await prompt(.fixture(
                        id: "password-1",
                        kind: .authentication,
                        message: "Password:",
                        route: route,
                        hopIndex: 0
                    ))
                    throw KwtSSHLeaseError.operationFailed(
                        code: "ssh_connection_failed",
                        message: "Authentication failed.",
                        retryable: true
                    )
                }
                if attempts.load() == 1 {
                    throw KwtSSHLeaseError.routeChanged
                }
                return KwtSSHTestLease(
                    routeIdentity: route.routeIdentity,
                    releaseCount: releases
                )
            }
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            presentationSSHConnectionProvider: nil,
            presentationSSHAcquisitionCoordinator: coordinator
        )

        let acquisition = Task {
            try await model.acquirePresentationSSHConnection(
                hostID: UUID(),
                info: host
            )
        }
        if promptsBeforeFailure {
            await waitUntilMainActor {
                model.presentationSSHSession?.isAwaitingPrompt == true
            }
            model.presentationSSHSession?.submit("incorrect")
        }

        await waitUntilMainActor {
            guard let session = model.presentationSSHSession else {
                return false
            }
            if promptsBeforeFailure {
                return session.state
                    == .failed("Authentication failed.")
            }
            return session.state == .configurationChanged
        }
        let session = try #require(model.presentationSSHSession)
        session.retry()

        let connection = try await acquisition.value
        #expect(connection.routeIdentity == route.routeIdentity)
        #expect(model.presentationSSHSession == nil)
        #expect(attempts.load() == 2)
        try await connection.release()
        #expect(releases.load() == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe distinguishes a reachable host without tmux")
    func connectionProbeReportsMissingTmux() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _, _ in
                (
                    status: 127,
                    stdout: WorkspaceTmuxTestSupport.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_UNAVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "host-a",
            name: "Host A",
            platform: .linux,
            sshDestination: "user-a@host-a.example"
        ), protocolNonce: WorkspaceTmuxTestSupport.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.diagnostics.map(\.code) == [.missingTmux])
        #expect(
            summary.diagnostics.first?.summary
                == "tmux is not available."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe requires its nonce-framed protocol block")
    func connectionProbeReportsSSHFailure() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _, _ in
                (
                    status: 255,
                    stdout:
                    "GHOSTHUB_SSH_REACHED\n"
                        + "GHOSTHUB_TMUX_AVAILABLE\n",
                    stderr:
                    "GHOSTHUB_SSH_REACHED\n"
                        + "GHOSTHUB_TMUX_AVAILABLE\n"
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "offline",
            name: "Offline",
            platform: .linux,
            sshDestination: "offline"
        ), protocolNonce: WorkspaceTmuxTestSupport.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .offline)
        #expect(!summary.host.lastKnownReachable)
        #expect(summary.diagnostics.map(\.code) == [
            .sshConnectionFailed,
        ])
        #expect(
            summary.diagnostics.first?.summary
                == "SSH could not connect to the host."
        )
        await model.shutdown()
    }

    @MainActor
    @Test(
        "connection probe keeps non-SSH command failures reachable",
        arguments: [Int32(1), Int32(127)]
    )
    func connectionProbeReportsProbeFailure(status: Int32) async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _, _ in
                (
                    status: status,
                    stdout: WorkspaceTmuxTestSupport.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_AVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "misconfigured-shell",
            name: "Misconfigured Shell",
            platform: .linux,
            sshDestination: "misconfigured-shell"
        ), protocolNonce: WorkspaceTmuxTestSupport.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(summary.host.lastSeenAt != nil)
        #expect(summary.diagnostics.map(\.code) == [.probeFailure])
        #expect(
            summary.diagnostics.first?.summary
                == "tmux did not respond successfully."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe treats an unconfirmed SSH timeout as offline")
    func connectionProbeReportsUnconfirmedTimeout() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _, _ in
                (
                    status: -124,
                    stdout: "",
                    stderr: "SSH wrapper output\n"
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "timed-out",
            name: "Timed Out",
            platform: .linux,
            sshDestination: "timed-out"
        ), protocolNonce: WorkspaceTmuxTestSupport.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .offline)
        #expect(!summary.host.lastKnownReachable)
        #expect(summary.host.lastSeenAt == nil)
        #expect(summary.diagnostics.map(\.code) == [.sshConnectionFailed])
        #expect(
            summary.diagnostics.first?.summary
                == "The SSH connection timed out."
        )
        await model.shutdown()
    }

    @MainActor
    @Test("failed host probe invalidates its shared SSH generation")
    func failedHostProbeInvalidatesConnection() async throws {
        let environment = try setupStandardEnvironment()
        let acquisitions = LockedValue(0)
        let releases = LockedValue(0)
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(hostname: "dead.example.test")
        )
        let pool = KwtSSHConnectionPool { route, _ in
            acquisitions.withLock { $0 += 1 }
            let generation = UInt64(acquisitions.load())
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: generation,
                arguments: ["-S", "/tmp/dead-\(generation).sock"],
                releaseCount: releases
            )
        }
        let anchor = try await pool.acquire(route: route, prompt: { _ in "" })
        let host = SSHHost(
            configKey: "dead",
            name: "Dead",
            platform: .linux,
            sshDestination: "dead.example.test"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _, _ in
                (
                    status: 255,
                    stdout: "",
                    stderr: "Control socket connect(/tmp/dead.sock): No such file"
                )
            },
            hostSSHConnectionProvider: nil,
            hostSSHSessionProvider: { sessionHost, destination in
                KwtSSHConnectionSession(
                    route: route,
                    host: sessionHost,
                    destination: destination,
                    pool: pool
                )
            }
        )

        _ = await model.probeSSHHost(
            host,
            protocolNonce: WorkspaceTmuxTestSupport.probeNonce
        )
        let replacement = try await pool.acquire(
            route: route,
            prompt: { _ in "" }
        )

        #expect(replacement.generation == 2)
        #expect(releases.load() == 0)
        try await anchor.release()
        #expect(releases.load() == 1)
        try await replacement.release()
        #expect(releases.load() == 2)
        await model.shutdown()
    }

    @MainActor
    @Test("canceling a host probe stops its runner and releases its lease")
    func cancelingHostProbeStopsRunnerAndReleasesConnection() async throws {
        let environment = try setupStandardEnvironment()
        let probeState = LockedValue((started: false, canceled: false))
        let releases = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _, _ in
                probeState.withLock { $0.started = true }
                let deadline = Date().addingTimeInterval(0.25)
                while Date() < deadline {
                    if Task.isCancelled {
                        probeState.withLock { $0.canceled = true }
                        return (
                            status: AccountCommandRunner.cancelledStatus,
                            stdout: "",
                            stderr: ""
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return (status: 255, stdout: "", stderr: "timed out")
            },
            hostSSHConnectionProvider: { _, _ in
                testKwtSSHAttachment(
                    release: { releases.withLock { $0 += 1 } }
                )
            }
        )
        let host = SSHHost(
            configKey: "cancel-probe",
            name: "Cancel Probe",
            platform: .linux,
            sshDestination: "cancel-probe.example.test"
        )

        let probe = Task {
            await model.probeSSHHost(
                host,
                protocolNonce: WorkspaceTmuxTestSupport.probeNonce
            )
        }
        await waitUntilMainActor { probeState.load().started }
        probe.cancel()
        _ = await probe.value

        #expect(probeState.load().canceled)
        #expect(releases.load() == 1)
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe uses native PowerShell for Windows hosts")
    func connectionProbeUsesWindowsPowerShell() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { host, connectionArguments, command in
                #expect(host.platform == .windows)
                #expect(connectionArguments == ["-test-connection"])
                #expect(command.contains("Get-Command tmux.exe"))
                #expect(command.contains("[Console]::Out.WriteLine()"))
                #expect(command.contains("GHOSTHUB_KWT_AVAILABLE"))
                if let managedPath =
                    KwtBinaryLocator.windowsRemoteManagedRelativePath(
                        revision:
                        KwtBinaryLocator.bundledRemoteRevision()
                    ) {
                    #expect(command.contains(
                        powerShellEncodedArgument(managedPath)
                    ))
                } else {
                    #expect(command.contains(
                        "$ghosthubKwtAvailable = $false"
                    ))
                }
                #expect(!command.contains("Get-Command kwt.exe"))
                #expect(!command.contains("command -v"))
                return (
                    status: 0,
                    stdout: WorkspaceTmuxTestSupport.probeOutput(
                        [
                            "GHOSTHUB_SSH_REACHED",
                            "GHOSTHUB_TMUX_AVAILABLE",
                            "GHOSTHUB_KWT_AVAILABLE",
                        ],
                        startupOutput: "unterminated startup output"
                    ),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "arm-builder",
            name: "ARM Builder",
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        ), protocolNonce: WorkspaceTmuxTestSupport.probeNonce)
        let summary = try result.get()

        #expect(summary.connectionState == .online)
        #expect(summary.platform == .windows)
        #expect(summary.diagnostics.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe distinguishes missing psmux from SSH failure")
    func connectionProbeReportsMissingPsmux() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _, _ in
                (
                    status: 127,
                    stdout: WorkspaceTmuxTestSupport.probeOutput([
                        "GHOSTHUB_SSH_REACHED",
                        "GHOSTHUB_TMUX_UNAVAILABLE",
                    ]),
                    stderr: ""
                )
            }
        )

        let result = await model.probeSSHHost(SSHHost(
            configKey: "arm-builder",
            name: "ARM Builder",
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        ), protocolNonce: WorkspaceTmuxTestSupport.probeNonce)
        let summary = try result.get()
        let diagnostic = try #require(summary.diagnostics.first)

        #expect(summary.connectionState == .degraded)
        #expect(summary.host.lastKnownReachable)
        #expect(diagnostic.code == .missingTmux)
        #expect(diagnostic.summary == "psmux is not available.")
        #expect(diagnostic.recoverySuggestion.contains("tmux.exe alias"))
        await model.shutdown()
    }

    @MainActor
    @Test("remote failures do not enter the workspace-wide error")
    func remoteFailureStaysHostScopedWhenLocalAlsoFails() async throws {
        let environment = try setupStandardEnvironment()
        let remote = SSHHost(
            configKey: "offline",
            name: "Offline Host",
            platform: .linux,
            sshDestination: "offline"
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([remote])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { host in
                throw KwtInventoryError.commandFailed(
                    host: host.displayName,
                    status: host.isRemote ? 127 : 1
                )
            },
            tmuxSessionDiscovery: { host in
                .failure(.shellFailed(status: host.isRemote ? 255 : 1))
            },
            configuredSSHHostsProvider: { configuredHosts.value },
            configuredSSHHostsPublisher:
            configuredHosts.eraseToAnyPublisher(),
            startServices: true
        )

        await waitUntilMainActor {
            if case .failed = model.workspaceInventoryState {
                return true
            }
            return false
        }

        guard case let .failed(message) = model.workspaceInventoryState else {
            Issue.record("Expected local inventory failure")
            await model.shutdown()
            return
        }
        let remoteHostID = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }?.id
        )
        #expect(!message.contains("Offline Host"))
        #expect(!message.contains("status 255"))
        #expect(
            model.workspaceInventoryWarningsByHost[remoteHostID]?
                .contains("status 255") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("duplicate project warnings appear once")
    func duplicateProjectWarningsAreDeduplicated() async throws {
        let environment = try setupStandardEnvironment()
        let warning = "project: temporary kwt failure"
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            kwtInventoryLoader: { _ in
                KwtHostInventory(projects: [
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: "first",
                            name: "project",
                            path: "/first",
                            lastTouched: nil
                        ),
                        worktrees: [],
                        warning: "temporary kwt failure"
                    ),
                    KwtProjectInventory(
                        project: KwtProjectRecord(
                            repository: "second",
                            name: "project",
                            path: "/second",
                            lastTouched: nil
                        ),
                        worktrees: [],
                        warning: "temporary kwt failure"
                    ),
                ])
            },
            tmuxSessionDiscovery: { _ in .success([]) },
            startServices: true
        )

        await waitUntilMainActor {
            model.workspaceInventoryState == .loaded
                && model.workspaceInventoryWarning != nil
        }
        #expect(model.workspaceInventoryWarning == warning)
        await model.shutdown()
    }
}
