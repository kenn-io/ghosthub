use std::fmt;
use std::sync::Arc;

use serde::{Deserialize, Deserializer, de};

#[derive(Clone, Eq, PartialEq)]
pub struct KwtBundle {
    revision: String,
    sha256: String,
    bytes: Arc<[u8]>,
}

impl KwtBundle {
    /// Construct an exact revision-pinned KWT helper bundle.
    ///
    /// # Errors
    ///
    /// Returns an error when metadata is malformed or the payload is empty.
    pub fn new(
        revision: impl Into<String>,
        sha256: impl Into<String>,
        bytes: impl Into<Arc<[u8]>>,
    ) -> Result<Self, String> {
        let revision = revision.into();
        let sha256 = sha256.into();
        let bytes = bytes.into();
        if revision.len() != 40
            || !revision
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err("KWT revision must be a lowercase 40-character Git revision".to_owned());
        }
        if sha256.len() != 64
            || !sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err("KWT digest must be a lowercase SHA-256 value".to_owned());
        }
        if bytes.is_empty() {
            return Err("KWT helper bundle is empty".to_owned());
        }
        Ok(Self {
            revision,
            sha256,
            bytes,
        })
    }

    #[must_use]
    pub fn revision(&self) -> &str {
        &self.revision
    }

    #[must_use]
    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    #[must_use]
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

impl fmt::Debug for KwtBundle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("KwtBundle")
            .field("revision", &self.revision)
            .field("sha256", &self.sha256)
            .field("bytes", &format_args!("<{} bytes>", self.bytes.len()))
            .finish()
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct KwtProject {
    repository: String,
    name: String,
    path: String,
    last_touched: Option<String>,
    #[serde(deserialize_with = "deserialize_nonempty_string")]
    registration_fingerprint: String,
}

fn deserialize_nonempty_string<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    if value.is_empty() {
        return Err(de::Error::custom(
            "KWT registration_fingerprint must not be empty",
        ));
    }
    Ok(value)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct KwtProjectMutation {
    status: String,
    project: KwtProject,
}

#[derive(Debug, Deserialize)]
struct KwtCommandErrorEnvelope {
    error: KwtCommandError,
}

#[derive(Debug, Deserialize)]
struct KwtCommandError {
    code: String,
    message: String,
    retryable: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct KwtCommandFailure {
    code: String,
    message: String,
    retryable: bool,
}

impl KwtCommandFailure {
    pub(crate) fn code(&self) -> &str {
        &self.code
    }

    pub(crate) fn message(&self) -> &str {
        &self.message
    }

    pub(crate) const fn retryable(&self) -> bool {
        self.retryable
    }
}

impl KwtProject {
    #[must_use]
    pub fn repository(&self) -> &str {
        &self.repository
    }
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }
    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }
    #[must_use]
    pub fn last_touched(&self) -> Option<&str> {
        self.last_touched.as_deref()
    }
    #[must_use]
    pub fn registration_fingerprint(&self) -> &str {
        &self.registration_fingerprint
    }
}

pub(crate) fn parse_project_mutation(
    output: &[u8],
    expected_status: &str,
) -> Result<KwtProject, String> {
    let response: KwtProjectMutation =
        serde_json::from_slice(output).map_err(|error| error.to_string())?;
    if response.status != expected_status {
        return Err(format!(
            "expected KWT project status {expected_status:?}, received {:?}",
            response.status
        ));
    }
    Ok(response.project)
}

pub(crate) fn parse_command_failure(output: &[u8]) -> Option<KwtCommandFailure> {
    let response: KwtCommandErrorEnvelope = serde_json::from_slice(output).ok()?;
    Some(KwtCommandFailure {
        code: response.error.code,
        message: response.error.message,
        retryable: response.error.retryable,
    })
}

/// Decode a machine-readable KWT command failure for presentation by an
/// owning workflow layer.
#[must_use]
pub fn kwt_command_failure_message(output: &[u8]) -> Option<String> {
    let failure = parse_command_failure(output)?;
    Some(format!("{} ({})", failure.message(), failure.code()))
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct KwtWorktree {
    path: String,
    branch: String,
    commit_hash: String,
    is_main: bool,
    created_at: Option<String>,
    generation: Option<String>,
    repository: String,
    session_name: String,
    tmux_socket_name: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct KwtBranchCandidate {
    name: String,
    source: String,
    is_remote: bool,
    #[serde(default)]
    #[serde(rename = "label")]
    _label: String,
    #[serde(default)]
    #[serde(rename = "is_current")]
    _is_current: bool,
    #[serde(default)]
    #[serde(rename = "last_commit")]
    _last_commit: Option<serde_json::Value>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct KwtPullRequest {
    id: String,
    provider: String,
    repository: KwtPullRequestRepository,
    number: u64,
    url: String,
    title: String,
    author: String,
    source: KwtPullRequestBranch,
    target: KwtPullRequestBranch,
    draft: bool,
    state: String,
    head_sha: String,
    #[serde(default)]
    merged_at: Option<String>,
    imported: bool,
    #[serde(default)]
    workspace: Option<KwtImportedWorkspace>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct KwtPullRequestRepository {
    provider: String,
    identity: String,
    host: String,
    owner: String,
    name: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct KwtPullRequestBranch {
    branch: String,
    repository: KwtPullRequestRepository,
    is_fork: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct KwtImportedWorkspace {
    id: String,
    repository: String,
    branch: String,
    path: String,
    #[serde(default)]
    generation: Option<String>,
    state: String,
    session_name: String,
    #[serde(default)]
    tmux_socket_name: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct KwtPullRequestList {
    pull_requests: Vec<KwtPullRequest>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct KwtPullRequestImport {
    status: String,
    pull_request: KwtPullRequest,
    project: KwtPullRequestProject,
    workspace: KwtImportedWorkspace,
    #[serde(default)]
    session_start_error: Option<serde_json::Value>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtPullRequestImportRequest {
    project_path: String,
    repository: String,
    registration_fingerprint: String,
    selector: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct KwtPullRequestProject {
    identity: String,
    name: String,
    path: String,
}

impl KwtPullRequestImportRequest {
    #[must_use]
    pub fn new(
        project_path: impl Into<String>,
        repository: impl Into<String>,
        registration_fingerprint: impl Into<String>,
        selector: impl Into<String>,
    ) -> Self {
        Self {
            project_path: project_path.into(),
            repository: repository.into(),
            registration_fingerprint: registration_fingerprint.into(),
            selector: selector.into(),
        }
    }

    pub(crate) fn project_path(&self) -> &str {
        &self.project_path
    }

    pub(crate) fn repository(&self) -> &str {
        &self.repository
    }

    pub(crate) fn registration_fingerprint(&self) -> &str {
        &self.registration_fingerprint
    }

    pub(crate) fn selector(&self) -> &str {
        &self.selector
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtWorktreeCreate {
    project_path: String,
    repository: String,
    registration_fingerprint: String,
    branch: String,
    source: Option<String>,
    creates_branch: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtWorktreeOpen {
    path: String,
    repository: String,
    registration_fingerprint: String,
    generation: String,
    session_name: String,
}

impl KwtWorktreeOpen {
    #[must_use]
    pub fn new(
        path: impl Into<String>,
        repository: impl Into<String>,
        registration_fingerprint: impl Into<String>,
        generation: impl Into<String>,
        session_name: impl Into<String>,
    ) -> Self {
        Self {
            path: path.into(),
            repository: repository.into(),
            registration_fingerprint: registration_fingerprint.into(),
            generation: generation.into(),
            session_name: session_name.into(),
        }
    }

    pub(crate) fn path(&self) -> &str {
        &self.path
    }

    pub(crate) fn repository(&self) -> &str {
        &self.repository
    }

    pub(crate) fn registration_fingerprint(&self) -> &str {
        &self.registration_fingerprint
    }

    pub(crate) fn generation(&self) -> &str {
        &self.generation
    }

    #[must_use]
    pub fn session_name(&self) -> &str {
        &self.session_name
    }
}

impl KwtWorktreeCreate {
    #[must_use]
    pub fn new(
        project_path: impl Into<String>,
        repository: impl Into<String>,
        registration_fingerprint: impl Into<String>,
        branch: impl Into<String>,
        source: Option<String>,
        creates_branch: bool,
    ) -> Self {
        Self {
            project_path: project_path.into(),
            repository: repository.into(),
            registration_fingerprint: registration_fingerprint.into(),
            branch: branch.into(),
            source,
            creates_branch,
        }
    }

    #[must_use]
    pub fn project_path(&self) -> &str {
        &self.project_path
    }

    #[must_use]
    pub fn repository(&self) -> &str {
        &self.repository
    }

    #[must_use]
    pub fn registration_fingerprint(&self) -> &str {
        &self.registration_fingerprint
    }

    #[must_use]
    pub fn branch(&self) -> &str {
        &self.branch
    }

    #[must_use]
    pub fn source(&self) -> Option<&str> {
        self.source.as_deref()
    }

    #[must_use]
    pub const fn creates_branch(&self) -> bool {
        self.creates_branch
    }
}

impl KwtBranchCandidate {
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub fn source(&self) -> &str {
        &self.source
    }

    #[must_use]
    pub const fn is_remote(&self) -> bool {
        self.is_remote
    }
}

pub(crate) fn parse_branches(output: &[u8]) -> Result<Vec<KwtBranchCandidate>, serde_json::Error> {
    serde_json::from_slice(output)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtProtectedWorktreeOpen {
    path: String,
    project_path: String,
    repository: String,
    registration_fingerprint: String,
    generation: String,
    session_name: String,
    tmux_socket_name: String,
}

impl KwtProtectedWorktreeOpen {
    #[must_use]
    pub fn new(
        path: impl Into<String>,
        project_path: impl Into<String>,
        repository: impl Into<String>,
        registration_fingerprint: impl Into<String>,
        generation: impl Into<String>,
        session_name: impl Into<String>,
        tmux_socket_name: impl Into<String>,
    ) -> Self {
        Self {
            path: path.into(),
            project_path: project_path.into(),
            repository: repository.into(),
            registration_fingerprint: registration_fingerprint.into(),
            generation: generation.into(),
            session_name: session_name.into(),
            tmux_socket_name: tmux_socket_name.into(),
        }
    }

    pub(crate) fn path(&self) -> &str {
        &self.path
    }
    pub(crate) fn repository(&self) -> &str {
        &self.repository
    }
    pub(crate) fn project_path(&self) -> &str {
        &self.project_path
    }
    pub(crate) fn registration_fingerprint(&self) -> &str {
        &self.registration_fingerprint
    }
    pub(crate) fn generation(&self) -> &str {
        &self.generation
    }
    #[must_use]
    pub fn session_name(&self) -> &str {
        &self.session_name
    }
    #[must_use]
    pub fn tmux_socket_name(&self) -> &str {
        &self.tmux_socket_name
    }
}

pub(crate) fn parse_pull_requests(output: &[u8]) -> Result<Vec<KwtPullRequest>, serde_json::Error> {
    serde_json::from_slice::<KwtPullRequestList>(output).map(|response| response.pull_requests)
}

pub(crate) fn parse_pull_request_import(output: &[u8]) -> Result<KwtPullRequestImport, String> {
    let response: KwtPullRequestImport =
        serde_json::from_slice(output).map_err(|error| error.to_string())?;
    if !matches!(response.status.as_str(), "created" | "already_imported") {
        return Err(format!(
            "unexpected KWT pull-request import status {:?}",
            response.status
        ));
    }
    if response
        .workspace
        .tmux_socket_name
        .as_deref()
        .is_none_or(str::is_empty)
    {
        return Err("KWT pull-request import omitted its protected tmux socket".to_owned());
    }
    Ok(response)
}

impl KwtPullRequest {
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }
    #[must_use]
    pub const fn number(&self) -> u64 {
        self.number
    }
    #[must_use]
    pub fn url(&self) -> &str {
        &self.url
    }
    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }
    #[must_use]
    pub fn author(&self) -> &str {
        &self.author
    }
    #[must_use]
    pub fn source_branch(&self) -> &str {
        &self.source.branch
    }
    #[must_use]
    pub const fn draft(&self) -> bool {
        self.draft
    }
    #[must_use]
    pub const fn imported(&self) -> bool {
        self.imported
    }
}

impl KwtImportedWorkspace {
    #[must_use]
    pub fn repository(&self) -> &str {
        &self.repository
    }
    #[must_use]
    pub fn branch(&self) -> &str {
        &self.branch
    }
    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }
    #[must_use]
    pub fn generation(&self) -> Option<&str> {
        self.generation.as_deref()
    }
    #[must_use]
    pub fn session_name(&self) -> &str {
        &self.session_name
    }
    #[must_use]
    pub fn tmux_socket_name(&self) -> Option<&str> {
        self.tmux_socket_name.as_deref()
    }
}

impl KwtPullRequestImport {
    #[must_use]
    pub fn workspace(&self) -> &KwtImportedWorkspace {
        &self.workspace
    }
    #[must_use]
    pub fn project_identity(&self) -> &str {
        &self.project.identity
    }
    #[must_use]
    pub fn project_path(&self) -> &str {
        &self.project.path
    }
}

impl KwtWorktree {
    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }
    #[must_use]
    pub fn branch(&self) -> &str {
        &self.branch
    }
    #[must_use]
    pub fn commit_hash(&self) -> &str {
        &self.commit_hash
    }
    #[must_use]
    pub const fn is_main(&self) -> bool {
        self.is_main
    }
    #[must_use]
    pub fn created_at(&self) -> Option<&str> {
        self.created_at.as_deref()
    }
    #[must_use]
    pub fn generation(&self) -> Option<&str> {
        self.generation.as_deref()
    }
    #[must_use]
    pub fn repository(&self) -> &str {
        &self.repository
    }
    #[must_use]
    pub fn session_name(&self) -> &str {
        &self.session_name
    }
    #[must_use]
    pub fn tmux_socket_name(&self) -> Option<&str> {
        self.tmux_socket_name.as_deref()
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct KwtDirectoryWorkspace {
    name: String,
    path: String,
    session_name: String,
    session_live: bool,
}

impl KwtDirectoryWorkspace {
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }
    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }
    #[must_use]
    pub fn session_name(&self) -> &str {
        &self.session_name
    }
    #[must_use]
    pub const fn session_live(&self) -> bool {
        self.session_live
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtProjectInventory {
    project: KwtProject,
    worktrees: Vec<KwtWorktree>,
}

impl KwtProjectInventory {
    #[must_use]
    pub const fn project(&self) -> &KwtProject {
        &self.project
    }
    #[must_use]
    pub fn worktrees(&self) -> &[KwtWorktree] {
        &self.worktrees
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct KwtInventory {
    projects: Vec<KwtProjectInventory>,
    directory_workspaces: Vec<KwtDirectoryWorkspace>,
}

impl KwtInventory {
    /// Decode the three supported KWT machine-readable inventory surfaces.
    ///
    /// Worktrees are joined to projects by KWT's repository identity. Unknown
    /// repositories remain excluded until a project record makes them usable.
    ///
    /// # Errors
    ///
    /// Returns the first JSON schema or decoding error from any surface.
    pub fn parse(
        projects: &[u8],
        worktrees: &[u8],
        directory_workspaces: &[u8],
    ) -> Result<Self, serde_json::Error> {
        let projects: Vec<KwtProject> = serde_json::from_slice(projects)?;
        let mut worktrees: Vec<KwtWorktree> = serde_json::from_slice(worktrees)?;
        let directory_workspaces = serde_json::from_slice(directory_workspaces)?;
        let projects = projects
            .into_iter()
            .map(|project| {
                let (matching, remaining): (Vec<_>, Vec<_>) = std::mem::take(&mut worktrees)
                    .into_iter()
                    .partition(|worktree| worktree.repository == project.repository);
                worktrees = remaining;
                KwtProjectInventory {
                    project,
                    worktrees: matching,
                }
            })
            .collect();
        Ok(Self {
            projects,
            directory_workspaces,
        })
    }

    #[must_use]
    pub fn projects(&self) -> &[KwtProjectInventory] {
        &self.projects
    }
    #[must_use]
    pub fn directory_workspaces(&self) -> &[KwtDirectoryWorkspace] {
        &self.directory_workspaces
    }
}

#[cfg(test)]
mod tests {
    use super::{
        KwtBundle, KwtInventory, parse_command_failure, parse_project_mutation,
        parse_pull_request_import, parse_pull_requests,
    };

    #[test]
    fn bundle_rejects_ambiguous_metadata_and_hides_payload_in_debug() {
        assert!(KwtBundle::new("ABC", "00", [1_u8]).is_err());
        let bundle =
            KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8, 2, 3]).expect("valid bundle");
        let debug = format!("{bundle:?}");
        assert!(debug.contains("<3 bytes>"));
        assert!(!debug.contains("[1, 2, 3]"));
    }

    #[test]
    fn inventory_joins_global_worktrees_without_reordering_projects() {
        let inventory = KwtInventory::parse(
            br#"[{"repository":"two","name":"Second","path":"/r/two","last_touched":null,"registration_fingerprint":"two-fingerprint"},{"repository":"one","name":"First","path":"/r/one","last_touched":"now","registration_fingerprint":"one-fingerprint"}]"#,
            br#"[{"path":"/w/one","branch":"main","commit_hash":"abc","is_main":true,"created_at":null,"generation":"g1","repository":"one","session_name":"one-main","tmux_socket_name":null},{"path":"/w/two","branch":"topic","commit_hash":"def","is_main":false,"created_at":"then","generation":null,"repository":"two","session_name":"two-topic","tmux_socket_name":"alt"}]"#,
            br#"[{"name":"scratch","path":"/w/scratch","session_name":"scratch","session_live":false}]"#,
        ).expect("valid inventory");

        assert_eq!(inventory.projects()[0].project().repository(), "two");
        assert_eq!(inventory.projects()[0].worktrees()[0].branch(), "topic");
        assert_eq!(
            inventory.projects()[1].worktrees()[0].session_name(),
            "one-main"
        );
        assert_eq!(inventory.directory_workspaces()[0].name(), "scratch");
    }

    #[test]
    fn inventory_rejects_schema_drift() {
        let error = KwtInventory::parse(
            br#"[{"repository":"one","name":"One","path":"/r/one","last_touched":null,"registration_fingerprint":"one-fingerprint","surprise":true}]"#,
            b"[]",
            b"[]",
        );
        assert!(error.is_err());
    }

    #[test]
    fn inventory_rejects_an_empty_registration_fingerprint() {
        let error = KwtInventory::parse(
            br#"[{"repository":"one","name":"One","path":"/r/one","last_touched":null,"registration_fingerprint":""}]"#,
            b"[]",
            b"[]",
        );
        assert!(error.is_err());
    }

    #[test]
    fn project_mutations_require_the_expected_machine_status() {
        let registered = parse_project_mutation(
            br#"{"status":"registered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"opaque-registration"}}"#,
            "registered",
        )
        .expect("valid registration");
        assert_eq!(registered.path(), "/code/widget");
        assert!(
            parse_project_mutation(
                br#"{"status":"unregistered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"opaque-registration"}}"#,
                "registered",
            )
            .is_err()
        );
    }

    #[test]
    fn project_command_errors_preserve_retry_guidance() {
        let failure = parse_command_failure(
            br#"{"error":{"code":"registration_changed","message":"the project changed","retryable":true}}"#,
        )
        .expect("structured KWT failure");
        assert_eq!(failure.code(), "registration_changed");
        assert_eq!(failure.message(), "the project changed");
        assert!(failure.retryable());
    }

    #[test]
    fn pull_request_contract_preserves_provider_identity_and_protected_socket() {
        let pull_requests = parse_pull_requests(br#"{"pull_requests":[{"id":"github:github.com/acme/widget#17","provider":"github","repository":{"provider":"github","identity":"github.com/acme/widget","host":"github.com","owner":"acme","name":"widget"},"number":17,"url":"https://github.com/acme/widget/pull/17","title":"Improve rendering","author":"octocat","source":{"branch":"feature/rendering","repository":{"provider":"github","identity":"github.com/octocat/widget","host":"github.com","owner":"octocat","name":"widget"},"is_fork":true},"target":{"branch":"main","repository":{"provider":"github","identity":"github.com/acme/widget","host":"github.com","owner":"acme","name":"widget"},"is_fork":false},"draft":false,"state":"open","head_sha":"0123456789abcdef0123456789abcdef01234567","imported":false}]}"#).expect("valid PR list");
        assert_eq!(pull_requests[0].number(), 17);
        assert_eq!(pull_requests[0].source_branch(), "feature/rendering");

        let imported = parse_pull_request_import(br#"{"status":"created","pull_request":{"id":"github:github.com/acme/widget#17","provider":"github","repository":{"provider":"github","identity":"github.com/acme/widget","host":"github.com","owner":"acme","name":"widget"},"number":17,"url":"https://github.com/acme/widget/pull/17","title":"Improve rendering","author":"octocat","source":{"branch":"feature/rendering","repository":{"provider":"github","identity":"github.com/octocat/widget","host":"github.com","owner":"octocat","name":"widget"},"is_fork":true},"target":{"branch":"main","repository":{"provider":"github","identity":"github.com/acme/widget","host":"github.com","owner":"acme","name":"widget"},"is_fork":false},"draft":false,"state":"open","head_sha":"0123456789abcdef0123456789abcdef01234567","imported":true,"workspace":{"id":"workspace","repository":"github.com/acme/widget","branch":"pr-17-feature-rendering","path":"/worktrees/pr-17","generation":"11111111111111111111111111111111","state":"ready","session_name":"widget-pr-17","tmux_socket_name":"kwt-pr-a1b2"}},"project":{"identity":"github.com/acme/widget","name":"widget","path":"/code/widget"},"workspace":{"id":"workspace","repository":"github.com/acme/widget","branch":"pr-17-feature-rendering","path":"/worktrees/pr-17","generation":"11111111111111111111111111111111","state":"ready","session_name":"widget-pr-17","tmux_socket_name":"kwt-pr-a1b2"}}"#).expect("valid import");
        assert_eq!(imported.workspace().tmux_socket_name(), Some("kwt-pr-a1b2"));
    }

    #[test]
    fn pull_request_import_rejects_missing_protected_socket() {
        let result = parse_pull_request_import(br#"{"status":"created","pull_request":{"id":"github:github.com/acme/widget#17","provider":"github","repository":{"provider":"github","identity":"github.com/acme/widget","host":"github.com","owner":"acme","name":"widget"},"number":17,"url":"https://github.com/acme/widget/pull/17","title":"Improve rendering","author":"octocat","source":{"branch":"feature/rendering","repository":{"provider":"github","identity":"github.com/octocat/widget","host":"github.com","owner":"octocat","name":"widget"},"is_fork":true},"target":{"branch":"main","repository":{"provider":"github","identity":"github.com/acme/widget","host":"github.com","owner":"acme","name":"widget"},"is_fork":false},"draft":false,"state":"open","head_sha":"0123456789abcdef0123456789abcdef01234567","imported":true},"project":{"identity":"github.com/acme/widget","name":"widget","path":"/code/widget"},"workspace":{"id":"workspace","repository":"github.com/acme/widget","branch":"pr-17","path":"/worktrees/pr-17","generation":"11111111111111111111111111111111","state":"ready","session_name":"widget-pr-17"}}"#);
        assert!(result.is_err());
    }
}
