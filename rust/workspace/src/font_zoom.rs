use std::sync::atomic::Ordering;

use crate::{Appearance, Workspace, WorkspaceError, scene::lock_live_navigation};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalFontZoom {
    Increase,
    Decrease,
    Reset,
}

impl Workspace {
    pub(crate) fn effective_appearance(&self) -> Appearance {
        let mut appearance = self
            .scene
            .runtime
            .appearance
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        if let Some(size) = *self
            .scene
            .font_size
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
        {
            appearance.font_size = size;
        }
        appearance
    }

    /// Change this window's terminal size without changing its saved Appearance settings.
    /// Reset follows the latest saved size; new windows start without an override.
    ///
    /// # Errors
    /// Returns an error if this window has closed.
    pub fn zoom_terminal_font(&self, command: TerminalFontZoom) -> Result<(), WorkspaceError> {
        let _navigation = lock_live_navigation(&self.scene)?;
        let configured = self
            .scene
            .runtime
            .appearance
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .font_size();
        let mut override_size = self
            .scene
            .font_size
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let current = override_size.unwrap_or(configured);
        let next = match command {
            TerminalFontZoom::Increase => Some(current.saturating_add(1)),
            TerminalFontZoom::Decrease => Some(current.saturating_sub(1).max(1)),
            TerminalFontZoom::Reset => None,
        };
        if *override_size != next {
            *override_size = next;
            self.scene.revision.fetch_add(1, Ordering::Release);
        }
        Ok(())
    }
}
