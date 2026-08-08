import Foundation

public enum HerdrCommandError:
    Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case cancelled(host: String)
    case commandFailed(status: Int32, stderr: String)
    case missingMarker
    case malformedJSON
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Herdr is unavailable on this host."
        case let .cancelled(host):
            return "Stopped checking Herdr sessions on \(host)."
        case let .commandFailed(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Herdr exited with status \(status)."
                : "Herdr exited with status \(status): \(detail)"
        case .missingMarker:
            return "Herdr returned output without Ghosthub's JSON marker."
        case .malformedJSON:
            return "Herdr returned malformed session inventory JSON."
        case .unsupportedPlatform:
            return "Native Herdr sessions are unavailable on Windows hosts."
        }
    }
}
