import GhosthubWorkspace
import SwiftUI

@MainActor
enum WorkspacePresentationLifecycle {
    struct PendingWorktreeRemovalIdentity: Equatable {
        let generation: String?

        init(_ worktree: WorktreeSummary) {
            generation = worktree.generation
        }
    }

    static func cancelPreparedZellijKill(
        workspaceAlert: inout WorkspaceAlert?,
        cancel: (ZellijSessionKillRequest) -> Void
    ) {
        guard case let .zellijKillConfirmation(request) = workspaceAlert
        else { return }
        cancel(request)
        workspaceAlert = nil
    }

    static func prepareWorktreeRemoval(
        _ worktree: WorktreeSummary,
        using prepare: (UUID) async throws -> WorktreeRemovalRequest
    ) async throws -> WorktreeRemovalRequest {
        try await prepare(worktree.id)
    }

    static func reserveWorktreeRemovalPreparation(
        _ worktree: WorktreeSummary,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) -> Bool {
        guard pendingWorktrees.isEmpty else { return false }
        pendingWorktrees[worktree.id] = PendingWorktreeRemovalIdentity(
            worktree
        )
        return true
    }

    static func holdsWorktreeRemovalReservation(
        _ worktree: WorktreeSummary,
        pendingWorktrees: [UUID: PendingWorktreeRemovalIdentity]
    ) -> Bool {
        pendingWorktrees == [
            worktree.id: PendingWorktreeRemovalIdentity(worktree),
        ]
    }

    @discardableResult
    static func clearWorktreeRemovalPreparation(
        _ worktree: WorktreeSummary,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) -> Bool {
        guard holdsWorktreeRemovalReservation(
            worktree,
            pendingWorktrees: pendingWorktrees
        ) else { return false }
        pendingWorktrees.removeAll()
        return true
    }

    static func presentNonWorktreeWorkspaceAlert(
        _ alert: WorkspaceAlert,
        workspaceAlert: inout WorkspaceAlert?,
        pendingWorktreeRemoval: inout WorktreeRemovalRequest?,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) {
        if pendingWorktreeRemoval != nil {
            pendingWorktreeRemoval = nil
            pendingWorktrees.removeAll()
        }
        workspaceAlert = alert
    }

    static func beginWorktreeRemovalResolution(
        pendingWorktreeRemoval: inout WorktreeRemovalRequest?
    ) {
        pendingWorktreeRemoval = nil
    }

    static func transitionWorktreeRemovalConfirmation(
        to request: WorktreeRemovalRequest,
        pendingWorktreeRemoval: inout WorktreeRemovalRequest?,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) {
        pendingWorktreeRemoval = request
        if pendingWorktrees[request.worktree.id] == nil {
            pendingWorktrees[request.worktree.id] =
                PendingWorktreeRemovalIdentity(request.worktree)
        }
    }

    static func finishFailedWorktreeRemoval(
        _ current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        currentSnapshot: (() -> WorkspaceSnapshot)? = nil,
        visibility: WorktreeVisibility,
        pendingWorktrees: inout [UUID: PendingWorktreeRemovalIdentity]
    ) -> WorkspaceSelection {
        let updated = selectionAfterSnapshotChange(
            current,
            in: currentSnapshot?() ?? snapshot,
            visibility: visibility,
            pendingRemovals: pendingWorktrees
        )
        pendingWorktrees.removeAll()
        return updated
    }

    static func selectionForHostTmuxSession(
        _ session: WorkspaceTmuxSessionSelection,
        from current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility
    ) -> WorkspaceSelection {
        var updated = current
        updated.select(
            .tmuxSession(hostID: session.hostID, name: session.name),
            in: snapshot,
            visibility: visibility
        )
        return updated
    }

    static func selectionForTmuxCommand(
        _ session: WorkspaceTmuxSessionSelection,
        from current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility
    ) -> WorkspaceSelection {
        let target: WorkspaceNavigationTarget
        if let worktreeID = session.worktreeID {
            target = .worktree(worktreeID)
        } else if let directoryWorkspaceID = session.directoryWorkspaceID {
            target = .directoryWorkspace(directoryWorkspaceID)
        } else {
            target = .tmuxSession(hostID: session.hostID, name: session.name)
        }

        var updated = current
        updated.select(target, in: snapshot, visibility: visibility)
        return updated
    }

    static func selectionAfterSnapshotChange(
        _ current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility,
        pendingRemovals: [UUID: PendingWorktreeRemovalIdentity]
    ) -> WorkspaceSelection {
        if let selectedWorktreeID = current.selectedWorktreeID,
           let pending = pendingRemovals[selectedWorktreeID],
           let projectID = current.selectedProjectID,
           snapshot.project(id: projectID) != nil {
            let worktree = snapshot.worktree(id: selectedWorktreeID)
            let generationChanged = pending.generation.map {
                worktree?.generation != $0
            } ?? false
            guard worktree == nil || generationChanged else {
                return current.normalizedBySelectingVisibleFallback(
                    in: snapshot,
                    visibility: visibility
                )
            }
            var updated = current
            updated.select(
                .project(projectID),
                in: snapshot,
                visibility: visibility
            )
            return updated
        }
        return current.normalizedBySelectingVisibleFallback(
            in: snapshot,
            visibility: visibility
        )
    }

    /// Borrowed sessions are presentation attachments rather than owned tmux
    /// tabs. Cmd-W and pane-originated close requests detach that presentation
    /// as one unit; they must never locally remove a leaf from tmux's
    /// authoritative layout or kill the borrowed pane.
    static func closeBorrowedSessionIfActive(
        _ activeSession: WorkspaceTmuxSessionSelection?,
        deactivate: () -> Void
    ) -> Bool {
        guard activeSession != nil else { return false }
        deactivate()
        return true
    }

    static func deactivateSessionsForNavigation(
        hideTmux: () -> Void,
        deactivateHerdr: () -> Void,
        deactivateZellij: () -> Void
    ) {
        hideTmux()
        deactivateHerdr()
        deactivateZellij()
    }

    static func openHerdrSession(
        _ session: WorkspaceHerdrSessionSelection,
        replacing tmuxSession: WorkspaceTmuxSessionSelection?,
        open: (WorkspaceHerdrSessionSelection) async throws -> Void,
        isCurrent: () -> Bool = { true },
        hideTmux: (WorkspaceTmuxSessionSelection) -> Void
    ) async throws -> Bool {
        try await open(session)
        guard isCurrent() else { return false }
        if let tmuxSession {
            hideTmux(tmuxSession)
        }
        return true
    }

    static func startZellijSessionActivation(
        _ session: WorkspaceZellijSessionSelection,
        open: (WorkspaceZellijSessionSelection) -> Void
    ) {
        open(session)
    }

    static func isPeerTakeoverNavigation(
        _ selection: WorkspaceSelection,
        pending: WorkspaceSelection?
    ) -> Bool {
        pending?.navigationTarget == selection.navigationTarget
    }

    static func transitionHerdrSession(
        to target: WorkspaceHerdrSessionSelection,
        from active: WorkspaceHerdrSessionSelection?,
        deactivate: (WorkspaceHerdrSessionSelection) -> Void,
        start: () -> Void
    ) {
        if let active, active.hostID != target.hostID {
            deactivate(active)
        }
        start()
    }
}

/// Hides the active tmux presentation when navigation leaves its route while
/// retaining the underlying attachment for a later return. Kept as a small
/// modifier so route behavior can be exercised without constructing the
/// entire sidebar hierarchy.
struct TmuxSessionPresentationLifecycleModifier: ViewModifier {
    let selection: WorkspaceSelection
    let selectionBaseline: WorkspaceSelection?
    let activeSession: WorkspaceTmuxSessionSelection?
    var suppressesHide = false
    let hide: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, newSelection in
                if !suppressesHide,
                   activeSession != nil,
                   let selectionBaseline,
                   newSelection != selectionBaseline {
                    hide()
                }
            }
    }
}

@MainActor
final class HerdrPresentationIntentController: ObservableObject {
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?

    func start(
        operation: @escaping @MainActor (
            @escaping @MainActor @Sendable () -> Bool
        ) async throws -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) {
        cancel()
        let currentRevision = revision
        task = Task { @MainActor [weak self] in
            let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && revision == currentRevision
            }
            defer {
                if let self, revision == currentRevision {
                    task = nil
                }
            }
            do {
                try await operation(isCurrent)
            } catch {
                guard isCurrent(), !(error is CancellationError) else { return }
                onFailure(error)
            }
        }
    }

    func cancel() {
        revision &+= 1
        task?.cancel()
        task = nil
    }
}

@MainActor
final class SessionPreparationController<Request>: ObservableObject {
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?

    func start(
        prepare: @escaping () async throws -> Request,
        cancelPrepared: @escaping (Request) -> Void,
        onPrepared: @escaping (Request) -> Void,
        onFailure: @escaping (any Error) -> Void
    ) {
        cancel()
        let currentRevision = revision
        task = Task { @MainActor [weak self] in
            do {
                let request = try await prepare()
                guard let self else {
                    cancelPrepared(request)
                    return
                }
                guard !Task.isCancelled,
                      revision == currentRevision else {
                    cancelPrepared(request)
                    return
                }
                task = nil
                onPrepared(request)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      revision == currentRevision,
                      !(error is CancellationError)
                else { return }
                task = nil
                onFailure(error)
            }
        }
    }

    func cancel() {
        revision &+= 1
        task?.cancel()
        task = nil
    }
}

/// Closes an active Herdr presentation only when navigation leaves the
/// host-level route used by Herdr sessions.
struct HerdrSessionPresentationLifecycleModifier: ViewModifier {
    let selection: WorkspaceSelection
    let activeSession: WorkspaceHerdrSessionSelection?
    var suppressesDeactivation = false
    let deactivate: (WorkspaceHerdrSessionSelection) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, newSelection in
                guard !suppressesDeactivation,
                      let activeSession,
                      newSelection.selectedHostID != activeSession.hostID
                      || newSelection.selectedProjectID != nil
                      || newSelection.selectedWorktreeID != nil
                      || newSelection.selectedDirectoryWorkspaceID != nil
                else { return }
                deactivate(activeSession)
            }
    }
}

/// Closes an active Zellij client when navigation leaves its host-level route.
struct ZellijSessionPresentationLifecycleModifier: ViewModifier {
    let selection: WorkspaceSelection
    let activeSession: WorkspaceZellijSessionSelection?
    var suppressesDeactivation = false
    let deactivate: (WorkspaceZellijSessionSelection) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, newSelection in
                guard !suppressesDeactivation,
                      let activeSession,
                      newSelection.selectedHostID != activeSession.hostID
                      || newSelection.selectedProjectID != nil
                      || newSelection.selectedWorktreeID != nil
                      || newSelection.selectedDirectoryWorkspaceID != nil
                else { return }
                deactivate(activeSession)
            }
    }
}

enum WorkspaceAlert: Identifiable {
    case sessionKillConfirmation(TmuxSessionKillRequest)
    case sessionKillFailure(session: String, message: String)
    case zellijKillConfirmation(ZellijSessionKillRequest)
    case zellijKillFailure(session: String, message: String)
    case zellijCreationFailure(session: String, message: String)
    case herdrLifecycleConfirmation(HerdrSessionLifecycleRequest)
    case herdrLifecycleFailure(
        session: String,
        action: String,
        message: String
    )
    case sessionThemeFailure(session: String, message: String)
    case worktreeRemovalConfirmation(WorktreeRemovalRequest)
    case worktreeRemovalFailure(worktree: String, message: String)
    case projectRemovalConfirmation(ProjectRemovalRequest)
    case projectRemovalFailure(project: String, message: String)

    var id: String {
        switch self {
        case let .sessionKillConfirmation(request):
            return "session:confirm:\(request.session.id)"
        case let .sessionKillFailure(session, message):
            return "session:failure:\(session):\(message)"
        case let .zellijKillConfirmation(request):
            return "zellij:confirm:\(request.session.id)"
        case let .zellijKillFailure(session, message):
            return "zellij:failure:\(session):\(message)"
        case let .zellijCreationFailure(session, message):
            return "zellij:create:failure:\(session):\(message)"
        case let .herdrLifecycleConfirmation(request):
            return "herdr:confirm:\(request.session.id):\(request.action)"
        case let .herdrLifecycleFailure(session, action, message):
            return "herdr:failure:\(action):\(session):\(message)"
        case let .sessionThemeFailure(session, message):
            return "session-theme:failure:\(session):\(message)"
        case let .worktreeRemovalConfirmation(request):
            return "worktree:confirm:\(request.worktree.id.uuidString)"
        case let .worktreeRemovalFailure(worktree, message):
            return "worktree:failure:\(worktree):\(message)"
        case let .projectRemovalConfirmation(request):
            return "project:confirm:\(request.confirmedHost.id.uuidString):"
                + request.project.id.uuidString
        case let .projectRemovalFailure(project, message):
            return "project:failure:\(project):\(message)"
        }
    }
}
