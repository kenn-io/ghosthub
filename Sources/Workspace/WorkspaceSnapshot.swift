import Foundation

public struct WorkspaceSnapshot: Equatable, Sendable {
    public var generation: UInt64
    public var platformAuthenticated: Bool
    public var activePlatformHost: String?
    public var hosts: [HostSummary]
    public var projects: [ProjectSummary]
    public var worktrees: [WorktreeSummary]
    public var sessions: [TerminalSessionSummary]
    public var projectMap: [String: String]

    public init(
        generation: UInt64 = 0,
        platformAuthenticated: Bool = false,
        activePlatformHost: String? = nil,
        hosts: [HostSummary],
        projects: [ProjectSummary],
        worktrees: [WorktreeSummary],
        sessions: [TerminalSessionSummary] = [],
        projectMap: [String: String] = [:]
    ) {
        self.generation = generation
        self.platformAuthenticated = platformAuthenticated
        self.activePlatformHost = activePlatformHost
        self.hosts = hosts
        self.projects = projects
        self.worktrees = worktrees
        self.sessions = sessions
        self.projectMap = projectMap
    }

    public func host(id: UUID) -> HostSummary? {
        hosts.first { $0.id == id }
    }

    public func project(id: UUID) -> ProjectSummary? {
        projects.first { $0.id == id }
    }

    public func worktree(id: UUID) -> WorktreeSummary? {
        worktrees.first { $0.id == id }
    }

    public func canCreateWorktree(in project: ProjectSummary) -> Bool {
        !project.isSynthesized
            && !project.isStale
            && host(id: project.hostID)?.canCreateWorktree == true
    }

    public func canImportPullRequest(in project: ProjectSummary) -> Bool {
        !project.isSynthesized
            && !project.isStale
            && project.scopedKey.lowercased().hasPrefix("github.com/")
            && host(id: project.hostID)?.canImportPullRequest == true
    }

    public func sessions(
        for worktreeID: UUID
    ) -> [TerminalSessionSummary] {
        sessions.filter { $0.worktreeID == worktreeID }
    }
}

extension WorkspaceSnapshot {
    public static let empty = WorkspaceSnapshot(
        hosts: [], projects: [], worktrees: []
    )

    public var hostsByID: [UUID: HostSummary] {
        Dictionary(
            hosts.map { ($0.id, $0) }
        ) { first, _ in first }
    }

    public var hostsByConfigKey: [String: HostSummary] {
        Dictionary(
            hosts.map { ($0.configKey, $0) }
        ) { first, _ in first }
    }

    public var projectsByID: [UUID: ProjectSummary] {
        Dictionary(
            projects.map { ($0.id, $0) }
        ) { first, _ in first }
    }

    public var worktreesByID: [UUID: WorktreeSummary] {
        Dictionary(
            worktrees.map { ($0.id, $0) }
        ) { first, _ in first }
    }

    public var worktreesByHostScopedKey:
        [HostScopedKey: WorktreeSummary] {
        Dictionary(
            worktrees.map {
                (
                    HostScopedKey(
                        hostID: $0.hostID,
                        scopedKey: $0.scopedKey
                    ),
                    $0
                )
            }
        ) { first, _ in first }
    }
}

public enum ConsoleBindingMode: String, Equatable, Sendable {
    case followSelectedHost
    case pinHost
}

public struct WorkspaceSelection: Equatable, Sendable {
    public var selectedHostID: UUID
    public var selectedProjectID: UUID?
    public var selectedWorktreeID: UUID?
    public internal(set) var consoleBindingMode: ConsoleBindingMode
    public internal(set) var pinnedConsoleHostID: UUID?

    public init(
        selectedHostID: UUID,
        selectedProjectID: UUID? = nil,
        selectedWorktreeID: UUID? = nil,
        consoleBindingMode: ConsoleBindingMode = .followSelectedHost,
        pinnedConsoleHostID: UUID? = nil
    ) {
        self.selectedHostID = selectedHostID
        self.selectedProjectID = selectedProjectID
        self.selectedWorktreeID = selectedWorktreeID
        self.pinnedConsoleHostID = pinnedConsoleHostID

        // Pin mode requires a pinned host; fall back to follow mode
        // so boundConsoleHostID never silently retargets to the
        // selected host through a different code path.
        if consoleBindingMode == .pinHost, pinnedConsoleHostID == nil {
            self.consoleBindingMode = .followSelectedHost
        } else {
            self.consoleBindingMode = consoleBindingMode
        }
    }

    public var boundConsoleHostID: UUID {
        switch consoleBindingMode {
        case .followSelectedHost:
            return selectedHostID
        case .pinHost:
            return pinnedConsoleHostID ?? selectedHostID
        }
    }

    public mutating func setConsoleBinding(
        mode: ConsoleBindingMode,
        pinnedHostID: UUID? = nil
    ) {
        if mode == .pinHost, let pinnedHostID {
            consoleBindingMode = .pinHost
            pinnedConsoleHostID = pinnedHostID
        } else {
            consoleBindingMode = .followSelectedHost
            pinnedConsoleHostID = nil
        }
    }
}
