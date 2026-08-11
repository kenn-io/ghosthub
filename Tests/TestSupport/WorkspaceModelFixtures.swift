import Foundation
import GhosthubPersistence
import GhosthubWorkspace

// Canonical fixture extensions for workspace model types.
// Test targets that cannot import GhosthubTestSupport may
// duplicate these — keep this file as the source of truth.

public struct WorkspaceBootstrap: Equatable, Sendable {
    public let snapshot: WorkspaceSnapshot
    public let selection: WorkspaceSelection

    public init(
        snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) {
        self.snapshot = snapshot
        self.selection = selection
    }

    public static func preview() -> WorkspaceBootstrap {
        let localHost = HostSummary(
            id: UUID(uuidString: "B5EA95AB-51A3-4F17-B6C3-8A4C1004BFA1")!,
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let remoteHost = HostSummary(
            id: UUID(uuidString: "EBA2D713-489E-4A24-85FD-647E2B49B30A")!,
            name: "Office Studio",
            kind: .remote,
            platform: .macOS
        )
        let localProject = ProjectSummary(
            id: UUID(uuidString: "D69D5E04-16D6-49E8-8CA7-F89A13394E0B")!,
            hostID: localHost.id,
            name: "ghosthub",
            rootPath: "/Users/wesm/code/ghosthub",
            defaultBranch: "main"
        )
        let remoteProject = ProjectSummary(
            id: UUID(uuidString: "7A44BEA7-868C-429F-BCE9-3EACD297B642")!,
            hostID: remoteHost.id,
            name: "api",
            rootPath: "/Users/wesm/code/api",
            defaultBranch: "main"
        )
        let mainWorktree = WorktreeSummary(
            id: UUID(uuidString: "DD56782E-B408-459C-A468-C22CC6DFDDFB")!,
            hostID: localHost.id,
            projectID: localProject.id,
            name: "primary checkout",
            path: "/Users/wesm/code/ghosthub",
            branch: "main",
            isPrimary: true,
            checksStatus: .success
        )
        let sidebarNavWorktree = WorktreeSummary(
            id: UUID(uuidString: "1A2B3C4D-5E6F-7A8B-9C0D-E1F2A3B4C5D6")!,
            hostID: localHost.id,
            projectID: localProject.id,
            name: "sidebar-nav",
            path: "/Users/wesm/code/ghosthub-sidebar-nav",
            branch: "sidebar-nav"
        )
        let reviewFixesWorktree = WorktreeSummary(
            id: UUID(uuidString: "2B3C4D5E-6F7A-8B9C-0DE1-F2A3B4C5D6E7")!,
            hostID: localHost.id,
            projectID: localProject.id,
            name: "review-fixes",
            path: "/Users/wesm/code/ghosthub-review-fixes",
            branch: "review-fixes"
        )
        let releaseWorktree = WorktreeSummary(
            id: UUID(uuidString: "3C4D5E6F-7A8B-9C0D-E1F2-A3B4C5D6E7F8")!,
            hostID: remoteHost.id,
            projectID: remoteProject.id,
            name: "release",
            path: "/Users/wesm/code/api-release",
            branch: "release"
        )
        let workerRolloutWorktree = WorktreeSummary(
            id: UUID(uuidString: "4D5E6F7A-8B9C-0DE1-F2A3-B4C5D6E7F8A9")!,
            hostID: remoteHost.id,
            projectID: remoteProject.id,
            name: "worker-rollout",
            path: "/Users/wesm/code/api-worker-rollout",
            branch: "worker-rollout"
        )

        let snapshot = WorkspaceSnapshot(
            hosts: [localHost, remoteHost],
            projects: [localProject, remoteProject],
            worktrees: [
                mainWorktree,
                sidebarNavWorktree,
                reviewFixesWorktree,
                releaseWorktree,
                workerRolloutWorktree,
            ],
            sessions: []
        )

        return WorkspaceBootstrap(
            snapshot: snapshot,
            selection: WorkspaceSelection(
                selectedHostID: localHost.id,
                selectedProjectID: localProject.id,
                selectedWorktreeID: mainWorktree.id
            )
        )
    }
}

// MARK: - Host

public extension HostSummary {
    static func fixture(
        id: UUID = UUID(),
        configKey: String = "",
        name: String = "This Mac",
        kind: HostKind = .selfHost,
        platform: HostPlatform = .macOS,
        sshDestination: String? = nil,
        preferredTransport: HostTransport = .ssh,
        lastKnownReachable: Bool = true,
        lastSeenAt: Date? = nil,
        remoteHostname: String? = nil,
        version: String? = nil,
        lastSnapshotAt: Date? = nil,
        remoteCapabilities: RemoteHostCapabilities? = nil,
        remoteDiagnostics: [RemoteHostDiagnostic] = [],
        tmuxSessions: [TmuxSessionSummary] = [],
        herdrSessions: [HerdrSessionSummary] = [],
        herdrAvailable: Bool = false,
        zellijSessions: [ZellijSessionSummary] = [],
        zellijAvailable: Bool = false,
        decodedConnectionState: HostConnectionState? = nil,
        transientOverride: HostConnectionState? = nil,
        operationAvailability:
        [String: OperationAvailabilityEntry]? = nil,
        exeVM: ExeVMMetadata? = nil
    ) -> HostSummary {
        HostSummary(
            id: id, configKey: configKey,
            name: name,
            kind: kind, platform: platform,
            sshDestination: sshDestination,
            preferredTransport: preferredTransport,
            lastKnownReachable: lastKnownReachable,
            lastSeenAt: lastSeenAt,
            remoteHostname: remoteHostname,
            version: version,
            lastSnapshotAt: lastSnapshotAt,
            remoteCapabilities: remoteCapabilities,
            remoteDiagnostics: remoteDiagnostics,
            tmuxSessions: tmuxSessions,
            herdrSessions: herdrSessions,
            herdrAvailable: herdrAvailable,
            zellijSessions: zellijSessions,
            zellijAvailable: zellijAvailable,
            decodedConnectionState:
            decodedConnectionState,
            transientOverride: transientOverride,
            operationAvailability:
            operationAvailability,
            exeVM: exeVM
        )
    }
}

// MARK: - Project

public extension ProjectSummary {
    static func fixture(
        id: UUID = UUID(),
        hostID: UUID = UUID(),
        name: String = "ghosthub",
        rootPath: String = "/tmp/ghosthub",
        isStale: Bool = false,
        repositoryKind: ProjectRepositoryKind = .standard,
        defaultBranch: String = "main",
        platformURL: String? = nil,
        platformCoverage: String? = nil,
        isSynthesized: Bool = false
    ) -> ProjectSummary {
        ProjectSummary(
            id: id, hostID: hostID,
            name: name, rootPath: rootPath,
            isStale: isStale,
            repositoryKind: repositoryKind,
            defaultBranch: defaultBranch,
            platformURL: platformURL,
            platformCoverage: platformCoverage,
            isSynthesized: isSynthesized
        )
    }
}

// MARK: - Worktree

public extension WorktreeSummary {
    static func fixture(
        id: UUID = UUID(),
        hostID: UUID = UUID(),
        projectID: UUID = UUID(),
        scopedKey: String = "",
        name: String = "main",
        path: String = "/tmp/ghosthub",
        branch: String = "main",
        isPrimary: Bool = false,
        isHidden: Bool = false,
        isStale: Bool = false,
        createdAt: String? = nil,
        generation: String? = nil,
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
        lastViewedAt: Date? = nil
    ) -> WorktreeSummary {
        WorktreeSummary(
            id: id, hostID: hostID,
            projectID: projectID,
            scopedKey: scopedKey,
            name: name, path: path,
            branch: branch,
            isPrimary: isPrimary,
            isHidden: isHidden,
            isStale: isStale,
            createdAt: createdAt,
            generation: generation,
            diffAdded: diffAdded,
            diffRemoved: diffRemoved,
            syncAhead: syncAhead,
            syncBehind: syncBehind,
            linkedIssueNumbers: linkedIssueNumbers,
            linkedPullRequestNumber:
            linkedPullRequestNumber,
            pullRequestTitle: pullRequestTitle,
            pullRequestState: pullRequestState,
            pullRequestURL: pullRequestURL,
            pullRequestUpdatedAt: pullRequestUpdatedAt,
            checksStatus: checksStatus,
            checksDetail: checksDetail,
            lastPolledAt: lastPolledAt,
            lastAgentActivity: lastAgentActivity,
            lastViewedAt: lastViewedAt
        )
    }
}

// MARK: - Snapshot

public extension WorkspaceSnapshot {
    static func fixture(
        hosts: [HostSummary] = [],
        projects: [ProjectSummary] = [],
        worktrees: [WorktreeSummary] = [],
        sessions: [TerminalSessionSummary] = []
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            hosts: hosts, projects: projects,
            worktrees: worktrees, sessions: sessions
        )
    }
}

// MARK: - Remote Host Capabilities

public extension RemoteHostCommandCapabilities {
    static func fixture(
        worktreeCreate: Bool = true,
        worktreeImportPullRequest: Bool = true,
        worktreeDelete: Bool = true,
        sessionEnsure: Bool = true,
        sessionKill: Bool = true
    ) -> RemoteHostCommandCapabilities {
        RemoteHostCommandCapabilities(
            worktreeCreate: worktreeCreate,
            worktreeImportPullRequest:
            worktreeImportPullRequest,
            worktreeDelete: worktreeDelete,
            sessionEnsure: sessionEnsure,
            sessionKill: sessionKill
        )
    }
}

public extension RemoteHostDependencyCapabilities {
    static func fixture(
        git: Bool = true,
        gh: Bool = true,
        platformAuthenticated: Bool? = nil,
        tmux: Bool = true
    ) -> RemoteHostDependencyCapabilities {
        RemoteHostDependencyCapabilities(
            git: git, gh: gh,
            platformAuthenticated: platformAuthenticated,
            tmux: tmux
        )
    }
}

public extension RemoteHostFeatureCapabilities {
    static func fixture(
        resourceMetrics: Bool = false,
        setupHook: Bool = false,
        teardownHook: Bool = false,
        moshAttach: Bool = false
    ) -> RemoteHostFeatureCapabilities {
        RemoteHostFeatureCapabilities(
            resourceMetrics: resourceMetrics,
            setupHook: setupHook,
            teardownHook: teardownHook,
            moshAttach: moshAttach
        )
    }
}

public extension RemoteHostCapabilities {
    static func fixture(
        commands: RemoteHostCommandCapabilities
            = .fixture(),
        dependencies: RemoteHostDependencyCapabilities
            = .fixture(),
        features: RemoteHostFeatureCapabilities
            = .fixture()
    ) -> RemoteHostCapabilities {
        RemoteHostCapabilities(
            commands: commands,
            dependencies: dependencies,
            features: features
        )
    }
}

// MARK: - Terminal Session Record

public extension TerminalSessionRecord {
    static func fixture(
        id: UUID = UUID(),
        hostID: UUID,
        worktreeID: UUID? = nil,
        scopedKey: String? = nil,
        presetID: String? = nil,
        kind: SessionKind = .preset,
        launchMode: LaunchMode = .directCommand,
        backend: SessionBackendKind = .remoteTmux,
        workingDirectory: String? = nil,
        command: String? = nil,
        childPID: Int32? = nil,
        remoteLocator: String? = nil,
        isAlive: Bool = true,
        restartPolicy: RestartPolicy = .manual,
        lastExitCode: Int32? = nil,
        lastOutputAt: Date? = nil,
        lastSeenInSnapshotAt: Date? = nil,
        createdAt: Date = Date(
            timeIntervalSince1970: 1_700_000_000
        ),
        updatedAt: Date = Date(
            timeIntervalSince1970: 1_700_000_000
        )
    ) -> TerminalSessionRecord {
        let resolvedKey = scopedKey
            ?? "session:\(id.uuidString)"
        return TerminalSessionRecord(
            id: id, hostID: hostID,
            worktreeID: worktreeID,
            scopedKey: resolvedKey,
            presetID: presetID,
            kind: kind, launchMode: launchMode,
            backend: backend,
            workingDirectory: workingDirectory,
            command: command,
            childPID: childPID,
            remoteLocator: remoteLocator,
            isAlive: isAlive,
            restartPolicy: restartPolicy,
            lastExitCode: lastExitCode,
            lastOutputAt: lastOutputAt,
            lastSeenInSnapshotAt: lastSeenInSnapshotAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
