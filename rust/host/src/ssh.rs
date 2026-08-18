use std::ffi::{OsStr, OsString};
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::command_process::{self, CommandContainment};
use crate::kwt::parse_command_failure;
use crate::{CancellationToken, CommandPrefix, CommandRunner, KwtBundle};
use model::DiagnosticKind;

const ROUTE_TIMEOUT: Duration = Duration::from_secs(30);
const LEASE_INACTIVITY_TIMEOUT: Duration = Duration::from_secs(30);
const LEASE_RELEASE_TIMEOUT: Duration = Duration::from_secs(2);
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(25);
const STREAM_CHANNEL_DEPTH: usize = 16;
const MAX_STREAM_LINE_BYTES: usize = 8 * 1024 * 1024;
const MAX_EVENT_MESSAGE_BYTES: usize = 16 * 1024;
const MAX_PROMPT_RESPONSE_BYTES: usize = 64 * 1024;
const PROJECTION_POLICY_V1: &str = "kwt.openssh.projection.v1";

#[derive(Clone, Eq, PartialEq)]
pub struct KwtSshExecutable(OsString);

impl KwtSshExecutable {
    /// Construct an absolute path to the revision-pinned controller-side KWT.
    ///
    /// # Errors
    ///
    /// Returns an error when the path is not absolute.
    pub fn from_absolute(path: impl Into<OsString>) -> Result<Self, SshError> {
        let path = path.into();
        if !Path::new(&path).is_absolute() {
            return Err(SshError::new(
                DiagnosticKind::ExecutableNotFound,
                "controller KWT path is not absolute",
            ));
        }
        Ok(Self(path))
    }

    #[must_use]
    pub fn as_os_str(&self) -> &OsStr {
        &self.0
    }

    /// Install and verify the revision-pinned native controller in Ghosthub's
    /// helper root, returning the exact executable path to use.
    ///
    /// Each revision and digest has an immutable destination. A conflicting
    /// existing file is rejected rather than overwritten while another
    /// process might be executing it.
    ///
    /// # Errors
    ///
    /// Returns an error when the helper root is not absolute, installation
    /// fails, or existing bytes do not match the reviewed bundle.
    pub fn activate(bundle: &KwtBundle, helper_root: &Path) -> Result<Self, SshError> {
        if !helper_root.is_absolute() {
            return Err(SshError::new(
                DiagnosticKind::UnsupportedEnvironment,
                "KWT controller helper root must be absolute",
            ));
        }
        let directory = helper_root.join("kwt-controller").join(format!(
            "{}-{}",
            bundle.revision(),
            bundle.sha256()
        ));
        let executable = directory.join(if cfg!(windows) { "kwt.exe" } else { "kwt" });
        if executable.exists() {
            verify_bundle_file(&executable, bundle)?;
            #[cfg(unix)]
            ensure_controller_executable(&executable)?;
            return Self::from_absolute(executable.into_os_string());
        }
        fs::create_dir_all(&directory).map_err(classify_io_error)?;
        let mut nonce = [0_u8; 16];
        getrandom::fill(&mut nonce).map_err(|error| {
            SshError::new(
                DiagnosticKind::Transport,
                format!("generate KWT controller install nonce: {error}"),
            )
        })?;
        let temporary = directory.join(format!(".kwt-{}.tmp", hex::encode(nonce)));
        let install = (|| -> Result<(), SshError> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(classify_io_error)?;
            file.write_all(bundle.bytes()).map_err(classify_io_error)?;
            file.sync_all().map_err(classify_io_error)?;
            drop(file);
            match fs::rename(&temporary, &executable) {
                Ok(()) => Ok(()),
                Err(_error) if executable.exists() => verify_bundle_file(&executable, bundle),
                Err(error) => Err(classify_io_error(error)),
            }
        })();
        let _ignored = fs::remove_file(&temporary);
        install?;
        verify_bundle_file(&executable, bundle)?;
        #[cfg(unix)]
        ensure_controller_executable(&executable)?;
        Self::from_absolute(executable.into_os_string())
    }
}

#[cfg(unix)]
fn ensure_controller_executable(path: &Path) -> Result<(), SshError> {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = fs::metadata(path).map_err(classify_io_error)?.permissions();
    if permissions.mode() & 0o100 == 0 {
        permissions.set_mode(permissions.mode() | 0o100);
        fs::set_permissions(path, permissions).map_err(classify_io_error)?;
    }
    if fs::metadata(path)
        .map_err(classify_io_error)?
        .permissions()
        .mode()
        & 0o100
        == 0
    {
        return Err(SshError::new(
            DiagnosticKind::Transport,
            "installed KWT controller is not owner-executable",
        ));
    }
    Ok(())
}

fn verify_bundle_file(path: &Path, bundle: &KwtBundle) -> Result<(), SshError> {
    let bytes = fs::read(path).map_err(classify_io_error)?;
    let digest = Sha256::digest(&bytes);
    let actual = hex::encode(digest);
    if actual != bundle.sha256() || bytes.as_slice() != bundle.bytes() {
        return Err(SshError::new(
            DiagnosticKind::MalformedOutput,
            "installed KWT controller does not match the revision-pinned bundle",
        ));
    }
    Ok(())
}

impl fmt::Debug for KwtSshExecutable {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("KwtSshExecutable")
            .field(&self.0)
            .finish()
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SshTarget {
    hostname: String,
    user: Option<String>,
    port: Option<u16>,
}

impl SshTarget {
    /// Construct one logical SSH target.
    ///
    /// # Errors
    ///
    /// Returns an error for empty or control-character-bearing values.
    pub fn new(
        hostname: impl Into<String>,
        user: Option<String>,
        port: Option<u16>,
    ) -> Result<Self, SshError> {
        let target = Self {
            hostname: hostname.into(),
            user,
            port,
        };
        target.validate()?;
        Ok(target)
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

    fn validate(&self) -> Result<(), SshError> {
        require_safe_value("SSH hostname", &self.hostname)?;
        if let Some(user) = &self.user {
            require_safe_value("SSH user", user)?;
        }
        if self.port == Some(0) {
            return Err(SshError::malformed("SSH port must be greater than zero"));
        }
        Ok(())
    }
}

#[derive(Clone, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SshExecutionProjection {
    arguments: Vec<String>,
    #[serde(default)]
    private_config: Vec<String>,
}

impl SshExecutionProjection {
    #[must_use]
    pub fn arguments(&self) -> &[String] {
        &self.arguments
    }

    #[must_use]
    pub fn private_config_line_count(&self) -> usize {
        self.private_config.len()
    }

    fn validate(&self) -> Result<(), SshError> {
        if self.arguments.is_empty() {
            return Err(SshError::malformed("SSH projection has no arguments"));
        }
        for argument in &self.arguments {
            require_safe_value("SSH projection argument", argument)?;
        }
        for line in &self.private_config {
            require_safe_value("SSH private configuration line", line)?;
        }
        Ok(())
    }
}

impl fmt::Debug for SshExecutionProjection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SshExecutionProjection")
            .field("arguments", &self.arguments)
            .field(
                "private_config",
                &format_args!("<{} private lines>", self.private_config.len()),
            )
            .finish()
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SshResolvedTarget {
    logical_target: SshTarget,
    effective_target: SshTarget,
    display_target: String,
    host_key_alias: Option<String>,
    strict_host_key_checking: Option<String>,
    projection: SshExecutionProjection,
}

impl SshResolvedTarget {
    #[must_use]
    pub const fn logical_target(&self) -> &SshTarget {
        &self.logical_target
    }

    #[must_use]
    pub const fn effective_target(&self) -> &SshTarget {
        &self.effective_target
    }

    #[must_use]
    pub fn display_target(&self) -> &str {
        &self.display_target
    }

    #[must_use]
    pub const fn projection(&self) -> &SshExecutionProjection {
        &self.projection
    }

    fn validate(&self) -> Result<(), SshError> {
        self.logical_target.validate()?;
        self.effective_target.validate()?;
        require_safe_value("SSH display target", &self.display_target)?;
        if let Some(alias) = &self.host_key_alias {
            require_safe_value("SSH host-key alias", alias)?;
        }
        if let Some(policy) = &self.strict_host_key_checking {
            require_safe_value("SSH strict-host-key policy", policy)?;
        }
        self.projection.validate()
    }
}

#[derive(Clone, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SshRouteSnapshot {
    logical_target: SshTarget,
    targets: Vec<SshResolvedTarget>,
    route_identity: String,
    projection_policy: String,
    observed_at: String,
}

impl SshRouteSnapshot {
    /// Decode and validate KWT's native-consumer route contract.
    ///
    /// # Errors
    ///
    /// Returns an error for schema drift, unsupported projection policy, or a
    /// snapshot that does not describe the requested logical target.
    pub fn parse(bytes: &[u8], requested: &SshTarget) -> Result<Self, SshError> {
        let snapshot: Self = serde_json::from_slice(bytes)
            .map_err(|error| SshError::malformed(format!("decode SSH route: {error}")))?;
        snapshot.validate(requested)?;
        Ok(snapshot)
    }

    #[must_use]
    pub const fn logical_target(&self) -> &SshTarget {
        &self.logical_target
    }

    #[must_use]
    pub fn targets(&self) -> &[SshResolvedTarget] {
        &self.targets
    }

    #[must_use]
    pub fn route_identity(&self) -> &str {
        &self.route_identity
    }

    #[must_use]
    pub fn projection_policy(&self) -> &str {
        &self.projection_policy
    }

    fn validate(&self, requested: &SshTarget) -> Result<(), SshError> {
        requested.validate()?;
        self.logical_target.validate()?;
        if &self.logical_target != requested {
            return Err(SshError::malformed(
                "SSH route logical target does not match the request",
            ));
        }
        if self.projection_policy != PROJECTION_POLICY_V1 {
            return Err(SshError::new(
                DiagnosticKind::UnsupportedEnvironment,
                format!(
                    "unsupported KWT SSH projection policy {:?}",
                    self.projection_policy
                ),
            ));
        }
        require_sha256("SSH route identity", &self.route_identity)?;
        require_safe_value("SSH observation timestamp", &self.observed_at)?;
        if self.targets.is_empty() {
            return Err(SshError::malformed("SSH route has no targets"));
        }
        for target in &self.targets {
            target.validate()?;
        }
        if self.targets.last().map(SshResolvedTarget::logical_target) != Some(requested) {
            return Err(SshError::malformed(
                "SSH route final target does not match the request",
            ));
        }
        Ok(())
    }
}

impl fmt::Debug for SshRouteSnapshot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SshRouteSnapshot")
            .field("logical_target", &self.logical_target)
            .field("targets", &self.targets)
            .field("route_identity", &self.route_identity)
            .field("projection_policy", &self.projection_policy)
            .field("observed_at", &self.observed_at)
            .finish()
    }
}

pub struct KwtSshResolver<R> {
    command: CommandPrefix,
    runner: R,
}

impl<R> KwtSshResolver<R> {
    #[must_use]
    pub fn new(executable: KwtSshExecutable, runner: R) -> Self {
        Self {
            command: CommandPrefix::native(executable.0),
            runner,
        }
    }

    pub(crate) const fn with_command(command: CommandPrefix, runner: R) -> Self {
        Self { command, runner }
    }
}

impl<R: CommandRunner> KwtSshResolver<R> {
    /// Resolve one logical target without connecting or prompting.
    ///
    /// # Errors
    ///
    /// Returns a classified KWT command or route-contract failure.
    pub fn resolve(
        &self,
        target: &SshTarget,
        cancellation: &CancellationToken,
    ) -> Result<SshRouteSnapshot, SshError> {
        target.validate()?;
        let args = self.command.with_arguments(resolve_arguments(target));
        let output = self
            .runner
            .run(self.command.program(), &args, cancellation, ROUTE_TIMEOUT)
            .map_err(classify_io_error)?;
        if output.status != 0 {
            return Err(classify_kwt_failure(
                &output.stdout,
                output.status,
                "resolve SSH route",
            ));
        }
        SshRouteSnapshot::parse(&output.stdout, target)
    }
}

fn resolve_arguments(target: &SshTarget) -> Vec<OsString> {
    let mut args = vec!["ssh".into(), "resolve".into(), "--json".into()];
    if let Some(user) = target.user() {
        args.extend(["--user".into(), user.into()]);
    }
    if let Some(port) = target.port() {
        args.extend(["--port".into(), port.to_string().into()]);
    }
    args.extend(["--".into(), target.hostname().into()]);
    args
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum SshLeaseMode {
    Multiplexed,
    Masterless,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SshLeaseResult {
    lease_id: String,
    route_identity: String,
    generation: u64,
    mode: SshLeaseMode,
    arguments: Vec<String>,
}

impl SshLeaseResult {
    #[must_use]
    pub fn lease_id(&self) -> &str {
        &self.lease_id
    }

    #[must_use]
    pub fn route_identity(&self) -> &str {
        &self.route_identity
    }

    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    #[must_use]
    pub fn arguments(&self) -> &[String] {
        &self.arguments
    }

    fn validate(&self, route: &SshRouteSnapshot) -> Result<(), SshError> {
        require_safe_value("SSH lease ID", &self.lease_id)?;
        if self.route_identity != route.route_identity {
            return Err(SshError::malformed(
                "SSH lease route identity does not match the reviewed route",
            ));
        }
        if self.generation == 0 {
            return Err(SshError::malformed("SSH lease generation is zero"));
        }
        if self.mode != SshLeaseMode::Multiplexed {
            return Err(SshError::new(
                DiagnosticKind::UnsupportedEnvironment,
                "KWT did not provide a persistent multiplexed SSH lease",
            ));
        }
        if self.arguments.is_empty() {
            return Err(SshError::malformed("SSH lease has no OpenSSH arguments"));
        }
        for argument in &self.arguments {
            require_safe_value("SSH lease argument", argument)?;
        }
        require_option_only_lease_arguments(&self.arguments)?;
        Ok(())
    }
}

fn require_option_only_lease_arguments(arguments: &[String]) -> Result<(), SshError> {
    let mut pairs = arguments.chunks_exact(2);
    let mut has_control_path = false;
    let mut has_fail_closed_proxy = false;
    for pair in &mut pairs {
        if !matches!(pair[0].as_str(), "-F" | "-o" | "-S") {
            return Err(SshError::malformed(
                "SSH lease contains an unsupported OpenSSH argument",
            ));
        }
        if pair[0] == "-S" && !pair[1].is_empty() {
            has_control_path = true;
        }
        if pair[0] == "-o"
            && matches!(
                pair[1].as_str(),
                "ProxyCommand=/usr/bin/false" | "ProxyCommand=cmd.exe /d /c exit 255"
            )
        {
            has_fail_closed_proxy = true;
        }
    }
    if !pairs.remainder().is_empty() {
        return Err(SshError::malformed(
            "SSH lease contains a destination or incomplete OpenSSH option",
        ));
    }
    if !has_control_path || !has_fail_closed_proxy {
        return Err(SshError::malformed(
            "SSH lease does not provide fail-closed multiplexed execution",
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
pub enum SshPromptKind {
    #[serde(rename = "ssh_authentication")]
    Authentication,
    #[serde(rename = "ssh_host_key")]
    HostKey,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SshPromptDetails {
    logical_target: SshTarget,
    effective_target: SshTarget,
    display_target: String,
    hop_index: usize,
    hop_count: usize,
    host_key: Option<SshHostKeyDetails>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SshHostKeyDetails {
    host: String,
    algorithm: String,
    fingerprint: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SshLeasePrompt {
    id: String,
    kind: SshPromptKind,
    message: String,
    sensitive: bool,
    deadline: String,
    details: SshPromptDetails,
}

impl SshLeasePrompt {
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub const fn kind(&self) -> SshPromptKind {
        self.kind
    }

    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }

    #[must_use]
    pub const fn sensitive(&self) -> bool {
        self.sensitive
    }

    #[must_use]
    pub fn deadline(&self) -> &str {
        &self.deadline
    }

    /// Return the time remaining before KWT stops accepting this prompt.
    ///
    /// # Errors
    ///
    /// Returns an error when the daemon supplied a non-RFC3339 deadline.
    pub fn remaining(&self) -> Result<Duration, SshError> {
        let deadline = parse_rfc3339(&self.deadline)
            .ok_or_else(|| SshError::malformed("SSH prompt deadline is not valid RFC3339"))?;
        Ok(deadline
            .duration_since(SystemTime::now())
            .unwrap_or_default())
    }

    #[must_use]
    pub const fn details(&self) -> &SshPromptDetails {
        &self.details
    }

    fn validate(&self, route: &SshRouteSnapshot) -> Result<(), SshError> {
        require_safe_value("SSH prompt ID", &self.id)?;
        require_safe_value("SSH prompt deadline", &self.deadline)?;
        if parse_rfc3339(&self.deadline).is_none() {
            return Err(SshError::malformed(
                "SSH prompt deadline is not valid RFC3339",
            ));
        }
        if self.message.len() > MAX_EVENT_MESSAGE_BYTES {
            return Err(SshError::malformed("SSH prompt message is too large"));
        }
        if self.sensitive != (self.kind == SshPromptKind::Authentication) {
            return Err(SshError::malformed(
                "SSH prompt sensitivity does not match its kind",
            ));
        }
        match (self.kind, self.details.host_key.as_ref()) {
            (SshPromptKind::HostKey, Some(host_key)) => host_key.validate()?,
            (SshPromptKind::HostKey, None) => {
                return Err(SshError::malformed(
                    "SSH host-key prompt omitted reviewed key details",
                ));
            }
            (SshPromptKind::Authentication, Some(_)) => {
                return Err(SshError::malformed(
                    "SSH authentication prompt included host-key details",
                ));
            }
            (SshPromptKind::Authentication, None) => {}
        }
        if self.details.hop_count != route.targets.len()
            || self.details.hop_index >= route.targets.len()
        {
            return Err(SshError::malformed(
                "SSH prompt hop does not belong to the reviewed route",
            ));
        }
        let target = &route.targets[self.details.hop_index];
        if self.details.logical_target != target.logical_target
            || self.details.effective_target != target.effective_target
            || self.details.display_target != target.display_target
        {
            return Err(SshError::malformed(
                "SSH prompt target does not match the reviewed route",
            ));
        }
        Ok(())
    }
}

impl SshPromptDetails {
    #[must_use]
    pub const fn logical_target(&self) -> &SshTarget {
        &self.logical_target
    }

    #[must_use]
    pub const fn effective_target(&self) -> &SshTarget {
        &self.effective_target
    }

    #[must_use]
    pub fn display_target(&self) -> &str {
        &self.display_target
    }

    #[must_use]
    pub const fn hop_index(&self) -> usize {
        self.hop_index
    }

    #[must_use]
    pub const fn hop_count(&self) -> usize {
        self.hop_count
    }

    #[must_use]
    pub const fn host_key(&self) -> Option<&SshHostKeyDetails> {
        self.host_key.as_ref()
    }
}

impl SshHostKeyDetails {
    fn validate(&self) -> Result<(), SshError> {
        require_safe_value("SSH host-key host", &self.host)?;
        require_safe_value("SSH host-key algorithm", &self.algorithm)?;
        require_safe_value("SSH host-key fingerprint", &self.fingerprint)?;
        if self.host.is_empty() || self.algorithm.is_empty() || self.fingerprint.is_empty() {
            return Err(SshError::malformed("SSH host-key details are incomplete"));
        }
        Ok(())
    }

    #[must_use]
    pub fn host(&self) -> &str {
        &self.host
    }

    #[must_use]
    pub fn algorithm(&self) -> &str {
        &self.algorithm
    }

    #[must_use]
    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SshLeaseEvent {
    Progress(String),
    Warning(String),
    Prompt(Box<SshLeasePrompt>),
    Complete(SshLeaseResult),
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct OperationEvent {
    operation_id: String,
    sequence: u64,
    kind: OperationKind,
    message: Option<String>,
    prompt: Option<SshLeasePrompt>,
    result: Option<SshLeaseResult>,
    failure: Option<OperationFailure>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
enum OperationKind {
    Progress,
    Warning,
    Prompt,
    Complete,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct OperationFailure {
    code: String,
    message: String,
    retryable: bool,
}

#[derive(Debug, Default)]
pub struct SshLeaseStream {
    operation_id: Option<String>,
    sequence: u64,
    terminal: bool,
}

impl SshLeaseStream {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            operation_id: None,
            sequence: 0,
            terminal: false,
        }
    }

    /// Accept one NDJSON event from `kwt ssh lease --json`.
    ///
    /// # Errors
    ///
    /// Returns an error for stream ordering, shape, prompt attribution, or
    /// completion authority violations.
    pub fn accept(
        &mut self,
        line: &[u8],
        route: &SshRouteSnapshot,
    ) -> Result<SshLeaseEvent, SshError> {
        if self.terminal {
            return Err(SshError::malformed("SSH lease stream is already terminal"));
        }
        if line.len() > MAX_STREAM_LINE_BYTES {
            return Err(SshError::malformed("SSH lease event is too large"));
        }
        let event: OperationEvent = serde_json::from_slice(line)
            .map_err(|error| SshError::malformed(format!("decode SSH lease event: {error}")))?;
        require_safe_value("SSH operation ID", &event.operation_id)?;
        match &self.operation_id {
            Some(operation_id) if operation_id != &event.operation_id => {
                return Err(SshError::malformed("SSH lease operation ID changed"));
            }
            None => self.operation_id = Some(event.operation_id.clone()),
            Some(_) => {}
        }
        if event.sequence != self.sequence + 1 {
            return Err(SshError::malformed(format!(
                "SSH lease event sequence is {}; expected {}",
                event.sequence,
                self.sequence + 1
            )));
        }
        self.sequence = event.sequence;
        let accepted = match event.kind {
            OperationKind::Progress | OperationKind::Warning => {
                if event.prompt.is_some() || event.result.is_some() || event.failure.is_some() {
                    return Err(SshError::malformed(
                        "SSH status event carries an incompatible payload",
                    ));
                }
                let message = event.message.unwrap_or_default();
                if message.len() > MAX_EVENT_MESSAGE_BYTES {
                    return Err(SshError::malformed("SSH status message is too large"));
                }
                if event.kind == OperationKind::Progress {
                    SshLeaseEvent::Progress(message)
                } else {
                    SshLeaseEvent::Warning(message)
                }
            }
            OperationKind::Prompt => {
                if event.message.is_some() || event.result.is_some() || event.failure.is_some() {
                    return Err(SshError::malformed(
                        "SSH prompt event carries an incompatible payload",
                    ));
                }
                let prompt = event
                    .prompt
                    .ok_or_else(|| SshError::malformed("SSH prompt event has no prompt"))?;
                prompt.validate(route)?;
                SshLeaseEvent::Prompt(Box::new(prompt))
            }
            OperationKind::Complete => {
                if event.message.is_some() || event.prompt.is_some() {
                    return Err(SshError::malformed(
                        "SSH completion carries an incompatible payload",
                    ));
                }
                self.terminal = true;
                match (event.result, event.failure) {
                    (Some(result), None) => {
                        result.validate(route)?;
                        SshLeaseEvent::Complete(result)
                    }
                    (None, Some(failure)) => return Err(SshError::operation(failure)),
                    _ => {
                        return Err(SshError::malformed(
                            "SSH completion must carry one result or failure",
                        ));
                    }
                }
            }
        };
        Ok(accepted)
    }
}

#[derive(Serialize)]
struct PromptResponse<'a> {
    prompt_id: &'a str,
    value: &'a str,
}

pub struct KwtSshLeaseClient {
    command: CommandPrefix,
    inactivity_timeout: Duration,
}

impl KwtSshLeaseClient {
    #[must_use]
    pub fn new(executable: KwtSshExecutable) -> Self {
        Self {
            command: CommandPrefix::native(executable.0),
            inactivity_timeout: LEASE_INACTIVITY_TIMEOUT,
        }
    }

    pub(crate) const fn with_command(command: CommandPrefix) -> Self {
        Self {
            command,
            inactivity_timeout: LEASE_INACTIVITY_TIMEOUT,
        }
    }

    #[cfg(test)]
    fn with_inactivity_timeout(mut self, timeout: Duration) -> Self {
        self.inactivity_timeout = timeout;
        self
    }

    /// Acquire and hold one KWT-owned persistent SSH connection.
    ///
    /// The prompt callback runs on the caller's worker thread. UI adapters must
    /// bridge it to presentation state and honor the prompt's daemon deadline.
    ///
    /// # Errors
    ///
    /// Returns a classified launch, timeout, protocol, prompt, or KWT failure.
    pub fn acquire(
        &self,
        route: &SshRouteSnapshot,
        cancellation: &CancellationToken,
        mut prompt: impl FnMut(&SshLeasePrompt) -> Result<String, SshError>,
        mut status: impl FnMut(&SshLeaseEvent),
    ) -> Result<SshLease, SshError> {
        require_active_acquisition(cancellation)?;
        let mut command = Command::new(self.command.program());
        command_process::prepare(&mut command);
        let args = self.command.with_arguments(lease_arguments(route));
        let mut child = command
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(classify_io_error)?;
        let containment = match while_acquisition_active(cancellation, || {
            CommandContainment::attach(&mut child).map_err(classify_io_error)
        }) {
            Ok(containment) => containment,
            Err(error) => {
                let _ignored = child.kill();
                let _ignored = child.wait();
                return Err(error);
            }
        };
        let stdin = child.stdin.take().ok_or_else(|| {
            SshError::new(DiagnosticKind::Transport, "KWT lease stdin is unavailable")
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            SshError::new(DiagnosticKind::Transport, "KWT lease stdout is unavailable")
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            SshError::new(DiagnosticKind::Transport, "KWT lease stderr is unavailable")
        })?;
        let (sender, receiver) = sync_channel(STREAM_CHANNEL_DEPTH);
        let stdout_reader = spawn_line_reader(stdout, sender.clone());
        let (prompt_sender, prompt_receiver) = sync_channel(1);
        let prompt_writer = spawn_prompt_writer(stdin, prompt_receiver, sender);
        let diagnostics = Arc::new(Mutex::new(Vec::new()));
        let stderr_reader = spawn_diagnostic_reader(stderr, Arc::clone(&diagnostics));
        let process = LeaseProcess {
            child,
            prompt_sender: Some(prompt_sender),
            prompt_writer: Some(prompt_writer),
            containment,
            receiver: Some(receiver),
            stdout_reader: Some(stdout_reader),
            stderr_reader: Some(stderr_reader),
            diagnostics,
            released: false,
        };
        self.drive_acquisition(process, route, cancellation, &mut prompt, &mut status)
    }

    fn drive_acquisition(
        &self,
        mut process: LeaseProcess,
        route: &SshRouteSnapshot,
        cancellation: &CancellationToken,
        prompt: &mut impl FnMut(&SshLeasePrompt) -> Result<String, SshError>,
        status: &mut impl FnMut(&SshLeaseEvent),
    ) -> Result<SshLease, SshError> {
        let mut decoder = SshLeaseStream::new();
        let mut last_activity = Instant::now();
        loop {
            if cancellation.is_cancelled() {
                process.terminate_and_reap();
                return Err(SshError::new(
                    DiagnosticKind::Transport,
                    "SSH lease acquisition cancelled",
                ));
            }
            if last_activity.elapsed() >= self.inactivity_timeout {
                process.terminate_and_reap();
                return Err(SshError::new(
                    DiagnosticKind::Timeout,
                    "SSH connection preparation stopped responding",
                ));
            }
            match process
                .receiver
                .as_ref()
                .expect("lease output remains available while acquiring")
                .recv_timeout(PROCESS_POLL_INTERVAL)
            {
                Ok(StreamItem::Line(line)) => {
                    last_activity = Instant::now();
                    match accept_lease_line(&mut decoder, &line, route)? {
                        SshLeaseEvent::Prompt(request) => {
                            let response = prompt(&request)?;
                            if response.len() > MAX_PROMPT_RESPONSE_BYTES {
                                return Err(SshError::new(
                                    DiagnosticKind::MalformedOutput,
                                    "SSH prompt response is too large",
                                ));
                            }
                            let payload = encode_prompt_response(&request, &response)?;
                            while_acquisition_active(cancellation, || {
                                process.queue_prompt_response(payload)
                            })?;
                            last_activity = Instant::now();
                        }
                        SshLeaseEvent::Complete(result) => {
                            return while_acquisition_active(cancellation, || {
                                Ok(SshLease {
                                    result,
                                    process: Arc::new(LeaseState::new(process)),
                                })
                            });
                        }
                        event => status(&event),
                    }
                }
                Ok(StreamItem::Failed(error)) => {
                    process.terminate_and_reap();
                    return Err(classify_io_error(error));
                }
                Ok(StreamItem::End) => {
                    let error = process.exit_error("SSH lease ended before completion");
                    process.terminate_and_reap();
                    return Err(error);
                }
                Err(RecvTimeoutError::Timeout) => {
                    if process
                        .child
                        .try_wait()
                        .map_err(classify_io_error)?
                        .is_some()
                    {
                        let error = process.exit_error("SSH lease exited before completion");
                        process.finish_io();
                        return Err(error);
                    }
                }
                Err(RecvTimeoutError::Disconnected) => {
                    let error = process.exit_error("SSH lease output disconnected");
                    process.terminate_and_reap();
                    return Err(error);
                }
            }
        }
    }
}

fn encode_prompt_response(prompt: &SshLeasePrompt, response: &str) -> Result<Vec<u8>, SshError> {
    let mut payload = serde_json::to_vec(&PromptResponse {
        prompt_id: prompt.id(),
        value: response,
    })
    .map_err(|error| SshError::malformed(format!("encode SSH prompt response: {error}")))?;
    payload.push(b'\n');
    Ok(payload)
}

fn require_active_acquisition(cancellation: &CancellationToken) -> Result<(), SshError> {
    if cancellation.is_cancelled() {
        Err(SshError::new(
            DiagnosticKind::Transport,
            "SSH lease acquisition cancelled",
        ))
    } else {
        Ok(())
    }
}

fn while_acquisition_active<T>(
    cancellation: &CancellationToken,
    operation: impl FnOnce() -> Result<T, SshError>,
) -> Result<T, SshError> {
    match cancellation.run_if_active(operation) {
        Some(result) => result,
        None => Err(SshError::new(
            DiagnosticKind::Transport,
            "SSH lease acquisition cancelled",
        )),
    }
}

fn lease_arguments(route: &SshRouteSnapshot) -> Vec<OsString> {
    let mut args = vec![
        "ssh".into(),
        "lease".into(),
        "--json".into(),
        "--route-identity".into(),
        route.route_identity().into(),
        "--projection-policy".into(),
        route.projection_policy().into(),
        "--host-key-policy".into(),
        "review".into(),
    ];
    if let Some(user) = route.logical_target().user() {
        args.extend(["--user".into(), user.into()]);
    }
    if let Some(port) = route.logical_target().port() {
        args.extend(["--port".into(), port.to_string().into()]);
    }
    args.extend(["--".into(), route.logical_target().hostname().into()]);
    args
}

#[derive(Clone)]
pub struct SshLease {
    result: SshLeaseResult,
    process: Arc<LeaseState>,
}

impl SshLease {
    #[cfg(feature = "test-support")]
    pub(crate) fn test_fixture(route_identity: &str, generation: u64) -> Self {
        Self {
            result: SshLeaseResult {
                lease_id: "test-lease".to_owned(),
                route_identity: route_identity.to_owned(),
                generation,
                mode: SshLeaseMode::Multiplexed,
                arguments: Vec::new(),
            },
            process: Arc::new(LeaseState {
                process: Mutex::new(None),
            }),
        }
    }

    #[must_use]
    pub const fn result(&self) -> &SshLeaseResult {
        &self.result
    }

    /// Confirm that the KWT controller still owns this lease.
    ///
    /// # Errors
    ///
    /// Returns a classified transport failure after the controller exits or
    /// when its status can no longer be inspected.
    pub fn ensure_live(&self) -> Result<(), SshError> {
        self.process.ensure_live()
    }

    /// Release the lease when this is its final owner.
    ///
    /// # Errors
    ///
    /// Returns an error if KWT does not release within the bounded deadline.
    pub fn release(self) -> Result<(), SshError> {
        if Arc::strong_count(&self.process) != 1 {
            return Ok(());
        }
        self.process.release()
    }
}

impl fmt::Debug for SshLease {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SshLease")
            .field("result", &self.result)
            .finish_non_exhaustive()
    }
}

enum StreamItem {
    Line(Vec<u8>),
    Failed(io::Error),
    End,
}

struct LeaseState {
    process: Mutex<Option<LeaseProcess>>,
}

impl LeaseState {
    fn new(process: LeaseProcess) -> Self {
        Self {
            process: Mutex::new(Some(process)),
        }
    }

    fn release(&self) -> Result<(), SshError> {
        let process = self
            .process
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(mut process) = process {
            process.release(LEASE_RELEASE_TIMEOUT)
        } else {
            Ok(())
        }
    }

    fn ensure_live(&self) -> Result<(), SshError> {
        let mut process = self
            .process
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active) = process.as_mut() else {
            return Err(SshError::new(
                DiagnosticKind::Transport,
                "SSH lease controller is no longer active",
            ));
        };
        match active.child.try_wait() {
            Ok(None) => Ok(()),
            Ok(Some(_status)) => {
                let mut exited = process
                    .take()
                    .expect("observed lease process remains owned");
                let error = exited.exit_error("SSH lease controller exited unexpectedly");
                finish_exited_lease(exited);
                Err(error)
            }
            Err(error) => {
                let mut failed = process.take().expect("failed lease process remains owned");
                failed.terminate_and_reap();
                Err(classify_io_error(error))
            }
        }
    }
}

fn finish_exited_lease(mut process: LeaseProcess) {
    let _cleanup = thread::Builder::new()
        .name("ghosthub-ssh-lease-exit".to_owned())
        .spawn(move || {
            process.containment.terminate();
            process.released = true;
            process.finish_io();
        });
}

impl Drop for LeaseState {
    fn drop(&mut self) {
        let process = self
            .process
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(mut process) = process {
            let _ignored = thread::Builder::new()
                .name("ghosthub-ssh-lease-release".to_owned())
                .spawn(move || {
                    let _ignored = process.release(LEASE_RELEASE_TIMEOUT);
                });
        }
    }
}

struct LeaseProcess {
    child: Child,
    prompt_sender: Option<SyncSender<Vec<u8>>>,
    prompt_writer: Option<JoinHandle<()>>,
    containment: CommandContainment,
    receiver: Option<Receiver<StreamItem>>,
    stdout_reader: Option<JoinHandle<()>>,
    stderr_reader: Option<JoinHandle<()>>,
    diagnostics: Arc<Mutex<Vec<u8>>>,
    released: bool,
}

impl LeaseProcess {
    fn queue_prompt_response(&self, payload: Vec<u8>) -> Result<(), SshError> {
        let sender = self
            .prompt_sender
            .as_ref()
            .ok_or_else(|| SshError::new(DiagnosticKind::Transport, "SSH lease input is closed"))?;
        sender.try_send(payload).map_err(|error| match error {
            TrySendError::Full(_) => SshError::new(
                DiagnosticKind::MalformedOutput,
                "KWT requested another SSH response before consuming the previous one",
            ),
            TrySendError::Disconnected(_) => {
                SshError::new(DiagnosticKind::Transport, "SSH lease input is closed")
            }
        })
    }

    fn release(&mut self, timeout: Duration) -> Result<(), SshError> {
        self.prompt_sender.take();
        let deadline = Instant::now() + timeout;
        loop {
            if self.child.try_wait().map_err(classify_io_error)?.is_some() {
                self.released = true;
                self.finish_io();
                return Ok(());
            }
            if Instant::now() >= deadline {
                self.terminate_and_reap();
                return Err(SshError::new(
                    DiagnosticKind::Timeout,
                    "KWT did not release the SSH lease in time",
                ));
            }
            thread::sleep(PROCESS_POLL_INTERVAL);
        }
    }

    fn exit_error(&mut self, fallback: &str) -> SshError {
        if let Some(receiver) = self.receiver.as_ref() {
            while let Ok(item) = receiver.try_recv() {
                if let StreamItem::Line(line) = item
                    && let Some(failure) = parse_failure_envelope(&line)
                {
                    return SshError::operation(failure);
                }
            }
        }
        let diagnostic = self
            .diagnostics
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let message = String::from_utf8_lossy(&diagnostic).trim().to_owned();
        if message.is_empty() {
            SshError::new(DiagnosticKind::Transport, fallback)
        } else {
            SshError::new(DiagnosticKind::Transport, message)
        }
    }

    fn terminate_and_reap(&mut self) {
        self.prompt_sender.take();
        self.containment.terminate();
        let _ignored = self.child.kill();
        let _ignored = self.child.wait();
        self.released = true;
        self.finish_io();
    }

    fn finish_io(&mut self) {
        self.prompt_sender.take();
        finish_stream_readers(
            &mut self.receiver,
            &mut self.stdout_reader,
            &mut self.stderr_reader,
        );
        if let Some(writer) = self.prompt_writer.take() {
            let _ignored = writer.join();
        }
    }
}

impl Drop for LeaseProcess {
    fn drop(&mut self) {
        if !self.released {
            self.terminate_and_reap();
        }
    }
}

fn finish_stream_readers(
    receiver: &mut Option<Receiver<StreamItem>>,
    stdout_reader: &mut Option<JoinHandle<()>>,
    stderr_reader: &mut Option<JoinHandle<()>>,
) {
    receiver.take();
    if let Some(reader) = stdout_reader.take() {
        let _ignored = reader.join();
    }
    if let Some(reader) = stderr_reader.take() {
        let _ignored = reader.join();
    }
}

fn spawn_prompt_writer(
    mut stdin: impl Write + Send + 'static,
    receiver: Receiver<Vec<u8>>,
    output: SyncSender<StreamItem>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        while let Ok(payload) = receiver.recv() {
            if let Err(error) = stdin.write_all(&payload).and_then(|()| stdin.flush()) {
                let _ignored = output.send(StreamItem::Failed(error));
                return;
            }
        }
    })
}

fn spawn_line_reader(
    stdout: impl Read + Send + 'static,
    sender: SyncSender<StreamItem>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            let mut line = Vec::new();
            match reader
                .by_ref()
                .take((MAX_STREAM_LINE_BYTES + 2) as u64)
                .read_until(b'\n', &mut line)
            {
                Ok(0) => {
                    let _ignored = sender.send(StreamItem::End);
                    return;
                }
                Ok(_) => {
                    if line.len() > MAX_STREAM_LINE_BYTES + 1
                        || (line.len() == MAX_STREAM_LINE_BYTES + 1 && !line.ends_with(b"\n"))
                    {
                        let _ignored = sender.send(StreamItem::Failed(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "KWT SSH lease event is too large",
                        )));
                        return;
                    }
                    while matches!(line.last(), Some(b'\n' | b'\r')) {
                        line.pop();
                    }
                    if sender.send(StreamItem::Line(line)).is_err() {
                        return;
                    }
                }
                Err(error) => {
                    let _ignored = sender.send(StreamItem::Failed(error));
                    return;
                }
            }
        }
    })
}

fn spawn_diagnostic_reader(
    stderr: impl Read + Send + 'static,
    diagnostics: Arc<Mutex<Vec<u8>>>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut stderr = stderr;
        let mut chunk = [0_u8; 4096];
        loop {
            match stderr.read(&mut chunk) {
                Ok(0) | Err(_) => return,
                Ok(count) => {
                    let mut captured = diagnostics
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    let remaining = MAX_EVENT_MESSAGE_BYTES.saturating_sub(captured.len());
                    captured.extend_from_slice(&chunk[..count.min(remaining)]);
                }
            }
        }
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SshError {
    kind: DiagnosticKind,
    code: Option<String>,
    detail: String,
    retryable: bool,
}

impl SshError {
    fn new(kind: DiagnosticKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            code: None,
            detail: detail.into(),
            retryable: false,
        }
    }

    fn malformed(detail: impl Into<String>) -> Self {
        Self::new(DiagnosticKind::MalformedOutput, detail)
    }

    fn operation(failure: OperationFailure) -> Self {
        let kind = match failure.code.as_str() {
            "ssh_route_unreviewable" | "ssh_unsupported_version" => {
                DiagnosticKind::UnsupportedEnvironment
            }
            "ssh_prompt_timed_out" => DiagnosticKind::Timeout,
            _ => DiagnosticKind::Transport,
        };
        Self {
            kind,
            code: Some(failure.code),
            detail: failure.message,
            retryable: failure.retryable,
        }
    }

    /// Construct the user-cancelled prompt result used by native UI bridges.
    #[must_use]
    pub fn prompt_cancelled() -> Self {
        Self::new(DiagnosticKind::Transport, "SSH prompt was cancelled")
    }

    #[must_use]
    pub const fn kind(&self) -> DiagnosticKind {
        self.kind
    }

    #[must_use]
    pub fn code(&self) -> Option<&str> {
        self.code.as_deref()
    }

    #[must_use]
    pub const fn retryable(&self) -> bool {
        self.retryable
    }
}

impl fmt::Display for SshError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.detail)
    }
}

impl std::error::Error for SshError {}

fn classify_io_error(error: io::Error) -> SshError {
    let kind = match error.kind() {
        io::ErrorKind::NotFound => DiagnosticKind::ExecutableNotFound,
        io::ErrorKind::PermissionDenied => DiagnosticKind::PermissionDenied,
        io::ErrorKind::TimedOut => DiagnosticKind::Timeout,
        _ => DiagnosticKind::Transport,
    };
    let message = error.to_string();
    drop(error);
    SshError::new(kind, message)
}

fn classify_kwt_failure(stdout: &[u8], status: i32, operation: &str) -> SshError {
    if let Some(failure) = parse_command_failure(stdout) {
        return SshError::operation(OperationFailure {
            code: failure.code().to_owned(),
            message: failure.message().to_owned(),
            retryable: failure.retryable(),
        });
    }
    SshError::new(
        DiagnosticKind::Transport,
        format!("{operation} failed with status {status}"),
    )
}

fn parse_failure_envelope(line: &[u8]) -> Option<OperationFailure> {
    #[derive(Deserialize)]
    struct Envelope {
        error: OperationFailure,
    }
    serde_json::from_slice::<Envelope>(line)
        .ok()
        .map(|envelope| envelope.error)
}

fn accept_lease_line(
    decoder: &mut SshLeaseStream,
    line: &[u8],
    route: &SshRouteSnapshot,
) -> Result<SshLeaseEvent, SshError> {
    if let Some(failure) = parse_failure_envelope(line) {
        return Err(SshError::operation(failure));
    }
    decoder.accept(line, route)
}

fn require_safe_value(name: &str, value: &str) -> Result<(), SshError> {
    if value.is_empty() {
        return Err(SshError::malformed(format!("{name} is empty")));
    }
    if value.chars().any(char::is_control) {
        return Err(SshError::malformed(format!(
            "{name} contains control characters"
        )));
    }
    Ok(())
}

fn require_sha256(name: &str, value: &str) -> Result<(), SshError> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(SshError::malformed(format!(
            "{name} is not a canonical SHA-256 value"
        )));
    }
    Ok(())
}

fn parse_rfc3339(value: &str) -> Option<SystemTime> {
    let bytes = value.as_bytes();
    if bytes.len() < 20
        || bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
    {
        return None;
    }
    let year = i64::from(decimal(bytes.get(0..4)?)?);
    let month = decimal(bytes.get(5..7)?)?;
    let day = decimal(bytes.get(8..10)?)?;
    let hour = decimal(bytes.get(11..13)?)?;
    let minute = decimal(bytes.get(14..16)?)?;
    let second = decimal(bytes.get(17..19)?)?;
    if year < 1970
        || !(1..=12).contains(&month)
        || day == 0
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }

    let mut cursor = 19;
    let mut nanos = 0_u32;
    if bytes.get(cursor) == Some(&b'.') {
        cursor += 1;
        let start = cursor;
        while bytes.get(cursor).is_some_and(u8::is_ascii_digit) {
            cursor += 1;
        }
        let fraction = bytes.get(start..cursor)?;
        if fraction.is_empty() || fraction.len() > 9 {
            return None;
        }
        let precision = u32::try_from(9 - fraction.len()).ok()?;
        nanos = decimal(fraction)? * 10_u32.pow(precision);
    }

    let offset = match bytes.get(cursor..) {
        Some(b"Z") => 0_i64,
        Some(zone) if zone.len() == 6 && matches!(zone[0], b'+' | b'-') && zone[3] == b':' => {
            let hours = decimal(&zone[1..3])?;
            let minutes = decimal(&zone[4..6])?;
            if hours > 23 || minutes > 59 {
                return None;
            }
            let seconds = i64::from(hours * 3600 + minutes * 60);
            if zone[0] == b'-' { -seconds } else { seconds }
        }
        _ => return None,
    };
    let days = days_since_unix_epoch(year, month, day);
    let seconds = days
        .checked_mul(86_400)?
        .checked_add(i64::from(hour * 3600 + minute * 60 + second))?
        .checked_sub(offset)?;
    let seconds = u64::try_from(seconds).ok()?;
    UNIX_EPOCH.checked_add(Duration::new(seconds, nanos))
}

fn decimal(bytes: &[u8]) -> Option<u32> {
    if bytes.is_empty() || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    bytes.iter().try_fold(0_u32, |value, byte| {
        value.checked_mul(10)?.checked_add(u32::from(*byte - b'0'))
    })
}

const fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        _ => 0,
    }
}

fn days_since_unix_epoch(year: i64, month: u32, day: u32) -> i64 {
    let adjusted_year = year - i64::from(month <= 2);
    let era = adjusted_year.div_euclid(400);
    let year_of_era = adjusted_year - era * 400;
    let shifted_month = i64::from(month) + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * shifted_month + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::sync::{
        Arc, Barrier, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    };

    use super::*;
    use crate::{CommandOutput, CommandRunner};

    fn route_json() -> Vec<u8> {
        br#"{
          "logical_target":{"hostname":"final.example","user":"deploy","port":2200},
          "targets":[
            {
              "logical_target":{"hostname":"jump","user":null,"port":null},
              "effective_target":{"hostname":"jump.example","user":"ops","port":22},
              "display_target":"ops@jump.example:22",
              "host_key_alias":null,
              "strict_host_key_checking":"ask",
              "projection":{"arguments":["-o","HostName=jump.example"],"private_config":[]}
            },
            {
              "logical_target":{"hostname":"final.example","user":"deploy","port":2200},
              "effective_target":{"hostname":"10.0.0.8","user":"deploy","port":2200},
              "display_target":"deploy@10.0.0.8:2200",
              "host_key_alias":"final.example",
              "strict_host_key_checking":"ask",
              "projection":{"arguments":["-o","HostName=10.0.0.8"],"private_config":["SetEnv TOKEN=secret"]}
            }
          ],
          "route_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "projection_policy":"kwt.openssh.projection.v1",
          "observed_at":"2026-08-15T12:00:00Z"
        }"#
        .to_vec()
    }

    fn route() -> SshRouteSnapshot {
        let target = SshTarget::new("final.example", Some("deploy".to_owned()), Some(2200))
            .expect("valid target");
        SshRouteSnapshot::parse(&route_json(), &target).expect("valid route")
    }

    #[derive(Default)]
    struct RecordingRunner {
        calls: Mutex<Vec<(OsString, Vec<OsString>)>>,
    }

    impl CommandRunner for RecordingRunner {
        fn run(
            &self,
            program: &OsStr,
            args: &[OsString],
            _cancellation: &CancellationToken,
            _timeout: Duration,
        ) -> io::Result<CommandOutput> {
            self.calls
                .lock()
                .expect("record calls")
                .push((program.to_owned(), args.to_vec()));
            Ok(CommandOutput {
                status: 0,
                stdout: route_json(),
                stderr: Vec::new(),
            })
        }
    }

    #[test]
    fn route_resolution_uses_the_exact_pinned_helper_and_target_argv() {
        let executable = KwtSshExecutable::from_absolute(if cfg!(windows) {
            r"C:\Ghosthub\kwt.exe"
        } else {
            "/opt/ghosthub/kwt"
        })
        .expect("absolute helper");
        let resolver = KwtSshResolver::new(executable.clone(), RecordingRunner::default());
        let target = SshTarget::new("final.example", Some("deploy".to_owned()), Some(2200))
            .expect("valid target");

        let observed = resolver
            .resolve(&target, &CancellationToken::new())
            .expect("resolve route");

        assert_eq!(observed, route());
        let calls = resolver.runner.calls.lock().expect("recorded calls");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, executable.0);
        assert_eq!(
            calls[0].1,
            [
                "ssh",
                "resolve",
                "--json",
                "--user",
                "deploy",
                "--port",
                "2200",
                "--",
                "final.example",
            ]
            .map(OsString::from)
        );
    }

    #[test]
    fn route_snapshots_reject_wrong_targets_and_private_config_is_redacted() {
        let wrong = SshTarget::new("other.example", None, None).expect("valid target");
        let error = SshRouteSnapshot::parse(&route_json(), &wrong).expect_err("wrong target");
        assert_eq!(error.kind(), DiagnosticKind::MalformedOutput);

        let debug = format!("{:?}", route());
        assert!(!debug.contains("TOKEN=secret"));
        assert!(debug.contains("<1 private lines>"));
    }

    #[test]
    fn lease_stream_requires_ordered_hop_attributed_prompts_and_exact_completion() {
        let route = route();
        let mut stream = SshLeaseStream::new();
        let progress =
            br#"{"operation_id":"op-1","sequence":1,"kind":"progress","message":"connecting"}"#;
        assert_eq!(
            stream.accept(progress, &route).expect("progress"),
            SshLeaseEvent::Progress("connecting".to_owned())
        );
        let prompt = br#"{
          "operation_id":"op-1","sequence":2,"kind":"prompt",
          "prompt":{
            "id":"prompt-1","kind":"ssh_host_key","message":"Continue?","sensitive":false,
            "deadline":"2026-08-15T12:00:30Z",
            "details":{
              "logical_target":{"hostname":"jump","user":null,"port":null},
              "effective_target":{"hostname":"jump.example","user":"ops","port":22},
              "display_target":"ops@jump.example:22","hop_index":0,"hop_count":2,
              "host_key":{"host":"jump.example","algorithm":"ED25519","fingerprint":"SHA256:abc123"}
            }
          }
        }"#;
        let accepted = stream.accept(prompt, &route).expect("attributed prompt");
        let SshLeaseEvent::Prompt(prompt) = accepted else {
            panic!("expected prompt");
        };
        let host_key = prompt.details().host_key().expect("reviewed host key");
        assert_eq!(host_key.host(), "jump.example");
        assert_eq!(host_key.algorithm(), "ED25519");
        assert_eq!(host_key.fingerprint(), "SHA256:abc123");
        let complete = br#"{
          "operation_id":"op-1","sequence":3,"kind":"complete",
          "result":{
            "lease_id":"lease-1","route_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":7,
            "mode":"multiplexed","arguments":["-S","control-path","-o","ProxyCommand=/usr/bin/false"]
          }
        }"#;
        let accepted = stream.accept(complete, &route).expect("valid lease");
        assert!(matches!(accepted, SshLeaseEvent::Complete(_)));
    }

    #[test]
    fn lease_stream_rejects_sequence_route_and_prompt_authority_drift() {
        let route = route();
        let mut stream = SshLeaseStream::new();
        let skipped = br#"{"operation_id":"op-1","sequence":2,"kind":"progress","message":"late"}"#;
        assert!(stream.accept(skipped, &route).is_err());

        let mut stream = SshLeaseStream::new();
        let wrong_prompt = br#"{
          "operation_id":"op-1","sequence":1,"kind":"prompt",
          "prompt":{
            "id":"prompt-1","kind":"ssh_authentication","message":"Password:","sensitive":true,
            "deadline":"2026-08-15T12:00:30Z",
            "details":{
              "logical_target":{"hostname":"jump","user":null,"port":null},
              "effective_target":{"hostname":"attacker.example","user":"ops","port":22},
              "display_target":"ops@attacker.example:22","hop_index":0,"hop_count":2
            }
          }
        }"#;
        assert!(stream.accept(wrong_prompt, &route).is_err());

        let mut stream = SshLeaseStream::new();
        let wrong_route = br#"{
          "operation_id":"op-1","sequence":1,"kind":"complete",
          "result":{
            "lease_id":"lease-1","route_identity":"route-2","generation":7,
            "mode":"multiplexed","arguments":["final.example"]
          }
        }"#;
        assert!(stream.accept(wrong_route, &route).is_err());
    }

    #[test]
    fn lease_stream_rejects_destination_bearing_arguments() {
        let route = route();
        let mut stream = SshLeaseStream::new();
        let complete = br#"{
          "operation_id":"op-1","sequence":1,"kind":"complete",
          "result":{
            "lease_id":"lease-1","route_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":7,
            "mode":"multiplexed","arguments":["-S","control-path","final.example"]
          }
        }"#;

        let error = stream
            .accept(complete, &route)
            .expect_err("destination-bearing lease arguments");
        assert_eq!(error.kind(), DiagnosticKind::MalformedOutput);
    }

    #[test]
    fn lease_stream_requires_fail_closed_control_socket_execution() {
        let route = route();
        for arguments in [
            r#"["-S","control-path"]"#,
            r#"["-S","control-path","-o","ProxyCommand=none"]"#,
            r#"["-o","ProxyCommand=/usr/bin/false"]"#,
        ] {
            let mut stream = SshLeaseStream::new();
            let complete = format!(
                r#"{{"operation_id":"op-1","sequence":1,"kind":"complete","result":{{"lease_id":"lease-1","route_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":7,"mode":"multiplexed","arguments":{arguments}}}}}"#
            );

            let error = stream
                .accept(complete.as_bytes(), &route)
                .expect_err("lease must fail closed when its master disappears");
            assert_eq!(error.kind(), DiagnosticKind::MalformedOutput);
        }
    }

    #[test]
    fn masterless_and_structured_failures_are_classified_without_retry_guessing() {
        let route = route();
        let mut stream = SshLeaseStream::new();
        let masterless = br#"{
          "operation_id":"op-1","sequence":1,"kind":"complete",
          "result":{
            "lease_id":"lease-1","route_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":7,
            "mode":"masterless","arguments":["final.example"]
          }
        }"#;
        let error = stream
            .accept(masterless, &route)
            .expect_err("masterless lease");
        assert_eq!(error.kind(), DiagnosticKind::UnsupportedEnvironment);

        let mut stream = SshLeaseStream::new();
        let failure = br#"{
          "operation_id":"op-2","sequence":1,"kind":"complete",
          "failure":{"code":"ssh_configuration_changed","message":"route changed","retryable":true}
        }"#;
        let error = stream.accept(failure, &route).expect_err("changed route");
        assert_eq!(error.code(), Some("ssh_configuration_changed"));
        assert!(error.retryable());
    }

    #[test]
    fn lease_arguments_bind_the_reviewed_route_and_logical_target() {
        assert_eq!(
            lease_arguments(&route()),
            [
                "ssh",
                "lease",
                "--json",
                "--route-identity",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "--projection-policy",
                "kwt.openssh.projection.v1",
                "--host-key-policy",
                "review",
                "--user",
                "deploy",
                "--port",
                "2200",
                "--",
                "final.example",
            ]
            .map(OsString::from)
        );
    }

    #[test]
    fn configured_inactivity_timeout_is_retained_for_process_acquisition() {
        let executable = KwtSshExecutable::from_absolute(if cfg!(windows) {
            r"C:\Ghosthub\kwt.exe"
        } else {
            "/opt/ghosthub/kwt"
        })
        .expect("absolute helper");
        let client =
            KwtSshLeaseClient::new(executable).with_inactivity_timeout(Duration::from_millis(10));
        assert_eq!(client.inactivity_timeout, Duration::from_millis(10));
    }

    #[test]
    fn reader_shutdown_drops_a_full_channel_before_joining() {
        let (sender, receiver) = sync_channel(1);
        sender
            .send(StreamItem::Line(b"queued".to_vec()))
            .expect("prime bounded output channel");
        let reader = thread::spawn(move || {
            assert!(
                sender.send(StreamItem::Line(b"blocked".to_vec())).is_err(),
                "dropping the receiver must unblock the reader"
            );
        });
        let mut receiver = Some(receiver);
        let mut stdout_reader = Some(reader);
        let mut stderr_reader = None;

        finish_stream_readers(&mut receiver, &mut stdout_reader, &mut stderr_reader);

        assert!(receiver.is_none());
        assert!(stdout_reader.is_none());
    }

    #[test]
    fn prompt_deadlines_require_canonical_rfc3339_instants() {
        let epoch = parse_rfc3339("1970-01-01T00:00:00Z").expect("Unix epoch");
        assert_eq!(epoch, UNIX_EPOCH);
        let offset = parse_rfc3339("1970-01-01T01:00:00+01:00").expect("offset epoch");
        assert_eq!(offset, UNIX_EPOCH);
        let fractional = parse_rfc3339("1970-01-01T00:00:00.125Z").expect("fractional epoch");
        assert_eq!(
            fractional.duration_since(UNIX_EPOCH).expect("after epoch"),
            Duration::from_millis(125)
        );

        for invalid in [
            "2026-08-15T12:00:30",
            "2026-02-29T12:00:30Z",
            "2026-08-15T24:00:30Z",
            "2026-08-15T12:00:30.1234567890Z",
        ] {
            assert!(parse_rfc3339(invalid).is_none(), "must reject {invalid}");
        }
    }

    #[test]
    fn standalone_failure_envelope_precedes_lease_event_decoding() {
        let mut decoder = SshLeaseStream::new();
        let error = accept_lease_line(
            &mut decoder,
            br#"{"error":{"code":"ssh_route_unreviewable","message":"route changed","retryable":true}}"#,
            &route(),
        )
        .expect_err("standalone failure must retain its KWT classification");

        assert_eq!(error.code(), Some("ssh_route_unreviewable"));
        assert_eq!(error.to_string(), "route changed");
        assert!(error.retryable());
        assert_eq!(error.kind(), DiagnosticKind::UnsupportedEnvironment);
    }

    #[test]
    fn final_lease_owner_releases_by_closing_stdin() {
        let marker =
            std::env::temp_dir().join(format!("ghosthub-ssh-lease-release-{}", std::process::id()));
        let _ignored = std::fs::remove_file(&marker);
        let complete = r#"{"operation_id":"op-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":7,"mode":"multiplexed","arguments":["-S","control-path","-o","ProxyCommand=/usr/bin/false"]}}"#;
        #[cfg(windows)]
        let command = {
            let marker = marker.to_string_lossy().replace('\'', "''");
            CommandPrefix::new(
                "powershell.exe",
                [
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    &format!(
                        "[Console]::Out.WriteLine('{complete}'); while ($null -ne [Console]::In.ReadLine()) {{}}; [IO.File]::WriteAllText('{marker}', 'released'); #"
                    ),
                ]
                .map(OsString::from)
                .to_vec(),
            )
        };
        #[cfg(not(windows))]
        let command = {
            let marker = marker.to_string_lossy().replace('\'', "'\\''");
            CommandPrefix::new(
                "/bin/sh",
                vec![
                    "-c".into(),
                    format!(
                        "printf '%s\\n' '{complete}'; cat >/dev/null; printf released > '{marker}'"
                    )
                    .into(),
                ],
            )
        };
        let lease = KwtSshLeaseClient::with_command(command)
            .acquire(
                &route(),
                &CancellationToken::new(),
                |_| Err(SshError::prompt_cancelled()),
                |_| {},
            )
            .expect("acquire scripted lease");
        let final_owner = lease.clone();
        drop(lease);
        thread::sleep(Duration::from_millis(50));
        assert!(
            !marker.exists(),
            "dropping a non-final clone must retain the lease"
        );
        drop(final_owner);
        let deadline = Instant::now() + Duration::from_secs(3);
        while !marker.exists() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(25));
        }
        assert_eq!(
            std::fs::read_to_string(&marker).expect("graceful release marker"),
            "released"
        );
        std::fs::remove_file(marker).expect("remove release marker");
    }

    #[test]
    fn cancelled_prompt_response_never_reaches_the_controller() {
        let cancellation = CancellationToken::new();
        let (sender, receiver) = sync_channel(1);
        cancellation.cancel();
        let error = while_acquisition_active(&cancellation, || {
            sender
                .try_send(b"credential-must-not-cross".to_vec())
                .map_err(|_| SshError::new(DiagnosticKind::Transport, "queue failed"))
        })
        .expect_err("cancelled prompt must abort before queueing");

        assert_eq!(error.kind(), DiagnosticKind::Transport);
        assert!(
            receiver.try_recv().is_err(),
            "cancelled credential reached KWT"
        );
    }

    #[test]
    fn cancelled_acquisition_rejects_a_decoded_completion() {
        let cancellation = CancellationToken::new();
        cancellation.cancel();

        let error = require_active_acquisition(&cancellation)
            .expect_err("cancelled completion must not become a lease");

        assert_eq!(error.kind(), DiagnosticKind::Transport);
    }

    #[test]
    fn pre_cancelled_acquisition_never_attempts_to_spawn_the_controller() {
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        let missing = if cfg!(windows) {
            r"C:\definitely-missing\ghosthub-kwt.exe"
        } else {
            "/definitely-missing/ghosthub-kwt"
        };

        let error = KwtSshLeaseClient::with_command(CommandPrefix::native(missing))
            .acquire(
                &route(),
                &cancellation,
                |_| Err(SshError::prompt_cancelled()),
                |_| {},
            )
            .expect_err("pre-cancelled acquisition must not spawn KWT");

        assert_eq!(error.to_string(), "SSH lease acquisition cancelled");
    }

    #[test]
    fn cancellation_before_containment_skips_attachment() {
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        let mut attached = false;

        let error = while_acquisition_active(&cancellation, || {
            attached = true;
            Ok(())
        })
        .expect_err("cancelled child must not be attached or resumed");

        assert_eq!(error.to_string(), "SSH lease acquisition cancelled");
        assert!(!attached);
    }

    #[test]
    fn controller_resume_is_atomic_with_cancellation() {
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let entered = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let cancel_started = Arc::new(Barrier::new(2));
        let order = Arc::new(AtomicUsize::new(0));
        let resume_order = Arc::new(AtomicUsize::new(usize::MAX));
        let cancel_order = Arc::new(AtomicUsize::new(usize::MAX));
        let worker = {
            let entered = Arc::clone(&entered);
            let release = Arc::clone(&release);
            let order = Arc::clone(&order);
            let resume_order = Arc::clone(&resume_order);
            thread::spawn(move || {
                while_acquisition_active(&worker_cancellation, || {
                    entered.wait();
                    release.wait();
                    resume_order.store(order.fetch_add(1, Ordering::AcqRel), Ordering::Release);
                    Ok(())
                })
            })
        };
        entered.wait();
        let (cancelled_tx, cancelled_rx) = mpsc::channel();
        let cancelling = {
            let cancel_started = Arc::clone(&cancel_started);
            let order = Arc::clone(&order);
            let cancel_order = Arc::clone(&cancel_order);
            thread::spawn(move || {
                cancel_started.wait();
                cancellation.cancel();
                cancel_order.store(order.fetch_add(1, Ordering::AcqRel), Ordering::Release);
                cancelled_tx.send(()).expect("cancellation receiver");
            })
        };
        cancel_started.wait();
        let cancellation_overtook_resume =
            cancelled_rx.recv_timeout(Duration::from_millis(50)).is_ok();
        release.wait();
        worker
            .join()
            .expect("resume worker")
            .expect("resume result");
        if !cancellation_overtook_resume {
            cancelled_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("cancellation completes after resume");
        }
        cancelling.join().expect("cancellation worker");

        assert!(!cancellation_overtook_resume);
        assert!(resume_order.load(Ordering::Acquire) < cancel_order.load(Ordering::Acquire));
    }

    #[test]
    fn blocked_credential_write_does_not_block_cancellation() {
        struct BlockingWriter {
            entered: Arc<Barrier>,
            release: Arc<Barrier>,
        }

        impl Write for BlockingWriter {
            fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
                self.entered.wait();
                self.release.wait();
                Ok(buffer.len())
            }

            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }

        let cancellation = CancellationToken::new();
        let entered = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let (prompt_sender, prompt_receiver) = sync_channel(1);
        let (output_sender, _output_receiver) = sync_channel(1);
        let writer = spawn_prompt_writer(
            BlockingWriter {
                entered: Arc::clone(&entered),
                release: Arc::clone(&release),
            },
            prompt_receiver,
            output_sender,
        );
        while_acquisition_active(&cancellation, || {
            prompt_sender
                .try_send(b"secret".to_vec())
                .map_err(|_| SshError::new(DiagnosticKind::Transport, "queue failed"))
        })
        .expect("queue credential while active");
        entered.wait();
        let (cancelled_tx, cancelled_rx) = mpsc::channel();
        let cancelling = thread::spawn(move || {
            cancellation.cancel();
            cancelled_tx.send(()).expect("cancellation receiver");
        });
        let cancelled_while_write_blocked =
            cancelled_rx.recv_timeout(Duration::from_secs(1)).is_ok();
        release.wait();
        cancelling.join().expect("cancellation worker");
        drop(prompt_sender);
        writer.join().expect("prompt writer");

        assert!(cancelled_while_write_blocked);
    }

    #[test]
    fn acquired_lease_reports_an_unexpected_controller_exit() {
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
                &route(),
                &CancellationToken::new(),
                |_| Err(SshError::prompt_cancelled()),
                |_| {},
            )
            .expect("acquire scripted lease before its controller exits");

        let deadline = Instant::now() + Duration::from_secs(3);
        let error = loop {
            match lease.ensure_live() {
                Ok(()) if Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(10));
                }
                Ok(()) => panic!("exited lease remained live"),
                Err(error) => break error,
            }
        };

        assert_eq!(error.kind(), DiagnosticKind::Transport);
        assert!(error.to_string().contains("controller exited"));
    }

    #[test]
    fn controller_activation_is_content_addressed_and_rejects_replacement() {
        let bytes = b"native-controller".to_vec();
        let digest = hex::encode(Sha256::digest(&bytes));
        let bundle = KwtBundle::new("a".repeat(40), digest, bytes.clone()).expect("valid bundle");
        let mut nonce = [0_u8; 16];
        getrandom::fill(&mut nonce).expect("test nonce");
        let root = std::env::temp_dir().join(format!(
            "ghosthub-ssh-controller-test-{}-{}",
            std::process::id(),
            hex::encode(nonce)
        ));

        let executable = KwtSshExecutable::activate(&bundle, &root).expect("activate bundle");
        assert_eq!(
            fs::read(Path::new(executable.as_os_str())).expect("read helper"),
            bytes
        );
        let same = KwtSshExecutable::activate(&bundle, &root).expect("reuse exact helper");
        assert_eq!(same, executable);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let executable_path = Path::new(executable.as_os_str());
            assert_ne!(
                fs::metadata(executable_path)
                    .expect("controller metadata")
                    .permissions()
                    .mode()
                    & 0o100,
                0,
                "new controller must be owner-executable"
            );
            fs::set_permissions(executable_path, fs::Permissions::from_mode(0o600))
                .expect("remove executable permission");
            KwtSshExecutable::activate(&bundle, &root).expect("repair exact helper permissions");
            assert_ne!(
                fs::metadata(executable_path)
                    .expect("repaired controller metadata")
                    .permissions()
                    .mode()
                    & 0o100,
                0,
                "matching controller must regain owner-executable permission"
            );
        }

        fs::write(Path::new(executable.as_os_str()), b"replacement").expect("replace helper");
        let error = KwtSshExecutable::activate(&bundle, &root).expect_err("reject replacement");
        assert_eq!(error.kind(), DiagnosticKind::MalformedOutput);
        fs::remove_dir_all(&root).expect("remove exact test root");
    }
}
