import AppKit
import Foundation
import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubWorkspace
import SwiftUI
import Synchronization
import Testing
@testable import GhosthubUI

@Suite("Remote host agent hooks in Settings")
struct RemoteAgentHooksSettingsTests {
    private static let buildServer = SSHHost(
        configKey: "build-server", name: "Build Server",
        platform: .linux, sshDestination: "user@build.example.test"
    )

    /// Opens Settings on the Hosts pane, where the first SSH host is
    /// selected, runs `body`, and closes the window.
    @MainActor
    private func withSettings(
        hosts: [SSHHost],
        actions: SettingsActions,
        _ body: (NSWindow) async throws -> Void
    ) async throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let suiteName = "ghosthub.settings.agent-hooks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(
            configPipeline: LibghosttyConfigPipeline(
                paths: LibghosttyConfigPaths(configDirectory: configDirectory)
            ),
            userDefaults: defaults
        )
        store.setSSHHosts(hosts)
        store.selectedDomain = .hosts
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: SettingsView(store: store, actions: actions)
                    .defaultAppStorage(defaults)
                    .frame(width: 1040, height: 744)
            )
        )
        // Off screen and behind other windows, so the test takes no focus.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer { window.close() }
        try await body(window)
    }

    /// Awaits rather than spinning the run loop, so the section's load can
    /// resume on the main actor.
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    @Test("a Linux host shows its hook status without a connection test")
    func linuxHostLoadsHookStatus() async throws {
        let requested = Mutex(Set<String?>())
        let actions = SettingsActions(loadAgentHooks: { host in
            _ = requested.withLock { $0.insert(host?.sshDestination) }
            return .success([])
        })
        try await withSettings(hosts: [Self.buildServer], actions: actions) { _ in
            try await waitUntil {
                requested.withLock { $0.contains("user@build.example.test") }
            }
        }

        #expect(requested.withLock { $0.contains("user@build.example.test") })
    }

    @MainActor
    private static func show(_ harness: HostsHarness, _ defaults: UserDefaults) -> NSWindow {
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: harness
                    .defaultAppStorage(defaults)
                    .frame(width: 800, height: 744)
            )
        )
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        return window
    }

    @MainActor
    @Test("an unsaved address is checked only after Test Connection")
    func unsavedAddressWaitsForConnectionCheck() async throws {
        let suiteName = "ghosthub.settings.agent-hooks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let requested = Mutex<[String?]>([])
        var actions = SettingsActions()
        actions.loadAgentHooks = { host in
            requested.withLock { $0.append(host?.sshDestination) }
            return .success([])
        }
        let state = HostsState(
            host: Self.buildServer, editedDestination: "user@typo.example.test"
        )
        let window = Self.show(HostsHarness(state: state, actions: actions), defaults)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(requested.withLock { $0 }.isEmpty)

        state.probeResult = HostProbeSummary(host: HostSummary(
            id: UUID(), configKey: "build-server", name: "Build Server",
            kind: .remote, platform: .linux, sshDestination: "user@typo.example.test"
        ))
        try await waitUntil { !requested.withLock { $0 }.isEmpty }

        #expect(requested.withLock { $0 } == ["user@typo.example.test"])
    }

    @MainActor
    @Test("a connection check reloads hook status that could not load before it")
    func connectionCheckReloadsHookStatus() async throws {
        let suiteName = "ghosthub.settings.agent-hooks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // The first load fails as it would before the host key is approved.
        let loads = Mutex(0)
        var actions = SettingsActions()
        actions.loadAgentHooks = { _ in
            let attempt = loads.withLock { count in
                count += 1
                return count
            }
            return attempt == 1
                ? .failure(.message("Host key verification failed."))
                : .success([])
        }
        let state = HostsState(host: Self.buildServer)
        let window = Self.show(HostsHarness(state: state, actions: actions), defaults)
        defer { window.close() }
        try await waitUntil { loads.withLock { $0 } == 1 }

        // Test Connection approved the host and reached it.
        state.probeResult = HostProbeSummary(host: HostSummary(
            id: UUID(), configKey: "build-server", name: "Build Server",
            kind: .remote, platform: .linux,
            sshDestination: "user@build.example.test"
        ))
        try await waitUntil { loads.withLock { $0 } == 2 }

        #expect(loads.withLock { $0 } == 2)
    }
}

/// Host Settings state a test changes, as SettingsView owns it in the app.
@MainActor
@Observable
private final class HostsState {
    var drafts: [SSHHostDraft]
    var selectedDraftID: UUID?
    var probeResult: HostProbeSummary?

    let savedHosts: [SSHHost]

    /// Settings with `host` saved; `editedDestination` is an address typed
    /// in the form but not saved.
    init(host: SSHHost, editedDestination: String? = nil) {
        savedHosts = [host]
        var draft = SSHHostDraft(host)
        if let editedDestination {
            draft.sshDestination = editedDestination
        }
        drafts = [draft]
        selectedDraftID = draft.id
    }
}

private struct HostsHarness: View {
    @Bindable var state: HostsState
    let actions: SettingsActions

    var body: some View {
        HostsSettingsView(
            sshHosts: $state.drafts,
            selectedSSHHostDraftID: $state.selectedDraftID,
            hostProbeResult: $state.probeResult,
            hostProbeErrorMessage: .constant(nil),
            isProbingSSHHost: .constant(false),
            isInstallingRemoteKwt: .constant(false),
            remoteKwtInstallMessage: .constant(nil),
            tailscalePeers: .constant(nil),
            tailscaleError: .constant(nil),
            isLoadingTailscale: .constant(false),
            isTailscaleSheetPresented: .constant(false),
            isInstallingWindowsKwt: .constant(false),
            probeSSHHost: actions.probeSSHHost,
            pendingSSHHostKeyConfirmation: actions.pendingSSHHostKeyConfirmation,
            trustSSHHostKey: actions.trustSSHHostKey,
            sshAuthenticationView: actions.sshAuthenticationView,
            isSSHAuthenticationReady: actions.isSSHAuthenticationReady,
            cancelSSHAuthentication: actions.cancelSSHAuthentication,
            retainSSHAuthenticationForHandoff: actions.retainSSHAuthenticationForHandoff,
            installRemoteKwt: actions.installRemoteKwt,
            registerRemoteProject: actions.registerRemoteProject,
            loadTailscalePeers: actions.loadTailscalePeers,
            installWindowsKwt: actions.installWindowsKwt,
            loadAgentHooks: actions.loadAgentHooks,
            installAgentHooks: actions.installAgentHooks,
            savedSSHHosts: state.savedHosts
        )
    }
}
