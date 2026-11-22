import GhosthubSettings
import Synchronization
import Testing
@testable import GhosthubUI

@MainActor
@Suite("Agent hook setup across host switches")
struct AgentHookSetupTests {
    private static let hostA = SSHHost(
        configKey: "host-a", name: "Host A", platform: .linux,
        sshDestination: "user@host-a.example.test"
    )
    private static let hostB = SSHHost(
        configKey: "host-b", name: "Host B", platform: .linux,
        sshDestination: "user@host-b.example.test"
    )
    private static let notInstalled = [AgentHookSetupStatus(
        agent: "claude", displayName: "Claude Code",
        available: true, installed: false, current: false
    )]
    private static let installed = [AgentHookSetupStatus(
        agent: "claude", displayName: "Claude Code",
        available: true, installed: true, current: true
    )]

    /// Yields until `condition` holds, so a started task reaches its
    /// first suspension.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0 ..< 1000 where !condition() {
            await Task.yield()
        }
    }

    @Test("an install that finishes after a host switch leaves the new host's status")
    func installAfterSwitchIsNotShown() async {
        let setup = AgentHookSetup(typingDelay: .zero)
        await setup.load(Self.hostA) { _ in .success(Self.notInstalled) }
        let (finish, release) = AsyncStream<Void>.makeStream()
        let installing = Task {
            await setup.install(Self.hostA) { _ in
                for await _ in finish {
                    break
                }
                return .success(Self.installed)
            }
        }
        await settle { setup.isInstalling }
        #expect(setup.isInstalling)

        await setup.load(Self.hostB) { _ in .success(Self.notInstalled) }
        // Host B is not the one installing, so it can install too.
        #expect(!setup.isInstalling)

        release.yield()
        await installing.value
        #expect(setup.statuses == Self.notInstalled)
        #expect(setup.errorMessage == nil)
    }

    @Test("a load that finishes after a host switch leaves the new host's status")
    func loadAfterSwitchIsNotShown() async {
        let setup = AgentHookSetup(typingDelay: .zero)
        let (finish, release) = AsyncStream<Void>.makeStream()
        let startedA = Mutex(false)
        let loadingA = Task {
            await setup.load(Self.hostA) { _ in
                startedA.withLock { $0 = true }
                for await _ in finish {
                    break
                }
                return .failure(.message("Host A is unreachable."))
            }
        }
        await settle { startedA.withLock { $0 } }
        #expect(startedA.withLock { $0 })

        await setup.load(Self.hostB) { _ in .success(Self.installed) }
        release.yield()
        await loadingA.value

        #expect(setup.statuses == Self.installed)
        #expect(setup.errorMessage == nil)
    }

    @Test("an install on the shown host shows its result")
    func installOnShownHostIsShown() async {
        let setup = AgentHookSetup(typingDelay: .zero)
        await setup.load(Self.hostA) { _ in .success(Self.notInstalled) }
        await setup.install(Self.hostA) { _ in .success(Self.installed) }

        #expect(setup.statuses == Self.installed)
        #expect(!setup.isInstalling)
    }
}
