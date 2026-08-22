import GhosthubTransport
import Foundation
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import Testing
@testable import GhosthubApp

@Suite("tmux session termination")
struct TmuxSessionKillerTests {
    @Test("reviewed route is retained through conditional kill")
    func reviewedRouteBindsKill() async throws {
        let acquisitions = LockedValue(0)
        let releases = LockedValue(0)
        let commands = LockedValue<[String]>([])
        let host = SSHHostInfo(
            user: nil,
            hostname: "builder.example.test",
            port: nil
        )
        let commandLease = KwtSSHCommandLease { _ in
            acquisitions.withLock { $0 += 1 }
            return KwtSSHConnection(
                arguments: ["-S", "/tmp/reviewed.sock"],
                routeIdentity: "reviewed-route",
                generation: 7,
                release: { releases.withLock { $0 += 1 } }
            )
        }
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, command in
                commands.withLock { $0.append(command) }
                return (0, "")
            },
            commandLease: commandLease
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "reviewed"
        )

        try await killer.killReviewed(
            selection,
            expectedIdentity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1785182057"
            ),
            expectedRouteIdentity: "reviewed-route",
            on: .ssh(host)
        )

        #expect(acquisitions.load() == 1)
        #expect(releases.load() == 1)
        #expect(commands.load().count == 1)
    }

    @Test("changed route blocks conditional kill")
    func changedRouteBlocksKill() async {
        let releases = LockedValue(0)
        let commands = LockedValue<[String]>([])
        let host = SSHHostInfo(
            user: nil,
            hostname: "replacement.example.test",
            port: nil
        )
        let commandLease = KwtSSHCommandLease { _ in
            KwtSSHConnection(
                arguments: ["-S", "/tmp/replacement.sock"],
                routeIdentity: "replacement-route",
                generation: 8,
                release: { releases.withLock { $0 += 1 } }
            )
        }
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, command in
                commands.withLock { $0.append(command) }
                return (0, "")
            },
            commandLease: commandLease
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "reviewed"
        )

        await #expect {
            try await killer.killReviewed(
                selection,
                expectedIdentity: TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$42",
                    createdAt: "1785182057"
                ),
                expectedRouteIdentity: "reviewed-route",
                on: .ssh(host)
            )
        } throws: { error in
            error as? TmuxSessionKillError == .hostChanged(
                session: selection.name
            )
        }
        #expect(releases.load() == 1)
        #expect(commands.load().isEmpty)
    }

    @Test("a dead pooled control socket invalidates its lease")
    func deadPooledSocketInvalidatesLease() async {
        let invalidations = LockedValue(0)
        let releases = LockedValue(0)
        let host = SSHHostInfo(
            user: nil,
            hostname: "builder.example.test",
            port: nil
        )
        let commandLease = KwtSSHCommandLease { _ in
            KwtSSHConnection(
                arguments: ["-S", "/tmp/dead.sock"],
                routeIdentity: "reviewed-route",
                generation: 9,
                release: { releases.withLock { $0 += 1 } },
                invalidate: { invalidations.withLock { $0 += 1 } }
            )
        }
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            outputRunner: { _, _ in
                AccountCommandOutput(
                    status: 255,
                    stdout: "",
                    stderr:
                    "Control socket connect(/tmp/dead.sock): No such file or directory"
                )
            },
            commandLease: commandLease
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "reviewed"
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
                host: host.displayName,
                session: selection.name,
                status: 255
            )
        }
        #expect(invalidations.load() == 1)
        #expect(releases.load() == 1)
    }

    @Test(
        "a dead control socket during identity review invalidates its lease",
        arguments: [1, 2]
    )
    func deadSocketDuringIdentityReview(failingCommand: Int) async {
        let commands = LockedValue(0)
        let invalidations = LockedValue(0)
        let releases = LockedValue(0)
        let host = SSHHostInfo(
            user: nil,
            hostname: "builder.example.test",
            port: nil
        )
        let commandLease = KwtSSHCommandLease { _ in
            KwtSSHConnection(
                arguments: ["-S", "/tmp/dead.sock"],
                routeIdentity: "reviewed-route",
                generation: 9,
                release: { releases.withLock { $0 += 1 } },
                invalidate: { invalidations.withLock { $0 += 1 } }
            )
        }
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            outputRunner: { _, command in
                commands.withLock { $0 += 1 }
                let commandNumber = commands.load()
                if commandNumber == failingCommand {
                    return AccountCommandOutput(
                        status: 255,
                        stdout: "",
                        stderr:
                        "Control socket connect(/tmp/dead.sock): No such file or directory"
                    )
                }
                let stdout = command.contains("display-message")
                    ? "GHOSTHUB_TMUX_SESSION_IDENTITY\t31415\t$42\t1785182057\n"
                    : ""
                return AccountCommandOutput(
                    status: 0,
                    stdout: stdout,
                    stderr: ""
                )
            },
            commandLease: commandLease
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "reviewed"
        )

        await #expect {
            try await killer.sessionIdentity(selection, on: .ssh(host))
        } throws: { error in
            error as? TmuxSessionKillError == .identityCommandFailed(
                host: host.displayName,
                session: selection.name,
                status: 255
            )
        }
        #expect(invalidations.load() == 1)
        #expect(releases.load() == 1)
    }

    @Test("a dead control socket during tmux resolution invalidates its lease")
    func deadSocketDuringTmuxResolution() async {
        let invalidations = LockedValue(0)
        let releases = LockedValue(0)
        let host = SSHHostInfo(
            user: nil,
            hostname: "builder.example.test",
            port: nil
        )
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output:
            "Control socket connect(/tmp/dead.sock): No such file or directory"
        )
        let commandLease = KwtSSHCommandLease { _ in
            KwtSSHConnection(
                arguments: ["-S", "/tmp/dead.sock"],
                routeIdentity: "reviewed-route",
                generation: 9,
                release: { releases.withLock { $0 += 1 } },
                invalidate: { invalidations.withLock { $0 += 1 } }
            )
        }
        let killer = TmuxSessionKiller(
            pathResolver: { _ in
                .failure(.sshConnectionFailed(
                    host: host.displayName,
                    classification: classification
                ))
            },
            runner: { _, _ in (0, "") },
            commandLease: commandLease
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "reviewed"
        )

        await #expect {
            try await killer.sessionIdentity(selection, on: .ssh(host))
        } throws: { error in
            error as? TmuxBinaryError == .sshConnectionFailed(
                host: host.displayName,
                classification: classification
            )
        }
        #expect(invalidations.load() == 1)
        #expect(releases.load() == 1)
    }

    @Test("matching identity is killed while a replacement survives")
    func realTmuxIdentityBoundary() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else {
            return
        }
        let server = try TestTmuxServer(
            tmuxPath: tmuxPath,
            socket: .runOwned(purpose: "kill")
        )
        defer { server.stop() }
        let socketName = server.socketName
        let sessionName = "same-name"
        try server.createSession("anchor")
        try server.createSession(sessionName)

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
        let absent = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "has-session", "-t", "=\(sessionName):",
            ],
            timeout: 5
        )
        #expect(absent.status != 0)

        try server.createSession(sessionName)
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
        let replacementStillRunning = AccountCommandRunner.runProcess(
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
        #expect(command.contains("GHOSTHUB_TMUX_DIAGNOSTIC"))
        #expect(command.contains(" 2>&1"))
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
        #expect(recorded[2].contains(" 2>&1"))
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

    @Test("kill reports explicit session absence")
    func killReportsExplicitAbsence() async {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (
                    1,
                    TmuxSessionKiller.diagnosticMarker
                        + "can't find session: worker\n"
                )
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
            error as? TmuxSessionKillError == .sessionNotRunning(
                host: "localhost",
                session: "worker"
            )
        }
    }

    @Test("identity mismatch preserves the replacement session")
    func identityMismatch() async {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (
                    0,
                    TmuxSessionKiller.diagnosticMarker
                        + "GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH\n"
                )
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

    @Test(
        "unframed identity mismatch output does not override a successful kill",
        arguments: [
            "GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH\n",
            TmuxSessionKiller.diagnosticMarker
                + "prefix GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH suffix\n",
        ]
    )
    func ignoresUnframedIdentityMismatch(_ output: String) async throws {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in (0, output) }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "worker"
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
        #expect(commands[0].contains("GHOSTHUB_TMUX_DIAGNOSTIC"))
        #expect(commands[0].contains(" 2>&1"))
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

    @Test("kill ignores unframed shell absence diagnostics")
    func killIgnoresUnframedShellAbsence() async {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (
                    1,
                    "can't find session: shell-helper\n"
                        + "error connecting to /tmp/tmux-501/kwt "
                        + "(Permission denied)"
                )
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
            error as? TmuxSessionKillError == .commandFailed(
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
                (
                    1,
                    TmuxSessionKiller.diagnosticMarker
                        + "can't find session: worker\n"
                )
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
        "kill treats missing socket diagnostics as session absence",
        arguments: [
            "error connecting to /tmp/tmux-501/kwt (No such file or directory)",
            "failed to connect to server: No such file or directory",
        ]
    )
    func missingSocketDuringKill(output: String) async {
        let killer = TmuxSessionKiller(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (1, TmuxSessionKiller.diagnosticMarker + output)
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "worker",
            socketName: "kwt"
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
            error as? TmuxSessionKillError == .sessionNotRunning(
                host: "localhost",
                session: "worker"
            )
        }
    }

    @Test(
        "only missing session or server diagnostics confirm absence",
        arguments: [
            (
                "GHOSTHUB_TMUX_DIAGNOSTIC\tcan't find session: worker",
                true
            ),
            (
                "GHOSTHUB_TMUX_DIAGNOSTIC\t"
                    + "no server running on /tmp/tmux-501/default",
                true
            ),
            (
                "GHOSTHUB_TMUX_DIAGNOSTIC\t"
                    + "error connecting to /tmp/tmux-501/kwt "
                    + "(No such file or directory)",
                true
            ),
            (
                "GHOSTHUB_TMUX_DIAGNOSTIC\t"
                    + "failed to connect to server: No such file or directory",
                true
            ),
            ("error connecting to socket (Permission denied)", false),
            (
                "shell: error connecting to startup helper\n"
                    + "error connecting to /tmp/tmux-501/kwt "
                    + "(Permission denied)\n"
                    + "shell: (No such file or directory)",
                false
            ),
            (
                "can't find session: shell-helper\n"
                    + "error connecting to /tmp/tmux-501/kwt "
                    + "(Permission denied)",
                false
            ),
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
