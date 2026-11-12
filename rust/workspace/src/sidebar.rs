use super::{
    Ordering, SessionSelection, SidebarPreferences, Workspace, WorkspaceError, lock_live_navigation,
};

impl Workspace {
    #[must_use]
    pub fn configured_sidebar(&self) -> SidebarPreferences {
        self.scene
            .runtime
            .settings
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(SidebarPreferences::default, |settings| {
                settings.config.sidebar().clone()
            })
    }

    /// Update the latest preferences, preserving changes made by other windows.
    ///
    /// # Errors
    /// Returns an error for a closed scene or unavailable settings storage.
    pub fn update_sidebar(
        &self,
        update: impl FnOnce(&mut SidebarPreferences),
    ) -> Result<(), WorkspaceError> {
        let _mutation = self
            .scene
            .runtime
            .settings_mutation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = lock_live_navigation(&self.scene)?;
        let mut settings = self
            .scene
            .runtime
            .settings
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let settings = settings
            .as_mut()
            .ok_or_else(|| WorkspaceError::new("Sidebar settings storage is unavailable"))?;
        let mut preferences = settings.config.sidebar().clone();
        update(&mut preferences);
        settings
            .config
            .replace_sidebar(&settings.roots, preferences)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        self.scene.runtime.revision.fetch_add(1, Ordering::Release);
        Ok(())
    }
}

#[must_use]
pub fn session_order_id(selection: &SessionSelection) -> String {
    // Length prefixes keep names and socket paths unambiguous without changing session identity.
    use std::fmt::Write as _;
    let mut key = String::new();
    for part in [
        selection.host_id(),
        selection.endpoint(),
        match selection.kind() {
            super::SessionKind::Tmux => "tmux",
            super::SessionKind::Herdr => "herdr",
            super::SessionKind::Zellij => "zellij",
        },
        selection.session(),
        selection.tmux_socket_name().unwrap_or(""),
    ] {
        write!(&mut key, "{}:{part}", part.len()).expect("writing a string");
    }
    key
}
