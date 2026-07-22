import Foundation
import GhosthubTestSupport
@testable import GhosthubWorkspace

// MARK: - Domain Model Fixtures

extension HostSummary {

    // MARK: Semantic State Fixtures

    static func localFixture(
        name: String = "This Mac",
        platform: HostPlatform = .macOS
    ) -> HostSummary {
        fixture(name: name, kind: .selfHost, platform: platform)
    }

    static func onlineRemoteFixture(
        name: String = "Build Box",
        platform: HostPlatform = .linux,
        sshDestination: String = "rpi5-ssd",
        transport: HostTransport = .ssh,
        version: String = "0.1.0",
        remoteHostname: String? = nil
    ) -> HostSummary {
        fixture(
            name: name,
            kind: .remote,
            platform: platform,
            sshDestination: sshDestination,
            preferredTransport: transport,
            lastKnownReachable: true,
            lastSeenAt: Date(
                timeIntervalSince1970: 1_700_000_000
            ),
            remoteHostname: remoteHostname,
            version: version
        )
    }

}

extension RemoteHostDiagnostic {
    static func missingGhFixture() -> RemoteHostDiagnostic {
        RemoteHostDiagnostic(
            code: .missingGh,
            severity: .warning,
            summary: "Missing gh",
            recoverySuggestion: "Install GitHub CLI (`gh`) on the remote "
                + "host to import pull requests."
        )
    }
}

// MARK: - Relational Convenience Fixtures

extension ProjectSummary {
    static func fixture(
        for host: HostSummary,
        name: String = "test-project",
        rootPath: String? = nil,
        isStale: Bool = false,
        repositoryKind: ProjectRepositoryKind = .standard,
        defaultBranch: String = "main"
    ) -> ProjectSummary {
        let derivedRoot = rootPath
            ?? "/home/user/\(name)"
        return fixture(
            hostID: host.id,
            name: name,
            rootPath: derivedRoot,
            isStale: isStale,
            repositoryKind: repositoryKind,
            defaultBranch: defaultBranch
        )
    }
}

extension WorktreeSummary {
    static func fixture(
        for project: ProjectSummary,
        name: String = "main",
        path: String? = nil,
        branch: String = "main",
        isPrimary: Bool = false,
        isHidden: Bool = false,
        isStale: Bool = false,
        linkedIssueNumbers: [Int] = [],
        linkedPullRequestNumber: Int? = nil,
        pullRequestTitle: String? = nil,
        pullRequestState: PRState? = nil,
        pullRequestURL: String? = nil,
        pullRequestUpdatedAt: Date? = nil,
        checksStatus: ChecksStatus? = nil,
        checksDetail: [CheckDetailItem] = []
    ) -> WorktreeSummary {
        let derivedPath = path
            ?? "\(project.rootPath)-\(name)"
        return fixture(
            hostID: project.hostID,
            projectID: project.id,
            name: name,
            path: derivedPath,
            branch: branch,
            isPrimary: isPrimary,
            isHidden: isHidden,
            isStale: isStale,
            linkedIssueNumbers: linkedIssueNumbers,
            linkedPullRequestNumber: linkedPullRequestNumber,
            pullRequestTitle: pullRequestTitle,
            pullRequestState: pullRequestState,
            pullRequestURL: pullRequestURL,
            pullRequestUpdatedAt: pullRequestUpdatedAt,
            checksStatus: checksStatus,
            checksDetail: checksDetail
        )
    }
}

// MARK: - Standard Workspace Setup

struct StandardWorkspaceSetup {
    let snapshot: WorkspaceSnapshot
    let localHost: HostSummary
    let remoteHost: HostSummary
    let remoteProject: ProjectSummary
    let remoteWorktree: WorktreeSummary
}

extension StandardWorkspaceSetup {
    func makeSelection(
        host: HostSummary? = nil,
        project: ProjectSummary? = nil,
        worktree: WorktreeSummary? = nil
    ) -> WorkspaceSelection {
        let effectiveHostID: UUID
        if let worktree {
            effectiveHostID = worktree.hostID
        } else if let project {
            effectiveHostID = project.hostID
        } else {
            effectiveHostID = (host ?? localHost).id
        }
        return WorkspaceSelection(
            selectedHostID: effectiveHostID,
            selectedProjectID: project?.id
                ?? worktree?.projectID,
            selectedWorktreeID: worktree?.id
        )
    }
}

func makeStandardWorkspaceSetup(
    remoteHostName: String = "Build Box",
    remoteProjectName: String = "api",
    remoteWorktreeName: String = "release",
    remoteWorktreeBranch: String = "release/2026-03"
) -> StandardWorkspaceSetup {
    let localHost = HostSummary.localFixture()
    let remoteHost = HostSummary.onlineRemoteFixture(
        name: remoteHostName
    )
    let remoteProject = ProjectSummary.fixture(
        for: remoteHost,
        name: remoteProjectName
    )
    let remoteWorktree = WorktreeSummary.fixture(
        for: remoteProject,
        name: remoteWorktreeName,
        branch: remoteWorktreeBranch
    )
    let snapshot = WorkspaceSnapshot.fixture(
        hosts: [localHost, remoteHost],
        projects: [remoteProject],
        worktrees: [remoteWorktree]
    )
    return StandardWorkspaceSetup(
        snapshot: snapshot,
        localHost: localHost,
        remoteHost: remoteHost,
        remoteProject: remoteProject,
        remoteWorktree: remoteWorktree
    )
}

// MARK: - Snapshot + Selection Pairing

func makeSnapshotAndSelection(
    host: HostSummary,
    project: ProjectSummary? = nil,
    worktree: WorktreeSummary? = nil
) -> (snapshot: WorkspaceSnapshot, selection: WorkspaceSelection) {
    let snapshot = WorkspaceSnapshot.fixture(
        hosts: [host],
        projects: project.map { [$0] } ?? [],
        worktrees: worktree.map { [$0] } ?? []
    )
    let selection = WorkspaceSelection(
        selectedHostID: host.id,
        selectedProjectID: project?.id,
        selectedWorktreeID: worktree?.id
    )
    return (snapshot, selection)
}
