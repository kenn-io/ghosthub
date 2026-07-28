import Foundation

public func tmuxSSHConnectionArguments(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    var arguments = [
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
    ]
    // The screenshot app is ad-hoc signed and runs against guarded scratch
    // state. Keep its SSH isolation explicit without changing normal clients.
    if let scratch = environment["GHOSTHUB_DEMO_SCRATCH"],
       let directory = environment["GHOSTHUB_DEMO_SSH_DIR"],
       scratch.hasPrefix("/"), directory == "\(scratch)/ssh" {
        arguments.insert(contentsOf: [
            "-F", "\(directory)/config",
            "-o", "UserKnownHostsFile=\(directory)/known_hosts",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ProxyCommand=none",
            "-o", "ProxyJump=none",
        ], at: 0)
    }
    return arguments
}

public func shellQuotedCommandArgument(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

public func powerShellQuotedCommandArgument(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
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

public let ghosthubManagedWindowsKwtRelativePath =
    #".ghosthub\bin\kwt.exe"#

public func powerShellKwtResolutionPrelude() -> String {
    """
    $ghosthubManagedKwt = Join-Path $env:USERPROFILE \(
        powerShellQuotedCommandArgument(ghosthubManagedWindowsKwtRelativePath)
    )
    if (Test-Path -LiteralPath $ghosthubManagedKwt -PathType Leaf) {
        $ghosthubKwt = $ghosthubManagedKwt
    } else {
        $ghosthubKwt = (Get-Command kwt.exe -CommandType Application -ErrorAction Stop).Source
    }
    """
}

public func powerShellKwtAvailabilityPrelude() -> String {
    """
    $ghosthubManagedKwt = Join-Path $env:USERPROFILE \(
        powerShellQuotedCommandArgument(ghosthubManagedWindowsKwtRelativePath)
    )
    $ghosthubKwtAvailable = (Test-Path -LiteralPath $ghosthubManagedKwt -PathType Leaf) -or ($null -ne (Get-Command kwt.exe -CommandType Application -ErrorAction SilentlyContinue))
    """
}

/// Initializes the remote account's login environment, then delegates
/// Ghosthub-owned POSIX command text to `/bin/sh`. The outer simple command is
/// accepted by POSIX shells and non-POSIX account shells such as fish.
public func remoteAccountLoginShellCommand(_ command: String) -> String {
    let posixCommand = "exec /bin/sh -c "
        + shellQuotedCommandArgument(command)
    let accountShellCommand = "exec \"${SHELL:-/bin/sh}\" -lc "
        + shellQuotedCommandArgument(posixCommand)
    return "exec /bin/sh -c "
        + shellQuotedCommandArgument(accountShellCommand)
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
    case create
}

/// Default colors Ghosthub applies to tmux panes when a built-in terminal
/// theme is selected. Tmux otherwise answers OSC 10/11 queries from the first
/// attached client, which can describe a different terminal's theme.
public struct TmuxPresentationStyle: Equatable, Sendable {
    public let foreground: String
    public let background: String

    public init(foreground: String, background: String) {
        self.foreground = foreground
        self.background = background
    }

    fileprivate var tmuxStyle: String {
        "fg=\(foreground),bg=\(background)"
    }
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
        workingDirectory: String? = nil,
        sshConnectionArguments: [String] = tmuxSSHConnectionArguments()
    ) -> String {
        switch host {
        case .local:
            return localAttachCommand(
                tmuxPath: tmuxPath,
                kwtPath: kwtPath,
                workingDirectory: workingDirectory
            )
        case let .ssh(info):
            if info.platform == .windows {
                if launchMode == .create {
                    return remoteCreateThenAttachCommand(
                        info: info,
                        tmuxPath: tmuxPath,
                        workingDirectory: workingDirectory,
                        sshConnectionArguments: sshConnectionArguments
                    )
                }
                if protectedWorkspacePath == nil, workspacePath != nil {
                    return windowsRemoteWorkspaceAttachCommand(
                        info: info,
                        tmuxPath: tmuxPath,
                        sshConnectionArguments: sshConnectionArguments
                    )
                }
                return windowsRemoteAttachCommand(
                    info: info,
                    tmuxPath: tmuxPath,
                    sshConnectionArguments: sshConnectionArguments
                )
            }
            if launchMode == .create {
                return remoteCreateThenAttachCommand(
                    info: info,
                    tmuxPath: tmuxPath,
                    workingDirectory: workingDirectory,
                    sshConnectionArguments: sshConnectionArguments
                )
            }
            if protectedWorkspacePath == nil, workspacePath != nil {
                return remoteWorkspaceAttachCommand(
                    info: info,
                    tmuxPath: tmuxPath,
                    remoteKwtCommandPrelude: remoteKwtCommandPrelude,
                    sshConnectionArguments: sshConnectionArguments
                )
            }
            return remoteAttachCommand(
                info: info,
                tmuxPath: tmuxPath,
                remoteKwtCommandPrelude: remoteKwtCommandPrelude,
                sshConnectionArguments: sshConnectionArguments
            )
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
                        presentationSetupCommand(tmuxPath: tmuxPath)
                    )
                    commands.append("exec \(attach)")
                }
            }
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
        for (option, value) in presentationOptions {
            arguments += [
                ";", "set-option", "-t",
                presentationTarget, option, value,
            ]
        }
        for (option, value) in windowPresentationOptions {
            arguments += [
                ";", "set-option", "-w", "-t",
                presentationTarget, option, value,
            ]
        }
        return arguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
    }

    private var presentationTarget: String {
        // set-option parses a bare session name as a prefix target. The
        // trailing colon makes tmux interpret `=name:` as an exact session
        // target, so a disappeared "alpha" cannot style "alphabet".
        "=\(sessionName):"
    }

    private var presentationOptions: [(String, String)] {
        guard presentationStyle != nil else { return [] }
        return [
            ("status-style", "reverse"),
            ("message-style", "reverse"),
            ("message-command-style", "reverse"),
        ]
    }

    private var windowPresentationOptions: [(String, String)] {
        guard let presentationStyle else { return [] }
        return [
            ("window-style", presentationStyle.tmuxStyle),
            ("window-active-style", presentationStyle.tmuxStyle),
        ]
    }

    /// Tmux interaction remains user-owned. These style resets only make tmux
    /// chrome and terminal default-color queries resolve through the colors
    /// configured by Ghosthub.
    private func presentationSetupCommand(tmuxPath: String) -> String {
        guard presentationStyle != nil else { return ":" }
        var commands = presentationOptions.map { option, value in
            let command = tmuxArguments(
                tmuxPath,
                "set-option", "-t", presentationTarget, option, value
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            return "\(command) >/dev/null 2>&1 || :"
        }
        if !windowPresentationOptions.isEmpty {
            let listWindows = tmuxArguments(
                tmuxPath,
                "list-windows", "-t", presentationTarget,
                "-F", "#{window_id}"
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            let setWindowOptions = windowPresentationOptions.map {
                option, value in
                let commandPrefix = tmuxArguments(
                    tmuxPath,
                    "set-option", "-w", "-t"
                ).map(shellQuotedCommandArgument).joined(separator: " ")
                return "\(commandPrefix) \"$ghosthub_window\" "
                    + "\(shellQuotedCommandArgument(option)) "
                    + "\(shellQuotedCommandArgument(value)) "
                    + ">/dev/null 2>&1 || :"
            }.joined(separator: "; ")
            commands.append(
                "\(listWindows) 2>/dev/null | "
                    + "while IFS= read -r ghosthub_window; do "
                    + "\(setWindowOptions); done"
            )
        }
        return commands.joined(separator: "; ")
    }

    /// Kwt establishes or repairs the complete session before starting its
    /// tmux client. When Ghosthub owns presentation, run kwt as the foreground
    /// terminal's background child just long enough to identify that client,
    /// then style the finished session and wait on the same client process.
    /// This preserves kwt's atomic create-and-attach path under
    /// `destroy-unattached` while ensuring repair-created windows are included.
    private func kwtAttachWithPresentationCommand(
        _ kwtCommand: String,
        tmuxPath: String
    ) -> String {
        guard presentationStyle != nil else { return "exec \(kwtCommand)" }
        let listClients = tmuxArguments(
            tmuxPath,
            "list-clients", "-t", "=\(sessionName)",
            "-F", "#{client_pid}"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        return [
            "exec 3<&0",
            "ghosthub_existing_clients=\"$(\(listClients) 2>/dev/null)\"",
            "\(kwtCommand) <&3 3<&- & ghosthub_kwt_pid=$!",
            "ghosthub_kwt_client_ready=",
            "while kill -0 \"$ghosthub_kwt_pid\" 2>/dev/null; do "
                + "for ghosthub_client_pid in $(\(listClients) 2>/dev/null); "
                + "do ghosthub_client_was_existing=; "
                + "for ghosthub_existing_client_pid in "
                + "$ghosthub_existing_clients; do "
                + "if [ \"$ghosthub_existing_client_pid\" = "
                + "\"$ghosthub_client_pid\" ]; then "
                + "ghosthub_client_was_existing=1; break; fi; done; "
                + "if [ -z \"$ghosthub_client_was_existing\" ]; then "
                + "ghosthub_kwt_client_ready=1; break; fi; done; "
                + "[ -n \"$ghosthub_kwt_client_ready\" ] && break; "
                + "sleep 0.01; done",
            "if [ -n \"$ghosthub_kwt_client_ready\" ]; then "
                + "\(presentationSetupCommand(tmuxPath: tmuxPath)); fi",
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
        useAccountLoginShell: Bool = false
    ) -> String {
        if info.platform == .windows {
            return windowsRemoteAttachCommand(
                info: info,
                tmuxPath: tmuxPath,
                sshConnectionArguments: sshConnectionArguments
            )
        }
        let attach: String
        if let protectedWorkspacePath {
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
        if protectedWorkspacePath == nil {
            remoteAttachCommands.append(
                presentationSetupCommand(tmuxPath: tmuxPath)
            )
        }
        remoteAttachCommands.append(attach)
        let remoteAttachBody = remoteAttachCommands.joined(separator: "; ")
        let requiresAccountLoginShell =
            useAccountLoginShell
                || protectedWorkspacePath != nil
                || presentationStyle != nil
        let remoteAttach = requiresAccountLoginShell
            ? remoteAccountLoginShellCommand(remoteAttachBody)
            : remoteAttachBody
        return shellCommand(
            [
                "/bin/sh", "-c", Self.sshReconnectScript,
                "ghosthub-ssh-tmux",
            ] + sshArguments(
                info: info,
                allocateTTY: true,
                remoteCommand: remoteAttach,
                sshConnectionArguments: sshConnectionArguments
            )
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
                remoteCommand: remoteAccountLoginShellCommand(initialBody),
                sshConnectionArguments: sshConnectionArguments
            )
        )
        let reconnectAttach = remoteAttachCommand(
            info: info,
            tmuxPath: tmuxPath,
            remoteKwtCommandPrelude: nil,
            sshConnectionArguments: sshConnectionArguments,
            useAccountLoginShell: true
        )
        let hasSession = tmuxArguments(
            tmuxPath,
            "has-session", "-t", "=\(sessionName)"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        let remoteProbe = "unset TMUX TMUX_PANE; "
            + "exec \(hasSession) >/dev/null 2>&1"
        let sessionProbe = shellCommand(
            [
                "/bin/sh", "-c", Self.sshReconnectScript,
                "ghosthub-ssh-kwt-probe",
            ] + sshArguments(
                info: info,
                allocateTTY: false,
                remoteCommand: remoteAccountLoginShellCommand(remoteProbe),
                sshConnectionArguments: sshConnectionArguments
            )
        )
        return shellCommand([
            "/bin/sh", "-c", Self.remoteWorkspaceAttachScript,
            "ghosthub-ssh-kwt-attach",
            initialAttach, sessionProbe, reconnectAttach,
        ])
    }

    private func windowsRemoteWorkspaceAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        sshConnectionArguments: [String]
    ) -> String {
        guard let workspacePath else {
            return windowsRemoteAttachCommand(
                info: info,
                tmuxPath: tmuxPath,
                sshConnectionArguments: sshConnectionArguments
            )
        }
        let initialScript = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        Remove-Item Env:TMUX, Env:TMUX_PANE -ErrorAction SilentlyContinue
        \(powerShellKwtResolutionPrelude())
        & $ghosthubKwt 'open' \(powerShellQuotedCommandArgument(workspacePath))
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
        let probeScript = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        Remove-Item Env:TMUX, Env:TMUX_PANE -ErrorAction SilentlyContinue
        \(windowsMuxCommand(
            tmuxPath: tmuxPath,
            arguments: ["has-session", "-t", "=\(sessionName)"]
        )) *> $null
        exit $LASTEXITCODE
        """
        let sessionProbe = shellCommand(
            [
                "/bin/sh", "-c", Self.sshReconnectScript,
                "ghosthub-ssh-kwt-probe",
            ] + sshArguments(
                info: info,
                allocateTTY: false,
                remoteCommand: powerShellEncodedCommand(probeScript),
                sshConnectionArguments: sshConnectionArguments
            )
        )
        let reconnectAttach = windowsRemoteAttachCommand(
            info: info,
            tmuxPath: tmuxPath,
            sshConnectionArguments: sshConnectionArguments
        )
        return shellCommand([
            "/bin/sh", "-c", Self.remoteWorkspaceAttachScript,
            "ghosthub-ssh-kwt-attach",
            initialAttach, sessionProbe, reconnectAttach,
        ])
    }

    private func windowsRemoteAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        sshConnectionArguments: [String]
    ) -> String {
        let attach: String
        if let protectedWorkspacePath {
            attach = """
            \(powerShellKwtResolutionPrelude())
            & $ghosthubKwt 'pr' 'attach' \(powerShellQuotedCommandArgument(protectedWorkspacePath))
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
        return shellCommand(
            [
                "/bin/sh", "-c", Self.sshReconnectScript,
                "ghosthub-ssh-psmux",
            ] + sshArguments(
                info: info,
                allocateTTY: true,
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
        let remoteCreate: String
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
            sshConnectionArguments: sshConnectionArguments
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
            .map(powerShellQuotedCommandArgument)
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
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes",
            "-o", "ConnectTimeout=15",
        ]
        arguments.append(contentsOf: sshConnectionArguments)
        if let port = info.port, port != 22 {
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

    /// Runs creation once and, after success, permanently switches this
    /// terminal process to the attach-only reconnect command.
    static let remoteCreateThenAttachScript = """
    /bin/sh -c "$1"
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    exec /bin/sh -c "$2"
    """

    /// The first kwt client stays attached while it creates the workspace. An
    /// SSH transport loss probes the exact session through the ordinary retry
    /// loop: confirmed presence advances to attach-only reconnect, while
    /// confirmed absence retries kwt because the original SSH connection may
    /// have failed before the remote command ran. Absent-session retries use
    /// the same bounded backoff as ordinary SSH reconnects.
    static let remoteWorkspaceAttachScript = """
    delay=1
    while :; do
        started=$(date +%s)
        /bin/sh -c "$1"
        status=$?
        [ "$status" -eq 255 ] || exit "$status"
        /bin/sh -c "$2"
        status=$?
        case "$status" in
            0) exec /bin/sh -c "$3" ;;
            1)
                now=$(date +%s)
                if [ $((now - started)) -ge 30 ]; then delay=1; fi
                printf '\r\n[Ghosthub: workspace session absent; retrying in %ss]\r\n' "$delay"
                sleep "$delay"
                if [ "$delay" -lt 30 ]; then
                    delay=$((delay * 2))
                    [ "$delay" -le 30 ] || delay=30
                fi
                ;;
            *) exit "$status" ;;
        esac
    done
    """

    /// OpenSSH reserves status 255 for transport/setup failure. Clean detach
    /// and ordinary tmux failures pass through so Ghosthub does not fight an
    /// intentional detach or spin on a missing session.
    static let sshReconnectScript = """
    delay=1
    while :; do
        started=$(date +%s)
        "$@"
        status=$?
        [ "$status" -eq 255 ] || exit "$status"
        now=$(date +%s)
        if [ $((now - started)) -ge 30 ]; then delay=1; fi
        printf '\r\n[Ghosthub: SSH disconnected; reconnecting in %ss]\r\n' "$delay"
        sleep "$delay"
        if [ "$delay" -lt 30 ]; then
            delay=$((delay * 2))
            [ "$delay" -le 30 ] || delay=30
        fi
    done
    """
}
