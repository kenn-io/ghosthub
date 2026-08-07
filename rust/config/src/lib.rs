//! Configuration and path resolution for the Rust Ghosthub application.

use std::{collections::BTreeMap, fmt, fs, io, path::Path};

use serde::Deserialize;

const CONFIG_HOME: &str = "GHOSTHUB_CONFIG_HOME";
const STATE_HOME: &str = "GHOSTHUB_STATE_HOME";
const GHOSTHUB_HOME: &str = "GHOSTHUB_HOME";
const APPLICATION_CONFIG: &str = "config.toml";
const DEFAULT_TMUX_BINARY: &str = "/usr/bin/tmux";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WslSettings {
    distro: Option<String>,
    tmux_binary: String,
    socket_directory: Option<String>,
}

impl WslSettings {
    #[must_use]
    pub fn distro(&self) -> Option<&str> {
        self.distro.as_deref()
    }

    #[must_use]
    pub fn tmux_binary(&self) -> &str {
        &self.tmux_binary
    }

    #[must_use]
    pub fn socket_directory(&self) -> Option<&str> {
        self.socket_directory.as_deref()
    }
}

impl Default for WslSettings {
    fn default() -> Self {
        Self {
            distro: None,
            tmux_binary: DEFAULT_TMUX_BINARY.to_owned(),
            socket_directory: None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ApplicationConfig {
    wsl: WslSettings,
    terminal: TerminalAppearance,
}

impl ApplicationConfig {
    /// Parse and validate the read-only Rust-port configuration.
    ///
    /// # Errors
    ///
    /// Returns an error for malformed TOML, unknown fields, or invalid values.
    pub fn from_toml(contents: &str) -> Result<Self, ConfigError> {
        let file: ConfigFile = toml::from_str(contents)
            .map_err(|error| ConfigError::new(format!("parse {APPLICATION_CONFIG}: {error}")))?;
        file.try_into()
    }

    /// Load `<resolved config root>/config.toml`, or use defaults when absent.
    ///
    /// # Errors
    ///
    /// Returns an error when a present file cannot be read or validated.
    pub fn load(roots: &Roots) -> Result<Self, ConfigError> {
        let path = Path::new(&roots.config).join(APPLICATION_CONFIG);
        match fs::read_to_string(&path) {
            Ok(contents) => Self::from_toml(&contents),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(ConfigError::new(format!(
                "read {}: {error}",
                path.display()
            ))),
        }
    }

    /// Resolve the current process configuration roots and load the app file.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid path overrides or an invalid present file.
    pub fn load_current() -> Result<Self, ConfigError> {
        let platform = current_platform();
        let home_name = if platform == Platform::Windows {
            "USERPROFILE"
        } else {
            "HOME"
        };
        let user_home = std::env::var(home_name)
            .map_err(|error| ConfigError::new(format!("read {home_name}: {error}")))?;
        let mut environment = BTreeMap::new();
        for name in [GHOSTHUB_HOME, CONFIG_HOME, STATE_HOME] {
            match std::env::var(name) {
                Ok(value) => {
                    environment.insert(name.to_owned(), value);
                }
                Err(std::env::VarError::NotPresent) => {}
                Err(error) => {
                    return Err(ConfigError::new(format!("read {name}: {error}")));
                }
            }
        }
        let roots = resolve_roots(&ResolveInput {
            platform,
            user_home,
            environment,
        })
        .map_err(|error| ConfigError::new(error.to_string()))?;
        Self::load(&roots)
    }

    #[must_use]
    pub const fn wsl(&self) -> &WslSettings {
        &self.wsl
    }

    #[must_use]
    pub const fn terminal(&self) -> &TerminalAppearance {
        &self.terminal
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConfigError {
    detail: String,
}

impl ConfigError {
    fn new(detail: impl Into<String>) -> Self {
        Self {
            detail: detail.into(),
        }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.detail)
    }
}

impl std::error::Error for ConfigError {}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct ConfigFile {
    wsl: WslFile,
    terminal: TerminalFile,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "kebab-case")]
struct WslFile {
    distro: Option<String>,
    tmux_binary: Option<String>,
    socket_directory: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "kebab-case")]
struct TerminalFile {
    font_family: Option<String>,
    font_size: Option<u16>,
    background: Option<String>,
    foreground: Option<String>,
    clipboard_write: Option<bool>,
}

impl TryFrom<ConfigFile> for ApplicationConfig {
    type Error = ConfigError;

    fn try_from(file: ConfigFile) -> Result<Self, Self::Error> {
        let defaults = Self::default();
        let tmux_binary = file
            .wsl
            .tmux_binary
            .unwrap_or_else(|| defaults.wsl.tmux_binary.clone());
        require_posix_absolute("wsl.tmux-binary", &tmux_binary)?;
        if let Some(distro) = &file.wsl.distro {
            require_nonempty("wsl.distro", distro)?;
        }
        if let Some(path) = &file.wsl.socket_directory {
            require_posix_absolute("wsl.socket-directory", path)?;
        }

        let font_family = file
            .terminal
            .font_family
            .unwrap_or_else(|| defaults.terminal.font_family.clone());
        require_nonempty("terminal.font-family", &font_family)?;
        let font_size = file
            .terminal
            .font_size
            .unwrap_or(defaults.terminal.font_size);
        if font_size == 0 {
            return Err(ConfigError::new(
                "terminal.font-size must be greater than zero",
            ));
        }
        let background = file
            .terminal
            .background
            .map_or(Ok(defaults.terminal.background), |value| {
                parse_rgb("terminal.background", &value)
            })?;
        let foreground = file
            .terminal
            .foreground
            .map_or(Ok(defaults.terminal.foreground), |value| {
                parse_rgb("terminal.foreground", &value)
            })?;

        Ok(Self {
            wsl: WslSettings {
                distro: file.wsl.distro,
                tmux_binary,
                socket_directory: file.wsl.socket_directory,
            },
            terminal: TerminalAppearance {
                font_family,
                font_size,
                background,
                foreground,
                allow_remote_clipboard_write: file
                    .terminal
                    .clipboard_write
                    .unwrap_or(defaults.terminal.allow_remote_clipboard_write),
            },
        })
    }
}

fn require_nonempty(name: &str, value: &str) -> Result<(), ConfigError> {
    if value.is_empty() {
        Err(ConfigError::new(format!("{name} must not be empty")))
    } else {
        Ok(())
    }
}

fn require_posix_absolute(name: &str, value: &str) -> Result<(), ConfigError> {
    if value.starts_with('/') {
        Ok(())
    } else {
        Err(ConfigError::new(format!(
            "{name} must be an absolute POSIX path"
        )))
    }
}

fn parse_rgb(name: &str, value: &str) -> Result<u32, ConfigError> {
    let digits = value
        .strip_prefix('#')
        .filter(|digits| digits.len() == 6)
        .ok_or_else(|| ConfigError::new(format!("{name} must use #RRGGBB")))?;
    u32::from_str_radix(digits, 16)
        .map_err(|_| ConfigError::new(format!("{name} must use #RRGGBB")))
}

const fn current_platform() -> Platform {
    #[cfg(target_os = "windows")]
    {
        Platform::Windows
    }
    #[cfg(not(target_os = "windows"))]
    {
        Platform::Posix
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TerminalAppearance {
    font_family: String,
    font_size: u16,
    background: u32,
    foreground: u32,
    allow_remote_clipboard_write: bool,
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

    #[must_use]
    pub const fn allow_remote_clipboard_write(&self) -> bool {
        self.allow_remote_clipboard_write
    }

    #[must_use]
    pub fn with_remote_clipboard_write(mut self, allowed: bool) -> Self {
        self.allow_remote_clipboard_write = allowed;
        self
    }
}

impl Default for TerminalAppearance {
    fn default() -> Self {
        Self {
            font_family: "Cascadia Mono".to_owned(),
            font_size: 14,
            background: 0x0c_0f_14,
            foreground: 0xd8_de_e9,
            allow_remote_clipboard_write: true,
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
