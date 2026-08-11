//! Verified mux identities and capabilities.

use std::ffi::{OsStr, OsString};
use std::fmt;

use serde::Deserialize;
use unicode_segmentation::UnicodeSegmentation;

pub mod probe;

pub const IDENTITY_MISMATCH_MARKER: &str = "__ghosthub_attach_identity_mismatch_v1__";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionName(String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionNameError {
    Empty,
    TooLong,
    ForbiddenCharacter,
}

impl SessionName {
    /// Normalize and validate a user-supplied tmux session name.
    ///
    /// # Errors
    ///
    /// Returns an error for an empty name, a name longer than 100 Unicode
    /// grapheme clusters, or a name containing a control character, period,
    /// number sign, or colon.
    pub fn parse(value: &str) -> Result<Self, SessionNameError> {
        let value = value.trim();
        if value.is_empty() {
            return Err(SessionNameError::Empty);
        }
        if value.graphemes(true).count() > 100 {
            return Err(SessionNameError::TooLong);
        }
        if value
            .chars()
            .any(|character| character.is_control() || matches!(character, '#' | '.' | ':'))
        {
            return Err(SessionNameError::ForbiddenCharacter);
        }
        Ok(Self(value.to_owned()))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for SessionNameError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => formatter.write_str("Name the tmux session."),
            Self::TooLong | Self::ForbiddenCharacter => formatter
                .write_str(
                    "Use 1-100 characters without number signs, periods, colons, or control characters.",
                ),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionIdentity {
    server_pid: u32,
    session_id: String,
    created_at: u64,
}

impl SessionIdentity {
    #[must_use]
    pub fn new(server_pid: u32, session_id: impl Into<String>, created_at: u64) -> Self {
        Self {
            server_pid,
            session_id: session_id.into(),
            created_at,
        }
    }

    #[must_use]
    pub const fn server_pid(&self) -> u32 {
        self.server_pid
    }

    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    #[must_use]
    pub const fn created_at(&self) -> u64 {
        self.created_at
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveredSession {
    name: String,
    identity: SessionIdentity,
    attached_clients: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HerdrSessionName(String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HerdrSessionNameError {
    Empty,
    TooLong,
    ForbiddenCharacter,
}

impl HerdrSessionName {
    /// Normalize and validate a user-supplied Herdr session name.
    ///
    /// # Errors
    ///
    /// Returns an error unless the name contains 1-64 ASCII letters, digits,
    /// periods, underscores, or hyphens and is not `.` or `..`.
    pub fn parse(value: &str) -> Result<Self, HerdrSessionNameError> {
        let value = value.trim();
        if value.is_empty() {
            return Err(HerdrSessionNameError::Empty);
        }
        if value.len() > 64 {
            return Err(HerdrSessionNameError::TooLong);
        }
        if matches!(value, "." | "..")
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(HerdrSessionNameError::ForbiddenCharacter);
        }
        Ok(Self(value.to_owned()))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for HerdrSessionNameError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => formatter.write_str("Name the Herdr session."),
            Self::TooLong | Self::ForbiddenCharacter => formatter
                .write_str("Use 1-64 ASCII letters, numbers, periods, underscores, or hyphens."),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HerdrSessionState {
    Running,
    Stopped,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HerdrLifecycleAction {
    Stop,
    Delete,
}

impl HerdrLifecycleAction {
    #[must_use]
    pub const fn command(self) -> &'static str {
        match self {
            Self::Stop => "stop",
            Self::Delete => "delete",
        }
    }

    #[must_use]
    pub const fn expected_state(self) -> HerdrSessionState {
        match self {
            Self::Stop => HerdrSessionState::Running,
            Self::Delete => HerdrSessionState::Stopped,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HerdrSessionRecord {
    name: String,
    is_default: bool,
    state: HerdrSessionState,
    session_directory: String,
    socket_path: String,
}

/// Exact name carried by a one-shot Herdr launch authority.
///
/// User-authored names can enter only through [`HerdrSessionName`], while
/// names read from Herdr inventory are preserved without applying creation
/// restrictions.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HerdrLaunchTarget(HerdrLaunchTargetSource);

#[derive(Clone, Debug, Eq, PartialEq)]
enum HerdrLaunchTargetSource {
    Created(HerdrSessionName),
    Discovered(String),
}

impl HerdrLaunchTarget {
    #[must_use]
    pub const fn created(name: HerdrSessionName) -> Self {
        Self(HerdrLaunchTargetSource::Created(name))
    }

    #[must_use]
    pub fn discovered(record: &HerdrSessionRecord) -> Self {
        Self(HerdrLaunchTargetSource::Discovered(
            record.name().to_owned(),
        ))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        match &self.0 {
            HerdrLaunchTargetSource::Created(name) => name.as_str(),
            HerdrLaunchTargetSource::Discovered(name) => name,
        }
    }
}

impl HerdrSessionRecord {
    #[must_use]
    pub fn new(
        name: impl Into<String>,
        is_default: bool,
        state: HerdrSessionState,
        session_directory: impl Into<String>,
        socket_path: impl Into<String>,
    ) -> Self {
        Self {
            name: name.into(),
            is_default,
            state,
            session_directory: session_directory.into(),
            socket_path: socket_path.into(),
        }
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub const fn is_default(&self) -> bool {
        self.is_default
    }

    #[must_use]
    pub const fn state(&self) -> HerdrSessionState {
        self.state
    }

    #[must_use]
    pub fn session_directory(&self) -> &str {
        &self.session_directory
    }

    #[must_use]
    pub fn socket_path(&self) -> &str {
        &self.socket_path
    }
}

impl DiscoveredSession {
    #[must_use]
    pub fn new(name: impl Into<String>, identity: SessionIdentity, attached_clients: u32) -> Self {
        Self {
            name: name.into(),
            identity,
            attached_clients,
        }
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub const fn identity(&self) -> &SessionIdentity {
        &self.identity
    }

    #[must_use]
    pub const fn attached_clients(&self) -> u32 {
        self.attached_clients
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AttachPlan {
    program: OsString,
    args: Vec<OsString>,
    target_name: String,
    identity: SessionIdentity,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HerdrAttachPlan {
    program: OsString,
    args: Vec<OsString>,
}

/// One Herdr launch-or-attach action. This constructive authority is consumed
/// by the terminal launcher and is intentionally neither cloneable nor
/// serializable.
#[derive(Debug, Eq, PartialEq)]
pub struct HerdrLaunchOnce {
    program: OsString,
    args: Vec<OsString>,
    target_name: HerdrLaunchTarget,
}

impl HerdrAttachPlan {
    #[must_use]
    pub fn attach_only(program: impl Into<OsString>, args: Vec<OsString>) -> Self {
        Self {
            program: program.into(),
            args,
        }
    }

    #[must_use]
    pub fn program(&self) -> &OsStr {
        &self.program
    }

    #[must_use]
    pub fn args(&self) -> &[OsString] {
        &self.args
    }
}

impl HerdrLaunchOnce {
    #[must_use]
    pub fn launch_or_attach(
        program: impl Into<OsString>,
        args: Vec<OsString>,
        target_name: HerdrLaunchTarget,
    ) -> Self {
        Self {
            program: program.into(),
            args,
            target_name,
        }
    }

    #[must_use]
    pub fn into_parts(self) -> (OsString, Vec<OsString>, HerdrLaunchTarget) {
        (self.program, self.args, self.target_name)
    }
}

/// One atomic local create-or-attach launch. The authority is intentionally
/// neither cloneable nor serializable and is consumed by the terminal launcher.
#[derive(Debug, Eq, PartialEq)]
pub struct CreateOnce {
    program: OsString,
    args: Vec<OsString>,
    target_name: SessionName,
}

impl CreateOnce {
    #[must_use]
    pub fn local_atomic(
        program: impl Into<OsString>,
        args: Vec<OsString>,
        target_name: SessionName,
    ) -> Self {
        Self {
            program: program.into(),
            args,
            target_name,
        }
    }

    #[must_use]
    pub fn into_parts(self) -> (OsString, Vec<OsString>, SessionName) {
        (self.program, self.args, self.target_name)
    }
}

/// One isolated capability probe that may exercise otherwise unavailable mux
/// launch behavior. It is intentionally neither cloneable nor serializable.
#[derive(Debug, Eq, PartialEq)]
pub struct AdmissionPlan {
    program: OsString,
    args: Vec<OsString>,
}

impl AdmissionPlan {
    #[must_use]
    pub fn isolated(program: impl Into<OsString>, args: Vec<OsString>) -> Self {
        Self {
            program: program.into(),
            args,
        }
    }

    #[must_use]
    pub fn program(&self) -> &OsStr {
        &self.program
    }

    #[must_use]
    pub fn args(&self) -> &[OsString] {
        &self.args
    }
}

impl AttachPlan {
    #[must_use]
    pub fn attach_only(
        program: impl Into<OsString>,
        args: Vec<OsString>,
        target_name: impl Into<String>,
        identity: SessionIdentity,
    ) -> Self {
        Self {
            program: program.into(),
            args,
            target_name: target_name.into(),
            identity,
        }
    }

    #[must_use]
    pub fn program(&self) -> &OsStr {
        &self.program
    }

    #[must_use]
    pub fn args(&self) -> &[OsString] {
        &self.args
    }

    #[must_use]
    pub fn target_name(&self) -> &str {
        &self.target_name
    }

    #[must_use]
    pub const fn identity(&self) -> &SessionIdentity {
        &self.identity
    }
}

const REQUIRED_CAPABILITIES: [&str; 7] = [
    "atomic-create-or-attach",
    "new-session-environment",
    "attach-preserve-environment",
    "exact-targets",
    "stable-session-identity",
    "server-instance-identity",
    "isolated-namespace",
];

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ExecutablePlatform {
    Posix,
    Windows,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProbeObservation {
    pub name: String,
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl ProbeObservation {
    #[must_use]
    pub fn is_supported(&self) -> bool {
        self.exit_code == 0 && self.stdout.trim() == "supported" && self.stderr.trim().is_empty()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MuxCapabilities {
    bits: u8,
}

impl MuxCapabilities {
    #[must_use]
    pub const fn all_required(self) -> bool {
        self.bits == 0b0111_1111
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TmuxVersion {
    major: u32,
    minor: u32,
    patch: Option<u32>,
    suffix: Option<char>,
}

impl fmt::Display for TmuxVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}.{}", self.major, self.minor)?;
        if let Some(patch) = self.patch {
            write!(formatter, ".{patch}")?;
        }
        if let Some(suffix) = self.suffix {
            write!(formatter, "{suffix}")?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedTmuxBinary {
    path: String,
    version: TmuxVersion,
    implementation_revision: Option<String>,
    capabilities: MuxCapabilities,
}

impl VerifiedTmuxBinary {
    #[must_use]
    pub const fn version(&self) -> TmuxVersion {
        self.version
    }

    #[must_use]
    pub fn implementation_revision(&self) -> Option<&str> {
        self.implementation_revision.as_deref()
    }

    #[must_use]
    pub const fn capabilities(&self) -> MuxCapabilities {
        self.capabilities
    }

    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ResolveErrorKind {
    InvalidVersion,
    MissingCapability,
    NotAbsolute,
    UnsupportedVersion,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolveError {
    kind: ResolveErrorKind,
    subject: String,
}

impl ResolveError {
    #[must_use]
    pub const fn kind(&self) -> ResolveErrorKind {
        self.kind
    }

    #[must_use]
    pub fn subject(&self) -> &str {
        &self.subject
    }
}

impl fmt::Display for ResolveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}: {}", self.kind, self.subject)
    }
}

impl std::error::Error for ResolveError {}

/// Resolve an executable only after all required behavior probes succeeded.
///
/// # Errors
///
/// Returns a classified error for an invalid path or version, an unsupported
/// tmux protocol version, or the first missing behavioral capability.
pub fn resolve_tmux_binary(
    platform: ExecutablePlatform,
    path: &str,
    version_output: &str,
    observations: &[ProbeObservation],
) -> Result<VerifiedTmuxBinary, ResolveError> {
    if !is_absolute(platform, path) {
        return Err(error(ResolveErrorKind::NotAbsolute, path));
    }

    let version = parse_version(version_output)
        .ok_or_else(|| error(ResolveErrorKind::InvalidVersion, "version-output"))?;
    if (version.major, version.minor) < (3, 2) {
        return Err(error(
            ResolveErrorKind::UnsupportedVersion,
            version.to_string(),
        ));
    }

    for capability in REQUIRED_CAPABILITIES {
        if !observations
            .iter()
            .any(|observation| observation.name == capability && observation.is_supported())
        {
            return Err(error(ResolveErrorKind::MissingCapability, capability));
        }
    }

    Ok(VerifiedTmuxBinary {
        path: path.to_owned(),
        version,
        implementation_revision: parse_revision(version_output),
        capabilities: MuxCapabilities { bits: 0b0111_1111 },
    })
}

fn error(kind: ResolveErrorKind, subject: impl Into<String>) -> ResolveError {
    ResolveError {
        kind,
        subject: subject.into(),
    }
}

fn is_absolute(platform: ExecutablePlatform, path: &str) -> bool {
    match platform {
        ExecutablePlatform::Posix => path.starts_with('/'),
        ExecutablePlatform::Windows => {
            let bytes = path.as_bytes();
            bytes.len() >= 3
                && bytes[0].is_ascii_alphabetic()
                && bytes[1] == b':'
                && matches!(bytes[2], b'\\' | b'/')
        }
    }
}

fn parse_version(output: &str) -> Option<TmuxVersion> {
    let value = output.lines().find_map(|line| line.strip_prefix("tmux "))?;
    let (major, remainder) = value.trim().split_once('.')?;
    let major = major.parse().ok()?;
    let minor_end = remainder
        .find(|character: char| !character.is_ascii_digit())
        .unwrap_or(remainder.len());
    let (minor, remainder) = remainder.split_at(minor_end);
    let minor = minor.parse().ok()?;
    let (patch, suffix) = match remainder.as_bytes() {
        [] => (None, None),
        [suffix] if suffix.is_ascii_alphabetic() => (None, Some(char::from(*suffix))),
        [b'.', rest @ ..] => {
            let patch_end = rest
                .iter()
                .position(|byte| !byte.is_ascii_digit())
                .unwrap_or(rest.len());
            let (patch, suffix) = rest.split_at(patch_end);
            let patch = std::str::from_utf8(patch).ok()?.parse().ok()?;
            let suffix = match suffix {
                [] => None,
                [suffix] if suffix.is_ascii_alphabetic() => Some(char::from(*suffix)),
                _ => return None,
            };
            (Some(patch), suffix)
        }
        _ => return None,
    };
    Some(TmuxVersion {
        major,
        minor,
        patch,
        suffix,
    })
}

fn parse_revision(output: &str) -> Option<String> {
    let line = output.lines().find(|line| line.starts_with("psmux "))?;
    let parenthesized = line.split_once('(')?.1.strip_suffix(')')?;
    parenthesized.split_whitespace().next().map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::{
        CreateOnce, HerdrLaunchOnce, HerdrLaunchTarget, HerdrSessionName, HerdrSessionNameError,
        HerdrSessionRecord, HerdrSessionState, SessionName, SessionNameError,
    };
    use static_assertions::assert_not_impl_any;

    assert_not_impl_any!(CreateOnce: Clone, serde::Serialize);
    assert_not_impl_any!(HerdrLaunchOnce: Clone, serde::Serialize);

    #[test]
    fn herdr_session_names_match_the_shipped_creation_contract() {
        assert_eq!(
            HerdrSessionName::parse("  review.fix_1  ")
                .expect("valid name")
                .as_str(),
            "review.fix_1"
        );
        assert_eq!(
            HerdrSessionName::parse(" "),
            Err(HerdrSessionNameError::Empty)
        );
        assert_eq!(
            HerdrSessionName::parse("."),
            Err(HerdrSessionNameError::ForbiddenCharacter)
        );
        assert_eq!(
            HerdrSessionName::parse("has space"),
            Err(HerdrSessionNameError::ForbiddenCharacter)
        );
        assert_eq!(
            HerdrSessionName::parse(&"x".repeat(65)),
            Err(HerdrSessionNameError::TooLong)
        );
    }

    #[test]
    fn discovered_herdr_names_bypass_creation_only_restrictions() {
        let record = HerdrSessionRecord::new(
            "review session",
            false,
            HerdrSessionState::Stopped,
            "/tmp/herdr/review session",
            "/tmp/herdr/review session/herdr.sock",
        );

        assert!(HerdrSessionName::parse(record.name()).is_err());
        assert_eq!(
            HerdrLaunchTarget::discovered(&record).as_str(),
            record.name()
        );
    }

    #[test]
    fn session_names_match_the_shipped_creation_contract() {
        assert_eq!(
            SessionName::parse("  release work  ")
                .expect("valid name")
                .as_str(),
            "release work"
        );
        assert_eq!(SessionName::parse("  "), Err(SessionNameError::Empty));
        assert_eq!(
            SessionName::parse("has.period"),
            Err(SessionNameError::ForbiddenCharacter)
        );
        assert_eq!(
            SessionName::parse("has:colon"),
            Err(SessionNameError::ForbiddenCharacter)
        );
        assert_eq!(
            SessionName::parse("#(touch /tmp/ghosthub-owned)"),
            Err(SessionNameError::ForbiddenCharacter)
        );
        assert_eq!(
            SessionName::parse("has\nnewline"),
            Err(SessionNameError::ForbiddenCharacter)
        );
        assert_eq!(
            SessionName::parse(&"x".repeat(101)),
            Err(SessionNameError::TooLong)
        );
        assert!(
            SessionName::parse(&"e\u{301}".repeat(100)).is_ok(),
            "Swift-compatible character counting treats combining sequences as one name character"
        );
    }

    #[test]
    fn create_once_is_consumed_into_one_exact_argv() {
        let plan = CreateOnce::local_atomic(
            "wsl.exe",
            vec![
                "new-session".into(),
                "-A".into(),
                "-s".into(),
                "demo".into(),
            ],
            SessionName::parse("demo").expect("valid name"),
        );
        let (program, args, target) = plan.into_parts();

        assert_eq!(program, "wsl.exe");
        assert_eq!(
            args,
            ["new-session", "-A", "-s", "demo"]
                .into_iter()
                .map(std::ffi::OsString::from)
                .collect::<Vec<_>>()
        );
        assert_eq!(target.as_str(), "demo");
    }
}
