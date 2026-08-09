import GhosthubTransport

public enum HerdrAttachmentLaunchMode: Equatable, Sendable {
    case attachExisting
    case launchOrAttach
}

public struct HerdrAttachmentInfo: Equatable, Sendable {
    public let sessionName: String
    public let isDefault: Bool
    public let host: CommandHost

    public init(
        sessionName: String,
        isDefault: Bool,
        host: CommandHost
    ) {
        self.sessionName = sessionName
        self.isDefault = isDefault
        self.host = host
    }

    public func attachCommand(
        herdrPath: String,
        launchMode: HerdrAttachmentLaunchMode = .attachExisting,
        sshConnectionArguments: [String] = [],
        remoteExitStatusPath: String? = nil
    ) throws -> String {
        let attach = localAttachCommand(
            herdrPath: herdrPath,
            launchMode: launchMode
        )
        switch host {
        case .local:
            return attach
        case let .ssh(info):
            guard info.platform == .posix else {
                throw HerdrCommandError.unsupportedPlatform
            }
            let remoteAttach = accountLoginShellCommand(attach)
            let sshAttach = shellCommand(
                [
                    "/bin/sh", "-c", Self.sshAttachScript,
                    "ghosthub-ssh-herdr",
                ] + sshArguments(
                    info: info,
                    remoteCommand: remoteAttach,
                    sshConnectionArguments: sshConnectionArguments
                )
            )
            let recordedCommand: String
            if let remoteExitStatusPath, !remoteExitStatusPath.isEmpty {
                recordedCommand = shellCommand([
                    "/bin/sh", "-c", Self.remoteExitStatusScript,
                    "ghosthub-ssh-status", remoteExitStatusPath, sshAttach,
                ])
            } else {
                recordedCommand = sshAttach
            }
            return surfaceAccountLoginShellCommand(recordedCommand)
        }
    }

    private func localAttachCommand(
        herdrPath: String,
        launchMode: HerdrAttachmentLaunchMode
    ) -> String {
        let arguments: [String] = switch launchMode {
        case .attachExisting:
            [herdrPath, "session", "attach", sessionName]
        case .launchOrAttach where isDefault:
            [herdrPath]
        case .launchOrAttach:
            [herdrPath, "--session", sessionName]
        }
        let invocation = arguments.map(shellQuotedCommandArgument)
            .joined(separator: " ")
        return shellCommand([
            "/bin/sh", "-c",
            "\(HerdrEnvironment.unsetCommand); exec \(invocation)",
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
        let destination = info.user.map { "\($0)@\(info.hostname)" }
            ?? info.hostname
        arguments.append(contentsOf: ["--", destination, remoteCommand])
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
