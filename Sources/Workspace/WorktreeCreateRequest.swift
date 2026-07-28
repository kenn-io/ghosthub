import Foundation

/// A narrow request for creating a kwt worktree. Kwt remains responsible for
/// choosing the path and reporting the resulting tmux session identity.
public struct WorktreeCreateRequest: Equatable, Sendable {
    public let projectID: UUID
    public let branchName: String
    public let createsBranch: Bool
    public let source: String?

    public init(
        projectID: UUID,
        branchName: String,
        createsBranch: Bool,
        source: String? = nil
    ) {
        self.projectID = projectID
        self.branchName = branchName
        self.createsBranch = createsBranch
        self.source = source
    }
}

public struct WorktreeBranchCandidate:
    Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let source: String
    public let isRemote: Bool

    public var id: String { source }

    public init(
        name: String,
        source: String,
        isRemote: Bool
    ) {
        self.name = name
        self.source = source
        self.isRemote = isRemote
    }

    private enum CodingKeys: String, CodingKey {
        case name, source
        case isRemote = "is_remote"
    }
}

public enum GitBranchName {
    public static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else { return false }
        guard !value.hasPrefix("-"), value != "@" else { return false }
        guard !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.contains("//"), !value.contains(".."),
              !value.contains("@{"), !value.hasSuffix("."),
              !value.hasSuffix(".lock")
        else { return false }

        guard !value.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7f
        }) else { return false }

        let invalid = CharacterSet(charactersIn: " ~^:?*[\\")
        guard value.rangeOfCharacter(from: invalid) == nil else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                !component.isEmpty
                    && !component.hasPrefix(".")
                    && !component.hasSuffix(".")
                    && !component.hasSuffix(".lock")
            }
    }
}
