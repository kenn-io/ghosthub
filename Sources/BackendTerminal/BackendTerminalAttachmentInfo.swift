import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace

/// Builds the ordinary client command that shows one backend terminal in a
/// libghostty surface: `herdr-core attach ADDRESS` or
/// `kwt rex attach BLOCK_ID`. Closing the surface detaches; the backend
/// keeps the terminal running.
public struct BackendTerminalAttachmentInfo: Equatable, Sendable {
    public let terminal: BackendTerminalSummary
    public let host: CommandHost

    public init(terminal: BackendTerminalSummary, host: CommandHost) {
        self.terminal = terminal
        self.host = host
    }

    /// `executablePath` is the resolved `herdr-core` for Herdr Core, or the
    /// host's pinned kwt for Rex.
    public func attachCommand(
        executablePath: String,
        sshConnectionArguments: [String] = [],
        remoteExitStatusPath: String? = nil
    ) throws -> String {
        let attach = try localAttachCommand(executablePath: executablePath)
        switch host {
        case .local:
            switch terminal.kind {
            case .herdrCore:
                return attach
            case .rex:
                // Rex for Mac may put its CLI only on the login shell's PATH.
                return surfaceAccountLoginShellCommand(attach)
            }
        case let .ssh(info):
            guard info.platform == .posix else {
                throw BackendTerminalCommandError.unsupportedPlatform(terminal.kind)
            }
            let sshAttach = shellCommand(
                [
                    "/bin/sh", "-c", Self.sshAttachScript,
                    "ghosthub-ssh-\(terminal.kind.rawValue)",
                ] + sshArguments(
                    info: info,
                    remoteCommand: accountLoginShellCommand(attach),
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

    private func localAttachCommand(executablePath: String) throws -> String {
        let arguments: [String]
        let prefix: String
        switch terminal.kind {
        case .herdrCore:
            arguments = [executablePath, "attach", terminal.address]
            prefix = HerdrEnvironment.unsetCommand + "; "
        case .rex:
            guard RexInventory.isBlockID(terminal.address) else {
                throw BackendTerminalCommandError.invalidAddress(
                    .rex, address: terminal.address
                )
            }
            arguments = [executablePath, "rex", "attach", terminal.address]
            prefix = ""
        }
        let invocation = arguments.map(shellQuotedCommandArgument)
            .joined(separator: " ")
        return shellCommand(["/bin/sh", "-c", "\(prefix)exec \(invocation)"])
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
