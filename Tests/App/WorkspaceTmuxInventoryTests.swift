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
                && !model.workspaceInventoryWarningsByHost.isEmpty
        }

        #expect(remoteInventoryLoads.count == 0)
        let remoteSummary = try #require(
            model.snapshot.hosts.first { $0.configKey == remote.configKey }
        )
        #expect(remoteSummary.primaryDiagnostic?.code == .missingKwt)
        #expect(!remoteSummary.canCreateWorktree)
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
        #expect(remoteSummary.primaryDiagnostic?.code == .missingKwt)
        #expect(remoteSummary.lastKnownReachable)
        #expect(remoteSummary.connectionState == .degraded)
        #expect(!remoteSummary.canCreateWorktree)
        await model.shutdown()
    }

    @MainActor
    @Test("losing remote kwt retains cached inventory but disables creation")
    func remoteKwtLossDisablesCreation() async throws {
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
            kwtWorktreeCreator: { _, _, _ in
                _ = creationAttempts.increment()
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

        availability.markRemoteKwtUnavailable()
        model.refreshKwtInventory()
        await waitUntilMainActor {
            model.snapshot.host(id: cachedProject.hostID)?
                .primaryDiagnostic?.code == .missingKwt
        }

        let unavailableHost = try #require(
            model.snapshot.host(id: cachedProject.hostID)
        )
        #expect(!unavailableHost.canCreateWorktree)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(unavailableHost.tmuxSessions.map(\.name) == ["docbank"])
        #expect(model.workspaceInventoryWarningsByHost[unavailableHost.id] == nil)

        do {
            try await model.createWorktree(WorktreeCreateRequest(
                projectID: cachedProject.id,
                branchName: "feature/should-not-run",
                createsBranch: true
            ))
            Issue.record("Expected unavailable kwt to reject creation")
        } catch let error as KwtWorktreeError {
            #expect(error == .projectUnavailable)
        }
        #expect(creationAttempts.count == 0)

        availability.markRemoteKwtAvailable()
        model.refreshKwtInventory()
        await waitUntilMainActor {
            let host = model.snapshot.host(id: cachedProject.hostID)
            return host?.primaryDiagnostic?.code != .missingKwt
                && host?.canCreateWorktree == true
        }
        #expect(model.snapshot.canCreateWorktree(in: cachedProject))
        await model.shutdown()
    }

    @MainActor
    @Test(
        "status 127 during creation disables kwt and schedules discovery",
        arguments: CreationKwtFailurePhase.allCases
    )
    private func creationKwtLossDisablesCapability(
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
                && model.snapshot.host(id: cachedProject.hostID)?
                .primaryDiagnostic?.code == .missingKwt
        }
        #expect(creationAttempts.count == 1)
        #expect(model.snapshot.project(id: cachedProject.id) != nil)
        #expect(!model.snapshot.canCreateWorktree(in: cachedProject))
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
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, command in
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
        #expect(summary.diagnostics.count == 1)
        #expect(summary.diagnostics.first?.code == .missingKwt)
        #expect(summary.diagnostics.first?.severity == .warning)
        #expect(
            summary.diagnostics.first?.recoverySuggestion
                .contains("Tmux sessions remain available") == true
        )
        await model.shutdown()
    }

    @MainActor
    @Test("connection probe distinguishes a reachable host without tmux")
    func connectionProbeReportsMissingTmux() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { _, _ in
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
            sshHostProbeRunner: { _, _ in
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
            sshHostProbeRunner: { _, _ in
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
            sshHostProbeRunner: { _, _ in
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
    @Test("connection probe uses native PowerShell for Windows hosts")
    func connectionProbeUsesWindowsPowerShell() async throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            sshHostProbeRunner: { host, command in
                #expect(host.platform == .windows)
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
            sshHostProbeRunner: { _, _ in
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
