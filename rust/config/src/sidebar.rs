use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum SidebarSort {
    #[default]
    Manual,
    Name,
    Backend,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum BackendLabel {
    #[default]
    Chip,
    Text,
    Dot,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum SidebarRowHeight {
    #[default]
    Regular,
    Compact,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, deny_unknown_fields, rename_all = "kebab-case")]
pub struct SidebarPreferences {
    pub session_sort: SidebarSort,
    pub backend_label: BackendLabel,
    pub row_height: SidebarRowHeight,
    pub hide_worktree_sessions: bool,
    pub hide_root_checkout: bool,
    pub session_order: Vec<String>,
}

impl Default for SidebarPreferences {
    fn default() -> Self {
        Self {
            session_sort: SidebarSort::Manual,
            backend_label: BackendLabel::Chip,
            row_height: SidebarRowHeight::Regular,
            hide_worktree_sessions: true,
            hide_root_checkout: false,
            session_order: Vec::new(),
        }
    }
}
