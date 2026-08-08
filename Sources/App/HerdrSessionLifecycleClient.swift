import Foundation
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace

struct HerdrSessionLifecycleClient: Sendable {
    typealias ConnectionArgumentsProvider = @Sendable (SSHHostInfo) -> [String]

    private let commandRunner: AccountCommandRunner
    private let connectionArgumentsProvider: ConnectionArgumentsProvider
    private let processTimeout: TimeInterval

    init(
        commandRunner: AccountCommandRunner = AccountCommandRunner(),
        connectionArgumentsProvider: @escaping ConnectionArgumentsProvider = {
            host in
            SSHConnectionPool.connectionArguments(for: host)
                + SSHConfigurationResolver.noninteractiveHostKeyArguments(
                    for: host
                )
        },
        processTimeout: TimeInterval = 15
    ) {
        self.commandRunner = commandRunner
        self.connectionArgumentsProvider = connectionArgumentsProvider
        self.processTimeout = processTimeout
    }

    func record(
        named name: String,
        on host: CommandHost
    ) -> Result<HerdrSessionRecord, HerdrSessionLifecycleError> {
        switch resolvedExecutable(on: host) {
        case let .success(path):
            return record(named: name, on: host, herdrPath: path)
        case let .failure(error):
            return .failure(error)
        }
    }

    func stop(
        _ confirmed: HerdrSessionRecord,
        on host: CommandHost
    ) -> Result<HerdrSessionRecord, HerdrSessionLifecycleError> {
        mutate(.stop, confirmed: confirmed, expected: .running, on: host)
    }

    func delete(
        _ confirmed: HerdrSessionRecord,
        on host: CommandHost
    ) -> Result<HerdrSessionRecord, HerdrSessionLifecycleError> {
        guard !confirmed.isDefault else {
            return .failure(.defaultSessionCannotBeDeleted)
        }
        return mutate(.delete, confirmed: confirmed, expected: .stopped, on: host)
    }

    private func mutate(
        _ action: HerdrSessionLifecycleAction,
        confirmed: HerdrSessionRecord,
        expected: HerdrSessionState,
        on host: CommandHost
    ) -> Result<HerdrSessionRecord, HerdrSessionLifecycleError> {
        guard confirmed.state == expected else {
            return .failure(.stateChanged(
                name: confirmed.name,
                expected: expected
            ))
        }
        let herdrPath: String
        switch resolvedExecutable(on: host) {
        case let .success(path): herdrPath = path
        case let .failure(error): return .failure(error)
        }
        let current: HerdrSessionRecord
        switch record(
            named: confirmed.name,
            on: host,
            herdrPath: herdrPath
        ) {
        case let .success(record): current = record
        case let .failure(error): return .failure(error)
        }
        guard current.state == expected else {
            return .failure(.stateChanged(
                name: confirmed.name,
                expected: expected
            ))
        }
        guard current.sessionDirectory == confirmed.sessionDirectory,
              current.socketPath == confirmed.socketPath
        else { return .failure(.locationChanged(confirmed.name)) }

        let output = run(HerdrSessionLifecycle.command(
            action: action,
            name: confirmed.name,
            herdrPath: herdrPath
        ), on: host)
        return HerdrSessionLifecycle.parse(
            action: action,
            status: output.status,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }

    private func record(
        named name: String,
        on host: CommandHost,
        herdrPath: String
    ) -> Result<HerdrSessionRecord, HerdrSessionLifecycleError> {
        let output = run(
            HerdrSessionList.command(herdrPath: herdrPath),
            on: host
        )
        switch HerdrSessionList.parseRecords(
            status: output.status,
            stdout: output.stdout,
            stderr: output.stderr
        ) {
        case let .success(records):
            guard let record = records.first(where: { $0.name == name }) else {
                return .failure(.sessionMissing(name))
            }
            return .success(record)
        case let .failure(error):
            return .failure(lifecycleError(error))
        }
    }

    private func resolvedExecutable(
        on host: CommandHost
    ) -> Result<String, HerdrSessionLifecycleError> {
        guard supportsHerdr(host) else {
            return .failure(.unsupportedPlatform)
        }
        let output = run(HerdrExecutable.command(), on: host)
        switch HerdrExecutable.parse(
            status: output.status,
            stdout: output.stdout,
            stderr: output.stderr
        ) {
        case let .available(path): return .success(path)
        case .unavailable: return .failure(.unavailable)
        case let .failure(error): return .failure(lifecycleError(error))
        }
    }

    private func lifecycleError(
        _ error: HerdrCommandError
    ) -> HerdrSessionLifecycleError {
        switch error {
        case .unavailable: .unavailable
        case .unsupportedPlatform: .unsupportedPlatform
        case let .commandFailed(status, stderr):
            status == 127
                ? .unavailable
                : .commandFailed(
                    status: status,
                    code: nil,
                    message: stderr
                )
        case .missingMarker: .missingMarker
        case .malformedJSON: .malformedJSON
        case let .cancelled(host): .commandFailed(
                status: AccountCommandRunner.cancelledStatus,
                code: nil,
                message: "Stopped checking Herdr sessions on \(host)."
            )
        }
    }

    private func supportsHerdr(_ host: CommandHost) -> Bool {
        switch host {
        case .local: true
        case let .ssh(info): info.platform == .posix
        }
    }

    private func run(
        _ command: String,
        on host: CommandHost
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
                connectionArguments: connectionArgumentsProvider(info),
                command: command,
                timeout: processTimeout
            )
        }
    }
}
