import Darwin
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

    @Test(
        "runtime monitor surfaces non-missing open failures",
        arguments: [Int32(EACCES), Int32(EMFILE)]
    )
    func runtimeMonitorSurfacesOpenFailure(openError: Int32) throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        try fixture.writeConfig("font-size = 13\n")
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                guard path == fixture.configFile.path else {
                    return open(path, flags)
                }
                errno = openError
                return -1
            },
            changeHandler: {}
        )

        expectThrowsEqual(
            LibghosttyConfigFileMonitorError.openFile(
                fixture.configFile, openError
            )
        ) {
            try monitor.start()
        }
    }

    @Test("monitor retains successful sources after a later open failure")
    func monitorRetainsSuccessfulSourcesAfterOpenFailure() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        try fixture.writeConfig("font-size = 13\n")
        let changed = DispatchSemaphore(value: 0)
        let blockedDirectory = fixture.tempDirectory.standardizedFileURL
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                guard path == blockedDirectory.path else {
                    return open(path, flags)
                }
                errno = EACCES
                return -1
            }
        ) {
            changed.signal()
        }
        defer { monitor.stop() }

        expectThrowsEqual(
            LibghosttyConfigFileMonitorError.openFile(
                blockedDirectory, EACCES
            )
        ) {
            try monitor.start()
        }

        try fixture.writeConfig("font-size = 14\n")
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("unchanged update retries a degraded watch graph")
    func unchangedUpdateRetriesMissingSources() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        try fixture.writeConfig("font-size = 13\n")
        let blockedDirectory = fixture.tempDirectory.standardizedFileURL
        var blocksDirectory = true
        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                guard blocksDirectory,
                      path == blockedDirectory.path
                else {
                    return open(path, flags)
                }
                errno = EMFILE
                return -1
            }
        ) {
            changed.signal()
        }
        defer { monitor.stop() }
        expectThrowsEqual(
            LibghosttyConfigFileMonitorError.openFile(
                blockedDirectory, EMFILE
            )
        ) {
            try monitor.start()
        }

        blocksDirectory = false
        try monitor.update(fileURLs: [fixture.configFile])
        try FileManager.default.removeItem(at: fixture.configFile)
        #expect(changed.wait(timeout: .now() + 2) == .success)
        while changed.wait(timeout: .now()) == .success {}

        try fixture.writeConfig("font-size = 14\n")
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("unchanged graph updates do not reopen descriptors")
    func unchangedGraphUpdateIsNoOp() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        try fixture.writeConfig("font-size = 13\n")
        var openCount = 0
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                openCount += 1
                return open(path, flags)
            },
            changeHandler: {}
        )
        try monitor.start()
        defer { monitor.stop() }
        let startOpenCount = openCount

        try monitor.update(fileURLs: [fixture.configFile])

        #expect(openCount == startOpenCount)
    }

    @Test("in-place writes invalidate a staged file snapshot")
    func inPlaceWriteInvalidatesStagedSnapshot() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let replacement = fixture.tempDirectory
            .appendingPathComponent("replacement.conf")
        try fixture.writeConfig("font-size = 13\n")
        try fixture.writeConfig("font-size = 14\n", to: replacement)
        var replacementOpenCount = 0
        var didRewriteReplacement = false
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                let descriptor = open(path, flags)
                guard path == replacement.path else {
                    return descriptor
                }
                replacementOpenCount += 1
                if !didRewriteReplacement {
                    try? "font-size = 123\n".write(
                        to: replacement,
                        atomically: false,
                        encoding: .utf8
                    )
                    didRewriteReplacement = true
                }
                return descriptor
            },
            changeHandler: {}
        )
        try monitor.start()
        defer { monitor.stop() }

        try monitor.update(fileURLs: [replacement])

        #expect(replacementOpenCount == 2)
    }

    @Test("failed graph replacement retains the previous watch graph")
    func failedGraphReplacementRetainsExistingSources() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let replacement = fixture.tempDirectory
            .appendingPathComponent("replacement.conf")
        try fixture.writeConfig("font-size = 13\n")
        try fixture.writeConfig("font-size = 14\n", to: replacement)
        var blockedPath: String?
        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                guard path == blockedPath else {
                    return open(path, flags)
                }
                errno = EMFILE
                return -1
            }
        ) {
            changed.signal()
        }
        try monitor.start()
        defer { monitor.stop() }

        blockedPath = replacement.path
        expectThrowsEqual(
            LibghosttyConfigFileMonitorError.openFile(
                replacement, EMFILE
            )
        ) {
            try monitor.update(fileURLs: [replacement])
        }

        try fixture.writeConfig("font-size = 15\n")
        #expect(changed.wait(timeout: .now() + 2) == .success)

        blockedPath = nil
        try monitor.update(fileURLs: [replacement])
        try fixture.writeConfig("font-size = 16\n")
        #expect(
            changed.wait(timeout: .now() + 0.25) == .timedOut
        )
        try fixture.writeConfig("font-size = 17\n", to: replacement)
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("failed retry does not commit an unstable staged graph")
    func failedRetryPreservesPreviousGraph() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let replacementDirectory = fixture.tempDirectory
            .appendingPathComponent("replacement", isDirectory: true)
        let replacement = replacementDirectory
            .appendingPathComponent("terminal.conf")
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: false
        )
        try fixture.writeConfig("font-size = 13\n")
        try fixture.writeConfig("font-size = 14\n", to: replacement)
        var didInvalidateSnapshot = false
        var replacementDirectoryOpenCount = 0
        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                if path == replacement.path,
                   !didInvalidateSnapshot {
                    let descriptor = open(path, flags)
                    try? FileManager.default.removeItem(at: replacement)
                    didInvalidateSnapshot = true
                    return descriptor
                }
                if path == replacementDirectory.path {
                    replacementDirectoryOpenCount += 1
                    if replacementDirectoryOpenCount > 1 {
                        errno = EACCES
                        return -1
                    }
                }
                return open(path, flags)
            },
            changeHandler: {
                changed.signal()
            }
        )
        try monitor.start()
        defer { monitor.stop() }

        expectThrowsEqual(
            LibghosttyConfigFileMonitorError.openFile(
                replacementDirectory,
                EACCES
            )
        ) {
            try monitor.update(fileURLs: [replacement])
        }

        try fixture.writeConfig("font-size = 15\n")
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("missing graph replacements prune obsolete directories")
    func missingGraphReplacementsPruneObsoleteDirectories() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        var missingConfigs: [URL] = []
        for index in 0..<8 {
            let directory = fixture.tempDirectory.appendingPathComponent(
                "missing-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            missingConfigs.append(
                directory.appendingPathComponent("terminal.conf")
            )
        }
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [missingConfigs[0]],
            debounceInterval: .milliseconds(25),
            changeHandler: {}
        )
        try monitor.start()
        defer { monitor.stop() }

        for config in missingConfigs.dropFirst() {
            try monitor.update(fileURLs: [config])
            #expect(
                monitor.activeWatchedDirectories()
                    == monitor.watchedDirectories()
            )
        }
    }

    @Test("deeper missing graphs prune obsolete ancestor fallbacks")
    func deeperMissingGraphsPruneObsoleteAncestorFallbacks() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        var directory = fixture.tempDirectory
        var missingConfigs: [URL] = []
        for index in 0..<8 {
            directory = directory.appendingPathComponent(
                "level-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            missingConfigs.append(
                directory.appendingPathComponent("terminal.conf")
            )
        }
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [missingConfigs[0]],
            debounceInterval: .milliseconds(25),
            changeHandler: {}
        )
        try monitor.start()
        defer { monitor.stop() }

        for config in missingConfigs.dropFirst() {
            try monitor.update(fileURLs: [config])
            #expect(
                monitor.activeWatchedDirectories()
                    == monitor.watchedDirectories()
            )
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

    @Test("new config reloads even when its watcher cannot be installed")
    func newConfigReloadsWhenWatcherInstallFails() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        var blocksConfig = false
        let changed = DispatchSemaphore(value: 0)
        let failed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [fixture.configFile],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                guard blocksConfig,
                      path == fixture.configFile.path
                else {
                    return open(path, flags)
                }
                errno = EMFILE
                return -1
            },
            errorHandler: { _ in
                failed.signal()
            },
            changeHandler: {
                changed.signal()
            }
        )
        try monitor.start()
        defer { monitor.stop() }

        blocksConfig = true
        try fixture.writeConfig("font-size = 14\n")

        #expect(failed.wait(timeout: .now() + 2) == .success)
        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("directory disappearance falls back to an existing ancestor")
    func directoryDisappearanceFallsBackToExistingAncestor() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let transientDirectory = fixture.tempDirectory.appendingPathComponent(
            "transient",
            isDirectory: true
        )
        let config = transientDirectory.appendingPathComponent(
            "terminal.conf"
        )
        try FileManager.default.createDirectory(
            at: transientDirectory,
            withIntermediateDirectories: false
        )
        var removedTransientDirectory = false
        let changed = DispatchSemaphore(value: 0)
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [config],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                if !removedTransientDirectory,
                   path == transientDirectory.path {
                    removedTransientDirectory = true
                    try? FileManager.default.removeItem(
                        at: transientDirectory
                    )
                }
                return open(path, flags)
            },
            changeHandler: {
                changed.signal()
            }
        )
        try monitor.start()
        defer { monitor.stop() }
        #expect(
            monitor.activeWatchedDirectories().contains(
                fixture.tempDirectory.standardizedFileURL
            )
        )

        try FileManager.default.createDirectory(
            at: transientDirectory,
            withIntermediateDirectories: false
        )
        try fixture.writeConfig("font-size = 14\n", to: config)

        #expect(changed.wait(timeout: .now() + 2) == .success)
    }

    @Test("unstable directory coverage is reported")
    func unstableDirectoryCoverageIsReported() throws {
        let fixture = try TemporaryConfigMonitorFixture.create()
        let missingConfig = fixture.tempDirectory.appendingPathComponent(
            "terminal.conf"
        )
        let blockedDirectory = fixture.tempDirectory.standardizedFileURL
        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: [missingConfig],
            queue: DispatchQueue(
                label: "com.ghosthub.terminal.config-monitor-test"
            ),
            debounceInterval: .milliseconds(25),
            requiringExistingFiles: false,
            openHandler: { path, flags in
                guard path == blockedDirectory.path else {
                    return open(path, flags)
                }
                errno = ENOENT
                return -1
            },
            changeHandler: {}
        )

        expectThrowsEqual(
            LibghosttyConfigFileMonitorError.openFile(
                blockedDirectory,
                ENOENT
            )
        ) {
            try monitor.start()
        }
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
        #expect(
            monitor.activeWatchedDirectories().contains(
                targetDirectory.standardizedFileURL
            )
        )

        try FileManager.default.removeItem(at: target)
        #expect(changed.wait(timeout: .now() + 2) == .success)
        while changed.wait(timeout: .now()) == .success {}
        #expect(
            monitor.activeWatchedDirectories().contains(
                targetDirectory.standardizedFileURL
            )
        )

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
