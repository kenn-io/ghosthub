//! Rex inventory and its KWT window-control protocol.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
mod channel;
pub use channel::Channel;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct Terminal {
    pub block_id: String,
    pub session_id: String,
    pub window_id: String,
    #[serde(default)]
    pub session_label: String,
    #[serde(default)]
    pub window_label: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub focused: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Window {
    pub id: String,
    pub session_id: String,
    pub title: String,
    pub detail: String,
}

/// A missing or stopped Rex server is an ordinary empty inventory.
///
/// # Errors
/// Rejects malformed inventory and ambiguous terminal identities.
pub fn parse_inventory(bytes: &[u8]) -> Result<Vec<Window>, String> {
    #[derive(Deserialize)]
    struct Listing {
        status: String,
        terminals: Vec<Terminal>,
    }
    let listing: Listing = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    match listing.status.as_str() {
        "not_installed" | "not_running" => return Ok(Vec::new()),
        "running" => {}
        _ => return Err("Cannot read the Rex server status.".to_owned()),
    }
    let mut blocks = BTreeSet::new();
    let mut groups: BTreeMap<String, Vec<Terminal>> = BTreeMap::new();
    let mut order = Vec::new();
    for terminal in listing.terminals {
        if !valid_id(&terminal.block_id, "block")
            || !valid_id(&terminal.window_id, "window")
            || !valid_id(&terminal.session_id, "session")
            || !blocks.insert(terminal.block_id.clone())
        {
            return Err("Cannot read the Rex terminal identity.".to_owned());
        }
        if !groups.contains_key(&terminal.window_id) {
            order.push(terminal.window_id.clone());
        }
        let group = groups.entry(terminal.window_id.clone()).or_default();
        if group
            .first()
            .is_some_and(|first| first.session_id != terminal.session_id)
        {
            return Err("A Rex window belongs to more than one session.".to_owned());
        }
        group.push(terminal);
    }
    Ok(order
        .into_iter()
        .map(|id| {
            let terminals = &groups[&id];
            let first = &terminals[0];
            let focused = terminals.iter().find(|t| t.focused).unwrap_or(first);
            let pane_name = if focused.name.trim().is_empty() {
                &focused.label
            } else {
                &focused.name
            };
            let title = window_title(&first.window_label, pane_name);
            let count = terminals.len();
            let panes = if count == 1 {
                "1 pane".to_owned()
            } else {
                format!("{count} panes")
            };
            Window {
                id,
                session_id: first.session_id.clone(),
                title,
                detail: if first.session_label.trim().is_empty() {
                    panes
                } else {
                    format!("{} · {panes}", first.session_label.trim())
                },
            }
        })
        .collect())
}

#[must_use]
pub fn valid_id(value: &str, kind: &str) -> bool {
    value
        .strip_prefix(kind)
        .and_then(|s| s.strip_prefix(':'))
        .is_some_and(|s| !s.is_empty() && s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-'))
}

/// Rex uses a pane's name for windows with an automatically generated label.
#[must_use]
pub fn window_title(label: &str, pane: &str) -> String {
    let label = label.trim();
    let automatic = label.strip_prefix("Window ").is_some_and(|id| {
        id.len() == 8
            && id
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    });
    if !label.is_empty() && !automatic {
        label.to_owned()
    } else if !pane.trim().is_empty() {
        pane.trim().to_owned()
    } else {
        "Rex window".to_owned()
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum Layout {
    Pane { block_id: String },
    Split { split: Box<Split> },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Horizontal,
    Vertical,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Split {
    pub split_id: String,
    pub direction: Direction,
    pub ratio: f64,
    pub before: Layout,
    pub after: Layout,
}

impl Layout {
    #[must_use]
    pub fn panes(&self) -> Vec<&str> {
        match self {
            Self::Pane { block_id } => vec![block_id],
            Self::Split { split } => {
                let mut ids = split.before.panes();
                ids.extend(split.after.panes());
                ids
            }
        }
    }

    fn validate(&self, ids: &mut BTreeSet<String>) -> bool {
        match self {
            Self::Pane { block_id } => valid_id(block_id, "block") && ids.insert(block_id.clone()),
            Self::Split { split } => {
                valid_id(&split.split_id, "split")
                    && ids.insert(split.split_id.clone())
                    && split.ratio > 0.0
                    && split.ratio < 1.0
                    && split.before.validate(ids)
                    && split.after.validate(ids)
            }
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Layer {
    pub kind: String,
    pub layout: Option<Layout>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct WindowView {
    pub window_id: String,
    #[serde(default)]
    pub label: Option<String>,
    pub focused_block_id: Option<String>,
    pub zoomed_block_id: Option<String>,
    pub layers: Vec<Layer>,
}

impl WindowView {
    #[must_use]
    pub fn layout(&self) -> Option<&Layout> {
        self.layers
            .iter()
            .find(|l| l.kind == "tiled")
            .and_then(|l| l.layout.as_ref())
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct View {
    pub revision: u64,
    pub label: Option<String>,
    pub session_id: String,
    pub windows: Vec<WindowView>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct PaneTitle {
    pub name: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ControlError {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ControlResult {
    pub revision: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Message {
    View {
        view: View,
        #[serde(default)]
        terminals: BTreeMap<String, PaneTitle>,
    },
    Reply {
        id: u64,
        result: Option<ControlResult>,
        error: Option<ControlError>,
    },
    Ended,
}

impl Message {
    /// # Errors
    /// Rejects malformed control lines or unusable split trees.
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        let message: Self = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        if let Self::View { view, .. } = &message {
            let mut ids = BTreeSet::new();
            if !valid_id(&view.session_id, "session")
                || !view.windows.iter().all(|w| {
                    valid_id(&w.window_id, "window")
                        && ids.insert(w.window_id.clone())
                        && w.layout().is_none_or(|layout| layout.validate(&mut ids))
                        && [&w.focused_block_id, &w.zoomed_block_id]
                            .into_iter()
                            .flatten()
                            .all(|id| valid_id(id, "block"))
                })
            {
                return Err("Cannot read the Rex window layout.".to_owned());
            }
        }
        Ok(message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inventory_groups_terminal_blocks_by_window_and_keeps_ids() {
        let listing = br#"{"status":"running","terminals":[
          {"block_id":"block:one","session_id":"session:studio","window_id":"window:work","session_label":"Studio","window_label":"Work","name":"Editor"},
          {"block_id":"block:two","session_id":"session:studio","window_id":"window:work","name":"Tests","focused":true},
          {"block_id":"block:three","session_id":"session:studio","window_id":"window:logs","window_label":"Window 0123abcd","name":"Logs"}
        ]}"#;
        let windows = parse_inventory(listing).unwrap();
        assert_eq!(windows.len(), 2);
        assert_eq!(
            (&*windows[0].id, &*windows[0].title, &*windows[0].detail),
            ("window:work", "Work", "Studio · 2 panes")
        );
        assert_eq!(
            (&*windows[1].id, &*windows[1].title),
            ("window:logs", "Logs")
        );
        assert!(
            parse_inventory(br#"{"status":"not_running","terminals":[]}"#)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn inventory_rejects_duplicate_or_unusable_terminal_addresses() {
        let terminal =
            r#"{"block_id":"block:one","session_id":"session:studio","window_id":"window:work"}"#;
        let duplicate = format!(r#"{{"status":"running","terminals":[{terminal},{terminal}]}}"#);
        assert!(parse_inventory(duplicate.as_bytes()).is_err());
        for address in [
            "--help",
            "block:",
            "window:one",
            "block:a\nb",
            "block:one;exit",
        ] {
            assert!(!valid_id(address, "block"), "{address}");
        }
    }

    #[test]
    fn control_preserves_nested_layout_focus_and_zoom() {
        let message = Message::parse(br#"{"type":"view","view":{"revision":9,"session_id":"session:studio","windows":[{
            "window_id":"window:work","focused_block_id":"block:tests","zoomed_block_id":"block:tests","layers":[{
              "kind":"tiled","layout":{"split":{"split_id":"split:main","direction":"horizontal","ratio":0.65,
                 "before":{"block_id":"block:editor"},"after":{"block_id":"block:tests"}}}}
            ]},{
              "window_id":"window:other","focused_block_id":"block:float","zoomed_block_id":"block:float",
              "layers":[
                {"kind":"tiled","layout":{"block_id":"block:logs"}},
                {"kind":"floating","layout":{"block_id":"block:float"}}
              ]
            }]},"terminals":{"block:tests":{"name":"Tests"}}}"#).unwrap();
        let Message::View { view, terminals } = message else {
            panic!("expected a view")
        };
        assert_eq!(
            view.windows[0].layout().unwrap().panes(),
            ["block:editor", "block:tests"]
        );
        assert_eq!(
            view.windows[0].focused_block_id.as_deref(),
            Some("block:tests")
        );
        assert_eq!(
            view.windows[0].zoomed_block_id.as_deref(),
            Some("block:tests")
        );
        assert_eq!(terminals["block:tests"].name, "Tests");
        assert_eq!(view.windows[1].layout().unwrap().panes(), ["block:logs"]);
    }

    #[test]
    fn control_rejects_ambiguous_trees_and_invalid_geometry() {
        let view = r#"{"type":"view","view":{"revision":1,"session_id":"session:s","windows":[{"window_id":"window:w","layers":[{"kind":"tiled","layout":{"split":{"split_id":"split:s","direction":"horizontal","ratio":0.5,"before":{"block_id":"block:a"},"after":{"block_id":"block:b"}}}}]}]}}"#;
        assert!(Message::parse(view.replace("block:b", "block:a").as_bytes()).is_err());
        assert!(Message::parse(view.replace("0.5", "1.5").as_bytes()).is_err());
        assert!(Message::parse(view.replace("horizontal", "diagonal").as_bytes()).is_err());
        assert!(Message::parse(br#"{"type":"reply"}"#).is_err());
    }
}
