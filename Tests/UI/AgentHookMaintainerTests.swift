import Foundation
import GhosthubSettings
import GhosthubTerminalSupport
@testable import GhosthubUI
import Synchronization
import Testing

/// Holds status checks until the test lets them go.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Fake hosts: each knows its agents' hook state and records the commands
/// Ghosthub ran there.
private final class FakeHosts: Sendable {
    let state = Mutex<[String: [AgentHookSetupStatus]]>([:])
    let failing = Mutex<Set<String>>([])
    let calls = Mutex<[String]>([])
    /// When set, a status check waits for it, as over a slow SSH link.
    let statusGate = Mutex<Gate?>(nil)

    static func key(_ host: SSHHost?) -> String {
        host?.configKey ?? "local"
    }

    static func claude(installed: Bool, current: Bool) -> AgentHookSetupStatus {
        AgentHookSetupStatus(
            agent: "claude", displayName: "Claude Code",
            available: true, installed: installed, current: current
        )
    }

    func set(_ host: String, _ statuses: [AgentHookSetupStatus]) {
        state.withLock { $0[host] = statuses }
    }

    @MainActor
    func maintainer() -> AgentHookMaintainer {
        AgentHookMaintainer(
            status: { host in
                let key = Self.key(host)
                self.calls.withLock { $0.append("status \(key)") }
                if let gate = self.statusGate.withLock({ $0 }) {
                    await gate.wait()
                }
                if self.failing.withLock({ $0.contains(key) }) {
                    return .failure(.message("\(key) is unreachable"))
                }
                return .success(self.state.withLock { $0[key] ?? [] })
            },
            install: { host in
                let key = Self.key(host)
                self.calls.withLock { $0.append("install \(key)") }
                let installed = self.state.withLock { state in
                    state[key] = (state[key] ?? []).map {
                        var status = $0
                        status.installed = true
                        status.current = true
                        return status
                    }
                    return state[key] ?? []
                }
                return .success(installed)
            }
        )
    }

    func installs() -> [String] {
        calls.withLock { $0 }.filter { $0.hasPrefix("install") }.sorted()
    }
}

@MainActor
@Suite("Agent hook upkeep")
struct AgentHookMaintainerTests {
    let linux = SSHHost(
        configKey: "builder",
        name: "Builder",
        platform: .linux,
        sshDestination: "builder"
    )
    let mac = SSHHost(
        configKey: "studio",
        name: "Studio",
        platform: .macOS,
        sshDestination: "studio"
    )
    let windows = SSHHost(configKey: "pc", name: "PC", platform: .windows, sshDestination: "pc")

    @Test("this Mac comes first, and Windows hosts stay manual")
    func targets() {
        #expect(AgentHookTarget.all(sshHosts: [linux, windows, mac]).map(\.name)
            == ["This Mac", "Builder", "Studio"])
    }

    @Test("upkeep installs only where an agent lacks current hooks, once per launch")
    func maintainInstallsWhereNeeded() async {
        let hosts = FakeHosts()
        hosts.set("local", [FakeHosts.claude(installed: true, current: true)])
        hosts.set("builder", [FakeHosts.claude(installed: true, current: false)])
        hosts.set("studio", [FakeHosts.claude(installed: false, current: false)])
        let maintainer = hosts.maintainer()
        let targets = AgentHookTarget.all(sshHosts: [linux, mac])

        await maintainer.maintain(targets)
        #expect(hosts.installs() == ["install builder", "install studio"])
        #expect(!maintainer.hooksMissing(in: targets))

        // A newly installed agent on the same host waits for the next
        // launch or a manual install; upkeep does not poll hosts.
        hosts.set("builder", [FakeHosts.claude(installed: false, current: false)])
        await maintainer.maintain(targets)
        #expect(hosts.installs() == ["install builder", "install studio"])
    }

    @Test("an unreachable host is tried again on the next upkeep")
    func maintainRetriesFailures() async {
        let hosts = FakeHosts()
        hosts.set("builder", [FakeHosts.claude(installed: false, current: false)])
        hosts.failing.withLock { $0 = ["builder"] }
        let maintainer = hosts.maintainer()
        let targets = AgentHookTarget.all(sshHosts: [linux])

        await maintainer.maintain(targets)
        #expect(maintainer.phases["builder"] == .failed("builder is unreachable"))
        #expect(hosts.installs().isEmpty)

        hosts.failing.withLock { $0 = [] }
        await maintainer.maintain(targets)
        #expect(hosts.installs() == ["install builder"])
    }

    @Test("reading hook state never installs")
    func checkWithoutInstalling() async {
        let hosts = FakeHosts()
        hosts.set("builder", [FakeHosts.claude(installed: false, current: false)])
        let maintainer = hosts.maintainer()
        let targets = AgentHookTarget.all(sshHosts: [linux])

        await maintainer.check(targets, installing: false)

        #expect(hosts.installs().isEmpty)
        #expect(maintainer.hooksMissing(in: targets))
        #expect(maintainer.checked(targets))
    }

    @Test("an install asked for while Settings is reading a host still happens")
    func installDuringCheck() async {
        let hosts = FakeHosts()
        hosts.set("builder", [FakeHosts.claude(installed: false, current: false)])
        let gate = Gate()
        hosts.statusGate.withLock { $0 = gate }
        let maintainer = hosts.maintainer()
        let targets = AgentHookTarget.all(sshHosts: [linux])

        let reading = Task { await maintainer.check(targets, installing: false) }
        while maintainer.phases["builder"] != .checking {
            await Task.yield()
        }
        let upkeep = Task { await maintainer.maintain(targets) }
        await Task.yield()
        await gate.open()
        await reading.value
        await upkeep.value

        #expect(hosts.installs() == ["install builder"])
    }
}

@MainActor
@Suite("Welcome sheet")
struct OnboardingPresenterTests {
    let linux = SSHHost(
        configKey: "builder",
        name: "Builder",
        platform: .linux,
        sshDestination: "builder"
    )

    private func makeSettings() throws -> SettingsStore {
        let suite = "ghosthub.onboarding.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SettingsStore(
            configPipeline: LibghosttyConfigPipeline(
                paths: LibghosttyConfigPaths(configDirectory: configDirectory)
            ),
            userDefaults: defaults
        )
    }

    @Test("one window shows the sheet, and another takes it if that window closes")
    func oneWindowClaims() {
        let presenter = OnboardingPresenter()
        let first = UUID()
        let second = UUID()
        #expect(!presenter.claim(first), "nothing to show yet")

        presenter.present()
        #expect(presenter.claim(first))
        #expect(!presenter.claim(second))
        presenter.release(first)
        #expect(presenter.claim(second))

        presenter.finish()
        #expect(!presenter.claim(second))

        // Show Welcome opens it in the window it was chosen from.
        presenter.present(in: first)
        #expect(!presenter.claim(second))
        #expect(presenter.claim(first))
    }

    @Test("a new install is welcomed without checking any host")
    func newInstall() async throws {
        let hosts = FakeHosts()
        let presenter = OnboardingPresenter()
        let settings = try makeSettings()

        await presenter.decideAtLaunch(
            settings: settings, maintainer: hosts.maintainer(), isNewInstall: true
        )

        #expect(presenter.isPending)
        #expect(hosts.calls.withLock { $0 }.isEmpty)
    }

    @Test("an existing user is welcomed once only when a host lacks current hooks")
    func existingUser() async throws {
        let settings = try makeSettings()
        settings.setSSHHosts([linux])
        let hosts = FakeHosts()
        hosts.set("local", [FakeHosts.claude(installed: true, current: true)])
        hosts.set("builder", [FakeHosts.claude(installed: false, current: false)])
        let presenter = OnboardingPresenter()

        await presenter.decideAtLaunch(
            settings: settings, maintainer: hosts.maintainer(), isNewInstall: false
        )
        #expect(presenter.isPending)
        #expect(hosts.installs().isEmpty, "the check only reads")

        let current = FakeHosts()
        current.set("builder", [FakeHosts.claude(installed: true, current: true)])
        let quiet = OnboardingPresenter()
        let settled = try makeSettings()
        settled.setSSHHosts([linux])
        await quiet.decideAtLaunch(
            settings: settled, maintainer: current.maintainer(), isNewInstall: false
        )
        #expect(!quiet.isPending)
        #expect(settled.onboardingCompleted, "nothing to set up, so it never asks")
    }

    @Test("a host Ghosthub cannot reach leaves the decision for the next launch")
    func unreachableHost() async throws {
        let settings = try makeSettings()
        settings.setSSHHosts([linux])
        let hosts = FakeHosts()
        hosts.failing.withLock { $0 = ["builder"] }
        let presenter = OnboardingPresenter()

        await presenter.decideAtLaunch(
            settings: settings, maintainer: hosts.maintainer(), isNewInstall: false
        )

        #expect(!presenter.isPending)
        #expect(!settings.onboardingCompleted)
    }

    @Test("someone who already turned on automatic hooks is not welcomed")
    func automaticHooksAlreadyOn() async throws {
        let settings = try makeSettings()
        settings.setAutoInstallAgentHooks(true)
        let presenter = OnboardingPresenter()

        await presenter.decideAtLaunch(
            settings: settings, maintainer: FakeHosts().maintainer(), isNewInstall: true
        )

        #expect(!presenter.isPending)
        #expect(settings.onboardingCompleted)
    }
}
