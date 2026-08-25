import Foundation
import GhosthubTransport

/// Borrows a daemon-owned SSH connection for one bounded command group.
/// Remote callers receive only kwt-reviewed arguments and never construct a
/// second SSH route in Swift.
struct KwtSSHCommandLease: Sendable {
    typealias Acquirer = @Sendable (SSHHostInfo) async throws -> KwtSSHConnection

    private let acquire: Acquirer

    init(acquire: @escaping Acquirer) {
        self.acquire = acquire
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        acquire = { host in
            try await Self.acquireNoninteractive(
                host,
                environment: environment
            )
        }
    }

    /// An injected command transport already supplies its own SSH arguments.
    /// Keep those tests and custom runners independent of the daemon lease.
    static let injectedTransport = KwtSSHCommandLease { _ in
        KwtSSHConnection(
            arguments: [],
            routeIdentity: "injected-command-transport",
            generation: 0
        )
    }

    /// The daemon lease for production runners, or the injected transport
    /// when a caller supplied its own remote runner.
    static func unlessInjected(_ injected: Bool) -> KwtSSHCommandLease {
        injected ? .injectedTransport : KwtSSHCommandLease()
    }

    func acquire(on host: SSHHostInfo) async throws -> KwtSSHConnection {
        try await acquire(host)
    }

    func withArguments<Value: Sendable>(
        on host: CommandHost,
        operation: @escaping @Sendable ([String]?) async throws -> Value
    ) async throws -> Value {
        try await withConnection(on: host) { connection in
            try await operation(connection?.arguments)
        }
    }

    func withConnection<Value: Sendable>(
        on host: CommandHost,
        operation: @escaping @Sendable (KwtSSHConnection?) async throws -> Value
    ) async throws -> Value {
        guard case let .ssh(info) = host else {
            return try await operation(nil)
        }

        let connection = try await acquire(info)
        let value: Value
        do {
            value = try await operation(connection)
        } catch {
            try? await connection.release()
            throw error
        }
        try await connection.release()
        return value
    }

    /// Runs one blocking remote command off the cooperative pool with the
    /// borrowed arguments, and reports an unusable master back to the pool.
    func runCommand(
        on host: SSHHostInfo,
        command: @escaping @Sendable ([String]) -> AccountCommandOutput
    ) async throws -> AccountCommandOutput {
        try await withConnection(on: .ssh(host)) { connection in
            await runCommand(using: connection, command: command)
        }
    }

    /// Runs a command against a lease already owned by the caller while
    /// preserving the same dead-control-socket invalidation behavior.
    func runCommand(
        using connection: KwtSSHConnection?,
        command: @escaping @Sendable ([String]) -> AccountCommandOutput
    ) async -> AccountCommandOutput {
        let arguments = connection?.arguments ?? []
        let output = await BlockingTask.run(priority: .userInitiated) {
            command(arguments)
        }
        if SSHConnectionFailure.indicatesUnusableConnection(
            status: output.status,
            output: output.stderr
        ) {
            await connection?.invalidate()
        }
        return output
    }

    private static func acquireNoninteractive(
        _ host: SSHHostInfo,
        environment: [String: String]
    ) async throws -> KwtSSHConnection {
        let demoArguments = demoSSHIsolationArguments(environment: environment)
        if !demoArguments.isEmpty {
            return KwtSSHConnection(
                arguments: demoArguments,
                routeIdentity: SSHDestination.demoRouteIdentity(host),
                generation: 0
            )
        }
        let subscriberID = UUID()
        let request = KwtSSHDestinationRequest(
            destination: SSHDestination.render(host),
            host: host
        )
        return try await KwtSSHAcquisitionCoordinator.shared.acquire(
            request: request,
            subscriberID: subscriberID,
            canPresentPrompts: false,
            prompt: { _, _ in
                throw KwtSSHLeaseError.operationFailed(
                    code: "ssh_interaction_required",
                    message: "SSH authentication requires an active window.",
                    retryable: false
                )
            }
        )
    }

    static func scpArguments(from sshArguments: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(sshArguments.count)
        var index = 0
        while index < sshArguments.count {
            let argument = sshArguments[index]
            if argument == "-S", index + 1 < sshArguments.count {
                result.append("-o")
                result.append("ControlPath=\(sshArguments[index + 1])")
                index += 2
                continue
            }
            if argument == "-p", index + 1 < sshArguments.count {
                result.append("-P")
                result.append(sshArguments[index + 1])
                index += 2
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }
}
