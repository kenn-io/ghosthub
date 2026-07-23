import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubTerminalSupport

struct LibghosttyConfigFileMonitorTests {
    @Test("monitor fires when the config file changes")
    func monitorFiresWhenConfigFileChanges() throws {
        try TemporaryConfigMonitorFixture.withFixture(
            initialConfig: "font-size = 13\n"
        ) { fixture in
            try fixture.expectChange { file in
                try? "font-size = 14\n".write(
                    to: file,
                    atomically: false,
                    encoding: .utf8
                )
            }
        }
    }

    @Test("monitor throws when the config file does not exist")
    func monitorThrowsWhenConfigFileDoesNotExist() throws {
        try TemporaryConfigMonitorFixture.withFixture { fixture in
            let missingFile =
                fixture.tempDirectory.appendingPathComponent(
                    "missing.conf",
                    isDirectory: false
                )
            let monitor = LibghosttyConfigFileMonitor(
                fileURL: missingFile,
                changeHandler: {}
            )

            expectThrowsEqual(
                LibghosttyConfigFileMonitorError.openFile(
                    missingFile, ENOENT
                )
            ) {
                try monitor.start()
            }
        }
    }

    @Test("monitor reattaches after delete and recreate")
    func monitorReattachesAfterFileIsDeletedAndRecreatedLater()
        throws {
        try TemporaryConfigMonitorFixture.withFixture(
            initialConfig: "font-size = 13\n"
        ) { fixture in
            try fixture.expectChange(timeout: 3.0) { file in
                try? FileManager.default.removeItem(at: file)
                Thread.sleep(forTimeInterval: 0.25)
                try? "font-size = 14\n".write(
                    to: file,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    @Test("monitor coalesces writes across the active config graph")
    func monitorDebouncesConfigGraphWrites() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let included = fixture.tempDirectory
            .appendingPathComponent("included.conf")
        try fixture.writeConfig("font-size = 13\n")
        try fixture.writeConfig("foreground = ffffff\n", to: included)

        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile, included],
            debounceInterval: .milliseconds(250)
        ) {
            changed.signal()
        }
        try monitor.start()
        defer { monitor.stop() }

        try fixture.writeConfig("font-size = 14\n")
        try fixture.writeConfig("foreground = eeeeee\n", to: included)

        #expect(changed.wait(timeout: .now() + 2) == .success)
        #expect(
            changed.wait(timeout: .now() + 0.4) == .timedOut
        )
    }

    @Test("monitor notices creation of a config under an absent directory")
    func monitorNoticesMissingConfigCreation() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let nested = fixture.tempDirectory
            .appendingPathComponent("project/.ghosthub/terminal.conf")
        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [nested],
            debounceInterval: .milliseconds(25)
        ) {
            changed.signal()
        }
        try monitor.start()
        defer { monitor.stop() }

        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fixture.writeConfig(
            "font-size = 15\n",
            to: nested
        )

        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("monitor replaces its watched config graph")
    func monitorUpdatesConfigGraph() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let replacement = fixture.tempDirectory
            .appendingPathComponent("replacement.conf")
        try fixture.writeConfig("font-size = 13\n")
        try fixture.writeConfig("font-size = 14\n", to: replacement)

        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            debounceInterval: .milliseconds(25)
        ) {
            changed.signal()
        }
        try monitor.start()
        defer { monitor.stop() }
        try monitor.update(fileURLs: [replacement])

        try fixture.writeConfig("font-size = 16\n")
        #expect(
            changed.wait(timeout: .now() + 0.25) == .timedOut
        )

        try fixture.writeConfig("font-size = 17\n", to: replacement)
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("monitor notices when a config symlink changes targets")
    func monitorNoticesSymlinkRetargeting() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let first = fixture.tempDirectory
            .appendingPathComponent("first.conf")
        let second = fixture.tempDirectory
            .appendingPathComponent("second.conf")
        try fixture.writeConfig("font-size = 13\n", to: first)
        try fixture.writeConfig("font-size = 14\n", to: second)
        try FileManager.default.createSymbolicLink(
            at: fixture.configFile,
            withDestinationURL: first
        )

        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            debounceInterval: .milliseconds(25)
        ) {
            changed.signal()
        }
        try monitor.start()
        defer { monitor.stop() }

        try FileManager.default.removeItem(at: fixture.configFile)
        try FileManager.default.createSymbolicLink(
            at: fixture.configFile,
            withDestinationURL: second
        )

        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("monitor notices creation of a dangling symlink target")
    func monitorNoticesDanglingSymlinkTargetCreation() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let lexicalDirectory = fixture.tempDirectory
            .appendingPathComponent("lexical", isDirectory: true)
        let targetDirectory = fixture.tempDirectory
            .appendingPathComponent("targets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lexicalDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: false
        )
        let config = lexicalDirectory.appendingPathComponent("terminal.conf")
        let target = targetDirectory.appendingPathComponent("terminal.conf")
        try FileManager.default.createSymbolicLink(
            at: config,
            withDestinationURL: target
        )

        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [config],
            debounceInterval: .milliseconds(25)
        ) {
            changed.signal()
        }
        try monitor.start()
        defer { monitor.stop() }

        try fixture.writeConfig("font-size = 14\n", to: target)
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("monitor notices recreation of a deleted symlink target")
    func monitorNoticesDelayedSymlinkTargetRecreation() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let lexicalDirectory = fixture.tempDirectory
            .appendingPathComponent("lexical", isDirectory: true)
        let targetDirectory = fixture.tempDirectory
            .appendingPathComponent("targets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lexicalDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: false
        )
        let config = lexicalDirectory.appendingPathComponent("terminal.conf")
        let target = targetDirectory.appendingPathComponent("terminal.conf")
        try fixture.writeConfig("font-size = 13\n", to: target)
        try FileManager.default.createSymbolicLink(
            at: config,
            withDestinationURL: target
        )

        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [config],
            debounceInterval: .milliseconds(25)
        ) {
            changed.signal()
        }
        try monitor.start()
        defer { monitor.stop() }

        try FileManager.default.removeItem(at: target)
        #expect(changed.wait(timeout: .now() + 2) == .success)
        while changed.wait(timeout: .now()) == .success {}

        try fixture.writeConfig("font-size = 14\n", to: target)
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("watch graph processes more than 64 desired files")
    func watchGraphDoesNotSpendSymlinkBudgetOnDesiredFiles() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        var configFiles: [URL] = []
        var expectedDirectories: Set<URL> = []

        for index in 0..<80 {
            let directory = fixture.tempDirectory.appendingPathComponent(
                "config-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            expectedDirectories.insert(directory.standardizedFileURL)
            configFiles.append(
                directory.appendingPathComponent("terminal.conf")
            )
        }

        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: configFiles,
            changeHandler: {}
        )
        let watchedDirectories = monitor.watchedDirectories()

        #expect(expectedDirectories.isSubset(of: watchedDirectories))
    }

    @Test("monitor rebinds when an ancestor symlink changes targets")
    func monitorRebindsAfterAncestorSymlinkRetargeting() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let firstDirectory = fixture.tempDirectory
            .appendingPathComponent("first", isDirectory: true)
        let secondDirectory = fixture.tempDirectory
            .appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: firstDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: secondDirectory,
            withIntermediateDirectories: false
        )
        let first = firstDirectory.appendingPathComponent("terminal.conf")
        let second = secondDirectory.appendingPathComponent("terminal.conf")
        try fixture.writeConfig("font-size = 13\n", to: first)
        try fixture.writeConfig("font-size = 14\n", to: second)

        let current = fixture.tempDirectory
            .appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: current,
            withDestinationURL: firstDirectory
        )
        let config = current.appendingPathComponent("terminal.conf")
        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [config],
            debounceInterval: .milliseconds(25)
        ) {
            changed.signal()
        }
        try monitor.start()
        defer { monitor.stop() }

        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(
            at: current,
            withDestinationURL: secondDirectory
        )
        #expect(changed.wait(timeout: .now() + 2) == .success)
        while changed.wait(timeout: .now()) == .success {}

        try fixture.writeConfig("font-size = 15\n", to: first)
        #expect(
            changed.wait(timeout: .now() + 0.25) == .timedOut
        )

        try fixture.writeConfig("font-size = 16\n", to: second)
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }
}
