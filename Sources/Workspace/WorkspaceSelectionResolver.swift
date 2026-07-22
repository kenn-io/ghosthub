import Foundation

public enum WorkspaceSelectionResolver {
    public static func initialSelection(
        in snapshot: WorkspaceSnapshot,
        localHostID: UUID
    ) -> WorkspaceSelection {
        if let firstLocalProject = snapshot.projects.first(where: {
            $0.hostID == localHostID
                && !$0.isStale
                && $0.kind == .repository
        }) {
            return WorkspaceSelection(
                selectedHostID: localHostID,
                selectedProjectID: firstLocalProject.id
            )
        }

        if let firstProject = snapshot.projects.first(where: {
            !$0.isStale && $0.kind == .repository
        }) {
            return WorkspaceSelection(
                selectedHostID: firstProject.hostID,
                selectedProjectID: firstProject.id
            )
        }

        return WorkspaceSelection(selectedHostID: localHostID)
    }

    public static func selectedProject(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) -> ProjectSummary? {
        explicitlySelectedProject(in: snapshot, selection: selection)
            ?? snapshot.projects.first {
                $0.hostID == selection.selectedHostID
                    && !$0.isStale
            }
    }

    public static func explicitlySelectedProject(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) -> ProjectSummary? {
        if let selectedProjectID = selection.selectedProjectID,
           let project = snapshot.project(id: selectedProjectID),
           !project.isStale {
            return project
        }

        if let selectedWorktreeID = selection.selectedWorktreeID,
           let worktree = snapshot.worktree(id: selectedWorktreeID),
           !worktree.isStale,
           let project = snapshot.project(id: worktree.projectID),
           !project.isStale {
            return project
        }

        return nil
    }

    public static func selectedProjectID(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) -> UUID? {
        selectedProject(in: snapshot, selection: selection)?.id
    }
}
