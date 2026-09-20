import AppKit
import Darwin
import Foundation
import GhosthubSettings
import GhosthubTerminalSupport
import SwiftUI
import Testing
@testable import GhosthubUI

@Suite("Settings documentation screenshots")
struct SettingsScreenshotTests {
    @MainActor
    @Test("exports Settings with synthetic details", arguments: [
        SettingsDomain.hosts, .keyboard, .privacy,
    ])
    func settings(domain: SettingsDomain) throws {
        guard let directory = ProcessInfo.processInfo
            .environment["GHOSTHUB_SETTINGS_SCREENSHOT_DIR"] else { return }
        let path = URL(fileURLWithPath: directory)
            .appendingPathComponent("guide-\(domain.rawValue).png").path
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let suiteName = "ghosthub.settings.screenshot.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(
            configPipeline: LibghosttyConfigPipeline(
                paths: LibghosttyConfigPaths(configDirectory: configDirectory)
            ),
            userDefaults: defaults
        )
        store.setSSHHosts([
            SSHHost(
                configKey: "build-server",
                name: "Build Server",
                platform: .linux,
                sshDestination: "user@build.example.test"
            ),
        ])
        store.selectedDomain = domain
        let controller = NSHostingController(
            rootView: Color.clear
                .sheet(isPresented: .constant(true)) {
                    SettingsView(store: store)
                        .defaultAppStorage(defaults)
                        .frame(width: 1040, height: 744)
                        .preferredColorScheme(.dark)
                }
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(CGSize(width: 1200, height: 900))
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(2)
        while window.attachedSheet == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let sheet = try #require(window.attachedSheet)
        sheet.appearance = NSAppearance(named: .darkAqua)
        let frameView = try #require(sheet.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        frameView.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        // Match the demo capturer: the runtime retains this own-window API
        // even though current SDKs no longer expose it to new source.
        let library = try #require(dlopen(nil, RTLD_LAZY))
        defer { dlclose(library) }
        let symbol = try #require(dlsym(library, "CGWindowListCreateImage"))
        typealias CreateWindowImage = @convention(c) (
            CGRect, UInt32, CGWindowID, UInt32
        ) -> Unmanaged<CGImage>?
        let createImage = unsafeBitCast(symbol, to: CreateWindowImage.self)
        let imageOptions: CGWindowImageOption = [
            .boundsIgnoreFraming, .nominalResolution,
        ]
        let image = try #require(createImage(
            .null, CGWindowListOption.optionIncludingWindow.rawValue,
            CGWindowID(sheet.windowNumber), imageOptions.rawValue
        )).takeRetainedValue()
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
