import Foundation
import GhosthubTestSupport
import GhosthubTmux
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

/// Ghosthub lists, restores, and forgets saved sessions through the pinned kwt.
extension PinnedKwtContractTests {
    @Test("a stopped server's session is listed, restored, and forgotten")
    func restoresAndForgetsSavedSessionsThroughPinnedKwt() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"] == "1" else { return }
        let binary = try #require(environment["GHOSTHUB_KWT_CONTRACT_BINARY"])
        let tmuxPath = try #require(environment["GHOSTHUB_TEST_TMUX_BINARY"])
        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = try fixture.createSubdirectory("kwt-home")
        let overrides = ["KWT_HOME": kwtHome.path, "SHELL": "/bin/sh"]
        let client = KwtSessionClient(
            localRunner: { command in
                let output = AccountCommandRunner.runProcess(
                    executable: "/bin/sh",
                    arguments: ["-c", command],
                    timeout: 30,
                    environmentOverrides: overrides
                )
                return (output.status, output.stdout)
            },
            localBinaryPath: binary
        )
        let server = try TestTmuxServer(
            tmuxPath: tmuxPath,
            socket: .productContract(name: "default")
        )
        func tmux(_ arguments: String...) -> AccountCommandOutput {
            AccountCommandRunner.runProcess(
                executable: tmuxPath,
                arguments: server.connectionArguments + arguments,
                timeout: 10
            )
        }
        defer { _ = tmux("kill-server") }
        func saved() async throws -> [SavedTmuxSession] {
            try await client.savedSessions(on: .local).filter { $0.session == "restore desk" }
        }

        try server.createSession("restore desk", command: "/bin/sleep 600")
        #expect(try await saved().isEmpty)

        server.stop()
        let entry = try #require(try await saved().first)
        #expect(entry.isOnGhosthubServer)
        #expect(entry.socket.name == "default")

        let report = try await client.restore([entry.id], on: .local)
        #expect(report.entries.map(\.outcome) == ["restored"])
        #expect(report.problems.isEmpty)
        let identity = tmux(
            "display-message", "-p", "-t", "=restore desk:",
            "#{pid}\t#{session_id}\t#{session_created}"
        )
        try #require(identity.status == 0, Comment(rawValue: identity.stderr))
        let fields = identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t").map(String.init)
        try #require(fields.count == 3)

        // Killing the server's last session stops it; forget keeps the
        // killed session from coming back as restorable.
        #expect(try await saved().isEmpty)
        _ = tmux("kill-server")
        try await client.forget(
            socketName: "default",
            identity: TmuxSessionIdentity(
                serverPID: fields[0], sessionID: fields[1], createdAt: fields[2]
            ),
            on: .local
        )
        #expect(try await saved().isEmpty)
    }

    @Test("a dismissed saved session is no longer offered")
    func dismissesSavedSessionThroughPinnedKwt() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"] == "1" else { return }
        let binary = try #require(environment["GHOSTHUB_KWT_CONTRACT_BINARY"])
        let tmuxPath = try #require(environment["GHOSTHUB_TEST_TMUX_BINARY"])
        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = try fixture.createSubdirectory("kwt-home")
        let overrides = ["KWT_HOME": kwtHome.path, "SHELL": "/bin/sh"]
        let client = KwtSessionClient(
            localRunner: { command in
                let output = AccountCommandRunner.runProcess(
                    executable: "/bin/sh",
                    arguments: ["-c", command],
                    timeout: 30,
                    environmentOverrides: overrides
                )
                return (output.status, output.stdout)
            },
            localBinaryPath: binary
        )
        let server = try TestTmuxServer(
            tmuxPath: tmuxPath,
            socket: .productContract(name: "default")
        )
        defer { server.stop() }
        func saved() async throws -> [SavedTmuxSession] {
            try await client.savedSessions(on: .local).filter { $0.session == "dismiss desk" }
        }

        try server.createSession("dismiss desk", command: "/bin/sleep 600")
        #expect(try await saved().isEmpty)
        server.stop()
        let entry = try #require(try await saved().first)
        // A plain session gets its own sidebar row.
        #expect(!entry.worktree)
        #expect(entry.savedAt > 0)

        try await client.dismiss([entry.id], on: .local)
        #expect(try await saved().isEmpty)
    }
}
