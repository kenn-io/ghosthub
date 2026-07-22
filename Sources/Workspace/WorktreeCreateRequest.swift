import Foundation

/// A narrow request for creating a kwt worktree. Kwt remains responsible for
/// choosing the path and reporting the resulting tmux session identity.
public struct WorktreeCreateRequest: Equatable, Sendable {
    public let projectID: UUID
    public let branchName: String
    public let createsBranch: Bool

    public init(
        projectID: UUID,
        branchName: String,
        createsBranch: Bool
    ) {
        self.projectID = projectID
        self.branchName = branchName
        self.createsBranch = createsBranch
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
