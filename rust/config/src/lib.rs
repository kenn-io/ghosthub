//! Configuration and path resolution for the Rust Ghosthub application.

use std::{collections::BTreeMap, fmt};

use serde::Deserialize;

const CONFIG_HOME: &str = "GHOSTHUB_CONFIG_HOME";
const STATE_HOME: &str = "GHOSTHUB_STATE_HOME";
const GHOSTHUB_HOME: &str = "GHOSTHUB_HOME";

#[derive(Clone, Debug, PartialEq)]
pub struct TerminalAppearance {
    font_family: String,
    font_size: u16,
    background: u32,
    foreground: u32,
}

impl TerminalAppearance {
    #[must_use]
    pub fn font_family(&self) -> &str {
        &self.font_family
    }

    #[must_use]
    pub const fn font_size(&self) -> u16 {
        self.font_size
    }

    #[must_use]
    pub const fn background(&self) -> u32 {
        self.background
    }

    #[must_use]
    pub const fn foreground(&self) -> u32 {
        self.foreground
    }
}

impl Default for TerminalAppearance {
    fn default() -> Self {
        Self {
            font_family: "Cascadia Mono".to_owned(),
            font_size: 14,
            background: 0x11_13_18,
            foreground: 0xee_f0_f4,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum Platform {
    Posix,
    Windows,
}

#[derive(Clone, Debug)]
pub struct ResolveInput {
    pub platform: Platform,
    pub user_home: String,
    pub environment: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Roots {
    pub ghosthub_home: String,
    pub config: String,
    pub state: String,
    pub helpers: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ResolveErrorKind {
    NotLocalAbsolute,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolveError {
    input: String,
    kind: ResolveErrorKind,
}

impl ResolveError {
    #[must_use]
    pub fn input(&self) -> &str {
        &self.input
    }

    #[must_use]
    pub const fn kind(&self) -> ResolveErrorKind {
        self.kind
    }
}

impl fmt::Display for ResolveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "{} must be a local absolute path ({:?})",
            self.input, self.kind
        )
    }
}

impl std::error::Error for ResolveError {}

/// Resolve the application roots from injected platform, home, and
/// environment values.
///
/// # Errors
///
/// Returns a blocking error when a present override or required user home is
/// not a local absolute path under the selected platform's syntax.
pub fn resolve_roots(input: &ResolveInput) -> Result<Roots, ResolveError> {
    let home_override = resolve_override(input, GHOSTHUB_HOME)?;
    let config_override = resolve_override(input, CONFIG_HOME)?;
    let state_override = resolve_override(input, STATE_HOME)?;

    let ghosthub_home = if let Some(home) = &home_override {
        home.clone()
    } else {
        let home = resolve_user_home(input)?;
        join(input.platform, &home, ".ghosthub")
    };

    let config = if let Some(config) = config_override {
        config
    } else if home_override.is_some() || input.platform == Platform::Windows {
        join(input.platform, &ghosthub_home, "config")
    } else {
        let home = resolve_user_home(input)?;
        join(input.platform, &home, ".config/ghosthub")
    };

    let state = if let Some(state) = state_override {
        state
    } else {
        match input.platform {
            Platform::Posix => ghosthub_home.clone(),
            Platform::Windows => join(input.platform, &ghosthub_home, "state"),
        }
    };

    let helpers = join(input.platform, &ghosthub_home, "helpers");

    Ok(Roots {
        ghosthub_home,
        config,
        state,
        helpers,
    })
}

fn resolve_override(
    input: &ResolveInput,
    name: &'static str,
) -> Result<Option<String>, ResolveError> {
    input
        .environment
        .get(name)
        .map(|value| validate(input.platform, name, value))
        .transpose()
}

fn resolve_user_home(input: &ResolveInput) -> Result<String, ResolveError> {
    let name = match input.platform {
        Platform::Posix => "HOME",
        Platform::Windows => "USERPROFILE",
    };
    validate(input.platform, name, &input.user_home)
}

fn validate(platform: Platform, input: &str, value: &str) -> Result<String, ResolveError> {
    let valid = match platform {
        Platform::Posix => value.starts_with('/'),
        Platform::Windows => is_windows_drive_rooted(value),
    };

    if !valid {
        return Err(ResolveError {
            input: input.to_owned(),
            kind: ResolveErrorKind::NotLocalAbsolute,
        });
    }

    Ok(match platform {
        Platform::Posix => value.to_owned(),
        Platform::Windows => value.replace('/', "\\"),
    })
}

fn is_windows_drive_rooted(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/')
}

fn join(platform: Platform, base: &str, child: &str) -> String {
    match platform {
        Platform::Posix => {
            let base = base.trim_end_matches('/');
            if base.is_empty() {
                format!("/{}", child.trim_start_matches('/'))
            } else {
                format!("{base}/{}", child.trim_matches('/'))
            }
        }
        Platform::Windows => {
            let base = base.trim_end_matches(['\\', '/']);
            let child = child.replace('/', "\\");
            format!("{base}\\{}", child.trim_matches('\\'))
        }
    }
}
