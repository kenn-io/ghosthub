use crate::{Ordering, Workspace, WorkspaceError, lock_live_navigation};
use config::{KeyboardPreferences, ShortcutAction};

impl Workspace {
    #[must_use]
    pub fn configured_keyboard(&self) -> KeyboardPreferences {
        self.scene
            .runtime
            .settings
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(KeyboardPreferences::default, |settings| {
                settings.config.keyboard().clone()
            })
    }

    /// Save one shortcut against the latest configuration shared by all windows.
    ///
    /// # Errors
    /// Returns an error for invalid/conflicting shortcuts, closed scenes, or a failed write.
    pub fn set_shortcut(
        &self,
        action: ShortcutAction,
        value: Option<&str>,
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
            .ok_or_else(|| WorkspaceError::new("Keyboard settings storage is unavailable"))?;
        let mut keyboard = settings.config.keyboard().clone();
        keyboard
            .set(action, value)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        settings
            .config
            .replace_keyboard(&settings.roots, keyboard)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        self.scene.runtime.revision.fetch_add(1, Ordering::Release);
        Ok(())
    }
}
