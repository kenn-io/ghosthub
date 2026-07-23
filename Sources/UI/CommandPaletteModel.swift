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
    case newWorktree(UUID)
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
        isWorkspacesRoute: Bool = true,
        isSidebarVisible: Bool,
        isSidePanelVisible: Bool,
        interfaceAppearance: AppearancePreference = .system,
        worktreeVisibility: WorktreeVisibility = .default,
        supportsSettings: Bool = true
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
        commands.append(contentsOf: newWorktreeCommands(
            in: snapshot,
            selection: selection
        ))
        commands.append(contentsOf: projectCommands(
            in: snapshot,
            visibility: worktreeVisibility
        ))
        commands.append(contentsOf: worktreeCommands(
            in: snapshot,
            visibility: worktreeVisibility
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
        visibility: WorktreeVisibility = .default
    ) -> [WorkspaceCommandItem] {
        let rows = WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: visibility
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
