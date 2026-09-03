import Foundation
import GhosthubTestSupport
import GhosthubTransport
import Synchronization
import Testing
@testable import GhosthubApp

private let findClient = TmuxAttachedClientIdentity(
    serverPID: "123",
    clientPID: "789",
    clientCreatedAt: "321",
    clientTTY: "/dev/ttys001",
    sessionID: "$7",
    sessionCreatedAt: "456",
    paneID: "%9"
)

@Suite("tmux pane Find")
struct TmuxPaneFinderTests {
    @Test("marked state distinguishes matches from no matches")
    func parsesState() {
        #expect(TmuxPaneFinder.parseState(
            "noise\nGHOSTHUB_TMUX_FIND_STATE_token\t1\t5\t0\nwarning",
            marker: "GHOSTHUB_TMUX_FIND_STATE_token",
            includesCount: true
        ) == .match(total: 5))
        #expect(TmuxPaneFinder.parseState(
            "GHOSTHUB_TMUX_FIND_STATE_token\t0\t\t",
            marker: "GHOSTHUB_TMUX_FIND_STATE_token",
            includesCount: true
        ) == .noMatch)
        #expect(TmuxPaneFinder.parseState(
            "GHOSTHUB_TMUX_FIND_STATE_token\t1\t5\t1",
            marker: "GHOSTHUB_TMUX_FIND_STATE_token",
            includesCount: true
        ) == .match(total: nil))
    }

    @Test(arguments: [
        "",
        "GHOSTHUB_TMUX_FIND_STATE_other\t1\t5\t0",
        "GHOSTHUB_TMUX_FIND_STATE_token\tx\t5\t0",
        "GHOSTHUB_TMUX_FIND_STATE_token\t1\t5\t0\textra",
    ])
    func rejectsMalformedState(_ output: String) {
        #expect(TmuxPaneFinder.parseState(
            output,
            marker: "GHOSTHUB_TMUX_FIND_STATE_token",
            includesCount: true
        ) == nil)
    }

    @Test("copy-mode search syntax follows the tmux version boundary")
    func versionedSearchRendering() {
        let legacy = TmuxPaneFinder.action(
            .search("-foo"),
            target: target(version: .init(major: 3, minor: 5)),
            stateMarker: "STATE"
        )
        let modern = TmuxPaneFinder.action(
            .search("-foo"),
            target: target(version: .copyModeOptionParsing),
            stateMarker: "STATE"
        )

        #expect(legacy.contains("'search-backward-text' '-foo'"))
        #expect(!legacy.contains("'search-backward-text' '--' '-foo'"))
        #expect(modern.contains("'search-backward-text' '--' '-foo'"))
    }

    @Test("literal query survives the guarded shell command")
    func literalQueryCommandIsShellSyntax() {
        let query = "match;\"x\" #{pane_id} \\ q't $HOME ${x} -lead"
        let command = TmuxPaneFinder.command(
            .search(query),
            target: target(version: .copyModeOptionParsing),
            guardMarker: "GUARD",
            stateMarker: "STATE",
            hookIndex: 1_500_000_001
        )
        let syntax = AccountCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-n", "-c", command],
            timeout: 5
        )

        #expect(syntax.status == 0, Comment(rawValue: syntax.stderr))
        #expect(command.contains("#{search_present}"))
        #expect(command.contains("#{search_count}"))
        #expect(command.contains("#{search_count_partial}"))
        #expect(!command.contains("#{search_match}"))
    }

    @Test("failures never disclose the query")
    func fixedFailureMessage() async throws {
        let query = "private-query-$HOME"
        let command = Mutex<String?>(nil)
        let finder = TmuxPaneFinder(runner: { _, _, rendered in
            command.withLock { $0 = rendered }
            return (1, query)
        })

        let result = await finder.perform(
            .search(query),
            target: target(version: .copyModeOptionParsing)
        )
        let failure = try #require(result.failure)

        #expect(command.withLock { $0 }?.contains(query) == true)
        #expect(failure.message == "tmux could not search this pane.")
        #expect(!failure.message.contains(query))
    }

    @Test("real tmux searches pane history and cancels copy mode")
    func realTmuxSearch() async throws {
        guard case let .success(binary) = TmuxBinaryResolver()
            .resolveTmuxBinary(),
            let version = TmuxVersion(output: binary.version),
            version >= .minimumFind
        else { return }
        let server = try makeTestTmuxServer(
            tmuxPath: binary.path,
            purpose: "find",
            sessions: ["find"]
        )
        defer { server.stop() }
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let ttyDirectory = stateDirectory.appendingPathComponent(
            "tmux-clients",
            isDirectory: true
        )
        let token = UUID().uuidString.lowercased()
        let client = try TestTmuxClient(
            tmuxPath: binary.path,
            socketName: server.socketName,
            sessionName: "find",
            clientToken: token,
            clientTTYDirectory: ttyDirectory
        )
        defer { client.stop() }
        _ = try await client.publishedTTY()

        let output = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: [
                "-L", server.socketName,
                "send-keys", "-t", "find:",
                "printf '\\156\\145\\145\\144\\154\\145 one\\n"
                    + "\\156\\145\\145\\144\\154\\145 two\\n"
                    + "\\156\\145\\145\\144\\154\\145 three\\n'",
                "Enter",
            ],
            timeout: 5
        )
        #expect(output.status == 0)
        for _ in 0 ..< 100 {
            let capture = AccountCommandRunner.runProcess(
                executable: binary.path,
                arguments: [
                    "-L", server.socketName,
                    "capture-pane", "-p", "-t", "find:",
                ],
                timeout: 5
            )
            if capture.stdout.contains("needle three") {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let identity = try await TmuxPaneSplitter().clientIdentity(
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: binary.path,
                sessionName: "find",
                socketName: server.socketName,
                sshConnectionArguments: [],
                clientToken: token,
                clientTTYDirectory: ttyDirectory.path
            )
        ).get()
        let target = TmuxFindTarget(
            host: .local,
            tmuxPath: binary.path,
            tmuxVersion: version,
            sessionName: "find",
            socketName: server.socketName,
            sshConnectionArguments: [],
            expectedClient: identity
        )
        let finder = TmuxPaneFinder()

        let searched = await finder.perform(.search("needle"), target: target)
        if version >= .searchCount {
            #expect(try searched.get() == .match(total: 3))
        } else {
            #expect(try searched.get() == .match(total: nil))
        }
        #expect(try await finder.perform(.next, target: target).get()
            != .noMatch)
        #expect(try await finder.perform(.previous, target: target).get()
            != .noMatch)
        #expect(try await finder.perform(.cancel, target: target).get() == nil)

        let literal = "match;\"x\" #{pane_id} \\ q't $HOME ${x} -lead"
        let literalOutput = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: [
                "-L", server.socketName,
                "send-keys", "-t", "find:",
                "printf '%s\\n' \(shellQuotedCommandArgument(literal))",
            ],
            timeout: 5
        )
        #expect(literalOutput.status == 0)
        let literalEnter = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: [
                "-L", server.socketName,
                "send-keys", "-t", "find:", "Enter",
            ],
            timeout: 5
        )
        #expect(literalEnter.status == 0)
        for _ in 0 ..< 100 {
            let capture = AccountCommandRunner.runProcess(
                executable: binary.path,
                arguments: [
                    "-L", server.socketName,
                    "capture-pane", "-p", "-t", "find:",
                ],
                timeout: 5
            )
            if capture.stdout.contains(literal) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await finder.perform(.search(literal), target: target).get()
            != .noMatch)
        #expect(try await finder.perform(
            .search("absent-find-value"),
            target: target
        ).get() == .noMatch)

        let activeMode = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: [
                "-L", server.socketName,
                "display-message", "-p", "-t", "find:", "#{pane_in_mode}",
            ],
            timeout: 5
        )
        #expect(activeMode.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == "1")
        #expect(try await finder.perform(.cancel, target: target).get() == nil)

        let mode = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: [
                "-L", server.socketName,
                "display-message", "-p", "-t", "find:", "#{pane_in_mode}",
            ],
            timeout: 5
        )
        #expect(mode.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == "0")

        _ = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: [
                "-L", server.socketName,
                "new-session", "-d", "-s", "keepalive",
            ],
            timeout: 5
        )
        _ = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: [
                "-L", server.socketName,
                "kill-session", "-t", "find",
            ],
            timeout: 5
        )
        let changed = await finder.perform(.search("needle"), target: target)
        #expect(try #require(changed.failure).kind == .targetChanged)
    }

    private func target(version: TmuxVersion) -> TmuxFindTarget {
        TmuxFindTarget(
            host: .local,
            tmuxPath: "/opt/homebrew/bin/tmux",
            tmuxVersion: version,
            sessionName: "find-session",
            socketName: "find-socket",
            sshConnectionArguments: [],
            expectedClient: findClient
        )
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(failure) = self else { return nil }
        return failure
    }
}
