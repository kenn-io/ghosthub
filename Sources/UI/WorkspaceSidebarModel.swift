import Foundation
import GhosthubWorkspace

public struct WorkspaceTmuxSessionSelection: Equatable, Sendable {
    public var hostID: UUID
    public var name: String
    public var worktreeID: UUID?
    public var worktreePath: String?
    public var socketName: String?

    public init(
        hostID: UUID,
        name: String,
        worktreeID: UUID? = nil,
        worktreePath: String? = nil,
        socketName: String? = nil
    ) {
        self.hostID = hostID
        self.name = name
        self.worktreeID = worktreeID
        self.worktreePath = worktreePath
        self.socketName = socketName
    }
}

public enum WorkspaceSidebarRowIcon: Equatable, Sendable {
    case localHost
    case remoteHost
    case project
    case primaryWorktree
    case worktree
    case tmuxSession

    public var systemImageName: String {
        switch self {
        case .localHost:
            return "laptopcomputer"
        case .remoteHost:
            return "server.rack"
        case .project:
            return "folder"
        case .primaryWorktree:
            return "square.stack.3d.up"
        case .worktree:
            return "point.3.connected.trianglepath.dotted"
        case .tmuxSession:
            return "terminal"
        }
    }
}

public struct WorkspaceSidebarRow: Equatable, Identifiable, Sendable {
    public var target: WorkspaceNavigationTarget
    public var icon: WorkspaceSidebarRowIcon
    public var title: String
    public var subtitle: String?
    public var indentLevel: Int
    /// Populated only for worktree rows; nil for host and project rows.
    public var worktreeStatus: WorktreeRowStatus?

    public var id: WorkspaceNavigationTarget { target }

    public init(
        target: WorkspaceNavigationTarget,
        icon: WorkspaceSidebarRowIcon,
        title: String,
        subtitle: String? = nil,
        indentLevel: Int = 0,
        worktreeStatus: WorktreeRowStatus? = nil
    ) {
        self.target = target
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.indentLevel = indentLevel
        self.worktreeStatus = worktreeStatus
    }
}

public struct WorkspaceSidebarSection: Equatable, Identifiable, Sendable {
    public var host: HostSummary
    public var projects: [WorkspaceSidebarProject]
    public var tmuxSessionRows: [WorkspaceSidebarRow]

    public var id: UUID { host.id }

    public var row: WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .host(host.id),
            icon: host.kind == .selfHost ? .localHost : .remoteHost,
            title: host.sidebarTitle,
            subtitle: host.sidebarSubtitle
        )
    }
}

public struct WorkspaceSidebarProject: Equatable, Identifiable, Sendable {
    public var project: ProjectSummary
    public var worktrees: [WorktreeSummary]
    /// Worktree rows with status derived from sessions in the snapshot.
    /// Built by `WorkspaceSidebarModel.sections(in:visibility:)`.
    public var worktreeRows: [WorkspaceSidebarRow]

    public var id: UUID { project.id }

    public var row: WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .project(project.id),
            icon: .project,
            title: project.sidebarTitle,
            subtitle: project.sidebarSubtitle
        )
    }
}

public enum WorkspaceSidebarModel {
    public static func tmuxSessionSelection(
        for selection: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot
    ) -> WorkspaceTmuxSessionSelection? {
        guard let worktreeID = selection.selectedWorktreeID,
              let worktree = snapshot.worktree(id: worktreeID)
        else { return nil }
        return tmuxSessionSelection(for: worktree)
    }

    public static func tmuxSessionSelection(
        for worktree: WorktreeSummary
    ) -> WorkspaceTmuxSessionSelection? {
        guard !worktree.isStale,
              let name = worktree.tmuxSessionName,
              !name.isEmpty
        else { return nil }
        return WorkspaceTmuxSessionSelection(
            hostID: worktree.hostID,
            name: name,
            worktreeID: worktree.id,
            worktreePath: worktree.path,
            socketName: worktree.tmuxSocketName
        )
    }

    public static func sections(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility = .default
    ) -> [WorkspaceSidebarSection] {
        snapshot.hosts.map { host in
            // Discovery only lists the host's default tmux server. A
            // protected PR workspace lives on its own socket, so its session
            // name never identifies a discovered session and must not
            // suppress an unrelated default-server session of the same name.
            let defaultServerSessionNames = Set(
                snapshot.worktrees.compactMap { worktree in
                    worktree.hostID == host.id && worktree.tmuxSocketName == nil
                        ? worktree.tmuxSessionName : nil
                }
            )
            let projects = snapshot.projects
                .filter {
                    $0.hostID == host.id
                        && !$0.isStale
                        && $0.kind == .repository
                }
                .map { project in
                    let worktrees = snapshot.worktrees.filter {
                        $0.hostID == host.id
                            && $0.projectID == project.id
                            && !$0.isStale
                            && visibility.includes($0)
                    }
                    let rows = worktrees.map { worktree in
                        worktreeRow(for: worktree, snapshot: snapshot)
                    }
                    return WorkspaceSidebarProject(
                        project: project,
                        worktrees: worktrees,
                        worktreeRows: rows
                    )
                }
            return WorkspaceSidebarSection(
                host: host,
                projects: projects,
                tmuxSessionRows: host.tmuxSessions
                    .filter { !defaultServerSessionNames.contains($0.name) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { tmuxSessionRow($0, hostID: host.id) }
            )
        }
    }

    private static func tmuxSessionRow(
        _ session: TmuxSessionSummary,
        hostID: UUID
    ) -> WorkspaceSidebarRow {
        let subtitle: String
        if !session.windows.isEmpty {
            subtitle = session.windows.count == 1
                ? "1 window"
                : "\(session.windows.count) windows"
        } else if session.managed {
            subtitle = "Workspace session"
        } else {
            subtitle = "Tmux session"
        }
        return WorkspaceSidebarRow(
            target: .tmuxSession(hostID: hostID, name: session.name),
            icon: .tmuxSession,
            title: session.name,
            subtitle: subtitle,
            indentLevel: 0
        )
    }

    private static func worktreeRow(
        for worktree: WorktreeSummary,
        snapshot: WorkspaceSnapshot
    ) -> WorkspaceSidebarRow {
        let sessions = snapshot.sessions(for: worktree.id)
        let status = WorktreeRowStatus.make(for: worktree, sessions: sessions)
        // The branch/PR lives in the status's second line and the detail
        // card, so worktree rows carry no subtitle. Command-palette search
        // reads worktree.sidebarSubtitle directly instead.
        return WorkspaceSidebarRow(
            target: .worktree(worktree.id),
            icon: worktree.isPrimary ? .primaryWorktree : .worktree,
            title: worktree.sidebarTitle,
            subtitle: nil,
            indentLevel: 1,
            worktreeStatus: status
        )
    }
}
