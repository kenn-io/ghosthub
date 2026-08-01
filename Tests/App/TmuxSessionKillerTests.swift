import Foundation
import GhosthubTmux
import GhosthubUI
import Testing
@testable import GhosthubApp

@Suite("tmux session termination")
struct TmuxSessionKillerTests {
    @Test("matching identity is killed while a replacement survives")
    func realTmuxIdentityBoundary() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else {
            return
        }
        let socketName = ProcessInfo.processInfo.environment[
            "GHOSTHUB_TEST_TMUX_RUN_ID"
        ].map { "ghosthub-kill-\($0)" }
            ?? "ghosthub-kill-\(UUID().uuidString.lowercased())"
        let sessionName = "same-name"
        defer {
            _ = TmuxBinaryResolver.runProcess(
                executable: tmuxPath,
                arguments: ["-L", socketName, "kill-server"],
                timeout: 5
            )
        }
        let anchor = TmuxBinaryResolver.runProcess(
            executable: tmuxPath,
            arguments: [
                "-f", "/dev/null", "-L", socketName,
                "new-session", "-d", "-s", "anchor",
            ],
            timeout: 5
        )
        #expect(anchor.status == 0)
        let initial = TmuxBinaryResolver.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "new-session", "-d", "-s", sessionName,
            ],
            timeout: 5
        )
        #expect(initial.status == 0)

        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success(tmuxPath) }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: sessionName,
            socketName: socketName
        )
        let originalIdentity = try await killer.sessionIdentity(
            selection,
            on: .local
        )

        try await killer.kill(
            selection,
            expectedIdentity: originalIdentity,
            on: .local
        )
        let absent = TmuxBinaryResolver.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "has-session", "-t", "=\(sessionName):",
            ],
            timeout: 5
        )
        #expect(absent.status != 0)

        let replacement = TmuxBinaryResolver.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "new-session", "-d", "-s", sessionName,
            ],
            timeout: 5
        )
        #expect(replacement.status == 0)
        await #expect {
            try await killer.kill(
                selection,
                expectedIdentity: originalIdentity,
                on: .local
            )
        } throws: { error in
            error as? TmuxSessionKillError == .sessionChanged(
                host: "localhost",
                session: sessionName
            )
        }
        let replacementStillRunning = TmuxBinaryResolver.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "has-session", "-t", "=\(sessionName):",
            ],
            timeout: 5
        )
        #expect(replacementStillRunning.status == 0)
    }

    @Test("kill checks the exact session identity on its selected socket")
    func exactSocketIdentity() async throws {
        let recordedCommand = LockedValue<String?>(nil)
        let killer = TmuxSessionKiller(
            pathResolver: { _ in
                .success("/opt/homebrew/bin/tmux")
            },
            runner: { _, command in
                recordedCommand.store(command)
                return (0, "")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "review's session",
            socketName: "kwt-pr-0123456789abcdef"
        )

        try await killer.kill(
            selection,
            expectedIdentity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1785182057"
            ),
            on: .local
        )

        let command = try #require(recordedCommand.load())
        #expect(command.contains("'if-shell' '-F'"))
        #expect(command.contains("'kwt-pr-0123456789abcdef'"))
        #expect(command.contains("'=review'\\''s session:'"))
        #expect(
            command.contains(
                "#{==:#{pid},31415}"
            )
        )
        #expect(
            command.contains(
                "#{==:#{session_id},$42}"
            )
        )
        #expect(
            command.contains(
                "#{==:#{session_created},1785182057}"
            )
        )
        #expect(
            command.contains("GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH")
        )
    }

    @Test("Windows identity and kill use PowerShell and psmux quoting")
    func windowsIdentityAndKillCommands() async throws {
        let commands = LockedValue<[String]>([])
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let killer = TmuxSessionKiller(
            pathResolver: { _ in
                .success(#"C:\Program Files\psmux\tmux.exe"#)
            },
            runner: { _, command in
                commands.withLock { $0.append(command) }
                if command.contains(
                    powerShellEncodedArgument("display-message")
                ) {
                    return (
                        0,
                        "GHOSTHUB_TMUX_SESSION_IDENTITY\t"
                            + "31415\t$42\t1785182057\r\n"
                    )
                }
                return (0, "")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "review's session",
            socketName: "kwt-pr-windows"
        )

        let identity = try await killer.sessionIdentity(
            selection,
            on: .ssh(host)
        )
        try await killer.kill(
            selection,
            expectedIdentity: identity,
            on: .ssh(host)
        )

        let recorded = try #require(
            commands.load().count == 3 ? commands.load() : nil
        )
        #expect(recorded.allSatisfy { $0.contains(
            "[Console]::OutputEncoding"
        ) })
        #expect(recorded[0].contains(
            "& "
                + [
                    #"C:\Program Files\psmux\tmux.exe"#,
                    "-L",
                    "kwt-pr-windows",
                    "has-session",
                    "-t",
                    "=review's session:",
                ]
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
        ))
        #expect(recorded[0].contains(" 2>&1"))
        #expect(recorded[1].contains(
            "& "
                + [
                    #"C:\Program Files\psmux\tmux.exe"#,
                    "-L",
                    "kwt-pr-windows",
                    "display-message",
                    "-p",
                    "-t",
                    "=review's session:",
                ]
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
        ))
        #expect(recorded[2].contains(
            ["if-shell", "-F"]
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
        ))
        #expect(recorded[2].contains(
            ["-t", "=review's session:"]
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
        ))
        #expect(recorded[2].contains(
            powerShellEncodedArgument("kill-session -t $42")
        ))
        #expect(!recorded.joined().contains("review's session"))
    }

    @Test("kill failure preserves host, session, and status")
    func commandFailure() async {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "builder",
            port: 2222
        )
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in (1, "") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "worker"
        )

        await #expect {
            try await killer.kill(
                selection,
                expectedIdentity: TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1785182057"
                ),
                on: .ssh(host)
            )
        } throws: { error in
            error as? TmuxSessionKillError == .commandFailed(
                host: "wesm@builder:2222",
                session: "worker",
                status: 1
            )
        }
    }

    @Test("identity mismatch preserves the replacement session")
    func identityMismatch() async {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (0, "GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH\n")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "worker"
        )

        await #expect {
            try await killer.kill(
                selection,
                expectedIdentity: TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1785182057"
                ),
                on: .local
            )
        } throws: { error in
            error as? TmuxSessionKillError == .sessionChanged(
                host: "localhost",
                session: "worker"
            )
        }
    }

    @Test("session identity is read from the selected socket")
    func readsIdentity() async throws {
        let recordedCommands = LockedValue<[String]>([])
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, command in
                recordedCommands.withLock { $0.append(command) }
                guard command.contains("display-message") else {
                    return (0, "")
                }
                return (
                    0,
                    "Welcome to the host\n"
                        + "GHOSTHUB_TMUX_SESSION_IDENTITY\t"
                        + "31415\t$42\t1785182057\n"
                        + "shell startup output\n"
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "worker",
            socketName: "protected"
        )

        let identity = try await killer.sessionIdentity(
            selection,
            on: .local
        )

        #expect(identity == TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$42",
            createdAt: "1785182057"
        ))
        let commands = try #require(
            recordedCommands.load().count == 2
                ? recordedCommands.load()
                : nil
        )
        #expect(commands[0].contains(
            "'/usr/bin/tmux' '-L' 'protected' 'has-session'"
                + " '-t' '=worker:'"
        ))
        #expect(commands[0].hasSuffix(" 2>&1"))
        #expect(commands[1].contains(
            "'/usr/bin/tmux' '-L' 'protected' 'display-message'"
                + " '-p' '-t' '=worker:'"
        ))
    }

    @Test("identity command failure is not reported as session absence")
    func identityCommandFailure() async {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (1, "error connecting to socket (Permission denied)")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "worker"
        )

        await #expect {
            try await killer.sessionIdentity(selection, on: .local)
        } throws: { error in
            error as? TmuxSessionKillError == .identityCommandFailed(
                host: "localhost",
                session: "worker",
                status: 1
            )
        }
    }

    @Test("malformed identity is not reported as session absence")
    func malformedIdentity() async {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in (0, "unexpected output") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "worker"
        )

        await #expect {
            try await killer.sessionIdentity(selection, on: .local)
        } throws: { error in
            error as? TmuxSessionKillError == .identityUnavailable(
                host: "localhost",
                session: "worker"
            )
        }
    }

    @Test("explicit absence is reported as session not running")
    func explicitAbsence() async {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (1, "can't find session: worker\n")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "worker"
        )

        await #expect {
            try await killer.sessionIdentity(selection, on: .local)
        } throws: { error in
            error as? TmuxSessionKillError == .sessionNotRunning(
                host: "localhost",
                session: "worker"
            )
        }
    }

    @Test(
        "only missing session or server diagnostics confirm absence",
        arguments: [
            ("can't find session: worker", true),
            ("no server running on /tmp/tmux-501/default", true),
            ("error connecting to socket (Permission denied)", false),
            ("", false),
        ]
    )
    func confirmedAbsenceDiagnostics(
        output: String,
        expected: Bool
    ) {
        #expect(
            TmuxSessionKiller.isConfirmedAbsence(output) == expected
        )
    }
}
