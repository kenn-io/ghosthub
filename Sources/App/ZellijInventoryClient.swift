import Foundation
import GhosthubTransport
import GhosthubZellij

struct ZellijInventoryClient: Sendable {
    typealias ConnectionArgumentsProvider = @Sendable (SSHHostInfo) -> [String]

    private let commandRunner: AccountCommandRunner
    private let connectionArgumentsProvider: ConnectionArgumentsProvider
    private let processTimeout: TimeInterval

    init(
        commandRunner: AccountCommandRunner = AccountCommandRunner(),
        connectionArgumentsProvider: @escaping ConnectionArgumentsProvider = {
            SSHCommandArguments.noninteractive(for: $0)
        },
        processTimeout: TimeInterval = 15
    ) {
        self.commandRunner = commandRunner
        self.connectionArgumentsProvider = connectionArgumentsProvider
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

    func discover(
        on host: CommandHost,
        sshConnectionArguments: [String]? = nil
    ) -> ZellijDiscoveryResult {
        guard supportsZellij(host) else { return .unavailable }
        let connectionArguments = resolvedConnectionArguments(
            on: host,
            override: sshConnectionArguments
        )
        let zellijPath: String
        switch resolveExecutable(
            on: host,
            sshConnectionArguments: connectionArguments
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
            sshConnectionArguments: connectionArguments
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
        sshConnectionArguments: [String]? = nil
    ) -> Result<Void, ZellijCommandError> {
        let connectionArguments = resolvedConnectionArguments(
            on: host,
            override: sshConnectionArguments
        )
        let zellijPath: String
        switch resolveExecutable(
            on: host,
            sshConnectionArguments: connectionArguments
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
            sshConnectionArguments: connectionArguments
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

    private func resolvedConnectionArguments(
        on host: CommandHost,
        override: [String]?
    ) -> [String]? {
        if let override {
            return override
        }
        guard case let .ssh(info) = host else { return nil }
        return connectionArgumentsProvider(info)
    }

    private func run(
        _ command: String,
        on host: CommandHost,
        sshConnectionArguments: [String]? = nil
    ) -> AccountCommandOutput {
        switch host {
        case .local:
            commandRunner.runLocalLoginShell(
                command: command,
                timeout: processTimeout
            )
        case let .ssh(info):
            commandRunner.runRemoteLoginShell(
                host: info,
                connectionArguments: sshConnectionArguments
                    ?? connectionArgumentsProvider(info),
                command: command,
                timeout: processTimeout
            )
        }
    }
}
