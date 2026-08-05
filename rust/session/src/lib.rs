//! Verified mux identities and capabilities.

use std::fmt;

use serde::Deserialize;

pub mod probe;

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
    patch: u32,
}

impl fmt::Display for TmuxVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}.{}.{}", self.major, self.minor, self.patch)
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
        if !observations.iter().any(|observation| {
            observation.name == capability
                && observation.exit_code == 0
                && observation.stdout.trim() == "supported"
                && observation.stderr.trim().is_empty()
        }) {
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
    let mut numbers = value.trim().split('.');
    let major = numbers.next()?.parse().ok()?;
    let minor = numbers.next()?.parse().ok()?;
    let patch = numbers.next().map_or(Some(0), |value| value.parse().ok())?;
    if numbers.next().is_some() {
        return None;
    }
    Some(TmuxVersion {
        major,
        minor,
        patch,
    })
}

fn parse_revision(output: &str) -> Option<String> {
    let line = output.lines().find(|line| line.starts_with("psmux "))?;
    let parenthesized = line.split_once('(')?.1.strip_suffix(')')?;
    parenthesized.split_whitespace().next().map(str::to_owned)
}
