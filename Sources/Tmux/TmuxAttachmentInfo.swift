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
        if case .ssh = self { return true }
        return false
    }
}

public enum TmuxAttachmentLaunchMode: String, Codable, Equatable, Sendable {
    case attach
    case create
}

/// An ordinary tmux client launched inside a Ghostty terminal surface.
/// Tmux owns rendering, windows, panes, history, input, and process lifetime.
public struct TmuxAttachmentInfo: Equatable, Sendable {
    public let sessionName: String
    public let host: TmuxHost
    public var launchMode: TmuxAttachmentLaunchMode

    public init(
        sessionName: String,
        host: TmuxHost,
        launchMode: TmuxAttachmentLaunchMode = .attach
    ) {
        self.sessionName = sessionName
        self.host = host
        self.launchMode = launchMode
    }

    public func attachCommand(
        tmuxPath: String = "tmux",
        workingDirectory: String? = nil,
        sshConnectionArguments: [String] = tmuxSSHConnectionArguments()
    ) -> String {
        switch host {
        case .local:
            return localAttachCommand(
                tmuxPath: tmuxPath,
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
            return remoteAttachCommand(
                info: info,
                tmuxPath: tmuxPath,
                sshConnectionArguments: sshConnectionArguments
            )
        }
    }

    private func localAttachCommand(
        tmuxPath: String,
        workingDirectory: String?
    ) -> String {
        let attach = [
            tmuxPath, "attach-session", "-E", "-t", "=\(sessionName)",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        var commands = ["unset TMUX TMUX_PANE"]
        switch launchMode {
        case .attach:
            break
        case .create:
            commands.append(
                createIfAbsentCommand(
                    tmuxPath: tmuxPath,
                    workingDirectory: workingDirectory
                )
            )
        }
        commands.append(presentationSetupCommand(tmuxPath: tmuxPath))
        commands.append("exec \(attach)")
        return shellCommand([
            "/bin/sh", "-c", commands.joined(separator: "; "),
        ])
    }

    private func remoteAttachCommand(
        info: SSHHostInfo,
        tmuxPath: String,
        sshConnectionArguments: [String]
    ) -> String {
        let attach = [
            tmuxPath, "attach-session", "-E", "-t", "=\(sessionName)",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        let remoteAttach = [
            "unset TMUX TMUX_PANE",
            presentationSetupCommand(tmuxPath: tmuxPath),
            "exec \(attach)",
        ].joined(separator: "; ")
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
        let hasSession = [
            tmuxPath, "has-session", "-t", target,
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        let createSession = ([
            tmuxPath, "new-session", "-d", "-E", "-s", sessionName,
        ] + (workingDirectory.map { ["-c", $0] } ?? []))
            .map(shellQuotedCommandArgument).joined(separator: " ")
        return "\(hasSession) 2>/dev/null || "
            + "\(createSession) || \(hasSession)"
    }

    /// Tmux behavior remains user-owned. These session-scoped style resets
    /// only make tmux chrome resolve through the foreground and background
    /// configured by Ghosthub.
    private func presentationSetupCommand(tmuxPath: String) -> String {
        let options = [
            ("status-style", "default"),
            ("message-style", "reverse"),
            ("message-command-style", "reverse"),
        ]
        return options.map { option, value in
            let command = [
                tmuxPath, "set-option", "-t", sessionName, option, value,
            ].map(shellQuotedCommandArgument).joined(separator: " ")
            return "\(command) >/dev/null 2>&1 || :"
        }.joined(separator: "; ")
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

    /// Runs creation once and, after success, permanently switches this
    /// terminal process to the attach-only reconnect command.
    static let remoteCreateThenAttachScript = """
    /bin/sh -c "$1"
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    exec /bin/sh -c "$2"
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
