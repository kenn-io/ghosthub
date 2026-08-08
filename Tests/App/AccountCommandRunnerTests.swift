import Foundation
import GhosthubTransport
import Synchronization
import Testing
@testable import GhosthubApp

private struct CapturedAccountCommand: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var timeout: TimeInterval
    var environmentOverrides: [String: String]
}

@Suite("Account command runner")
struct AccountCommandRunnerTests {
    @Test("local commands run through the configured account login shell")
    func localLoginShell() {
        let captured = Mutex<CapturedAccountCommand?>(nil)
        let runner = AccountCommandRunner(
            processRunner: { executable, arguments, timeout, overrides in
                captured.withLock { value in
                    value = CapturedAccountCommand(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        environmentOverrides: overrides
                    )
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "ready\n",
                    stderr: "note\n"
                )
            },
            loginShellProvider: { "/bin/account-shell" }
        )

        let result = runner.runLocalLoginShell(
            command: "printf ready",
            timeout: 4
        )

        #expect(result == AccountCommandOutput(
            status: 0,
            stdout: "ready\n",
            stderr: "note\n"
        ))
        #expect(captured.withLock { $0?.executable } == "/bin/account-shell")
        #expect(captured.withLock { $0?.arguments.first } == "-lc")
        #expect(captured.withLock { $0?.arguments.last }?.contains("printf ready") == true)
        #expect(captured.withLock { $0?.timeout } == 4)
    }

    @Test("remote commands keep SSH output streams separate and use supplied routing")
    func remoteLoginShell() {
        let captured = Mutex<CapturedAccountCommand?>(nil)
        let runner = AccountCommandRunner(
            processRunner: { executable, arguments, timeout, overrides in
                captured.withLock { value in
                    value = CapturedAccountCommand(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        environmentOverrides: overrides
                    )
                }
                return AccountCommandOutput(
                    status: 17,
                    stdout: "protocol\n",
                    stderr: "diagnostic\n"
                )
            },
            loginShellProvider: { "/bin/account-shell" }
        )
        let host = SSHHostInfo(
            user: "dev",
            hostname: "build.example",
            port: 2222
        )

        let result = runner.runRemoteLoginShell(
            host: host,
            connectionArguments: ["-F", "/tmp/ssh config"],
            command: "printf remote",
            timeout: 6
        )

        #expect(result.status == 17)
        #expect(result.stdout == "protocol\n")
        #expect(result.stderr == "diagnostic\n")
        let command = captured.withLock { $0?.arguments.last } ?? ""
        #expect(command.contains("/usr/bin/ssh"))
        #expect(command.contains("BatchMode=yes"))
        #expect(command.contains("/tmp/ssh config"))
        #expect(command.contains("2222"))
        #expect(command.contains("dev@build.example"))
        #expect(command.contains("${SHELL:-/bin/sh}"))
    }

    @Test("subprocesses do not inherit enclosing multiplexer clients")
    func sanitizedEnvironment() {
        let sanitized = AccountCommandRunner.sanitizedProcessEnvironment([
            "PATH": "/usr/bin",
            "TMUX": "/tmp/tmux-501/default,1,0",
            "TMUX_PANE": "%3",
            "HERDR_ENV": "production",
            "HERDR_SESSION": "review",
            "HERDR_SOCKET_PATH": "/tmp/herdr.sock",
            "HERDR_CLIENT_SOCKET_PATH": "/tmp/herdr-client.sock",
            "HERDR_PANE_ID": "pane-1",
            "HERDR_TAB_ID": "tab-1",
            "HERDR_WORKSPACE_ID": "workspace-1",
            "HERDR_BIN_PATH": "/usr/bin/herdr",
            "HERDR_ACTIVE_WORKSPACE_ID": "workspace-1",
            "HERDR_ACTIVE_TAB_ID": "tab-1",
            "HERDR_ACTIVE_PANE_ID": "pane-1",
            "HERDR_ACTIVE_PANE_CWD": "/tmp/review",
        ])

        #expect(sanitized == ["PATH": "/usr/bin"])
    }
}
