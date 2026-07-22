import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubTerminalSupport

struct GhosttyConfigFileMonitorTests {
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
            let monitor = GhosttyConfigFileMonitor(
                fileURL: missingFile,
                changeHandler: {}
            )

            expectThrowsEqual(
                GhosttyConfigFileMonitorError.openFile(
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
}
