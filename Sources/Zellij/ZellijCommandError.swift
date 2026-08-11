import Foundation

public enum ZellijCommandError:
    Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case commandFailed(status: Int32, stderr: String)
    case missingMarker
    case malformedInventory(line: String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Zellij is unavailable on this host."
        case let .commandFailed(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Zellij exited with status \(status)."
                : "Zellij exited with status \(status): \(detail)"
        case .missingMarker:
            return "Zellij returned output without Ghosthub's inventory marker."
        case let .malformedInventory(line):
            return "Zellij returned an unrecognized session entry: \(line)"
        case .unsupportedPlatform:
            return "Native Zellij sessions are unavailable on Windows hosts."
        }
    }
}
