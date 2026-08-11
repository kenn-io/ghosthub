//! Application workflow and capability boundary for GPUI.

use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock, TryLockError};
use std::thread;
use std::time::Duration;

use config::TerminalAppearance;
use host::{
    AdmissionAttacher, AttachTerm, CancellationToken, CommandRunner, HerdrInventory, HostError,
    HostSnapshot, KwtInventory, LiveSessionTarget, StdCommandRunner, WslConfig, WslExecutable,
    WslHost, ZellijInventory,
};
pub use input::{KeyEvent, KeyInput, Modifiers, MouseAction, MouseButton, MouseInput, NamedKey};
use model::DiagnosticKind;
use session::HerdrLaunchTarget;
pub use session::{
    HerdrLifecycleAction, HerdrSessionName, HerdrSessionNameError, HerdrSessionState, SessionName,
    SessionNameError, ZellijSessionName, ZellijSessionNameError,
};
use surface::{GridSize, PixelSize, Rgb, SurfaceStore};
use terminal::{
    ClipboardPolicy, ClipboardReadRequest as TerminalClipboardRead, ClipboardTarget, DefaultColors,
    TerminalEvent, TerminalWorker,
};

const REDUCED_COLOR_NOTICE: &str =
    "Using TERM=xterm because xterm-256color terminfo is unavailable in WSL";
const TMUX_CREATE_DISCOVERY_ATTEMPTS: usize = 5;
const TMUX_CREATE_DISCOVERY_DELAY: Duration = Duration::from_millis(40);
const HERDR_STARTUP_BACKOFF: [Duration; 8] = [
    Duration::from_millis(50),
    Duration::from_millis(100),
    Duration::from_millis(200),
    Duration::from_millis(400),
    Duration::from_millis(800),
    Duration::from_secs(1),
    Duration::from_secs(1),
    Duration::from_secs(1),
];
const CREATE_IDENTITY_TIMEOUT: Duration = Duration::from_secs(5);
const CREATE_IDENTITY_MIN_COLUMNS: usize = 120;
const INVENTORY_REFRESH_INTERVAL: Duration = Duration::from_secs(10);
const KWT_REFRESH_INTERVAL: Duration = Duration::from_mins(1);
const KWT_REFRESH_BUDGET: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, PartialEq)]
pub struct Appearance {
    font_family: String,
    font_size: u16,
    background: u32,
    foreground: u32,
}

impl Appearance {
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
}

impl From<TerminalAppearance> for Appearance {
    fn from(value: TerminalAppearance) -> Self {
        Self {
            font_family: value.font_family().to_owned(),
            font_size: value.font_size(),
            background: value.background(),
            foreground: value.foreground(),
        }
    }
}

impl Default for Appearance {
    fn default() -> Self {
        TerminalAppearance::default().into()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionItem {
    name: String,
    attached_clients: u32,
}

impl SessionItem {
    #[must_use]
    pub fn new(name: impl Into<String>, attached_clients: u32) -> Self {
        Self {
            name: name.into(),
            attached_clients,
        }
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub const fn attached_clients(&self) -> u32 {
        self.attached_clients
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionSelection {
    host_id: String,
    endpoint: String,
    session: String,
    kind: SessionKind,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionKind {
    Tmux,
    Herdr,
    Zellij,
}

impl SessionSelection {
    #[must_use]
    pub fn new(
        host_id: impl Into<String>,
        endpoint: impl Into<String>,
        session: impl Into<String>,
    ) -> Self {
        Self {
            host_id: host_id.into(),
            endpoint: endpoint.into(),
            session: session.into(),
            kind: SessionKind::Tmux,
        }
    }

    #[must_use]
    pub fn herdr(
        host_id: impl Into<String>,
        endpoint: impl Into<String>,
        session: impl Into<String>,
    ) -> Self {
        Self {
            host_id: host_id.into(),
            endpoint: endpoint.into(),
            session: session.into(),
            kind: SessionKind::Herdr,
        }
    }

    #[must_use]
    pub fn zellij(
        host_id: impl Into<String>,
        endpoint: impl Into<String>,
        session: impl Into<String>,
    ) -> Self {
        Self {
            host_id: host_id.into(),
            endpoint: endpoint.into(),
            session: session.into(),
            kind: SessionKind::Zellij,
        }
    }

    #[must_use]
    pub fn host_id(&self) -> &str {
        &self.host_id
    }

    #[must_use]
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    #[must_use]
    pub fn session(&self) -> &str {
        &self.session
    }

    #[must_use]
    pub const fn kind(&self) -> SessionKind {
        self.kind
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostConnectionState {
    Disconnected,
    Connecting,
    Ready,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RefreshPresentation {
    Connecting,
    PreserveReady,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostDiagnostic {
    kind: DiagnosticKind,
    message: String,
}

impl HostDiagnostic {
    #[must_use]
    pub fn new(kind: DiagnosticKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    #[must_use]
    pub const fn kind(&self) -> DiagnosticKind {
        self.kind
    }

    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostItem {
    id: String,
    name: String,
    endpoint: String,
    socket_directory: Option<String>,
    connection: HostConnectionState,
    sessions: Vec<SessionItem>,
    diagnostic: Option<HostDiagnostic>,
    herdr_available: bool,
    herdr_sessions: Vec<HerdrSessionItem>,
    herdr_diagnostic: Option<HostDiagnostic>,
    zellij_available: bool,
    zellij_sessions: Vec<SessionItem>,
    zellij_diagnostic: Option<HostDiagnostic>,
    projects: Vec<ProjectItem>,
    directory_workspaces: Vec<DirectoryWorkspaceItem>,
    kwt_state: KwtState,
    kwt_diagnostic: Option<HostDiagnostic>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum KwtState {
    Uninitialized,
    Unavailable,
    Ready,
    Refreshing { available: bool },
    Mutating,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectItem {
    repository: String,
    name: String,
    path: String,
    registration_fingerprint: String,
    worktrees: Vec<WorktreeItem>,
}

impl ProjectItem {
    #[must_use]
    pub fn new(
        repository: impl Into<String>,
        name: impl Into<String>,
        path: impl Into<String>,
        registration_fingerprint: impl Into<String>,
        worktrees: Vec<WorktreeItem>,
    ) -> Self {
        Self {
            repository: repository.into(),
            name: name.into(),
            path: path.into(),
            registration_fingerprint: registration_fingerprint.into(),
            worktrees,
        }
    }

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
    pub fn registration_fingerprint(&self) -> &str {
        &self.registration_fingerprint
    }

    #[must_use]
    pub fn worktrees(&self) -> &[WorktreeItem] {
        &self.worktrees
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorktreeItem {
    path: String,
    branch: String,
    is_main: bool,
    generation: Option<String>,
    session_name: String,
    tmux_socket_name: Option<String>,
    session_available: bool,
}

impl WorktreeItem {
    #[must_use]
    pub fn new(
        path: impl Into<String>,
        branch: impl Into<String>,
        is_main: bool,
        generation: Option<String>,
        session_name: impl Into<String>,
        tmux_socket_name: Option<String>,
        session_available: bool,
    ) -> Self {
        Self {
            path: path.into(),
            branch: branch.into(),
            is_main,
            generation,
            session_name: session_name.into(),
            tmux_socket_name,
            session_available,
        }
    }

    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }

    #[must_use]
    pub fn branch(&self) -> &str {
        &self.branch
    }

    #[must_use]
    pub const fn is_main(&self) -> bool {
        self.is_main
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

    #[must_use]
    pub const fn session_available(&self) -> bool {
        self.session_available
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DirectoryWorkspaceItem {
    name: String,
    path: String,
    session_name: String,
    session_available: bool,
}

impl DirectoryWorkspaceItem {
    #[must_use]
    pub fn new(
        name: impl Into<String>,
        path: impl Into<String>,
        session_name: impl Into<String>,
        session_available: bool,
    ) -> Self {
        Self {
            name: name.into(),
            path: path.into(),
            session_name: session_name.into(),
            session_available,
        }
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
    pub fn session_name(&self) -> &str {
        &self.session_name
    }

    #[must_use]
    pub const fn session_available(&self) -> bool {
        self.session_available
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HerdrSessionItem {
    name: String,
    is_default: bool,
    state: HerdrSessionState,
    lifecycle_action: Option<HerdrLifecycleAction>,
    launch_pending: bool,
}

impl HerdrSessionItem {
    #[must_use]
    pub fn new(name: impl Into<String>, is_default: bool, state: HerdrSessionState) -> Self {
        Self {
            name: name.into(),
            is_default,
            state,
            lifecycle_action: None,
            launch_pending: false,
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
    pub const fn lifecycle_action(&self) -> Option<HerdrLifecycleAction> {
        self.lifecycle_action
    }

    #[must_use]
    pub const fn launch_pending(&self) -> bool {
        self.launch_pending
    }
}

impl HostItem {
    #[must_use]
    pub fn wsl(
        endpoint: impl Into<String>,
        socket_directory: Option<String>,
        connection: HostConnectionState,
        sessions: Vec<SessionItem>,
        diagnostic: Option<HostDiagnostic>,
    ) -> Self {
        Self {
            id: "wsl".to_owned(),
            name: "WSL".to_owned(),
            endpoint: endpoint.into(),
            socket_directory,
            connection,
            sessions,
            diagnostic,
            herdr_available: false,
            herdr_sessions: Vec::new(),
            herdr_diagnostic: None,
            zellij_available: false,
            zellij_sessions: Vec::new(),
            zellij_diagnostic: None,
            projects: Vec::new(),
            directory_workspaces: Vec::new(),
            kwt_state: KwtState::Uninitialized,
            kwt_diagnostic: None,
        }
    }

    #[must_use]
    pub fn with_herdr_sessions(mut self, sessions: Vec<HerdrSessionItem>) -> Self {
        self.herdr_available = true;
        self.herdr_sessions = sessions;
        self
    }

    #[must_use]
    pub fn with_herdr_diagnostic(mut self, diagnostic: HostDiagnostic) -> Self {
        self.herdr_diagnostic = Some(diagnostic);
        self
    }

    #[must_use]
    pub fn with_zellij_sessions(mut self, sessions: Vec<SessionItem>) -> Self {
        self.zellij_available = true;
        self.zellij_sessions = sessions;
        self
    }

    #[must_use]
    pub fn with_zellij_diagnostic(mut self, diagnostic: HostDiagnostic) -> Self {
        self.zellij_diagnostic = Some(diagnostic);
        self
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
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    #[must_use]
    pub fn socket_directory(&self) -> Option<&str> {
        self.socket_directory.as_deref()
    }

    #[must_use]
    pub const fn connection(&self) -> HostConnectionState {
        self.connection
    }

    #[must_use]
    pub fn sessions(&self) -> &[SessionItem] {
        &self.sessions
    }

    #[must_use]
    pub const fn diagnostic(&self) -> Option<&HostDiagnostic> {
        self.diagnostic.as_ref()
    }

    #[must_use]
    pub const fn herdr_available(&self) -> bool {
        self.herdr_available
    }

    #[must_use]
    pub fn herdr_sessions(&self) -> &[HerdrSessionItem] {
        &self.herdr_sessions
    }

    #[must_use]
    pub const fn herdr_diagnostic(&self) -> Option<&HostDiagnostic> {
        self.herdr_diagnostic.as_ref()
    }

    #[must_use]
    pub const fn zellij_available(&self) -> bool {
        self.zellij_available
    }

    #[must_use]
    pub fn zellij_sessions(&self) -> &[SessionItem] {
        &self.zellij_sessions
    }

    #[must_use]
    pub const fn zellij_diagnostic(&self) -> Option<&HostDiagnostic> {
        self.zellij_diagnostic.as_ref()
    }

    #[must_use]
    pub fn projects(&self) -> &[ProjectItem] {
        &self.projects
    }

    #[must_use]
    pub fn directory_workspaces(&self) -> &[DirectoryWorkspaceItem] {
        &self.directory_workspaces
    }

    #[must_use]
    pub const fn kwt_refreshing(&self) -> bool {
        matches!(
            self.kwt_state,
            KwtState::Refreshing { .. } | KwtState::Mutating
        )
    }

    #[must_use]
    pub const fn kwt_initialized(&self) -> bool {
        !matches!(self.kwt_state, KwtState::Uninitialized)
    }

    #[must_use]
    pub const fn kwt_available(&self) -> bool {
        matches!(
            self.kwt_state,
            KwtState::Ready | KwtState::Refreshing { available: true } | KwtState::Mutating
        )
    }

    #[must_use]
    pub const fn kwt_mutating(&self) -> bool {
        matches!(self.kwt_state, KwtState::Mutating)
    }

    #[must_use]
    pub fn can_add_kwt_project(&self) -> bool {
        self.connection == HostConnectionState::Ready
            && !self.kwt_mutating()
            && (self.kwt_available() || self.kwt_diagnostic.is_some())
    }

    #[must_use]
    pub fn can_remove_kwt_project(&self) -> bool {
        self.connection == HostConnectionState::Ready
            && !self.kwt_mutating()
            && self.kwt_available()
            && self.kwt_diagnostic.is_none()
    }

    #[must_use]
    pub const fn kwt_diagnostic(&self) -> Option<&HostDiagnostic> {
        self.kwt_diagnostic.as_ref()
    }

    #[must_use]
    pub fn with_kwt_inventory(
        mut self,
        projects: Vec<ProjectItem>,
        directory_workspaces: Vec<DirectoryWorkspaceItem>,
    ) -> Self {
        self.projects = projects;
        self.directory_workspaces = directory_workspaces;
        self.kwt_state = KwtState::Ready;
        self
    }

    #[must_use]
    pub fn kwt_owns_default_tmux_session(&self, name: &str) -> bool {
        self.projects.iter().any(|project| {
            project.worktrees.iter().any(|worktree| {
                worktree.tmux_socket_name.is_none() && worktree.session_name == name
            })
        }) || self
            .directory_workspaces
            .iter()
            .any(|workspace| workspace.session_name == name)
    }
}

#[derive(Clone)]
pub enum WorkspaceContent {
    Shell,
    Loading,
    Ready {
        endpoint: String,
        sessions: Vec<SessionItem>,
    },
    Attaching {
        host_id: String,
        endpoint: String,
        session: String,
        kind: SessionKind,
    },
    Terminal {
        host_id: String,
        endpoint: String,
        session: String,
        kind: SessionKind,
        presentation_id: u64,
        surface: Arc<SurfaceStore>,
    },
    Error {
        message: String,
    },
}

#[derive(Clone)]
pub struct WorkspaceSnapshot {
    revision: u64,
    appearance: Appearance,
    content: WorkspaceContent,
    hosts: Vec<HostItem>,
    selected_host: Option<String>,
    notice: Option<String>,
    retained_selections: Vec<SessionSelection>,
}

impl WorkspaceSnapshot {
    #[must_use]
    pub fn ready(
        appearance: Appearance,
        endpoint: impl Into<String>,
        sessions: Vec<SessionItem>,
    ) -> Self {
        Self {
            revision: 0,
            appearance,
            content: WorkspaceContent::Ready {
                endpoint: endpoint.into(),
                sessions,
            },
            hosts: Vec::new(),
            selected_host: None,
            notice: None,
            retained_selections: Vec::new(),
        }
    }

    #[must_use]
    pub fn shell(appearance: Appearance, hosts: Vec<HostItem>) -> Self {
        let selected_host = hosts.first().map(|host| host.id.clone());
        Self {
            revision: 0,
            appearance,
            content: WorkspaceContent::Shell,
            hosts,
            selected_host,
            notice: None,
            retained_selections: Vec::new(),
        }
    }

    #[must_use]
    pub const fn revision(&self) -> u64 {
        self.revision
    }

    #[must_use]
    pub const fn appearance(&self) -> &Appearance {
        &self.appearance
    }

    #[must_use]
    pub const fn content(&self) -> &WorkspaceContent {
        &self.content
    }

    #[must_use]
    pub fn hosts(&self) -> &[HostItem] {
        &self.hosts
    }

    #[must_use]
    pub fn selected_host(&self) -> Option<&str> {
        self.selected_host.as_deref()
    }

    #[must_use]
    pub fn notice(&self) -> Option<&str> {
        self.notice.as_deref()
    }

    #[must_use]
    pub fn retained_selections(&self) -> &[SessionSelection] {
        &self.retained_selections
    }
}

pub struct ClipboardRead {
    inner: TerminalClipboardRead,
}

impl ClipboardRead {
    #[must_use]
    pub fn respond(&self, text: &str) -> Vec<u8> {
        self.inner.respond(text)
    }
}

pub enum WorkspaceEvent {
    ClipboardWrite {
        text: String,
        primary: bool,
    },
    ClipboardRead(ClipboardRead),
    ConfirmPaste,
    KwtProjectMutationFinished {
        action: KwtProjectAction,
    },
    KwtProjectMutationFailed {
        action: KwtProjectAction,
        message: String,
    },
    KwtBranchesLoaded {
        project_path: String,
        branches: Vec<KwtBranchItem>,
    },
    KwtWorktreeCreated {
        target: KwtWorktreeTarget,
    },
    KwtWorktreeOperationFailed {
        project_path: String,
        message: String,
    },
    Error(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtBranchItem {
    name: String,
    source: String,
    remote: bool,
}

impl KwtBranchItem {
    #[must_use]
    pub fn new(name: impl Into<String>, source: impl Into<String>, remote: bool) -> Self {
        Self {
            name: name.into(),
            source: source.into(),
            remote,
        }
    }

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
        self.remote
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtWorktreeTarget {
    host_id: String,
    endpoint: String,
    repository: String,
    project_path: String,
    registration_fingerprint: String,
    worktree_path: String,
    generation: Option<String>,
    session_name: String,
}

impl KwtWorktreeTarget {
    #[must_use]
    pub fn host_id(&self) -> &str {
        &self.host_id
    }
    #[must_use]
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }
    #[must_use]
    pub fn repository(&self) -> &str {
        &self.repository
    }
    #[must_use]
    pub fn project_path(&self) -> &str {
        &self.project_path
    }
    #[must_use]
    pub fn registration_fingerprint(&self) -> &str {
        &self.registration_fingerprint
    }
    #[must_use]
    pub fn worktree_path(&self) -> &str {
        &self.worktree_path
    }
    #[must_use]
    pub fn generation(&self) -> Option<&str> {
        self.generation.as_deref()
    }
    #[must_use]
    pub fn session_name(&self) -> &str {
        &self.session_name
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KwtProjectAction {
    Add,
    Remove,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionKillConfirmation {
    selection: SessionSelection,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HerdrLifecycleConfirmation {
    selection: SessionSelection,
    action: HerdrLifecycleAction,
}

impl HerdrLifecycleConfirmation {
    #[must_use]
    pub const fn selection(&self) -> &SessionSelection {
        &self.selection
    }

    #[must_use]
    pub const fn action(&self) -> HerdrLifecycleAction {
        self.action
    }
}

impl SessionKillConfirmation {
    #[must_use]
    pub const fn selection(&self) -> &SessionSelection {
        &self.selection
    }
}

const MAX_EVENTS_PER_DRAIN: usize = 32;
const RETAINED_EVENT_RESERVE: usize = 8;
const ACTIVE_EVENT_BUDGET: usize = MAX_EVENTS_PER_DRAIN - RETAINED_EVENT_RESERVE;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceError {
    message: String,
    backpressure: bool,
}

impl WorkspaceError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            backpressure: false,
        }
    }

    fn from_worker(error: &terminal::WorkerError) -> Self {
        Self {
            message: error.to_string(),
            backpressure: error.is_backpressure(),
        }
    }

    #[must_use]
    pub const fn is_backpressure(&self) -> bool {
        self.backpressure
    }
}

impl fmt::Display for WorkspaceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for WorkspaceError {}

/// Whether a user-entered project path is absolute in either the WSL or
/// Windows namespace. Windows paths are resolved inside the selected distro
/// before KWT receives them.
#[must_use]
pub fn is_absolute_project_path_input(path: &str) -> bool {
    let path = path.trim();
    if path.starts_with('/') || path.starts_with(r"\\") || path.starts_with("//") {
        return true;
    }
    let bytes = path.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/')
}

/// Validate the portable Git ref subset accepted by the worktree creation UI.
/// KWT and Git remain authoritative; this rejects only inputs that Git is
/// guaranteed to reject or interpret ambiguously.
#[must_use]
#[allow(
    clippy::case_sensitive_file_extension_comparisons,
    reason = "Git's reserved .lock suffix is intentionally case-sensitive"
)]
pub fn is_valid_git_branch_name(value: &str) -> bool {
    if value.is_empty()
        || value.trim() != value
        || value.starts_with('-')
        || value == "@"
        || value.starts_with('/')
        || value.ends_with('/')
        || value.contains("//")
        || value.contains("..")
        || value.contains("@{")
        || value.ends_with('.')
        || value.ends_with(".lock")
        || value
            .chars()
            .any(|character| character.is_control() || " ~^:?*[\\".contains(character))
    {
        return false;
    }
    value.split('/').all(|component| {
        !component.is_empty()
            && !component.starts_with('.')
            && !component.ends_with('.')
            && !component.ends_with(".lock")
    })
}

pub struct WslHostSpec {
    config: WslConfig,
    executable: Option<WslExecutable>,
    diagnostic: Option<HostDiagnostic>,
}

impl WslHostSpec {
    #[must_use]
    pub fn available(config: WslConfig, executable: WslExecutable) -> Self {
        Self {
            config,
            executable: Some(executable),
            diagnostic: None,
        }
    }

    #[must_use]
    pub fn unavailable(config: WslConfig, error: &HostError) -> Self {
        Self {
            config,
            executable: None,
            diagnostic: Some(HostDiagnostic::new(error.kind(), error.to_string())),
        }
    }

    fn host_item(&self) -> HostItem {
        HostItem::wsl(
            self.config.distro().unwrap_or("Default distro"),
            self.config.socket_directory().map(str::to_owned),
            if self.diagnostic.is_some() {
                HostConnectionState::Unavailable
            } else {
                HostConnectionState::Disconnected
            },
            Vec::new(),
            self.diagnostic.clone(),
        )
    }
}

type SharedCommandRunner = Arc<dyn CommandRunner>;
type RuntimeHost = WslHost<SharedCommandRunner>;

struct HostContext {
    host: RuntimeHost,
    snapshot: HostSnapshot,
}

trait WslDiscovery: Send + Sync {
    fn discover(
        &self,
        config: WslConfig,
        executable: WslExecutable,
        existing_host: Option<RuntimeHost>,
        cancellation: &CancellationToken,
    ) -> Result<HostContext, HostError>;
}

struct SystemWslDiscovery {
    runner: SharedCommandRunner,
}

impl SystemWslDiscovery {
    fn new() -> Self {
        Self {
            runner: Arc::new(StdCommandRunner),
        }
    }
}

impl WslDiscovery for SystemWslDiscovery {
    fn discover(
        &self,
        config: WslConfig,
        executable: WslExecutable,
        existing_host: Option<RuntimeHost>,
        cancellation: &CancellationToken,
    ) -> Result<HostContext, HostError> {
        let host = existing_host
            .unwrap_or_else(|| WslHost::new(config, Arc::clone(&self.runner), executable));
        host.discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
            .map(|snapshot| HostContext { host, snapshot })
    }
}

type RefreshTask = Box<dyn FnOnce() + Send + 'static>;

trait RefreshRuntime: Send + Sync {
    fn spawn(&self, name: &str, task: RefreshTask) -> std::io::Result<()>;
    fn spawn_after(
        &self,
        name: &str,
        delay: Duration,
        cancellation: CancellationToken,
        task: RefreshTask,
    ) -> std::io::Result<()>;
}

struct ThreadRefreshRuntime;

impl RefreshRuntime for ThreadRefreshRuntime {
    fn spawn(&self, name: &str, task: RefreshTask) -> std::io::Result<()> {
        thread::Builder::new()
            .name(name.to_owned())
            .spawn(task)
            .map(|_| ())
    }

    fn spawn_after(
        &self,
        name: &str,
        delay: Duration,
        cancellation: CancellationToken,
        task: RefreshTask,
    ) -> std::io::Result<()> {
        self.spawn(
            name,
            Box::new(move || {
                if !cancellation.wait_cancelled(delay) {
                    task();
                }
            }),
        )
    }
}

struct Published<T> {
    value: T,
    generation: u64,
}

impl<T> Published<T> {
    const fn new(value: T, generation: u64) -> Self {
        Self { value, generation }
    }

    fn map<U>(&self, capture: impl FnOnce(&T, u64) -> U) -> U {
        capture(&self.value, self.generation)
    }
}

struct PendingPaste {
    worker_generation: u64,
    input: input::EncodedInput,
}

enum KillCaptureRequest {
    Tmux {
        selection: SessionSelection,
        host: RuntimeHost,
        endpoint: host::WslEndpoint,
        runtime: host::WslRuntimeIdentity,
    },
    Zellij(PendingKill),
}

struct PendingKill {
    generation: u64,
    selection: SessionSelection,
    host: RuntimeHost,
    target: KillTarget,
}

#[derive(Clone)]
enum KillTarget {
    Tmux(Arc<LiveSessionTarget>),
    Zellij {
        endpoint: host::WslEndpoint,
        runtime: host::WslRuntimeIdentity,
        executable: String,
        name: String,
    },
}

#[derive(Clone)]
struct PendingHerdrLifecycle {
    generation: u64,
    selection: SessionSelection,
    action: HerdrLifecycleAction,
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    executable: String,
    record: session::HerdrSessionRecord,
}

impl PendingHerdrLifecycle {
    fn key(&self) -> HerdrOperationKey {
        HerdrOperationKey {
            endpoint: self.endpoint.clone(),
            runtime: self.runtime.clone(),
            name: self.record.name().to_owned(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HerdrOperationKey {
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    name: String,
}

struct InFlightHerdrLifecycle {
    generation: u64,
    key: HerdrOperationKey,
    action: HerdrLifecycleAction,
    reconcile_after_generation: Option<u64>,
    recovery: Option<DelayedHerdrRecovery>,
}

struct DelayedHerdrRecovery {
    executable: String,
    record: session::HerdrSessionRecord,
    presentation: SuppressedHerdrPresentation,
}

#[derive(Default)]
struct HerdrLifecycleReconciliation {
    changed: bool,
    recoveries: Vec<SuppressedHerdrPresentation>,
}

#[derive(Default)]
struct HerdrLifecycleState {
    pending: Option<PendingHerdrLifecycle>,
    in_flight: Vec<InFlightHerdrLifecycle>,
    launches: Vec<HerdrOperationKey>,
}

impl HerdrLifecycleState {
    fn reserve_launch(&mut self, key: &HerdrOperationKey) -> bool {
        if self.launches.contains(key) || self.in_flight_action(key).is_some() {
            return false;
        }
        self.launches.push(key.clone());
        true
    }

    fn finish_launch(&mut self, key: &HerdrOperationKey) -> bool {
        let previous_len = self.launches.len();
        self.launches.retain(|candidate| candidate != key);
        self.launches.len() != previous_len
    }

    fn launch_pending(&self, key: &HerdrOperationKey) -> bool {
        self.launches.contains(key)
    }

    fn in_flight_action(&self, key: &HerdrOperationKey) -> Option<HerdrLifecycleAction> {
        self.in_flight
            .iter()
            .find(|operation| &operation.key == key)
            .map(|operation| operation.action)
    }

    fn start(&mut self, pending: &PendingHerdrLifecycle) -> bool {
        let key = pending.key();
        if self.in_flight_action(&key).is_some() {
            return false;
        }
        self.in_flight.push(InFlightHerdrLifecycle {
            generation: pending.generation,
            key,
            action: pending.action,
            reconcile_after_generation: None,
            recovery: None,
        });
        true
    }

    fn finish(&mut self, generation: u64) -> bool {
        let previous_len = self.in_flight.len();
        self.in_flight
            .retain(|operation| operation.generation != generation);
        self.in_flight.len() != previous_len
    }

    fn mark_uncertain(
        &mut self,
        pending: &PendingHerdrLifecycle,
        reconcile_after_generation: u64,
        presentation: Option<SuppressedHerdrPresentation>,
    ) -> bool {
        let Some(operation) = self
            .in_flight
            .iter_mut()
            .find(|operation| operation.generation == pending.generation)
        else {
            return false;
        };
        operation.reconcile_after_generation = Some(reconcile_after_generation);
        operation.recovery = presentation.map(|presentation| DelayedHerdrRecovery {
            executable: pending.executable.clone(),
            record: pending.record.clone(),
            presentation,
        });
        true
    }

    fn reconcile(
        &mut self,
        snapshot: &HostSnapshot,
        publication_generation: u64,
        release_recoveries: bool,
    ) -> HerdrLifecycleReconciliation {
        let mut result = HerdrLifecycleReconciliation::default();
        let mut remaining = Vec::with_capacity(self.in_flight.len());
        for mut operation in self.in_flight.drain(..) {
            let Some(reconcile_after_generation) = operation.reconcile_after_generation else {
                remaining.push(operation);
                continue;
            };
            if publication_generation <= reconcile_after_generation {
                remaining.push(operation);
                continue;
            }
            if operation.key.endpoint != *snapshot.endpoint() {
                remaining.push(operation);
                continue;
            }
            if !matches!(snapshot.herdr(), HerdrInventory::Available { .. }) {
                remaining.push(operation);
                continue;
            }
            if operation.key.runtime != *snapshot.runtime() {
                result.changed = true;
                continue;
            }
            let recoverable = operation.recovery.as_ref().is_some_and(|recovery| {
                herdr_record_is_still_running(
                    snapshot,
                    &operation.key.endpoint,
                    &operation.key.runtime,
                    &recovery.executable,
                    &recovery.record,
                )
            });
            if recoverable && !release_recoveries {
                remaining.push(operation);
                continue;
            }
            if recoverable && let Some(recovery) = operation.recovery.take() {
                result.recoveries.push(recovery.presentation);
            }
            result.changed = true;
        }
        self.in_flight = remaining;
        result
    }
}

fn with_herdr_launch_fence<T, E>(
    lifecycle: &Mutex<HerdrLifecycleState>,
    key: &HerdrOperationKey,
    blocked: impl FnOnce() -> E,
    launch: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    let lifecycle = lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if lifecycle.in_flight_action(key).is_some() {
        return Err(blocked());
    }
    launch()
}

#[derive(Clone)]
struct AttachRequest {
    host_id: String,
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    target: AttachTarget,
    name: String,
    inventory_generation: u64,
}

impl AttachRequest {
    fn herdr_operation_key(&self) -> Option<HerdrOperationKey> {
        (self.target.kind() == SessionKind::Herdr).then(|| HerdrOperationKey {
            endpoint: self.endpoint.clone(),
            runtime: self.runtime.clone(),
            name: self.name.clone(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum AttachTarget {
    Tmux(session::SessionIdentity),
    Worktree {
        repository: String,
        path: String,
        generation: Option<String>,
        session_name: String,
    },
    Herdr {
        executable: String,
        is_default: bool,
        session_directory: String,
        socket_path: String,
    },
    Zellij {
        executable: String,
        name: String,
    },
}

impl AttachTarget {
    fn tmux(&self) -> Option<&session::SessionIdentity> {
        match self {
            Self::Tmux(identity) => Some(identity),
            Self::Worktree { .. } | Self::Herdr { .. } | Self::Zellij { .. } => None,
        }
    }

    fn herdr_matches(&self, record: &session::HerdrSessionRecord) -> bool {
        matches!(
            self,
            Self::Herdr {
                is_default,
                session_directory,
                socket_path,
                ..
            } if *is_default == record.is_default()
                && session_directory == record.session_directory()
                && socket_path == record.socket_path()
        )
    }

    const fn kind(&self) -> SessionKind {
        match self {
            Self::Tmux(_) | Self::Worktree { .. } => SessionKind::Tmux,
            Self::Herdr { .. } => SessionKind::Herdr,
            Self::Zellij { .. } => SessionKind::Zellij,
        }
    }
}

#[derive(Clone)]
struct CreateRequest {
    host_id: String,
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    name: SessionName,
}

#[derive(Clone)]
struct HerdrCreateRequest {
    host_id: String,
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    executable: String,
    term: AttachTerm,
    name: HerdrLaunchTarget,
    precondition: HerdrLaunchPrecondition,
}

#[derive(Clone)]
struct ZellijCreateRequest {
    host_id: String,
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    executable: String,
    term: AttachTerm,
    name: ZellijSessionName,
}

impl HerdrCreateRequest {
    fn operation_key(&self) -> HerdrOperationKey {
        HerdrOperationKey {
            endpoint: self.endpoint.clone(),
            runtime: self.runtime.clone(),
            name: self.name.as_str().to_owned(),
        }
    }
}

#[derive(Clone)]
enum HerdrLaunchPrecondition {
    Absent,
    Stopped(session::HerdrSessionRecord),
}

impl HerdrLaunchPrecondition {
    const fn is_default(&self) -> bool {
        match self {
            Self::Absent => false,
            Self::Stopped(record) => record.is_default(),
        }
    }
}

struct PendingCreation {
    navigation_generation: u64,
    previous: Option<PresentationKey>,
    cancellation: CancellationToken,
    herdr_operation: Option<HerdrOperationKey>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PresentationKey {
    host_id: String,
    endpoint: String,
    socket_directory: Option<String>,
    runtime: host::WslRuntimeIdentity,
    target: AttachTarget,
}

struct SuppressedHerdrPresentation {
    active_selection: Option<SessionSelection>,
    retained: Option<ClosedRetainedPresentation>,
    navigation_generation: u64,
}

struct SuppressedZellijPresentation {
    active_selection: Option<SessionSelection>,
    retained: Option<ClosedRetainedPresentation>,
    navigation_generation: u64,
}

struct ClosedRetainedPresentation {
    key: PresentationKey,
    attachment: ActiveAttachment<AttachRequest>,
    presentation_id: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FallbackAuthority {
    presentation: PresentationKey,
    target: PresentationKey,
    navigation_generation: u64,
}

impl AttachRequest {
    fn presentation_key(&self) -> PresentationKey {
        PresentationKey {
            host_id: self.host_id.clone(),
            endpoint: self.endpoint.distro().to_owned(),
            socket_directory: self.host.socket_directory().map(str::to_owned),
            runtime: self.runtime.clone(),
            target: self.target.clone(),
        }
    }

    fn selection(&self) -> SessionSelection {
        match self.target.kind() {
            SessionKind::Tmux => {
                SessionSelection::new(&self.host_id, self.endpoint.distro(), &self.name)
            }
            SessionKind::Herdr => {
                SessionSelection::herdr(&self.host_id, self.endpoint.distro(), &self.name)
            }
            SessionKind::Zellij => {
                SessionSelection::zellij(&self.host_id, self.endpoint.distro(), &self.name)
            }
        }
    }
}

enum AttachFreshError {
    Host(WorkspaceError),
    SessionChanged {
        error: WorkspaceError,
        snapshot: Box<HostSnapshot>,
    },
}

struct ActiveAttachment<T> {
    request: T,
    term: AttachTerm,
    generation: u64,
    fallback: Option<FallbackAuthority>,
}

struct AttachmentState<T> {
    generation: u64,
    active: Option<ActiveAttachment<T>>,
}

impl<T> AttachmentState<T> {
    const fn new() -> Self {
        Self {
            generation: 0,
            active: None,
        }
    }

    #[cfg(test)]
    fn reserve(&mut self, request: T, term: AttachTerm) -> Option<u64> {
        self.reserve_with_fallback(request, term, None)
    }

    fn reserve_with_fallback(
        &mut self,
        request: T,
        term: AttachTerm,
        fallback: Option<FallbackAuthority>,
    ) -> Option<u64> {
        if self.active.is_some() {
            return None;
        }
        self.generation = self
            .generation
            .checked_add(1)
            .expect("attachment generation exhausted");
        self.active = Some(ActiveAttachment {
            request,
            term,
            generation: self.generation,
            fallback,
        });
        Some(self.generation)
    }

    fn active(&self) -> Option<&ActiveAttachment<T>> {
        self.active.as_ref()
    }

    fn active_mut(&mut self) -> Option<&mut ActiveAttachment<T>> {
        self.active.as_mut()
    }

    fn is_current(&self, generation: u64) -> bool {
        self.generation == generation
            && self
                .active
                .as_ref()
                .is_some_and(|active| active.generation == generation)
    }

    fn promote_if_current(&mut self, generation: u64, term: AttachTerm) -> bool {
        if !self.is_current(generation) {
            return false;
        }
        if let Some(active) = &mut self.active {
            active.term = term;
        }
        true
    }

    fn fallback_if_current(&self, generation: u64) -> Option<FallbackAuthority> {
        self.is_current(generation)
            .then(|| {
                self.active
                    .as_ref()
                    .and_then(|active| active.fallback.clone())
            })
            .flatten()
    }

    fn confirm_if_current(&mut self, generation: u64) -> bool {
        if !self.is_current(generation) {
            return false;
        }
        if let Some(active) = &mut self.active {
            active.fallback = None;
        }
        true
    }

    fn clear_if_current(&mut self, generation: u64) -> bool {
        if !self.is_current(generation) {
            return false;
        }
        self.invalidate();
        true
    }

    fn invalidate(&mut self) {
        self.generation = self
            .generation
            .checked_add(1)
            .expect("attachment generation exhausted");
        self.active = None;
    }

    fn take_active(&mut self) -> Option<ActiveAttachment<T>> {
        self.generation = self
            .generation
            .checked_add(1)
            .expect("attachment generation exhausted");
        self.active.take()
    }
}

struct WorkerState<T> {
    generation: u64,
    worker: Option<T>,
}

impl<T> WorkerState<T> {
    const fn new() -> Self {
        Self {
            generation: 0,
            worker: None,
        }
    }

    fn publish(&mut self, worker: T) -> u64 {
        self.advance_generation();
        self.worker = Some(worker);
        self.generation
    }

    fn active(&self) -> Option<&T> {
        self.worker.as_ref()
    }

    fn active_with_generation(&self) -> Option<(&T, u64)> {
        self.worker.as_ref().map(|worker| (worker, self.generation))
    }

    fn invalidate(&mut self) -> Option<T> {
        self.advance_generation();
        self.worker.take()
    }

    const fn generation(&self) -> u64 {
        self.generation
    }

    fn advance_generation(&mut self) {
        self.generation = self
            .generation
            .checked_add(1)
            .expect("worker generation exhausted");
    }
}

struct RetainedPresentation<T> {
    key: PresentationKey,
    selection: SessionSelection,
    attachment: ActiveAttachment<AttachRequest>,
    worker: T,
    presentation_id: u64,
}

struct RetainedRestart {
    key: PresentationKey,
    selection: SessionSelection,
    attachment: ActiveAttachment<AttachRequest>,
    presentation_id: u64,
}

struct RetainedRetry {
    key: PresentationKey,
    request: AttachRequest,
}

struct RetainedDrain {
    emitted: Vec<WorkspaceEvent>,
    retries: Vec<RetainedRetry>,
    processed: usize,
    changed: bool,
}

struct RetainedPresentations<T> {
    entries: Vec<RetainedPresentation<T>>,
    restarting: Vec<RetainedRestart>,
}

impl<T> RetainedPresentations<T> {
    const fn new() -> Self {
        Self {
            entries: Vec::new(),
            restarting: Vec::new(),
        }
    }

    fn insert(&mut self, presentation: RetainedPresentation<T>) {
        if let Some(index) = self
            .entries
            .iter()
            .position(|entry| entry.key == presentation.key)
        {
            self.entries.remove(index);
        }
        self.entries.push(presentation);
    }

    fn take(&mut self, key: &PresentationKey) -> Option<RetainedPresentation<T>> {
        let index = self.entries.iter().position(|entry| &entry.key == key)?;
        Some(self.entries.remove(index))
    }

    fn remove_matching(&mut self, mut matches: impl FnMut(&PresentationKey) -> bool) -> bool {
        let before = self.entries.len();
        self.entries.retain(|entry| !matches(&entry.key));
        let mut changed = self.entries.len() != before;
        let restart_before = self.restarting.len();
        self.restarting.retain(|entry| !matches(&entry.key));
        changed |= self.restarting.len() != restart_before;
        changed
    }

    fn take_matching(
        &mut self,
        mut matches: impl FnMut(&PresentationKey) -> bool,
    ) -> Vec<RetainedPresentation<T>> {
        let mut removed = Vec::new();
        let mut index = 0;
        while index < self.entries.len() {
            if matches(&self.entries[index].key) {
                removed.push(self.entries.remove(index));
            } else {
                index += 1;
            }
        }
        removed
    }

    fn contains(&self, key: &PresentationKey) -> bool {
        self.entries.iter().any(|entry| &entry.key == key)
            || self.restarting.iter().any(|entry| &entry.key == key)
    }

    fn key_for_selection(&self, selection: &SessionSelection) -> Option<PresentationKey> {
        self.entries
            .iter()
            .find(|entry| &entry.selection == selection)
            .map(|entry| entry.key.clone())
            .or_else(|| {
                self.restarting
                    .iter()
                    .find(|entry| &entry.selection == selection)
                    .map(|entry| entry.key.clone())
            })
    }

    fn selections(&self) -> Vec<SessionSelection> {
        self.entries
            .iter()
            .map(|entry| entry.selection.clone())
            .chain(self.restarting.iter().map(|entry| entry.selection.clone()))
            .collect()
    }

    fn reconcile_session_names(
        &mut self,
        snapshot: &HostSnapshot,
        socket_directory: Option<&str>,
    ) -> bool {
        let mut changed = false;
        for presentation in &mut self.entries {
            if let Some(name) =
                refreshed_session_name(&presentation.key, snapshot, socket_directory)
                && name != presentation.attachment.request.name
            {
                name.clone_into(&mut presentation.attachment.request.name);
                presentation.selection = presentation.attachment.request.selection();
                changed = true;
            }
        }
        for presentation in &mut self.restarting {
            if let Some(name) =
                refreshed_session_name(&presentation.key, snapshot, socket_directory)
                && name != presentation.attachment.request.name
            {
                name.clone_into(&mut presentation.attachment.request.name);
                presentation.selection = presentation.attachment.request.selection();
                changed = true;
            }
        }
        changed
    }

    fn finish_restart(
        &mut self,
        key: &PresentationKey,
        worker: T,
        original_name: &str,
        resolved_request: &AttachRequest,
    ) -> bool {
        let Some(index) = self.restarting.iter().position(|entry| &entry.key == key) else {
            return false;
        };
        let mut restart = self.restarting.remove(index);
        if restart.attachment.request.name == original_name {
            restart.selection = resolved_request.selection();
            resolved_request
                .name
                .clone_into(&mut restart.attachment.request.name);
        }
        self.insert(RetainedPresentation {
            key: restart.key,
            selection: restart.selection,
            attachment: restart.attachment,
            worker,
            presentation_id: restart.presentation_id,
        });
        true
    }

    fn fail_restart(&mut self, key: &PresentationKey) -> Option<RetainedRestart> {
        let index = self.restarting.iter().position(|entry| &entry.key == key)?;
        Some(self.restarting.remove(index))
    }

    fn handle_exit(
        &mut self,
        index: usize,
        code: u32,
        output_tail: &str,
        confirmed: bool,
        emitted: &mut Vec<WorkspaceEvent>,
        retries: &mut Vec<RetainedRetry>,
    ) {
        let term = self.entries[index].attachment.term;
        let (retry, diagnostic) = classify_terminal_exit_event(code, output_tail, term, confirmed);
        if retry {
            let presentation = self.entries.remove(index);
            let RetainedPresentation {
                key,
                selection,
                mut attachment,
                worker: _,
                presentation_id,
            } = presentation;
            attachment.term = AttachTerm::Xterm;
            retries.push(RetainedRetry {
                key: key.clone(),
                request: attachment.request.clone(),
            });
            self.restarting.push(RetainedRestart {
                key,
                selection,
                attachment,
                presentation_id,
            });
        } else {
            self.entries.remove(index);
            if let Some(diagnostic) = diagnostic {
                emitted.push(WorkspaceEvent::Error(diagnostic));
            }
        }
    }
}

fn refreshed_session_name(
    key: &PresentationKey,
    snapshot: &HostSnapshot,
    socket_directory: Option<&str>,
) -> Option<String> {
    (key.host_id == "wsl"
        && key.endpoint == snapshot.endpoint().distro()
        && key.socket_directory.as_deref() == socket_directory
        && key.runtime == *snapshot.runtime())
    .then(|| match &key.target {
        AttachTarget::Tmux(identity) => snapshot
            .sessions()
            .iter()
            .find(|session| session.identity() == identity)
            .map(|session| session.name().to_owned()),
        AttachTarget::Worktree { session_name, .. } => Some(session_name.clone()),
        AttachTarget::Herdr {
            executable,
            is_default,
            session_directory,
            socket_path,
        } => match snapshot.herdr() {
            HerdrInventory::Available {
                executable: current_executable,
                sessions,
            } if current_executable == executable => sessions
                .iter()
                .find(|session| {
                    session.is_default() == *is_default
                        && session.session_directory() == session_directory
                        && session.socket_path() == socket_path
                })
                .map(|session| session.name().to_owned()),
            _ => None,
        },
        AttachTarget::Zellij { executable, name } => match snapshot.zellij() {
            ZellijInventory::Available {
                executable: current_executable,
                sessions,
            } if current_executable == executable => sessions
                .iter()
                .find(|session| session.name() == name)
                .map(|session| session.name().to_owned()),
            _ => None,
        },
    })
    .flatten()
}

impl RetainedPresentations<TerminalWorker> {
    fn drain_events(&mut self, budget: usize) -> RetainedDrain {
        let mut emitted = Vec::new();
        let mut retries = Vec::new();
        let mut processed = 0;
        let mut changed = false;
        let mut index = 0;
        while index < self.entries.len() && processed < budget {
            let confirmed = self.entries[index].worker.is_confirmed_live();
            match self.entries[index].worker.try_event() {
                Ok(Some(
                    TerminalEvent::ClipboardWrite { .. } | TerminalEvent::ClipboardRead(_),
                )) => {
                    processed += 1;
                    index += 1;
                }
                Ok(Some(TerminalEvent::ConfirmPaste(_))) => {
                    processed += 1;
                    let _cancelled = self.entries[index].worker.cancel_paste();
                    index += 1;
                }
                Ok(Some(TerminalEvent::Error(error))) => {
                    processed += 1;
                    emitted.push(WorkspaceEvent::Error(error));
                    index += 1;
                }
                Ok(Some(TerminalEvent::Exited { code, output_tail })) => {
                    processed += 1;
                    changed = true;
                    self.handle_exit(
                        index,
                        code,
                        &output_tail,
                        confirmed,
                        &mut emitted,
                        &mut retries,
                    );
                }
                Err(error) => {
                    processed += 1;
                    self.entries.remove(index);
                    changed = true;
                    emitted.push(WorkspaceEvent::Error(error.to_string()));
                }
                Ok(None) => index += 1,
            }
        }
        RetainedDrain {
            emitted,
            retries,
            processed,
            changed,
        }
    }
}

fn claim_terminal_exit<A, W>(
    attachment: &mut AttachmentState<A>,
    worker: &mut WorkerState<W>,
    attachment_generation: u64,
    worker_generation: u64,
    retry_term: bool,
) -> bool {
    if !attachment.is_current(attachment_generation) || worker.generation() != worker_generation {
        return false;
    }
    worker.invalidate();
    if !retry_term {
        attachment.invalidate();
    }
    true
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TerminalGeometry {
    grid: GridSize,
    pixels: PixelSize,
    sequence: u64,
}

fn publish_worker_at_latest_geometry<T, E>(
    geometry: &Mutex<TerminalGeometry>,
    workers: &Mutex<WorkerState<T>>,
    worker: T,
    initial_geometry: TerminalGeometry,
    resize: impl FnOnce(&T, TerminalGeometry) -> Result<(), E>,
) -> Result<u64, E> {
    let geometry = geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let latest_geometry = *geometry;
    let mut workers = workers
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if latest_geometry != initial_geometry {
        resize(&worker, latest_geometry)?;
    }
    Ok(workers.publish(worker))
}

struct ConptyAdmissionAttacher {
    size: GridSize,
}

impl ConptyAdmissionAttacher {
    fn new() -> Self {
        Self {
            size: GridSize::new(80, 24).expect("admission grid is valid"),
        }
    }
}

impl AdmissionAttacher for ConptyAdmissionAttacher {
    type Client = TerminalWorker;

    fn attach(&self, plan: &session::AdmissionPlan) -> Result<Self::Client, String> {
        TerminalWorker::admission(plan, self.size).map_err(|error| error.to_string())
    }
}

struct Inner {
    appearance: Appearance,
    host_scoped_inventory: bool,
    wsl_config: Option<WslConfig>,
    wsl_executable: Mutex<Option<WslExecutable>>,
    state: RwLock<WorkspaceContent>,
    hosts: RwLock<Vec<HostItem>>,
    selected_host: RwLock<Option<String>>,
    inventory_state: Mutex<WorkspaceContent>,
    revision: AtomicU64,
    snapshot_writers: AtomicUsize,
    presentation_generation: AtomicU64,
    navigation_generation: AtomicU64,
    navigation: Mutex<()>,
    host: Mutex<Option<Published<HostContext>>>,
    discovery_cancel: Mutex<Option<CancellationToken>>,
    event_drain: Mutex<()>,
    worker: Mutex<WorkerState<TerminalWorker>>,
    retained_presentations: Mutex<RetainedPresentations<TerminalWorker>>,
    pending_paste: Mutex<Option<PendingPaste>>,
    pending_creation: Mutex<Option<PendingCreation>>,
    pending_kill: Mutex<Option<PendingKill>>,
    kill_generation: AtomicU64,
    herdr_lifecycle: Mutex<HerdrLifecycleState>,
    herdr_lifecycle_generation: AtomicU64,
    session_operations: Mutex<()>,
    operation_events: Mutex<std::collections::VecDeque<WorkspaceEvent>>,
    terminal_geometry: Mutex<TerminalGeometry>,
    allow_remote_clipboard_write: bool,
    refresh_generation: AtomicU64,
    refresh_finished: AtomicU64,
    refresh_publication: Mutex<()>,
    inventory_cadence_started: AtomicBool,
    kwt_cadence_started: AtomicBool,
    inventory_polling_enabled: AtomicBool,
    kwt_refresh_generation: AtomicU64,
    kwt_discovery_cancel: Mutex<Option<CancellationToken>>,
    kwt_publication: Mutex<()>,
    kwt_mutation_in_flight: AtomicBool,
    discovery: Arc<dyn WslDiscovery>,
    refresh_runtime: Arc<dyn RefreshRuntime>,
    attachment: Mutex<AttachmentState<AttachRequest>>,
    terminal_notice: RwLock<Option<String>>,
}

#[derive(Clone)]
pub struct Workspace {
    inner: Arc<Inner>,
}

struct SnapshotWrite<'a> {
    writers: &'a AtomicUsize,
}

impl Drop for SnapshotWrite<'_> {
    fn drop(&mut self) {
        self.writers.fetch_sub(1, Ordering::Release);
    }
}

fn begin_snapshot_write(inner: &Inner) -> SnapshotWrite<'_> {
    inner.snapshot_writers.fetch_add(1, Ordering::AcqRel);
    SnapshotWrite {
        writers: &inner.snapshot_writers,
    }
}

fn read_revision_consistent<T>(
    revision: &AtomicU64,
    writers: &AtomicUsize,
    mut read: impl FnMut(u64) -> T,
) -> T {
    loop {
        while writers.load(Ordering::Acquire) != 0 {
            std::thread::yield_now();
        }
        let before = revision.load(Ordering::Acquire);
        let value = read(before);
        if writers.load(Ordering::Acquire) == 0 && revision.load(Ordering::Acquire) == before {
            return value;
        }
    }
}

impl Workspace {
    #[must_use]
    pub fn startup_error(appearance: TerminalAppearance, message: impl Into<String>) -> Self {
        Self::preview(WorkspaceSnapshot {
            revision: 0,
            appearance: appearance.into(),
            content: WorkspaceContent::Error {
                message: message.into(),
            },
            hosts: Vec::new(),
            selected_host: None,
            notice: None,
            retained_selections: Vec::new(),
        })
    }

    #[must_use]
    pub fn preview(snapshot: WorkspaceSnapshot) -> Self {
        let presentation_generation = match &snapshot.content {
            WorkspaceContent::Terminal {
                presentation_id, ..
            } => *presentation_id,
            _ => 0,
        };
        Self {
            inner: Arc::new(Inner {
                appearance: snapshot.appearance,
                host_scoped_inventory: false,
                wsl_config: None,
                wsl_executable: Mutex::new(None),
                state: RwLock::new(snapshot.content.clone()),
                hosts: RwLock::new(snapshot.hosts),
                selected_host: RwLock::new(snapshot.selected_host),
                inventory_state: Mutex::new(snapshot.content),
                revision: AtomicU64::new(snapshot.revision),
                snapshot_writers: AtomicUsize::new(0),
                presentation_generation: AtomicU64::new(presentation_generation),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                event_drain: Mutex::new(()),
                worker: Mutex::new(WorkerState::new()),
                retained_presentations: Mutex::new(RetainedPresentations::new()),
                pending_paste: Mutex::new(None),
                pending_creation: Mutex::new(None),
                pending_kill: Mutex::new(None),
                kill_generation: AtomicU64::new(0),
                herdr_lifecycle: Mutex::new(HerdrLifecycleState::default()),
                herdr_lifecycle_generation: AtomicU64::new(0),
                session_operations: Mutex::new(()),
                operation_events: Mutex::new(std::collections::VecDeque::new()),
                terminal_geometry: Mutex::new(default_terminal_geometry()),
                allow_remote_clipboard_write: true,
                refresh_generation: AtomicU64::new(0),
                refresh_finished: AtomicU64::new(0),
                refresh_publication: Mutex::new(()),
                inventory_cadence_started: AtomicBool::new(false),
                kwt_cadence_started: AtomicBool::new(false),
                inventory_polling_enabled: AtomicBool::new(false),
                kwt_refresh_generation: AtomicU64::new(0),
                kwt_discovery_cancel: Mutex::new(None),
                kwt_publication: Mutex::new(()),
                kwt_mutation_in_flight: AtomicBool::new(false),
                discovery: Arc::new(SystemWslDiscovery::new()),
                refresh_runtime: Arc::new(ThreadRefreshRuntime),
                attachment: Mutex::new(AttachmentState::new()),
                terminal_notice: RwLock::new(snapshot.notice),
            }),
        }
    }

    #[must_use]
    pub fn application(appearance: TerminalAppearance, wsl: Option<WslHostSpec>) -> Self {
        Self::application_with_services(
            appearance,
            wsl,
            Arc::new(SystemWslDiscovery::new()),
            Arc::new(ThreadRefreshRuntime),
        )
    }

    fn application_with_services(
        appearance: TerminalAppearance,
        wsl: Option<WslHostSpec>,
        discovery: Arc<dyn WslDiscovery>,
        refresh_runtime: Arc<dyn RefreshRuntime>,
    ) -> Self {
        let allow_remote_clipboard_write = appearance.allow_remote_clipboard_write();
        let hosts = wsl
            .as_ref()
            .map(WslHostSpec::host_item)
            .into_iter()
            .collect();
        let selected_host = wsl.as_ref().map(|_| "wsl".to_owned());
        let wsl_config = wsl.as_ref().map(|spec| spec.config.clone());
        let wsl_executable = wsl.and_then(|spec| spec.executable);
        Self {
            inner: Arc::new(Inner {
                appearance: appearance.into(),
                host_scoped_inventory: true,
                wsl_config,
                wsl_executable: Mutex::new(wsl_executable),
                state: RwLock::new(WorkspaceContent::Shell),
                hosts: RwLock::new(hosts),
                selected_host: RwLock::new(selected_host),
                inventory_state: Mutex::new(WorkspaceContent::Shell),
                revision: AtomicU64::new(0),
                snapshot_writers: AtomicUsize::new(0),
                presentation_generation: AtomicU64::new(0),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                event_drain: Mutex::new(()),
                worker: Mutex::new(WorkerState::new()),
                retained_presentations: Mutex::new(RetainedPresentations::new()),
                pending_paste: Mutex::new(None),
                pending_creation: Mutex::new(None),
                pending_kill: Mutex::new(None),
                kill_generation: AtomicU64::new(0),
                herdr_lifecycle: Mutex::new(HerdrLifecycleState::default()),
                herdr_lifecycle_generation: AtomicU64::new(0),
                session_operations: Mutex::new(()),
                operation_events: Mutex::new(std::collections::VecDeque::new()),
                terminal_geometry: Mutex::new(default_terminal_geometry()),
                allow_remote_clipboard_write,
                refresh_generation: AtomicU64::new(0),
                refresh_finished: AtomicU64::new(0),
                refresh_publication: Mutex::new(()),
                inventory_cadence_started: AtomicBool::new(false),
                kwt_cadence_started: AtomicBool::new(false),
                inventory_polling_enabled: AtomicBool::new(false),
                kwt_refresh_generation: AtomicU64::new(0),
                kwt_discovery_cancel: Mutex::new(None),
                kwt_publication: Mutex::new(()),
                kwt_mutation_in_flight: AtomicBool::new(false),
                discovery,
                refresh_runtime,
                attachment: Mutex::new(AttachmentState::new()),
                terminal_notice: RwLock::new(None),
            }),
        }
    }

    #[must_use]
    pub fn start_wsl(config: WslConfig, appearance: TerminalAppearance) -> Self {
        let allow_remote_clipboard_write = appearance.allow_remote_clipboard_write();
        let workspace = Self {
            inner: Arc::new(Inner {
                appearance: appearance.into(),
                host_scoped_inventory: false,
                wsl_config: Some(config.clone()),
                wsl_executable: Mutex::new(None),
                state: RwLock::new(WorkspaceContent::Loading),
                hosts: RwLock::new(vec![HostItem::wsl(
                    config.distro().unwrap_or("Default distro"),
                    config.socket_directory().map(str::to_owned),
                    HostConnectionState::Connecting,
                    Vec::new(),
                    None,
                )]),
                selected_host: RwLock::new(Some("wsl".to_owned())),
                inventory_state: Mutex::new(WorkspaceContent::Loading),
                revision: AtomicU64::new(0),
                snapshot_writers: AtomicUsize::new(0),
                presentation_generation: AtomicU64::new(0),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                event_drain: Mutex::new(()),
                worker: Mutex::new(WorkerState::new()),
                retained_presentations: Mutex::new(RetainedPresentations::new()),
                pending_paste: Mutex::new(None),
                pending_creation: Mutex::new(None),
                pending_kill: Mutex::new(None),
                kill_generation: AtomicU64::new(0),
                herdr_lifecycle: Mutex::new(HerdrLifecycleState::default()),
                herdr_lifecycle_generation: AtomicU64::new(0),
                session_operations: Mutex::new(()),
                operation_events: Mutex::new(std::collections::VecDeque::new()),
                terminal_geometry: Mutex::new(default_terminal_geometry()),
                allow_remote_clipboard_write,
                refresh_generation: AtomicU64::new(0),
                refresh_finished: AtomicU64::new(0),
                refresh_publication: Mutex::new(()),
                inventory_cadence_started: AtomicBool::new(false),
                kwt_cadence_started: AtomicBool::new(false),
                inventory_polling_enabled: AtomicBool::new(false),
                kwt_refresh_generation: AtomicU64::new(0),
                kwt_discovery_cancel: Mutex::new(None),
                kwt_publication: Mutex::new(()),
                kwt_mutation_in_flight: AtomicBool::new(false),
                discovery: Arc::new(SystemWslDiscovery::new()),
                refresh_runtime: Arc::new(ThreadRefreshRuntime),
                attachment: Mutex::new(AttachmentState::new()),
                terminal_notice: RwLock::new(None),
            }),
        };
        workspace.start_refresh(config, None, RefreshPresentation::Connecting);
        workspace
    }

    /// Start discovery for enabled hosts after the application has painted.
    ///
    /// # Errors
    ///
    /// Returns an error only when an enabled host cannot start its refresh.
    pub fn connect_enabled_hosts(&self) -> Result<(), WorkspaceError> {
        let Some(config) = self.inner.wsl_config.clone() else {
            return Ok(());
        };
        let executable = self
            .inner
            .wsl_executable
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        if executable.is_some() {
            self.start_refresh(config, executable, RefreshPresentation::Connecting);
        }
        Ok(())
    }

    /// Refresh the current WSL inventory without requiring an app restart.
    ///
    /// # Errors
    ///
    /// Returns an error for preview workspaces, which have no host config.
    pub fn refresh(&self) -> Result<(), WorkspaceError> {
        let config = self
            .inner
            .wsl_config
            .clone()
            .ok_or_else(|| WorkspaceError::new("preview workspace cannot refresh WSL"))?;
        let executable = self
            .inner
            .wsl_executable
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let presentation = if self.host_is_ready() {
            RefreshPresentation::PreserveReady
        } else {
            RefreshPresentation::Connecting
        };
        self.start_refresh(config, executable, presentation);
        start_kwt_refresh(&self.inner, true);
        Ok(())
    }

    /// Register one explicit absolute WSL checkout through the pinned KWT helper.
    ///
    /// The command and subsequent inventory read run on the background refresh
    /// runtime. Ghosthub never scans the host or edits KWT configuration.
    ///
    /// # Errors
    ///
    /// Returns an error when the host selection is stale, KWT is unavailable,
    /// another project mutation is running, or the task cannot be scheduled.
    pub fn add_kwt_project(
        &self,
        host_id: &str,
        endpoint: &str,
        path: &str,
    ) -> Result<(), WorkspaceError> {
        let path = path.trim();
        if !is_absolute_project_path_input(path) {
            return Err(WorkspaceError::new(
                "Choose a project folder or enter an absolute Windows or WSL path.",
            ));
        }
        self.start_kwt_project_mutation(
            host_id,
            endpoint,
            KwtProjectMutationRequest::Add {
                path: path.to_owned(),
            },
        )
    }

    /// Unregister one freshly identified WSL project through the pinned KWT helper.
    ///
    /// This changes KWT metadata only. It never deletes a repository or
    /// worktree and never terminates a tmux session.
    ///
    /// # Errors
    ///
    /// Returns an error when the host or project identity is stale, another
    /// project mutation is running, or the task cannot be scheduled.
    pub fn remove_kwt_project(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        path: &str,
        registration_fingerprint: &str,
    ) -> Result<(), WorkspaceError> {
        self.start_kwt_project_mutation(
            host_id,
            endpoint,
            KwtProjectMutationRequest::Remove {
                repository: repository.to_owned(),
                path: path.to_owned(),
                registration_fingerprint: registration_fingerprint.to_owned(),
            },
        )
    }

    /// Load branch candidates for one authoritative registered project.
    ///
    /// The read is serialized with KWT mutations and runs on the background
    /// runtime. Results arrive as a workspace event.
    ///
    /// # Errors
    ///
    /// Returns an error when the project selection is stale or another KWT
    /// operation is active.
    pub fn load_kwt_branches(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        project_path: &str,
        registration_fingerprint: &str,
    ) -> Result<(), WorkspaceError> {
        self.start_kwt_worktree_operation(
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            KwtWorktreeOperation::Branches,
        )
    }

    /// Create one new or existing-branch KWT worktree without launching a
    /// detached tmux session. Successful creation refreshes authoritative KWT
    /// inventory and returns the exact worktree target as an event.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid branch names, stale project identity, or
    /// an already-running KWT operation.
    #[allow(clippy::too_many_arguments)]
    pub fn create_kwt_worktree(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        project_path: &str,
        registration_fingerprint: &str,
        branch: &str,
        source: Option<&str>,
        creates_branch: bool,
    ) -> Result<(), WorkspaceError> {
        let branch = branch.trim();
        if !is_valid_git_branch_name(branch) {
            return Err(WorkspaceError::new("Enter a valid Git branch name."));
        }
        self.start_kwt_worktree_operation(
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            KwtWorktreeOperation::Create {
                branch: branch.to_owned(),
                source: source.map(str::to_owned),
                creates_branch,
            },
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn start_kwt_worktree_operation(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        project_path: &str,
        registration_fingerprint: &str,
        operation: KwtWorktreeOperation,
    ) -> Result<(), WorkspaceError> {
        let task = reserve_kwt_worktree_operation(
            &self.inner,
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            operation,
        )?;
        let task_inner = Arc::clone(&self.inner);
        if let Err(error) = self.inner.refresh_runtime.spawn(
            "ghosthub-kwt-worktree-operation",
            Box::new(move || run_kwt_worktree_operation(&task_inner, &task)),
        ) {
            finish_kwt_project_mutation(&self.inner, None);
            return Err(WorkspaceError::new(format!(
                "start KWT worktree operation: {error}"
            )));
        }
        Ok(())
    }

    fn start_kwt_project_mutation(
        &self,
        host_id: &str,
        endpoint: &str,
        request: KwtProjectMutationRequest,
    ) -> Result<(), WorkspaceError> {
        let task = reserve_kwt_project_mutation(&self.inner, host_id, endpoint, request)?;
        let task_inner = Arc::clone(&self.inner);
        if let Err(error) = self.inner.refresh_runtime.spawn(
            "ghosthub-kwt-project-mutation",
            Box::new(move || run_kwt_project_mutation(&task_inner, &task)),
        ) {
            finish_kwt_project_mutation(&self.inner, None);
            return Err(WorkspaceError::new(format!(
                "start KWT project operation: {error}"
            )));
        }
        Ok(())
    }

    /// Start the application-owned inventory cadence after the first frame.
    ///
    /// The timer and every host read execute through the background refresh
    /// runtime. Calling this method never performs discovery itself and is
    /// idempotent for the lifetime of the workspace.
    ///
    /// # Errors
    ///
    /// Returns an error when the background cadence cannot be scheduled.
    pub fn start_inventory_cadence(&self) -> Result<(), WorkspaceError> {
        if self.inner.wsl_config.is_none() {
            return Ok(());
        }
        if self
            .inner
            .inventory_cadence_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
            && let Err(error) = schedule_inventory_refresh(&self.inner)
        {
            self.inner
                .inventory_cadence_started
                .store(false, Ordering::Release);
            return Err(WorkspaceError::new(format!(
                "schedule inventory refresh cadence: {error}"
            )));
        }
        if self
            .inner
            .wsl_config
            .as_ref()
            .is_some_and(|config| config.kwt_bundle().is_some())
            && self
                .inner
                .kwt_cadence_started
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            && let Err(error) = schedule_kwt_refresh(&self.inner)
        {
            self.inner
                .kwt_cadence_started
                .store(false, Ordering::Release);
            return Err(WorkspaceError::new(format!(
                "schedule KWT refresh cadence: {error}"
            )));
        }
        Ok(())
    }

    /// Enable or suspend automatic inventory reads for the visible window.
    ///
    /// This changes only an in-memory flag. It never starts discovery and is
    /// therefore safe to call from the window-activation callback.
    pub fn set_inventory_polling_enabled(&self, enabled: bool) {
        self.inner
            .inventory_polling_enabled
            .store(enabled, Ordering::Release);
    }

    fn refresh_if_ready(&self) -> Result<bool, WorkspaceError> {
        if !self.host_is_ready() || refresh_is_in_flight(&self.inner) {
            return Ok(false);
        }
        let config = self
            .inner
            .wsl_config
            .clone()
            .ok_or_else(|| WorkspaceError::new("preview workspace cannot refresh WSL"))?;
        let executable = self
            .inner
            .wsl_executable
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        self.start_refresh(config, executable, RefreshPresentation::PreserveReady);
        Ok(true)
    }

    fn host_is_ready(&self) -> bool {
        self.inner
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .any(|host| host.id == "wsl" && host.connection == HostConnectionState::Ready)
    }

    /// Cancel the active WSL inventory refresh, if one is connecting.
    ///
    /// Returns `true` when an active refresh was cancelled.
    #[must_use]
    pub fn cancel_refresh(&self) -> bool {
        cancel_refresh(&self.inner)
    }

    #[must_use]
    pub fn snapshot(&self) -> WorkspaceSnapshot {
        read_revision_consistent(
            &self.inner.revision,
            &self.inner.snapshot_writers,
            |revision| {
                let mut hosts = self
                    .inner
                    .hosts
                    .read()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clone();
                let current_runtime = self
                    .inner
                    .host
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .as_ref()
                    .map(|published| {
                        (
                            published.value.snapshot.endpoint().clone(),
                            published.value.snapshot.runtime().clone(),
                        )
                    });
                project_herdr_lifecycle(
                    &mut hosts,
                    current_runtime.as_ref(),
                    &self.inner.herdr_lifecycle,
                );
                WorkspaceSnapshot {
                    revision,
                    appearance: self.inner.appearance.clone(),
                    content: self
                        .inner
                        .state
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .clone(),
                    hosts,
                    selected_host: self
                        .inner
                        .selected_host
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .clone(),
                    notice: self
                        .inner
                        .terminal_notice
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .clone(),
                    retained_selections: self
                        .inner
                        .retained_presentations
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .selections(),
                }
            },
        )
    }

    /// Begin an attach-only presentation for one discovered session.
    ///
    /// # Errors
    ///
    /// Returns an error if another presentation is active or the requested
    /// session is not in the latest resolved inventory.
    pub fn attach(&self, selection: &SessionSelection) -> Result<(), WorkspaceError> {
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some()
        {
            return Err(WorkspaceError::new(
                "a terminal presentation is already open",
            ));
        }
        let navigation_generation = self.begin_navigation();
        let (key, request) = self.navigation_target(selection)?;
        match request {
            None if self.activate_retained_presentation(&key, None)? => Ok(()),
            None => Err(WorkspaceError::new(
                "the retained terminal presentation is no longer available",
            )),
            Some(request) => self.start_attachment(request, None, navigation_generation),
        }
    }

    /// Select another presentation, retaining the current ordinary tmux client.
    ///
    /// A presentation that has already been opened is restored synchronously.
    /// The first visit still performs a fresh identity check immediately before
    /// launching its ordinary client.
    ///
    /// # Errors
    ///
    /// Returns an error if the requested session is absent from the latest
    /// inventory or the replacement attachment cannot be started.
    pub fn switch_session(&self, selection: &SessionSelection) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.switch_session_locked(selection)
    }

    /// Open one exact registered KWT worktree through KWT's repair-or-open
    /// path. The resulting presentation is an ordinary tmux client and is
    /// retained exactly like a directly discovered tmux presentation.
    ///
    /// # Errors
    ///
    /// Returns an error when the host, project, or durable worktree identity
    /// no longer matches current authoritative inventory.
    #[allow(clippy::too_many_arguments)]
    pub fn open_kwt_worktree(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        project_path: &str,
        registration_fingerprint: &str,
        worktree_path: &str,
        generation: Option<&str>,
        session_name: &str,
    ) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let request = capture_kwt_worktree_request(
            &self.inner,
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            worktree_path,
            generation,
            session_name,
        )?;
        let key = request.presentation_key();
        if self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some_and(|active| active.request.presentation_key() == key)
        {
            return Ok(());
        }
        let navigation_generation = self.begin_navigation();
        let already_open = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(&key);
        let in_flight_fallback = self.supersede_inflight_attachment()?;
        let visible_previous = self.retain_active_presentation()?;
        let previous = in_flight_fallback.or(visible_previous);
        let fallback = previous.clone().map(|presentation| FallbackAuthority {
            presentation,
            target: key.clone(),
            navigation_generation,
        });
        match self.activate_retained_presentation(&key, fallback.clone()) {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) => {
                if let Some(previous) = previous {
                    let _restored = self.activate_retained_presentation(&previous, None);
                }
                return Err(error);
            }
        }
        if already_open {
            if let Some(previous) = previous {
                let _restored = self.activate_retained_presentation(&previous, None);
            }
            return Err(WorkspaceError::new(
                "the retained worktree presentation is no longer available",
            ));
        }
        self.start_attachment(request, fallback, navigation_generation)
    }

    fn switch_session_locked(&self, selection: &SessionSelection) -> Result<(), WorkspaceError> {
        let same_visible_selection = matches!(
            self.inner
                .state
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone(),
            WorkspaceContent::Terminal { host_id, endpoint, session, kind, .. }
                if host_id == selection.host_id()
                    && endpoint == selection.endpoint()
                    && session == selection.session()
                    && kind == selection.kind()
        );
        let has_active_attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some();
        if same_visible_selection && !has_active_attachment {
            return Ok(());
        }
        if selection.kind() == SessionKind::Herdr
            && herdr_operation_pending_for_selection(&self.inner, selection)
        {
            return Err(WorkspaceError::new(
                "this Herdr session is already starting or changing lifecycle",
            ));
        }

        let (key, request) = self.navigation_target(selection)?;
        if self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some_and(|active| active.request.presentation_key() == key)
        {
            return Ok(());
        }
        let navigation_generation = self.begin_navigation();
        let already_open = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(&key);
        let in_flight_fallback = self.supersede_inflight_attachment()?;
        let visible_previous = self.retain_active_presentation()?;
        let previous = in_flight_fallback.or(visible_previous);
        let fallback = previous.clone().map(|presentation| FallbackAuthority {
            presentation,
            target: key.clone(),
            navigation_generation,
        });
        match self.activate_retained_presentation(&key, fallback.clone()) {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) => {
                if let Some(previous) = previous {
                    let _restored = self.activate_retained_presentation(&previous, None);
                }
                return Err(error);
            }
        }
        if already_open {
            if let Some(previous) = previous {
                let _restored = self.activate_retained_presentation(&previous, None);
            }
            return Err(WorkspaceError::new(
                "the retained terminal presentation is no longer available",
            ));
        }
        let Some(request) = request else {
            if let Some(previous) = previous {
                let _restored = self.activate_retained_presentation(&previous, None);
            }
            return Err(WorkspaceError::new(
                "the retained terminal presentation is no longer available",
            ));
        };
        self.start_attachment(request, fallback, navigation_generation)
    }

    /// Create or attach to one exact local WSL tmux session with a consumed
    /// one-shot authority.
    ///
    /// Existing visible presentations are retained and restored if the new
    /// client cannot be established. Once the atomic client is launched,
    /// failure never reruns creation or destroys the resulting session.
    ///
    /// # Errors
    ///
    /// Returns an error when the name is invalid, the selected endpoint
    /// changed, the host has no admitted inventory, a matching session is
    /// already present, or the creation task cannot be started.
    pub fn create_session(
        &self,
        host_id: &str,
        endpoint: &str,
        name: &str,
    ) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let name =
            SessionName::parse(name).map_err(|error| WorkspaceError::new(error.to_string()))?;
        let navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let request = capture_create_request(&self.inner, host_id, endpoint, name)?;
        let navigation_generation = self.begin_navigation();
        let in_flight_fallback = self.supersede_inflight_attachment()?;
        let visible_previous = self.retain_active_presentation()?;
        let previous = in_flight_fallback.or(visible_previous);
        let cancellation = CancellationToken::new();
        *self
            .inner
            .pending_creation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(PendingCreation {
            navigation_generation,
            previous: previous.clone(),
            cancellation: cancellation.clone(),
            herdr_operation: None,
        });
        clear_terminal_notice(&self.inner);
        set_inner_state(
            &self.inner,
            WorkspaceContent::Attaching {
                host_id: request.host_id.clone(),
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.as_str().to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        let inner = Arc::clone(&self.inner);
        let spawn_request = request.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-create".to_owned())
            .spawn(move || {
                run_create(&inner, &spawn_request, navigation_generation, &cancellation);
            })
        {
            drop(navigation);
            restore_inventory_after_creation_failure(
                &self.inner,
                None,
                navigation_generation,
                format!("start tmux creation task: {error}"),
            );
            return Err(WorkspaceError::new(format!(
                "start tmux creation task: {error}"
            )));
        }
        Ok(())
    }

    /// Launch one new named Herdr session and attach its ordinary client.
    ///
    /// The launch authority is consumed once. Failure never repeats the
    /// constructive action automatically.
    ///
    /// # Errors
    ///
    /// Returns an error when the name is invalid, Herdr is unavailable, the
    /// endpoint changed, or the task cannot be started.
    pub fn create_herdr_session(
        &self,
        host_id: &str,
        endpoint: &str,
        name: &str,
    ) -> Result<(), WorkspaceError> {
        let name = HerdrSessionName::parse(name)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let request = capture_herdr_create_request(&self.inner, host_id, endpoint, name)?;
        self.start_herdr_launch(&request, navigation)
    }

    /// Create one named Zellij session and attach its ordinary client.
    ///
    /// # Errors
    ///
    /// Returns an error when the name is invalid, Zellij or the selected host
    /// is unavailable, another session operation is active, or the background
    /// launch task cannot be started.
    pub fn create_zellij_session(
        &self,
        host_id: &str,
        endpoint: &str,
        name: &str,
    ) -> Result<(), WorkspaceError> {
        let name = ZellijSessionName::parse(name)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let request = capture_zellij_create_request(&self.inner, host_id, endpoint, name)?;
        let navigation_generation = self.begin_navigation();
        let in_flight_fallback = self.supersede_inflight_attachment()?;
        let visible_previous = self.retain_active_presentation()?;
        let previous = in_flight_fallback.or(visible_previous);
        let cancellation = CancellationToken::new();
        *self
            .inner
            .pending_creation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(PendingCreation {
            navigation_generation,
            previous,
            cancellation: cancellation.clone(),
            herdr_operation: None,
        });
        clear_terminal_notice(&self.inner);
        set_inner_state(
            &self.inner,
            WorkspaceContent::Attaching {
                host_id: request.host_id.clone(),
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.as_str().to_owned(),
                kind: SessionKind::Zellij,
            },
        );
        let inner = Arc::clone(&self.inner);
        let spawn_request = request.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-zellij-create".to_owned())
            .spawn(move || {
                run_zellij_create(&inner, &spawn_request, navigation_generation, &cancellation);
            })
        {
            drop(navigation);
            restore_inventory_after_creation_failure(
                &self.inner,
                None,
                navigation_generation,
                format!("start Zellij creation task: {error}"),
            );
            return Err(WorkspaceError::new(format!(
                "start Zellij creation task: {error}"
            )));
        }
        Ok(())
    }

    /// Restart one stopped Herdr session and attach the launched client.
    ///
    /// Restart consumes the same one-shot constructive authority as creation,
    /// but only after the stopped record and its configuration paths are
    /// revalidated.
    ///
    /// # Errors
    ///
    /// Returns an error when the selected session is no longer stopped, the
    /// endpoint changed, or the launch task cannot be started.
    pub fn restart_herdr_session(
        &self,
        selection: &SessionSelection,
    ) -> Result<(), WorkspaceError> {
        let navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let request = capture_herdr_restart_request(&self.inner, selection)?;
        self.start_herdr_launch(&request, navigation)
    }

    fn start_herdr_launch(
        &self,
        request: &HerdrCreateRequest,
        navigation: std::sync::MutexGuard<'_, ()>,
    ) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let operation_key = request.operation_key();
        if !self
            .inner
            .herdr_lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .reserve_launch(&operation_key)
        {
            return Err(WorkspaceError::new(
                "this Herdr session is already starting or changing lifecycle",
            ));
        }
        let navigation_generation = self.begin_navigation();
        let in_flight_fallback = match self.supersede_inflight_attachment() {
            Ok(fallback) => fallback,
            Err(error) => {
                finish_herdr_launch(&self.inner, &operation_key);
                return Err(error);
            }
        };
        let visible_previous = match self.retain_active_presentation() {
            Ok(previous) => previous,
            Err(error) => {
                finish_herdr_launch(&self.inner, &operation_key);
                return Err(error);
            }
        };
        let previous = in_flight_fallback.or(visible_previous);
        let cancellation = CancellationToken::new();
        *self
            .inner
            .pending_creation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(PendingCreation {
            navigation_generation,
            previous: previous.clone(),
            cancellation: cancellation.clone(),
            herdr_operation: Some(operation_key),
        });
        clear_terminal_notice(&self.inner);
        set_inner_state(
            &self.inner,
            WorkspaceContent::Attaching {
                host_id: request.host_id.clone(),
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.as_str().to_owned(),
                kind: SessionKind::Herdr,
            },
        );

        let inner = Arc::clone(&self.inner);
        let spawn_request = request.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-herdr-launch".to_owned())
            .spawn(move || {
                run_herdr_create(&inner, &spawn_request, navigation_generation, &cancellation);
            })
        {
            drop(navigation);
            restore_inventory_after_creation_failure(
                &self.inner,
                None,
                navigation_generation,
                format!("start Herdr launch task: {error}"),
            );
            return Err(WorkspaceError::new(format!(
                "start Herdr launch task: {error}"
            )));
        }
        Ok(())
    }

    fn begin_navigation(&self) -> u64 {
        invalidate_pending_kill(&self.inner);
        invalidate_pending_herdr_lifecycle(&self.inner);
        self.inner
            .navigation_generation
            .fetch_add(1, Ordering::AcqRel)
            .checked_add(1)
            .expect("navigation generation exhausted")
    }

    fn retained_key_for_selection(&self, selection: &SessionSelection) -> Option<PresentationKey> {
        self.inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .key_for_selection(selection)
    }

    fn navigation_target(
        &self,
        selection: &SessionSelection,
    ) -> Result<(PresentationKey, Option<AttachRequest>), WorkspaceError> {
        let retained = self.retained_key_for_selection(selection);
        choose_navigation_target(retained, capture_attach_request(&self.inner, selection))
    }

    fn supersede_inflight_attachment(&self) -> Result<Option<PresentationKey>, WorkspaceError> {
        let mut attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let attaching = matches!(
            *self
                .inner
                .state
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            WorkspaceContent::Attaching { .. }
        );
        if !attaching {
            return Ok(None);
        }
        let active = attachment.take_active();
        drop(attachment);
        let fallback = if let Some(active) = active {
            active.fallback.map(|fallback| fallback.presentation)
        } else {
            let pending = self
                .inner
                .pending_creation
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take()
                .ok_or_else(|| {
                    WorkspaceError::new("the in-flight terminal presentation is not available")
                })?;
            pending.cancellation.cancel();
            finish_pending_creation(&self.inner, &pending);
            pending.previous
        };
        clear_pending_paste(&self.inner);
        self.restore_inventory_state();
        Ok(fallback)
    }

    fn retain_active_presentation(&self) -> Result<Option<PresentationKey>, WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let mut attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active_attachment) = attachment.active() else {
            return Ok(None);
        };
        let selection = active_attachment.request.selection();
        let presentation_id = {
            let state = self
                .inner
                .state
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            match &*state {
                WorkspaceContent::Terminal {
                    presentation_id, ..
                } => *presentation_id,
                _ => return Ok(None),
            }
        };
        let mut worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if worker.active().is_none() {
            return Err(WorkspaceError::new(
                "the active terminal presentation is not available",
            ));
        }
        if let Some(active) = worker.active() {
            active.set_clipboard_writes_enabled(false);
            let _cancelled = active.cancel_paste();
        }
        let active_attachment = attachment
            .take_active()
            .expect("active attachment was checked");
        let key = active_attachment.request.presentation_key();
        let active_worker = worker.invalidate().expect("active worker was checked");
        drop(worker);
        clear_pending_paste(&self.inner);
        clear_terminal_notice(&self.inner);
        self.inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(RetainedPresentation {
                key: key.clone(),
                selection: selection.clone(),
                attachment: active_attachment,
                worker: active_worker,
                presentation_id,
            });
        self.restore_inventory_state();
        drop(attachment);
        Ok(Some(key))
    }

    fn activate_retained_presentation(
        &self,
        key: &PresentationKey,
        fallback: Option<FallbackAuthority>,
    ) -> Result<bool, WorkspaceError> {
        activate_retained_presentation(&self.inner, key, fallback)
    }

    fn start_attachment(
        &self,
        request: AttachRequest,
        fallback: Option<FallbackAuthority>,
        navigation_generation: u64,
    ) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let generation;
        {
            let mut attachment = self
                .inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut state = self
                .inner
                .state
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if matches!(
                &*state,
                WorkspaceContent::Attaching { .. } | WorkspaceContent::Terminal { .. }
            ) {
                return Err(WorkspaceError::new(
                    "a terminal presentation is already opening",
                ));
            }
            generation = attachment
                .reserve_with_fallback(request.clone(), AttachTerm::Xterm256Color, fallback)
                .ok_or_else(|| WorkspaceError::new("a terminal presentation is already opening"))?;
            clear_terminal_notice(&self.inner);
            *state = WorkspaceContent::Attaching {
                host_id: request.host_id.clone(),
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.clone(),
                kind: request.target.kind(),
            };
        }
        self.inner.revision.fetch_add(1, Ordering::Release);
        let inner = Arc::clone(&self.inner);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-attach".to_owned())
            .spawn(move || {
                run_attach(&inner, &request, AttachTerm::Xterm256Color, generation);
            })
        {
            let mut attachment = self
                .inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some((_, fallback)) =
                failed_attachment_context(&self.inner, &attachment, generation)
            {
                let fallback = fallback
                    .filter(|fallback| fallback.navigation_generation == navigation_generation);
                attachment.clear_if_current(generation);
                drop(attachment);
                self.restore_inventory_state();
                restore_attach_fallback_locked(&self.inner, fallback);
            }
            return Err(WorkspaceError::new(format!("start attach task: {error}")));
        }
        Ok(())
    }

    /// Queue a neutral input event for the active presentation.
    ///
    /// # Errors
    ///
    /// Returns an error when no terminal is active or its worker has stopped.
    pub fn send_key(&self, input: KeyInput) -> Result<(), WorkspaceError> {
        let worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        worker
            .active()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .send_key(input)
            .map_err(|error| WorkspaceError::from_worker(&error))
    }

    /// Queue a terminal-grid mouse event for the active presentation.
    ///
    /// # Errors
    ///
    /// Returns an error when no terminal is active or its worker has stopped.
    pub fn send_mouse(&self, input: MouseInput) -> Result<(), WorkspaceError> {
        let worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        worker
            .active()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .send_mouse(input)
            .map_err(|error| WorkspaceError::from_worker(&error))
    }

    /// Approve the one pending unsafe paste request.
    ///
    /// # Errors
    ///
    /// Returns an error when no paste is pending or the terminal stopped.
    pub fn approve_paste(&self) -> Result<(), WorkspaceError> {
        let paste = self
            .inner
            .pending_paste
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            .ok_or_else(|| WorkspaceError::new("no paste is awaiting confirmation"))?;
        let worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if paste.worker_generation != worker.generation() {
            return Err(WorkspaceError::new(
                "paste confirmation belongs to a closed terminal",
            ));
        }
        worker
            .active()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .confirm_paste(paste.input)
            .map_err(|error| WorkspaceError::new(error.to_string()))
    }

    pub fn cancel_paste(&self) {
        let paste = self
            .inner
            .pending_paste
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        let Some(paste) = paste else {
            return;
        };
        let worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if paste.worker_generation == worker.generation()
            && let Some(worker) = worker.active()
        {
            let _ignored = worker.cancel_paste();
        }
    }

    /// Query one session's live identity before exposing destructive
    /// confirmation to the presentation layer.
    ///
    /// # Errors
    ///
    /// Returns an error when the selection is not part of the current WSL
    /// inventory or the background query cannot be started.
    pub fn request_session_kill(&self, selection: &SessionSelection) -> Result<(), WorkspaceError> {
        let (generation, removed) = invalidate_pending_kill(&self.inner);
        if removed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
        let (_herdr_generation, herdr_removed) = invalidate_pending_herdr_lifecycle(&self.inner);
        if herdr_removed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
        let request = capture_kill_request(&self.inner, selection, generation)?;
        if let KillCaptureRequest::Zellij(pending) = request {
            if !publish_pending_kill(&self.inner, pending) {
                return Err(WorkspaceError::new(
                    "Zellij kill request was superseded before confirmation",
                ));
            }
            return Ok(());
        }
        let KillCaptureRequest::Tmux {
            selection,
            host,
            endpoint,
            runtime,
        } = request
        else {
            unreachable!("Zellij kill requests return above");
        };
        let workspace = self.clone();
        thread::Builder::new()
            .name("ghosthub-session-kill-identity".to_owned())
            .spawn(move || {
                let result = host.capture_live_session(
                    &endpoint,
                    &runtime,
                    selection.session(),
                    &CancellationToken::new(),
                );
                match result {
                    Ok(target) => {
                        publish_pending_kill(
                            &workspace.inner,
                            PendingKill {
                                generation,
                                selection,
                                host,
                                target: KillTarget::Tmux(Arc::new(target)),
                            },
                        );
                    }
                    Err(error) => {
                        let pending_kill = workspace
                            .inner
                            .pending_kill
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        if workspace.inner.kill_generation.load(Ordering::Acquire) != generation {
                            return;
                        }
                        workspace.push_operation_error(error.to_string());
                        workspace.inner.revision.fetch_add(1, Ordering::Release);
                        drop(pending_kill);
                    }
                }
            })
            .map_err(|error| WorkspaceError::new(format!("verify tmux session: {error}")))?;
        Ok(())
    }

    #[must_use]
    pub fn session_kill_confirmation(&self) -> Option<SessionKillConfirmation> {
        let pending_kill = self
            .inner
            .pending_kill
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let generation = self.inner.kill_generation.load(Ordering::Acquire);
        pending_kill
            .as_ref()
            .filter(|pending| pending.generation == generation)
            .map(|pending| SessionKillConfirmation {
                selection: pending.selection.clone(),
            })
    }

    pub fn cancel_session_kill(&self) {
        let (_generation, removed) = invalidate_pending_kill(&self.inner);
        if removed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
    }

    /// Execute the identity-guarded kill approved by the user.
    ///
    /// # Errors
    ///
    /// Returns an error when no live confirmation is pending or the kill task
    /// cannot be started.
    pub fn confirm_session_kill(&self) -> Result<(), WorkspaceError> {
        let pending = self
            .inner
            .pending_kill
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            .ok_or_else(|| WorkspaceError::new("no session kill is awaiting confirmation"))?;
        if self.inner.kill_generation.load(Ordering::Acquire) != pending.generation {
            return Err(WorkspaceError::new(
                "session kill confirmation is no longer current",
            ));
        }
        self.inner.revision.fetch_add(1, Ordering::Release);
        let workspace = self.clone();
        let retry = PendingKill {
            generation: pending.generation,
            selection: pending.selection.clone(),
            host: pending.host.clone(),
            target: pending.target.clone(),
        };
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-session-kill".to_owned())
            .spawn(move || {
                let _operation = workspace
                    .inner
                    .session_operations
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                match &pending.target {
                    KillTarget::Tmux(target) => {
                        match pending
                            .host
                            .kill_live_session(target, &CancellationToken::new())
                        {
                            Ok(()) => workspace.finish_session_kill(target),
                            Err(error) => workspace.push_operation_error(error.to_string()),
                        }
                    }
                    KillTarget::Zellij {
                        endpoint,
                        runtime,
                        executable,
                        name,
                    } => {
                        let mut suppressed = None;
                        let result = pending.host.kill_zellij_session(
                            endpoint,
                            runtime,
                            executable,
                            name,
                            &CancellationToken::new(),
                            || {
                                suppressed =
                                    workspace.close_zellij_presentations(endpoint, runtime, name);
                            },
                        );
                        match result {
                            Ok(()) => {
                                workspace.finish_zellij_presentation(endpoint, runtime, name);
                            }
                            Err(error) => {
                                workspace.restore_suppressed_zellij_presentation(suppressed);
                                workspace.push_operation_error(error.to_string());
                            }
                        }
                    }
                }
                let _refresh_started = workspace.refresh();
                workspace.inner.revision.fetch_add(1, Ordering::Release);
            })
        {
            *self
                .inner
                .pending_kill
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(retry);
            self.inner.revision.fetch_add(1, Ordering::Release);
            return Err(WorkspaceError::new(format!(
                "start session kill task: {error}"
            )));
        }
        Ok(())
    }

    /// Prepare a confirmed Herdr Stop or Delete action from current inventory.
    ///
    /// The host revalidates the record again immediately before mutation.
    ///
    /// # Errors
    ///
    /// Returns an error when the selected record is missing, in the wrong
    /// state, or is Herdr's non-deletable default session.
    pub fn request_herdr_lifecycle(
        &self,
        selection: &SessionSelection,
        action: HerdrLifecycleAction,
    ) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let (generation, removed) = invalidate_pending_herdr_lifecycle(&self.inner);
        if removed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
        self.cancel_session_kill();
        let pending = capture_herdr_lifecycle(&self.inner, selection, action, generation)?;
        let mut lifecycle = self
            .inner
            .herdr_lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if lifecycle.in_flight_action(&pending.key()).is_some() {
            return Err(WorkspaceError::new(
                "a lifecycle action is already running for this Herdr session",
            ));
        }
        if lifecycle.launch_pending(&pending.key()) {
            return Err(WorkspaceError::new("this Herdr session is still starting"));
        }
        if self
            .inner
            .herdr_lifecycle_generation
            .load(Ordering::Acquire)
            != generation
        {
            return Err(WorkspaceError::new(
                "Herdr lifecycle request is no longer current",
            ));
        }
        lifecycle.pending = Some(pending);
        drop(lifecycle);
        self.inner.revision.fetch_add(1, Ordering::Release);
        Ok(())
    }

    #[must_use]
    pub fn herdr_lifecycle_confirmation(&self) -> Option<HerdrLifecycleConfirmation> {
        let generation = self
            .inner
            .herdr_lifecycle_generation
            .load(Ordering::Acquire);
        self.inner
            .herdr_lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .pending
            .as_ref()
            .filter(|pending| pending.generation == generation)
            .map(|pending| HerdrLifecycleConfirmation {
                selection: pending.selection.clone(),
                action: pending.action,
            })
    }

    pub fn cancel_herdr_lifecycle(&self) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let (_generation, removed) = invalidate_pending_herdr_lifecycle(&self.inner);
        if removed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
    }

    /// Execute the confirmed, freshly revalidated Herdr mutation.
    ///
    /// # Errors
    ///
    /// Returns an error when no confirmation is pending or the lifecycle task
    /// cannot be started.
    pub fn confirm_herdr_lifecycle(&self) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let mut lifecycle = self
            .inner
            .herdr_lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let pending = lifecycle.pending.take().ok_or_else(|| {
            WorkspaceError::new("no Herdr lifecycle action is awaiting confirmation")
        })?;
        if self
            .inner
            .herdr_lifecycle_generation
            .load(Ordering::Acquire)
            != pending.generation
        {
            return Err(WorkspaceError::new(
                "Herdr lifecycle confirmation is no longer current",
            ));
        }
        if let Err(error) = require_host_session_actions(&self.inner, &pending.selection) {
            lifecycle.pending = Some(pending);
            return Err(error);
        }
        if !lifecycle.start(&pending) {
            return Err(WorkspaceError::new(
                "a lifecycle action is already running for this Herdr session",
            ));
        }
        drop(lifecycle);
        self.inner.revision.fetch_add(1, Ordering::Release);
        let workspace = self.clone();
        let retry = pending.clone();
        if let Err(error) = thread::Builder::new()
            .name(format!("ghosthub-herdr-{}", pending.action.command()))
            .spawn(move || run_herdr_lifecycle(&workspace, &pending))
        {
            let mut lifecycle = self
                .inner
                .herdr_lifecycle
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            lifecycle.finish(retry.generation);
            if self
                .inner
                .herdr_lifecycle_generation
                .load(Ordering::Acquire)
                == retry.generation
                && lifecycle.pending.is_none()
            {
                lifecycle.pending = Some(retry);
            }
            drop(lifecycle);
            self.inner.revision.fetch_add(1, Ordering::Release);
            return Err(WorkspaceError::new(format!(
                "start Herdr lifecycle task: {error}"
            )));
        }
        Ok(())
    }

    fn push_operation_error(&self, error: String) {
        self.push_operation_event(WorkspaceEvent::Error(error));
    }

    fn push_operation_event(&self, event: WorkspaceEvent) {
        let mut events = self
            .inner
            .operation_events
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if events.len() >= MAX_EVENTS_PER_DRAIN {
            events.pop_front();
        }
        events.push_back(event);
    }

    fn finish_session_kill(&self, target: &LiveSessionTarget) {
        self.finish_killed_presentation(target.endpoint(), target.runtime(), target.identity());
    }

    fn finish_killed_presentation(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        identity: &session::SessionIdentity,
    ) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let key_matches = |request: &AttachRequest| {
            request.endpoint == *endpoint
                && request.runtime == *runtime
                && request.target.tmux() == Some(identity)
        };
        let active_matches = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some_and(|active| key_matches(&active.request));
        if active_matches {
            self.detach_locked();
        }
        let changed = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove_matching(|key| {
                key.endpoint == endpoint.distro()
                    && key.runtime == *runtime
                    && key.target.tmux() == Some(identity)
            });
        if changed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
    }

    fn finish_zellij_presentation(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        name: &str,
    ) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let target_matches = |target: &AttachTarget| matches!(target, AttachTarget::Zellij { name: target_name, .. } if target_name == name);
        let active_matches = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some_and(|active| {
                active.request.endpoint == *endpoint
                    && active.request.runtime == *runtime
                    && target_matches(&active.request.target)
            });
        if active_matches {
            self.detach_locked();
        }
        let changed = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove_matching(|key| {
                key.endpoint == endpoint.distro()
                    && key.runtime == *runtime
                    && target_matches(&key.target)
            });
        if changed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
    }

    fn close_zellij_presentations(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        name: &str,
    ) -> Option<SuppressedZellijPresentation> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let navigation_generation = self.inner.navigation_generation.load(Ordering::Acquire);
        let target_matches = |target: &AttachTarget| matches!(target, AttachTarget::Zellij { name: target_name, .. } if target_name == name);
        let mut attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let active_selection = attachment.active().and_then(|active| {
            (active.request.endpoint == *endpoint
                && active.request.runtime == *runtime
                && target_matches(&active.request.target))
            .then(|| active.request.selection())
        });
        if active_selection.is_some() {
            attachment.invalidate();
            self.inner
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .invalidate();
            clear_pending_paste(&self.inner);
            clear_terminal_notice(&self.inner);
            self.restore_inventory_state();
        }
        drop(attachment);

        let removed = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take_matching(|key| {
                key.endpoint == endpoint.distro()
                    && key.runtime == *runtime
                    && target_matches(&key.target)
            });
        let changed = active_selection.is_some() || !removed.is_empty();
        let retained = active_selection.is_none().then(|| {
            removed
                .into_iter()
                .next()
                .map(|presentation| ClosedRetainedPresentation {
                    key: presentation.key,
                    attachment: presentation.attachment,
                    presentation_id: presentation.presentation_id,
                })
        });
        if changed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
        (active_selection.is_some() || retained.is_some()).then_some(SuppressedZellijPresentation {
            active_selection,
            retained: retained.flatten(),
            navigation_generation,
        })
    }

    fn restore_suppressed_zellij_presentation(
        &self,
        suppressed: Option<SuppressedZellijPresentation>,
    ) {
        let Some(suppressed) = suppressed else {
            return;
        };
        if let Some(retained) = suppressed.retained {
            match reopen_closed_retained_presentation(&self.inner, retained) {
                Ok(presentation) => {
                    publish_restored_retained_presentation(&self.inner, presentation);
                }
                Err(error) => {
                    self.push_operation_error(format!(
                        "could not restore a retained Zellij presentation after a failed kill: {error}"
                    ));
                }
            }
        }
        let Some(selection) = suppressed.active_selection else {
            return;
        };
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self.inner.navigation_generation.load(Ordering::Acquire)
            != suppressed.navigation_generation
        {
            return;
        }
        if let Err(error) = self.switch_session_locked(&selection) {
            self.push_operation_error(format!(
                "could not restore the Zellij presentation after a failed kill: {error}"
            ));
        }
    }

    fn finish_herdr_presentation(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        record: &session::HerdrSessionRecord,
    ) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let key_matches = |request: &AttachRequest| {
            request.endpoint == *endpoint
                && request.runtime == *runtime
                && request.name == record.name()
                && request.target.herdr_matches(record)
        };
        let active_matches = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some_and(|active| key_matches(&active.request));
        if active_matches {
            self.detach_locked();
        }
        let changed = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove_matching(|key| {
                key.endpoint == endpoint.distro()
                    && key.runtime == *runtime
                    && key.target.herdr_matches(record)
            });
        if changed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
    }

    fn close_herdr_presentations(
        &self,
        pending: &PendingHerdrLifecycle,
    ) -> Option<SuppressedHerdrPresentation> {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let navigation_generation = self.inner.navigation_generation.load(Ordering::Acquire);
        let mut attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let active_selection = attachment.active().and_then(|active| {
            let matches = active.request.endpoint == pending.endpoint
                && active.request.runtime == pending.runtime
                && active.request.target.herdr_matches(&pending.record);
            matches.then(|| active.request.selection())
        });
        if active_selection.is_some() {
            attachment.invalidate();
            self.inner
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .invalidate();
            clear_pending_paste(&self.inner);
            clear_terminal_notice(&self.inner);
            self.restore_inventory_state();
        }
        drop(attachment);

        let removed = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take_matching(|key| {
                key.endpoint == pending.endpoint.distro()
                    && key.runtime == pending.runtime
                    && key.target.herdr_matches(&pending.record)
            });
        let changed = active_selection.is_some() || !removed.is_empty();
        let retained = active_selection.is_none().then(|| {
            removed
                .into_iter()
                .next()
                .map(|presentation| ClosedRetainedPresentation {
                    key: presentation.key,
                    attachment: presentation.attachment,
                    presentation_id: presentation.presentation_id,
                })
        });
        if changed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
        (active_selection.is_some() || retained.is_some()).then_some(SuppressedHerdrPresentation {
            active_selection,
            retained: retained.flatten(),
            navigation_generation,
        })
    }

    fn restore_suppressed_herdr_presentation(
        &self,
        suppressed: Option<SuppressedHerdrPresentation>,
    ) {
        let Some(suppressed) = suppressed else {
            return;
        };
        if let Some(retained) = suppressed.retained {
            match reopen_closed_retained_presentation(&self.inner, retained) {
                Ok(presentation) => {
                    publish_restored_retained_presentation(&self.inner, presentation);
                }
                Err(error) => {
                    self.push_operation_error(format!(
                        "could not restore a retained Herdr presentation after a failed lifecycle action: {error}"
                    ));
                }
            }
        }
        let Some(selection) = suppressed.active_selection else {
            return;
        };
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self.inner.navigation_generation.load(Ordering::Acquire)
            != suppressed.navigation_generation
        {
            return;
        }
        if let Err(error) = self.switch_session_locked(&selection) {
            self.push_operation_error(format!(
                "could not restore the Herdr presentation after a failed lifecycle action: {error}"
            ));
        }
    }

    /// Update the desired grid and resize an active VT/PTTY pair together.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid dimensions or a stopped terminal worker.
    pub fn resize(&self, columns: usize, rows: usize) -> Result<(), WorkspaceError> {
        self.resize_with_pixels(columns, rows, 0, 0)
    }

    /// Update the ordered grid and pixel dimensions from the presentation.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid dimensions or a stopped terminal worker.
    pub fn resize_with_pixels(
        &self,
        columns: usize,
        rows: usize,
        pixel_width: u16,
        pixel_height: u16,
    ) -> Result<(), WorkspaceError> {
        let size =
            GridSize::new(columns, rows).map_err(|error| WorkspaceError::new(error.to_string()))?;
        let geometry = {
            let mut geometry = self
                .inner
                .terminal_geometry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            geometry.grid = size;
            geometry.pixels = PixelSize::new(pixel_width, pixel_height);
            geometry.sequence = geometry.sequence.saturating_add(1);
            *geometry
        };
        if let Some(worker) = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
        {
            worker
                .resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
                .map_err(|error| WorkspaceError::from_worker(&error))?;
        }
        Ok(())
    }

    /// Complete a configured local OSC 52 read through the active worker.
    ///
    /// # Errors
    ///
    /// Returns an error when no terminal is active or its worker stopped.
    pub fn complete_clipboard_read(
        &self,
        request: &ClipboardRead,
        contents: &str,
    ) -> Result<(), WorkspaceError> {
        self.send_clipboard_response(request.respond(contents))
    }

    /// Queue a response produced by an authorized local OSC 52 read.
    ///
    /// # Errors
    ///
    /// Returns an error when no terminal is active, its worker stopped, or
    /// bounded input delivery is applying backpressure.
    pub fn send_clipboard_response(&self, bytes: Vec<u8>) -> Result<(), WorkspaceError> {
        let worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        worker
            .active()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .send_bytes(bytes)
            .map_err(|error| WorkspaceError::from_worker(&error))
    }

    pub fn detach(&self) {
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.detach_locked();
    }

    fn detach_locked(&self) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        self.begin_navigation();
        if let Some(pending) = self
            .inner
            .pending_creation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            pending.cancellation.cancel();
            finish_pending_creation(&self.inner, &pending);
        }
        self.inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .invalidate();
        clear_pending_paste(&self.inner);
        clear_terminal_notice(&self.inner);
        self.inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .invalidate();
        self.restore_inventory_state();
    }

    #[must_use]
    pub fn drain_events(&self) -> (Vec<WorkspaceEvent>, bool) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _drain = self
            .inner
            .event_drain
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut emitted = Vec::new();
        let operation_has_more = self.drain_operation_events(&mut emitted);
        let mut exited = false;
        let mut exited_attachment = None;
        let mut exited_worker_generation = None;
        let mut exit_error = None;
        let mut retry_term = false;
        let mut processed = 0;
        for _ in 0..ACTIVE_EVENT_BUDGET {
            let Some((event, source_worker_generation, client_confirmed_live)) =
                self.next_terminal_event()
            else {
                break;
            };
            match event {
                Ok(Some(TerminalEvent::ClipboardWrite { write, .. })) => {
                    processed += 1;
                    emitted.push(WorkspaceEvent::ClipboardWrite {
                        text: write.text,
                        primary: write.target == ClipboardTarget::Selection,
                    });
                }
                Ok(Some(TerminalEvent::ClipboardRead(read))) => {
                    processed += 1;
                    emitted.push(WorkspaceEvent::ClipboardRead(ClipboardRead { inner: read }));
                }
                Ok(Some(TerminalEvent::ConfirmPaste(paste))) => {
                    processed += 1;
                    let mut pending = self
                        .inner
                        .pending_paste
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if pending.is_none() {
                        *pending = Some(PendingPaste {
                            worker_generation: source_worker_generation,
                            input: paste,
                        });
                        emitted.push(WorkspaceEvent::ConfirmPaste);
                    }
                }
                Ok(Some(TerminalEvent::Exited { code, output_tail })) => {
                    processed += 1;
                    let Some((request, term, generation, fallback)) =
                        self.attachment_for_worker(source_worker_generation)
                    else {
                        break;
                    };
                    (retry_term, exit_error) = classify_terminal_exit_event(
                        code,
                        &output_tail,
                        term,
                        client_confirmed_live,
                    );
                    exited_attachment = Some((request, generation, fallback));
                    exited_worker_generation = Some(source_worker_generation);
                    exited = true;
                    break;
                }
                Ok(Some(TerminalEvent::Error(error))) => {
                    processed += 1;
                    emitted.push(WorkspaceEvent::Error(error));
                }
                Ok(None) => break,
                Err(error) => {
                    let Some((request, _, generation, fallback)) =
                        self.attachment_for_worker(source_worker_generation)
                    else {
                        break;
                    };
                    exit_error = Some(error.to_string());
                    exited_attachment = Some((request, generation, fallback));
                    exited_worker_generation = Some(source_worker_generation);
                    exited = true;
                    break;
                }
            }
        }
        if exited && let Some(worker_generation) = exited_worker_generation {
            self.handle_terminal_exit(
                exited_attachment,
                worker_generation,
                retry_term,
                exit_error,
                &mut emitted,
            );
        }
        let active_processed = processed;
        let retained_budget = retained_event_budget(processed, exited);
        let retained_processed = self.drain_retained_events(retained_budget, &mut emitted);
        let may_have_more = operation_has_more
            || event_source_may_have_more(active_processed, ACTIVE_EVENT_BUDGET, exited)
            || event_source_may_have_more(retained_processed, retained_budget, false);
        (emitted, may_have_more)
    }

    fn drain_operation_events(&self, emitted: &mut Vec<WorkspaceEvent>) -> bool {
        let mut events = self
            .inner
            .operation_events
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for _ in 0..RETAINED_EVENT_RESERVE {
            let Some(event) = events.pop_front() else {
                break;
            };
            emitted.push(event);
        }
        !events.is_empty()
    }

    fn next_terminal_event(
        &self,
    ) -> Option<(
        Result<Option<TerminalEvent>, terminal::WorkerError>,
        u64,
        bool,
    )> {
        let (event, worker_generation, confirmed) = {
            let worker = self
                .inner
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let (worker, generation) = worker.active_with_generation()?;
            (worker.try_event(), generation, worker.is_confirmed_live())
        };
        if confirmed {
            self.mark_attachment_confirmed(worker_generation);
        }
        Some((event, worker_generation, confirmed))
    }

    fn drain_retained_events(&self, budget: usize, emitted: &mut Vec<WorkspaceEvent>) -> usize {
        let drain = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .drain_events(budget);
        if drain.changed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
        emitted.extend(drain.emitted);
        for retry in drain.retries {
            self.retry_retained_with_xterm(retry, emitted);
        }
        drain.processed
    }

    fn attachment_for_worker(
        &self,
        worker_generation: u64,
    ) -> Option<(AttachRequest, AttachTerm, u64, Option<FallbackAuthority>)> {
        let attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .generation()
            != worker_generation
        {
            return None;
        }
        attachment.active().map(|active| {
            (
                active.request.clone(),
                active.term,
                active.generation,
                active.fallback.clone(),
            )
        })
    }

    fn mark_attachment_confirmed(&self, worker_generation: u64) {
        let mut attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .generation()
            != worker_generation
        {
            return;
        }
        if let Some(generation) = attachment.active().map(|active| active.generation) {
            attachment.confirm_if_current(generation);
        }
    }

    fn handle_terminal_exit(
        &self,
        attachment: Option<(AttachRequest, u64, Option<FallbackAuthority>)>,
        worker_generation: u64,
        retry_term: bool,
        exit_error: Option<String>,
        emitted: &mut Vec<WorkspaceEvent>,
    ) {
        let Some((request, generation, fallback)) = attachment else {
            return;
        };
        let fallback =
            fallback.filter(|fallback| fallback_owns_request(&self.inner, fallback, &request));
        {
            let mut attachment = self
                .inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut worker = self
                .inner
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !claim_terminal_exit(
                &mut attachment,
                &mut worker,
                generation,
                worker_generation,
                retry_term,
            ) {
                return;
            }
            if let Some(error) = exit_error {
                emitted.push(WorkspaceEvent::Error(error));
            }
            if retry_term {
                publish_terminfo_retry_boundary(
                    &self.inner,
                    &request.host_id,
                    request.endpoint.distro(),
                    &request.name,
                    request.target.kind(),
                );
            } else {
                clear_pending_paste(&self.inner);
                clear_terminal_notice(&self.inner);
                self.restore_inventory_state();
            }
        }
        if retry_term {
            self.retry_with_xterm(request, generation, emitted);
        } else {
            restore_attach_fallback(&self.inner, fallback);
        }
    }

    fn start_refresh(
        &self,
        config: WslConfig,
        executable: Option<WslExecutable>,
        presentation: RefreshPresentation,
    ) {
        let inner = Arc::clone(&self.inner);
        let cancellation = CancellationToken::new();
        let generation = begin_refresh(&inner, &cancellation, presentation);
        let deadline_inner = Arc::clone(&inner);
        let deadline_cancellation = cancellation.clone();
        if let Err(error) = inner.refresh_runtime.spawn_after(
            "ghosthub-wsl-refresh-deadline",
            refresh_budget(generation),
            deadline_cancellation.clone(),
            Box::new(move || {
                expire_refresh(&deadline_inner, generation, &deadline_cancellation);
            }),
        ) {
            fail_refresh_start(
                &inner,
                generation,
                &cancellation,
                "schedule WSL refresh deadline",
                &error,
            );
            return;
        }
        let discovery = Arc::clone(&inner.discovery);
        let existing_host = inner
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map(|published| published.value.host.clone());
        let task_inner = Arc::clone(&inner);
        let task_cancellation = cancellation.clone();
        let spawn_result = inner.refresh_runtime.spawn(
            "ghosthub-wsl-discovery",
            Box::new(move || {
                if task_cancellation.is_cancelled() {
                    return;
                }
                let resolved =
                    executable
                        .map_or_else(WslExecutable::system, Ok)
                        .and_then(|executable| {
                            discovery.discover(
                                config,
                                executable,
                                existing_host,
                                &task_cancellation,
                            )
                        });
                if task_cancellation.is_cancelled() {
                    return;
                }
                let reconciliation = resolved.as_ref().ok().map(|context| {
                    (
                        context.snapshot.clone(),
                        context.host.socket_directory().map(str::to_owned),
                    )
                });
                let mut delayed_recoveries = Vec::new();
                let published = publish_refresh(&task_inner, generation, || {
                    if task_cancellation.is_cancelled() {
                        return;
                    }
                    match resolved {
                        Ok(context) => {
                            delayed_recoveries =
                                publish_discovered_host(&task_inner, context, generation);
                        }
                        Err(error) => {
                            set_wsl_host_unavailable(&task_inner, error.kind(), error.to_string());
                        }
                    }
                    task_inner
                        .refresh_finished
                        .store(generation, Ordering::Release);
                });
                if published && let Some((snapshot, socket_directory)) = reconciliation {
                    reconcile_presentation_session_names(
                        &task_inner,
                        generation,
                        &snapshot,
                        socket_directory.as_deref(),
                    );
                }
                task_cancellation.cancel();
                if published {
                    Self::restore_delayed_herdr_presentations(&task_inner, delayed_recoveries);
                    start_initial_kwt_refresh(&task_inner);
                }
            }),
        );
        if let Err(error) = spawn_result {
            fail_refresh_start(
                &inner,
                generation,
                &cancellation,
                "start WSL discovery task",
                &error,
            );
        }
    }

    fn restore_delayed_herdr_presentations(
        inner: &Arc<Inner>,
        recoveries: Vec<SuppressedHerdrPresentation>,
    ) {
        if recoveries.is_empty() {
            return;
        }
        let workspace = Self {
            inner: Arc::clone(inner),
        };
        let _operation = inner
            .session_operations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for suppressed in recoveries {
            workspace.restore_suppressed_herdr_presentation(Some(suppressed));
        }
    }

    fn restore_inventory_state(&self) {
        let state = self
            .inner
            .inventory_state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        self.set_state(state);
    }

    fn retry_with_xterm(
        &self,
        request: AttachRequest,
        generation: u64,
        emitted: &mut Vec<WorkspaceEvent>,
    ) {
        {
            let mut attachment = self
                .inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !attachment.promote_if_current(generation, AttachTerm::Xterm) {
                return;
            }
        }
        let inner = Arc::clone(&self.inner);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-terminfo-retry".to_owned())
            .spawn(move || run_attach(&inner, &request, AttachTerm::Xterm, generation))
        {
            let mut attachment = self
                .inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some((_, fallback)) =
                failed_attachment_context(&self.inner, &attachment, generation)
            {
                attachment.clear_if_current(generation);
                drop(attachment);
                self.restore_inventory_state();
                restore_attach_fallback(&self.inner, fallback);
                emitted.push(WorkspaceEvent::Error(format!(
                    "start TERM=xterm retry: {error}"
                )));
            }
        }
    }

    fn retry_retained_with_xterm(&self, retry: RetainedRetry, emitted: &mut Vec<WorkspaceEvent>) {
        let inner = Arc::clone(&self.inner);
        let key = retry.key.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-retained-terminal-terminfo-retry".to_owned())
            .spawn(move || run_retained_retry(&inner, &retry))
        {
            fail_retained_retry(&self.inner, &key, None);
            emitted.push(WorkspaceEvent::Error(format!(
                "start retained TERM=xterm retry: {error}"
            )));
        }
    }

    fn set_state(&self, state: WorkspaceContent) {
        set_inner_state(&self.inner, state);
    }
}

fn publish_pending_kill(inner: &Inner, pending: PendingKill) -> bool {
    let mut pending_kill = inner
        .pending_kill
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.kill_generation.load(Ordering::Acquire) != pending.generation {
        return false;
    }
    *pending_kill = Some(pending);
    drop(pending_kill);
    inner.revision.fetch_add(1, Ordering::Release);
    true
}

fn invalidate_pending_kill(inner: &Inner) -> (u64, bool) {
    let mut pending_kill = inner
        .pending_kill
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = inner.kill_generation.fetch_add(1, Ordering::AcqRel) + 1;
    (generation, pending_kill.take().is_some())
}

fn invalidate_pending_herdr_lifecycle(inner: &Inner) -> (u64, bool) {
    let mut lifecycle = inner
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = inner
        .herdr_lifecycle_generation
        .fetch_add(1, Ordering::AcqRel)
        + 1;
    (generation, lifecycle.pending.take().is_some())
}

fn finish_herdr_launch(inner: &Inner, key: &HerdrOperationKey) {
    if inner
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .finish_launch(key)
    {
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn finish_pending_creation(inner: &Inner, pending: &PendingCreation) {
    if let Some(key) = &pending.herdr_operation {
        finish_herdr_launch(inner, key);
    }
}

fn activate_retained_presentation(
    inner: &Inner,
    key: &PresentationKey,
    fallback: Option<FallbackAuthority>,
) -> Result<bool, WorkspaceError> {
    let _snapshot_write = begin_snapshot_write(inner);
    let mut attachment = inner
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(presentation) = inner
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take(key)
    else {
        return Ok(false);
    };
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let term = presentation.attachment.term;
    let Some(generation) =
        reserve_retained_attachment(&mut attachment, &presentation.attachment, fallback)
    else {
        drop(attachment);
        reinsert_retained_presentation(inner, presentation);
        return Err(WorkspaceError::new(
            "a terminal presentation is already opening",
        ));
    };
    if let Err(error) =
        presentation
            .worker
            .resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
    {
        attachment.clear_if_current(generation);
        drop(attachment);
        reinsert_retained_presentation(inner, presentation);
        return Err(WorkspaceError::from_worker(&error));
    }
    let mut workers = inner
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if workers.active().is_some() {
        attachment.clear_if_current(generation);
        drop(workers);
        drop(attachment);
        reinsert_retained_presentation(inner, presentation);
        return Err(WorkspaceError::new(
            "a terminal presentation is already open",
        ));
    }
    let selection = attachment
        .active()
        .map(|active| active.request.selection())
        .expect("retained attachment was just reserved");
    let RetainedPresentation {
        key: _,
        selection: _,
        attachment: _,
        worker,
        presentation_id,
    } = presentation;
    worker.set_clipboard_writes_enabled(false);
    let surface = worker.surface_handle();
    let worker_generation = workers.publish(worker);
    drop(workers);

    clear_pending_paste(inner);
    set_terminal_notice(inner, term);
    set_inner_state(
        inner,
        WorkspaceContent::Terminal {
            host_id: selection.host_id().to_owned(),
            endpoint: selection.endpoint().to_owned(),
            session: selection.session().to_owned(),
            kind: selection.kind(),
            presentation_id,
            surface,
        },
    );
    drop(attachment);
    let workers = inner
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if workers.generation() == worker_generation
        && let Some(worker) = workers.active()
    {
        worker.set_clipboard_writes_enabled(true);
    }
    Ok(true)
}

fn reserve_retained_attachment(
    state: &mut AttachmentState<AttachRequest>,
    retained: &ActiveAttachment<AttachRequest>,
    fallback: Option<FallbackAuthority>,
) -> Option<u64> {
    state.reserve_with_fallback(
        retained.request.clone(),
        retained.term,
        fallback.or_else(|| retained.fallback.clone()),
    )
}

fn reinsert_retained_presentation(
    inner: &Inner,
    presentation: RetainedPresentation<TerminalWorker>,
) {
    inner
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .insert(presentation);
}

const fn event_source_may_have_more(processed: usize, budget: usize, exited: bool) -> bool {
    budget > 0 && !exited && processed == budget
}

const fn retained_event_budget(processed: usize, exited: bool) -> usize {
    if exited {
        0
    } else {
        MAX_EVENTS_PER_DRAIN.saturating_sub(processed)
    }
}

fn capture_attach_request(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<AttachRequest, WorkspaceError> {
    if matches!(selection.kind(), SessionKind::Herdr | SessionKind::Zellij) {
        require_host_session_actions(inner, selection)?;
    }
    let selected_host = inner
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if selected_host.as_deref() != Some(selection.host_id()) {
        return Err(WorkspaceError::new("host is not selected"));
    }
    let host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, inventory_generation| {
        if context.snapshot.endpoint().distro() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the session selection",
            ));
        }
        let (target, name) = match selection.kind() {
            SessionKind::Tmux => {
                let session = context
                    .snapshot
                    .sessions()
                    .iter()
                    .find(|session| session.name() == selection.session())
                    .ok_or_else(|| {
                        WorkspaceError::new("session is not in the current inventory")
                    })?;
                (
                    AttachTarget::Tmux(session.identity().clone()),
                    session.name().to_owned(),
                )
            }
            SessionKind::Herdr => {
                let HerdrInventory::Available {
                    executable,
                    sessions,
                } = context.snapshot.herdr()
                else {
                    return Err(WorkspaceError::new("Herdr is not available on this host"));
                };
                let session = sessions
                    .iter()
                    .find(|session| session.name() == selection.session())
                    .ok_or_else(|| {
                        WorkspaceError::new("Herdr session is not in the current inventory")
                    })?;
                if session.state() != HerdrSessionState::Running {
                    return Err(WorkspaceError::new(
                        "Herdr session is stopped; restart it before opening",
                    ));
                }
                (
                    AttachTarget::Herdr {
                        executable: executable.clone(),
                        is_default: session.is_default(),
                        session_directory: session.session_directory().to_owned(),
                        socket_path: session.socket_path().to_owned(),
                    },
                    session.name().to_owned(),
                )
            }
            SessionKind::Zellij => {
                let ZellijInventory::Available {
                    executable,
                    sessions,
                } = context.snapshot.zellij()
                else {
                    return Err(WorkspaceError::new("Zellij is not available on this host"));
                };
                let session = sessions
                    .iter()
                    .find(|session| session.name() == selection.session())
                    .ok_or_else(|| {
                        WorkspaceError::new("Zellij session is not in the current inventory")
                    })?;
                (
                    AttachTarget::Zellij {
                        executable: executable.clone(),
                        name: session.name().to_owned(),
                    },
                    session.name().to_owned(),
                )
            }
        };
        Ok(AttachRequest {
            host_id: selection.host_id().to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            target,
            name,
            inventory_generation,
        })
    })
}

fn capture_kill_request(
    inner: &Inner,
    selection: &SessionSelection,
    generation: u64,
) -> Result<KillCaptureRequest, WorkspaceError> {
    if !matches!(selection.kind(), SessionKind::Tmux | SessionKind::Zellij) {
        return Err(WorkspaceError::new(
            "Kill Session is available only for tmux and Zellij sessions",
        ));
    }
    if inner
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_deref()
        != Some(selection.host_id())
    {
        return Err(WorkspaceError::new("host is not selected"));
    }
    if let Some(request) = inner
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .active()
        .map(|active| active.request.clone())
        .filter(|request| {
            request.host_id == selection.host_id()
                && request.endpoint.distro() == selection.endpoint()
                && request.name == selection.session()
                && request.target.kind() == SessionKind::Tmux
        })
    {
        return Ok(KillCaptureRequest::Tmux {
            selection: selection.clone(),
            host: request.host,
            endpoint: request.endpoint,
            runtime: request.runtime,
        });
    }
    let host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the session selection",
            ));
        }
        match selection.kind() {
            SessionKind::Tmux => {
                if !context
                    .snapshot
                    .sessions()
                    .iter()
                    .any(|session| session.name() == selection.session())
                {
                    return Err(WorkspaceError::new(
                        "session is not in the current inventory",
                    ));
                }
                Ok(KillCaptureRequest::Tmux {
                    selection: selection.clone(),
                    host: context.host.clone(),
                    endpoint: context.snapshot.endpoint().clone(),
                    runtime: context.snapshot.runtime().clone(),
                })
            }
            SessionKind::Zellij => {
                let ZellijInventory::Available {
                    executable,
                    sessions,
                } = context.snapshot.zellij()
                else {
                    return Err(WorkspaceError::new("Zellij is not available on this host"));
                };
                if !sessions
                    .iter()
                    .any(|session| session.name() == selection.session())
                {
                    return Err(WorkspaceError::new(
                        "Zellij session is not in the current inventory",
                    ));
                }
                Ok(KillCaptureRequest::Zellij(PendingKill {
                    generation,
                    selection: selection.clone(),
                    host: context.host.clone(),
                    target: KillTarget::Zellij {
                        endpoint: context.snapshot.endpoint().clone(),
                        runtime: context.snapshot.runtime().clone(),
                        executable: executable.clone(),
                        name: selection.session().to_owned(),
                    },
                }))
            }
            SessionKind::Herdr => unreachable!("Herdr was rejected above"),
        }
    })
}

fn capture_herdr_lifecycle(
    inner: &Inner,
    selection: &SessionSelection,
    action: HerdrLifecycleAction,
    generation: u64,
) -> Result<PendingHerdrLifecycle, WorkspaceError> {
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "Herdr lifecycle actions require a Herdr session",
        ));
    }
    require_host_session_actions(inner, selection)?;
    let host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the Herdr session selection",
            ));
        }
        let HerdrInventory::Available {
            executable,
            sessions,
        } = context.snapshot.herdr()
        else {
            return Err(WorkspaceError::new("Herdr is not available on this host"));
        };
        let record = sessions
            .iter()
            .find(|session| session.name() == selection.session())
            .cloned()
            .ok_or_else(|| WorkspaceError::new("Herdr session is not in current inventory"))?;
        if record.state() != action.expected_state() {
            let expected = match action.expected_state() {
                HerdrSessionState::Running => "running",
                HerdrSessionState::Stopped => "stopped",
            };
            return Err(WorkspaceError::new(format!(
                "Herdr session is no longer {expected}"
            )));
        }
        if action == HerdrLifecycleAction::Delete && record.is_default() {
            return Err(WorkspaceError::new(
                "Herdr's default session cannot be deleted",
            ));
        }
        Ok(PendingHerdrLifecycle {
            generation,
            selection: selection.clone(),
            action,
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            executable: executable.clone(),
            record,
        })
    })
}

fn capture_create_request(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    name: SessionName,
) -> Result<CreateRequest, WorkspaceError> {
    let selected_host = inner
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if selected_host.as_deref() != Some(host_id) {
        return Err(WorkspaceError::new("host is not selected"));
    }
    let hosts = inner
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let selected = hosts
        .iter()
        .find(|host| host.id == host_id)
        .ok_or_else(|| WorkspaceError::new("host is not available"))?;
    if selected.endpoint != endpoint {
        return Err(WorkspaceError::new(
            "the WSL endpoint changed; choose the host again before creating a session",
        ));
    }
    if matches!(
        selected.connection,
        HostConnectionState::Disconnected | HostConnectionState::Unavailable
    ) {
        return Err(WorkspaceError::new(
            "connect the WSL host before creating a tmux session",
        ));
    }
    if selected
        .sessions
        .iter()
        .any(|session| session.name == name.as_str())
    {
        return Err(WorkspaceError::new(
            "a tmux session with this name already exists",
        ));
    }
    drop(hosts);
    let host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "the WSL endpoint changed; choose the host again before creating a session",
            ));
        }
        Ok(CreateRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            name,
        })
    })
}

fn capture_herdr_create_request(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    name: HerdrSessionName,
) -> Result<HerdrCreateRequest, WorkspaceError> {
    if inner
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_deref()
        != Some(host_id)
    {
        return Err(WorkspaceError::new("host is not selected"));
    }
    require_host_session_actions(
        inner,
        &SessionSelection::herdr(host_id, endpoint, name.as_str()),
    )?;
    let host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "the WSL endpoint changed; choose the host again before creating a session",
            ));
        }
        let HerdrInventory::Available {
            executable,
            sessions,
        } = context.snapshot.herdr()
        else {
            return Err(WorkspaceError::new("Herdr is not available on this host"));
        };
        if sessions
            .iter()
            .any(|session| session.name() == name.as_str())
        {
            return Err(WorkspaceError::new(
                "a Herdr session with this name already exists; restart it instead",
            ));
        }
        Ok(HerdrCreateRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            executable: executable.clone(),
            term: context.snapshot.creation_term(),
            name: HerdrLaunchTarget::created(name),
            precondition: HerdrLaunchPrecondition::Absent,
        })
    })
}

fn capture_zellij_create_request(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    name: ZellijSessionName,
) -> Result<ZellijCreateRequest, WorkspaceError> {
    if inner
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_deref()
        != Some(host_id)
    {
        return Err(WorkspaceError::new("host is not selected"));
    }

    require_host_session_actions(
        inner,
        &SessionSelection::zellij(host_id, endpoint, name.as_str()),
    )?;
    let host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "the WSL endpoint changed; choose the host again before creating a session",
            ));
        }
        let ZellijInventory::Available {
            executable,
            sessions,
        } = context.snapshot.zellij()
        else {
            return Err(WorkspaceError::new("Zellij is not available on this host"));
        };
        if sessions
            .iter()
            .any(|session| session.name() == name.as_str())
        {
            return Err(WorkspaceError::new(
                "a Zellij session with this name already exists",
            ));
        }
        Ok(ZellijCreateRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            executable: executable.clone(),
            term: context.snapshot.creation_term(),
            name,
        })
    })
}

fn capture_herdr_restart_request(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<HerdrCreateRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "the selected session is not a Herdr session",
        ));
    }
    require_host_session_actions(inner, selection)?;
    let host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "the WSL endpoint changed; refresh before restarting the session",
            ));
        }
        let HerdrInventory::Available {
            executable,
            sessions,
        } = context.snapshot.herdr()
        else {
            return Err(WorkspaceError::new("Herdr is not available on this host"));
        };
        let record = sessions
            .iter()
            .find(|session| session.name() == selection.session())
            .cloned()
            .ok_or_else(|| WorkspaceError::new("Herdr session is no longer in inventory"))?;
        if record.state() != HerdrSessionState::Stopped {
            return Err(WorkspaceError::new("Herdr session is already running"));
        }
        let name = HerdrLaunchTarget::discovered(&record);
        Ok(HerdrCreateRequest {
            host_id: selection.host_id().to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            executable: executable.clone(),
            term: context.snapshot.creation_term(),
            name,
            precondition: HerdrLaunchPrecondition::Stopped(record),
        })
    })
}

fn require_host_session_actions(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<(), WorkspaceError> {
    let hosts = inner
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let host = hosts
        .iter()
        .find(|host| host.id == selection.host_id() && host.endpoint == selection.endpoint())
        .ok_or_else(|| WorkspaceError::new("the selected host is not available"))?;
    if matches!(
        host.connection,
        HostConnectionState::Disconnected | HostConnectionState::Unavailable
    ) {
        return Err(WorkspaceError::new(
            "connect the WSL host before changing a session",
        ));
    }
    match selection.kind() {
        SessionKind::Herdr if host.herdr_diagnostic.is_some() => {
            return Err(WorkspaceError::new(
                "refresh Herdr inventory before changing a session",
            ));
        }
        SessionKind::Zellij if host.zellij_diagnostic.is_some() => {
            return Err(WorkspaceError::new(
                "refresh Zellij inventory before changing a session",
            ));
        }
        SessionKind::Tmux | SessionKind::Herdr | SessionKind::Zellij => {}
    }
    Ok(())
}

fn herdr_operation_pending_for_selection(inner: &Inner, selection: &SessionSelection) -> bool {
    let lifecycle = inner
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    lifecycle.launches.iter().any(|operation| {
        operation.endpoint.distro() == selection.endpoint() && operation.name == selection.session()
    }) || lifecycle.in_flight.iter().any(|operation| {
        operation.key.endpoint.distro() == selection.endpoint()
            && operation.key.name == selection.session()
    })
}

fn choose_navigation_target(
    retained: Option<PresentationKey>,
    current: Result<AttachRequest, WorkspaceError>,
) -> Result<(PresentationKey, Option<AttachRequest>), WorkspaceError> {
    match current {
        Ok(request) => {
            let key = request.presentation_key();
            if retained.as_ref() == Some(&key) {
                Ok((key, None))
            } else {
                Ok((key, Some(request)))
            }
        }
        Err(error) => retained.map_or(Err(error), |key| Ok((key, None))),
    }
}

fn begin_refresh(
    inner: &Inner,
    cancellation: &CancellationToken,
    presentation: RefreshPresentation,
) -> u64 {
    let generation = reserve_refresh(inner, cancellation);
    if presentation == RefreshPresentation::Connecting {
        publish_refresh(inner, generation, || {
            if inner.host_scoped_inventory {
                let mut hosts = inner
                    .hosts
                    .write()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") {
                    host.connection = HostConnectionState::Connecting;
                    host.diagnostic = None;
                }
                inner.revision.fetch_add(1, Ordering::Release);
            } else {
                set_inventory_state(inner, WorkspaceContent::Loading);
            }
        });
    }
    generation
}

fn refresh_is_in_flight(inner: &Inner) -> bool {
    inner
        .discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|cancellation| !cancellation.is_cancelled())
}

fn reserve_refresh(inner: &Inner, cancellation: &CancellationToken) -> u64 {
    let _publication = inner
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = inner.refresh_generation.fetch_add(1, Ordering::AcqRel) + 1;
    if let Some(previous) = inner
        .discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .replace(cancellation.clone())
    {
        previous.cancel();
    }
    generation
}

fn reserve_constructive_inventory(inner: &Inner) -> u64 {
    let _publication = inner
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = inner.refresh_generation.fetch_add(1, Ordering::AcqRel) + 1;
    if let Some(previous) = inner
        .discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        previous.cancel();
    }
    generation
}

fn reserve_current_constructive_inventory(
    inner: &Inner,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Option<u64> {
    let _navigation = inner
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if cancellation.is_cancelled()
        || inner.navigation_generation.load(Ordering::Acquire) != navigation_generation
    {
        return None;
    }
    Some(reserve_constructive_inventory(inner))
}

fn settle_constructive_inventory(inner: &Inner, generation: u64) {
    let _publication = inner
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.refresh_generation.load(Ordering::Acquire) != generation {
        return;
    }
    let _snapshot_write = begin_snapshot_write(inner);
    let ready = {
        let mut host = inner
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(published) = host.as_mut() else {
            return;
        };
        published.generation = generation;
        ready_content(&published.value.snapshot)
    };
    set_inventory_state(inner, ready);
}

fn publish_refresh(inner: &Inner, generation: u64, publish: impl FnOnce()) -> bool {
    let _publication = inner
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.refresh_generation.load(Ordering::Acquire) != generation {
        return false;
    }
    let _snapshot_write = begin_snapshot_write(inner);
    publish();
    true
}

fn publish_discovered_host(
    inner: &Inner,
    context: HostContext,
    generation: u64,
) -> Vec<SuppressedHerdrPresentation> {
    let kwt_context_changed = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|published| {
            published.value.snapshot.endpoint() != context.snapshot.endpoint()
                || published.value.snapshot.runtime() != context.snapshot.runtime()
        });
    if kwt_context_changed {
        invalidate_kwt_inventory(inner);
    }
    let state = ready_content(&context.snapshot);
    let reconciliation =
        reconcile_herdr_lifecycle_fences(inner, &context.snapshot, generation, true);
    set_herdr_inventory(inner, context.snapshot.herdr());
    set_zellij_inventory(inner, context.snapshot.zellij());
    *inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) =
        Some(Published::new(context, generation));
    set_inventory_state(inner, state);
    reconciliation.recoveries
}

fn invalidate_kwt_inventory(inner: &Inner) {
    let _publication = inner
        .kwt_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    inner.kwt_refresh_generation.fetch_add(1, Ordering::AcqRel);
    if let Some(cancellation) = inner
        .kwt_discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        cancellation.cancel();
    }
    if let Some(host) = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter_mut()
        .find(|host| host.id == "wsl")
    {
        host.projects.clear();
        host.directory_workspaces.clear();
        host.kwt_state = KwtState::Uninitialized;
        host.kwt_diagnostic = None;
    }
}

fn cancel_refresh(inner: &Inner) -> bool {
    let _publication = inner
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let connecting = inner
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .any(|host| host.id == "wsl" && host.connection == HostConnectionState::Connecting);
    if !connecting {
        return false;
    }
    inner.refresh_generation.fetch_add(1, Ordering::AcqRel);
    if let Some(cancellation) = inner
        .discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        cancellation.cancel();
    }
    set_wsl_host_disconnected(inner);
    true
}

fn schedule_inventory_refresh(inner: &Arc<Inner>) -> std::io::Result<()> {
    let weak_inner = Arc::downgrade(inner);
    inner.refresh_runtime.spawn_after(
        "ghosthub-inventory-cadence",
        INVENTORY_REFRESH_INTERVAL,
        CancellationToken::new(),
        Box::new(move || {
            let Some(inner) = weak_inner.upgrade() else {
                return;
            };
            let workspace = Workspace {
                inner: Arc::clone(&inner),
            };
            if inner.inventory_polling_enabled.load(Ordering::Acquire) {
                let operation = match inner.session_operations.try_lock() {
                    Ok(operation) => Some(operation),
                    Err(TryLockError::Poisoned(error)) => Some(error.into_inner()),
                    Err(TryLockError::WouldBlock) => None,
                };
                if let Some(_operation) = operation {
                    let _refresh_started = workspace.refresh_if_ready();
                }
            }
            if let Err(error) = schedule_inventory_refresh(&inner) {
                inner
                    .inventory_cadence_started
                    .store(false, Ordering::Release);
                workspace
                    .push_operation_error(format!("inventory refresh cadence stopped: {error}"));
            }
        }),
    )
}

fn schedule_kwt_refresh(inner: &Arc<Inner>) -> std::io::Result<()> {
    let weak_inner = Arc::downgrade(inner);
    inner.refresh_runtime.spawn_after(
        "ghosthub-kwt-inventory-cadence",
        KWT_REFRESH_INTERVAL,
        CancellationToken::new(),
        Box::new(move || {
            let Some(inner) = weak_inner.upgrade() else {
                return;
            };
            if inner.inventory_polling_enabled.load(Ordering::Acquire) {
                start_kwt_refresh(&inner, false);
            }
            if let Err(error) = schedule_kwt_refresh(&inner) {
                inner.kwt_cadence_started.store(false, Ordering::Release);
                Workspace {
                    inner: Arc::clone(&inner),
                }
                .push_operation_error(format!("KWT inventory cadence stopped: {error}"));
            }
        }),
    )
}

fn start_initial_kwt_refresh(inner: &Arc<Inner>) {
    let should_start = inner
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .find(|host| host.id == "wsl")
        .is_some_and(|host| !host.kwt_initialized() && !host.kwt_refreshing());
    if should_start {
        start_kwt_refresh(inner, false);
    }
}

struct KwtRefresh {
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    cancellation: CancellationToken,
    generation: u64,
}

#[derive(Clone)]
enum KwtProjectMutationRequest {
    Add {
        path: String,
    },
    Remove {
        repository: String,
        path: String,
        registration_fingerprint: String,
    },
}

impl KwtProjectMutationRequest {
    const fn action(&self) -> KwtProjectAction {
        match self {
            Self::Add { .. } => KwtProjectAction::Add,
            Self::Remove { .. } => KwtProjectAction::Remove,
        }
    }
}

struct KwtProjectMutationTask {
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    cancellation: CancellationToken,
    generation: u64,
    request: KwtProjectMutationRequest,
}

#[derive(Clone)]
enum KwtWorktreeOperation {
    Branches,
    Create {
        branch: String,
        source: Option<String>,
        creates_branch: bool,
    },
}

struct KwtWorktreeTask {
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    cancellation: CancellationToken,
    generation: u64,
    repository: String,
    project_path: String,
    registration_fingerprint: String,
    operation: KwtWorktreeOperation,
}

#[allow(clippy::too_many_arguments)]
fn reserve_kwt_worktree_operation(
    inner: &Arc<Inner>,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    operation: KwtWorktreeOperation,
) -> Result<KwtWorktreeTask, WorkspaceError> {
    if host_id != "wsl" {
        return Err(WorkspaceError::new(
            "KWT worktrees are available only on WSL",
        ));
    }
    if inner
        .kwt_mutation_in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err(WorkspaceError::new(
            "another KWT operation is already running",
        ));
    }
    let captured = (|| {
        let (host, resolved_endpoint, runtime) = inner
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|published| published.value.snapshot.endpoint().distro() == endpoint)
            .map(|published| {
                (
                    published.value.host.clone(),
                    published.value.snapshot.endpoint().clone(),
                    published.value.snapshot.runtime().clone(),
                )
            })
            .ok_or_else(|| WorkspaceError::new("refresh WSL before changing worktrees"))?;
        let hosts = inner
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let item = hosts
            .iter()
            .find(|item| item.id == host_id && item.endpoint == endpoint)
            .ok_or_else(|| WorkspaceError::new("the selected WSL host is unavailable"))?;
        if item.connection != HostConnectionState::Ready
            || !item.kwt_available()
            || item.kwt_diagnostic.is_some()
        {
            return Err(WorkspaceError::new(
                "refresh KWT inventory before changing worktrees",
            ));
        }
        if !item.projects.iter().any(|project| {
            project.repository == repository
                && project.path == project_path
                && project.registration_fingerprint == registration_fingerprint
        }) {
            return Err(WorkspaceError::new(
                "the selected KWT project is no longer in current inventory",
            ));
        }
        drop(hosts);
        let cancellation = CancellationToken::new();
        let generation = {
            let _publication = inner
                .kwt_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let generation = inner.kwt_refresh_generation.fetch_add(1, Ordering::AcqRel) + 1;
            if let Some(previous) = inner
                .kwt_discovery_cancel
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take()
            {
                previous.cancel();
            }
            let _snapshot_write = begin_snapshot_write(inner);
            if let Some(item) = inner
                .hosts
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter_mut()
                .find(|item| item.id == host_id && item.endpoint == endpoint)
            {
                item.kwt_state = KwtState::Mutating;
                inner.revision.fetch_add(1, Ordering::Release);
            }
            generation
        };
        Ok(KwtWorktreeTask {
            host,
            endpoint: resolved_endpoint,
            runtime,
            cancellation,
            generation,
            repository: repository.to_owned(),
            project_path: project_path.to_owned(),
            registration_fingerprint: registration_fingerprint.to_owned(),
            operation,
        })
    })();
    if captured.is_err() {
        inner.kwt_mutation_in_flight.store(false, Ordering::Release);
    }
    captured
}

fn run_kwt_worktree_operation(inner: &Arc<Inner>, task: &KwtWorktreeTask) {
    match &task.operation {
        KwtWorktreeOperation::Branches => {
            match task.host.list_kwt_branches(
                &task.endpoint,
                &task.runtime,
                &task.project_path,
                &task.cancellation,
            ) {
                Ok(branches) => push_operation_event(
                    inner,
                    WorkspaceEvent::KwtBranchesLoaded {
                        project_path: task.project_path.clone(),
                        branches: branches
                            .into_iter()
                            .map(|branch| {
                                KwtBranchItem::new(
                                    branch.name(),
                                    branch.source(),
                                    branch.is_remote(),
                                )
                            })
                            .collect(),
                    },
                ),
                Err(error) => push_operation_event(
                    inner,
                    WorkspaceEvent::KwtWorktreeOperationFailed {
                        project_path: task.project_path.clone(),
                        message: error.to_string(),
                    },
                ),
            }
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
        }
        KwtWorktreeOperation::Create {
            branch,
            source,
            creates_branch,
        } => run_kwt_worktree_create(inner, task, branch, source.as_deref(), *creates_branch),
    }
    finish_kwt_project_mutation(inner, Some((&task.endpoint, &task.runtime)));
}

fn run_kwt_worktree_create(
    inner: &Arc<Inner>,
    task: &KwtWorktreeTask,
    branch: &str,
    source: Option<&str>,
    creates_branch: bool,
) {
    let result = task
        .host
        .create_kwt_worktree(
            &task.endpoint,
            &task.runtime,
            &host::KwtWorktreeCreate::new(
                &task.project_path,
                branch,
                source.map(str::to_owned),
                creates_branch,
            ),
            &task.cancellation,
        )
        .map_err(|error| WorkspaceError::new(error.to_string()))
        .and_then(|()| {
            task.host
                .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
                .map_err(|error| WorkspaceError::new(error.to_string()))?
                .ok_or_else(|| {
                    WorkspaceError::new(
                        "the pinned KWT helper became unavailable after creating the worktree",
                    )
                })
        });
    match result {
        Ok(inventory) => {
            let target = inventory.projects().iter().find_map(|project| {
                (project.project().repository() == task.repository
                    && project.project().path() == task.project_path
                    && project.project().registration_fingerprint()
                        == task.registration_fingerprint)
                    .then(|| {
                        project
                            .worktrees()
                            .iter()
                            .find(|worktree| worktree.branch() == branch)
                            .map(|worktree| KwtWorktreeTarget {
                                host_id: "wsl".to_owned(),
                                endpoint: task.endpoint.distro().to_owned(),
                                repository: task.repository.clone(),
                                project_path: task.project_path.clone(),
                                registration_fingerprint: task.registration_fingerprint.clone(),
                                worktree_path: worktree.path().to_owned(),
                                generation: worktree.generation().map(str::to_owned),
                                session_name: worktree.session_name().to_owned(),
                            })
                    })
                    .flatten()
            });
            publish_kwt_inventory(
                inner,
                task.generation,
                &task.endpoint,
                &task.runtime,
                &inventory,
            );
            if let Some(target) = target {
                push_operation_event(inner, WorkspaceEvent::KwtWorktreeCreated { target });
            } else {
                push_operation_event(
                    inner,
                    WorkspaceEvent::KwtWorktreeOperationFailed {
                        project_path: task.project_path.clone(),
                        message: "KWT created the worktree, but refreshed inventory did not contain its exact identity".to_owned(),
                    },
                );
            }
        }
        Err(error) => {
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    project_path: task.project_path.clone(),
                    message: error.to_string(),
                },
            );
        }
    }
}

fn reserve_kwt_refresh(inner: &Arc<Inner>, supersede: bool) -> Option<KwtRefresh> {
    if inner.kwt_mutation_in_flight.load(Ordering::Acquire) {
        return None;
    }
    if inner
        .wsl_config
        .as_ref()
        .is_none_or(|config| config.kwt_bundle().is_none())
    {
        return None;
    }
    let (host, endpoint, runtime) = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .map(|published| {
            (
                published.value.host.clone(),
                published.value.snapshot.endpoint().clone(),
                published.value.snapshot.runtime().clone(),
            )
        })?;
    if !supersede {
        let eligible = inner
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .find(|item| item.id == "wsl" && item.endpoint == endpoint.distro())
            .is_some_and(|item| {
                item.connection == HostConnectionState::Ready && !item.kwt_refreshing()
            });
        if !eligible {
            return None;
        }
    }
    let cancellation = CancellationToken::new();
    let generation = {
        let _publication = inner
            .kwt_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if inner.kwt_mutation_in_flight.load(Ordering::Acquire) {
            return None;
        }
        let generation = inner.kwt_refresh_generation.fetch_add(1, Ordering::AcqRel) + 1;
        if let Some(previous) = inner
            .kwt_discovery_cancel
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replace(cancellation.clone())
        {
            previous.cancel();
        }
        let _snapshot_write = begin_snapshot_write(inner);
        if let Some(item) = inner
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter_mut()
            .find(|item| item.id == "wsl" && item.endpoint == endpoint.distro())
        {
            item.kwt_state = KwtState::Refreshing {
                available: item.kwt_available(),
            };
            inner.revision.fetch_add(1, Ordering::Release);
        }
        generation
    };
    Some(KwtRefresh {
        host,
        endpoint,
        runtime,
        cancellation,
        generation,
    })
}

fn reserve_kwt_project_mutation(
    inner: &Arc<Inner>,
    host_id: &str,
    endpoint: &str,
    request: KwtProjectMutationRequest,
) -> Result<KwtProjectMutationTask, WorkspaceError> {
    if host_id != "wsl" {
        return Err(WorkspaceError::new(
            "KWT projects are available only on WSL",
        ));
    }
    if inner
        .kwt_mutation_in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err(WorkspaceError::new(
            "another KWT project operation is already running",
        ));
    }
    match capture_kwt_project_mutation(inner, endpoint, request) {
        Ok(task) => Ok(task),
        Err(error) => {
            inner.kwt_mutation_in_flight.store(false, Ordering::Release);
            Err(error)
        }
    }
}

fn capture_kwt_project_mutation(
    inner: &Arc<Inner>,
    endpoint: &str,
    request: KwtProjectMutationRequest,
) -> Result<KwtProjectMutationTask, WorkspaceError> {
    let (host, resolved_endpoint, runtime) = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .filter(|published| published.value.snapshot.endpoint().distro() == endpoint)
        .map(|published| {
            (
                published.value.host.clone(),
                published.value.snapshot.endpoint().clone(),
                published.value.snapshot.runtime().clone(),
            )
        })
        .ok_or_else(|| WorkspaceError::new("refresh WSL before changing KWT projects"))?;
    {
        let hosts = inner
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let item = hosts
            .iter()
            .find(|item| item.id == "wsl" && item.endpoint == endpoint)
            .ok_or_else(|| WorkspaceError::new("the selected WSL host is no longer available"))?;
        match &request {
            KwtProjectMutationRequest::Add { .. } => {
                if !item.can_add_kwt_project() {
                    return Err(WorkspaceError::new(
                        "the pinned KWT helper is unavailable on this host",
                    ));
                }
            }
            KwtProjectMutationRequest::Remove {
                repository,
                path,
                registration_fingerprint,
            } => {
                if !item.can_remove_kwt_project() {
                    return Err(WorkspaceError::new(
                        "refresh KWT inventory before removing a project",
                    ));
                }
                if !item.projects.iter().any(|project| {
                    project.repository == *repository
                        && project.path == *path
                        && project.registration_fingerprint == *registration_fingerprint
                }) {
                    return Err(WorkspaceError::new(
                        "the selected KWT project is no longer in the current inventory",
                    ));
                }
            }
        }
    }
    let cancellation = CancellationToken::new();
    let generation = {
        let _publication = inner
            .kwt_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let generation = inner.kwt_refresh_generation.fetch_add(1, Ordering::AcqRel) + 1;
        if let Some(previous) = inner
            .kwt_discovery_cancel
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            previous.cancel();
        }
        let _snapshot_write = begin_snapshot_write(inner);
        if let Some(item) = inner
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter_mut()
            .find(|item| item.id == "wsl" && item.endpoint == endpoint)
        {
            item.kwt_state = KwtState::Mutating;
            inner.revision.fetch_add(1, Ordering::Release);
        }
        generation
    };
    Ok(KwtProjectMutationTask {
        host,
        endpoint: resolved_endpoint,
        runtime,
        cancellation,
        generation,
        request,
    })
}

fn run_kwt_project_mutation(inner: &Arc<Inner>, task: &KwtProjectMutationTask) {
    let action = task.request.action();
    let mutation = match &task.request {
        KwtProjectMutationRequest::Add { path } => {
            task.host
                .register_kwt_project(&task.endpoint, &task.runtime, path, &task.cancellation)
        }
        KwtProjectMutationRequest::Remove {
            repository,
            path,
            registration_fingerprint,
        } => task.host.remove_kwt_project(
            &task.endpoint,
            &task.runtime,
            path,
            repository,
            registration_fingerprint,
            &task.cancellation,
        ),
    };
    match mutation {
        Ok(project) => {
            publish_kwt_project_mutation(
                inner,
                task.generation,
                &task.endpoint,
                &task.runtime,
                action,
                &project,
            );
            let refreshed =
                task.host
                    .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation);
            match refreshed {
                Ok(Some(inventory)) => publish_kwt_inventory(
                    inner,
                    task.generation,
                    &task.endpoint,
                    &task.runtime,
                    &inventory,
                ),
                Ok(None) => publish_kwt_error(
                    inner,
                    task.generation,
                    &task.endpoint,
                    &task.runtime,
                    HostDiagnostic::new(
                        DiagnosticKind::ExecutableNotFound,
                        "The pinned KWT helper became unavailable after changing the project",
                    ),
                ),
                Err(error) => publish_kwt_error(
                    inner,
                    task.generation,
                    &task.endpoint,
                    &task.runtime,
                    HostDiagnostic::new(error.kind(), error.to_string()),
                ),
            }
            push_operation_event(inner, WorkspaceEvent::KwtProjectMutationFinished { action });
        }
        Err(error) => {
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            push_operation_event(
                inner,
                WorkspaceEvent::KwtProjectMutationFailed {
                    action,
                    message: error.to_string(),
                },
            );
        }
    }
    finish_kwt_project_mutation(inner, Some((&task.endpoint, &task.runtime)));
}

fn publish_kwt_project_mutation(
    inner: &Inner,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    action: KwtProjectAction,
    project: &host::KwtProject,
) {
    publish_kwt(inner, generation, endpoint, runtime, |host| {
        match action {
            KwtProjectAction::Add => {
                let worktrees = host
                    .projects
                    .iter()
                    .find(|item| {
                        item.repository == project.repository() && item.path == project.path()
                    })
                    .map(|item| item.worktrees.clone())
                    .unwrap_or_default();
                host.projects.retain(|item| {
                    item.repository != project.repository() && item.path != project.path()
                });
                host.projects.push(ProjectItem::new(
                    project.repository(),
                    project.name(),
                    project.path(),
                    project.registration_fingerprint(),
                    worktrees,
                ));
                host.projects.sort_by(|left, right| {
                    left.name
                        .cmp(&right.name)
                        .then_with(|| left.path.cmp(&right.path))
                });
            }
            KwtProjectAction::Remove => {
                host.projects.retain(|item| {
                    item.repository != project.repository() || item.path != project.path()
                });
            }
        }
        host.kwt_state = KwtState::Ready;
        host.kwt_diagnostic = None;
    });
}

fn publish_kwt_mutation_failure(
    inner: &Inner,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
) {
    publish_kwt(inner, generation, endpoint, runtime, |host| {
        host.kwt_state = KwtState::Ready;
    });
}

fn finish_kwt_project_mutation(
    inner: &Arc<Inner>,
    target: Option<(&host::WslEndpoint, &host::WslRuntimeIdentity)>,
) {
    {
        let _snapshot_write = begin_snapshot_write(inner);
        if let Some((endpoint, runtime)) = target {
            let current_matches = inner
                .host
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_ref()
                .is_some_and(|published| {
                    published.value.snapshot.endpoint() == endpoint
                        && published.value.snapshot.runtime() == runtime
                });
            if current_matches
                && let Some(host) = inner
                    .hosts
                    .write()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .iter_mut()
                    .find(|host| host.id == "wsl" && host.endpoint == endpoint.distro())
            {
                host.kwt_state = KwtState::Ready;
            }
        } else {
            for host in inner
                .hosts
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter_mut()
            {
                if host.kwt_mutating() {
                    host.kwt_state = KwtState::Ready;
                }
            }
        }
        inner.kwt_mutation_in_flight.store(false, Ordering::Release);
        inner.revision.fetch_add(1, Ordering::Release);
    }
    start_initial_kwt_refresh(inner);
}

fn push_operation_event(inner: &Inner, event: WorkspaceEvent) {
    let mut events = inner
        .operation_events
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if events.len() >= MAX_EVENTS_PER_DRAIN {
        events.pop_front();
    }
    events.push_back(event);
}

fn start_kwt_refresh(inner: &Arc<Inner>, supersede: bool) -> bool {
    let Some(refresh) = reserve_kwt_refresh(inner, supersede) else {
        return false;
    };
    let KwtRefresh {
        host,
        endpoint,
        runtime,
        cancellation,
        generation,
    } = refresh;

    let deadline_inner = Arc::clone(inner);
    let deadline_cancellation = cancellation.clone();
    let deadline_endpoint = endpoint.clone();
    let deadline_runtime = runtime.clone();
    if let Err(error) = inner.refresh_runtime.spawn_after(
        "ghosthub-kwt-refresh-deadline",
        KWT_REFRESH_BUDGET,
        deadline_cancellation.clone(),
        Box::new(move || {
            deadline_cancellation.cancel();
            publish_kwt_error(
                &deadline_inner,
                generation,
                &deadline_endpoint,
                &deadline_runtime,
                HostDiagnostic::new(DiagnosticKind::Timeout, "KWT inventory timed out"),
            );
        }),
    ) {
        cancellation.cancel();
        publish_kwt_error(
            inner,
            generation,
            &endpoint,
            &runtime,
            HostDiagnostic::new(
                DiagnosticKind::Transport,
                format!("schedule KWT inventory deadline: {error}"),
            ),
        );
        return false;
    }

    let task_inner = Arc::clone(inner);
    let task_cancellation = cancellation.clone();
    let task_endpoint = endpoint.clone();
    let task_runtime = runtime.clone();
    if let Err(error) = inner.refresh_runtime.spawn(
        "ghosthub-kwt-discovery",
        Box::new(move || {
            let result = host.discover_kwt(&task_endpoint, &task_runtime, &task_cancellation);
            if task_cancellation.is_cancelled() {
                return;
            }
            match result {
                Ok(Some(inventory)) => publish_kwt_inventory(
                    &task_inner,
                    generation,
                    &task_endpoint,
                    &task_runtime,
                    &inventory,
                ),
                Ok(None) => {
                    publish_kwt_unavailable(&task_inner, generation, &task_endpoint, &task_runtime);
                }
                Err(error) => publish_kwt_error(
                    &task_inner,
                    generation,
                    &task_endpoint,
                    &task_runtime,
                    HostDiagnostic::new(error.kind(), error.to_string()),
                ),
            }
            task_cancellation.cancel();
        }),
    ) {
        cancellation.cancel();
        publish_kwt_error(
            inner,
            generation,
            &endpoint,
            &runtime,
            HostDiagnostic::new(
                DiagnosticKind::Transport,
                format!("start KWT inventory task: {error}"),
            ),
        );
        return false;
    }
    true
}

fn publish_kwt_inventory(
    inner: &Inner,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    inventory: &KwtInventory,
) {
    publish_kwt(inner, generation, endpoint, runtime, |host| {
        let session_names = host
            .sessions
            .iter()
            .map(|session| session.name.as_str())
            .collect::<std::collections::HashSet<_>>();
        host.projects = inventory
            .projects()
            .iter()
            .map(|project| {
                ProjectItem::new(
                    project.project().repository(),
                    project.project().name(),
                    project.project().path(),
                    project.project().registration_fingerprint(),
                    project
                        .worktrees()
                        .iter()
                        .map(|worktree| {
                            let available = worktree.tmux_socket_name().is_none()
                                && session_names.contains(worktree.session_name());
                            WorktreeItem::new(
                                worktree.path(),
                                worktree.branch(),
                                worktree.is_main(),
                                worktree.generation().map(str::to_owned),
                                worktree.session_name(),
                                worktree.tmux_socket_name().map(str::to_owned),
                                available,
                            )
                        })
                        .collect(),
                )
            })
            .collect();
        host.directory_workspaces = inventory
            .directory_workspaces()
            .iter()
            .map(|workspace| {
                DirectoryWorkspaceItem::new(
                    workspace.name(),
                    workspace.path(),
                    workspace.session_name(),
                    workspace.session_live() && session_names.contains(workspace.session_name()),
                )
            })
            .collect();
        host.kwt_state = KwtState::Ready;
        host.kwt_diagnostic = None;
    });
}

fn publish_kwt_error(
    inner: &Inner,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    diagnostic: HostDiagnostic,
) {
    publish_kwt(inner, generation, endpoint, runtime, |host| {
        host.kwt_state = if host.kwt_available() {
            KwtState::Ready
        } else {
            KwtState::Unavailable
        };
        host.kwt_diagnostic = Some(diagnostic);
    });
}

fn publish_kwt_unavailable(
    inner: &Inner,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
) {
    publish_kwt(inner, generation, endpoint, runtime, |host| {
        host.projects.clear();
        host.directory_workspaces.clear();
        host.kwt_state = KwtState::Unavailable;
        host.kwt_diagnostic = None;
    });
}

fn publish_kwt(
    inner: &Inner,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    publish: impl FnOnce(&mut HostItem),
) {
    let _publication = inner
        .kwt_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.kwt_refresh_generation.load(Ordering::Acquire) != generation {
        return;
    }
    let current_matches = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|published| {
            published.value.snapshot.endpoint() == endpoint
                && published.value.snapshot.runtime() == runtime
        });
    if !current_matches {
        return;
    }
    let _snapshot_write = begin_snapshot_write(inner);
    if let Some(host) = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter_mut()
        .find(|host| host.id == "wsl" && host.endpoint == endpoint.distro())
    {
        publish(host);
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

const fn refresh_budget(generation: u64) -> Duration {
    if generation == 1 {
        Duration::from_secs(45)
    } else {
        Duration::from_secs(30)
    }
}

fn expire_refresh(inner: &Inner, generation: u64, cancellation: &CancellationToken) -> bool {
    publish_refresh(inner, generation, || {
        if inner.refresh_finished.load(Ordering::Acquire) == generation {
            return;
        }
        cancellation.cancel();
        inner.refresh_finished.store(generation, Ordering::Release);
        set_wsl_host_unavailable(
            inner,
            DiagnosticKind::Timeout,
            format!(
                "WSL host refresh timed out after {} seconds",
                refresh_budget(generation).as_secs()
            ),
        );
    }) && cancellation.is_cancelled()
}

fn fail_refresh_start(
    inner: &Inner,
    generation: u64,
    cancellation: &CancellationToken,
    context: &str,
    error: &std::io::Error,
) {
    cancellation.cancel();
    publish_refresh(inner, generation, || {
        inner.refresh_finished.store(generation, Ordering::Release);
        set_wsl_host_unavailable(
            inner,
            DiagnosticKind::Transport,
            format!("{context}: {error}"),
        );
    });
}

fn run_create(
    inner: &Inner,
    request: &CreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(inventory_publication) =
        reserve_current_constructive_inventory(inner, navigation_generation, cancellation)
    else {
        return;
    };
    let created = create_fresh(inner, request, navigation_generation, cancellation);
    let (worker, snapshot, session, initial_geometry, term) = match created {
        Ok(created) => created,
        Err(error) => {
            settle_constructive_inventory(inner, inventory_publication);
            restore_inventory_after_creation_failure(
                inner,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        settle_constructive_inventory(inner, inventory_publication);
        drop(worker);
        return;
    }

    let inventory_generation =
        match merge_created_inventory(inner, request, snapshot.clone(), inventory_publication) {
            Ok(generation) => generation,
            Err(error) => {
                settle_constructive_inventory(inner, inventory_publication);
                drop(worker);
                restore_inventory_after_creation_failure(
                    inner,
                    None,
                    navigation_generation,
                    error.to_string(),
                );
                return;
            }
        };
    let attached = AttachRequest {
        host_id: request.host_id.clone(),
        host: request.host.clone(),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Tmux(session.identity().clone()),
        name: session.name().to_owned(),
        inventory_generation,
    };
    publish_created_presentation(
        inner,
        attached,
        worker,
        initial_geometry,
        term,
        navigation_generation,
    );
}

fn run_herdr_create(
    inner: &Inner,
    request: &HerdrCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(inventory_publication) =
        reserve_current_constructive_inventory(inner, navigation_generation, cancellation)
    else {
        return;
    };
    let created = create_herdr_fresh(inner, request, navigation_generation, cancellation);
    let (worker, snapshot, session, initial_geometry) = match created {
        Ok(created) => created,
        Err(error) => {
            settle_constructive_inventory(inner, inventory_publication);
            restore_inventory_after_creation_failure(
                inner,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        settle_constructive_inventory(inner, inventory_publication);
        drop(worker);
        return;
    }
    let inventory_generation = match merge_herdr_created_inventory(
        inner,
        request,
        snapshot.clone(),
        inventory_publication,
    ) {
        Ok(generation) => generation,
        Err(error) => {
            settle_constructive_inventory(inner, inventory_publication);
            drop(worker);
            restore_inventory_after_creation_failure(
                inner,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    let attached = AttachRequest {
        host_id: request.host_id.clone(),
        host: request.host.clone(),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Herdr {
            executable: request.executable.clone(),
            is_default: session.is_default(),
            session_directory: session.session_directory().to_owned(),
            socket_path: session.socket_path().to_owned(),
        },
        name: session.name().to_owned(),
        inventory_generation,
    };
    publish_created_presentation(
        inner,
        attached,
        worker,
        initial_geometry,
        request.term,
        navigation_generation,
    );
}

fn run_zellij_create(
    inner: &Inner,
    request: &ZellijCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(inventory_publication) =
        reserve_current_constructive_inventory(inner, navigation_generation, cancellation)
    else {
        return;
    };
    let created = create_zellij_fresh(inner, request, navigation_generation, cancellation);
    let (worker, snapshot, session, initial_geometry) = match created {
        Ok(created) => created,
        Err(error) => {
            settle_constructive_inventory(inner, inventory_publication);
            restore_inventory_after_creation_failure(
                inner,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        settle_constructive_inventory(inner, inventory_publication);
        drop(worker);
        return;
    }
    let inventory_generation = match merge_constructive_inventory(
        inner,
        &request.host,
        &request.endpoint,
        &request.runtime,
        snapshot.clone(),
        inventory_publication,
        "the created Zellij session",
    ) {
        Ok(generation) => generation,
        Err(error) => {
            settle_constructive_inventory(inner, inventory_publication);
            drop(worker);
            restore_inventory_after_creation_failure(
                inner,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    let attached = AttachRequest {
        host_id: request.host_id.clone(),
        host: request.host.clone(),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Zellij {
            executable: request.executable.clone(),
            name: session.name().to_owned(),
        },
        name: session.name().to_owned(),
        inventory_generation,
    };
    publish_created_presentation(
        inner,
        attached,
        worker,
        initial_geometry,
        request.term,
        navigation_generation,
    );
}

fn run_herdr_lifecycle(workspace: &Workspace, pending: &PendingHerdrLifecycle) {
    let _operation = workspace
        .inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut suppressed = None;
    match pending.host.mutate_herdr_session(
        (&pending.endpoint, &pending.runtime),
        &pending.executable,
        &pending.record,
        pending.action,
        &CancellationToken::new(),
        || {
            reserve_constructive_inventory(&workspace.inner);
            if pending.action == HerdrLifecycleAction::Stop {
                suppressed = workspace.close_herdr_presentations(pending);
            }
        },
    ) {
        Ok(record) => {
            workspace.finish_herdr_presentation(
                &pending.endpoint,
                &pending.runtime,
                &pending.record,
            );
            if let Err(error) = publish_herdr_lifecycle_response(&workspace.inner, pending, record)
            {
                reconcile_herdr_lifecycle_failure(
                    workspace,
                    pending,
                    format!(
                        "Herdr {} succeeded, but Ghosthub could not publish the result: {error}",
                        pending.action.command()
                    ),
                    None,
                );
            } else {
                finish_herdr_lifecycle_state(&workspace.inner, pending.generation);
                let _reconciled = reconcile_herdr_lifecycle_inventory(&workspace.inner, pending);
            }
        }
        Err(error) => {
            reconcile_herdr_lifecycle_failure(workspace, pending, error.to_string(), suppressed);
        }
    }
}

fn reconcile_herdr_lifecycle_failure(
    workspace: &Workspace,
    pending: &PendingHerdrLifecycle,
    operation_error: String,
    suppressed: Option<SuppressedHerdrPresentation>,
) {
    match reconcile_herdr_lifecycle_inventory(&workspace.inner, pending) {
        Ok(snapshot) => {
            finish_herdr_lifecycle_state(&workspace.inner, pending.generation);
            if herdr_session_is_still_running(&snapshot, pending) {
                workspace.restore_suppressed_herdr_presentation(suppressed);
            } else {
                workspace.finish_herdr_presentation(
                    &pending.endpoint,
                    &pending.runtime,
                    &pending.record,
                );
            }
            workspace.push_operation_error(operation_error);
        }
        Err(reconciliation_error) => {
            let message = format!(
                "{operation_error}; Ghosthub could not reconcile the Herdr session: {reconciliation_error}"
            );
            publish_herdr_lifecycle_uncertain(&workspace.inner, pending, suppressed, &message);
            workspace.push_operation_error(message);
        }
    }
}

fn finish_herdr_lifecycle_state(inner: &Inner, generation: u64) {
    let _snapshot_write = begin_snapshot_write(inner);
    inner
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .finish(generation);
    inner.revision.fetch_add(1, Ordering::Release);
}

fn create_herdr_fresh(
    inner: &Inner,
    request: &HerdrCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        session::HerdrSessionRecord,
        TerminalGeometry,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if before.endpoint() != &request.endpoint || before.runtime() != &request.runtime {
        return Err(WorkspaceError::new(
            "WSL changed; refresh before creating the Herdr session",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = before.herdr()
    else {
        return Err(WorkspaceError::new("Herdr is not available on this host"));
    };
    if executable != &request.executable {
        return Err(WorkspaceError::new(
            "the Herdr executable changed; refresh before creating the session",
        ));
    }
    let current = sessions
        .iter()
        .find(|session| session.name() == request.name.as_str());
    validate_herdr_launch_precondition(&request.precondition, current)?;
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new("Herdr creation was superseded"));
    }
    let (worker, geometry) = with_herdr_launch_fence(
        &inner.herdr_lifecycle,
        &request.operation_key(),
        || {
            WorkspaceError::new(
                "Herdr session lifecycle is changing; wait for inventory to refresh",
            )
        },
        || {
            let authority = request.host.herdr_launch_once(
                before.endpoint(),
                &request.executable,
                request.name.clone(),
                request.precondition.is_default(),
                request.term,
            );
            let geometry = *inner
                .terminal_geometry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let worker = TerminalWorker::launch_herdr_with_metadata(
                authority,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
                default_colors(&inner.appearance),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
            Ok((worker, geometry))
        },
    )?;

    let expected_name = request.name.as_str();
    let discovered = poll_session_startup("Zellij", cancellation, &HERDR_STARTUP_BACKOFF, || {
        if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            return Err(WorkspaceError::new("Herdr creation was superseded"));
        }
        let snapshot = request
            .host
            .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        if snapshot.endpoint() != &request.endpoint || snapshot.runtime() != &request.runtime {
            return Err(WorkspaceError::new(
                "WSL changed while creating the Herdr session",
            ));
        }
        let session = match snapshot.herdr() {
            HerdrInventory::Available {
                executable,
                sessions,
            } if executable == &request.executable => sessions
                .iter()
                .find(|session| {
                    herdr_launch_result_matches(&request.precondition, expected_name, session)
                })
                .cloned(),
            _ => None,
        };
        Ok(session.map(|session| (snapshot, session)))
    })?;
    if let Some((snapshot, session)) = discovered {
        return Ok((worker, snapshot, session, geometry));
    }
    drop(worker);
    Err(WorkspaceError::new(
        "Herdr started, but the new session did not appear in inventory; refresh before trying again",
    ))
}

fn create_zellij_fresh(
    inner: &Inner,
    request: &ZellijCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        session::ZellijSessionRecord,
        TerminalGeometry,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if before.endpoint() != &request.endpoint || before.runtime() != &request.runtime {
        return Err(WorkspaceError::new(
            "WSL changed; refresh before creating the Zellij session",
        ));
    }
    let ZellijInventory::Available {
        executable,
        sessions,
    } = before.zellij()
    else {
        return Err(WorkspaceError::new("Zellij is not available on this host"));
    };
    if executable != &request.executable {
        return Err(WorkspaceError::new(
            "the Zellij executable changed; refresh before creating the session",
        ));
    }
    if sessions
        .iter()
        .any(|session| session.name() == request.name.as_str())
    {
        return Err(WorkspaceError::new(
            "a Zellij session with this name already exists",
        ));
    }
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new("Zellij creation was superseded"));
    }
    let authority = request.host.zellij_launch_once(
        before.endpoint(),
        &request.executable,
        request.name.clone(),
        request.term,
    );
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::launch_zellij_with_metadata(
        authority,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
        default_colors(&inner.appearance),
    )
    .map_err(|error| WorkspaceError::new(error.to_string()))?;

    let expected_name = request.name.as_str();
    let discovered = poll_session_startup("Herdr", cancellation, &HERDR_STARTUP_BACKOFF, || {
        if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            return Err(WorkspaceError::new("Zellij creation was superseded"));
        }
        let snapshot = request
            .host
            .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        if snapshot.endpoint() != &request.endpoint || snapshot.runtime() != &request.runtime {
            return Err(WorkspaceError::new(
                "WSL changed while creating the Zellij session",
            ));
        }
        let session = match snapshot.zellij() {
            ZellijInventory::Available {
                executable,
                sessions,
            } if executable == &request.executable => sessions
                .iter()
                .find(|session| session.name() == expected_name)
                .cloned(),
            _ => None,
        };
        Ok(session.map(|session| (snapshot, session)))
    })?;
    if let Some((snapshot, session)) = discovered {
        return Ok((worker, snapshot, session, geometry));
    }
    drop(worker);
    Err(WorkspaceError::new(
        "Zellij started, but the new session did not appear in inventory; refresh before trying again",
    ))
}

fn poll_session_startup<T>(
    backend: &str,
    cancellation: &CancellationToken,
    delays: &[Duration],
    mut probe: impl FnMut() -> Result<Option<T>, WorkspaceError>,
) -> Result<Option<T>, WorkspaceError> {
    let mut delay_index = 0;
    loop {
        if cancellation.is_cancelled() {
            return Err(WorkspaceError::new(format!(
                "{backend} startup was cancelled"
            )));
        }
        if let Some(value) = probe()? {
            return Ok(Some(value));
        }
        let Some(delay) = delays.get(delay_index).copied() else {
            return Ok(None);
        };
        delay_index += 1;
        if cancellation.wait_cancelled(delay) {
            return Err(WorkspaceError::new(format!(
                "{backend} startup was cancelled"
            )));
        }
    }
}

fn validate_herdr_launch_precondition(
    precondition: &HerdrLaunchPrecondition,
    current: Option<&session::HerdrSessionRecord>,
) -> Result<(), WorkspaceError> {
    match (precondition, current) {
        (HerdrLaunchPrecondition::Absent, None) => {}
        (HerdrLaunchPrecondition::Absent, Some(_)) => {
            return Err(WorkspaceError::new(
                "a Herdr session with this name already exists; restart it instead",
            ));
        }
        (HerdrLaunchPrecondition::Stopped(expected), Some(current))
            if current.state() == HerdrSessionState::Stopped
                && current.is_default() == expected.is_default()
                && current.session_directory() == expected.session_directory()
                && current.socket_path() == expected.socket_path() => {}
        (HerdrLaunchPrecondition::Stopped(_), Some(current))
            if current.state() == HerdrSessionState::Running =>
        {
            return Err(WorkspaceError::new("Herdr session is already running"));
        }
        (HerdrLaunchPrecondition::Stopped(_), Some(_)) => {
            return Err(WorkspaceError::new(
                "Herdr session moved to a different configuration",
            ));
        }
        (HerdrLaunchPrecondition::Stopped(_), None) => {
            return Err(WorkspaceError::new("Herdr session no longer exists"));
        }
    }
    Ok(())
}

fn herdr_launch_result_matches(
    precondition: &HerdrLaunchPrecondition,
    expected_name: &str,
    current: &session::HerdrSessionRecord,
) -> bool {
    if current.name() != expected_name
        || current.is_default() != precondition.is_default()
        || current.state() != HerdrSessionState::Running
    {
        return false;
    }
    match precondition {
        HerdrLaunchPrecondition::Absent => true,
        HerdrLaunchPrecondition::Stopped(expected) => {
            current.session_directory() == expected.session_directory()
                && current.socket_path() == expected.socket_path()
        }
    }
}

fn publish_created_presentation(
    inner: &Inner,
    attached: AttachRequest,
    worker: TerminalWorker,
    initial_geometry: TerminalGeometry,
    term: AttachTerm,
    navigation_generation: u64,
) {
    let _snapshot_write = begin_snapshot_write(inner);
    let navigation = inner
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        drop(navigation);
        drop(worker);
        return;
    }
    let pending = inner
        .pending_creation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
        .filter(|pending| pending.navigation_generation == navigation_generation);
    let Some(pending) = pending else {
        drop(navigation);
        drop(worker);
        return;
    };
    let key = attached.presentation_key();
    let fallback = pending
        .previous
        .clone()
        .map(|presentation| FallbackAuthority {
            presentation,
            target: key,
            navigation_generation,
        });
    let mut attachment = inner
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(generation) =
        attachment.reserve_with_fallback(attached.clone(), term, fallback.clone())
    else {
        finish_pending_creation(inner, &pending);
        drop(attachment);
        drop(navigation);
        drop(worker);
        restore_inventory_after_creation_failure(
            inner,
            fallback.map(|fallback| fallback.presentation),
            navigation_generation,
            "another terminal presentation replaced the creation request".to_owned(),
        );
        return;
    };
    let surface = worker.surface_handle();
    if let Err(error) = publish_worker_at_latest_geometry(
        &inner.terminal_geometry,
        &inner.worker,
        worker,
        initial_geometry,
        |worker, geometry| {
            worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
        },
    ) {
        attachment.clear_if_current(generation);
        finish_pending_creation(inner, &pending);
        drop(attachment);
        drop(navigation);
        restore_inventory_after_creation_failure(
            inner,
            fallback.map(|fallback| fallback.presentation),
            navigation_generation,
            error.to_string(),
        );
        return;
    }
    set_terminal_notice(inner, term);
    set_inner_state(
        inner,
        WorkspaceContent::Terminal {
            host_id: attached.host_id,
            endpoint: attached.endpoint.distro().to_owned(),
            session: attached.name,
            kind: attached.target.kind(),
            presentation_id: next_presentation_id(inner),
            surface,
        },
    );
    finish_pending_creation(inner, &pending);
    drop(attachment);
    drop(navigation);
}

fn create_fresh(
    inner: &Inner,
    request: &CreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        session::DiscoveredSession,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if before.endpoint() != &request.endpoint {
        return Err(WorkspaceError::new(
            "the default WSL distro changed; refresh before creating the session",
        ));
    }
    if before.runtime() != &request.runtime {
        return Err(WorkspaceError::new(
            "WSL restarted; refresh before creating the session",
        ));
    }
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new("tmux creation was superseded"));
    }
    let (authority, receipt, term) = request
        .host
        .create_once(before.endpoint(), before.runtime(), request.name.clone())
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let launch_geometry = creation_launch_geometry(geometry);
    let worker = TerminalWorker::create_with_metadata(
        authority,
        launch_geometry.grid,
        launch_geometry.sequence,
        launch_geometry.pixels,
        ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
        default_colors(&inner.appearance),
    )
    .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let client_identity = request
        .host
        .wait_for_creation_identity(
            before.endpoint(),
            &receipt,
            cancellation,
            CREATE_IDENTITY_TIMEOUT,
        )
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    for attempt in 0..TMUX_CREATE_DISCOVERY_ATTEMPTS {
        if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            drop(worker);
            return Err(WorkspaceError::new("tmux creation was superseded"));
        }
        let snapshot = request
            .host
            .discover_after_create(
                before.endpoint(),
                &request.runtime,
                before.creation_term(),
                before.herdr(),
                before.zellij(),
                cancellation,
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        if let Some(session) = created_session(&snapshot, &client_identity) {
            return Ok((worker, snapshot, session, launch_geometry, term));
        }
        if attempt + 1 < TMUX_CREATE_DISCOVERY_ATTEMPTS {
            thread::sleep(TMUX_CREATE_DISCOVERY_DELAY);
        }
    }
    drop(worker);
    Err(WorkspaceError::new(
        "the one-shot tmux client started, but its exact session did not appear; refresh to inspect the host before trying again",
    ))
}

fn creation_launch_geometry(geometry: TerminalGeometry) -> TerminalGeometry {
    if geometry.grid.columns() >= CREATE_IDENTITY_MIN_COLUMNS {
        return geometry;
    }
    TerminalGeometry {
        grid: GridSize::new(CREATE_IDENTITY_MIN_COLUMNS, geometry.grid.rows())
            .expect("creation identity grid is valid"),
        ..geometry
    }
}

fn created_session(
    snapshot: &HostSnapshot,
    client_identity: &session::SessionIdentity,
) -> Option<session::DiscoveredSession> {
    snapshot
        .sessions()
        .iter()
        .find(|session| session.identity() == client_identity)
        .cloned()
}

fn restore_inventory_after_creation_failure(
    inner: &Inner,
    previous: Option<PresentationKey>,
    navigation_generation: u64,
    message: String,
) {
    let _snapshot_write = begin_snapshot_write(inner);
    let _navigation = inner
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return;
    }
    let pending = inner
        .pending_creation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
        .filter(|pending| pending.navigation_generation == navigation_generation);
    if let Some(pending) = &pending {
        pending.cancellation.cancel();
        finish_pending_creation(inner, pending);
    }
    let previous = pending.and_then(|pending| pending.previous).or(previous);
    restore_presentation_inventory(inner);
    if let Some(previous) = previous {
        match activate_retained_presentation(inner, &previous, None) {
            Ok(true) => {}
            Ok(false) => set_local_notice(
                inner,
                "the previous terminal presentation is no longer available".to_owned(),
            ),
            Err(error) => set_local_notice(
                inner,
                format!("could not restore the previous terminal presentation: {error}"),
            ),
        }
    }
    publish_local_notice(inner, message);
}

fn run_attach(inner: &Inner, request: &AttachRequest, term: AttachTerm, generation: u64) {
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !inner
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .is_current(generation)
    {
        return;
    }
    match attach_fresh(inner, request, term) {
        Ok((worker, snapshot, attached_session, initial_geometry)) => {
            let _snapshot_write = begin_snapshot_write(inner);
            let mut attachment = inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !attachment.is_current(generation) {
                drop(worker);
                return;
            }
            let surface = worker.surface_handle();
            let endpoint = snapshot.endpoint().distro().to_owned();
            publish_attach_inventory(inner, request, snapshot);
            let key = attachment
                .active()
                .expect("current attachment was checked")
                .request
                .presentation_key();
            let session = current_inventory_session_name(inner, &key).unwrap_or(attached_session);
            if let Some(active) = attachment.active_mut() {
                session.clone_into(&mut active.request.name);
            }
            if let Err(error) = publish_worker_at_latest_geometry(
                &inner.terminal_geometry,
                &inner.worker,
                worker,
                initial_geometry,
                |worker, geometry| {
                    worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
                },
            ) {
                let fallback = attachment
                    .fallback_if_current(generation)
                    .filter(|fallback| fallback_owns_request(inner, fallback, request));
                attachment.clear_if_current(generation);
                drop(attachment);
                publish_attachment_failure(inner, request.inventory_generation, error);
                restore_attach_fallback(inner, fallback);
                return;
            }
            set_terminal_notice(inner, term);
            let presentation_id = next_presentation_id(inner);
            set_inner_state(
                inner,
                WorkspaceContent::Terminal {
                    host_id: request.host_id.clone(),
                    endpoint,
                    session,
                    kind: request.target.kind(),
                    presentation_id,
                    surface,
                },
            );
        }
        Err(error) => {
            let _snapshot_write = begin_snapshot_write(inner);
            let mut attachment = inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some((current_request, fallback)) =
                failed_attachment_context(inner, &attachment, generation)
            else {
                return;
            };
            attachment.clear_if_current(generation);
            drop(attachment);
            match error {
                AttachFreshError::Host(error) => {
                    publish_attachment_failure(inner, current_request.inventory_generation, error);
                }
                AttachFreshError::SessionChanged { error, snapshot } => {
                    publish_stale_attachment_failure(inner, &current_request, *snapshot, &error);
                }
            }
            restore_attach_fallback(inner, fallback);
        }
    }
}

fn current_inventory_session_name(inner: &Inner, key: &PresentationKey) -> Option<String> {
    inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .and_then(|published| {
            refreshed_session_name(
                key,
                &published.value.snapshot,
                published.value.host.socket_directory(),
            )
        })
}

fn run_retained_retry(inner: &Inner, retry: &RetainedRetry) {
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    match attach_fresh_retained(inner, retry) {
        Ok((worker, snapshot, resolved_request, initial_geometry)) => {
            let _snapshot_write = begin_snapshot_write(inner);
            let latest_geometry = *inner
                .terminal_geometry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if latest_geometry != initial_geometry
                && let Err(error) = worker.resize_with_metadata(
                    latest_geometry.grid,
                    latest_geometry.sequence,
                    latest_geometry.pixels,
                )
            {
                fail_retained_retry(inner, &retry.key, Some(error.to_string()));
                return;
            }
            worker.set_clipboard_writes_enabled(false);
            let published = inner
                .retained_presentations
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .finish_restart(&retry.key, worker, &retry.request.name, &resolved_request);
            if published {
                publish_attach_inventory(inner, &resolved_request, snapshot);
                inner.revision.fetch_add(1, Ordering::Release);
            }
        }
        Err(AttachFreshError::Host(error)) => {
            let _snapshot_write = begin_snapshot_write(inner);
            fail_retained_retry(inner, &retry.key, Some(error.to_string()));
        }
        Err(AttachFreshError::SessionChanged { error, snapshot }) => {
            let _snapshot_write = begin_snapshot_write(inner);
            remove_failed_retained_retry(inner, &retry.key);
            publish_retained_stale_failure(inner, &retry.request, *snapshot, &error);
        }
    }
}

fn fail_retained_retry(inner: &Inner, key: &PresentationKey, diagnostic: Option<String>) {
    remove_failed_retained_retry(inner, key);
    if let Some(diagnostic) = diagnostic {
        publish_local_notice(inner, diagnostic);
    }
}

fn remove_failed_retained_retry(inner: &Inner, key: &PresentationKey) {
    let removed = inner
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .fail_restart(key);
    if removed.is_some() {
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn fallback_owns_request(
    inner: &Inner,
    fallback: &FallbackAuthority,
    request: &AttachRequest,
) -> bool {
    inner.navigation_generation.load(Ordering::Acquire) == fallback.navigation_generation
        && fallback.target == request.presentation_key()
}

fn failed_attachment_context(
    inner: &Inner,
    attachment: &AttachmentState<AttachRequest>,
    generation: u64,
) -> Option<(AttachRequest, Option<FallbackAuthority>)> {
    if !attachment.is_current(generation) {
        return None;
    }
    let request = attachment.active()?.request.clone();
    let fallback = attachment
        .fallback_if_current(generation)
        .filter(|fallback| fallback_owns_request(inner, fallback, &request));
    Some((request, fallback))
}

fn restore_attach_fallback(inner: &Inner, fallback: Option<FallbackAuthority>) {
    let _navigation = inner
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    restore_attach_fallback_locked(inner, fallback);
}

fn restore_attach_fallback_locked(inner: &Inner, fallback: Option<FallbackAuthority>) {
    let Some(fallback) = fallback else {
        return;
    };
    if inner.navigation_generation.load(Ordering::Acquire) != fallback.navigation_generation {
        return;
    }
    let preserved_notice = inner
        .terminal_notice
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    match activate_retained_presentation(inner, &fallback.presentation, None) {
        Ok(true) => {
            if let Some(notice) = preserved_notice {
                set_local_notice(inner, notice);
            }
        }
        Ok(false) => set_local_notice(
            inner,
            "the previous terminal presentation is no longer available".to_owned(),
        ),
        Err(error) => set_local_notice(
            inner,
            format!("could not restore the previous terminal presentation: {error}"),
        ),
    }
}

fn merge_created_inventory(
    inner: &Inner,
    request: &CreateRequest,
    snapshot: HostSnapshot,
    publication_generation: u64,
) -> Result<u64, WorkspaceError> {
    merge_constructive_inventory(
        inner,
        &request.host,
        &request.endpoint,
        &request.runtime,
        snapshot,
        publication_generation,
        "the created tmux session",
    )
}

fn merge_herdr_created_inventory(
    inner: &Inner,
    request: &HerdrCreateRequest,
    snapshot: HostSnapshot,
    publication_generation: u64,
) -> Result<u64, WorkspaceError> {
    merge_constructive_inventory(
        inner,
        &request.host,
        &request.endpoint,
        &request.runtime,
        snapshot,
        publication_generation,
        "the created Herdr session",
    )
}

fn merge_herdr_lifecycle_inventory(
    inner: &Inner,
    pending: &PendingHerdrLifecycle,
    snapshot: HostSnapshot,
    publication_generation: u64,
) -> Result<u64, WorkspaceError> {
    merge_constructive_inventory(
        inner,
        &pending.host,
        &pending.endpoint,
        &pending.runtime,
        snapshot,
        publication_generation,
        "the Herdr lifecycle result",
    )
}

fn publish_herdr_lifecycle_response(
    inner: &Inner,
    pending: &PendingHerdrLifecycle,
    record: session::HerdrSessionRecord,
) -> Result<u64, WorkspaceError> {
    let publication_generation = reserve_constructive_inventory(inner);
    let snapshot = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .filter(|published| {
            published.value.snapshot.endpoint() == &pending.endpoint
                && published.value.snapshot.runtime() == &pending.runtime
        })
        .map(|published| published.value.snapshot.clone())
        .ok_or_else(|| {
            WorkspaceError::new(
                "the WSL endpoint changed while publishing the Herdr lifecycle response",
            )
        })?
        .with_herdr_lifecycle(pending.action, &pending.executable, &pending.record, record)
        .ok_or_else(|| {
            WorkspaceError::new(
                "the Herdr lifecycle response no longer matches published inventory",
            )
        })?;
    merge_herdr_lifecycle_inventory(inner, pending, snapshot, publication_generation)
}

fn reconcile_herdr_lifecycle_inventory(
    inner: &Inner,
    pending: &PendingHerdrLifecycle,
) -> Result<HostSnapshot, WorkspaceError> {
    let publication_generation = reserve_constructive_inventory(inner);
    let snapshot = match pending.host.discover(&ConptyAdmissionAttacher::new()) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            settle_constructive_inventory(inner, publication_generation);
            return Err(WorkspaceError::new(error.to_string()));
        }
    };
    match snapshot.herdr() {
        HerdrInventory::Available { .. } => {}
        HerdrInventory::Failed(error) => {
            settle_constructive_inventory(inner, publication_generation);
            return Err(WorkspaceError::new(error.to_string()));
        }
        HerdrInventory::Unavailable => {
            settle_constructive_inventory(inner, publication_generation);
            return Err(WorkspaceError::new(
                "Herdr became unavailable while reconciling the lifecycle action",
            ));
        }
    }
    merge_herdr_lifecycle_inventory(inner, pending, snapshot.clone(), publication_generation)?;
    Ok(snapshot)
}

fn herdr_session_is_still_running(
    snapshot: &HostSnapshot,
    pending: &PendingHerdrLifecycle,
) -> bool {
    herdr_record_is_still_running(
        snapshot,
        &pending.endpoint,
        &pending.runtime,
        &pending.executable,
        &pending.record,
    )
}

fn herdr_record_is_still_running(
    snapshot: &HostSnapshot,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    expected_executable: &str,
    expected: &session::HerdrSessionRecord,
) -> bool {
    snapshot.endpoint() == endpoint
        && snapshot.runtime() == runtime
        && matches!(
            snapshot.herdr(),
            HerdrInventory::Available {
                executable,
                sessions,
            } if executable == expected_executable
                && sessions.iter().any(|record| {
                    record.name() == expected.name()
                        && record.state() == HerdrSessionState::Running
                        && record.is_default() == expected.is_default()
                        && record.session_directory() == expected.session_directory()
                        && record.socket_path() == expected.socket_path()
                })
        )
}

#[cfg(test)]
fn herdr_lifecycle_is_reflected(snapshot: &HostSnapshot, pending: &PendingHerdrLifecycle) -> bool {
    let HerdrInventory::Available { sessions, .. } = snapshot.herdr() else {
        return false;
    };
    let current = sessions
        .iter()
        .find(|session| session.name() == pending.record.name());
    match pending.action {
        HerdrLifecycleAction::Stop => current.is_some_and(|record| {
            record.state() == HerdrSessionState::Stopped
                && record.is_default() == pending.record.is_default()
                && record.session_directory() == pending.record.session_directory()
                && record.socket_path() == pending.record.socket_path()
        }),
        HerdrLifecycleAction::Delete => current.is_none(),
    }
}

fn publish_herdr_lifecycle_uncertain(
    inner: &Inner,
    pending: &PendingHerdrLifecycle,
    suppressed: Option<SuppressedHerdrPresentation>,
    message: &str,
) {
    let _snapshot_write = begin_snapshot_write(inner);
    let reconcile_after_generation = inner.refresh_generation.load(Ordering::Acquire);
    inner
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .mark_uncertain(pending, reconcile_after_generation, suppressed);
    let mut hosts = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(host) = hosts
        .iter_mut()
        .find(|host| host.endpoint == pending.endpoint.distro())
    {
        host.herdr_diagnostic = Some(HostDiagnostic::new(
            DiagnosticKind::Transport,
            message.to_owned(),
        ));
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn merge_constructive_inventory(
    inner: &Inner,
    runtime_host: &RuntimeHost,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    snapshot: HostSnapshot,
    publication_generation: u64,
    operation: &str,
) -> Result<u64, WorkspaceError> {
    let _publication = inner
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.refresh_generation.load(Ordering::Acquire) != publication_generation {
        return Err(WorkspaceError::new(format!(
            "newer inventory superseded {operation}; refresh before trying again"
        )));
    }
    let _snapshot_write = begin_snapshot_write(inner);
    if snapshot.endpoint() != endpoint || snapshot.runtime() != runtime {
        return Err(WorkspaceError::new(format!(
            "WSL changed while publishing {operation}"
        )));
    }
    let published_generation = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .and_then(|published| {
            (published.value.snapshot.endpoint() == endpoint
                && published.value.snapshot.runtime() == runtime)
                .then_some(published.generation)
        })
        .ok_or_else(|| {
            WorkspaceError::new(format!(
                "the WSL endpoint changed while publishing {operation}; refresh before trying again"
            ))
        })?;
    if published_generation > publication_generation {
        return Err(WorkspaceError::new(
            "session inventory generation moved backwards during publication",
        ));
    }
    let inventory_generation = publication_generation;

    let inventory_state = ready_content(&snapshot);
    reconcile_herdr_lifecycle_fences(inner, &snapshot, publication_generation, false);
    set_herdr_inventory(inner, snapshot.herdr());
    set_zellij_inventory(inner, snapshot.zellij());
    reconcile_retained_session_names(inner, &snapshot, runtime_host.socket_directory());
    *inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
        HostContext {
            host: runtime_host.clone(),
            snapshot,
        },
        inventory_generation,
    ));
    set_inventory_state(inner, inventory_state);
    Ok(inventory_generation)
}

fn publish_attach_inventory(inner: &Inner, request: &AttachRequest, snapshot: HostSnapshot) {
    publish_refresh(inner, request.inventory_generation, || {
        set_attach_inventory(inner, request, snapshot);
    });
}

fn set_attach_inventory(inner: &Inner, request: &AttachRequest, snapshot: HostSnapshot) {
    let inventory_state = ready_content(&snapshot);
    set_herdr_inventory(inner, snapshot.herdr());
    set_zellij_inventory(inner, snapshot.zellij());
    reconcile_retained_session_names(inner, &snapshot, request.host.socket_directory());
    *inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
        HostContext {
            host: request.host.clone(),
            snapshot,
        },
        request.inventory_generation,
    ));
    set_inventory_state(inner, inventory_state);
}

fn reconcile_presentation_session_names(
    inner: &Inner,
    refresh_generation: u64,
    snapshot: &HostSnapshot,
    socket_directory: Option<&str>,
) {
    let _snapshot_write = begin_snapshot_write(inner);
    let mut attachment = inner
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _publication = inner
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.refresh_generation.load(Ordering::Acquire) != refresh_generation {
        return;
    }
    reconcile_retained_session_names(inner, snapshot, socket_directory);
    let renamed = attachment.active_mut().and_then(|active| {
        let name = refreshed_session_name(
            &active.request.presentation_key(),
            snapshot,
            socket_directory,
        )?;
        if name == active.request.name {
            return None;
        }
        name.clone_into(&mut active.request.name);
        Some((
            active.request.host_id.clone(),
            active.request.endpoint.distro().to_owned(),
            name,
        ))
    });
    let Some((renamed_host, renamed_endpoint, renamed_session)) = renamed else {
        return;
    };
    let changed = {
        let mut state = inner
            .state
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match &mut *state {
            WorkspaceContent::Attaching {
                host_id,
                endpoint,
                session,
                ..
            }
            | WorkspaceContent::Terminal {
                host_id,
                endpoint,
                session,
                ..
            } if host_id == &renamed_host && endpoint == &renamed_endpoint => {
                session.clone_from(&renamed_session);
                true
            }
            _ => false,
        }
    };
    if changed {
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn reconcile_retained_session_names(
    inner: &Inner,
    snapshot: &HostSnapshot,
    socket_directory: Option<&str>,
) {
    let changed = inner
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .reconcile_session_names(snapshot, socket_directory);
    if changed {
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn publish_stale_attachment_failure(
    inner: &Inner,
    request: &AttachRequest,
    snapshot: HostSnapshot,
    error: &WorkspaceError,
) {
    clear_pending_paste(inner);
    restore_presentation_inventory(inner);
    publish_refresh(inner, request.inventory_generation, || {
        set_local_notice(inner, error.to_string());
        set_attach_inventory(inner, request, snapshot);
    });
}

fn publish_retained_stale_failure(
    inner: &Inner,
    request: &AttachRequest,
    snapshot: HostSnapshot,
    error: &WorkspaceError,
) {
    publish_refresh(inner, request.inventory_generation, || {
        set_local_notice(inner, error.to_string());
        set_attach_inventory(inner, request, snapshot);
    });
}

fn publish_attachment_failure(inner: &Inner, inventory_generation: u64, error: impl fmt::Display) {
    let message = error.to_string();
    clear_pending_paste(inner);
    restore_presentation_inventory(inner);
    publish_refresh(inner, inventory_generation, || {
        if inner.host_scoped_inventory {
            set_wsl_host_unavailable(inner, DiagnosticKind::Transport, message);
        } else {
            set_inner_state(inner, WorkspaceContent::Error { message });
        }
    });
}

fn restore_presentation_inventory(inner: &Inner) {
    let state = inner
        .inventory_state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    set_inner_state(inner, state);
}

fn reopen_closed_retained_presentation(
    inner: &Inner,
    mut closed: ClosedRetainedPresentation,
) -> Result<RetainedPresentation<TerminalWorker>, WorkspaceError> {
    let term = closed.attachment.term;
    let (worker, _snapshot, attached_name, initial_geometry) =
        attach_fresh(inner, &closed.attachment.request, term).map_err(|error| match error {
            AttachFreshError::Host(error) | AttachFreshError::SessionChanged { error, .. } => error,
        })?;
    let latest_geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if latest_geometry != initial_geometry {
        worker
            .resize_with_metadata(
                latest_geometry.grid,
                latest_geometry.sequence,
                latest_geometry.pixels,
            )
            .map_err(|error| WorkspaceError::from_worker(&error))?;
    }
    attached_name.clone_into(&mut closed.attachment.request.name);
    let selection = closed.attachment.request.selection();
    worker.set_clipboard_writes_enabled(false);
    Ok(RetainedPresentation {
        key: closed.key,
        selection,
        attachment: closed.attachment,
        worker,
        presentation_id: closed.presentation_id,
    })
}

fn publish_restored_retained_presentation(
    inner: &Inner,
    presentation: RetainedPresentation<TerminalWorker>,
) {
    let _snapshot_write = begin_snapshot_write(inner);
    inner
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .insert(presentation);
    inner.revision.fetch_add(1, Ordering::Release);
}

#[allow(
    clippy::too_many_lines,
    reason = "all backend attachment capabilities share one audited dispatch boundary"
)]
fn attach_fresh(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let fresh = discover_fresh_runtime(request)?;
    match &request.target {
        AttachTarget::Tmux(identity) => {
            let session = fresh
                .sessions()
                .iter()
                .find(|session| session.name() == request.name)
                .cloned();
            let Some(session) = session else {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new(
                        "session no longer exists; refresh and choose another session",
                    ),
                    snapshot: Box::new(fresh),
                });
            };
            if identity != session.identity() {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new(
                        "session identity changed since discovery; refusing stale attachment",
                    ),
                    snapshot: Box::new(fresh),
                });
            }
            launch_fresh_tmux(inner, request, term, &fresh, &session)
        }
        AttachTarget::Worktree {
            repository,
            path,
            generation,
            session_name,
        } => {
            let cancellation = CancellationToken::new();
            validate_fresh_worktree(
                request,
                &fresh,
                repository,
                path,
                generation.as_deref(),
                session_name,
                &cancellation,
            )?;
            launch_fresh_worktree(
                inner,
                request,
                term,
                &fresh,
                path,
                session_name,
                &cancellation,
            )
        }
        AttachTarget::Herdr { .. } => {
            let Some(session) = fresh_herdr_session(&fresh, &request.target) else {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new(
                        "Herdr session changed since discovery; refresh and choose it again",
                    ),
                    snapshot: Box::new(fresh),
                });
            };
            launch_fresh_herdr(inner, request, term, &fresh, &session)
        }
        AttachTarget::Zellij { executable, name } => {
            let ZellijInventory::Available {
                executable: current_executable,
                sessions,
            } = fresh.zellij()
            else {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new("Zellij is no longer available on this host"),
                    snapshot: Box::new(fresh),
                });
            };
            let Some(session) = sessions
                .iter()
                .find(|session| session.name() == name && current_executable == executable)
                .cloned()
            else {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new(
                        "Zellij session changed since discovery; refresh and choose it again",
                    ),
                    snapshot: Box::new(fresh),
                });
            };
            launch_fresh_zellij(inner, request, term, &fresh, &session)
        }
    }
}

fn attach_fresh_retained(
    inner: &Inner,
    retry: &RetainedRetry,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        AttachRequest,
        TerminalGeometry,
    ),
    AttachFreshError,
> {
    let fresh = discover_fresh_runtime(&retry.request)?;
    let Some(resolved_request) = resolve_retained_retry_request(retry, &fresh) else {
        return Err(AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "session identity changed since discovery; refusing stale attachment",
            ),
            snapshot: Box::new(fresh),
        });
    };
    let (worker, snapshot, _, geometry) = match &retry.key.target {
        AttachTarget::Tmux(identity) => {
            let session = fresh
                .sessions()
                .iter()
                .find(|session| session.identity() == identity)
                .cloned()
                .expect("resolved retained request has a matching tmux session");
            launch_fresh_tmux(
                inner,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                &session,
            )?
        }
        AttachTarget::Worktree {
            repository,
            path,
            generation,
            session_name,
        } => {
            let cancellation = CancellationToken::new();
            validate_fresh_worktree(
                &resolved_request,
                &fresh,
                repository,
                path,
                generation.as_deref(),
                session_name,
                &cancellation,
            )?;
            launch_fresh_worktree(
                inner,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                path,
                session_name,
                &cancellation,
            )?
        }
        AttachTarget::Herdr { .. } => {
            let session = fresh_herdr_session(&fresh, &retry.key.target)
                .expect("resolved retained request has a matching Herdr session");
            launch_fresh_herdr(
                inner,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                &session,
            )?
        }
        AttachTarget::Zellij { executable, name } => {
            let ZellijInventory::Available {
                executable: current_executable,
                sessions,
            } = fresh.zellij()
            else {
                unreachable!("resolved retained request has Zellij inventory");
            };
            let session = sessions
                .iter()
                .find(|session| session.name() == name && current_executable == executable)
                .expect("resolved retained request has a matching Zellij session");
            launch_fresh_zellij(inner, &resolved_request, AttachTerm::Xterm, &fresh, session)?
        }
    };
    Ok((worker, snapshot, resolved_request, geometry))
}

#[allow(clippy::too_many_arguments)]
fn validate_fresh_worktree(
    request: &AttachRequest,
    fresh: &HostSnapshot,
    repository: &str,
    path: &str,
    generation: Option<&str>,
    session_name: &str,
    cancellation: &CancellationToken,
) -> Result<(), AttachFreshError> {
    let inventory = request
        .host
        .discover_kwt(&request.endpoint, &request.runtime, cancellation)
        .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?
        .ok_or_else(|| {
            AttachFreshError::Host(WorkspaceError::new(
                "the revision-pinned KWT helper is unavailable",
            ))
        })?;
    let current = inventory.projects().iter().find_map(|project| {
        (project.project().repository() == repository).then(|| {
            project.worktrees().iter().find(|worktree| {
                worktree.path() == path
                    && worktree.generation() == generation
                    && worktree.tmux_socket_name().is_none()
            })
        })?
    });
    match current {
        Some(worktree) if worktree.session_name() == session_name => Ok(()),
        Some(_) => Err(AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "worktree session identity changed since discovery; refresh and choose it again",
            ),
            snapshot: Box::new(fresh.clone()),
        }),
        None => Err(AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "worktree identity changed since discovery; refresh and choose it again",
            ),
            snapshot: Box::new(fresh.clone()),
        }),
    }
}

fn discover_fresh_runtime(request: &AttachRequest) -> Result<HostSnapshot, AttachFreshError> {
    let fresh = request
        .host
        .discover(&ConptyAdmissionAttacher::new())
        .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    if fresh.endpoint() != &request.endpoint || fresh.runtime() != &request.runtime {
        return Err(AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "WSL runtime changed since session discovery; refresh and try again",
            ),
            snapshot: Box::new(fresh),
        });
    }
    Ok(fresh)
}

fn resolve_retained_retry_request(
    retry: &RetainedRetry,
    fresh: &HostSnapshot,
) -> Option<AttachRequest> {
    let name = refreshed_session_name(&retry.key, fresh, retry.request.host.socket_directory())?;
    let mut request = retry.request.clone();
    name.clone_into(&mut request.name);
    Some(request)
}

fn launch_fresh_tmux(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    session: &session::DiscoveredSession,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let plan = request
        .host
        .attach_plan_with_term(fresh.endpoint(), session, term);
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::attach_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
        default_colors(&inner.appearance),
    )
    .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    Ok((
        worker,
        fresh.clone(),
        plan.target_name().to_owned(),
        geometry,
    ))
}

#[allow(clippy::too_many_arguments)]
fn capture_kwt_worktree_request(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: Option<&str>,
    session_name: &str,
) -> Result<AttachRequest, WorkspaceError> {
    if host_id != "wsl"
        || inner
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref()
            != Some(host_id)
    {
        return Err(WorkspaceError::new("the WSL host is not selected"));
    }
    let host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the worktree selection",
            ));
        }
        let hosts = inner
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let host_item = hosts
            .iter()
            .find(|host| host.id == host_id && host.endpoint == endpoint)
            .ok_or_else(|| WorkspaceError::new("the selected WSL host is unavailable"))?;
        if host_item.connection != HostConnectionState::Ready || !host_item.kwt_available() {
            return Err(WorkspaceError::new(
                "refresh KWT inventory before opening this worktree",
            ));
        }
        let worktree = host_item
            .projects
            .iter()
            .find(|project| {
                project.repository == repository
                    && project.path == project_path
                    && project.registration_fingerprint == registration_fingerprint
            })
            .and_then(|project| {
                project.worktrees.iter().find(|worktree| {
                    worktree.path == worktree_path
                        && worktree.generation.as_deref() == generation
                        && worktree.session_name == session_name
                        && worktree.tmux_socket_name.is_none()
                })
            })
            .ok_or_else(|| {
                WorkspaceError::new(
                    "the selected worktree is no longer in authoritative KWT inventory",
                )
            })?;
        Ok(AttachRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            target: AttachTarget::Worktree {
                repository: repository.to_owned(),
                path: worktree.path.clone(),
                generation: worktree.generation.clone(),
                session_name: worktree.session_name.clone(),
            },
            name: worktree.session_name.clone(),
            inventory_generation,
        })
    })
}

fn launch_fresh_worktree(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    path: &str,
    session_name: &str,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let plan = request
        .host
        .kwt_repair_or_open_plan(
            fresh.endpoint(),
            fresh.runtime(),
            path,
            session_name,
            term,
            cancellation,
        )
        .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::repair_or_open_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
        default_colors(&inner.appearance),
    )
    .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    Ok((
        worker,
        fresh.clone(),
        plan.target_name().to_owned(),
        geometry,
    ))
}

fn fresh_herdr_session(
    snapshot: &HostSnapshot,
    target: &AttachTarget,
) -> Option<session::HerdrSessionRecord> {
    let AttachTarget::Herdr {
        executable,
        is_default,
        session_directory,
        socket_path,
    } = target
    else {
        return None;
    };
    let HerdrInventory::Available {
        executable: current_executable,
        sessions,
    } = snapshot.herdr()
    else {
        return None;
    };
    (current_executable == executable)
        .then(|| {
            sessions.iter().find(|session| {
                session.is_default() == *is_default
                    && session.session_directory() == session_directory
                    && session.socket_path() == socket_path
                    && session.state() == HerdrSessionState::Running
            })
        })
        .flatten()
        .cloned()
}

fn launch_fresh_herdr(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    session: &session::HerdrSessionRecord,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let AttachTarget::Herdr { executable, .. } = &request.target else {
        unreachable!("Herdr launch requires a Herdr target");
    };
    let operation_key = request
        .herdr_operation_key()
        .expect("Herdr launch has an operation key");
    let (worker, geometry) = with_herdr_launch_fence(
        &inner.herdr_lifecycle,
        &operation_key,
        || AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "Herdr session lifecycle is changing; wait for inventory to refresh",
            ),
            snapshot: Box::new(fresh.clone()),
        },
        || {
            let plan = request
                .host
                .herdr_attach_plan(fresh.endpoint(), executable, session, term);
            let geometry = *inner
                .terminal_geometry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let worker = TerminalWorker::attach_herdr_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
                default_colors(&inner.appearance),
            )
            .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
            Ok((worker, geometry))
        },
    )?;
    Ok((worker, fresh.clone(), session.name().to_owned(), geometry))
}

fn launch_fresh_zellij(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    session: &session::ZellijSessionRecord,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let AttachTarget::Zellij { executable, .. } = &request.target else {
        unreachable!("Zellij launch requires a Zellij target");
    };
    let plan = request
        .host
        .zellij_attach_plan(fresh.endpoint(), executable, session, term);
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::attach_zellij_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
        default_colors(&inner.appearance),
    )
    .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    Ok((worker, fresh.clone(), session.name().to_owned(), geometry))
}

fn set_terminal_notice(inner: &Inner, term: AttachTerm) {
    let notice = (term == AttachTerm::Xterm).then(|| REDUCED_COLOR_NOTICE.to_owned());
    *inner
        .terminal_notice
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = notice;
}

fn set_local_notice(inner: &Inner, message: String) {
    *inner
        .terminal_notice
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(message);
}

fn publish_local_notice(inner: &Inner, message: String) {
    set_local_notice(inner, message);
    inner.revision.fetch_add(1, Ordering::Release);
}

fn clear_terminal_notice(inner: &Inner) {
    *inner
        .terminal_notice
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
}

fn default_colors(appearance: &Appearance) -> DefaultColors {
    DefaultColors::new(rgb(appearance.foreground()), rgb(appearance.background()))
}

fn rgb(color: u32) -> Rgb {
    Rgb::new(
        ((color >> 16) & 0xff) as u8,
        ((color >> 8) & 0xff) as u8,
        (color & 0xff) as u8,
    )
}

fn ready_content(snapshot: &HostSnapshot) -> WorkspaceContent {
    WorkspaceContent::Ready {
        endpoint: snapshot.endpoint().distro().to_owned(),
        sessions: snapshot
            .sessions()
            .iter()
            .map(|session| SessionItem::new(session.name(), session.attached_clients()))
            .collect(),
    }
}

fn set_herdr_inventory(inner: &Inner, inventory: &HerdrInventory) {
    let mut hosts = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") else {
        return;
    };
    match inventory {
        HerdrInventory::Unavailable => {
            host.herdr_available = false;
            host.herdr_sessions.clear();
            host.herdr_diagnostic = None;
        }
        HerdrInventory::Available { sessions, .. } => {
            host.herdr_available = true;
            host.herdr_sessions = sessions
                .iter()
                .map(|session| {
                    HerdrSessionItem::new(session.name(), session.is_default(), session.state())
                })
                .collect();
            host.herdr_diagnostic = None;
        }
        HerdrInventory::Failed(error) => {
            host.herdr_diagnostic = Some(HostDiagnostic::new(error.kind(), error.to_string()));
        }
    }
}

fn set_zellij_inventory(inner: &Inner, inventory: &ZellijInventory) {
    let mut hosts = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") else {
        return;
    };
    match inventory {
        ZellijInventory::Unavailable => {
            host.zellij_available = false;
            host.zellij_sessions.clear();
            host.zellij_diagnostic = None;
        }
        ZellijInventory::Available { sessions, .. } => {
            host.zellij_available = true;
            host.zellij_sessions = sessions
                .iter()
                .map(|session| SessionItem::new(session.name(), 0))
                .collect();
            host.zellij_diagnostic = None;
        }
        ZellijInventory::Failed(error) => {
            host.zellij_diagnostic = Some(HostDiagnostic::new(error.kind(), error.to_string()));
        }
    }
}

fn project_herdr_lifecycle(
    hosts: &mut [HostItem],
    current_runtime: Option<&(host::WslEndpoint, host::WslRuntimeIdentity)>,
    lifecycle: &Mutex<HerdrLifecycleState>,
) {
    let Some((endpoint, runtime)) = current_runtime else {
        return;
    };
    let lifecycle = lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts
        .iter_mut()
        .find(|host| host.endpoint == endpoint.distro())
    else {
        return;
    };
    for session in &mut host.herdr_sessions {
        let key = HerdrOperationKey {
            endpoint: endpoint.clone(),
            runtime: runtime.clone(),
            name: session.name.clone(),
        };
        session.lifecycle_action = lifecycle.in_flight_action(&key);
        session.launch_pending = lifecycle.launch_pending(&key);
    }
}

fn reconcile_herdr_lifecycle_fences(
    inner: &Inner,
    snapshot: &HostSnapshot,
    publication_generation: u64,
    release_recoveries: bool,
) -> HerdrLifecycleReconciliation {
    inner
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .reconcile(snapshot, publication_generation, release_recoveries)
}

fn set_inner_state(inner: &Inner, state: WorkspaceContent) {
    *inner
        .state
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = state;
    inner.revision.fetch_add(1, Ordering::Release);
}

fn set_inventory_state(inner: &Inner, state: WorkspaceContent) {
    let host_updated = {
        let mut hosts = inner
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") {
            match &state {
                WorkspaceContent::Loading => {
                    host.connection = HostConnectionState::Connecting;
                    host.diagnostic = None;
                }
                WorkspaceContent::Ready { endpoint, sessions } => {
                    if host.endpoint != *endpoint {
                        host.projects.clear();
                        host.directory_workspaces.clear();
                        host.kwt_state = KwtState::Uninitialized;
                        host.kwt_diagnostic = None;
                    }
                    host.endpoint.clone_from(endpoint);
                    host.connection = HostConnectionState::Ready;
                    host.sessions.clone_from(sessions);
                    reconcile_kwt_session_availability(host);
                    host.diagnostic = None;
                }
                WorkspaceContent::Error { message } => {
                    host.connection = HostConnectionState::Unavailable;
                    host.diagnostic = Some(HostDiagnostic::new(
                        DiagnosticKind::Transport,
                        message.clone(),
                    ));
                }
                WorkspaceContent::Shell
                | WorkspaceContent::Attaching { .. }
                | WorkspaceContent::Terminal { .. } => {}
            }
            true
        } else {
            false
        }
    };
    if host_updated && inner.host_scoped_inventory {
        let mut current = inner
            .state
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !matches!(
            *current,
            WorkspaceContent::Shell
                | WorkspaceContent::Attaching { .. }
                | WorkspaceContent::Terminal { .. }
        ) {
            *current = WorkspaceContent::Shell;
        }
        inner.revision.fetch_add(1, Ordering::Release);
        return;
    }
    publish_legacy_inventory_state(inner, state);
}

fn reconcile_kwt_session_availability(host: &mut HostItem) {
    let session_names = host
        .sessions
        .iter()
        .map(|session| session.name.as_str())
        .collect::<std::collections::HashSet<_>>();
    for project in &mut host.projects {
        for worktree in &mut project.worktrees {
            worktree.session_available = worktree.tmux_socket_name.is_none()
                && session_names.contains(worktree.session_name.as_str());
        }
    }
    for workspace in &mut host.directory_workspaces {
        workspace.session_available = session_names.contains(workspace.session_name.as_str());
    }
}

fn publish_legacy_inventory_state(inner: &Inner, state: WorkspaceContent) {
    *inner
        .inventory_state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = state.clone();
    let mut current = inner
        .state
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if matches!(
        &*current,
        WorkspaceContent::Attaching { .. } | WorkspaceContent::Terminal { .. }
    ) {
        return;
    }
    *current = state;
    inner.revision.fetch_add(1, Ordering::Release);
}

fn set_wsl_host_unavailable(inner: &Inner, kind: DiagnosticKind, message: String) {
    let mut hosts = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") {
        host.connection = HostConnectionState::Unavailable;
        host.diagnostic = Some(HostDiagnostic::new(kind, message.clone()));
        if inner.host_scoped_inventory {
            inner.revision.fetch_add(1, Ordering::Release);
            return;
        }
    }
    drop(hosts);
    publish_legacy_inventory_state(inner, WorkspaceContent::Error { message });
}

fn set_wsl_host_disconnected(inner: &Inner) {
    let mut hosts = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") {
        host.connection = HostConnectionState::Disconnected;
        host.diagnostic = None;
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn clear_pending_paste(inner: &Inner) {
    inner
        .pending_paste
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
}

fn publish_terminfo_retry_boundary(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    session: &str,
    kind: SessionKind,
) {
    clear_pending_paste(inner);
    set_inner_state(
        inner,
        WorkspaceContent::Attaching {
            host_id: host_id.to_owned(),
            endpoint: endpoint.to_owned(),
            session: session.to_owned(),
            kind,
        },
    );
}

fn next_presentation_id(inner: &Inner) -> u64 {
    inner
        .presentation_generation
        .fetch_add(1, Ordering::AcqRel)
        .wrapping_add(1)
}

fn classify_terminal_exit(code: u32, output_tail: &str) -> String {
    let lower = output_tail.to_ascii_lowercase();
    if is_identity_mismatch_exit(code, output_tail) {
        return "session identity changed immediately before attachment; refresh and try again"
            .to_owned();
    }
    if lower.contains("can't find session") || lower.contains("no sessions") {
        return "the tmux session no longer exists; refresh and choose another session".to_owned();
    }
    format!("tmux client exited with status {code}")
}

fn classify_terminal_exit_event(
    code: u32,
    output_tail: &str,
    term: AttachTerm,
    client_confirmed_live: bool,
) -> (bool, Option<String>) {
    if is_identity_mismatch_exit(code, output_tail) {
        return (false, Some(classify_terminal_exit(code, output_tail)));
    }
    if code == 0 {
        return (false, None);
    }
    let startup_terminfo_failure =
        !client_confirmed_live && is_exact_terminfo_startup_failure(output_tail, term);
    let retry_term = startup_terminfo_failure && term == AttachTerm::Xterm256Color;
    if startup_terminfo_failure && term == AttachTerm::Xterm {
        return (
            false,
            Some("tmux could not use either xterm-256color or xterm terminfo in WSL".to_owned()),
        );
    }
    let diagnostic = (!retry_term).then(|| classify_terminal_exit(code, output_tail));
    (retry_term, diagnostic)
}

fn is_identity_mismatch_exit(code: u32, output_tail: &str) -> bool {
    code == 0 && output_tail.trim_matches(['\r', '\n']) == session::IDENTITY_MISMATCH_MARKER
}

fn is_exact_terminfo_startup_failure(output: &str, term: AttachTerm) -> bool {
    let term_name = match term {
        AttachTerm::Xterm256Color => "xterm-256color",
        AttachTerm::Xterm => "xterm",
    };
    let line = output.trim_matches(['\r', '\n']).to_ascii_lowercase();
    [
        format!("missing or unsuitable terminal: {term_name}"),
        format!("open terminal failed: missing or unsuitable terminal: {term_name}"),
        format!("terminal entry not found: {term_name}"),
        format!("open terminal failed: terminal entry not found: {term_name}"),
    ]
    .contains(&line)
}

fn default_terminal_geometry() -> TerminalGeometry {
    TerminalGeometry {
        grid: GridSize::new(100, 30)
            .unwrap_or_else(|_| unreachable!("fixed terminal grid is valid")),
        pixels: PixelSize::default(),
        sequence: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_path_input_accepts_windows_and_wsl_absolute_paths() {
        assert!(is_absolute_project_path_input(r"C:\Users\test\code\widget"));
        assert!(is_absolute_project_path_input("D:/code/widget"));
        assert!(is_absolute_project_path_input(
            r"\\wsl.localhost\Ubuntu\home\test\widget"
        ));
        assert!(is_absolute_project_path_input("/home/test/widget"));
        assert!(!is_absolute_project_path_input(r"C:code\widget"));
        assert!(!is_absolute_project_path_input("code/widget"));
    }

    #[test]
    fn branch_name_validation_matches_the_git_ref_creation_boundary() {
        for valid in ["feature/worktrees", "release-2.0", "users/wes/code"] {
            assert!(
                is_valid_git_branch_name(valid),
                "expected {valid:?} to be valid"
            );
        }
        for invalid in [
            "",
            " feature",
            "feature ",
            "-feature",
            "feature..old",
            "feature@{old}",
            "feature.lock",
            "feature//nested",
            ".hidden/feature",
            "feature?",
        ] {
            assert!(
                !is_valid_git_branch_name(invalid),
                "expected {invalid:?} to be invalid"
            );
        }
    }
    use std::collections::VecDeque;
    use std::sync::{Barrier, atomic::AtomicUsize, mpsc};

    #[test]
    fn revision_consistent_read_retries_a_projection_crossing_an_update() {
        let revision = AtomicU64::new(1);
        let writers = AtomicUsize::new(0);
        let mut reads = 0;

        let observed = read_revision_consistent(&revision, &writers, |captured| {
            reads += 1;
            if reads == 1 {
                revision.fetch_add(1, Ordering::Release);
            }
            (captured, reads)
        });

        assert_eq!(observed, (2, 2));
    }

    #[test]
    fn revision_consistent_read_waits_for_a_multi_field_publication() {
        let revision = Arc::new(AtomicU64::new(1));
        let writers = Arc::new(AtomicUsize::new(1));
        let value = Arc::new(AtomicUsize::new(1));
        let (read_tx, read_rx) = mpsc::channel();
        let reader_revision = Arc::clone(&revision);
        let reader_writers = Arc::clone(&writers);
        let reader_value = Arc::clone(&value);
        let reader = thread::spawn(move || {
            read_revision_consistent(&reader_revision, &reader_writers, |captured| {
                read_tx.send(()).expect("announce snapshot read");
                (captured, reader_value.load(Ordering::Acquire))
            })
        });

        assert!(read_rx.recv_timeout(Duration::from_millis(20)).is_err());
        value.store(2, Ordering::Release);
        revision.fetch_add(1, Ordering::Release);
        writers.fetch_sub(1, Ordering::Release);

        assert_eq!(reader.join().expect("snapshot reader"), (2, 2));
    }

    #[test]
    fn session_operation_fence_spans_launch_until_publication() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let launch = workspace
            .inner
            .session_operations
            .lock()
            .expect("launch operation");
        let (waiting_tx, waiting_rx) = mpsc::channel();
        let (entered_tx, entered_rx) = mpsc::channel();
        let lifecycle_workspace = workspace.clone();
        let lifecycle = thread::spawn(move || {
            waiting_tx.send(()).expect("announce lifecycle wait");
            let _lifecycle = lifecycle_workspace
                .inner
                .session_operations
                .lock()
                .expect("lifecycle operation");
            entered_tx.send(()).expect("announce lifecycle entry");
        });

        waiting_rx.recv().expect("lifecycle reached fence");
        assert!(
            entered_rx.try_recv().is_err(),
            "lifecycle mutation must wait while client publication is in flight"
        );
        drop(launch);
        entered_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("lifecycle enters after publication");
        lifecycle.join().expect("lifecycle thread");
    }

    #[test]
    fn lifecycle_registration_waits_for_the_herdr_launch_fence() {
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
        let key = HerdrOperationKey {
            endpoint: snapshot.endpoint().clone(),
            runtime: snapshot.runtime().clone(),
            name: "review".to_owned(),
        };
        let lifecycle = Mutex::new(HerdrLifecycleState::default());

        with_herdr_launch_fence(
            &lifecycle,
            &key,
            || (),
            || {
                assert!(
                    lifecycle.try_lock().is_err(),
                    "client launch must hold the lifecycle registration lock"
                );
                Ok(())
            },
        )
        .expect("launch without an operation");

        lifecycle
            .lock()
            .expect("lifecycle state")
            .in_flight
            .push(InFlightHerdrLifecycle {
                generation: 1,
                key: key.clone(),
                action: HerdrLifecycleAction::Stop,
                reconcile_after_generation: None,
                recovery: None,
            });
        let mut launched = false;
        assert!(
            with_herdr_launch_fence(
                &lifecycle,
                &key,
                || "blocked",
                || {
                    launched = true;
                    Ok("launched")
                },
            )
            .is_err()
        );
        assert!(!launched, "an in-flight Stop must fence client launch");
    }

    struct BlockingRestoreRunner {
        entered: Mutex<Option<mpsc::SyncSender<()>>>,
        release: Mutex<mpsc::Receiver<()>>,
    }

    impl CommandRunner for BlockingRestoreRunner {
        fn run(
            &self,
            _program: &std::ffi::OsStr,
            _args: &[std::ffi::OsString],
            _cancellation: &CancellationToken,
            _timeout: Duration,
        ) -> std::io::Result<host::CommandOutput> {
            if let Some(entered) = self.entered.lock().expect("entered signal").take() {
                entered.send(()).expect("announce blocked discovery");
                self.release
                    .lock()
                    .expect("release signal")
                    .recv()
                    .expect("release blocked discovery");
            }
            Err(std::io::Error::new(
                std::io::ErrorKind::ConnectionAborted,
                "fixture discovery stopped",
            ))
        }
    }

    #[test]
    fn retained_herdr_recovery_does_not_block_snapshots_during_discovery() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let snapshot = HostSnapshot::test_fixture_with_herdr(
            "Ubuntu",
            "boot",
            42,
            Vec::new(),
            HerdrInventory::Unavailable,
        );
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let runner: SharedCommandRunner = Arc::new(BlockingRestoreRunner {
            entered: Mutex::new(Some(entered_tx)),
            release: Mutex::new(release_rx),
        });
        let host = WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            runner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let request = AttachRequest {
            host_id: "wsl".to_owned(),
            host,
            endpoint: snapshot.endpoint().clone(),
            runtime: snapshot.runtime().clone(),
            target: AttachTarget::Herdr {
                executable: "/opt/herdr/bin/herdr".to_owned(),
                is_default: false,
                session_directory: "/tmp/herdr/review".to_owned(),
                socket_path: "/tmp/herdr/review/herdr.sock".to_owned(),
            },
            name: "review".to_owned(),
            inventory_generation: 1,
        };
        let suppressed = SuppressedHerdrPresentation {
            active_selection: None,
            retained: Some(ClosedRetainedPresentation {
                key: request.presentation_key(),
                attachment: ActiveAttachment {
                    request,
                    term: AttachTerm::Xterm256Color,
                    generation: 1,
                    fallback: None,
                },
                presentation_id: 1,
            }),
            navigation_generation: 0,
        };
        let recovery_workspace = workspace.clone();
        let recovery = thread::spawn(move || {
            recovery_workspace.restore_suppressed_herdr_presentation(Some(suppressed));
        });
        entered_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("recovery reached WSL discovery");

        let snapshot_workspace = workspace.clone();
        let (snapshot_tx, snapshot_rx) = mpsc::sync_channel(1);
        let snapshot_reader = thread::spawn(move || {
            let _snapshot = snapshot_workspace.snapshot();
            snapshot_tx.send(()).expect("publish completed read");
        });
        let snapshot_completed = snapshot_rx.recv_timeout(Duration::from_millis(250)).is_ok();

        release_tx.send(()).expect("release WSL discovery");
        recovery.join().expect("recovery task");
        snapshot_reader.join().expect("snapshot reader");
        assert!(
            snapshot_completed,
            "slow retained recovery must not hold the snapshot publication guard"
        );
    }

    type SpawnFailureHook = Box<dyn FnOnce() + Send>;

    #[derive(Default)]
    struct ManualRefreshRuntime {
        work: Mutex<VecDeque<RefreshTask>>,
        deadlines: Mutex<VecDeque<(Duration, CancellationToken, RefreshTask)>>,
        fail_next_work: AtomicBool,
        before_spawn_failure: Mutex<Option<SpawnFailureHook>>,
    }

    impl ManualRefreshRuntime {
        fn run_next_work(&self) {
            let task = self.work.lock().expect("work queue").pop_front();
            task.expect("queued work")();
        }

        fn run_next_deadline(&self) {
            let task = self
                .deadlines
                .lock()
                .expect("deadline queue")
                .pop_front()
                .map(|(_, cancellation, task)| (cancellation, task));
            let (cancellation, task) = task.expect("queued deadline");
            if !cancellation.is_cancelled() {
                task();
            }
        }

        fn deadline_delays(&self) -> Vec<Duration> {
            self.deadlines
                .lock()
                .expect("deadline queue")
                .iter()
                .map(|(delay, _, _)| *delay)
                .collect()
        }

        fn fail_next_work(&self, before_failure: impl FnOnce() + Send + 'static) {
            *self
                .before_spawn_failure
                .lock()
                .expect("spawn failure hook") = Some(Box::new(before_failure));
            self.fail_next_work.store(true, Ordering::Release);
        }
    }

    impl RefreshRuntime for ManualRefreshRuntime {
        fn spawn(&self, _name: &str, task: RefreshTask) -> std::io::Result<()> {
            if self.fail_next_work.swap(false, Ordering::AcqRel) {
                if let Some(before_failure) = self
                    .before_spawn_failure
                    .lock()
                    .expect("spawn failure hook")
                    .take()
                {
                    before_failure();
                }
                return Err(std::io::Error::other("scripted work spawn failure"));
            }
            self.work.lock().expect("work queue").push_back(task);
            Ok(())
        }

        fn spawn_after(
            &self,
            _name: &str,
            delay: Duration,
            cancellation: CancellationToken,
            task: RefreshTask,
        ) -> std::io::Result<()> {
            self.deadlines
                .lock()
                .expect("deadline queue")
                .push_back((delay, cancellation, task));
            Ok(())
        }
    }

    struct BlockingDiscovery {
        snapshot: HostSnapshot,
        entered: Mutex<Option<mpsc::SyncSender<()>>>,
        release: Mutex<mpsc::Receiver<()>>,
    }

    impl WslDiscovery for BlockingDiscovery {
        fn discover(
            &self,
            config: WslConfig,
            executable: WslExecutable,
            existing_host: Option<RuntimeHost>,
            _cancellation: &CancellationToken,
        ) -> Result<HostContext, HostError> {
            if let Some(entered) = self.entered.lock().expect("entered signal").take() {
                entered.send(()).expect("announce blocked discovery");
            }
            self.release
                .lock()
                .expect("release signal")
                .recv()
                .expect("release blocked discovery");
            let host = existing_host
                .unwrap_or_else(|| WslHost::new(config, Arc::new(StdCommandRunner), executable));
            Ok(HostContext {
                host,
                snapshot: self.snapshot.clone(),
            })
        }
    }

    struct FixedDiscovery {
        snapshot: HostSnapshot,
        reused_hosts: AtomicUsize,
    }

    impl FixedDiscovery {
        fn new(snapshot: HostSnapshot) -> Self {
            Self {
                snapshot,
                reused_hosts: AtomicUsize::new(0),
            }
        }
    }

    impl WslDiscovery for FixedDiscovery {
        fn discover(
            &self,
            config: WslConfig,
            executable: WslExecutable,
            existing_host: Option<RuntimeHost>,
            _cancellation: &CancellationToken,
        ) -> Result<HostContext, HostError> {
            let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
            let host = existing_host.map_or_else(
                || WslHost::new(config, runner, executable),
                |host| {
                    self.reused_hosts.fetch_add(1, Ordering::AcqRel);
                    host
                },
            );
            Ok(HostContext {
                host,
                snapshot: self.snapshot.clone(),
            })
        }
    }

    fn presentation_key_fixture(
        kernel_boot_id: &str,
        init_start_ticks: u64,
        identity: session::SessionIdentity,
    ) -> PresentationKey {
        let snapshot =
            HostSnapshot::test_fixture("Ubuntu", kernel_boot_id, init_start_ticks, Vec::new());
        PresentationKey {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            socket_directory: None,
            runtime: snapshot.runtime().clone(),
            target: AttachTarget::Tmux(identity),
        }
    }

    fn fallback_fixture(
        kernel_boot_id: &str,
        init_start_ticks: u64,
        identity: session::SessionIdentity,
        navigation_generation: u64,
    ) -> FallbackAuthority {
        let presentation = presentation_key_fixture(kernel_boot_id, init_start_ticks, identity);
        FallbackAuthority {
            target: presentation.clone(),
            presentation,
            navigation_generation,
        }
    }

    fn captured_request(workspace: &Workspace, name: &str) -> AttachRequest {
        capture_attach_request(
            &workspace.inner,
            &SessionSelection::new("wsl", "Ubuntu", name),
        )
        .expect("fixture session is present")
    }

    #[cfg(windows)]
    fn attach_request_fixture(
        snapshot: &HostSnapshot,
        identity: session::SessionIdentity,
        name: &str,
    ) -> AttachRequest {
        AttachRequest {
            host_id: "wsl".to_owned(),
            host: WslHost::new(
                WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                    .expect("absolute WSL path"),
            ),
            endpoint: snapshot.endpoint().clone(),
            runtime: snapshot.runtime().clone(),
            target: AttachTarget::Tmux(identity),
            name: name.to_owned(),
            inventory_generation: 1,
        }
    }

    #[cfg(windows)]
    fn herdr_attach_request_fixture(snapshot: &HostSnapshot, name: &str) -> AttachRequest {
        AttachRequest {
            host_id: "wsl".to_owned(),
            host: WslHost::new(
                WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                    .expect("absolute WSL path"),
            ),
            endpoint: snapshot.endpoint().clone(),
            runtime: snapshot.runtime().clone(),
            target: AttachTarget::Herdr {
                executable: "/opt/herdr/bin/herdr".to_owned(),
                is_default: false,
                session_directory: "/tmp/herdr/review".to_owned(),
                socket_path: "/tmp/herdr/review/herdr.sock".to_owned(),
            },
            name: name.to_owned(),
            inventory_generation: 1,
        }
    }

    #[cfg(windows)]
    fn zellij_attach_request_fixture(snapshot: &HostSnapshot, name: &str) -> AttachRequest {
        AttachRequest {
            host_id: "wsl".to_owned(),
            host: WslHost::new(
                WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                    .expect("absolute WSL path"),
            ),
            endpoint: snapshot.endpoint().clone(),
            runtime: snapshot.runtime().clone(),
            target: AttachTarget::Zellij {
                executable: "/usr/bin/zellij".to_owned(),
                name: name.to_owned(),
            },
            name: name.to_owned(),
            inventory_generation: 1,
        }
    }

    #[test]
    fn terminal_event_drain_reserves_progress_for_retained_workers() {
        assert_eq!(ACTIVE_EVENT_BUDGET, MAX_EVENTS_PER_DRAIN - 8);
        assert_eq!(
            retained_event_budget(ACTIVE_EVENT_BUDGET, false),
            RETAINED_EVENT_RESERVE
        );
        assert!(!event_source_may_have_more(
            ACTIVE_EVENT_BUDGET - 1,
            ACTIVE_EVENT_BUDGET,
            false
        ));
        assert!(event_source_may_have_more(
            ACTIVE_EVENT_BUDGET,
            ACTIVE_EVENT_BUDGET,
            false
        ));
        assert!(!event_source_may_have_more(
            ACTIVE_EVENT_BUDGET,
            ACTIVE_EVENT_BUDGET,
            true
        ));
    }

    #[test]
    fn appearance_projects_terminal_default_colors() {
        let appearance = Appearance {
            font_family: "monospace".to_owned(),
            font_size: 14,
            background: 0x12_34_56,
            foreground: 0x65_43_21,
        };

        let colors = default_colors(&appearance);

        assert_eq!(colors.background(), Rgb::new(0x12, 0x34, 0x56));
        assert_eq!(colors.foreground(), Rgb::new(0x65, 0x43, 0x21));
    }

    #[test]
    fn atomic_attach_identity_mismatch_has_a_specific_diagnostic() {
        let (retry_term, diagnostic) = classify_terminal_exit_event(
            0,
            session::IDENTITY_MISMATCH_MARKER,
            AttachTerm::Xterm256Color,
            false,
        );

        assert!(!retry_term);
        assert_eq!(
            diagnostic.as_deref(),
            Some("session identity changed immediately before attachment; refresh and try again")
        );
    }

    #[test]
    fn application_attachment_failure_stays_on_the_wsl_host() {
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        publish_attachment_failure(
            &workspace.inner,
            0,
            WorkspaceError::new("attachment launch failed"),
        );

        let snapshot = workspace.snapshot();
        assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
        let host = &snapshot.hosts()[0];
        assert_eq!(host.connection(), HostConnectionState::Unavailable);
        assert_eq!(
            host.diagnostic().map(HostDiagnostic::message),
            Some("attachment launch failed")
        );
    }

    #[test]
    fn stale_attachment_failure_cannot_overwrite_a_newer_host_refresh() {
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));
        let newer_generation = begin_refresh(
            &workspace.inner,
            &CancellationToken::new(),
            RefreshPresentation::Connecting,
        );
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "stale".to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        publish_attachment_failure(
            &workspace.inner,
            newer_generation - 1,
            WorkspaceError::new("stale attachment failure"),
        );

        let snapshot = workspace.snapshot();
        assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
        let host = &snapshot.hosts()[0];
        assert_eq!(host.connection(), HostConnectionState::Connecting);
        assert_eq!(host.diagnostic(), None);
    }

    #[test]
    fn stale_attachment_refreshes_inventory_without_disabling_the_host() {
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let config = WslConfig::with_distro("Ubuntu").expect("valid config");
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
        );
        let host = WslHost::new(
            config,
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            executable,
        );
        let original = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "work",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        );
        *workspace
            .inner
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
            HostContext {
                host,
                snapshot: original,
            },
            0,
        ));
        set_inventory_state(
            &workspace.inner,
            WorkspaceContent::Ready {
                endpoint: "Ubuntu".to_owned(),
                sessions: vec![SessionItem::new("work", 0)],
            },
        );
        let request = capture_attach_request(
            &workspace.inner,
            &SessionSelection::new("wsl", "Ubuntu", "work"),
        )
        .expect("attach request");
        let replacement = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "other",
                session::SessionIdentity::new(100, "$2", 201),
                0,
            )],
        );

        publish_stale_attachment_failure(
            &workspace.inner,
            &request,
            replacement,
            &WorkspaceError::new("session no longer exists"),
        );

        let snapshot = workspace.snapshot();
        assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
        let host = &snapshot.hosts()[0];
        assert_eq!(host.connection(), HostConnectionState::Ready);
        assert_eq!(host.sessions(), &[SessionItem::new("other", 0)]);
        assert_eq!(snapshot.notice(), Some("session no longer exists"));
    }

    #[test]
    fn retained_stale_failure_preserves_the_visible_terminal_and_pending_input() {
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let config = WslConfig::with_distro("Ubuntu").expect("valid config");
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
        );
        let host = WslHost::new(
            config,
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            executable,
        );
        let original = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "hidden",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        );
        *workspace
            .inner
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
            HostContext {
                host,
                snapshot: original,
            },
            0,
        ));
        let request = capture_attach_request(
            &workspace.inner,
            &SessionSelection::new("wsl", "Ubuntu", "hidden"),
        )
        .expect("hidden attach request");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "visible".to_owned(),
                kind: SessionKind::Tmux,
                presentation_id: 9,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
                    1,
                    GridSize::new(80, 24).expect("valid grid"),
                ))),
            },
        );
        *workspace.inner.pending_paste.lock().expect("pending paste") = Some(PendingPaste {
            worker_generation: 7,
            input: input::encode_input(
                &KeyInput::paste("pending\ninput"),
                input::TerminalModes::default(),
            ),
        });
        let replacement = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());

        publish_retained_stale_failure(
            &workspace.inner,
            &request,
            replacement,
            &WorkspaceError::new("hidden session changed"),
        );

        let snapshot = workspace.snapshot();
        assert!(matches!(
            snapshot.content(),
            WorkspaceContent::Terminal { session, presentation_id, .. }
                if session == "visible" && *presentation_id == 9
        ));
        assert!(
            workspace
                .inner
                .pending_paste
                .lock()
                .expect("pending paste")
                .is_some()
        );
        assert_eq!(snapshot.notice(), Some("hidden session changed"));
        assert!(snapshot.hosts()[0].sessions().is_empty());
    }

    #[test]
    fn legacy_attachment_failure_remains_top_level() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));

        publish_attachment_failure(
            &workspace.inner,
            0,
            WorkspaceError::new("legacy attachment failed"),
        );

        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Error { message } if message == "legacy attachment failed"
        ));
    }

    #[test]
    fn terminal_output_that_only_contains_the_marker_is_not_an_attach_mismatch() {
        let output = format!("shell output: {}\r\n", session::IDENTITY_MISMATCH_MARKER);

        let (retry_term, diagnostic) =
            classify_terminal_exit_event(0, &output, AttachTerm::Xterm256Color, false);

        assert!(!retry_term);
        assert_eq!(diagnostic, None);
    }

    #[test]
    fn initial_exact_terminfo_failure_retries_with_xterm() {
        let (retry_term, diagnostic) = classify_terminal_exit_event(
            1,
            "missing or unsuitable terminal: xterm-256color\r\n",
            AttachTerm::Xterm256Color,
            false,
        );

        assert!(retry_term);
        assert_eq!(diagnostic, None);
    }

    #[cfg(windows)]
    #[test]
    fn hidden_unconfirmed_client_keeps_its_identity_and_fallback_during_terminfo_retry() {
        let host = WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let request = AttachRequest {
            host_id: "wsl".to_owned(),
            host,
            endpoint: snapshot.endpoint().clone(),
            runtime: snapshot.runtime().clone(),
            target: AttachTarget::Tmux(identity.clone()),
            name: "replacement".to_owned(),
            inventory_generation: 1,
        };
        let key = request.presentation_key();
        let fallback = FallbackAuthority {
            presentation: PresentationKey {
                target: AttachTarget::Tmux(session::SessionIdentity::new(100, "$2", 201)),
                ..key.clone()
            },
            target: key.clone(),
            navigation_generation: 7,
        };
        let mut retained = RetainedPresentations::new();
        retained.insert(RetainedPresentation {
            key: key.clone(),
            selection: SessionSelection::new("wsl", "Ubuntu", "replacement"),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: Some(fallback.clone()),
            },
            worker: (),
            presentation_id: 7,
        });
        let mut emitted = Vec::new();
        let mut retries = Vec::new();

        retained.handle_exit(
            0,
            1,
            "missing or unsuitable terminal: xterm-256color\r\n",
            false,
            &mut emitted,
            &mut retries,
        );

        let retry = retries.pop().expect("retained xterm retry");

        assert!(emitted.is_empty());
        assert_eq!(retry.key, key);
        assert!(retained.contains(&key));
        assert_eq!(retained.selections()[0].session(), "replacement");
        assert_eq!(retained.restarting[0].attachment.term, AttachTerm::Xterm);
        assert_eq!(
            retained.restarting[0].attachment.fallback.as_ref(),
            Some(&fallback)
        );

        let mut restored_attachment = AttachmentState::new();
        let rebound_fallback = FallbackAuthority {
            presentation: fallback.presentation.clone(),
            target: fallback.target.clone(),
            navigation_generation: 8,
        };
        let restored_generation = reserve_retained_attachment(
            &mut restored_attachment,
            &retained.restarting[0].attachment,
            Some(rebound_fallback.clone()),
        )
        .expect("reactivate retained attachment");
        let mut restored_worker = WorkerState::new();
        let worker_generation = restored_worker.publish(());
        let fallback_after_reactivation =
            restored_attachment.fallback_if_current(restored_generation);

        assert!(claim_terminal_exit(
            &mut restored_attachment,
            &mut restored_worker,
            restored_generation,
            worker_generation,
            false,
        ));
        assert_eq!(fallback_after_reactivation, Some(rebound_fallback));
    }

    #[cfg(windows)]
    #[test]
    fn retained_terminfo_retry_resolves_a_renamed_session_by_identity() {
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let original_snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let request = attach_request_fixture(&original_snapshot, identity.clone(), "original");
        let key = request.presentation_key();
        let retry = RetainedRetry {
            key: key.clone(),
            request: request.clone(),
        };
        let renamed_snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new("renamed", identity, 0)],
        );
        let resolved_request = resolve_retained_retry_request(&retry, &renamed_snapshot)
            .expect("stable retained identity survives a rename");
        let mut retained = RetainedPresentations::new();
        retained.restarting.push(RetainedRestart {
            key: key.clone(),
            selection: SessionSelection::new("wsl", "Ubuntu", "original"),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm,
                generation: 1,
                fallback: None,
            },
            presentation_id: 7,
        });

        assert_eq!(resolved_request.name, "renamed");
        assert!(retained.finish_restart(&key, (), &retry.request.name, &resolved_request));
        assert_eq!(retained.entries[0].selection.session(), "renamed");
        assert_eq!(retained.entries[0].attachment.request.name, "renamed");
    }

    #[cfg(windows)]
    #[test]
    fn retained_terminfo_retry_preserves_herdr_selection_kind() {
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let request = herdr_attach_request_fixture(&snapshot, "original");
        let key = request.presentation_key();
        let mut resolved_request = request.clone();
        resolved_request.name = "renamed".to_owned();
        let mut retained = RetainedPresentations::new();
        retained.restarting.push(RetainedRestart {
            key: key.clone(),
            selection: SessionSelection::herdr("wsl", "Ubuntu", "original"),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm,
                generation: 1,
                fallback: None,
            },
            presentation_id: 7,
        });

        assert!(retained.finish_restart(&key, (), "original", &resolved_request));
        assert_eq!(retained.entries[0].selection.kind(), SessionKind::Herdr);
        assert_eq!(retained.entries[0].selection.session(), "renamed");
        assert_eq!(
            retained.entries[0].attachment.request.selection().kind(),
            SessionKind::Herdr
        );
    }

    #[test]
    fn presentation_identity_survives_rename_but_not_a_wsl_runtime_restart() {
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let original = presentation_key_fixture("boot-a", 42, identity.clone());
        let renamed = presentation_key_fixture("boot-a", 42, identity.clone());
        let restarted = presentation_key_fixture("boot-b", 7, identity);

        assert_eq!(original, renamed);
        assert_ne!(original, restarted);
    }

    #[cfg(windows)]
    #[test]
    fn current_inventory_identity_wins_over_a_same_name_retained_session() {
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let stale = attach_request_fixture(
            &snapshot,
            session::SessionIdentity::new(100, "$1", 200),
            "demo",
        );
        let current = attach_request_fixture(
            &snapshot,
            session::SessionIdentity::new(100, "$2", 201),
            "demo",
        );

        let (selected, request) =
            choose_navigation_target(Some(stale.presentation_key()), Ok(current.clone()))
                .expect("current session remains selectable");

        assert_eq!(selected, current.presentation_key());
        assert_eq!(request.map(|request| request.target), Some(current.target));
    }

    #[cfg(windows)]
    #[test]
    fn inventory_rename_updates_the_retained_display_name_without_changing_its_key() {
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let original_snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "original",
                identity.clone(),
                0,
            )],
        );
        let request = attach_request_fixture(&original_snapshot, identity.clone(), "original");
        let key = request.presentation_key();
        let mut retained = RetainedPresentations::new();
        retained.insert(RetainedPresentation {
            key: key.clone(),
            selection: SessionSelection::new("wsl", "Ubuntu", "original"),
            attachment: ActiveAttachment {
                request: request.clone(),
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            worker: (),
            presentation_id: 7,
        });
        let stale_activation_key = retained
            .key_for_selection(&SessionSelection::new("wsl", "Ubuntu", "original"))
            .expect("stale caller captured retained identity");
        let renamed_snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new("renamed", identity, 0)],
        );

        assert!(retained.reconcile_session_names(&renamed_snapshot, None));

        assert!(retained.contains(&key));
        assert_eq!(retained.selections()[0].session(), "renamed");
        assert_eq!(retained.entries[0].attachment.request.name, "renamed");
        assert_eq!(
            retained.key_for_selection(&SessionSelection::new("wsl", "Ubuntu", "renamed")),
            Some(key.clone())
        );
        let activated = retained
            .take(&stale_activation_key)
            .expect("identity remains activatable after rename");
        assert_eq!(activated.selection.session(), "renamed");
        assert_eq!(activated.attachment.request.name, "renamed");

        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        *workspace.inner.host.lock().expect("host") = Some(Published::new(
            HostContext {
                host: request.host.clone(),
                snapshot: renamed_snapshot.clone(),
            },
            2,
        ));
        assert_eq!(
            current_inventory_session_name(&workspace.inner, &key).as_deref(),
            Some("renamed")
        );
        workspace
            .inner
            .attachment
            .lock()
            .expect("attachment")
            .reserve(request, AttachTerm::Xterm256Color)
            .expect("reserve visible attachment");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "original".to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        reconcile_presentation_session_names(&workspace.inner, 0, &renamed_snapshot, None);

        assert_eq!(
            workspace
                .inner
                .attachment
                .lock()
                .expect("attachment")
                .active()
                .expect("visible attachment")
                .request
                .name,
            "renamed"
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Attaching { session, .. } if session == "renamed"
        ));
    }

    #[cfg(windows)]
    #[test]
    fn inventory_rename_preserves_a_retained_herdr_selection() {
        let original_snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let request = herdr_attach_request_fixture(&original_snapshot, "original");
        let key = request.presentation_key();
        let mut retained = RetainedPresentations::new();
        retained.insert(RetainedPresentation {
            key: key.clone(),
            selection: request.selection(),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            worker: (),
            presentation_id: 7,
        });
        let renamed_snapshot = HostSnapshot::test_fixture_with_herdr(
            "Ubuntu",
            "boot-id",
            42,
            Vec::new(),
            HerdrInventory::Available {
                executable: "/opt/herdr/bin/herdr".to_owned(),
                sessions: vec![session::HerdrSessionRecord::new(
                    "renamed",
                    false,
                    HerdrSessionState::Running,
                    "/tmp/herdr/review",
                    "/tmp/herdr/review/herdr.sock",
                )],
            },
        );

        assert!(retained.reconcile_session_names(&renamed_snapshot, None));

        assert!(retained.contains(&key));
        assert_eq!(retained.entries[0].selection.kind(), SessionKind::Herdr);
        assert_eq!(retained.entries[0].selection.session(), "renamed");
        assert_eq!(
            retained.key_for_selection(&SessionSelection::herdr("wsl", "Ubuntu", "renamed")),
            Some(key)
        );
    }

    #[cfg(windows)]
    #[test]
    fn retained_rename_advances_the_workspace_revision_once() {
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let original_snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "original",
                identity.clone(),
                0,
            )],
        );
        let request = attach_request_fixture(&original_snapshot, identity.clone(), "original");
        let renamed_snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new("renamed", identity, 0)],
        );
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        workspace
            .inner
            .retained_presentations
            .lock()
            .expect("retained presentations")
            .restarting
            .push(RetainedRestart {
                key: request.presentation_key(),
                selection: SessionSelection::new("wsl", "Ubuntu", "original"),
                attachment: ActiveAttachment {
                    request,
                    term: AttachTerm::Xterm256Color,
                    generation: 1,
                    fallback: None,
                },
                presentation_id: 7,
            });
        let revision = workspace.snapshot().revision();

        reconcile_retained_session_names(&workspace.inner, &renamed_snapshot, None);
        let renamed = workspace.snapshot();

        assert_eq!(renamed.revision(), revision + 1);
        assert_eq!(renamed.retained_selections()[0].session(), "renamed");

        reconcile_retained_session_names(&workspace.inner, &renamed_snapshot, None);
        assert_eq!(workspace.snapshot().revision(), renamed.revision());
    }

    #[cfg(windows)]
    #[test]
    fn detach_invalidates_fallback_authority_before_an_async_failure() {
        let host = WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let request = AttachRequest {
            host_id: "wsl".to_owned(),
            host,
            endpoint: snapshot.endpoint().clone(),
            runtime: snapshot.runtime().clone(),
            target: AttachTarget::Tmux(session::SessionIdentity::new(100, "$1", 200)),
            name: "replacement".to_owned(),
            inventory_generation: 1,
        };
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let navigation_generation = workspace.begin_navigation();
        let fallback = FallbackAuthority {
            presentation: presentation_key_fixture(
                "boot-id",
                42,
                session::SessionIdentity::new(100, "$2", 201),
            ),
            target: request.presentation_key(),
            navigation_generation,
        };
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "replacement".to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        assert!(fallback_owns_request(&workspace.inner, &fallback, &request));
        workspace.detach();
        assert!(!fallback_owns_request(
            &workspace.inner,
            &fallback,
            &request
        ));
    }

    #[cfg(windows)]
    #[test]
    fn failed_attachment_context_uses_stable_identity_after_name_reconciliation() {
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let request = attach_request_fixture(
            &snapshot,
            session::SessionIdentity::new(100, "$1", 200),
            "original",
        );
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let navigation_generation = workspace.begin_navigation();
        let mut fallback = fallback_fixture(
            "boot-id",
            42,
            session::SessionIdentity::new(100, "$2", 201),
            navigation_generation,
        );
        fallback.target = request.presentation_key();
        let generation = workspace
            .inner
            .attachment
            .lock()
            .expect("attachment")
            .reserve_with_fallback(request, AttachTerm::Xterm256Color, Some(fallback.clone()))
            .expect("reserve attachment");
        {
            let mut attachment = workspace.inner.attachment.lock().expect("attachment");
            attachment
                .active_mut()
                .expect("active attachment")
                .request
                .name = "renamed".to_owned();
        }
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "original".to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        let attachment = workspace.inner.attachment.lock().expect("attachment");
        let (failed_request, restored_fallback) =
            failed_attachment_context(&workspace.inner, &attachment, generation)
                .expect("current failure context");

        assert_eq!(failed_request.name, "renamed");
        assert_eq!(restored_fallback, Some(fallback));
    }

    #[test]
    fn terminfo_retry_unpublishes_terminal_and_preserves_session_kind() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let workspace = Workspace::preview(WorkspaceSnapshot {
            revision: 1,
            appearance: Appearance::default(),
            content: WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
                kind: SessionKind::Tmux,
                presentation_id: 7,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
            },
            hosts: Vec::new(),
            selected_host: None,
            notice: None,
            retained_selections: Vec::new(),
        });
        *workspace.inner.pending_paste.lock().expect("pending paste") = Some(PendingPaste {
            worker_generation: 1,
            input: input::encode_input(
                &KeyInput::paste("first\nsecond"),
                input::TerminalModes::default(),
            ),
        });

        publish_terminfo_retry_boundary(
            &workspace.inner,
            "wsl",
            "Ubuntu",
            "work",
            SessionKind::Herdr,
        );

        assert!(
            workspace
                .inner
                .pending_paste
                .lock()
                .expect("pending paste")
                .is_none()
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Attaching { host_id, endpoint, session, kind, .. }
                if host_id == "wsl"
                    && endpoint == "Ubuntu"
                    && session == "work"
                    && *kind == SessionKind::Herdr
        ));
        assert_eq!(next_presentation_id(&workspace.inner), 8);
    }

    #[test]
    fn successful_xterm_fallback_notice_persists_until_detach() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));

        set_terminal_notice(&workspace.inner, AttachTerm::Xterm);

        assert_eq!(workspace.snapshot().notice(), Some(REDUCED_COLOR_NOTICE));
        workspace.detach();
        assert_eq!(workspace.snapshot().notice(), None);
    }

    #[test]
    fn established_client_exit_never_uses_terminfo_fallback() {
        let (retry_term, diagnostic) = classify_terminal_exit_event(
            1,
            "missing or unsuitable terminal: xterm-256color\r\n",
            AttachTerm::Xterm256Color,
            true,
        );

        assert!(!retry_term);
        assert_eq!(
            diagnostic.as_deref(),
            Some("tmux client exited with status 1")
        );
    }

    #[test]
    fn pane_output_containing_terminfo_text_is_not_a_startup_failure() {
        let (retry_term, diagnostic) = classify_terminal_exit_event(
            1,
            "previous pane output\r\nmissing or unsuitable terminal: xterm-256color\r\n",
            AttachTerm::Xterm256Color,
            false,
        );

        assert!(!retry_term);
        assert_eq!(
            diagnostic.as_deref(),
            Some("tmux client exited with status 1")
        );
    }

    #[test]
    fn captured_host_generation_cannot_overwrite_a_later_refresh() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let context_generation = workspace.inner.refresh_generation.load(Ordering::Acquire);
        let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
        let host = WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            runner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute system WSL path"),
        );
        let snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "work",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        );
        *workspace
            .inner
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
            HostContext { host, snapshot },
            context_generation,
        ));
        *workspace
            .inner
            .selected_host
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some("wsl".to_owned());
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
                kind: SessionKind::Tmux,
                presentation_id: 1,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
                    1,
                    GridSize::new(80, 24).expect("valid grid"),
                ))),
            },
        );

        let refresh_generation = begin_refresh(
            &workspace.inner,
            &CancellationToken::new(),
            RefreshPresentation::Connecting,
        );
        let request = capture_attach_request(
            &workspace.inner,
            &SessionSelection::new("wsl", "Ubuntu", "work"),
        )
        .expect("capture request");
        assert_eq!(request.inventory_generation, context_generation);
        assert!(refresh_generation > request.inventory_generation);
        assert!(publish_refresh(
            &workspace.inner,
            refresh_generation,
            || set_inventory_state(
                &workspace.inner,
                WorkspaceContent::Ready {
                    endpoint: "Ubuntu".to_owned(),
                    sessions: vec![SessionItem::new("newer", 0)],
                },
            )
        ));
        assert!(!publish_refresh(
            &workspace.inner,
            request.inventory_generation,
            || set_inventory_state(
                &workspace.inner,
                WorkspaceContent::Ready {
                    endpoint: "Ubuntu".to_owned(),
                    sessions: vec![SessionItem::new("stale", 0)],
                },
            )
        ));

        workspace.restore_inventory_state();

        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.len() == 1 && sessions[0].name() == "newer"
        ));
    }

    #[test]
    fn created_session_is_resolved_by_client_identity_not_requested_name() {
        let client_identity = session::SessionIdentity::new(100, "$1", 200);
        let snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![
                session::DiscoveredSession::new(
                    "requested",
                    session::SessionIdentity::new(100, "$2", 201),
                    0,
                ),
                session::DiscoveredSession::new("renamed-by-hook", client_identity.clone(), 1),
            ],
        );

        let created = created_session(&snapshot, &client_identity).expect("client session");

        assert_eq!(created.name(), "renamed-by-hook");
        assert_eq!(created.identity(), &client_identity);
    }

    #[test]
    fn creation_identity_report_gets_a_bounded_startup_width() {
        let narrow = TerminalGeometry {
            grid: GridSize::new(20, 12).expect("valid narrow grid"),
            pixels: PixelSize::new(200, 240),
            sequence: 7,
        };

        let launch = creation_launch_geometry(narrow);

        assert_eq!(launch.grid.columns(), CREATE_IDENTITY_MIN_COLUMNS);
        assert_eq!(launch.grid.rows(), narrow.grid.rows());
        assert_eq!(launch.pixels, narrow.pixels);
        assert_eq!(launch.sequence, narrow.sequence);
        assert_eq!(
            creation_launch_geometry(launch),
            launch,
            "already-wide grids are unchanged"
        );
    }

    #[test]
    fn post_create_inventory_cannot_overwrite_a_newer_refresh() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
        let runtime_host = WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            runner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute system WSL path"),
        );
        let initial_generation = workspace.inner.refresh_generation.load(Ordering::Acquire);
        let initial_snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "before",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        );
        *workspace.inner.host.lock().expect("host context") = Some(Published::new(
            HostContext {
                host: runtime_host.clone(),
                snapshot: initial_snapshot.clone(),
            },
            initial_generation,
        ));
        let request = CreateRequest {
            host_id: "wsl".to_owned(),
            host: runtime_host.clone(),
            endpoint: initial_snapshot.endpoint().clone(),
            runtime: initial_snapshot.runtime().clone(),
            name: SessionName::parse("created").expect("valid name"),
        };

        let operation_generation = reserve_constructive_inventory(&workspace.inner);
        let refresh_generation = begin_refresh(
            &workspace.inner,
            &CancellationToken::new(),
            RefreshPresentation::Connecting,
        );
        let refreshed = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "refreshed",
                session::SessionIdentity::new(100, "$2", 201),
                0,
            )],
        );
        assert!(publish_refresh(
            &workspace.inner,
            refresh_generation,
            || {
                *workspace.inner.host.lock().expect("host context") = Some(Published::new(
                    HostContext {
                        host: runtime_host,
                        snapshot: refreshed,
                    },
                    refresh_generation,
                ));
            }
        ));
        let created = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "created",
                session::SessionIdentity::new(100, "$3", 202),
                1,
            )],
        );

        let merged =
            merge_created_inventory(&workspace.inner, &request, created, operation_generation);

        assert!(merged.is_err());
        let host = workspace.inner.host.lock().expect("host context");
        let published = host.as_ref().expect("published host");
        assert_eq!(published.generation, refresh_generation);
        assert_eq!(published.value.snapshot.sessions()[0].name(), "refreshed");
    }

    #[test]
    fn post_create_inventory_supersedes_an_inflight_refresh() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
        let runtime_host = WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            runner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute system WSL path"),
        );
        let initial_generation = workspace.inner.refresh_generation.load(Ordering::Acquire);
        let initial_snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "before",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        );
        *workspace.inner.host.lock().expect("host context") = Some(Published::new(
            HostContext {
                host: runtime_host.clone(),
                snapshot: initial_snapshot.clone(),
            },
            initial_generation,
        ));
        let request = CreateRequest {
            host_id: "wsl".to_owned(),
            host: runtime_host,
            endpoint: initial_snapshot.endpoint().clone(),
            runtime: initial_snapshot.runtime().clone(),
            name: SessionName::parse("created").expect("valid name"),
        };
        let cancellation = CancellationToken::new();
        let refresh_generation = begin_refresh(
            &workspace.inner,
            &cancellation,
            RefreshPresentation::Connecting,
        );
        let operation_generation = reserve_constructive_inventory(&workspace.inner);
        let created = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "created",
                session::SessionIdentity::new(100, "$2", 201),
                1,
            )],
        );

        let merged =
            merge_created_inventory(&workspace.inner, &request, created, operation_generation)
                .expect("merge post-create inventory");

        assert_eq!(merged, operation_generation);
        assert!(merged > refresh_generation);
        assert!(cancellation.is_cancelled());
        assert!(!publish_refresh(
            &workspace.inner,
            refresh_generation,
            || panic!("superseded refresh must not publish")
        ));
        let host = workspace.inner.host.lock().expect("host context");
        let published = host.as_ref().expect("published host");
        assert_eq!(published.generation, merged);
        assert_eq!(published.value.snapshot.sessions()[0].name(), "created");
    }

    #[test]
    fn failed_herdr_restart_during_refresh_restores_cached_ready_host() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let navigation_generation = workspace.begin_navigation();
        let operation_cancellation = CancellationToken::new();
        let refresh_cancellation = CancellationToken::new();
        let refresh_generation = begin_refresh(
            &workspace.inner,
            &refresh_cancellation,
            RefreshPresentation::Connecting,
        );
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Connecting
        );

        let operation_generation = reserve_current_constructive_inventory(
            &workspace.inner,
            navigation_generation,
            &operation_cancellation,
        )
        .expect("current restart reserves inventory publication");
        assert!(operation_generation > refresh_generation);
        assert!(refresh_cancellation.is_cancelled());

        settle_constructive_inventory(&workspace.inner, operation_generation);

        let snapshot = workspace.snapshot();
        let host = &snapshot.hosts()[0];
        assert_eq!(host.connection(), HostConnectionState::Ready);
        assert_eq!(host.sessions()[0].name(), "work");
        assert_eq!(host.herdr_sessions().len(), 2);
    }

    #[test]
    fn stale_or_cancelled_herdr_restart_cannot_cancel_a_newer_refresh() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let queued_navigation = workspace.begin_navigation();
        let cancelled = CancellationToken::new();
        cancelled.cancel();
        let refresh_cancellation = CancellationToken::new();
        let refresh_generation = begin_refresh(
            &workspace.inner,
            &refresh_cancellation,
            RefreshPresentation::Connecting,
        );

        assert_eq!(
            reserve_current_constructive_inventory(&workspace.inner, queued_navigation, &cancelled,),
            None
        );
        let active = CancellationToken::new();
        workspace.begin_navigation();
        assert_eq!(
            reserve_current_constructive_inventory(&workspace.inner, queued_navigation, &active,),
            None
        );

        assert!(!refresh_cancellation.is_cancelled());
        assert_eq!(
            workspace.inner.refresh_generation.load(Ordering::Acquire),
            refresh_generation
        );
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Connecting
        );
    }

    #[test]
    fn stale_refresh_cannot_overwrite_a_newer_ready_generation() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "preview",
            Vec::new(),
        ));
        let reserved = Arc::new(Barrier::new(2));
        let resume = Arc::new(Barrier::new(2));
        let old_workspace = workspace.clone();
        let old_reserved = Arc::clone(&reserved);
        let old_resume = Arc::clone(&resume);
        let old = thread::spawn(move || {
            let cancellation = CancellationToken::new();
            let generation = reserve_refresh(&old_workspace.inner, &cancellation);
            old_reserved.wait();
            old_resume.wait();
            let published = publish_refresh(&old_workspace.inner, generation, || {
                set_inner_state(&old_workspace.inner, WorkspaceContent::Loading);
            });
            (generation, cancellation, published)
        });

        reserved.wait();
        let current_cancellation = CancellationToken::new();
        let current_generation = begin_refresh(
            &workspace.inner,
            &current_cancellation,
            RefreshPresentation::Connecting,
        );
        assert!(publish_refresh(
            &workspace.inner,
            current_generation,
            || set_inner_state(
                &workspace.inner,
                WorkspaceContent::Ready {
                    endpoint: "current".to_owned(),
                    sessions: Vec::new(),
                },
            )
        ));
        resume.wait();
        let (old_generation, old_cancellation, old_published) =
            old.join().expect("stale refresh thread");

        assert!(old_cancellation.is_cancelled());
        assert!(!old_published);
        assert!(current_generation > old_generation);
        assert_eq!(
            workspace.inner.refresh_generation.load(Ordering::Acquire),
            current_generation
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { endpoint, .. } if endpoint == "current"
        ));
    }

    #[test]
    fn stale_retry_rejects_detach_followed_by_a_new_attachment() {
        let attachment = Arc::new(Mutex::new(AttachmentState::new()));
        let old_generation = attachment
            .lock()
            .expect("attachment lock")
            .reserve("old", AttachTerm::Xterm256Color)
            .expect("reserve old attachment");
        let exit_captured = Arc::new(Barrier::new(2));
        let retry_resumed = Arc::new(Barrier::new(2));
        let old_attachment = Arc::clone(&attachment);
        let old_exit_captured = Arc::clone(&exit_captured);
        let old_retry_resumed = Arc::clone(&retry_resumed);
        let old_retry = thread::spawn(move || {
            old_exit_captured.wait();
            old_retry_resumed.wait();
            old_attachment
                .lock()
                .expect("attachment lock")
                .promote_if_current(old_generation, AttachTerm::Xterm)
        });

        exit_captured.wait();
        {
            let mut attachment = attachment.lock().expect("attachment lock");
            attachment.invalidate();
            attachment
                .reserve("new", AttachTerm::Xterm256Color)
                .expect("reserve new attachment");
        }
        retry_resumed.wait();

        assert!(!old_retry.join().expect("stale retry thread"));
        let attachment = attachment.lock().expect("attachment lock");
        let active = attachment.active().expect("new attachment remains active");
        assert_eq!(active.request, "new");
        assert_eq!(active.term, AttachTerm::Xterm256Color);
    }

    #[test]
    fn stale_spawn_failure_cannot_clear_a_new_attachment() {
        let attachment = Arc::new(Mutex::new(AttachmentState::new()));
        let old_generation = attachment
            .lock()
            .expect("attachment lock")
            .reserve("old", AttachTerm::Xterm256Color)
            .expect("reserve old attachment");
        let failure_observed = Arc::new(Barrier::new(2));
        let cleanup_resumed = Arc::new(Barrier::new(2));
        let old_attachment = Arc::clone(&attachment);
        let old_failure_observed = Arc::clone(&failure_observed);
        let old_cleanup_resumed = Arc::clone(&cleanup_resumed);
        let old_cleanup = thread::spawn(move || {
            old_failure_observed.wait();
            old_cleanup_resumed.wait();
            old_attachment
                .lock()
                .expect("attachment lock")
                .clear_if_current(old_generation)
        });

        failure_observed.wait();
        {
            let mut attachment = attachment.lock().expect("attachment lock");
            attachment.invalidate();
            attachment
                .reserve("new", AttachTerm::Xterm256Color)
                .expect("reserve new attachment");
        }
        cleanup_resumed.wait();

        assert!(!old_cleanup.join().expect("stale cleanup thread"));
        assert_eq!(
            attachment
                .lock()
                .expect("attachment lock")
                .active()
                .expect("new attachment remains active")
                .request,
            "new"
        );
    }

    #[test]
    fn worker_publication_and_generation_are_captured_atomically() {
        let worker = Arc::new(Mutex::new(WorkerState::new()));
        worker.lock().expect("worker lock").publish("old");
        let drain_ready = Arc::new(Barrier::new(2));
        let drain_resumed = Arc::new(Barrier::new(2));
        let draining_worker = Arc::clone(&worker);
        let draining_ready = Arc::clone(&drain_ready);
        let draining_resumed = Arc::clone(&drain_resumed);
        let drain = thread::spawn(move || {
            draining_ready.wait();
            draining_resumed.wait();
            let worker = draining_worker.lock().expect("worker lock");
            worker
                .active_with_generation()
                .map(|(worker, generation)| (*worker, generation))
        });

        drain_ready.wait();
        let published_generation = worker.lock().expect("worker lock").publish("new");
        drain_resumed.wait();

        assert_eq!(
            drain.join().expect("drain thread"),
            Some(("new", published_generation))
        );
    }

    #[test]
    fn worker_publication_applies_geometry_that_changed_during_launch() {
        let initial = default_terminal_geometry();
        let latest = TerminalGeometry {
            grid: GridSize::new(132, 43).expect("valid grid"),
            pixels: PixelSize::new(1_320, 860),
            sequence: initial.sequence + 1,
        };
        let geometry = Mutex::new(latest);
        let workers = Mutex::new(WorkerState::new());
        let applied = Mutex::new(None);

        let generation = publish_worker_at_latest_geometry(
            &geometry,
            &workers,
            "client",
            initial,
            |_, geometry| {
                *applied.lock().expect("applied geometry lock") = Some(geometry);
                Ok::<(), ()>(())
            },
        )
        .expect("publish worker");

        assert_eq!(
            *applied.lock().expect("applied geometry lock"),
            Some(latest)
        );
        assert_eq!(
            workers
                .lock()
                .expect("worker lock")
                .active_with_generation(),
            Some((&"client", generation))
        );
    }

    #[test]
    fn worker_publication_holds_geometry_until_worker_is_visible() {
        let initial = default_terminal_geometry();
        let latest = TerminalGeometry {
            sequence: initial.sequence + 1,
            ..initial
        };
        let geometry = Arc::new(Mutex::new(latest));
        let workers = Arc::new(Mutex::new(WorkerState::new()));
        let (locked_sender, locked_receiver) = std::sync::mpsc::channel();
        let (release_sender, release_receiver) = std::sync::mpsc::channel();
        let publishing_geometry = Arc::clone(&geometry);
        let publishing_workers = Arc::clone(&workers);
        let publisher = thread::spawn(move || {
            publish_worker_at_latest_geometry(
                &publishing_geometry,
                &publishing_workers,
                "client",
                initial,
                |_, _| {
                    locked_sender.send(()).expect("signal held locks");
                    release_receiver.recv().expect("resume publication");
                    Ok::<(), ()>(())
                },
            )
            .expect("publish worker")
        });

        locked_receiver.recv().expect("publication reached resize");
        let geometry_was_locked = geometry.try_lock().is_err();
        let worker_was_locked = workers.try_lock().is_err();
        release_sender.send(()).expect("release publication");
        let _generation = publisher.join().expect("publisher thread");

        assert!(geometry_was_locked, "geometry lock was released too early");
        assert!(worker_was_locked, "worker lock was released too early");
    }

    #[test]
    fn replacement_fallback_survives_publication_until_the_client_is_confirmed() {
        let fallback = fallback_fixture(
            "boot-id",
            42,
            session::SessionIdentity::new(100, "$1", 200),
            1,
        );
        let mut attachment = AttachmentState::new();
        let attachment_generation = attachment
            .reserve_with_fallback(
                "replacement",
                AttachTerm::Xterm256Color,
                Some(fallback.clone()),
            )
            .expect("reserve replacement attachment");
        let mut worker = WorkerState::new();
        let worker_generation = worker.publish("replacement client");

        let fallback_for_exit = attachment.fallback_if_current(attachment_generation);
        assert_eq!(
            fallback_for_exit,
            Some(fallback.clone()),
            "publishing the replacement must not consume its fallback"
        );

        assert!(claim_terminal_exit(
            &mut attachment,
            &mut worker,
            attachment_generation,
            worker_generation,
            false,
        ));
        assert_eq!(fallback_for_exit, Some(fallback));
    }

    #[test]
    fn confirmed_replacement_releases_its_fallback() {
        let fallback = fallback_fixture(
            "boot-id",
            42,
            session::SessionIdentity::new(100, "$1", 200),
            1,
        );
        let mut attachment = AttachmentState::new();
        let generation = attachment
            .reserve_with_fallback("replacement", AttachTerm::Xterm256Color, Some(fallback))
            .expect("reserve replacement attachment");

        assert!(attachment.confirm_if_current(generation));
        assert_eq!(attachment.fallback_if_current(generation), None);
    }

    #[test]
    fn duplicate_exit_claim_cannot_invalidate_the_retry_worker() {
        let attachment = Arc::new(Mutex::new(AttachmentState::new()));
        let attachment_generation = attachment
            .lock()
            .expect("attachment lock")
            .reserve("request", AttachTerm::Xterm256Color)
            .expect("reserve attachment");
        let worker = Arc::new(Mutex::new(WorkerState::new()));
        let worker_generation = worker.lock().expect("worker lock").publish("client");
        let exit_claimed = Arc::new(Barrier::new(2));

        let exiting_attachment = Arc::clone(&attachment);
        let exiting_worker = Arc::clone(&worker);
        let exiting_claimed = Arc::clone(&exit_claimed);
        let exit = thread::spawn(move || {
            let mut attachment = exiting_attachment.lock().expect("attachment lock");
            let mut worker = exiting_worker.lock().expect("worker lock");
            let claimed = claim_terminal_exit(
                &mut attachment,
                &mut worker,
                attachment_generation,
                worker_generation,
                true,
            );
            exiting_claimed.wait();
            claimed
        });

        let disconnected_attachment = Arc::clone(&attachment);
        let disconnected_worker = Arc::clone(&worker);
        let disconnect = thread::spawn(move || {
            exit_claimed.wait();
            let mut attachment = disconnected_attachment.lock().expect("attachment lock");
            let mut worker = disconnected_worker.lock().expect("worker lock");
            claim_terminal_exit(
                &mut attachment,
                &mut worker,
                attachment_generation,
                worker_generation,
                false,
            )
        });

        assert!(exit.join().expect("exit drain"));
        assert!(!disconnect.join().expect("disconnect drain"));
        assert!(
            attachment
                .lock()
                .expect("attachment lock")
                .is_current(attachment_generation)
        );
        assert!(worker.lock().expect("worker lock").active().is_none());
    }

    #[test]
    fn received_exit_is_claimed_before_a_competing_disconnect() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "test",
            Vec::new(),
        ));
        let attachment = Arc::new(Mutex::new(AttachmentState::new()));
        let attachment_generation = attachment
            .lock()
            .expect("attachment lock")
            .reserve("request", AttachTerm::Xterm256Color)
            .expect("reserve attachment");
        let worker = Arc::new(Mutex::new(WorkerState::new()));
        let worker_generation = worker.lock().expect("worker lock").publish("client");
        let (exit_received_tx, exit_received_rx) = std::sync::mpsc::channel();
        let (disconnect_waiting_tx, disconnect_waiting_rx) = std::sync::mpsc::channel();
        let allow_exit_claim = Arc::new(Barrier::new(2));

        let exiting_inner = Arc::clone(&workspace.inner);
        let exiting_attachment = Arc::clone(&attachment);
        let exiting_worker = Arc::clone(&worker);
        let exiting_allow_claim = Arc::clone(&allow_exit_claim);
        let exit = thread::spawn(move || {
            let _drain = exiting_inner.event_drain.lock().expect("event drain lock");
            exit_received_tx.send(()).expect("signal exit received");
            exiting_allow_claim.wait();
            let mut attachment = exiting_attachment.lock().expect("attachment lock");
            let mut worker = exiting_worker.lock().expect("worker lock");
            claim_terminal_exit(
                &mut attachment,
                &mut worker,
                attachment_generation,
                worker_generation,
                true,
            )
        });

        let disconnected_inner = Arc::clone(&workspace.inner);
        let disconnected_attachment = Arc::clone(&attachment);
        let disconnected_worker = Arc::clone(&worker);
        let disconnect = thread::spawn(move || {
            exit_received_rx.recv().expect("wait for exit event");
            disconnect_waiting_tx
                .send(())
                .expect("signal disconnect waiting");
            let _drain = disconnected_inner
                .event_drain
                .lock()
                .expect("event drain lock");
            let mut attachment = disconnected_attachment.lock().expect("attachment lock");
            let mut worker = disconnected_worker.lock().expect("worker lock");
            claim_terminal_exit(
                &mut attachment,
                &mut worker,
                attachment_generation,
                worker_generation,
                false,
            )
        });

        disconnect_waiting_rx
            .recv()
            .expect("wait for disconnect contender");
        allow_exit_claim.wait();

        assert!(exit.join().expect("exit drain"));
        assert!(!disconnect.join().expect("disconnect drain"));
        assert!(
            attachment
                .lock()
                .expect("attachment lock")
                .is_current(attachment_generation)
        );
    }

    #[test]
    fn inventory_refresh_does_not_replace_an_active_terminal() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let size = GridSize::new(80, 24).expect("valid grid");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
                kind: SessionKind::Tmux,
                presentation_id: 1,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
            },
        );
        let revision = workspace.snapshot().revision();

        set_inventory_state(
            &workspace.inner,
            WorkspaceContent::Ready {
                endpoint: "Ubuntu".to_owned(),
                sessions: vec![SessionItem::new("other", 0)],
            },
        );

        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "work"
        ));
        assert_eq!(workspace.snapshot().revision(), revision);

        workspace.restore_inventory_state();

        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.len() == 1 && sessions[0].name() == "other"
        ));
    }

    #[test]
    fn switching_to_the_active_session_is_a_no_op() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let size = GridSize::new(80, 24).expect("valid grid");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
                kind: SessionKind::Tmux,
                presentation_id: 1,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
            },
        );

        workspace
            .switch_session(&SessionSelection::new("wsl", "Ubuntu", "work"))
            .expect("active session remains selected");

        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "work"
        ));

        assert!(
            workspace
                .switch_session(&SessionSelection::new("wsl", "Debian", "work"))
                .is_err(),
            "an equal name on a different endpoint is not the active selection"
        );
    }

    #[test]
    fn a_different_selection_supersedes_an_inflight_attachment_and_carries_its_fallback() {
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let config = WslConfig::with_distro("Ubuntu").expect("valid config");
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
        );
        let host = WslHost::new(
            config,
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            executable,
        );
        let snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![
                session::DiscoveredSession::new(
                    "opening",
                    session::SessionIdentity::new(100, "$1", 200),
                    0,
                ),
                session::DiscoveredSession::new(
                    "selected",
                    session::SessionIdentity::new(100, "$2", 201),
                    0,
                ),
            ],
        );
        *workspace
            .inner
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
            HostContext {
                host,
                snapshot: snapshot.clone(),
            },
            0,
        ));
        set_inventory_state(&workspace.inner, ready_content(&snapshot));
        let opening = captured_request(&workspace, "opening");
        let selected = captured_request(&workspace, "selected");
        let opening_navigation = workspace.begin_navigation();
        let mut fallback = fallback_fixture(
            "boot-id",
            42,
            session::SessionIdentity::new(100, "$3", 202),
            opening_navigation,
        );
        fallback.target = opening.presentation_key();
        workspace
            .inner
            .attachment
            .lock()
            .expect("attachment")
            .reserve_with_fallback(opening, AttachTerm::Xterm256Color, Some(fallback.clone()))
            .expect("reserve opening attachment");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "opening".to_owned(),
                kind: SessionKind::Tmux,
            },
        );
        let carried_fallback = workspace
            .supersede_inflight_attachment()
            .expect("supersede opening attachment");
        let selected_navigation = workspace.begin_navigation();
        let carried_fallback = carried_fallback.map(|presentation| FallbackAuthority {
            presentation,
            target: selected.presentation_key(),
            navigation_generation: selected_navigation,
        });
        let selected_generation = workspace
            .inner
            .attachment
            .lock()
            .expect("attachment")
            .reserve_with_fallback(selected, AttachTerm::Xterm256Color, carried_fallback)
            .expect("reserve selected attachment");
        let attachment = workspace.inner.attachment.lock().expect("attachment");
        let active = attachment.active().expect("selected attachment active");
        assert_eq!(
            attachment.fallback_if_current(selected_generation).as_ref(),
            Some(&FallbackAuthority {
                presentation: fallback.presentation,
                target: active.request.presentation_key(),
                navigation_generation: selected_navigation,
            })
        );
    }

    #[test]
    fn switching_sessions_cancels_pending_creation_and_restores_inventory() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            vec![SessionItem::new("selected", 0)],
        ));
        let creation_navigation = workspace.begin_navigation();
        let cancellation = CancellationToken::new();
        *workspace
            .inner
            .pending_creation
            .lock()
            .expect("pending creation") = Some(PendingCreation {
            navigation_generation: creation_navigation,
            previous: None,
            cancellation: cancellation.clone(),
            herdr_operation: None,
        });
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "creating".to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        let _switch_navigation = workspace.begin_navigation();
        let fallback = workspace
            .supersede_inflight_attachment()
            .expect("switch supersedes pending creation");

        assert_eq!(fallback, None);
        assert!(cancellation.is_cancelled());
        assert!(
            workspace
                .inner
                .pending_creation
                .lock()
                .expect("pending creation")
                .is_none()
        );
        restore_inventory_after_creation_failure(
            &workspace.inner,
            None,
            creation_navigation,
            "stale creation failure".to_owned(),
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "selected")
        ));
        assert_eq!(workspace.snapshot().notice(), None);
    }

    #[test]
    fn detaching_during_creation_cancels_the_task_and_restores_inventory() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            vec![SessionItem::new("existing", 0)],
        ));
        let creation_navigation = workspace.begin_navigation();
        let cancellation = CancellationToken::new();
        *workspace
            .inner
            .pending_creation
            .lock()
            .expect("pending creation") = Some(PendingCreation {
            navigation_generation: creation_navigation,
            previous: None,
            cancellation: cancellation.clone(),
            herdr_operation: None,
        });
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "creating".to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        workspace.detach();

        assert!(cancellation.is_cancelled());
        assert!(
            workspace
                .inner
                .pending_creation
                .lock()
                .expect("pending creation")
                .is_none()
        );
        restore_inventory_after_creation_failure(
            &workspace.inner,
            None,
            creation_navigation,
            "stale creation failure".to_owned(),
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "existing")
        ));
        assert_eq!(workspace.snapshot().notice(), None);
    }

    #[cfg(windows)]
    #[test]
    fn stale_kill_identity_results_cannot_publish_confirmation() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let host = WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let pending = |generation| PendingKill {
            generation,
            selection: SessionSelection::new("wsl", "Ubuntu", "work"),
            host: host.clone(),
            target: KillTarget::Tmux(Arc::new(LiveSessionTarget::test_fixture(
                &snapshot,
                "work",
                session::SessionIdentity::new(100, "$1", 200),
            ))),
        };

        workspace.inner.kill_generation.store(2, Ordering::Release);
        assert!(!publish_pending_kill(&workspace.inner, pending(1)));
        assert_eq!(workspace.session_kill_confirmation(), None);

        workspace.inner.kill_generation.store(3, Ordering::Release);
        assert!(publish_pending_kill(&workspace.inner, pending(3)));
        assert!(workspace.session_kill_confirmation().is_some());
        workspace
            .request_session_kill(&SessionSelection::new("wsl", "Ubuntu", "missing"))
            .expect_err("new invalid request still supersedes old confirmation");
        assert_eq!(workspace.session_kill_confirmation(), None);
    }

    #[test]
    fn invalid_switch_target_does_not_detach_the_active_session() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let size = GridSize::new(80, 24).expect("valid grid");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
                kind: SessionKind::Tmux,
                presentation_id: 1,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
            },
        );

        assert!(
            workspace
                .switch_session(&SessionSelection::new("wsl", "Ubuntu", "missing"))
                .is_err()
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "work"
        ));
    }

    #[cfg(windows)]
    #[test]
    fn killed_presentation_cleanup_never_detaches_a_different_active_session() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let killed_identity = session::SessionIdentity::new(100, "$1", 200);
        let active_identity = session::SessionIdentity::new(100, "$2", 201);
        let active_request = attach_request_fixture(&snapshot, active_identity.clone(), "active");
        workspace
            .inner
            .attachment
            .lock()
            .expect("attachment")
            .reserve(active_request, AttachTerm::Xterm256Color)
            .expect("reserve active attachment");
        let size = GridSize::new(80, 24).expect("valid grid");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "active".to_owned(),
                kind: SessionKind::Tmux,
                presentation_id: 1,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
            },
        );

        workspace.finish_killed_presentation(
            snapshot.endpoint(),
            snapshot.runtime(),
            &killed_identity,
        );

        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "active"
        ));
        assert_eq!(
            workspace
                .inner
                .attachment
                .lock()
                .expect("attachment")
                .active()
                .expect("active attachment")
                .request
                .target,
            AttachTarget::Tmux(active_identity)
        );
    }

    #[cfg(windows)]
    #[test]
    fn zellij_kill_suppression_keeps_active_recovery_authority() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let request = zellij_attach_request_fixture(&snapshot, "work");
        workspace
            .inner
            .attachment
            .lock()
            .expect("attachment")
            .reserve(request, AttachTerm::Xterm256Color)
            .expect("reserve active attachment");
        let size = GridSize::new(80, 24).expect("valid grid");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
                kind: SessionKind::Zellij,
                presentation_id: 1,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
            },
        );

        let suppressed = workspace
            .close_zellij_presentations(snapshot.endpoint(), snapshot.runtime(), "work")
            .expect("matching presentation is recoverable");

        assert_eq!(
            suppressed.active_selection,
            Some(SessionSelection::zellij("wsl", "Ubuntu", "work"))
        );
        assert!(
            workspace
                .inner
                .attachment
                .lock()
                .expect("attachment")
                .active()
                .is_none()
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { .. }
        ));
    }

    #[test]
    fn refresh_failure_is_deferred_until_the_terminal_closes() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        let size = GridSize::new(80, 24).expect("valid grid");
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
                kind: SessionKind::Tmux,
                presentation_id: 1,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
            },
        );

        set_inventory_state(
            &workspace.inner,
            WorkspaceContent::Error {
                message: "WSL is unavailable".to_owned(),
            },
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { .. }
        ));

        workspace.restore_inventory_state();

        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Error { message } if message == "WSL is unavailable"
        ));
    }

    #[test]
    fn refresh_budgets_distinguish_cold_start_from_retry() {
        assert_eq!(refresh_budget(1), Duration::from_secs(45));
        assert_eq!(refresh_budget(2), Duration::from_secs(30));
    }

    #[test]
    fn blocked_host_discovery_does_not_block_snapshot_reads() {
        let snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot",
            42,
            vec![session::DiscoveredSession::new(
                "work",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        );
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let discovery = Arc::new(BlockingDiscovery {
            snapshot,
            entered: Mutex::new(Some(entered_tx)),
            release: Mutex::new(release_rx),
        });
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(spec),
            discovery,
            Arc::new(ThreadRefreshRuntime),
        );
        workspace.connect_enabled_hosts().expect("start refresh");
        entered_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("discovery reached blocking host read");

        let snapshot_workspace = workspace.clone();
        let (snapshot_tx, snapshot_rx) = mpsc::sync_channel(1);
        let snapshot_reader = thread::spawn(move || {
            let snapshot = snapshot_workspace.snapshot();
            snapshot_tx
                .send(snapshot.hosts()[0].connection())
                .expect("publish snapshot result");
        });
        let connection = snapshot_rx
            .recv_timeout(Duration::from_millis(250))
            .expect("snapshot remains responsive during host I/O");
        assert_eq!(connection, HostConnectionState::Connecting);

        release_tx.send(()).expect("release host discovery");
        snapshot_reader.join().expect("snapshot reader");
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while workspace.snapshot().hosts()[0].connection() != HostConnectionState::Ready
            && std::time::Instant::now() < deadline
        {
            thread::yield_now();
        }
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Ready
        );
    }

    #[test]
    fn refresh_deadlines_and_retry_order_are_manually_driven() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
            "Ubuntu",
            "boot",
            42,
            vec![session::DiscoveredSession::new(
                "work",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        )));
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(spec),
            discovery,
            runtime.clone(),
        );

        workspace.connect_enabled_hosts().expect("start refresh");
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Connecting
        );
        assert_eq!(runtime.deadline_delays(), vec![Duration::from_secs(45)]);

        runtime.run_next_deadline();
        assert_eq!(
            workspace.snapshot().hosts()[0]
                .diagnostic()
                .expect("timeout diagnostic")
                .kind(),
            DiagnosticKind::Timeout
        );

        set_inner_state(&workspace.inner, WorkspaceContent::Shell);
        workspace.refresh().expect("start retry");
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Shell
        ));
        assert_eq!(runtime.deadline_delays(), vec![Duration::from_secs(30)]);
        runtime.run_next_work();
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Connecting
        );
        runtime.run_next_work();

        let snapshot = workspace.snapshot();
        assert_eq!(snapshot.hosts()[0].connection(), HostConnectionState::Ready);
        assert_eq!(snapshot.hosts()[0].sessions()[0].name(), "work");

        runtime.run_next_deadline();
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Ready
        );
    }

    fn herdr_workspace_with_sessions(
        herdr_sessions: Vec<session::HerdrSessionRecord>,
    ) -> (Workspace, Arc<ManualRefreshRuntime>) {
        herdr_workspace_with_sessions_and_term(herdr_sessions, AttachTerm::Xterm256Color)
    }

    fn herdr_workspace_with_sessions_and_term(
        herdr_sessions: Vec<session::HerdrSessionRecord>,
        term: AttachTerm,
    ) -> (Workspace, Arc<ManualRefreshRuntime>) {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let snapshot = HostSnapshot::test_fixture_with_herdr(
            "Ubuntu",
            "boot",
            42,
            vec![session::DiscoveredSession::new(
                "work",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
            HerdrInventory::Available {
                executable: "/opt/herdr/bin/herdr".to_owned(),
                sessions: herdr_sessions,
            },
        )
        .test_fixture_with_creation_term(term);
        let discovery = Arc::new(FixedDiscovery::new(snapshot));
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(spec),
            discovery,
            runtime.clone(),
        );

        workspace.connect_enabled_hosts().expect("start refresh");
        runtime.run_next_work();
        (workspace, runtime)
    }

    fn herdr_workspace_fixture() -> (Workspace, Arc<ManualRefreshRuntime>) {
        herdr_workspace_with_sessions(vec![
            session::HerdrSessionRecord::new(
                "default",
                true,
                HerdrSessionState::Running,
                "/tmp/herdr/default",
                "/tmp/herdr/default/herdr.sock",
            ),
            session::HerdrSessionRecord::new(
                "review",
                false,
                HerdrSessionState::Stopped,
                "/tmp/herdr/review",
                "/tmp/herdr/review/herdr.sock",
            ),
        ])
    }

    #[test]
    fn successful_refresh_projects_herdr_without_changing_tmux_readiness() {
        let (workspace, _runtime) = herdr_workspace_fixture();

        let snapshot = workspace.snapshot();
        let host = &snapshot.hosts()[0];
        assert_eq!(host.connection(), HostConnectionState::Ready);
        assert_eq!(host.sessions()[0].name(), "work");
        assert!(host.herdr_available());
        assert_eq!(host.herdr_sessions().len(), 2);
        assert!(host.herdr_sessions()[0].is_default());
        assert_eq!(host.herdr_sessions()[1].state(), HerdrSessionState::Stopped);
        assert!(host.herdr_diagnostic().is_none());
    }

    #[test]
    fn herdr_constructive_requests_use_the_admitted_terminal_capability() {
        let (workspace, _runtime) = herdr_workspace_with_sessions_and_term(
            vec![session::HerdrSessionRecord::new(
                "review",
                false,
                HerdrSessionState::Stopped,
                "/tmp/herdr/review",
                "/tmp/herdr/review/herdr.sock",
            )],
            AttachTerm::Xterm,
        );

        let created = capture_herdr_create_request(
            &workspace.inner,
            "wsl",
            "Ubuntu",
            HerdrSessionName::parse("created").expect("valid name"),
        )
        .expect("capture creation");
        let restarted = capture_herdr_restart_request(
            &workspace.inner,
            &SessionSelection::herdr("wsl", "Ubuntu", "review"),
        )
        .expect("capture restart");

        assert_eq!(created.term, AttachTerm::Xterm);
        assert_eq!(restarted.term, AttachTerm::Xterm);
    }

    #[test]
    fn unavailable_hosts_reject_herdr_mutations_and_preserve_confirmation() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
        workspace
            .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
            .expect("prepare stop while ready");
        workspace
            .inner
            .hosts
            .write()
            .expect("hosts")
            .iter_mut()
            .find(|host| host.id == "wsl")
            .expect("WSL host")
            .connection = HostConnectionState::Unavailable;

        let error = workspace
            .confirm_herdr_lifecycle()
            .expect_err("unavailable host must block confirmed mutation");
        assert!(error.to_string().contains("connect the WSL host"));
        assert!(workspace.herdr_lifecycle_confirmation().is_some());

        let stopped = SessionSelection::herdr("wsl", "Ubuntu", "review");
        assert!(workspace.restart_herdr_session(&stopped).is_err());
        workspace.cancel_herdr_lifecycle();
        assert!(
            workspace
                .request_herdr_lifecycle(&stopped, HerdrLifecycleAction::Delete)
                .is_err()
        );
    }

    #[test]
    fn in_flight_herdr_lifecycle_is_visible_and_rejects_duplicates() {
        let (workspace, _runtime) = herdr_workspace_fixture();

        let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
        workspace
            .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
            .expect("running session may be stopped");
        assert_eq!(
            workspace
                .herdr_lifecycle_confirmation()
                .expect("stop confirmation")
                .action(),
            HerdrLifecycleAction::Stop
        );
        let stop_generation = {
            let mut lifecycle = workspace
                .inner
                .herdr_lifecycle
                .lock()
                .expect("lifecycle state");
            let pending = lifecycle.pending.take().expect("pending stop");
            assert!(lifecycle.start(&pending));
            pending.generation
        };
        assert_eq!(
            workspace.snapshot().hosts()[0].herdr_sessions()[0].lifecycle_action(),
            Some(HerdrLifecycleAction::Stop)
        );
        assert!(
            workspace
                .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
                .is_err(),
            "a duplicate lifecycle action is rejected while Stop is in flight"
        );
        workspace
            .inner
            .herdr_lifecycle
            .lock()
            .expect("lifecycle state")
            .finish(stop_generation);
        assert_eq!(
            workspace.snapshot().hosts()[0].herdr_sessions()[0].lifecycle_action(),
            None
        );

        let stopped = SessionSelection::herdr("wsl", "Ubuntu", "review");
        let restart = capture_herdr_restart_request(&workspace.inner, &stopped)
            .expect("stopped session may restart");
        assert!(matches!(
            restart.precondition,
            HerdrLaunchPrecondition::Stopped(record) if record.name() == "review"
        ));
        workspace
            .request_herdr_lifecycle(&stopped, HerdrLifecycleAction::Delete)
            .expect("stopped named session may be deleted");
        assert_eq!(
            workspace
                .herdr_lifecycle_confirmation()
                .expect("delete confirmation")
                .action(),
            HerdrLifecycleAction::Delete
        );
    }

    #[test]
    fn pending_herdr_launch_is_visible_and_rejects_duplicate_operations() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let stopped = SessionSelection::herdr("wsl", "Ubuntu", "review");
        let request = capture_herdr_restart_request(&workspace.inner, &stopped)
            .expect("stopped session may restart");
        let key = request.operation_key();

        assert!(
            workspace
                .inner
                .herdr_lifecycle
                .lock()
                .expect("lifecycle state")
                .reserve_launch(&key)
        );

        let snapshot = workspace.snapshot();
        let review = snapshot.hosts()[0]
            .herdr_sessions()
            .iter()
            .find(|session| session.name() == "review")
            .expect("review session");
        assert!(review.launch_pending());
        assert!(
            !workspace
                .inner
                .herdr_lifecycle
                .lock()
                .expect("lifecycle state")
                .reserve_launch(&key)
        );
        assert!(
            workspace
                .switch_session(&stopped)
                .expect_err("a pending restart blocks presentation changes")
                .to_string()
                .contains("already starting")
        );
        assert!(
            workspace
                .request_herdr_lifecycle(&stopped, HerdrLifecycleAction::Delete)
                .expect_err("lifecycle mutation is blocked while restart is pending")
                .to_string()
                .contains("still starting")
        );

        finish_herdr_launch(&workspace.inner, &key);
        assert!(!workspace.snapshot().hosts()[0].herdr_sessions()[1].launch_pending());
    }

    #[test]
    fn failed_herdr_inventory_blocks_fresh_and_mutating_actions() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        set_herdr_inventory(
            &workspace.inner,
            &HerdrInventory::Failed(
                WslExecutable::from_absolute("wsl.exe").expect_err("relative path is rejected"),
            ),
        );

        let create = capture_herdr_create_request(
            &workspace.inner,
            "wsl",
            "Ubuntu",
            HerdrSessionName::parse("created").expect("valid name"),
        )
        .err()
        .expect("failed inventory blocks creation");
        assert!(create.to_string().contains("refresh Herdr inventory"));

        let stopped = SessionSelection::herdr("wsl", "Ubuntu", "review");
        let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
        assert!(
            workspace
                .switch_session(&running)
                .expect_err("failed inventory blocks a fresh open")
                .to_string()
                .contains("refresh Herdr inventory")
        );
        assert!(
            capture_herdr_restart_request(&workspace.inner, &stopped)
                .err()
                .expect("failed inventory blocks restart")
                .to_string()
                .contains("refresh Herdr inventory")
        );
        assert!(
            workspace
                .request_herdr_lifecycle(&stopped, HerdrLifecycleAction::Delete)
                .expect_err("failed inventory blocks mutation")
                .to_string()
                .contains("refresh Herdr inventory")
        );
    }

    fn assert_inconclusive_inventory_keeps_lifecycle_fenced(
        workspace: &Workspace,
        fresh: &HostSnapshot,
        reconciliation_floor: u64,
    ) {
        assert!(
            !reconcile_herdr_lifecycle_fences(&workspace.inner, fresh, reconciliation_floor, true,)
                .changed
        );
        let failed = HostSnapshot::test_fixture_with_herdr(
            "Ubuntu",
            "boot",
            42,
            Vec::new(),
            HerdrInventory::Failed(
                WslExecutable::from_absolute("wsl.exe").expect_err("relative path is rejected"),
            ),
        );
        assert!(
            !reconcile_herdr_lifecycle_fences(
                &workspace.inner,
                &failed,
                reconciliation_floor + 1,
                true,
            )
            .changed
        );
        let unavailable_after_restart = HostSnapshot::test_fixture_with_herdr(
            "Ubuntu",
            "restarted-boot",
            84,
            Vec::new(),
            HerdrInventory::Unavailable,
        );
        assert!(
            !reconcile_herdr_lifecycle_fences(
                &workspace.inner,
                &unavailable_after_restart,
                reconciliation_floor + 2,
                true,
            )
            .changed
        );
    }

    #[test]
    fn uncertain_lifecycle_stays_fenced_until_fresh_inventory_arrives() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
        workspace
            .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
            .expect("running session may be stopped");
        let pending = {
            let mut lifecycle = workspace
                .inner
                .herdr_lifecycle
                .lock()
                .expect("lifecycle state");
            let pending = lifecycle.pending.take().expect("pending stop");
            assert!(lifecycle.start(&pending));
            pending
        };

        publish_herdr_lifecycle_uncertain(
            &workspace.inner,
            &pending,
            Some(SuppressedHerdrPresentation {
                active_selection: Some(running.clone()),
                retained: None,
                navigation_generation: workspace
                    .inner
                    .navigation_generation
                    .load(Ordering::Acquire),
            }),
            "could not reconcile the stopped session",
        );

        let uncertain = workspace.snapshot();
        let host = &uncertain.hosts()[0];
        assert_eq!(
            host.herdr_sessions()[0].lifecycle_action(),
            Some(HerdrLifecycleAction::Stop)
        );
        assert!(host.herdr_diagnostic().is_some());

        let fresh = workspace
            .inner
            .host
            .lock()
            .expect("host context")
            .as_ref()
            .expect("published host")
            .value
            .snapshot
            .clone();
        let reconciliation_floor = workspace.inner.refresh_generation.load(Ordering::Acquire);
        assert_inconclusive_inventory_keeps_lifecycle_fenced(
            &workspace,
            &fresh,
            reconciliation_floor,
        );
        let deferred = reconcile_herdr_lifecycle_fences(
            &workspace.inner,
            &fresh,
            reconciliation_floor + 3,
            false,
        );
        assert!(!deferred.changed);
        assert!(deferred.recoveries.is_empty());
        let mut reconciled_recovery = reconcile_herdr_lifecycle_fences(
            &workspace.inner,
            &fresh,
            reconciliation_floor + 4,
            true,
        );
        assert!(reconciled_recovery.changed);
        assert_eq!(reconciled_recovery.recoveries.len(), 1);
        assert_eq!(
            reconciled_recovery
                .recoveries
                .pop()
                .and_then(|recovery| recovery.active_selection),
            Some(running),
        );
        set_herdr_inventory(&workspace.inner, fresh.herdr());
        workspace.inner.revision.fetch_add(1, Ordering::Release);

        let reconciled = workspace.snapshot();
        let host = &reconciled.hosts()[0];
        assert_eq!(host.herdr_sessions()[0].lifecycle_action(), None);
        assert!(host.herdr_diagnostic().is_none());
    }

    #[test]
    fn ordinary_refresh_cannot_reconcile_an_active_lifecycle_operation() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
        workspace
            .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
            .expect("running session may be stopped");
        {
            let mut lifecycle = workspace
                .inner
                .herdr_lifecycle
                .lock()
                .expect("lifecycle state");
            let pending = lifecycle.pending.take().expect("pending stop");
            assert!(lifecycle.start(&pending));
        }
        let snapshot = workspace
            .inner
            .host
            .lock()
            .expect("host context")
            .as_ref()
            .expect("published host")
            .value
            .snapshot
            .clone();

        assert!(
            !reconcile_herdr_lifecycle_fences(&workspace.inner, &snapshot, u64::MAX, true).changed
        );
        assert_eq!(
            workspace.snapshot().hosts()[0].herdr_sessions()[0].lifecycle_action(),
            Some(HerdrLifecycleAction::Stop),
        );
    }

    #[test]
    fn stop_preparation_removes_every_matching_retained_client() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let selection = SessionSelection::herdr("wsl", "Ubuntu", "default");
        let request = capture_attach_request(&workspace.inner, &selection)
            .expect("running Herdr session is attachable");
        let key = request.presentation_key();
        let attachment = |generation| ActiveAttachment {
            request: request.clone(),
            term: AttachTerm::Xterm256Color,
            generation,
            fallback: None,
        };
        let mut retained = RetainedPresentations::new();
        retained.insert(RetainedPresentation {
            key: key.clone(),
            selection: selection.clone(),
            attachment: attachment(1),
            worker: 1_u8,
            presentation_id: 1,
        });
        retained.entries.push(RetainedPresentation {
            key: key.clone(),
            selection,
            attachment: attachment(2),
            worker: 2_u8,
            presentation_id: 2,
        });

        let removed = retained.take_matching(|candidate| candidate == &key);

        assert_eq!(removed.len(), 2);
        assert!(!retained.contains(&key));
    }

    #[test]
    fn fresh_inventory_supersedes_a_synthetic_lifecycle_response() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
        workspace
            .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
            .expect("running session may be stopped");
        let pending = workspace
            .inner
            .herdr_lifecycle
            .lock()
            .expect("lifecycle state")
            .pending
            .clone()
            .expect("pending stop");
        let stopped = session::HerdrSessionRecord::new(
            "default",
            true,
            HerdrSessionState::Stopped,
            "/tmp/herdr/default",
            "/tmp/herdr/default/herdr.sock",
        );
        let before = workspace
            .inner
            .host
            .lock()
            .expect("host context")
            .as_ref()
            .expect("published host")
            .value
            .snapshot
            .clone();
        assert!(!herdr_lifecycle_is_reflected(&before, &pending));

        publish_herdr_lifecycle_response(&workspace.inner, &pending, stopped)
            .expect("authoritative response publishes");

        let snapshot = workspace.snapshot();
        let host = &snapshot.hosts()[0];
        assert_eq!(host.sessions()[0].name(), "work");
        assert_eq!(host.herdr_sessions()[0].state(), HerdrSessionState::Stopped);
        let published = workspace
            .inner
            .host
            .lock()
            .expect("host context")
            .as_ref()
            .expect("published host")
            .value
            .snapshot
            .clone();
        assert!(herdr_lifecycle_is_reflected(&published, &pending));

        let fresh_generation = reserve_constructive_inventory(&workspace.inner);
        merge_herdr_lifecycle_inventory(
            &workspace.inner,
            &pending,
            before.clone(),
            fresh_generation,
        )
        .expect("fresh contradictory inventory publishes");
        assert!(!herdr_lifecycle_is_reflected(&before, &pending));
        assert_eq!(
            workspace.snapshot().hosts()[0].herdr_sessions()[0].state(),
            HerdrSessionState::Running,
        );
    }

    #[test]
    fn restart_preserves_an_authoritative_name_outside_the_creation_subset() {
        let name = "review session";
        let (workspace, _runtime) =
            herdr_workspace_with_sessions(vec![session::HerdrSessionRecord::new(
                name,
                false,
                HerdrSessionState::Stopped,
                "/tmp/herdr/review session",
                "/tmp/herdr/review session/herdr.sock",
            )]);

        let request = capture_herdr_restart_request(
            &workspace.inner,
            &SessionSelection::herdr("wsl", "Ubuntu", name),
        )
        .expect("discovered session names remain restartable");

        assert_eq!(request.name.as_str(), name);
        assert!(matches!(
            request.precondition,
            HerdrLaunchPrecondition::Stopped(record) if record.name() == name
        ));
    }

    #[test]
    fn restart_rejects_a_session_whose_default_role_changed() {
        let expected = session::HerdrSessionRecord::new(
            "review",
            false,
            HerdrSessionState::Stopped,
            "/tmp/herdr/review",
            "/tmp/herdr/review/herdr.sock",
        );
        let current = session::HerdrSessionRecord::new(
            "review",
            true,
            HerdrSessionState::Stopped,
            "/tmp/herdr/review",
            "/tmp/herdr/review/herdr.sock",
        );

        assert!(
            validate_herdr_launch_precondition(
                &HerdrLaunchPrecondition::Stopped(expected),
                Some(&current),
            )
            .is_err()
        );
    }

    #[test]
    fn restart_result_rejects_a_same_named_replacement() {
        let expected = session::HerdrSessionRecord::new(
            "review",
            false,
            HerdrSessionState::Stopped,
            "/tmp/herdr/review",
            "/tmp/herdr/review/herdr.sock",
        );
        let replacement = session::HerdrSessionRecord::new(
            "review",
            false,
            HerdrSessionState::Running,
            "/tmp/herdr/replacement",
            "/tmp/herdr/replacement/herdr.sock",
        );

        assert!(!herdr_launch_result_matches(
            &HerdrLaunchPrecondition::Stopped(expected),
            "review",
            &replacement,
        ));
    }

    #[test]
    fn herdr_startup_polling_accepts_a_session_after_early_misses() {
        let cancellation = CancellationToken::new();
        let mut probes = 0;

        let result = poll_session_startup(
            "Herdr",
            &cancellation,
            &[Duration::ZERO; 6],
            || -> Result<Option<&'static str>, WorkspaceError> {
                probes += 1;
                Ok((probes == 6).then_some("running"))
            },
        )
        .expect("polling succeeds");

        assert_eq!(result, Some("running"));
        assert_eq!(probes, 6);
    }

    #[test]
    fn herdr_refresh_failure_preserves_cached_rows() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::wsl(
                "Ubuntu",
                None,
                HostConnectionState::Ready,
                Vec::new(),
                None,
            )],
        ));
        set_herdr_inventory(
            &workspace.inner,
            &HerdrInventory::Available {
                executable: "/opt/herdr/bin/herdr".to_owned(),
                sessions: vec![session::HerdrSessionRecord::new(
                    "review",
                    false,
                    HerdrSessionState::Running,
                    "/tmp/herdr/review",
                    "/tmp/herdr/review/herdr.sock",
                )],
            },
        );
        set_herdr_inventory(
            &workspace.inner,
            &HerdrInventory::Failed(
                WslExecutable::from_absolute("wsl.exe").expect_err("relative path is rejected"),
            ),
        );

        let snapshot = workspace.snapshot();
        let host = &snapshot.hosts()[0];
        assert!(host.herdr_available());
        assert_eq!(host.herdr_sessions()[0].name(), "review");
        assert_eq!(
            host.herdr_diagnostic().expect("scoped diagnostic").kind(),
            DiagnosticKind::MalformedOutput
        );
    }

    #[test]
    fn zellij_refresh_failure_preserves_cached_rows() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::wsl(
                "Ubuntu",
                None,
                HostConnectionState::Ready,
                Vec::new(),
                None,
            )],
        ));
        set_zellij_inventory(
            &workspace.inner,
            &ZellijInventory::Available {
                executable: "/opt/zellij/bin/zellij".to_owned(),
                sessions: vec![session::ZellijSessionRecord::discovered("review")],
            },
        );
        set_zellij_inventory(
            &workspace.inner,
            &ZellijInventory::Failed(
                WslExecutable::from_absolute("wsl.exe").expect_err("relative path is rejected"),
            ),
        );

        let snapshot = workspace.snapshot();
        let host = &snapshot.hosts()[0];
        assert!(host.zellij_available());
        assert_eq!(host.zellij_sessions()[0].name(), "review");
        assert_eq!(
            host.zellij_diagnostic().expect("scoped diagnostic").kind(),
            DiagnosticKind::MalformedOutput
        );
    }

    #[test]
    fn host_refresh_keeps_cached_multiplexer_rows_visible() {
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));
        {
            let mut hosts = workspace.inner.hosts.write().expect("hosts");
            let host = &mut hosts[0];
            host.connection = HostConnectionState::Ready;
            host.sessions = vec![SessionItem::new("tmux-work", 0)];
            host.herdr_available = true;
            host.herdr_sessions = vec![HerdrSessionItem::new(
                "herdr-work",
                false,
                HerdrSessionState::Running,
            )];
            host.zellij_available = true;
            host.zellij_sessions = vec![SessionItem::new("zellij-work", 0)];
        }

        begin_refresh(
            &workspace.inner,
            &CancellationToken::new(),
            RefreshPresentation::Connecting,
        );

        let snapshot = workspace.snapshot();
        assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
        let host = &snapshot.hosts()[0];
        assert_eq!(host.connection(), HostConnectionState::Connecting);
        assert_eq!(host.sessions()[0].name(), "tmux-work");
        assert_eq!(host.herdr_sessions()[0].name(), "herdr-work");
        assert_eq!(host.zellij_sessions()[0].name(), "zellij-work");
    }

    #[test]
    fn kwt_inventory_projects_worktrees_without_replacing_session_state() {
        let bundle =
            host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
        let config = WslConfig::with_distro("Ubuntu")
            .expect("valid config")
            .with_kwt_bundle(bundle);
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
        );
        let snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot",
            42,
            vec![session::DiscoveredSession::new(
                "project-main",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        );
        let runtime_host = WslHost::new(
            config,
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            executable,
        );
        *workspace.inner.host.lock().expect("published host") = Some(Published::new(
            HostContext {
                host: runtime_host,
                snapshot: snapshot.clone(),
            },
            1,
        ));
        set_inventory_state(&workspace.inner, ready_content(&snapshot));
        workspace
            .inner
            .kwt_refresh_generation
            .store(7, Ordering::Release);
        let inventory = KwtInventory::parse(
            br#"[{"repository":"project-id","name":"project","path":"/repos/project","last_touched":null,"registration_fingerprint":"project-fingerprint"}]"#,
            br#"[{"path":"/repos/project","branch":"main","commit_hash":"abc","is_main":true,"created_at":null,"generation":"g1","repository":"project-id","session_name":"project-main","tmux_socket_name":null}]"#,
            br#"[{"name":"scratch","path":"/work/scratch","session_name":"scratch","session_live":false}]"#,
        )
        .expect("valid KWT inventory");

        publish_kwt_inventory(
            &workspace.inner,
            7,
            snapshot.endpoint(),
            snapshot.runtime(),
            &inventory,
        );

        let projected = workspace.snapshot();
        assert!(matches!(projected.content(), WorkspaceContent::Shell));
        let host = &projected.hosts()[0];
        assert!(host.kwt_available());
        assert_eq!(host.projects()[0].name(), "project");
        assert_eq!(host.projects()[0].worktrees()[0].branch(), "main");
        assert!(host.projects()[0].worktrees()[0].session_available());
        assert_eq!(host.directory_workspaces()[0].name(), "scratch");
        assert!(!host.directory_workspaces()[0].session_available());

        set_inventory_state(
            &workspace.inner,
            WorkspaceContent::Ready {
                endpoint: "Ubuntu".to_owned(),
                sessions: Vec::new(),
            },
        );
        let refreshed = workspace.snapshot();
        assert_eq!(refreshed.hosts()[0].projects().len(), 1);
        assert!(
            !refreshed.hosts()[0].projects()[0].worktrees()[0].session_available(),
            "the fast tmux refresh reconciles availability without rerunning KWT"
        );

        workspace
            .inner
            .kwt_mutation_in_flight
            .store(true, Ordering::Release);
        assert!(
            !start_kwt_refresh(&workspace.inner, true),
            "inventory reads cannot supersede a project mutation"
        );
        {
            let mut hosts = workspace.inner.hosts.write().expect("hosts");
            hosts[0].kwt_state = KwtState::Mutating;
        }
        publish_kwt_mutation_failure(&workspace.inner, 7, snapshot.endpoint(), snapshot.runtime());
        finish_kwt_project_mutation(
            &workspace.inner,
            Some((snapshot.endpoint(), snapshot.runtime())),
        );
        let failed = workspace.snapshot();
        assert_eq!(failed.hosts()[0].projects()[0].name(), "project");
        assert!(failed.hosts()[0].kwt_diagnostic().is_none());
        assert!(!failed.hosts()[0].kwt_mutating());
    }

    #[test]
    fn worktree_open_uses_durable_kwt_identity_even_without_a_live_tmux_session() {
        let bundle =
            host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
        let config = WslConfig::with_distro("Ubuntu")
            .expect("valid config")
            .with_kwt_bundle(bundle);
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
        );
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
        *workspace.inner.host.lock().expect("published host") = Some(Published::new(
            HostContext {
                host: WslHost::new(
                    config,
                    Arc::new(StdCommandRunner) as SharedCommandRunner,
                    executable,
                ),
                snapshot: snapshot.clone(),
            },
            3,
        ));
        *workspace
            .inner
            .selected_host
            .write()
            .expect("selected host") = Some("wsl".to_owned());
        set_inventory_state(&workspace.inner, ready_content(&snapshot));
        workspace
            .inner
            .kwt_refresh_generation
            .store(7, Ordering::Release);
        let inventory = KwtInventory::parse(
            br#"[{"repository":"project-id","name":"project","path":"/repos/project","last_touched":null,"registration_fingerprint":"project-fingerprint"}]"#,
            br#"[{"path":"/work/project/topic","branch":"topic","commit_hash":"abc","is_main":false,"created_at":null,"generation":"g7","repository":"project-id","session_name":"project-topic","tmux_socket_name":null}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");
        publish_kwt_inventory(
            &workspace.inner,
            7,
            snapshot.endpoint(),
            snapshot.runtime(),
            &inventory,
        );

        let request = capture_kwt_worktree_request(
            &workspace.inner,
            "wsl",
            "Ubuntu",
            "project-id",
            "/repos/project",
            "project-fingerprint",
            "/work/project/topic",
            Some("g7"),
            "project-topic",
        )
        .expect("KWT identity grants repair-or-open authority");
        assert!(matches!(request.target, AttachTarget::Worktree { .. }));
        assert_eq!(request.name, "project-topic");
        assert!(
            capture_kwt_worktree_request(
                &workspace.inner,
                "wsl",
                "Ubuntu",
                "project-id",
                "/repos/project",
                "project-fingerprint",
                "/work/project/topic",
                Some("stale"),
                "project-topic",
            )
            .is_err()
        );
    }

    #[test]
    fn confirmed_project_mutation_survives_failed_inventory_reconciliation() {
        let config = WslConfig::with_distro("Ubuntu").expect("valid config");
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
        );
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
        *workspace.inner.host.lock().expect("published host") = Some(Published::new(
            HostContext {
                host: WslHost::new(
                    config,
                    Arc::new(StdCommandRunner) as SharedCommandRunner,
                    executable,
                ),
                snapshot: snapshot.clone(),
            },
            1,
        ));
        workspace
            .inner
            .kwt_refresh_generation
            .store(7, Ordering::Release);
        let added = KwtInventory::parse(
            br#"[{"repository":"added-id","name":"added","path":"/repos/added","last_touched":null,"registration_fingerprint":"added-fingerprint"}]"#,
            b"[]",
            b"[]",
        )
        .expect("valid mutation project");
        let added = added.projects()[0].project();
        publish_kwt_project_mutation(
            &workspace.inner,
            7,
            snapshot.endpoint(),
            snapshot.runtime(),
            KwtProjectAction::Add,
            added,
        );
        publish_kwt_error(
            &workspace.inner,
            7,
            snapshot.endpoint(),
            snapshot.runtime(),
            HostDiagnostic::new(
                DiagnosticKind::Transport,
                "post-registration inventory failed",
            ),
        );
        let reconciled = workspace.snapshot();
        assert_eq!(reconciled.hosts()[0].projects()[0].name(), "added");
        assert!(reconciled.hosts()[0].kwt_diagnostic().is_some());

        publish_kwt_project_mutation(
            &workspace.inner,
            7,
            snapshot.endpoint(),
            snapshot.runtime(),
            KwtProjectAction::Remove,
            added,
        );
        let removed = workspace.snapshot();
        assert!(removed.hosts()[0].projects().is_empty());
    }

    #[test]
    fn failed_kwt_inventory_keeps_constructive_add_separate_from_remove_authority() {
        let mut host = HostItem::wsl("Ubuntu", None, HostConnectionState::Ready, Vec::new(), None);
        host.kwt_state = KwtState::Unavailable;
        host.kwt_diagnostic = Some(HostDiagnostic::new(
            DiagnosticKind::Transport,
            "automatic inventory failed",
        ));

        assert!(host.can_add_kwt_project());
        assert!(!host.can_remove_kwt_project());
    }

    #[test]
    fn stale_kwt_publication_cannot_replace_the_current_project_tree() {
        let config = WslConfig::with_distro("Ubuntu").expect("valid config");
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
        );
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
        *workspace.inner.host.lock().expect("published host") = Some(Published::new(
            HostContext {
                host: WslHost::new(
                    config,
                    Arc::new(StdCommandRunner) as SharedCommandRunner,
                    executable,
                ),
                snapshot: snapshot.clone(),
            },
            1,
        ));
        workspace
            .inner
            .kwt_refresh_generation
            .store(2, Ordering::Release);
        let inventory = KwtInventory::parse(
            br#"[{"repository":"project-id","name":"stale","path":"/repos/stale","last_touched":null,"registration_fingerprint":"stale-fingerprint"}]"#,
            b"[]",
            b"[]",
        )
        .expect("valid KWT inventory");

        publish_kwt_inventory(
            &workspace.inner,
            1,
            snapshot.endpoint(),
            snapshot.runtime(),
            &inventory,
        );

        assert!(workspace.snapshot().hosts()[0].projects().is_empty());
    }

    #[test]
    fn background_cadence_refreshes_ready_hosts_and_reuses_the_admitted_host() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
            "Ubuntu",
            "boot",
            42,
            vec![session::DiscoveredSession::new(
                "work",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        )));
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(spec),
            discovery.clone(),
            runtime.clone(),
        );

        workspace.connect_enabled_hosts().expect("connect host");
        assert!(!workspace.refresh_if_ready().expect("connecting no-op"));
        runtime.run_next_work();
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Ready
        );
        runtime.run_next_deadline();

        workspace
            .start_inventory_cadence()
            .expect("start inventory cadence");
        workspace.set_inventory_polling_enabled(true);
        workspace
            .start_inventory_cadence()
            .expect("cadence start is idempotent");
        assert_eq!(runtime.deadline_delays(), vec![INVENTORY_REFRESH_INTERVAL]);
        let before_refresh = workspace.snapshot();
        runtime.run_next_deadline();
        let refreshing = workspace.snapshot();
        assert_eq!(
            refreshing.hosts()[0].connection(),
            HostConnectionState::Ready,
            "background refresh keeps the usable host and its actions visible"
        );
        assert_eq!(
            refreshing.revision(),
            before_refresh.revision(),
            "starting background work does not publish transient UI state"
        );
        assert!(
            capture_create_request(
                &workspace.inner,
                "wsl",
                "Ubuntu",
                SessionName::parse("new work").expect("valid name"),
            )
            .is_ok(),
            "an admitted host remains available for creation while its inventory refreshes"
        );
        assert!(
            capture_create_request(
                &workspace.inner,
                "wsl",
                "Debian",
                SessionName::parse("new work").expect("valid name"),
            )
            .is_err(),
            "creation never follows a changed default distro implicitly"
        );
        runtime.run_next_work();

        assert_eq!(discovery.reused_hosts.load(Ordering::Acquire), 1);
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Ready
        );
    }

    #[test]
    fn inventory_cadence_is_a_no_op_without_an_enabled_host() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            None,
            Arc::new(SystemWslDiscovery::new()),
            runtime.clone(),
        );

        workspace
            .start_inventory_cadence()
            .expect("missing WSL host is not a scheduling error");

        assert!(runtime.deadline_delays().is_empty());
        assert!(
            !workspace
                .inner
                .inventory_cadence_started
                .load(Ordering::Acquire)
        );
    }

    #[test]
    fn kwt_inventory_uses_a_distinct_slower_cadence() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let bundle =
            host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
        let config = WslConfig::with_distro("Ubuntu")
            .expect("valid config")
            .with_kwt_bundle(bundle);
        let spec = WslHostSpec::available(
            config,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(spec),
            Arc::new(SystemWslDiscovery::new()),
            runtime.clone(),
        );

        workspace
            .start_inventory_cadence()
            .expect("start both inventory cadences");
        workspace
            .start_inventory_cadence()
            .expect("cadence start remains idempotent");

        assert_eq!(
            runtime.deadline_delays(),
            vec![INVENTORY_REFRESH_INTERVAL, KWT_REFRESH_INTERVAL]
        );
    }

    #[test]
    fn background_kwt_refresh_requires_the_matching_host_to_be_ready() {
        let bundle =
            host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
        let config = WslConfig::with_distro("Ubuntu")
            .expect("valid config")
            .with_kwt_bundle(bundle);
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
        );
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
        *workspace.inner.host.lock().expect("published host") = Some(Published::new(
            HostContext {
                host: WslHost::new(
                    config,
                    Arc::new(StdCommandRunner) as SharedCommandRunner,
                    executable,
                ),
                snapshot,
            },
            1,
        ));

        for state in [
            HostConnectionState::Disconnected,
            HostConnectionState::Unavailable,
        ] {
            workspace.inner.hosts.write().expect("hosts")[0].connection = state;
            assert!(
                reserve_kwt_refresh(&workspace.inner, false).is_none(),
                "background KWT work must not use retained host authority while {state:?}"
            );
        }

        workspace.inner.hosts.write().expect("hosts")[0].connection = HostConnectionState::Ready;
        let refresh = reserve_kwt_refresh(&workspace.inner, false)
            .expect("ready matching host permits background KWT refresh");
        refresh.cancellation.cancel();
    }

    #[test]
    fn failed_mutation_spawn_starts_deferred_kwt_refresh_for_replaced_runtime() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let bundle =
            host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
        let config = WslConfig::with_distro("Ubuntu")
            .expect("valid config")
            .with_kwt_bundle(bundle.clone());
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
            Arc::new(SystemWslDiscovery::new()),
            runtime.clone(),
        );
        let old_snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-old", 42, Vec::new());
        *workspace.inner.host.lock().expect("published host") = Some(Published::new(
            HostContext {
                host: WslHost::new(
                    config,
                    Arc::new(StdCommandRunner) as SharedCommandRunner,
                    executable.clone(),
                ),
                snapshot: old_snapshot.clone(),
            },
            1,
        ));
        set_inventory_state(&workspace.inner, ready_content(&old_snapshot));
        workspace.inner.hosts.write().expect("hosts")[0].kwt_state = KwtState::Ready;

        let replacement_inner = Arc::clone(&workspace.inner);
        runtime.fail_next_work(move || {
            let replacement = HostSnapshot::test_fixture("Debian", "boot-new", 84, Vec::new());
            let replacement_config = WslConfig::with_distro("Debian")
                .expect("valid replacement config")
                .with_kwt_bundle(bundle);
            *replacement_inner.host.lock().expect("published host") = Some(Published::new(
                HostContext {
                    host: WslHost::new(
                        replacement_config,
                        Arc::new(StdCommandRunner) as SharedCommandRunner,
                        executable,
                    ),
                    snapshot: replacement.clone(),
                },
                2,
            ));
            set_inventory_state(&replacement_inner, ready_content(&replacement));
        });

        let error = workspace
            .add_kwt_project("wsl", "Ubuntu", "/repos/project")
            .expect_err("scripted mutation spawn fails");
        assert!(error.to_string().contains("scripted work spawn failure"));
        assert!(
            !workspace
                .inner
                .kwt_mutation_in_flight
                .load(Ordering::Acquire)
        );
        let snapshot = workspace.snapshot();
        assert_eq!(snapshot.hosts()[0].endpoint(), "Debian");
        assert!(snapshot.hosts()[0].kwt_refreshing());
        assert_eq!(
            runtime.work.lock().expect("work queue").len(),
            1,
            "settlement schedules the initial KWT refresh for the replacement runtime"
        );
    }

    #[test]
    fn inactive_inventory_cadence_does_not_start_host_work() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
            "Ubuntu",
            "boot",
            42,
            Vec::new(),
        )));
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(spec),
            discovery,
            runtime.clone(),
        );

        workspace
            .start_inventory_cadence()
            .expect("start inventory cadence");
        runtime.run_next_deadline();

        assert!(runtime.work.lock().expect("work queue").is_empty());
        assert_eq!(runtime.deadline_delays(), vec![INVENTORY_REFRESH_INTERVAL]);
    }

    #[test]
    fn inventory_cadence_yields_to_create_and_lifecycle_operations() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
            "Ubuntu",
            "boot",
            42,
            Vec::new(),
        )));
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(spec),
            discovery,
            runtime.clone(),
        );
        workspace.connect_enabled_hosts().expect("connect host");
        runtime.run_next_work();
        runtime.run_next_deadline();
        workspace.set_inventory_polling_enabled(true);
        workspace
            .start_inventory_cadence()
            .expect("start inventory cadence");
        let generation = workspace.inner.refresh_generation.load(Ordering::Acquire);

        {
            let _create_operation = workspace
                .inner
                .session_operations
                .lock()
                .expect("hold tmux creation lane");
            runtime.run_next_deadline();
            assert!(runtime.work.lock().expect("work queue").is_empty());
            assert_eq!(
                workspace.inner.refresh_generation.load(Ordering::Acquire),
                generation,
                "cadence cannot supersede tmux creation publication"
            );
        }

        {
            let _lifecycle_operation = workspace
                .inner
                .session_operations
                .lock()
                .expect("hold Herdr lifecycle lane");
            runtime.run_next_deadline();
            assert!(runtime.work.lock().expect("work queue").is_empty());
            assert_eq!(
                workspace.inner.refresh_generation.load(Ordering::Acquire),
                generation,
                "cadence cannot supersede Herdr lifecycle publication"
            );
        }

        runtime.run_next_deadline();
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Ready,
            "cadence resumes without demoting the usable host"
        );
        assert_eq!(
            workspace.inner.refresh_generation.load(Ordering::Acquire),
            generation + 1
        );
    }

    #[test]
    fn cancelling_refresh_invalidates_work_and_restores_disconnected_host() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
            "Ubuntu",
            "boot",
            42,
            vec![session::DiscoveredSession::new(
                "work",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            )],
        )));
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(spec),
            discovery,
            runtime.clone(),
        );

        workspace.connect_enabled_hosts().expect("start refresh");
        let active_generation = workspace.inner.refresh_generation.load(Ordering::Acquire);
        assert!(workspace.cancel_refresh());
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Disconnected
        );
        assert!(
            workspace.inner.refresh_generation.load(Ordering::Acquire) > active_generation,
            "cancellation must invalidate late publication"
        );
        assert!(
            !workspace.cancel_refresh(),
            "disconnected refresh is inactive"
        );

        runtime.run_next_work();
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Disconnected,
            "cancelled discovery cannot publish"
        );
        runtime.run_next_deadline();
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Disconnected,
            "cancelled deadline cannot publish"
        );
    }

    #[test]
    fn legacy_inventory_publication_still_updates_top_level_content() {
        let workspace = Workspace::preview(WorkspaceSnapshot {
            revision: 0,
            appearance: Appearance::default(),
            content: WorkspaceContent::Loading,
            hosts: vec![HostItem::wsl(
                "Ubuntu",
                None,
                HostConnectionState::Connecting,
                Vec::new(),
                None,
            )],
            selected_host: Some("wsl".to_owned()),
            notice: None,
            retained_selections: Vec::new(),
        });

        set_inventory_state(
            &workspace.inner,
            WorkspaceContent::Ready {
                endpoint: "Ubuntu".to_owned(),
                sessions: vec![SessionItem::new("work", 0)],
            },
        );

        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.len() == 1 && sessions[0].name() == "work"
        ));

        set_wsl_host_unavailable(
            &workspace.inner,
            DiagnosticKind::Timeout,
            "legacy refresh timed out".to_owned(),
        );
        let snapshot = workspace.snapshot();
        assert!(matches!(
            snapshot.content(),
            WorkspaceContent::Error { message } if message == "legacy refresh timed out"
        ));
        assert_eq!(
            snapshot.hosts()[0]
                .diagnostic()
                .expect("classified host diagnostic")
                .kind(),
            DiagnosticKind::Timeout
        );
    }

    #[test]
    fn only_the_current_refresh_deadline_can_publish_timeout() {
        let spec = WslHostSpec::available(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        );
        let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));
        let stale = CancellationToken::new();
        let stale_generation =
            begin_refresh(&workspace.inner, &stale, RefreshPresentation::Connecting);
        let current = CancellationToken::new();
        let current_generation =
            begin_refresh(&workspace.inner, &current, RefreshPresentation::Connecting);

        assert!(!expire_refresh(&workspace.inner, stale_generation, &stale));
        assert!(expire_refresh(
            &workspace.inner,
            current_generation,
            &current
        ));
        assert!(current.is_cancelled());
        let snapshot = workspace.snapshot();
        assert_eq!(
            snapshot.hosts()[0].connection(),
            HostConnectionState::Unavailable
        );
        assert_eq!(
            snapshot.hosts()[0]
                .diagnostic()
                .expect("timeout diagnostic")
                .kind(),
            DiagnosticKind::Timeout
        );
    }
}
