import Foundation
import GhosthubTransport
import GhosthubZellij

struct ZellijInventoryClient: Sendable {
    typealias ConnectionArgumentsProvider = @Sendable (SSHHostInfo) -> [String]

    private let commandRunner: AccountCommandRunner
    private let commandLease: KwtSSHCommandLease
    private let processTimeout: TimeInterval

    init(
        commandRunner: AccountCommandRunner = AccountCommandRunner(),
        processTimeout: TimeInterval = 15
    ) {
        self.commandRunner = commandRunner
        commandLease = KwtSSHCommandLease()
        self.processTimeout = processTimeout
    }

    /// Uses caller-supplied SSH arguments instead of borrowing a kwt lease.
    init(
        commandRunner: AccountCommandRunner = AccountCommandRunner(),
        connectionArgumentsProvider: @escaping ConnectionArgumentsProvider,
        processTimeout: TimeInterval = 15
    ) {
        self.commandRunner = commandRunner
        commandLease = KwtSSHCommandLease { host in
            KwtSSHConnection(
                arguments: connectionArgumentsProvider(host),
                routeIdentity: "injected-command-transport",
                generation: 0
            )
        }
        self.processTimeout = processTimeout
    }

    func resolveExecutable(
        on host: CommandHost,
        sshConnectionArguments: [String]? = nil
    ) -> Result<String, ZellijCommandError> {
        guard supportsZellij(host) else {
            return .failure(.unsupportedPlatform)
        }
        let output = run(
            ZellijExecutable.command(),
            on: host,
            sshConnectionArguments: sshConnectionArguments
        )
        switch ZellijExecutable.parse(
            status: output.status,
            stdout: output.stdout,
            stderr: output.stderr
        ) {
        case let .available(path):
            return .success(path)
        case .unavailable:
            return .failure(.unavailable)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Discovers sessions through one borrowed kwt lease for remote hosts.
    func discover(on host: CommandHost) async -> ZellijDiscoveryResult {
        guard supportsZellij(host) else { return .unavailable }
        do {
            return try await commandLease.withConnection(on: host) {
                connection in
                let result = await BlockingTask.run {
                    discover(
                        on: host,
                        sshConnectionArguments: connection?.arguments
                    )
                }
                if case let .failure(.commandFailed(status, stderr)) = result,
                   SSHConnectionFailure.indicatesUnusableConnection(
                       status: status,
                       output: stderr
                   ) {
                    await connection?.invalidate()
                }
                return result
            }
        } catch {
            return .failure(.commandFailed(
                status: 255,
                stderr: error.localizedDescription
            ))
        }
    }

    func discover(
        on host: CommandHost,
        sshConnectionArguments: [String]?
    ) -> ZellijDiscoveryResult {
        guard supportsZellij(host) else { return .unavailable }
        let zellijPath: String
        switch resolveExecutable(
            on: host,
            sshConnectionArguments: sshConnectionArguments
        ) {
        case let .success(path):
            zellijPath = path
        case .failure(.unavailable), .failure(.unsupportedPlatform):
            return .unavailable
        case let .failure(error):
            return .failure(error)
        }
        let output = run(
            ZellijSessionList.command(zellijPath: zellijPath),
            on: host,
            sshConnectionArguments: sshConnectionArguments
        )
        return ZellijSessionList.parse(
            status: output.status,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }

    func kill(
        sessionName: String,
        on host: CommandHost,
        sshConnectionArguments: [String]?
    ) -> Result<Void, ZellijCommandError> {
        let zellijPath: String
        switch resolveExecutable(
            on: host,
            sshConnectionArguments: sshConnectionArguments
        ) {
        case let .success(path):
            zellijPath = path
        case let .failure(error):
            return .failure(error)
        }
        let output = run(
            ZellijSessionLifecycle.killCommand(
                zellijPath: zellijPath,
                sessionName: sessionName
            ),
            on: host,
            sshConnectionArguments: sshConnectionArguments
        )
        guard output.status == 0 else {
            return .failure(.commandFailed(
                status: output.status,
                stderr: output.stderr
            ))
        }
        return .success(())
    }

    private func supportsZellij(_ host: CommandHost) -> Bool {
        switch host {
        case .local:
            true
        case let .ssh(info):
            info.platform == .posix
        }
    }

    private func run(
        _ command: String,
        on host: CommandHost,
        sshConnectionArguments: [String]?
    ) -> AccountCommandOutput {
        switch host {
        case .local:
            return commandRunner.runLocalLoginShell(
                command: command,
                timeout: processTimeout
            )
        case let .ssh(info):
            guard let sshConnectionArguments else {
                return .leaseRequired
            }
            return commandRunner.runRemoteLoginShell(
                host: info,
                connectionArguments: sshConnectionArguments,
                command: command,
                timeout: processTimeout,
                retryPolicy: .idempotent
            )
        }
    }
}
