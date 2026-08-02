import Foundation
import GhosthubUI
import GhosthubWorkspace

enum WorktreeGeneration {
    /// Returns the value only when it is a durable kwt generation
    /// (32 lowercase hex characters); any other value is not identity.
    static func canonical(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: #"^[0-9a-f]{32}$"#,
                  options: .regularExpression
              ) != nil
        else { return nil }
        return value
    }

    static func isCanonical(_ value: String?) -> Bool {
        canonical(value) != nil
    }
}

private func isValidOptionalWorktreeGeneration(_ value: String?) -> Bool {
    value == nil || WorktreeGeneration.isCanonical(value)
}

struct WorkspaceNavigationDescriptor: Codable, Hashable, Sendable {
    var hostKey: String
    var projectKey: String?
    var worktreeGeneration: String?
}

enum WorkspaceTmuxOwnerDescriptor: Codable, Hashable, Sendable {
    case unbound
    case worktree(generation: String)
}

struct WorkspaceTmuxDescriptor: Codable, Hashable, Sendable {
    var hostKey: String
    var sessionName: String
    var socketName: String?
    var owner: WorkspaceTmuxOwnerDescriptor
}

struct WorkspaceWindowState: Codable, Hashable, Sendable {
    var windowID: UUID
    var navigation: WorkspaceNavigationDescriptor?
    var tmux: WorkspaceTmuxDescriptor?

    static func fresh(windowID: UUID = UUID()) -> Self {
        Self(windowID: windowID, navigation: nil, tmux: nil)
    }

    static func capture(
        windowID: UUID,
        selection: WorkspaceSelection,
        activeTmux: WorkspaceTmuxSessionSelection?,
        snapshot: WorkspaceSnapshot
    ) -> Self {
        let host = snapshot.host(id: selection.selectedHostID)
        let project = selection.selectedProjectID.flatMap {
            snapshot.project(id: $0)
        }
        let worktree = selection.selectedWorktreeID.flatMap {
            snapshot.worktree(id: $0)
        }
        let observedGeneration = activeTmux.flatMap { active -> String? in
            guard active.worktreeID == selection.selectedWorktreeID,
                  active.worktreeGeneration != nil
            else { return nil }
            return WorktreeGeneration.canonical(active.worktreeGeneration)
        }
        let worktreeGeneration: String?
        if activeTmux?.worktreeID == selection.selectedWorktreeID,
           activeTmux?.worktreeGeneration != nil {
            worktreeGeneration = observedGeneration
        } else {
            worktreeGeneration = WorktreeGeneration.canonical(
                worktree?.generation
            )
        }
        let navigation = host.map {
            WorkspaceNavigationDescriptor(
                hostKey: $0.configKey,
                projectKey: project?.scopedKey,
                worktreeGeneration: worktreeGeneration
            )
        }
        // A session can outlive navigation elsewhere for one frame before
        // the lifecycle modifier detaches it. Persist a tmux descriptor
        // only when its host and worktree ownership match the captured
        // navigation; otherwise keep the navigation alone rather than
        // emitting a combination the resolver rejects outright.
        let tmux = activeTmux.flatMap { active -> WorkspaceTmuxDescriptor? in
            guard let activeHost = snapshot.host(id: active.hostID),
                  let navigation,
                  activeHost.configKey == navigation.hostKey
            else { return nil }
            let owner: WorkspaceTmuxOwnerDescriptor
            if let worktreeID = active.worktreeID {
                let generation = active.worktreeGeneration == nil
                    ? WorktreeGeneration.canonical(
                        snapshot.worktree(id: worktreeID)?.generation
                    )
                    : WorktreeGeneration.canonical(
                        active.worktreeGeneration
                    )
                guard let generation,
                      generation == navigation.worktreeGeneration
                else { return nil }
                owner = .worktree(generation: generation)
            } else {
                guard selection.selectedProjectID == nil,
                      selection.selectedWorktreeID == nil,
                      active.socketName == nil
                else { return nil }
                owner = .unbound
            }
            return WorkspaceTmuxDescriptor(
                hostKey: activeHost.configKey,
                sessionName: active.name,
                socketName: active.socketName,
                owner: owner
            )
        }
        return Self(windowID: windowID, navigation: navigation, tmux: tmux)
    }
}

struct WorkspaceWindowStateBuffer {
    private(set) var retained: WorkspaceWindowState
    private var pendingPresentations: [WorkspaceWindowState] = []
    private var awaitsLateRestoration = false

    init(retained: WorkspaceWindowState = .fresh()) {
        self.retained = retained
    }

    mutating func beginAppearance(
        with presented: WorkspaceWindowState?
    ) -> WorkspaceWindowState? {
        awaitsLateRestoration = presented == nil
        guard let presented else { return nil }
        retained = presented
        return presented
    }

    mutating func prepareToPresent(_ state: WorkspaceWindowState) {
        retained = state
        pendingPresentations.append(state)
    }

    mutating func receive(
        _ presented: WorkspaceWindowState?
    ) -> WorkspaceWindowState? {
        guard let presented else { return nil }

        if let index = pendingPresentations.firstIndex(of: presented) {
            pendingPresentations.remove(at: index)
            return nil
        }

        retained = presented
        guard awaitsLateRestoration else { return nil }
        awaitsLateRestoration = false
        return presented
    }

    func resolved(_ presented: WorkspaceWindowState?) -> WorkspaceWindowState {
        presented ?? retained
    }
}

enum WorkspaceRestorationResolution: Equatable, Sendable {
    case invalid
    case pending(selection: WorkspaceSelection?)
    case ready(
        selection: WorkspaceSelection,
        tmux: WorkspaceTmuxSessionSelection?
    )
    case needsProtectedProbe(
        selection: WorkspaceSelection,
        tmux: WorkspaceTmuxSessionSelection
    )
}

enum WorkspaceWindowRestorationResolver {
    static func resolve(
        _ state: WorkspaceWindowState,
        in snapshot: WorkspaceSnapshot
    ) -> WorkspaceRestorationResolution {
        guard let navigation = state.navigation,
              isNonblank(navigation.hostKey),
              isValidOptional(navigation.projectKey),
              isValidOptionalWorktreeGeneration(
                  navigation.worktreeGeneration
              ),
              navigation.worktreeGeneration == nil
              || navigation.projectKey != nil
        else { return .invalid }

        if let tmux = state.tmux {
            guard isNonblank(tmux.hostKey),
                  isNonblank(tmux.sessionName),
                  isValidOptional(tmux.socketName),
                  tmux.hostKey == navigation.hostKey
            else { return .invalid }
            switch tmux.owner {
            case .unbound:
                guard navigation.worktreeGeneration == nil,
                      tmux.socketName == nil
                else { return .invalid }
            case let .worktree(generation):
                guard WorktreeGeneration.canonical(generation) != nil,
                      generation == navigation.worktreeGeneration
                else { return .invalid }
            }
        }

        guard let host = snapshot.hosts.first(where: {
            $0.configKey == navigation.hostKey
        }) else {
            return .pending(selection: nil)
        }
        var selection = WorkspaceSelection(selectedHostID: host.id)

        if let projectKey = navigation.projectKey {
            guard let project = snapshot.projects.first(where: {
                $0.hostID == host.id
                    && $0.scopedKey == projectKey
                    && !$0.isStale
            }) else {
                return .pending(selection: selection)
            }
            selection.selectedProjectID = project.id

            if let worktreeGeneration = navigation.worktreeGeneration {
                guard let worktree = snapshot.worktrees.first(where: {
                    $0.hostID == host.id
                        && $0.projectID == project.id
                        && $0.generation == worktreeGeneration
                        && !$0.isStale
                }) else {
                    return .pending(selection: selection)
                }
                selection.selectedWorktreeID = worktree.id
            }
        }

        guard let tmux = state.tmux else {
            return .ready(selection: selection, tmux: nil)
        }
        if host.kind == .remote, host.connectionState == .offline {
            return .pending(selection: selection)
        }
        let worktreeGeneration: String?
        switch tmux.owner {
        case .unbound:
            worktreeGeneration = nil
        case let .worktree(generation):
            worktreeGeneration = generation
        }
        let owner = worktreeGeneration.flatMap { worktreeGeneration in
            snapshot.worktrees.first {
                $0.hostID == host.id
                    && $0.projectID == selection.selectedProjectID
                    && $0.generation == worktreeGeneration
                    && !$0.isStale
            }
        }
        if worktreeGeneration != nil, owner == nil {
            return .pending(selection: selection)
        }
        if let owner,
           owner.tmuxSessionName != tmux.sessionName
           || owner.tmuxSocketName != tmux.socketName {
            return .pending(selection: selection)
        }
        let tmuxSelection = WorkspaceTmuxSessionSelection(
            hostID: host.id,
            name: tmux.sessionName,
            worktreeID: owner?.id,
            worktreePath: owner?.path,
            worktreeGeneration: worktreeGeneration,
            socketName: tmux.socketName
        )

        if tmux.socketName != nil {
            guard owner != nil
            else { return .pending(selection: selection) }
            return .needsProtectedProbe(
                selection: selection,
                tmux: tmuxSelection
            )
        }
        guard host.tmuxSessions.contains(where: {
            $0.name == tmux.sessionName
        }) else {
            return .pending(selection: selection)
        }
        return .ready(selection: selection, tmux: tmuxSelection)
    }

    private static func isNonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidOptional(_ value: String?) -> Bool {
        value.map(isNonblank) ?? true
    }
}
