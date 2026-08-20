//! Application workflow and capability boundary for GPUI.

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, RwLock, TryLockError};
use std::thread;
use std::time::{Duration, Instant};

use config::{ApplicationConfig, Roots, SshHostSettings, TerminalAppearance};
pub use config::{CursorStyle, TerminalTheme};
use host::{
    AdmissionAttacher, AttachTerm, CancellationToken, CommandRunner, HerdrInventory, HostError,
    HostSnapshot, KwtInventory, KwtPullRequestImportRequest, KwtSshExecutable, LiveSessionTarget,
    RemoteSessionInventory, RemoteTmuxConfig, RemoteTmuxHost, RemoteTmuxSnapshot, SshExecutable,
    SshLeasePrompt, SshPromptKind, SshTarget, StdCommandRunner, WslConfig, WslExecutable, WslHost,
    ZellijInventory,
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
    TerminalEvent, TerminalStartup, TerminalWorker,
};

const REDUCED_COLOR_NOTICE: &str =
    "Using TERM=xterm because xterm-256color terminfo is unavailable on this host";
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
const WORKTREE_CLIENT_STARTUP_BACKOFF: [Duration; 10] = [
    Duration::from_millis(100),
    Duration::from_millis(200),
    Duration::from_millis(400),
    Duration::from_millis(800),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(2),
    Duration::from_secs(3),
    Duration::from_secs(3),
    Duration::from_secs(3),
];
const CREATE_IDENTITY_TIMEOUT: Duration = Duration::from_secs(5);
const SSH_PROMPT_TIMEOUT: Duration = Duration::from_mins(5);
const CREATE_IDENTITY_MIN_COLUMNS: usize = 120;
const INVENTORY_REFRESH_INTERVAL: Duration = Duration::from_secs(10);
const KWT_REFRESH_INTERVAL: Duration = Duration::from_mins(1);
const KWT_REFRESH_BUDGET: Duration = Duration::from_secs(30);
const PENDING_KWT_CREATION_REFRESH_LIMIT: u8 = 3;
const PENDING_KWT_CREATION_LIFETIME: Duration = Duration::from_mins(3);

#[derive(Clone, Debug, PartialEq)]
pub struct Appearance {
    theme: TerminalTheme,
    font_family: String,
    font_size: u16,
    background: u32,
    foreground: u32,
    cursor_style: CursorStyle,
    allow_shell_integration_cursor: bool,
    hide_mouse_while_typing: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AppearanceSettingsDraft {
    pub theme: TerminalTheme,
    pub font_family: String,
    pub font_size: String,
    pub background: String,
    pub foreground: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalSettingsDraft {
    pub cursor_style: CursorStyle,
    pub allow_shell_integration_cursor: bool,
    pub hide_mouse_while_typing: bool,
}

impl From<&TerminalAppearance> for TerminalSettingsDraft {
    fn from(value: &TerminalAppearance) -> Self {
        Self {
            cursor_style: value.cursor_style(),
            allow_shell_integration_cursor: value.allow_shell_integration_cursor(),
            hide_mouse_while_typing: value.hide_mouse_while_typing(),
        }
    }
}

impl From<&Appearance> for TerminalSettingsDraft {
    fn from(value: &Appearance) -> Self {
        Self {
            cursor_style: value.cursor_style(),
            allow_shell_integration_cursor: value.allow_shell_integration_cursor(),
            hide_mouse_while_typing: value.hide_mouse_while_typing(),
        }
    }
}

impl From<&TerminalAppearance> for AppearanceSettingsDraft {
    fn from(value: &TerminalAppearance) -> Self {
        Self {
            theme: value.theme(),
            font_family: value.font_family().to_owned(),
            font_size: value.font_size().to_string(),
            background: format!("#{:06x}", value.background()),
            foreground: format!("#{:06x}", value.foreground()),
        }
    }
}

impl From<&Appearance> for AppearanceSettingsDraft {
    fn from(value: &Appearance) -> Self {
        Self {
            theme: value.theme(),
            font_family: value.font_family().to_owned(),
            font_size: value.font_size().to_string(),
            background: format!("#{:06x}", value.background()),
            foreground: format!("#{:06x}", value.foreground()),
        }
    }
}

impl Appearance {
    #[must_use]
    pub const fn theme(&self) -> TerminalTheme {
        self.theme
    }

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

    #[must_use]
    pub const fn cursor_style(&self) -> CursorStyle {
        self.cursor_style
    }

    #[must_use]
    pub const fn allow_shell_integration_cursor(&self) -> bool {
        self.allow_shell_integration_cursor
    }

    #[must_use]
    pub const fn hide_mouse_while_typing(&self) -> bool {
        self.hide_mouse_while_typing
    }
}

impl From<TerminalAppearance> for Appearance {
    fn from(value: TerminalAppearance) -> Self {
        Self {
            theme: value.theme(),
            font_family: value.font_family().to_owned(),
            font_size: value.font_size(),
            background: value.background(),
            foreground: value.foreground(),
            cursor_style: value.cursor_style(),
            allow_shell_integration_cursor: value.allow_shell_integration_cursor(),
            hide_mouse_while_typing: value.hide_mouse_while_typing(),
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
    tmux_socket_name: Option<String>,
    worktree_path: Option<String>,
    worktree_generation: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionKind {
    Tmux,
    Herdr,
    Zellij,
}

impl SessionSelection {
    fn for_kind(
        host_id: impl Into<String>,
        endpoint: impl Into<String>,
        session: impl Into<String>,
        kind: SessionKind,
    ) -> Self {
        match kind {
            SessionKind::Tmux => Self::new(host_id, endpoint, session),
            SessionKind::Herdr => Self::herdr(host_id, endpoint, session),
            SessionKind::Zellij => Self::zellij(host_id, endpoint, session),
        }
    }

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
            tmux_socket_name: None,
            worktree_path: None,
            worktree_generation: None,
        }
    }

    #[must_use]
    pub fn protected_worktree(
        host_id: impl Into<String>,
        endpoint: impl Into<String>,
        session: impl Into<String>,
        socket_name: impl Into<String>,
        path: impl Into<String>,
        generation: impl Into<String>,
    ) -> Self {
        Self {
            host_id: host_id.into(),
            endpoint: endpoint.into(),
            session: session.into(),
            kind: SessionKind::Tmux,
            tmux_socket_name: Some(socket_name.into()),
            worktree_path: Some(path.into()),
            worktree_generation: Some(generation.into()),
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
            tmux_socket_name: None,
            worktree_path: None,
            worktree_generation: None,
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
            tmux_socket_name: None,
            worktree_path: None,
            worktree_generation: None,
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

    #[must_use]
    pub fn tmux_socket_name(&self) -> Option<&str> {
        self.tmux_socket_name.as_deref()
    }

    #[must_use]
    pub fn worktree_path(&self) -> Option<&str> {
        self.worktree_path.as_deref()
    }

    #[must_use]
    pub fn worktree_generation(&self) -> Option<&str> {
        self.worktree_generation.as_deref()
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
    tmux_available: bool,
    tmux_diagnostic: Option<HostDiagnostic>,
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
            tmux_available: true,
            tmux_diagnostic: None,
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
    pub fn ssh(
        id: impl Into<String>,
        name: impl Into<String>,
        endpoint: impl Into<String>,
        connection: HostConnectionState,
        sessions: Vec<SessionItem>,
        diagnostic: Option<HostDiagnostic>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            endpoint: endpoint.into(),
            socket_directory: None,
            connection,
            sessions,
            diagnostic,
            tmux_available: false,
            tmux_diagnostic: None,
            herdr_available: false,
            herdr_sessions: Vec::new(),
            herdr_diagnostic: None,
            zellij_available: false,
            zellij_sessions: Vec::new(),
            zellij_diagnostic: None,
            projects: Vec::new(),
            directory_workspaces: Vec::new(),
            kwt_state: KwtState::Unavailable,
            kwt_diagnostic: None,
        }
    }

    #[must_use]
    pub fn is_ssh(&self) -> bool {
        self.id.starts_with("ssh:")
    }

    #[must_use]
    pub fn with_tmux_diagnostic(mut self, diagnostic: HostDiagnostic) -> Self {
        self.tmux_available = false;
        self.tmux_diagnostic = Some(diagnostic);
        self
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

    /// Whether cached session inventory may authorize a new host action.
    ///
    /// WSL refreshes retain their admitted local runtime and may continue to
    /// use cached inventory. SSH refreshes are a connection boundary and must
    /// finish before another action can use the replacement lease.
    #[must_use]
    pub fn accepts_session_actions(&self) -> bool {
        match self.connection {
            HostConnectionState::Ready => true,
            HostConnectionState::Connecting => !self.is_ssh(),
            HostConnectionState::Disconnected | HostConnectionState::Unavailable => false,
        }
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
    pub const fn tmux_available(&self) -> bool {
        self.tmux_available
    }

    #[must_use]
    pub const fn tmux_diagnostic(&self) -> Option<&HostDiagnostic> {
        self.tmux_diagnostic.as_ref()
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

    #[must_use]
    pub fn kwt_owns_protected_presentation(&self, selection: &SessionSelection) -> bool {
        let (Some(socket_name), Some(worktree_path), Some(generation)) = (
            selection.tmux_socket_name(),
            selection.worktree_path(),
            selection.worktree_generation(),
        ) else {
            return false;
        };
        selection.kind() == SessionKind::Tmux
            && selection.host_id() == self.id
            && selection.endpoint() == self.endpoint
            && self.projects.iter().any(|project| {
                project.worktrees.iter().any(|worktree| {
                    worktree.session_name == selection.session()
                        && worktree.tmux_socket_name.as_deref() == Some(socket_name)
                        && worktree.path == worktree_path
                        && worktree.generation.as_deref() == Some(generation)
                })
            })
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
    notice: Option<WorkspaceNotice>,
    active_selection: Option<SessionSelection>,
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
            active_selection: None,
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
            active_selection: None,
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
        self.notice.as_ref().map(|notice| notice.message.as_str())
    }

    #[must_use]
    pub fn notice_is_transient(&self) -> bool {
        self.notice.as_ref().is_some_and(|notice| notice.transient)
    }

    #[must_use]
    pub fn retained_selections(&self) -> &[SessionSelection] {
        &self.retained_selections
    }

    #[must_use]
    pub const fn active_selection(&self) -> Option<&SessionSelection> {
        self.active_selection.as_ref()
    }
}

#[derive(Clone)]
struct WorkspaceNotice {
    message: String,
    transient: bool,
}

pub struct ClipboardRead {
    inner: TerminalClipboardRead,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SshHostDraft {
    pub name: String,
    pub hostname: String,
    pub user: String,
    pub port: String,
    pub tmux_binary: String,
    pub socket_directory: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConfiguredSshHost {
    id: String,
    draft: SshHostDraft,
}

impl ConfiguredSshHost {
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub const fn draft(&self) -> &SshHostDraft {
        &self.draft
    }
}

impl From<&SshHostSettings> for SshHostDraft {
    fn from(host: &SshHostSettings) -> Self {
        Self {
            name: host.name().to_owned(),
            hostname: host.hostname().to_owned(),
            user: host.user().unwrap_or_default().to_owned(),
            port: host
                .port()
                .map_or_else(String::new, |port| port.to_string()),
            tmux_binary: host.tmux_binary().to_owned(),
            socket_directory: host.socket_directory().unwrap_or_default().to_owned(),
        }
    }
}

#[derive(Clone)]
pub struct SshPromptRequest {
    host_id: String,
    generation: u64,
    prompt: SshLeasePrompt,
    response: Arc<Mutex<Option<SyncSender<Option<String>>>>>,
}

impl SshPromptRequest {
    #[must_use]
    pub fn host_id(&self) -> &str {
        &self.host_id
    }

    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    #[must_use]
    pub const fn kind(&self) -> SshPromptKind {
        self.prompt.kind()
    }

    #[must_use]
    pub fn message(&self) -> &str {
        self.prompt.message()
    }

    #[must_use]
    pub fn display_target(&self) -> &str {
        self.prompt.details().display_target()
    }

    #[must_use]
    pub const fn host_key(&self) -> Option<&host::SshHostKeyDetails> {
        self.prompt.details().host_key()
    }

    #[must_use]
    pub const fn sensitive(&self) -> bool {
        self.prompt.sensitive()
    }

    pub fn respond(&self, value: Option<String>) {
        if let Some(response) = self
            .response
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            let _ignored = response.send(value);
        }
    }
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
    SshPrompt(SshPromptRequest),
    SshPromptDismissed {
        host_id: String,
        generation: u64,
    },
    KwtProjectMutationFinished {
        action: KwtProjectAction,
    },
    KwtProjectMutationFailed {
        action: KwtProjectAction,
        message: String,
    },
    KwtBranchesLoaded {
        operation_id: u64,
        project_path: String,
        branches: Vec<KwtBranchItem>,
    },
    KwtPullRequestsLoaded {
        operation_id: u64,
        project_path: String,
        pull_requests: Vec<KwtPullRequestItem>,
    },
    KwtWorktreeRemovalReady {
        project_path: String,
        worktree_path: String,
        authority: u64,
        session_was_running: bool,
    },
    KwtWorktreeCreated {
        target: KwtWorktreeTarget,
        navigation_generation: u64,
    },
    KwtWorktreeRemoved {
        operation_id: u64,
        project_path: String,
        worktree_path: String,
    },
    KwtWorktreeCreationPending {
        project_path: String,
        message: String,
        navigation_generation: u64,
    },
    KwtWorktreeCreationExpired {
        project_path: String,
        message: String,
        navigation_generation: u64,
    },
    KwtWorktreeOperationFailed {
        operation_id: u64,
        project_path: String,
        worktree_path: Option<String>,
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KwtPullRequestItem {
    id: String,
    number: u64,
    url: String,
    title: String,
    author: String,
    source_branch: String,
    draft: bool,
    imported: bool,
}

impl KwtPullRequestItem {
    #[must_use]
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        number: u64,
        url: impl Into<String>,
        title: impl Into<String>,
        author: impl Into<String>,
        source_branch: impl Into<String>,
        draft: bool,
        imported: bool,
    ) -> Self {
        Self {
            id: id.into(),
            number,
            url: url.into(),
            title: title.into(),
            author: author.into(),
            source_branch: source_branch.into(),
            draft,
            imported,
        }
    }

    fn from_host(value: &host::KwtPullRequest) -> Self {
        Self::new(
            value.id(),
            value.number(),
            value.url(),
            value.title(),
            value.author(),
            value.source_branch(),
            value.draft(),
            value.imported(),
        )
    }

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
        &self.source_branch
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
    tmux_socket_name: Option<String>,
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
    #[must_use]
    pub fn tmux_socket_name(&self) -> Option<&str> {
        self.tmux_socket_name.as_deref()
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

fn is_canonical_kwt_generation(generation: &str) -> bool {
    generation.len() == 32 && generation.bytes().all(|byte| byte.is_ascii_hexdigit())
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

    #[must_use]
    pub const fn is_available(&self) -> bool {
        self.executable.is_some()
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
type RuntimeRemoteHost = RemoteTmuxHost<SharedCommandRunner>;

#[derive(Clone)]
pub struct RemoteHostSpec {
    config: RemoteTmuxConfig,
    controller: Option<KwtSshExecutable>,
    ssh: Option<SshExecutable>,
    diagnostic: Option<HostDiagnostic>,
}

impl RemoteHostSpec {
    #[must_use]
    pub fn available(
        config: RemoteTmuxConfig,
        controller: KwtSshExecutable,
        ssh: SshExecutable,
    ) -> Self {
        Self {
            config,
            controller: Some(controller),
            ssh: Some(ssh),
            diagnostic: None,
        }
    }

    #[must_use]
    pub fn unavailable(
        config: RemoteTmuxConfig,
        kind: DiagnosticKind,
        message: impl Into<String>,
    ) -> Self {
        Self {
            config,
            controller: None,
            ssh: None,
            diagnostic: Some(HostDiagnostic::new(kind, message)),
        }
    }

    /// Construct a Windows SSH host whose KWT and OpenSSH processes will be
    /// resolved inside the ready synthetic WSL host at connection time.
    #[must_use]
    pub fn wsl(config: RemoteTmuxConfig) -> Self {
        Self {
            config,
            controller: None,
            ssh: None,
            diagnostic: None,
        }
    }

    fn host_item(&self) -> HostItem {
        HostItem::ssh(
            self.config.id(),
            self.config.name(),
            self.config.endpoint(),
            if self.diagnostic.is_some() {
                HostConnectionState::Unavailable
            } else {
                HostConnectionState::Disconnected
            },
            Vec::new(),
            self.diagnostic.clone(),
        )
    }

    fn runtime_host(&self, runner: SharedCommandRunner) -> Option<RuntimeRemoteHost> {
        Some(RemoteTmuxHost::new(
            self.config.clone(),
            self.controller.as_ref()?,
            self.ssh.as_ref()?,
            runner,
        ))
    }
}

struct RemoteHostContext {
    generation: u64,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
}

struct RemoteEntry {
    config: RemoteTmuxConfig,
    native_host: Option<RuntimeRemoteHost>,
    context: Option<RemoteHostContext>,
    cancellation: Option<CancellationToken>,
    constructive_cancellation: Option<RemoteConstructiveState>,
    attachment_attempt: Option<RemoteAttachmentAttempt>,
    generation: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum RemoteConstructiveTarget {
    Herdr {
        route_identity: String,
        executable: String,
        name: String,
        precondition: HerdrLaunchPrecondition,
    },
    Zellij {
        route_identity: String,
        executable: String,
        name: String,
    },
}

enum RemoteConstructiveState {
    Active {
        navigation_generation: u64,
        cancellation: CancellationToken,
        launched: Arc<AtomicBool>,
        target: RemoteConstructiveTarget,
    },
    PendingReconciliation(RemoteConstructiveTarget),
}

struct RemoteAttachmentAttempt {
    navigation_generation: u64,
    cancellation: CancellationToken,
}

struct RemoteActive {
    key: RemotePresentationKey,
    selection: SessionSelection,
    worker_generation: u64,
    lease: host::SshLease,
    presentation_id: u64,
    term: AttachTerm,
    retainable: bool,
    identity_mismatch_marker: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum RemoteSessionIdentity {
    Tmux(session::SessionIdentity),
    Herdr {
        name: String,
        is_default: bool,
        session_directory: String,
        socket_path: String,
    },
    Zellij(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RemotePresentationKey {
    host_id: String,
    endpoint: String,
    route_identity: String,
    lease_generation: u64,
    session_identity: RemoteSessionIdentity,
}

struct RemoteRetainedPresentation {
    active: RemoteActive,
    worker: TerminalWorker,
}

struct RemoteRetainedPresentations {
    entries: Vec<RemoteRetainedPresentation>,
}

struct RemoteRetainedDrain {
    emitted: Vec<WorkspaceEvent>,
    processed: usize,
    changed: bool,
}

struct RemotePublishError {
    error: WorkspaceError,
    worker: TerminalWorker,
}

struct RemotePublicationFence<'a> {
    host_id: &'a str,
    connection_generation: u64,
    snapshot: &'a RemoteTmuxSnapshot,
    cancellation: &'a CancellationToken,
}

#[derive(Clone, Copy)]
struct RemoteInventory<'a> {
    tmux: Option<&'a [session::DiscoveredSession]>,
    herdr: Option<&'a [session::HerdrSessionRecord]>,
    zellij: Option<&'a [session::ZellijSessionRecord]>,
}

impl<'a> From<&'a RemoteTmuxSnapshot> for RemoteInventory<'a> {
    fn from(snapshot: &'a RemoteTmuxSnapshot) -> Self {
        Self {
            tmux: snapshot
                .tmux_diagnostic()
                .is_none()
                .then(|| snapshot.sessions()),
            herdr: match snapshot.herdr() {
                HerdrInventory::Available { sessions, .. } => Some(sessions),
                HerdrInventory::Unavailable => Some(&[]),
                HerdrInventory::Failed(_) => None,
            },
            zellij: match snapshot.zellij() {
                ZellijInventory::Available { sessions, .. } => Some(sessions),
                ZellijInventory::Unavailable => Some(&[]),
                ZellijInventory::Failed(_) => None,
            },
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum RemoteReconcile {
    Found(SessionKind, String),
    Unknown,
    Stale,
}

impl RemotePresentationKey {
    fn reconcile(
        &mut self,
        endpoint: &str,
        route_identity: &str,
        lease_generation: u64,
        inventory: Option<RemoteInventory<'_>>,
    ) -> RemoteReconcile {
        if self.endpoint != endpoint || self.route_identity != route_identity {
            return RemoteReconcile::Stale;
        }
        let Some(inventory) = inventory else {
            return RemoteReconcile::Stale;
        };
        let (kind, name) = match &self.session_identity {
            RemoteSessionIdentity::Tmux(identity) => {
                let Some(sessions) = inventory.tmux else {
                    self.lease_generation = lease_generation;
                    return RemoteReconcile::Unknown;
                };
                let Some(session) = sessions
                    .iter()
                    .find(|session| session.identity() == identity)
                else {
                    return RemoteReconcile::Stale;
                };
                (SessionKind::Tmux, session.name().to_owned())
            }
            RemoteSessionIdentity::Herdr {
                name,
                is_default,
                session_directory,
                socket_path,
            } => {
                let Some(sessions) = inventory.herdr else {
                    self.lease_generation = lease_generation;
                    return RemoteReconcile::Unknown;
                };
                let Some(session) = sessions.iter().find(|session| {
                    session.name() == name
                        && session.is_default() == *is_default
                        && session.session_directory() == session_directory
                        && session.socket_path() == socket_path
                        && session.state() == HerdrSessionState::Running
                }) else {
                    return RemoteReconcile::Stale;
                };
                (SessionKind::Herdr, session.name().to_owned())
            }
            RemoteSessionIdentity::Zellij(name) => {
                let Some(sessions) = inventory.zellij else {
                    self.lease_generation = lease_generation;
                    return RemoteReconcile::Unknown;
                };
                let Some(session) = sessions.iter().find(|session| session.name() == name) else {
                    return RemoteReconcile::Stale;
                };
                (SessionKind::Zellij, session.name().to_owned())
            }
        };
        self.lease_generation = lease_generation;
        RemoteReconcile::Found(kind, name)
    }
}

const fn retain_remote_session(kind: SessionKind) -> bool {
    matches!(kind, SessionKind::Tmux)
}

impl RemoteRetainedPresentations {
    const fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    fn insert(&mut self, presentation: RemoteRetainedPresentation) {
        if let Some(index) = self
            .entries
            .iter()
            .position(|entry| entry.active.key == presentation.active.key)
        {
            self.entries.remove(index);
        }
        self.entries.push(presentation);
    }

    fn take(&mut self, key: &RemotePresentationKey) -> Option<RemoteRetainedPresentation> {
        let index = self
            .entries
            .iter()
            .position(|entry| &entry.active.key == key)?;
        Some(self.entries.remove(index))
    }

    fn take_for_selection(
        &mut self,
        selection: &SessionSelection,
    ) -> Option<RemoteRetainedPresentation> {
        let index = self
            .entries
            .iter()
            .position(|entry| &entry.active.selection == selection)?;
        Some(self.entries.remove(index))
    }

    fn selections(&self) -> Vec<SessionSelection> {
        self.entries
            .iter()
            .map(|entry| entry.active.selection.clone())
            .collect()
    }

    fn remove_host(&mut self, host_id: &str) -> bool {
        let before = self.entries.len();
        self.entries
            .retain(|entry| entry.active.selection.host_id() != host_id);
        self.entries.len() != before
    }

    fn reconcile(
        &mut self,
        host_id: &str,
        endpoint: &str,
        route_identity: &str,
        lease_generation: u64,
        inventory: Option<RemoteInventory<'_>>,
    ) -> Vec<RemoteRetainedPresentation> {
        let mut stale = Vec::new();
        let mut index = 0;
        while index < self.entries.len() {
            if self.entries[index].active.key.host_id != host_id {
                index += 1;
                continue;
            }
            let resolved = self.entries[index].active.key.reconcile(
                endpoint,
                route_identity,
                lease_generation,
                inventory,
            );
            match resolved {
                RemoteReconcile::Found(kind, name) => {
                    self.entries[index].active.selection =
                        SessionSelection::for_kind(host_id, endpoint, name, kind);
                    index += 1;
                }
                RemoteReconcile::Unknown => index += 1,
                RemoteReconcile::Stale => stale.push(self.entries.remove(index)),
            }
        }
        stale
    }

    fn drain_events(&mut self, budget: usize) -> RemoteRetainedDrain {
        let mut emitted = Vec::new();
        let mut processed = 0;
        let mut changed = false;
        let mut index = 0;
        while index < self.entries.len() && processed < budget {
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
                    let identity_mismatch_marker =
                        self.entries[index].active.identity_mismatch_marker.clone();
                    self.entries.remove(index);
                    if let Some(error) = classify_remote_terminal_exit(
                        code,
                        &output_tail,
                        identity_mismatch_marker.as_deref(),
                    ) {
                        emitted.push(WorkspaceEvent::Error(error));
                    }
                }
                Err(error) => {
                    processed += 1;
                    changed = true;
                    self.entries.remove(index);
                    emitted.push(WorkspaceEvent::Error(error.to_string()));
                }
                Ok(None) => index += 1,
            }
        }
        RemoteRetainedDrain {
            emitted,
            processed,
            changed,
        }
    }
}

struct SettingsState {
    config: ApplicationConfig,
    roots: Roots,
}

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

fn equivalent_tmux_presentation_key(
    inner: &Inner,
    request: &AttachRequest,
) -> Option<PresentationKey> {
    let published_host = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let host = published_host.as_ref().filter(|published| {
        published.value.snapshot.endpoint() == &request.endpoint
            && published.value.snapshot.runtime() == &request.runtime
    })?;
    worktree_tmux_presentation_key(request, &host.value.snapshot)
}

fn normalize_attached_worktree_target(
    active: &mut ActiveAttachment<AttachRequest>,
    snapshot: &HostSnapshot,
    attached_name: &str,
) -> bool {
    if !matches!(active.request.target, AttachTarget::Worktree { .. }) {
        return false;
    }
    let Some(identity) = snapshot
        .sessions()
        .iter()
        .find(|session| session.name() == attached_name)
        .map(|session| session.identity().clone())
    else {
        return false;
    };
    let previous_key = active.request.presentation_key();
    active.request.target = AttachTarget::Tmux(identity);
    if let Some(fallback) = &mut active.fallback
        && fallback.target == previous_key
    {
        fallback.target = active.request.presentation_key();
    }
    true
}

fn worktree_tmux_presentation_key(
    request: &AttachRequest,
    snapshot: &HostSnapshot,
) -> Option<PresentationKey> {
    let AttachTarget::Worktree { session_name, .. } = &request.target else {
        return None;
    };
    let identity = snapshot
        .sessions()
        .iter()
        .find(|session| session.name() == session_name)?
        .identity()
        .clone();
    Some(PresentationKey {
        host_id: request.host_id.clone(),
        endpoint: request.endpoint.distro().to_owned(),
        socket_directory: request.host.socket_directory().map(str::to_owned),
        runtime: request.runtime.clone(),
        target: AttachTarget::Tmux(identity),
    })
}

fn presentation_is_open(inner: &Inner, key: &PresentationKey) -> bool {
    let active = inner
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .active()
        .is_some_and(|active| active.request.presentation_key() == *key);
    if active {
        return true;
    }
    inner
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .contains(key)
}

fn attach_target_matches_killed_tmux(
    target: &AttachTarget,
    identity: &session::SessionIdentity,
    name: Option<&str>,
    socket_name: Option<&str>,
) -> bool {
    match target {
        AttachTarget::Tmux(target_identity) => target_identity == identity,
        AttachTarget::Worktree { session_name, .. } => {
            socket_name.is_none() && name.is_some_and(|name| session_name == name)
        }
        AttachTarget::ProtectedWorktree {
            session_name,
            tmux_socket_name,
            ..
        } => {
            name.is_some_and(|name| session_name == name)
                && socket_name.is_some_and(|socket| tmux_socket_name == socket)
        }
        AttachTarget::Herdr { .. } | AttachTarget::Zellij { .. } => false,
    }
}

fn request_matches_killed_tmux(
    request: &AttachRequest,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    identity: &session::SessionIdentity,
    name: Option<&str>,
    socket_name: Option<&str>,
) -> bool {
    request.endpoint == *endpoint
        && request.runtime == *runtime
        && attach_target_matches_killed_tmux(&request.target, identity, name, socket_name)
}

fn presentation_key_matches_killed_tmux(
    key: &PresentationKey,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    identity: &session::SessionIdentity,
    name: Option<&str>,
    socket_name: Option<&str>,
) -> bool {
    key.endpoint == endpoint.distro()
        && key.runtime == *runtime
        && attach_target_matches_killed_tmux(&key.target, identity, name, socket_name)
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum AttachTarget {
    Tmux(session::SessionIdentity),
    Worktree {
        repository: String,
        registration_fingerprint: String,
        path: String,
        generation: Option<String>,
        session_name: String,
    },
    ProtectedWorktree {
        repository: String,
        project_path: String,
        registration_fingerprint: String,
        path: String,
        generation: String,
        session_name: String,
        tmux_socket_name: String,
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
            Self::Tmux(_) | Self::Worktree { .. } | Self::ProtectedWorktree { .. } => {
                SessionKind::Tmux
            }
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

#[derive(Clone)]
struct RemoteHerdrCreateRequest {
    host_id: String,
    connection_generation: u64,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    executable: String,
    name: HerdrLaunchTarget,
    precondition: HerdrLaunchPrecondition,
}

#[derive(Clone)]
struct RemoteZellijCreateRequest {
    host_id: String,
    connection_generation: u64,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    executable: String,
    name: ZellijSessionName,
}

#[derive(Clone)]
struct RemoteZellijAttachRequest {
    host_id: String,
    connection_generation: u64,
    selection: SessionSelection,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    executable: String,
    name: String,
}

#[derive(Clone)]
struct RemoteTmuxAttachRequest {
    host_id: String,
    connection_generation: u64,
    selection: SessionSelection,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    session: session::DiscoveredSession,
}

#[derive(Clone)]
struct RemoteHerdrAttachRequest {
    host_id: String,
    connection_generation: u64,
    selection: SessionSelection,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    executable: String,
    session: session::HerdrSessionRecord,
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

#[derive(Clone, Debug, Eq, PartialEq)]
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

impl RemoteHerdrCreateRequest {
    fn constructive_target(&self) -> RemoteConstructiveTarget {
        RemoteConstructiveTarget::Herdr {
            route_identity: self.snapshot.route_identity().to_owned(),
            executable: self.executable.clone(),
            name: self.name.as_str().to_owned(),
            precondition: self.precondition.clone(),
        }
    }
}

impl RemoteZellijCreateRequest {
    fn constructive_target(&self) -> RemoteConstructiveTarget {
        RemoteConstructiveTarget::Zellij {
            route_identity: self.snapshot.route_identity().to_owned(),
            executable: self.executable.clone(),
            name: self.name.as_str().to_owned(),
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
        if let AttachTarget::ProtectedWorktree {
            path,
            generation,
            tmux_socket_name,
            ..
        } = &self.target
        {
            return SessionSelection::protected_worktree(
                &self.host_id,
                self.endpoint.distro(),
                &self.name,
                tmux_socket_name,
                path,
                generation,
            );
        }
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
        self.replace(worker).0
    }

    fn replace(&mut self, worker: T) -> (u64, Option<T>) {
        self.advance_generation();
        let previous = self.worker.replace(worker);
        (self.generation, previous)
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

    fn invalidate_if_generation(&mut self, generation: u64) -> Option<T> {
        if self.generation != generation {
            return None;
        }
        self.invalidate()
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
        AttachTarget::Worktree { session_name, .. }
        | AttachTarget::ProtectedWorktree { session_name, .. } => Some(session_name.clone()),
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
    appearance: RwLock<Appearance>,
    host_scoped_inventory: bool,
    wsl_config: Option<WslConfig>,
    wsl_executable: Mutex<Option<WslExecutable>>,
    state: RwLock<WorkspaceContent>,
    hosts: RwLock<Vec<HostItem>>,
    selected_host: RwLock<Option<String>>,
    inventory_state: Mutex<WorkspaceContent>,
    revision: AtomicU64,
    snapshot_writers: AtomicUsize,
    remote_publication: Mutex<()>,
    presentation_generation: AtomicU64,
    operation_sequence: AtomicU64,
    navigation_generation: AtomicU64,
    navigation: Mutex<()>,
    host: Mutex<Option<Published<HostContext>>>,
    remote_hosts: Mutex<HashMap<String, RemoteEntry>>,
    remote_active: Mutex<Option<RemoteActive>>,
    remote_retained: Mutex<RemoteRetainedPresentations>,
    remote_runner: SharedCommandRunner,
    remote_controller: Option<KwtSshExecutable>,
    ssh_executable: Option<SshExecutable>,
    settings: Mutex<Option<SettingsState>>,
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
    remote_constructive_in_flight: AtomicBool,
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
    kwt_worktree_listing: Mutex<Option<KwtWorktreeListing>>,
    kwt_removal_generation: AtomicU64,
    pending_kwt_removal: Mutex<Option<PendingKwtRemoval>>,
    pending_kwt_creations: Mutex<Vec<PendingKwtCreation>>,
    discovery: Arc<dyn WslDiscovery>,
    refresh_runtime: Arc<dyn RefreshRuntime>,
    attachment: Mutex<AttachmentState<AttachRequest>>,
    terminal_notice: RwLock<Option<WorkspaceNotice>>,
}

#[derive(Clone)]
pub struct Workspace {
    inner: Arc<Inner>,
}

struct SnapshotWrite<'a> {
    writers: &'a AtomicUsize,
}

fn optional_trimmed(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

fn remote_config(settings: &SshHostSettings) -> Result<RemoteTmuxConfig, WorkspaceError> {
    let target = SshTarget::new(
        settings.hostname(),
        settings.user().map(str::to_owned),
        settings.port(),
    )
    .map_err(|error| WorkspaceError::new(error.to_string()))?;
    RemoteTmuxConfig::new(
        settings.id(),
        settings.name(),
        target,
        settings.tmux_binary(),
        settings.socket_directory().map(str::to_owned),
    )
    .map_err(|error| WorkspaceError::new(error.to_string()))
}

fn remote_connection_matches(left: &RemoteTmuxConfig, right: &RemoteTmuxConfig) -> bool {
    left.id() == right.id()
        && left.target() == right.target()
        && left.tmux_binary() == right.tmux_binary()
        && left.socket_directory() == right.socket_directory()
}

fn request_ssh_prompt(
    inner: &Inner,
    host_id: &str,
    generation: u64,
    prompt: &SshLeasePrompt,
    cancellation: &CancellationToken,
) -> Result<String, host::SshError> {
    let wait = prompt.remaining()?.min(SSH_PROMPT_TIMEOUT);
    if wait.is_zero() {
        return Err(host::SshError::prompt_cancelled());
    }
    let deadline = Instant::now() + wait;
    let (sender, receiver) = sync_channel(1);
    let request = SshPromptRequest {
        host_id: host_id.to_owned(),
        generation,
        prompt: prompt.clone(),
        response: Arc::new(Mutex::new(Some(sender))),
    };
    push_operation_event(inner, WorkspaceEvent::SshPrompt(request));
    inner.revision.fetch_add(1, Ordering::Release);
    let result = loop {
        if cancellation.is_cancelled() {
            break Err(host::SshError::prompt_cancelled());
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break Err(host::SshError::prompt_cancelled());
        }
        match receiver.recv_timeout(remaining.min(Duration::from_millis(100))) {
            Ok(Some(value)) => break Ok(value),
            Ok(None) | Err(RecvTimeoutError::Disconnected) => {
                break Err(host::SshError::prompt_cancelled());
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
    };
    push_operation_event(
        inner,
        WorkspaceEvent::SshPromptDismissed {
            host_id: host_id.to_owned(),
            generation,
        },
    );
    inner.revision.fetch_add(1, Ordering::Release);
    result
}

fn remote_host_for_connection(
    inner: &Inner,
    config: RemoteTmuxConfig,
    native_host: Option<RuntimeRemoteHost>,
    cancellation: &CancellationToken,
) -> Result<RuntimeRemoteHost, host::RemoteTmuxError> {
    if let Some(host) = native_host {
        return Ok(host);
    }
    let (wsl_host, snapshot) = inner
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .map(|context| (context.value.host.clone(), context.value.snapshot.clone()))
        .ok_or_else(|| {
            host::RemoteTmuxError::transport("Connect the WSL host before connecting an SSH host")
        })?;
    wsl_host
        .remote_tmux_host(
            snapshot.endpoint(),
            snapshot.runtime(),
            config,
            cancellation,
        )
        .map_err(|error| host::RemoteTmuxError::from_host(&error))
}

fn publish_remote_connection(
    inner: &Inner,
    host_id: &str,
    generation: u64,
    result: Result<(RuntimeRemoteHost, RemoteTmuxSnapshot), host::RemoteTmuxError>,
) {
    let publication = inner
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let snapshot_write = begin_snapshot_write(inner);
    let mut stale_presentations = Vec::new();
    let pending_reconciliation;
    let mut entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get_mut(host_id) else {
        return;
    };
    if entry.generation != generation {
        return;
    }
    entry.cancellation = None;
    match result {
        Ok((host, snapshot)) => {
            let endpoint = snapshot.endpoint().to_owned();
            let route_identity = snapshot.route_identity().to_owned();
            let lease_generation = snapshot.lease_generation();
            pending_reconciliation =
                entry
                    .constructive_cancellation
                    .as_ref()
                    .and_then(|operation| match operation {
                        RemoteConstructiveState::PendingReconciliation(target) => {
                            Some((host.clone(), snapshot.clone(), target.clone()))
                        }
                        RemoteConstructiveState::Active { .. } => None,
                    });
            entry.context = Some(RemoteHostContext {
                generation,
                host,
                snapshot: snapshot.clone(),
            });
            drop(entries);
            stale_presentations = reconcile_remote_presentations(
                inner,
                host_id,
                &endpoint,
                &route_identity,
                lease_generation,
                Some(RemoteInventory::from(&snapshot)),
            );
            set_remote_host_snapshot(inner, host_id, &snapshot);
        }
        Err(error) => {
            let diagnostic = HostDiagnostic::new(error.kind(), error.to_string());
            cancel_remote_constructive(entry);
            cancel_remote_attachment(entry);
            let stale_context = entry.context.take();
            drop(entries);
            set_remote_host_state(
                inner,
                host_id,
                HostConnectionState::Unavailable,
                None,
                Some(diagnostic),
            );
            drop(snapshot_write);
            drop(stale_context);
            drop(stale_presentations);
            drop(publication);
            return;
        }
    }
    drop(snapshot_write);
    drop(stale_presentations);
    drop(publication);
    if let Some((host, snapshot, target)) = pending_reconciliation {
        reconcile_remote_constructive_after_connection(
            inner, host_id, generation, &host, snapshot, &target,
        );
    }
}

fn reconcile_remote_constructive_after_connection(
    inner: &Inner,
    host_id: &str,
    generation: u64,
    host: &RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    target: &RemoteConstructiveTarget,
) {
    reconcile_remote_constructive_with_backoff(
        inner,
        host_id,
        generation,
        snapshot,
        target,
        &HERDR_STARTUP_BACKOFF,
        |snapshot, cancellation| host.refresh(snapshot.lease(), cancellation),
    );
}

fn reconcile_remote_constructive_with_backoff<E>(
    inner: &Inner,
    host_id: &str,
    generation: u64,
    mut snapshot: RemoteTmuxSnapshot,
    target: &RemoteConstructiveTarget,
    backoff: &[Duration],
    mut refresh: impl FnMut(
        &RemoteTmuxSnapshot,
        &CancellationToken,
    ) -> Result<RemoteSessionInventory, E>,
) {
    if remote_constructive_target_is_present(&snapshot, target) {
        clear_pending_remote_constructive(inner, host_id, generation, target);
        return;
    }
    let cancellation = CancellationToken::new();
    for delay in backoff {
        thread::sleep(*delay);
        let Some(current) =
            pending_remote_constructive_snapshot(inner, host_id, generation, target)
        else {
            return;
        };
        snapshot = current;
        if remote_constructive_target_is_present(&snapshot, target) {
            clear_pending_remote_constructive(inner, host_id, generation, target);
            return;
        }
        let Ok(inventory) = refresh(&snapshot, &cancellation) else {
            continue;
        };
        let Ok(refreshed) = publish_remote_inventory(
            inner,
            host_id,
            generation,
            &snapshot,
            &cancellation,
            inventory,
        ) else {
            // Another same-connection probe may have published first. The
            // next attempt must reconcile against that authoritative snapshot
            // rather than leaving the constructive operation permanently
            // reserved by stale publication authority.
            continue;
        };
        snapshot = refreshed;
        if remote_constructive_target_is_present(&snapshot, target) {
            clear_pending_remote_constructive(inner, host_id, generation, target);
            return;
        }
    }
    clear_pending_remote_constructive(inner, host_id, generation, target);
}

fn remote_constructive_target_is_present(
    snapshot: &RemoteTmuxSnapshot,
    target: &RemoteConstructiveTarget,
) -> bool {
    match target {
        RemoteConstructiveTarget::Herdr {
            route_identity,
            executable,
            name,
            precondition,
        } => {
            snapshot.route_identity() == route_identity
                && matches!(
                    snapshot.herdr(),
                    HerdrInventory::Available {
                        executable: current_executable,
                        sessions,
                    } if current_executable == executable
                        && sessions.iter().any(|session| {
                            herdr_launch_result_matches(precondition, name, session)
                        })
                )
        }
        RemoteConstructiveTarget::Zellij {
            route_identity,
            executable,
            name,
        } => {
            snapshot.route_identity() == route_identity
                && matches!(
                    snapshot.zellij(),
                    ZellijInventory::Available {
                        executable: current_executable,
                        sessions,
                    } if current_executable == executable
                        && sessions.iter().any(|session| session.name() == name)
                )
        }
    }
}

fn pending_remote_constructive_snapshot(
    inner: &Inner,
    host_id: &str,
    generation: u64,
    target: &RemoteConstructiveTarget,
) -> Option<RemoteTmuxSnapshot> {
    inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(host_id)
        .and_then(|entry| {
            (entry.generation == generation
                && matches!(
                    entry.constructive_cancellation.as_ref(),
                    Some(RemoteConstructiveState::PendingReconciliation(current))
                        if current == target
                ))
            .then_some(entry.context.as_ref())
            .flatten()
            .filter(|context| context.generation == generation)
            .map(|context| context.snapshot.clone())
        })
}

#[cfg(test)]
fn pending_remote_constructive_target(
    inner: &Inner,
    host_id: &str,
) -> Option<RemoteConstructiveTarget> {
    inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(host_id)
        .and_then(|entry| match entry.constructive_cancellation.as_ref() {
            Some(RemoteConstructiveState::PendingReconciliation(target)) => Some(target.clone()),
            Some(RemoteConstructiveState::Active { .. }) | None => None,
        })
}

fn clear_pending_remote_constructive(
    inner: &Inner,
    host_id: &str,
    generation: u64,
    target: &RemoteConstructiveTarget,
) {
    let mut entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get_mut(host_id) else {
        return;
    };
    if entry.generation == generation
        && matches!(
            entry.constructive_cancellation.as_ref(),
            Some(RemoteConstructiveState::PendingReconciliation(current)) if current == target
        )
    {
        entry.constructive_cancellation = None;
    }
}

fn reconcile_remote_presentations(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    route_identity: &str,
    lease_generation: u64,
    inventory: Option<RemoteInventory<'_>>,
) -> Vec<RemoteRetainedPresentation> {
    let _navigation = inner
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let terminal_update = {
        let mut remote_active = inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active) = remote_active
            .as_mut()
            .filter(|active| active.key.host_id == host_id)
        else {
            return inner
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .reconcile(
                    host_id,
                    endpoint,
                    route_identity,
                    lease_generation,
                    inventory,
                );
        };
        match active
            .key
            .reconcile(endpoint, route_identity, lease_generation, inventory)
        {
            RemoteReconcile::Found(kind, name) => {
                active.retainable = retain_remote_session(kind);
                let selection = SessionSelection::for_kind(host_id, endpoint, name, kind);
                if active.selection == selection {
                    None
                } else {
                    active.selection = selection;
                    let worker = inner
                        .worker
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if worker.generation() == active.worker_generation {
                        worker.active().map(|worker| {
                            (
                                active.selection.clone(),
                                active.presentation_id,
                                worker.surface_handle(),
                            )
                        })
                    } else {
                        None
                    }
                }
            }
            RemoteReconcile::Unknown => None,
            RemoteReconcile::Stale => {
                active.retainable = false;
                None
            }
        }
    };
    let stale = inner
        .remote_retained
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .reconcile(
            host_id,
            endpoint,
            route_identity,
            lease_generation,
            inventory,
        );
    if let Some((selection, presentation_id, surface)) = terminal_update {
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
    }
    stale
}

fn set_remote_host_snapshot(inner: &Inner, host_id: &str, snapshot: &RemoteTmuxSnapshot) {
    let mut hosts = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == host_id) else {
        return;
    };
    host.connection = HostConnectionState::Ready;
    host.sessions = snapshot
        .sessions()
        .iter()
        .map(|session| SessionItem::new(session.name(), session.attached_clients()))
        .collect();
    host.diagnostic = None;
    host.tmux_available = snapshot.tmux_binary().is_some();
    host.tmux_diagnostic = snapshot
        .tmux_diagnostic()
        .map(|error| HostDiagnostic::new(error.kind(), error.to_string()));
    apply_herdr_inventory(host, snapshot.herdr());
    apply_zellij_inventory(host, snapshot.zellij());
    inner.revision.fetch_add(1, Ordering::Release);
}

fn set_remote_herdr_launch_pending(inner: &Inner, host_id: &str, name: &str, pending: bool) {
    let mut hosts = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(session) = hosts
        .iter_mut()
        .find(|host| host.id == host_id)
        .and_then(|host| {
            host.herdr_sessions
                .iter_mut()
                .find(|session| session.name == name)
        })
    else {
        return;
    };
    if session.launch_pending != pending {
        session.launch_pending = pending;
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn set_remote_host_state(
    inner: &Inner,
    host_id: &str,
    connection: HostConnectionState,
    sessions: Option<Vec<SessionItem>>,
    diagnostic: Option<HostDiagnostic>,
) {
    let mut hosts = inner
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == host_id) else {
        return;
    };
    host.connection = connection;
    if let Some(sessions) = sessions {
        host.sessions = sessions;
    }
    host.diagnostic = diagnostic;
    inner.revision.fetch_add(1, Ordering::Release);
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
            active_selection: None,
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
                appearance: RwLock::new(snapshot.appearance),
                host_scoped_inventory: false,
                wsl_config: None,
                wsl_executable: Mutex::new(None),
                state: RwLock::new(snapshot.content.clone()),
                hosts: RwLock::new(snapshot.hosts),
                selected_host: RwLock::new(snapshot.selected_host),
                inventory_state: Mutex::new(snapshot.content),
                revision: AtomicU64::new(snapshot.revision),
                snapshot_writers: AtomicUsize::new(0),
                remote_publication: Mutex::new(()),
                presentation_generation: AtomicU64::new(presentation_generation),
                operation_sequence: AtomicU64::new(0),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                remote_hosts: Mutex::new(HashMap::new()),
                remote_active: Mutex::new(None),
                remote_retained: Mutex::new(RemoteRetainedPresentations::new()),
                remote_runner: Arc::new(StdCommandRunner),
                remote_controller: None,
                ssh_executable: None,
                settings: Mutex::new(None),
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
                remote_constructive_in_flight: AtomicBool::new(false),
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
                kwt_worktree_listing: Mutex::new(None),
                kwt_removal_generation: AtomicU64::new(0),
                pending_kwt_removal: Mutex::new(None),
                pending_kwt_creations: Mutex::new(Vec::new()),
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

    /// Build the application workspace with disconnected configured SSH hosts.
    ///
    /// # Panics
    ///
    /// Panics only if the newly constructed workspace unexpectedly has another
    /// strong owner before composition finishes.
    #[must_use]
    pub fn application_with_remote_hosts(
        appearance: TerminalAppearance,
        wsl: Option<WslHostSpec>,
        remote_specs: Vec<RemoteHostSpec>,
        settings: ApplicationConfig,
        roots: Roots,
        controller: Option<KwtSshExecutable>,
        ssh: Option<SshExecutable>,
    ) -> Self {
        let mut workspace = Self::application(appearance, wsl);
        let inner = Arc::get_mut(&mut workspace.inner)
            .expect("newly constructed workspace has one strong owner");
        inner.remote_controller = controller;
        inner.ssh_executable = ssh;
        *inner
            .settings
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(SettingsState {
            config: settings,
            roots,
        });
        let runner = Arc::clone(&inner.remote_runner);
        let entries = inner
            .remote_hosts
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let hosts = inner
            .hosts
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for spec in remote_specs {
            let item = spec.host_item();
            if spec.diagnostic.is_none() {
                entries.insert(
                    item.id().to_owned(),
                    RemoteEntry {
                        config: spec.config.clone(),
                        native_host: spec.runtime_host(Arc::clone(&runner)),
                        context: None,
                        cancellation: None,
                        constructive_cancellation: None,
                        attachment_attempt: None,
                        generation: 0,
                    },
                );
            }
            hosts.push(item);
        }
        if inner
            .selected_host
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_none()
        {
            *inner
                .selected_host
                .get_mut()
                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                hosts.first().map(|host| host.id().to_owned());
        }
        workspace
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
                appearance: RwLock::new(appearance.into()),
                host_scoped_inventory: true,
                wsl_config,
                wsl_executable: Mutex::new(wsl_executable),
                state: RwLock::new(WorkspaceContent::Shell),
                hosts: RwLock::new(hosts),
                selected_host: RwLock::new(selected_host),
                inventory_state: Mutex::new(WorkspaceContent::Shell),
                revision: AtomicU64::new(0),
                snapshot_writers: AtomicUsize::new(0),
                remote_publication: Mutex::new(()),
                presentation_generation: AtomicU64::new(0),
                operation_sequence: AtomicU64::new(0),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                remote_hosts: Mutex::new(HashMap::new()),
                remote_active: Mutex::new(None),
                remote_retained: Mutex::new(RemoteRetainedPresentations::new()),
                remote_runner: Arc::new(StdCommandRunner),
                remote_controller: None,
                ssh_executable: None,
                settings: Mutex::new(None),
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
                remote_constructive_in_flight: AtomicBool::new(false),
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
                kwt_worktree_listing: Mutex::new(None),
                kwt_removal_generation: AtomicU64::new(0),
                pending_kwt_removal: Mutex::new(None),
                pending_kwt_creations: Mutex::new(Vec::new()),
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
                appearance: RwLock::new(appearance.into()),
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
                remote_publication: Mutex::new(()),
                presentation_generation: AtomicU64::new(0),
                operation_sequence: AtomicU64::new(0),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                remote_hosts: Mutex::new(HashMap::new()),
                remote_active: Mutex::new(None),
                remote_retained: Mutex::new(RemoteRetainedPresentations::new()),
                remote_runner: Arc::new(StdCommandRunner),
                remote_controller: None,
                ssh_executable: None,
                settings: Mutex::new(None),
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
                remote_constructive_in_flight: AtomicBool::new(false),
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
                kwt_worktree_listing: Mutex::new(None),
                kwt_removal_generation: AtomicU64::new(0),
                pending_kwt_removal: Mutex::new(None),
                pending_kwt_creations: Mutex::new(Vec::new()),
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

    #[must_use]
    pub fn configured_ssh_hosts(&self) -> Vec<ConfiguredSshHost> {
        self.inner
            .settings
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map(|settings| {
                settings
                    .config
                    .ssh_hosts()
                    .iter()
                    .map(|host| ConfiguredSshHost {
                        id: host.id(),
                        draft: host.into(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    #[must_use]
    pub fn configured_appearance(&self) -> AppearanceSettingsDraft {
        self.inner
            .settings
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(
                || {
                    let appearance = self
                        .inner
                        .appearance
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    AppearanceSettingsDraft::from(&*appearance)
                },
                |settings| AppearanceSettingsDraft::from(settings.config.terminal()),
            )
    }

    #[must_use]
    pub fn configured_terminal_settings(&self) -> TerminalSettingsDraft {
        self.inner
            .settings
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(
                || {
                    let appearance = self
                        .inner
                        .appearance
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    TerminalSettingsDraft::from(&*appearance)
                },
                |settings| TerminalSettingsDraft::from(settings.config.terminal()),
            )
    }

    /// Persist terminal appearance settings and publish them to the running
    /// workspace. Existing clients keep their negotiated terminal palette;
    /// the UI and newly opened clients use the saved values immediately.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid values, unavailable settings storage, or
    /// an I/O failure.
    pub fn save_appearance(&self, draft: &AppearanceSettingsDraft) -> Result<(), WorkspaceError> {
        let font_size = draft
            .font_size
            .trim()
            .parse::<u16>()
            .map_err(|_| WorkspaceError::new("Font size must be a number from 1 to 65535"))?;
        let appearance = {
            let mut settings = self
                .inner
                .settings
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let settings = settings
                .as_mut()
                .ok_or_else(|| WorkspaceError::new("Appearance settings storage is unavailable"))?;
            let appearance = TerminalAppearance::themed(
                draft.theme,
                draft.font_family.trim(),
                font_size,
                draft.background.trim(),
                draft.foreground.trim(),
                settings.config.terminal().allow_remote_clipboard_write(),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))?
            .with_terminal_preferences(
                settings.config.terminal().cursor_style(),
                settings.config.terminal().allow_shell_integration_cursor(),
                settings.config.terminal().hide_mouse_while_typing(),
            );
            let roots = settings.roots.clone();
            settings
                .config
                .replace_terminal_appearance(&roots, appearance.clone())
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            appearance
        };
        let _snapshot_write = begin_snapshot_write(&self.inner);
        *self
            .inner
            .appearance
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = appearance.into();
        self.inner.revision.fetch_add(1, Ordering::Release);
        Ok(())
    }

    /// Persist terminal interaction settings and publish them to the running workspace.
    ///
    /// # Errors
    ///
    /// Returns an error when settings storage is unavailable or cannot be written.
    pub fn save_terminal_settings(
        &self,
        draft: &TerminalSettingsDraft,
    ) -> Result<(), WorkspaceError> {
        let appearance = {
            let mut settings = self
                .inner
                .settings
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let settings = settings
                .as_mut()
                .ok_or_else(|| WorkspaceError::new("Terminal settings storage is unavailable"))?;
            let appearance = settings
                .config
                .terminal()
                .clone()
                .with_terminal_preferences(
                    draft.cursor_style,
                    draft.allow_shell_integration_cursor,
                    draft.hide_mouse_while_typing,
                );
            let roots = settings.roots.clone();
            settings
                .config
                .replace_terminal_appearance(&roots, appearance.clone())
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            appearance
        };
        let _snapshot_write = begin_snapshot_write(&self.inner);
        *self
            .inner
            .appearance
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = appearance.into();
        self.inner.revision.fetch_add(1, Ordering::Release);
        Ok(())
    }

    /// Persist a new or edited SSH host and publish its disconnected row.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid fields, duplicate endpoints, unavailable
    /// settings storage, or an I/O failure.
    pub fn save_ssh_host(
        &self,
        original_id: Option<&str>,
        draft: &SshHostDraft,
    ) -> Result<String, WorkspaceError> {
        let port =
            if draft.port.trim().is_empty() {
                None
            } else {
                Some(
                    draft.port.trim().parse::<u16>().map_err(|_| {
                        WorkspaceError::new("Port must be a number from 1 to 65535")
                    })?,
                )
            };
        let host = SshHostSettings::new(
            draft.name.trim(),
            draft.hostname.trim(),
            optional_trimmed(&draft.user),
            port,
            draft.tmux_binary.trim(),
            optional_trimmed(&draft.socket_directory),
        )
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let id = host.id();
        {
            let mut settings = self
                .inner
                .settings
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let settings = settings
                .as_mut()
                .ok_or_else(|| WorkspaceError::new("SSH settings storage is unavailable"))?;
            let mut hosts = settings.config.ssh_hosts().to_vec();
            if let Some(original_id) = original_id {
                let index = hosts
                    .iter()
                    .position(|candidate| candidate.id() == original_id)
                    .ok_or_else(|| WorkspaceError::new("SSH host changed; reopen Settings"))?;
                hosts[index] = host.clone();
            } else {
                hosts.push(host.clone());
            }
            let roots = settings.roots.clone();
            settings
                .config
                .replace_ssh_hosts(&roots, hosts)
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
        }
        self.publish_saved_ssh_host(original_id, &host)?;
        Ok(id)
    }

    /// Remove one configured SSH host after disconnecting its local clients.
    ///
    /// # Errors
    ///
    /// Returns an error if the host changed or configuration cannot be saved.
    pub fn remove_ssh_host(&self, id: &str) -> Result<(), WorkspaceError> {
        {
            let mut settings = self
                .inner
                .settings
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let settings = settings
                .as_mut()
                .ok_or_else(|| WorkspaceError::new("SSH settings storage is unavailable"))?;
            let mut hosts = settings.config.ssh_hosts().to_vec();
            let previous_len = hosts.len();
            hosts.retain(|host| host.id() != id);
            if hosts.len() == previous_len {
                return Err(WorkspaceError::new("SSH host changed; reopen Settings"));
            }
            let roots = settings.roots.clone();
            settings
                .config
                .replace_ssh_hosts(&roots, hosts)
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
        }
        self.remove_ssh_host_runtime(id);
        Ok(())
    }

    /// Select one current host without starting a connection.
    ///
    /// # Errors
    ///
    /// Returns an error when the host is no longer configured.
    pub fn select_host(&self, id: &str) -> Result<(), WorkspaceError> {
        let exists = self
            .inner
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .any(|host| host.id() == id);
        if !exists {
            return Err(WorkspaceError::new("host is no longer configured"));
        }
        *self
            .inner
            .selected_host
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(id.to_owned());
        self.inner.revision.fetch_add(1, Ordering::Release);
        Ok(())
    }

    /// Explicitly connect or refresh one host.
    ///
    /// # Errors
    ///
    /// Returns an error when the host no longer exists or its background task
    /// cannot be scheduled.
    pub fn connect_host(&self, id: &str) -> Result<(), WorkspaceError> {
        self.select_host(id)?;
        if id == "wsl" {
            return self.refresh();
        }
        let generation = self.inner.operation_sequence.fetch_add(1, Ordering::AcqRel) + 1;
        let cancellation = CancellationToken::new();
        let (config, native_host) = {
            let _publication = self
                .inner
                .remote_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let _snapshot_write = begin_snapshot_write(&self.inner);
            let connection = {
                let mut entries = self
                    .inner
                    .remote_hosts
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let entry = entries
                    .get_mut(id)
                    .ok_or_else(|| WorkspaceError::new("SSH host is unavailable in this build"))?;
                cancel_remote_constructive(entry);
                cancel_remote_attachment(entry);
                if let Some(previous) = entry.cancellation.replace(cancellation.clone()) {
                    previous.cancel();
                }
                entry.generation = generation;
                (entry.config.clone(), entry.native_host.clone())
            };
            set_remote_host_state(&self.inner, id, HostConnectionState::Connecting, None, None);
            connection
        };
        let inner = Arc::clone(&self.inner);
        let host_id = id.to_owned();
        if let Err(error) = self.inner.refresh_runtime.spawn(
            "ghosthub-ssh-connect",
            Box::new(move || {
                let prompt_inner = Arc::clone(&inner);
                let prompt_host = host_id.clone();
                let prompt_cancel = cancellation.clone();
                let result = remote_host_for_connection(&inner, config, native_host, &cancellation)
                    .and_then(|host| {
                        host.connect(
                            &cancellation,
                            move |prompt| {
                                request_ssh_prompt(
                                    &prompt_inner,
                                    &prompt_host,
                                    generation,
                                    prompt,
                                    &prompt_cancel,
                                )
                            },
                            |_| {},
                        )
                        .map(|snapshot| (host, snapshot))
                    });
                publish_remote_connection(&inner, &host_id, generation, result);
            }),
        ) {
            let stale_context = {
                let _publication = self
                    .inner
                    .remote_publication
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let _snapshot_write = begin_snapshot_write(&self.inner);
                let stale_context = self
                    .inner
                    .remote_hosts
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .get_mut(id)
                    .filter(|entry| entry.generation == generation)
                    .map(|entry| {
                        entry.cancellation.take();
                        entry.context.take()
                    });
                if stale_context.is_some() {
                    set_remote_host_state(
                        &self.inner,
                        id,
                        HostConnectionState::Disconnected,
                        None,
                        None,
                    );
                }
                stale_context.flatten()
            };
            drop(stale_context);
            return Err(WorkspaceError::new(format!(
                "start SSH connection: {error}"
            )));
        }
        Ok(())
    }

    #[must_use]
    pub fn cancel_host_connection(&self, id: &str) -> bool {
        if id == "wsl" {
            return self.cancel_refresh();
        }
        let cancelled = {
            let _publication = self
                .inner
                .remote_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let _snapshot_write = begin_snapshot_write(&self.inner);
            let cancelled = {
                let mut entries = self
                    .inner
                    .remote_hosts
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                entries.get_mut(id).and_then(|entry| {
                    let cancellation = entry.cancellation.take()?;
                    entry.generation = entry.generation.wrapping_add(1).max(1);
                    Some((cancellation, entry.context.take()))
                })
            };
            if cancelled.is_some() {
                set_remote_host_state(
                    &self.inner,
                    id,
                    HostConnectionState::Disconnected,
                    None,
                    None,
                );
            }
            cancelled
        };
        if let Some((cancellation, stale_context)) = cancelled {
            cancellation.cancel();
            drop(stale_context);
            true
        } else {
            false
        }
    }

    #[must_use]
    pub fn ssh_prompt_is_current(&self, host_id: &str, generation: u64) -> bool {
        self.inner
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(host_id)
            .is_some_and(|entry| entry.generation == generation && entry.cancellation.is_some())
    }

    fn update_ssh_host_metadata(
        &self,
        original_id: Option<&str>,
        config: &RemoteTmuxConfig,
    ) -> bool {
        if original_id != Some(config.id()) {
            return false;
        }
        let _snapshot_write = begin_snapshot_write(&self.inner);
        {
            let mut entries = self
                .inner
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(entry) = entries
                .get_mut(config.id())
                .filter(|entry| remote_connection_matches(&entry.config, config))
            else {
                return false;
            };
            entry.config = config.clone();
        }
        if let Some(item) = self
            .inner
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter_mut()
            .find(|item| item.id() == config.id())
        {
            config.name().clone_into(&mut item.name);
            item.endpoint = config.endpoint();
        }
        self.inner.revision.fetch_add(1, Ordering::Release);
        true
    }

    fn publish_saved_ssh_host(
        &self,
        original_id: Option<&str>,
        settings: &SshHostSettings,
    ) -> Result<(), WorkspaceError> {
        let config = remote_config(settings)?;
        let new_id = config.id().to_owned();
        if self.update_ssh_host_metadata(original_id, &config) {
            return Ok(());
        }
        let selected_original = original_id.is_some_and(|original_id| {
            self.inner
                .selected_host
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_deref()
                == Some(original_id)
        });
        if let Some(original_id) = original_id {
            self.remove_ssh_host_runtime(original_id);
        }
        #[cfg(windows)]
        let dependencies_available = self
            .inner
            .wsl_executable
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some();
        #[cfg(not(windows))]
        let dependencies_available =
            self.inner.remote_controller.is_some() && self.inner.ssh_executable.is_some();
        let item = HostItem::ssh(
            config.id(),
            config.name(),
            config.endpoint(),
            if dependencies_available {
                HostConnectionState::Disconnected
            } else {
                HostConnectionState::Unavailable
            },
            Vec::new(),
            (!dependencies_available).then(|| {
                HostDiagnostic::new(
                    DiagnosticKind::ExecutableNotFound,
                    "SSH support is unavailable in this build",
                )
            }),
        );
        #[cfg(windows)]
        let runtime = None;
        #[cfg(not(windows))]
        let runtime = self
            .inner
            .remote_controller
            .as_ref()
            .zip(self.inner.ssh_executable.as_ref())
            .map(|(controller, ssh)| {
                RemoteTmuxHost::new(
                    config.clone(),
                    controller,
                    ssh,
                    Arc::clone(&self.inner.remote_runner),
                )
            });
        let _snapshot_write = begin_snapshot_write(&self.inner);
        if dependencies_available {
            self.inner
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(
                    settings.id(),
                    RemoteEntry {
                        config,
                        native_host: runtime,
                        context: None,
                        cancellation: None,
                        constructive_cancellation: None,
                        attachment_attempt: None,
                        generation: 0,
                    },
                );
        }
        self.inner
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(item);
        if selected_original {
            *self
                .inner
                .selected_host
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(new_id);
        }
        self.inner.revision.fetch_add(1, Ordering::Release);
        Ok(())
    }

    fn remove_ssh_host_runtime(&self, id: &str) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        if let Some(mut entry) = self
            .inner
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(id)
        {
            if let Some(cancellation) = entry.cancellation.take() {
                cancellation.cancel();
            }
            cancel_remote_constructive(&mut entry);
            cancel_remote_attachment(&mut entry);
        }
        let active_matches = self
            .inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_some_and(|active| active.selection.host_id() == id);
        if active_matches {
            self.detach();
        }
        self.inner
            .remote_retained
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove_host(id);
        self.inner
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .retain(|host| host.id() != id);
        let selected_removed = self
            .inner
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref()
            == Some(id);
        if selected_removed {
            *self
                .inner
                .selected_host
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = self
                .inner
                .hosts
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .first()
                .map(|host| host.id().to_owned());
        }
        self.inner.revision.fetch_add(1, Ordering::Release);
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
    ) -> Result<u64, WorkspaceError> {
        self.start_kwt_worktree_operation(
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            KwtWorktreeOperation::Branches,
        )
    }

    /// Load open pull requests through KWT for one authoritative project.
    ///
    /// # Errors
    ///
    /// Returns an error when the project is stale or another KWT operation is active.
    pub fn load_kwt_pull_requests(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        project_path: &str,
        registration_fingerprint: &str,
    ) -> Result<u64, WorkspaceError> {
        self.start_kwt_worktree_operation(
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            KwtWorktreeOperation::PullRequests,
        )
    }

    /// Import one KWT pull request and navigate to its protected workspace.
    ///
    /// # Errors
    ///
    /// Returns an error for an empty selector, stale project authority, or a
    /// concurrently running KWT operation.
    pub fn import_kwt_pull_request(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        project_path: &str,
        registration_fingerprint: &str,
        selector: &str,
    ) -> Result<u64, WorkspaceError> {
        let selector = selector.trim();
        if selector.is_empty() {
            return Err(WorkspaceError::new("Choose a pull request to import."));
        }
        let navigation_generation = self.begin_navigation();
        let operation_id = self.start_kwt_worktree_operation(
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            KwtWorktreeOperation::ImportPullRequest {
                selector: selector.to_owned(),
                navigation_generation,
            },
        )?;
        debug_assert_eq!(operation_id, navigation_generation);
        Ok(navigation_generation)
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
    ) -> Result<u64, WorkspaceError> {
        let branch = branch.trim();
        if !is_valid_git_branch_name(branch) {
            return Err(WorkspaceError::new("Enter a valid Git branch name."));
        }
        let navigation_generation = self.begin_navigation();
        let operation_id = self.start_kwt_worktree_operation(
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            KwtWorktreeOperation::Create {
                branch: branch.to_owned(),
                source: source.map(str::to_owned),
                creates_branch,
                navigation_generation,
            },
        )?;
        debug_assert_eq!(operation_id, navigation_generation);
        Ok(navigation_generation)
    }

    /// Capture the exact live tmux identity, if any, before presenting a
    /// worktree-removal confirmation.
    ///
    /// # Errors
    ///
    /// Returns an error for stale inventory or when the background identity
    /// query cannot be started.
    #[allow(clippy::too_many_arguments)]
    pub fn request_kwt_worktree_removal(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        project_path: &str,
        registration_fingerprint: &str,
        worktree_path: &str,
        generation: &str,
        session_name: &str,
        tmux_socket_name: Option<&str>,
    ) -> Result<u64, WorkspaceError> {
        if !is_canonical_kwt_generation(generation) {
            return Err(WorkspaceError::new(
                "Refresh KWT inventory before removing this worktree.",
            ));
        }
        let (host, resolved_endpoint, runtime, socket_name) = capture_kwt_worktree_removal_context(
            &self.inner,
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            worktree_path,
            generation,
            session_name,
            tmux_socket_name,
        )?;
        let mut pending = self
            .inner
            .pending_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let authority = self
            .inner
            .kwt_removal_generation
            .fetch_add(1, Ordering::AcqRel)
            + 1;
        pending.take();
        drop(pending);
        let capture = KwtRemovalCapture {
            host,
            authority,
            endpoint: resolved_endpoint,
            runtime,
            repository: repository.to_owned(),
            project_path: project_path.to_owned(),
            registration_fingerprint: registration_fingerprint.to_owned(),
            worktree_path: worktree_path.to_owned(),
            generation: generation.to_owned(),
            session_name: session_name.to_owned(),
            socket_name,
        };
        let inner = Arc::clone(&self.inner);
        self.inner
            .refresh_runtime
            .spawn(
                "ghosthub-kwt-removal-identity",
                Box::new(move || capture_kwt_removal_authority(&inner, capture)),
            )
            .map_err(|error| WorkspaceError::new(format!("verify worktree session: {error}")))?;
        Ok(authority)
    }

    pub fn cancel_kwt_worktree_removal(&self) {
        let mut pending = self
            .inner
            .pending_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.inner
            .kwt_removal_generation
            .fetch_add(1, Ordering::AcqRel);
        pending.take();
    }

    /// Cancel the exact branch or pull-request listing owned by a project dialog.
    ///
    /// Cancellation invalidates the listing's publication generation and
    /// releases the KWT operation lane immediately. A late task completion is
    /// fenced by the removed ownership record and cannot settle a replacement.
    #[must_use]
    pub fn cancel_kwt_worktree_listing(&self, operation_id: u64) -> bool {
        let listing = {
            let mut active = self
                .inner
                .kwt_worktree_listing
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if active
                .as_ref()
                .is_none_or(|listing| listing.operation_id != operation_id)
            {
                return false;
            }
            let Some(listing) = active.take() else {
                return false;
            };
            listing
        };
        listing.cancellation.cancel();
        {
            let _publication = self
                .inner
                .kwt_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let _generation = self.inner.kwt_refresh_generation.compare_exchange(
                listing.generation,
                listing.generation.saturating_add(1),
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
        finish_kwt_project_mutation(&self.inner, None);
        true
    }

    /// Remove one exact non-main KWT worktree while preserving its Git branch.
    ///
    /// The operation revalidates the project, worktree generation, WSL
    /// runtime, and expected tmux state off the UI thread. Ghosthub terminates
    /// a freshly confirmed exact tmux identity first; KWT then requires that
    /// workspace session to remain absent while it removes the checkout under
    /// the same lifecycle fence used by guarded open.
    ///
    /// # Errors
    ///
    /// Returns an error for stale inventory, main worktrees, missing durable
    /// generation, or another KWT operation already in progress.
    #[allow(clippy::too_many_arguments)]
    pub fn remove_kwt_worktree(
        &self,
        host_id: &str,
        endpoint: &str,
        repository: &str,
        project_path: &str,
        registration_fingerprint: &str,
        worktree_path: &str,
        generation: &str,
        session_name: &str,
        authority: u64,
    ) -> Result<(), WorkspaceError> {
        if !is_canonical_kwt_generation(generation) {
            return Err(WorkspaceError::new(
                "Refresh KWT inventory before removing this worktree.",
            ));
        }
        let pending = take_pending_kwt_removal(
            &self.inner,
            authority,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            worktree_path,
            generation,
            session_name,
        )?;
        let result = self.start_kwt_worktree_operation(
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            KwtWorktreeOperation::Remove {
                worktree_path: worktree_path.to_owned(),
                generation: generation.to_owned(),
                session_name: session_name.to_owned(),
                socket_name: pending.socket_name.clone(),
                live_target: pending.live_target.clone(),
                operation_id: authority,
            },
        );
        if result.is_err() {
            restore_pending_kwt_removal(&self.inner, pending);
        }
        result.map(|_| ())
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
    ) -> Result<u64, WorkspaceError> {
        let task = reserve_kwt_worktree_operation(
            &self.inner,
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            operation,
        )?;
        let operation_id = task.operation_id;
        if task.is_listing() {
            *self
                .inner
                .kwt_worktree_listing
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(KwtWorktreeListing {
                generation: task.generation,
                operation_id,
                cancellation: task.cancellation.clone(),
            });
        }
        let task_inner = Arc::clone(&self.inner);
        let background_task = task.clone();
        if let Err(error) = self.inner.refresh_runtime.spawn(
            "ghosthub-kwt-worktree-operation",
            Box::new(move || run_kwt_worktree_operation(&task_inner, &background_task)),
        ) {
            finish_kwt_worktree_operation(&self.inner, &task);
            return Err(WorkspaceError::new(format!(
                "start KWT worktree operation: {error}"
            )));
        }
        Ok(operation_id)
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
                // Snapshot fields must be owned before crossing into the
                // attachment locks. Presentation transitions take attachment
                // before publishing state, so retaining an RwLock guard here
                // would invert that order and could deadlock the UI.
                let content = {
                    self.inner
                        .state
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .clone()
                };
                let selected_host = {
                    self.inner
                        .selected_host
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .clone()
                };
                let notice = {
                    self.inner
                        .terminal_notice
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .clone()
                };
                let active_selection = {
                    let remote = self
                        .inner
                        .remote_active
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .as_ref()
                        .map(|active| active.selection.clone());
                    remote.or_else(|| {
                        self.inner
                            .attachment
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .active()
                            .map(|active| active.request.selection())
                    })
                };
                let retained_selections = {
                    let mut selections = self
                        .inner
                        .retained_presentations
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .selections();
                    selections.extend(
                        self.inner
                            .remote_retained
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .selections(),
                    );
                    selections
                };
                WorkspaceSnapshot {
                    revision,
                    appearance: self
                        .inner
                        .appearance
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .clone(),
                    content,
                    hosts,
                    selected_host,
                    notice,
                    active_selection,
                    retained_selections,
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
        if self.is_remote_host(selection.host_id()) {
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
            return self.switch_session(selection);
        }
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
        if self.is_remote_host(selection.host_id()) {
            let _navigation = self
                .inner
                .navigation
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let navigation_generation = self.begin_navigation();
            self.settle_local_navigation_before_remote()?;
            let current_key = self.remote_presentation_key(selection);
            let active_matches = self
                .inner
                .remote_active
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_ref()
                .is_some_and(|active| {
                    current_key
                        .as_ref()
                        .map_or_else(|| active.selection == *selection, |key| active.key == *key)
                });
            if active_matches {
                return self.refresh_active_remote_selection(selection, current_key.as_ref());
            }
            if self.activate_remote_retained(selection, current_key.as_ref())? {
                return Ok(());
            }
            if selection.kind() == SessionKind::Herdr {
                let request = capture_remote_herdr_attach_request(&self.inner, selection)?;
                return self.start_remote_herdr_attachment(request, navigation_generation);
            }
            if selection.kind() == SessionKind::Zellij {
                let request = capture_remote_zellij_attach_request(&self.inner, selection)?;
                return self.start_remote_zellij_attachment(request, navigation_generation);
            }
            let request = capture_remote_tmux_attach_request(&self.inner, selection)?;
            return self.start_remote_tmux_attachment(request, navigation_generation);
        }
        if self
            .inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
        {
            let _navigation = self
                .inner
                .navigation
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let (key, request) = self.navigation_target(selection)?;
            let navigation_generation = self.begin_navigation();
            self.inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .invalidate();
            if self.activate_retained_over_remote(&key)? {
                return Ok(());
            }
            let Some(request) = request else {
                return Err(WorkspaceError::new(
                    "the retained terminal presentation is no longer available",
                ));
            };
            return self.start_attachment_over_remote(request, navigation_generation);
        }
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.switch_session_locked(selection)
    }

    fn is_remote_host(&self, host_id: &str) -> bool {
        self.inner
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains_key(host_id)
    }

    fn remote_presentation_key(
        &self,
        selection: &SessionSelection,
    ) -> Option<RemotePresentationKey> {
        let entries = self
            .inner
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let context = entries.get(selection.host_id())?.context.as_ref()?;
        if context.snapshot.endpoint() != selection.endpoint() {
            return None;
        }
        let session_identity = match selection.kind() {
            SessionKind::Tmux => RemoteSessionIdentity::Tmux(
                context
                    .snapshot
                    .sessions()
                    .iter()
                    .find(|session| session.name() == selection.session())?
                    .identity()
                    .clone(),
            ),
            SessionKind::Herdr => {
                let session = context.snapshot.herdr().sessions().iter().find(|session| {
                    session.name() == selection.session()
                        && session.state() == HerdrSessionState::Running
                })?;
                RemoteSessionIdentity::Herdr {
                    name: session.name().to_owned(),
                    is_default: session.is_default(),
                    session_directory: session.session_directory().to_owned(),
                    socket_path: session.socket_path().to_owned(),
                }
            }
            SessionKind::Zellij => RemoteSessionIdentity::Zellij(
                context
                    .snapshot
                    .zellij()
                    .sessions()
                    .iter()
                    .find(|session| session.name() == selection.session())?
                    .name()
                    .to_owned(),
            ),
        };
        Some(RemotePresentationKey {
            host_id: selection.host_id().to_owned(),
            endpoint: selection.endpoint().to_owned(),
            route_identity: context.snapshot.route_identity().to_owned(),
            lease_generation: context.snapshot.lease_generation(),
            session_identity,
        })
    }

    fn refresh_active_remote_selection(
        &self,
        selection: &SessionSelection,
        current_key: Option<&RemotePresentationKey>,
    ) -> Result<(), WorkspaceError> {
        self.inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .invalidate();
        let surface = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .map(TerminalWorker::surface_handle)
            .ok_or_else(|| WorkspaceError::new("the active remote presentation is unavailable"))?;
        let mut remote_active = self
            .inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active) = remote_active.as_mut() else {
            return Err(WorkspaceError::new(
                "the active remote presentation changed while selecting it",
            ));
        };
        if current_key.is_some_and(|key| active.key == *key) && active.selection != *selection {
            active.selection = selection.clone();
            set_inner_state(
                &self.inner,
                WorkspaceContent::Terminal {
                    host_id: selection.host_id().to_owned(),
                    endpoint: selection.endpoint().to_owned(),
                    session: selection.session().to_owned(),
                    kind: selection.kind(),
                    presentation_id: active.presentation_id,
                    surface,
                },
            );
        }
        Ok(())
    }

    fn activate_remote_retained(
        &self,
        selection: &SessionSelection,
        current_key: Option<&RemotePresentationKey>,
    ) -> Result<bool, WorkspaceError> {
        let presentation = {
            let mut retained = self
                .inner
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            current_key.and_then(|key| retained.take(key)).or_else(|| {
                current_key
                    .is_none()
                    .then(|| retained.take_for_selection(selection))
                    .flatten()
            })
        };
        let Some(mut presentation) = presentation else {
            return Ok(false);
        };
        if current_key.is_some() {
            presentation.active.selection = selection.clone();
        }
        presentation.worker.set_clipboard_writes_enabled(true);
        if let Err(error) = publish_remote_worker(
            &self.inner,
            presentation.worker,
            presentation.active.key.clone(),
            &presentation.active.selection,
            presentation.active.lease.clone(),
            presentation.active.presentation_id,
            presentation.active.term,
            presentation.active.identity_mismatch_marker.clone(),
            None,
        ) {
            let RemotePublishError { error, worker } = *error;
            presentation.worker = worker;
            presentation.worker.set_clipboard_writes_enabled(false);
            self.inner
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(presentation);
            return Err(error);
        }
        Ok(true)
    }

    fn start_attachment_over_remote(
        &self,
        request: AttachRequest,
        navigation_generation: u64,
    ) -> Result<(), WorkspaceError> {
        let generation = {
            let mut attachment = self
                .inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if self
                .inner
                .remote_active
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .is_none()
            {
                return Err(WorkspaceError::new(
                    "the remote terminal presentation is no longer active",
                ));
            }
            attachment
                .reserve_with_fallback(request.clone(), AttachTerm::Xterm256Color, None)
                .ok_or_else(|| WorkspaceError::new("a terminal presentation is already opening"))?
        };
        let inner = Arc::clone(&self.inner);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-cross-host-attach".to_owned())
            .spawn(move || {
                run_attach_over_remote(
                    &inner,
                    &request,
                    AttachTerm::Xterm256Color,
                    generation,
                    navigation_generation,
                );
            })
        {
            self.inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clear_if_current(generation);
            return Err(WorkspaceError::new(format!("start attach task: {error}")));
        }
        Ok(())
    }

    fn activate_retained_over_remote(&self, key: &PresentationKey) -> Result<bool, WorkspaceError> {
        let Some(presentation) = self
            .inner
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take(key)
        else {
            return Ok(false);
        };
        let snapshot_write = begin_snapshot_write(&self.inner);
        let mut attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(generation) =
            reserve_retained_attachment(&mut attachment, &presentation.attachment, None)
        else {
            reinsert_retained_presentation(&self.inner, presentation);
            return Err(WorkspaceError::new(
                "a terminal presentation is already opening",
            ));
        };
        let geometry = self
            .inner
            .terminal_geometry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Err(error) = presentation.worker.resize_with_metadata(
            geometry.grid,
            geometry.sequence,
            geometry.pixels,
        ) {
            attachment.clear_if_current(generation);
            reinsert_retained_presentation(&self.inner, presentation);
            return Err(WorkspaceError::from_worker(&error));
        }
        let mut remote_active = self
            .inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active_remote) = remote_active.as_ref() else {
            attachment.clear_if_current(generation);
            reinsert_retained_presentation(&self.inner, presentation);
            return Err(WorkspaceError::new(
                "the remote terminal presentation is no longer active",
            ));
        };
        let mut workers = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if workers.generation() != active_remote.worker_generation {
            attachment.clear_if_current(generation);
            reinsert_retained_presentation(&self.inner, presentation);
            return Err(WorkspaceError::new(
                "the remote terminal presentation changed while switching",
            ));
        }
        let selection = presentation.attachment.request.selection();
        let term = presentation.attachment.term;
        let surface = presentation.worker.surface_handle();
        let presentation_id = presentation.presentation_id;
        presentation.worker.set_clipboard_writes_enabled(true);
        let (_, previous_worker) = workers.replace(presentation.worker);
        let previous_remote = remote_active.take();
        clear_pending_paste(&self.inner);
        set_terminal_notice(&self.inner, term);
        set_inner_state(
            &self.inner,
            WorkspaceContent::Terminal {
                host_id: selection.host_id().to_owned(),
                endpoint: selection.endpoint().to_owned(),
                session: selection.session().to_owned(),
                kind: selection.kind(),
                presentation_id,
                surface,
            },
        );
        drop(workers);
        drop(remote_active);
        drop(geometry);
        drop(attachment);
        if let (Some(worker), Some(active)) = (previous_worker, previous_remote)
            && active.retainable
        {
            worker.set_clipboard_writes_enabled(false);
            let _cancelled = worker.cancel_paste();
            self.inner
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(RemoteRetainedPresentation { active, worker });
        }
        drop(snapshot_write);
        Ok(true)
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
        tmux_socket_name: Option<&str>,
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
            tmux_socket_name,
        )?;
        let worktree_key = request.presentation_key();
        let equivalent_tmux_key = equivalent_tmux_presentation_key(&self.inner, &request);
        let key = equivalent_tmux_key
            .filter(|key| presentation_is_open(&self.inner, key))
            .unwrap_or(worktree_key);
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
        if self.is_remote_host(host_id) {
            let request =
                capture_remote_herdr_create_request(&self.inner, host_id, endpoint, name)?;
            return self.start_remote_herdr_launch(request, navigation);
        }
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
        if self.is_remote_host(host_id) {
            let request =
                capture_remote_zellij_create_request(&self.inner, host_id, endpoint, name)?;
            return self.start_remote_zellij_launch(request, navigation);
        }
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
        if self.is_remote_host(selection.host_id()) {
            let request = capture_remote_herdr_restart_request(&self.inner, selection)?;
            return self.start_remote_herdr_launch(request, navigation);
        }
        let request = capture_herdr_restart_request(&self.inner, selection)?;
        self.start_herdr_launch(&request, navigation)
    }

    fn start_remote_herdr_launch(
        &self,
        request: RemoteHerdrCreateRequest,
        navigation: std::sync::MutexGuard<'_, ()>,
    ) -> Result<(), WorkspaceError> {
        self.reserve_remote_constructive()?;
        let navigation_generation = self.begin_navigation();
        let cancellation = CancellationToken::new();
        let launched = match register_remote_constructive(
            &self.inner,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
            request.constructive_target(),
        ) {
            Ok(launched) => launched,
            Err(error) => {
                self.inner
                    .remote_constructive_in_flight
                    .store(false, Ordering::Release);
                return Err(error);
            }
        };
        if let Err(error) = self.settle_local_navigation_before_remote() {
            cancellation.cancel();
            clear_remote_constructive_registration(&self.inner, &request.host_id);
            self.inner
                .remote_constructive_in_flight
                .store(false, Ordering::Release);
            return Err(error);
        }
        set_remote_herdr_launch_pending(&self.inner, &request.host_id, request.name.as_str(), true);
        let pending_host_id = request.host_id.clone();
        let pending_name = request.name.as_str().to_owned();
        let inner = Arc::clone(&self.inner);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-herdr-launch".to_owned())
            .spawn(move || {
                run_remote_herdr_create(
                    &inner,
                    &request,
                    navigation_generation,
                    &cancellation,
                    &launched,
                );
            })
        {
            clear_remote_constructive_registration(&self.inner, &pending_host_id);
            self.inner
                .remote_constructive_in_flight
                .store(false, Ordering::Release);
            set_remote_herdr_launch_pending(&self.inner, &pending_host_id, &pending_name, false);
            drop(navigation);
            return Err(WorkspaceError::new(format!(
                "start remote Herdr launch task: {error}"
            )));
        }
        drop(navigation);
        Ok(())
    }

    fn start_remote_zellij_launch(
        &self,
        request: RemoteZellijCreateRequest,
        navigation: std::sync::MutexGuard<'_, ()>,
    ) -> Result<(), WorkspaceError> {
        self.reserve_remote_constructive()?;
        let navigation_generation = self.begin_navigation();
        let cancellation = CancellationToken::new();
        let launched = match register_remote_constructive(
            &self.inner,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
            request.constructive_target(),
        ) {
            Ok(launched) => launched,
            Err(error) => {
                self.inner
                    .remote_constructive_in_flight
                    .store(false, Ordering::Release);
                return Err(error);
            }
        };
        if let Err(error) = self.settle_local_navigation_before_remote() {
            cancellation.cancel();
            clear_remote_constructive_registration(&self.inner, &request.host_id);
            self.inner
                .remote_constructive_in_flight
                .store(false, Ordering::Release);
            return Err(error);
        }
        let pending_host_id = request.host_id.clone();
        let inner = Arc::clone(&self.inner);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-zellij-launch".to_owned())
            .spawn(move || {
                run_remote_zellij_create(
                    &inner,
                    &request,
                    navigation_generation,
                    &cancellation,
                    &launched,
                );
            })
        {
            clear_remote_constructive_registration(&self.inner, &pending_host_id);
            self.inner
                .remote_constructive_in_flight
                .store(false, Ordering::Release);
            drop(navigation);
            return Err(WorkspaceError::new(format!(
                "start remote Zellij launch task: {error}"
            )));
        }
        drop(navigation);
        Ok(())
    }

    fn start_remote_zellij_attachment(
        &self,
        request: RemoteZellijAttachRequest,
        navigation_generation: u64,
    ) -> Result<(), WorkspaceError> {
        let cancellation = CancellationToken::new();
        register_remote_attachment(
            &self.inner,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
        )?;
        let inner = Arc::clone(&self.inner);
        let host_id = request.host_id.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-zellij-attach".to_owned())
            .spawn(move || {
                run_remote_zellij_attach(&inner, &request, navigation_generation, &cancellation);
            })
        {
            clear_remote_attachment_registration(&self.inner, &host_id, navigation_generation);
            return Err(WorkspaceError::new(format!(
                "start remote Zellij attachment task: {error}"
            )));
        }
        Ok(())
    }

    fn start_remote_tmux_attachment(
        &self,
        request: RemoteTmuxAttachRequest,
        navigation_generation: u64,
    ) -> Result<(), WorkspaceError> {
        let cancellation = CancellationToken::new();
        register_remote_attachment(
            &self.inner,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
        )?;
        let inner = Arc::clone(&self.inner);
        let host_id = request.host_id.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-tmux-attach".to_owned())
            .spawn(move || {
                run_remote_tmux_attach(&inner, &request, navigation_generation, &cancellation);
            })
        {
            clear_remote_attachment_registration(&self.inner, &host_id, navigation_generation);
            return Err(WorkspaceError::new(format!(
                "start remote tmux attachment task: {error}"
            )));
        }
        Ok(())
    }

    fn start_remote_herdr_attachment(
        &self,
        request: RemoteHerdrAttachRequest,
        navigation_generation: u64,
    ) -> Result<(), WorkspaceError> {
        let cancellation = CancellationToken::new();
        register_remote_attachment(
            &self.inner,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
        )?;
        let inner = Arc::clone(&self.inner);
        let host_id = request.host_id.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-herdr-attach".to_owned())
            .spawn(move || {
                run_remote_herdr_attach(&inner, &request, navigation_generation, &cancellation);
            })
        {
            clear_remote_attachment_registration(&self.inner, &host_id, navigation_generation);
            return Err(WorkspaceError::new(format!(
                "start remote Herdr attachment task: {error}"
            )));
        }
        Ok(())
    }

    fn reserve_remote_constructive(&self) -> Result<(), WorkspaceError> {
        self.inner
            .remote_constructive_in_flight
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| {
                WorkspaceError::new("another remote session is already being created or restarted")
            })?;
        Ok(())
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
        cancel_remote_attachments(&self.inner);
        let generation = next_operation_id(&self.inner);
        self.inner
            .navigation_generation
            .fetch_max(generation, Ordering::AcqRel);
        cancel_superseded_remote_constructive_navigation(&self.inner, generation);
        generation
    }

    #[must_use]
    pub fn navigation_intent_is_current(&self, generation: u64) -> bool {
        self.inner.navigation_generation.load(Ordering::Acquire) == generation
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

    fn settle_local_navigation_before_remote(&self) -> Result<(), WorkspaceError> {
        let Some(fallback) = self.supersede_inflight_attachment()? else {
            return Ok(());
        };
        if self.activate_retained_presentation(&fallback, None)? {
            Ok(())
        } else {
            Err(WorkspaceError::new(
                "the previous terminal presentation is no longer available",
            ))
        }
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
                let result = selection.tmux_socket_name().map_or_else(
                    || {
                        host.capture_live_session(
                            &endpoint,
                            &runtime,
                            selection.session(),
                            &CancellationToken::new(),
                        )
                    },
                    |socket_name| {
                        host.capture_live_session_on_socket(
                            &endpoint,
                            &runtime,
                            socket_name,
                            selection.session(),
                            &CancellationToken::new(),
                        )
                    },
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
        self.finish_killed_presentation(
            target.endpoint(),
            target.runtime(),
            target.identity(),
            target.name(),
            target.socket_name(),
        );
    }

    fn finish_killed_presentation(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        identity: &session::SessionIdentity,
        target_name: &str,
        socket_name: Option<&str>,
    ) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let key_matches = |request: &AttachRequest| {
            request_matches_killed_tmux(
                request,
                endpoint,
                runtime,
                identity,
                Some(target_name),
                socket_name,
            )
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
                presentation_key_matches_killed_tmux(
                    key,
                    endpoint,
                    runtime,
                    identity,
                    Some(target_name),
                    socket_name,
                )
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
            && let Err(error) =
                worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
        {
            return Err(WorkspaceError::from_worker(&error));
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
        self.inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
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
    #[allow(
        clippy::too_many_lines,
        reason = "event draining keeps active and retained terminal ordering in one boundary"
    )]
    pub fn drain_events(&self) -> (Vec<WorkspaceEvent>, bool) {
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let _drain = self
            .inner
            .event_drain
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.monitor_remote_lease_liveness();
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
                        if self.handle_remote_terminal_exit(
                            source_worker_generation,
                            self.classify_active_remote_terminal_exit(
                                source_worker_generation,
                                code,
                                &output_tail,
                            ),
                            &mut emitted,
                        ) {
                            exited = true;
                        }
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
                        if self.handle_remote_terminal_exit(
                            source_worker_generation,
                            Some(error.to_string()),
                            &mut emitted,
                        ) {
                            exited = true;
                        }
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
        let remote_retained_budget = retained_budget.div_ceil(2);
        let local_retained_budget = retained_budget - remote_retained_budget;
        let retained_processed = self.drain_retained_events(local_retained_budget, &mut emitted);
        let remote_retained_processed =
            self.drain_remote_retained_events(remote_retained_budget, &mut emitted);
        let may_have_more = operation_has_more
            || event_source_may_have_more(active_processed, ACTIVE_EVENT_BUDGET, exited)
            || event_source_may_have_more(retained_processed, local_retained_budget, false)
            || event_source_may_have_more(remote_retained_processed, remote_retained_budget, false);
        (emitted, may_have_more)
    }

    fn monitor_remote_lease_liveness(&self) {
        let _publication = self
            .inner
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _snapshot_write = begin_snapshot_write(&self.inner);
        let failed = {
            let mut entries = self
                .inner
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            entries
                .iter_mut()
                .filter_map(|(host_id, entry)| {
                    let error = current_remote_context(entry)?
                        .snapshot
                        .lease()
                        .ensure_live()
                        .err()?;
                    entry.generation = entry.generation.wrapping_add(1).max(1);
                    if let Some(cancellation) = entry.cancellation.take() {
                        cancellation.cancel();
                    }
                    cancel_remote_constructive(entry);
                    cancel_remote_attachment(entry);
                    let context = entry.context.take()?;
                    Some((host_id.clone(), error, context))
                })
                .collect::<Vec<_>>()
        };
        for (host_id, error, context) in failed {
            let stale_presentations = reconcile_remote_presentations(
                &self.inner,
                &host_id,
                context.snapshot.endpoint(),
                context.snapshot.route_identity(),
                context.snapshot.lease_generation(),
                None,
            );
            set_remote_host_state(
                &self.inner,
                &host_id,
                HostConnectionState::Unavailable,
                None,
                Some(HostDiagnostic::new(error.kind(), error.to_string())),
            );
            drop(stale_presentations);
            drop(context);
        }
    }

    fn handle_remote_terminal_exit(
        &self,
        worker_generation: u64,
        error: Option<String>,
        emitted: &mut Vec<WorkspaceEvent>,
    ) -> bool {
        let mut remote_active = self
            .inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if remote_active
            .as_ref()
            .is_none_or(|active| active.worker_generation != worker_generation)
        {
            return false;
        }
        let mut worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if worker.generation() != worker_generation {
            return false;
        }
        let _closed = worker.invalidate_if_generation(worker_generation);
        let _active = remote_active.take();
        drop(worker);
        drop(remote_active);
        clear_pending_paste(&self.inner);
        clear_terminal_notice(&self.inner);
        self.restore_inventory_state();
        if let Some(error) = error {
            emitted.push(WorkspaceEvent::Error(error));
        }
        true
    }

    fn classify_active_remote_terminal_exit(
        &self,
        worker_generation: u64,
        code: u32,
        output_tail: &str,
    ) -> Option<String> {
        let remote_active = self
            .inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let active = remote_active
            .as_ref()
            .filter(|active| active.worker_generation == worker_generation)?;
        classify_remote_terminal_exit(
            code,
            output_tail,
            active.identity_mismatch_marker.as_deref(),
        )
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

    fn drain_remote_retained_events(
        &self,
        budget: usize,
        emitted: &mut Vec<WorkspaceEvent>,
    ) -> usize {
        let drain = self
            .inner
            .remote_retained
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .drain_events(budget);
        if drain.changed {
            self.inner.revision.fetch_add(1, Ordering::Release);
        }
        emitted.extend(drain.emitted);
        drain.processed
    }

    fn attachment_for_worker(
        &self,
        worker_generation: u64,
    ) -> Option<(AttachRequest, AttachTerm, u64, Option<FallbackAuthority>)> {
        if self
            .inner
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_some_and(|active| active.worker_generation == worker_generation)
        {
            return None;
        }
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
    require_wsl_host_id(selection.host_id())?;
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
        .filter(|request| request.selection() == *selection)
    {
        return Ok(KillCaptureRequest::Tmux {
            selection: selection.clone(),
            host: request.host,
            endpoint: request.endpoint,
            runtime: request.runtime,
        });
    }
    require_current_protected_selection(inner, selection)?;
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
                if selection.tmux_socket_name().is_none()
                    && !context
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

fn require_current_protected_selection(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<(), WorkspaceError> {
    let Some(socket_name) = selection.tmux_socket_name() else {
        return Ok(());
    };
    let exact_worktree = inner
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .filter(|host| {
            host.id() == selection.host_id()
                && host.endpoint() == selection.endpoint()
                && host.connection() == HostConnectionState::Ready
        })
        .flat_map(HostItem::projects)
        .flat_map(ProjectItem::worktrees)
        .any(|worktree| {
            worktree.session_name() == selection.session()
                && worktree.tmux_socket_name() == Some(socket_name)
                && worktree.path() == selection.worktree_path().unwrap_or_default()
                && worktree.generation() == selection.worktree_generation()
        });
    if exact_worktree {
        Ok(())
    } else {
        Err(WorkspaceError::new(
            "protected worktree is not in the current inventory",
        ))
    }
}

fn capture_herdr_lifecycle(
    inner: &Inner,
    selection: &SessionSelection,
    action: HerdrLifecycleAction,
    generation: u64,
) -> Result<PendingHerdrLifecycle, WorkspaceError> {
    require_wsl_host_id(selection.host_id())?;
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
    require_wsl_host_id(host_id)?;
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
    require_wsl_host_id(host_id)?;
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

fn capture_remote_herdr_create_request(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    name: HerdrSessionName,
) -> Result<RemoteHerdrCreateRequest, WorkspaceError> {
    require_host_session_actions(
        inner,
        &SessionSelection::herdr(host_id, endpoint, name.as_str()),
    )?;
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(host_id)
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before creating a session"))?;
    if context.snapshot.endpoint() != endpoint {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before creating the session",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = context.snapshot.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    if sessions
        .iter()
        .any(|session| session.name() == name.as_str())
    {
        return Err(WorkspaceError::new(
            "a Herdr session with this name already exists; restart it instead",
        ));
    }
    Ok(RemoteHerdrCreateRequest {
        host_id: host_id.to_owned(),
        connection_generation: entry.generation,
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        name: HerdrLaunchTarget::created(name),
        precondition: HerdrLaunchPrecondition::Absent,
    })
}

fn capture_zellij_create_request(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    name: ZellijSessionName,
) -> Result<ZellijCreateRequest, WorkspaceError> {
    require_wsl_host_id(host_id)?;
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

fn capture_remote_zellij_create_request(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    name: ZellijSessionName,
) -> Result<RemoteZellijCreateRequest, WorkspaceError> {
    require_host_session_actions(
        inner,
        &SessionSelection::zellij(host_id, endpoint, name.as_str()),
    )?;
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(host_id)
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before creating a session"))?;
    if context.snapshot.endpoint() != endpoint {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before creating the session",
        ));
    }
    let ZellijInventory::Available {
        executable,
        sessions,
    } = context.snapshot.zellij()
    else {
        return Err(WorkspaceError::new(
            "Zellij is not available on this SSH host",
        ));
    };
    if sessions
        .iter()
        .any(|session| session.name() == name.as_str())
    {
        return Err(WorkspaceError::new(
            "a Zellij session with this name already exists",
        ));
    }
    Ok(RemoteZellijCreateRequest {
        host_id: host_id.to_owned(),
        connection_generation: entry.generation,
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        name,
    })
}

fn capture_remote_tmux_attach_request(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<RemoteTmuxAttachRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Tmux {
        return Err(WorkspaceError::new(
            "the selected session is not a tmux session",
        ));
    }
    require_host_session_actions(inner, selection)?;
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before opening a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before opening the session",
        ));
    }
    let session = context
        .snapshot
        .sessions()
        .iter()
        .find(|session| session.name() == selection.session())
        .cloned()
        .ok_or_else(|| WorkspaceError::new("session is not in current remote inventory"))?;
    Ok(RemoteTmuxAttachRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        selection: selection.clone(),
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        session,
    })
}

fn capture_remote_zellij_attach_request(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<RemoteZellijAttachRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Zellij {
        return Err(WorkspaceError::new(
            "the selected session is not a Zellij session",
        ));
    }
    require_host_session_actions(inner, selection)?;
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before opening a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before opening the session",
        ));
    }
    let ZellijInventory::Available {
        executable,
        sessions,
    } = context.snapshot.zellij()
    else {
        return Err(WorkspaceError::new(
            "Zellij is not available on this SSH host",
        ));
    };
    let session = sessions
        .iter()
        .find(|session| session.name() == selection.session())
        .ok_or_else(|| WorkspaceError::new("Zellij session is no longer active"))?;
    Ok(RemoteZellijAttachRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        selection: selection.clone(),
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        name: session.name().to_owned(),
    })
}

fn capture_remote_herdr_attach_request(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<RemoteHerdrAttachRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "the selected session is not a Herdr session",
        ));
    }
    require_host_session_actions(inner, selection)?;
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before opening a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before opening the session",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = context.snapshot.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    let session = sessions
        .iter()
        .find(|session| {
            session.name() == selection.session() && session.state() == HerdrSessionState::Running
        })
        .cloned()
        .ok_or_else(|| WorkspaceError::new("Herdr session is no longer running"))?;
    Ok(RemoteHerdrAttachRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        selection: selection.clone(),
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        session,
    })
}

fn capture_herdr_restart_request(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<HerdrCreateRequest, WorkspaceError> {
    require_wsl_host_id(selection.host_id())?;
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

fn capture_remote_herdr_restart_request(
    inner: &Inner,
    selection: &SessionSelection,
) -> Result<RemoteHerdrCreateRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "the selected session is not a Herdr session",
        ));
    }
    require_host_session_actions(inner, selection)?;
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before restarting a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before restarting the session",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = context.snapshot.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    let record = sessions
        .iter()
        .find(|session| session.name() == selection.session())
        .cloned()
        .ok_or_else(|| WorkspaceError::new("Herdr session is no longer in inventory"))?;
    if record.state() != HerdrSessionState::Stopped {
        return Err(WorkspaceError::new("Herdr session is already running"));
    }
    Ok(RemoteHerdrCreateRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        name: HerdrLaunchTarget::discovered(&record),
        precondition: HerdrLaunchPrecondition::Stopped(record),
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
    if !host.accepts_session_actions() {
        let message = if host.id == "wsl" {
            "connect the WSL host before changing a session"
        } else {
            "wait for the SSH host connection to be ready before changing a session"
        };
        return Err(WorkspaceError::new(message));
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

fn require_wsl_host_id(host_id: &str) -> Result<(), WorkspaceError> {
    if host_id == "wsl" {
        Ok(())
    } else {
        Err(WorkspaceError::new(
            "this session action requires the local WSL host",
        ))
    }
}

fn current_remote_context(entry: &RemoteEntry) -> Option<&RemoteHostContext> {
    entry
        .context
        .as_ref()
        .filter(|context| context.generation == entry.generation)
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
    PullRequests,
    ImportPullRequest {
        selector: String,
        navigation_generation: u64,
    },
    Create {
        branch: String,
        source: Option<String>,
        creates_branch: bool,
        navigation_generation: u64,
    },
    Remove {
        worktree_path: String,
        generation: String,
        session_name: String,
        socket_name: Option<String>,
        live_target: Option<Arc<host::LiveSessionTarget>>,
        operation_id: u64,
    },
}

#[derive(Clone)]
struct KwtWorktreeTask {
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    cancellation: CancellationToken,
    generation: u64,
    operation_id: u64,
    repository: String,
    project_path: String,
    registration_fingerprint: String,
    operation: KwtWorktreeOperation,
}

struct KwtWorktreeListing {
    generation: u64,
    operation_id: u64,
    cancellation: CancellationToken,
}

impl KwtWorktreeTask {
    const fn is_listing(&self) -> bool {
        matches!(
            self.operation,
            KwtWorktreeOperation::Branches | KwtWorktreeOperation::PullRequests
        )
    }
}

struct PendingKwtRemoval {
    authority: u64,
    endpoint: host::WslEndpoint,
    repository: String,
    project_path: String,
    registration_fingerprint: String,
    worktree_path: String,
    generation: String,
    session_name: String,
    socket_name: Option<String>,
    live_target: Option<Arc<host::LiveSessionTarget>>,
}

struct KwtRemovalCapture {
    host: RuntimeHost,
    authority: u64,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    repository: String,
    project_path: String,
    registration_fingerprint: String,
    worktree_path: String,
    generation: String,
    session_name: String,
    socket_name: Option<String>,
}

#[derive(Clone)]
struct PendingKwtCreation {
    endpoint: host::WslEndpoint,
    repository: String,
    project_path: String,
    registration_fingerprint: String,
    branch: String,
    navigation_generation: u64,
    baseline: Vec<KwtWorktreeIdentity>,
    refreshes_remaining: u8,
    deadline: Instant,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct KwtWorktreeIdentity {
    path: String,
    generation: Option<String>,
}

#[derive(Default)]
struct KwtWorktreeOutcome {
    refresh_kwt: bool,
    refresh_tmux: bool,
}

fn capture_kwt_removal_authority(inner: &Inner, capture: KwtRemovalCapture) {
    let cancellation = CancellationToken::new();
    let running = if let Some(socket_name) = capture.socket_name.as_deref() {
        capture.host.session_is_running_on_socket(
            &capture.endpoint,
            &capture.runtime,
            socket_name,
            &capture.session_name,
            &cancellation,
        )
    } else {
        capture.host.session_is_running(
            &capture.endpoint,
            &capture.runtime,
            &capture.session_name,
            &cancellation,
        )
    };
    let live_target = match running {
        Ok(false) => None,
        Ok(true) => match capture.socket_name.as_deref().map_or_else(
            || {
                capture.host.capture_live_session(
                    &capture.endpoint,
                    &capture.runtime,
                    &capture.session_name,
                    &cancellation,
                )
            },
            |socket_name| {
                capture.host.capture_live_session_on_socket(
                    &capture.endpoint,
                    &capture.runtime,
                    socket_name,
                    &capture.session_name,
                    &cancellation,
                )
            },
        ) {
            Ok(target) => Some(Arc::new(target)),
            Err(error) => {
                publish_kwt_removal_capture_failure(
                    inner,
                    capture.authority,
                    &capture.project_path,
                    &capture.worktree_path,
                    error.to_string(),
                );
                return;
            }
        },
        Err(error) => {
            publish_kwt_removal_capture_failure(
                inner,
                capture.authority,
                &capture.project_path,
                &capture.worktree_path,
                error.to_string(),
            );
            return;
        }
    };
    let session_was_running = live_target.is_some();
    let mut pending = inner
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.kwt_removal_generation.load(Ordering::Acquire) != capture.authority {
        return;
    }
    let project_path = capture.project_path.clone();
    let worktree_path = capture.worktree_path.clone();
    *pending = Some(PendingKwtRemoval {
        authority: capture.authority,
        endpoint: capture.endpoint,
        repository: capture.repository,
        project_path: capture.project_path,
        registration_fingerprint: capture.registration_fingerprint,
        worktree_path: capture.worktree_path,
        generation: capture.generation,
        session_name: capture.session_name,
        socket_name: capture.socket_name,
        live_target,
    });
    drop(pending);
    push_operation_event(
        inner,
        WorkspaceEvent::KwtWorktreeRemovalReady {
            project_path,
            worktree_path,
            authority: capture.authority,
            session_was_running,
        },
    );
}

fn publish_kwt_removal_capture_failure(
    inner: &Inner,
    authority: u64,
    project_path: &str,
    worktree_path: &str,
    message: String,
) {
    let _pending = inner
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.kwt_removal_generation.load(Ordering::Acquire) != authority {
        return;
    }
    push_operation_event(
        inner,
        WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: authority,
            project_path: project_path.to_owned(),
            worktree_path: Some(worktree_path.to_owned()),
            message,
        },
    );
}

#[allow(clippy::too_many_arguments)]
fn capture_kwt_worktree_removal_context(
    inner: &Inner,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: &str,
    session_name: &str,
    tmux_socket_name: Option<&str>,
) -> Result<
    (
        RuntimeHost,
        host::WslEndpoint,
        host::WslRuntimeIdentity,
        Option<String>,
    ),
    WorkspaceError,
> {
    if host_id != "wsl" {
        return Err(WorkspaceError::new(
            "KWT worktrees are available only on WSL",
        ));
    }
    let context = inner
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
        .ok_or_else(|| WorkspaceError::new("refresh WSL before removing a worktree"))?;
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
            "refresh KWT inventory before removing this worktree",
        ));
    }
    let worktree = item
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
                    && worktree.generation.as_deref() == Some(generation)
                    && worktree.session_name == session_name
                    && worktree.tmux_socket_name.as_deref() == tmux_socket_name
            })
        })
        .ok_or_else(|| {
            WorkspaceError::new("the selected worktree changed; refresh and choose it again")
        })?;
    if worktree.is_main {
        return Err(WorkspaceError::new(
            "the primary checkout cannot be removed",
        ));
    }
    Ok((
        context.0,
        context.1,
        context.2,
        worktree.tmux_socket_name.clone(),
    ))
}

#[allow(clippy::too_many_arguments)]
fn take_pending_kwt_removal(
    inner: &Inner,
    authority: u64,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: &str,
    session_name: &str,
) -> Result<PendingKwtRemoval, WorkspaceError> {
    let pending = inner
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
        .ok_or_else(|| WorkspaceError::new("review the worktree removal again"))?;
    let matches = pending.authority == authority
        && pending.endpoint.distro() == endpoint
        && pending.repository == repository
        && pending.project_path == project_path
        && pending.registration_fingerprint == registration_fingerprint
        && pending.worktree_path == worktree_path
        && pending.generation == generation
        && pending.session_name == session_name;
    if !matches || inner.kwt_removal_generation.load(Ordering::Acquire) != authority {
        return Err(WorkspaceError::new(
            "the worktree changed after confirmation; review the removal again",
        ));
    }
    Ok(pending)
}

fn restore_pending_kwt_removal(inner: &Inner, pending: PendingKwtRemoval) {
    let mut slot = inner
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.kwt_removal_generation.load(Ordering::Acquire) == pending.authority && slot.is_none() {
        *slot = Some(pending);
    }
}

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    reason = "reservation keeps host identity validation and publication fencing atomic"
)]
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
        let project = item.projects.iter().find(|project| {
            project.repository == repository
                && project.path == project_path
                && project.registration_fingerprint == registration_fingerprint
        });
        let Some(project) = project else {
            return Err(WorkspaceError::new(
                "the selected KWT project is no longer in current inventory",
            ));
        };
        validate_kwt_worktree_operation(project, &operation)?;
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
        let operation_id = match &operation {
            KwtWorktreeOperation::Branches | KwtWorktreeOperation::PullRequests => {
                next_operation_id(inner)
            }
            KwtWorktreeOperation::ImportPullRequest {
                navigation_generation,
                ..
            }
            | KwtWorktreeOperation::Create {
                navigation_generation,
                ..
            } => *navigation_generation,
            KwtWorktreeOperation::Remove { operation_id, .. } => *operation_id,
        };
        Ok(KwtWorktreeTask {
            host,
            endpoint: resolved_endpoint,
            runtime,
            cancellation,
            generation,
            operation_id,
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

fn validate_kwt_worktree_operation(
    project: &ProjectItem,
    operation: &KwtWorktreeOperation,
) -> Result<(), WorkspaceError> {
    let KwtWorktreeOperation::Remove {
        worktree_path,
        generation,
        session_name,
        socket_name,
        ..
    } = operation
    else {
        return Ok(());
    };
    let worktree = project
        .worktrees
        .iter()
        .find(|worktree| {
            worktree.path == *worktree_path
                && worktree.generation.as_deref() == Some(generation)
                && worktree.session_name == *session_name
                && worktree.tmux_socket_name.as_ref() == socket_name.as_ref()
        })
        .ok_or_else(|| {
            WorkspaceError::new("the selected worktree changed; refresh and choose it again")
        })?;
    if worktree.is_main {
        return Err(WorkspaceError::new(
            "the primary checkout cannot be removed",
        ));
    }
    Ok(())
}

#[allow(
    clippy::too_many_lines,
    reason = "one exhaustive dispatch keeps KWT operation settlement and refresh behavior aligned"
)]
fn run_kwt_worktree_operation(inner: &Arc<Inner>, task: &KwtWorktreeTask) {
    let outcome = match &task.operation {
        KwtWorktreeOperation::Branches => {
            match task.host.list_kwt_branches(
                &task.endpoint,
                &task.runtime,
                &task.project_path,
                &task.cancellation,
            ) {
                Ok(branches) => push_kwt_listing_event(
                    inner,
                    task,
                    WorkspaceEvent::KwtBranchesLoaded {
                        operation_id: task.operation_id,
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
                Err(error) => push_kwt_listing_event(
                    inner,
                    task,
                    WorkspaceEvent::KwtWorktreeOperationFailed {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        worktree_path: None,
                        message: error.to_string(),
                    },
                ),
            }
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            KwtWorktreeOutcome::default()
        }
        KwtWorktreeOperation::PullRequests => {
            match task.host.list_kwt_pull_requests(
                &task.endpoint,
                &task.runtime,
                &task.project_path,
                &task.cancellation,
            ) {
                Ok(pull_requests) => push_kwt_listing_event(
                    inner,
                    task,
                    WorkspaceEvent::KwtPullRequestsLoaded {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        pull_requests: pull_requests
                            .iter()
                            .map(KwtPullRequestItem::from_host)
                            .collect(),
                    },
                ),
                Err(error) => push_kwt_listing_event(
                    inner,
                    task,
                    WorkspaceEvent::KwtWorktreeOperationFailed {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        worktree_path: None,
                        message: error.to_string(),
                    },
                ),
            }
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            KwtWorktreeOutcome::default()
        }
        KwtWorktreeOperation::ImportPullRequest {
            selector,
            navigation_generation,
        } => run_kwt_pull_request_import(inner, task, selector, *navigation_generation),
        KwtWorktreeOperation::Create {
            branch,
            source,
            creates_branch,
            navigation_generation,
        } => KwtWorktreeOutcome {
            refresh_kwt: run_kwt_worktree_create(
                inner,
                task,
                branch,
                source.as_deref(),
                *creates_branch,
                *navigation_generation,
            ),
            refresh_tmux: false,
        },
        KwtWorktreeOperation::Remove {
            worktree_path,
            generation,
            session_name,
            socket_name,
            live_target,
            ..
        } => run_kwt_worktree_remove(
            inner,
            task,
            worktree_path,
            generation,
            session_name,
            socket_name.as_deref(),
            live_target.as_deref(),
        ),
    };
    finish_kwt_worktree_operation(inner, task);
    if outcome.refresh_tmux {
        let workspace = Workspace {
            inner: Arc::clone(inner),
        };
        if let Err(error) = workspace.refresh() {
            workspace.push_operation_error(format!(
                "the worktree was removed, but session inventory could not refresh: {error}"
            ));
        }
    }
    if outcome.refresh_kwt {
        start_kwt_refresh(inner, false);
    }
}

#[allow(
    clippy::too_many_lines,
    reason = "import validates the complete KWT response and refreshed protected-workspace identity"
)]
fn run_kwt_pull_request_import(
    inner: &Arc<Inner>,
    task: &KwtWorktreeTask,
    selector: &str,
    navigation_generation: u64,
) -> KwtWorktreeOutcome {
    let request = KwtPullRequestImportRequest::new(
        &task.project_path,
        &task.repository,
        &task.registration_fingerprint,
        selector,
    );
    let imported = match task.host.import_kwt_pull_request(
        &task.endpoint,
        &task.runtime,
        &request,
        &task.cancellation,
    ) {
        Ok(imported) => imported,
        Err(error) => {
            let (outcome, message) =
                kwt_pull_request_import_failure(error.kind(), &error.to_string());
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: None,
                    message,
                },
            );
            return outcome;
        }
    };
    let workspace = imported.workspace();
    let exact_response = imported.project_identity() == task.repository
        && imported.project_path() == task.project_path
        && workspace.repository() == task.repository
        && workspace.generation().is_some()
        && workspace.tmux_socket_name().is_some();
    if !exact_response {
        publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
        push_operation_event(
            inner,
            WorkspaceEvent::KwtWorktreeOperationFailed {
                operation_id: task.operation_id,
                project_path: task.project_path.clone(),
                worktree_path: None,
                message: "KWT imported the pull request but returned an inconsistent protected workspace; refresh before opening it."
                    .to_owned(),
            },
        );
        return KwtWorktreeOutcome {
            refresh_kwt: true,
            refresh_tmux: false,
        };
    }
    let Ok(Some(inventory)) =
        task.host
            .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
    else {
        publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
        push_operation_event(
            inner,
            WorkspaceEvent::KwtWorktreeOperationFailed {
                operation_id: task.operation_id,
                project_path: task.project_path.clone(),
                worktree_path: Some(workspace.path().to_owned()),
                message: "The pull request was imported, but KWT inventory is temporarily unavailable. Ghosthub will refresh it automatically."
                    .to_owned(),
            },
        );
        return KwtWorktreeOutcome {
            refresh_kwt: true,
            refresh_tmux: false,
        };
    };
    let exact = inventory.projects().iter().find_map(|project| {
        (project.project().repository() == task.repository
            && project.project().path() == task.project_path
            && project.project().registration_fingerprint() == task.registration_fingerprint)
            .then(|| {
                project.worktrees().iter().find(|worktree| {
                    worktree.path() == workspace.path()
                        && worktree.generation() == workspace.generation()
                        && worktree.session_name() == workspace.session_name()
                        && worktree.tmux_socket_name() == workspace.tmux_socket_name()
                })
            })
            .flatten()
    });
    let Some(exact) = exact else {
        publish_kwt_inventory(
            inner,
            task.generation,
            &task.endpoint,
            &task.runtime,
            &inventory,
        );
        push_operation_event(
            inner,
            WorkspaceEvent::KwtWorktreeOperationFailed {
                operation_id: task.operation_id,
                project_path: task.project_path.clone(),
                worktree_path: Some(workspace.path().to_owned()),
                message: "The imported pull request changed before KWT inventory could confirm it. Refresh and choose it again."
                    .to_owned(),
            },
        );
        return KwtWorktreeOutcome::default();
    };
    let target = KwtWorktreeTarget {
        host_id: "wsl".to_owned(),
        endpoint: task.endpoint.distro().to_owned(),
        repository: task.repository.clone(),
        project_path: task.project_path.clone(),
        registration_fingerprint: task.registration_fingerprint.clone(),
        worktree_path: exact.path().to_owned(),
        generation: exact.generation().map(str::to_owned),
        session_name: exact.session_name().to_owned(),
        tmux_socket_name: exact.tmux_socket_name().map(str::to_owned),
    };
    publish_kwt_inventory(
        inner,
        task.generation,
        &task.endpoint,
        &task.runtime,
        &inventory,
    );
    push_operation_event(
        inner,
        WorkspaceEvent::KwtWorktreeCreated {
            target,
            navigation_generation,
        },
    );
    KwtWorktreeOutcome::default()
}

fn kwt_pull_request_import_failure(
    kind: DiagnosticKind,
    detail: &str,
) -> (KwtWorktreeOutcome, String) {
    if kind == DiagnosticKind::Timeout {
        return (
            KwtWorktreeOutcome {
                refresh_kwt: true,
                refresh_tmux: false,
            },
            "Pull-request import timed out and may have completed. Ghosthub will refresh KWT inventory automatically."
                .to_owned(),
        );
    }
    (KwtWorktreeOutcome::default(), detail.to_owned())
}

fn run_kwt_worktree_remove(
    inner: &Arc<Inner>,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
    session_name: &str,
    socket_name: Option<&str>,
    live_target: Option<&host::LiveSessionTarget>,
) -> KwtWorktreeOutcome {
    let _session_operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Err(error) =
        preflight_kwt_worktree_remove(task, worktree_path, generation, session_name, socket_name)
    {
        fail_kwt_worktree_remove(inner, task, error);
        return KwtWorktreeOutcome::default();
    }

    if let Some(target) = live_target {
        if let Err(error) = task.host.kill_live_session(target, &task.cancellation) {
            fail_kwt_worktree_remove(inner, task, error.to_string());
            return KwtWorktreeOutcome::default();
        }
        Workspace {
            inner: Arc::clone(inner),
        }
        .finish_session_kill(target);
    }

    if let Err(error) = task.host.remove_kwt_worktree(
        &task.endpoint,
        &task.runtime,
        &task.project_path,
        worktree_path,
        generation,
        session_name,
        socket_name,
        &task.cancellation,
    ) {
        if error.kind() == DiagnosticKind::Timeout {
            return reconcile_timed_out_kwt_worktree_remove(
                inner,
                task,
                worktree_path,
                generation,
                live_target.is_some(),
            );
        }
        fail_kwt_worktree_remove(inner, task, error.to_string());
        return KwtWorktreeOutcome::default();
    }
    tombstone_removed_kwt_worktree(inner, task, worktree_path, generation);

    KwtWorktreeOutcome {
        refresh_kwt: reconcile_removed_kwt_worktree(inner, task, worktree_path, generation),
        refresh_tmux: live_target.is_some(),
    }
}

fn reconcile_timed_out_kwt_worktree_remove(
    inner: &Arc<Inner>,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
    session_killed: bool,
) -> KwtWorktreeOutcome {
    match task
        .host
        .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
    {
        Ok(Some(inventory)) => {
            let still_present = inventory.projects().iter().any(|project| {
                project.worktrees().iter().any(|worktree| {
                    worktree.path() == worktree_path && worktree.generation() == Some(generation)
                })
            });
            publish_kwt_inventory(
                inner,
                task.generation,
                &task.endpoint,
                &task.runtime,
                &inventory,
            );
            if still_present {
                push_operation_event(
                    inner,
                    WorkspaceEvent::KwtWorktreeOperationFailed {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        worktree_path: Some(worktree_path.to_owned()),
                        message: "Worktree removal timed out. KWT still reports the worktree; Ghosthub will keep refreshing its inventory."
                            .to_owned(),
                    },
                );
            } else {
                tombstone_removed_kwt_worktree(inner, task, worktree_path, generation);
                push_operation_event(
                    inner,
                    WorkspaceEvent::KwtWorktreeRemoved {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        worktree_path: worktree_path.to_owned(),
                    },
                );
            }
        }
        Ok(None) => {
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: Some(worktree_path.to_owned()),
                    message: "Worktree removal timed out and KWT inventory is temporarily unavailable. Ghosthub will reconcile it automatically."
                        .to_owned(),
                },
            );
        }
        Err(error) => {
            publish_kwt_error(
                inner,
                task.generation,
                &task.endpoint,
                &task.runtime,
                HostDiagnostic::new(error.kind(), error.to_string()),
            );
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: Some(worktree_path.to_owned()),
                    message: "Worktree removal timed out and its result could not be confirmed. Ghosthub will reconcile it automatically."
                        .to_owned(),
                },
            );
        }
    }
    KwtWorktreeOutcome {
        refresh_kwt: true,
        refresh_tmux: session_killed,
    }
}

fn tombstone_removed_kwt_worktree(
    inner: &Inner,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
) {
    publish_kwt(
        inner,
        task.generation,
        &task.endpoint,
        &task.runtime,
        |host| {
            remove_cached_kwt_worktree(
                host,
                &task.repository,
                &task.project_path,
                &task.registration_fingerprint,
                worktree_path,
                generation,
            );
        },
    );
}

fn remove_cached_kwt_worktree(
    host: &mut HostItem,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: &str,
) -> bool {
    let Some(project) = host.projects.iter_mut().find(|project| {
        project.repository == repository
            && project.path == project_path
            && project.registration_fingerprint == registration_fingerprint
    }) else {
        return false;
    };
    let before = project.worktrees.len();
    project.worktrees.retain(|worktree| {
        worktree.path != worktree_path || worktree.generation.as_deref() != Some(generation)
    });
    project.worktrees.len() != before
}

fn preflight_kwt_worktree_remove(
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
    session_name: &str,
    socket_name: Option<&str>,
) -> Result<(), String> {
    let inventory = task
        .host
        .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "KWT is no longer available on this host".to_owned())?;
    let current = inventory.projects().iter().find_map(|project| {
        let identity_matches = project.project().repository() == task.repository
            && project.project().path() == task.project_path
            && project.project().registration_fingerprint() == task.registration_fingerprint;
        identity_matches.then(|| {
            project.worktrees().iter().find(|worktree| {
                worktree.path() == worktree_path
                    && worktree.generation() == Some(generation)
                    && worktree.session_name() == session_name
                    && worktree.tmux_socket_name() == socket_name
                    && !worktree.is_main()
            })
        })?
    });
    current
        .ok_or_else(|| {
            "the worktree changed after confirmation; refresh and review the removal again"
                .to_owned()
        })
        .map(|_| ())
}

fn reconcile_removed_kwt_worktree(
    inner: &Arc<Inner>,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
) -> bool {
    match task
        .host
        .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
    {
        Ok(Some(inventory)) => {
            let still_present = inventory.projects().iter().any(|project| {
                project.worktrees().iter().any(|worktree| {
                    worktree.path() == worktree_path && worktree.generation() == Some(generation)
                })
            });
            if still_present {
                return fail_kwt_worktree_remove(
                    inner,
                    task,
                    "KWT reported success but the worktree is still present; refresh before retrying."
                        .to_owned(),
                );
            }
            publish_kwt_inventory(
                inner,
                task.generation,
                &task.endpoint,
                &task.runtime,
                &inventory,
            );
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeRemoved {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: worktree_path.to_owned(),
                },
            );
            true
        }
        Ok(None) => {
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeRemoved {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: worktree_path.to_owned(),
                },
            );
            true
        }
        Err(error) => {
            publish_kwt_error(
                inner,
                task.generation,
                &task.endpoint,
                &task.runtime,
                HostDiagnostic::new(error.kind(), error.to_string()),
            );
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeRemoved {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: worktree_path.to_owned(),
                },
            );
            true
        }
    }
}

fn fail_kwt_worktree_remove(inner: &Arc<Inner>, task: &KwtWorktreeTask, message: String) -> bool {
    publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
    push_operation_event(
        inner,
        WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: task.operation_id,
            project_path: task.project_path.clone(),
            worktree_path: match &task.operation {
                KwtWorktreeOperation::Remove { worktree_path, .. } => Some(worktree_path.clone()),
                KwtWorktreeOperation::Branches
                | KwtWorktreeOperation::PullRequests
                | KwtWorktreeOperation::ImportPullRequest { .. }
                | KwtWorktreeOperation::Create { .. } => None,
            },
            message,
        },
    );
    false
}

fn run_kwt_worktree_create(
    inner: &Arc<Inner>,
    task: &KwtWorktreeTask,
    branch: &str,
    source: Option<&str>,
    creates_branch: bool,
    navigation_generation: u64,
) -> bool {
    let baseline = match capture_kwt_creation_baseline(task) {
        Ok(baseline) => baseline,
        Err(error) => {
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: None,
                    message: error.to_string(),
                },
            );
            return false;
        }
    };
    let result = task.host.create_kwt_worktree(
        &task.endpoint,
        &task.runtime,
        &host::KwtWorktreeCreate::new(
            &task.project_path,
            &task.repository,
            &task.registration_fingerprint,
            branch,
            source.map(str::to_owned),
            creates_branch,
        ),
        &task.cancellation,
    );
    match result {
        Ok(()) => {
            let pending = pending_kwt_creation(task, branch, navigation_generation, baseline);
            remember_pending_kwt_creation(inner, pending.clone());
            reconcile_created_kwt_worktree(inner, task, &pending, true)
        }
        Err(error) if error.kind() == DiagnosticKind::Timeout => {
            let pending = pending_kwt_creation(task, branch, navigation_generation, baseline);
            remember_pending_kwt_creation(inner, pending.clone());
            reconcile_created_kwt_worktree(inner, task, &pending, false)
        }
        Err(error) => {
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: None,
                    message: error.to_string(),
                },
            );
            false
        }
    }
}

fn capture_kwt_creation_baseline(
    task: &KwtWorktreeTask,
) -> Result<Vec<KwtWorktreeIdentity>, WorkspaceError> {
    let inventory = task
        .host
        .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?
        .ok_or_else(|| WorkspaceError::new("KWT is no longer available on this host"))?;
    let project = inventory
        .projects()
        .iter()
        .find(|project| {
            project.project().repository() == task.repository
                && project.project().path() == task.project_path
                && project.project().registration_fingerprint() == task.registration_fingerprint
        })
        .ok_or_else(|| {
            WorkspaceError::new(
                "the selected project changed; refresh it before creating a worktree",
            )
        })?;
    Ok(project
        .worktrees()
        .iter()
        .map(kwt_worktree_identity)
        .collect())
}

fn kwt_worktree_identity(worktree: &host::KwtWorktree) -> KwtWorktreeIdentity {
    KwtWorktreeIdentity {
        path: worktree.path().to_owned(),
        generation: worktree.generation().map(str::to_owned),
    }
}

fn kwt_identity_was_in_baseline(
    baseline: &[KwtWorktreeIdentity],
    worktree: &host::KwtWorktree,
) -> bool {
    baseline.iter().any(|identity| {
        identity.path == worktree.path()
            || identity
                .generation
                .as_deref()
                .is_some_and(|generation| worktree.generation() == Some(generation))
    })
}

fn pending_kwt_creation(
    task: &KwtWorktreeTask,
    branch: &str,
    navigation_generation: u64,
    baseline: Vec<KwtWorktreeIdentity>,
) -> PendingKwtCreation {
    PendingKwtCreation {
        endpoint: task.endpoint.clone(),
        repository: task.repository.clone(),
        project_path: task.project_path.clone(),
        registration_fingerprint: task.registration_fingerprint.clone(),
        branch: branch.to_owned(),
        navigation_generation,
        baseline,
        refreshes_remaining: PENDING_KWT_CREATION_REFRESH_LIMIT,
        deadline: Instant::now() + PENDING_KWT_CREATION_LIFETIME,
    }
}

fn reconcile_created_kwt_worktree(
    inner: &Arc<Inner>,
    task: &KwtWorktreeTask,
    pending: &PendingKwtCreation,
    mutation_confirmed: bool,
) -> bool {
    match task
        .host
        .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
    {
        Ok(Some(inventory)) => {
            let target = pending_kwt_creation_target(pending, &inventory);
            publish_kwt_inventory(
                inner,
                task.generation,
                &task.endpoint,
                &task.runtime,
                &inventory,
            );
            if target.is_some() {
                false
            } else {
                push_operation_event(
                    inner,
                    WorkspaceEvent::KwtWorktreeCreationPending {
                        project_path: task.project_path.clone(),
                        message: if mutation_confirmed {
                            "Worktree created. Waiting for KWT to refresh it.".to_owned()
                        } else {
                            "Worktree creation timed out. Ghosthub will reconcile KWT inventory automatically."
                                .to_owned()
                        },
                        navigation_generation: pending.navigation_generation,
                    },
                );
                true
            }
        }
        Ok(None) => {
            publish_kwt_mutation_failure(inner, task.generation, &task.endpoint, &task.runtime);
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeCreationPending {
                    project_path: task.project_path.clone(),
                    message: if mutation_confirmed {
                        "Worktree created. Waiting for KWT to become available.".to_owned()
                    } else {
                        "Worktree creation timed out and KWT inventory is temporarily unavailable. Ghosthub will reconcile it automatically."
                            .to_owned()
                    },
                    navigation_generation: pending.navigation_generation,
                },
            );
            true
        }
        Err(error) => {
            publish_kwt_error(
                inner,
                task.generation,
                &task.endpoint,
                &task.runtime,
                HostDiagnostic::new(error.kind(), error.to_string()),
            );
            push_operation_event(
                inner,
                WorkspaceEvent::KwtWorktreeCreationPending {
                    project_path: task.project_path.clone(),
                    message: if mutation_confirmed {
                        "Worktree created. KWT inventory is temporarily unavailable; Ghosthub will retry."
                            .to_owned()
                    } else {
                        "Worktree creation timed out and its result could not be confirmed. Ghosthub will reconcile it automatically."
                            .to_owned()
                    },
                    navigation_generation: pending.navigation_generation,
                },
            );
            true
        }
    }
}

fn remember_pending_kwt_creation(inner: &Inner, pending: PendingKwtCreation) {
    let mut creations = inner
        .pending_kwt_creations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    creations.retain(|candidate| {
        candidate.endpoint != pending.endpoint
            || candidate.repository != pending.repository
            || candidate.project_path != pending.project_path
            || candidate.registration_fingerprint != pending.registration_fingerprint
            || candidate.branch != pending.branch
    });
    creations.push(pending);
}

fn pending_kwt_creation_target(
    pending: &PendingKwtCreation,
    inventory: &KwtInventory,
) -> Option<KwtWorktreeTarget> {
    let project = inventory.projects().iter().find(|project| {
        project.project().repository() == pending.repository
            && project.project().path() == pending.project_path
            && project.project().registration_fingerprint() == pending.registration_fingerprint
    })?;
    let worktree = project.worktrees().iter().find(|worktree| {
        worktree.branch() == pending.branch
            && !kwt_identity_was_in_baseline(&pending.baseline, worktree)
    })?;
    Some(KwtWorktreeTarget {
        host_id: "wsl".to_owned(),
        endpoint: pending.endpoint.distro().to_owned(),
        repository: pending.repository.clone(),
        project_path: pending.project_path.clone(),
        registration_fingerprint: pending.registration_fingerprint.clone(),
        worktree_path: worktree.path().to_owned(),
        generation: worktree.generation().map(str::to_owned),
        session_name: worktree.session_name().to_owned(),
        tmux_socket_name: worktree.tmux_socket_name().map(str::to_owned),
    })
}

fn resolve_pending_kwt_creations(
    inner: &Inner,
    endpoint: &host::WslEndpoint,
    inventory: &KwtInventory,
) {
    resolve_pending_kwt_creations_at(inner, endpoint, inventory, Instant::now());
}

fn resolve_pending_kwt_creations_at(
    inner: &Inner,
    endpoint: &host::WslEndpoint,
    inventory: &KwtInventory,
    now: Instant,
) {
    let mut resolved = Vec::new();
    let mut expired = Vec::new();
    let mut pending = inner
        .pending_kwt_creations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    pending.retain_mut(|candidate| {
        if candidate.endpoint != *endpoint {
            return true;
        }
        if now >= candidate.deadline {
            expired.push((
                candidate.project_path.clone(),
                candidate.navigation_generation,
            ));
            false
        } else if let Some(target) = pending_kwt_creation_target(candidate, inventory) {
            resolved.push((target, candidate.navigation_generation));
            false
        } else {
            candidate.refreshes_remaining = candidate.refreshes_remaining.saturating_sub(1);
            if candidate.refreshes_remaining > 0 {
                return true;
            }
            expired.push((
                candidate.project_path.clone(),
                candidate.navigation_generation,
            ));
            false
        }
    });
    drop(pending);
    for (target, navigation_generation) in resolved {
        push_operation_event(
            inner,
            WorkspaceEvent::KwtWorktreeCreated {
                target,
                navigation_generation,
            },
        );
    }
    for (project_path, navigation_generation) in expired {
        push_operation_event(
            inner,
            WorkspaceEvent::KwtWorktreeCreationExpired {
                project_path,
                message: "KWT did not report the created worktree before reconciliation expired. Refresh the project before trying again."
                    .to_owned(),
                navigation_generation,
            },
        );
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
                Ok(Some(inventory)) => {
                    publish_kwt_inventory(
                        inner,
                        task.generation,
                        &task.endpoint,
                        &task.runtime,
                        &inventory,
                    );
                }
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

fn finish_kwt_worktree_operation(inner: &Arc<Inner>, task: &KwtWorktreeTask) {
    if task.is_listing() {
        let owns_listing = {
            let mut active = inner
                .kwt_worktree_listing
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if active.as_ref().is_some_and(|listing| {
                listing.generation == task.generation && listing.operation_id == task.operation_id
            }) {
                active.take();
                true
            } else {
                false
            }
        };
        if !owns_listing {
            return;
        }
    }
    finish_kwt_project_mutation(inner, Some((&task.endpoint, &task.runtime)));
}

fn push_kwt_listing_event(inner: &Inner, task: &KwtWorktreeTask, event: WorkspaceEvent) {
    let active = inner
        .kwt_worktree_listing
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if active.as_ref().is_some_and(|listing| {
        listing.generation == task.generation
            && listing.operation_id == task.operation_id
            && !task.cancellation.is_cancelled()
    }) {
        push_operation_event(inner, event);
    }
    drop(active);
}

fn next_operation_id(inner: &Inner) -> u64 {
    inner
        .operation_sequence
        .fetch_add(1, Ordering::AcqRel)
        .checked_add(1)
        .expect("workspace operation sequence exhausted")
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
                Ok(Some(inventory)) => {
                    publish_kwt_inventory(
                        &task_inner,
                        generation,
                        &task_endpoint,
                        &task_runtime,
                        &inventory,
                    );
                }
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
) -> bool {
    let published = publish_kwt(inner, generation, endpoint, runtime, |host| {
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
    if published {
        resolve_pending_kwt_creations(inner, endpoint, inventory);
    }
    published
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
) -> bool {
    let _publication = inner
        .kwt_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.kwt_refresh_generation.load(Ordering::Acquire) != generation {
        return false;
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
        return false;
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
        true
    } else {
        false
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

struct RemoteConstructiveReset<'a> {
    inner: &'a Inner,
    host_id: &'a str,
    navigation_generation: u64,
}

struct RemoteAttachmentReset<'a> {
    inner: &'a Inner,
    host_id: &'a str,
    navigation_generation: u64,
}

impl Drop for RemoteAttachmentReset<'_> {
    fn drop(&mut self) {
        clear_remote_attachment_registration(self.inner, self.host_id, self.navigation_generation);
    }
}

impl Drop for RemoteConstructiveReset<'_> {
    fn drop(&mut self) {
        let _pending = settle_remote_constructive_task(
            self.inner,
            self.host_id,
            self.navigation_generation,
            false,
        );
        self.inner
            .remote_constructive_in_flight
            .store(false, Ordering::Release);
    }
}

fn register_remote_constructive(
    inner: &Inner,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    target: RemoteConstructiveTarget,
) -> Result<Arc<AtomicBool>, WorkspaceError> {
    let mut entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get_mut(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host is no longer configured"))?;
    let context = entry
        .context
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected before session creation"))?;
    if entry.generation != connection_generation
        || !remote_snapshot_authority_matches(&context.snapshot, expected)
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed before session creation; refresh before trying again",
        ));
    }
    if entry.constructive_cancellation.is_some() {
        return Err(WorkspaceError::new(
            "another remote session is already being created or restarted",
        ));
    }
    let launched = Arc::new(AtomicBool::new(false));
    entry.constructive_cancellation = Some(RemoteConstructiveState::Active {
        navigation_generation,
        cancellation: cancellation.clone(),
        launched: Arc::clone(&launched),
        target,
    });
    Ok(launched)
}

fn clear_remote_constructive_registration(inner: &Inner, host_id: &str) {
    if let Some(entry) = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get_mut(host_id)
    {
        entry.constructive_cancellation = None;
    }
}

fn settle_remote_constructive_task(
    inner: &Inner,
    host_id: &str,
    navigation_generation: u64,
    succeeded: bool,
) -> Option<RemoteConstructiveTarget> {
    let mut entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries.get_mut(host_id)?;
    let operation = entry.constructive_cancellation.take()?;
    match operation {
        RemoteConstructiveState::Active {
            navigation_generation: current_generation,
            launched,
            target,
            ..
        } if current_generation == navigation_generation => {
            if succeeded || !launched.load(Ordering::Acquire) {
                None
            } else {
                entry.constructive_cancellation = Some(
                    RemoteConstructiveState::PendingReconciliation(target.clone()),
                );
                Some(target)
            }
        }
        current => {
            entry.constructive_cancellation = Some(current);
            None
        }
    }
}

fn cancel_remote_constructive(entry: &mut RemoteEntry) {
    let Some(operation) = entry.constructive_cancellation.take() else {
        return;
    };
    match operation {
        RemoteConstructiveState::Active {
            cancellation,
            launched,
            target,
            ..
        } => {
            let launched = launched.load(Ordering::Acquire);
            cancellation.cancel();
            if launched {
                entry.constructive_cancellation =
                    Some(RemoteConstructiveState::PendingReconciliation(target));
            }
        }
        pending @ RemoteConstructiveState::PendingReconciliation(_) => {
            entry.constructive_cancellation = Some(pending);
        }
    }
}

fn cancel_superseded_remote_constructive_navigation(inner: &Inner, generation: u64) {
    for entry in inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .values_mut()
    {
        let Some(RemoteConstructiveState::Active {
            navigation_generation,
            cancellation,
            launched,
            ..
        }) = entry.constructive_cancellation.as_ref()
        else {
            continue;
        };
        if *navigation_generation < generation && !launched.load(Ordering::Acquire) {
            cancellation.cancel();
        }
    }
}

fn remote_constructive_is_current(
    inner: &Inner,
    host_id: &str,
    cancellation: &CancellationToken,
) -> bool {
    !cancellation.is_cancelled()
        && inner
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(host_id)
            .and_then(|entry| entry.constructive_cancellation.as_ref())
            .is_some_and(|operation| {
                matches!(
                    operation,
                    RemoteConstructiveState::Active {
                        cancellation: current,
                        ..
                    } if !current.is_cancelled()
                )
            })
}

fn register_remote_attachment(
    inner: &Inner,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<(), WorkspaceError> {
    let mut entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get_mut(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host is no longer configured"))?;
    let context = entry
        .context
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected before attachment"))?;
    if entry.generation != connection_generation
        || !remote_snapshot_authority_matches(&context.snapshot, expected)
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed before attachment; refresh before trying again",
        ));
    }
    if let Some(previous) = entry.attachment_attempt.take() {
        previous.cancellation.cancel();
    }
    entry.attachment_attempt = Some(RemoteAttachmentAttempt {
        navigation_generation,
        cancellation: cancellation.clone(),
    });
    Ok(())
}

fn remote_attachment_is_current(
    inner: &Inner,
    host_id: &str,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> bool {
    !cancellation.is_cancelled()
        && inner.navigation_generation.load(Ordering::Acquire) == navigation_generation
        && inner
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(host_id)
            .and_then(|entry| entry.attachment_attempt.as_ref())
            .is_some_and(|attempt| {
                attempt.navigation_generation == navigation_generation
                    && !attempt.cancellation.is_cancelled()
            })
}

fn with_current_remote_attachment_launch<T>(
    inner: &Inner,
    host_id: &str,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launch: impl FnOnce() -> Result<T, WorkspaceError>,
) -> Result<T, WorkspaceError> {
    let _navigation = inner
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new("remote attachment was superseded"));
    }
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let current = entries
        .get(host_id)
        .and_then(|entry| entry.attachment_attempt.as_ref())
        .is_some_and(|attempt| {
            attempt.navigation_generation == navigation_generation
                && !attempt.cancellation.is_cancelled()
        });
    if cancellation.is_cancelled() || !current {
        return Err(WorkspaceError::new("remote attachment was superseded"));
    }
    launch()
}

fn with_current_remote_constructive_launch<T>(
    inner: &Inner,
    request_host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launch: impl FnOnce() -> Result<T, WorkspaceError>,
) -> Result<T, WorkspaceError> {
    let _navigation = inner
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if cancellation.is_cancelled()
        || inner.navigation_generation.load(Ordering::Acquire) != navigation_generation
    {
        return Err(WorkspaceError::new(
            "remote session creation was superseded",
        ));
    }
    with_current_remote_constructive(
        inner,
        request_host_id,
        connection_generation,
        expected,
        cancellation,
        launch,
    )
}

fn clear_remote_attachment_registration(inner: &Inner, host_id: &str, navigation_generation: u64) {
    let mut entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(entry) = entries.get_mut(host_id)
        && entry
            .attachment_attempt
            .as_ref()
            .is_some_and(|attempt| attempt.navigation_generation == navigation_generation)
    {
        entry.attachment_attempt = None;
    }
}

fn cancel_remote_attachment(entry: &mut RemoteEntry) {
    if let Some(attempt) = entry.attachment_attempt.take() {
        attempt.cancellation.cancel();
    }
}

fn cancel_remote_attachments(inner: &Inner) {
    for entry in inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .values_mut()
    {
        cancel_remote_attachment(entry);
    }
}

fn remote_snapshot_authority_matches(
    current: &RemoteTmuxSnapshot,
    expected: &RemoteTmuxSnapshot,
) -> bool {
    current.endpoint() == expected.endpoint()
        && current.route_identity() == expected.route_identity()
        && current.lease_generation() == expected.lease_generation()
        && current.inventory_generation() == expected.inventory_generation()
}

fn validate_remote_publication_fence(
    entry: &RemoteEntry,
    fence: &RemotePublicationFence<'_>,
) -> Result<(), WorkspaceError> {
    let context = entry
        .context
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected during the operation"))?;
    if fence.cancellation.is_cancelled()
        || entry.generation != fence.connection_generation
        || !remote_snapshot_authority_matches(&context.snapshot, fence.snapshot)
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed during the operation; refresh before trying again",
        ));
    }
    Ok(())
}

fn with_current_remote_constructive<T>(
    inner: &Inner,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    cancellation: &CancellationToken,
    launch: impl FnOnce() -> Result<T, WorkspaceError>,
) -> Result<T, WorkspaceError> {
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host is no longer configured"))?;
    let context = entry
        .context
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected before session creation"))?;
    let active = entry
        .constructive_cancellation
        .as_ref()
        .is_some_and(|operation| {
            matches!(
                operation,
                RemoteConstructiveState::Active {
                    cancellation: current,
                    ..
                } if !current.is_cancelled()
            )
        });
    if cancellation.is_cancelled()
        || !active
        || entry.generation != connection_generation
        || !remote_snapshot_authority_matches(&context.snapshot, expected)
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed before session creation; refresh before trying again",
        ));
    }
    launch()
}

fn recapture_remote_attachment_context(
    inner: &Inner,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
) -> Result<(RuntimeRemoteHost, RemoteTmuxSnapshot), WorkspaceError> {
    let entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected before attachment"))?;
    if entry.generation != connection_generation
        || context.snapshot.endpoint() != expected.endpoint()
        || context.snapshot.route_identity() != expected.route_identity()
        || context.snapshot.lease_generation() != expected.lease_generation()
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed before attachment; refresh before trying again",
        ));
    }
    Ok((context.host.clone(), context.snapshot.clone()))
}

fn recapture_remote_tmux_attach_request(
    inner: &Inner,
    request: &RemoteTmuxAttachRequest,
) -> Result<RemoteTmuxAttachRequest, WorkspaceError> {
    let (host, snapshot) = recapture_remote_attachment_context(
        inner,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    )?;
    let session = snapshot
        .sessions()
        .iter()
        .find(|session| session.identity() == request.session.identity())
        .cloned()
        .ok_or_else(|| {
            WorkspaceError::new(
                "the remote tmux session changed while waiting; refresh before opening it",
            )
        })?;
    Ok(RemoteTmuxAttachRequest {
        host_id: request.host_id.clone(),
        connection_generation: request.connection_generation,
        selection: SessionSelection::new(&request.host_id, snapshot.endpoint(), session.name()),
        host,
        snapshot,
        session,
    })
}

fn recapture_remote_herdr_attach_request(
    inner: &Inner,
    request: &RemoteHerdrAttachRequest,
) -> Result<RemoteHerdrAttachRequest, WorkspaceError> {
    let (host, snapshot) = recapture_remote_attachment_context(
        inner,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    )?;
    let (executable, session) = resolve_remote_herdr_attach_target(
        snapshot.herdr(),
        &request.executable,
        &request.session,
    )?;
    Ok(RemoteHerdrAttachRequest {
        host_id: request.host_id.clone(),
        connection_generation: request.connection_generation,
        selection: SessionSelection::herdr(&request.host_id, snapshot.endpoint(), session.name()),
        host,
        snapshot,
        executable,
        session,
    })
}

fn recapture_remote_zellij_attach_request(
    inner: &Inner,
    request: &RemoteZellijAttachRequest,
) -> Result<RemoteZellijAttachRequest, WorkspaceError> {
    let (host, snapshot) = recapture_remote_attachment_context(
        inner,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    )?;
    let (executable, session) =
        resolve_remote_zellij_attach_target(snapshot.zellij(), &request.executable, &request.name)?;
    Ok(RemoteZellijAttachRequest {
        host_id: request.host_id.clone(),
        connection_generation: request.connection_generation,
        selection: SessionSelection::zellij(&request.host_id, snapshot.endpoint(), session.name()),
        host,
        snapshot,
        executable,
        name: session.name().to_owned(),
    })
}

fn run_remote_tmux_attach(
    inner: &Inner,
    request: &RemoteTmuxAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _reset = RemoteAttachmentReset {
        inner,
        host_id: &request.host_id,
        navigation_generation,
    };
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !remote_attachment_is_current(inner, &request.host_id, navigation_generation, cancellation) {
        return;
    }
    let result = recapture_remote_tmux_attach_request(inner, request).and_then(|request| {
        prepare_remote_tmux_attachment(inner, &request, navigation_generation, cancellation)
            .and_then(|(worker, term, identity_mismatch_marker)| {
                let navigation = inner
                    .navigation
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
                    drop(worker);
                    return Ok(());
                }
                let key = RemotePresentationKey {
                    host_id: request.host_id.clone(),
                    endpoint: request.snapshot.endpoint().to_owned(),
                    route_identity: request.snapshot.route_identity().to_owned(),
                    lease_generation: request.snapshot.lease_generation(),
                    session_identity: RemoteSessionIdentity::Tmux(
                        request.session.identity().clone(),
                    ),
                };
                let published = publish_remote_worker(
                    inner,
                    worker,
                    key,
                    &request.selection,
                    request.snapshot.lease().clone(),
                    next_presentation_id(inner),
                    term,
                    Some(identity_mismatch_marker),
                    Some(&RemotePublicationFence {
                        host_id: &request.host_id,
                        connection_generation: request.connection_generation,
                        snapshot: &request.snapshot,
                        cancellation,
                    }),
                )
                .map_err(|error| error.error);
                drop(navigation);
                published?;
                Ok(())
            })
    });
    if let Err(error) = result
        && remote_attachment_is_current(
            inner,
            &request.host_id,
            navigation_generation,
            cancellation,
        )
    {
        push_operation_event(inner, WorkspaceEvent::Error(error.to_string()));
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn prepare_remote_tmux_attachment(
    inner: &Inner,
    request: &RemoteTmuxAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, AttachTerm, String), WorkspaceError> {
    let term = request
        .host
        .probe_terminal_term(&request.snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let (plan, identity_mismatch_marker) = request
        .host
        .attach_plan(&request.snapshot, &request.session, term.as_str())
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = with_current_remote_attachment_launch(
        inner,
        &request.host_id,
        navigation_generation,
        cancellation,
        || {
            TerminalWorker::attach_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
                current_default_colors(inner),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    )?;
    Ok((worker, term, identity_mismatch_marker))
}

fn run_remote_herdr_attach(
    inner: &Inner,
    request: &RemoteHerdrAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _reset = RemoteAttachmentReset {
        inner,
        host_id: &request.host_id,
        navigation_generation,
    };
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !remote_attachment_is_current(inner, &request.host_id, navigation_generation, cancellation) {
        return;
    }
    let result = recapture_remote_herdr_attach_request(inner, request).and_then(|request| {
        prepare_remote_herdr_attachment(inner, &request, navigation_generation, cancellation)
            .and_then(|(worker, snapshot, session, geometry, term)| {
                if let Err(error) =
                    worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
                {
                    return Err(WorkspaceError::from_worker(&error));
                }
                let navigation = inner
                    .navigation
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
                    drop(worker);
                    return Ok(());
                }
                let key = RemotePresentationKey {
                    host_id: request.host_id.clone(),
                    endpoint: snapshot.endpoint().to_owned(),
                    route_identity: snapshot.route_identity().to_owned(),
                    lease_generation: snapshot.lease_generation(),
                    session_identity: RemoteSessionIdentity::Herdr {
                        name: session.name().to_owned(),
                        is_default: session.is_default(),
                        session_directory: session.session_directory().to_owned(),
                        socket_path: session.socket_path().to_owned(),
                    },
                };
                let published = publish_remote_worker(
                    inner,
                    worker,
                    key,
                    &request.selection,
                    snapshot.lease().clone(),
                    next_presentation_id(inner),
                    term,
                    None,
                    Some(&RemotePublicationFence {
                        host_id: &request.host_id,
                        connection_generation: request.connection_generation,
                        snapshot: &snapshot,
                        cancellation,
                    }),
                )
                .map_err(|error| error.error);
                drop(navigation);
                published?;
                Ok(())
            })
    });
    if let Err(error) = result
        && remote_attachment_is_current(
            inner,
            &request.host_id,
            navigation_generation,
            cancellation,
        )
    {
        push_operation_event(inner, WorkspaceEvent::Error(error.to_string()));
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn prepare_remote_herdr_attachment(
    inner: &Inner,
    request: &RemoteHerdrAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        RemoteTmuxSnapshot,
        session::HerdrSessionRecord,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let inventory = request
        .host
        .refresh(request.snapshot.lease(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new(
            "remote Herdr attachment was superseded",
        ));
    }
    let snapshot = publish_remote_inventory(
        inner,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
        cancellation,
        inventory,
    )?;
    let (executable, session) = resolve_remote_herdr_attach_target(
        snapshot.herdr(),
        &request.executable,
        &request.session,
    )?;
    let term = request
        .host
        .probe_terminal_term(&snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let plan = request
        .host
        .herdr_attach_plan(&snapshot, &executable, &session, term.as_str())
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = with_current_remote_attachment_launch(
        inner,
        &request.host_id,
        navigation_generation,
        cancellation,
        || {
            TerminalWorker::attach_herdr_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
                current_default_colors(inner),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    )?;
    Ok((worker, snapshot, session, geometry, term))
}

fn resolve_remote_herdr_attach_target(
    inventory: &HerdrInventory,
    expected_executable: &str,
    expected: &session::HerdrSessionRecord,
) -> Result<(String, session::HerdrSessionRecord), WorkspaceError> {
    let HerdrInventory::Available {
        executable,
        sessions,
    } = inventory
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    if executable != expected_executable {
        return Err(WorkspaceError::new(
            "the remote Herdr executable changed; refresh before opening the session",
        ));
    }
    let session = sessions
        .iter()
        .find(|session| session.name() == expected.name())
        .ok_or_else(|| WorkspaceError::new("Herdr session is no longer available"))?;
    if session.state() != HerdrSessionState::Running
        || session.is_default() != expected.is_default()
        || session.session_directory() != expected.session_directory()
        || session.socket_path() != expected.socket_path()
    {
        return Err(WorkspaceError::new(
            "Herdr session identity changed; refresh before opening it",
        ));
    }
    Ok((executable.clone(), session.clone()))
}

fn run_remote_zellij_attach(
    inner: &Inner,
    request: &RemoteZellijAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _reset = RemoteAttachmentReset {
        inner,
        host_id: &request.host_id,
        navigation_generation,
    };
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !remote_attachment_is_current(inner, &request.host_id, navigation_generation, cancellation) {
        return;
    }
    let result = recapture_remote_zellij_attach_request(inner, request).and_then(|request| {
        prepare_remote_zellij_attachment(inner, &request, navigation_generation, cancellation)
            .and_then(|(worker, snapshot, session, geometry, term)| {
                if let Err(error) =
                    worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
                {
                    return Err(WorkspaceError::from_worker(&error));
                }
                let navigation = inner
                    .navigation
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
                    drop(worker);
                    return Ok(());
                }
                let key = RemotePresentationKey {
                    host_id: request.host_id.clone(),
                    endpoint: snapshot.endpoint().to_owned(),
                    route_identity: snapshot.route_identity().to_owned(),
                    lease_generation: snapshot.lease_generation(),
                    session_identity: RemoteSessionIdentity::Zellij(session.name().to_owned()),
                };
                let published = publish_remote_worker(
                    inner,
                    worker,
                    key,
                    &request.selection,
                    snapshot.lease().clone(),
                    next_presentation_id(inner),
                    term,
                    None,
                    Some(&RemotePublicationFence {
                        host_id: &request.host_id,
                        connection_generation: request.connection_generation,
                        snapshot: &snapshot,
                        cancellation,
                    }),
                )
                .map_err(|error| error.error);
                drop(navigation);
                published?;
                Ok(())
            })
    });
    if let Err(error) = result
        && remote_attachment_is_current(
            inner,
            &request.host_id,
            navigation_generation,
            cancellation,
        )
    {
        push_operation_event(inner, WorkspaceEvent::Error(error.to_string()));
        inner.revision.fetch_add(1, Ordering::Release);
    }
}

fn prepare_remote_zellij_attachment(
    inner: &Inner,
    request: &RemoteZellijAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        RemoteTmuxSnapshot,
        session::ZellijSessionRecord,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let inventory = request
        .host
        .refresh(request.snapshot.lease(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new(
            "remote Zellij attachment was superseded",
        ));
    }
    let snapshot = publish_remote_inventory(
        inner,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
        cancellation,
        inventory,
    )?;
    let (executable, session) =
        resolve_remote_zellij_attach_target(snapshot.zellij(), &request.executable, &request.name)?;
    let term = request
        .host
        .probe_terminal_term(&snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let plan = request
        .host
        .zellij_attach_plan(&snapshot, &executable, &session, term.as_str())
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = with_current_remote_attachment_launch(
        inner,
        &request.host_id,
        navigation_generation,
        cancellation,
        || {
            TerminalWorker::attach_zellij_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
                current_default_colors(inner),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    )?;
    Ok((worker, snapshot, session, geometry, term))
}

fn resolve_remote_zellij_attach_target(
    inventory: &ZellijInventory,
    expected_executable: &str,
    expected_name: &str,
) -> Result<(String, session::ZellijSessionRecord), WorkspaceError> {
    let ZellijInventory::Available {
        executable,
        sessions,
    } = inventory
    else {
        return Err(WorkspaceError::new(
            "Zellij is not available on this SSH host",
        ));
    };
    if executable != expected_executable {
        return Err(WorkspaceError::new(
            "the remote Zellij executable changed; refresh before opening the session",
        ));
    }
    let session = sessions
        .iter()
        .find(|session| session.name() == expected_name)
        .cloned()
        .ok_or_else(|| {
            WorkspaceError::new("Zellij session is no longer active; refresh before opening it")
        })?;
    Ok((executable.clone(), session))
}

fn run_remote_herdr_create(
    inner: &Inner,
    request: &RemoteHerdrCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launched: &AtomicBool,
) {
    let _reset = RemoteConstructiveReset {
        inner,
        host_id: &request.host_id,
        navigation_generation,
    };
    let Some(operation) = lock_session_operations(inner, cancellation) else {
        return;
    };
    let result = create_remote_herdr_fresh(
        inner,
        request,
        navigation_generation,
        cancellation,
        launched,
    )
    .and_then(|(worker, inventory, session, geometry, term)| {
        let snapshot = publish_remote_inventory(
            inner,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            cancellation,
            inventory,
        )?;
        if let Err(error) =
            worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
        {
            return Err(WorkspaceError::from_worker(&error));
        }
        let navigation = inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            drop(worker);
            drop(navigation);
            return Ok(());
        }
        let selection =
            SessionSelection::herdr(&request.host_id, snapshot.endpoint(), session.name());
        let key = RemotePresentationKey {
            host_id: request.host_id.clone(),
            endpoint: snapshot.endpoint().to_owned(),
            route_identity: snapshot.route_identity().to_owned(),
            lease_generation: snapshot.lease_generation(),
            session_identity: RemoteSessionIdentity::Herdr {
                name: session.name().to_owned(),
                is_default: session.is_default(),
                session_directory: session.session_directory().to_owned(),
                socket_path: session.socket_path().to_owned(),
            },
        };
        let published = publish_remote_worker(
            inner,
            worker,
            key,
            &selection,
            snapshot.lease().clone(),
            next_presentation_id(inner),
            term,
            None,
            Some(&RemotePublicationFence {
                host_id: &request.host_id,
                connection_generation: request.connection_generation,
                snapshot: &snapshot,
                cancellation,
            }),
        )
        .map_err(|error| error.error);
        drop(navigation);
        published?;
        Ok(())
    });
    if let Err(error) = &result
        && inner.navigation_generation.load(Ordering::Acquire) == navigation_generation
        && remote_constructive_is_current(inner, &request.host_id, cancellation)
    {
        push_operation_event(inner, WorkspaceEvent::Error(error.to_string()));
        inner.revision.fetch_add(1, Ordering::Release);
    }
    set_remote_herdr_launch_pending(inner, &request.host_id, request.name.as_str(), false);
    let pending = settle_remote_constructive_task(
        inner,
        &request.host_id,
        navigation_generation,
        result.is_ok(),
    );
    drop(operation);
    if let Some(target) = pending {
        reconcile_remote_constructive_after_connection(
            inner,
            &request.host_id,
            request.connection_generation,
            &request.host,
            request.snapshot.clone(),
            &target,
        );
    }
}

fn run_remote_zellij_create(
    inner: &Inner,
    request: &RemoteZellijCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launched: &AtomicBool,
) {
    let _reset = RemoteConstructiveReset {
        inner,
        host_id: &request.host_id,
        navigation_generation,
    };
    let Some(operation) = lock_session_operations(inner, cancellation) else {
        return;
    };
    let result = create_remote_zellij_fresh(
        inner,
        request,
        navigation_generation,
        cancellation,
        launched,
    )
    .and_then(|(worker, inventory, session, geometry, term)| {
        let snapshot = publish_remote_inventory(
            inner,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            cancellation,
            inventory,
        )?;
        if let Err(error) =
            worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
        {
            return Err(WorkspaceError::from_worker(&error));
        }
        let navigation = inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            drop(worker);
            drop(navigation);
            return Ok(());
        }
        let selection =
            SessionSelection::zellij(&request.host_id, snapshot.endpoint(), session.name());
        let key = RemotePresentationKey {
            host_id: request.host_id.clone(),
            endpoint: snapshot.endpoint().to_owned(),
            route_identity: snapshot.route_identity().to_owned(),
            lease_generation: snapshot.lease_generation(),
            session_identity: RemoteSessionIdentity::Zellij(session.name().to_owned()),
        };
        let published = publish_remote_worker(
            inner,
            worker,
            key,
            &selection,
            snapshot.lease().clone(),
            next_presentation_id(inner),
            term,
            None,
            Some(&RemotePublicationFence {
                host_id: &request.host_id,
                connection_generation: request.connection_generation,
                snapshot: &snapshot,
                cancellation,
            }),
        )
        .map_err(|error| error.error);
        drop(navigation);
        published?;
        Ok(())
    });
    if let Err(error) = &result
        && inner.navigation_generation.load(Ordering::Acquire) == navigation_generation
        && remote_constructive_is_current(inner, &request.host_id, cancellation)
    {
        push_operation_event(inner, WorkspaceEvent::Error(error.to_string()));
        inner.revision.fetch_add(1, Ordering::Release);
    }
    let pending = settle_remote_constructive_task(
        inner,
        &request.host_id,
        navigation_generation,
        result.is_ok(),
    );
    drop(operation);
    if let Some(target) = pending {
        reconcile_remote_constructive_after_connection(
            inner,
            &request.host_id,
            request.connection_generation,
            &request.host,
            request.snapshot.clone(),
            &target,
        );
    }
}

fn lock_session_operations<'a>(
    inner: &'a Inner,
    cancellation: &CancellationToken,
) -> Option<std::sync::MutexGuard<'a, ()>> {
    loop {
        match inner.session_operations.try_lock() {
            Ok(operation) => return Some(operation),
            Err(TryLockError::Poisoned(error)) => return Some(error.into_inner()),
            Err(TryLockError::WouldBlock) => {
                if cancellation.wait_cancelled(Duration::from_millis(10)) {
                    return None;
                }
            }
        }
    }
}

fn create_remote_herdr_fresh(
    inner: &Inner,
    request: &RemoteHerdrCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launched: &AtomicBool,
) -> Result<
    (
        TerminalWorker,
        RemoteSessionInventory,
        session::HerdrSessionRecord,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .refresh(request.snapshot.lease(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let HerdrInventory::Available {
        executable,
        sessions,
    } = before.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    if executable != &request.executable {
        return Err(WorkspaceError::new(
            "the remote Herdr executable changed; refresh before creating the session",
        ));
    }
    let current = sessions
        .iter()
        .find(|session| session.name() == request.name.as_str());
    validate_herdr_launch_precondition(&request.precondition, current)?;
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new("remote Herdr creation was superseded"));
    }
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let term = request
        .host
        .probe_terminal_term(&request.snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let worker = with_current_remote_constructive_launch(
        inner,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
        navigation_generation,
        cancellation,
        || {
            let authority = request
                .host
                .herdr_launch_once(
                    &request.snapshot,
                    &request.executable,
                    request.name.clone(),
                    request.precondition.is_default(),
                    term.as_str(),
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            // Constructing the worker consumes the one-shot launch authority
            // even when PTY or containment setup subsequently fails.
            launched.store(true, Ordering::Release);
            let worker = TerminalWorker::launch_herdr_with_metadata(
                authority,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
                current_default_colors(inner),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
            Ok(worker)
        },
    )?;
    let expected_name = request.name.as_str();
    let discovered = poll_session_startup("Herdr", cancellation, &HERDR_STARTUP_BACKOFF, || {
        // Launch authority has already been consumed. Navigation may suppress
        // presentation, but inventory must still converge on the mutation.
        let inventory = request
            .host
            .refresh(request.snapshot.lease(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let session = match inventory.herdr() {
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
        Ok(session.map(|session| (inventory, session)))
    })?;
    if let Some((inventory, session)) = discovered {
        Ok((worker, inventory, session, geometry, term))
    } else {
        drop(worker);
        Err(WorkspaceError::new(
            "Herdr started, but the remote session did not appear in inventory; refresh before trying again",
        ))
    }
}

fn create_remote_zellij_fresh(
    inner: &Inner,
    request: &RemoteZellijCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launched: &AtomicBool,
) -> Result<
    (
        TerminalWorker,
        RemoteSessionInventory,
        session::ZellijSessionRecord,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .refresh(request.snapshot.lease(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let ZellijInventory::Available {
        executable,
        sessions,
    } = before.zellij()
    else {
        return Err(WorkspaceError::new(
            "Zellij is not available on this SSH host",
        ));
    };
    if executable != &request.executable {
        return Err(WorkspaceError::new(
            "the remote Zellij executable changed; refresh before creating the session",
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
        return Err(WorkspaceError::new("remote Zellij creation was superseded"));
    }
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let term = request
        .host
        .probe_terminal_term(&request.snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let worker = with_current_remote_constructive_launch(
        inner,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
        navigation_generation,
        cancellation,
        || {
            let authority = request
                .host
                .zellij_launch_once(
                    &request.snapshot,
                    &request.executable,
                    request.name.clone(),
                    term.as_str(),
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            // Constructing the worker consumes the one-shot launch authority
            // even when PTY or containment setup subsequently fails.
            launched.store(true, Ordering::Release);
            let worker = TerminalWorker::launch_zellij_with_metadata(
                authority,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(inner.allow_remote_clipboard_write),
                current_default_colors(inner),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
            Ok(worker)
        },
    )?;
    let expected_name = request.name.as_str();
    let discovered = poll_session_startup("Zellij", cancellation, &HERDR_STARTUP_BACKOFF, || {
        // Launch authority has already been consumed. Navigation may suppress
        // presentation, but inventory must still converge on the mutation.
        let inventory = request
            .host
            .refresh(request.snapshot.lease(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let session = match inventory.zellij() {
            ZellijInventory::Available {
                executable,
                sessions,
            } if executable == &request.executable => sessions
                .iter()
                .find(|session| session.name() == expected_name)
                .cloned(),
            _ => None,
        };
        Ok(session.map(|session| (inventory, session)))
    })?;
    if let Some((inventory, session)) = discovered {
        Ok((worker, inventory, session, geometry, term))
    } else {
        drop(worker);
        Err(WorkspaceError::new(
            "Zellij started, but the remote session did not appear in inventory; refresh before trying again",
        ))
    }
}

fn publish_remote_inventory(
    inner: &Inner,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    cancellation: &CancellationToken,
    inventory: RemoteSessionInventory,
) -> Result<RemoteTmuxSnapshot, WorkspaceError> {
    let _publication = inner
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let snapshot_write = begin_snapshot_write(inner);
    let mut entries = inner
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get_mut(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected during the operation"))?;
    let fence = RemotePublicationFence {
        host_id,
        connection_generation,
        snapshot: expected,
        cancellation,
    };
    validate_remote_publication_fence(entry, &fence)?;
    let context = entry
        .context
        .as_mut()
        .expect("the publication fence requires a remote context");
    let snapshot = expected.with_inventory(inventory);
    context.snapshot = snapshot.clone();
    drop(entries);
    let stale_presentations = reconcile_remote_presentations(
        inner,
        host_id,
        snapshot.endpoint(),
        snapshot.route_identity(),
        snapshot.lease_generation(),
        Some(RemoteInventory::from(&snapshot)),
    );
    set_remote_host_snapshot(inner, host_id, &snapshot);
    drop(snapshot_write);
    drop(stale_presentations);
    Ok(snapshot)
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
                current_default_colors(inner),
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
        current_default_colors(inner),
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
        current_default_colors(inner),
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
        Ok((worker, snapshot, attached_session, initial_geometry, attached_term)) => {
            let _snapshot_write = begin_snapshot_write(inner);
            let mut attachment = inner
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !attachment.is_current(generation) {
                drop(worker);
                return;
            }
            if let Some(active) = attachment.active_mut() {
                normalize_attached_worktree_target(active, &snapshot, &attached_session);
                active.term = attached_term;
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
                let current_request = attachment
                    .active()
                    .expect("current attachment was checked")
                    .request
                    .clone();
                let fallback = attachment
                    .fallback_if_current(generation)
                    .filter(|fallback| fallback_owns_request(inner, fallback, &current_request));
                attachment.clear_if_current(generation);
                drop(attachment);
                publish_attachment_failure(inner, request.inventory_generation, error);
                restore_attach_fallback(inner, fallback);
                return;
            }
            set_terminal_notice(inner, attached_term);
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

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    reason = "remote publication keeps explicit worker, presentation, and connection authority in one atomic swap"
)]
fn publish_remote_worker(
    inner: &Inner,
    worker: TerminalWorker,
    key: RemotePresentationKey,
    selection: &SessionSelection,
    lease: host::SshLease,
    presentation_id: u64,
    term: AttachTerm,
    identity_mismatch_marker: Option<String>,
    fence: Option<&RemotePublicationFence<'_>>,
) -> Result<(), Box<RemotePublishError>> {
    let surface = worker.surface_handle();
    let snapshot_write = begin_snapshot_write(inner);
    let remote_entries = if let Some(fence) = fence {
        if fence.host_id != selection.host_id() || fence.host_id != key.host_id {
            return Err(Box::new(RemotePublishError {
                error: WorkspaceError::new("the remote publication target changed"),
                worker,
            }));
        }
        let entries = inner
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(entry) = entries.get(fence.host_id) else {
            return Err(Box::new(RemotePublishError {
                error: WorkspaceError::new("the SSH host disconnected during the operation"),
                worker,
            }));
        };
        if let Err(error) = validate_remote_publication_fence(entry, fence) {
            return Err(Box::new(RemotePublishError { error, worker }));
        }
        Some(entries)
    } else {
        None
    };
    let mut attachment = inner
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let geometry = inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Err(error) =
        worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
    {
        return Err(Box::new(RemotePublishError {
            error: WorkspaceError::from_worker(&error),
            worker,
        }));
    }
    let previous_presentation_id = match &*inner
        .state
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
    {
        WorkspaceContent::Terminal {
            presentation_id, ..
        } => Some(*presentation_id),
        _ => None,
    };
    let mut remote_active = inner
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut workers = inner
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(active) = remote_active.as_ref()
        && workers.generation() != active.worker_generation
    {
        return Err(Box::new(RemotePublishError {
            error: WorkspaceError::new(
                "the active remote presentation changed while switching sessions",
            ),
            worker,
        }));
    }
    if (remote_active.is_some() || attachment.active().is_some()) && workers.active().is_none() {
        return Err(Box::new(RemotePublishError {
            error: WorkspaceError::new("the current terminal presentation is unavailable"),
            worker,
        }));
    }
    if attachment.active().is_some() && previous_presentation_id.is_none() {
        return Err(Box::new(RemotePublishError {
            error: WorkspaceError::new("the current terminal presentation identity is unavailable"),
            worker,
        }));
    }

    let previous_attachment = if remote_active.is_none() {
        attachment.take_active()
    } else {
        attachment.invalidate();
        None
    };
    let (worker_generation, previous_worker) = workers.replace(worker);
    let previous_remote = remote_active.replace(RemoteActive {
        key,
        selection: selection.clone(),
        worker_generation,
        lease,
        presentation_id,
        term,
        retainable: retain_remote_session(selection.kind()),
        identity_mismatch_marker,
    });
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
    drop(remote_entries);
    drop(workers);
    drop(remote_active);
    drop(geometry);
    drop(attachment);

    match (previous_worker, previous_remote, previous_attachment) {
        (Some(worker), Some(active), _) if active.retainable => {
            worker.set_clipboard_writes_enabled(false);
            let _cancelled = worker.cancel_paste();
            inner
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(RemoteRetainedPresentation { active, worker });
        }
        (Some(worker), None, Some(attachment)) => {
            worker.set_clipboard_writes_enabled(false);
            let _cancelled = worker.cancel_paste();
            let selection = attachment.request.selection();
            let key = attachment.request.presentation_key();
            inner
                .retained_presentations
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(RetainedPresentation {
                    key,
                    selection,
                    attachment,
                    worker,
                    presentation_id: previous_presentation_id
                        .expect("active local presentation identity was checked"),
                });
        }
        _ => {}
    }
    drop(snapshot_write);
    Ok(())
}

#[allow(
    clippy::too_many_lines,
    reason = "cross-host attachment keeps preparation, authority validation, and swap together"
)]
fn run_attach_over_remote(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
    generation: u64,
    navigation_generation: u64,
) {
    let _operation = inner
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation
        || !inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_current(generation)
    {
        return;
    }
    let result = attach_fresh(inner, request, term);
    let snapshot_write = begin_snapshot_write(inner);
    let mut attachment = inner
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.navigation_generation.load(Ordering::Acquire) != navigation_generation
        || !attachment.is_current(generation)
    {
        return;
    }
    let (worker, snapshot, attached_session, initial_geometry, attached_term) = match result {
        Ok(prepared) => prepared,
        Err(error) => {
            attachment.clear_if_current(generation);
            drop(attachment);
            let message = match error {
                AttachFreshError::Host(error) | AttachFreshError::SessionChanged { error, .. } => {
                    error.to_string()
                }
            };
            push_operation_event(inner, WorkspaceEvent::Error(message));
            inner.revision.fetch_add(1, Ordering::Release);
            return;
        }
    };
    if let Some(active) = attachment.active_mut() {
        normalize_attached_worktree_target(active, &snapshot, &attached_session);
        active.term = attached_term;
    }
    let surface = worker.surface_handle();
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
    let geometry = inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if *geometry != initial_geometry
        && let Err(error) =
            worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
    {
        attachment.clear_if_current(generation);
        drop(attachment);
        push_operation_event(inner, WorkspaceEvent::Error(error.to_string()));
        inner.revision.fetch_add(1, Ordering::Release);
        return;
    }
    let mut remote_active = inner
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(active_remote) = remote_active.as_ref() else {
        attachment.clear_if_current(generation);
        return;
    };
    let mut workers = inner
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if workers.generation() != active_remote.worker_generation {
        attachment.clear_if_current(generation);
        return;
    }
    let (_, previous_worker) = workers.replace(worker);
    let previous_remote = remote_active.take();
    set_terminal_notice(inner, attached_term);
    let presentation_id = next_presentation_id(inner);
    set_inner_state(
        inner,
        WorkspaceContent::Terminal {
            host_id: request.host_id.clone(),
            endpoint: request.endpoint.distro().to_owned(),
            session,
            kind: request.target.kind(),
            presentation_id,
            surface,
        },
    );
    drop(workers);
    drop(remote_active);
    drop(geometry);
    drop(attachment);
    if let (Some(worker), Some(active)) = (previous_worker, previous_remote)
        && active.retainable
    {
        worker.set_clipboard_writes_enabled(false);
        let _cancelled = worker.cancel_paste();
        inner
            .remote_retained
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(RemoteRetainedPresentation { active, worker });
    }
    drop(snapshot_write);
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
                *inner
                    .terminal_notice
                    .write()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(notice);
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
    let (worker, _snapshot, attached_name, initial_geometry, attached_term) =
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
    closed.attachment.term = attached_term;
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
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        String,
        TerminalGeometry,
        AttachTerm,
    ),
    AttachFreshError,
> {
    let fresh = discover_fresh_runtime(request)?;
    let (worker, snapshot, name, geometry, actual_term) = match &request.target {
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
            let (worker, snapshot, name, geometry) =
                launch_fresh_tmux(inner, request, term, &fresh, &session)?;
            (worker, snapshot, name, geometry, term)
        }
        AttachTarget::Worktree {
            repository,
            registration_fingerprint,
            path,
            generation,
            session_name,
        } => {
            let cancellation = CancellationToken::new();
            let open = host::KwtWorktreeOpen::new(
                path,
                repository,
                registration_fingerprint,
                generation.as_deref().ok_or_else(|| {
                    kwt_attachment_failure(
                        &fresh,
                        "worktree generation is unavailable; refresh KWT inventory before opening it",
                    )
                })?,
                session_name,
            );
            launch_fresh_worktree(inner, request, term, &fresh, &open, &cancellation)?
        }
        AttachTarget::ProtectedWorktree {
            repository,
            project_path,
            registration_fingerprint,
            path,
            generation,
            session_name,
            tmux_socket_name,
        } => {
            let cancellation = CancellationToken::new();
            let open = host::KwtProtectedWorktreeOpen::new(
                path,
                project_path,
                repository,
                registration_fingerprint,
                generation,
                session_name,
                tmux_socket_name,
            );
            launch_fresh_protected_worktree(inner, request, term, &fresh, &open, &cancellation)?
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
            let (worker, snapshot, name, geometry) =
                launch_fresh_herdr(inner, request, term, &fresh, &session)?;
            (worker, snapshot, name, geometry, term)
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
            let (worker, snapshot, name, geometry) =
                launch_fresh_zellij(inner, request, term, &fresh, &session)?;
            (worker, snapshot, name, geometry, term)
        }
    };
    Ok((worker, snapshot, name, geometry, actual_term))
}

#[allow(
    clippy::too_many_lines,
    reason = "retained restart dispatch covers every multiplexer capability without erasing backend identity"
)]
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
            registration_fingerprint,
            path,
            generation,
            session_name,
        } => {
            let cancellation = CancellationToken::new();
            let open = host::KwtWorktreeOpen::new(
                path,
                repository,
                registration_fingerprint,
                generation.as_deref().ok_or_else(|| {
                    kwt_attachment_failure(
                        &fresh,
                        "worktree generation is unavailable; refresh KWT inventory before opening it",
                    )
                })?,
                session_name,
            );
            let (worker, snapshot, name, geometry, _actual_term) = launch_fresh_worktree(
                inner,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                &open,
                &cancellation,
            )?;
            (worker, snapshot, name, geometry)
        }
        AttachTarget::ProtectedWorktree {
            repository,
            project_path,
            registration_fingerprint,
            path,
            generation,
            session_name,
            tmux_socket_name,
        } => {
            let cancellation = CancellationToken::new();
            let open = host::KwtProtectedWorktreeOpen::new(
                path,
                project_path,
                repository,
                registration_fingerprint,
                generation,
                session_name,
                tmux_socket_name,
            );
            let (worker, snapshot, name, geometry, _actual_term) = launch_fresh_protected_worktree(
                inner,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                &open,
                &cancellation,
            )?;
            (worker, snapshot, name, geometry)
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

fn kwt_attachment_failure(fresh: &HostSnapshot, error: impl fmt::Display) -> AttachFreshError {
    AttachFreshError::SessionChanged {
        error: WorkspaceError::new(error.to_string()),
        snapshot: Box::new(fresh.clone()),
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
        current_default_colors(inner),
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
    tmux_socket_name: Option<&str>,
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
                        && worktree.tmux_socket_name.as_deref() == tmux_socket_name
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
            target: if let Some(tmux_socket_name) = &worktree.tmux_socket_name {
                AttachTarget::ProtectedWorktree {
                    repository: repository.to_owned(),
                    project_path: project_path.to_owned(),
                    registration_fingerprint: registration_fingerprint.to_owned(),
                    path: worktree.path.clone(),
                    generation: worktree.generation.clone().ok_or_else(|| {
                        WorkspaceError::new(
                            "protected worktree generation is unavailable; refresh KWT inventory",
                        )
                    })?,
                    session_name: worktree.session_name.clone(),
                    tmux_socket_name: tmux_socket_name.clone(),
                }
            } else {
                AttachTarget::Worktree {
                    repository: repository.to_owned(),
                    registration_fingerprint: registration_fingerprint.to_owned(),
                    path: worktree.path.clone(),
                    generation: worktree.generation.clone(),
                    session_name: worktree.session_name.clone(),
                }
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
    open: &host::KwtWorktreeOpen,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        String,
        TerminalGeometry,
        AttachTerm,
    ),
    AttachFreshError,
> {
    match launch_fresh_worktree_once(inner, request, term, fresh, open, cancellation) {
        Ok((worker, snapshot, name, geometry)) => Ok((worker, snapshot, name, geometry, term)),
        Err(WorktreeLaunchError::RetryWithXterm) if term == AttachTerm::Xterm256Color => {
            let (worker, snapshot, name, geometry) = launch_fresh_worktree_once(
                inner,
                request,
                AttachTerm::Xterm,
                fresh,
                open,
                cancellation,
            )
            .map_err(WorktreeLaunchError::into_attach_error)?;
            Ok((worker, snapshot, name, geometry, AttachTerm::Xterm))
        }
        Err(error) => Err(error.into_attach_error()),
    }
}

fn launch_fresh_protected_worktree(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtProtectedWorktreeOpen,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        String,
        TerminalGeometry,
        AttachTerm,
    ),
    AttachFreshError,
> {
    match launch_fresh_protected_worktree_once(inner, request, term, fresh, open, cancellation) {
        Ok((worker, snapshot, name, geometry)) => Ok((worker, snapshot, name, geometry, term)),
        Err(WorktreeLaunchError::RetryWithXterm) if term == AttachTerm::Xterm256Color => {
            let (worker, snapshot, name, geometry) = launch_fresh_protected_worktree_once(
                inner,
                request,
                AttachTerm::Xterm,
                fresh,
                open,
                cancellation,
            )
            .map_err(WorktreeLaunchError::into_attach_error)?;
            Ok((worker, snapshot, name, geometry, AttachTerm::Xterm))
        }
        Err(error) => Err(error.into_attach_error()),
    }
}

fn launch_fresh_protected_worktree_once(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtProtectedWorktreeOpen,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), WorktreeLaunchError> {
    validate_protected_worktree_inventory(request, cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
    let plan = request
        .host
        .kwt_protected_attach_plan(fresh.endpoint(), fresh.runtime(), open, term, cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
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
        current_default_colors(inner),
    )
    .map_err(|error| {
        WorktreeLaunchError::Attach(AttachFreshError::Host(WorkspaceError::new(
            error.to_string(),
        )))
    })?;
    let readiness_path = plan.readiness_path().to_owned();
    let client_identity = wait_for_worktree_client_startup(
        term,
        cancellation,
        &WORKTREE_CLIENT_STARTUP_BACKOFF,
        || {
            worker
                .startup_status()
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
        || {
            request
                .host
                .kwt_protected_client_session_identity(
                    fresh.endpoint(),
                    fresh.runtime(),
                    &readiness_path,
                    open.tmux_socket_name(),
                    cancellation,
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    );
    request.host.remove_kwt_client_readiness(
        fresh.endpoint(),
        &readiness_path,
        &CancellationToken::new(),
    );
    match client_identity {
        Ok(_) => {
            validate_protected_worktree_inventory(request, cancellation).map_err(|error| {
                WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error))
            })?;
            Ok((
                worker,
                fresh.clone(),
                plan.target_name().to_owned(),
                geometry,
            ))
        }
        Err(error) => {
            drop(worker);
            Err(match error {
                WorktreeClientStartupError::RetryWithXterm => WorktreeLaunchError::RetryWithXterm,
                WorktreeClientStartupError::Failed(error) => {
                    WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error))
                }
            })
        }
    }
}

fn validate_protected_worktree_inventory(
    request: &AttachRequest,
    cancellation: &CancellationToken,
) -> Result<(), WorkspaceError> {
    let AttachTarget::ProtectedWorktree {
        repository,
        project_path,
        registration_fingerprint,
        path,
        generation,
        session_name,
        tmux_socket_name,
    } = &request.target
    else {
        return Err(WorkspaceError::new(
            "protected worktree authority was missing",
        ));
    };
    let inventory = request
        .host
        .discover_kwt(&request.endpoint, &request.runtime, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?
        .ok_or_else(|| WorkspaceError::new("KWT is no longer available on this host"))?;
    let exact = inventory.projects().iter().any(|project| {
        project.project().repository() == repository
            && project.project().path() == project_path
            && project.project().registration_fingerprint() == registration_fingerprint
            && project.worktrees().iter().any(|worktree| {
                worktree.path() == path
                    && worktree.generation() == Some(generation)
                    && worktree.session_name() == session_name
                    && worktree.tmux_socket_name() == Some(tmux_socket_name)
            })
    });
    if exact {
        Ok(())
    } else {
        Err(WorkspaceError::new(
            "the protected worktree changed; refresh and choose it again",
        ))
    }
}

enum WorktreeLaunchError {
    RetryWithXterm,
    Attach(AttachFreshError),
}

impl WorktreeLaunchError {
    fn into_attach_error(self) -> AttachFreshError {
        match self {
            Self::RetryWithXterm => AttachFreshError::Host(WorkspaceError::new(
                "KWT worktree client could not use the selected terminal type",
            )),
            Self::Attach(error) => error,
        }
    }
}

fn launch_fresh_worktree_once(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtWorktreeOpen,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), WorktreeLaunchError> {
    let plan = request
        .host
        .kwt_repair_or_open_plan(fresh.endpoint(), fresh.runtime(), open, term, cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
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
        current_default_colors(inner),
    )
    .map_err(|error| {
        WorktreeLaunchError::Attach(AttachFreshError::Host(WorkspaceError::new(
            error.to_string(),
        )))
    })?;
    let readiness_path = plan.readiness_path().to_owned();
    let client_identity = wait_for_worktree_client_startup(
        term,
        cancellation,
        &WORKTREE_CLIENT_STARTUP_BACKOFF,
        || {
            worker
                .startup_status()
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
        || {
            request
                .host
                .kwt_client_session_identity(
                    fresh.endpoint(),
                    fresh.runtime(),
                    &readiness_path,
                    cancellation,
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    );
    request.host.remove_kwt_client_readiness(
        fresh.endpoint(),
        &readiness_path,
        &CancellationToken::new(),
    );
    let client_identity = match client_identity {
        Ok(identity) => identity,
        Err(error) => {
            drop(worker);
            return Err(match error {
                WorktreeClientStartupError::RetryWithXterm => WorktreeLaunchError::RetryWithXterm,
                WorktreeClientStartupError::Failed(error) => {
                    WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error))
                }
            });
        }
    };
    let discovered = request
        .host
        .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
    if discovered.endpoint() != &request.endpoint || discovered.runtime() != &request.runtime {
        drop(worker);
        return Err(WorktreeLaunchError::Attach(kwt_attachment_failure(
            fresh,
            "WSL changed while opening the worktree session",
        )));
    }
    let identity_matches = discovered.sessions().iter().any(|session| {
        session.name() == open.session_name() && session.identity() == &client_identity
    });
    if !identity_matches {
        drop(worker);
        return Err(WorktreeLaunchError::Attach(kwt_attachment_failure(
            fresh,
            "KWT attached its client to a session that did not match the worktree inventory",
        )));
    }
    Ok((worker, discovered, plan.target_name().to_owned(), geometry))
}

#[derive(Debug)]
enum WorktreeClientStartupError {
    RetryWithXterm,
    Failed(WorkspaceError),
}

fn wait_for_worktree_client_startup(
    term: AttachTerm,
    cancellation: &CancellationToken,
    backoff: &[Duration],
    mut observe: impl FnMut() -> Result<TerminalStartup, WorkspaceError>,
    mut readiness: impl FnMut() -> Result<Option<session::SessionIdentity>, WorkspaceError>,
) -> Result<session::SessionIdentity, WorktreeClientStartupError> {
    let mut candidate = None;
    for delay in backoff {
        match observe().map_err(WorktreeClientStartupError::Failed)? {
            TerminalStartup::Exited { code, output_tail } => {
                return classify_kwt_startup_exit(code, &output_tail, term);
            }
            TerminalStartup::Failed(error) => {
                return Err(WorktreeClientStartupError::Failed(WorkspaceError::new(
                    format!("KWT could not open the worktree: {error}"),
                )));
            }
            TerminalStartup::Confirmed | TerminalStartup::Pending => {}
        }
        if let Some(identity) = readiness().map_err(WorktreeClientStartupError::Failed)? {
            if candidate.as_ref() == Some(&identity) {
                return Ok(identity);
            }
            candidate = Some(identity);
        } else {
            candidate = None;
        }
        if cancellation.wait_cancelled(*delay) {
            return Err(WorktreeClientStartupError::Failed(WorkspaceError::new(
                "KWT worktree startup was cancelled",
            )));
        }
    }
    match observe().map_err(WorktreeClientStartupError::Failed)? {
        TerminalStartup::Exited { code, output_tail } => {
            classify_kwt_startup_exit(code, &output_tail, term)
        }
        TerminalStartup::Failed(error) => Err(WorktreeClientStartupError::Failed(
            WorkspaceError::new(format!("KWT could not open the worktree: {error}")),
        )),
        TerminalStartup::Confirmed | TerminalStartup::Pending => {
            if let Some(identity) = readiness().map_err(WorktreeClientStartupError::Failed)?
                && candidate.as_ref() == Some(&identity)
            {
                return Ok(identity);
            }
            Err(WorktreeClientStartupError::Failed(WorkspaceError::new(
                "KWT worktree client did not establish an attached tmux client",
            )))
        }
    }
}

fn classify_kwt_startup_exit<T>(
    code: u32,
    output_tail: &str,
    term: AttachTerm,
) -> Result<T, WorktreeClientStartupError> {
    if is_exact_terminfo_startup_failure(output_tail, term) && term == AttachTerm::Xterm256Color {
        return Err(WorktreeClientStartupError::RetryWithXterm);
    }
    let message = if is_exact_terminfo_startup_failure(output_tail, term) {
        "WSL does not provide usable xterm terminfo for terminal attachment".to_owned()
    } else {
        format!(
            "KWT could not open the worktree: {}",
            classify_kwt_client_exit(code, output_tail)
        )
    };
    Err(WorktreeClientStartupError::Failed(WorkspaceError::new(
        message,
    )))
}

fn classify_kwt_client_exit(code: u32, output_tail: &str) -> String {
    host::kwt_command_failure_message(output_tail.as_bytes())
        .unwrap_or_else(|| format!("KWT client exited with status {code}"))
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
                current_default_colors(inner),
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
        current_default_colors(inner),
    )
    .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    Ok((worker, fresh.clone(), session.name().to_owned(), geometry))
}

fn set_terminal_notice(inner: &Inner, term: AttachTerm) {
    let notice = (term == AttachTerm::Xterm).then(|| WorkspaceNotice {
        message: REDUCED_COLOR_NOTICE.to_owned(),
        transient: true,
    });
    *inner
        .terminal_notice
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = notice;
}

fn set_local_notice(inner: &Inner, message: String) {
    *inner
        .terminal_notice
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(WorkspaceNotice {
        message,
        transient: false,
    });
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

fn current_default_colors(inner: &Inner) -> DefaultColors {
    let appearance = inner
        .appearance
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    default_colors(&appearance)
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
    apply_herdr_inventory(host, inventory);
}

fn apply_herdr_inventory(host: &mut HostItem, inventory: &HerdrInventory) {
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
    apply_zellij_inventory(host, inventory);
}

fn apply_zellij_inventory(host: &mut HostItem, inventory: &ZellijInventory) {
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

fn classify_remote_terminal_exit(
    code: u32,
    output_tail: &str,
    identity_mismatch_marker: Option<&str>,
) -> Option<String> {
    let has_identity_mismatch = identity_mismatch_marker.is_some_and(|marker| {
        output_tail
            .lines()
            .map(str::trim)
            .any(|line| line == marker)
    });
    if has_identity_mismatch {
        return Some(
            "session identity changed immediately before attachment; refresh and try again"
                .to_owned(),
        );
    }
    (code != 0).then(|| {
        let tail = output_tail.trim();
        if tail.is_empty() {
            format!("Remote session client exited with status {code}")
        } else {
            tail.to_owned()
        }
    })
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
    use terminal::TerminalEngine;

    const TEST_REMOTE_ROUTE: &str =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn remote_host_fixture(config: &RemoteTmuxConfig) -> RuntimeRemoteHost {
        let controller =
            KwtSshExecutable::from_absolute(std::env::current_exe().expect("test executable path"))
                .expect("absolute controller path");
        let ssh = SshExecutable::system().expect("system SSH");
        RemoteTmuxHost::new(
            config.clone(),
            &controller,
            &ssh,
            Arc::new(StdCommandRunner),
        )
    }

    fn remote_herdr_target(name: &str) -> RemoteConstructiveTarget {
        RemoteConstructiveTarget::Herdr {
            route_identity: TEST_REMOTE_ROUTE.to_owned(),
            executable: "/usr/bin/herdr".to_owned(),
            name: name.to_owned(),
            precondition: HerdrLaunchPrecondition::Absent,
        }
    }

    fn remote_zellij_target(name: &str) -> RemoteConstructiveTarget {
        RemoteConstructiveTarget::Zellij {
            route_identity: TEST_REMOTE_ROUTE.to_owned(),
            executable: "/usr/bin/zellij".to_owned(),
            name: name.to_owned(),
        }
    }

    #[test]
    fn remote_constructive_reconciliation_requires_original_authority() {
        let route = TEST_REMOTE_ROUTE;
        let stopped = session::HerdrSessionRecord::new(
            "agents",
            false,
            HerdrSessionState::Stopped,
            "/srv/herdr/agents",
            "/srv/herdr/agents/herdr.sock",
        );
        let target = RemoteConstructiveTarget::Herdr {
            route_identity: route.to_owned(),
            executable: "/usr/bin/herdr".to_owned(),
            name: "agents".to_owned(),
            precondition: HerdrLaunchPrecondition::Stopped(stopped),
        };
        let matching = RemoteTmuxSnapshot::test_fixture(
            "studio.example",
            route,
            7,
            Vec::new(),
            HerdrInventory::Available {
                executable: "/usr/bin/herdr".to_owned(),
                sessions: vec![session::HerdrSessionRecord::new(
                    "agents",
                    false,
                    HerdrSessionState::Running,
                    "/srv/herdr/agents",
                    "/srv/herdr/agents/herdr.sock",
                )],
            },
            ZellijInventory::Unavailable,
        );
        assert!(remote_constructive_target_is_present(&matching, &target));

        let changed_route = RemoteTmuxSnapshot::test_fixture(
            "replacement.example",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            8,
            Vec::new(),
            matching.herdr().clone(),
            ZellijInventory::Unavailable,
        );
        assert!(!remote_constructive_target_is_present(
            &changed_route,
            &target
        ));

        let changed_executable = RemoteTmuxSnapshot::test_fixture(
            "studio.example",
            route,
            8,
            Vec::new(),
            HerdrInventory::Available {
                executable: "/opt/homebrew/bin/herdr".to_owned(),
                sessions: match matching.herdr() {
                    HerdrInventory::Available { sessions, .. } => sessions.clone(),
                    _ => unreachable!("matching fixture has Herdr inventory"),
                },
            },
            ZellijInventory::Unavailable,
        );
        assert!(!remote_constructive_target_is_present(
            &changed_executable,
            &target
        ));

        let replacement = RemoteTmuxSnapshot::test_fixture(
            "studio.example",
            route,
            8,
            Vec::new(),
            HerdrInventory::Available {
                executable: "/usr/bin/herdr".to_owned(),
                sessions: vec![session::HerdrSessionRecord::new(
                    "agents",
                    false,
                    HerdrSessionState::Running,
                    "/srv/herdr/replacement",
                    "/srv/herdr/replacement/herdr.sock",
                )],
            },
            ZellijInventory::Unavailable,
        );
        assert!(!remote_constructive_target_is_present(
            &replacement,
            &target
        ));
    }

    #[test]
    fn consumed_remote_launch_failure_remains_pending_for_reconciliation() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "",
            None,
        )
        .expect("valid remote host");
        let target = remote_zellij_target("review");
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                config.id().to_owned(),
                RemoteEntry {
                    config,
                    native_host: None,
                    context: None,
                    cancellation: None,
                    constructive_cancellation: Some(RemoteConstructiveState::Active {
                        navigation_generation: 6,
                        cancellation: CancellationToken::new(),
                        launched: Arc::new(AtomicBool::new(true)),
                        target: target.clone(),
                    }),
                    attachment_attempt: None,
                    generation: 7,
                },
            );

        let pending = settle_remote_constructive_task(&workspace.inner, "ssh:studio", 6, false);

        assert_eq!(pending, Some(target.clone()));
        assert_eq!(
            pending_remote_constructive_target(&workspace.inner, "ssh:studio"),
            Some(target)
        );
    }

    #[test]
    fn remote_zellij_attachment_requires_fresh_executable_and_active_session() {
        let available = ZellijInventory::Available {
            executable: "/opt/homebrew/bin/zellij".to_owned(),
            sessions: vec![session::ZellijSessionRecord::discovered("review")],
        };

        let (executable, session) =
            resolve_remote_zellij_attach_target(&available, "/opt/homebrew/bin/zellij", "review")
                .expect("fresh active session");
        assert_eq!(executable, "/opt/homebrew/bin/zellij");
        assert_eq!(session.name(), "review");
        assert!(
            resolve_remote_zellij_attach_target(&available, "/usr/bin/zellij", "review").is_err()
        );
        assert!(
            resolve_remote_zellij_attach_target(
                &ZellijInventory::Available {
                    executable: "/opt/homebrew/bin/zellij".to_owned(),
                    sessions: Vec::new(),
                },
                "/opt/homebrew/bin/zellij",
                "review",
            )
            .is_err()
        );
    }

    #[test]
    fn queued_remote_attachment_recaptures_newer_same_connection_inventory() {
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "/usr/bin/tmux",
            None,
        )
        .expect("valid remote host");
        let host = remote_host_fixture(&config);
        let identity = session::SessionIdentity::new(42, "$1", 100);
        let initial = RemoteTmuxSnapshot::test_fixture(
            "studio.example",
            TEST_REMOTE_ROUTE,
            7,
            vec![session::DiscoveredSession::new(
                "build",
                identity.clone(),
                0,
            )],
            HerdrInventory::Unavailable,
            ZellijInventory::Unavailable,
        );
        let request = RemoteTmuxAttachRequest {
            host_id: config.id().to_owned(),
            connection_generation: 7,
            selection: SessionSelection::new(config.id(), config.endpoint(), "build"),
            host: host.clone(),
            snapshot: initial.clone(),
            session: initial.sessions()[0].clone(),
        };
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                config.id(),
                config.name(),
                config.endpoint(),
                HostConnectionState::Ready,
                vec![SessionItem::new("build", 0)],
                None,
            )],
        ));
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                config.id().to_owned(),
                RemoteEntry {
                    config,
                    native_host: Some(host.clone()),
                    context: Some(RemoteHostContext {
                        generation: 7,
                        host,
                        snapshot: initial.clone(),
                    }),
                    cancellation: None,
                    constructive_cancellation: None,
                    attachment_attempt: None,
                    generation: 7,
                },
            );
        let published = publish_remote_inventory(
            &workspace.inner,
            "ssh:studio",
            7,
            &initial,
            &CancellationToken::new(),
            RemoteSessionInventory::test_fixture(
                Some("/usr/bin/tmux".to_owned()),
                vec![
                    session::DiscoveredSession::new("build", identity.clone(), 0),
                    session::DiscoveredSession::new(
                        "created",
                        session::SessionIdentity::new(42, "$2", 101),
                        0,
                    ),
                ],
                HerdrInventory::Unavailable,
                ZellijInventory::Unavailable,
            ),
        )
        .expect("creation publishes newer inventory");

        let recaptured = recapture_remote_tmux_attach_request(&workspace.inner, &request)
            .expect("queued attachment accepts the newer inventory");

        assert_eq!(recaptured.snapshot.inventory_generation(), 1);
        assert_eq!(
            recaptured.snapshot.inventory_generation(),
            published.inventory_generation()
        );
        assert_eq!(recaptured.session.identity(), &identity);
        assert_eq!(recaptured.snapshot.sessions().len(), 2);
    }

    #[test]
    fn remote_herdr_attachment_requires_fresh_running_identity() {
        let expected = session::HerdrSessionRecord::new(
            "review",
            false,
            HerdrSessionState::Running,
            "/tmp/herdr/review",
            "/tmp/herdr/review.sock",
        );
        let available = HerdrInventory::Available {
            executable: "/usr/local/bin/herdr".to_owned(),
            sessions: vec![expected.clone()],
        };

        let (executable, session) =
            resolve_remote_herdr_attach_target(&available, "/usr/local/bin/herdr", &expected)
                .expect("fresh running session");
        assert_eq!(executable, "/usr/local/bin/herdr");
        assert_eq!(session, expected);

        for replacement in [
            session::HerdrSessionRecord::new(
                "review",
                false,
                HerdrSessionState::Stopped,
                "/tmp/herdr/review",
                "/tmp/herdr/review.sock",
            ),
            session::HerdrSessionRecord::new(
                "review",
                true,
                HerdrSessionState::Running,
                "/tmp/herdr/review",
                "/tmp/herdr/review.sock",
            ),
            session::HerdrSessionRecord::new(
                "review",
                false,
                HerdrSessionState::Running,
                "/tmp/herdr/replacement",
                "/tmp/herdr/replacement.sock",
            ),
        ] {
            assert!(
                resolve_remote_herdr_attach_target(
                    &HerdrInventory::Available {
                        executable: "/usr/local/bin/herdr".to_owned(),
                        sessions: vec![replacement],
                    },
                    "/usr/local/bin/herdr",
                    &expected,
                )
                .is_err()
            );
        }
        assert!(
            resolve_remote_herdr_attach_target(&available, "/usr/bin/herdr", &expected).is_err()
        );
    }

    #[test]
    fn only_remote_tmux_presentations_are_retainable() {
        assert!(retain_remote_session(SessionKind::Tmux));
        assert!(!retain_remote_session(SessionKind::Herdr));
        assert!(!retain_remote_session(SessionKind::Zellij));
    }

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

    #[test]
    fn worktree_removal_requires_a_canonical_generation() {
        assert!(is_canonical_kwt_generation(
            "0123456789abcdef0123456789ABCDEF"
        ));
        assert!(!is_canonical_kwt_generation("0123456789abcdef"));
        assert!(!is_canonical_kwt_generation(
            "0123456789abcdef0123456789abcdeg"
        ));
    }

    #[test]
    fn worktree_removal_capture_requires_the_reviewed_tmux_socket() {
        let (workspace, _runtime) = kwt_worktree_workspace_fixture();
        let generation = "22222222222222222222222222222222";
        workspace.inner.hosts.write().expect("hosts")[0].projects[0]
            .worktrees
            .push(WorktreeItem::new(
                "/work/project/protected",
                "protected",
                false,
                Some(generation.to_owned()),
                "project-protected",
                Some("kwt-pr-reviewed".to_owned()),
                false,
            ));

        let captured = capture_kwt_worktree_removal_context(
            &workspace.inner,
            "wsl",
            "Ubuntu",
            "project-id",
            "/repos/project",
            "project-fingerprint",
            "/work/project/protected",
            generation,
            "project-protected",
            Some("kwt-pr-reviewed"),
        )
        .expect("the reviewed protected socket grants removal capture");
        assert_eq!(captured.3.as_deref(), Some("kwt-pr-reviewed"));

        workspace.inner.hosts.write().expect("hosts")[0].projects[0].worktrees[1]
            .tmux_socket_name = Some("kwt-pr-replacement".to_owned());
        assert!(
            capture_kwt_worktree_removal_context(
                &workspace.inner,
                "wsl",
                "Ubuntu",
                "project-id",
                "/repos/project",
                "project-fingerprint",
                "/work/project/protected",
                generation,
                "project-protected",
                Some("kwt-pr-reviewed"),
            )
            .is_err(),
            "a changed protected socket requires a fresh removal confirmation"
        );
    }

    #[test]
    fn later_kwt_inventory_resolves_a_pending_created_worktree_once() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        workspace
            .inner
            .pending_kwt_creations
            .lock()
            .expect("pending creations")
            .push(PendingKwtCreation {
                endpoint: snapshot.endpoint().clone(),
                repository: "github.com/acme/widget".to_owned(),
                project_path: "/code/widget".to_owned(),
                registration_fingerprint: "registration".to_owned(),
                branch: "feature/new".to_owned(),
                navigation_generation: 41,
                baseline: Vec::new(),
                refreshes_remaining: PENDING_KWT_CREATION_REFRESH_LIMIT,
                deadline: Instant::now() + PENDING_KWT_CREATION_LIFETIME,
            });
        let inventory = KwtInventory::parse(
            br#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"registration"}]"#,
            br#"[{"path":"/work/widget/new","branch":"feature/new","commit_hash":"abc","is_main":false,"created_at":null,"generation":"0123456789abcdef0123456789abcdef","repository":"github.com/acme/widget","session_name":"widget-new","tmux_socket_name":null}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");

        resolve_pending_kwt_creations(&workspace.inner, snapshot.endpoint(), &inventory);
        resolve_pending_kwt_creations(&workspace.inner, snapshot.endpoint(), &inventory);

        assert!(
            workspace
                .inner
                .pending_kwt_creations
                .lock()
                .expect("pending creations")
                .is_empty()
        );
        let events = workspace
            .inner
            .operation_events
            .lock()
            .expect("operation events");
        assert_eq!(events.len(), 1);
        assert!(matches!(
            events.front(),
            Some(WorkspaceEvent::KwtWorktreeCreated {
                target,
                navigation_generation: 41,
            }) if target.worktree_path() == "/work/widget/new"
        ));
    }

    #[test]
    fn pending_creation_ignores_a_preexisting_same_branch_worktree_and_expires() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let baseline = KwtWorktreeIdentity {
            path: "/work/widget/existing".to_owned(),
            generation: Some("0123456789abcdef0123456789abcdef".to_owned()),
        };
        workspace
            .inner
            .pending_kwt_creations
            .lock()
            .expect("pending creations")
            .push(PendingKwtCreation {
                endpoint: snapshot.endpoint().clone(),
                repository: "github.com/acme/widget".to_owned(),
                project_path: "/code/widget".to_owned(),
                registration_fingerprint: "registration".to_owned(),
                branch: "feature/new".to_owned(),
                navigation_generation: 42,
                baseline: vec![baseline],
                refreshes_remaining: 2,
                deadline: Instant::now() + Duration::from_mins(1),
            });
        let inventory = KwtInventory::parse(
            br#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"registration"}]"#,
            br#"[{"path":"/work/widget/existing","branch":"feature/new","commit_hash":"def","is_main":false,"created_at":null,"generation":"fedcba9876543210fedcba9876543210","repository":"github.com/acme/widget","session_name":"widget-existing","tmux_socket_name":null}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");

        resolve_pending_kwt_creations(&workspace.inner, snapshot.endpoint(), &inventory);
        assert!(workspace.drain_events().0.is_empty());
        resolve_pending_kwt_creations(&workspace.inner, snapshot.endpoint(), &inventory);

        assert!(matches!(
            workspace.drain_events().0.as_slice(),
            [WorkspaceEvent::KwtWorktreeCreationExpired {
                project_path,
                navigation_generation: 42,
                ..
            }] if project_path == "/code/widget"
        ));
    }

    #[test]
    fn confirmed_creation_expiry_rejects_a_late_same_branch_worktree() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let now = Instant::now();
        workspace
            .inner
            .pending_kwt_creations
            .lock()
            .expect("pending creations")
            .push(PendingKwtCreation {
                endpoint: snapshot.endpoint().clone(),
                repository: "github.com/acme/widget".to_owned(),
                project_path: "/code/widget".to_owned(),
                registration_fingerprint: "registration".to_owned(),
                branch: "feature/new".to_owned(),
                navigation_generation: 43,
                baseline: Vec::new(),
                refreshes_remaining: PENDING_KWT_CREATION_REFRESH_LIMIT,
                deadline: now,
            });
        let inventory = KwtInventory::parse(
            br#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"registration"}]"#,
            br#"[{"path":"/work/widget/late","branch":"feature/new","commit_hash":"abc","is_main":false,"created_at":null,"generation":"0123456789abcdef0123456789abcdef","repository":"github.com/acme/widget","session_name":"widget-late","tmux_socket_name":null}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");

        resolve_pending_kwt_creations_at(&workspace.inner, snapshot.endpoint(), &inventory, now);

        assert!(matches!(
            workspace.drain_events().0.as_slice(),
            [WorkspaceEvent::KwtWorktreeCreationExpired {
                navigation_generation: 43,
                ..
            }]
        ));
        resolve_pending_kwt_creations_at(
            &workspace.inner,
            snapshot.endpoint(),
            &inventory,
            now + Duration::from_secs(1),
        );
        assert!(workspace.drain_events().0.is_empty());
    }

    #[test]
    fn worktree_removal_authority_can_be_restored_before_dispatch() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "widget-topic",
                identity.clone(),
                1,
            )],
        );
        let authority = 7;
        workspace
            .inner
            .kwt_removal_generation
            .store(authority, Ordering::Release);
        workspace
            .inner
            .pending_kwt_removal
            .lock()
            .expect("pending removal")
            .replace(PendingKwtRemoval {
                authority,
                endpoint: snapshot.endpoint().clone(),
                repository: "github.com/acme/widget".to_owned(),
                project_path: "/code/widget".to_owned(),
                registration_fingerprint: "registration".to_owned(),
                worktree_path: "/work/widget/topic".to_owned(),
                generation: "0123456789abcdef0123456789abcdef".to_owned(),
                session_name: "widget-topic".to_owned(),
                socket_name: None,
                live_target: Some(Arc::new(host::LiveSessionTarget::test_fixture(
                    &snapshot,
                    "widget-topic",
                    identity.clone(),
                ))),
            });

        let pending = take_pending_kwt_removal(
            &workspace.inner,
            authority,
            "Ubuntu",
            "github.com/acme/widget",
            "/code/widget",
            "registration",
            "/work/widget/topic",
            "0123456789abcdef0123456789abcdef",
            "widget-topic",
        )
        .expect("exact confirmation authority");

        assert_eq!(
            pending
                .live_target
                .as_ref()
                .expect("live authority")
                .identity(),
            &identity
        );
        assert!(
            workspace
                .inner
                .pending_kwt_removal
                .lock()
                .expect("pending removal")
                .is_none()
        );

        restore_pending_kwt_removal(&workspace.inner, pending);
        assert_eq!(
            workspace
                .inner
                .pending_kwt_removal
                .lock()
                .expect("restored pending removal")
                .as_ref()
                .map(|pending| pending.authority),
            Some(authority)
        );
    }

    #[test]
    fn worktree_removal_reservation_requires_the_exact_non_main_inventory_row() {
        let project = ProjectItem::new(
            "github.com/acme/widget",
            "widget",
            "/code/widget",
            "registration",
            vec![
                WorktreeItem::new(
                    "/code/widget",
                    "main",
                    true,
                    Some("11111111111111111111111111111111".to_owned()),
                    "widget-main",
                    None,
                    false,
                ),
                WorktreeItem::new(
                    "/work/widget/topic",
                    "topic",
                    false,
                    Some("22222222222222222222222222222222".to_owned()),
                    "widget-topic",
                    None,
                    true,
                ),
                WorktreeItem::new(
                    "/work/widget/protected",
                    "protected",
                    false,
                    Some("33333333333333333333333333333333".to_owned()),
                    "widget-protected",
                    Some("protected-socket".to_owned()),
                    false,
                ),
            ],
        );
        let remove = |path: &str, generation: &str, session: &str, socket_name: Option<&str>| {
            KwtWorktreeOperation::Remove {
                worktree_path: path.to_owned(),
                generation: generation.to_owned(),
                session_name: session.to_owned(),
                socket_name: socket_name.map(str::to_owned),
                live_target: None,
                operation_id: 1,
            }
        };

        assert!(
            validate_kwt_worktree_operation(
                &project,
                &remove(
                    "/work/widget/topic",
                    "22222222222222222222222222222222",
                    "widget-topic",
                    None,
                ),
            )
            .is_ok()
        );
        assert!(
            validate_kwt_worktree_operation(
                &project,
                &remove(
                    "/code/widget",
                    "11111111111111111111111111111111",
                    "widget-main",
                    None,
                ),
            )
            .is_err()
        );
        assert!(
            validate_kwt_worktree_operation(
                &project,
                &remove(
                    "/work/widget/topic",
                    "22222222222222222222222222222222",
                    "replacement",
                    None,
                ),
            )
            .is_err()
        );
        assert!(
            validate_kwt_worktree_operation(
                &project,
                &remove(
                    "/work/widget/protected",
                    "33333333333333333333333333333333",
                    "widget-protected",
                    Some("protected-socket"),
                ),
            )
            .is_ok(),
            "custom-socket worktrees are removable only through their exact protected socket"
        );
    }

    #[test]
    fn killed_tmux_cleanup_matches_worktree_presentations_by_authoritative_name() {
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let target = AttachTarget::Worktree {
            repository: "project-id".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            path: "/work/project/topic".to_owned(),
            generation: Some("generation".to_owned()),
            session_name: "project-topic".to_owned(),
        };

        assert!(attach_target_matches_killed_tmux(
            &target,
            &identity,
            Some("project-topic"),
            None,
        ));
        assert!(!attach_target_matches_killed_tmux(
            &target,
            &identity,
            Some("replacement"),
            None,
        ));
        assert!(!attach_target_matches_killed_tmux(
            &target, &identity, None, None
        ));
    }

    #[cfg(windows)]
    #[test]
    fn worktree_navigation_reuses_the_equivalent_discovered_tmux_identity() {
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "project-topic",
                identity.clone(),
                1,
            )],
        );
        let direct = attach_request_fixture(&snapshot, identity, "project-topic");
        let mut worktree = direct.clone();
        worktree.target = AttachTarget::Worktree {
            repository: "project-id".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            path: "/work/project/topic".to_owned(),
            generation: Some("generation".to_owned()),
            session_name: "project-topic".to_owned(),
        };

        let key = worktree_tmux_presentation_key(&worktree, &snapshot)
            .expect("the current tmux session supplies a stable presentation key");
        assert_eq!(key, direct.presentation_key());
    }

    #[cfg(windows)]
    #[test]
    fn launched_worktree_identity_remains_reusable_after_it_becomes_unbound() {
        let identity = session::SessionIdentity::new(100, "$1", 200);
        let snapshot = HostSnapshot::test_fixture(
            "Ubuntu",
            "boot-id",
            42,
            vec![session::DiscoveredSession::new(
                "project-topic",
                identity.clone(),
                1,
            )],
        );
        let direct = attach_request_fixture(&snapshot, identity, "project-topic");
        let mut worktree = direct.clone();
        worktree.target = AttachTarget::Worktree {
            repository: "project-id".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            path: "/work/project/topic".to_owned(),
            generation: Some("generation".to_owned()),
            session_name: "project-topic".to_owned(),
        };
        let worktree_key = worktree.presentation_key();

        let mut active = AttachmentState::new();
        active.reserve_with_fallback(
            worktree,
            AttachTerm::Xterm256Color,
            Some(FallbackAuthority {
                presentation: direct.presentation_key(),
                target: worktree_key,
                navigation_generation: 0,
            }),
        );
        assert!(normalize_attached_worktree_target(
            active.active_mut().expect("active worktree"),
            &snapshot,
            "project-topic",
        ));
        assert_eq!(
            active
                .active()
                .expect("normalized active presentation")
                .request
                .presentation_key(),
            direct.presentation_key(),
        );
        assert_eq!(
            active
                .active()
                .expect("normalized fallback")
                .fallback
                .as_ref()
                .expect("fallback authority")
                .target,
            direct.presentation_key(),
        );

        let active = active.take_active().expect("retain active presentation");
        let key = active.request.presentation_key();
        let mut retained = RetainedPresentations::new();
        retained.insert(RetainedPresentation {
            key: key.clone(),
            selection: active.request.selection(),
            attachment: active,
            worker: (),
            presentation_id: 1,
        });
        assert!(retained.contains(&direct.presentation_key()));
    }

    #[test]
    fn successful_worktree_removal_tombstones_only_the_exact_cached_generation() {
        let mut host = HostItem::wsl("Ubuntu", None, HostConnectionState::Ready, Vec::new(), None);
        host.projects = vec![ProjectItem::new(
            "project-id",
            "project",
            "/repos/project",
            "project-fingerprint",
            vec![
                WorktreeItem::new(
                    "/work/project/topic",
                    "topic",
                    false,
                    Some("old-generation".to_owned()),
                    "project-topic",
                    None,
                    false,
                ),
                WorktreeItem::new(
                    "/work/project/topic",
                    "topic",
                    false,
                    Some("replacement-generation".to_owned()),
                    "project-topic",
                    None,
                    false,
                ),
            ],
        )];

        assert!(remove_cached_kwt_worktree(
            &mut host,
            "project-id",
            "/repos/project",
            "project-fingerprint",
            "/work/project/topic",
            "old-generation",
        ));
        assert_eq!(host.projects[0].worktrees.len(), 1);
        assert_eq!(
            host.projects[0].worktrees[0].generation(),
            Some("replacement-generation"),
        );
    }

    #[test]
    fn cancelled_removal_capture_cannot_publish_a_late_failure() {
        let workspace = Workspace::preview(WorkspaceSnapshot::ready(
            Appearance::default(),
            "Ubuntu",
            Vec::new(),
        ));
        workspace
            .inner
            .kwt_removal_generation
            .store(2, Ordering::Release);

        publish_kwt_removal_capture_failure(
            &workspace.inner,
            1,
            "/code/widget",
            "/work/widget/topic",
            "stale failure".to_owned(),
        );
        assert!(workspace.drain_events().0.is_empty());

        publish_kwt_removal_capture_failure(
            &workspace.inner,
            2,
            "/code/widget",
            "/work/widget/topic",
            "current failure".to_owned(),
        );
        let (events, _) = workspace.drain_events();
        assert!(matches!(
            events.as_slice(),
            [WorkspaceEvent::KwtWorktreeOperationFailed {
                operation_id: 2,
                project_path,
                worktree_path: Some(worktree_path),
                message,
            }] if project_path == "/code/widget"
                && worktree_path == "/work/widget/topic"
                && message == "current failure"
        ));
    }

    #[cfg(windows)]
    #[test]
    fn kwt_attachment_failures_preserve_the_fresh_host_snapshot() {
        let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
        let AttachFreshError::SessionChanged {
            error,
            snapshot: preserved,
        } = kwt_attachment_failure(&snapshot, "KWT inventory failed")
        else {
            panic!("KWT failures must remain scoped below host transport");
        };

        assert_eq!(error.to_string(), "KWT inventory failed");
        assert_eq!(preserved.endpoint(), snapshot.endpoint());
        assert_eq!(preserved.runtime(), snapshot.runtime());
    }

    #[test]
    fn worktree_startup_rejects_an_early_guard_failure_before_inventory() {
        let cancellation = CancellationToken::new();
        let mut observations = VecDeque::from([
            TerminalStartup::Pending,
            TerminalStartup::Exited {
                code: 1,
                output_tail: r#"{"error":{"code":"registration_changed","message":"the worktree changed","retryable":true}}"#.to_owned(),
            },
        ]);

        let error = wait_for_worktree_client_startup(
            AttachTerm::Xterm256Color,
            &cancellation,
            &[Duration::ZERO, Duration::ZERO],
            || {
                Ok(observations
                    .pop_front()
                    .expect("one observation per startup attempt"))
            },
            || Ok(None),
        )
        .expect_err("guard rejection must prevent session publication");

        let WorktreeClientStartupError::Failed(error) = error else {
            panic!("a KWT guard rejection is not a terminfo fallback");
        };
        assert!(error.to_string().contains("registration_changed"));
        assert!(observations.is_empty());
    }

    #[test]
    fn worktree_startup_never_accepts_inventory_without_client_confirmation() {
        let cancellation = CancellationToken::new();
        let mut observations = 0;

        let error = wait_for_worktree_client_startup(
            AttachTerm::Xterm256Color,
            &cancellation,
            &[Duration::ZERO; 3],
            || {
                observations += 1;
                Ok(TerminalStartup::Pending)
            },
            || Ok(None),
        )
        .expect_err("a same-named session cannot prove client attachment");

        assert_eq!(observations, 4);
        let WorktreeClientStartupError::Failed(error) = error else {
            panic!("a pending client is not a terminfo fallback");
        };
        assert!(error.to_string().contains("did not establish"));
    }

    #[test]
    fn worktree_startup_retries_only_the_exact_initial_terminfo_failure() {
        let cancellation = CancellationToken::new();
        let error = wait_for_worktree_client_startup(
            AttachTerm::Xterm256Color,
            &cancellation,
            &[],
            || {
                Ok(TerminalStartup::Exited {
                    code: 1,
                    output_tail:
                        "open terminal failed: missing or unsuitable terminal: xterm-256color\r\n"
                            .to_owned(),
                })
            },
            || Ok(None),
        )
        .expect_err("missing xterm-256color requests the conservative retry");

        assert!(matches!(error, WorktreeClientStartupError::RetryWithXterm));
    }

    #[test]
    fn worktree_startup_uses_stable_tmux_client_identity_without_alt_screen() {
        let cancellation = CancellationToken::new();
        let identity = session::SessionIdentity::new(42, "$7", 99);
        let mut readiness = VecDeque::from([Some(identity.clone()), Some(identity.clone())]);

        let observed = wait_for_worktree_client_startup(
            AttachTerm::Xterm256Color,
            &cancellation,
            &[Duration::ZERO, Duration::ZERO],
            || Ok(TerminalStartup::Pending),
            || {
                Ok(readiness
                    .pop_front()
                    .expect("one readiness result per probe"))
            },
        )
        .expect("stable exact tmux client identity proves attachment");

        assert_eq!(observed, identity);
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

    fn kwt_worktree_workspace_fixture() -> (Workspace, Arc<ManualRefreshRuntime>) {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let bundle =
            host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid KWT bundle");
        let config = WslConfig::with_distro("Ubuntu")
            .expect("valid config")
            .with_kwt_bundle(bundle);
        let executable = WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute WSL path");
        let workspace = Workspace::application_with_services(
            TerminalAppearance::default(),
            Some(WslHostSpec::available(config.clone(), executable.clone())),
            Arc::new(SystemWslDiscovery::new()),
            runtime.clone(),
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
        set_inventory_state(&workspace.inner, ready_content(&snapshot));
        workspace
            .inner
            .kwt_refresh_generation
            .store(7, Ordering::Release);
        let inventory = KwtInventory::parse(
            br#"[{"repository":"project-id","name":"project","path":"/repos/project","last_touched":null,"registration_fingerprint":"project-fingerprint"}]"#,
            br#"[{"path":"/repos/project","branch":"main","commit_hash":"abc","is_main":true,"created_at":null,"generation":"0123456789abcdef0123456789abcdef","repository":"project-id","session_name":"project-main","tmux_socket_name":null}]"#,
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
        (workspace, runtime)
    }

    #[test]
    fn cancelling_a_kwt_listing_releases_the_lane_for_its_replacement() {
        let (workspace, runtime) = kwt_worktree_workspace_fixture();
        let first = workspace
            .load_kwt_pull_requests(
                "wsl",
                "Ubuntu",
                "project-id",
                "/repos/project",
                "project-fingerprint",
            )
            .expect("start pull-request listing");

        assert!(workspace.cancel_kwt_worktree_listing(first));
        let second = workspace
            .import_kwt_pull_request(
                "wsl",
                "Ubuntu",
                "project-id",
                "/repos/project",
                "project-fingerprint",
                "17",
            )
            .expect("replacement import starts immediately");

        assert_ne!(
            first, second,
            "listing and navigation operations share one unique ID sequence"
        );
        assert_eq!(runtime.work.lock().expect("work queue").len(), 2);
        runtime.run_next_work();
        assert!(
            workspace.drain_events().0.is_empty(),
            "a cancelled listing cannot publish into a newer operation"
        );
        assert!(
            workspace
                .inner
                .kwt_mutation_in_flight
                .load(Ordering::Acquire),
            "the cancelled task cannot settle over its replacement"
        );
    }

    #[test]
    fn pull_request_import_timeout_requests_reconciliation_and_reports_uncertainty() {
        let (outcome, message) = kwt_pull_request_import_failure(
            DiagnosticKind::Timeout,
            "import KWT pull request: inventory_timeout",
        );

        assert!(outcome.refresh_kwt);
        assert!(!outcome.refresh_tmux);
        assert!(message.contains("may have completed"));
        assert!(message.contains("refresh"));
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
            theme: TerminalTheme::Custom,
            font_family: "monospace".to_owned(),
            font_size: 14,
            background: 0x12_34_56,
            foreground: 0x65_43_21,
            cursor_style: CursorStyle::Block,
            allow_shell_integration_cursor: false,
            hide_mouse_while_typing: true,
        };

        let colors = default_colors(&appearance);

        assert_eq!(colors.background(), Rgb::new(0x12, 0x34, 0x56));
        assert_eq!(colors.foreground(), Rgb::new(0x65, 0x43, 0x21));
    }

    fn relative_luminance(color: Rgb) -> f64 {
        let linear = |component: u8| {
            let value = f64::from(component) / 255.0;
            if value <= 0.040_45 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    fn contrast_ratio(first: Rgb, second: Rgb) -> f64 {
        let first = relative_luminance(first);
        let second = relative_luminance(second);
        let (lighter, darker) = if first >= second {
            (first, second)
        } else {
            (second, first)
        };
        (lighter + 0.05) / (darker + 0.05)
    }

    #[test]
    fn light_themes_render_every_ansi_color_with_readable_contrast() {
        for theme in [TerminalTheme::ClearLight, TerminalTheme::Novel] {
            let (background, foreground) = theme.colors().expect("built-in theme colors");
            let appearance = Appearance {
                theme,
                font_family: "monospace".to_owned(),
                font_size: 14,
                background,
                foreground,
                cursor_style: CursorStyle::Block,
                allow_shell_integration_cursor: false,
                hide_mouse_while_typing: true,
            };
            let colors = default_colors(&appearance);
            let mut engine = TerminalEngine::with_default_colors(
                GridSize::new(16, 1).expect("valid grid"),
                colors,
            );
            let mut output = Vec::new();
            for index in 0_u8..16 {
                let code = if index < 8 { 30 + index } else { 82 + index };
                output.extend_from_slice(format!("\x1b[{code}mX").as_bytes());
            }

            let _events = engine.process(&output);
            let frame = engine.surface().load();
            for column in 0..16 {
                let ratio = contrast_ratio(frame.row(0)[column].foreground, colors.background());
                assert!(
                    ratio >= 4.5,
                    "{theme:?} ANSI color {column} has only {ratio:.2}:1 contrast"
                );
            }
        }
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
    fn remote_identity_mismatch_tolerates_preceding_login_shell_noise() {
        let marker = "GHOSTHUB_REMOTE_IDENTITY_MISMATCH_deadbeef";
        let output =
            format!("Welcome to the remote host\r\n{marker}\r\nlogout\r\nConnection closed.\r\n");

        let diagnostic = classify_remote_terminal_exit(0, &output, Some(marker))
            .expect("the attachment-specific marker is authoritative");

        assert!(diagnostic.contains("session identity changed"));
    }

    #[test]
    fn remote_output_that_only_mentions_the_marker_is_not_authoritative() {
        let marker = "GHOSTHUB_REMOTE_IDENTITY_MISMATCH_deadbeef";
        let output = format!("shell output: {marker}\r\nordinary logout\r\n");

        assert_eq!(
            classify_remote_terminal_exit(0, &output, Some(marker)),
            None
        );
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
            active_selection: None,
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
    fn stale_remote_exit_generation_cannot_invalidate_a_replacement_worker() {
        let mut worker = WorkerState::new();
        let exited_generation = worker.publish("remote client");
        let replacement_generation = worker.publish("local replacement");

        assert_eq!(worker.invalidate_if_generation(exited_generation), None);
        assert_eq!(worker.active(), Some(&"local replacement"));
        assert_eq!(worker.generation(), replacement_generation);
    }

    #[test]
    fn remote_presentation_identity_survives_only_a_same_route_lease_renewal() {
        let identity = session::SessionIdentity::new(42, "$1", 100);
        let mut key = RemotePresentationKey {
            host_id: "ssh:studio".to_owned(),
            endpoint: "studio.example".to_owned(),
            route_identity: "route-a".to_owned(),
            lease_generation: 7,
            session_identity: RemoteSessionIdentity::Tmux(identity.clone()),
        };
        let sessions = vec![session::DiscoveredSession::new("renamed", identity, 1)];

        assert_eq!(
            key.reconcile(
                "studio.example",
                "route-a",
                8,
                Some(RemoteInventory {
                    tmux: Some(&sessions),
                    herdr: Some(&[]),
                    zellij: Some(&[]),
                }),
            ),
            RemoteReconcile::Found(SessionKind::Tmux, "renamed".to_owned())
        );
        assert_eq!(key.lease_generation, 8);
        assert_eq!(
            key.reconcile(
                "studio.example",
                "route-a",
                9,
                Some(RemoteInventory {
                    tmux: None,
                    herdr: Some(&[]),
                    zellij: Some(&[]),
                }),
            ),
            RemoteReconcile::Unknown
        );
        assert_eq!(key.lease_generation, 9);
        assert_eq!(
            key.reconcile(
                "studio.example",
                "route-b",
                10,
                Some(RemoteInventory {
                    tmux: Some(&sessions),
                    herdr: Some(&[]),
                    zellij: Some(&[]),
                }),
            ),
            RemoteReconcile::Stale
        );
        assert_eq!(key.lease_generation, 9);
    }

    #[test]
    fn failed_remote_backend_inventory_preserves_known_presentation_identity() {
        let mut key = RemotePresentationKey {
            host_id: "ssh:studio".to_owned(),
            endpoint: "studio.example".to_owned(),
            route_identity: "route-a".to_owned(),
            lease_generation: 7,
            session_identity: RemoteSessionIdentity::Herdr {
                name: "review".to_owned(),
                is_default: false,
                session_directory: "/tmp/herdr/review".to_owned(),
                socket_path: "/tmp/herdr/review.sock".to_owned(),
            },
        };

        assert_eq!(
            key.reconcile(
                "studio.example",
                "route-a",
                8,
                Some(RemoteInventory {
                    tmux: Some(&[]),
                    herdr: None,
                    zellij: Some(&[]),
                }),
            ),
            RemoteReconcile::Unknown
        );
        assert_eq!(key.lease_generation, 8);
        assert_eq!(
            key.reconcile(
                "studio.example",
                "route-a",
                9,
                Some(RemoteInventory {
                    tmux: Some(&[]),
                    herdr: Some(&[]),
                    zellij: Some(&[]),
                }),
            ),
            RemoteReconcile::Stale
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
    fn remote_navigation_cancels_and_settles_pending_local_creation() {
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

        workspace.begin_navigation();
        workspace
            .settle_local_navigation_before_remote()
            .expect("remote navigation settles local creation");

        assert!(cancellation.is_cancelled());
        assert!(
            workspace
                .inner
                .pending_creation
                .lock()
                .expect("pending creation")
                .is_none()
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "selected")
        ));
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
            "killed",
            None,
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
    fn wsl_capture_rejects_remote_host_ids_even_when_inventory_identity_collides() {
        let (workspace, _runtime) = herdr_workspace_fixture();
        let remote_host = "ssh:collision";
        *workspace
            .inner
            .selected_host
            .write()
            .expect("selected host") = Some(remote_host.to_owned());

        assert!(
            capture_kill_request(
                &workspace.inner,
                &SessionSelection::new(remote_host, "Ubuntu", "work"),
                1,
            )
            .is_err()
        );
        assert!(
            capture_herdr_lifecycle(
                &workspace.inner,
                &SessionSelection::herdr(remote_host, "Ubuntu", "default"),
                HerdrLifecycleAction::Stop,
                1,
            )
            .is_err()
        );
        assert!(
            capture_create_request(
                &workspace.inner,
                remote_host,
                "Ubuntu",
                SessionName::parse("created").expect("valid tmux name"),
            )
            .is_err()
        );
        assert!(
            capture_herdr_create_request(
                &workspace.inner,
                remote_host,
                "Ubuntu",
                HerdrSessionName::parse("created").expect("valid Herdr name"),
            )
            .is_err()
        );
        assert!(
            capture_zellij_create_request(
                &workspace.inner,
                remote_host,
                "Ubuntu",
                ZellijSessionName::parse("created").expect("valid Zellij name"),
            )
            .is_err()
        );
        assert!(
            capture_herdr_restart_request(
                &workspace.inner,
                &SessionSelection::herdr(remote_host, "Ubuntu", "review"),
            )
            .is_err()
        );
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
    fn launched_remote_session_polling_outlives_navigation_intent() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let cancellation = CancellationToken::new();
        let launch_navigation = workspace.begin_navigation();
        let mut probes = 0;

        let result = poll_session_startup(
            "remote multiplexer",
            &cancellation,
            &[Duration::ZERO],
            || -> Result<Option<&'static str>, WorkspaceError> {
                probes += 1;
                if probes == 1 {
                    workspace.begin_navigation();
                    assert!(!workspace.navigation_intent_is_current(launch_navigation));
                    Ok(None)
                } else {
                    Ok(Some("published"))
                }
            },
        )
        .expect("connection-scoped polling survives navigation");

        assert_eq!(result, Some("published"));
        assert_eq!(probes, 2);
        assert!(!cancellation.is_cancelled());
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
    #[allow(
        clippy::too_many_lines,
        reason = "one fixture verifies ordinary and protected KWT identity from the same inventory"
    )]
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
            br#"[{"path":"/work/project/topic","branch":"topic","commit_hash":"abc","is_main":false,"created_at":null,"generation":"g7","repository":"project-id","session_name":"project-topic","tmux_socket_name":null},{"path":"/work/project/pr-17","branch":"pr-17","commit_hash":"def","is_main":false,"created_at":null,"generation":"g8","repository":"project-id","session_name":"project-pr-17","tmux_socket_name":"kwt-pr-a1b2"}]"#,
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
            None,
        )
        .expect("KWT identity grants repair-or-open authority");
        assert!(matches!(request.target, AttachTarget::Worktree { .. }));
        assert_eq!(request.name, "project-topic");
        let protected = capture_kwt_worktree_request(
            &workspace.inner,
            "wsl",
            "Ubuntu",
            "project-id",
            "/repos/project",
            "project-fingerprint",
            "/work/project/pr-17",
            Some("g8"),
            "project-pr-17",
            Some("kwt-pr-a1b2"),
        )
        .expect("KWT identity grants protected attach authority");
        assert!(matches!(
            protected.target,
            AttachTarget::ProtectedWorktree { ref tmux_socket_name, .. }
                if tmux_socket_name == "kwt-pr-a1b2"
        ));
        let protected_selection = protected.selection();
        assert_eq!(protected_selection.tmux_socket_name(), Some("kwt-pr-a1b2"));
        assert_ne!(
            protected_selection,
            SessionSelection::new("wsl", "Ubuntu", "project-pr-17"),
            "a same-named default-socket session is a different presentation"
        );
        assert!(
            capture_kwt_worktree_request(
                &workspace.inner,
                "wsl",
                "Ubuntu",
                "project-id",
                "/repos/project",
                "project-fingerprint",
                "/work/project/pr-17",
                Some("g8"),
                "project-pr-17",
                Some("kwt-pr-replaced"),
            )
            .is_err(),
            "a stale protected-socket action cannot open the replacement server"
        );
        assert!(matches!(
            capture_kill_request(&workspace.inner, &protected_selection, 9)
                .expect("protected selection grants a fresh named-socket kill query"),
            KillCaptureRequest::Tmux { selection, .. }
                if selection.tmux_socket_name() == Some("kwt-pr-a1b2")
        ));
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
                None,
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
            active_selection: None,
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

    #[test]
    fn cancelled_remote_connection_cannot_publish_a_late_failure() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Connecting,
                Vec::new(),
                None,
            )],
        ));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "/usr/bin/tmux",
            None,
        )
        .expect("valid remote host");
        let cancellation = CancellationToken::new();
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                "ssh:studio".to_owned(),
                RemoteEntry {
                    config,
                    native_host: None,
                    context: None,
                    cancellation: Some(cancellation.clone()),
                    constructive_cancellation: None,
                    attachment_attempt: None,
                    generation: 7,
                },
            );

        assert!(workspace.cancel_host_connection("ssh:studio"));
        assert!(cancellation.is_cancelled());
        publish_remote_connection(
            &workspace.inner,
            "ssh:studio",
            7,
            Err(host::RemoteTmuxError::transport("late transport failure")),
        );

        let snapshot = workspace.snapshot();
        assert_eq!(
            snapshot.hosts()[0].connection(),
            HostConnectionState::Disconnected
        );
        assert!(snapshot.hosts()[0].diagnostic().is_none());
    }

    #[test]
    fn remote_cancellation_waits_for_inventory_publication() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Connecting,
                Vec::new(),
                None,
            )],
        ));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "/usr/bin/tmux",
            None,
        )
        .expect("valid remote host");
        let cancellation = CancellationToken::new();
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                "ssh:studio".to_owned(),
                RemoteEntry {
                    config,
                    native_host: None,
                    context: None,
                    cancellation: Some(cancellation.clone()),
                    constructive_cancellation: None,
                    attachment_attempt: None,
                    generation: 7,
                },
            );

        let publication = workspace
            .inner
            .remote_publication
            .lock()
            .expect("hold inventory publication");
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (completed_tx, completed_rx) = mpsc::sync_channel(1);
        thread::scope(|scope| {
            let cancellation_task = scope.spawn(|| {
                entered_tx.send(()).expect("announce cancellation");
                completed_tx
                    .send(workspace.cancel_host_connection("ssh:studio"))
                    .expect("report cancellation");
            });
            entered_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("cancellation task started");
            assert_eq!(
                completed_rx.recv_timeout(Duration::from_millis(50)),
                Err(RecvTimeoutError::Timeout),
                "cancellation cannot cross an in-progress inventory publication"
            );

            set_remote_host_state(
                &workspace.inner,
                "ssh:studio",
                HostConnectionState::Ready,
                None,
                None,
            );
            drop(publication);

            assert!(
                completed_rx
                    .recv_timeout(Duration::from_secs(1))
                    .expect("cancellation completes after publication")
            );
            cancellation_task.join().expect("cancellation task");
        });

        assert!(cancellation.is_cancelled());
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Disconnected,
            "the newer cancellation transition wins over the completed publication"
        );
    }

    #[test]
    fn stale_lease_exit_cannot_cancel_its_replacement_connection() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Connecting,
                Vec::new(),
                None,
            )],
        ));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "",
            None,
        )
        .expect("valid remote host");
        let host = remote_host_fixture(&config);
        let stale = RemoteTmuxSnapshot::test_fixture(
            "studio.example",
            TEST_REMOTE_ROUTE,
            7,
            Vec::new(),
            HerdrInventory::Unavailable,
            ZellijInventory::Unavailable,
        );
        let replacement = CancellationToken::new();
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                "ssh:studio".to_owned(),
                RemoteEntry {
                    config,
                    native_host: Some(host.clone()),
                    context: Some(RemoteHostContext {
                        generation: 7,
                        host,
                        snapshot: stale,
                    }),
                    cancellation: Some(replacement.clone()),
                    constructive_cancellation: None,
                    attachment_attempt: None,
                    generation: 8,
                },
            );

        workspace.monitor_remote_lease_liveness();

        let entries = workspace.inner.remote_hosts.lock().expect("remote hosts");
        let entry = entries.get("ssh:studio").expect("remote entry");
        assert_eq!(entry.generation, 8);
        assert!(!replacement.is_cancelled());
        assert!(entry.context.is_some());
        drop(entries);
        assert_eq!(
            workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Connecting
        );
    }

    #[test]
    fn newer_navigation_cancels_a_queued_remote_attachment() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            )],
        ));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "",
            None,
        )
        .expect("valid remote host");
        let cancellation = CancellationToken::new();
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                "ssh:studio".to_owned(),
                RemoteEntry {
                    config,
                    native_host: None,
                    context: None,
                    cancellation: None,
                    constructive_cancellation: None,
                    attachment_attempt: Some(RemoteAttachmentAttempt {
                        navigation_generation: 7,
                        cancellation: cancellation.clone(),
                    }),
                    generation: 1,
                },
            );

        workspace.begin_navigation();

        assert!(cancellation.is_cancelled());
        assert!(
            workspace
                .inner
                .remote_hosts
                .lock()
                .expect("remote hosts")
                .get("ssh:studio")
                .expect("remote entry")
                .attachment_attempt
                .is_none()
        );
    }

    #[test]
    fn superseded_remote_attachment_cannot_cross_the_launch_fence() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            )],
        ));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "",
            None,
        )
        .expect("valid remote host");
        let cancellation = CancellationToken::new();
        workspace
            .inner
            .navigation_generation
            .store(7, Ordering::Release);
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                "ssh:studio".to_owned(),
                RemoteEntry {
                    config,
                    native_host: None,
                    context: None,
                    cancellation: None,
                    constructive_cancellation: None,
                    attachment_attempt: Some(RemoteAttachmentAttempt {
                        navigation_generation: 7,
                        cancellation: cancellation.clone(),
                    }),
                    generation: 1,
                },
            );
        workspace.begin_navigation();
        let launched = AtomicBool::new(false);

        let result = with_current_remote_attachment_launch(
            &workspace.inner,
            "ssh:studio",
            7,
            &cancellation,
            || {
                launched.store(true, Ordering::Release);
                Ok(())
            },
        );

        assert!(result.is_err());
        assert!(!launched.load(Ordering::Acquire));
    }

    #[test]
    fn connecting_remote_host_rejects_fresh_session_actions() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Connecting,
                Vec::new(),
                None,
            )],
        ));
        let selection = SessionSelection::new("ssh:studio", "studio.example", "build");

        let error = require_host_session_actions(&workspace.inner, &selection)
            .expect_err("connecting hosts cannot authorize fresh actions");

        assert!(error.to_string().contains("ready"));
    }

    #[test]
    fn connecting_wsl_host_preserves_cached_session_actions() {
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::wsl(
                "Ubuntu",
                None,
                HostConnectionState::Connecting,
                vec![SessionItem::new("build", 0)],
                None,
            )],
        ));
        let selection = SessionSelection::new("wsl", "Ubuntu", "build");

        require_host_session_actions(&workspace.inner, &selection)
            .expect("WSL cached inventory remains actionable during refresh");
    }

    #[test]
    fn refresh_after_remote_launch_transfers_inventory_reconciliation() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "",
            None,
        )
        .expect("valid remote host");
        let cancellation = CancellationToken::new();
        let target = remote_herdr_target("agents");
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                config.id().to_owned(),
                RemoteEntry {
                    config,
                    native_host: None,
                    context: None,
                    cancellation: None,
                    constructive_cancellation: Some(RemoteConstructiveState::Active {
                        navigation_generation: 6,
                        cancellation: cancellation.clone(),
                        launched: Arc::new(AtomicBool::new(true)),
                        target: target.clone(),
                    }),
                    attachment_attempt: None,
                    generation: 7,
                },
            );

        {
            let mut entries = workspace.inner.remote_hosts.lock().expect("remote hosts");
            cancel_remote_constructive(entries.get_mut("ssh:studio").expect("remote entry"));
        }

        assert!(cancellation.is_cancelled());
        assert!(!remote_constructive_is_current(
            &workspace.inner,
            "ssh:studio",
            &cancellation
        ));
        let pending = pending_remote_constructive_target(&workspace.inner, "ssh:studio");
        assert_eq!(pending, Some(target.clone()));
        drop(RemoteConstructiveReset {
            inner: &workspace.inner,
            host_id: "ssh:studio",
            navigation_generation: 6,
        });
        assert_eq!(
            pending_remote_constructive_target(&workspace.inner, "ssh:studio"),
            Some(target)
        );
    }

    #[test]
    fn navigation_cancels_only_prelaunch_remote_construction() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "",
            None,
        )
        .expect("valid remote host");
        let cancellation = CancellationToken::new();
        let launched = Arc::new(AtomicBool::new(false));
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                config.id().to_owned(),
                RemoteEntry {
                    config,
                    native_host: None,
                    context: None,
                    cancellation: None,
                    constructive_cancellation: Some(RemoteConstructiveState::Active {
                        navigation_generation: 7,
                        cancellation: cancellation.clone(),
                        launched: Arc::clone(&launched),
                        target: remote_zellij_target("review"),
                    }),
                    attachment_attempt: None,
                    generation: 1,
                },
            );

        cancel_superseded_remote_constructive_navigation(&workspace.inner, 8);
        assert!(cancellation.is_cancelled());

        let post_launch_cancellation = CancellationToken::new();
        launched.store(true, Ordering::Release);
        if let Some(entry) = workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .get_mut("ssh:studio")
        {
            entry.constructive_cancellation = Some(RemoteConstructiveState::Active {
                navigation_generation: 7,
                cancellation: post_launch_cancellation.clone(),
                launched,
                target: remote_zellij_target("review"),
            });
        }

        cancel_superseded_remote_constructive_navigation(&workspace.inner, 8);
        assert!(
            !post_launch_cancellation.is_cancelled(),
            "post-launch polling must survive navigation"
        );
    }

    #[test]
    fn cancelled_remote_construction_stops_waiting_for_the_operation_lane() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let occupied = workspace
            .inner
            .session_operations
            .lock()
            .expect("occupy session operation lane");
        let cancellation = CancellationToken::new();

        thread::scope(|scope| {
            let (settled_tx, settled_rx) = mpsc::sync_channel(1);
            let inner = &workspace.inner;
            let waiter_cancellation = cancellation.clone();
            scope.spawn(move || {
                let operation = lock_session_operations(inner, &waiter_cancellation);
                settled_tx
                    .send(operation.is_none())
                    .expect("report cancelled wait");
            });
            cancellation.cancel();
            assert!(
                settled_rx
                    .recv_timeout(Duration::from_secs(1))
                    .expect("cancelled waiter settles promptly")
            );
        });
        drop(occupied);
    }

    #[test]
    fn concurrent_remote_inventory_publication_settles_pending_reconciliation() {
        let workspace =
            Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "/usr/bin/tmux",
            None,
        )
        .expect("valid remote host");
        let host = remote_host_fixture(&config);
        let initial = RemoteTmuxSnapshot::test_fixture(
            "studio.example",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            7,
            Vec::new(),
            HerdrInventory::Unavailable,
            ZellijInventory::Unavailable,
        );
        let target = remote_herdr_target("agents");
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                config.id().to_owned(),
                RemoteEntry {
                    config,
                    native_host: Some(host.clone()),
                    context: Some(RemoteHostContext {
                        generation: 7,
                        host: host.clone(),
                        snapshot: initial.clone(),
                    }),
                    cancellation: None,
                    constructive_cancellation: Some(
                        RemoteConstructiveState::PendingReconciliation(target.clone()),
                    ),
                    attachment_attempt: None,
                    generation: 7,
                },
            );

        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        thread::scope(|scope| {
            let inner = &workspace.inner;
            let reconciliation_initial = initial.clone();
            let reconciliation_target = target.clone();
            let reconciliation = scope.spawn(move || {
                reconcile_remote_constructive_with_backoff(
                    inner,
                    "ssh:studio",
                    7,
                    reconciliation_initial,
                    &reconciliation_target,
                    &[Duration::ZERO, Duration::ZERO],
                    |_snapshot, _cancellation| {
                        entered_tx.send(()).expect("announce stale probe");
                        release_rx.recv().expect("release stale probe");
                        Err::<RemoteSessionInventory, ()>(())
                    },
                );
            });
            entered_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("reconciliation entered remote discovery");
            publish_remote_inventory(
                &workspace.inner,
                "ssh:studio",
                7,
                &initial,
                &CancellationToken::new(),
                RemoteSessionInventory::test_fixture(
                    Some("/usr/bin/tmux".to_owned()),
                    Vec::new(),
                    HerdrInventory::Available {
                        executable: "/usr/bin/herdr".to_owned(),
                        sessions: vec![session::HerdrSessionRecord::new(
                            "agents",
                            false,
                            HerdrSessionState::Running,
                            "/tmp/herdr/agents",
                            "/tmp/herdr/agents/herdr.sock",
                        )],
                    },
                    ZellijInventory::Unavailable,
                ),
            )
            .expect("concurrent inventory publication wins");
            release_tx
                .send(())
                .expect("release stale reconciliation probe");
            reconciliation.join().expect("reconciliation completes");
        });

        assert_eq!(
            pending_remote_constructive_target(&workspace.inner, "ssh:studio"),
            None,
            "the authoritative concurrent snapshot settles the pending launch"
        );
    }

    #[test]
    fn stale_remote_inventory_cannot_overwrite_the_published_generation() {
        let config = RemoteTmuxConfig::new(
            "ssh:studio",
            "Studio",
            SshTarget::new("studio.example", None, None).expect("valid target"),
            "/usr/bin/tmux",
            None,
        )
        .expect("valid remote host");
        let host = remote_host_fixture(&config);
        let identity = session::SessionIdentity::new(42, "$1", 100);
        let initial = RemoteTmuxSnapshot::test_fixture(
            "studio.example",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            7,
            vec![session::DiscoveredSession::new(
                "initial",
                identity.clone(),
                0,
            )],
            HerdrInventory::Unavailable,
            ZellijInventory::Unavailable,
        );
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Ready,
                vec![SessionItem::new("initial", 0)],
                None,
            )],
        ));
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                config.id().to_owned(),
                RemoteEntry {
                    config,
                    native_host: Some(host.clone()),
                    context: Some(RemoteHostContext {
                        generation: 7,
                        host,
                        snapshot: initial.clone(),
                    }),
                    cancellation: None,
                    constructive_cancellation: None,
                    attachment_attempt: None,
                    generation: 7,
                },
            );
        let cancellation = CancellationToken::new();
        let winner = publish_remote_inventory(
            &workspace.inner,
            "ssh:studio",
            7,
            &initial,
            &cancellation,
            RemoteSessionInventory::test_fixture(
                Some("/usr/bin/tmux".to_owned()),
                vec![session::DiscoveredSession::new(
                    "winner",
                    identity.clone(),
                    0,
                )],
                HerdrInventory::Unavailable,
                ZellijInventory::Unavailable,
            ),
        )
        .expect("first publication wins");

        let stale = publish_remote_inventory(
            &workspace.inner,
            "ssh:studio",
            7,
            &initial,
            &cancellation,
            RemoteSessionInventory::test_fixture(
                Some("/usr/bin/tmux".to_owned()),
                vec![session::DiscoveredSession::new("stale", identity, 0)],
                HerdrInventory::Unavailable,
                ZellijInventory::Unavailable,
            ),
        );

        assert!(stale.is_err());
        assert_eq!(winner.inventory_generation(), 1);
        assert_eq!(
            workspace.snapshot().hosts()[0].sessions()[0].name(),
            "winner"
        );
    }

    #[test]
    fn display_only_ssh_host_edits_preserve_runtime_and_selection() {
        let config = RemoteTmuxConfig::new(
            "ssh:deploy@studio.example:22",
            "Studio",
            SshTarget::new("studio.example", Some("deploy".to_owned()), Some(22))
                .expect("valid target"),
            "",
            None,
        )
        .expect("valid remote host");
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                config.id(),
                config.name(),
                config.endpoint(),
                HostConnectionState::Ready,
                vec![SessionItem::new("work", 0)],
                None,
            )],
        ));
        let cancellation = CancellationToken::new();
        let constructive_cancellation = CancellationToken::new();
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                config.id().to_owned(),
                RemoteEntry {
                    config: config.clone(),
                    native_host: None,
                    context: None,
                    cancellation: Some(cancellation.clone()),
                    constructive_cancellation: Some(RemoteConstructiveState::Active {
                        navigation_generation: 6,
                        cancellation: constructive_cancellation.clone(),
                        launched: Arc::new(AtomicBool::new(false)),
                        target: remote_zellij_target("review"),
                    }),
                    attachment_attempt: None,
                    generation: 7,
                },
            );
        let edited = SshHostSettings::new(
            "Build Mac",
            "studio.example",
            Some("deploy".to_owned()),
            Some(22),
            "",
            None,
        )
        .expect("valid settings");

        workspace
            .publish_saved_ssh_host(Some(config.id()), &edited)
            .expect("publish display edit");

        {
            let entries = workspace.inner.remote_hosts.lock().expect("remote hosts");
            let entry = entries.get(config.id()).expect("preserved runtime");
            assert_eq!(entry.generation, 7);
        }
        assert!(!cancellation.is_cancelled());
        assert!(!constructive_cancellation.is_cancelled());
        let snapshot = workspace.snapshot();
        assert_eq!(snapshot.selected_host(), Some(config.id()));
        assert_eq!(snapshot.hosts()[0].name(), "Build Mac");
        assert_eq!(snapshot.hosts()[0].connection(), HostConnectionState::Ready);
        assert_eq!(snapshot.hosts()[0].sessions()[0].name(), "work");
    }

    #[test]
    fn connection_changing_ssh_host_edits_disconnect_and_move_selection() {
        let config = RemoteTmuxConfig::new(
            "ssh:deploy@old.example:22",
            "Studio",
            SshTarget::new("old.example", Some("deploy".to_owned()), Some(22))
                .expect("valid target"),
            "/usr/bin/tmux",
            None,
        )
        .expect("valid remote host");
        let workspace = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![HostItem::ssh(
                config.id(),
                config.name(),
                config.endpoint(),
                HostConnectionState::Connecting,
                Vec::new(),
                None,
            )],
        ));
        let cancellation = CancellationToken::new();
        let constructive_cancellation = CancellationToken::new();
        workspace
            .inner
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .insert(
                config.id().to_owned(),
                RemoteEntry {
                    config: config.clone(),
                    native_host: None,
                    context: None,
                    cancellation: Some(cancellation.clone()),
                    constructive_cancellation: Some(RemoteConstructiveState::Active {
                        navigation_generation: 6,
                        cancellation: constructive_cancellation.clone(),
                        launched: Arc::new(AtomicBool::new(false)),
                        target: remote_zellij_target("review"),
                    }),
                    attachment_attempt: None,
                    generation: 7,
                },
            );
        let edited = SshHostSettings::new(
            "Studio",
            "new.example",
            Some("deploy".to_owned()),
            Some(22),
            "/usr/bin/tmux",
            None,
        )
        .expect("valid settings");
        let edited_id = edited.id();

        workspace
            .publish_saved_ssh_host(Some(config.id()), &edited)
            .expect("publish connection edit");

        assert!(cancellation.is_cancelled());
        assert!(constructive_cancellation.is_cancelled());
        let snapshot = workspace.snapshot();
        assert_eq!(snapshot.selected_host(), Some(edited_id.as_str()));
        assert_eq!(snapshot.hosts().len(), 1);
        assert_eq!(snapshot.hosts()[0].id(), edited_id);
        assert_eq!(
            snapshot.hosts()[0].connection(),
            HostConnectionState::Unavailable
        );
    }
}
