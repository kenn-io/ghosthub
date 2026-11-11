import Foundation
import GhosthubBackendTerminal
import GhosthubTransport
import GhosthubWorkspace

/// Lists and resolves backend terminals (Herdr Core and Rex) on a host.
/// Rex goes through the host's pinned kwt; Herdr Core through `herdr-core`
/// in the account's login environment.
struct BackendTerminalInventoryClient: Sendable {
    typealias ConnectionArgumentsProvider = @Sendable (SSHHostInfo) -> [String]

    private let commandRunner: AccountCommandRunner
    private let commandLease: KwtSSHCommandLease
    private let processTimeout: TimeInterval
    private let localKwtPath: String?
    private let remoteKwtRevision: String?

    init(
        commandRunner: AccountCommandRunner = AccountCommandRunner(),
        processTimeout: TimeInterval = 15,
        localKwtPath: String? = KwtBinaryLocator.bundledPath(),
        remoteKwtRevision: String? = KwtBinaryLocator.bundledRemoteRevision()
    ) {
        self.commandRunner = commandRunner
        commandLease = KwtSSHCommandLease()
        self.processTimeout = processTimeout
        self.localKwtPath = localKwtPath
        self.remoteKwtRevision = remoteKwtRevision
    }

    /// Uses caller-supplied SSH arguments instead of borrowing a kwt lease.
    init(
        commandRunner: AccountCommandRunner = AccountCommandRunner(),
        connectionArgumentsProvider: @escaping ConnectionArgumentsProvider,
        processTimeout: TimeInterval = 15,
        localKwtPath: String? = KwtBinaryLocator.bundledPath(),
        remoteKwtRevision: String? = KwtBinaryLocator.bundledRemoteRevision()
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
        self.localKwtPath = localKwtPath
        self.remoteKwtRevision = remoteKwtRevision
    }

    static func supports(_ host: CommandHost) -> Bool {
        switch host {
        case .local: true
        case let .ssh(info): info.platform == .posix
        }
    }

    /// Lists every backend's terminals through one borrowed kwt lease for a
    /// remote host. One backend's failure leaves the others' results.
    func discover(
        on host: CommandHost
    ) async -> [BackendTerminalKind: BackendTerminalDiscoveryResult] {
        guard Self.supports(host) else { return [:] }
        do {
            return try await commandLease.withConnection(on: host) { connection in
                let results = await BlockingTask.run {
                    Dictionary(uniqueKeysWithValues: BackendTerminalKind.allCases.map {
                        ($0, discover($0, on: host, sshConnectionArguments: connection?.arguments))
                    })
                }
                for result in results.values {
                    if case let .failure(.commandFailed(_, status, stderr)) = result,
                       SSHConnectionFailure.indicatesUnusableConnection(
                           status: status,
                           output: stderr
                       ) {
                        await connection?.invalidate()
                        break
                    }
                }
                return results
            }
        } catch {
            return Dictionary(uniqueKeysWithValues: BackendTerminalKind.allCases.map {
                ($0, .failure(.commandFailed($0, status: 255, stderr: error.localizedDescription)))
            })
        }
    }

    func discover(
        _ kind: BackendTerminalKind,
        on host: CommandHost,
        sshConnectionArguments: [String]?
    ) -> BackendTerminalDiscoveryResult {
        guard Self.supports(host) else { return .unavailable }
        switch kind {
        case .herdrCore:
            let path: String
            switch resolveExecutable(
                .herdrCore,
                on: host,
                sshConnectionArguments: sshConnectionArguments
            ) {
            case let .success(found):
                path = found
            case .failure(.unavailable), .failure(.unsupportedPlatform):
                return .unavailable
            case let .failure(error):
                return .failure(error)
            }
            let output = run(
                HerdrCoreInventory.command(executable: path),
                on: host,
                sshConnectionArguments: sshConnectionArguments
            )
            return HerdrCoreInventory.parse(
                status: output.status, stdout: output.stdout, stderr: output.stderr
            )
        case .rex:
            let output = run(
                RexInventory.command(kwtPrelude: kwtPrelude(for: host)),
                on: host,
                sshConnectionArguments: sshConnectionArguments
            )
            return RexInventory.parse(
                status: output.status, stdout: output.stdout, stderr: output.stderr
            )
        }
    }

    /// The absolute path of the program that attaches to `kind`'s terminals.
    func resolveExecutable(
        _ kind: BackendTerminalKind,
        on host: CommandHost,
        sshConnectionArguments: [String]? = nil
    ) -> Result<String, BackendTerminalCommandError> {
        guard Self.supports(host) else {
            return .failure(.unsupportedPlatform(kind))
        }
        let (command, marker) = switch kind {
        case .herdrCore:
            (HerdrCoreInventory.executableCommand, HerdrCoreInventory.pathMarker)
        case .rex:
            (
                RexInventory.executableCommand(kwtPrelude: kwtPrelude(for: host)),
                RexInventory.pathMarker
            )
        }
        let output = run(command, on: host, sshConnectionArguments: sshConnectionArguments)
        if output.status == 127 {
            return .failure(.unavailable(kind))
        }
        guard output.status == 0 else {
            return .failure(.commandFailed(kind, status: output.status, stderr: output.stderr))
        }
        let lines = output.stdout.components(separatedBy: "\n")
        guard let index = lines.lastIndex(of: marker), lines.indices.contains(index + 1) else {
            return .failure(.unavailable(kind))
        }
        let path = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            return .failure(.unavailable(kind))
        }
        return .success(path)
    }

    private func kwtPrelude(for host: CommandHost) -> String {
        switch host {
        case .local: KwtBinaryLocator.commandPrelude(exactPath: localKwtPath)
        case .ssh: KwtBinaryLocator.remoteCommandPrelude(revision: remoteKwtRevision)
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
