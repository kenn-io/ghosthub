import Combine
import Foundation
import GhosthubPersistence
import GhosthubSettings
import GhosthubTestSupport
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("ConfiguredHostOverlay")
struct ConfiguredHostOverlayTests {
    @Test("app-owned SSH hosts replace transitional remote inventory")
    func configuredHostsReplaceTransitionalRemoteInventory() {
        let local = HostSummary.fixture(
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let stale = HostSummary.fixture(
            configKey: "old",
            name: "Old Host",
            kind: .remote,
            platform: .linux,
            sshDestination: "old"
        )
        let staleProject = ProjectSummary.fixture(
            hostID: stale.id,
            name: "stale"
        )
        let source = WorkspaceSnapshot.fixture(
            hosts: [local, stale],
            projects: [staleProject],
            worktrees: []
        )

        let result = ConfiguredHostOverlay.apply([
            SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: .linux,
                sshDestination: "wesm@builder"
            ),
        ], to: source)

        #expect(result.hosts.map(\.name) == ["This Mac", "Builder"])
        #expect(result.hosts[1].kind == .remote)
        #expect(result.hosts[1].preferredTransport == .ssh)
        #expect(result.hosts[1].sshDestination == "wesm@builder")
        #expect(result.projects.isEmpty)
    }

    @Test("configured host identity is stable across launches")
    func configuredHostIdentityIsStable() {
        let configured = SSHHost(
            configKey: "builder",
            name: "Builder",
            platform: .linux,
            sshDestination: "builder"
        )

        let first = ConfiguredHostOverlay.apply(
            [configured],
            to: .empty
        ).hosts[0]
        let second = ConfiguredHostOverlay.apply(
            [configured],
            to: .empty
        ).hosts[0]

        #expect(first.id == second.id)
    }

    @Test("changing an SSH destination clears the old host inventory")
    func changingDestinationClearsInventory() {
        let host = HostSummary.fixture(
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "old-builder",
            tmuxSessions: [
                .init(name: "old-session", managed: false, windows: []),
            ]
        )
        let project = ProjectSummary.fixture(hostID: host.id)
        let worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id
        )
        let session = TerminalSessionSummary(
            id: UUID(),
            hostID: host.id,
            worktreeID: worktree.id,
            isAlive: true
        )
        let source = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [worktree],
            sessions: [session]
        )

        let result = ConfiguredHostOverlay.apply([
            SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: .linux,
                sshDestination: "new-builder"
            ),
        ], to: source)

        #expect(result.hosts[0].id == host.id)
        #expect(result.hosts[0].tmuxSessions.isEmpty)
        #expect(result.projects.isEmpty)
        #expect(result.worktrees.isEmpty)
        #expect(result.sessions.isEmpty)
    }

    @Test("changing an SSH destination clears directory workspaces")
    func changingDestinationClearsDirectoryWorkspaces() {
        let host = HostSummary.fixture(
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "old-builder"
        )
        var source = WorkspaceSnapshot.fixture(hosts: [host])
        source.directoryWorkspaces = [.init(
            id: UUID(),
            hostID: host.id,
            name: "hub",
            path: "/srv/hub",
            tmuxSessionName: "kwt-workspace-dir-hub",
            sessionLive: true
        )]

        let result = ConfiguredHostOverlay.apply([
            SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: .linux,
                sshDestination: "new-builder"
            ),
        ], to: source)

        #expect(result.directoryWorkspaces.isEmpty)
    }

    @Test(
        "changing host platform clears inventory",
        arguments: [
            (from: HostPlatform.linux, to: HostPlatform.windows),
            (from: HostPlatform.windows, to: HostPlatform.linux),
        ]
    )
    func changingPlatformClearsInventory(
        from: HostPlatform,
        to: HostPlatform
    ) {
        let host = HostSummary.fixture(
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: from,
            sshDestination: "builder",
            tmuxSessions: [
                .init(name: "old-session", managed: false, windows: []),
            ]
        )
        let project = ProjectSummary.fixture(hostID: host.id)
        let worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id
        )
        let session = TerminalSessionSummary(
            id: UUID(),
            hostID: host.id,
            worktreeID: worktree.id,
            isAlive: true
        )
        let source = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [worktree],
            sessions: [session]
        )

        let result = ConfiguredHostOverlay.apply([
            SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: to,
                sshDestination: "builder"
            ),
        ], to: source)

        #expect(result.hosts[0].id == host.id)
        #expect(result.hosts[0].platform == to)
        #expect(result.hosts[0].tmuxSessions.isEmpty)
        #expect(result.projects.isEmpty)
        #expect(result.worktrees.isEmpty)
        #expect(result.sessions.isEmpty)
    }

    @Test("duplicate destinations receive distinct host identities")
    func duplicateDestinationsReceiveDistinctIDs() {
        let existing = HostSummary.fixture(
            configKey: "first",
            name: "First",
            kind: .remote,
            platform: .linux,
            sshDestination: "builder"
        )

        let result = ConfiguredHostOverlay.apply([
            SSHHost(
                configKey: "first",
                name: "First",
                platform: .linux,
                sshDestination: "builder"
            ),
            SSHHost(
                configKey: "second",
                name: "Second",
                platform: .linux,
                sshDestination: "builder"
            ),
        ], to: WorkspaceSnapshot.fixture(hosts: [existing]))

        #expect(result.hosts.count == 2)
        #expect(Set(result.hosts.map(\.id)).count == 2)
    }

    @Test("exe.dev VMs retain provider metadata as ordinary SSH hosts")
    func exeVMsRetainProviderMetadata() throws {
        let metadata = ExeVMMetadata(
            accountConfigKey: "personal",
            accountName: "Personal",
            vmName: "build",
            region: "lon",
            regionDisplayName: "London, UK",
            httpsURL: "https://build.exe.xyz"
        )

        let result = ConfiguredHostOverlay.apply(
            [],
            exeHosts: [ExeConfiguredHost(
                sshHost: SSHHost(
                    configKey: "exe-dev.personal.build",
                    name: "build",
                    platform: .linux,
                    sshDestination: "vm+build@exe.dev"
                ),
                metadata: metadata
            )],
            to: .empty
        )

        let host = try #require(result.hosts.first)
        #expect(host.sshDestination == "vm+build@exe.dev")
        #expect(host.preferredTransport == .ssh)
        #expect(host.exeVM == metadata)
    }

    @Test("manual SSH hosts win when exe.dev returns the same destination")
    func manualHostsWinDuplicateDestinations() throws {
        let manual = SSHHost(
            configKey: "manual-build",
            name: "Manual Build",
            platform: .linux,
            sshDestination: "build.exe.xyz"
        )
        let result = ConfiguredHostOverlay.apply(
            [manual],
            exeHosts: [ExeConfiguredHost(
                sshHost: SSHHost(
                    configKey: "exe-dev.personal.build",
                    name: "build",
                    platform: .linux,
                    sshDestination: "build.exe.xyz"
                ),
                metadata: ExeVMMetadata(
                    accountConfigKey: "personal",
                    accountName: "Personal",
                    vmName: "build"
                )
            )],
            to: .empty
        )

        let host = try #require(result.hosts.first)
        #expect(result.hosts.count == 1)
        #expect(host.configKey == manual.configKey)
        #expect(host.exeVM == nil)
    }

    @Test("manual and generated config keys remain unique")
    func manualAndGeneratedConfigKeysRemainUnique() throws {
        let manual = SSHHost(
            configKey: "exe-dev.personal.build",
            name: "Manual Build",
            platform: .linux,
            sshDestination: "manual-build"
        )
        let metadata = ExeVMMetadata(
            accountConfigKey: "personal",
            accountName: "Personal",
            vmName: "build"
        )
        let result = ConfiguredHostOverlay.apply(
            [manual],
            exeHosts: [
                ExeConfiguredHost(
                    sshHost: SSHHost(
                        configKey: "exe-dev.personal.build",
                        name: "Provider Build",
                        platform: .linux,
                        sshDestination: "provider-build"
                    ),
                    metadata: metadata
                ),
                ExeConfiguredHost(
                    sshHost: SSHHost(
                        configKey: "exe-dev.personal.test",
                        name: "First Test",
                        platform: .linux,
                        sshDestination: "first-test"
                    ),
                    metadata: metadata
                ),
                ExeConfiguredHost(
                    sshHost: SSHHost(
                        configKey: "exe-dev.personal.test",
                        name: "Duplicate Test",
                        platform: .linux,
                        sshDestination: "duplicate-test"
                    ),
                    metadata: metadata
                ),
            ],
            to: .empty
        )

        #expect(Set(result.hosts.map(\.configKey)) == Set([
            "exe-dev.personal.build",
            "exe-dev.personal.test",
        ]))
        let manualHost = try #require(result.hosts.first {
            $0.configKey == "exe-dev.personal.build"
        })
        let providerHost = try #require(result.hosts.first {
            $0.configKey == "exe-dev.personal.test"
        })
        #expect(manualHost.sshDestination == "manual-build")
        #expect(providerHost.sshDestination == "first-test")
        #expect(Set(result.hosts.map(\.id)).count == result.hosts.count)
    }

    @Test("destination fallback cannot consume a later exact config identity")
    func destinationFallbackReservesExactMatches() {
        let existingA = HostSummary.fixture(
            configKey: "host-a",
            name: "Host A",
            kind: .remote,
            platform: .linux,
            sshDestination: "shared-destination"
        )

        let result = ConfiguredHostOverlay.apply([
            SSHHost(
                configKey: "host-b",
                name: "Host B",
                platform: .linux,
                sshDestination: "shared-destination"
            ),
            SSHHost(
                configKey: "host-a",
                name: "Host A renamed",
                platform: .linux,
                sshDestination: "new-destination"
            ),
        ], to: WorkspaceSnapshot.fixture(hosts: [existingA]))

        #expect(result.hosts.count == 2)
        #expect(Set(result.hosts.map(\.id)).count == 2)
        #expect(result.hosts[0].configKey == "host-b")
        #expect(result.hosts[0].id != existingA.id)
        #expect(result.hosts[1].configKey == "host-a")
        #expect(result.hosts[1].id == existingA.id)
        #expect(result.hosts[1].sshDestination == "new-destination")
    }

    @MainActor
    @Test("SSH settings propagate immediately to every window")
    func settingsSynchronizeAllWindows() async throws {
        let localHostID = UUID()
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([
            SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: .linux,
                sshDestination: "old-builder"
            ),
        ])
        let provider = { configuredHosts.value }
        let subscriptionCount = LockedValue(0)
        let publisher = configuredHosts.handleEvents(
            receiveSubscription: { _ in
                subscriptionCount.withLock { $0 += 1 }
            }
        ).eraseToAnyPublisher()
        let database = try WorkspaceDatabase.inMemory()
        let firstWindow = try makeModel(
            database: database,
            localHostID: localHostID,
            configuredSSHHostsProvider: provider,
            configuredSSHHostsPublisher: publisher
        )
        let secondWindow = try makeModel(
            database: database,
            localHostID: localHostID,
            configuredSSHHostsProvider: provider,
            configuredSSHHostsPublisher: publisher
        )
        for _ in 0 ..< 10 where subscriptionCount.load() < 2 {
            await Task.yield()
        }
        #expect(subscriptionCount.load() == 2)
        #expect(
            secondWindow.snapshot.hosts.last?.sshDestination
                == "old-builder"
        )
        let oldHost = try #require(secondWindow.snapshot.hosts.last)
        let activeSelection = WorkspaceTmuxSessionSelection(
            hostID: oldHost.id,
            name: "existing-session"
        )
        secondWindow.openBorrowedTmuxSession(activeSelection)
        #expect(
            secondWindow.borrowedTmuxSessionView(
                host: oldHost,
                sessionName: activeSelection.name,
                defersTerminalResize: false
            ) != nil
        )

        configuredHosts.send([
            SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: .linux,
                sshDestination: "new-builder"
            ),
        ])
        #expect(
            firstWindow.snapshot.hosts.last?.sshDestination
                == "new-builder"
        )
        #expect(
            secondWindow.snapshot.hosts.last?.sshDestination
                == "new-builder"
        )
        let updatedHost = try #require(secondWindow.snapshot.hosts.last)
        #expect(secondWindow.activeBorrowedTmuxSelection == nil)
        #expect(
            secondWindow.borrowedTmuxSessionView(
                host: updatedHost,
                sessionName: activeSelection.name,
                defersTerminalResize: false
            ) == nil
        )

        secondWindow.openBorrowedTmuxSession(activeSelection)
        #expect(
            secondWindow.activeBorrowedTmuxSelection == activeSelection
        )
        #expect(
            secondWindow.borrowedTmuxSessionView(
                host: updatedHost,
                sessionName: activeSelection.name,
                defersTerminalResize: false
            ) != nil
        )
        configuredHosts.send([])
        #expect(secondWindow.snapshot.hosts.count == 1)
        #expect(secondWindow.activeBorrowedTmuxSelection == nil)
        #expect(
            secondWindow.borrowedTmuxSessionView(
                host: updatedHost,
                sessionName: activeSelection.name,
                defersTerminalResize: false
            ) == nil
        )
    }
}
