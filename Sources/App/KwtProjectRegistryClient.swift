import GhosthubTransport
import Foundation
import GhosthubTmux

indirect enum KwtProjectErrorDetail: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: KwtProjectErrorDetail])
    case array([KwtProjectErrorDetail])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(
            [String: KwtProjectErrorDetail].self
        ) {
            self = .object(value)
        } else if let value = try? container.decode(
            [KwtProjectErrorDetail].self
        ) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported kwt error detail"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum KwtProjectCommandError: Error, Equatable, LocalizedError {
    case invalidProjectPath
    case invalidRegistrationFingerprint
    case commandFailed(
        host: String,
        status: Int32,
        code: String?,
        message: String?,
        retryable: Bool,
        details: [String: KwtProjectErrorDetail]
    )
    case malformedOutput(host: String)
    case routeChanged(host: String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectPath:
            return "Enter an absolute project path beginning with /."
        case .invalidRegistrationFingerprint:
            return "Refresh projects and confirm removal again."
        case let .commandFailed(
            host,
            status,
            _,
            message,
            retryable,
            _
        ):
            let detail = message
                ?? "kwt exited with status \(status) on \(host)."
            return retryable ? "\(detail) Try again." : detail
        case let .malformedOutput(host):
            return "kwt returned an invalid project response on \(host)."
        case let .routeChanged(host):
            return "The SSH connection for \(host) changed after confirmation."
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
        _ host: SSHHostInfo, _ connectionArguments: [String], _ command: String
    ) -> AccountCommandOutput

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
    private let commandLease: KwtSSHCommandLease

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 30,
        localBinaryPath: String? = KwtBinaryLocator.bundledPath(),
        remoteBinaryRevision: String? =
            KwtBinaryLocator.bundledRemoteRevision(),
        commandLease: KwtSSHCommandLease? = nil,
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
        self.remoteRunner = remoteRunner ?? { host, arguments, command in
            AccountCommandRunner().runRemoteLoginShell(
                host: host,
                connectionArguments: arguments,
                command: command,
                timeout: processTimeout
            )
        }
        self.commandLease = commandLease ?? .unlessInjected(
            remoteRunner != nil
        )
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
        expectedRegistration: String,
        expectedRouteIdentity: String?,
        on host: CommandHost
    ) async throws -> KwtProjectRecord {
        try await mutate(
            .unregister,
            projectPath: projectPath,
            expectedRepository: expectedRepository,
            expectedRegistration: expectedRegistration,
            expectedRouteIdentity: expectedRouteIdentity,
            on: host
        )
    }

    private func mutate(
        _ operation: Operation,
        projectPath: String,
        expectedRepository: String? = nil,
        expectedRegistration: String? = nil,
        expectedRouteIdentity: String? = nil,
        on host: CommandHost
    ) async throws -> KwtProjectRecord {
        switch host {
        case .local:
            let command = try Self.command(
                operation: operation,
                projectPath: projectPath,
                expectedRepository: expectedRepository,
                expectedRegistration: expectedRegistration,
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
                expectedRegistration: expectedRegistration,
                expectedRouteIdentity: expectedRouteIdentity,
                on: info
            )
        }
    }

    private func mutate(
        _ operation: Operation,
        projectPath: String,
        expectedRepository: String? = nil,
        expectedRegistration: String? = nil,
        expectedRouteIdentity: String? = nil,
        on host: SSHHostInfo
    ) async throws -> KwtProjectRecord {
        let command = try Self.command(
            operation: operation,
            projectPath: projectPath,
            expectedRepository: expectedRepository,
            expectedRegistration: expectedRegistration,
            binaryPrelude: KwtBinaryLocator.remoteCommandPrelude(
                revision: remoteBinaryRevision
            )
        )
        let result = try await commandLease.withConnection(
            on: .ssh(host)
        ) { connection in
            guard operation != .unregister
                || connection?.routeIdentity == expectedRouteIdentity
            else {
                throw KwtProjectCommandError.routeChanged(
                    host: host.displayName
                )
            }
            return await commandLease.runCommand(using: connection) {
                arguments in
                remoteRunner(host, arguments, command)
            }
        }
        return try Self.decode(
            (result.status, result.stdout),
            hostLabel: host.displayName,
            expectedStatus: operation.successStatus
        )
    }

    private static func command(
        operation: Operation,
        projectPath: String,
        expectedRepository: String?,
        expectedRegistration: String?,
        binaryPrelude: String
    ) throws -> String {
        guard projectPath.hasPrefix("/") else {
            throw KwtProjectCommandError.invalidProjectPath
        }
        var arguments = "projects \(operation.rawValue) "
            + shellQuotedCommandArgument(projectPath)
        if operation == .unregister {
            guard let expectedRepository,
                  let expectedRegistration,
                  !expectedRegistration.isEmpty
            else {
                throw KwtProjectCommandError.invalidRegistrationFingerprint
            }
            arguments += " --expected-repository "
                + shellQuotedCommandArgument(expectedRepository)
            arguments += " --expected-registration "
                + shellQuotedCommandArgument(expectedRegistration)
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
                    retryable: false,
                    details: [:]
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
                retryable: envelope?.error.retryable ?? false,
                details: envelope?.error.details ?? [:]
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
            return KwtProjectRecord(
                repository: response.project.repository,
                name: response.project.name,
                path: response.project.path,
                lastTouched: response.project.lastTouched
            )
        } catch let error as KwtProjectCommandError {
            throw error
        } catch {
            throw KwtProjectCommandError.malformedOutput(host: hostLabel)
        }
    }
}

private struct ProjectMutationResponse: Decodable {
    var status: String
    var project: ProjectMutationRecord
}

private struct ProjectMutationRecord: Decodable {
    var repository: String
    var name: String
    var path: String
    var lastTouched: String?

    private enum CodingKeys: String, CodingKey {
        case repository, name, path
        case lastTouched = "last_touched"
    }
}

private struct ProjectMutationErrorEnvelope: Decodable {
    var error: ProjectMutationErrorDTO
}

private struct ProjectMutationErrorDTO: Decodable {
    var code: String
    var message: String
    var retryable: Bool
    var details: [String: KwtProjectErrorDetail]?
}
