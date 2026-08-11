import GhosthubTransport
import Foundation
import GhosthubTmux

enum KwtProjectCommandError: Error, Equatable, LocalizedError {
    case invalidProjectPath
    case commandFailed(
        host: String,
        status: Int32,
        code: String?,
        message: String?,
        retryable: Bool
    )
    case malformedOutput(host: String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectPath:
            return "Enter an absolute project path beginning with /."
        case let .commandFailed(
            host,
            status,
            _,
            message,
            retryable
        ):
            let detail = message
                ?? "kwt exited with status \(status) on \(host)."
            return retryable ? "\(detail) Try again." : detail
        case let .malformedOutput(host):
            return "kwt returned an invalid project response on \(host)."
        }
    }
}

/// Mutates kwt's project registry through its supported machine-readable
/// boundary. Ghosthub never edits kwt configuration or scans the host.
struct KwtProjectRegistryClient: Sendable {
    typealias LocalRunner = @Sendable (
        _ command: String
    ) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ command: String
    ) -> (status: Int32, stdout: String)

    private enum Operation: String {
        case register = "add"
        case unregister = "remove"

        var successStatus: String {
            switch self {
            case .register: "registered"
            case .unregister: "unregistered"
            }
        }
    }

    private static let jsonMarker =
        "GHOSTHUB_KWT_PROJECT_JSON\n"
    private let localRunner: LocalRunner
    private let remoteRunner: RemoteRunner
    private let localBinaryPath: String?
    private let remoteBinaryRevision: String?

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 30,
        localBinaryPath: String? = KwtBinaryLocator.bundledPath(),
        remoteBinaryRevision: String? =
            KwtBinaryLocator.bundledRemoteRevision(),
        loginShellProvider: @escaping @Sendable () -> String =
            AccountCommandRunner.loginShell
    ) {
        self.localRunner = localRunner ?? { command in
            AccountCommandRunner.runLoginShell(
                shell: loginShellProvider(),
                command: command,
                timeout: processTimeout
            )
        }
        self.remoteRunner = remoteRunner ?? { host, command in
            AccountCommandRunner.runRemoteLoginShell(
                host: host,
                command: command,
                timeout: processTimeout
            )
        }
        self.localBinaryPath = localBinaryPath
        self.remoteBinaryRevision = remoteBinaryRevision
    }

    func register(
        projectPath: String,
        on host: CommandHost
    ) async throws -> KwtProjectRecord {
        try await mutate(.register, projectPath: projectPath, on: host)
    }

    func register(
        projectPath: String,
        on host: SSHHostInfo
    ) async throws -> KwtProjectRecord {
        try await mutate(.register, projectPath: projectPath, on: host)
    }

    func unregister(
        projectPath: String,
        expectedRepository: String,
        on host: CommandHost
    ) async throws -> KwtProjectRecord {
        try await mutate(
            .unregister,
            projectPath: projectPath,
            expectedRepository: expectedRepository,
            on: host
        )
    }

    private func mutate(
        _ operation: Operation,
        projectPath: String,
        expectedRepository: String? = nil,
        on host: CommandHost
    ) async throws -> KwtProjectRecord {
        switch host {
        case .local:
            let command = try Self.command(
                operation: operation,
                projectPath: projectPath,
                expectedRepository: expectedRepository,
                binaryPrelude: KwtBinaryLocator.commandPrelude(
                    exactPath: localBinaryPath
                )
            )
            let localRunner = localRunner
            let task = Task.detached(priority: .userInitiated) {
                localRunner(command)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            return try Self.decode(
                result,
                hostLabel: "this Mac",
                expectedStatus: operation.successStatus
            )
        case let .ssh(info):
            return try await mutate(
                operation,
                projectPath: projectPath,
                expectedRepository: expectedRepository,
                on: info
            )
        }
    }

    private func mutate(
        _ operation: Operation,
        projectPath: String,
        expectedRepository: String? = nil,
        on host: SSHHostInfo
    ) async throws -> KwtProjectRecord {
        let command = try Self.command(
            operation: operation,
            projectPath: projectPath,
            expectedRepository: expectedRepository,
            binaryPrelude: KwtBinaryLocator.remoteCommandPrelude(
                revision: remoteBinaryRevision
            )
        )
        let remoteRunner = remoteRunner
        let task = Task.detached(priority: .userInitiated) {
            remoteRunner(host, command)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return try Self.decode(
            result,
            hostLabel: host.displayName,
            expectedStatus: operation.successStatus
        )
    }

    private static func command(
        operation: Operation,
        projectPath: String,
        expectedRepository: String?,
        binaryPrelude: String
    ) throws -> String {
        guard projectPath.hasPrefix("/") else {
            throw KwtProjectCommandError.invalidProjectPath
        }
        var arguments = "projects \(operation.rawValue) "
            + shellQuotedCommandArgument(projectPath)
        if operation == .unregister, let expectedRepository {
            arguments += " --expected-repository "
                + shellQuotedCommandArgument(expectedRepository)
        }
        return binaryPrelude
            + "printf 'GHOSTHUB_KWT_PROJECT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" \(arguments) --json"
    }

    private static func decode(
        _ result: (status: Int32, stdout: String),
        hostLabel: String,
        expectedStatus: String
    ) throws -> KwtProjectRecord {
        guard let markerRange = result.stdout.range(
            of: jsonMarker,
            options: .backwards
        ) else {
            if result.status != 0 {
                throw KwtProjectCommandError.commandFailed(
                    host: hostLabel,
                    status: result.status,
                    code: nil,
                    message: nil,
                    retryable: false
                )
            }
            throw KwtProjectCommandError.malformedOutput(host: hostLabel)
        }
        let data = Data(result.stdout[markerRange.upperBound...].utf8)
        guard result.status == 0 else {
            let envelope = try? JSONDecoder().decode(
                ProjectMutationErrorEnvelope.self,
                from: data
            )
            throw KwtProjectCommandError.commandFailed(
                host: hostLabel,
                status: result.status,
                code: envelope?.error.code,
                message: envelope?.error.message,
                retryable: envelope?.error.retryable ?? false
            )
        }
        do {
            let response = try JSONDecoder().decode(
                ProjectMutationResponse.self,
                from: data
            )
            guard response.status == expectedStatus else {
                throw KwtProjectCommandError.malformedOutput(host: hostLabel)
            }
            return response.project
        } catch let error as KwtProjectCommandError {
            throw error
        } catch {
            throw KwtProjectCommandError.malformedOutput(host: hostLabel)
        }
    }
}

private struct ProjectMutationResponse: Decodable {
    var status: String
    var project: KwtProjectRecord
}

private struct ProjectMutationErrorEnvelope: Decodable {
    var error: ProjectMutationErrorDTO
}

private struct ProjectMutationErrorDTO: Decodable {
    var code: String
    var message: String
    var retryable: Bool
}
