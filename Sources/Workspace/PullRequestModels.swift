import Foundation

/// Provider-neutral pull-request candidate returned by kwt.
///
/// Ghosthub treats `id` as opaque and returns it unchanged when importing.
/// Repository, ref, worktree, and tmux naming remain kwt responsibilities.
public struct PullRequestCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let number: Int
    public let url: String
    public let title: String
    public let author: String
    public let sourceBranch: String
    public let targetBranch: String
    public let isDraft: Bool
    public let state: String
    public let isImported: Bool
    public let workspace: PullRequestWorkspace?

    public init(
        id: String,
        number: Int,
        url: String,
        title: String,
        author: String,
        sourceBranch: String,
        targetBranch: String,
        isDraft: Bool,
        state: String,
        isImported: Bool,
        workspace: PullRequestWorkspace? = nil
    ) {
        self.id = id
        self.number = number
        self.url = url
        self.title = title
        self.author = author
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.isDraft = isDraft
        self.state = state
        self.isImported = isImported
        self.workspace = workspace
    }
}

/// Canonical workspace identity returned by kwt after PR import.
public struct PullRequestWorkspace: Equatable, Sendable {
    public let id: String
    public let repository: String
    public let branch: String
    public let path: String
    public let state: String
    public let sessionName: String
    public let tmuxSocketName: String

    public init(
        id: String,
        repository: String,
        branch: String,
        path: String,
        state: String,
        sessionName: String,
        tmuxSocketName: String
    ) {
        self.id = id
        self.repository = repository
        self.branch = branch
        self.path = path
        self.state = state
        self.sessionName = sessionName
        self.tmuxSocketName = tmuxSocketName
    }
}

public struct PullRequestImportRequest: Equatable, Sendable {
    public let projectID: UUID
    public let pullRequestID: String

    public init(projectID: UUID, pullRequestID: String) {
        self.projectID = projectID
        self.pullRequestID = pullRequestID
    }
}
