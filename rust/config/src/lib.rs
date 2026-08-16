//! Configuration and path resolution for the Rust Ghosthub application.

use std::{
    collections::BTreeMap,
    fmt, fs,
    io::{self, Write},
    path::Path,
};

use serde::{Deserialize, Serialize};

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
    ssh_hosts: Vec<SshHostSettings>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SshHostSettings {
    name: String,
    hostname: String,
    user: Option<String>,
    port: Option<u16>,
    tmux_binary: String,
    socket_directory: Option<String>,
}

impl SshHostSettings {
    /// Validate one user-authored SSH host.
    ///
    /// # Errors
    ///
    /// Returns an error for empty labels or targets, invalid ports, control
    /// characters, or non-absolute remote paths.
    pub fn new(
        name: impl Into<String>,
        hostname: impl Into<String>,
        user: Option<String>,
        port: Option<u16>,
        tmux_binary: impl Into<String>,
        socket_directory: Option<String>,
    ) -> Result<Self, ConfigError> {
        let host = Self {
            name: name.into(),
            hostname: hostname.into(),
            user,
            port,
            tmux_binary: tmux_binary.into(),
            socket_directory,
        };
        host.validate("ssh-host")?;
        Ok(host)
    }

    fn validate(&self, prefix: &str) -> Result<(), ConfigError> {
        require_safe_nonempty(&format!("{prefix}.name"), &self.name)?;
        require_safe_nonempty(&format!("{prefix}.hostname"), &self.hostname)?;
        if let Some(user) = &self.user {
            require_safe_nonempty(&format!("{prefix}.user"), user)?;
        }
        if self.port == Some(0) {
            return Err(ConfigError::new(format!(
                "{prefix}.port must be greater than zero"
            )));
        }
        require_posix_absolute(&format!("{prefix}.tmux-binary"), &self.tmux_binary)?;
        if let Some(path) = &self.socket_directory {
            require_posix_absolute(&format!("{prefix}.socket-directory"), path)?;
        }
        Ok(())
    }

    #[must_use]
    pub fn id(&self) -> String {
        let user = self.user.as_deref().unwrap_or_default();
        let port = self.port.map_or_else(String::new, |port| port.to_string());
        format!("ssh:{user}@{}:{port}", self.hostname)
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub fn hostname(&self) -> &str {
        &self.hostname
    }

    #[must_use]
    pub fn user(&self) -> Option<&str> {
        self.user.as_deref()
    }

    #[must_use]
    pub const fn port(&self) -> Option<u16> {
        self.port
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
        let roots = current_roots()?;
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

    #[must_use]
    pub fn ssh_hosts(&self) -> &[SshHostSettings] {
        &self.ssh_hosts
    }

    /// Replace the configured SSH hosts and persist the complete validated
    /// application configuration.
    ///
    /// # Errors
    ///
    /// Returns an error when host identities collide or the file cannot be
    /// written.
    pub fn replace_ssh_hosts(
        &mut self,
        roots: &Roots,
        hosts: Vec<SshHostSettings>,
    ) -> Result<(), ConfigError> {
        validate_unique_ssh_hosts(&hosts)?;
        let mut candidate = self.clone();
        candidate.ssh_hosts = hosts;
        candidate.save(roots)?;
        *self = candidate;
        Ok(())
    }

    /// Persist the current configuration to its resolved location.
    ///
    /// # Errors
    ///
    /// Returns an error when the directory or file cannot be written.
    pub fn save(&self, roots: &Roots) -> Result<(), ConfigError> {
        let directory = Path::new(&roots.config);
        fs::create_dir_all(directory).map_err(|error| {
            ConfigError::new(format!("create {}: {error}", directory.display()))
        })?;
        let path = directory.join(APPLICATION_CONFIG);
        let contents = toml::to_string_pretty(&ConfigFile::from(self))
            .map_err(|error| ConfigError::new(format!("encode {APPLICATION_CONFIG}: {error}")))?;
        let mut temporary = tempfile::NamedTempFile::new_in(directory).map_err(|error| {
            ConfigError::new(format!("create temporary {}: {error}", path.display()))
        })?;
        temporary.write_all(contents.as_bytes()).map_err(|error| {
            ConfigError::new(format!("write temporary {}: {error}", path.display()))
        })?;
        temporary.as_file().sync_all().map_err(|error| {
            ConfigError::new(format!("sync temporary {}: {error}", path.display()))
        })?;
        temporary.persist(&path).map_err(|error| {
            ConfigError::new(format!("replace {}: {}", path.display(), error.error))
        })?;
        Ok(())
    }

    /// Resolve the current process roots without loading configuration.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid path overrides or a missing user home.
    pub fn current_roots() -> Result<Roots, ConfigError> {
        current_roots()
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

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
struct ConfigFile {
    wsl: WslFile,
    terminal: TerminalFile,
    #[serde(rename = "ssh-host")]
    ssh_hosts: Vec<SshHostFile>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields, rename_all = "kebab-case")]
struct WslFile {
    distro: Option<String>,
    tmux_binary: Option<String>,
    socket_directory: Option<String>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields, rename_all = "kebab-case")]
struct TerminalFile {
    font_family: Option<String>,
    font_size: Option<u16>,
    background: Option<String>,
    foreground: Option<String>,
    clipboard_write: Option<bool>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields, rename_all = "kebab-case")]
struct SshHostFile {
    name: String,
    hostname: String,
    user: Option<String>,
    port: Option<u16>,
    tmux_binary: Option<String>,
    socket_directory: Option<String>,
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

        let ssh_hosts = file
            .ssh_hosts
            .into_iter()
            .enumerate()
            .map(|(index, host)| {
                let host = SshHostSettings {
                    name: host.name,
                    hostname: host.hostname,
                    user: host.user,
                    port: host.port,
                    tmux_binary: host
                        .tmux_binary
                        .unwrap_or_else(|| DEFAULT_TMUX_BINARY.to_owned()),
                    socket_directory: host.socket_directory,
                };
                host.validate(&format!("ssh-host[{index}]"))?;
                Ok(host)
            })
            .collect::<Result<Vec<_>, ConfigError>>()?;
        validate_unique_ssh_hosts(&ssh_hosts)?;

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
            ssh_hosts,
        })
    }
}

impl From<&ApplicationConfig> for ConfigFile {
    fn from(config: &ApplicationConfig) -> Self {
        Self {
            wsl: WslFile {
                distro: config.wsl.distro.clone(),
                tmux_binary: Some(config.wsl.tmux_binary.clone()),
                socket_directory: config.wsl.socket_directory.clone(),
            },
            terminal: TerminalFile {
                font_family: Some(config.terminal.font_family.clone()),
                font_size: Some(config.terminal.font_size),
                background: Some(format!("#{:06x}", config.terminal.background)),
                foreground: Some(format!("#{:06x}", config.terminal.foreground)),
                clipboard_write: Some(config.terminal.allow_remote_clipboard_write),
            },
            ssh_hosts: config
                .ssh_hosts
                .iter()
                .map(|host| SshHostFile {
                    name: host.name.clone(),
                    hostname: host.hostname.clone(),
                    user: host.user.clone(),
                    port: host.port,
                    tmux_binary: Some(host.tmux_binary.clone()),
                    socket_directory: host.socket_directory.clone(),
                })
                .collect(),
        }
    }
}

fn validate_unique_ssh_hosts(hosts: &[SshHostSettings]) -> Result<(), ConfigError> {
    let mut identities = std::collections::BTreeSet::new();
    for host in hosts {
        if !identities.insert(host.id()) {
            return Err(ConfigError::new(format!(
                "SSH host {} is configured more than once",
                host.hostname
            )));
        }
    }
    Ok(())
}

fn require_nonempty(name: &str, value: &str) -> Result<(), ConfigError> {
    if value.is_empty() {
        Err(ConfigError::new(format!("{name} must not be empty")))
    } else {
        Ok(())
    }
}

fn require_safe_nonempty(name: &str, value: &str) -> Result<(), ConfigError> {
    require_nonempty(name, value)?;
    if value.chars().any(char::is_control) {
        Err(ConfigError::new(format!(
            "{name} must not contain control characters"
        )))
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

fn current_roots() -> Result<Roots, ConfigError> {
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
            Err(error) => return Err(ConfigError::new(format!("read {name}: {error}"))),
        }
    }
    resolve_roots(&ResolveInput {
        platform,
        user_home,
        environment,
    })
    .map_err(|error| ConfigError::new(error.to_string()))
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
