//! KWT-leased SSH transport for remote tmux discovery and attachment.

use std::ffi::{OsStr, OsString};
use std::fmt;
use std::path::Path;
use std::time::Duration;

use model::DiagnosticKind;
use session::{
    AttachPlan, DiscoveredSession, HerdrAttachPlan, HerdrLaunchOnce, HerdrLaunchTarget,
    HerdrSessionRecord, SessionIdentity, ZellijAttachPlan, ZellijLaunchOnce, ZellijSessionName,
    ZellijSessionRecord,
};

use crate::{
    AttachTerm, CancellationToken, CommandPrefix, CommandRunner, HerdrInventory, HostError,
    KwtSshExecutable, KwtSshLeaseClient, KwtSshResolver, SshLease, SshLeaseEvent, SshLeasePrompt,
    SshTarget, ZellijInventory, herdr, zellij,
};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);
// Keep fixed metadata printable under `LC_ALL=C`: tmux sanitizes control
// characters in format output to `_` in that locale. The name remains
// length-prefixed, so it may contain the separator or any other non-NUL byte.
const INVENTORY_FORMAT: &str =
    "#{pid}|#{session_id}|#{session_created}|#{session_attached}|#{n:session_name}|#{session_name}";
const TMUX_PATH_MARKER: &str = "GHOSTHUB_TMUX_PATH=";
const TMUX_PROBE_PREFIX: &str = "GHOSTHUB_TMUX_PROBE_";
const HERDR_PROBE_PREFIX: &str = "GHOSTHUB_HERDR_PROBE_";
const HERDR_INVENTORY_PREFIX: &str = "GHOSTHUB_HERDR_INVENTORY_";
const ZELLIJ_PROBE_PREFIX: &str = "GHOSTHUB_ZELLIJ_PROBE_";
const ZELLIJ_INVENTORY_PREFIX: &str = "GHOSTHUB_ZELLIJ_INVENTORY_";
const TERMINFO_PROBE_PREFIX: &str = "GHOSTHUB_TERMINFO_PROBE_";
const IDENTITY_MISMATCH_PREFIX: &str = "GHOSTHUB_REMOTE_IDENTITY_MISMATCH_";
const TERMINFO_PROBE_SCRIPT: &str = "\
if command -v infocmp >/dev/null 2>&1; then \
  if infocmp xterm-256color >/dev/null 2>&1; then printf 'xterm-256color\\n'; exit 0; fi; \
  if infocmp xterm >/dev/null 2>&1; then printf 'xterm\\n'; exit 0; fi; \
elif command -v tput >/dev/null 2>&1; then \
  if tput -T xterm-256color longname >/dev/null 2>&1; then printf 'xterm-256color\\n'; exit 0; fi; \
  if tput -T xterm longname >/dev/null 2>&1; then printf 'xterm\\n'; exit 0; fi; \
else \
  printf 'neither infocmp nor tput is available\\n' >&2; exit 127; \
fi; \
printf 'neither xterm-256color nor xterm terminfo is available\\n' >&2; exit 1";

/// Absolute system OpenSSH client used only with KWT-issued lease arguments.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SshExecutable(OsString);

impl SshExecutable {
    /// Resolve the system-owned OpenSSH executable without consulting `PATH`.
    ///
    /// # Errors
    ///
    /// Returns an error when the authoritative system location cannot be
    /// resolved or does not contain an executable.
    pub fn system() -> Result<Self, RemoteTmuxError> {
        #[cfg(windows)]
        let path = crate::windows_system::ssh_executable()
            .map_err(|error| RemoteTmuxError::local_executable(&error))?;
        #[cfg(not(windows))]
        let path = OsString::from("/usr/bin/ssh");
        Self::from_absolute(path)
    }

    /// Construct an injected absolute OpenSSH path.
    ///
    /// # Errors
    ///
    /// Returns an error for a relative or missing path.
    pub fn from_absolute(path: impl Into<OsString>) -> Result<Self, RemoteTmuxError> {
        let path = path.into();
        if !Path::new(&path).is_absolute() {
            return Err(RemoteTmuxError::new(
                DiagnosticKind::ExecutableNotFound,
                "OpenSSH executable path is not absolute",
            ));
        }
        if !Path::new(&path).is_file() {
            return Err(RemoteTmuxError::new(
                DiagnosticKind::ExecutableNotFound,
                format!("OpenSSH is not installed at {}", Path::new(&path).display()),
            ));
        }
        Ok(Self(path))
    }

    #[must_use]
    pub fn as_os_str(&self) -> &OsStr {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteTmuxConfig {
    id: String,
    name: String,
    target: SshTarget,
    tmux_binary: String,
    socket_directory: Option<String>,
}

impl RemoteTmuxConfig {
    /// Construct one configured SSH endpoint.
    ///
    /// # Errors
    ///
    /// Returns an error for unsafe labels or non-absolute remote paths.
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        target: SshTarget,
        tmux_binary: impl Into<String>,
        socket_directory: Option<String>,
    ) -> Result<Self, RemoteTmuxError> {
        let config = Self {
            id: id.into(),
            name: name.into(),
            target,
            tmux_binary: tmux_binary.into(),
            socket_directory,
        };
        require_safe("remote host ID", &config.id)?;
        require_safe("remote host name", &config.name)?;
        if !config.tmux_binary.is_empty() {
            require_absolute("remote tmux binary", &config.tmux_binary)?;
        }
        if let Some(path) = &config.socket_directory {
            require_absolute("remote tmux socket directory", path)?;
        }
        Ok(config)
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub const fn target(&self) -> &SshTarget {
        &self.target
    }

    #[must_use]
    pub fn endpoint(&self) -> String {
        let mut endpoint = self
            .target
            .user()
            .map_or_else(String::new, |user| format!("{user}@"));
        endpoint.push_str(self.target.hostname());
        if let Some(port) = self.target.port() {
            endpoint.push(':');
            endpoint.push_str(&port.to_string());
        }
        endpoint
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

impl Default for RemoteTmuxConfig {
    fn default() -> Self {
        Self {
            id: "ssh:example".to_owned(),
            name: "Remote host".to_owned(),
            target: SshTarget::new("example.invalid", None, None).expect("static SSH target"),
            tmux_binary: String::new(),
            socket_directory: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct RemoteTmuxSnapshot {
    endpoint: String,
    route_identity: String,
    lease_generation: u64,
    tmux_binary: Option<String>,
    tmux_diagnostic: Option<HostError>,
    sessions: Vec<DiscoveredSession>,
    herdr: HerdrInventory,
    zellij: ZellijInventory,
    lease: SshLease,
}

/// Multiplexer inventory captured through one reviewed SSH lease.
#[derive(Clone, Debug)]
pub struct RemoteSessionInventory {
    tmux_binary: Option<String>,
    tmux_diagnostic: Option<HostError>,
    sessions: Vec<DiscoveredSession>,
    herdr: HerdrInventory,
    zellij: ZellijInventory,
}

impl RemoteSessionInventory {
    #[must_use]
    pub fn tmux_binary(&self) -> Option<&str> {
        self.tmux_binary.as_deref()
    }

    #[must_use]
    pub const fn tmux_diagnostic(&self) -> Option<&HostError> {
        self.tmux_diagnostic.as_ref()
    }

    #[must_use]
    pub fn sessions(&self) -> &[DiscoveredSession] {
        &self.sessions
    }

    #[must_use]
    pub const fn herdr(&self) -> &HerdrInventory {
        &self.herdr
    }

    #[must_use]
    pub const fn zellij(&self) -> &ZellijInventory {
        &self.zellij
    }
}

impl RemoteTmuxSnapshot {
    #[must_use]
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    #[must_use]
    pub fn route_identity(&self) -> &str {
        &self.route_identity
    }

    #[must_use]
    pub const fn lease_generation(&self) -> u64 {
        self.lease_generation
    }

    #[must_use]
    pub fn tmux_binary(&self) -> Option<&str> {
        self.tmux_binary.as_deref()
    }

    #[must_use]
    pub const fn tmux_diagnostic(&self) -> Option<&HostError> {
        self.tmux_diagnostic.as_ref()
    }

    #[must_use]
    pub fn sessions(&self) -> &[DiscoveredSession] {
        &self.sessions
    }

    #[must_use]
    pub const fn herdr(&self) -> &HerdrInventory {
        &self.herdr
    }

    #[must_use]
    pub const fn zellij(&self) -> &ZellijInventory {
        &self.zellij
    }

    #[must_use]
    pub const fn lease(&self) -> &SshLease {
        &self.lease
    }

    /// Replace only the multiplexer inventory while preserving the reviewed
    /// route and lease identity that authorized the refresh.
    #[must_use]
    pub fn with_inventory(&self, inventory: RemoteSessionInventory) -> Self {
        Self {
            endpoint: self.endpoint.clone(),
            route_identity: self.route_identity.clone(),
            lease_generation: self.lease_generation,
            tmux_binary: inventory.tmux_binary,
            tmux_diagnostic: inventory.tmux_diagnostic,
            sessions: inventory.sessions,
            herdr: inventory.herdr,
            zellij: inventory.zellij,
            lease: self.lease.clone(),
        }
    }
}

#[derive(Clone)]
pub struct RemoteTmuxHost<R> {
    config: RemoteTmuxConfig,
    controller: CommandPrefix,
    ssh: CommandPrefix,
    runner: R,
}

impl<R> RemoteTmuxHost<R> {
    #[must_use]
    pub fn new(
        config: RemoteTmuxConfig,
        controller: &KwtSshExecutable,
        ssh: &SshExecutable,
        runner: R,
    ) -> Self {
        Self {
            config,
            controller: CommandPrefix::native(controller.as_os_str().to_os_string()),
            ssh: CommandPrefix::native(ssh.as_os_str().to_os_string()),
            runner,
        }
    }

    pub(crate) const fn with_commands(
        config: RemoteTmuxConfig,
        controller: CommandPrefix,
        ssh: CommandPrefix,
        runner: R,
    ) -> Self {
        Self {
            config,
            controller,
            ssh,
            runner,
        }
    }

    #[must_use]
    pub const fn config(&self) -> &RemoteTmuxConfig {
        &self.config
    }

    #[cfg(test)]
    pub(crate) const fn commands(&self) -> (&CommandPrefix, &CommandPrefix) {
        (&self.controller, &self.ssh)
    }
}

impl<R: CommandRunner + Clone> RemoteTmuxHost<R> {
    /// Resolve, acquire, and verify one remote tmux inventory.
    ///
    /// # Errors
    ///
    /// Returns a classified KWT, OpenSSH, or strict-inventory failure.
    pub fn connect(
        &self,
        cancellation: &CancellationToken,
        prompt: impl FnMut(&SshLeasePrompt) -> Result<String, crate::SshError>,
        status: impl FnMut(&SshLeaseEvent),
    ) -> Result<RemoteTmuxSnapshot, RemoteTmuxError> {
        let route = KwtSshResolver::with_command(self.controller.clone(), self.runner.clone())
            .resolve(self.config.target(), cancellation)
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let lease = KwtSshLeaseClient::with_command(self.controller.clone())
            .acquire(&route, cancellation, prompt, status)
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let inventory = self.refresh(&lease, cancellation)?;
        Ok(RemoteTmuxSnapshot {
            endpoint: self.config.endpoint(),
            route_identity: route.route_identity().to_owned(),
            lease_generation: lease.result().generation(),
            tmux_binary: inventory.tmux_binary,
            tmux_diagnostic: inventory.tmux_diagnostic,
            sessions: inventory.sessions,
            herdr: inventory.herdr,
            zellij: inventory.zellij,
            lease,
        })
    }

    /// Refresh inventory through an already-reviewed live lease.
    ///
    /// # Errors
    ///
    /// Returns a classified OpenSSH, remote tmux, or strict-inventory failure.
    pub fn refresh(
        &self,
        lease: &SshLease,
        cancellation: &CancellationToken,
    ) -> Result<RemoteSessionInventory, RemoteTmuxError> {
        let (tmux_binary, sessions, tmux_diagnostic) = scope_tmux_inventory(
            self.resolve_tmux_binary(lease, cancellation)
                .and_then(|binary| {
                    self.discover_sessions(lease, &binary, cancellation)
                        .map(|sessions| (binary, sessions))
                }),
        )?;
        let herdr = self.discover_herdr(lease, cancellation)?;
        let zellij = self.discover_zellij(lease, cancellation)?;
        Ok(RemoteSessionInventory {
            tmux_binary,
            tmux_diagnostic,
            sessions,
            herdr,
            zellij,
        })
    }

    /// Select a terminal type proven usable by the remote terminfo database.
    ///
    /// # Errors
    ///
    /// Returns a classified remote-command failure when neither required
    /// terminal entry can be verified.
    pub fn probe_terminal_term(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        cancellation: &CancellationToken,
    ) -> Result<AttachTerm, RemoteTmuxError> {
        let output = self.run_framed_remote_shell(
            snapshot.lease(),
            TERMINFO_PROBE_SCRIPT,
            TERMINFO_PROBE_PREFIX,
            cancellation,
        )?;
        if output.status != 0 {
            return Err(command_failure(
                &output,
                "remote terminal capability probe failed",
            ));
        }
        parse_terminal_term(&output.stdout)
    }

    fn discover_herdr(
        &self,
        lease: &SshLease,
        cancellation: &CancellationToken,
    ) -> Result<HerdrInventory, RemoteTmuxError> {
        let result: Result<Option<(String, Vec<HerdrSessionRecord>)>, RemoteTmuxError> = (|| {
            let probe = self.run_framed_remote_shell(
                lease,
                herdr::RESOLVE_SCRIPT,
                HERDR_PROBE_PREFIX,
                cancellation,
            )?;
            if probe.status != 0 && probe.status != 127 {
                return Err(command_failure(&probe, "remote Herdr probe failed"));
            }
            let executable = match herdr::parse_executable(probe.status, &probe.stdout)
                .map_err(|detail| RemoteTmuxError::new(DiagnosticKind::MalformedOutput, detail))?
            {
                herdr::ExecutableProbe::Available(executable) => executable,
                herdr::ExecutableProbe::Unavailable => return Ok(None),
            };
            let command = multiplexer_command(
                &herdr::CONTROL_VARIABLES,
                RemoteCommandLocale::StableOutput,
                None,
                &executable,
                ["session", "list", "--json"],
            );
            let output = self.run_framed_remote_shell(
                lease,
                &posix_command(&command),
                HERDR_INVENTORY_PREFIX,
                cancellation,
            )?;
            if output.status != 0 {
                return Err(command_failure(&output, "remote Herdr inventory failed"));
            }
            let sessions = herdr::parse_inventory(&output.stdout)
                .map_err(|detail| RemoteTmuxError::new(DiagnosticKind::MalformedOutput, detail))?;
            Ok(Some((executable, sessions)))
        })(
        );
        Ok(match result {
            Ok(Some((executable, sessions))) => HerdrInventory::Available {
                executable,
                sessions,
            },
            Ok(None) => HerdrInventory::Unavailable,
            Err(error) => HerdrInventory::Failed(scope_backend_failure(error)?),
        })
    }

    fn discover_zellij(
        &self,
        lease: &SshLease,
        cancellation: &CancellationToken,
    ) -> Result<ZellijInventory, RemoteTmuxError> {
        let result: Result<Option<(String, Vec<ZellijSessionRecord>)>, RemoteTmuxError> = (|| {
            let probe = self.run_framed_remote_shell(
                lease,
                zellij::RESOLVE_SCRIPT,
                ZELLIJ_PROBE_PREFIX,
                cancellation,
            )?;
            if probe.status != 0 && probe.status != 127 {
                return Err(command_failure(&probe, "remote Zellij probe failed"));
            }
            let executable = match zellij::parse_executable(probe.status, &probe.stdout)
                .map_err(|detail| RemoteTmuxError::new(DiagnosticKind::MalformedOutput, detail))?
            {
                zellij::ExecutableProbe::Available(executable) => executable,
                zellij::ExecutableProbe::Unavailable => return Ok(None),
            };
            let command = zellij_inventory_command(&executable);
            let output = self.run_framed_remote_shell(
                lease,
                &posix_command(&command),
                ZELLIJ_INVENTORY_PREFIX,
                cancellation,
            )?;
            let sessions = zellij::parse_inventory(output.status, &output.stdout, &output.stderr)
                .map_err(|detail| {
                RemoteTmuxError::new(DiagnosticKind::MalformedOutput, detail)
            })?;
            Ok(Some((executable, sessions)))
        })(
        );
        Ok(match result {
            Ok(Some((executable, sessions))) => ZellijInventory::Available {
                executable,
                sessions,
            },
            Ok(None) => ZellijInventory::Unavailable,
            Err(error) => ZellijInventory::Failed(scope_backend_failure(error)?),
        })
    }

    fn resolve_tmux_binary(
        &self,
        lease: &SshLease,
        cancellation: &CancellationToken,
    ) -> Result<String, RemoteTmuxError> {
        let probe = tmux_probe_command(self.config.tmux_binary());
        let output =
            self.run_framed_remote_shell(lease, &probe, TMUX_PROBE_PREFIX, cancellation)?;
        if output.status != 0 {
            return Err(RemoteTmuxError::new(
                if output.status == 127 {
                    DiagnosticKind::ExecutableNotFound
                } else {
                    DiagnosticKind::UnsupportedEnvironment
                },
                nonempty_diagnostic(&output.stderr, "tmux is unavailable on the remote host"),
            ));
        }
        parse_tmux_probe(&output.stdout)
    }

    fn discover_sessions(
        &self,
        lease: &SshLease,
        tmux_binary: &str,
        cancellation: &CancellationToken,
    ) -> Result<Vec<DiscoveredSession>, RemoteTmuxError> {
        let (begin_marker, end_marker) = inventory_markers()?;
        let command = posix_command(&tmux_command(
            &self.config,
            tmux_binary,
            ["-f", "/dev/null", "list-sessions", "-F", INVENTORY_FORMAT],
        ));
        let framed = framed_remote_shell_command(&command, &begin_marker, &end_marker);
        let output = self.run_remote_shell(lease, &framed, cancellation)?;
        let output = extract_framed_command_output(output, &begin_marker, &end_marker)?;
        if output.status != 0 {
            let diagnostic = String::from_utf8_lossy(&output.stderr);
            if is_missing_tmux_server(&diagnostic) {
                return Ok(Vec::new());
            }
            return Err(RemoteTmuxError::new(
                if output.status == 127 {
                    DiagnosticKind::ExecutableNotFound
                } else {
                    DiagnosticKind::UnsupportedEnvironment
                },
                nonempty_diagnostic(&output.stderr, "remote tmux inventory failed"),
            ));
        }
        parse_inventory_payload(&output.stdout)
    }

    /// Build an ordinary PTY client plan over the existing KWT lease.
    ///
    /// The returned marker is unique to this attachment and is the only
    /// authoritative identity-mismatch signal in the client's output.
    ///
    /// # Errors
    ///
    /// Returns an error when a cryptographically random marker cannot be
    /// generated.
    pub fn attach_plan(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        session: &DiscoveredSession,
        term: &str,
    ) -> Result<(AttachPlan, String), RemoteTmuxError> {
        snapshot
            .lease()
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let identity_mismatch_marker = identity_mismatch_marker()?;
        let identity = session.identity();
        let condition = format!(
            "#{{&&:{},#{{&&:{},{}}}}}",
            tmux_identity_equals("pid", &identity.server_pid().to_string()),
            tmux_identity_equals("session_id", identity.session_id()),
            tmux_identity_equals("session_created", &identity.created_at().to_string()),
        );
        let attach = format!("attach-session -E -t ={}", identity.session_id());
        let command = tmux_command(
            &self.config,
            snapshot.tmux_binary().ok_or_else(|| {
                RemoteTmuxError::new(
                    DiagnosticKind::ExecutableNotFound,
                    "tmux is unavailable on the remote host",
                )
            })?,
            [
                "if-shell",
                "-F",
                "-t",
                &format!("={}:", identity.session_id()),
                &condition,
                &attach,
                &format!("display-message -p {identity_mismatch_marker}"),
            ],
        );
        let mut command = command;
        if let Some(value) = command.iter_mut().find(|value| value.starts_with("TERM=")) {
            *value = format!("TERM={term}");
        }
        let plan = AttachPlan::attach_only(
            self.ssh.program(),
            self.ssh.with_arguments(ssh_arguments(
                snapshot.lease(),
                self.config.target(),
                true,
                &account_login_shell_command(&posix_command(&command)),
            )),
            session.name(),
            session.identity().clone(),
        );
        Ok((plan, identity_mismatch_marker))
    }

    /// Build an ordinary remote Herdr client over the reviewed SSH lease.
    ///
    /// # Errors
    ///
    /// Returns an error when the reviewed lease is no longer live.
    pub fn herdr_attach_plan(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        executable: &str,
        session: &HerdrSessionRecord,
        term: &str,
    ) -> Result<HerdrAttachPlan, RemoteTmuxError> {
        snapshot
            .lease()
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let command = multiplexer_command(
            &herdr::CONTROL_VARIABLES,
            RemoteCommandLocale::Login,
            Some(term),
            executable,
            ["session", "attach", session.name()],
        );
        Ok(HerdrAttachPlan::attach_only(
            self.ssh.program(),
            self.ssh.with_arguments(ssh_arguments(
                snapshot.lease(),
                self.config.target(),
                true,
                &account_login_shell_command(&posix_command(&command)),
            )),
        ))
    }

    /// Build one remote Herdr launch through the reviewed SSH lease.
    ///
    /// # Errors
    ///
    /// Returns an error when the reviewed lease is no longer live.
    pub fn herdr_launch_once(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        executable: &str,
        target: HerdrLaunchTarget,
        is_default: bool,
        term: &str,
    ) -> Result<HerdrLaunchOnce, RemoteTmuxError> {
        snapshot
            .lease()
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let command = herdr_launch_command(executable, &target, is_default, term);
        Ok(HerdrLaunchOnce::launch_or_attach(
            self.ssh.program(),
            self.ssh.with_arguments(ssh_arguments(
                snapshot.lease(),
                self.config.target(),
                true,
                &account_login_shell_command(&posix_command(&command)),
            )),
            target,
        ))
    }

    /// Build an ordinary remote Zellij client over the reviewed SSH lease.
    ///
    /// # Errors
    ///
    /// Returns an error when the reviewed lease is no longer live.
    pub fn zellij_attach_plan(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        executable: &str,
        session: &ZellijSessionRecord,
        term: &str,
    ) -> Result<ZellijAttachPlan, RemoteTmuxError> {
        snapshot
            .lease()
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let command = multiplexer_command(
            &zellij::CONTROL_VARIABLES,
            RemoteCommandLocale::Login,
            Some(term),
            executable,
            ["attach", "--", session.name()],
        );
        Ok(ZellijAttachPlan::attach_only(
            self.ssh.program(),
            self.ssh.with_arguments(ssh_arguments(
                snapshot.lease(),
                self.config.target(),
                true,
                &account_login_shell_command(&posix_command(&command)),
            )),
        ))
    }

    /// Build one remote Zellij creation through the reviewed SSH lease.
    ///
    /// # Errors
    ///
    /// Returns an error when the reviewed lease is no longer live.
    pub fn zellij_launch_once(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        executable: &str,
        name: ZellijSessionName,
        term: &str,
    ) -> Result<ZellijLaunchOnce, RemoteTmuxError> {
        snapshot
            .lease()
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let command = zellij_launch_command(executable, &name, term);
        Ok(ZellijLaunchOnce::create(
            self.ssh.program(),
            self.ssh.with_arguments(ssh_arguments(
                snapshot.lease(),
                self.config.target(),
                true,
                &account_login_shell_command(&posix_command(&command)),
            )),
            name,
        ))
    }

    fn run_framed_remote_shell(
        &self,
        lease: &SshLease,
        command: &str,
        prefix: &str,
        cancellation: &CancellationToken,
    ) -> Result<crate::CommandOutput, RemoteTmuxError> {
        let (begin, end) = payload_markers(prefix)?;
        let framed = framed_remote_shell_command(command, &begin, &end);
        let output = self.run_remote_shell(lease, &framed, cancellation)?;
        extract_framed_command_output(output, &begin, &end)
    }

    fn run_remote_shell(
        &self,
        lease: &SshLease,
        command: &str,
        cancellation: &CancellationToken,
    ) -> Result<crate::CommandOutput, RemoteTmuxError> {
        lease
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let output = self
            .runner
            .run(
                self.ssh.program(),
                &self.ssh.with_arguments(ssh_arguments(
                    lease,
                    self.config.target(),
                    false,
                    &account_login_shell_command(command),
                )),
                cancellation,
                COMMAND_TIMEOUT,
            )
            .map_err(|error| RemoteTmuxError::command_launch(&error))?;
        lease
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        Ok(output)
    }
}

fn framed_remote_shell_command(command: &str, begin_marker: &str, end_marker: &str) -> String {
    let begin = shell_quoted_argument(begin_marker);
    let end = shell_quoted_argument(end_marker);
    format!(
        "printf '%s\\n' {begin}; printf '%s\\n' {begin} >&2; ( {command} ); ghosthub_status=$?; printf '%s\\n' {end}; printf '%s\\n' {end} >&2; exit $ghosthub_status"
    )
}

fn tmux_command<'a>(
    config: &RemoteTmuxConfig,
    tmux_binary: &str,
    args: impl IntoIterator<Item = &'a str>,
) -> Vec<String> {
    let mut command = vec![
        "/usr/bin/env".to_owned(),
        "-u".to_owned(),
        "TMUX".to_owned(),
        "-u".to_owned(),
        "TMUX_PANE".to_owned(),
        "-u".to_owned(),
        "TMUX_TMPDIR".to_owned(),
    ];
    command.extend(["LC_ALL=C".to_owned(), "TERM=xterm-256color".to_owned()]);
    if let Some(path) = config.socket_directory() {
        command.push(format!("TMUX_TMPDIR={path}"));
    }
    command.push(tmux_binary.to_owned());
    command.extend(args.into_iter().map(str::to_owned));
    command
}

#[derive(Clone, Copy)]
enum RemoteCommandLocale {
    Login,
    StableOutput,
}

fn multiplexer_command<'a>(
    scrubbed: &[&str],
    locale: RemoteCommandLocale,
    term: Option<&str>,
    executable: &str,
    args: impl IntoIterator<Item = &'a str>,
) -> Vec<String> {
    let mut command = vec!["/usr/bin/env".to_owned()];
    for variable in scrubbed {
        command.extend(["-u".to_owned(), (*variable).to_owned()]);
    }
    if matches!(locale, RemoteCommandLocale::StableOutput) {
        command.push("LC_ALL=C".to_owned());
    }
    if let Some(term) = term {
        command.push(format!("TERM={term}"));
    }
    command.push(executable.to_owned());
    command.extend(args.into_iter().map(str::to_owned));
    command
}

fn herdr_launch_command(
    executable: &str,
    target: &HerdrLaunchTarget,
    is_default: bool,
    term: &str,
) -> Vec<String> {
    let mut args = Vec::new();
    if !is_default {
        args.extend(["--session", target.as_str()]);
    }
    multiplexer_command(
        &herdr::CONTROL_VARIABLES,
        RemoteCommandLocale::Login,
        Some(term),
        executable,
        args,
    )
}

fn zellij_launch_command(executable: &str, name: &ZellijSessionName, term: &str) -> Vec<String> {
    let argument = format!("--session={}", name.as_str());
    multiplexer_command(
        &zellij::CONTROL_VARIABLES,
        RemoteCommandLocale::Login,
        Some(term),
        executable,
        [argument.as_str()],
    )
}

fn zellij_inventory_command(executable: &str) -> Vec<String> {
    multiplexer_command(
        &zellij::CONTROL_VARIABLES,
        RemoteCommandLocale::StableOutput,
        None,
        executable,
        ["list-sessions", "--no-formatting"],
    )
}

fn ssh_arguments(
    lease: &SshLease,
    target: &SshTarget,
    allocate_tty: bool,
    remote_command: &str,
) -> Vec<OsString> {
    complete_ssh_arguments(
        lease.result().arguments(),
        target.hostname(),
        allocate_tty,
        remote_command,
    )
}

fn complete_ssh_arguments(
    lease_arguments: &[String],
    destination: &str,
    allocate_tty: bool,
    remote_command: &str,
) -> Vec<OsString> {
    let mut args = lease_arguments
        .iter()
        .map(OsString::from)
        .collect::<Vec<_>>();
    // KWT validates and emits an option-only lease prefix. The destination is
    // deliberately supplied exactly once here, after terminal-mode options.
    args.push(OsString::from(if allocate_tty { "-tt" } else { "-T" }));
    args.extend([OsString::from("--"), OsString::from(destination)]);
    args.push(OsString::from(remote_command));
    args
}

fn posix_command(command: &[String]) -> String {
    command
        .iter()
        .map(|value| format!("'{}'", value.replace('\'', "'\\''")))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quoted_argument(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn account_shell_command_argument(value: &str) -> String {
    value
        .split('`')
        .map(|segment| {
            format!(
                "\"{}\"",
                segment
                    .replace('\\', "\\\\")
                    .replace('"', "\\\"")
                    .replace('$', "\\$")
            )
        })
        .collect::<Vec<_>>()
        .join("'`'")
}

fn account_shell_command(command: &str) -> String {
    format!(
        "exec /bin/sh -c {}",
        account_shell_command_argument(command)
    )
}

fn account_login_shell_command(command: &str) -> String {
    let command = format!(
        "exec \"${{SHELL:-/bin/sh}}\" -lc {}",
        shell_quoted_argument(&account_shell_command(command))
    );
    account_shell_command(&command)
}

fn tmux_probe_command(configured: &str) -> String {
    let selection = if configured.is_empty() {
        "ghosthub_tmux_path=$(command -v tmux) || exit 127".to_owned()
    } else {
        format!("ghosthub_tmux_path={}", shell_quoted_argument(configured))
    };
    format!(
        "{selection}; test -x \"$ghosthub_tmux_path\" || exit 127; \
         printf '{TMUX_PATH_MARKER}%s\\n' \"$ghosthub_tmux_path\"; \
         \"$ghosthub_tmux_path\" -V"
    )
}

fn identity_mismatch_marker() -> Result<String, RemoteTmuxError> {
    let mut nonce = [0_u8; 16];
    getrandom::fill(&mut nonce).map_err(|error| {
        RemoteTmuxError::new(
            DiagnosticKind::Transport,
            format!("generate remote attachment marker: {error}"),
        )
    })?;
    Ok(format!("{IDENTITY_MISMATCH_PREFIX}{}", hex::encode(nonce)))
}

fn inventory_markers() -> Result<(String, String), RemoteTmuxError> {
    payload_markers("GHOSTHUB_TMUX_INVENTORY_")
}

fn payload_markers(prefix: &str) -> Result<(String, String), RemoteTmuxError> {
    let mut nonce = [0_u8; 16];
    getrandom::fill(&mut nonce).map_err(|error| {
        RemoteTmuxError::new(
            DiagnosticKind::Transport,
            format!("generate remote inventory marker: {error}"),
        )
    })?;
    let nonce = hex::encode(nonce);
    Ok((
        format!("{prefix}BEGIN_{nonce}"),
        format!("{prefix}END_{nonce}"),
    ))
}

fn extract_framed_payload(
    bytes: &[u8],
    begin_marker: &str,
    end_marker: &str,
) -> Result<Vec<u8>, RemoteTmuxError> {
    let begin = format!("{begin_marker}\n");
    let end = format!("{end_marker}\n");
    let start = find_bytes(bytes, begin.as_bytes()).ok_or_else(|| {
        RemoteTmuxError::new(
            DiagnosticKind::MalformedOutput,
            "remote output framing is invalid",
        )
    })? + begin.len();
    let finish = find_bytes(&bytes[start..], end.as_bytes())
        .map(|offset| start + offset)
        .ok_or_else(|| {
            RemoteTmuxError::new(
                DiagnosticKind::MalformedOutput,
                "remote output framing is invalid",
            )
        })?;
    if find_bytes(&bytes[start..finish], begin.as_bytes()).is_some()
        || find_bytes(&bytes[finish + end.len()..], end.as_bytes()).is_some()
    {
        return Err(RemoteTmuxError::new(
            DiagnosticKind::MalformedOutput,
            "remote output framing is invalid",
        ));
    }
    Ok(bytes[start..finish].to_vec())
}

fn find_bytes(bytes: &[u8], needle: &[u8]) -> Option<usize> {
    bytes
        .windows(needle.len())
        .position(|window| window == needle)
}

fn extract_framed_command_output(
    mut output: crate::CommandOutput,
    begin_marker: &str,
    end_marker: &str,
) -> Result<crate::CommandOutput, RemoteTmuxError> {
    let stdout_framed = has_complete_frame(&output.stdout, begin_marker, end_marker);
    let stderr_framed = has_complete_frame(&output.stderr, begin_marker, end_marker);
    if !stdout_framed || !stderr_framed {
        let diagnostic = stderr_framed
            .then(|| extract_framed_payload(&output.stderr, begin_marker, end_marker).ok())
            .flatten()
            .unwrap_or_else(|| output.stderr.clone());
        return Err(RemoteTmuxError::new(
            DiagnosticKind::Transport,
            nonempty_diagnostic(
                &diagnostic,
                "remote command wrapper failed before starting the requested command",
            ),
        ));
    }
    let stdout = extract_framed_payload(&output.stdout, begin_marker, end_marker)?;
    let stderr = extract_framed_payload(&output.stderr, begin_marker, end_marker)?;
    output.stdout = stdout;
    output.stderr = stderr;
    Ok(output)
}

fn has_complete_frame(bytes: &[u8], begin_marker: &str, end_marker: &str) -> bool {
    let begin = format!("{begin_marker}\n");
    let end = format!("{end_marker}\n");
    bytes
        .windows(begin.len())
        .position(|window| window == begin.as_bytes())
        .is_some_and(|start| {
            bytes[start + begin.len()..]
                .windows(end.len())
                .any(|window| window == end.as_bytes())
        })
}

fn command_failure(output: &crate::CommandOutput, fallback: &str) -> RemoteTmuxError {
    RemoteTmuxError::new(
        if output.status == 127 {
            DiagnosticKind::ExecutableNotFound
        } else {
            DiagnosticKind::UnsupportedEnvironment
        },
        nonempty_diagnostic(&output.stderr, fallback),
    )
}

type OptionalTmuxInventory = (Option<String>, Vec<DiscoveredSession>, Option<HostError>);

fn scope_tmux_inventory(
    result: Result<(String, Vec<DiscoveredSession>), RemoteTmuxError>,
) -> Result<OptionalTmuxInventory, RemoteTmuxError> {
    match result {
        Ok((binary, sessions)) => Ok((Some(binary), sessions, None)),
        Err(error) if error.kind() == DiagnosticKind::Transport => Err(error),
        Err(error) => Ok((
            None,
            Vec::new(),
            Some(HostError::new(error.kind(), error.to_string())),
        )),
    }
}

fn scope_backend_failure(error: RemoteTmuxError) -> Result<HostError, RemoteTmuxError> {
    if error.kind() == DiagnosticKind::Transport {
        Err(error)
    } else {
        Ok(HostError::new(error.kind(), error.to_string()))
    }
}

fn parse_tmux_probe(bytes: &[u8]) -> Result<String, RemoteTmuxError> {
    let output = std::str::from_utf8(bytes).map_err(|_| {
        RemoteTmuxError::new(
            DiagnosticKind::MalformedOutput,
            "remote tmux probe is not UTF-8",
        )
    })?;
    let paths = output
        .lines()
        .filter_map(|line| line.strip_prefix(TMUX_PATH_MARKER))
        .collect::<Vec<_>>();
    if paths.len() != 1 || !paths[0].starts_with('/') || paths[0].chars().any(char::is_control) {
        return Err(RemoteTmuxError::new(
            DiagnosticKind::MalformedOutput,
            "remote tmux probe returned an invalid executable path",
        ));
    }
    let version = output
        .lines()
        .find_map(|line| line.strip_prefix("tmux "))
        .and_then(|value| value.trim().split_once('.'))
        .and_then(|(major, remainder)| {
            let minor = remainder
                .split(|character: char| !character.is_ascii_digit())
                .next()?;
            Some((major.parse::<u32>().ok()?, minor.parse::<u32>().ok()?))
        })
        .ok_or_else(|| {
            RemoteTmuxError::new(
                DiagnosticKind::MalformedOutput,
                "remote tmux probe returned an invalid version",
            )
        })?;
    if version < (3, 2) {
        return Err(RemoteTmuxError::new(
            DiagnosticKind::UnsupportedEnvironment,
            format!("remote tmux {}.{} is older than 3.2", version.0, version.1),
        ));
    }
    Ok(paths[0].to_owned())
}

fn parse_terminal_term(bytes: &[u8]) -> Result<AttachTerm, RemoteTmuxError> {
    match std::str::from_utf8(bytes).map(str::trim) {
        Ok("xterm-256color") => Ok(AttachTerm::Xterm256Color),
        Ok("xterm") => Ok(AttachTerm::Xterm),
        _ => Err(RemoteTmuxError::new(
            DiagnosticKind::MalformedOutput,
            "remote terminal capability probe returned an invalid terminal type",
        )),
    }
}

fn is_missing_tmux_server(diagnostic: &str) -> bool {
    diagnostic.contains("no server running on ")
        || diagnostic.contains("failed to connect to server: No such file or directory")
        || (diagnostic.contains("error connecting to ")
            && diagnostic.contains(" (No such file or directory)"))
}

#[cfg(test)]
fn parse_inventory(
    bytes: &[u8],
    begin_marker: &str,
    end_marker: &str,
) -> Result<Vec<DiscoveredSession>, RemoteTmuxError> {
    let payload = extract_framed_payload(bytes, begin_marker, end_marker)
        .map_err(|_| malformed_inventory())?;
    parse_inventory_payload(&payload)
}

fn parse_inventory_payload(bytes: &[u8]) -> Result<Vec<DiscoveredSession>, RemoteTmuxError> {
    let mut remaining = std::str::from_utf8(bytes).map_err(|_| {
        RemoteTmuxError::new(
            DiagnosticKind::MalformedOutput,
            "remote tmux inventory is not UTF-8",
        )
    })?;
    let mut sessions = Vec::new();
    while !remaining.is_empty() {
        let mut fields = Vec::with_capacity(4);
        for _ in 0..4 {
            fields.push(take_field(&mut remaining)?);
        }
        let name_length = take_field(&mut remaining)?.parse::<usize>().map_err(|_| {
            RemoteTmuxError::new(
                DiagnosticKind::MalformedOutput,
                "remote tmux name length is invalid",
            )
        })?;
        let name = remaining
            .get(..name_length)
            .ok_or_else(malformed_inventory)?;
        remaining = remaining
            .get(name_length..)
            .and_then(|suffix| suffix.strip_prefix('\n'))
            .ok_or_else(malformed_inventory)?;
        let server_pid = fields[0]
            .parse::<u32>()
            .map_err(|_| malformed_inventory())?;
        let created = fields[2]
            .parse::<u64>()
            .map_err(|_| malformed_inventory())?;
        let attached = fields[3]
            .parse::<u32>()
            .map_err(|_| malformed_inventory())?;
        if server_pid == 0 || !valid_session_id(fields[1]) {
            return Err(malformed_inventory());
        }
        sessions.push(DiscoveredSession::new(
            name,
            SessionIdentity::new(server_pid, fields[1], created),
            attached,
        ));
    }
    Ok(sessions)
}

fn take_field<'a>(remaining: &mut &'a str) -> Result<&'a str, RemoteTmuxError> {
    let index = remaining.find('|').ok_or_else(malformed_inventory)?;
    let value = &remaining[..index];
    *remaining = &remaining[index + 1..];
    Ok(value)
}

fn valid_session_id(value: &str) -> bool {
    value.strip_prefix('$').is_some_and(|digits| {
        !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit())
    })
}

fn malformed_inventory() -> RemoteTmuxError {
    RemoteTmuxError::new(
        DiagnosticKind::MalformedOutput,
        "remote tmux inventory framing is invalid",
    )
}

fn tmux_identity_equals(field: &str, value: &str) -> String {
    format!("#{{==:#{{{field}}},{value}}}")
}

fn require_safe(subject: &str, value: &str) -> Result<(), RemoteTmuxError> {
    if value.is_empty() || value.chars().any(char::is_control) {
        Err(RemoteTmuxError::new(
            DiagnosticKind::MalformedOutput,
            format!("{subject} is empty or contains control characters"),
        ))
    } else {
        Ok(())
    }
}

fn require_absolute(subject: &str, value: &str) -> Result<(), RemoteTmuxError> {
    require_safe(subject, value)?;
    if value.starts_with('/') {
        Ok(())
    } else {
        Err(RemoteTmuxError::new(
            DiagnosticKind::MalformedOutput,
            format!("{subject} must be an absolute POSIX path"),
        ))
    }
}

fn nonempty_diagnostic(bytes: &[u8], fallback: &str) -> String {
    let message = String::from_utf8_lossy(bytes).trim().to_owned();
    if message.is_empty() {
        fallback.to_owned()
    } else {
        message
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteTmuxError {
    kind: DiagnosticKind,
    detail: String,
}

impl RemoteTmuxError {
    fn new(kind: DiagnosticKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }

    fn local_executable(error: &std::io::Error) -> Self {
        Self::new(
            if error.kind() == std::io::ErrorKind::NotFound {
                DiagnosticKind::ExecutableNotFound
            } else {
                DiagnosticKind::Transport
            },
            error.to_string(),
        )
    }

    fn command_launch(error: &std::io::Error) -> Self {
        Self::new(DiagnosticKind::Transport, error.to_string())
    }

    fn ssh(error: &crate::SshError) -> Self {
        Self::new(error.kind(), error.to_string())
    }

    /// Construct a host-scoped transport failure before SSH admission begins.
    #[must_use]
    pub fn transport(detail: impl Into<String>) -> Self {
        Self::new(DiagnosticKind::Transport, detail)
    }

    /// Preserve a WSL substrate failure while preparing a remote SSH host.
    #[must_use]
    pub fn from_host(error: &crate::HostError) -> Self {
        Self::new(error.kind(), error.to_string())
    }

    #[must_use]
    pub const fn kind(&self) -> DiagnosticKind {
        self.kind
    }
}

impl fmt::Display for RemoteTmuxError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.detail)
    }
}

impl std::error::Error for RemoteTmuxError {}

#[cfg(test)]
mod tests {
    use std::thread;
    use std::time::Instant;

    use super::*;

    fn exited_lease() -> SshLease {
        let target = SshTarget::new("host-alias", None, None).expect("target");
        let route = crate::SshRouteSnapshot::parse(
            br#"{
              "logical_target":{"hostname":"host-alias","user":null,"port":null},
              "targets":[{
                "logical_target":{"hostname":"host-alias","user":null,"port":null},
                "effective_target":{"hostname":"host-alias","user":null,"port":null},
                "display_target":"host-alias","host_key_alias":null,
                "strict_host_key_checking":"ask",
                "projection":{"arguments":["-F","/dev/null"],"private_config":[]}
              }],
              "route_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "projection_policy":"kwt.openssh.projection.v1",
              "observed_at":"2026-08-15T12:00:00Z"
            }"#,
            &target,
        )
        .expect("route");
        let complete = r#"{"operation_id":"op-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":7,"mode":"multiplexed","arguments":["-S","control-path","-o","ProxyCommand=/usr/bin/false"]}}"#;
        #[cfg(windows)]
        let command = CommandPrefix::new(
            "powershell.exe",
            [
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                &format!("[Console]::Out.WriteLine('{complete}'); exit 23; #"),
            ]
            .map(OsString::from)
            .to_vec(),
        );
        #[cfg(not(windows))]
        let command = CommandPrefix::new(
            "/bin/sh",
            vec![
                "-c".into(),
                format!("printf '%s\\n' '{complete}'; exit 23").into(),
            ],
        );
        let lease = KwtSshLeaseClient::with_command(command)
            .acquire(
                &route,
                &CancellationToken::new(),
                |_| Err(crate::SshError::prompt_cancelled()),
                |_| {},
            )
            .expect("acquire lease before scripted exit");
        let deadline = Instant::now() + Duration::from_secs(3);
        while lease.ensure_live().is_ok() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        lease
    }

    #[test]
    fn remote_command_quotes_every_argument() {
        assert_eq!(
            posix_command(&["printf".to_owned(), "a b'c".to_owned()]),
            "'printf' 'a b'\\''c'"
        );
    }

    #[test]
    fn terminal_probe_accepts_only_verified_supported_terms() {
        assert_eq!(
            parse_terminal_term(b"xterm-256color\n").expect("preferred term"),
            AttachTerm::Xterm256Color
        );
        assert_eq!(
            parse_terminal_term(b"xterm\n").expect("fallback term"),
            AttachTerm::Xterm
        );
        assert!(parse_terminal_term(b"screen-256color\n").is_err());
        assert!(parse_terminal_term(b"xterm\nxterm-256color\n").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn terminal_probe_selects_the_verified_fallback() {
        use std::os::unix::fs::PermissionsExt;

        let directory = std::env::temp_dir().join(format!(
            "ghosthub-terminfo-probe-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time")
                .as_nanos()
        ));
        std::fs::create_dir(&directory).expect("create probe fixture");
        let infocmp = directory.join("infocmp");
        std::fs::write(&infocmp, "#!/bin/sh\n[ \"$1\" = xterm ]\n").expect("write probe fixture");
        let mut permissions = std::fs::metadata(&infocmp)
            .expect("probe fixture metadata")
            .permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&infocmp, permissions).expect("make probe fixture executable");
        let output = std::process::Command::new("/bin/sh")
            .args(["-c", TERMINFO_PROBE_SCRIPT])
            .env_clear()
            .env("PATH", &directory)
            .output()
            .expect("run terminal capability probe");
        std::fs::remove_dir_all(&directory).expect("remove probe fixture");
        assert!(output.status.success());
        assert_eq!(
            parse_terminal_term(&output.stdout).expect("verified fallback"),
            AttachTerm::Xterm
        );
    }

    #[test]
    fn tmux_environment_options_precede_assignments() {
        let config = RemoteTmuxConfig::new(
            "ssh:test",
            "Test",
            SshTarget::new("example.test", None, None).expect("target"),
            "/usr/bin/tmux",
            Some("/tmp/ghosthub-tmux".to_owned()),
        )
        .expect("config");

        assert_eq!(
            tmux_command(&config, "/usr/bin/tmux", ["list-sessions"]),
            [
                "/usr/bin/env",
                "-u",
                "TMUX",
                "-u",
                "TMUX_PANE",
                "-u",
                "TMUX_TMPDIR",
                "LC_ALL=C",
                "TERM=xterm-256color",
                "TMUX_TMPDIR=/tmp/ghosthub-tmux",
                "/usr/bin/tmux",
                "list-sessions",
            ]
            .map(str::to_owned)
        );
    }

    #[test]
    fn remote_interactive_commands_scrub_backend_state_and_preserve_login_locale() {
        assert_eq!(
            multiplexer_command(
                &["HERDR_SESSION", "HERDR_SOCKET_PATH"],
                RemoteCommandLocale::Login,
                Some("xterm-256color"),
                "/usr/bin/herdr",
                ["session", "attach", "review"],
            ),
            [
                "/usr/bin/env",
                "-u",
                "HERDR_SESSION",
                "-u",
                "HERDR_SOCKET_PATH",
                "TERM=xterm-256color",
                "/usr/bin/herdr",
                "session",
                "attach",
                "review",
            ]
            .map(str::to_owned)
        );
    }

    #[test]
    fn remote_inventory_commands_use_a_stable_locale() {
        let command = zellij_inventory_command("/usr/bin/zellij");

        assert!(command.iter().any(|argument| argument == "LC_ALL=C"));
        assert!(!command.iter().any(|argument| argument.starts_with("TERM=")));
    }

    #[test]
    fn remote_herdr_launch_uses_exact_nondefault_target_and_scrubbed_environment() {
        let name = session::HerdrSessionName::parse("review").expect("name");
        let command = herdr_launch_command(
            "/usr/local/bin/herdr",
            &HerdrLaunchTarget::created(name),
            false,
            "xterm",
        );

        assert_eq!(command[0], "/usr/bin/env");
        assert!(
            command
                .windows(2)
                .any(|pair| pair == ["-u", "HERDR_SESSION"])
        );
        assert!(!command.iter().any(|value| value.starts_with("LC_ALL=")));
        assert!(command.iter().any(|value| value == "TERM=xterm"));
        assert_eq!(
            &command[command.len() - 3..],
            ["/usr/local/bin/herdr", "--session", "review"]
        );
    }

    #[test]
    fn remote_herdr_default_launch_does_not_invent_a_session_selector() {
        let record = HerdrSessionRecord::new(
            "default",
            true,
            session::HerdrSessionState::Stopped,
            "/home/test/.local/share/herdr/default",
            "/tmp/herdr.sock",
        );
        let command = herdr_launch_command(
            "/usr/local/bin/herdr",
            &HerdrLaunchTarget::discovered(&record),
            true,
            "xterm",
        );

        assert_eq!(
            command.last().map(String::as_str),
            Some("/usr/local/bin/herdr")
        );
        assert!(!command.iter().any(|value| value == "--session"));
    }

    #[test]
    fn remote_zellij_creation_uses_one_exact_session_argument() {
        let name = ZellijSessionName::parse("review").expect("name");
        let command = zellij_launch_command("/usr/bin/zellij", &name, "xterm");

        assert_eq!(command[0], "/usr/bin/env");
        assert!(command.windows(2).any(|pair| pair == ["-u", "ZELLIJ"]));
        assert!(!command.iter().any(|value| value.starts_with("LC_ALL=")));
        assert!(command.iter().any(|value| value == "TERM=xterm"));
        assert_eq!(
            &command[command.len() - 2..],
            ["/usr/bin/zellij", "--session=review"]
        );
    }

    #[test]
    fn remote_zellij_inventory_keeps_status_metadata_for_active_filtering() {
        let command = zellij_inventory_command("/usr/bin/zellij");

        assert_eq!(
            &command[command.len() - 3..],
            ["/usr/bin/zellij", "list-sessions", "--no-formatting"]
        );
        assert!(!command.iter().any(|argument| argument == "--short"));
        let sessions = zellij::parse_inventory(
            0,
            b"work [Created 2m ago]\nold [Created 3h ago] (EXITED - attach to resurrect)\n",
            b"",
        )
        .expect("metadata-rich remote inventory");
        assert_eq!(
            sessions
                .iter()
                .map(ZellijSessionRecord::name)
                .collect::<Vec<_>>(),
            ["work"]
        );
    }

    #[test]
    fn optional_inventory_framing_ignores_login_shell_noise() {
        assert_eq!(
            extract_framed_payload(
                b"startup banner\nBEGIN\n{\"sessions\":[]}\nEND\nlogout noise\n",
                "BEGIN",
                "END",
            )
            .expect("framed payload"),
            b"{\"sessions\":[]}\n"
        );
        assert!(extract_framed_payload(b"BEGIN\npayload\n", "BEGIN", "END").is_err());
    }

    #[test]
    fn framing_ignores_non_utf8_login_shell_noise() {
        let output = extract_framed_command_output(
            crate::CommandOutput {
                status: 0,
                stdout: b"\xffstartup\nBEGIN\nbackend output\nEND\n\xfelogout\n".to_vec(),
                stderr: b"\x80warning\nBEGIN\nEND\n\x81logout\n".to_vec(),
            },
            "BEGIN",
            "END",
        )
        .expect("only framed payload bytes belong to the backend command");

        assert_eq!(output.stdout, b"backend output\n");
        assert!(output.stderr.is_empty());
    }

    #[test]
    fn framed_transport_failure_is_not_misclassified_as_malformed_output() {
        let error = extract_framed_command_output(
            crate::CommandOutput {
                status: 255,
                stdout: Vec::new(),
                stderr: b"connection closed".to_vec(),
            },
            "BEGIN",
            "END",
        )
        .expect_err("SSH status bypasses payload framing");

        assert_eq!(error.kind(), DiagnosticKind::Transport);
        assert_eq!(error.to_string(), "connection closed");
    }

    #[test]
    fn command_wrapper_failure_is_host_transport_even_when_status_looks_optional() {
        let error = extract_framed_command_output(
            crate::CommandOutput {
                status: 127,
                stdout: Vec::new(),
                stderr: b"wsl runtime guard did not start SSH".to_vec(),
            },
            "BEGIN",
            "END",
        )
        .expect_err("missing framing proves the backend command never started");

        assert_eq!(error.kind(), DiagnosticKind::Transport);
        assert_eq!(error.to_string(), "wsl runtime guard did not start SSH");
    }

    #[test]
    fn successful_unframed_shell_exit_is_a_transport_failure() {
        for (stdout, stderr) in [
            (Vec::new(), b"login shell exited early".to_vec()),
            (b"BEGIN\nbackend output\nEND\n".to_vec(), Vec::new()),
        ] {
            let error = extract_framed_command_output(
                crate::CommandOutput {
                    status: 0,
                    stdout,
                    stderr,
                },
                "BEGIN",
                "END",
            )
            .expect_err("both streams must prove the wrapper ran");

            assert_eq!(error.kind(), DiagnosticKind::Transport);
        }
    }

    #[test]
    fn framed_missing_backend_remains_backend_scoped() {
        let output = extract_framed_command_output(
            crate::CommandOutput {
                status: 127,
                stdout: b"noise\nBEGIN\nGHOSTHUB_ZELLIJ_UNAVAILABLE\nEND\n".to_vec(),
                stderr: b"login warning\nBEGIN\nbackend missing\nEND\nlogout noise\n".to_vec(),
            },
            "BEGIN",
            "END",
        )
        .expect("the remote command started and reported backend absence");

        assert_eq!(output.status, 127);
        assert_eq!(output.stdout, b"GHOSTHUB_ZELLIJ_UNAVAILABLE\n");
        assert_eq!(output.stderr, b"backend missing\n");
        assert_eq!(
            command_failure(&output, "missing backend").kind(),
            DiagnosticKind::ExecutableNotFound
        );
    }

    #[test]
    fn local_ssh_launch_failure_is_transport_not_backend_absence() {
        let error = RemoteTmuxError::command_launch(&std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "local SSH executable could not be launched",
        ));

        assert_eq!(error.kind(), DiagnosticKind::Transport);
        assert!(scope_backend_failure(error).is_err());
    }

    #[test]
    fn framed_zellij_stderr_ignores_login_shell_noise() {
        let output = extract_framed_command_output(
            crate::CommandOutput {
                status: 1,
                stdout: b"profile output\nBEGIN\nEND\n".to_vec(),
                stderr:
                    b"startup warning\nBEGIN\nNo active zellij sessions found.\nEND\nlogout noise\n"
                        .to_vec(),
            },
            "BEGIN",
            "END",
        )
        .expect("both command streams are framed");

        assert_eq!(
            zellij::parse_inventory(output.status, &output.stdout, &output.stderr)
                .expect("empty Zellij inventory"),
            Vec::<ZellijSessionRecord>::new()
        );
    }

    #[cfg(unix)]
    #[test]
    fn framed_shell_emits_both_markers_after_probe_exits_127() {
        let command = framed_remote_shell_command(
            "printf 'backend missing\\n' >&2; exit 127",
            "BEGIN",
            "END",
        );
        let output = std::process::Command::new("/bin/sh")
            .args(["-c", &command])
            .output()
            .expect("run framed shell boundary");
        let output = extract_framed_command_output(
            crate::CommandOutput {
                status: output.status.code().expect("shell exit status"),
                stdout: output.stdout,
                stderr: output.stderr,
            },
            "BEGIN",
            "END",
        )
        .expect("subshell exit preserves the parent framing shell");

        assert_eq!(output.status, 127);
        assert!(output.stdout.is_empty());
        assert_eq!(output.stderr, b"backend missing\n");
    }

    #[test]
    fn wsl_runtime_guard_status_is_transport() {
        let error = extract_framed_command_output(
            crate::CommandOutput {
                status: 125,
                stdout: Vec::new(),
                stderr: b"WSL runtime changed".to_vec(),
            },
            "BEGIN",
            "END",
        )
        .expect_err("an unframed wrapper failure is transport-level");

        assert_eq!(error.kind(), DiagnosticKind::Transport);
    }

    #[test]
    fn framed_backend_statuses_do_not_invalidate_the_transport() {
        for status in [125, 255] {
            let output = extract_framed_command_output(
                crate::CommandOutput {
                    status,
                    stdout: b"BEGIN\nbackend output\nEND\n".to_vec(),
                    stderr: b"BEGIN\nbackend failure\nEND\n".to_vec(),
                },
                "BEGIN",
                "END",
            )
            .expect("valid framing proves the backend command ran");

            assert_eq!(
                command_failure(&output, "backend failed").kind(),
                DiagnosticKind::UnsupportedEnvironment
            );
        }
    }

    #[test]
    fn optional_backend_failures_scope_only_non_transport_diagnostics() {
        let diagnostic = scope_backend_failure(RemoteTmuxError::new(
            DiagnosticKind::ExecutableNotFound,
            "Zellij is missing",
        ))
        .expect("backend absence remains scoped");
        assert_eq!(diagnostic.kind(), DiagnosticKind::ExecutableNotFound);

        let error = scope_backend_failure(RemoteTmuxError::new(
            DiagnosticKind::Transport,
            "SSH connection failed",
        ))
        .expect_err("transport failure invalidates the host");
        assert_eq!(error.kind(), DiagnosticKind::Transport);
    }

    #[test]
    fn missing_tmux_is_backend_scoped_but_transport_failure_is_not() {
        let (_, sessions, diagnostic) = scope_tmux_inventory(Err(RemoteTmuxError::new(
            DiagnosticKind::ExecutableNotFound,
            "tmux is unavailable on the remote host",
        )))
        .expect("missing optional tmux remains host-usable");
        assert!(sessions.is_empty());
        assert_eq!(
            diagnostic.expect("tmux diagnostic").kind(),
            DiagnosticKind::ExecutableNotFound
        );

        assert_eq!(
            scope_tmux_inventory(Err(RemoteTmuxError::new(
                DiagnosticKind::Transport,
                "SSH connection failed",
            )))
            .expect_err("transport failure invalidates the host")
            .kind(),
            DiagnosticKind::Transport
        );
    }

    #[test]
    fn leased_ssh_arguments_keep_destination_separate_from_remote_command() {
        let arguments = complete_ssh_arguments(
            &["-S".to_owned(), "/tmp/control".to_owned()],
            "host-alias",
            false,
            "'printf' 'a b'",
        );

        assert_eq!(
            arguments,
            [
                "-S",
                "/tmp/control",
                "-T",
                "--",
                "host-alias",
                "'printf' 'a b'",
            ]
            .map(OsString::from)
        );
    }

    #[test]
    fn kwt_lease_fixture_produces_one_destination_before_the_remote_command() {
        let lease_arguments = serde_json::from_str::<serde_json::Value>(
            r#"{"arguments":["-F","/dev/null","-o","BatchMode=yes","-S","/tmp/control","-o","ProxyCommand=/usr/bin/false"]}"#,
        )
        .expect("KWT lease fixture");
        let lease_arguments = lease_arguments["arguments"]
            .as_array()
            .expect("arguments")
            .iter()
            .map(|value| value.as_str().expect("argument").to_owned())
            .collect::<Vec<_>>();

        let arguments = complete_ssh_arguments(
            &lease_arguments,
            "host-alias",
            false,
            "'tmux' 'list-sessions'",
        );

        assert_eq!(
            arguments,
            [
                "-F",
                "/dev/null",
                "-o",
                "BatchMode=yes",
                "-S",
                "/tmp/control",
                "-o",
                "ProxyCommand=/usr/bin/false",
                "-T",
                "--",
                "host-alias",
                "'tmux' 'list-sessions'",
            ]
            .map(OsString::from)
        );
    }

    #[test]
    fn interactive_ssh_arguments_force_remote_tty_allocation() {
        let arguments = complete_ssh_arguments(
            &["-S".to_owned(), "/tmp/control".to_owned()],
            "host-alias",
            true,
            "'tmux' 'attach-session'",
        );

        assert_eq!(
            arguments,
            [
                "-S",
                "/tmp/control",
                "-tt",
                "--",
                "host-alias",
                "'tmux' 'attach-session'",
            ]
            .map(OsString::from)
        );
    }

    #[test]
    fn exited_lease_cannot_authorize_a_new_attachment() {
        let config = RemoteTmuxConfig::new(
            "ssh:test",
            "Test",
            SshTarget::new("host-alias", None, None).expect("target"),
            "/usr/bin/tmux",
            None,
        )
        .expect("config");
        let host = RemoteTmuxHost::with_commands(
            config,
            CommandPrefix::native("controller"),
            CommandPrefix::native("ssh"),
            crate::StdCommandRunner,
        );
        let session = DiscoveredSession::new("work", SessionIdentity::new(42, "$1", 100), 0);
        let snapshot = RemoteTmuxSnapshot {
            endpoint: "host-alias".to_owned(),
            route_identity: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                .to_owned(),
            lease_generation: 7,
            tmux_binary: Some("/usr/bin/tmux".to_owned()),
            tmux_diagnostic: None,
            sessions: vec![session.clone()],
            herdr: HerdrInventory::Unavailable,
            zellij: ZellijInventory::Unavailable,
            lease: exited_lease(),
        };

        let error = host
            .attach_plan(&snapshot, &session, "xterm-256color")
            .expect_err("exited controller cannot issue stale SSH arguments");

        assert_eq!(error.kind(), DiagnosticKind::Transport);
    }

    #[test]
    fn account_login_shell_preserves_the_fixed_remote_command() {
        let command = account_login_shell_command("'printf' 'a b'");

        assert!(command.starts_with("exec /bin/sh -c "));
        assert!(command.contains("SHELL:-/bin/sh"));
        assert!(command.contains("-lc"));
        assert!(command.contains("printf"));
    }

    #[test]
    fn system_tmux_probe_honors_the_explicit_path() {
        let probe = tmux_probe_command("/usr/bin/tmux");

        assert!(!probe.contains("command -v tmux"));
        assert!(probe.contains("ghosthub_tmux_path='/usr/bin/tmux'"));
        assert!(probe.contains(TMUX_PATH_MARKER));
    }

    #[test]
    fn automatic_tmux_probe_uses_the_remote_login_path() {
        let probe = tmux_probe_command("");

        assert!(probe.contains("command -v tmux"));
        assert!(probe.contains("test -x \"$ghosthub_tmux_path\""));
        assert!(probe.contains(TMUX_PATH_MARKER));
    }

    #[test]
    fn configured_tmux_probe_keeps_the_explicit_path() {
        let probe = tmux_probe_command("/custom/bin/tmux");

        assert!(!probe.contains("command -v tmux"));
        assert!(probe.contains("ghosthub_tmux_path='/custom/bin/tmux'"));
    }

    #[test]
    fn tmux_probe_accepts_homebrew_tmux_after_login_shell_noise() {
        let path = parse_tmux_probe(
            b"login banner\nGHOSTHUB_TMUX_PATH=/opt/homebrew/bin/tmux\ntmux 3.5a\n",
        )
        .expect("probe");

        assert_eq!(path, "/opt/homebrew/bin/tmux");
    }

    #[test]
    fn tmux_probe_rejects_an_old_version() {
        let error = parse_tmux_probe(b"GHOSTHUB_TMUX_PATH=/usr/bin/tmux\ntmux 3.1c\n")
            .expect_err("old tmux");

        assert_eq!(error.kind(), DiagnosticKind::UnsupportedEnvironment);
    }

    #[test]
    fn missing_executable_is_not_an_empty_tmux_server() {
        assert!(!is_missing_tmux_server(
            "env: /usr/bin/tmux: No such file or directory"
        ));
        assert!(is_missing_tmux_server(
            "no server running on /private/tmp/tmux-501/default"
        ));
        assert!(is_missing_tmux_server(
            "error connecting to /private/tmp/tmux-501/default (No such file or directory)"
        ));
    }

    #[test]
    fn inventory_preserves_control_characters_in_names() {
        let sessions = parse_inventory(
            b"login banner\nBEGIN\n42|$1|100|0|6|a|\tb\nc\nEND\nshell footer\n",
            "BEGIN",
            "END",
        )
        .expect("inventory");
        assert_eq!(sessions[0].name(), "a|\tb\nc");
        assert_eq!(sessions[0].identity(), &SessionIdentity::new(42, "$1", 100));
    }

    #[test]
    fn inventory_ignores_login_shell_output_outside_validated_markers() {
        let sessions = parse_inventory(
            b"welcome\nBEGIN\n42|$1|100|0|4|work\nEND\nlogout noise\n",
            "BEGIN",
            "END",
        )
        .expect("inventory");

        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].name(), "work");
    }

    #[test]
    fn inventory_requires_both_payload_markers() {
        let error = parse_inventory(b"42|$1|100|0|4|work\n", "BEGIN", "END")
            .expect_err("unframed inventory");

        assert_eq!(error.kind(), DiagnosticKind::MalformedOutput);
    }

    #[test]
    fn config_requires_absolute_remote_paths() {
        let error = RemoteTmuxConfig::new(
            "ssh:test",
            "Test",
            SshTarget::new("example.test", None, None).expect("target"),
            "tmux",
            None,
        )
        .expect_err("relative path");
        assert_eq!(error.kind(), DiagnosticKind::MalformedOutput);
    }
}
