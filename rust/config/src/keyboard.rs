use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ConfigError;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ShortcutAction {
    ToggleSidebar,
    NextSession,
    PreviousSession,
}

impl ShortcutAction {
    pub const ALL: [Self; 3] = [
        Self::ToggleSidebar,
        Self::NextSession,
        Self::PreviousSession,
    ];

    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::ToggleSidebar => "Toggle Sidebar",
            Self::NextSession => "Next Session",
            Self::PreviousSession => "Previous Session",
        }
    }

    fn default_binding(self) -> KeyChord {
        KeyChord {
            control: true,
            alt: false,
            shift: self != Self::NextSession,
            key: if self == Self::ToggleSidebar {
                "b"
            } else {
                "tab"
            }
            .to_owned(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KeyChord {
    control: bool,
    alt: bool,
    shift: bool,
    key: String,
}

impl KeyChord {
    /// Parse one Ctrl/Alt chord; ordinary typing and fixed shortcuts stay available.
    ///
    /// # Errors
    /// Rejects missing modifiers, unknown keys, repeated modifiers, and reserved chords.
    pub fn parse(value: &str) -> Result<Self, ConfigError> {
        let value = value.trim().to_ascii_lowercase();
        let mut parts: Vec<_> = value.split('+').collect();
        let key = parts.pop().unwrap_or_default();
        let key = if key == "plus" { "+" } else { key };
        let named = matches!(
            key,
            "tab"
                | "enter"
                | "escape"
                | "backspace"
                | "delete"
                | "space"
                | "left"
                | "right"
                | "up"
                | "down"
                | "home"
                | "end"
                | "pageup"
                | "pagedown"
        );
        let character = key.len() == 1 && key.as_bytes()[0].is_ascii_graphic();
        let function = key.strip_prefix('f').is_some_and(|digits| {
            digits
                .parse::<u8>()
                .is_ok_and(|n| (1..=12).contains(&n) && digits == n.to_string())
        });
        if !named && !character && !function {
            return Err(ConfigError::new(
                "Choose a letter, number, punctuation, navigation key, or F1–F12",
            ));
        }
        let mut chord = Self {
            control: false,
            alt: false,
            shift: false,
            key: key.to_owned(),
        };
        for part in parts {
            let field = match part {
                "ctrl" => &mut chord.control,
                "alt" => &mut chord.alt,
                "shift" => &mut chord.shift,
                _ => {
                    return Err(ConfigError::new(
                        "Use Ctrl, Alt, and Shift as shortcut modifiers",
                    ));
                }
            };
            if *field {
                return Err(ConfigError::new("Use each shortcut modifier once"));
            }
            *field = true;
        }
        if !chord.control && !chord.alt {
            return Err(ConfigError::new("Include Ctrl or Alt in the shortcut"));
        }
        if chord.control && chord.shift && key == "v" {
            return Err(ConfigError::new("Ctrl+Shift+V is reserved for Paste"));
        }
        if chord.control && chord.shift && key == "c" {
            return Err(ConfigError::new("Ctrl+Shift+C is reserved for Copy"));
        }
        if (chord.alt && matches!(key, "tab" | "f4"))
            || (chord.control && key == "escape")
            || (chord.control && chord.alt && key == "delete")
        {
            return Err(ConfigError::new(
                "This shortcut is reserved by the operating system",
            ));
        }
        Ok(chord)
    }

    #[must_use]
    pub fn config_value(&self) -> String {
        self.parts(if self.key == "+" { "plus" } else { &self.key })
            .join("+")
    }

    #[must_use]
    pub fn gpui_value(&self) -> String {
        self.parts(&self.key).join("-")
    }

    #[must_use]
    pub fn display(&self) -> String {
        let value = self.config_value();
        value
            .split('+')
            .map(|part| {
                if part.len() == 1 {
                    part.to_ascii_uppercase()
                } else {
                    part[..1].to_ascii_uppercase() + &part[1..]
                }
            })
            .collect::<Vec<_>>()
            .join("+")
    }

    fn parts<'a>(&self, key: &'a str) -> Vec<&'a str> {
        let mut parts = Vec::new();
        if self.control {
            parts.push("ctrl");
        }
        if self.alt {
            parts.push("alt");
        }
        if self.shift {
            parts.push("shift");
        }
        parts.push(key);
        parts
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "String", into = "String")]
enum Shortcut {
    Disabled,
    Binding(KeyChord),
}

impl TryFrom<String> for Shortcut {
    type Error = ConfigError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value == "none" {
            Ok(Self::Disabled)
        } else {
            KeyChord::parse(&value).map(Self::Binding)
        }
    }
}

impl From<Shortcut> for String {
    fn from(value: Shortcut) -> Self {
        match value {
            Shortcut::Disabled => "none".to_owned(),
            Shortcut::Binding(chord) => chord.config_value(),
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct KeyboardPreferences {
    shortcuts: BTreeMap<ShortcutAction, Shortcut>,
}

impl KeyboardPreferences {
    #[must_use]
    pub fn binding(&self, action: ShortcutAction) -> Option<KeyChord> {
        match self.shortcuts.get(&action) {
            Some(Shortcut::Disabled) => None,
            Some(Shortcut::Binding(chord)) => Some(chord.clone()),
            None => Some(action.default_binding()),
        }
    }

    /// Change one action, disable it with `none`, or reset it with `None`.
    ///
    /// # Errors
    /// Rejects invalid chords and conflicts without changing the current preferences.
    pub fn set(&mut self, action: ShortcutAction, value: Option<&str>) -> Result<(), ConfigError> {
        let mut candidate = self.clone();
        if let Some(value) = value {
            candidate
                .shortcuts
                .insert(action, Shortcut::try_from(value.to_owned())?);
        } else {
            candidate.shortcuts.remove(&action);
        }
        candidate.validate()?;
        *self = candidate;
        Ok(())
    }

    pub(crate) fn validate(&self) -> Result<(), ConfigError> {
        for (index, action) in ShortcutAction::ALL.into_iter().enumerate() {
            if let Some(binding) = self.binding(action) {
                for other in ShortcutAction::ALL.into_iter().skip(index + 1) {
                    if self.binding(other).as_ref() == Some(&binding) {
                        return Err(ConfigError::new(format!(
                            "{} is used by both {} and {}",
                            binding.display(),
                            action.title(),
                            other.title()
                        )));
                    }
                }
            }
        }
        Ok(())
    }
}
