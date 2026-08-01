import GhosthubWorkspace
import SwiftUI

/// Keeps a borrowed tmux attachment scoped to the workspace presentation.
/// Kept as a small modifier so route and removal lifecycle behavior can be
/// exercised without constructing the entire sidebar hierarchy.
struct TmuxSessionPresentationLifecycleModifier: ViewModifier {
    let selection: WorkspaceSelection
    let selectionBaseline: WorkspaceSelection?
    let activeSession: WorkspaceTmuxSessionSelection?
    let isWorkspaceVisible: Bool
    let deactivate: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, newSelection in
                if activeSession != nil,
                   let selectionBaseline,
                   newSelection != selectionBaseline {
                    deactivate()
                }
            }
            .onChange(of: isWorkspaceVisible) { _, isVisible in
                if !isVisible {
                    deactivate()
                }
            }
            .onDisappear {
                deactivate()
            }
    }
}

enum WorkspaceDestructiveAlert: Identifiable {
    case sessionKillConfirmation(TmuxSessionKillRequest)
    case sessionKillFailure(session: String, message: String)
    case worktreeRemovalConfirmation(WorktreeRemovalRequest)
    case worktreeRemovalFailure(worktree: String, message: String)

    var id: String {
        switch self {
        case let .sessionKillConfirmation(request):
            return "session:confirm:\(request.session.id)"
        case let .sessionKillFailure(session, message):
            return "session:failure:\(session):\(message)"
        case let .worktreeRemovalConfirmation(request):
            return "worktree:confirm:\(request.worktree.id.uuidString)"
        case let .worktreeRemovalFailure(worktree, message):
            return "worktree:failure:\(worktree):\(message)"
        }
    }
}

struct SessionKillUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Session termination is unavailable."
    }
}

struct WorktreeRemovalUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Worktree removal is unavailable."
    }
}
