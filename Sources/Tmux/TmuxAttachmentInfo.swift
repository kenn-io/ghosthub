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
    public let user: String?
    public let hostname: String
    public let port: Int?

    public init(user: String?, hostname: String, port: Int?) {
        self.user = user
        self.hostname = hostname
        self.port = port
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

/// An ordinary tmux client launched inside a libghostty terminal surface.
/// Tmux owns rendering, windows, panes, history, input, and process lifetime.
public struct TmuxAttachmentInfo: Equatable, Sendable {
    public let sessionName: String
    public let host: TmuxHost
    public let socketName: String?
    public let workspacePath: String?
    public let protectedWorkspacePath: String?
    public var launchMode: TmuxAttachmentLaunchMode

    public init(
        sessionName: String,
        host: TmuxHost,
        socketName: String? = nil,
        workspacePath: String? = nil,
        protectedWorkspacePath: String? = nil,
        launchMode: TmuxAttachmentLaunchMode = .attach
    ) {
        self.sessionName = sessionName
        self.host = host
        self.socketName = socketName
        self.workspacePath = workspacePath
        self.protectedWorkspacePath = protectedWorkspacePath
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
                commands.append(presentationSetupCommand(tmuxPath: tmuxPath))
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
                commands.append("exec \(protectedAttach)")
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
                    commands.append("exec \(openWorkspace)")
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
        [
            ("status-style", "reverse"),
            ("message-style", "reverse"),
            ("message-command-style", "reverse"),
        ]
    }

    /// Tmux behavior remains user-owned. These session-scoped style resets
    /// only make tmux chrome resolve through the foreground and background
    /// configured by Ghosthub.
    private func presentationSetupCommand(tmuxPath: String) -> String {
        presentationOptions.map { option, value in
            let command = tmuxArguments(
                tmuxPath,
                "set-option", "-t", presentationTarget, option, value
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            return "\(command) >/dev/null 2>&1 || :"
        }.joined(separator: "; ")
    }

    private func remoteAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        remoteKwtCommandPrelude: String?,
        sshConnectionArguments: [String],
        useAccountLoginShell: Bool = false
    ) -> String {
        let attach: String
        if let protectedWorkspacePath {
            let protectedAttach: String
            if let remoteKwtCommandPrelude {
                protectedAttach = remoteKwtCommandPrelude
                    + "exec \"$ghosthub_kwt_path\" 'pr' 'attach' "
                    + shellQuotedCommandArgument(protectedWorkspacePath)
            } else {
                protectedAttach =
                    "printf 'Ghosthub: managed kwt is unavailable\\n' >&2; "
                        + "exit 127"
            }
            attach = remoteAccountLoginShellCommand(protectedAttach)
        } else {
            let tmuxAttach = tmuxArguments(
                tmuxPath,
                "attach-session", "-E", "-t", "=\(sessionName)"
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            attach = "exec \(tmuxAttach)"
        }
        let remoteAttachBody = [
            "unset TMUX TMUX_PANE",
            presentationSetupCommand(tmuxPath: tmuxPath),
            attach,
        ].joined(separator: "; ")
        let remoteAttach = useAccountLoginShell
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
            remoteOpen = remoteKwtCommandPrelude
                + "exec \"$ghosthub_kwt_path\" 'open' "
                + shellQuotedCommandArgument(workspacePath)
        } else {
            remoteOpen =
                "printf 'Ghosthub: managed kwt is unavailable\\n' >&2; "
                    + "exit 127"
        }
        let initialAttach = shellCommand(
            sshArguments(
                info: info,
                allocateTTY: true,
                remoteCommand: remoteAccountLoginShellCommand(remoteOpen),
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

    private func remoteCreateThenAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        workingDirectory: String?,
        sshConnectionArguments: [String]
    ) -> String {
        let remoteCreate = "unset TMUX TMUX_PANE; "
            + createIfAbsentCommand(
                tmuxPath: tmuxPath,
                workingDirectory: workingDirectory
            )
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
