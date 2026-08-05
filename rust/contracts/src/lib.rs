//! Strict loading and consumption accounting for cross-platform contracts.

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt, fs,
    path::{Component, Path, PathBuf},
};

use serde::Deserialize;

const SCHEMA_VERSION: u32 = 1;
const MANIFEST_NAME: &str = "manifest.json";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum PlatformTag {
    Posix,
    Windows,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ErrorKind {
    DuplicateId,
    DuplicatePath,
    InvalidFixturePath,
    InvalidManifest,
    MissingFixture,
    UnconsumedFixtures,
    UnknownFixture,
    UnsupportedSchema,
}

#[derive(Debug, Eq, PartialEq)]
pub struct Error {
    kind: ErrorKind,
    subject: String,
}

impl Error {
    #[must_use]
    pub const fn kind(&self) -> ErrorKind {
        self.kind
    }

    #[must_use]
    pub fn subject(&self) -> &str {
        &self.subject
    }

    fn new(kind: ErrorKind, subject: impl Into<String>) -> Self {
        Self {
            kind,
            subject: subject.into(),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}: {}", self.kind, self.subject)
    }
}

impl std::error::Error for Error {}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestFile {
    schema_version: u32,
    fixtures: Vec<FixtureEntry>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct FixtureEntry {
    id: String,
    suite: String,
    schema_version: u32,
    platforms: Vec<PlatformTag>,
    path: PathBuf,
}

#[derive(Debug)]
pub struct Manifest {
    root: PathBuf,
    fixtures: Vec<FixtureEntry>,
}

impl Manifest {
    /// Load and validate the manifest under `root`.
    ///
    /// # Errors
    ///
    /// Returns an error when the manifest is unreadable or malformed, uses an
    /// unsupported schema, contains duplicate identity, or references an
    /// unsafe or missing fixture path.
    pub fn load(root: &Path) -> Result<Self, Error> {
        let manifest_path = root.join(MANIFEST_NAME);
        let contents = fs::read_to_string(&manifest_path)
            .map_err(|_| Error::new(ErrorKind::InvalidManifest, MANIFEST_NAME))?;
        let parsed: ManifestFile = serde_json::from_str(&contents)
            .map_err(|_| Error::new(ErrorKind::InvalidManifest, MANIFEST_NAME))?;

        if parsed.schema_version != SCHEMA_VERSION {
            return Err(Error::new(ErrorKind::UnsupportedSchema, MANIFEST_NAME));
        }

        let mut ids = BTreeSet::new();
        let mut paths = BTreeSet::new();
        for fixture in &parsed.fixtures {
            if fixture.schema_version != SCHEMA_VERSION {
                return Err(Error::new(ErrorKind::UnsupportedSchema, fixture.id.clone()));
            }
            if !ids.insert(fixture.id.clone()) {
                return Err(Error::new(ErrorKind::DuplicateId, fixture.id.clone()));
            }
            if !paths.insert(fixture.path.clone()) {
                return Err(Error::new(
                    ErrorKind::DuplicatePath,
                    fixture.path.to_string_lossy(),
                ));
            }
            if !is_safe_relative(&fixture.path) {
                return Err(Error::new(
                    ErrorKind::InvalidFixturePath,
                    fixture.id.clone(),
                ));
            }
            if !root.join(&fixture.path).is_file() {
                return Err(Error::new(ErrorKind::MissingFixture, fixture.id.clone()));
            }
        }

        Ok(Self {
            root: root.to_path_buf(),
            fixtures: parsed.fixtures,
        })
    }

    #[must_use]
    pub fn suite<'manifest>(
        &'manifest self,
        suite: &str,
        platforms: &[PlatformTag],
    ) -> SuiteRun<'manifest> {
        let pending = self
            .fixtures
            .iter()
            .filter(|fixture| fixture.suite == suite)
            .filter(|fixture| {
                fixture
                    .platforms
                    .iter()
                    .any(|platform| platforms.contains(platform))
            })
            .map(|fixture| (fixture.id.as_str(), fixture))
            .collect();

        SuiteRun {
            root: &self.root,
            pending,
        }
    }
}

#[derive(Debug)]
pub struct SuiteRun<'manifest> {
    root: &'manifest Path,
    pending: BTreeMap<&'manifest str, &'manifest FixtureEntry>,
}

impl SuiteRun<'_> {
    /// Mark one applicable fixture as consumed and return its resolved path.
    ///
    /// # Errors
    ///
    /// Returns an error when the ID is not applicable to this suite run or
    /// was already consumed.
    pub fn consume(&mut self, id: &str) -> Result<PathBuf, Error> {
        let fixture = self
            .pending
            .remove(id)
            .ok_or_else(|| Error::new(ErrorKind::UnknownFixture, id))?;
        Ok(self.root.join(&fixture.path))
    }

    /// Verify that the suite consumed every applicable fixture exactly once.
    ///
    /// # Errors
    ///
    /// Returns the sorted, comma-separated IDs that were not consumed.
    pub fn finish(self) -> Result<(), Error> {
        if self.pending.is_empty() {
            return Ok(());
        }

        Err(Error::new(
            ErrorKind::UnconsumedFixtures,
            self.pending.keys().copied().collect::<Vec<_>>().join(","),
        ))
    }
}

fn is_safe_relative(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}
