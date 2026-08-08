import Foundation
import GhosthubTransport
import GhosthubWorkspace

public enum HerdrSessionLifecycleAction: String, Equatable, Sendable {
    case stop
    case delete
}

public enum HerdrSessionLifecycleError:
    Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case unsupportedPlatform
    case sessionMissing(String)
    case stateChanged(name: String, expected: HerdrSessionState)
    case locationChanged(String)
    case defaultSessionCannotBeDeleted
    case commandFailed(status: Int32, code: String?, message: String)
    case missingMarker
    case malformedJSON

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Herdr is unavailable on this host."
        case .unsupportedPlatform:
            "Native Herdr sessions are unavailable on Windows hosts."
        case let .sessionMissing(name):
            "Herdr session \(name) no longer exists."
        case let .stateChanged(name, expected):
            "Herdr session \(name) is no longer \(expected.rawValue)."
        case let .locationChanged(name):
            "Herdr session \(name) moved to a different configuration."
        case .defaultSessionCannotBeDeleted:
            "Herdr's default session cannot be deleted."
        case let .commandFailed(status, _, message):
            message.isEmpty
                ? "Herdr exited with status \(status)."
                : "Herdr exited with status \(status): \(message)"
        case .missingMarker:
            "Herdr returned output without Ghosthub's lifecycle marker."
        case .malformedJSON:
            "Herdr returned malformed lifecycle JSON."
        }
    }
}

public enum HerdrSessionLifecycle {
    public static let marker = "GHOSTHUB_HERDR_SESSION_JSON"

    public static func command(
        action: HerdrSessionLifecycleAction,
        name: String,
        herdrPath: String
    ) -> String {
        let invocation = [
            herdrPath, "session", action.rawValue, name, "--json",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return [
            HerdrEnvironment.unsetCommand,
            "printf '%s\\n' '\(marker)'",
            "exec \(invocation)",
        ].joined(separator: "; ")
    }

    public static func parse(
        action: HerdrSessionLifecycleAction,
        status: Int32,
        stdout: String,
        stderr: String
    ) -> Result<HerdrSessionRecord, HerdrSessionLifecycleError> {
        if status == 127 {
            return .failure(.unavailable)
        }
        let lines = stdout.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard let markerIndex = lines.lastIndex(where: { $0 == marker }) else {
            if status == 0 {
                return .failure(.missingMarker)
            }
            return .failure(.commandFailed(
                status: status,
                code: nil,
                message: stderr.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ))
        }
        let payload = lines[(markerIndex + 1)...].joined(separator: "\n")
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                  LifecycleEnvelope.self,
                  from: data
              )
        else { return .failure(.malformedJSON) }

        if let error = envelope.error {
            return .failure(.commandFailed(
                status: status,
                code: error.code,
                message: error.message
            ))
        }
        guard status == 0, let session = envelope.session else {
            return .failure(.commandFailed(
                status: status,
                code: nil,
                message: stderr.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ))
        }
        switch action {
        case .stop where envelope.stopped != true:
            return .failure(.malformedJSON)
        case .delete where envelope.deleted != true:
            return .failure(.malformedJSON)
        default:
            return .success(session.record)
        }
    }

    private struct LifecycleEnvelope: Decodable {
        var session: Session?
        var stopped: Bool?
        var deleted: Bool?
        var error: CommandError?

        struct CommandError: Decodable {
            var code: String?
            var message: String
        }

        struct Session: Decodable {
            var name: String
            var `default`: Bool
            var running: Bool
            var sessionDirectory: String
            var socketPath: String

            enum CodingKeys: String, CodingKey {
                case name
                case `default`
                case running
                case sessionDirectory = "session_dir"
                case socketPath = "socket_path"
            }

            var record: HerdrSessionRecord {
                HerdrSessionRecord(
                    name: name,
                    isDefault: `default`,
                    state: running ? .running : .stopped,
                    sessionDirectory: sessionDirectory,
                    socketPath: socketPath
                )
            }
        }
    }
}
