import Foundation
import GhosthubTransport

public enum TmuxAttachmentLaunchMode: String, Codable, Equatable, Sendable {
    case attach
    case attachOnly
    case create
}

public struct TmuxClientSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// An ordinary tmux client launched inside a libghostty terminal surface.
/// Tmux owns rendering, windows, panes, history, input, and process lifetime.
/// Ghosthub enables tmux's session mouse option before presenting the client so
/// wheel scrolling reaches tmux history without requiring user configuration.
public struct TmuxAttachmentInfo: Equatable, Sendable {
    public let sessionName: String
    public let host: CommandHost
    public let socketName: String?
    public let workspacePath: String?
    public let protectedWorkspacePath: String?
    public let presentationStyle: TmuxPresentationStyle?
    public var launchMode: TmuxAttachmentLaunchMode
    public let initialCommand: String?
    public let ignoresClientSize: Bool
    public let initialClientSize: TmuxClientSize?

    public init(
        sessionName: String,
        host: CommandHost,
        socketName: String? = nil,
        workspacePath: String? = nil,
        protectedWorkspacePath: String? = nil,
        presentationStyle: TmuxPresentationStyle? = nil,
        launchMode: TmuxAttachmentLaunchMode = .attach,
        initialCommand: String? = nil,
        ignoresClientSize: Bool = false,
        initialClientSize: TmuxClientSize? = nil
    ) {
        self.sessionName = sessionName
        self.host = host
        self.socketName = socketName
        self.workspacePath = workspacePath
        self.protectedWorkspacePath = protectedWorkspacePath
        self.presentationStyle = presentationStyle
        self.launchMode = launchMode
        self.initialCommand = initialCommand
        self.ignoresClientSize = ignoresClientSize
        self.initialClientSize = initialClientSize
    }

    public func attachCommand(
        tmuxPath: String = "tmux",
        kwtPath: String? = nil,
        remoteKwtCommandPrelude: String? = nil,
        windowsKwtRelativePath: String? = nil,
        workingDirectory: String? = nil,
        sshConnectionArguments: [String] = demoSSHIsolationArguments(),
        remoteExitStatusPath: String? = nil,
        clientTTYToken: String? = nil,
        localClientTTYDirectory: String? = nil
    ) -> String {
        switch host {
        case .local:
            let command = localAttachCommand(
                tmuxPath: tmuxPath,
                kwtPath: kwtPath,
                workingDirectory: workingDirectory
            )
            return recordedClientTTYCommand(
                command,
                token: clientTTYToken,
                directory: localClientTTYDirectory
            )
        case let .ssh(info):
            let command: String
            if info.platform == .windows {
                if launchMode == .create {
                    command = remoteCreateThenAttachCommand(
                        info: info,
                        tmuxPath: tmuxPath,
                        workingDirectory: workingDirectory,
                        sshConnectionArguments: sshConnectionArguments,
                        clientTTYToken: clientTTYToken
                    )
                } else if launchMode != .attachOnly,
                          protectedWorkspacePath == nil,
                          workspacePath != nil {
                    command = windowsRemoteWorkspaceAttachCommand(
                        info: info,
                        tmuxPath: tmuxPath,
                        windowsKwtRelativePath: windowsKwtRelativePath,
                        sshConnectionArguments: sshConnectionArguments
                    )
                } else {
                    command = windowsRemoteAttachCommand(
                        info: info,
                        tmuxPath: tmuxPath,
                        windowsKwtRelativePath: windowsKwtRelativePath,
                        sshConnectionArguments: sshConnectionArguments
                    )
                }
            } else if launchMode == .create {
                if let initialCommand, !initialCommand.isEmpty {
                    command = remoteInitialCommandAttachCommand(
                        info: info,
                        tmuxPath: tmuxPath,
                        workingDirectory: workingDirectory,
                        initialCommand: initialCommand,
                        sshConnectionArguments: sshConnectionArguments,
                        clientTTYToken: clientTTYToken
                    )
                } else {
                    command = remoteCreateThenAttachCommand(
                        info: info,
                        tmuxPath: tmuxPath,
                        workingDirectory: workingDirectory,
                        sshConnectionArguments: sshConnectionArguments,
                        clientTTYToken: clientTTYToken
                    )
                }
            } else if launchMode != .attachOnly,
                      protectedWorkspacePath == nil,
                      workspacePath != nil {
                command = remoteWorkspaceAttachCommand(
                    info: info,
                    tmuxPath: tmuxPath,
                    remoteKwtCommandPrelude: remoteKwtCommandPrelude,
                    sshConnectionArguments: sshConnectionArguments,
                    clientTTYToken: clientTTYToken
                )
            } else {
                command = remoteAttachCommand(
                    info: info,
                    tmuxPath: tmuxPath,
                    remoteKwtCommandPrelude: remoteKwtCommandPrelude,
                    sshConnectionArguments: sshConnectionArguments,
                    clientTTYToken: clientTTYToken
                )
            }
            let recordedCommand: String
            if let remoteExitStatusPath, !remoteExitStatusPath.isEmpty {
                recordedCommand = shellCommand([
                    "/bin/sh", "-c", Self.remoteExitStatusScript,
                    "ghosthub-ssh-status", remoteExitStatusPath, command,
                ])
            } else {
                recordedCommand = command
            }
            let terminalCommand = if let initialSizeCommand {
                shellCommand([
                    "/bin/sh", "-c",
                    initialSizeCommand + "; exec " + recordedCommand,
                ])
            } else {
                recordedCommand
            }
            return surfaceAccountLoginShellCommand(terminalCommand)
        }
    }

    private func localAttachCommand(
        tmuxPath: String,
        kwtPath: String?,
        workingDirectory: String?
    ) -> String {
        let attach = tmuxArguments(tmuxPath, attachArguments)
            .map(shellQuotedCommandArgument).joined(separator: " ")
        var commands = ["unset TMUX TMUX_PANE"]
        if let initialSizeCommand {
            commands.append(initialSizeCommand)
        }
        switch launchMode {
        case .attach:
            if let protectedWorkspacePath {
                guard let kwtPath, !kwtPath.isEmpty else {
                    commands.append(
                        "printf 'Ghosthub: bundled kwt is unavailable\\n' >&2"
                    )
                    commands.append("exit 127")
                    break
                }
                // Unlike an ordinary attach, this hands off to kwt, which
                // finds tmux by name on PATH. A Ghosthub launched from Finder
                // inherits the GUI session's PATH, which routinely omits
                // Homebrew, so lead with the tmux Ghosthub already resolved
                // and version-checked through the login shell.
                if let directory = resolvedBinaryDirectory(tmuxPath) {
                    commands.append(
                        "PATH=\(shellQuotedCommandArgument(directory)):$PATH"
                    )
                    commands.append("export PATH")
                }
                let protectedAttach = [
                    kwtPath, "pr", "attach", protectedWorkspacePath,
                ].map(shellQuotedCommandArgument).joined(separator: " ")
                commands.append(
                    kwtAttachWithSessionSetupCommand(
                        protectedAttach,
                        tmuxPath: tmuxPath
                    )
                )
            } else {
                if let workspacePath {
                    guard let kwtPath, !kwtPath.isEmpty else {
                        commands.append(
                            "printf 'Ghosthub: bundled kwt is unavailable\\n' >&2"
                        )
                        commands.append("exit 127")
                        break
                    }
                    if let directory = resolvedBinaryDirectory(tmuxPath) {
                        commands.append(
                            "PATH=\(shellQuotedCommandArgument(directory)):$PATH"
                        )
                        commands.append("export PATH")
                    }
                    let openWorkspace = [
                        kwtPath, "open", workspacePath,
                    ].map(shellQuotedCommandArgument).joined(separator: " ")
                    // Let kwt create and attach with one tmux client.
                    // A detached `--start-session` phase is unsafe when the
                    // user's tmux server enables destroy-unattached.
                    commands.append(
                        kwtAttachWithSessionSetupCommand(
                            openWorkspace,
                            tmuxPath: tmuxPath
                        )
                    )
                } else {
                    commands.append(mouseSetupCommand(tmuxPath: tmuxPath))
                    commands.append(
                        presentationCommand?.bestEffortCommand(
                            tmuxPath: tmuxPath
                        ) ?? ":"
                    )
                    commands.append("exec \(attach)")
                }
            }
        case .attachOnly:
            commands.append(mouseSetupCommand(tmuxPath: tmuxPath))
            commands.append(
                presentationCommand?.bestEffortCommand(
                    tmuxPath: tmuxPath
                ) ?? ":"
            )
            commands.append("exec \(attach)")
        case .create:
            let createAndAttach = localCreateAndAttachCommand(
                tmuxPath: tmuxPath,
                workingDirectory: workingDirectory
            )
            commands.append("exec \(createAndAttach)")
        }
        return shellCommand([
            "/bin/sh", "-c", commands.joined(separator: "; "),
        ])
    }

    /// A single tmux client invocation atomically creates or attaches the
    /// local session. Keeping new-session and attachment together prevents a
    /// server with destroy-unattached enabled from removing a detached
    /// session in the gap before Ghosthub attaches.
    private func localCreateAndAttachCommand(
        tmuxPath: String,
        workingDirectory: String?
    ) -> String {
        var arguments = tmuxArguments(
            tmuxPath,
            "new-session", "-A", "-E", "-s", sessionName
        ) + (workingDirectory.map { ["-c", $0] } ?? [])
        if let initialCommand, !initialCommand.isEmpty {
            arguments.append(initialCommand)
        }
        arguments = appendingMouseOption(to: arguments)
        if let presentationCommand {
            arguments = presentationCommand.appendingOptions(to: arguments)
        }
        return arguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
    }

    private var presentationCommand: TmuxPresentationCommand? {
        guard let presentationStyle else { return nil }
        return TmuxPresentationCommand(
            sessionName: sessionName,
            socketName: socketName,
            style: presentationStyle
        )
    }

    private var attachArguments: [String] {
        var arguments = ["attach-session", "-E"]
        if ignoresClientSize {
            arguments += ["-f", "ignore-size"]
        }
        arguments += ["-t", "=\(sessionName)"]
        return arguments
    }

    private var initialSizeCommand: String? {
        guard ignoresClientSize,
              let initialClientSize,
              initialClientSize.columns > 0,
              initialClientSize.rows > 0
        else { return nil }
        return "stty columns \(initialClientSize.columns)"
            + " rows \(initialClientSize.rows) || exit $?"
    }

    /// Kwt establishes or repairs the complete session before starting its
    /// tmux client. Run kwt as the foreground terminal's background child just
    /// long enough to observe a client on this launch's PTY, then enable mouse
    /// handling, apply any presentation style, and wait on the same client.
    /// This preserves kwt's atomic create-and-attach path under
    /// `destroy-unattached` while ensuring repair-created windows are included.
    private func kwtAttachWithSessionSetupCommand(
        _ kwtCommand: String,
        tmuxPath: String
    ) -> String {
        var setupCommands = [mouseSetupCommand(tmuxPath: tmuxPath)]
        if let presentationCommand {
            setupCommands.append(
                presentationCommand.bestEffortCommand(tmuxPath: tmuxPath)
            )
        }
        let sessionSetup = setupCommands.joined(separator: "; ")
        let listClientTTYs = tmuxArguments(
            tmuxPath,
            "list-clients", "-t", "=\(sessionName)",
            "-F", "#{client_tty}"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        return [
            "exec 3<&0",
            "ghosthub_kwt_tty=\"$(tty 2>/dev/null)\"",
            "\(kwtCommand) <&3 3<&- & ghosthub_kwt_pid=$!",
            "ghosthub_kwt_client_ready=",
            "while kill -0 \"$ghosthub_kwt_pid\" 2>/dev/null; do "
                + "for ghosthub_client_tty in "
                + "$(\(listClientTTYs) 2>/dev/null); do "
                + "if [ \"$ghosthub_client_tty\" = "
                + "\"$ghosthub_kwt_tty\" ]; then "
                + "ghosthub_kwt_client_ready=1; break; fi; done; "
                + "[ -n \"$ghosthub_kwt_client_ready\" ] && break; "
                + "sleep 0.01; done",
            "if [ -n \"$ghosthub_kwt_client_ready\" ]; then "
                + "\(sessionSetup); fi",
            "wait \"$ghosthub_kwt_pid\"",
            "ghosthub_kwt_status=$?",
            "exec 3<&-",
            "exit \"$ghosthub_kwt_status\"",
        ].joined(separator: "; ")
    }

    private func remoteAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        remoteKwtCommandPrelude: String?,
        sshConnectionArguments: [String],
        clientTTYToken: String?,
        includesPresentation: Bool = true
    ) -> String {
        if info.platform == .windows {
            return windowsRemoteAttachCommand(
                info: info,
                tmuxPath: tmuxPath,
                sshConnectionArguments: sshConnectionArguments
            )
        }
        let attach: String
        if let protectedWorkspacePath,
           launchMode != .attachOnly {
            let protectedAttach: String
            if let remoteKwtCommandPrelude {
                let kwtAttach = remoteKwtCommandPrelude
                    + "\"$ghosthub_kwt_path\" 'pr' 'attach' "
                    + shellQuotedCommandArgument(protectedWorkspacePath)
                protectedAttach = kwtAttachWithSessionSetupCommand(
                    kwtAttach,
                    tmuxPath: tmuxPath
                )
            } else {
                protectedAttach =
                    "printf 'Ghosthub: managed kwt is unavailable\\n' >&2; "
                        + "exit 127"
            }
            attach = protectedAttach
        } else {
            let tmuxAttach = tmuxArguments(tmuxPath, attachArguments)
                .map(shellQuotedCommandArgument).joined(separator: " ")
            attach = "exec \(tmuxAttach)"
        }
        var remoteAttachCommands = ["unset TMUX TMUX_PANE"]
        if includesPresentation,
           protectedWorkspacePath == nil || launchMode == .attachOnly {
            remoteAttachCommands.append(
                mouseSetupCommand(tmuxPath: tmuxPath)
            )
            remoteAttachCommands.append(
                presentationCommand?.bestEffortCommand(
                    tmuxPath: tmuxPath
                ) ?? ":"
            )
        }
        remoteAttachCommands.append(attach)
        // Every POSIX remote tmux phase runs through the account login shell
        // so login-initialized settings such as TMUX_TMPDIR resolve the same
        // tmux server as later styling and identity commands.
        let remoteAttach = accountLoginShellCommand(
            recordedClientTTYBody(
                remoteAttachCommands.joined(separator: "; "),
                token: clientTTYToken
            )
        )
        return sshAttachCommand(
            label: "ghosthub-ssh-tmux",
            info: info,
            allocateTTY: true,
            remoteCommand: remoteAttach,
            sshConnectionArguments: sshConnectionArguments
        )
    }

    private func remoteWorkspaceAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        remoteKwtCommandPrelude: String?,
        sshConnectionArguments: [String],
        clientTTYToken: String?
    ) -> String {
        guard let workspacePath else {
            return remoteAttachCommand(
                info: info,
                tmuxPath: tmuxPath,
                remoteKwtCommandPrelude: nil,
                sshConnectionArguments: sshConnectionArguments,
                clientTTYToken: clientTTYToken
            )
        }
        let remoteOpen: String
        if let remoteKwtCommandPrelude {
            let kwtOpen = remoteKwtCommandPrelude
                + "\"$ghosthub_kwt_path\" 'open' "
                + shellQuotedCommandArgument(workspacePath)
            remoteOpen = kwtAttachWithSessionSetupCommand(
                kwtOpen,
                tmuxPath: tmuxPath
            )
        } else {
            remoteOpen =
                "printf 'Ghosthub: managed kwt is unavailable\\n' >&2; "
                    + "exit 127"
        }
        let initialBody = recordedClientTTYBody([
            "unset TMUX TMUX_PANE",
            remoteOpen,
        ].joined(separator: "; "), token: clientTTYToken)
        let initialAttach = shellCommand(
            sshArguments(
                info: info,
                allocateTTY: true,
                remoteCommand: accountLoginShellCommand(initialBody),
                sshConnectionArguments: sshConnectionArguments
            )
        )
        return shellCommand([
            "/bin/sh", "-c", Self.remoteWorkspaceAttachScript,
            "ghosthub-ssh-kwt-attach",
            initialAttach,
        ])
    }

    private func windowsRemoteWorkspaceAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        windowsKwtRelativePath: String?,
        sshConnectionArguments: [String]
    ) -> String {
        guard let workspacePath else {
            return windowsRemoteAttachCommand(
                info: info,
                tmuxPath: tmuxPath,
                windowsKwtRelativePath: windowsKwtRelativePath,
                sshConnectionArguments: sshConnectionArguments
            )
        }
        let initialScript = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        Remove-Item Env:TMUX, Env:TMUX_PANE -ErrorAction SilentlyContinue
        \(powerShellKwtResolutionPrelude(
            managedRelativePath: windowsKwtRelativePath
        ))
        & $ghosthubKwt 'open' \(powerShellEncodedArgument(workspacePath))
        exit $LASTEXITCODE
        """
        let initialAttach = shellCommand(
            sshArguments(
                info: info,
                allocateTTY: true,
                remoteCommand: powerShellEncodedCommand(initialScript),
                sshConnectionArguments: sshConnectionArguments
            )
        )
        return shellCommand([
            "/bin/sh", "-c", Self.remoteWorkspaceAttachScript,
            "ghosthub-ssh-kwt-attach",
            initialAttach,
        ])
    }

    private func windowsRemoteAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        windowsKwtRelativePath: String? = nil,
        sshConnectionArguments: [String]
    ) -> String {
        let attach: String
        if let protectedWorkspacePath, launchMode != .attachOnly {
            attach = """
            \(powerShellKwtResolutionPrelude(
                managedRelativePath: windowsKwtRelativePath
            ))
            & $ghosthubKwt 'pr' 'attach' \(powerShellEncodedArgument(protectedWorkspacePath))
            """
        } else {
            attach = windowsMuxCommand(
                tmuxPath: tmuxPath,
                arguments: attachArguments
            )
        }
        let script = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        Remove-Item Env:TMUX, Env:TMUX_PANE -ErrorAction SilentlyContinue
        \(attach)
        exit $LASTEXITCODE
        """
        let remoteCommand = powerShellEncodedCommand(script)
        return sshAttachCommand(
            label: "ghosthub-ssh-psmux",
            info: info,
            allocateTTY: true,
            remoteCommand: remoteCommand,
            sshConnectionArguments: sshConnectionArguments
        )
    }

    private func sshAttachCommand(
        label: String,
        info: SSHHostInfo,
        allocateTTY: Bool,
        remoteCommand: String,
        sshConnectionArguments: [String]
    ) -> String {
        return shellCommand(
            [
                "/bin/sh", "-c", Self.sshAttachScript,
                label,
            ] + sshArguments(
                info: info,
                allocateTTY: allocateTTY,
                remoteCommand: remoteCommand,
                sshConnectionArguments: sshConnectionArguments
            )
        )
    }

    private func remoteCreateThenAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        workingDirectory: String?,
        sshConnectionArguments: [String],
        clientTTYToken: String?
    ) -> String {
        var remoteCreate: String
        if info.platform == .windows {
            let script = """
            $ErrorActionPreference = 'Stop'
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            Remove-Item Env:TMUX, Env:TMUX_PANE -ErrorAction SilentlyContinue
            \(windowsCreateIfAbsentScript(
                tmuxPath: tmuxPath,
                workingDirectory: workingDirectory
            ))
            """
            remoteCreate = powerShellEncodedCommand(script)
        } else {
            remoteCreate = "unset TMUX TMUX_PANE; "
                + createIfAbsentCommand(
                    tmuxPath: tmuxPath,
                    workingDirectory: workingDirectory
                )
            // Session setup is best effort and must not mask failed creation:
            // exit with the creation status first, then report success
            // regardless of mouse or styling outcomes.
            remoteCreate += " || exit $?; "
                + mouseSetupCommand(tmuxPath: tmuxPath)
            if let presentationCommand {
                remoteCreate += "; "
                    + presentationCommand.bestEffortCommand(
                        tmuxPath: tmuxPath
                    )
            }
            remoteCreate += "; exit 0"
            remoteCreate = accountLoginShellCommand(remoteCreate)
        }
        let createOnce = shellCommand(
            sshArguments(
                info: info,
                allocateTTY: false,
                remoteCommand: remoteCreate,
                sshConnectionArguments: sshConnectionArguments
            )
        )
        let attach = remoteAttachCommand(
            info: info,
            tmuxPath: tmuxPath,
            remoteKwtCommandPrelude: nil,
            sshConnectionArguments: sshConnectionArguments,
            clientTTYToken: clientTTYToken,
            includesPresentation: false
        )
        return shellCommand([
            "/bin/sh", "-c", Self.remoteCreateThenAttachScript,
            "ghosthub-ssh-tmux-create-once", createOnce, attach,
        ])
    }

    /// Profile-backed creation must allocate the SSH PTY before tmux starts so
    /// interactive commands such as sudo and docker exec inherit the terminal
    /// that remains attached to the outer host session. Native recovery probes
    /// the exact session before deciding whether creation may run again.
    private func remoteInitialCommandAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        workingDirectory: String?,
        initialCommand: String,
        sshConnectionArguments: [String],
        clientTTYToken: String?
    ) -> String {
        var createArguments = tmuxArguments(
            tmuxPath,
            "new-session", "-A", "-E", "-s", sessionName
        ) + (workingDirectory.map { ["-c", $0] } ?? [])
        createArguments.append(initialCommand)
        createArguments = appendingMouseOption(to: createArguments)
        if let presentationCommand {
            createArguments = presentationCommand.appendingOptions(
                to: createArguments
            )
        }
        let createAndAttach = createArguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        let initialBody = recordedClientTTYBody(
            "unset TMUX TMUX_PANE; exec \(createAndAttach)",
            token: clientTTYToken
        )
        return shellCommand(
            sshArguments(
                info: info,
                allocateTTY: true,
                remoteCommand: accountLoginShellCommand(initialBody),
                sshConnectionArguments: sshConnectionArguments
            )
        )
    }

    private func createIfAbsentCommand(
        tmuxPath: String,
        workingDirectory: String?
    ) -> String {
        let target = "=\(sessionName)"
        let hasSession = tmuxArguments(
            tmuxPath,
            "has-session", "-t", target
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        let createSession = (tmuxArguments(
            tmuxPath,
            "new-session", "-d", "-E", "-s", sessionName
        ) + (workingDirectory.map { ["-c", $0] } ?? []))
            .map(shellQuotedCommandArgument).joined(separator: " ")
        return "\(hasSession) 2>/dev/null || "
            + "\(createSession) || \(hasSession)"
    }

    private func appendingMouseOption(to arguments: [String]) -> [String] {
        arguments + [
            ";", "set-option", "-t", exactSessionTarget,
            "mouse", "on",
        ]
    }

    private func mouseSetupCommand(tmuxPath: String) -> String {
        let command = tmuxArguments(
            tmuxPath,
            "set-option", "-t", exactSessionTarget,
            "mouse", "on"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        return "\(command) >/dev/null 2>&1 || :"
    }

    private var exactSessionTarget: String {
        "=\(sessionName):"
    }

    private func recordedClientTTYCommand(
        _ command: String,
        token: String?,
        directory: String? = nil
    ) -> String {
        guard let token else { return command }
        return shellCommand([
            "/bin/sh", "-c",
            recordedClientTTYBody(
                command,
                token: token,
                directory: directory
            ),
        ])
    }

    private func recordedClientTTYBody(
        _ command: String,
        token: String?,
        directory: String? = nil
    ) -> String {
        guard let token,
              !token.isEmpty,
              token.utf8.allSatisfy({ byte in
                  byte == 45 || byte >= 48 && byte <= 57
                      || byte >= 65 && byte <= 90
                      || byte >= 97 && byte <= 122
              })
        else { return command }
        let nestedCommand = shellCommand(["/bin/sh", "-c", command])
        let clientTTYDirectory = directory.map(shellQuotedCommandArgument)
            ?? "\"$HOME/.ghosthub/tmux-clients\""
        return [
            "unset TMUX TMUX_PANE",
            "ghosthub_client_tty_dir=\(clientTTYDirectory)",
            "ghosthub_client_tty_path=\"$ghosthub_client_tty_dir/\(token)\"",
            "ghosthub_client_tty_tmp=\"$ghosthub_client_tty_path.$$\"",
            "ghosthub_client_pid=",
            "ghosthub_client_token_ready=",
            "ghosthub_client_tty=$(tty 2>/dev/null) "
                + "|| ghosthub_client_tty=",
            "if [ -n \"$ghosthub_client_tty\" ] "
                + "&& (umask 077; mkdir -p \"$ghosthub_client_tty_dir\"); "
                + "then ghosthub_client_token_ready=1; fi",
            "ghosthub_client_cleanup() { rm -f "
                + "\"$ghosthub_client_tty_path\" "
                + "\"$ghosthub_client_tty_tmp\"; "
                + "case \"$ghosthub_client_pid\" in "
                + "''|*[!0-9]*) ;; *) kill \"$ghosthub_client_pid\" "
                + "2>/dev/null || : ;; esac; }",
            "trap ghosthub_client_cleanup 0",
            "trap 'exit 129' HUP",
            "trap 'exit 130' INT",
            "trap 'exit 143' TERM",
            "if [ -n \"$ghosthub_client_token_ready\" ]; then "
                + "(umask 077; printf '%s\\n' \"$ghosthub_client_tty\" "
                + "> \"$ghosthub_client_tty_tmp\") "
                + "&& mv -f \"$ghosthub_client_tty_tmp\" "
                + "\"$ghosthub_client_tty_path\" || :; fi",
            "exec 3<&0",
            "\(nestedCommand) <&3 3<&- & ghosthub_client_pid=$!",
            "wait \"$ghosthub_client_pid\"",
            "ghosthub_client_status=$?",
            "ghosthub_client_pid=",
            "exec 3<&-",
            "exit \"$ghosthub_client_status\"",
        ].joined(separator: "; ")
    }

    private func windowsCreateIfAbsentScript(
        tmuxPath: String,
        workingDirectory: String?
    ) -> String {
        let target = "=\(sessionName)"
        let hasSession = windowsMuxCommand(
            tmuxPath: tmuxPath,
            arguments: ["has-session", "-t", target]
        )
        var createArguments = [
            "new-session", "-d", "-E", "-s", sessionName,
        ]
        if let workingDirectory {
            createArguments += ["-c", workingDirectory]
        }
        let createSession = windowsMuxCommand(
            tmuxPath: tmuxPath,
            arguments: createArguments
        ) + " '-e' ('PATH=' + $env:PATH)"
        return """
        & { \(hasSession) } *> $null
        if ($LASTEXITCODE -ne 0) {
            \(createSession)
            $ghosthubCreateStatus = $LASTEXITCODE
            if ($ghosthubCreateStatus -ne 0) {
                & { \(hasSession) } *> $null
                exit $LASTEXITCODE
            }
        }
        exit 0
        """
    }

    private func tmuxArguments(
        _ tmuxPath: String,
        _ arguments: String...
    ) -> [String] {
        tmuxArguments(tmuxPath, arguments)
    }

    private func tmuxArguments(
        _ tmuxPath: String,
        _ arguments: [String]
    ) -> [String] {
        var result = [tmuxPath]
        if let socketName, !socketName.isEmpty {
            result.append(contentsOf: ["-L", socketName])
        }
        return result + arguments
    }

    private func windowsMuxCommand(
        tmuxPath: String,
        arguments: [String]
    ) -> String {
        var values = [tmuxPath]
        if let socketName, !socketName.isEmpty {
            values += ["-L", socketName]
        }
        values += arguments
        return "& " + values
            .map(powerShellEncodedArgument)
            .joined(separator: " ")
    }

    private func sshArguments(
        info: SSHHostInfo,
        allocateTTY: Bool,
        remoteCommand: String,
        sshConnectionArguments: [String]
    ) -> [String] {
        var arguments = [
            "/usr/bin/ssh", allocateTTY ? "-tt" : "-T",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes",
            "-o", "ConnectTimeout=15",
        ]
        arguments.append(contentsOf: sshConnectionArguments)
        if let port = info.port {
            arguments.append(contentsOf: ["-p", "\(port)"])
        }
        let destination = info.user.map { "\($0)@\(info.hostname)" }
            ?? info.hostname
        arguments.append(contentsOf: ["--", destination, remoteCommand])
        return arguments
    }

    private func shellCommand(_ arguments: [String]) -> String {
        arguments.map(shellQuotedCommandArgument).joined(separator: " ")
    }

    /// The directory holding an absolute binary path. A bare command name
    /// carries no location worth putting on PATH.
    private func resolvedBinaryDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        return directory.isEmpty || directory == "/" ? nil : directory
    }

    /// Runs creation once and, after success, switches this terminal process
    /// to one attach-only command.
    static let remoteCreateThenAttachScript = """
    /bin/sh -c "$1"
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    exec /bin/sh -c "$2"
    """

    /// Runs one workspace establishment attempt. Native recovery probes the
    /// exact session before deciding whether establishment may run again.
    static let remoteWorkspaceAttachScript = """
    exec /bin/sh -c "$1"
    """

    /// Records the final status of the complete remote establishment or
    /// attachment command before libghostty's macOS login wrapper can obscure
    /// a failed nested OpenSSH process.
    static let remoteExitStatusScript = """
    /bin/sh -c "$2"
    ghosthub_status=$?
    printf '%s\n' "$ghosthub_status" > "$1"
    exit "$ghosthub_status"
    """

    /// Runs one OpenSSH attachment attempt and returns its exact status to its
    /// immediate one-shot command owner.
    static let sshAttachScript = "exec \"$@\""
}
