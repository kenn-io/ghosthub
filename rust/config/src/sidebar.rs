use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

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
    pub hidden_session_patterns: Vec<String>,
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
            hidden_session_patterns: Vec::new(),
        }
    }
}

impl SidebarPreferences {
    /// Case-sensitive, whole-name wildcards; `?` matches one displayed character.
    #[must_use]
    pub fn hides_tmux_session(&self, name: &str) -> bool {
        self.hidden_session_patterns.iter().any(|pattern| {
            let pattern = pattern.trim();
            !pattern.is_empty() && matches_pattern(name, pattern)
        })
    }

    pub(crate) fn normalize(&mut self) {
        let mut seen = std::collections::HashSet::new();
        self.hidden_session_patterns = self
            .hidden_session_patterns
            .iter()
            .map(|pattern| pattern.trim().to_owned())
            .filter(|pattern| !pattern.is_empty() && seen.insert(pattern.clone()))
            .collect();
    }
}

fn matches_pattern(value: &str, pattern: &str) -> bool {
    let value: Vec<_> = value.graphemes(true).collect();
    let mut previous = vec![false; value.len() + 1];
    previous[0] = true;
    for token in pattern.graphemes(true) {
        let mut current = vec![false; value.len() + 1];
        if token == "*" {
            current[0] = previous[0];
            for index in 0..value.len() {
                current[index + 1] = previous[index + 1] || current[index];
            }
        } else {
            for (index, character) in value.iter().enumerate() {
                current[index + 1] = previous[index] && (token == "?" || token == *character);
            }
        }
        previous = current;
    }
    previous[value.len()]
}
