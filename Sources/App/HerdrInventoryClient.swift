import Foundation
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace

struct HerdrInventoryClient: Sendable {
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
        sshConnectionArguments: [String]? = nil,
        backend: HerdrBackend = .tui
    ) -> Result<String, HerdrCommandError> {
        guard supportsHerdr(host) else {
            return .failure(.unsupportedPlatform)
        }
        let output = run(
            HerdrExecutable.command(backend: backend),
            on: host,
            sshConnectionArguments: sshConnectionArguments
        )
        switch HerdrExecutable.parse(
            status: output.status,
            stdout: output.stdout,
            stderr: output.stderr,
            backend: backend
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
    func discover(on host: CommandHost) async -> HerdrDiscoveryResult {
        guard supportsHerdr(host) else { return .unavailable }
        do {
            return try await commandLease.withConnection(on: host) {
                connection in
                let result = await BlockingTask.run {
                    discover(
                        on: host,
                        sshConnectionArguments: connection?.arguments
                    )
                }
                let error: HerdrCommandError?
                switch result {
                case let .failure(failure): error = failure
                case let .available(_, _, failures): error = failures[.core] ?? failures[.tui]
                case .unavailable: error = nil
                }
                if case let .commandFailed(status, stderr) = error,
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
    ) -> HerdrDiscoveryResult {
        guard supportsHerdr(host) else { return .unavailable }
        let tui = discover(on: host, sshConnectionArguments: sshConnectionArguments, backend: .tui)
        let core = discover(
            on: host,
            sshConnectionArguments: sshConnectionArguments,
            backend: .core
        )
        var sessions: [HerdrSessionSummary] = []
        var available = false
        var tuiAvailable = false
        var failures: [HerdrBackend: HerdrCommandError] = [:]
        for (backend, result) in [(HerdrBackend.tui, tui), (.core, core)] {
            switch result {
            case let .available(found, _, _):
                available = true
                tuiAvailable = tuiAvailable || backend == .tui
                sessions += found
            case let .failure(error):
                failures[backend] = error
            case .unavailable:
                break
            }
        }
        if available {
            return .available(sessions, tuiAvailable: tuiAvailable, failures: failures)
        }
        return (failures[.core] ?? failures[.tui]).map(HerdrDiscoveryResult.failure) ?? .unavailable
    }

    func discover(
        on host: CommandHost,
        sshConnectionArguments: [String]?,
        backend: HerdrBackend
    ) -> HerdrDiscoveryResult {
        guard supportsHerdr(host) else { return .unavailable }
        let herdrPath: String
        switch resolveExecutable(
            on: host,
            sshConnectionArguments: sshConnectionArguments,
            backend: backend
        ) {
        case let .success(path):
            herdrPath = path
        case .failure(.unavailable), .failure(.unsupportedPlatform):
            return .unavailable
        case let .failure(error):
            return .failure(error)
        }

        let output = run(
            backend == .tui
                ? HerdrSessionList.command(herdrPath: herdrPath)
                : HerdrCoreInventory.command(executable: herdrPath),
            on: host,
            sshConnectionArguments: sshConnectionArguments
        )
        let parse = backend == .tui ? HerdrSessionList.parse : HerdrCoreInventory.parse
        return parse(output.status, output.stdout, output.stderr)
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
