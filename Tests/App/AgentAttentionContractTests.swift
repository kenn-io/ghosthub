import Foundation
import GhosthubTestSupport
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

/// The pinned kwt's agent hook writes the pane state that discovery reads.
extension PinnedKwtContractTests {
    @Test("discovery reads the state the pinned kwt agent hook records")
    func discoveryReadsPinnedAgentHookState() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"] == "1" else { return }
        let binary = try #require(environment["GHOSTHUB_KWT_CONTRACT_BINARY"])
        let tmuxPath = try #require(environment["GHOSTHUB_TEST_TMUX_BINARY"])
        let server = try TestTmuxServer(tmuxPath: tmuxPath, socket: .productContract(name: "kwt"))
        defer { server.stop() }
        try server.createSession("agent desk", command: "/bin/sleep 60")
        try server.createSession("quiet desk", command: "/bin/sleep 60")
        let pane = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: server.connectionArguments + [
                "display-message", "-p", "-t", "=agent desk:",
                "#{pane_id}\t#{socket_path},#{pid},0",
            ],
            timeout: 5
        )
        try #require(pane.status == 0, Comment(rawValue: pane.stderr))
        let fields = pane.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t").map(String.init)
        try #require(fields.count == 2)

        func runHook(_ event: String, _ extra: String = "") throws {
            let payload = #"{"session_id":"s-1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","#
                + #""permission_mode":"default","hook_event_name":""# + event + #"""#
                + extra + "}"
            let hook = AccountCommandRunner.runProcess(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s' \"$1\" | \"$0\" agent-hook run --agent claude"
                        + " --source kwt-tmux-agent-state",
                    binary, payload,
                ],
                timeout: 10,
                environmentOverrides: ["TMUX": fields[1], "TMUX_PANE": fields[0]]
            )
            try #require(hook.status == 0, Comment(rawValue: hook.stderr))
        }
        let bin = URL(fileURLWithPath: tmuxPath).deletingLastPathComponent().path
        let resolver = TmuxBinaryResolver(processRunner: { shell, command in
            AccountCommandRunner.runLoginShell(
                shell: shell,
                command: "export PATH=\(shellQuotedCommandArgument(bin)):$PATH; " + command,
                timeout: 10
            )
        })
        func discoveredPanes(_ name: String) throws -> [TmuxPaneAgentState] {
            try #require(
                resolver.discoverSessions().get().first {
                    $0.name == name && $0.socketName == "kwt"
                }
            ).agentPanes
        }

        try runHook("PermissionRequest", #","tool_name":"Bash","tool_input":{"command":"ls"}"#)
        #expect(try discoveredPanes("agent desk").map(\.state) == [.approval])

        try runHook("Stop")
        let finished = try discoveredPanes("agent desk")
        #expect(finished.map(\.state) == [.done])
        #expect(finished.map(\.agent) == ["claude"])
        #expect(finished.map(\.paneID) == [fields[0]])
        #expect(try discoveredPanes("quiet desk").isEmpty)

        try runHook("SessionEnd", #","reason":"prompt_input_exit""#)
        #expect(try discoveredPanes("agent desk").isEmpty)
    }

    @Test("Ghosthub installs and reads hooks through the pinned kwt")
    func installsAgentHooksThroughPinnedKwt() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"] == "1" else { return }
        let binary = try #require(environment["GHOSTHUB_KWT_CONTRACT_BINARY"])
        let fixture = try TempDirectoryFixture(shortPath: true)
        let home = try fixture.createSubdirectory("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        var overrides = ["HOME": home.path]
        for variable in [
            "CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME", "GEMINI_CLI_HOME",
            "HERMES_HOME", "OPENCODE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "QWEN_HOME",
            "XDG_CONFIG_HOME",
        ] {
            overrides[variable] = ""
        }
        let client = KwtAgentHookClient(
            localRunner: { [overrides] command in
                let output = AccountCommandRunner.runProcess(
                    executable: "/bin/sh",
                    arguments: ["-c", command],
                    timeout: 10,
                    environmentOverrides: overrides
                )
                return (output.status, output.stdout)
            },
            localBinaryPath: binary
        )

        let before = try await client.run(.status, on: .local)
        let claudeBefore = try #require(before.first { $0.agent == "claude" })
        #expect(claudeBefore.available && !claudeBefore.installed)
        #expect(before.first { $0.agent == "codex" }?.available == false)

        let after = try await client.run(.install, on: .local)
        let claude = try #require(after.first { $0.agent == "claude" })
        #expect(claude.installed && claude.current)
        let settings = try String(
            contentsOf: home.appendingPathComponent(".claude/settings.json"),
            encoding: .utf8
        )
        #expect(settings.contains("agent-hook run --agent claude"))
    }
}
