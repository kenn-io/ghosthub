import Foundation
import GhosthubTmux

enum KwtProjectRegistrationError: Error, Equatable, LocalizedError {
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
            return "kwt returned an invalid project registration response on \(host)."
        }
    }
}

/// Registers a repository through kwt's supported machine-readable boundary.
/// Ghosthub never edits kwt configuration or scans the host filesystem.
struct KwtProjectRegistrar: Sendable {
    typealias LocalRunner = @Sendable (
        _ command: String
    ) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ command: String
    ) -> (status: Int32, stdout: String)

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
            TmuxBinaryResolver.loginShell
    ) {
        self.localRunner = localRunner ?? { command in
            TmuxBinaryResolver.runLoginShell(
                shell: loginShellProvider(),
                command: command,
                timeout: processTimeout
            )
        }
        self.remoteRunner = remoteRunner ?? { host, command in
            TmuxBinaryResolver.runRemoteLoginShell(
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
        on host: TmuxHost
    ) async throws -> KwtProjectRecord {
        switch host {
        case .local:
            let command = try Self.command(
                projectPath: projectPath,
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
            return try Self.decode(result, hostLabel: "this Mac")
        case let .ssh(info):
            return try await register(projectPath: projectPath, on: info)
        }
    }

    func register(
        projectPath: String,
        on host: SSHHostInfo
    ) async throws -> KwtProjectRecord {
        let command = try Self.command(
            projectPath: projectPath,
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
            hostLabel: host.displayName
        )
    }

    static func command(
        projectPath: String,
        binaryPrelude: String
    ) throws -> String {
        let projectPath = projectPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard projectPath.hasPrefix("/") else {
            throw KwtProjectRegistrationError.invalidProjectPath
        }
        return binaryPrelude
            + "printf 'GHOSTHUB_KWT_PROJECT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" projects add "
            + shellQuotedCommandArgument(projectPath)
            + " --json"
    }

    private static func decode(
        _ result: (status: Int32, stdout: String),
        hostLabel: String
    ) throws -> KwtProjectRecord {
        guard let markerRange = result.stdout.range(
            of: jsonMarker,
            options: .backwards
        ) else {
            if result.status != 0 {
                throw KwtProjectRegistrationError.commandFailed(
                    host: hostLabel,
                    status: result.status,
                    code: nil,
                    message: nil,
                    retryable: false
                )
            }
            throw KwtProjectRegistrationError.malformedOutput(
                host: hostLabel
            )
        }
        let data = Data(result.stdout[markerRange.upperBound...].utf8)
        guard result.status == 0 else {
            let envelope = try? JSONDecoder().decode(
                ProjectRegistrationErrorEnvelope.self,
                from: data
            )
            throw KwtProjectRegistrationError.commandFailed(
                host: hostLabel,
                status: result.status,
                code: envelope?.error.code,
                message: envelope?.error.message,
                retryable: envelope?.error.retryable ?? false
            )
        }
        do {
            let response = try JSONDecoder().decode(
                ProjectRegistrationResponse.self,
                from: data
            )
            guard response.status == "registered" else {
                throw KwtProjectRegistrationError.malformedOutput(
                    host: hostLabel
                )
            }
            return response.project
        } catch let error as KwtProjectRegistrationError {
            throw error
        } catch {
            throw KwtProjectRegistrationError.malformedOutput(
                host: hostLabel
            )
        }
    }
}

private struct ProjectRegistrationResponse: Decodable {
    var status: String
    var project: KwtProjectRecord
}

private struct ProjectRegistrationErrorEnvelope: Decodable {
    var error: ProjectRegistrationErrorDTO
}

private struct ProjectRegistrationErrorDTO: Decodable {
    var code: String
    var message: String
    var retryable: Bool
}
