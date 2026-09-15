import Foundation

public enum WorkspaceKnownAgent: String, CaseIterable, Equatable, Sendable {
    case claude
    case codex
    case opencode
    case gemini
    case copilot

    public static func recognize(
        executableName: String?
    ) -> WorkspaceKnownAgent? {
        guard let normalized = normalizedExecutableName(executableName) else {
            return nil
        }

        switch normalized {
        case "claude":
            return .claude
        case "codex":
            return .codex
        case "opencode":
            return .opencode
        case "gemini":
            return .gemini
        case "copilot":
            return .copilot
        default:
            return nil
        }
    }

    static func normalizedExecutableName(
        _ executableName: String?
    ) -> String? {
        guard let executableName else {
            return nil
        }

        let trimmed = executableName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let firstToken = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        ).first.map(String.init)
        return firstToken?.lowercased()
    }
}

public struct WorkspaceActivitySessionHint: Equatable, Sendable {
    public var presetID: String?
    public var command: String?

    public init(presetID: String?, command: String?) {
        self.presetID = presetID
        self.command = command
    }
}
