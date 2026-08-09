import GhosthubTransport
import Darwin
import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("TmuxBinaryResolver")
struct TmuxBinaryResolverTests {
    @Test("parses the resolved path from shell output")
    func parsesPath() throws {
        let resolver = TmuxBinaryResolver(processRunner: { _, command in
            #expect(command.contains("command -v tmux"))
            #expect(command.contains("-V"))
            #expect(command.hasPrefix("ghosthub_tmux_path="))
            return (
                status: 0,
                stdout: "/opt/homebrew/bin/tmux\ntmux 3.2a\n"
            )
        })
        #expect(try resolver.resolveTmuxPath().get() == "/opt/homebrew/bin/tmux")
    }

    @Test("resolution preserves the probed tmux version")
    func preservesVersion() throws {
        let resolver = TmuxBinaryResolver(processRunner: { _, _ in
            (
                status: 0,
                stdout: "/opt/homebrew/bin/tmux\ntmux 3.4a\n"
            )
        })

        #expect(
            try resolver.resolveTmuxBinary().get()
                == ResolvedTmuxBinary(
                    path: "/opt/homebrew/bin/tmux",
                    version: "tmux 3.4a"
                )
        )
    }

    @Test("account shell initializes PATH without interpreting probe syntax")
    func supportsNonPOSIXLoginShells() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-login-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let tmux = directory.appendingPathComponent("tmux")
        try "#!/bin/sh\nprintf 'tmux 3.6a\\n'\n".write(
            to: tmux, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tmux.path
        )

        let shell = directory.appendingPathComponent("account-shell")
        try """
        #!/bin/sh
        case "$2" in
          "exec /bin/sh -c "*) ;;
          *) exit 97 ;;
        esac
        PATH=\(shellQuotedCommandArgument(directory.path)):/usr/bin:/bin
        export PATH
        exec /bin/sh -c "$2"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )

        let resolver = TmuxBinaryResolver(
            loginShellProvider: { shell.path }
        )

        #expect(resolver.resolveTmuxPath() == .success(tmux.path))
    }

    @Test("configured account shell launches a quoted executable")
    func configuredAccountShellLaunchesExecutable() throws {
        let password = try #require(getpwuid(getuid()))
        let shell = String(cString: password.pointee.pw_shell)
        let argument = #"exec /bin/sh -c "marker=$(printf '%s' 'ready'); printf '%s\n' "$marker"""#

        // A hang backstop only: real login shells can take seconds to start
        // under parallel suite load, so a tight timeout is a flake.
        let result = AccountCommandRunner.runProcessInLoginShell(
            executable: "/usr/bin/printf",
            arguments: ["%s", argument],
            timeout: 15,
            accountShell: shell
        )

        #expect(result.status == 0)
        #expect(result.stdout == argument)
    }

    @Test("login-shell process preserves explicit environment overrides")
    func loginShellProcessPreservesEnvironmentOverrides() throws {
        let password = try #require(getpwuid(getuid()))
        let shell = String(cString: password.pointee.pw_shell)
        let result = AccountCommandRunner.runProcessInLoginShell(
            executable: "/usr/bin/printenv",
            arguments: ["GHOSTHUB_TEST_OVERRIDE"],
            timeout: 15,
            accountShell: shell,
            environmentOverrides: [
                "GHOSTHUB_TEST_OVERRIDE": "available-through-login-shell",
            ]
        )

        #expect(result.status == 0)
        #expect(result.stdout == "available-through-login-shell\n")
    }

    @Test("remote POSIX command runs under the configured account shell")
    func remotePOSIXCommandRunsUnderConfiguredAccountShell() throws {
        let password = try #require(getpwuid(getuid()))
        let shell = String(cString: password.pointee.pw_shell)
        let host = SSHHostInfo(
            user: nil,
            hostname: "remote.example",
            port: nil
        )
        let command = AccountCommandRunner.remoteLoginCommand(
            host: host,
            command:
            "marker=$(printf '%s' 'REMOTE_SHELL_READY'); "
                + "printf 'GHOSTHUB_%s\\n' \"$marker\""
        )

        // A hang backstop only: real login shells can take seconds to start
        // under parallel suite load, so a tight timeout is a flake.
        let result = AccountCommandRunner.runProcess(
            executable: shell,
            arguments: ["-c", command],
            timeout: 15
        )

        #expect(result.status == 0)
        #expect(result.stdout == "GHOSTHUB_REMOTE_SHELL_READY\n")
    }

    @Test("process output keeps diagnostics separate from protocol output")
    func separatesStandardError() {
        let result = AccountCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf 'GHOSTHUB_SSH_REACHED\\n'; "
                    + "printf 'diagnostic\\n' >&2",
            ],
            timeout: 5
        )

        #expect(result.status == 0)
        #expect(result.stdout == "GHOSTHUB_SSH_REACHED\n")
        #expect(result.stderr == "diagnostic\n")
    }

    @Test("rejects unsupported tmux versions")
    func rejectsOldVersion() {
        let resolver = TmuxBinaryResolver(processRunner: { _, _ in
            (status: 0, stdout: "/usr/bin/tmux\ntmux 3.1c\n")
        })
        #expect(
            resolver.resolveTmuxPath()
                == .failure(.unsupportedVersion(
                    found: "tmux 3.1c",
                    minimum: "3.2"
                ))
        )
    }

    @Test("remote resolution uses its supplied SSH snapshot")
    func resolvesRemotePathWithSuppliedSSHArguments() throws {
        let host = SSHHostInfo(user: "wesm", hostname: "build-box", port: 2222)
        let sshArguments = [
            "-F", "/dev/null",
            "-o", "SetEnv=GHOSTHUB_TMUX_PROFILE=fleet",
        ]
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { received, receivedArguments, command in
                #expect(received == host)
                #expect(receivedArguments == sshArguments)
                #expect(command.contains("command -v tmux"))
                return (
                    status: 0,
                    stdout: "welcome\n/usr/local/bin/tmux\ntmux 3.6a\n",
                    stderr: ""
                )
            }
        )

        #expect(
            try resolver.resolveTmuxBinary(
                on: host,
                sshConnectionArguments: sshArguments
            ).get()
                == ResolvedTmuxBinary(
                    path: "/usr/local/bin/tmux",
                    version: "tmux 3.6a"
                )
        )
    }

    @Test("SSH stderr is preserved for native recovery classification")
    func reportsRemoteSSHFailure() {
        let host = SSHHostInfo(
            user: "wesm", hostname: "untrusted-host", port: nil
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { _, _, _ in
                (
                    status: 255,
                    stdout: "",
                    stderr: "Permission denied (publickey,password)."
                )
            }
        )
        let expected = TmuxBinaryError.sshConnectionFailed(
            host: host.displayName,
            classification: SSHConnectionFailure.classify(
                status: 255,
                output: "Permission denied (publickey,password)."
            )
        )

        #expect(resolver.resolveTmuxPath(on: host) == .failure(expected))
        #expect(resolver.discoverSessions(on: host) == .failure(expected))
    }

    @Test("protected POSIX probe uses exact socket and session targets")
    func probesProtectedPOSIXSession() throws {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "build-box",
            port: nil
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { _, _, command in
                #expect(command.contains("-L"))
                #expect(command.contains("kwt-pr-0123456789abcdef"))
                #expect(command.contains("has-session"))
                #expect(command.contains("=pr-32"))
                return (
                    status: 0,
                    stdout: "/usr/bin/tmux\ntmux 3.6\n"
                        + "GHOSTHUB_TMUX_SESSION_PRESENT\n",
                    stderr: ""
                )
            }
        )

        #expect(try resolver.sessionExists(
            name: "pr-32",
            socketName: "kwt-pr-0123456789abcdef",
            on: host
        ).get())
    }

    @Test("exact probe recognizes an absent session")
    func probesAbsentSession() throws {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "build-box",
            port: nil
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { _, _, _ in
                (
                    status: 0,
                    stdout: "/usr/bin/tmux\ntmux 3.6\n"
                        + "GHOSTHUB_TMUX_SESSION_ABSENT\n",
                    stderr: ""
                )
            }
        )

        #expect(try !resolver.sessionExists(
            name: "pr-32",
            socketName: nil,
            on: host
        ).get())
    }

    @Test("exact probe rejects an unsupported tmux version")
    func exactProbeRejectsOldVersion() {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "build-box",
            port: nil
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { _, _, _ in
                (
                    status: 0,
                    stdout: "/usr/bin/tmux\ntmux 3.1c\n"
                        + "GHOSTHUB_TMUX_SESSION_PRESENT\n",
                    stderr: ""
                )
            }
        )

        #expect(resolver.sessionExists(
            name: "pr-32",
            socketName: "kwt-pr-0123456789abcdef",
            on: host
        ) == .failure(.unsupportedVersion(
            found: "tmux 3.1c",
            minimum: "3.2"
        )))
    }

    @Test("exact probe does not treat generic tmux failure as absence")
    func exactProbePreservesGenericFailure() {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "build-box",
            port: nil
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { _, _, _ in
                (
                    status: 1,
                    stdout: "/usr/bin/tmux\ntmux 3.6\n",
                    stderr: "error connecting to /tmp/tmux: Permission denied"
                )
            }
        )

        #expect(resolver.sessionExists(
            name: "pr-32",
            socketName: "kwt-pr-0123456789abcdef",
            on: host
        ) == .failure(.shellFailed(status: 1)))
    }

    @Test("protected Windows probe uses exact socket and session targets")
    func probesProtectedWindowsSession() throws {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { _, _, command in
                for argument in [
                    "-L",
                    "kwt-pr-0123456789abcdef",
                    "has-session",
                    "-t",
                    "=pr-32",
                ] {
                    #expect(command.contains(
                        Data(argument.utf8).base64EncodedString()
                    ))
                }
                #expect(!command.contains("kwt-pr-0123456789abcdef"))
                #expect(!command.contains("=pr-32"))
                return (
                    status: 0,
                    stdout: "C:\\Tools\\tmux.exe\r\ntmux 3.4\r\n"
                        + "GHOSTHUB_TMUX_SESSION_PRESENT\r\n",
                    stderr: ""
                )
            }
        )

        #expect(try resolver.sessionExists(
            name: "pr-32",
            socketName: "kwt-pr-0123456789abcdef",
            on: host
        ).get())
    }

    @Test("Windows resolution discovers the psmux tmux alias")
    func resolvesWindowsPsmuxPath() throws {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: 2222,
            platform: .windows
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { received, _, command in
                #expect(received == host)
                #expect(command.contains("Get-Command tmux.exe"))
                #expect(command.contains("[Console]::OutputEncoding"))
                #expect(!command.contains("command -v"))
                return (
                    status: 0,
                    stdout:
                    #"C:\Users\wesm\scoop\apps\psmux\current\tmux.exe"#
                        + "\ntmux 3.3.7\n",
                    stderr: ""
                )
            }
        )

        #expect(
            try resolver.resolveTmuxPath(on: host).get()
                == #"C:\Users\wesm\scoop\apps\psmux\current\tmux.exe"#
        )
    }

    @Test("Windows remote commands bypass POSIX login shells")
    func encodesWindowsRemoteCommand() throws {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let command = "Write-Output 'windows-ready'"

        let remoteCommand = AccountCommandRunner.remoteLoginCommand(
            host: host,
            command: command
        )

        #expect(remoteCommand.hasPrefix(
            "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "
        ))
        #expect(!remoteCommand.contains("${SHELL"))
        #expect(!remoteCommand.contains("/bin/sh"))
        let encoded = try #require(remoteCommand.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        #expect(String(data: data, encoding: .utf16LittleEndian) == command)
    }

    @Test("discovers every local tmux session without control-mode attachment")
    func discoversLocalSessions() throws {
        let resolver = TmuxBinaryResolver(processRunner: { _, command in
            #expect(command.contains("list-sessions"))
            #expect(command.contains("#{session_name}"))
            #expect(!command.contains("-CC"))
            #expect(!command.contains("; status="))
            #expect(command.hasPrefix("ghosthub_tmux_path="))
            #expect(command.contains("ghosthub_tmux_status"))
            return (
                status: 0,
                stdout: """
                /opt/homebrew/bin/tmux
                tmux 3.7b
                GHOSTHUB_TMUX_SESSION\t2\t101\t$1\t1783344091\t\tdocbank
                GHOSTHUB_TMUX_SESSION\t4\t101\t$2\t1783344092\towner-token\tGhosthub\twork

                """
            )
        })

        #expect(
            try resolver.discoverSessions().get() == [
                DiscoveredTmuxSession(
                    name: "docbank", windowCount: 2,
                    serverPID: "101",
                    sessionID: "$1", createdAt: "1783344091", managed: false
                ),
                DiscoveredTmuxSession(
                    name: "Ghosthub\twork", windowCount: 4,
                    serverPID: "101",
                    sessionID: "$2", createdAt: "1783344092", managed: true
                ),
            ]
        )
    }

    @Test("real zsh login shell discovers the current tmux server")
    func realZshLoginShellDiscoversCurrentServer() throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_LIVE_INTEGRATION_TESTS"
        ] == "1" else { return }
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            return
        }
        let expected = AccountCommandRunner.runLoginShell(
            shell: "/bin/zsh",
            command: "tmux list-sessions -F '#{session_name}' 2>/dev/null",
            timeout: 5
        )
        guard expected.status == 0 else { return }

        let resolver = TmuxBinaryResolver(
            loginShellProvider: { "/bin/zsh" }
        )
        let discovered = try resolver.discoverSessions().get()
        let expectedNames = Set(
            expected.stdout.split(whereSeparator: \.isNewline).map(String.init)
        )

        #expect(Set(discovered.map(\.name)) == expectedNames)
    }

    @Test("remote discovery uses the configured SSH host")
    func discoversRemoteSessions() throws {
        let host = SSHHostInfo(
            user: "wesm", hostname: "build-box", port: 2222
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { received, _, command in
                #expect(received == host)
                #expect(command.contains("list-sessions"))
                return (
                    status: 0,
                    stdout: """
                    /usr/local/bin/tmux
                    tmux 3.6
                    GHOSTHUB_TMUX_SESSION\t3\t202\t$7\t99\t\tremote-work

                    """,

                    stderr: ""
                )
            }
        )

        #expect(
            try resolver.discoverSessions(on: host).get()
                == [DiscoveredTmuxSession(
                    name: "remote-work", windowCount: 3,
                    serverPID: "202",
                    sessionID: "$7", createdAt: "99", managed: false
                )]
        )
    }

    @Test("Windows discovery uses psmux formatted session output")
    func discoversWindowsPsmuxSessions() throws {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { received, _, command in
                #expect(received == host)
                #expect(command.contains("Get-Command tmux.exe"))
                #expect(command.contains("'list-sessions' '-F'"))
                #expect(!command.contains("#{session_name}"))
                #expect(command.contains(
                    "[System.Convert]::FromBase64String"
                ))
                return (
                    status: 0,
                    stdout: "C:\\Tools\\psmux\\tmux.exe\r\n"
                        + "tmux 3.6.7\r\n"
                        + "GHOSTHUB_TMUX_SESSION\t2\t202\t$7"
                        + "\t1783344091\t\twindows-work\r\n",
                    stderr: ""
                )
            }
        )

        #expect(
            try resolver.discoverSessions(on: host).get()
                == [DiscoveredTmuxSession(
                    name: "windows-work",
                    windowCount: 2,
                    serverPID: "202",
                    sessionID: "$7",
                    createdAt: "1783344091",
                    managed: false
                )]
        )
    }

    @Test("a reachable tmux server with no sessions produces an empty inventory")
    func discoversEmptyServer() throws {
        let resolver = TmuxBinaryResolver(processRunner: { _, _ in
            (status: 0, stdout: "/usr/bin/tmux\ntmux 3.6a\n")
        })

        #expect(try resolver.discoverSessions().get().isEmpty)
    }

    @Test("a missing tmux socket confirms session absence")
    func missingSocketIsAbsence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-absence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let tmux = directory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        if [ "$1" = "-V" ]; then
          printf 'tmux 3.6a\n'
          exit 0
        fi
        printf 'error connecting to /tmp/tmux-501/default (No such file or directory)\n' >&2
        exit 1
        """.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )

        let host = SSHHostInfo(
            user: "wesm",
            hostname: "build-box",
            port: nil
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { _, _, command in
                let output = AccountCommandRunner.runProcess(
                    executable: "/bin/sh",
                    arguments: ["-c", command],
                    timeout: 5,
                    environmentOverrides: [
                        "PATH": "\(directory.path):/usr/bin:/bin",
                    ]
                )
                return (output.status, output.stdout, output.stderr)
            }
        )

        #expect(try resolver.discoverSessions(on: host).get().isEmpty)
        #expect(try !resolver.sessionExists(
            name: "pr-32",
            socketName: "kwt-pr-0123456789abcdef",
            on: host
        ).get())
    }

    @Test("a reachable default server error is not confirmed absence")
    func defaultServerErrorIsNotAbsence() {
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "build-box",
            port: nil
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { _, _, _ in
                (
                    status: 1,
                    stdout: "/usr/bin/tmux\ntmux 3.6a\n",
                    stderr: "error connecting to /tmp/tmux-501/default (Permission denied)\n"
                )
            }
        )

        #expect(
            resolver.discoverSessions(on: host)
                == .failure(.shellFailed(status: 1))
        )
    }

    @Test("default discovery preserves a generic tmux status one failure")
    func discoveryCommandPreservesGenericFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let tmux = directory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        if [ "$1" = "-V" ]; then
          printf 'tmux 3.6a\n'
          exit 0
        fi
        printf 'error connecting to tmux server (Permission denied)\n' >&2
        exit 1
        """.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )

        let shell = directory.appendingPathComponent("account-shell")
        try """
        #!/bin/sh
        PATH=\(shellQuotedCommandArgument(directory.path)):/usr/bin:/bin
        export PATH
        exec /bin/sh -c "$2"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: shell.path
        )

        let resolver = TmuxBinaryResolver(
            loginShellProvider: { shell.path }
        )

        #expect(
            resolver.discoverSessions()
                == .failure(.shellFailed(status: 1))
        )
    }

    @Test("nonzero exit maps to notFound")
    func notFound() {
        let resolver = TmuxBinaryResolver(processRunner: { _, _ in
            (status: 1, stdout: "")
        })
        guard case .failure(.notFound) = resolver.resolveTmuxPath() else {
            Issue.record("expected notFound")
            return
        }
    }

    @Test("real login shell resolves tmux on this machine")
    func realResolution() throws {
        let resolver = TmuxBinaryResolver()
        switch resolver.resolveTmuxPath() {
        case let .success(path):
            #expect(FileManager.default.isExecutableFile(atPath: path))
        case .failure:
            // Only acceptable if tmux genuinely isn't installed.
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/bin/sh")
            probe.arguments = ["-lc", "command -v tmux"]
            try probe.run()
            probe.waitUntilExit()
            #expect(probe.terminationStatus != 0, "tmux exists but resolver failed")
        }
    }

    @Test("a hanging login-shell probe is terminated at its deadline")
    func hangingProbeTimesOut() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("hanging-shell")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(
            to: shell, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let resolver = TmuxBinaryResolver(
            processTimeout: 0.05,
            loginShellProvider: { shell.path }
        )
        let started = Date()

        #expect(
            resolver.resolveTmuxPath()
                == .failure(.probeTimedOut(shell: shell.path))
        )
        // The failure above already establishes that the budget ended this.
        // The clock only has to rule out waiting on the ten-second sleep,
        // which a tighter bound cannot do reliably on a loaded machine.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("cancelling a login-shell probe terminates it promptly")
    func hangingProbeCancels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("hanging-shell")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(
            to: shell, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let processTimeout: TimeInterval = 5
        let resolver = TmuxBinaryResolver(
            processTimeout: processTimeout,
            loginShellProvider: { shell.path }
        )
        let task = Task.detached { resolver.resolveTmuxPath() }
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        task.cancel()

        #expect(
            await task.value
                == .failure(.probeCancelled(shell: shell.path))
        )
        // Cancellation has to beat the process budget rather than ride it out.
        #expect(Date().timeIntervalSince(started) < processTimeout)
    }

    @Test("a background descendant cannot hold probe stdout open")
    func backgroundDescendantTimesOutAndIsKilled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("background-shell")
        let childPIDFile = directory.appendingPathComponent("child-pid")
        try """
        #!/bin/sh
        /bin/sleep 10 &
        printf '%s' "$!" > \(childPIDFile.path)
        exit 1
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        // The probe kills the shell's process group on timeout, so the budget
        // must comfortably exceed process startup. At a fraction of a second a
        // loaded machine can reach the timeout before the shell has recorded
        // its child, leaving nothing to assert against.
        let processTimeout: TimeInterval = 2
        let resolver = TmuxBinaryResolver(
            processTimeout: processTimeout,
            loginShellProvider: { shell.path }
        )
        let started = Date()

        #expect(
            resolver.resolveTmuxPath()
                == .failure(.probeTimedOut(shell: shell.path))
        )
        // Well under the descendant's ten-second sleep: the probe must not
        // wait for it.
        #expect(Date().timeIntervalSince(started) < processTimeout + 3)
        let childPID = try #require(Self.recordedPID(at: childPIDFile))
        #expect(Self.waitForExit(of: childPID))
    }

    /// Reads a pid a subprocess published, tolerating the gap between the
    /// shell creating the file through redirection and writing the value.
    private static func recordedPID(
        at file: URL,
        timeout: TimeInterval = 5
    ) -> Int32? {
        poll(timeout: timeout) {
            guard let contents = try? String(
                contentsOf: file, encoding: .utf8
            ) else { return nil }
            return Int32(
                contents.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Signalling a process group does not reap its members synchronously.
    private static func waitForExit(
        of pid: Int32,
        timeout: TimeInterval = 5
    ) -> Bool {
        poll(timeout: timeout) { kill(pid, 0) != 0 ? true : nil } ?? false
    }

    private static func poll<Value>(
        timeout: TimeInterval,
        until produce: () -> Value?
    ) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = produce() {
                return value
            }
            usleep(20_000)
        } while Date() < deadline
        return produce()
    }

    @Test("noisy startup output is drained but remains memory bounded")
    func noisyProbeOutputIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("noisy-shell")
        try """
        #!/bin/sh
        /usr/bin/yes x | /usr/bin/head -c 1100000
        exit 0
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let resolver = TmuxBinaryResolver(
            processTimeout: 2,
            loginShellProvider: { shell.path }
        )

        #expect(
            resolver.resolveTmuxPath()
                == .failure(.probeOutputExceeded(shell: shell.path))
        )
    }

    @Test("continuously readable output cannot bypass the probe budget")
    func continuouslyReadableOutputIsInterrupted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("continuous-shell")
        try """
        #!/bin/sh
        /usr/bin/yes x &
        producer=$!
        (/bin/sleep 2; /bin/kill "$producer" 2>/dev/null) &
        wait "$producer"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let processTimeout: TimeInterval = 5
        let resolver = TmuxBinaryResolver(
            processTimeout: processTimeout,
            loginShellProvider: { shell.path }
        )
        let started = Date()

        #expect(
            resolver.resolveTmuxPath()
                == .failure(.probeOutputExceeded(shell: shell.path))
        )
        // The output cap, not the clock, must end this. The failure above
        // proves the cause; this only rules out riding out the whole budget.
        #expect(Date().timeIntervalSince(started) < processTimeout)
    }

    @Test("probe does not inherit unrelated descriptors")
    func probeDescriptorsAreIsolated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        var unrelatedDescriptors = [Int32](repeating: -1, count: 2)
        let pipeStatus = unrelatedDescriptors.withUnsafeMutableBufferPointer {
            pipe($0.baseAddress!)
        }
        try #require(pipeStatus == 0)
        let unrelatedRead = unrelatedDescriptors[0]
        let unrelatedWrite = unrelatedDescriptors[1]
        defer {
            close(unrelatedRead)
            close(unrelatedWrite)
        }
        #expect(fcntl(unrelatedRead, F_SETFD, 0) == 0)

        let shell = directory.appendingPathComponent("probe-shell")
        try """
        #!/bin/sh
        if [ -e /dev/fd/\(unrelatedRead) ]; then
          exit 42
        fi
        printf '/opt/homebrew/bin/tmux\ntmux 3.6a\n'
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let resolver = TmuxBinaryResolver(loginShellProvider: { shell.path })

        #expect(
            resolver.resolveTmuxPath()
                == .success("/opt/homebrew/bin/tmux")
        )
    }
}

@Suite("TmuxPathCache")
struct TmuxPathCacheTests {
    /// The resolve closure is `@Sendable` (the cache resolves off the main
    /// actor), so a mutable call counter lives in a lock-free atomic box
    /// rather than a captured `var`.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("a successful resolution is cached and not re-resolved")
    func cachesSuccess() throws {
        let counter = Counter()
        let cache = TmuxPathCache {
            _ = counter.increment()
            return .success(ResolvedTmuxBinary(
                path: "/opt/homebrew/bin/tmux",
                version: "tmux 3.4a"
            ))
        }

        let expected = ResolvedTmuxBinary(
            path: "/opt/homebrew/bin/tmux",
            version: "tmux 3.4a"
        )
        #expect(try cache.resolveTmuxBinary().get() == expected)
        #expect(try cache.resolveTmuxBinary().get() == expected)
        #expect(counter.count == 1)
    }

    @Test("a failed resolution is not cached, so a later install recovers without a restart")
    func doesNotCacheFailure() throws {
        let counter = Counter()
        let cache = TmuxPathCache {
            counter.increment() == 1
                ? .failure(.notFound(shell: "/bin/zsh"))
                : .success(ResolvedTmuxBinary(
                    path: "/opt/homebrew/bin/tmux",
                    version: "tmux 3.4"
                ))
        }

        guard case .failure = cache.resolveTmuxBinary() else {
            Issue.record("expected the first resolve to fail")
            return
        }
        #expect(
            try cache.resolveTmuxBinary().get().path
                == "/opt/homebrew/bin/tmux"
        )
        #expect(counter.count == 2)
    }
}
