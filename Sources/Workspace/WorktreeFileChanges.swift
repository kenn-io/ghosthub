import Foundation

public enum WorktreeChangePath {
    public static func key(_ path: String, usesWindowsPaths: Bool) -> String {
        guard usesWindowsPaths else { return path }
        return path.replacingOccurrences(of: "/", with: "\\")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func matches(
        _ lhs: String, _ rhs: String, usesWindowsPaths: Bool
    ) -> Bool {
        key(lhs, usesWindowsPaths: usesWindowsPaths)
            == key(rhs, usesWindowsPaths: usesWindowsPaths)
    }
}

public enum WorktreeFileState: String, Codable, CaseIterable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case conflicted
    case untracked
}

public protocol WorktreeChangesRetryClassifying: Error {
    var isRetryable: Bool { get }
    var requiresInventoryRefresh: Bool { get }
}

public struct WorktreeFileChange: Codable, Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    public let index: WorktreeFileState?
    public let worktree: WorktreeFileState?

    public init(
        path: String,
        originalPath: String?,
        index: WorktreeFileState?,
        worktree: WorktreeFileState?
    ) {
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.worktree = worktree
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case originalPath = "original_path"
        case index
        case worktree
    }
}

public enum WorktreeChangeState: String, Codable, CaseIterable, Sendable {
    case clean
    case modified
    case staged
    case conflicted
}

public struct WorktreeFileChanges: Equatable, Sendable {
    public let repository: String
    public let path: String
    public let generation: String
    public let state: WorktreeChangeState
    public let summary: WorktreeChangeSummary
    public let files: [WorktreeFileChange]
    public let observedAt: String

    public init(
        repository: String,
        path: String,
        generation: String,
        state: WorktreeChangeState,
        summary: WorktreeChangeSummary,
        files: [WorktreeFileChange],
        observedAt: String
    ) {
        self.repository = repository
        self.path = path
        self.generation = generation
        self.state = state
        self.summary = summary
        self.files = files
        self.observedAt = observedAt
    }

    public func sortedForPresentation() -> Self {
        Self(
            repository: repository,
            path: path,
            generation: generation,
            state: state,
            summary: summary,
            files: files.sortedForPresentation(),
            observedAt: observedAt
        )
    }
}

public extension [WorktreeFileChange] {
    func sortedForPresentation() -> Self {
        sorted {
            if $0.path != $1.path {
                return $0.path < $1.path
            }
            return ($0.originalPath ?? "") < ($1.originalPath ?? "")
        }
    }
}
