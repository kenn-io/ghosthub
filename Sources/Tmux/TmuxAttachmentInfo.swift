import Foundation

public func tmuxSSHConnectionArguments(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    // The screenshot app is ad-hoc signed and runs against guarded scratch
    // state. Keep its SSH isolation explicit without changing normal clients.
    guard let scratch = environment["GHOSTHUB_DEMO_SCRATCH"],
          let directory = environment["GHOSTHUB_DEMO_SSH_DIR"],
          scratch.hasPrefix("/"), directory == "\(scratch)/ssh"
    else { return [] }

    return [
        "-F", "\(directory)/config",
        "-o", "UserKnownHostsFile=\(directory)/known_hosts",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ProxyCommand=none",
        "-o", "ProxyJump=none",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
    ]
}

public func shellQuotedCommandArgument(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func accountShellCommandArgument(_ value: String) -> String {
    value.split(separator: "`", omittingEmptySubsequences: false)
        .map { segment in
            let escaped = String(segment)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
            return "\"\(escaped)\""
        }
        .joined(separator: "'`'")
}

public func accountShellCommand(_ command: String) -> String {
    "exec /bin/sh -c " + accountShellCommandArgument(command)
}

/// Keeps caller-controlled text out of PowerShell source. The generated
/// expression contains only a Base64 alphabet in an ASCII-delimited literal.
public func powerShellEncodedArgument(_ value: String) -> String {
    let encoded = Data(value.utf8).base64EncodedString()
    return "([System.Text.Encoding]::UTF8.GetString("
        + "[System.Convert]::FromBase64String('\(encoded)')))"
}

public func powerShellEncodedCommand(_ command: String) -> String {
    let data = command.data(using: .utf16LittleEndian) ?? Data()
    return [
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-EncodedCommand",
        data.base64EncodedString(),
    ].joined(separator: " ")
}

public func powerShellKwtResolutionPrelude(
    managedRelativePath: String?
) -> String {
    guard let managedRelativePath else {
        return "throw 'Ghosthub managed kwt is unavailable'"
    }
    return """
    $ghosthubKwt = Join-Path $env:USERPROFILE \(
        powerShellEncodedArgument(managedRelativePath)
    )
    if (-not (Test-Path -LiteralPath $ghosthubKwt -PathType Leaf)) {
        throw 'Ghosthub managed kwt is unavailable'
    }
    """
}

public func powerShellKwtAvailabilityPrelude(
    managedRelativePath: String?
) -> String {
    guard let managedRelativePath else {
        return "$ghosthubKwtAvailable = $false"
    }
    return """
    $ghosthubManagedKwt = Join-Path $env:USERPROFILE \(
        powerShellEncodedArgument(managedRelativePath)
    )
    $ghosthubKwtAvailable = Test-Path -LiteralPath $ghosthubManagedKwt -PathType Leaf
    """
}

/// Initializes an account's login environment, then delegates
/// Ghosthub-owned POSIX command text to `/bin/sh`. The outer command argument
/// is accepted by POSIX shells and non-POSIX account shells such as fish.
private func accountLoginCommand(_ command: String) -> String {
    let posixCommand = accountShellCommand(command)
    return "exec \"${SHELL:-/bin/sh}\" -lc "
        + shellQuotedCommandArgument(posixCommand)
}

public func accountLoginShellCommand(_ command: String) -> String {
    accountShellCommand(accountLoginCommand(command))
}

/// Libghostty's macOS surface startup prepends `exec -l` to custom commands,
/// so its command must begin with the executable rather than the `exec`
/// shell builtin. The nested account login and POSIX handoffs remain the same.
public func surfaceAccountLoginShellCommand(_ command: String) -> String {
    "/bin/sh -c " + accountShellCommandArgument(accountLoginCommand(command))
}

public enum ConnectionState: Codable, Equatable, Sendable {
    case connecting
    case reconnecting(reason: String?)
    case connected
    case disconnected(reason: String?)
}

public struct SSHHostInfo: Codable, Hashable, Sendable {
    public enum Platform: String, Codable, Hashable, Sendable {
        case posix
        case windows
    }

    public let user: String?
    public let hostname: String
    public let port: Int?
    public let platform: Platform

    public init(
        user: String?,
        hostname: String,
        port: Int?,
        platform: Platform = .posix
    ) {
        self.user = user
        self.hostname = hostname
        self.port = port
        self.platform = platform
    }

    public var displayName: String {
        let destination = user.map { "\($0)@\(hostname)" } ?? hostname
        guard let port, port != 22 else { return destination }
        return "\(destination):\(port)"
    }
}

public enum TmuxHost: Codable, Hashable, Sendable {
    case local
    case ssh(SSHHostInfo)

    public var displayName: String {
        switch self {
        case .local:
            "localhost"
        case let .ssh(info):
            info.displayName
        }
    }

    public var isRemote: Bool {
        if case .ssh = self {
            return true
        }
        return false
    }
}

public enum TmuxAttachmentLaunchMode: String, Codable, Equatable, Sendable {
    case attach
    case attachOnly
    case create
}

/// An ordinary tmux client launched inside a libghostty terminal surface.
/// Tmux owns rendering, windows, panes, history, input, and process lifetime.
public struct TmuxAttachmentInfo: Equatable, Sendable {
    public let sessionName: String
    public let host: TmuxHost
    public let socketName: String?
    public let workspacePath: String?
    public let protectedWorkspacePath: String?
    public let presentationStyle: TmuxPresentationStyle?
    public var launchMode: TmuxAttachmentLaunchMode

    public init(
        sessionName: String,
        host: TmuxHost,
        socketName: String? = nil,
        workspacePath: String? = nil,
        protectedWorkspacePath: String? = nil,
        presentationStyle: TmuxPresentationStyle? = nil,
        launchMode: TmuxAttachmentLaunchMode = .attach
    ) {
        self.sessionName = sessionName
        self.host = host
        self.socketName = socketName
        self.workspacePath = workspacePath
        self.protectedWorkspacePath = protectedWorkspacePath
        self.presentationStyle = presentationStyle
        self.launchMode = launchMode
    }

    public func attachCommand(
        tmuxPath: String = "tmux",
        kwtPath: String? = nil,
        remoteKwtCommandPrelude: String? = nil,
        windowsKwtRelativePath: String? = nil,
        workingDirectory: String? = nil,
        sshConnectionArguments: [String] = tmuxSSHConnectionArguments(),
        remoteExitStatusPath: String? = nil
    ) -> String {
        switch host {
        case .local:
            return localAttachCommand(
                tmuxPath: tmuxPath,
                kwtPath: kwtPath,
                workingDirectory: workingDirectory
            )
        case let .ssh(info):
            let command: String
            if info.platform == .windows {
                if launchMode == .create {
                    command = remoteCreateThenAttachCommand(
                        info: info,
                        tmuxPath: tmuxPath,
                        workingDirectory: workingDirectory,
                        sshConnectionArguments: sshConnectionArguments
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
                command = remoteCreateThenAttachCommand(
                    info: info,
                    tmuxPath: tmuxPath,
                    workingDirectory: workingDirectory,
                    sshConnectionArguments: sshConnectionArguments
                )
            } else if launchMode != .attachOnly,
                      protectedWorkspacePath == nil,
                      workspacePath != nil {
                command = remoteWorkspaceAttachCommand(
                    info: info,
                    tmuxPath: tmuxPath,
                    remoteKwtCommandPrelude: remoteKwtCommandPrelude,
                    sshConnectionArguments: sshConnectionArguments
                )
            } else {
                command = remoteAttachCommand(
                    info: info,
                    tmuxPath: tmuxPath,
                    remoteKwtCommandPrelude: remoteKwtCommandPrelude,
                    sshConnectionArguments: sshConnectionArguments
                )
            }
            let recordedCommand: String
            if let remoteExitStatusPath, !remoteExitStatusPath.isEmpty {
                recordedCommand = "GHOSTHUB_SSH_EXIT_STATUS_PATH="
                    + shellQuotedCommandArgument(remoteExitStatusPath)
                    + "; export GHOSTHUB_SSH_EXIT_STATUS_PATH; "
                    + command
            } else {
                recordedCommand = "unset GHOSTHUB_SSH_EXIT_STATUS_PATH; "
                    + command
            }
            return surfaceAccountLoginShellCommand(recordedCommand)
        }
    }

    private func localAttachCommand(
        tmuxPath: String,
        kwtPath: String?,
        workingDirectory: String?
    ) -> String {
        let attach = tmuxArguments(
            tmuxPath,
            "attach-session", "-E", "-t", "=\(sessionName)"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        var commands = ["unset TMUX TMUX_PANE"]
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
                    kwtAttachWithPresentationCommand(
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
                        kwtAttachWithPresentationCommand(
                            openWorkspace,
                            tmuxPath: tmuxPath
                        )
                    )
                } else {
                    commands.append(
                        presentationCommand?.bestEffortCommand(
                            tmuxPath: tmuxPath
                        ) ?? ":"
                    )
                    commands.append("exec \(attach)")
                }
            }
        case .attachOnly:
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

    /// Kwt establishes or repairs the complete session before starting its
    /// tmux client. When Ghosthub owns presentation, run kwt as the foreground
    /// terminal's background child just long enough to observe a client on
    /// this launch's PTY, then style the finished session and wait on the same
    /// client process.
    /// This preserves kwt's atomic create-and-attach path under
    /// `destroy-unattached` while ensuring repair-created windows are included.
    private func kwtAttachWithPresentationCommand(
        _ kwtCommand: String,
        tmuxPath: String
    ) -> String {
        guard let presentationCommand else {
            return host.isRemote ? kwtCommand : "exec \(kwtCommand)"
        }
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
                + "\(presentationCommand.bestEffortCommand(tmuxPath: tmuxPath)); fi",
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
        if let protectedWorkspacePath, launchMode != .attachOnly {
            let protectedAttach: String
            if let remoteKwtCommandPrelude {
                let kwtAttach = remoteKwtCommandPrelude
                    + "\"$ghosthub_kwt_path\" 'pr' 'attach' "
                    + shellQuotedCommandArgument(protectedWorkspacePath)
                protectedAttach = kwtAttachWithPresentationCommand(
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
            let tmuxAttach = tmuxArguments(
                tmuxPath,
                "attach-session", "-E", "-t", "=\(sessionName)"
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            attach = "exec \(tmuxAttach)"
        }
        var remoteAttachCommands = ["unset TMUX TMUX_PANE"]
        if includesPresentation,
           protectedWorkspacePath == nil || launchMode == .attachOnly {
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
            remoteAttachCommands.joined(separator: "; ")
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
        sshConnectionArguments: [String]
    ) -> String {
        guard let workspacePath else {
            return remoteAttachCommand(
                info: info,
                tmuxPath: tmuxPath,
                remoteKwtCommandPrelude: nil,
                sshConnectionArguments: sshConnectionArguments
            )
        }
        let remoteOpen: String
        if let remoteKwtCommandPrelude {
            let kwtOpen = remoteKwtCommandPrelude
                + "\"$ghosthub_kwt_path\" 'open' "
                + shellQuotedCommandArgument(workspacePath)
            remoteOpen = kwtAttachWithPresentationCommand(
                kwtOpen,
                tmuxPath: tmuxPath
            )
        } else {
            remoteOpen =
                "printf 'Ghosthub: managed kwt is unavailable\\n' >&2; "
                    + "exit 127"
        }
        let initialBody = [
            "unset TMUX TMUX_PANE",
            remoteOpen,
        ].joined(separator: "; ")
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
                arguments: [
                    "attach-session", "-E", "-t", "=\(sessionName)",
                ]
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
        sshConnectionArguments: [String]
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
            if let presentationCommand {
                // Styling is best effort and must not mask a failed creation:
                // exit with the creation status first, then report success
                // regardless of styling outcomes.
                remoteCreate += " || exit $?; "
                    + presentationCommand.bestEffortCommand(
                        tmuxPath: tmuxPath
                    )
                    + "; exit 0"
            }
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
            includesPresentation: false
        )
        return shellCommand([
            "/bin/sh", "-c", Self.remoteCreateThenAttachScript,
            "ghosthub-ssh-tmux-create-once", createOnce, attach,
        ])
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

    /// Runs one OpenSSH attachment attempt and records its exact status before
    /// returning it. Libghostty's macOS login wrapper can otherwise report a
    /// successful child exit for a failed nested command.
    static let sshAttachScript = """
    ghosthub_status_path=${GHOSTHUB_SSH_EXIT_STATUS_PATH-}
    unset GHOSTHUB_SSH_EXIT_STATUS_PATH
    "$@"
    ghosthub_status=$?
    if [ -n "$ghosthub_status_path" ]; then
        printf '%s\n' "$ghosthub_status" > "$ghosthub_status_path"
    fi
    exit "$ghosthub_status"
    """
}
