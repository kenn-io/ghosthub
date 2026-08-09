import Foundation
import GhosthubSettings
import GhosthubWorkspace

public enum WorkspaceCommandShortcut: Equatable, Sendable {
    case commandB
    case commandShiftP
    case commandShiftComma
    case commandShiftN
    case commandShiftI
    case commandShiftDelete
    case commandOptionUp
    case commandOptionDown
    case commandDigit(Int)

    public var displayText: String {
        switch self {
        case .commandB:
            return "Cmd+B"
        case .commandShiftP:
            return "Cmd+Shift+P"
        case .commandShiftComma:
            return "Cmd+Shift+,"
        case .commandShiftN:
            return "Cmd+Shift+N"
        case .commandShiftI:
            return "Cmd+Shift+I"
        case .commandShiftDelete:
            return "Cmd+Shift+Delete"
        case .commandOptionUp:
            return "Cmd+Opt+Up"
        case .commandOptionDown:
            return "Cmd+Opt+Down"
        case let .commandDigit(index):
            return "Cmd+\(index)"
        }
    }
}

public enum WorkspaceCommandAction: Equatable, Sendable {
    case toggleSidebar
    case openConfigDirectory
    case reloadTerminalConfig
    case previousWorktree
    case nextWorktree
    case newTmuxSession(UUID)
    case newHerdrSession(UUID)
    case addProject(UUID)
    case openTmuxSession(WorkspaceTmuxSessionSelection)
    case openHerdrSession(WorkspaceHerdrSessionSelection)
    case restartHerdrSession(WorkspaceHerdrSessionSelection)
    case stopHerdrSession(WorkspaceHerdrSessionSelection)
    case deleteHerdrSession(WorkspaceHerdrSessionSelection)
    case killTmuxSession(WorkspaceTmuxSessionSelection)
    case applyThemeToCurrentTmuxSession(
        WorkspaceTmuxSessionSelection
    )
    case newWorktree(UUID)
    case importPullRequest(UUID)
    case openSettings(SettingsDomain)
    case setInterfaceAppearance(AppearancePreference)
    case select(WorkspaceNavigationTarget)
    case showLogViewer
}

public struct WorkspaceCommandItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: [String]
    public let shortcut: WorkspaceCommandShortcut?
    public let action: WorkspaceCommandAction

    public init(
        id: String,
        title: String,
        subtitle: String,
        keywords: [String] = [],
        shortcut: WorkspaceCommandShortcut? = nil,
        action: WorkspaceCommandAction
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.shortcut = shortcut
        self.action = action
    }
}

public enum CommandPaletteSelection: Sendable {
    public enum Direction: Sendable {
        case up, down
    }

    public static func moved(
        from index: Int?,
        direction: Direction,
        count: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        switch direction {
        case .down:
            guard let i = index else { return 0 }
            return (i + 1) % count
        case .up:
            guard let i = index else { return count - 1 }
            return (i - 1 + count) % count
        }
    }

    public static func resolved(
        selectedIndex: Int?,
        count: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        guard let i = selectedIndex, i < count else {
            return 0
        }
        return i
    }
}

public enum CommandPaletteModel {
    public static func commands(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection,
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeTmuxSessionIsConnected: Bool = false,
        activeTmuxSessionCanApplyTheme: Bool = false,
        isWorkspacesRoute: Bool = true,
        isSidebarVisible: Bool,
        isSidePanelVisible: Bool,
        interfaceAppearance: AppearancePreference = .system,
        worktreeVisibility: WorktreeVisibility = .default,
        tmuxSessionVisibility: TmuxSessionVisibility = TmuxSessionVisibility(),
        supportsSettings: Bool = true,
        worktreeOrderRawValue: String = "",
        tmuxSessionOrderRawValue: String = "",
        herdrSessionOrderRawValue: String = "",
        pendingHerdrSessions: Set<WorkspaceHerdrSessionSelection> = []
    ) -> [WorkspaceCommandItem] {
        var commands = [
            WorkspaceCommandItem(
                id: "toggle-sidebar",
                title: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                subtitle: "Toggle the project and worktree navigation sidebar.",
                keywords: ["sidebar", "navigation", "toggle"],
                shortcut: .commandB,
                action: .toggleSidebar
            ),
            WorkspaceCommandItem(
                id: "open-config-directory",
                title: "Open Ghosthub config directory",
                subtitle: "Open ~/.config/ghosthub in Finder.",
                keywords: ["open", "ghosthub", "config", "directory", "finder", "settings"],
                action: .openConfigDirectory
            ),
            WorkspaceCommandItem(
                id: "reload-terminal-config",
                title: "Reload Configuration",
                subtitle: "Reload the active Ghosthub terminal configuration.",
                keywords: [
                    "reload", "terminal", "config", "ghostty.conf",
                ],
                shortcut: .commandShiftComma,
                action: .reloadTerminalConfig
            ),
            WorkspaceCommandItem(
                id: "show-log-viewer",
                title: "Show Application Log",
                subtitle: "Open a terminal viewing the Ghosthub log file.",
                keywords: ["log", "viewer", "debug", "diagnostic", "tail"],
                action: .showLogViewer
            ),
            WorkspaceCommandItem(
                id: "previous-worktree",
                title: "Previous Worktree",
                subtitle: "Cycle backward through worktrees in sidebar order.",
                keywords: ["previous", "worktree", "cycle"],
                shortcut: .commandOptionUp,
                action: .previousWorktree
            ),
            WorkspaceCommandItem(
                id: "next-worktree",
                title: "Next Worktree",
                subtitle: "Cycle forward through worktrees in sidebar order.",
                keywords: ["next", "worktree", "cycle"],
                shortcut: .commandOptionDown,
                action: .nextWorktree
            ),
        ]

        commands.append(contentsOf: appearanceCommands(current: interfaceAppearance))
        commands.append(contentsOf: settingsCommands(
            supportsSettings: supportsSettings
        ))
        commands.append(contentsOf: hostCommands(in: snapshot))
        commands.append(contentsOf: hostActionCommands(in: snapshot))
        commands.append(contentsOf: activeTmuxThemeCommands(
            activeSelection: activeTmuxSession,
            activeSelectionIsConnected:
            activeTmuxSessionIsConnected,
            canApplyTheme: activeTmuxSessionCanApplyTheme
        ))
        commands.append(contentsOf: tmuxSessionCommands(
            in: snapshot,
            activeSelection: activeTmuxSession,
            activeSelectionIsConnected: activeTmuxSessionIsConnected,
            visibility: worktreeVisibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            worktreeOrderRawValue: worktreeOrderRawValue,
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue
        ))
        commands.append(contentsOf: herdrSessionCommands(
            in: snapshot,
            visibility: worktreeVisibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            worktreeOrderRawValue: worktreeOrderRawValue,
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue,
            herdrSessionOrderRawValue: herdrSessionOrderRawValue,
            pendingHerdrSessions: pendingHerdrSessions
        ))
        commands.append(contentsOf: newWorktreeCommands(
            in: snapshot,
            selection: selection
        ))
        commands.append(contentsOf: importPullRequestCommands(
            in: snapshot,
            selection: selection
        ))
        commands.append(contentsOf: projectCommands(
            in: snapshot,
            visibility: worktreeVisibility
        ))
        commands.append(contentsOf: worktreeCommands(
            in: snapshot,
            visibility: worktreeVisibility,
            worktreeOrderRawValue: worktreeOrderRawValue
        ))
        return commands
    }

    private static func selectedProjectID(
        from selection: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot
    ) -> UUID? {
        WorkspaceSelectionResolver.selectedProjectID(
            in: snapshot,
            selection: selection
        )
    }

    private static func orderedSidebarProjects(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) -> [WorkspaceSidebarProject] {
        let selectedProjectID = selectedProjectID(from: selection, in: snapshot)
        let projects = WorkspaceSidebarModel.sections(in: snapshot)
            .flatMap(\.projects)

        return projects.sorted { lhs, rhs in
            switch (
                lhs.project.id == selectedProjectID,
                rhs.project.id == selectedProjectID
            ) {
            case (true, false):
                return true
            case (false, true):
                return false
            default:
                return lhs.project.name.localizedCaseInsensitiveCompare(
                    rhs.project.name
                ) == .orderedAscending
            }
        }
    }

    public static func filteredCommands(
        _ commands: [WorkspaceCommandItem],
        query: String
    ) -> [WorkspaceCommandItem] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !tokens.isEmpty else {
            return commands
        }

        let matches = commands.enumerated().compactMap {
            index, command -> (index: Int, command: WorkspaceCommandItem)? in
            let haystack = ([command.title, command.subtitle] + command.keywords)
                .joined(separator: " ")
                .lowercased()
            guard tokens.allSatisfy({ haystack.contains($0) }) else {
                return nil
            }
            return (index, command)
        }

        return matches.map(\.command)
    }

    private static func appearanceCommands(
        current: AppearancePreference
    ) -> [WorkspaceCommandItem] {
        [
            WorkspaceCommandItem(
                id: "appearance-system",
                title: current == .system ? "Follow System Appearance" : "Use System Appearance",
                subtitle: current == .system ? "Ghosthub is already following macOS appearance." :
                    "Match the app chrome to macOS Light or Dark mode.",
                keywords: ["appearance", "theme", "system", "light", "dark", "mode"],
                action: .setInterfaceAppearance(.system)
            ),
            WorkspaceCommandItem(
                id: "appearance-light",
                title: current == .light ? "Use Light Appearance (Current)" :
                    "Use Light Appearance",
                subtitle: "Force Ghosthub’s app chrome into Light mode.",
                keywords: ["appearance", "theme", "light", "mode"],
                action: .setInterfaceAppearance(.light)
            ),
            WorkspaceCommandItem(
                id: "appearance-dark",
                title: current == .dark ? "Use Dark Appearance (Current)" : "Use Dark Appearance",
                subtitle: "Force Ghosthub’s app chrome into Dark mode.",
                keywords: ["appearance", "theme", "dark", "mode"],
                action: .setInterfaceAppearance(.dark)
            ),
        ]
    }

    private static func settingsCommands(
        supportsSettings: Bool
    ) -> [WorkspaceCommandItem] {
        let domainCommands: [WorkspaceCommandItem]
        if supportsSettings {
            let domains: [SettingsDomain] = [
                .appearance,
                .terminal,
                .keyboard,
                .worktrees,
                .agents,
                .hosts,
                .integrations,
            ]
            domainCommands = domains.map { domain in
                WorkspaceCommandItem(
                    id: "settings-\(domain.rawValue)",
                    title: "Open \(domain.title) Settings",
                    subtitle: "Open the \(domain.title.lowercased()) section in Options.",
                    keywords: ["settings", "options", domain.title.lowercased()],
                    action: .openSettings(domain)
                )
            }
        } else {
            domainCommands = []
        }

        return domainCommands
    }

    private static func hostCommands(in snapshot: WorkspaceSnapshot) -> [WorkspaceCommandItem] {
        snapshot.hosts.map { host in
            WorkspaceCommandItem(
                id: "host-\(host.id.uuidString)",
                title: "Select Host: \(host.name)",
                subtitle: host.commandPaletteSubtitle,
                keywords: host.searchKeywords,
                action: .select(.host(host.id))
            )
        }
    }

    private static func hostActionCommands(
        in snapshot: WorkspaceSnapshot
    ) -> [WorkspaceCommandItem] {
        snapshot.hosts.flatMap { host in
            var commands = [
                WorkspaceCommandItem(
                    id: "new-tmux-session-\(host.id.uuidString)",
                    title: "New tmux session on \(host.name)",
                    subtitle: "Create and attach on \(host.commandPaletteSubtitle)",
                    keywords: [
                        "new", "create", "tmux", "session",
                        host.name, host.sshDestination ?? "",
                    ],
                    action: .newTmuxSession(host.id)
                ),
            ]
            if host.herdrAvailable {
                commands.append(WorkspaceCommandItem(
                    id: "new-herdr-session-\(host.id.uuidString)",
                    title: "New Herdr session on \(host.name)",
                    subtitle: "Create and attach on \(host.commandPaletteSubtitle)",
                    keywords: [
                        "new", "create", "herdr", "session",
                        host.name, host.sshDestination ?? "",
                    ],
                    action: .newHerdrSession(host.id)
                ))
            }
            if host.canRegisterProjects {
                commands.append(WorkspaceCommandItem(
                    id: "add-project-\(host.id.uuidString)",
                    title: "Add Project on \(host.name)",
                    subtitle: "Register an existing checkout with kwt.",
                    keywords: [
                        "add", "register", "project", "repository", "kwt",
                        host.name, host.sshDestination ?? "",
                    ],
                    action: .addProject(host.id)
                ))
            }
            return commands
        }
    }

    private static func tmuxSessionCommands(
        in snapshot: WorkspaceSnapshot,
        activeSelection: WorkspaceTmuxSessionSelection?,
        activeSelectionIsConnected: Bool,
        visibility: WorktreeVisibility,
        tmuxSessionVisibility: TmuxSessionVisibility,
        worktreeOrderRawValue: String,
        tmuxSessionOrderRawValue: String
    ) -> [WorkspaceCommandItem] {
        let sections = WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            worktreeOrderRawValue: worktreeOrderRawValue,
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue
        )
        let sessions = sections.flatMap { section -> [(
            session: WorkspaceTmuxSessionSelection,
            hostName: String,
            canRequestKill: Bool,
            keywords: [String]
        )] in
            let discovered: [(
                session: WorkspaceTmuxSessionSelection,
                hostName: String,
                canRequestKill: Bool,
                keywords: [String]
            )] = section.tmuxSessionRows.compactMap { row in
                guard case let .tmuxSession(hostID, name) = row.target else {
                    return nil
                }
                let session = WorkspaceTmuxSessionSelection(
                    hostID: hostID,
                    name: name
                )
                return (
                    session,
                    section.host.name,
                    WorkspaceSidebarModel.canRequestKill(
                        session,
                        in: snapshot,
                        activeSelection: activeSelection,
                        activeSelectionIsConnected:
                        activeSelectionIsConnected
                    ),
                    [row.title, row.subtitle ?? "", section.row.title]
                )
            }
            let worktrees: [(
                session: WorkspaceTmuxSessionSelection,
                hostName: String,
                canRequestKill: Bool,
                keywords: [String]
            )] = section.projects.flatMap { project in
                project.worktrees.compactMap { worktree in
                    guard let session = WorkspaceSidebarModel
                        .tmuxSessionSelection(for: worktree)
                    else { return nil }
                    return (
                        session,
                        section.host.name,
                        WorkspaceSidebarModel.canRequestKill(
                            session,
                            in: snapshot,
                            activeSelection: activeSelection,
                            activeSelectionIsConnected:
                            activeSelectionIsConnected
                        ),
                        [
                            worktree.name,
                            worktree.path,
                            project.project.name,
                            section.row.title,
                        ]
                    )
                }
            }
            let directories: [(
                session: WorkspaceTmuxSessionSelection,
                hostName: String,
                canRequestKill: Bool,
                keywords: [String]
            )] = section.directoryWorkspaceRows.compactMap { row in
                guard case let .directoryWorkspace(directoryID) = row.target,
                      let directory = snapshot.directoryWorkspace(
                          id: directoryID
                      )
                else { return nil }
                let session = WorkspaceSidebarModel.tmuxSessionSelection(
                    for: directory
                )
                return (
                    session,
                    section.host.name,
                    WorkspaceSidebarModel.canRequestKill(
                        session,
                        in: snapshot,
                        activeSelection: activeSelection,
                        activeSelectionIsConnected: activeSelectionIsConnected
                    ),
                    [
                        directory.name,
                        directory.path,
                        section.row.title,
                    ]
                )
            }
            let workspaceSessions = worktrees + directories
            let workspaceSessionIDs = Set(
                workspaceSessions.map { $0.session.id }
            )
            return workspaceSessions + discovered.filter {
                !workspaceSessionIDs.contains($0.session.id)
            }
        }

        return sessions.flatMap {
            session, hostName, canRequestKill, keywords in
            var commands = [
                WorkspaceCommandItem(
                    id: "open-tmux-session-\(session.id)",
                    title: "Open tmux session: \(session.name)",
                    subtitle: "Attach on \(hostName).",
                    keywords: ["open", "attach", "tmux", "session"]
                        + keywords,
                    action: .openTmuxSession(session)
                ),
            ]
            if canRequestKill {
                commands.append(WorkspaceCommandItem(
                    id: "kill-tmux-session-\(session.id)",
                    title: "Kill tmux session: \(session.name)",
                    subtitle: "Terminate every pane and process on \(hostName).",
                    keywords: [
                        "kill", "terminate", "stop", "tmux", "session",
                    ] + keywords,
                    action: .killTmuxSession(session)
                ))
            }
            return commands
        }
    }

    private static func activeTmuxThemeCommands(
        activeSelection: WorkspaceTmuxSessionSelection?,
        activeSelectionIsConnected: Bool,
        canApplyTheme: Bool
    ) -> [WorkspaceCommandItem] {
        guard let activeSelection,
              activeSelectionIsConnected,
              canApplyTheme
        else { return [] }
        return [
            WorkspaceCommandItem(
                id: "apply-theme-to-current-tmux-session",
                title: "Apply Theme to Current Session",
                subtitle: "Apply the selected theme to \(activeSelection.name) and every attached client.",
                keywords: [
                    "apply", "retheme", "theme", "tmux", "session",
                    activeSelection.name,
                ],
                action: .applyThemeToCurrentTmuxSession(
                    activeSelection
                )
            ),
        ]
    }

    private static func herdrSessionCommands(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility,
        tmuxSessionVisibility: TmuxSessionVisibility,
        worktreeOrderRawValue: String,
        tmuxSessionOrderRawValue: String,
        herdrSessionOrderRawValue: String,
        pendingHerdrSessions: Set<WorkspaceHerdrSessionSelection>
    ) -> [WorkspaceCommandItem] {
        WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility,
            tmuxSessionVisibility: tmuxSessionVisibility,
            worktreeOrderRawValue: worktreeOrderRawValue,
            tmuxSessionOrderRawValue: tmuxSessionOrderRawValue,
            herdrSessionOrderRawValue: herdrSessionOrderRawValue
        ).flatMap { section in
            section.herdrSessionRows.flatMap { row -> [WorkspaceCommandItem] in
                guard case let .herdrSession(hostID, name) = row.target else {
                    return []
                }
                let session = WorkspaceHerdrSessionSelection(
                    hostID: hostID,
                    name: name
                )
                guard !pendingHerdrSessions.contains(session) else { return [] }
                let keywords = [
                    "herdr", "session", name,
                    section.host.name, section.row.title,
                ]
                switch row.herdrSessionState {
                case .running:
                    return [
                        WorkspaceCommandItem(
                            id: "open-herdr-session-\(session.id)",
                            title: "Open Herdr session: \(name)",
                            subtitle: "Attach on \(section.host.name).",
                            keywords: ["open", "attach"] + keywords,
                            action: .openHerdrSession(session)
                        ),
                        WorkspaceCommandItem(
                            id: "stop-herdr-session-\(session.id)",
                            title: "Stop Herdr session: \(name)",
                            subtitle: "Stop every process on \(section.host.name).",
                            keywords: ["stop", "terminate"] + keywords,
                            action: .stopHerdrSession(session)
                        ),
                    ]
                case .stopped:
                    var commands = [WorkspaceCommandItem(
                        id: "restart-herdr-session-\(session.id)",
                        title: "Restart Herdr session: \(name)",
                        subtitle: "Restore its saved shape and attach on \(section.host.name).",
                        keywords: ["restart", "start", "attach"] + keywords,
                        action: .restartHerdrSession(session)
                    )]
                    if row.herdrSessionIsDefault != true {
                        commands.append(WorkspaceCommandItem(
                            id: "delete-herdr-session-\(session.id)",
                            title: "Delete Herdr session: \(name)",
                            subtitle: "Permanently remove its saved state on \(section.host.name).",
                            keywords: ["delete", "remove"] + keywords,
                            action: .deleteHerdrSession(session)
                        ))
                    }
                    return commands
                case nil:
                    return []
                }
            }
        }
    }

    private static func newWorktreeCommands(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) -> [WorkspaceCommandItem] {
        orderedSidebarProjects(in: snapshot, selection: selection)
            .filter { snapshot.canCreateWorktree(in: $0.project) }
            .map { sidebarProject in
                let project = sidebarProject.project
                let projectName = sidebarProject.row.title
                let host = snapshot.host(id: project.hostID)
                return WorkspaceCommandItem(
                    id: "new-worktree-\(project.id.uuidString)",
                    title: "New Worktree in \(projectName)",
                    subtitle: host.map { "Create with kwt on \($0.name)." }
                        ?? "Create with kwt.",
                    keywords: [
                        "new", "create", "worktree", "kwt",
                        projectName, project.rootPath,
                    ],
                    shortcut: project.id == selectedProjectID(
                        from: selection,
                        in: snapshot
                    ) ? .commandShiftN : nil,
                    action: .newWorktree(project.id)
                )
            }
    }

    private static func importPullRequestCommands(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) -> [WorkspaceCommandItem] {
        orderedSidebarProjects(in: snapshot, selection: selection)
            .filter {
                snapshot.canImportPullRequest(in: $0.project)
            }
            .map { sidebarProject in
                let project = sidebarProject.project
                let projectName = sidebarProject.row.title
                let host = snapshot.host(id: project.hostID)
                return WorkspaceCommandItem(
                    id: "import-pr-\(project.id.uuidString)",
                    title: "Import Pull Request in \(projectName)",
                    subtitle: host.map {
                        "Discover and import with kwt on \($0.name)."
                    } ?? "Discover and import with kwt.",
                    keywords: [
                        "import", "pull", "request", "pr", "kwt",
                        projectName, project.rootPath,
                    ],
                    shortcut: project.id == selectedProjectID(
                        from: selection,
                        in: snapshot
                    ) ? .commandShiftI : nil,
                    action: .importPullRequest(project.id)
                )
            }
    }

    private static func projectCommands(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility = .default
    ) -> [WorkspaceCommandItem] {
        WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility
        ).flatMap { section in
            section.projects.map { sidebarProject in
                let row = sidebarProject.row
                return WorkspaceCommandItem(
                    id: "project-\(sidebarProject.project.id.uuidString)",
                    title: "Select Project: \(row.title)",
                    subtitle: row.subtitle ?? "",
                    keywords: [
                        row.title,
                        row.subtitle ?? "",
                        sidebarProject.project.rootPath,
                        section.row.title,
                    ],
                    action: row.selectAction
                )
            }
        }
    }

    private static func worktreeCommands(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility = .default,
        worktreeOrderRawValue: String = ""
    ) -> [WorkspaceCommandItem] {
        let rows = WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility,
            worktreeOrderRawValue: worktreeOrderRawValue
        )
        .flatMap { section in
            section.projects.flatMap { sidebarProject in
                sidebarProject.worktreeRows.map {
                    (row: $0, section: section, project: sidebarProject)
                }
            }
        }

        return rows.enumerated().compactMap { index, item in
            guard case let .worktree(worktreeID) = item.row.target,
                  let worktree = snapshot.worktree(id: worktreeID)
            else {
                return nil
            }
            let projectName = snapshot.project(id: worktree.projectID)?.name ?? ""
            let hostName = snapshot.host(id: worktree.hostID)?.name ?? ""
            return WorkspaceCommandItem(
                id: "worktree-\(worktree.id.uuidString)",
                title: "Switch to Worktree: \(item.row.title)",
                subtitle: "\(worktree.branch) · \(worktree.path)",
                keywords: [
                    item.row.title,
                    worktree.sidebarSubtitle,
                    worktree.branch,
                    worktree.path,
                    projectName,
                    hostName,
                    item.project.row.title,
                    item.section.row.title,
                ],
                shortcut: index < 9 ? .commandDigit(index + 1) : nil,
                action: item.row.selectAction
            )
        }
    }

}

private extension WorkspaceSidebarRow {
    var selectAction: WorkspaceCommandAction {
        .select(target)
    }
}
