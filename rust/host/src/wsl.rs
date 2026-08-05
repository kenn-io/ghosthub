use std::ffi::{OsStr, OsString};
use std::fmt;

use model::DiagnosticKind;
use session::{AttachPlan, DiscoveredSession, SessionIdentity};

use crate::{CommandOutput, CommandRunner};

const WSL_EXE: &str = "wsl.exe";
const DEFAULT_TMUX: &str = "/usr/bin/tmux";
const INVENTORY_FORMAT: &str =
    "#{pid}\t#{session_id}\t#{session_created}\t#{session_name}\t#{session_attached}";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WslConfig {
    distro: Option<String>,
    tmux_binary: String,
    tmux_tmpdir: Option<String>,
}

impl WslConfig {
    /// Select a specific WSL distro with the default tmux path.
    ///
    /// # Errors
    ///
    /// Returns an error for an empty distro name.
    pub fn with_distro(distro: impl Into<String>) -> Result<Self, HostError> {
        Self::configured(Some(distro.into()), DEFAULT_TMUX, None)
    }

    /// Configure the WSL endpoint without consulting shell startup files.
    ///
    /// # Errors
    ///
    /// Returns an error when a configured distro is empty or a POSIX path is
    /// not absolute.
    pub fn configured(
        distro: Option<String>,
        tmux_binary: impl Into<String>,
        tmux_tmpdir: Option<String>,
    ) -> Result<Self, HostError> {
        if distro.as_ref().is_some_and(String::is_empty) {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                "configured WSL distro is empty",
            ));
        }

        let tmux_binary = tmux_binary.into();
        if !is_posix_absolute(&tmux_binary) {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                format!("tmux path is not absolute: {tmux_binary}"),
            ));
        }
        if let Some(path) = &tmux_tmpdir
            && !is_posix_absolute(path)
        {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                format!("tmux socket directory is not absolute: {path}"),
            ));
        }

        Ok(Self {
            distro,
            tmux_binary,
            tmux_tmpdir,
        })
    }
}

impl Default for WslConfig {
    fn default() -> Self {
        Self {
            distro: None,
            tmux_binary: DEFAULT_TMUX.to_owned(),
            tmux_tmpdir: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WslEndpoint {
    distro: String,
}

impl WslEndpoint {
    #[must_use]
    pub fn distro(&self) -> &str {
        &self.distro
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WslRuntimeIdentity {
    kernel_boot_id: String,
    init_start_ticks: u64,
}

impl WslRuntimeIdentity {
    #[must_use]
    pub fn kernel_boot_id(&self) -> &str {
        &self.kernel_boot_id
    }

    #[must_use]
    pub const fn init_start_ticks(&self) -> u64 {
        self.init_start_ticks
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostSnapshot {
    endpoint: WslEndpoint,
    runtime: WslRuntimeIdentity,
    sessions: Vec<DiscoveredSession>,
}

impl HostSnapshot {
    #[must_use]
    pub const fn endpoint(&self) -> &WslEndpoint {
        &self.endpoint
    }

    #[must_use]
    pub const fn runtime(&self) -> &WslRuntimeIdentity {
        &self.runtime
    }

    #[must_use]
    pub fn sessions(&self) -> &[DiscoveredSession] {
        &self.sessions
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostError {
    kind: DiagnosticKind,
    detail: String,
}

impl HostError {
    fn new(kind: DiagnosticKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }

    #[must_use]
    pub const fn kind(&self) -> DiagnosticKind {
        self.kind
    }
}

impl fmt::Display for HostError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.detail)
    }
}

impl std::error::Error for HostError {}

#[derive(Debug)]
pub struct WslHost<R> {
    config: WslConfig,
    runner: R,
}

impl<R: CommandRunner> WslHost<R> {
    #[must_use]
    pub const fn new(config: WslConfig, runner: R) -> Self {
        Self { config, runner }
    }

    #[must_use]
    pub const fn runner(&self) -> &R {
        &self.runner
    }

    /// Resolve the exact WSL runtime and discover its tmux inventory.
    ///
    /// # Errors
    ///
    /// Returns a classified error for transport, executable, permission,
    /// unsupported runtime, or malformed-output failures.
    pub fn discover(&self) -> Result<HostSnapshot, HostError> {
        let endpoint = self.resolve_endpoint()?;
        let runtime = self.resolve_runtime(&endpoint)?;
        let sessions = self.discover_sessions(&endpoint)?;
        Ok(HostSnapshot {
            endpoint,
            runtime,
            sessions,
        })
    }

    /// Build an attach-only plan for a discovered session.
    ///
    /// # Errors
    ///
    /// Returns an error if the session name cannot be represented.
    pub fn attach_plan(
        &self,
        endpoint: &WslEndpoint,
        session: &DiscoveredSession,
    ) -> Result<AttachPlan, HostError> {
        if session.name().contains(['\0', '\n', '\r']) {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                "tmux session name contains an invalid control character",
            ));
        }

        let mut args = pinned_prefix(endpoint);
        args.push(OsString::from("/usr/bin/env"));
        args.push(OsString::from("TERM=xterm-256color"));
        if let Some(path) = &self.config.tmux_tmpdir {
            args.push(OsString::from(format!("TMUX_TMPDIR={path}")));
        }
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(
            [
                "attach-session",
                "-E",
                "-t",
                &format!("={}", session.name()),
            ]
            .into_iter()
            .map(OsString::from),
        );

        Ok(AttachPlan::attach_only(
            WSL_EXE,
            args,
            session.name(),
            session.identity().clone(),
        ))
    }

    fn resolve_endpoint(&self) -> Result<WslEndpoint, HostError> {
        if let Some(distro) = &self.config.distro {
            return Ok(WslEndpoint {
                distro: distro.clone(),
            });
        }

        let output = self.run(&[OsString::from("--exec"), OsString::from("/usr/bin/env")])?;
        if output.status != 0 {
            return Err(classify_command_failure(
                output.status,
                &output.stderr,
                "resolve default WSL distro",
            ));
        }
        let stdout = decode(&output.stdout, "default distro environment")?;
        let distro = stdout
            .lines()
            .find_map(|line| line.strip_prefix("WSL_DISTRO_NAME="))
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "WSL_DISTRO_NAME missing from default distro environment",
                )
            })?;
        Ok(WslEndpoint {
            distro: distro.to_owned(),
        })
    }

    fn resolve_runtime(&self, endpoint: &WslEndpoint) -> Result<WslRuntimeIdentity, HostError> {
        let mut args = pinned_prefix(endpoint);
        args.extend(
            [
                "/usr/bin/cat",
                "/proc/version",
                "/proc/sys/kernel/random/boot_id",
                "/proc/1/stat",
            ]
            .into_iter()
            .map(OsString::from),
        );
        let output = self.run(&args)?;
        if output.status != 0 {
            return Err(classify_command_failure(
                output.status,
                &output.stderr,
                "read WSL runtime identity",
            ));
        }
        parse_runtime(&output.stdout)
    }

    fn discover_sessions(
        &self,
        endpoint: &WslEndpoint,
    ) -> Result<Vec<DiscoveredSession>, HostError> {
        let mut args = pinned_prefix(endpoint);
        args.push(OsString::from("/usr/bin/env"));
        args.push(OsString::from("TERM=xterm-256color"));
        if let Some(path) = &self.config.tmux_tmpdir {
            args.push(OsString::from(format!("TMUX_TMPDIR={path}")));
        }
        args.extend(
            [
                self.config.tmux_binary.as_str(),
                "-f",
                "/dev/null",
                "list-sessions",
                "-F",
                INVENTORY_FORMAT,
            ]
            .into_iter()
            .map(OsString::from),
        );
        let output = self.run(&args)?;
        if output.status != 0 {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if is_no_server(&stderr) {
                return Ok(Vec::new());
            }
            return Err(classify_command_failure(
                output.status,
                &output.stderr,
                &self.config.tmux_binary,
            ));
        }
        parse_inventory(&output.stdout)
    }

    fn run(&self, args: &[OsString]) -> Result<CommandOutput, HostError> {
        self.runner
            .run(OsStr::new(WSL_EXE), args)
            .map_err(|error| HostError::new(DiagnosticKind::Transport, error.to_string()))
    }
}

fn pinned_prefix(endpoint: &WslEndpoint) -> Vec<OsString> {
    ["--distribution", endpoint.distro(), "--exec"]
        .into_iter()
        .map(OsString::from)
        .collect()
}

fn parse_runtime(bytes: &[u8]) -> Result<WslRuntimeIdentity, HostError> {
    let output = decode(bytes, "WSL runtime identity")?;
    let mut lines = output.lines();
    let version = lines.next().unwrap_or_default();
    let kernel_boot_id = lines.next().unwrap_or_default();
    let init_stat = lines.next().unwrap_or_default();

    if !version.to_ascii_lowercase().contains("wsl2") {
        return Err(HostError::new(
            DiagnosticKind::UnsupportedEnvironment,
            format!("WSL2 required; kernel reported: {version}"),
        ));
    }
    if kernel_boot_id.is_empty() {
        return Err(HostError::new(
            DiagnosticKind::MalformedOutput,
            "kernel boot ID is missing",
        ));
    }
    let close_paren = init_stat.rfind(')').ok_or_else(|| {
        HostError::new(
            DiagnosticKind::MalformedOutput,
            "PID 1 stat has no command terminator",
        )
    })?;
    let fields = init_stat[close_paren + 1..]
        .split_whitespace()
        .collect::<Vec<_>>();
    let init_start_ticks = fields
        .get(19)
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| {
            HostError::new(
                DiagnosticKind::MalformedOutput,
                "PID 1 stat has no valid start time",
            )
        })?;

    Ok(WslRuntimeIdentity {
        kernel_boot_id: kernel_boot_id.to_owned(),
        init_start_ticks,
    })
}

fn parse_inventory(bytes: &[u8]) -> Result<Vec<DiscoveredSession>, HostError> {
    let output = decode(bytes, "tmux inventory")?;
    output
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let fields = line.split('\t').collect::<Vec<_>>();
            if fields.len() != 5 {
                return Err(HostError::new(
                    DiagnosticKind::MalformedOutput,
                    format!("tmux inventory row has {} fields", fields.len()),
                ));
            }
            let server_pid = fields[0].parse::<u32>().map_err(|_| {
                HostError::new(DiagnosticKind::MalformedOutput, "invalid tmux server PID")
            })?;
            let created_at = fields[2].parse::<u64>().map_err(|_| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "invalid tmux creation time",
                )
            })?;
            let attached_clients = fields[4].parse::<u32>().map_err(|_| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "invalid tmux attached-client count",
                )
            })?;
            Ok(DiscoveredSession::new(
                fields[3],
                SessionIdentity::new(server_pid, fields[1], created_at),
                attached_clients,
            ))
        })
        .collect()
}

fn decode<'a>(bytes: &'a [u8], subject: &str) -> Result<&'a str, HostError> {
    std::str::from_utf8(bytes).map_err(|_| {
        HostError::new(
            DiagnosticKind::MalformedOutput,
            format!("{subject} is not UTF-8"),
        )
    })
}

fn classify_command_failure(status: i32, stderr: &[u8], subject: &str) -> HostError {
    let stderr = String::from_utf8_lossy(stderr);
    let lower = stderr.to_ascii_lowercase();
    let kind = if status == 127 || lower.contains("no such file") {
        DiagnosticKind::ExecutableNotFound
    } else if lower.contains("permission denied") {
        DiagnosticKind::PermissionDenied
    } else {
        DiagnosticKind::Transport
    };
    HostError::new(kind, format!("{subject}: {}", stderr.trim()))
}

fn is_no_server(stderr: &str) -> bool {
    let lower = stderr.to_ascii_lowercase();
    lower.contains("no server running")
        || (lower.contains("error connecting") && lower.contains("no such file"))
}

fn is_posix_absolute(path: &str) -> bool {
    path.starts_with('/')
}
