import AppKit
import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubUI
import GhosthubWorkspace
import SwiftUI
import XCTest

@MainActor
final class SettingsViewTests: XCTestCase {
    private let stableMinimumSize = CGSize(width: 1040, height: 680)

    private func makeSettingsStore() -> SettingsStore {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        let suiteName = "ghosthub.settings.view.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(
            configPipeline: GhosttyConfigPipeline(
                paths: GhosttyConfigPaths(
                    configDirectory: tempRoot.appendingPathComponent(
                        ".config",
                        isDirectory: true
                    )
                )
            ),
            userDefaults: defaults
        )
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        return store
    }

    private func assertStableSize(
        _ actual: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.width,
            stableMinimumSize.width,
            accuracy: 0.5,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.height,
            stableMinimumSize.height,
            accuracy: 0.5,
            file: file,
            line: line
        )
    }

    private func pumpRunLoopAndLayout<Content: View>(
        for hostingView: NSHostingView<Content>
    ) {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func fittingSize(for store: SettingsStore) -> CGSize {
        let hostingView = NSHostingView(
            rootView: SettingsView(store: store)
        )
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }

    func testHostsDomainWithSSHHostKeepsStableMinimumSize() {
        let store = makeSettingsStore()
        store.selectedDomain = .hosts
        store.setSSHHosts([
            SSHHost(
                configKey: "office",
                name: "Office Studio",
                platform: .linux,
                sshDestination: "wesm@office-studio"
            ),
        ])

        assertStableSize(fittingSize(for: store))
    }

    func testSettingsViewHostsDomainRequestsStableMinimumSize() {
        let store = makeSettingsStore()
        store.selectedDomain = .hosts

        assertStableSize(fittingSize(for: store))
    }

    func testAppearanceDomainUsesStableMinimumSize() {
        let store = makeSettingsStore()
        store.selectedDomain = .appearance

        assertStableSize(fittingSize(for: store))
    }

    func testRestoredDomainsKeepStableMinimumSize() {
        let store = makeSettingsStore()
        for domain in [
            SettingsDomain.keyboard,
            .worktrees,
            .agents,
        ] {
            store.selectedDomain = domain
            assertStableSize(fittingSize(for: store))
        }
    }

}
