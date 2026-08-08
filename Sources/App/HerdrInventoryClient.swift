import Foundation
import GhosthubHerdr
import GhosthubTransport

struct HerdrInventoryClient: Sendable {
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
        on host: CommandHost
    ) -> Result<String, HerdrCommandError> {
        guard supportsHerdr(host) else {
            return .failure(.unsupportedPlatform)
        }
        let output = run(HerdrExecutable.command(), on: host)
        switch HerdrExecutable.parse(
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

    func discover(on host: CommandHost) -> HerdrDiscoveryResult {
        let herdrPath: String
        switch resolveExecutable(on: host) {
        case let .success(path):
            herdrPath = path
        case .failure(.unavailable), .failure(.unsupportedPlatform):
            return .unavailable
        case let .failure(error):
            return .failure(error)
        }

        let output = run(
            HerdrSessionList.command(herdrPath: herdrPath),
            on: host
        )
        return HerdrSessionList.parse(
            status: output.status,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }

    func paneSplitCapability(
        on host: CommandHost,
        herdrPath: String,
        sessionName: String,
        sshConnectionArguments: [String]
    ) -> Result<HerdrPaneSplitCapability?, HerdrCommandError> {
        guard supportsHerdr(host) else {
            return .failure(.unsupportedPlatform)
        }
        let output = run(
            HerdrPaneSplitCapabilityProbe.command(herdrPath: herdrPath),
            on: host,
            sshConnectionArguments: sshConnectionArguments
        )
        return HerdrPaneSplitCapabilityProbe.parse(
            status: output.status,
            stdout: output.stdout,
            stderr: output.stderr,
            sessionName: sessionName
        )
    }

    private func supportsHerdr(_ host: CommandHost) -> Bool {
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
