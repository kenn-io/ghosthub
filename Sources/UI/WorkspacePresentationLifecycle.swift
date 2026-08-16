import GhosthubWorkspace
import SwiftUI

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
    case projectRemovalConfirmation(
        project: ProjectSummary,
        host: HostSummary
    )
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
        case let .projectRemovalConfirmation(project, host):
            return "project:confirm:\(host.id.uuidString):\(project.id.uuidString)"
        case let .projectRemovalFailure(project, message):
            return "project:failure:\(project):\(message)"
        }
    }
}
