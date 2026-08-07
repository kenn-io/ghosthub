import AppKit
import GhosthubSettings
import GhosthubTerminalSupport
@testable import GhosthubUI
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
            configPipeline: LibghosttyConfigPipeline(
                paths: LibghosttyConfigPaths(
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

    private func waitForAttachedSheet(
        on window: NSWindow,
        timeout: TimeInterval = 1
    ) -> NSWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        while window.attachedSheet == nil, Date() < deadline {
            RunLoop.main.run(
                until: Date().addingTimeInterval(0.01)
            )
        }
        return window.attachedSheet
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

    func testFollowConfigAllowsSharedTmuxThemeOverride() throws {
        let store = makeSettingsStore()
        store.selectedDomain = .appearance
        store.setTerminalTheme(.followConfig)
        let hostingView = NSHostingView(
            rootView: SettingsSheetHost(store: store)
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1600,
                height: 1000
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        addTeardownBlock { window.close() }

        let sheet = try XCTUnwrap(waitForAttachedSheet(on: window))
        let sheetContent = try XCTUnwrap(sheet.contentView)
        let toggle = try XCTUnwrap(
            firstUntitledButton(in: sheetContent)
        )
        XCTAssertTrue(toggle.isEnabled)
    }

    func testRestoredDomainsKeepStableMinimumSize() {
        let store = makeSettingsStore()
        for domain in [
            SettingsDomain.keyboard,
            .worktrees,
            .agents,
            .integrations,
        ] {
            store.selectedDomain = domain
            assertStableSize(fittingSize(for: store))
        }
    }

    func testSettingsViewOpeningSizeAdaptsToLayoutProposal() {
        let store = makeSettingsStore()
        let proposals = [
            CGSize(width: 1400, height: 900),
            CGSize(width: 1600, height: 1000),
        ]
        let controller = NSHostingController(
            rootView: SettingsView(store: store)
        )

        XCTAssertNotEqual(
            controller.sizeThatFits(in: proposals[0]),
            controller.sizeThatFits(in: proposals[1])
        )
    }

    func testPresentedSettingsKeepsSizeWhenDomainChanges() throws {
        let store = makeSettingsStore()
        store.selectedDomain = .appearance
        let hostingView = NSHostingView(
            rootView: SettingsSheetHost(store: store)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        addTeardownBlock {
            window.close()
        }

        let sheet = try XCTUnwrap(waitForAttachedSheet(on: window))
        let initialSize = sheet.frame.size
        let sheetContent = try XCTUnwrap(sheet.contentView)
        let settingsList = try XCTUnwrap(
            viewDescendants(of: sheetContent)
                .compactMap { $0 as? NSTableView }
                .first { $0.selectedRow >= 0 }
        )
        let appearanceIndex = try XCTUnwrap(
            SettingsDomain.allCases.firstIndex(of: .appearance)
        )
        let terminalIndex = try XCTUnwrap(
            SettingsDomain.allCases.firstIndex(of: .terminal)
        )
        let terminalRow = settingsList.selectedRow
            + terminalIndex - appearanceIndex

        settingsList.selectRowIndexes(
            IndexSet(integer: terminalRow),
            byExtendingSelection: false
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(settingsList.selectedRow, terminalRow)
        XCTAssertEqual(sheet.frame.size, initialSize)
    }

    func testDomainNavigationKeepsExeAccountRefresh() throws {
        let store = makeSettingsStore()
        store.selectedDomain = .integrations
        let refreshID = UUID()
        var cancelledRefreshIDs: [UUID] = []
        let actions = SettingsActions(
            cancelExeAccountRefresh: { cancelledRefreshIDs.append($0) }
        )
        let hostingView = NSHostingView(
            rootView: SettingsSheetHost(
                store: store,
                actions: actions,
                initialExeAccountRefreshID: refreshID
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        pumpRunLoopAndLayout(for: hostingView)
        addTeardownBlock { window.close() }
        let sheet = try XCTUnwrap(waitForAttachedSheet(on: window))
        let sheetContent = try XCTUnwrap(sheet.contentView)
        sheet.displayIfNeeded()
        sheetContent.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let settingsList = try XCTUnwrap(
            viewDescendants(of: sheetContent)
                .compactMap { $0 as? NSTableView }
                .first { $0.selectedRow >= 0 }
        )
        let integrationsIndex = try XCTUnwrap(
            SettingsDomain.allCases.firstIndex(of: .integrations)
        )
        let appearanceIndex = try XCTUnwrap(
            SettingsDomain.allCases.firstIndex(of: .appearance)
        )
        let appearanceRow = settingsList.selectedRow
            + appearanceIndex - integrationsIndex
        settingsList.selectRowIndexes(
            IndexSet(integer: appearanceRow),
            byExtendingSelection: false
        )
        pumpRunLoopAndLayout(for: hostingView)

        XCTAssertEqual(cancelledRefreshIDs, [])
    }

}

@MainActor
private func firstUntitledButton(in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title.isEmpty {
        return button
    }
    for subview in view.subviews {
        if let button = firstUntitledButton(in: subview) {
            return button
        }
    }
    return nil
}

private struct SettingsSheetHost: View {
    @ObservedObject var store: SettingsStore
    var actions = SettingsActions()
    var initialExeAccountRefreshID: UUID?

    var body: some View {
        Color.clear
            .sheet(isPresented: .constant(true)) {
                SettingsView(
                    store: store,
                    actions: actions,
                    initialExeAccountRefreshID: initialExeAccountRefreshID
                )
            }
    }
}
