import AppKit
import Foundation
import GhosthubSettings
import GhosthubTerminalSupport
import SwiftUI
import Synchronization
import Testing
@testable import GhosthubUI

@Suite("Remote host agent hooks in Settings")
struct RemoteAgentHooksSettingsTests {
    /// Opens Settings on the Hosts pane, where the first SSH host is
    /// selected, and records each host whose hook status is requested.
    @MainActor
    private func requestedHosts(
        for hosts: [SSHHost],
        until done: (Set<String?>) -> Bool
    ) async throws -> Set<String?> {
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
        let requested = Mutex(Set<String?>())
        let actions = SettingsActions(loadAgentHooks: { host in
            _ = requested.withLock { $0.insert(host?.sshDestination) }
            return .success([])
        })
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
        let deadline = Date().addingTimeInterval(3)
        // Await rather than spin the run loop, so the section's load can
        // resume on the main actor after its typing delay.
        while !done(requested.withLock { $0 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return requested.withLock { $0 }
    }

    @MainActor
    @Test("a Linux host shows its hook status without a connection test")
    func linuxHostLoadsHookStatus() async throws {
        let requested = try await requestedHosts(
            for: [SSHHost(
                configKey: "build-server", name: "Build Server",
                platform: .linux, sshDestination: "user@build.example.test"
            )]
        ) { $0.contains("user@build.example.test") }

        #expect(requested.contains("user@build.example.test"))
    }
}
