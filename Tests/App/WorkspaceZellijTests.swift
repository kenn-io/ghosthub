import Combine
import Foundation
import GhosthubPersistence
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import GhosthubZellij
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("Workspace Zellij support", .serialized)
@MainActor
struct WorkspaceZellijTests {
    @Test("application activation does not refresh Zellij inventory")
    func applicationActivationDoesNotRefreshZellijInventory() async throws {
        let environment = try zellijEnvironment(sessions: [])
        let discoveries = Mutex(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            zellijSessionDiscovery: { _ in
                discoveries.withLock { $0 += 1 }
                return .available([])
            }
        )
        model.startZellijSessionDiscovery()
        await waitUntilMainActor { discoveries.withLock { $0 } == 1 }

        model.handleApplicationDidBecomeActiveForResourceMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        #expect(discoveries.withLock { $0 } == 1)
        await model.shutdown()
    }

    @Test("explicit refresh cancels the superseded Zellij probe")
    func refreshCancelsSupersededDiscovery() async throws {
        let environment = try zellijEnvironment(sessions: [])
        let discovery = CancellableZellijDiscoveryProbe(blockingCall: 1)
        defer { discovery.release() }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            zellijSessionDiscovery: discovery.discover
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor { discovery.calls == 1 }
        model.refreshWorkspaceInventory()
        await waitUntilMainActor {
            discovery.didCancel
                && discovery.calls == 2
                && model.snapshot.host(id: environment.host.id)?
                .zellijSessions.map(\.name) == ["replacement"]
        }

        #expect(discovery.didCancel)
        await model.shutdown()
    }

    @Test("shutdown cancels detached Zellij creation retry discovery")
    func shutdownCancelsCreationRetryDiscovery() async throws {
        let environment = try zellijEnvironment(sessions: [])
        let discovery = CancellableZellijDiscoveryProbe(blockingCall: 3)
        defer { discovery.release() }
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeZellijSurfaceStore: RecordingNativeSessionSurfaceStore(),
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionDiscovery: discovery.discover,
            zellijSessionValidationDiscovery: { _, _ in .available([]) },
            createdSessionDiscoveryDelays: [.zero]
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: environment.host.id,
            name: "release"
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor { discovery.calls == 1 }
        try await model.createZellijSession(selection)
        await waitUntilMainActor(timeout: .seconds(1)) {
            discovery.calls == 3
        }

        await model.shutdown()
        await waitUntilMainActor { discovery.didCancel }

        #expect(discovery.didCancel)
    }

    @Test("multi-host discovery publishes one completed Zellij inventory")
    func multiHostDiscoveryPublishesOnce() async throws {
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let remote = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder"
        )
        let model = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local, remote],
                projects: [],
                worktrees: []
            ),
            zellijSessionDiscovery: { host in
                .available([host.displayName])
            }
        )
        let publications = Mutex<[WorkspaceSnapshot]>([])
        let updates = model.$snapshot.dropFirst().sink { snapshot in
            guard snapshot.hosts.contains(where: {
                !$0.zellijSessions.isEmpty
            }) else { return }
            publications.withLock { $0.append(snapshot) }
        }

        model.startZellijSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts.allSatisfy {
                $0.zellijSessions.count == 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(publications.withLock { $0.count } == 1)
        #expect(publications.withLock { snapshots in
            snapshots.first?.hosts.allSatisfy {
                $0.zellijSessions.count == 1
            } == true
        })
        withExtendedLifetime(updates) {}
        await model.shutdown()
    }

    @Test("discovery probes local and POSIX hosts but excludes Windows")
    func supportedDiscoveryHosts() async throws {
        let local = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let linux = HostSummary(
            id: UUID(),
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder"
        )
        let windows = HostSummary(
            id: UUID(),
            configKey: "windows",
            name: "Windows",
            kind: .remote,
            platform: .windows,
            sshDestination: "dev@windows"
        )
        let hosts = Mutex(Set<CommandHost>())
        let database = try WorkspaceDatabase.inMemory()
        let model = try makeModel(
            database: database,
            localHostID: local.id,
            snapshot: WorkspaceSnapshot(
                hosts: [local, linux, windows],
                projects: [],
                worktrees: []
            ),
            zellijSessionDiscovery: { host in
                _ = hosts.withLock { $0.insert(host) }
                return .available([host.displayName])
            }
        )

        model.startZellijSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: local.id)?.zellijSessions.count == 1
                && model.snapshot.host(id: linux.id)?.zellijSessions.count == 1
        }

        #expect(hosts.withLock { $0 } == Set([
            CommandHost.local,
            CommandHost.ssh(SSHHostInfo(
                user: "dev",
                hostname: "builder",
                port: nil
            )),
        ]))
        #expect(model.snapshot.host(id: local.id)?.zellijAvailable == true)
        #expect(model.snapshot.host(id: windows.id)?.zellijAvailable == false)
        await model.shutdown()
    }

}
