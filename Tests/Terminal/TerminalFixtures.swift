import Dispatch
import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubTerminalSupport

// MARK: - Runtime Callbacks Spy

final class RuntimeCallbacksSpy {
    var recordedClipboardLocation: LibghosttyClipboardLocation?
    var recordedCloseProcessAlive: Bool?

    var callbacks: LibghosttySurfaceRuntimeCallbacks {
        LibghosttySurfaceRuntimeCallbacks(
            readClipboard: { [weak self] loc, _ in
                self?.recordedClipboardLocation = loc
            },
            closeSurface: { [weak self] alive in
                self?.recordedCloseProcessAlive = alive
            }
        )
    }
}

// MARK: - Dummy Runtime Callbacks

extension LibghosttySurfaceRuntimeCallbacks {
    static var dummy: LibghosttySurfaceRuntimeCallbacks {
        .init(
            readClipboard: { _, _ in },
            closeSurface: { _ in }
        )
    }
}

// MARK: - Mock Libghostty Layout

struct MockLibghosttyLayout {
    let root: URL
    let resources: URL
    let tempDir: TempDirectoryFixture

    static func create() throws -> MockLibghosttyLayout {
        let tempDir = try TempDirectoryFixture()
        let root = tempDir.url
        let resources = root
            .appendingPathComponent(
                ".build/libghostty/source/zig-out/share/ghostty",
                isDirectory: true
            )
        let terminfo = root
            .appendingPathComponent(
                ".build/libghostty/source/zig-out/share/terminfo/78",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: terminfo,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: terminfo
                .appendingPathComponent("xterm-ghostty").path,
            contents: Data()
        )

        return MockLibghosttyLayout(
            root: root,
            resources: resources,
            tempDir: tempDir
        )
    }
}

struct TemporaryConfigMonitorFixture {
    let tempDirectory: URL
    let configFile: URL
    let tempDir: TempDirectoryFixture

    static func create() throws -> TemporaryConfigMonitorFixture {
        let tempDir = try TempDirectoryFixture()

        return TemporaryConfigMonitorFixture(
            tempDirectory: tempDir.url,
            configFile: tempDir.url.appendingPathComponent(
                "ghostty.conf",
                isDirectory: false
            ),
            tempDir: tempDir
        )
    }

    func writeConfig(
        _ content: String,
        to url: URL? = nil,
        atomically: Bool = true
    ) throws {
        try content.write(
            to: url ?? configFile,
            atomically: atomically,
            encoding: .utf8
        )
    }

    func startMonitor(
        fileURL: URL? = nil,
        changeHandler: @escaping @Sendable () -> Void
    ) throws -> LibghosttyConfigFileMonitor {
        let monitor = LibghosttyConfigFileMonitor(
            fileURL: fileURL ?? configFile,
            changeHandler: changeHandler
        )
        try monitor.start()
        return monitor
    }

    func expectChange(
        timeout: TimeInterval = 10.0,
        action: @escaping @Sendable (URL) -> Void
    ) throws {
        let changed = DispatchSemaphore(value: 0)
        let monitor = try startMonitor { changed.signal() }
        defer { monitor.stop() }

        // Repeat the mutation until the monitor reports it: under parallel
        // test load a single write can race dispatch-source arming or a
        // starved queue, so any one bounded wait is a flake. A dead monitor
        // still fails; it never signals no matter how many writes land.
        let deadline = Date().addingTimeInterval(timeout)
        var fired = false
        while !fired, Date() < deadline {
            action(configFile)
            fired = changed.wait(timeout: .now() + 0.25) == .success
        }
        #expect(fired)
    }

    static func withFixture(
        initialConfig: String? = nil,
        _ body: (TemporaryConfigMonitorFixture) throws -> Void
    ) throws {
        let fixture = try create()
        if let config = initialConfig {
            try fixture.writeConfig(config)
        }
        try withExtendedLifetime(fixture.tempDir) {
            try body(fixture)
        }
    }
}
