import Foundation
import GhosthubWorkspace

public enum WorkspaceSidebarOrderStorage {
    public static let worktreeKey = "workspaceSidebarWorktreeOrderV1"
    public static let tmuxSessionKey = "workspaceSidebarTmuxSessionOrderV1"

    public static func worktreeRawValue(
        in defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: worktreeKey) ?? ""
    }
}

struct WorkspaceSidebarOrder: Equatable {
    private var itemIDs: [String]

    init(rawValue: String = "") {
        var seen = Set<String>()
        itemIDs = rawValue
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }

    var rawValue: String {
        itemIDs.joined(separator: "\n")
    }

    func ordered<Item>(
        _ items: [Item],
        identifiedBy identifier: (Item) -> String
    ) -> [Item] {
        let positions = Dictionary(
            uniqueKeysWithValues: itemIDs.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        return items.enumerated().sorted { lhs, rhs in
            let lhsPosition = positions[identifier(lhs.element)]
            let rhsPosition = positions[identifier(rhs.element)]
            switch (lhsPosition, rhsPosition) {
            case let (lhsPosition?, rhsPosition?):
                return lhsPosition < rhsPosition
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }

    mutating func move(
        _ sourceID: String,
        to targetID: String,
        within groupItemIDs: [String]
    ) -> Bool {
        guard sourceID != targetID else { return false }

        let groupIDSet = Set(groupItemIDs)
        var orderedGroupIDs = orderedIDs(groupItemIDs)
        guard let sourceIndex = orderedGroupIDs.firstIndex(of: sourceID),
              let targetIndex = orderedGroupIDs.firstIndex(of: targetID)
        else { return false }
        orderedGroupIDs.remove(at: sourceIndex)
        guard let orderedTargetIndex = orderedGroupIDs.firstIndex(of: targetID)
        else { return false }
        let insertionIndex = sourceIndex < targetIndex
            ? orderedTargetIndex + 1
            : orderedTargetIndex
        orderedGroupIDs.insert(sourceID, at: insertionIndex)

        var replacements = orderedGroupIDs.makeIterator()
        itemIDs = itemIDs.map { itemID in
            guard groupIDSet.contains(itemID) else { return itemID }
            return replacements.next() ?? itemID
        }
        while let replacement = replacements.next() {
            itemIDs.append(replacement)
        }
        return true
    }

    mutating func prune(keeping knownItemIDs: Set<String>) -> Bool {
        let pruned = itemIDs.filter(knownItemIDs.contains)
        guard pruned != itemIDs else { return false }
        itemIDs = pruned
        return true
    }

    private func orderedIDs(_ ids: [String]) -> [String] {
        let positions = Dictionary(
            uniqueKeysWithValues: itemIDs.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        return ids.enumerated().sorted { lhs, rhs in
            let lhsPosition = positions[lhs.element]
            let rhsPosition = positions[rhs.element]
            switch (lhsPosition, rhsPosition) {
            case let (lhsPosition?, rhsPosition?):
                return lhsPosition < rhsPosition
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }
}

enum WorkspaceSidebarPruningPolicy {
    static func shouldPrune(
        refreshComplete: Bool,
        inventoryWarning: String?,
        inventoryWarningsByHost: [UUID: String]
    ) -> Bool {
        refreshComplete
            && inventoryWarning == nil
            && inventoryWarningsByHost.isEmpty
    }
}

enum WorkspaceSidebarDropPlacement: Equatable {
    case before
    case after

    static func resolve(
        sourceID: String,
        targetID: String,
        orderedIDs: [String]
    ) -> Self? {
        guard sourceID != targetID,
              let sourceIndex = orderedIDs.firstIndex(of: sourceID),
              let targetIndex = orderedIDs.firstIndex(of: targetID)
        else { return nil }
        return sourceIndex < targetIndex ? .after : .before
    }
}

public struct WorkspaceTmuxSessionSelection:
    Equatable, Hashable, Identifiable, Sendable {
    public var hostID: UUID
    public var name: String
    public var worktreeID: UUID?
    public var worktreePath: String?
    public var worktreeGeneration: String?
    public var socketName: String?

    public init(
        hostID: UUID,
        name: String,
        worktreeID: UUID? = nil,
        worktreePath: String? = nil,
        worktreeGeneration: String? = nil,
        socketName: String? = nil
    ) {
        self.hostID = hostID
        self.name = name
        self.worktreeID = worktreeID
        self.worktreePath = worktreePath
        self.worktreeGeneration = worktreeGeneration
        self.socketName = socketName
    }

    public var id: String {
        [
            hostID.uuidString,
            socketName ?? "default",
            name,
        ].joined(separator: ":")
    }
}

public enum WorkspaceSidebarRowIcon: Equatable, Sendable {
    case localHost
    case remoteHost
    case exeDevHost
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
        case .exeDevHost:
            return "cloud"
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
    public var isEmpty: Bool {
        projects.isEmpty && tmuxSessionRows.isEmpty
    }

    public var row: WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .host(host.id),
            icon: host.kind == .selfHost
                ? .localHost
                : host.exeVM == nil ? .remoteHost : .exeDevHost,
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
            worktreeGeneration: worktree.generation,
            socketName: worktree.tmuxSocketName
        )
    }

    public static func canRequestKill(
        _ selection: WorkspaceTmuxSessionSelection,
        in snapshot: WorkspaceSnapshot,
        activeSelection: WorkspaceTmuxSessionSelection? = nil,
        activeSelectionIsConnected: Bool = false
    ) -> Bool {
        if activeSelectionIsConnected,
           activeSelection?.id == selection.id {
            return true
        }
        guard selection.socketName == nil else {
            return false
        }
        return snapshot.host(id: selection.hostID)?.tmuxSessions.contains {
            $0.name == selection.name && $0.hasStableIdentity
        } == true
    }

    public static func killableTmuxSession(
        for worktree: WorktreeSummary,
        in snapshot: WorkspaceSnapshot,
        activeSelection: WorkspaceTmuxSessionSelection? = nil,
        activeSelectionIsConnected: Bool = false
    ) -> WorkspaceTmuxSessionSelection? {
        guard let selection = tmuxSessionSelection(for: worktree),
              canRequestKill(
                  selection,
                  in: snapshot,
                  activeSelection: activeSelection,
                  activeSelectionIsConnected: activeSelectionIsConnected
              )
        else { return nil }
        return selection
    }

    public static func sections(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility = .default,
        tmuxSessionVisibility: TmuxSessionVisibility = TmuxSessionVisibility(),
        worktreeOrderRawValue: String = "",
        tmuxSessionOrderRawValue: String = ""
    ) -> [WorkspaceSidebarSection] {
        let worktreeOrder = WorkspaceSidebarOrder(
            rawValue: worktreeOrderRawValue
        )
        let tmuxSessionOrder = WorkspaceSidebarOrder(
            rawValue: tmuxSessionOrderRawValue
        )
        return snapshot.hosts.map { host in
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
                    let worktrees = worktreeOrder.ordered(
                        snapshot.worktrees.filter {
                            $0.hostID == host.id
                                && $0.projectID == project.id
                                && !$0.isStale
                                && visibility.includes($0)
                        },
                        identifiedBy: { $0.id.uuidString }
                    )
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
                tmuxSessionRows: tmuxSessionOrder.ordered(
                    host.tmuxSessions
                        .filter {
                            !defaultServerSessionNames.contains($0.name)
                                && !tmuxSessionVisibility.isHidden($0.name)
                        }
                        .sorted {
                            $0.name.localizedStandardCompare($1.name)
                                == .orderedAscending
                        },
                    identifiedBy: {
                        tmuxSessionOrderID(
                            hostID: host.id,
                            name: $0.name
                        )
                    }
                )
                .map { tmuxSessionRow($0, hostID: host.id) }
            )
        }
    }

    static func tmuxSessionOrderID(
        hostID: UUID,
        name: String
    ) -> String {
        "\(hostID.uuidString):\(name)"
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
