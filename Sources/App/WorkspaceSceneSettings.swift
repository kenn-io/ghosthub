import GhosthubSettings
import GhosthubWorkspace

@MainActor
struct WorkspaceSceneSettings {
    var workspaceConfiguration: () -> WorkspaceConfiguration
    var worktreeVisibility: () -> WorktreeVisibility
    var presentHostsSettings: () -> Void

    static func live(
        store: SettingsStore = .shared
    ) -> WorkspaceSceneSettings {
        WorkspaceSceneSettings(
            workspaceConfiguration: {
                WorkspaceConfiguration.fromSettings(store)
            },
            worktreeVisibility: {
                WorktreeVisibility(
                    hideRootWorktrees:
                    store.worktreePreferences.hideRootCheckout,
                    showHiddenWorktrees:
                    store.worktreePreferences
                        .showHiddenWorktreesByDefault
                )
            },
            presentHostsSettings: {
                store.selectedDomain = .hosts
            }
        )
    }
}
