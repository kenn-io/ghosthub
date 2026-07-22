import Foundation

public enum ProjectRepositoryKind: String, Codable, Equatable, Sendable {
    case standard
    case bare
}

public enum ProjectKind: String, Codable, Equatable, Sendable {
    case repository
}
public enum PRState: String, Codable, CaseIterable, Sendable {
    case open
    case closed
    case merged
    case draft
}

public enum ChecksStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case success
    case failure
    case none
}

/// The aggregate review decision for a pull request, as returned by the
/// GitHub Reviews API. Unknown values decode to `nil` rather than
/// poisoning the snapshot decode.
public enum PullRequestReviewDecision: String, Codable, CaseIterable, Sendable {
    case approved
    case changesRequested = "changes_requested"
    case reviewRequired = "review_required"
    /// GitHub returns `"none"` when no review has been submitted.
    /// Named `noDecision` (not `none`) to avoid shadowing `Optional.none`.
    case noDecision = "none"
}

/// Whether a pull request can be merged without conflicts.
/// Wire values: `clean` | `dirty` | `unknown`.
/// An unrecognized value decodes to `.unknown` so the snapshot decode is
/// never poisoned by a new value GitHub may introduce.
public enum PullRequestMergeable: String, Codable, CaseIterable, Sendable {
    case clean
    case dirty
    case unknown
}

public struct CheckDetailItem: Codable, Equatable, Sendable {
    /// Per-check status from GitHub Checks API. Free-form string
    /// because GitHub's vocabulary (`queued`, `in_progress`,
    /// `completed`) is disjoint from the rolled-up `ChecksStatus`
    /// summary used at the worktree level. Treating this as an
    /// enum poisons the entire snapshot decode whenever GitHub
    /// returns a value the enum doesn't enumerate.
    public var name: String
    public var status: String
    public var conclusion: String?
    public var url: String?

    public init(
        name: String,
        status: String,
        conclusion: String? = nil,
        url: String? = nil
    ) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.url = url
    }
}

public struct ProjectSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var hostID: UUID
    public var scopedKey: String
    /// Optional legacy producer registry identifier.
    public var registryID: String?
    public var name: String
    public var rootPath: String
    public var isStale: Bool
    public var repositoryKind: ProjectRepositoryKind
    public var kind: ProjectKind
    public var defaultBranch: String
    public var platformURL: String?
    public var platformCoverage: String?
    /// A synthesized project has no registered local checkout — it exists only
    /// to anchor an orphan workspace's worktree, so its rootPath/repositoryKind
    /// are empty. Consumers treat it as read-only: it is never a target for
    /// worktree creation, PR import, or a terminal working directory.
    public var isSynthesized: Bool

    public init(
        id: UUID,
        hostID: UUID,
        scopedKey: String = "",
        registryID: String? = nil,
        name: String,
        rootPath: String,
        isStale: Bool = false,
        repositoryKind: ProjectRepositoryKind = .standard,
        kind: ProjectKind = .repository,
        defaultBranch: String = "main",
        platformURL: String? = nil,
        platformCoverage: String? = nil,
        isSynthesized: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.scopedKey = scopedKey
        self.registryID = registryID
        self.name = name
        self.rootPath = rootPath
        self.isStale = isStale
        self.repositoryKind = repositoryKind
        self.kind = kind
        self.defaultBranch = defaultBranch
        self.platformURL = platformURL
        self.platformCoverage = platformCoverage
        self.isSynthesized = isSynthesized
    }

}

public extension ProjectSummary {
    var platformRepositoryFullName: String? {
        guard let platformURL else {
            return nil
        }
        return Self.parsePlatformRepository(from: platformURL)
    }

    /// Extracts the host from `platformURL`. Returns `nil` for github.com.
    var platformRepositoryHost: String? {
        guard let platformURL else {
            return nil
        }
        return Self.parsePlatformHost(from: platformURL)
    }

    var platformRepositoryProvider: String? {
        guard let platformURL else {
            return nil
        }
        return PlatformRepository.provider(
            forHost: Self.parsePlatformHost(from: platformURL)
        )
    }

    private static func parsePlatformRepository(
        from rawValue: String
    ) -> String? {
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return nil
        }

        if let components = URLComponents(string: trimmed),
           components.host != nil {
            return normalizeRepositoryPath(components.path)
        }

        guard let separatorIndex = trimmed.firstIndex(of: ":") else {
            return nil
        }
        let pathPart = String(
            trimmed[trimmed.index(after: separatorIndex)...]
        )
        return normalizeRepositoryPath(pathPart)
    }

    private static func parsePlatformHost(
        from rawValue: String
    ) -> String? {
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return nil
        }

        let host = URLComponents(string: trimmed)
            .flatMap(Self.platformHost(from:))
            ?? Self.scpStyleHost(from: trimmed)
        guard let host, !host.isEmpty else {
            return nil
        }
        if host.lowercased() == "github.com" {
            return nil
        }
        return host
    }

    private static func platformHost(
        from components: URLComponents
    ) -> String? {
        guard let host = components.host, !host.isEmpty else {
            return nil
        }
        guard let port = components.port else {
            return host
        }
        return "\(host):\(port)"
    }

    private static func scpStyleHost(from value: String) -> String? {
        guard let separatorIndex = value.firstIndex(of: ":") else {
            return nil
        }
        let hostPart = String(value[..<separatorIndex])
        return hostPart.split(separator: "@").last.map(String.init)
            ?? hostPart
    }

    private static func normalizeRepositoryPath(
        _ rawPath: String
    ) -> String? {
        let trimmed = rawPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(
                of: ".git",
                with: "",
                options: [.anchored, .backwards]
            )
        let parts = trimmed.split(separator: "/")
        guard parts.count >= 2,
              let name = parts.last
        else {
            return nil
        }
        return parts.dropLast().joined(separator: "/")
            + "/\(name)"
    }
}

enum PlatformRepository {
    static func provider(forHost host: String?) -> String {
        guard let host, !host.isEmpty else {
            return "github"
        }
        let normalized = host.lowercased()
        if normalized == "gitlab.com" || normalized.contains("gitlab") {
            return "gitlab"
        }
        if normalized == "codeberg.org" || normalized.contains("forgejo") {
            return "forgejo"
        }
        if normalized == "gitea.com" || normalized.contains("gitea") {
            return "gitea"
        }
        return "github"
    }

    static func defaultHost(forProvider provider: String) -> String? {
        switch provider.lowercased() {
        case "github", "gh":
            return "github.com"
        case "gitlab", "gl":
            return "gitlab.com"
        case "forgejo", "fj":
            return "codeberg.org"
        case "gitea":
            return "gitea.com"
        default:
            return nil
        }
    }
}

public struct WorktreeSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var hostID: UUID
    public var projectID: UUID
    public var scopedKey: String
    /// Optional legacy producer registry identifier.
    public var registryID: String?
    public var name: String
    public var path: String
    public var branch: String
    public var isPrimary: Bool
    public var isHidden: Bool
    public var isStale: Bool
    public var diffAdded: Int?
    public var diffRemoved: Int?
    public var syncAhead: Int?
    public var syncBehind: Int?
    public var linkedIssueNumbers: [Int]
    public var linkedPullRequestNumber: Int?
    public var pullRequestTitle: String?
    public var pullRequestState: PRState?
    public var pullRequestURL: String?
    public var pullRequestUpdatedAt: Date?
    public var checksStatus: ChecksStatus?
    public var checksDetail: [CheckDetailItem]
    public var lastPolledAt: Date?
    public var lastAgentActivity: Date?
    public var lastViewedAt: Date?
    /// Exact tmux session identity reported by kwt for this worktree.
    /// Ghosthub borrows this session through its ordinary tmux client.
    public var tmuxSessionName: String?
    public var sessionBackend: SessionBackendKind
    public var pullRequestReviewDecision: PullRequestReviewDecision?
    public var pullRequestMergeable: PullRequestMergeable?
    public var pullRequestAdditions: Int?
    public var pullRequestDeletions: Int?
    public var pullRequestCommentCount: Int?

    public init(
        id: UUID,
        hostID: UUID,
        projectID: UUID,
        scopedKey: String = "",
        registryID: String? = nil,
        name: String,
        path: String,
        branch: String,
        isPrimary: Bool = false,
        isHidden: Bool = false,
        isStale: Bool = false,
        diffAdded: Int? = nil,
        diffRemoved: Int? = nil,
        syncAhead: Int? = nil,
        syncBehind: Int? = nil,
        linkedIssueNumbers: [Int] = [],
        linkedPullRequestNumber: Int? = nil,
        pullRequestTitle: String? = nil,
        pullRequestState: PRState? = nil,
        pullRequestURL: String? = nil,
        pullRequestUpdatedAt: Date? = nil,
        checksStatus: ChecksStatus? = nil,
        checksDetail: [CheckDetailItem] = [],
        lastPolledAt: Date? = nil,
        lastAgentActivity: Date? = nil,
        lastViewedAt: Date? = nil,
        tmuxSessionName: String? = nil,
        sessionBackend: SessionBackendKind = .localPTY,
        pullRequestReviewDecision: PullRequestReviewDecision? = nil,
        pullRequestMergeable: PullRequestMergeable? = nil,
        pullRequestAdditions: Int? = nil,
        pullRequestDeletions: Int? = nil,
        pullRequestCommentCount: Int? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.projectID = projectID
        self.scopedKey = scopedKey
        self.registryID = registryID
        self.name = name
        self.path = path
        self.branch = branch
        self.isPrimary = isPrimary
        self.isHidden = isHidden
        self.isStale = isStale
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.syncAhead = syncAhead
        self.syncBehind = syncBehind
        self.linkedIssueNumbers = linkedIssueNumbers
        self.linkedPullRequestNumber = linkedPullRequestNumber
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestState = pullRequestState
        self.pullRequestURL = pullRequestURL
        self.pullRequestUpdatedAt = pullRequestUpdatedAt
        self.checksStatus = checksStatus
        self.checksDetail = checksDetail
        self.lastPolledAt = lastPolledAt
        self.lastAgentActivity = lastAgentActivity
        self.lastViewedAt = lastViewedAt
        self.tmuxSessionName = tmuxSessionName
        self.sessionBackend = sessionBackend
        self.pullRequestReviewDecision = pullRequestReviewDecision
        self.pullRequestMergeable = pullRequestMergeable
        self.pullRequestAdditions = pullRequestAdditions
        self.pullRequestDeletions = pullRequestDeletions
        self.pullRequestCommentCount = pullRequestCommentCount
    }

}

public struct WorktreeVisibility: Equatable, Sendable {
    public static let `default` = WorktreeVisibility()

    public var hideRootWorktrees: Bool
    public var showHiddenWorktrees: Bool

    public init(
        hideRootWorktrees: Bool = false,
        showHiddenWorktrees: Bool = true
    ) {
        self.hideRootWorktrees = hideRootWorktrees
        self.showHiddenWorktrees = showHiddenWorktrees
    }

    public func includes(_ worktree: WorktreeSummary) -> Bool {
        if hideRootWorktrees, worktree.isPrimary {
            return false
        }
        if !showHiddenWorktrees, worktree.isHidden {
            return false
        }
        return true
    }
}
