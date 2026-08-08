import Foundation

public enum WorkspaceNavigationTarget: Hashable, Sendable {
    case host(UUID)
    case project(UUID)
    case worktree(UUID)
    case directoryWorkspace(UUID)
    /// A host-scoped tmux session discovered independently of the project
    /// registry. Selection keeps the host current; the App layer owns one
    /// ordinary native tmux client presentation.
    case tmuxSession(hostID: UUID, name: String)
}

public extension WorkspaceSelection {
    var navigationTarget: WorkspaceNavigationTarget {
        if let selectedDirectoryWorkspaceID {
            return .directoryWorkspace(selectedDirectoryWorkspaceID)
        }
        if let selectedWorktreeID {
            return .worktree(selectedWorktreeID)
        }

        if let selectedProjectID {
            return .project(selectedProjectID)
        }

        return .host(selectedHostID)
    }

    mutating func select(
        _ target: WorkspaceNavigationTarget?,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility = .default
    ) {
        guard let target else {
            return
        }

        switch target {
        case let .host(hostID):
            guard snapshot.host(id: hostID) != nil else {
                return
            }

            selectedHostID = hostID
            selectedProjectID = nil
            selectedWorktreeID = nil
            selectedDirectoryWorkspaceID = nil
        case let .project(projectID):
            guard let project = snapshot.project(id: projectID) else {
                return
            }
            guard !project.isStale else {
                return
            }

            selectedHostID = project.hostID
            selectedProjectID = project.id
            selectedWorktreeID = nil
            selectedDirectoryWorkspaceID = nil
        case let .worktree(worktreeID):
            guard let worktree = snapshot.worktree(id: worktreeID) else {
                return
            }
            guard !worktree.isStale else {
                return
            }

            selectedHostID = worktree.hostID
            selectedProjectID = worktree.projectID
            selectedWorktreeID = worktree.id
            selectedDirectoryWorkspaceID = nil
        case let .directoryWorkspace(directoryWorkspaceID):
            guard let workspace = snapshot.directoryWorkspace(
                id: directoryWorkspaceID
            ) else {
                return
            }
            selectedHostID = workspace.hostID
            selectedProjectID = nil
            selectedWorktreeID = nil
            selectedDirectoryWorkspaceID = workspace.id
        case let .tmuxSession(hostID, _):
            guard snapshot.host(id: hostID) != nil else {
                return
            }
            selectedHostID = hostID
            selectedProjectID = nil
            selectedWorktreeID = nil
            selectedDirectoryWorkspaceID = nil
        }

        self = normalized(in: snapshot, visibility: visibility)
    }

    func normalized(in snapshot: WorkspaceSnapshot) -> WorkspaceSelection {
        normalized(in: snapshot, visibility: .default)
    }

    func normalized(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility
    ) -> WorkspaceSelection {
        let selectedProject = selectedProjectID
            .flatMap(snapshot.project(id:))
            .flatMap { $0.isStale ? nil : $0 }
        let selectedWorktree: WorktreeSummary?
        if let selectedWorktreeID,
           let worktree = snapshot.worktree(id: selectedWorktreeID),
           !worktree.isStale,
           visibility.includes(worktree) {
            selectedWorktree = worktree
        } else {
            selectedWorktree = nil
        }
        let selectedDirectoryWorkspace = selectedDirectoryWorkspaceID
            .flatMap(snapshot.directoryWorkspace(id:))

        let resolvedHostID: UUID
        if let selectedDirectoryWorkspace {
            resolvedHostID = selectedDirectoryWorkspace.hostID
        } else if let selectedWorktree {
            resolvedHostID = selectedWorktree.hostID
        } else if let selectedProject {
            resolvedHostID = selectedProject.hostID
        } else if let selectedHost = snapshot.host(id: selectedHostID) {
            resolvedHostID = selectedHost.id
        } else if let firstHost = snapshot.hosts.first {
            resolvedHostID = firstHost.id
        } else {
            resolvedHostID = selectedHostID
        }

        var resolvedProjectID: UUID?
        var resolvedWorktreeID: UUID?
        var resolvedDirectoryWorkspaceID: UUID?

        if let selectedDirectoryWorkspace,
           selectedDirectoryWorkspace.hostID == resolvedHostID {
            resolvedDirectoryWorkspaceID = selectedDirectoryWorkspace.id
        }

        if resolvedDirectoryWorkspaceID == nil,
           let selectedWorktree,
           selectedWorktree.hostID == resolvedHostID {
            resolvedWorktreeID = selectedWorktree.id

            if let owningProject = snapshot.project(id: selectedWorktree.projectID),
               !owningProject.isStale,
               owningProject.hostID == resolvedHostID {
                resolvedProjectID = owningProject.id
            }
        }

        if resolvedDirectoryWorkspaceID == nil,
           resolvedProjectID == nil,
           let selectedProject,
           selectedProject.hostID == resolvedHostID {
            resolvedProjectID = selectedProject.id
        }

        let resolvedConsoleBinding = resolvedConsoleBinding(in: snapshot)

        return WorkspaceSelection(
            selectedHostID: resolvedHostID,
            selectedProjectID: resolvedProjectID,
            selectedWorktreeID: resolvedWorktreeID,
            selectedDirectoryWorkspaceID: resolvedDirectoryWorkspaceID,
            consoleBindingMode: resolvedConsoleBinding.mode,
            pinnedConsoleHostID: resolvedConsoleBinding.pinnedHostID
        )
    }

    func normalizedBySelectingVisibleFallback(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility
    ) -> WorkspaceSelection {
        guard let selectedWorktreeID else {
            return normalized(in: snapshot, visibility: visibility)
        }
        guard let selectedWorktree = snapshot.worktree(
            id: selectedWorktreeID
        ), !selectedWorktree.isStale else {
            return normalizedSelectingProjectFallback(
                in: snapshot,
                visibility: visibility
            )
        }
        guard !visibility.includes(selectedWorktree) else {
            return normalized(in: snapshot, visibility: visibility)
        }

        let siblings = snapshot.worktrees.filter {
            $0.hostID == selectedWorktree.hostID
                && $0.projectID == selectedWorktree.projectID
                && !$0.isStale
        }
        let visibleSiblings = siblings.filter(visibility.includes)

        var updatedSelection = normalized(in: snapshot, visibility: visibility)
        guard let selectedIndex = siblings.firstIndex(where: {
            $0.id == selectedWorktree.id
        }) else {
            return updatedSelection
        }

        let nextVisible = siblings[(selectedIndex + 1)...].first(where: visibility.includes)
        let previousVisible = siblings[..<selectedIndex].reversed()
            .first(where: visibility.includes)

        if let replacement = nextVisible ?? previousVisible ?? visibleSiblings.first {
            updatedSelection.select(
                .worktree(replacement.id),
                in: snapshot,
                visibility: visibility
            )
            return updatedSelection.normalized(in: snapshot, visibility: visibility)
        }

        updatedSelection.select(
            .project(selectedWorktree.projectID),
            in: snapshot,
            visibility: visibility
        )
        return updatedSelection.normalized(in: snapshot, visibility: visibility)
    }

    private func normalizedSelectingProjectFallback(
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility
    ) -> WorkspaceSelection {
        var updatedSelection = normalized(
            in: snapshot,
            visibility: visibility
        )
        guard let selectedProjectID,
              let project = snapshot.project(id: selectedProjectID),
              !project.isStale
        else { return updatedSelection }

        let replacement = snapshot.worktrees.first {
            $0.hostID == project.hostID
                && $0.projectID == project.id
                && !$0.isStale
                && visibility.includes($0)
        }
        if let replacement {
            updatedSelection.select(
                .worktree(replacement.id),
                in: snapshot,
                visibility: visibility
            )
        }
        return updatedSelection.normalized(
            in: snapshot,
            visibility: visibility
        )
    }

    private func resolvedConsoleBinding(
        in snapshot: WorkspaceSnapshot
    ) -> (mode: ConsoleBindingMode, pinnedHostID: UUID?) {
        let resolvedPinnedHostID = pinnedConsoleHostID.flatMap { hostID in
            snapshot.host(id: hostID)?.id
        }

        switch consoleBindingMode {
        case .followSelectedHost:
            return (.followSelectedHost, resolvedPinnedHostID)
        case .pinHost:
            guard let resolvedPinnedHostID else {
                return (.followSelectedHost, nil)
            }

            return (.pinHost, resolvedPinnedHostID)
        }
    }

    /// Project terminal configuration is user-authored input to the app's
    /// libghostty config, so it may only come from a checkout the user
    /// controls. An imported pull request carries a protected tmux socket and
    /// contributor-controlled source, so its `.ghosthub/terminal.conf` is
    /// skipped in favor of the project's own checkout.
    func terminalConfigRoot(in snapshot: WorkspaceSnapshot) -> URL? {
        if let selectedWorktreeID,
           let worktree = snapshot.worktree(id: selectedWorktreeID),
           !worktree.isStale,
           worktree.tmuxSocketName == nil,
           snapshot.host(id: worktree.hostID)?.kind == .selfHost {
            return URL(fileURLWithPath: worktree.path, isDirectory: true)
        }

        guard let selectedProjectID,
              let project = snapshot.project(id: selectedProjectID),
              !project.isStale,
              !project.isSynthesized,
              snapshot.host(id: project.hostID)?.kind == .selfHost,
              project.repositoryKind == .standard
        else {
            return nil
        }

        return URL(fileURLWithPath: project.rootPath, isDirectory: true)
    }
}
