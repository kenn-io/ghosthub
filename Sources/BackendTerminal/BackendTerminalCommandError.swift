import Foundation
import GhosthubWorkspace

public enum BackendTerminalCommandError:
    Error, Equatable, LocalizedError, Sendable {
    case unavailable(BackendTerminalKind)
    case cancelled(BackendTerminalKind, host: String)
    case commandFailed(BackendTerminalKind, status: Int32, stderr: String)
    case missingMarker(BackendTerminalKind)
    case malformedJSON(BackendTerminalKind)
    case unsupportedPlatform(BackendTerminalKind)
    case invalidAddress(BackendTerminalKind, address: String)

    public var kind: BackendTerminalKind {
        switch self {
        case let .unavailable(kind), let .cancelled(kind, _),
             let .commandFailed(kind, _, _), let .missingMarker(kind),
             let .malformedJSON(kind), let .unsupportedPlatform(kind),
             let .invalidAddress(kind, _):
            kind
        }
    }

    public var errorDescription: String? {
        let program = kind.programName
        switch self {
        case .unavailable:
            return "\(program) is unavailable on this host."
        case let .cancelled(_, host):
            return "Stopped checking \(program) terminals on \(host)."
        case let .commandFailed(_, status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(program) exited with status \(status)."
                : "\(program) exited with status \(status): \(detail)"
        case .missingMarker:
            return "\(program) returned output without Ghosthub's JSON marker."
        case .malformedJSON:
            return "\(program) returned malformed terminal inventory JSON."
        case .unsupportedPlatform:
            return "\(kind.displayName) are unavailable on Windows hosts."
        case let .invalidAddress(_, address):
            return "“\(address)” is not a \(program) terminal address."
        }
    }
}

public extension BackendTerminalKind {
    /// The command whose failures a person would recognize.
    var programName: String {
        switch self {
        case .herdrCore: "Herdr core"
        case .rex: "kwt rex"
        }
    }

    /// The plural name used in messages.
    var displayName: String {
        switch self {
        case .herdrCore: "Herdr terminals"
        case .rex: "Rex terminals"
        }
    }
}
