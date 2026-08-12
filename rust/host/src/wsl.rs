use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use model::DiagnosticKind;
use session::{
    AdmissionPlan, AttachPlan, CreateOnce, DiscoveredSession, ExecutablePlatform, HerdrAttachPlan,
    HerdrLaunchOnce, HerdrLaunchTarget, HerdrLifecycleAction, HerdrSessionRecord,
    HerdrSessionState, IDENTITY_MISMATCH_MARKER, ProbeObservation, RepairOrOpenPlan,
    SessionIdentity, SessionName, VerifiedTmuxBinary, ZellijAttachPlan, ZellijLaunchOnce,
    ZellijSessionName, ZellijSessionRecord, resolve_tmux_binary,
};

use crate::herdr::{self, ExecutableProbe};
use crate::kwt::{parse_branches, parse_command_failure, parse_project_mutation};
use crate::zellij;
use crate::{
    CancellationToken, CommandOutput, CommandRunner, KwtBranchCandidate, KwtBundle, KwtInventory,
    KwtProject, KwtWorktreeCreate,
};

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
const KILL_IDENTITY_MISMATCH_MARKER: &str = "__ghosthub_kill_identity_mismatch_v1__";
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
    kwt_bundle: Option<KwtBundle>,
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

    #[must_use]
    pub const fn kwt_bundle(&self) -> Option<&KwtBundle> {
        self.kwt_bundle.as_ref()
    }

    #[must_use]
    pub fn with_kwt_bundle(mut self, bundle: KwtBundle) -> Self {
        self.kwt_bundle = Some(bundle);
        self
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
            kwt_bundle: None,
        })
    }
}

impl Default for WslConfig {
    fn default() -> Self {
        Self {
            distro: None,
            tmux_binary: DEFAULT_TMUX.to_owned(),
            tmux_tmpdir: None,
            kwt_bundle: None,
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

/// Opaque authority to read and remove one nonce-scoped creation receipt.
/// Only [`WslHost`] can construct its private path.
#[derive(Debug, Eq, PartialEq)]
pub struct CreationReceipt {
    path: String,
    staging_path: String,
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
    creation_term: AttachTerm,
    sessions: Vec<DiscoveredSession>,
    herdr: Box<HerdrInventory>,
    zellij: Box<ZellijInventory>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtHostSnapshot {
    endpoint: WslEndpoint,
    runtime: WslRuntimeIdentity,
    inventory: Option<KwtInventory>,
}

impl KwtHostSnapshot {
    #[must_use]
    pub const fn endpoint(&self) -> &WslEndpoint {
        &self.endpoint
    }

    #[must_use]
    pub const fn runtime(&self) -> &WslRuntimeIdentity {
        &self.runtime
    }

    #[must_use]
    pub const fn inventory(&self) -> Option<&KwtInventory> {
        self.inventory.as_ref()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HerdrInventory {
    Unavailable,
    Available {
        executable: String,
        sessions: Vec<HerdrSessionRecord>,
    },
    Failed(HostError),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ZellijInventory {
    Unavailable,
    Available {
        executable: String,
        sessions: Vec<ZellijSessionRecord>,
    },
    Failed(HostError),
}

impl ZellijInventory {
    #[must_use]
    pub const fn is_available(&self) -> bool {
        matches!(self, Self::Available { .. })
    }

    #[must_use]
    pub fn executable(&self) -> Option<&str> {
        match self {
            Self::Available { executable, .. } => Some(executable),
            Self::Unavailable | Self::Failed(_) => None,
        }
    }

    #[must_use]
    pub fn sessions(&self) -> &[ZellijSessionRecord] {
        match self {
            Self::Available { sessions, .. } => sessions,
            Self::Unavailable | Self::Failed(_) => &[],
        }
    }

    #[must_use]
    pub const fn diagnostic(&self) -> Option<&HostError> {
        match self {
            Self::Failed(error) => Some(error),
            Self::Unavailable | Self::Available { .. } => None,
        }
    }
}

impl HerdrInventory {
    #[must_use]
    pub const fn is_available(&self) -> bool {
        matches!(self, Self::Available { .. })
    }

    #[must_use]
    pub fn executable(&self) -> Option<&str> {
        match self {
            Self::Available { executable, .. } => Some(executable),
            Self::Unavailable | Self::Failed(_) => None,
        }
    }

    #[must_use]
    pub fn sessions(&self) -> &[HerdrSessionRecord] {
        match self {
            Self::Available { sessions, .. } => sessions,
            Self::Unavailable | Self::Failed(_) => &[],
        }
    }

    #[must_use]
    pub const fn diagnostic(&self) -> Option<&HostError> {
        match self {
            Self::Failed(error) => Some(error),
            Self::Unavailable | Self::Available { .. } => None,
        }
    }
}

/// Fresh, non-persistable authority to kill one exact live tmux session.
///
/// The constructor is private so cached inventory cannot be promoted into
/// destructive authority. Callers can obtain this value only from a live
/// tmux query immediately before presenting confirmation.
#[derive(Debug)]
pub struct LiveSessionTarget {
    endpoint: WslEndpoint,
    runtime: WslRuntimeIdentity,
    name: String,
    identity: SessionIdentity,
}

impl LiveSessionTarget {
    #[cfg(feature = "test-support")]
    #[doc(hidden)]
    #[must_use]
    pub fn test_fixture(
        snapshot: &HostSnapshot,
        name: impl Into<String>,
        identity: SessionIdentity,
    ) -> Self {
        Self {
            endpoint: snapshot.endpoint.clone(),
            runtime: snapshot.runtime.clone(),
            name: name.into(),
            identity,
        }
    }

    #[must_use]
    pub fn endpoint(&self) -> &WslEndpoint {
        &self.endpoint
    }

    #[must_use]
    pub const fn runtime(&self) -> &WslRuntimeIdentity {
        &self.runtime
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub const fn identity(&self) -> &SessionIdentity {
        &self.identity
    }
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
            creation_term: AttachTerm::Xterm256Color,
            sessions,
            herdr: Box::new(HerdrInventory::Unavailable),
            zellij: Box::new(ZellijInventory::Unavailable),
        }
    }

    #[cfg(feature = "test-support")]
    #[doc(hidden)]
    #[must_use]
    pub fn test_fixture_with_herdr(
        distro: impl Into<String>,
        kernel_boot_id: impl Into<String>,
        init_start_ticks: u64,
        sessions: Vec<DiscoveredSession>,
        herdr: HerdrInventory,
    ) -> Self {
        let mut snapshot = Self::test_fixture(distro, kernel_boot_id, init_start_ticks, sessions);
        snapshot.herdr = Box::new(herdr);
        snapshot
    }

    #[cfg(feature = "test-support")]
    #[doc(hidden)]
    #[must_use]
    pub fn test_fixture_with_zellij(
        distro: impl Into<String>,
        kernel_boot_id: impl Into<String>,
        init_start_ticks: u64,
        sessions: Vec<DiscoveredSession>,
        zellij: ZellijInventory,
    ) -> Self {
        let mut snapshot = Self::test_fixture(distro, kernel_boot_id, init_start_ticks, sessions);
        snapshot.zellij = Box::new(zellij);
        snapshot
    }

    #[cfg(feature = "test-support")]
    #[doc(hidden)]
    #[must_use]
    pub const fn test_fixture_with_creation_term(mut self, term: AttachTerm) -> Self {
        self.creation_term = term;
        self
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
    pub const fn creation_term(&self) -> AttachTerm {
        self.creation_term
    }

    #[must_use]
    pub fn sessions(&self) -> &[DiscoveredSession] {
        &self.sessions
    }

    #[must_use]
    pub fn herdr(&self) -> &HerdrInventory {
        self.herdr.as_ref()
    }

    #[must_use]
    pub fn zellij(&self) -> &ZellijInventory {
        self.zellij.as_ref()
    }

    /// Apply one authoritative Herdr lifecycle response to this snapshot.
    ///
    /// Returns `None` when the snapshot does not contain the session inventory
    /// that authorized the operation.
    #[must_use]
    pub fn with_herdr_lifecycle(
        mut self,
        action: HerdrLifecycleAction,
        expected_executable: &str,
        confirmed: &HerdrSessionRecord,
        record: HerdrSessionRecord,
    ) -> Option<Self> {
        let HerdrInventory::Available {
            executable,
            sessions,
        } = self.herdr.as_mut()
        else {
            return None;
        };
        if executable != expected_executable {
            return None;
        }
        let index = sessions.iter().position(|session| {
            session.name() == confirmed.name()
                && session.state() == confirmed.state()
                && session.is_default() == confirmed.is_default()
                && session.session_directory() == confirmed.session_directory()
                && session.socket_path() == confirmed.socket_path()
        })?;
        match action {
            HerdrLifecycleAction::Stop => sessions[index] = record,
            HerdrLifecycleAction::Delete => {
                sessions.remove(index);
            }
        }
        Some(self)
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
    verified_kwt: Arc<Mutex<Option<VerifiedKwtHelper>>>,
    kwt_activation: Arc<Mutex<()>>,
}

#[derive(Debug)]
struct VerifiedAdmission {
    endpoint: WslEndpoint,
    runtime: WslRuntimeIdentity,
    creation_term: AttachTerm,
    _binary: VerifiedTmuxBinary,
}

#[derive(Clone, Debug)]
struct VerifiedKwtHelper {
    endpoint: WslEndpoint,
    runtime: WslRuntimeIdentity,
    path: String,
}

impl<R: CommandRunner> WslHost<R> {
    #[must_use]
    pub fn new(config: WslConfig, runner: R, wsl_executable: WslExecutable) -> Self {
        Self {
            config,
            runner,
            wsl_executable,
            verified_tmux: Arc::new(Mutex::new(None)),
            verified_kwt: Arc::new(Mutex::new(None)),
            kwt_activation: Arc::new(Mutex::new(())),
        }
    }

    #[must_use]
    pub const fn runner(&self) -> &R {
        &self.runner
    }

    #[must_use]
    pub fn socket_directory(&self) -> Option<&str> {
        self.config.socket_directory()
    }

    /// Read KWT project and worktree inventory independently from session
    /// discovery. Callers schedule this on the slower worktree cadence; tmux
    /// and Herdr refreshes never invoke it.
    ///
    /// A missing embedded helper is normal in developer builds and returns
    /// `Ok(None)`. Packaged builds require the bundle during compilation.
    ///
    /// # Errors
    ///
    /// Returns a classified error when helper activation, execution, parsing,
    /// or the WSL runtime boundary fails.
    pub fn discover_kwt(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        cancellation: &CancellationToken,
    ) -> Result<Option<KwtInventory>, HostError> {
        let Some(bundle) = self.config.kwt_bundle() else {
            return Ok(None);
        };
        self.require_runtime(endpoint, runtime, cancellation)?;
        let helper = self.ensure_kwt_helper(endpoint, runtime, bundle, cancellation)?;
        let projects = self.run_kwt(endpoint, &helper, &["projects", "--json"], cancellation)?;
        let worktrees = self.run_kwt(
            endpoint,
            &helper,
            &["list", "--global", "--json"],
            cancellation,
        )?;
        let directories = self.run_kwt(
            endpoint,
            &helper,
            &["workspace", "list", "--json"],
            cancellation,
        )?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        KwtInventory::parse(&projects.stdout, &worktrees.stdout, &directories.stdout)
            .map(Some)
            .map_err(|error| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    format!("KWT returned invalid project or worktree inventory: {error}"),
                )
            })
    }

    /// Resolve the current WSL instance and read only KWT inventory.
    ///
    /// This does not perform tmux admission, tmux discovery, or Herdr
    /// discovery, making it suitable for the independent worktree cadence.
    ///
    /// # Errors
    ///
    /// Returns a classified WSL, helper, command, or schema error.
    pub fn discover_kwt_current(
        &self,
        cancellation: &CancellationToken,
    ) -> Result<KwtHostSnapshot, HostError> {
        let endpoint = self.resolve_endpoint(cancellation)?;
        let runtime = self.resolve_runtime(&endpoint, cancellation)?;
        let inventory = self.discover_kwt(&endpoint, &runtime, cancellation)?;
        Ok(KwtHostSnapshot {
            endpoint,
            runtime,
            inventory,
        })
    }

    /// Register one explicit absolute repository path with the pinned KWT helper.
    ///
    /// Ghosthub never scans WSL or edits KWT configuration directly. The
    /// returned project is the helper's authoritative machine-readable record.
    ///
    /// # Errors
    ///
    /// Returns a classified path, helper, command, schema, or runtime error.
    pub fn register_kwt_project(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        project_path: &str,
        cancellation: &CancellationToken,
    ) -> Result<KwtProject, HostError> {
        let project_path = project_path.trim();
        if !is_project_path_input_absolute(project_path) {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                "Choose a project folder or enter an absolute Windows or WSL path.",
            ));
        }
        let bundle = self.config.kwt_bundle().ok_or_else(|| {
            HostError::new(
                DiagnosticKind::ExecutableNotFound,
                "The pinned KWT helper is unavailable in this build",
            )
        })?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        let helper = self.ensure_kwt_helper(endpoint, runtime, bundle, cancellation)?;
        let project_path = self.resolve_kwt_project_path(endpoint, project_path, cancellation)?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        let output = self.run_scrubbed(
            endpoint,
            &[&helper, "projects", "add", &project_path, "--json"],
            cancellation,
        )?;
        require_kwt_project_command(&output, "register the KWT project")?;
        let project = parse_project_mutation(&output.stdout, "registered").map_err(|error| {
            HostError::new(
                DiagnosticKind::MalformedOutput,
                format!("KWT returned an invalid project registration response: {error}"),
            )
        })?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        Ok(project)
    }

    fn resolve_kwt_project_path(
        &self,
        endpoint: &WslEndpoint,
        project_path: &str,
        cancellation: &CancellationToken,
    ) -> Result<String, HostError> {
        if let Some(path) = resolve_wsl_unc_project_path(endpoint, project_path)? {
            return Ok(path);
        }
        if is_posix_absolute(project_path) {
            return Ok(project_path.to_owned());
        }
        let output = self.run_scrubbed(
            endpoint,
            &["/usr/bin/wslpath", "-a", "-u", project_path],
            cancellation,
        )?;
        if output.status != 0 {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                format!(
                    "That Windows folder is not available in {} through WSL.",
                    endpoint.distro()
                ),
            ));
        }
        let stdout = decode(&output.stdout, "resolved WSL project path")?;
        let mut lines = stdout.lines();
        let resolved = lines.next().map(str::trim).unwrap_or_default();
        if !is_posix_absolute(resolved) || lines.any(|line| !line.trim().is_empty()) {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                "WSL returned an invalid project path",
            ));
        }
        Ok(resolved.to_owned())
    }

    /// Unregister one freshly revalidated project without deleting its checkout.
    ///
    /// KWT performs the final guarded compare-and-swap using both the exact
    /// persisted path and credential-free repository identity.
    ///
    /// # Errors
    ///
    /// Returns a classified error when identity changed, KWT refuses the
    /// removal, output is malformed, or the WSL runtime boundary moved.
    pub fn remove_kwt_project(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        expected_path: &str,
        expected_repository: &str,
        expected_registration: &str,
        cancellation: &CancellationToken,
    ) -> Result<KwtProject, HostError> {
        let bundle = self.config.kwt_bundle().ok_or_else(|| {
            HostError::new(
                DiagnosticKind::ExecutableNotFound,
                "The pinned KWT helper is unavailable in this build",
            )
        })?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        let helper = self.ensure_kwt_helper(endpoint, runtime, bundle, cancellation)?;
        let projects = self.run_kwt(endpoint, &helper, &["projects", "--json"], cancellation)?;
        let current: Vec<KwtProject> =
            serde_json::from_slice(&projects.stdout).map_err(|error| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    format!("KWT returned invalid project inventory before removal: {error}"),
                )
            })?;
        if !current.iter().any(|project| {
            project.path() == expected_path
                && project.repository() == expected_repository
                && project.registration_fingerprint() == expected_registration
        }) {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                "The project registration changed. Refresh and confirm removal again.",
            ));
        }
        self.require_runtime(endpoint, runtime, cancellation)?;
        let output = self.run_scrubbed(
            endpoint,
            &[
                &helper,
                "projects",
                "remove",
                expected_path,
                "--expected-repository",
                expected_repository,
                "--expected-registration",
                expected_registration,
                "--json",
            ],
            cancellation,
        )?;
        require_kwt_project_command(&output, "unregister the KWT project")?;
        let project = parse_project_mutation(&output.stdout, "unregistered").map_err(|error| {
            HostError::new(
                DiagnosticKind::MalformedOutput,
                format!("KWT returned an invalid project removal response: {error}"),
            )
        })?;
        if project.path() != expected_path || project.repository() != expected_repository {
            return Err(HostError::new(
                DiagnosticKind::MalformedOutput,
                "KWT removed a project other than the confirmed identity",
            ));
        }
        self.require_runtime(endpoint, runtime, cancellation)?;
        Ok(project)
    }

    fn ensure_kwt_helper(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        bundle: &KwtBundle,
        cancellation: &CancellationToken,
    ) -> Result<String, HostError> {
        let _activation = self
            .kwt_activation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let cached = self
            .verified_kwt
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|verified| verified.endpoint == *endpoint && verified.runtime == *runtime)
            .cloned();
        if let Some(verified) = cached {
            if self.kwt_helper_matches(endpoint, &verified.path, bundle, cancellation)? {
                self.require_runtime(endpoint, runtime, cancellation)?;
                return Ok(verified.path);
            }
            *self
                .verified_kwt
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
        }

        let home = self.resolve_home(endpoint, cancellation)?;
        let directory = format!("{home}/.ghosthub/helpers/kwt/{}", bundle.revision());
        let path = format!("{directory}/kwt");
        if !self.kwt_helper_matches(endpoint, &path, bundle, cancellation)? {
            self.install_kwt_helper(endpoint, &directory, &path, bundle, cancellation)?;
        }
        self.require_runtime(endpoint, runtime, cancellation)?;
        *self
            .verified_kwt
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(VerifiedKwtHelper {
            endpoint: endpoint.clone(),
            runtime: runtime.clone(),
            path: path.clone(),
        });
        Ok(path)
    }

    fn resolve_home(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
    ) -> Result<String, HostError> {
        let mut args = pinned_prefix(endpoint);
        args.push(OsString::from("/usr/bin/env"));
        let output = self.run(&args, cancellation)?;
        if output.status != 0 {
            return Err(classify_command_failure(
                output.status,
                &output.stderr,
                "resolve the WSL home directory",
            ));
        }
        let environment = decode(&output.stdout, "WSL environment")?;
        environment
            .lines()
            .find_map(|line| line.strip_prefix("HOME="))
            .filter(|home| is_posix_absolute(home))
            .map(str::to_owned)
            .ok_or_else(|| {
                HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "WSL HOME is missing or is not an absolute path",
                )
            })
    }

    fn install_kwt_helper(
        &self,
        endpoint: &WslEndpoint,
        directory: &str,
        path: &str,
        bundle: &KwtBundle,
        cancellation: &CancellationToken,
    ) -> Result<(), HostError> {
        let output = self.run_scrubbed(
            endpoint,
            &["/usr/bin/install", "-d", "-m", "0700", directory],
            cancellation,
        )?;
        require_kwt_command(&output, "create the managed KWT helper directory")?;

        let temp = format!("{path}.tmp-{}", helper_nonce()?);
        let upload = self.run_scrubbed_with_input(
            endpoint,
            &[
                "/usr/bin/dd",
                &format!("of={temp}"),
                "status=none",
                "conv=fsync",
            ],
            bundle.bytes(),
            cancellation,
        );
        let result = upload.and_then(|output| {
            require_kwt_command(&output, "upload the managed KWT helper")?;
            let chmod =
                self.run_scrubbed(endpoint, &["/usr/bin/chmod", "0755", &temp], cancellation)?;
            require_kwt_command(&chmod, "make the managed KWT helper executable")?;
            if !self.kwt_helper_matches(endpoint, &temp, bundle, cancellation)? {
                return Err(HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "uploaded KWT helper failed revision or digest verification",
                ));
            }
            let activate =
                self.run_scrubbed(endpoint, &["/usr/bin/mv", "-f", &temp, path], cancellation)?;
            require_kwt_command(&activate, "activate the managed KWT helper")?;
            if !self.kwt_helper_matches(endpoint, path, bundle, cancellation)? {
                return Err(HostError::new(
                    DiagnosticKind::MalformedOutput,
                    "activated KWT helper failed revision or digest verification",
                ));
            }
            Ok(())
        });
        if result.is_err() {
            let _ignored = self.run_scrubbed(
                endpoint,
                &["/usr/bin/rm", "-f", &temp],
                &CancellationToken::new(),
            );
        }
        result
    }

    fn kwt_helper_matches(
        &self,
        endpoint: &WslEndpoint,
        path: &str,
        bundle: &KwtBundle,
        cancellation: &CancellationToken,
    ) -> Result<bool, HostError> {
        let digest = self.run_scrubbed(endpoint, &["/usr/bin/sha256sum", path], cancellation)?;
        if digest.status != 0 {
            return Ok(false);
        }
        let digest = decode(&digest.stdout, "KWT helper digest")?;
        if digest.split_whitespace().next() != Some(bundle.sha256()) {
            return Ok(false);
        }
        let version = self.run_scrubbed(endpoint, &[path, "version"], cancellation)?;
        if version.status != 0 {
            return Ok(false);
        }
        let version = decode(&version.stdout, "KWT helper version")?;
        Ok(version.lines().next() == Some(&format!("kwt version {}", bundle.revision())))
    }

    fn run_kwt(
        &self,
        endpoint: &WslEndpoint,
        helper: &str,
        command: &[&str],
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, HostError> {
        let mut arguments = Vec::with_capacity(command.len() + 1);
        arguments.push(helper);
        arguments.extend_from_slice(command);
        let output = self.run_scrubbed(endpoint, &arguments, cancellation)?;
        if output.status == 0 {
            Ok(output)
        } else {
            Err(classify_kwt_command_failure(&output, "read KWT inventory"))
        }
    }

    /// Resolve the revision-pinned helper and build a re-runnable ordinary
    /// client for one exact KWT worktree.
    ///
    /// # Errors
    ///
    /// Returns an error when the helper cannot be verified for the captured
    /// WSL runtime.
    pub fn kwt_repair_or_open_plan(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        worktree_path: &str,
        session_name: &str,
        term: AttachTerm,
        cancellation: &CancellationToken,
    ) -> Result<RepairOrOpenPlan, HostError> {
        self.require_runtime(endpoint, runtime, cancellation)?;
        let bundle = self.config.kwt_bundle().ok_or_else(|| {
            HostError::new(
                DiagnosticKind::ExecutableNotFound,
                "the revision-pinned KWT helper is not bundled",
            )
        })?;
        let helper = self.ensure_kwt_helper(endpoint, runtime, bundle, cancellation)?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(
            &mut args,
            Some(term.environment()),
            self.config.tmux_tmpdir.as_deref(),
            &[],
        );
        args.extend(
            [helper.as_str(), "open", worktree_path]
                .into_iter()
                .map(OsString::from),
        );
        Ok(RepairOrOpenPlan::worktree(
            self.wsl_executable.as_os_str(),
            args,
            session_name,
        ))
    }

    /// List existing branch candidates for one freshly identified project.
    ///
    /// # Errors
    ///
    /// Returns an error when the project identity is stale, the managed helper
    /// cannot be verified, or KWT emits malformed machine-readable output.
    pub fn list_kwt_branches(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        project_path: &str,
        cancellation: &CancellationToken,
    ) -> Result<Vec<KwtBranchCandidate>, HostError> {
        self.require_runtime(endpoint, runtime, cancellation)?;
        let bundle = self.config.kwt_bundle().ok_or_else(|| {
            HostError::new(
                DiagnosticKind::ExecutableNotFound,
                "the revision-pinned KWT helper is not bundled",
            )
        })?;
        let helper = self.ensure_kwt_helper(endpoint, runtime, bundle, cancellation)?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        let output = self.run_kwt_in_directory(
            endpoint,
            &helper,
            project_path,
            &["branches", "--json"],
            cancellation,
        )?;
        if output.status != 0 {
            return Err(classify_command_failure(
                output.status,
                &output.stderr,
                "list KWT branches",
            ));
        }
        self.require_runtime(endpoint, runtime, cancellation)?;
        parse_branches(&output.stdout)
            .map_err(|error| HostError::new(DiagnosticKind::MalformedOutput, error.to_string()))
    }

    /// Create one KWT worktree without launching its tmux client.
    ///
    /// # Errors
    ///
    /// Returns an error when the project identity is stale, helper validation
    /// fails, or KWT rejects the requested branch operation.
    pub fn create_kwt_worktree(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        request: &KwtWorktreeCreate,
        cancellation: &CancellationToken,
    ) -> Result<(), HostError> {
        self.require_runtime(endpoint, runtime, cancellation)?;
        let bundle = self.config.kwt_bundle().ok_or_else(|| {
            HostError::new(
                DiagnosticKind::ExecutableNotFound,
                "the revision-pinned KWT helper is not bundled",
            )
        })?;
        let helper = self.ensure_kwt_helper(endpoint, runtime, bundle, cancellation)?;
        let mut command = vec!["add"];
        if request.creates_branch() {
            command.push("--branch");
        } else if let Some(source) = request
            .source()
            .filter(|source| *source != request.branch())
        {
            command.extend(["--from", source]);
        }
        command.extend([
            request.branch(),
            "--no-launch",
            "--expected-repository",
            request.repository(),
            "--expected-registration",
            request.registration_fingerprint(),
        ]);
        self.require_runtime(endpoint, runtime, cancellation)?;
        let output = self.run_kwt_in_directory(
            endpoint,
            &helper,
            request.project_path(),
            &command,
            cancellation,
        )?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        if output.status == 0 {
            Ok(())
        } else {
            Err(HostError::new(
                if output.status == 127 {
                    DiagnosticKind::ExecutableNotFound
                } else {
                    DiagnosticKind::Transport
                },
                parse_command_failure(&output.stdout).map_or_else(
                    || {
                        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
                        if detail.is_empty() {
                            "KWT could not create the worktree".to_owned()
                        } else {
                            detail
                        }
                    },
                    |failure| friendly_kwt_failure(&failure),
                ),
            ))
        }
    }

    /// Remove one exact KWT worktree while preserving its Git branch.
    ///
    /// KWT owns the filesystem and registry mutation. The expected generation
    /// prevents a stale inventory row from removing a replacement checkout at
    /// the same path.
    ///
    /// # Errors
    ///
    /// Returns an error when the WSL runtime changed, helper verification
    /// fails, or KWT rejects the exact path/generation pair.
    pub fn remove_kwt_worktree(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        project_path: &str,
        worktree_path: &str,
        generation: &str,
        cancellation: &CancellationToken,
    ) -> Result<(), HostError> {
        self.require_runtime(endpoint, runtime, cancellation)?;
        let bundle = self.config.kwt_bundle().ok_or_else(|| {
            HostError::new(
                DiagnosticKind::ExecutableNotFound,
                "the revision-pinned KWT helper is not bundled",
            )
        })?;
        let helper = self.ensure_kwt_helper(endpoint, runtime, bundle, cancellation)?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        let output = self.run_kwt_in_directory(
            endpoint,
            &helper,
            project_path,
            &["remove", "--if-generation", generation, worktree_path],
            cancellation,
        )?;
        self.require_runtime(endpoint, runtime, cancellation)?;
        if output.status == 0 {
            Ok(())
        } else {
            Err(HostError::new(
                if output.status == 127 {
                    DiagnosticKind::ExecutableNotFound
                } else {
                    DiagnosticKind::Transport
                },
                parse_command_failure(&output.stdout).map_or_else(
                    || {
                        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
                        if detail.is_empty() {
                            "KWT could not remove the worktree".to_owned()
                        } else {
                            detail
                        }
                    },
                    |failure| friendly_kwt_failure(&failure),
                ),
            ))
        }
    }

    fn run_kwt_in_directory(
        &self,
        endpoint: &WslEndpoint,
        helper: &str,
        directory: &str,
        command: &[&str],
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, HostError> {
        let mut args = pinned_prefix(endpoint);
        append_scrubbed_environment(&mut args);
        args.push(OsString::from("--chdir"));
        args.push(OsString::from(directory));
        if let Some(path) = self.config.tmux_tmpdir.as_deref() {
            args.push(OsString::from(format!("TMUX_TMPDIR={path}")));
        }
        args.push(OsString::from(helper));
        args.extend(command.iter().map(OsString::from));
        self.run(&args, cancellation)
    }

    fn run_scrubbed(
        &self,
        endpoint: &WslEndpoint,
        command: &[&str],
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, HostError> {
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(&mut args, None, self.config.tmux_tmpdir.as_deref(), &[]);
        args.extend(command.iter().map(OsString::from));
        self.run(&args, cancellation)
    }

    fn run_scrubbed_with_input(
        &self,
        endpoint: &WslEndpoint,
        command: &[&str],
        input: &[u8],
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, HostError> {
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(&mut args, None, self.config.tmux_tmpdir.as_deref(), &[]);
        args.extend(command.iter().map(OsString::from));
        self.runner
            .run_with_input(
                self.wsl_executable.as_os_str(),
                &args,
                input,
                cancellation,
                COMMAND_TIMEOUT,
            )
            .map_err(|error| classify_runner_error(&error))
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
            let creation_term = self.verify_tmux(&endpoint, &runtime, attacher, cancellation)?;
            let sessions = self.discover_sessions(&endpoint, cancellation)?;
            let herdr = self.discover_herdr(&endpoint, cancellation);
            let zellij = self.discover_zellij(&endpoint, cancellation);
            let observed_runtime = self.resolve_runtime(&endpoint, cancellation)?;
            if runtime == observed_runtime {
                return Ok(HostSnapshot {
                    endpoint,
                    runtime,
                    creation_term,
                    sessions,
                    herdr: Box::new(herdr),
                    zellij: Box::new(zellij),
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
    pub fn attach_plan(&self, endpoint: &WslEndpoint, session: &DiscoveredSession) -> AttachPlan {
        self.attach_plan_with_term(endpoint, session, AttachTerm::Xterm256Color)
    }

    /// Build an attach-only plan with an explicit terminal capability level.
    pub fn attach_plan_with_term(
        &self,
        endpoint: &WslEndpoint,
        session: &DiscoveredSession,
        term: AttachTerm,
    ) -> AttachPlan {
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

        AttachPlan::attach_only(
            self.wsl_executable.as_os_str(),
            args,
            session.name(),
            session.identity().clone(),
        )
    }

    /// Build an attach-only plan for one exact running Herdr session.
    #[must_use]
    pub fn herdr_attach_plan(
        &self,
        endpoint: &WslEndpoint,
        executable: &str,
        session: &HerdrSessionRecord,
        term: AttachTerm,
    ) -> HerdrAttachPlan {
        let mut args = pinned_prefix(endpoint);
        append_herdr_environment(&mut args);
        args.push(OsString::from(term.environment()));
        args.extend(
            [executable, "session", "attach", session.name()]
                .into_iter()
                .map(OsString::from),
        );
        HerdrAttachPlan::attach_only(self.wsl_executable.as_os_str(), args)
    }

    /// Build an attach-only plan for one freshly discovered active Zellij session.
    #[must_use]
    pub fn zellij_attach_plan(
        &self,
        endpoint: &WslEndpoint,
        executable: &str,
        session: &ZellijSessionRecord,
        term: AttachTerm,
    ) -> ZellijAttachPlan {
        let mut args = pinned_prefix(endpoint);
        append_zellij_environment(&mut args);
        args.push(OsString::from(term.environment()));
        args.extend(
            [executable, "attach", "--", session.name()]
                .into_iter()
                .map(OsString::from),
        );
        ZellijAttachPlan::attach_only(self.wsl_executable.as_os_str(), args)
    }

    /// Build one non-repeatable Zellij session creation client.
    #[must_use]
    pub fn zellij_launch_once(
        &self,
        endpoint: &WslEndpoint,
        executable: &str,
        name: ZellijSessionName,
        term: AttachTerm,
    ) -> ZellijLaunchOnce {
        let mut args = pinned_prefix(endpoint);
        append_zellij_environment(&mut args);
        args.push(OsString::from(term.environment()));
        args.push(OsString::from(executable));
        args.push(OsString::from(format!("--session={}", name.as_str())));
        ZellijLaunchOnce::create(self.wsl_executable.as_os_str(), args, name)
    }

    /// Revalidate and kill one exact active Zellij session.
    ///
    /// Zellij does not expose a stable session generation, so an exact
    /// same-name replacement remains a documented backend limitation. The
    /// runtime, executable, and active inventory are checked immediately
    /// before the destructive command.
    ///
    /// # Errors
    ///
    /// Returns a classified error when the WSL runtime, Zellij executable, or
    /// active session no longer matches confirmation, or when the direct kill
    /// command fails.
    pub fn kill_zellij_session(
        &self,
        endpoint: &WslEndpoint,
        expected_runtime: &WslRuntimeIdentity,
        expected_executable: &str,
        name: &str,
        cancellation: &CancellationToken,
        before_mutation: impl FnOnce(),
    ) -> Result<(), HostError> {
        self.validate_current_zellij_target(
            endpoint,
            expected_runtime,
            expected_executable,
            name,
            cancellation,
        )?;
        before_mutation();
        self.validate_current_zellij_target(
            endpoint,
            expected_runtime,
            expected_executable,
            name,
            cancellation,
        )?;

        let mut args = pinned_prefix(endpoint);
        append_zellij_environment(&mut args);
        args.extend(
            [expected_executable, "kill-session", "--", name]
                .into_iter()
                .map(OsString::from),
        );
        let output = self.run(&args, cancellation)?;
        if output.status != 0 {
            return Err(classify_command_failure(
                output.status,
                &output.stderr,
                "kill Zellij session",
            ));
        }
        self.require_runtime(endpoint, expected_runtime, cancellation)
    }

    fn validate_current_zellij_target(
        &self,
        endpoint: &WslEndpoint,
        expected_runtime: &WslRuntimeIdentity,
        expected_executable: &str,
        name: &str,
        cancellation: &CancellationToken,
    ) -> Result<(), HostError> {
        self.require_runtime(endpoint, expected_runtime, cancellation)?;
        let (executable, sessions) = match self.discover_zellij(endpoint, cancellation) {
            ZellijInventory::Available {
                executable,
                sessions,
            } => (executable, sessions),
            ZellijInventory::Unavailable => {
                return Err(HostError::new(
                    DiagnosticKind::ExecutableNotFound,
                    "Zellij is unavailable on this host",
                ));
            }
            ZellijInventory::Failed(error) => return Err(error),
        };
        if executable != expected_executable {
            return Err(HostError::new(
                DiagnosticKind::Transport,
                "the Zellij executable changed after kill confirmation",
            ));
        }
        if !sessions.iter().any(|session| session.name() == name) {
            return Err(HostError::new(
                DiagnosticKind::Transport,
                format!("Zellij session ‘{name}’ is no longer active"),
            ));
        }
        self.require_runtime(endpoint, expected_runtime, cancellation)
    }

    /// Build one Herdr launch-or-attach client. The returned authority is
    /// consumed by the terminal launcher and cannot be retried.
    #[must_use]
    pub fn herdr_launch_once(
        &self,
        endpoint: &WslEndpoint,
        executable: &str,
        name: HerdrLaunchTarget,
        is_default: bool,
        term: AttachTerm,
    ) -> HerdrLaunchOnce {
        let mut args = pinned_prefix(endpoint);
        append_herdr_environment(&mut args);
        args.push(OsString::from(term.environment()));
        args.push(OsString::from(executable));
        if !is_default {
            args.push(OsString::from("--session"));
            args.push(OsString::from(name.as_str()));
        }
        HerdrLaunchOnce::launch_or_attach(self.wsl_executable.as_os_str(), args, name)
    }

    /// Revalidate and execute one confirmed destructive Herdr lifecycle action.
    ///
    /// The current runtime, executable, default role, state, and configuration
    /// paths are captured immediately before mutation. Herdr does not expose a
    /// stable generation identity, so replacement that preserves all of those
    /// fields remains an accepted backend limitation.
    ///
    /// # Errors
    ///
    /// Returns a classified error when the endpoint changed, the current
    /// record no longer matches the confirmation, or Herdr rejects the action.
    pub fn mutate_herdr_session(
        &self,
        expected_host: (&WslEndpoint, &WslRuntimeIdentity),
        expected_executable: &str,
        confirmed: &HerdrSessionRecord,
        action: HerdrLifecycleAction,
        cancellation: &CancellationToken,
        before_mutation: impl FnOnce(),
    ) -> Result<HerdrSessionRecord, HostError> {
        let (endpoint, expected_runtime) = expected_host;
        self.validate_current_herdr_lifecycle_target(
            endpoint,
            expected_runtime,
            expected_executable,
            confirmed,
            action,
            cancellation,
        )?;

        before_mutation();

        self.validate_current_herdr_lifecycle_target(
            endpoint,
            expected_runtime,
            expected_executable,
            confirmed,
            action,
            cancellation,
        )?;
        self.require_runtime(endpoint, expected_runtime, cancellation)?;

        let mut args = pinned_prefix(endpoint);
        append_herdr_environment(&mut args);
        args.extend(
            [
                expected_executable,
                "session",
                action.command(),
                confirmed.name(),
                "--json",
            ]
            .into_iter()
            .map(OsString::from),
        );
        let output = self.run(&args, cancellation)?;
        if output.status != 0 {
            return Err(HostError::new(
                if output.status == 127 {
                    DiagnosticKind::ExecutableNotFound
                } else {
                    DiagnosticKind::Transport
                },
                herdr::lifecycle_error(&output.stdout, &output.stderr),
            ));
        }
        let record = herdr::parse_lifecycle(action, &output.stdout)
            .map_err(|detail| HostError::new(DiagnosticKind::MalformedOutput, detail))?;
        validate_herdr_lifecycle_response(confirmed, &record, action)?;
        let observed_runtime = self.resolve_runtime(endpoint, cancellation)?;
        if &observed_runtime != expected_runtime {
            return Err(HostError::new(
                DiagnosticKind::Transport,
                "WSL changed during the Herdr lifecycle action",
            ));
        }
        Ok(record)
    }

    fn validate_current_herdr_lifecycle_target(
        &self,
        endpoint: &WslEndpoint,
        expected_runtime: &WslRuntimeIdentity,
        expected_executable: &str,
        confirmed: &HerdrSessionRecord,
        action: HerdrLifecycleAction,
        cancellation: &CancellationToken,
    ) -> Result<(), HostError> {
        self.require_runtime(endpoint, expected_runtime, cancellation)?;
        let (executable, sessions) = match self.discover_herdr(endpoint, cancellation) {
            HerdrInventory::Available {
                executable,
                sessions,
            } => (executable, sessions),
            HerdrInventory::Unavailable => {
                return Err(HostError::new(
                    DiagnosticKind::ExecutableNotFound,
                    "Herdr is unavailable on this host",
                ));
            }
            HerdrInventory::Failed(error) => return Err(error),
        };
        if executable != expected_executable {
            return Err(HostError::new(
                DiagnosticKind::Transport,
                "the Herdr executable changed after lifecycle confirmation",
            ));
        }
        let current = sessions
            .iter()
            .find(|session| session.name() == confirmed.name())
            .ok_or_else(|| {
                HostError::new(
                    DiagnosticKind::Transport,
                    format!("Herdr session {} no longer exists", confirmed.name()),
                )
            })?;
        validate_herdr_lifecycle_target(confirmed, current, action)
    }

    /// Build one atomic local create-or-attach client for an already verified
    /// WSL endpoint. The returned authority cannot be cloned and must be
    /// consumed by the terminal launcher.
    ///
    /// # Errors
    ///
    /// Returns an error when this endpoint and runtime lack fresh admission,
    /// or when a collision-resistant identity marker cannot be generated for
    /// the ordinary client's tmux-side identity report.
    pub fn create_once(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        name: SessionName,
    ) -> Result<(CreateOnce, CreationReceipt, AttachTerm), HostError> {
        let term = self
            .verified_tmux
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|verified| {
                admission_matches(&verified.endpoint, &verified.runtime, endpoint, runtime)
            })
            .map(|verified| verified.creation_term)
            .ok_or_else(|| {
                HostError::new(
                    DiagnosticKind::UnsupportedEnvironment,
                    "tmux creation requires fresh admission for this WSL runtime",
                )
            })?;
        let (authority, receipt) = self.create_once_with_term(endpoint, name, term)?;
        Ok((authority, receipt, term))
    }

    fn create_once_with_term(
        &self,
        endpoint: &WslEndpoint,
        name: SessionName,
        term: AttachTerm,
    ) -> Result<(CreateOnce, CreationReceipt), HostError> {
        let receipt = creation_identity_receipt()?;
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(
            &mut args,
            Some(term.environment()),
            self.config.tmux_tmpdir.as_deref(),
            &[],
        );
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(
            ["new-session", "-A", "-E", "-s"]
                .into_iter()
                .map(OsString::from),
        );
        args.push(OsString::from(name.as_str()));
        args.extend([";", "run-shell", "-b"].into_iter().map(OsString::from));
        args.push(OsString::from(creation_receipt_command(&receipt)));
        Ok((
            CreateOnce::local_atomic(self.wsl_executable.as_os_str(), args, name),
            receipt,
        ))
    }

    /// Read the exact identity written by the consumed create-or-attach
    /// command queue without sending internal framing through `ConPTY`.
    ///
    /// # Errors
    ///
    /// Returns an error when the receipt is absent, malformed, or cannot be
    /// read before the bounded creation deadline.
    pub fn wait_for_creation_identity(
        &self,
        endpoint: &WslEndpoint,
        receipt: &CreationReceipt,
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> Result<SessionIdentity, HostError> {
        let deadline = Instant::now() + timeout;
        loop {
            if cancellation.is_cancelled() {
                self.remove_creation_receipt(endpoint, receipt);
                return Err(HostError::new(
                    DiagnosticKind::Transport,
                    "tmux creation identity wait was cancelled",
                ));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                self.remove_creation_receipt(endpoint, receipt);
                return Err(HostError::new(
                    DiagnosticKind::Timeout,
                    "timed out waiting for the ordinary tmux client identity",
                ));
            }
            let mut args = pinned_prefix(endpoint);
            args.extend(
                [
                    "/usr/bin/env",
                    "LC_ALL=C",
                    "/usr/bin/cat",
                    "--",
                    receipt.path.as_str(),
                ]
                .into_iter()
                .map(OsString::from),
            );
            let output = self
                .runner
                .run(
                    self.wsl_executable.as_os_str(),
                    &args,
                    cancellation,
                    remaining.min(COMMAND_TIMEOUT),
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
                })?;
            if output.status == 0 {
                self.remove_creation_receipt(endpoint, receipt);
                return parse_creation_receipt(&output.stdout);
            }
            if !is_missing_creation_receipt(&output.stderr) {
                self.remove_creation_receipt(endpoint, receipt);
                return Err(classify_command_failure(
                    output.status,
                    &output.stderr,
                    "read tmux creation identity",
                ));
            }
            if cancellation.wait_cancelled(Duration::from_millis(20)) {
                self.remove_creation_receipt(endpoint, receipt);
                return Err(HostError::new(
                    DiagnosticKind::Transport,
                    "tmux creation identity wait was cancelled",
                ));
            }
        }
    }

    fn remove_creation_receipt(&self, endpoint: &WslEndpoint, receipt: &CreationReceipt) {
        let mut args = pinned_prefix(endpoint);
        args.extend(
            [
                "/usr/bin/rm",
                "-f",
                "--",
                receipt.path.as_str(),
                receipt.staging_path.as_str(),
            ]
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

    /// Capture the exact inventory after a one-shot create client has started,
    /// without rerunning admission or creation.
    ///
    /// # Errors
    ///
    /// Returns a classified error when inventory cannot be read or the WSL
    /// runtime changed across the creation boundary.
    pub fn discover_after_create(
        &self,
        endpoint: &WslEndpoint,
        runtime: &WslRuntimeIdentity,
        creation_term: AttachTerm,
        herdr: &HerdrInventory,
        zellij: &ZellijInventory,
        cancellation: &CancellationToken,
    ) -> Result<HostSnapshot, HostError> {
        let sessions = self.discover_sessions(endpoint, cancellation)?;
        let observed_runtime = self.resolve_runtime(endpoint, cancellation)?;
        if &observed_runtime != runtime {
            return Err(HostError::new(
                DiagnosticKind::Transport,
                "WSL distro restarted while creating the tmux session",
            ));
        }
        Ok(HostSnapshot {
            endpoint: endpoint.clone(),
            runtime: observed_runtime,
            creation_term,
            sessions,
            herdr: Box::new(herdr.clone()),
            zellij: Box::new(zellij.clone()),
        })
    }

    /// Capture fresh destructive authority for one exact session.
    ///
    /// This deliberately does not accept a cached `SessionIdentity`. The WSL
    /// runtime is checked on both sides of the tmux query so a distro restart
    /// cannot launder an old inventory row into a confirmation.
    ///
    /// # Errors
    ///
    /// Returns a classified error when the runtime changed, the session is no
    /// longer running, or tmux returned an invalid identity.
    pub fn capture_live_session(
        &self,
        endpoint: &WslEndpoint,
        expected_runtime: &WslRuntimeIdentity,
        name: &str,
        cancellation: &CancellationToken,
    ) -> Result<LiveSessionTarget, HostError> {
        self.require_runtime(endpoint, expected_runtime, cancellation)?;
        let sessions = self.discover_sessions(endpoint, cancellation)?;
        let session = sessions
            .into_iter()
            .find(|session| session.name() == name)
            .ok_or_else(|| {
                HostError::new(
                    DiagnosticKind::Transport,
                    format!("Session ‘{name}’ is no longer running. Refresh before trying again."),
                )
            })?;
        self.require_runtime(endpoint, expected_runtime, cancellation)?;
        Ok(LiveSessionTarget {
            endpoint: endpoint.clone(),
            runtime: expected_runtime.clone(),
            name: session.name().to_owned(),
            identity: session.identity().clone(),
        })
    }

    /// Check whether one exact tmux session name is currently present.
    ///
    /// The WSL runtime is checked on both sides so a restart cannot turn an
    /// absence observation into authority over a replacement environment.
    ///
    /// # Errors
    ///
    /// Returns a classified discovery or runtime error.
    pub fn session_is_running(
        &self,
        endpoint: &WslEndpoint,
        expected_runtime: &WslRuntimeIdentity,
        name: &str,
        cancellation: &CancellationToken,
    ) -> Result<bool, HostError> {
        self.require_runtime(endpoint, expected_runtime, cancellation)?;
        let running = self
            .discover_sessions(endpoint, cancellation)?
            .iter()
            .any(|session| session.name() == name);
        self.require_runtime(endpoint, expected_runtime, cancellation)?;
        Ok(running)
    }

    /// Kill the exact session identity captured immediately before user
    /// confirmation.
    ///
    /// Tmux evaluates all three identity fields and performs the kill in one
    /// server-side command. A replaced session is never destroyed.
    ///
    /// # Errors
    ///
    /// Returns an error when the WSL runtime changed, the session disappeared,
    /// its identity no longer matches, or tmux could not execute the command.
    pub fn kill_live_session(
        &self,
        target: &LiveSessionTarget,
        cancellation: &CancellationToken,
    ) -> Result<(), HostError> {
        self.require_runtime(&target.endpoint, &target.runtime, cancellation)?;
        let identity = &target.identity;
        let tmux_target = format!("={}:", identity.session_id());
        let condition = tmux_identity_condition(identity);
        let kill = format!("kill-session -t ={}", identity.session_id());
        let mismatch = format!("display-message -p {KILL_IDENTITY_MISMATCH_MARKER}");
        let output = self.run_tmux_command(
            &target.endpoint,
            cancellation,
            &[
                "-f",
                "/dev/null",
                "if-shell",
                "-F",
                "-t",
                &tmux_target,
                &condition,
                &kill,
                &mismatch,
            ],
        )?;
        if output.status != 0 {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if is_no_server(&stderr) || is_missing_session(&stderr) {
                let sessions = self.discover_sessions(&target.endpoint, cancellation)?;
                self.require_runtime(&target.endpoint, &target.runtime, cancellation)?;
                if sessions.iter().any(|session| {
                    session.name() == target.name && session.identity() != &target.identity
                }) {
                    return Err(session_replaced_after_confirmation(&target.name));
                }
            }
            return Err(classify_session_command_failure(
                output.status,
                &output.stderr,
                &target.name,
                "kill",
            ));
        }
        if String::from_utf8_lossy(&output.stdout).contains(KILL_IDENTITY_MISMATCH_MARKER) {
            return Err(session_replaced_after_confirmation(&target.name));
        }
        Ok(())
    }

    fn require_runtime(
        &self,
        endpoint: &WslEndpoint,
        expected: &WslRuntimeIdentity,
        cancellation: &CancellationToken,
    ) -> Result<(), HostError> {
        if self.resolve_runtime(endpoint, cancellation)? == *expected {
            Ok(())
        } else {
            Err(HostError::new(
                DiagnosticKind::Transport,
                "WSL restarted; refresh the host before changing the session",
            ))
        }
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

    fn discover_herdr(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
    ) -> HerdrInventory {
        match self.resolve_herdr_executable(endpoint, cancellation) {
            Ok(ExecutableProbe::Available(executable)) => {
                self.list_herdr_sessions(endpoint, cancellation, executable)
            }
            Ok(ExecutableProbe::Unavailable) => HerdrInventory::Unavailable,
            Err(error) => HerdrInventory::Failed(error),
        }
    }

    fn discover_zellij(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
    ) -> ZellijInventory {
        match self.resolve_zellij_executable(endpoint, cancellation) {
            Ok(zellij::ExecutableProbe::Available(executable)) => {
                self.list_zellij_sessions(endpoint, cancellation, executable)
            }
            Ok(zellij::ExecutableProbe::Unavailable) => ZellijInventory::Unavailable,
            Err(error) => ZellijInventory::Failed(error),
        }
    }

    fn resolve_zellij_executable(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
    ) -> Result<zellij::ExecutableProbe, HostError> {
        let mut args = pinned_prefix(endpoint);
        args.extend(
            ["/bin/sh", "-lc", zellij::RESOLVE_SCRIPT]
                .into_iter()
                .map(OsString::from),
        );
        let output = self.run(&args, cancellation)?;
        if output.status != 0 && output.status != 127 {
            return Err(classify_command_failure(
                output.status,
                &output.stderr,
                "resolve Zellij executable",
            ));
        }
        zellij::parse_executable(output.status, &output.stdout)
            .map_err(|detail| HostError::new(DiagnosticKind::MalformedOutput, detail))
    }

    fn list_zellij_sessions(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        executable: String,
    ) -> ZellijInventory {
        let mut args = pinned_prefix(endpoint);
        append_zellij_environment(&mut args);
        args.extend(
            [executable.as_str(), "list-sessions", "--no-formatting"]
                .into_iter()
                .map(OsString::from),
        );
        let output = match self.run(&args, cancellation) {
            Ok(output) => output,
            Err(error) => return ZellijInventory::Failed(error),
        };
        if output.status == 127 {
            return ZellijInventory::Unavailable;
        }
        match zellij::parse_inventory(output.status, &output.stdout, &output.stderr) {
            Ok(sessions) => ZellijInventory::Available {
                executable,
                sessions,
            },
            Err(detail) => ZellijInventory::Failed(HostError::new(
                if output.status == 0 {
                    DiagnosticKind::MalformedOutput
                } else {
                    DiagnosticKind::Transport
                },
                detail,
            )),
        }
    }

    fn resolve_herdr_executable(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
    ) -> Result<ExecutableProbe, HostError> {
        let mut args = pinned_prefix(endpoint);
        args.extend(
            ["/bin/sh", "-lc", herdr::RESOLVE_SCRIPT]
                .into_iter()
                .map(OsString::from),
        );
        let output = self.run(&args, cancellation)?;
        if output.status != 0 && output.status != 127 {
            return Err(classify_command_failure(
                output.status,
                &output.stderr,
                "resolve Herdr executable",
            ));
        }
        herdr::parse_executable(output.status, &output.stdout)
            .map_err(|detail| HostError::new(DiagnosticKind::MalformedOutput, detail))
    }

    fn list_herdr_sessions(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        executable: String,
    ) -> HerdrInventory {
        let mut args = pinned_prefix(endpoint);
        append_herdr_environment(&mut args);
        args.extend(
            [executable.as_str(), "session", "list", "--json"]
                .into_iter()
                .map(OsString::from),
        );
        let output = match self.run(&args, cancellation) {
            Ok(output) => output,
            Err(error) => return HerdrInventory::Failed(error),
        };
        if output.status == 127 {
            return HerdrInventory::Unavailable;
        }
        if output.status != 0 {
            return HerdrInventory::Failed(classify_command_failure(
                output.status,
                &output.stderr,
                "list Herdr sessions",
            ));
        }
        match herdr::parse_inventory(&output.stdout) {
            Ok(sessions) => HerdrInventory::Available {
                executable,
                sessions,
            },
            Err(detail) => {
                HerdrInventory::Failed(HostError::new(DiagnosticKind::MalformedOutput, detail))
            }
        }
    }

    fn run_tmux_command(
        &self,
        endpoint: &WslEndpoint,
        cancellation: &CancellationToken,
        tmux_args: &[&str],
    ) -> Result<CommandOutput, HostError> {
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(
            &mut args,
            Some("TERM=xterm"),
            self.config.tmux_tmpdir.as_deref(),
            &[],
        );
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(tmux_args.iter().map(OsString::from));
        self.run(&args, cancellation)
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
    ) -> Result<AttachTerm, HostError> {
        if let Some(term) = self
            .verified_tmux
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|verified| {
                admission_matches(&verified.endpoint, &verified.runtime, endpoint, runtime)
            })
            .map(|verified| verified.creation_term)
        {
            return Ok(term);
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
        let new_session_environment = self.run_tmux_required(
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
        let (repeat_create_client, creation_term) = self.start_admission_create_client(
            endpoint,
            &admission_tmpdir,
            &namespace,
            &session,
            &target,
            attacher,
            cancellation,
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
        let create_preserved_value = self.run_tmux_required(
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
            "read atomic create-or-attach environment",
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
                    == "GHOSTHUB_PROBE=session"
                && decode(
                    &create_preserved_value.stdout,
                    "atomic create-or-attach environment",
                )?
                .trim()
                    == "GHOSTHUB_PROBE=session";
        let observations = [
            observation("atomic-create-or-attach", true),
            observation(
                "new-session-environment",
                String::from_utf8_lossy(&new_session_environment.stdout)
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
            endpoint: endpoint.clone(),
            runtime: runtime.clone(),
            creation_term,
            _binary: verified,
        });
        Ok(creation_term)
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
    ) -> Option<CommandOutput> {
        if timeout.is_zero() {
            return None;
        }
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(&mut args, None, Some(tmux_tmpdir), &[]);
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(tmux_args.iter().map(OsString::from));
        self.runner
            .run(
                self.wsl_executable.as_os_str(),
                &args,
                &CancellationToken::new(),
                timeout.min(CLEANUP_COMMAND_TIMEOUT),
            )
            .ok()
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
        term: AttachTerm,
    ) -> AdmissionPlan {
        let mut args = pinned_prefix(endpoint);
        append_tmux_environment(
            &mut args,
            Some(term.environment()),
            Some(tmux_tmpdir),
            &["GHOSTHUB_PROBE=ignored"],
        );
        args.push(OsString::from(&self.config.tmux_binary));
        args.extend(
            [
                "-f",
                "/dev/null",
                "-L",
                namespace,
                "new-session",
                "-A",
                "-E",
                "-s",
                session_name,
                "exec /usr/bin/sleep 60",
            ]
            .into_iter()
            .map(OsString::from),
        );
        AdmissionPlan::isolated(self.wsl_executable.as_os_str(), args)
    }

    #[allow(
        clippy::too_many_arguments,
        reason = "the admission client is bound to one private tmux target"
    )]
    fn start_admission_create_client<A: AdmissionAttacher>(
        &self,
        endpoint: &WslEndpoint,
        tmux_tmpdir: &str,
        namespace: &str,
        session_name: &str,
        target: &str,
        attacher: &A,
        cancellation: &CancellationToken,
    ) -> Result<(A::Client, AttachTerm), HostError> {
        let preferred_plan = self.admission_new_session_plan(
            endpoint,
            tmux_tmpdir,
            namespace,
            session_name,
            AttachTerm::Xterm256Color,
        );
        let preferred_failure = match attacher.attach(&preferred_plan) {
            Ok(client) => match self.wait_for_admission_attachment(
                endpoint,
                cancellation,
                tmux_tmpdir,
                namespace,
                target,
                true,
            ) {
                Ok(()) => return Ok((client, AttachTerm::Xterm256Color)),
                Err(error) => {
                    drop(client);
                    if cancellation.is_cancelled() {
                        return Err(error);
                    }
                    self.wait_for_admission_attachment(
                        endpoint,
                        cancellation,
                        tmux_tmpdir,
                        namespace,
                        target,
                        false,
                    )?;
                    error.to_string()
                }
            },
            Err(error) => error,
        };

        let baseline_plan = self.admission_new_session_plan(
            endpoint,
            tmux_tmpdir,
            namespace,
            session_name,
            AttachTerm::Xterm,
        );
        let client = attacher.attach(&baseline_plan).map_err(|error| {
            HostError::new(
                DiagnosticKind::Transport,
                format!(
                    "start atomic create-or-attach admission client: {error}; xterm-256color probe failed: {preferred_failure}"
                ),
            )
        })?;
        self.wait_for_admission_attachment(
            endpoint,
            cancellation,
            tmux_tmpdir,
            namespace,
            target,
            true,
        )?;
        Ok((client, AttachTerm::Xterm))
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

fn validate_herdr_lifecycle_target(
    confirmed: &HerdrSessionRecord,
    current: &HerdrSessionRecord,
    action: HerdrLifecycleAction,
) -> Result<(), HostError> {
    if action == HerdrLifecycleAction::Delete && current.is_default() {
        return Err(HostError::new(
            DiagnosticKind::UnsupportedEnvironment,
            "Herdr's current default session cannot be deleted",
        ));
    }
    if current.is_default() != confirmed.is_default() {
        return Err(HostError::new(
            DiagnosticKind::Transport,
            format!(
                "Herdr session {} changed its default role",
                confirmed.name()
            ),
        ));
    }
    if current.state() != action.expected_state() {
        let expected = match action.expected_state() {
            HerdrSessionState::Running => "running",
            HerdrSessionState::Stopped => "stopped",
        };
        return Err(HostError::new(
            DiagnosticKind::Transport,
            format!("Herdr session {} is no longer {expected}", confirmed.name()),
        ));
    }
    if current.session_directory() != confirmed.session_directory()
        || current.socket_path() != confirmed.socket_path()
    {
        return Err(HostError::new(
            DiagnosticKind::Transport,
            format!(
                "Herdr session {} moved to a different configuration",
                confirmed.name()
            ),
        ));
    }
    Ok(())
}

fn validate_herdr_lifecycle_response(
    confirmed: &HerdrSessionRecord,
    response: &HerdrSessionRecord,
    action: HerdrLifecycleAction,
) -> Result<(), HostError> {
    let same_identity = response.name() == confirmed.name()
        && response.is_default() == confirmed.is_default()
        && response.session_directory() == confirmed.session_directory()
        && response.socket_path() == confirmed.socket_path();
    if !same_identity || response.state() != HerdrSessionState::Stopped {
        return Err(HostError::new(
            DiagnosticKind::MalformedOutput,
            format!(
                "Herdr returned an inconsistent session record after {}",
                action.command()
            ),
        ));
    }
    Ok(())
}

fn admission_matches(
    verified_endpoint: &WslEndpoint,
    verified_runtime: &WslRuntimeIdentity,
    endpoint: &WslEndpoint,
    runtime: &WslRuntimeIdentity,
) -> bool {
    verified_endpoint == endpoint && verified_runtime == runtime
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

    fn terminate_mux_once(&self, budget: Duration) -> bool {
        let deadline = Instant::now() + budget;
        let mut namespaces = BTreeSet::new();
        if let Some(isolated_namespaces) = &self.isolated_namespaces {
            for namespace in isolated_namespaces {
                let _inserted = namespaces.insert(namespace.clone());
                let remaining = deadline.saturating_duration_since(Instant::now());
                let _output = self.host.run_tmux_cleanup(
                    self.endpoint,
                    &self.tmux_tmpdir,
                    &["-f", "/dev/null", "-L", namespace, "kill-server"],
                    remaining,
                );
            }
        } else {
            for (namespace, session) in &self.exact_sessions {
                let _inserted = namespaces.insert(namespace.clone());
                let target = format!("={session}");
                let remaining = deadline.saturating_duration_since(Instant::now());
                let _output = self.host.run_tmux_cleanup(
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
        namespaces.into_iter().all(|namespace| {
            let remaining = deadline.saturating_duration_since(Instant::now());
            self.host
                .run_tmux_cleanup(
                    self.endpoint,
                    &self.tmux_tmpdir,
                    &["-f", "/dev/null", "-L", &namespace, "list-sessions"],
                    remaining,
                )
                .is_some_and(|output| {
                    output.status != 0 && is_no_server(&String::from_utf8_lossy(&output.stderr))
                })
        })
    }
}

impl<R: CommandRunner> Drop for AdmissionCleanup<'_, R> {
    fn drop(&mut self) {
        let confirmed_absent = if self.server_creation_uncertain {
            let start = Instant::now();
            let mut confirmed_absent = false;
            settle_uncertain_cleanup(
                || start.elapsed(),
                thread::sleep,
                |remaining| confirmed_absent = self.terminate_mux_once(remaining),
            );
            confirmed_absent
        } else {
            let start = Instant::now();
            retry_cleanup_until_absent(
                || start.elapsed(),
                thread::sleep,
                |remaining| self.terminate_mux_once(remaining),
            )
        };
        // The socket root is the only route to a private server. Preserve it
        // whenever termination cannot be proved so a later cleanup can still
        // reach the process rather than stranding it behind an unlinked path.
        if confirmed_absent {
            self.host.remove_admission_tmpdir(
                self.endpoint,
                &self.tmux_tmpdir,
                self.creation_settled,
            );
        }
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

fn append_herdr_environment(args: &mut Vec<OsString>) {
    args.push(OsString::from("/usr/bin/env"));
    for variable in herdr::CONTROL_VARIABLES {
        args.push(OsString::from("-u"));
        args.push(OsString::from(variable));
    }
}

fn append_zellij_environment(args: &mut Vec<OsString>) {
    args.push(OsString::from("/usr/bin/env"));
    for variable in zellij::CONTROL_VARIABLES {
        args.push(OsString::from("-u"));
        args.push(OsString::from(variable));
    }
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

fn retry_cleanup_until_absent(
    mut elapsed: impl FnMut() -> Duration,
    mut wait: impl FnMut(Duration),
    mut cleanup: impl FnMut(Duration) -> bool,
) -> bool {
    loop {
        let remaining = UNCERTAIN_CLEANUP_SETTLE.saturating_sub(elapsed());
        if remaining.is_zero() {
            return false;
        }
        if cleanup(remaining) {
            return true;
        }
        let remaining = UNCERTAIN_CLEANUP_SETTLE.saturating_sub(elapsed());
        if remaining.is_zero() {
            return false;
        }
        wait(UNCERTAIN_CLEANUP_DELAY.min(remaining));
    }
}

struct AdmissionScope {
    tmpdir: String,
    name_nonce: String,
}

fn creation_identity_receipt() -> Result<CreationReceipt, HostError> {
    let mut nonce = [0_u8; 16];
    getrandom::fill(&mut nonce).map_err(|error| {
        HostError::new(
            DiagnosticKind::Transport,
            format!("generate tmux creation identity receipt: {error}"),
        )
    })?;
    let path = format!("/tmp/.ghosthub-create-{:032x}", u128::from_ne_bytes(nonce));
    Ok(CreationReceipt {
        staging_path: format!("{path}.tmp"),
        path,
    })
}

fn creation_receipt_command(receipt: &CreationReceipt) -> String {
    format!(
        "/bin/sh -c 'umask 077; set -C; /usr/bin/printf \"%s|%s|%s|!\" \"$1\" \"$2\" \"$3\" > \"$4\" && /usr/bin/mv -T -- \"$4\" \"$5\"' ghosthub-receipt '#{{pid}}' '#{{session_id}}' '#{{session_created}}' '{}' '{}'",
        receipt.staging_path, receipt.path
    )
}

fn parse_creation_receipt(bytes: &[u8]) -> Result<SessionIdentity, HostError> {
    let value = decode(bytes, "tmux creation identity")?
        .strip_suffix("|!")
        .ok_or_else(|| {
            HostError::new(
                DiagnosticKind::MalformedOutput,
                "tmux creation identity had invalid framing",
            )
        })?;
    let mut fields = value.split('|');
    let server_pid = fields
        .next()
        .and_then(|field| field.parse::<u32>().ok())
        .ok_or_else(|| {
            HostError::new(
                DiagnosticKind::MalformedOutput,
                "tmux creation identity had an invalid server PID",
            )
        })?;
    let session_id = fields
        .next()
        .filter(|field| !field.is_empty())
        .ok_or_else(|| {
            HostError::new(
                DiagnosticKind::MalformedOutput,
                "tmux creation identity had an empty session ID",
            )
        })?;
    let created_at = fields
        .next()
        .and_then(|field| field.parse::<u64>().ok())
        .ok_or_else(|| {
            HostError::new(
                DiagnosticKind::MalformedOutput,
                "tmux creation identity had an invalid creation time",
            )
        })?;
    if fields.next().is_some() {
        return Err(HostError::new(
            DiagnosticKind::MalformedOutput,
            "tmux creation identity had extra fields",
        ));
    }
    Ok(SessionIdentity::new(server_pid, session_id, created_at))
}

fn is_missing_creation_receipt(stderr: &[u8]) -> bool {
    String::from_utf8_lossy(stderr)
        .to_ascii_lowercase()
        .contains("no such file")
}

fn helper_nonce() -> Result<String, HostError> {
    let mut nonce = [0_u8; 16];
    getrandom::fill(&mut nonce).map_err(|error| {
        HostError::new(
            DiagnosticKind::Transport,
            format!("generate managed KWT helper name: {error}"),
        )
    })?;
    Ok(format!("{:032x}", u128::from_ne_bytes(nonce)))
}

fn require_kwt_command(output: &CommandOutput, subject: &str) -> Result<(), HostError> {
    if output.status == 0 {
        Ok(())
    } else {
        Err(classify_command_failure(
            output.status,
            &output.stderr,
            subject,
        ))
    }
}

fn require_kwt_project_command(output: &CommandOutput, subject: &str) -> Result<(), HostError> {
    if output.status == 0 {
        return Ok(());
    }
    if parse_command_failure(&output.stdout).is_some() {
        return Err(classify_kwt_command_failure(output, subject));
    }
    Err(classify_command_failure(
        output.status,
        &output.stderr,
        subject,
    ))
}

fn classify_kwt_command_failure(output: &CommandOutput, subject: &str) -> HostError {
    let Some(failure) = parse_command_failure(&output.stdout) else {
        return classify_command_failure(output.status, &output.stderr, subject);
    };
    HostError::new(
        if failure.code() == "inventory_timeout" {
            DiagnosticKind::Timeout
        } else {
            DiagnosticKind::Transport
        },
        friendly_kwt_failure(&failure),
    )
}

fn friendly_kwt_failure(failure: &crate::kwt::KwtCommandFailure) -> String {
    match failure.code() {
        "daemon_start_failed" => {
            "KWT's background service did not start. Ghosthub will retry automatically.".to_owned()
        }
        "daemon_draining" => {
            "KWT is finishing an update. Ghosthub will retry automatically.".to_owned()
        }
        _ => {
            let retry = if failure.retryable() {
                " Try again."
            } else {
                ""
            };
            format!("{}{retry}", failure.message())
        }
    }
}

fn classify_runner_error(error: &std::io::Error) -> HostError {
    HostError::new(
        if error.kind() == std::io::ErrorKind::TimedOut {
            DiagnosticKind::Timeout
        } else {
            DiagnosticKind::Transport
        },
        error.to_string(),
    )
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

fn classify_session_command_failure(
    status: i32,
    stderr: &[u8],
    session: &str,
    operation: &str,
) -> HostError {
    let text = String::from_utf8_lossy(stderr);
    if is_no_server(&text) || is_missing_session(&text) {
        return HostError::new(
            DiagnosticKind::Transport,
            format!("Session ‘{session}’ is no longer running."),
        );
    }
    classify_command_failure(
        status,
        stderr,
        &format!("{operation} tmux session ‘{session}’"),
    )
}

fn session_replaced_after_confirmation(session: &str) -> HostError {
    HostError::new(
        DiagnosticKind::Transport,
        format!(
            "Session ‘{session}’ was replaced after confirmation. Review the new session before trying again."
        ),
    )
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

fn is_project_path_input_absolute(path: &str) -> bool {
    if is_posix_absolute(path) || path.starts_with(r"\\") || path.starts_with("//") {
        return true;
    }
    let bytes = path.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/')
}

fn resolve_wsl_unc_project_path(
    endpoint: &WslEndpoint,
    path: &str,
) -> Result<Option<String>, HostError> {
    if !path.starts_with(r"\\") && !path.starts_with("//") {
        return Ok(None);
    }
    let normalized = path.replace('\\', "/");
    let mut components = normalized.trim_start_matches('/').split('/');
    let server = components.next().unwrap_or_default();
    if !server.eq_ignore_ascii_case("wsl.localhost") && !server.eq_ignore_ascii_case("wsl$") {
        return Ok(None);
    }
    let distro = components.next().unwrap_or_default();
    if distro.is_empty() || !distro.eq_ignore_ascii_case(endpoint.distro()) {
        return Err(HostError::new(
            DiagnosticKind::MalformedOutput,
            format!(
                "That folder belongs to WSL distro {distro:?}, but this host uses {}.",
                endpoint.distro()
            ),
        ));
    }
    let suffix = components.collect::<Vec<_>>().join("/");
    Ok(Some(if suffix.is_empty() {
        "/".to_owned()
    } else {
        format!("/{suffix}")
    }))
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

fn tmux_identity_condition(identity: &SessionIdentity) -> String {
    format!(
        "#{{&&:{},#{{&&:{},{}}}}}",
        tmux_identity_equals("pid", &identity.server_pid().to_string()),
        tmux_identity_equals("session_id", identity.session_id()),
        tmux_identity_equals("session_created", &identity.created_at().to_string()),
    )
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::ffi::{OsStr, OsString};
    use std::io;
    use std::sync::{Arc, Mutex, atomic::AtomicBool};

    use super::*;

    const TEST_RUNTIME_OUTPUT: &[u8] = b"Linux 6.6.0-WSL2\n12345678-1234-1234-1234-123456789abc\n1 (init) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 42\n";

    #[derive(Clone)]
    struct KwtMutationRunner {
        calls: Arc<Mutex<Vec<Vec<String>>>>,
        helper_matches: Arc<AtomicBool>,
    }

    impl Default for KwtMutationRunner {
        fn default() -> Self {
            Self {
                calls: Arc::default(),
                helper_matches: Arc::new(AtomicBool::new(true)),
            }
        }
    }

    impl CommandRunner for KwtMutationRunner {
        fn run(
            &self,
            _program: &OsStr,
            args: &[OsString],
            _cancellation: &CancellationToken,
            _timeout: Duration,
        ) -> io::Result<CommandOutput> {
            let args = args
                .iter()
                .map(|argument| argument.to_string_lossy().into_owned())
                .collect::<Vec<_>>();
            self.calls.lock().expect("calls").push(args.clone());
            if args
                .windows(2)
                .any(|pair| pair == ["--expected-registration", "replacement-registration"])
            {
                return Ok(CommandOutput {
                    status: 1,
                    stdout: br#"{"error":{"code":"registration_changed","message":"the project registration changed before the operation began","retryable":true}}"#.to_vec(),
                    stderr: Vec::new(),
                });
            }
            let stdout = if args.iter().any(|argument| argument == "/usr/bin/cat") {
                TEST_RUNTIME_OUTPUT.to_vec()
            } else if args.iter().any(|argument| argument == "/usr/bin/sha256sum") {
                let digest = if self.helper_matches.load(Ordering::Acquire) {
                    "b".repeat(64)
                } else {
                    "c".repeat(64)
                };
                format!("{digest}  helper\n").into_bytes()
            } else if args.last().is_some_and(|argument| argument == "version") {
                format!("kwt version {}\n", "a".repeat(40)).into_bytes()
            } else if args
                .last()
                .is_some_and(|argument| argument == "/usr/bin/env")
            {
                b"HOME=/home/test\n".to_vec()
            } else if args.iter().any(|argument| argument == "/usr/bin/wslpath") {
                b"/mnt/c/Users/test/code/widget\n".to_vec()
            } else if args.windows(2).any(|pair| pair == ["projects", "add"]) {
                br#"{"status":"registered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"opaque-registration"}}"#.to_vec()
            } else if args.windows(2).any(|pair| pair == ["projects", "remove"]) {
                br#"{"status":"unregistered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"opaque-registration"}}"#.to_vec()
            } else if args.windows(2).any(|pair| pair == ["branches", "--json"]) {
                br#"[{"name":"feature/ready","label":"feature/ready","source":"origin/feature/ready","is_current":false,"is_remote":true,"last_commit":{"hash":"abc","message":"ready","author":"A","date":"2026-01-01T00:00:00Z"}}]"#.to_vec()
            } else if (args.iter().any(|argument| argument == "add")
                && args.iter().any(|argument| argument == "--no-launch"))
                || (args.iter().any(|argument| argument == "remove")
                    && args.iter().any(|argument| argument == "--if-generation"))
            {
                Vec::new()
            } else if args.iter().any(|argument| argument == "projects") {
                br#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"opaque-registration"}]"#.to_vec()
            } else if args.iter().any(|argument| {
                matches!(
                    argument.as_str(),
                    "/usr/bin/install"
                        | "/usr/bin/dd"
                        | "/usr/bin/chmod"
                        | "/usr/bin/mv"
                        | "/usr/bin/rm"
                )
            }) {
                Vec::new()
            } else {
                return Err(io::Error::other(format!(
                    "unexpected KWT mutation command: {args:?}"
                )));
            };
            Ok(CommandOutput {
                status: 0,
                stdout,
                stderr: Vec::new(),
            })
        }

        fn run_with_input(
            &self,
            program: &OsStr,
            args: &[OsString],
            _input: &[u8],
            cancellation: &CancellationToken,
            timeout: Duration,
        ) -> io::Result<CommandOutput> {
            self.helper_matches.store(true, Ordering::Release);
            self.run(program, args, cancellation, timeout)
        }
    }

    fn kwt_mutation_host() -> (
        WslHost<KwtMutationRunner>,
        KwtMutationRunner,
        WslEndpoint,
        WslRuntimeIdentity,
    ) {
        kwt_mutation_host_with_config(WslConfig::with_distro("Ubuntu").expect("config"))
    }

    fn kwt_mutation_host_with_config(
        config: WslConfig,
    ) -> (
        WslHost<KwtMutationRunner>,
        KwtMutationRunner,
        WslEndpoint,
        WslRuntimeIdentity,
    ) {
        let runner = KwtMutationRunner::default();
        let endpoint = WslEndpoint {
            distro: "Ubuntu".to_owned(),
        };
        let runtime = WslRuntimeIdentity {
            kernel_boot_id: "12345678-1234-1234-1234-123456789abc".to_owned(),
            init_start_ticks: 42,
        };
        let bundle =
            KwtBundle::new("a".repeat(40), "b".repeat(64), vec![1_u8]).expect("valid bundle");
        let host = WslHost::new(
            config.with_kwt_bundle(bundle),
            runner.clone(),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("WSL path"),
        );
        *host.verified_kwt.lock().expect("verified KWT") = Some(VerifiedKwtHelper {
            endpoint: endpoint.clone(),
            runtime: runtime.clone(),
            path: "/home/test/.ghosthub/helpers/kwt/revision/kwt".to_owned(),
        });
        (host, runner, endpoint, runtime)
    }

    #[test]
    fn kwt_project_mutations_use_exact_machine_readable_arguments() {
        let (host, runner, endpoint, runtime) = kwt_mutation_host();
        let cancellation = CancellationToken::new();
        let registered = host
            .register_kwt_project(&endpoint, &runtime, "/code/widget", &cancellation)
            .expect("register project");
        assert_eq!(registered.repository(), "github.com/acme/widget");
        let removed = host
            .remove_kwt_project(
                &endpoint,
                &runtime,
                "/code/widget",
                "github.com/acme/widget",
                "opaque-registration",
                &cancellation,
            )
            .expect("remove project");
        assert_eq!(removed.path(), "/code/widget");

        let calls = runner.calls.lock().expect("calls");
        assert!(calls.iter().any(|args| {
            args.ends_with(&[
                "projects".to_owned(),
                "add".to_owned(),
                "/code/widget".to_owned(),
                "--json".to_owned(),
            ])
        }));
        assert!(calls.iter().any(|args| {
            args.ends_with(&[
                "projects".to_owned(),
                "remove".to_owned(),
                "/code/widget".to_owned(),
                "--expected-repository".to_owned(),
                "github.com/acme/widget".to_owned(),
                "--expected-registration".to_owned(),
                "opaque-registration".to_owned(),
                "--json".to_owned(),
            ])
        }));
    }

    #[test]
    fn kwt_commands_use_the_configured_tmux_socket_directory() {
        let config = WslConfig::configured(
            Some("Ubuntu".to_owned()),
            "/usr/bin/tmux",
            Some("/run/user/1000/ghosthub".to_owned()),
        )
        .expect("configured socket directory");
        let (host, runner, endpoint, runtime) = kwt_mutation_host_with_config(config);

        host.register_kwt_project(
            &endpoint,
            &runtime,
            "/code/widget",
            &CancellationToken::new(),
        )
        .expect("register project through configured tmux namespace");

        let calls = runner.calls.lock().expect("calls");
        assert!(calls.iter().any(|args| {
            args.windows(2).any(|pair| pair == ["projects", "add"])
                && args
                    .iter()
                    .any(|argument| argument == "TMUX_TMPDIR=/run/user/1000/ghosthub")
        }));
    }

    #[test]
    fn kwt_worktree_commands_use_exact_project_directory_and_no_launch() {
        let (host, runner, endpoint, runtime) = kwt_mutation_host();
        let cancellation = CancellationToken::new();

        let branches = host
            .list_kwt_branches(&endpoint, &runtime, "/code/widget", &cancellation)
            .expect("list branch candidates");
        assert_eq!(branches[0].name(), "feature/ready");
        assert_eq!(branches[0].source(), "origin/feature/ready");
        host.create_kwt_worktree(
            &endpoint,
            &runtime,
            &KwtWorktreeCreate::new(
                "/code/widget",
                "github.com/acme/widget",
                "opaque-registration",
                "feature/ready",
                Some("origin/feature/ready".to_owned()),
                false,
            ),
            &cancellation,
        )
        .expect("create existing remote branch worktree");
        host.remove_kwt_worktree(
            &endpoint,
            &runtime,
            "/code/widget",
            "/work/widget/feature-ready",
            "0123456789abcdef0123456789abcdef",
            &cancellation,
        )
        .expect("remove exact worktree while preserving its branch");

        let calls = runner.calls.lock().expect("calls");
        assert!(calls.iter().any(|args| {
            args.windows(2).any(|pair| pair == ["branches", "--json"])
                && args
                    .windows(2)
                    .any(|pair| pair == ["--chdir", "/code/widget"])
        }));
        assert!(calls.iter().any(|args| {
            args.ends_with(&[
                "add".to_owned(),
                "--from".to_owned(),
                "origin/feature/ready".to_owned(),
                "feature/ready".to_owned(),
                "--no-launch".to_owned(),
                "--expected-repository".to_owned(),
                "github.com/acme/widget".to_owned(),
                "--expected-registration".to_owned(),
                "opaque-registration".to_owned(),
            ]) && args
                .windows(2)
                .any(|pair| pair == ["--chdir", "/code/widget"])
        }));
        assert!(calls.iter().any(|args| {
            args.ends_with(&[
                "remove".to_owned(),
                "--if-generation".to_owned(),
                "0123456789abcdef0123456789abcdef".to_owned(),
                "/work/widget/feature-ready".to_owned(),
            ]) && args
                .windows(2)
                .any(|pair| pair == ["--chdir", "/code/widget"])
        }));
    }

    #[test]
    fn kwt_worktree_creation_rejects_a_changed_project_registration_before_add() {
        let (host, runner, endpoint, runtime) = kwt_mutation_host();
        let error = host
            .create_kwt_worktree(
                &endpoint,
                &runtime,
                &KwtWorktreeCreate::new(
                    "/code/widget",
                    "github.com/acme/widget",
                    "replacement-registration",
                    "feature/ready",
                    Some("origin/feature/ready".to_owned()),
                    false,
                ),
                &CancellationToken::new(),
            )
            .expect_err("a stale project registration must not grant mutation authority");

        assert!(error.to_string().contains("registration changed"));
        assert!(runner.calls.lock().expect("calls").iter().any(|args| {
            args.windows(2)
                .any(|pair| pair == ["--expected-registration", "replacement-registration"])
        }));
    }

    #[test]
    fn kwt_open_plan_is_re_runnable_and_uses_the_pinned_helper() {
        let (host, _runner, endpoint, runtime) = kwt_mutation_host();
        let plan = host
            .kwt_repair_or_open_plan(
                &endpoint,
                &runtime,
                "/work/widget/topic",
                "widget-topic",
                AttachTerm::Xterm256Color,
                &CancellationToken::new(),
            )
            .expect("build worktree open plan");
        let args = plan
            .args()
            .iter()
            .map(|argument| argument.to_string_lossy())
            .collect::<Vec<_>>();
        assert!(args.windows(3).any(|args| {
            args == [
                "/home/test/.ghosthub/helpers/kwt/revision/kwt",
                "open",
                "/work/widget/topic",
            ]
        }));
        assert!(
            args.iter()
                .any(|argument| argument == "TERM=xterm-256color")
        );
        assert_eq!(plan.target_name(), "widget-topic");
        assert_eq!(plan.clone(), plan);
    }

    #[test]
    fn cached_kwt_helper_is_revalidated_and_repaired_before_execution() {
        let (host, runner, endpoint, runtime) = kwt_mutation_host();
        runner.helper_matches.store(false, Ordering::Release);

        host.register_kwt_project(
            &endpoint,
            &runtime,
            "/code/widget",
            &CancellationToken::new(),
        )
        .expect("replace the stale helper before project execution");

        let calls = runner.calls.lock().expect("calls");
        let digest_check = calls
            .iter()
            .position(|args| args.iter().any(|argument| argument == "/usr/bin/sha256sum"))
            .expect("cached helper digest is checked");
        let upload = calls
            .iter()
            .position(|args| args.iter().any(|argument| argument == "/usr/bin/dd"))
            .expect("stale helper is reinstalled");
        let project_command = calls
            .iter()
            .position(|args| args.windows(2).any(|pair| pair == ["projects", "add"]))
            .expect("project command executes after repair");
        assert!(digest_check < upload && upload < project_command);
    }

    #[test]
    fn kwt_project_registration_resolves_windows_paths_inside_the_distro() {
        let (host, runner, endpoint, runtime) = kwt_mutation_host();
        let cancellation = CancellationToken::new();

        host.register_kwt_project(
            &endpoint,
            &runtime,
            r"C:\Users\test\code\widget",
            &cancellation,
        )
        .expect("register Windows project path");

        let calls = runner.calls.lock().expect("calls");
        assert!(calls.iter().any(|args| {
            args.ends_with(&[
                "/usr/bin/wslpath".to_owned(),
                "-a".to_owned(),
                "-u".to_owned(),
                r"C:\Users\test\code\widget".to_owned(),
            ])
        }));
        assert!(calls.iter().any(|args| {
            args.ends_with(&[
                "projects".to_owned(),
                "add".to_owned(),
                "/mnt/c/Users/test/code/widget".to_owned(),
                "--json".to_owned(),
            ])
        }));
    }

    #[test]
    fn kwt_project_registration_maps_the_selected_distros_unc_path_directly() {
        let (host, runner, endpoint, runtime) = kwt_mutation_host();
        let cancellation = CancellationToken::new();

        for path in [
            r"\\wsl.localhost\Ubuntu\home\test\code\widget",
            "//wsl.localhost/Ubuntu/home/test/code/widget",
        ] {
            host.register_kwt_project(&endpoint, &runtime, path, &cancellation)
                .expect("register WSL UNC project path");
        }

        let calls = runner.calls.lock().expect("calls");
        assert!(
            !calls
                .iter()
                .any(|args| { args.iter().any(|argument| argument == "/usr/bin/wslpath") })
        );
        assert_eq!(
            calls
                .iter()
                .filter(|args| {
                    args.ends_with(&[
                        "projects".to_owned(),
                        "add".to_owned(),
                        "/home/test/code/widget".to_owned(),
                        "--json".to_owned(),
                    ])
                })
                .count(),
            2
        );
    }

    #[test]
    fn kwt_project_registration_rejects_a_different_distros_unc_path() {
        let (host, _runner, endpoint, runtime) = kwt_mutation_host();
        let cancellation = CancellationToken::new();

        for path in [
            r"\\wsl.localhost\Debian\home\test\code\widget",
            "//wsl.localhost/Debian/home/test/code/widget",
        ] {
            let error = host
                .register_kwt_project(&endpoint, &runtime, path, &cancellation)
                .expect_err("a WSL UNC path cannot cross distro identity");

            assert_eq!(error.kind(), DiagnosticKind::MalformedOutput);
            assert!(error.to_string().contains("this host uses Ubuntu"));
        }
    }

    #[test]
    fn kwt_daemon_start_failures_are_actionable_and_hide_internal_cli_context() {
        let output = CommandOutput {
            status: 1,
            stdout: br#"{"error":{"code":"daemon_start_failed","message":"kwt daemon did not become ready","retryable":true}}"#.to_vec(),
            stderr: b"kwt projects: daemon_start_failed: kwt daemon did not become ready\n"
                .to_vec(),
        };

        let error = classify_kwt_command_failure(&output, "read KWT inventory");

        assert_eq!(error.kind(), DiagnosticKind::Transport);
        assert_eq!(
            error.to_string(),
            "KWT's background service did not start. Ghosthub will retry automatically."
        );
        assert!(!error.to_string().contains("daemon_start_failed"));
        assert!(!error.to_string().contains("kwt projects"));
    }

    #[test]
    fn authoritative_herdr_lifecycle_updates_only_the_target_session() {
        let running = HerdrSessionRecord::new(
            "work",
            false,
            HerdrSessionState::Running,
            "/tmp/work",
            "/tmp/work.sock",
        );
        let other = HerdrSessionRecord::new(
            "other",
            false,
            HerdrSessionState::Running,
            "/tmp/other",
            "/tmp/other.sock",
        );
        let snapshot = HostSnapshot {
            endpoint: WslEndpoint {
                distro: "Ubuntu".to_owned(),
            },
            runtime: WslRuntimeIdentity {
                kernel_boot_id: "boot".to_owned(),
                init_start_ticks: 1,
            },
            creation_term: AttachTerm::Xterm256Color,
            sessions: Vec::new(),
            herdr: Box::new(HerdrInventory::Available {
                executable: "/usr/bin/herdr".to_owned(),
                sessions: vec![running.clone(), other.clone()],
            }),
            zellij: Box::new(ZellijInventory::Unavailable),
        };
        let stopped = HerdrSessionRecord::new(
            "work",
            false,
            HerdrSessionState::Stopped,
            "/tmp/work",
            "/tmp/work.sock",
        );

        let stopped_snapshot = snapshot
            .with_herdr_lifecycle(
                HerdrLifecycleAction::Stop,
                "/usr/bin/herdr",
                &running,
                stopped.clone(),
            )
            .expect("stop response applies");
        assert_eq!(
            stopped_snapshot.herdr().sessions(),
            &[stopped, other.clone()]
        );

        let deleted_snapshot = stopped_snapshot
            .with_herdr_lifecycle(
                HerdrLifecycleAction::Delete,
                "/usr/bin/herdr",
                &other,
                other.clone(),
            )
            .expect("delete response applies");
        assert_eq!(deleted_snapshot.herdr().sessions().len(), 1);
        assert_eq!(deleted_snapshot.herdr().sessions()[0].name(), "work");
    }

    #[test]
    fn lifecycle_publication_rejects_changed_inventory_identity() {
        let confirmed = HerdrSessionRecord::new(
            "work",
            false,
            HerdrSessionState::Running,
            "/tmp/work",
            "/tmp/work.sock",
        );
        let stopped = HerdrSessionRecord::new(
            "work",
            false,
            HerdrSessionState::Stopped,
            "/tmp/work",
            "/tmp/work.sock",
        );
        let snapshot = |executable: &str, session: HerdrSessionRecord| HostSnapshot {
            endpoint: WslEndpoint {
                distro: "Ubuntu".to_owned(),
            },
            runtime: WslRuntimeIdentity {
                kernel_boot_id: "boot".to_owned(),
                init_start_ticks: 1,
            },
            creation_term: AttachTerm::Xterm256Color,
            sessions: Vec::new(),
            herdr: Box::new(HerdrInventory::Available {
                executable: executable.to_owned(),
                sessions: vec![session],
            }),
            zellij: Box::new(ZellijInventory::Unavailable),
        };
        let replacement = HerdrSessionRecord::new(
            "work",
            false,
            HerdrSessionState::Running,
            "/tmp/replacement",
            "/tmp/replacement.sock",
        );

        assert!(
            snapshot("/opt/herdr-v2", confirmed.clone())
                .with_herdr_lifecycle(
                    HerdrLifecycleAction::Stop,
                    "/usr/bin/herdr",
                    &confirmed,
                    stopped.clone(),
                )
                .is_none()
        );
        assert!(
            snapshot("/usr/bin/herdr", replacement)
                .with_herdr_lifecycle(
                    HerdrLifecycleAction::Stop,
                    "/usr/bin/herdr",
                    &confirmed,
                    stopped.clone(),
                )
                .is_none()
        );
        assert!(
            snapshot("/usr/bin/herdr", stopped.clone())
                .with_herdr_lifecycle(
                    HerdrLifecycleAction::Stop,
                    "/usr/bin/herdr",
                    &confirmed,
                    stopped,
                )
                .is_none()
        );
    }

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
    fn cached_admission_requires_the_same_endpoint_and_runtime() {
        let ubuntu = WslEndpoint {
            distro: "Ubuntu".to_owned(),
        };
        let debian = WslEndpoint {
            distro: "Debian".to_owned(),
        };
        let runtime = WslRuntimeIdentity {
            kernel_boot_id: "shared-wsl-kernel".to_owned(),
            init_start_ticks: 42,
        };
        let restarted = WslRuntimeIdentity {
            kernel_boot_id: "shared-wsl-kernel".to_owned(),
            init_start_ticks: 43,
        };

        assert!(admission_matches(&ubuntu, &runtime, &ubuntu, &runtime));
        assert!(!admission_matches(&ubuntu, &runtime, &debian, &runtime));
        assert!(!admission_matches(&ubuntu, &runtime, &ubuntu, &restarted));
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

    #[test]
    fn local_creation_is_one_atomic_scrubbed_client_command() {
        let host = WslHost::new(
            WslConfig::configured(
                Some("Ubuntu Work".to_owned()),
                "/opt/tmux/bin/tmux",
                Some("/run/user/1000/ghosthub".to_owned()),
            )
            .expect("valid config"),
            crate::StdCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let endpoint = WslEndpoint {
            distro: "Ubuntu Work".to_owned(),
        };
        let (plan, receipt) = host
            .create_once_with_term(
                &endpoint,
                SessionName::parse("release work").expect("valid name"),
                AttachTerm::Xterm256Color,
            )
            .expect("creation plan");
        let (program, args, target) = plan.into_parts();

        assert_eq!(program, r"C:\Windows\System32\wsl.exe");
        assert_eq!(target.as_str(), "release work");
        assert_eq!(
            args,
            [
                "--distribution",
                "Ubuntu Work",
                "--exec",
                "/usr/bin/env",
                "-u",
                "TMUX",
                "-u",
                "TMUX_PANE",
                "-u",
                "TMUX_TMPDIR",
                "TERM=xterm-256color",
                "TMUX_TMPDIR=/run/user/1000/ghosthub",
                "/opt/tmux/bin/tmux",
                "new-session",
                "-A",
                "-E",
                "-s",
                "release work",
                ";",
                "run-shell",
                "-b",
            ]
            .into_iter()
            .map(OsString::from)
            .chain([OsString::from(format!(
                "/bin/sh -c 'umask 077; set -C; /usr/bin/printf \"%s|%s|%s|!\" \"$1\" \"$2\" \"$3\" > \"$4\" && /usr/bin/mv -T -- \"$4\" \"$5\"' ghosthub-receipt '#{{pid}}' '#{{session_id}}' '#{{session_created}}' '{}' '{}'",
                receipt.staging_path, receipt.path
            ))])
            .collect::<Vec<_>>()
        );
        assert!(receipt.path.starts_with("/tmp/.ghosthub-create-"));
        assert_eq!(receipt.staging_path, format!("{}.tmp", receipt.path));
    }

    #[test]
    fn herdr_launch_is_one_scrubbed_argv_only_client_command() {
        let host = WslHost::new(
            WslConfig::with_distro("Ubuntu Work").expect("valid config"),
            crate::StdCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let endpoint = WslEndpoint {
            distro: "Ubuntu Work".to_owned(),
        };
        let plan = host.herdr_launch_once(
            &endpoint,
            "/home/test/.local/bin/herdr",
            HerdrLaunchTarget::created(
                session::HerdrSessionName::parse("review.fix_1").expect("valid name"),
            ),
            false,
            AttachTerm::Xterm256Color,
        );
        let (program, args, target) = plan.into_parts();

        assert_eq!(program, r"C:\Windows\System32\wsl.exe");
        assert_eq!(target.as_str(), "review.fix_1");
        assert_eq!(
            args.first().and_then(|value| value.to_str()),
            Some("--distribution")
        );
        assert!(args.windows(2).any(|pair| pair == ["-u", "HERDR_ENV"]));
        assert!(
            args.windows(2)
                .any(|pair| pair == ["-u", "HERDR_ACTIVE_PANE_CWD"])
        );
        assert!(args.iter().any(|arg| arg == "TERM=xterm-256color"));
        assert_eq!(
            args.iter()
                .rev()
                .take(3)
                .rev()
                .map(OsString::as_os_str)
                .collect::<Vec<_>>(),
            [
                OsStr::new("/home/test/.local/bin/herdr"),
                OsStr::new("--session"),
                OsStr::new("review.fix_1"),
            ]
        );

        let baseline = host.herdr_launch_once(
            &endpoint,
            "/home/test/.local/bin/herdr",
            HerdrLaunchTarget::created(
                session::HerdrSessionName::parse("baseline").expect("valid name"),
            ),
            false,
            AttachTerm::Xterm,
        );
        let (_, baseline_args, _) = baseline.into_parts();
        assert!(baseline_args.iter().any(|arg| arg == "TERM=xterm"));
        assert!(!baseline_args.iter().any(|arg| arg == "TERM=xterm-256color"));
    }
}
