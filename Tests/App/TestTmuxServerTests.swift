import Darwin
import Foundation
import GhosthubTestSupport
import Testing

private func findTestTmux() -> String? {
    ProcessInfo.processInfo.environment["PATH"]?
        .split(separator: ":")
        .map { String($0) + "/tmux" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

private final class TestTmuxCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var arguments: [[String]] = []

    func record(_ arguments: [String]) {
        lock.withLock {
            self.arguments.append(arguments)
        }
    }

    func snapshot() -> [[String]] {
        lock.withLock { arguments }
    }
}

@Suite("test tmux server boundary")
struct TestTmuxServerTests {
    @Test("wrapper identity is required before deriving a socket")
    func missingRunIdentityFails() {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GHOSTHUB_TEST_TMUX_RUN_ID")

        #expect(throws: TestTmuxServerError.self) {
            _ = try TestTmuxServer.runOwnedSocketName(
                purpose: "fixture",
                environment: environment
            )
        }
    }

    @Test("wrapper identity must be six alphanumeric characters")
    func malformedRunIdentityFails() {
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTHUB_TEST_TMUX_RUN_ID"] = "bad-id"

        #expect(throws: TestTmuxServerError.self) {
            _ = try TestTmuxServer.runOwnedSocketName(
                purpose: "fixture",
                environment: environment
            )
        }
    }

    @Test("wrapper directory must match the run identity")
    func mismatchedRunDirectoryFails() {
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTHUB_TEST_TMUX_RUN_ID"] = "ABC123"
        environment["TMUX_TMPDIR"] = "/tmp/not-a-ghosthub-test-run"

        #expect(throws: TestTmuxServerError.self) {
            _ = try TestTmuxServer.runOwnedSocketName(
                purpose: "fixture",
                environment: environment
            )
        }
    }

    @Test("run-owned sockets include the wrapper identity")
    func derivesRunOwnedSocketName() throws {
        let environment = try wrapperEnvironment()
        let runID = try #require(
            environment["GHOSTHUB_TEST_TMUX_RUN_ID"]
        )

        let name = try TestTmuxServer.runOwnedSocketName(
            purpose: "fixture",
            environment: environment
        )

        #expect(name == "ghosthub-fixture-\(runID)")
    }

    @Test("product sockets resolve beneath the wrapper directory")
    func derivesProtectedSocketPath() throws {
        let environment = try wrapperEnvironment()
        let tmuxDirectory = try #require(environment["TMUX_TMPDIR"])
        let server = try TestTmuxServer(
            tmuxPath: "/usr/bin/false",
            socket: .productContract(name: "default"),
            environment: environment
        )

        #expect(
            server.socketPath
                == "\(tmuxDirectory)/tmux-\(getuid())/default"
        )
    }

    @Test(
        "a real server is removed by whole-server teardown",
        .enabled(if: findTestTmux() != nil, "tmux is unavailable")
    )
    func stopsRealServer() throws {
        let tmuxPath = try #require(findTestTmux())
        let environment = try wrapperEnvironment()
        let server = try TestTmuxServer(
            tmuxPath: tmuxPath,
            socket: .runOwned(purpose: "fixture"),
            environment: environment
        )
        try server.createSession("owned")

        #expect(tmuxStatus(tmuxPath, server, ["has-session", "-t", "=owned:"]) == 0)
        server.stop()
        #expect(tmuxStatus(tmuxPath, server, ["has-session", "-t", "=owned:"]) != 0)
    }

    @Test(
        "a protected exact socket remains reachable by its product name",
        .enabled(if: findTestTmux() != nil, "tmux is unavailable")
    )
    func productSocketUsesPrivateNamedPath() throws {
        let tmuxPath = try #require(findTestTmux())
        let server = try TestTmuxServer(
            tmuxPath: tmuxPath,
            socket: .productContract(name: "kwt-pr-0123456789abcdef")
        )
        try server.createSession("protected")

        #expect(
            tmuxNamedStatus(
                tmuxPath,
                server.socketName,
                ["has-session", "-t", "=protected:"]
            ) == 0
        )
        server.stop()
        #expect(
            tmuxNamedStatus(
                tmuxPath,
                server.socketName,
                ["has-session", "-t", "=protected:"]
            ) != 0
        )
    }

    @Test("an injected runner owns server creation and teardown")
    func injectedRunnerOwnsLifecycle() throws {
        let recorder = TestTmuxCommandRecorder()
        let server = try TestTmuxServer(
            tmuxPath: "/test/tmux",
            socket: .runOwned(purpose: "runner"),
            commandRunner: { _, arguments, _ in
                recorder.record(arguments)
                return TestTmuxCommandOutput(status: 0, stderr: "")
            }
        )

        try server.createSession("owned")
        server.stop()

        let calls = recorder.snapshot()
        #expect(calls.count == 2)
        #expect(calls.first?.contains("new-session") == true)
        #expect(calls.last?.suffix(1) == ["kill-server"])
    }

    private func wrapperEnvironment() throws -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        _ = try #require(environment["GHOSTHUB_TEST_TMUX_RUN_ID"])
        _ = try #require(environment["TMUX_TMPDIR"])
        return environment
    }

    private func tmuxStatus(
        _ tmuxPath: String,
        _ server: TestTmuxServer,
        _ arguments: [String]
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = server.connectionArguments + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func tmuxNamedStatus(
        _ tmuxPath: String,
        _ socketName: String,
        _ arguments: [String]
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-L", socketName] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
