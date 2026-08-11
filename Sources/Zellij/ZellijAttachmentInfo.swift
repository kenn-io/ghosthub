import GhosthubTransport

public enum ZellijAttachmentLaunchMode: Equatable, Sendable {
    case attachExisting
    case create
}

public struct ZellijAttachmentInfo: Equatable, Sendable {
    public let sessionName: String
    public let host: CommandHost

    public init(sessionName: String, host: CommandHost) {
        self.sessionName = sessionName
        self.host = host
    }

    public func attachCommand(
        zellijPath: String,
        launchMode: ZellijAttachmentLaunchMode = .attachExisting,
        sshConnectionArguments: [String] = [],
        remoteExitStatusPath: String? = nil
    ) throws -> String {
        let attach = localAttachCommand(
            zellijPath: zellijPath,
            launchMode: launchMode
        )
        switch host {
        case .local:
            return attach
        case let .ssh(info):
            guard info.platform == .posix else {
                throw ZellijCommandError.unsupportedPlatform
            }
            let remoteAttach = accountLoginShellCommand(attach)
            let sshAttach = shellCommand(
                [
                    "/bin/sh", "-c", Self.sshAttachScript,
                    "ghosthub-ssh-zellij",
                ] + sshArguments(
                    info: info,
                    remoteCommand: remoteAttach,
                    sshConnectionArguments: sshConnectionArguments
                )
            )
            guard let remoteExitStatusPath, !remoteExitStatusPath.isEmpty else {
                return surfaceAccountLoginShellCommand(sshAttach)
            }
            return surfaceAccountLoginShellCommand(shellCommand([
                "/bin/sh", "-c", Self.remoteExitStatusScript,
                "ghosthub-ssh-status", remoteExitStatusPath, sshAttach,
            ]))
        }
    }

    private func localAttachCommand(
        zellijPath: String,
        launchMode: ZellijAttachmentLaunchMode
    ) -> String {
        let arguments: [String]
        switch launchMode {
        case .attachExisting:
            // Zellij has no atomic active-only client command. Callers must
            // validate active inventory first; the scene-wide kill fence
            // prevents Ghosthub reconnects from racing a confirmed kill.
            arguments = [zellijPath, "attach", "--", sessionName]
        case .create:
            arguments = [zellijPath, "--session=\(sessionName)"]
        }
        let invocation = arguments.map(shellQuotedCommandArgument)
            .joined(separator: " ")
        return shellCommand([
            "/bin/sh", "-c",
            "\(ZellijEnvironment.unsetCommand); exec \(invocation)",
        ])
    }

    private func sshArguments(
        info: SSHHostInfo,
        remoteCommand: String,
        sshConnectionArguments: [String]
    ) -> [String] {
        var arguments = [
            "/usr/bin/ssh", "-tt",
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
        arguments.append(contentsOf: [
            "--",
            info.user.map { "\($0)@\(info.hostname)" } ?? info.hostname,
            remoteCommand,
        ])
        return arguments
    }

    private func shellCommand(_ arguments: [String]) -> String {
        arguments.map(shellQuotedCommandArgument).joined(separator: " ")
    }

    static let remoteExitStatusScript = """
    /bin/sh -c "$2"
    ghosthub_status=$?
    printf '%s\\n' "$ghosthub_status" > "$1"
    exit "$ghosthub_status"
    """

    static let sshAttachScript = "exec \"$@\""
}
