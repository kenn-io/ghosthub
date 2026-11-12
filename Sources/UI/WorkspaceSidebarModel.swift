import Foundation
import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

public enum WorkspaceSidebarOrderStorage {
    public static let hostKey = "workspaceSidebarHostOrder"
    public static let defaultHostOrder = "local"
    public static let worktreeKey = "workspaceSidebarWorktreeOrderV1"
    /// One manual order for every backend's sessions on every host.
    public static let sessionKey = "workspaceSidebarSessionOrderV2"

    public static func hostRawValue(
        in defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: hostKey) ?? defaultHostOrder
    }

    public static func worktreeRawValue(
        in defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: worktreeKey) ?? ""
    }

    public static func sessionRawValue(
        in defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: sessionKey) ?? ""
    }

    /// Keeps a renamed tmux session at its saved sidebar position.
    public static func renameTmuxSession(
        hostID: UUID,
        from oldName: String,
        to newName: String,
        in defaults: UserDefaults = .standard
    ) {
        var order = WorkspaceSidebarOrder(
            rawValue: sessionRawValue(in: defaults)
        )
        guard order.replace(
            WorkspaceSidebarModel.tmuxSessionOrderID(
                hostID: hostID,
                name: oldName
            ),
            with: WorkspaceSidebarModel.tmuxSessionOrderID(
                hostID: hostID,
                name: newName
            )
        ) else { return }
        defaults.set(order.rawValue, forKey: sessionKey)
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
        guard !itemIDs.isEmpty, items.count > 1 else { return items }
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

        replaceGroup(with: orderedGroupIDs)
        return true
    }

    mutating func move(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        within groupItemIDs: [String]
    ) {
        var orderedGroupIDs = orderedIDs(groupItemIDs)
        orderedGroupIDs.move(fromOffsets: source, toOffset: destination)
        replaceGroup(with: orderedGroupIDs)
    }

    private mutating func replaceGroup(with orderedGroupIDs: [String]) {
        let groupIDSet = Set(orderedGroupIDs)
        var replacements = orderedGroupIDs.makeIterator()
        itemIDs = itemIDs.map { itemID in
            guard groupIDSet.contains(itemID) else { return itemID }
            return replacements.next() ?? itemID
        }
        while let replacement = replacements.next() {
            itemIDs.append(replacement)
        }
    }

    mutating func replace(_ itemID: String, with newItemID: String) -> Bool {
        guard itemID != newItemID, itemIDs.contains(itemID) else {
            return false
        }
        itemIDs.removeAll { $0 == newItemID }
        itemIDs = itemIDs.map { $0 == itemID ? newItemID : $0 }
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
    public var directoryWorkspaceID: UUID?
    public var workspacePath: String?
    public var worktreeGeneration: String?
    public var socketName: String?
    public var tmuxAttachMode: TmuxAttachMode?

    public init(
        hostID: UUID,
        name: String,
        worktreeID: UUID? = nil,
        directoryWorkspaceID: UUID? = nil,
        workspacePath: String? = nil,
        worktreeGeneration: String? = nil,
        socketName: String? = nil,
        tmuxAttachMode: TmuxAttachMode? = nil
    ) {
        self.hostID = hostID
        self.name = name
        self.worktreeID = worktreeID
        self.directoryWorkspaceID = directoryWorkspaceID
        self.workspacePath = workspacePath
        self.worktreeGeneration = worktreeGeneration
        self.socketName = socketName
        self.tmuxAttachMode = tmuxAttachMode
    }

    /// Compatibility for callers that still construct a worktree-owned
    /// selection with the previous argument label.
    public init(
        hostID: UUID,
        name: String,
        worktreeID: UUID? = nil,
        worktreePath: String?,
        worktreeGeneration: String? = nil,
        socketName: String? = nil,
        tmuxAttachMode: TmuxAttachMode? = nil
    ) {
        self.init(
            hostID: hostID,
            name: name,
            worktreeID: worktreeID,
            workspacePath: worktreePath,
            worktreeGeneration: worktreeGeneration,
            socketName: socketName,
            tmuxAttachMode: tmuxAttachMode
        )
    }

    public var id: String {
        Self.canonicalEndpointID(
            hostID: hostID,
            name: name,
            socketName: socketName,
            tmuxAttachMode: tmuxAttachMode
        )
    }

    public static func canonicalEndpointID(
        hostID: UUID,
        name: String,
        socketName: String?,
        tmuxAttachMode: TmuxAttachMode?
    ) -> String {
        [
            hostID.uuidString,
            tmuxAttachMode == .direct
                ? "unbound" : tmuxAttachMode?.rawValue ?? "unbound",
            socketName ?? "default",
            name,
        ].joined(separator: ":")
    }

    @available(*, deprecated, renamed: "workspacePath")
    public var worktreePath: String? {
        get { workspacePath }
        set { workspacePath = newValue }
    }
}

public enum WorkspaceSidebarRowIcon: Equatable, Sendable {
    case localHost
    case remoteHost
    case exeDevHost
    case project
    case primaryWorktree
    case worktree
    case directoryWorkspace
    case tmuxSession
    case herdrSession
    case herdrTerminal
    case rexTerminal
    case zellijSession

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
        case .directoryWorkspace:
            return "folder.badge.gearshape"
        case .tmuxSession:
            return "terminal"
        case .herdrSession:
            return "rectangle.3.group"
        case .herdrTerminal:
            return "terminal"
        case .rexTerminal:
            return "rectangle.split.2x1"
        case .zellijSession:
            return "rectangle.split.3x1"
        }
    }
}

/// The multiplexer behind a session row. Case order is the Backend sort.
public enum WorkspaceSidebarSessionBackend: Int, CaseIterable, Comparable, Sendable {
    case tmux
    case zellij
    case herdrTerminal
    case herdrTUI
    case rex

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The short label shown on the row.
    public var label: String {
        switch self {
        case .tmux: "tmux"
        case .zellij: "zellij"
        case .herdrTerminal: "herdr"
        case .herdrTUI: "herdr tui"
        case .rex: "rex"
        }
    }

    /// The spoken and tooltip name.
    public var title: String {
        switch self {
        case .tmux: "tmux session"
        case .zellij: "Zellij session"
        case .herdrTerminal: "Herdr terminal"
        case .herdrTUI: "Herdr TUI session"
        case .rex: "Rex terminal"
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
    /// Derived once with inventory; flag membership stays outside this cache.
    public var worktreeFlagKey: WorktreeFlagKey?
    /// Direct tmux discovery state for non-worktree workspace rows.
    public var sessionIsRunning: Bool
    /// Populated only for Herdr session rows.
    public var herdrSessionState: HerdrSessionState?
    /// Populated only for Herdr session rows.
    public var herdrSessionIsDefault: Bool?

    public var id: WorkspaceNavigationTarget { target }

    /// Nil for host, project, worktree, and directory workspace rows.
    public var sessionBackend: WorkspaceSidebarSessionBackend? {
        switch target {
        case .tmuxSession: .tmux
        case .zellijSession: .zellij
        case .herdrSession: .herdrTUI
        case let .backendTerminal(_, kind, _):
            kind == .rex ? .rex : .herdrTerminal
        case .host, .project, .worktree, .directoryWorkspace: nil
        }
    }

    /// Quiet text after a session's name. Herdr desktop panes in one tab
    /// share a `space / tab` title, so their address tells them apart; a
    /// Rex terminal shows its session and window.
    public var sessionDetail: String? {
        guard sessionBackend == .herdrTerminal || sessionBackend == .rex,
              let subtitle, subtitle != title
        else { return nil }
        return subtitle
    }

    /// The row's identity in the shared manual session order.
    public var sessionOrderID: String? {
        switch target {
        case let .tmuxSession(hostID, name, socketName):
            WorkspaceSidebarModel.tmuxSessionOrderID(
                hostID: hostID,
                name: name,
                socketName: socketName
            )
        case let .herdrSession(hostID, name):
            WorkspaceSidebarModel.herdrSessionOrderID(hostID: hostID, name: name)
        case let .backendTerminal(hostID, kind, address):
            WorkspaceSidebarModel.backendTerminalOrderID(
                hostID: hostID,
                kind: kind,
                address: address
            )
        case let .zellijSession(hostID, name):
            WorkspaceSidebarModel.zellijSessionOrderID(
                hostID: hostID,
                name: name
            )
        case .host, .project, .worktree, .directoryWorkspace:
            nil
        }
    }

    public init(
        target: WorkspaceNavigationTarget,
        icon: WorkspaceSidebarRowIcon,
        title: String,
        subtitle: String? = nil,
        indentLevel: Int = 0,
        worktreeStatus: WorktreeRowStatus? = nil,
        worktreeFlagKey: WorktreeFlagKey? = nil,
        sessionIsRunning: Bool = false,
        herdrSessionState: HerdrSessionState? = nil,
        herdrSessionIsDefault: Bool? = nil
    ) {
        self.target = target
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.indentLevel = indentLevel
        self.worktreeStatus = worktreeStatus
        self.worktreeFlagKey = worktreeFlagKey
        self.sessionIsRunning = sessionIsRunning
        self.herdrSessionState = herdrSessionState
        self.herdrSessionIsDefault = herdrSessionIsDefault
    }
}

public struct WorkspaceSidebarSection: Equatable, Identifiable, Sendable {
    public var host: HostSummary
    public var projects: [WorkspaceSidebarProject]
    public var directoryWorkspaceRows: [WorkspaceSidebarRow]
    /// Every backend's sessions on this host, in display order.
    public var sessionRows: [WorkspaceSidebarRow]

    public func sessionRows(
        for backend: WorkspaceSidebarSessionBackend
    ) -> [WorkspaceSidebarRow] {
        sessionRows.filter { $0.sessionBackend == backend }
    }

    public var id: UUID { host.id }
    public var isEmpty: Bool {
        projects.isEmpty
            && directoryWorkspaceRows.isEmpty
            && sessionRows.isEmpty
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
    static func hostOrderID(_ host: HostSummary) -> String {
        if host.kind == .selfHost {
            return WorkspaceSidebarOrderStorage.defaultHostOrder
        }
        return hostOrderID(configKey: host.configKey)
    }

    static func hostOrderID(configKey: String) -> String {
        "host:\(configKey)"
    }

    static func orderedSettingsHosts(
        _ hosts: [SSHHostDraft],
        hostOrderRawValue: String
    ) -> [HostSettingsRow] {
        WorkspaceSidebarOrder(rawValue: hostOrderRawValue).ordered(
            [.local] + hosts.map(HostSettingsRow.ssh), identifiedBy: \.id
        )
    }

    static func updatingHostOrder(
        _ rawValue: String,
        from previous: [SSHHostDraft],
        to current: [SSHHostDraft]
    ) -> String {
        let changedKeys = Set(previous.map(\.configKey))
            .symmetricDifference(Set(current.map(\.configKey)))
        let changedIDs = Set(changedKeys.map { hostOrderID(configKey: $0) })
        // New drafts can reuse a removed or unsaved host's configuration key.
        return rawValue.split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .filter { !changedIDs.contains($0) }
            .joined(separator: "\n")
    }

    public static func tmuxSessionSelection(
        for selection: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot
    ) -> WorkspaceTmuxSessionSelection? {
        if let directoryWorkspaceID = selection.selectedDirectoryWorkspaceID,
           let workspace = snapshot.directoryWorkspace(
               id: directoryWorkspaceID
           ) {
            return tmuxSessionSelection(for: workspace)
        }
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
            workspacePath: worktree.path,
            worktreeGeneration: worktree.generation,
            socketName: worktree.tmuxSocketName,
            tmuxAttachMode: worktree.tmuxAttachMode
        )
    }

    public static func tmuxSessionSelection(
        for workspace: DirectoryWorkspaceSummary
    ) -> WorkspaceTmuxSessionSelection {
        WorkspaceTmuxSessionSelection(
            hostID: workspace.hostID,
            name: workspace.tmuxSessionName,
            directoryWorkspaceID: workspace.id,
            workspacePath: workspace.path,
            socketName: workspace.tmuxSocketName,
            tmuxAttachMode: workspace.tmuxAttachMode
        )
    }

    /// Rename applies only to standalone sessions on the default tmux
    /// server. Kwt owns worktree and directory session names, and Windows
    /// hosts have no POSIX shell for the identity-guarded command. Kwt
    /// derives its session names rather than storing them, so a renamed
    /// kwt session would be orphaned even when it is shown as a plain row.
    public static func canRequestRename(
        _ selection: WorkspaceTmuxSessionSelection,
        in snapshot: WorkspaceSnapshot
    ) -> Bool {
        renameRequest(selection, in: snapshot) != nil
    }

    /// Captures the identity discovery recorded for the session, which the
    /// rename must still match when it runs.
    public static func renameRequest(
        _ selection: WorkspaceTmuxSessionSelection,
        in snapshot: WorkspaceSnapshot
    ) -> TmuxSessionRenameRequest? {
        guard selection.worktreeID == nil,
              selection.directoryWorkspaceID == nil,
              selection.socketName == nil,
              selection.tmuxAttachMode != .protected,
              let host = snapshot.host(id: selection.hostID),
              host.platform != .windows,
              !kwtOwnsTmuxSessionName(
                  selection.name,
                  hostID: host.id,
                  in: snapshot
              ),
              let summary = host.tmuxSessions.first(where: {
                  $0.name == selection.name
                      && $0.socketName == nil
                      && $0.hasStableIdentity
              }),
              let serverPID = summary.serverPID,
              let sessionID = summary.sessionID,
              let createdAt = summary.createdAt
        else { return nil }
        return TmuxSessionRenameRequest(
            session: selection,
            confirmedHost: host,
            serverPID: serverPID,
            sessionID: sessionID,
            sessionCreatedAt: createdAt
        )
    }

    /// kwt derives worktree and directory session names and finds them by
    /// name, so Ghosthub must neither rename them nor rename onto them.
    public static func kwtOwnsTmuxSessionName(
        _ name: String,
        hostID: UUID,
        in snapshot: WorkspaceSnapshot
    ) -> Bool {
        isKwtTmuxSessionName(name)
            || snapshot.worktrees.contains {
                $0.hostID == hostID
                    && $0.tmuxSessionName == name
                    && $0.tmuxSocketName == nil
            }
            || snapshot.directoryWorkspaces.contains {
                $0.hostID == hostID
                    && $0.tmuxSessionName == name
                    && $0.tmuxSocketName == nil
            }
    }

    public static func isKwtTmuxSessionName(_ name: String) -> Bool {
        name.hasPrefix("kwt-wt-") || name.hasPrefix("kwt-workspace-")
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
        guard selection.tmuxAttachMode != .protected else {
            return false
        }
        if selection.tmuxAttachMode == .direct,
           selection.socketName != nil,
           selection.worktreeID != nil || selection.directoryWorkspaceID != nil {
            if let worktreeID = selection.worktreeID,
               let worktree = snapshot.worktree(id: worktreeID) {
                return !worktree.isStale
                    && worktree.hostID == selection.hostID
                    && worktree.tmuxSessionName == selection.name
                    && worktree.tmuxSocketName == selection.socketName
                    && worktree.tmuxAttachMode == selection.tmuxAttachMode
                    && worktree.path == selection.workspacePath
                    && worktree.generation == selection.worktreeGeneration
            }
            if let directoryWorkspaceID = selection.directoryWorkspaceID,
               let workspace = snapshot.directoryWorkspace(
                   id: directoryWorkspaceID
               ) {
                return workspace.hostID == selection.hostID
                    && workspace.path == selection.workspacePath
                    && workspace.tmuxSessionName == selection.name
                    && workspace.tmuxSocketName == selection.socketName
                    && workspace.tmuxAttachMode == selection.tmuxAttachMode
                    && workspace.sessionLive
            }
            return false
        }
        return snapshot.host(id: selection.hostID)?.tmuxSessions.contains {
            $0.name == selection.name
                && $0.socketName == selection.socketName
                && $0.hasStableIdentity
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
        connectedTmuxSessionIDs: Set<String> = [],
        liveTmuxWindowCounts: [String: Int] = [:],
        hostOrderRawValue: String = "",
        worktreeOrderRawValue: String = "",
        sessionOrderRawValue: String = "",
        sessionSort: SidebarSessionSort = .manual,
        agentAttentionByEndpoint: [String: AgentAttention] = [:]
    ) -> [WorkspaceSidebarSection] {
        RenderWorkCounters.countSidebarSectionComputation()
        let worktreeOrder = WorkspaceSidebarOrder(
            rawValue: worktreeOrderRawValue
        )
        let sessionOrder = WorkspaceSidebarOrder(
            rawValue: sessionOrderRawValue
        )
        let hosts = WorkspaceSidebarOrder(rawValue: hostOrderRawValue).ordered(
            snapshot.hosts, identifiedBy: hostOrderID
        )
        return hosts.map { host in
            let sessionsByEndpoint = host.tmuxSessions.reduce(
                into: [String: TmuxSessionSummary]()
            ) { sessions, session in
                sessions[tmuxSessionOrderID(
                    hostID: host.id,
                    name: session.name,
                    socketName: session.socketName
                )] = session
            }
            let workspaceSessionIDs = Set(
                snapshot.worktrees.compactMap { worktree in
                    guard worktree.hostID == host.id,
                          worktree.tmuxAttachMode == .direct,
                          let name = worktree.tmuxSessionName else { return nil as String? }
                    return tmuxSessionOrderID(
                        hostID: host.id,
                        name: name,
                        socketName: worktree.tmuxSocketName
                    )
                } + snapshot.directoryWorkspaces.compactMap { workspace in
                    guard workspace.hostID == host.id,
                          workspace.tmuxAttachMode == .direct else { return nil as String? }
                    return tmuxSessionOrderID(
                        hostID: host.id,
                        name: workspace.tmuxSessionName,
                        socketName: workspace.tmuxSocketName
                    )
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
                        worktreeRow(
                            for: worktree,
                            snapshot: snapshot,
                            host: host,
                            project: project,
                            sessionsByEndpoint:
                            sessionsByEndpoint,
                            connectedTmuxSessionIDs:
                            connectedTmuxSessionIDs,
                            liveTmuxWindowCounts: liveTmuxWindowCounts
                        )
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
                directoryWorkspaceRows: snapshot.directoryWorkspaces
                    .filter { $0.hostID == host.id }
                    .map { directoryWorkspaceRow($0, host: host) },
                sessionRows: WorkspaceSidebarSessionOrdering.ordered(
                    host.tmuxSessions
                        .filter {
                            (!tmuxSessionVisibility.hideKwtManagedSessions
                                || !workspaceSessionIDs.contains(tmuxSessionOrderID(
                                    hostID: host.id,
                                    name: $0.name,
                                    socketName: $0.socketName
                                )))
                                && !tmuxSessionVisibility.isHidden($0.name)
                        }
                        .map {
                            tmuxSessionRow(
                                $0,
                                hostID: host.id,
                                connectedTmuxSessionIDs: connectedTmuxSessionIDs,
                                liveTmuxWindowCounts: liveTmuxWindowCounts
                            )
                        }
                        + host.herdrSessions.map {
                            herdrSessionRow($0, hostID: host.id)
                        }
                        + host.backendTerminals.map {
                            backendTerminalRow($0, hostID: host.id)
                        }
                        + host.zellijSessions.map {
                            zellijSessionRow($0, hostID: host.id)
                        },
                    sort: sessionSort,
                    manualOrder: sessionOrder,
                    agentAttentionByEndpoint: agentAttentionByEndpoint
                )
            )
        }
    }

    private static func directoryWorkspaceRow(
        _ workspace: DirectoryWorkspaceSummary,
        host _: HostSummary
    ) -> WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .directoryWorkspace(workspace.id),
            icon: .directoryWorkspace,
            title: workspace.name,
            subtitle: workspace.path,
            sessionIsRunning: workspace.sessionLive
        )
    }

    static func tmuxSessionOrderID(
        hostID: UUID,
        name: String,
        socketName: String? = nil
    ) -> String {
        if let socketName {
            return "\(hostID.uuidString):\(socketName):\(name)"
        }
        return "\(hostID.uuidString):\(name)"
    }

    static func herdrSessionOrderID(
        hostID: UUID,
        name: String
    ) -> String {
        "herdr:\(hostID.uuidString):\(name)"
    }

    /// Prefixed by backend so a terminal never collides with a session
    /// of the same name in the shared manual order.
    static func backendTerminalOrderID(
        hostID: UUID,
        kind: BackendTerminalKind,
        address: String
    ) -> String {
        switch kind {
        case .herdrCore: "herdr-core:\(hostID.uuidString):\(address)"
        case .rex: "rex:\(hostID.uuidString):\(address)"
        }
    }

    static func zellijSessionOrderID(
        hostID: UUID,
        name: String
    ) -> String {
        "zellij:\(hostID.uuidString):\(name)"
    }

    private static func zellijSessionRow(
        _ session: ZellijSessionSummary,
        hostID: UUID
    ) -> WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .zellijSession(hostID: hostID, name: session.name),
            icon: .zellijSession,
            title: session.name
        )
    }

    private static func herdrSessionRow(
        _ session: HerdrSessionSummary,
        hostID: UUID
    ) -> WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .herdrSession(hostID: hostID, name: session.name),
            icon: .herdrSession,
            title: session.title,
            subtitle: session.state == .running ? "Running" : "Stopped",
            herdrSessionState: session.state,
            herdrSessionIsDefault: session.isDefault
        )
    }

    private static func backendTerminalRow(
        _ terminal: BackendTerminalSummary,
        hostID: UUID
    ) -> WorkspaceSidebarRow {
        WorkspaceSidebarRow(
            target: .backendTerminal(
                hostID: hostID, kind: terminal.kind, address: terminal.address
            ),
            icon: terminal.kind == .rex ? .rexTerminal : .herdrTerminal,
            title: terminal.title,
            subtitle: terminal.detail ?? terminal.address
        )
    }

    private static func tmuxSessionRow(
        _ session: TmuxSessionSummary,
        hostID: UUID,
        connectedTmuxSessionIDs: Set<String>,
        liveTmuxWindowCounts: [String: Int]
    ) -> WorkspaceSidebarRow {
        let selectionID = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: session.name,
            socketName: session.socketName
        ).id
        let liveCount = connectedTmuxSessionIDs.contains(selectionID)
            ? liveTmuxWindowCounts[selectionID]
            : nil
        let windowCount = liveCount ?? (
            session.windows.isEmpty ? nil : session.windows.count
        )
        // The backend label already says "tmux"; the subtitle carries only
        // extra detail for the tooltip and VoiceOver.
        let subtitle: String? = if let windowCount {
            windowCount == 1 ? "1 window" : "\(windowCount) windows"
        } else if session.managed {
            "Workspace session"
        } else {
            nil
        }
        return WorkspaceSidebarRow(
            target: .tmuxSession(
                hostID: hostID,
                name: session.name,
                socketName: session.socketName
            ),
            icon: .tmuxSession,
            title: session.name,
            subtitle: subtitle,
            indentLevel: 0
        )
    }

    private static func worktreeRow(
        for worktree: WorktreeSummary,
        snapshot: WorkspaceSnapshot,
        host: HostSummary,
        project: ProjectSummary,
        sessionsByEndpoint: [String: TmuxSessionSummary],
        connectedTmuxSessionIDs: Set<String>,
        liveTmuxWindowCounts: [String: Int]
    ) -> WorkspaceSidebarRow {
        let sessions = snapshot.sessions(for: worktree.id)
        let tmuxSelection = tmuxSessionSelection(for: worktree)
        let hasConnectedPresentation = tmuxSelection.map {
            connectedTmuxSessionIDs.contains($0.id)
        } == true
        let tmuxSession = worktree.tmuxAttachMode == .direct
            && host.lastKnownReachable
            && host.tmuxInventoryIsAuthoritative
            ? worktree.tmuxSessionName.flatMap {
                sessionsByEndpoint[tmuxSessionOrderID(
                    hostID: host.id,
                    name: $0,
                    socketName: worktree.tmuxSocketName
                )]
            }
            : nil
        let tmuxWindowCount = if hasConnectedPresentation,
                                 let selectionID = tmuxSelection?.id,
                                 let liveCount = liveTmuxWindowCounts[selectionID] {
            liveCount
        } else {
            tmuxSession.flatMap {
                $0.windows.isEmpty ? nil : $0.windows.count
            }
        }
        let status = WorktreeRowStatus.make(
            for: worktree,
            sessions: sessions,
            hasLiveTmuxSession: tmuxSession != nil
                || hasConnectedPresentation,
            tmuxWindowCount: tmuxWindowCount
        )
        // The branch/PR lives in the status's second line and the detail
        // card, so worktree rows carry no subtitle. Command-palette search
        // reads worktree.sidebarSubtitle directly instead.
        return WorkspaceSidebarRow(
            target: .worktree(worktree.id),
            icon: worktree.isPrimary ? .primaryWorktree : .worktree,
            title: worktree.sidebarTitle,
            subtitle: nil,
            indentLevel: 1,
            worktreeStatus: status,
            worktreeFlagKey: WorktreeFlagKey.resolve(
                worktree: worktree, host: host, project: project
            )
        )
    }
}
