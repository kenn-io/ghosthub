use std::ffi::{OsStr, OsString};
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use model::DiagnosticKind;
use session::{
    AdmissionPlan, AttachPlan, DiscoveredSession, ExecutablePlatform, IDENTITY_MISMATCH_MARKER,
    ProbeObservation, SessionIdentity, VerifiedTmuxBinary, resolve_tmux_binary,
};

use crate::{CancellationToken, CommandOutput, CommandRunner};

const DEFAULT_TMUX: &str = "/usr/bin/tmux";
const DISCOVERY_ATTEMPTS: usize = 2;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(15);
const ATTACHMENT_PROBE_TIMEOUT: Duration = Duration::from_secs(5);
const CLEANUP_COMMAND_TIMEOUT: Duration = Duration::from_millis(500);
const UNCERTAIN_CLEANUP_DELAY: Duration = Duration::from_millis(50);
const UNCERTAIN_CLEANUP_SETTLE: Duration = Duration::from_secs(2);
// tmux 3.2 already implements `n:` with strlen, and admission exercises this
// same framing before inventory. Delimiters in names therefore stay unambiguous
// without adding another process crossing.
const INVENTORY_FORMAT: &str = "#{pid}\t#{session_id}\t#{session_created}\t#{session_attached}\t#{n:session_name}\t#{session_name}";
const ADMISSION_IDENTITY_FORMAT: &str = "#{pid}\t#{session_id}\t#{n:session_name}\t#{session_name}";
static ADMISSION_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub trait AdmissionAttacher {
    type Client;

    /// Start one ordinary PTY-backed client from the fully resolved plan.
    ///
    /// # Errors
    ///
    /// Returns an error when the client cannot be started.
    fn attach(&self, plan: &AdmissionPlan) -> Result<Self::Client, String>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WslConfig {
    distro: Option<String>,
    tmux_binary: String,
    tmux_tmpdir: Option<String>,
}

impl WslConfig {
    #[must_use]
    pub fn distro(&self) -> Option<&str> {
        self.distro.as_deref()
    }

    #[must_use]
    pub fn socket_directory(&self) -> Option<&str> {
        self.tmux_tmpdir.as_deref()
    }

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttachTerm {
    Xterm256Color,
    Xterm,
}

impl AttachTerm {
    const fn environment(self) -> &'static str {
        match self {
            Self::Xterm256Color => "TERM=xterm-256color",
            Self::Xterm => "TERM=xterm",
        }
    }
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
    #[cfg(feature = "test-support")]
    #[doc(hidden)]
    #[must_use]
    pub fn test_fixture(
        distro: impl Into<String>,
        kernel_boot_id: impl Into<String>,
        init_start_ticks: u64,
        sessions: Vec<DiscoveredSession>,
    ) -> Self {
        Self {
            endpoint: WslEndpoint {
                distro: distro.into(),
            },
            runtime: WslRuntimeIdentity {
                kernel_boot_id: kernel_boot_id.into(),
                init_start_ticks,
            },
            sessions,
        }
    }

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

/// Absolute path to the Windows-owned WSL launcher.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WslExecutable(OsString);

pub trait WslPresence: Send + Sync {
    /// Resolve the installed system WSL launcher without executing it.
    ///
    /// # Errors
    ///
    /// Returns an error when the system path cannot be inspected.
    fn resolve(&self) -> Result<Option<WslExecutable>, HostError>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemWslPresence;

impl WslPresence for SystemWslPresence {
    fn resolve(&self) -> Result<Option<WslExecutable>, HostError> {
        #[cfg(windows)]
        {
            let executable = WslExecutable::system()?;
            let exists = std::path::Path::new(executable.as_os_str()).try_exists();
            classify_wsl_presence(executable, exists)
        }
        #[cfg(not(windows))]
        {
            Ok(None)
        }
    }
}

#[cfg(any(windows, test))]
fn classify_wsl_presence(
    executable: WslExecutable,
    exists: std::io::Result<bool>,
) -> Result<Option<WslExecutable>, HostError> {
    match exists {
        Ok(true) => Ok(Some(executable)),
        Ok(false) => Ok(None),
        Err(error) => Err(HostError::new(
            if error.kind() == std::io::ErrorKind::PermissionDenied {
                DiagnosticKind::PermissionDenied
            } else {
                DiagnosticKind::Transport
            },
            format!("inspect system WSL executable: {error}"),
        )),
    }
}

impl WslExecutable {
    /// Resolve `wsl.exe` from the Windows system directory without consulting
    /// the current directory or the launcher `PATH`.
    ///
    /// # Errors
    ///
    /// Returns a classified error when the system directory cannot be read or
    /// on platforms where WSL is unavailable.
    #[cfg(windows)]
    pub fn system() -> Result<Self, HostError> {
        crate::windows_system::wsl_executable()
            .map(Self)
            .map_err(|error| HostError::new(DiagnosticKind::ExecutableNotFound, error.to_string()))
    }

    #[cfg(not(windows))]
    /// Report that the Windows-owned WSL launcher is unavailable.
    ///
    /// # Errors
    ///
    /// Always returns an unsupported-environment error on non-Windows hosts.
    pub fn system() -> Result<Self, HostError> {
        Err(HostError::new(
            DiagnosticKind::UnsupportedEnvironment,
            "WSL is available only on Windows",
        ))
    }

    /// Construct a resolved executable capability for deterministic adapters.
    ///
    /// # Errors
    ///
    /// Returns an error unless `path` is absolute.
    pub fn from_absolute(path: impl Into<OsString>) -> Result<Self, HostError> {
        let path = path.into();
        let text = path.to_string_lossy();
        let bytes = text.as_bytes();
        let is_drive_absolute = bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'\\' | b'/');
        if !is_drive_absolute {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                "WSL executable path is not absolute",
            ));
        }
        Ok(Self(path))
    }

    #[must_use]
    pub fn as_os_str(&self) -> &OsStr {
        &self.0
    }
}

#[derive(Clone, Debug)]
pub struct WslHost<R> {
    config: WslConfig,
    runner: R,
    wsl_executable: WslExecutable,
    verified_tmux: Arc<Mutex<Option<VerifiedAdmission>>>,
}

#[derive(Debug)]
struct VerifiedAdmission {
    runtime: WslRuntimeIdentity,
    _binary: VerifiedTmuxBinary,
}

impl<R: CommandRunner> WslHost<R> {
    #[must_use]
    pub fn new(config: WslConfig, runner: R, wsl_executable: WslExecutable) -> Self {
        Self {
            config,
            runner,
            wsl_executable,
            verified_tmux: Arc::new(Mutex::new(None)),
        }
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
    pub fn discover<A: AdmissionAttacher>(&self, attacher: &A) -> Result<HostSnapshot, HostError> {
        self.discover_with_cancel(attacher, &CancellationToken::new())
    }

    /// Discover inventory with cooperative cancellation for superseded reads.
    ///
    /// # Errors
    ///
    /// Returns a classified transport error when cancelled or timed out.
    pub fn discover_with_cancel<A: AdmissionAttacher>(
        &self,
        attacher: &A,
        cancellation: &CancellationToken,
    ) -> Result<HostSnapshot, HostError> {
        let endpoint = self.resolve_endpoint(cancellation)?;
        let mut runtime = self.resolve_runtime(&endpoint, cancellation)?;
        for _attempt in 0..DISCOVERY_ATTEMPTS {
            self.verify_tmux(&endpoint, &runtime, attacher, cancellation)?;
            let sessions = self.discover_sessions(&endpoint, cancellation)?;
            let observed_runtime = self.resolve_runtime(&endpoint, cancellation)?;
            if runtime == observed_runtime {
                return Ok(HostSnapshot {
                    endpoint,
                    runtime,
                    sessions,
                });
            }
            runtime = observed_runtime;
        }
        Err(HostError::new(
            DiagnosticKind::Transport,
            "WSL distro restarted during tmux discovery",
        ))
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
        self.attach_plan_with_term(endpoint, session, AttachTerm::Xterm256Color)
    }

    /// Build an attach-only plan with an explicit terminal capability level.
    ///
    /// # Errors
    ///
    /// Returns an error if the session name cannot be represented.
    pub fn attach_plan_with_term(
        &self,
        endpoint: &WslEndpoint,
        session: &DiscoveredSession,
        term: AttachTerm,
    ) -> Result<AttachPlan, HostError> {
        if session.name().contains(['\0', '\n', '\r']) {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                "tmux session name contains an invalid control character",
            ));
        }
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(
            &mut args,
            Some(term.environment()),
            self.config.tmux_tmpdir.as_deref(),
            &[],
        );
        args.push(OsString::from(&self.config.tmux_binary));
        let identity = session.identity();
        let target = format!("={}:", identity.session_id());
        let mut condition = String::from("#{&&:");
        condition.push_str(&tmux_identity_equals(
            "pid",
            &identity.server_pid().to_string(),
        ));
        condition.push_str(",#{&&:");
        condition.push_str(&tmux_identity_equals("session_id", identity.session_id()));
        condition.push(',');
        condition.push_str(&tmux_identity_equals(
            "session_created",
            &identity.created_at().to_string(),
        ));
        condition.push_str("}}");
        let attach = format!("attach-session -E -t ={}", identity.session_id());
        args.extend([
            OsString::from("if-shell"),
            OsString::from("-F"),
            OsString::from("-t"),
            OsString::from(target),
            OsString::from(condition),
            OsString::from(attach),
            OsString::from(format!("display-message -p {IDENTITY_MISMATCH_MARKER}")),
        ]);

        Ok(AttachPlan::attach_only(
            self.wsl_executable.as_os_str(),
            args,
            session.name(),
            session.identity().clone(),
        ))
    }

    fn resolve_endpoint(&self, cancellation: &CancellationToken) -> Result<WslEndpoint, HostError> {
        if let Some(distro) = &self.config.distro {
            return Ok(WslEndpoint {
                distro: distro.clone(),
            });
        }

        let output = self.run(
            &[OsString::from("--exec"), OsString::from("/usr/bin/env")],
            cancellation,
        )?;
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

    fn resolve_runtime(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
    ) -> Result<WslRuntimeIdentity, HostError> {
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
        let output = self.run(&args, cancellation)?;
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
        cancellation: &CancellationToken,
    ) -> Result<Vec<DiscoveredSession>, HostError> {
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(
            &mut args,
            Some("TERM=xterm-256color"),
            self.config.tmux_tmpdir.as_deref(),
            &[],
        );
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
        let output = self.run(&args, cancellation)?;
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

    #[allow(
        clippy::too_many_lines,
        reason = "the ordered isolated admission transcript stays together for safety auditing"
    )]
    fn verify_tmux<A: AdmissionAttacher>(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        attacher: &A,
        cancellation: &CancellationToken,
    ) -> Result<(), HostError> {
        if self
            .verified_tmux
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_some_and(|verified| verified.runtime == *runtime)
        {
            return Ok(());
        }

        let sequence = ADMISSION_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let scope = admission_scope(sequence)?;
        let namespace = format!("ghv-{}", scope.name_nonce);
        let session = format!("ghc-{}", scope.name_nonce);
        let target = format!("={session}");
        let prefix_miss = format!("={session}-o");
        let collision = format!("{session}-old");
        let collision_target = format!("={collision}");
        let renamed = format!("{session}-renamed");
        let renamed_target = format!("={renamed}");
        let peer_namespace = format!("{namespace}-peer");
        let peer_session = format!("ghp-{}", scope.name_nonce);
        let peer_target = format!("={peer_session}");
        let mut cleanup = AdmissionCleanup::new(self, endpoint, scope.tmpdir);
        self.create_admission_tmpdir(endpoint, cancellation, cleanup.tmpdir())?;
        cleanup.mark_creation_settled();
        let admission_tmpdir = cleanup.tmpdir().to_owned();

        let version = self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &["-V"],
            "tmux version",
        )?;
        self.require_admission_session_absent(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &target,
        )?;
        cleanup.begin_server_creation(&namespace, &session);
        let creation = self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "new-session",
                "-d",
                "-s",
                &session,
                "-e",
                "GHOSTHUB_PROBE=present",
                "exec /usr/bin/sleep 60",
            ],
            "create primary isolated session",
        );
        cleanup.finish_server_creation(&namespace, &session, &creation);
        creation?;
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "has-session",
                "-t",
                &target,
            ],
            "find primary isolated session",
        )?;
        let repeat_create_plan =
            self.admission_new_session_plan(endpoint, &admission_tmpdir, &namespace, &session);
        let repeat_create_client = attacher.attach(&repeat_create_plan).map_err(|error| {
            HostError::new(
                DiagnosticKind::Transport,
                format!("start atomic create-or-attach admission client: {error}"),
            )
        })?;
        self.wait_for_admission_attachment(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &target,
            true,
        )?;
        drop(repeat_create_client);
        self.wait_for_admission_attachment(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &target,
            false,
        )?;
        self.require_admission_session_absent(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &collision_target,
        )?;
        cleanup.begin_server_creation(&namespace, &collision);
        let creation = self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "new-session",
                "-d",
                "-s",
                &collision,
                "exec /usr/bin/sleep 60",
            ],
            "create exact-target collision",
        );
        cleanup.finish_server_creation(&namespace, &collision, &creation);
        creation?;
        let environment = self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "show-environment",
                "-t",
                &target,
                "GHOSTHUB_PROBE",
            ],
            "read new-session environment",
        )?;
        let initial_identity = self.read_admission_identity(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &session,
        )?;
        let exact_miss = self.run_tmux_missing_session(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "has-session",
                "-t",
                &prefix_miss,
            ],
            "probe exact target miss",
        )?;
        self.require_admission_session_absent(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &peer_namespace,
            &peer_target,
        )?;
        cleanup.begin_server_creation(&peer_namespace, &peer_session);
        let creation = self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &peer_namespace,
                "new-session",
                "-d",
                "-s",
                &peer_session,
                "exec /usr/bin/sleep 60",
            ],
            "create peer isolated session",
        );
        cleanup.finish_server_creation(&peer_namespace, &peer_session, &creation);
        creation?;
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &peer_namespace,
                "has-session",
                "-t",
                &peer_target,
            ],
            "find peer isolated session",
        )?;
        let peer_absent_from_primary = self.run_tmux_missing_session(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "has-session",
                "-t",
                &peer_target,
            ],
            "check peer absence from primary namespace",
        )?;
        let primary_absent_from_peer = self.run_tmux_missing_session(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &peer_namespace,
                "has-session",
                "-t",
                &target,
            ],
            "check primary absence from peer namespace",
        )?;
        let isolated = peer_absent_from_primary && primary_absent_from_peer;
        if !isolated {
            return Err(HostError::new(
                DiagnosticKind::UnsupportedEnvironment,
                "tmux admission failed: isolated namespaces are required",
            ));
        }
        cleanup.mark_isolated([&namespace, &peer_namespace]);
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "set-option",
                "-g",
                "update-environment",
                "GHOSTHUB_PROBE",
            ],
            "configure client environment updates",
        )?;
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "set-environment",
                "-t",
                &target,
                "GHOSTHUB_PROBE",
                "session",
            ],
            "set session environment control value",
        )?;
        let control_plan = self.admission_attach_plan(
            endpoint,
            &admission_tmpdir,
            &namespace,
            &target,
            false,
            "GHOSTHUB_PROBE=client",
        );
        let control_client = attacher.attach(&control_plan).map_err(|error| {
            HostError::new(
                DiagnosticKind::Transport,
                format!("start tmux admission control client: {error}"),
            )
        })?;
        self.wait_for_admission_attachment(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &target,
            true,
        )?;
        let positive_value = self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "show-environment",
                "-t",
                &target,
                "GHOSTHUB_PROBE",
            ],
            "read updated session environment",
        )?;
        drop(control_client);
        self.wait_for_admission_attachment(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &target,
            false,
        )?;
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "set-environment",
                "-t",
                &target,
                "GHOSTHUB_PROBE",
                "session",
            ],
            "reset session environment control value",
        )?;
        let preserve_plan = self.admission_attach_plan(
            endpoint,
            &admission_tmpdir,
            &namespace,
            &target,
            true,
            "GHOSTHUB_PROBE=ignored",
        );
        let preserve_client = attacher.attach(&preserve_plan).map_err(|error| {
            HostError::new(
                DiagnosticKind::Transport,
                format!("start tmux admission preserve client: {error}"),
            )
        })?;
        self.wait_for_admission_attachment(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &target,
            true,
        )?;
        let preserved_value = self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "show-environment",
                "-t",
                &target,
                "GHOSTHUB_PROBE",
            ],
            "read preserved session environment",
        )?;
        drop(preserve_client);
        self.wait_for_admission_attachment(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &target,
            false,
        )?;
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "rename-session",
                "-t",
                &target,
                &renamed,
            ],
            "rename exact session",
        )?;
        let renamed_identity = self.read_admission_identity(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &renamed,
        )?;
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "kill-session",
                "-t",
                &renamed_target,
            ],
            "kill exact renamed session",
        )?;
        let killed_absent = self.run_tmux_missing_session(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "has-session",
                "-t",
                &renamed_target,
            ],
            "confirm exact session removal",
        )?;
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "has-session",
                "-t",
                &collision_target,
            ],
            "confirm colliding session survived exact kill",
        )?;
        self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &["-f", "/dev/null", "-L", &namespace, "kill-server"],
            "stop isolated tmux server",
        )?;
        self.require_admission_session_absent(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &target,
        )?;
        cleanup.begin_server_creation(&namespace, &session);
        let creation = self.run_tmux_required(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                &namespace,
                "new-session",
                "-d",
                "-s",
                &session,
                "exec /usr/bin/sleep 60",
            ],
            "restart isolated tmux server",
        );
        cleanup.finish_server_creation(&namespace, &session, &creation);
        creation?;
        let restarted_identity = self.read_admission_identity(
            endpoint,
            cancellation,
            &admission_tmpdir,
            &namespace,
            &session,
        )?;
        let version_output = decode(&version.stdout, "tmux version")?;
        let stable_identity = initial_identity.session_id == renamed_identity.session_id;
        let server_identity = initial_identity.server_pid != restarted_identity.server_pid;
        let attach_preserves_environment =
            decode(&positive_value.stdout, "updated session environment")?.trim()
                == "GHOSTHUB_PROBE=client"
                && decode(&preserved_value.stdout, "preserved session environment")?.trim()
                    == "GHOSTHUB_PROBE=session";
        let observations = [
            observation("atomic-create-or-attach", true),
            observation(
                "new-session-environment",
                String::from_utf8_lossy(&environment.stdout)
                    .lines()
                    .any(|line| line == "GHOSTHUB_PROBE=present"),
            ),
            observation("attach-preserve-environment", attach_preserves_environment),
            observation("exact-targets", exact_miss && killed_absent),
            observation("stable-session-identity", stable_identity),
            observation("server-instance-identity", server_identity),
            observation("isolated-namespace", isolated),
        ];
        let verified = resolve_tmux_binary(
            ExecutablePlatform::Posix,
            &self.config.tmux_binary,
            version_output,
            &observations,
        )
        .map_err(|error| {
            HostError::new(
                DiagnosticKind::UnsupportedEnvironment,
                format!(
                    "tmux admission failed: {error}; identity probe returned {:?}",
                    initial_identity.session_id
                ),
            )
        })?;
        *self
            .verified_tmux
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(VerifiedAdmission {
            runtime: runtime.clone(),
            _binary: verified,
        });
        Ok(())
    }

    fn create_admission_tmpdir(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
    ) -> Result<(), HostError> {
        let mut args = pinned_prefix(endpoint);
        append_scrubbed_environment(&mut args);
        args.extend(
            ["/usr/bin/mkdir", "--mode=700", "--", tmux_tmpdir]
                .into_iter()
                .map(OsString::from),
        );
        let output = self.run(&args, cancellation)?;
        if output.status != 0 {
            return Err(classify_admission_failure(
                output.status,
                &output.stderr,
                "create private tmux admission directory",
            ));
        }
        Ok(())
    }

    fn remove_admission_tmpdir(
        &self,
        endpoint: &WslEndpoint,
        tmux_tmpdir: &str,
        creation_settled: bool,
    ) {
        if creation_settled {
            self.remove_admission_tmpdir_once(endpoint, tmux_tmpdir);
        } else {
            let start = Instant::now();
            settle_uncertain_cleanup(
                || start.elapsed(),
                thread::sleep,
                |_remaining| self.remove_admission_tmpdir_once(endpoint, tmux_tmpdir),
            );
        }
        if !self.admission_tmpdir_is_absent(endpoint, tmux_tmpdir) {
            self.remove_admission_tmpdir_once(endpoint, tmux_tmpdir);
        }
    }

    fn remove_admission_tmpdir_once(&self, endpoint: &WslEndpoint, tmux_tmpdir: &str) {
        let mut args = pinned_prefix(endpoint);
        append_scrubbed_environment(&mut args);
        args.extend(
            ["/usr/bin/rm", "-rf", "--", tmux_tmpdir]
                .into_iter()
                .map(OsString::from),
        );
        let _ignored = self.runner.run(
            self.wsl_executable.as_os_str(),
            &args,
            &CancellationToken::new(),
            CLEANUP_COMMAND_TIMEOUT,
        );
    }

    fn admission_tmpdir_is_absent(&self, endpoint: &WslEndpoint, tmux_tmpdir: &str) -> bool {
        let mut args = pinned_prefix(endpoint);
        append_scrubbed_environment(&mut args);
        args.extend(
            ["/usr/bin/test", "!", "-e", tmux_tmpdir]
                .into_iter()
                .map(OsString::from),
        );
        self.runner
            .run(
                self.wsl_executable.as_os_str(),
                &args,
                &CancellationToken::new(),
                CLEANUP_COMMAND_TIMEOUT,
            )
            .is_ok_and(|output| output.status == 0)
    }

    fn run_tmux(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
        tmux_args: &[&str],
    ) -> Result<CommandOutput, HostError> {
        self.run_tmux_with_env(endpoint, cancellation, tmux_tmpdir, &[], tmux_args)
    }

    fn run_tmux_cleanup(
        &self,
        endpoint: &WslEndpoint,
        tmux_tmpdir: &str,
        tmux_args: &[&str],
        timeout: Duration,
    ) {
        if timeout.is_zero() {
            return;
        }
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(&mut args, None, Some(tmux_tmpdir), &[]);
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(tmux_args.iter().map(OsString::from));
        let _ignored = self.runner.run(
            self.wsl_executable.as_os_str(),
            &args,
            &CancellationToken::new(),
            timeout.min(CLEANUP_COMMAND_TIMEOUT),
        );
    }

    fn read_admission_identity(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
        namespace: &str,
        expected_name: &str,
    ) -> Result<AdmissionIdentity, HostError> {
        let output = self.run_tmux_required(
            endpoint,
            cancellation,
            tmux_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                namespace,
                "list-sessions",
                "-F",
                ADMISSION_IDENTITY_FORMAT,
            ],
            "read isolated tmux identity",
        )?;
        for record in parse_tmux_name_records(&output.stdout, 2, "isolated tmux identity")? {
            if record.name != expected_name {
                continue;
            }
            let server_pid = record.fields[0].parse::<u32>().map_err(|_| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "isolated tmux identity has an invalid server PID",
                )
            })?;
            if server_pid == 0 || !is_tmux_session_id(record.fields[1]) {
                return Err(HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "isolated tmux identity is invalid",
                ));
            }
            return Ok(AdmissionIdentity {
                server_pid,
                session_id: record.fields[1].to_owned(),
            });
        }
        Err(HostError::new(
            DiagnosticKind::MalformedOutput,
            format!("isolated tmux session {expected_name:?} is absent from identity output"),
        ))
    }

    fn admission_new_session_plan(
        &self,
        endpoint: &WslEndpoint,
        tmux_tmpdir: &str,
        namespace: &str,
        session_name: &str,
    ) -> AdmissionPlan {
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(&mut args, Some("TERM=xterm"), Some(tmux_tmpdir), &[]);
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(
            [
                "-f",
                "/dev/null",
                "-L",
                namespace,
                "new-session",
                "-A",
                "-s",
                session_name,
                "exec /usr/bin/sleep 60",
            ]
            .into_iter()
            .map(OsString::from),
        );
        AdmissionPlan::isolated(self.wsl_executable.as_os_str(), args)
    }

    fn admission_attach_plan(
        &self,
        endpoint: &WslEndpoint,
        tmux_tmpdir: &str,
        namespace: &str,
        target: &str,
        preserve_environment: bool,
        probe_environment: &str,
    ) -> AdmissionPlan {
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(
            &mut args,
            Some("TERM=xterm"),
            Some(tmux_tmpdir),
            &[probe_environment],
        );
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(
            ["-f", "/dev/null", "-L", namespace, "attach-session"]
                .into_iter()
                .map(OsString::from),
        );
        if preserve_environment {
            args.push(OsString::from("-E"));
        }
        args.extend(["-t", target].into_iter().map(OsString::from));
        AdmissionPlan::isolated(self.wsl_executable.as_os_str(), args)
    }

    fn wait_for_admission_attachment(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
        namespace: &str,
        target: &str,
        attached: bool,
    ) -> Result<(), HostError> {
        let deadline = Instant::now() + ATTACHMENT_PROBE_TIMEOUT;
        loop {
            let output = self.run_tmux_required(
                endpoint,
                cancellation,
                tmux_tmpdir,
                &[
                    "-f",
                    "/dev/null",
                    "-L",
                    namespace,
                    "list-clients",
                    "-t",
                    target,
                    "-F",
                    "#{client_session}",
                ],
                "observe tmux admission client",
            )?;
            let count = decode(&output.stdout, "tmux attached-client inventory")?
                .lines()
                .filter(|line| !line.is_empty())
                .count();
            if (count > 0) == attached {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(HostError::new(
                    DiagnosticKind::UnsupportedEnvironment,
                    if attached {
                        "ordinary ConPTY tmux admission client did not attach"
                    } else {
                        "ordinary ConPTY tmux admission client did not detach"
                    },
                ));
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn run_tmux_required(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
        tmux_args: &[&str],
        subject: &str,
    ) -> Result<CommandOutput, HostError> {
        self.run_tmux_with_env_required(
            endpoint,
            cancellation,
            tmux_tmpdir,
            &[],
            tmux_args,
            subject,
        )
    }

    fn run_tmux_with_env_required(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
        environment: &[&str],
        tmux_args: &[&str],
        subject: &str,
    ) -> Result<CommandOutput, HostError> {
        let output =
            self.run_tmux_with_env(endpoint, cancellation, tmux_tmpdir, environment, tmux_args)?;
        if output.status == 0 {
            Ok(output)
        } else {
            Err(classify_admission_failure(
                output.status,
                &output.stderr,
                subject,
            ))
        }
    }

    fn run_tmux_missing_session(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
        tmux_args: &[&str],
        subject: &str,
    ) -> Result<bool, HostError> {
        let output = self.run_tmux(endpoint, cancellation, tmux_tmpdir, tmux_args)?;
        if output.status == 0 {
            return Ok(false);
        }
        if is_missing_session(&String::from_utf8_lossy(&output.stderr)) {
            return Ok(true);
        }
        Err(classify_admission_failure(
            output.status,
            &output.stderr,
            subject,
        ))
    }

    fn require_admission_session_absent(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
        namespace: &str,
        target: &str,
    ) -> Result<(), HostError> {
        let output = self.run_tmux(
            endpoint,
            cancellation,
            tmux_tmpdir,
            &[
                "-f",
                "/dev/null",
                "-L",
                namespace,
                "has-session",
                "-t",
                target,
            ],
        )?;
        if output.status == 0 {
            return Err(HostError::new(
                DiagnosticKind::UnsupportedEnvironment,
                format!("private tmux admission target {target:?} already exists"),
            ));
        }
        let stderr = String::from_utf8_lossy(&output.stderr);
        if is_missing_session(&stderr) || is_no_server(&stderr) {
            Ok(())
        } else {
            Err(classify_admission_failure(
                output.status,
                &output.stderr,
                "prove private tmux admission target is absent",
            ))
        }
    }

    fn run_tmux_with_env(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_tmpdir: &str,
        environment: &[&str],
        tmux_args: &[&str],
    ) -> Result<CommandOutput, HostError> {
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(&mut args, None, Some(tmux_tmpdir), environment);
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(tmux_args.iter().map(OsString::from));
        self.run(&args, cancellation)
    }

    fn run(
        &self,
        args: &[OsString],
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, HostError> {
        self.runner
            .run(
                self.wsl_executable.as_os_str(),
                args,
                cancellation,
                COMMAND_TIMEOUT,
            )
            .map_err(|error| {
                HostError::new(
                    if error.kind() == std::io::ErrorKind::TimedOut {
                        DiagnosticKind::Timeout
                    } else {
                        DiagnosticKind::Transport
                    },
                    error.to_string(),
                )
            })
    }
}

struct AdmissionCleanup<'a, R: CommandRunner> {
    host: &'a WslHost<R>,
    endpoint: &'a WslEndpoint,
    tmux_tmpdir: String,
    creation_settled: bool,
    exact_sessions: Vec<(String, String)>,
    isolated_namespaces: Option<Vec<String>>,
    server_creation_uncertain: bool,
}

struct AdmissionIdentity {
    server_pid: u32,
    session_id: String,
}

impl<'a, R: CommandRunner> AdmissionCleanup<'a, R> {
    fn new(host: &'a WslHost<R>, endpoint: &'a WslEndpoint, tmux_tmpdir: String) -> Self {
        Self {
            host,
            endpoint,
            tmux_tmpdir,
            creation_settled: false,
            exact_sessions: Vec::new(),
            isolated_namespaces: None,
            server_creation_uncertain: false,
        }
    }

    fn tmpdir(&self) -> &str {
        &self.tmux_tmpdir
    }

    fn mark_creation_settled(&mut self) {
        self.creation_settled = true;
    }

    fn begin_server_creation(&mut self, namespace: &str, session: &str) {
        let session = (namespace.to_owned(), session.to_owned());
        if !self.exact_sessions.contains(&session) {
            self.exact_sessions.push(session);
        }
        self.server_creation_uncertain = true;
    }

    fn finish_server_creation<T>(
        &mut self,
        namespace: &str,
        session: &str,
        result: &Result<T, HostError>,
    ) {
        if result.is_ok() {
            self.server_creation_uncertain = false;
        } else if result
            .as_ref()
            .err()
            .is_some_and(|error| is_duplicate_session(&error.to_string()))
        {
            self.server_creation_uncertain = false;
            self.exact_sessions
                .retain(|candidate| candidate != &(namespace.to_owned(), session.to_owned()));
        }
    }

    fn mark_isolated<'b>(&mut self, namespaces: impl IntoIterator<Item = &'b String>) {
        self.isolated_namespaces = Some(namespaces.into_iter().cloned().collect());
    }

    fn cleanup_pass_budget(&self) -> Duration {
        let commands = self
            .isolated_namespaces
            .as_ref()
            .map_or(self.exact_sessions.len(), Vec::len);
        CLEANUP_COMMAND_TIMEOUT.saturating_mul(u32::try_from(commands).unwrap_or(u32::MAX))
    }

    fn terminate_mux_once(&self, budget: Duration) {
        let deadline = Instant::now() + budget;
        if let Some(namespaces) = &self.isolated_namespaces {
            for namespace in namespaces {
                let remaining = deadline.saturating_duration_since(Instant::now());
                self.host.run_tmux_cleanup(
                    self.endpoint,
                    &self.tmux_tmpdir,
                    &["-f", "/dev/null", "-L", namespace, "kill-server"],
                    remaining,
                );
            }
        } else {
            for (namespace, session) in &self.exact_sessions {
                let target = format!("={session}");
                let remaining = deadline.saturating_duration_since(Instant::now());
                self.host.run_tmux_cleanup(
                    self.endpoint,
                    &self.tmux_tmpdir,
                    &[
                        "-f",
                        "/dev/null",
                        "-L",
                        namespace,
                        "kill-session",
                        "-t",
                        &target,
                    ],
                    remaining,
                );
            }
        }
    }
}

impl<R: CommandRunner> Drop for AdmissionCleanup<'_, R> {
    fn drop(&mut self) {
        if self.server_creation_uncertain {
            let start = Instant::now();
            settle_uncertain_cleanup(
                || start.elapsed(),
                thread::sleep,
                |remaining| self.terminate_mux_once(remaining),
            );
        } else {
            self.terminate_mux_once(self.cleanup_pass_budget());
        }
        // Keep the private socket root reachable until the final termination
        // pass, then remove it. Unlinking it earlier could strand a server
        // whose timed-out creation publishes its socket between passes.
        self.host
            .remove_admission_tmpdir(self.endpoint, &self.tmux_tmpdir, self.creation_settled);
    }
}

fn pinned_prefix(endpoint: &WslEndpoint) -> Vec<OsString> {
    ["--distribution", endpoint.distro(), "--exec"]
        .into_iter()
        .map(OsString::from)
        .collect()
}

fn append_scrubbed_environment(args: &mut Vec<OsString>) {
    args.extend(
        [
            "/usr/bin/env",
            "-u",
            "TMUX",
            "-u",
            "TMUX_PANE",
            "-u",
            "TMUX_TMPDIR",
        ]
        .into_iter()
        .map(OsString::from),
    );
}

fn append_tmux_environment(
    args: &mut Vec<OsString>,
    term: Option<&str>,
    tmux_tmpdir: Option<&str>,
    environment: &[&str],
) {
    append_scrubbed_environment(args);
    if let Some(term) = term {
        args.push(OsString::from(term));
    }
    if let Some(path) = tmux_tmpdir {
        args.push(OsString::from(format!("TMUX_TMPDIR={path}")));
    }
    args.extend(environment.iter().map(OsString::from));
}

fn settle_uncertain_cleanup(
    mut elapsed: impl FnMut() -> Duration,
    mut wait: impl FnMut(Duration),
    mut remove: impl FnMut(Duration),
) {
    loop {
        let remaining = UNCERTAIN_CLEANUP_SETTLE.saturating_sub(elapsed());
        if remaining.is_zero() {
            break;
        }
        remove(remaining);
        let remaining = UNCERTAIN_CLEANUP_SETTLE.saturating_sub(elapsed());
        if remaining.is_zero() {
            break;
        }
        wait(UNCERTAIN_CLEANUP_DELAY.min(remaining));
    }
}

struct AdmissionScope {
    tmpdir: String,
    name_nonce: String,
}

fn admission_scope(sequence: u64) -> Result<AdmissionScope, HostError> {
    let mut nonce = [0_u8; 16];
    getrandom::fill(&mut nonce).map_err(|error| {
        HostError::new(
            DiagnosticKind::Transport,
            format!("generate private tmux admission directory: {error}"),
        )
    })?;
    let nonce = format!("{:032x}", u128::from_ne_bytes(nonce));
    Ok(AdmissionScope {
        tmpdir: format!(
            "/tmp/ghosthub-tmux-probe.{:x}-{sequence:x}-{nonce}",
            std::process::id()
        ),
        name_nonce: nonce[..16].to_owned(),
    })
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
    if !is_boot_id(kernel_boot_id) {
        return Err(HostError::new(
            DiagnosticKind::MalformedOutput,
            "kernel boot ID is not a UUID",
        ));
    }
    if !init_stat.starts_with("1 (") {
        return Err(HostError::new(
            DiagnosticKind::MalformedOutput,
            "PID 1 stat does not identify process 1",
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
    parse_tmux_name_records(bytes, 4, "tmux inventory")?
        .into_iter()
        .map(|record| {
            let server_pid = record.fields[0].parse::<u32>().map_err(|_| {
                HostError::new(DiagnosticKind::MalformedOutput, "invalid tmux server PID")
            })?;
            if server_pid == 0 {
                return Err(HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "invalid tmux server PID",
                ));
            }
            if !is_tmux_session_id(record.fields[1]) {
                return Err(HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "invalid tmux session ID",
                ));
            }
            let created_at = record.fields[2].parse::<u64>().map_err(|_| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "invalid tmux creation time",
                )
            })?;
            let attached_clients = record.fields[3].parse::<u32>().map_err(|_| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "invalid tmux attached-client count",
                )
            })?;
            Ok(DiscoveredSession::new(
                record.name,
                SessionIdentity::new(server_pid, record.fields[1], created_at),
                attached_clients,
            ))
        })
        .collect()
}

struct TmuxNameRecord<'a> {
    fields: Vec<&'a str>,
    name: &'a str,
}

fn parse_tmux_name_records<'a>(
    bytes: &'a [u8],
    field_count: usize,
    subject: &str,
) -> Result<Vec<TmuxNameRecord<'a>>, HostError> {
    let mut remaining = decode(bytes, subject)?;
    let mut records = Vec::new();
    while !remaining.is_empty() {
        let mut fields = Vec::with_capacity(field_count);
        for _ in 0..field_count {
            fields.push(take_tmux_field(&mut remaining, subject)?);
        }
        let name_length = take_tmux_field(&mut remaining, subject)?
            .parse::<usize>()
            .map_err(|_| malformed_name_record(subject))?;
        let name = remaining
            .get(..name_length)
            .ok_or_else(|| malformed_name_record(subject))?;
        remaining = remaining
            .get(name_length..)
            .and_then(|suffix| suffix.strip_prefix('\n'))
            .ok_or_else(|| malformed_name_record(subject))?;
        records.push(TmuxNameRecord { fields, name });
    }
    Ok(records)
}

fn take_tmux_field<'a>(remaining: &mut &'a str, subject: &str) -> Result<&'a str, HostError> {
    let delimiter = remaining
        .find('\t')
        .ok_or_else(|| malformed_name_record(subject))?;
    let (field, suffix) = remaining.split_at(delimiter);
    *remaining = &suffix[1..];
    Ok(field)
}

fn malformed_name_record(subject: &str) -> HostError {
    HostError::new(
        DiagnosticKind::MalformedOutput,
        format!("{subject} has an invalid length-prefixed session name"),
    )
}

fn observation(name: &str, supported: bool) -> ProbeObservation {
    ProbeObservation {
        name: name.to_owned(),
        exit_code: i32::from(!supported),
        stdout: if supported {
            "supported"
        } else {
            "unsupported"
        }
        .to_owned(),
        stderr: String::new(),
    }
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

fn classify_admission_failure(status: i32, stderr: &[u8], subject: &str) -> HostError {
    let error = classify_command_failure(status, stderr, subject);
    if error.kind() == DiagnosticKind::Transport {
        HostError::new(
            DiagnosticKind::UnsupportedEnvironment,
            format!("tmux admission failed: {error}"),
        )
    } else {
        error
    }
}

fn is_no_server(stderr: &str) -> bool {
    let lower = stderr.to_ascii_lowercase();
    lower.contains("no server running")
        || (lower.contains("error connecting") && lower.contains("no such file"))
}

fn is_missing_session(stderr: &str) -> bool {
    let lower = stderr.to_ascii_lowercase();
    lower.contains("can't find session") || lower.contains("no such session")
}

fn is_duplicate_session(stderr: &str) -> bool {
    stderr.to_ascii_lowercase().contains("duplicate session")
}

fn is_posix_absolute(path: &str) -> bool {
    path.starts_with('/')
}

fn is_boot_id(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

fn is_tmux_session_id(value: &str) -> bool {
    value.strip_prefix('$').is_some_and(|digits| {
        !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit())
    })
}

fn tmux_identity_equals(field: &str, value: &str) -> String {
    let mut condition = String::from("#{==:#{");
    condition.push_str(field);
    condition.push_str("},");
    condition.push_str(value);
    condition.push('}');
    condition
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::io;

    use super::*;

    #[test]
    fn missing_system_wsl_is_not_an_error() {
        let result = classify_wsl_presence(
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute path"),
            Ok(false),
        )
        .expect("absence is supported");

        assert!(result.is_none());
    }

    #[test]
    fn unreadable_system_wsl_is_not_treated_as_absent() {
        let error = classify_wsl_presence(
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute path"),
            Err(io::Error::new(io::ErrorKind::PermissionDenied, "denied")),
        )
        .expect_err("presence failure is visible");

        assert_eq!(error.kind(), DiagnosticKind::PermissionDenied);
    }

    #[test]
    fn uncertain_cleanup_removes_creation_at_the_settle_deadline() {
        let elapsed = Cell::new(Duration::ZERO);
        let exists = Cell::new(false);
        let late_creation_ran = Cell::new(false);

        settle_uncertain_cleanup(
            || elapsed.get(),
            |delay| {
                let next = elapsed.get() + delay;
                elapsed.set(next);
                if next >= UNCERTAIN_CLEANUP_SETTLE.saturating_sub(UNCERTAIN_CLEANUP_DELAY)
                    && !late_creation_ran.replace(true)
                {
                    exists.set(true);
                }
            },
            |_remaining| exists.set(false),
        );

        assert!(late_creation_ran.get());
        assert!(elapsed.get() >= UNCERTAIN_CLEANUP_SETTLE);
        assert!(!exists.get(), "the final removal must follow late creation");
    }
}
