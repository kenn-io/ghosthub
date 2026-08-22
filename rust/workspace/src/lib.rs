//! Application workflow and capability boundary for GPUI.

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, RwLock, TryLockError, Weak};
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
use surface::{CursorShape, GridSize, PixelSize, Rgb, SurfaceStore};
use terminal::{
    ClipboardPolicy, ClipboardReadRequest as TerminalClipboardRead, ClipboardTarget, DefaultColors,
    TerminalEvent, TerminalStartup, TerminalWorker, WorkerError,
};

mod pump;
mod runtime;
mod scene;

use pump::start_event_pump;
use runtime::{
    Runtime, SceneId, begin_snapshot_write, cadence_fallback_scene, cancel_refresh,
    cancel_scene_remote_attachments, cancel_superseded_remote_constructive_navigation,
    capture_kwt_worktree_removal_context, capture_remote_herdr_attach_request,
    capture_remote_herdr_create_request, capture_remote_herdr_restart_request,
    capture_remote_tmux_attach_request, capture_remote_zellij_attach_request,
    capture_remote_zellij_create_request, clear_pending_remote_constructive,
    clear_remote_attachment_registration, clear_remote_constructive_registration,
    current_inventory_session_name, equivalent_tmux_presentation_key, finish_herdr_launch,
    finish_herdr_lifecycle_state, finish_pending_creation, for_each_scene,
    herdr_operation_pending_for_selection, invalidate_kwt_inventory, live_scenes,
    next_operation_id, next_presentation_id, next_scene_id, pending_remote_constructive_snapshot,
    publish_herdr_lifecycle_uncertain, publish_refresh, read_scene_revision_consistent,
    recapture_remote_herdr_attach_request, recapture_remote_herdr_create_request,
    recapture_remote_tmux_attach_request, recapture_remote_zellij_attach_request,
    recapture_remote_zellij_create_request, reconcile_herdr_lifecycle_fences, refresh_is_in_flight,
    register_remote_attachment, register_remote_constructive, register_scene,
    remember_pending_kwt_creation, remote_constructive_is_current, remote_host_for_connection,
    require_current_protected_selection, require_host_session_actions,
    reserve_constructive_inventory, reserve_refresh, scene_by_id, set_herdr_inventory,
    set_remote_herdr_launch_pending, set_remote_host_snapshot, set_remote_host_state,
    set_zellij_inventory, settle_remote_constructive_task, unregister_scene,
    with_current_remote_constructive,
};
use scene::{
    NavigationFence, Scene, activate_retained_presentation, attach_scene, begin_refresh,
    begin_scene_navigation, bump_scene_revision, cancel_owned_kwt_listing, cancel_pending_paste,
    capture_attach_request, capture_create_request, capture_herdr_create_request,
    capture_herdr_lifecycle, capture_herdr_restart_request, capture_kill_request,
    capture_kwt_removal_authority, capture_kwt_worktree_request, capture_zellij_create_request,
    clear_pending_paste, clear_terminal_notice, detach_scene_locked, drop_matching_confirmations,
    drop_matching_kill_confirmations, expire_refresh, fail_refresh_start, fail_retained_retry,
    failed_attachment_context, fallback_owns_request, finish_kwt_project_mutation,
    finish_kwt_worktree_operation, invalidate_pending_herdr_lifecycle, invalidate_pending_kill,
    join_runtime, lock_live_navigation, presentation_is_open, publish_discovered_host,
    publish_herdr_lifecycle_response, publish_pending_kill, publish_remote_connection,
    publish_remote_worker, publish_restored_retained_presentation, publish_terminfo_retry_boundary,
    reconcile_herdr_lifecycle_inventory, reconcile_presentation_session_names,
    reconcile_remote_presentations, register_kill_capture_intent, reinsert_retained_presentation,
    release_scene, reopen_closed_retained_presentation, request_ssh_prompt,
    reserve_kwt_project_mutation, reserve_kwt_worktree_operation, restore_attach_fallback,
    restore_attach_fallback_locked, restore_inventory_after_creation_failure,
    restore_pending_kwt_removal, restore_scene_inventory_state, retire_clipboard_writes,
    run_attach, run_attach_over_remote, run_create, run_herdr_create, run_kwt_project_mutation,
    run_kwt_worktree_operation, run_remote_herdr_attach, run_remote_herdr_create,
    run_remote_tmux_attach, run_remote_zellij_attach, run_remote_zellij_create, run_retained_retry,
    run_zellij_create, schedule_inventory_refresh, schedule_kwt_refresh, set_scene_state,
    set_terminal_notice, set_wsl_host_unavailable, start_initial_kwt_refresh, start_kwt_refresh,
    take_pending_kwt_removal,
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
const EVENT_PUMP_INTERVAL: Duration = Duration::from_millis(33);
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AppearanceSettingsDraft {
    pub theme: TerminalTheme,
    pub font_family: String,
    pub font_size: String,
    pub background: String,
    pub foreground: String,
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
    /// The worker the request came from; a response outliving it is
    /// discarded rather than typed into whatever session navigation
    /// installed since.
    worker_generation: u64,
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

    /// The originating worker generation, passed back with the response.
    #[must_use]
    pub const fn worker_generation(&self) -> u64 {
        self.worker_generation
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
/// Per-scene inbox capacity: a few frames of backlog at the drain budget.
/// Overflow sheds the oldest entry; addressed requests are cancelled, never
/// silently discarded.
const SCENE_INBOX_LIMIT: usize = 4 * MAX_EVENTS_PER_DRAIN;
const RETAINED_EVENT_RESERVE: usize = 8;
const ACTIVE_EVENT_BUDGET: usize = MAX_EVENTS_PER_DRAIN - RETAINED_EVENT_RESERVE;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceError {
    message: String,
    backpressure: bool,
    stale_input: bool,
}

impl WorkspaceError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            backpressure: false,
            stale_input: false,
        }
    }

    fn stale_input(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            backpressure: false,
            stale_input: true,
        }
    }

    /// Whether this refusal means the input outlived its terminal — an
    /// expected race outcome the sender drops silently, never a fault that
    /// should clear queued input or surface a diagnostic.
    #[must_use]
    pub const fn is_stale_input(&self) -> bool {
        self.stale_input
    }

    fn from_worker(error: &terminal::WorkerError) -> Self {
        Self {
            message: error.to_string(),
            backpressure: error.is_backpressure(),
            stale_input: false,
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
    /// In-flight attach attempts against this host, at most one per scene.
    /// Supersede and cancel fences act per scene; only connection-authority
    /// changes cancel every scene's attempt at once.
    attachment_attempts: Vec<RemoteAttachmentAttempt>,
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
        /// Scene that initiated the constructive operation; navigation in
        /// other scenes never cancels it.
        scene: SceneId,
        navigation_generation: u64,
        cancellation: CancellationToken,
        launched: Arc<AtomicBool>,
        target: RemoteConstructiveTarget,
    },
    PendingReconciliation(RemoteConstructiveTarget),
}

struct RemoteAttachmentAttempt {
    /// Scene that initiated the attempt; supersede and navigation fences
    /// compare against it so scenes never cancel each other's attempts.
    scene: SceneId,
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

    /// Whether any retained remote worker still needs pump service.
    fn has_workers(&self) -> bool {
        !self.entries.is_empty()
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

/// One pump pass; returns whether the pump should keep running.
type PumpTask = Box<dyn FnMut() -> bool + Send + 'static>;

trait RefreshRuntime: Send + Sync {
    fn spawn(&self, name: &str, task: RefreshTask) -> std::io::Result<()>;
    fn spawn_after(
        &self,
        name: &str,
        delay: Duration,
        cancellation: CancellationToken,
        task: RefreshTask,
    ) -> std::io::Result<()>;
    /// Drive the runtime event pump. The production runtime runs `tick` on
    /// a background thread every `interval` until it returns `false`; the
    /// manual test runtime records the pump and never runs it, keeping
    /// tests on the synchronous `pump_once` entry point.
    fn start_pump(&self, name: &str, interval: Duration, tick: PumpTask) -> std::io::Result<()>;
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

    fn start_pump(
        &self,
        name: &str,
        interval: Duration,
        mut tick: PumpTask,
    ) -> std::io::Result<()> {
        thread::Builder::new()
            .name(name.to_owned())
            .spawn(move || {
                loop {
                    thread::sleep(interval);
                    if !tick() {
                        break;
                    }
                }
            })
            .map(|_| ())
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

/// Target of one scene's in-flight asynchronous kill identity capture,
/// recorded before the capture task starts. A destructive mutation that
/// completes mid-capture matches the intent and advances the scene's kill
/// fence, so the capture's late publication fails its generation check
/// instead of resurrecting a dialog for a dead target.
struct KillCaptureIntent {
    generation: u64,
    selection: SessionSelection,
}

/// Target of one scene's in-flight asynchronous KWT removal identity
/// capture, with the same role as `KillCaptureIntent` for worktree
/// removals.
struct KwtRemovalCaptureIntent {
    authority: u64,
    endpoint: host::WslEndpoint,
    repository: String,
    project_path: String,
    registration_fingerprint: String,
    worktree_path: String,
    generation: String,
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
    /// Confirmation fence value from the owning scene's
    /// `herdr_lifecycle_generation`; only meaningful inside that scene.
    generation: u64,
    /// Runtime-unique id identifying this operation in the runtime-wide
    /// in-flight registry, where per-scene fence values could collide.
    operation_id: u64,
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
    operation_id: u64,
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
            operation_id: pending.operation_id,
            key,
            action: pending.action,
            reconcile_after_generation: None,
            recovery: None,
        });
        true
    }

    fn finish(&mut self, operation_id: u64) -> bool {
        let previous_len = self.in_flight.len();
        self.in_flight
            .retain(|operation| operation.operation_id != operation_id);
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
            .find(|operation| operation.operation_id == pending.operation_id)
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
    /// The scene whose presentation was suppressed: a delayed recovery is
    /// restored only through this still-live scene — its stored navigation
    /// generation is meaningless against any other scene's — and is
    /// discarded when the owner has closed.
    scene_id: SceneId,
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

    /// Whether any retained worker or pending restart still needs pump
    /// service.
    fn has_workers(&self) -> bool {
        !self.entries.is_empty() || !self.restarting.is_empty()
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

pub(crate) struct CursorDefault(AtomicU8);

impl CursorDefault {
    pub(crate) const fn new(style: CursorStyle) -> Self {
        Self(AtomicU8::new(cursor_style_code(style)))
    }

    fn load(&self) -> CursorShape {
        match self.0.load(Ordering::Acquire) {
            0 => CursorShape::Block,
            1 => CursorShape::Bar,
            2 => CursorShape::Underline,
            _ => unreachable!("cursor default contains an invalid shape"),
        }
    }

    fn store(&self, style: CursorStyle) {
        self.0.store(cursor_style_code(style), Ordering::Release);
    }
}

const fn cursor_style_code(style: CursorStyle) -> u8 {
    match style {
        CursorStyle::Block => 0,
        CursorStyle::Bar => 1,
        CursorStyle::Underline => 2,
    }
}

pub(crate) fn publish_worker_at_latest_geometry<T, E>(
    geometry: &Mutex<TerminalGeometry>,
    workers: &Mutex<WorkerState<T>>,
    worker: T,
    initial_geometry: TerminalGeometry,
    resize: impl FnOnce(&T, TerminalGeometry) -> Result<(), E>,
    reconcile: impl FnOnce(&T),
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
    let generation = workers.publish(worker);
    reconcile(
        workers
            .active()
            .expect("worker was published before reconciliation"),
    );
    Ok(generation)
}

pub(crate) fn resize_terminal_worker(
    worker: &TerminalWorker,
    geometry: TerminalGeometry,
) -> Result<(), WorkerError> {
    worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
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

#[derive(Clone)]
pub struct Workspace {
    scene: Arc<Scene>,
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
            scene: attach_scene(
                Arc::new(Runtime {
                    cursor_default: CursorDefault::new(snapshot.appearance.cursor_style()),
                    appearance: RwLock::new(snapshot.appearance),
                    host_scoped_inventory: false,
                    wsl_config: None,
                    wsl_executable: Mutex::new(None),
                    hosts: RwLock::new(snapshot.hosts),
                    inventory_state: Mutex::new(snapshot.content.clone()),
                    revision: AtomicU64::new(snapshot.revision),
                    snapshot_writers: AtomicUsize::new(0),
                    remote_publication: Mutex::new(()),
                    presentation_generation: AtomicU64::new(presentation_generation),
                    operation_sequence: AtomicU64::new(0),
                    host: Mutex::new(None),
                    remote_hosts: Mutex::new(HashMap::new()),
                    remote_runner: Arc::new(StdCommandRunner),
                    remote_controller: None,
                    ssh_executable: None,
                    settings_mutation: Mutex::new(()),
                    settings: Mutex::new(None),
                    discovery_cancel: Mutex::new(None),
                    event_drain: Mutex::new(()),
                    pump_started: AtomicBool::new(false),
                    herdr_lifecycle: Mutex::new(HerdrLifecycleState::default()),
                    session_operations: Mutex::new(()),
                    remote_constructive_in_flight: AtomicBool::new(false),
                    allow_remote_clipboard_write: true,
                    refresh_generation: AtomicU64::new(0),
                    refresh_finished: AtomicU64::new(0),
                    refresh_publication: Mutex::new(()),
                    inventory_cadence_started: AtomicBool::new(false),
                    kwt_cadence_started: AtomicBool::new(false),
                    kwt_refresh_generation: AtomicU64::new(0),
                    kwt_discovery_cancel: Mutex::new(None),
                    kwt_publication: Mutex::new(()),
                    kwt_mutation_in_flight: AtomicBool::new(false),
                    kwt_worktree_listing: Mutex::new(None),
                    pending_kwt_creations: Mutex::new(Vec::new()),
                    discovery: Arc::new(SystemWslDiscovery::new()),
                    refresh_runtime: Arc::new(ThreadRefreshRuntime),
                    scene_sequence: AtomicU64::new(0),
                    scenes: Mutex::new(Vec::new()),
                }),
                snapshot.content,
                snapshot.selected_host,
                snapshot.notice,
            ),
        }
    }

    /// Open an additional, independent scene over this workspace's shared
    /// runtime.
    ///
    /// The new scene observes the same hosts and inventory but keeps its own
    /// selection, content, presentations, geometry, notices, confirmations,
    /// and event queue. This is the constructor a non-GPUI client (such as
    /// the web UI) uses to join an existing runtime. Registration and the
    /// initial inventory projection are handshaked against concurrent
    /// publications, so a scene opened during a broadcast is never staler
    /// than the runtime's stored inventory.
    #[must_use]
    pub fn open_scene(&self) -> Self {
        Self {
            scene: join_runtime(Arc::clone(&self.scene.runtime)),
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
        let (mut runtime, mut selected_host) = Self::application_runtime(
            appearance,
            wsl,
            Arc::new(SystemWslDiscovery::new()),
            Arc::new(ThreadRefreshRuntime),
        );
        runtime.remote_controller = controller;
        runtime.ssh_executable = ssh;
        *runtime
            .settings
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(SettingsState {
            config: settings,
            roots,
        });
        let runner = Arc::clone(&runtime.remote_runner);
        {
            let entries = runtime
                .remote_hosts
                .get_mut()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let hosts = runtime
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
                            attachment_attempts: Vec::new(),
                            generation: 0,
                        },
                    );
                }
                hosts.push(item);
            }
            if selected_host.is_none() {
                selected_host = hosts.first().map(|host| host.id().to_owned());
            }
        }
        Self {
            scene: attach_scene(
                Arc::new(runtime),
                WorkspaceContent::Shell,
                selected_host,
                None,
            ),
        }
    }

    fn application_with_services(
        appearance: TerminalAppearance,
        wsl: Option<WslHostSpec>,
        discovery: Arc<dyn WslDiscovery>,
        refresh_runtime: Arc<dyn RefreshRuntime>,
    ) -> Self {
        let (runtime, selected_host) =
            Self::application_runtime(appearance, wsl, discovery, refresh_runtime);
        Self {
            scene: attach_scene(
                Arc::new(runtime),
                WorkspaceContent::Shell,
                selected_host,
                None,
            ),
        }
    }

    fn application_runtime(
        appearance: TerminalAppearance,
        wsl: Option<WslHostSpec>,
        discovery: Arc<dyn WslDiscovery>,
        refresh_runtime: Arc<dyn RefreshRuntime>,
    ) -> (Runtime, Option<String>) {
        let allow_remote_clipboard_write = appearance.allow_remote_clipboard_write();
        let hosts = wsl
            .as_ref()
            .map(WslHostSpec::host_item)
            .into_iter()
            .collect();
        let selected_host = wsl.as_ref().map(|_| "wsl".to_owned());
        let wsl_config = wsl.as_ref().map(|spec| spec.config.clone());
        let wsl_executable = wsl.and_then(|spec| spec.executable);
        (
            Runtime {
                cursor_default: CursorDefault::new(appearance.cursor_style()),
                appearance: RwLock::new(appearance.into()),
                host_scoped_inventory: true,
                wsl_config,
                wsl_executable: Mutex::new(wsl_executable),
                hosts: RwLock::new(hosts),
                inventory_state: Mutex::new(WorkspaceContent::Shell),
                revision: AtomicU64::new(0),
                snapshot_writers: AtomicUsize::new(0),
                remote_publication: Mutex::new(()),
                presentation_generation: AtomicU64::new(0),
                operation_sequence: AtomicU64::new(0),
                host: Mutex::new(None),
                remote_hosts: Mutex::new(HashMap::new()),
                remote_runner: Arc::new(StdCommandRunner),
                remote_controller: None,
                ssh_executable: None,
                settings_mutation: Mutex::new(()),
                settings: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                event_drain: Mutex::new(()),
                pump_started: AtomicBool::new(false),
                herdr_lifecycle: Mutex::new(HerdrLifecycleState::default()),
                session_operations: Mutex::new(()),
                remote_constructive_in_flight: AtomicBool::new(false),
                allow_remote_clipboard_write,
                refresh_generation: AtomicU64::new(0),
                refresh_finished: AtomicU64::new(0),
                refresh_publication: Mutex::new(()),
                inventory_cadence_started: AtomicBool::new(false),
                kwt_cadence_started: AtomicBool::new(false),
                kwt_refresh_generation: AtomicU64::new(0),
                kwt_discovery_cancel: Mutex::new(None),
                kwt_publication: Mutex::new(()),
                kwt_mutation_in_flight: AtomicBool::new(false),
                kwt_worktree_listing: Mutex::new(None),
                pending_kwt_creations: Mutex::new(Vec::new()),
                discovery,
                refresh_runtime,
                scene_sequence: AtomicU64::new(0),
                scenes: Mutex::new(Vec::new()),
            },
            selected_host,
        )
    }

    #[must_use]
    pub fn start_wsl(config: WslConfig, appearance: TerminalAppearance) -> Self {
        let allow_remote_clipboard_write = appearance.allow_remote_clipboard_write();
        let workspace = Self {
            scene: attach_scene(
                Arc::new(Runtime {
                    cursor_default: CursorDefault::new(appearance.cursor_style()),
                    appearance: RwLock::new(appearance.into()),
                    host_scoped_inventory: false,
                    wsl_config: Some(config.clone()),
                    wsl_executable: Mutex::new(None),
                    hosts: RwLock::new(vec![HostItem::wsl(
                        config.distro().unwrap_or("Default distro"),
                        config.socket_directory().map(str::to_owned),
                        HostConnectionState::Connecting,
                        Vec::new(),
                        None,
                    )]),
                    inventory_state: Mutex::new(WorkspaceContent::Loading),
                    revision: AtomicU64::new(0),
                    snapshot_writers: AtomicUsize::new(0),
                    remote_publication: Mutex::new(()),
                    presentation_generation: AtomicU64::new(0),
                    operation_sequence: AtomicU64::new(0),
                    host: Mutex::new(None),
                    remote_hosts: Mutex::new(HashMap::new()),
                    remote_runner: Arc::new(StdCommandRunner),
                    remote_controller: None,
                    ssh_executable: None,
                    settings_mutation: Mutex::new(()),
                    settings: Mutex::new(None),
                    discovery_cancel: Mutex::new(None),
                    event_drain: Mutex::new(()),
                    pump_started: AtomicBool::new(false),
                    herdr_lifecycle: Mutex::new(HerdrLifecycleState::default()),
                    session_operations: Mutex::new(()),
                    remote_constructive_in_flight: AtomicBool::new(false),
                    allow_remote_clipboard_write,
                    refresh_generation: AtomicU64::new(0),
                    refresh_finished: AtomicU64::new(0),
                    refresh_publication: Mutex::new(()),
                    inventory_cadence_started: AtomicBool::new(false),
                    kwt_cadence_started: AtomicBool::new(false),
                    kwt_refresh_generation: AtomicU64::new(0),
                    kwt_discovery_cancel: Mutex::new(None),
                    kwt_publication: Mutex::new(()),
                    kwt_mutation_in_flight: AtomicBool::new(false),
                    kwt_worktree_listing: Mutex::new(None),
                    pending_kwt_creations: Mutex::new(Vec::new()),
                    discovery: Arc::new(SystemWslDiscovery::new()),
                    refresh_runtime: Arc::new(ThreadRefreshRuntime),
                    scene_sequence: AtomicU64::new(0),
                    scenes: Mutex::new(Vec::new()),
                }),
                WorkspaceContent::Loading,
                Some("wsl".to_owned()),
                None,
            ),
        };
        workspace.start_refresh(config, None, RefreshPresentation::Connecting);
        workspace
    }

    /// Start discovery for enabled hosts after the application has painted.
    ///
    /// # Errors
    ///
    /// Returns an error when this scene has closed; refresh failures are
    /// reported through workspace events instead.
    pub fn connect_enabled_hosts(&self) -> Result<(), WorkspaceError> {
        // Same close fence as refresh: startup discovery is constructive
        // shared work no closed scene may initiate.
        let _navigation = lock_live_navigation(&self.scene)?;
        let Some(config) = self.scene.runtime.wsl_config.clone() else {
            return Ok(());
        };
        let executable = self
            .scene
            .runtime
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
        self.scene
            .runtime
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
        self.scene
            .runtime
            .settings
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(
                || {
                    let appearance = self
                        .scene
                        .runtime
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
        self.scene
            .runtime
            .settings
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(
                || {
                    let appearance = self
                        .scene
                        .runtime
                        .appearance
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    TerminalSettingsDraft::from(&*appearance)
                },
                |settings| TerminalSettingsDraft::from(settings.config.terminal()),
            )
    }

    #[must_use]
    pub fn hide_mouse_while_typing(&self) -> bool {
        self.scene
            .runtime
            .appearance
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .hide_mouse_while_typing()
    }

    /// Persist terminal interaction settings and publish them to the
    /// running workspace, updating the default cursor shape on every live
    /// worker.
    ///
    /// # Errors
    ///
    /// Returns an error when this scene has closed, or settings storage is
    /// unavailable or cannot be written.
    pub fn save_terminal_settings(
        &self,
        draft: &TerminalSettingsDraft,
    ) -> Result<(), WorkspaceError> {
        // Same mutation-then-fence discipline as the other settings
        // mutators: persistence and publication are one serialized
        // transition, refused for a closed scene.
        let _mutation = self
            .scene
            .runtime
            .settings_mutation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = lock_live_navigation(&self.scene)?;
        let appearance = {
            let mut settings = self
                .scene
                .runtime
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
        self.scene.runtime.cursor_default.store(draft.cursor_style);
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        *self
            .scene
            .runtime
            .appearance
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = appearance.into();
        update_default_cursor_shapes(
            &self.scene,
            current_default_cursor_shape(&self.scene.runtime),
        );
        self.scene.runtime.revision.fetch_add(1, Ordering::Release);
        Ok(())
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
        // Persistence and publication happen under one runtime-owned
        // mutation lock, acquired before the scene fence, so concurrent
        // saves publish in persistence order and a closed scene's retained
        // handle mutates nothing.
        let _mutation = self
            .scene
            .runtime
            .settings_mutation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = lock_live_navigation(&self.scene)?;
        let font_size = draft
            .font_size
            .trim()
            .parse::<u16>()
            .map_err(|_| WorkspaceError::new("Font size must be a number from 1 to 65535"))?;
        let appearance = {
            let mut settings = self
                .scene
                .runtime
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
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        *self
            .scene
            .runtime
            .appearance
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = appearance.into();
        self.scene.runtime.revision.fetch_add(1, Ordering::Release);
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
        // Same mutation-then-fence discipline as save_appearance: the
        // persistence and the runtime publication of this host are one
        // serialized transition, refused for a closed scene.
        let _mutation = self
            .scene
            .runtime
            .settings_mutation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let navigation = lock_live_navigation(&self.scene)?;
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
                .scene
                .runtime
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
        self.publish_saved_ssh_host(&navigation, original_id, &host)?;
        Ok(id)
    }

    /// Remove one configured SSH host after disconnecting its local clients.
    ///
    /// # Errors
    ///
    /// Returns an error if the host changed or configuration cannot be saved.
    pub fn remove_ssh_host(&self, id: &str) -> Result<(), WorkspaceError> {
        // The mutation lock is acquired before this scene's navigation
        // fence, and the removal loop takes other scenes' navigation locks
        // only under it, so two scenes' settings mutations serialize
        // instead of deadlocking across navigation locks.
        let _mutation = self
            .scene
            .runtime
            .settings_mutation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let navigation = lock_live_navigation(&self.scene)?;
        {
            let mut settings = self
                .scene
                .runtime
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
        self.remove_ssh_host_runtime(&navigation, id, None);
        Ok(())
    }

    /// Select one current host without starting a connection.
    ///
    /// # Errors
    ///
    /// Returns an error when the host is no longer configured.
    pub fn select_host(&self, id: &str) -> Result<(), WorkspaceError> {
        // The host-list read guard is held through the selection write, so
        // a concurrent removal cannot delete the host between the
        // existence check and the write — removal's reconciliation either
        // sees this selection and re-points it, or this selection fails
        // here. The snapshot-write guard keeps the selection and revision
        // bump one published transition.
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let hosts = self
            .scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !hosts.iter().any(|host| host.id() == id) {
            return Err(WorkspaceError::new("host is no longer configured"));
        }
        *self
            .scene
            .selected_host
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(id.to_owned());
        drop(hosts);
        bump_scene_revision(&self.scene);
        Ok(())
    }

    /// Explicitly connect or refresh one host.
    ///
    /// # Errors
    ///
    /// Returns an error when the host no longer exists or its background task
    /// cannot be scheduled.
    #[allow(
        clippy::too_many_lines,
        reason = "the runtime/scene split lengthens shared-state paths without adding logic"
    )]
    pub fn connect_host(&self, id: &str) -> Result<(), WorkspaceError> {
        // Lock order: `remote_publication` strictly before any scene
        // navigation lock. The publication side (publish_remote_connection
        // and its reconciliation) holds the publication lock while taking
        // every scene's navigation lock, so taking them here in the other
        // order deadlocks a connect against a concurrent publication. One
        // guard spans the whole method; the capture and cleanup sections
        // below run under it.
        let _publication = self
            .scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // Connecting is a constructive entry: a retained handle of a closed
        // scene must not mutate shared host state or publish connection
        // outcomes to surviving scenes.
        let _navigation = lock_live_navigation(&self.scene)?;
        self.select_host(id)?;
        if id == "wsl" {
            // The connect fence above already holds the navigation guard.
            return self.refresh_locked();
        }
        let generation = self
            .scene
            .runtime
            .operation_sequence
            .fetch_add(1, Ordering::AcqRel)
            + 1;
        let cancellation = CancellationToken::new();
        let (config, native_host) = {
            let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
            let connection = {
                let mut entries = self
                    .scene
                    .runtime
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
            set_remote_host_state(
                &self.scene.runtime,
                id,
                HostConnectionState::Connecting,
                None,
                None,
            );
            connection
        };
        let scene = Arc::clone(&self.scene);
        let host_id = id.to_owned();
        if let Err(error) = self.scene.runtime.refresh_runtime.spawn(
            "ghosthub-ssh-connect",
            Box::new(move || {
                let prompt_scene = Arc::clone(&scene);
                let prompt_host = host_id.clone();
                let prompt_cancel = cancellation.clone();
                let result =
                    remote_host_for_connection(&scene.runtime, config, native_host, &cancellation)
                        .and_then(|host| {
                            host.connect(
                                &cancellation,
                                move |prompt| {
                                    request_ssh_prompt(
                                        &prompt_scene,
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
                publish_remote_connection(&scene, &host_id, generation, result);
            }),
        ) {
            let stale_context = {
                let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
                let stale_context = self
                    .scene
                    .runtime
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
                        &self.scene.runtime,
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
        // Publication before the fence, matching connect_host; a retained
        // handle of a closed scene cannot cancel work active scenes use or
        // publish shared disconnected state, so the cancellation is
        // rejected rather than performed.
        let _publication = self
            .scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Ok(_navigation) = lock_live_navigation(&self.scene) else {
            return false;
        };
        if id == "wsl" {
            return cancel_refresh(&self.scene.runtime);
        }
        let cancelled = {
            let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
            let cancelled = {
                let mut entries = self
                    .scene
                    .runtime
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
                    &self.scene.runtime,
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
        self.scene
            .runtime
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
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        {
            let mut entries = self
                .scene
                .runtime
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
            .scene
            .runtime
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter_mut()
            .find(|item| item.id() == config.id())
        {
            config.name().clone_into(&mut item.name);
            item.endpoint = config.endpoint();
        }
        self.scene.runtime.revision.fetch_add(1, Ordering::Release);
        true
    }

    fn publish_saved_ssh_host(
        &self,
        navigation: &NavigationFence<'_>,
        original_id: Option<&str>,
        settings: &SshHostSettings,
    ) -> Result<(), WorkspaceError> {
        debug_assert!(
            navigation.fences(&self.scene),
            "the fence must belong to the initiating scene"
        );
        let config = remote_config(settings)?;
        let new_id = config.id().to_owned();
        if self.update_ssh_host_metadata(original_id, &config) {
            return Ok(());
        }
        // One writer guard spans the removal and the re-add: selections
        // re-pointed at the renamed id and the renamed host's list entry
        // publish to snapshot readers as a single transition, never a
        // dangling selection.
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        if let Some(original_id) = original_id {
            self.remove_ssh_host_runtime(navigation, original_id, Some(&new_id));
        }
        #[cfg(windows)]
        let dependencies_available = self
            .scene
            .runtime
            .wsl_executable
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some();
        #[cfg(not(windows))]
        let dependencies_available = self.scene.runtime.remote_controller.is_some()
            && self.scene.runtime.ssh_executable.is_some();
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
            .scene
            .runtime
            .remote_controller
            .as_ref()
            .zip(self.scene.runtime.ssh_executable.as_ref())
            .map(|(controller, ssh)| {
                RemoteTmuxHost::new(
                    config.clone(),
                    controller,
                    ssh,
                    Arc::clone(&self.scene.runtime.remote_runner),
                )
            });
        if dependencies_available {
            self.scene
                .runtime
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
                        attachment_attempts: Vec::new(),
                        generation: 0,
                    },
                );
        }
        self.scene
            .runtime
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(item);
        // The removal loop above already re-pointed every scene that had
        // the original id selected at the renamed id; re-asserting it here
        // from a pre-captured flag could overwrite a selection made since.
        self.scene.runtime.revision.fetch_add(1, Ordering::Release);
        Ok(())
    }

    /// Tear down runtime and per-scene state for one host id. On a host
    /// edit that changes the id, `successor` re-points selections that
    /// followed the old id at the renamed host instead of an arbitrary
    /// remaining one. The caller passes its held navigation fence for the
    /// initiating scene: the removal loop detaches that scene through the
    /// already-locked path, so the guard in the signature is what makes an
    /// unfenced call — which would race concurrent navigation — impossible
    /// rather than merely undocumented.
    ///
    /// Callers must additionally hold `runtime.settings_mutation` before
    /// taking their fence: this is the only path that holds one scene's
    /// navigation lock while acquiring other scenes' navigation locks, so
    /// two invocations initiated from different scenes would deadlock
    /// against each other without that outer serialization.
    fn remove_ssh_host_runtime(
        &self,
        navigation: &NavigationFence<'_>,
        id: &str,
        successor: Option<&str>,
    ) {
        debug_assert!(
            navigation.fences(&self.scene),
            "the fence must belong to the initiating scene"
        );
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        if let Some(mut entry) = self
            .scene
            .runtime
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
        self.scene
            .runtime
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .retain(|host| host.id() != id);
        let replacement = successor.map(str::to_owned).or_else(|| {
            self.scene
                .runtime
                .hosts
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .first()
                .map(|host| host.id().to_owned())
        });
        // Every live scene may hold presentations or a selection tied to
        // the removed host, not just the scene the removal was initiated
        // from.
        for scene in live_scenes(&self.scene.runtime) {
            let workspace = Self {
                scene: Arc::clone(&scene),
            };
            // Each scene's active check, conditional detach, and retained
            // cleanup happen under that scene's navigation lock, so a
            // concurrent session switch cannot slip a new presentation in
            // after the check (and be wrongly detached) or land on the
            // removed host after the pass (and keep its client alive).
            // The initiating scene's fence is already held by the caller;
            // the raw lock is deliberate for the others — a scene mid-
            // close still gets its removed-host state cleaned up.
            let _navigation = if Arc::ptr_eq(&scene, &self.scene) {
                None
            } else {
                Some(
                    scene
                        .navigation
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner),
                )
            };
            let active_matches = scene
                .remote_active
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_ref()
                .is_some_and(|active| active.selection.host_id() == id);
            if active_matches {
                workspace.detach_locked();
            }
            scene
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove_host(id);
            {
                // Compared and replaced under one write guard: a selection
                // of a surviving host that lands concurrently is never
                // overwritten by the replacement.
                let mut selected = scene
                    .selected_host
                    .write()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if selected.as_deref() == Some(id) {
                    selected.clone_from(&replacement);
                }
            }
            bump_scene_revision(&scene);
        }
        self.scene.runtime.revision.fetch_add(1, Ordering::Release);
    }

    /// Refresh the current WSL inventory without requiring an app restart.
    ///
    /// # Errors
    ///
    /// Returns an error when this scene has closed, and for preview
    /// workspaces, which have no host config.
    pub fn refresh(&self) -> Result<(), WorkspaceError> {
        // Refreshing reserves generations, cancels in-flight shared
        // refreshes, and publishes results: a retained handle of a closed
        // scene must not initiate it.
        let _navigation = lock_live_navigation(&self.scene)?;
        self.refresh_locked()
    }

    /// Refresh with the live-navigation fence already held by the caller.
    fn refresh_locked(&self) -> Result<(), WorkspaceError> {
        let config = self
            .scene
            .runtime
            .wsl_config
            .clone()
            .ok_or_else(|| WorkspaceError::new("preview workspace cannot refresh WSL"))?;
        let executable = self
            .scene
            .runtime
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
        start_kwt_refresh(&self.scene, true);
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
        // Same closed-scene fence as the other destructive confirmations,
        // held from authority creation through the identity-query
        // scheduling: a retained handle of a closed scene arms nothing.
        let _navigation = lock_live_navigation(&self.scene)?;
        if !is_canonical_kwt_generation(generation) {
            return Err(WorkspaceError::new(
                "Refresh KWT inventory before removing this worktree.",
            ));
        }
        let (host, resolved_endpoint, runtime, socket_name) = capture_kwt_worktree_removal_context(
            &self.scene.runtime,
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
            .scene
            .pending_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let authority = self
            .scene
            .kwt_removal_generation
            .fetch_add(1, Ordering::AcqRel)
            + 1;
        pending.take();
        // Record the capture's target before the task starts so a removal
        // of the same worktree completing mid-capture can fence the late
        // publication. Minting the authority and registering the intent
        // share this slot-lock critical section, so overlapping removal
        // requests serialize and cannot overwrite each other's intents.
        *self
            .scene
            .kwt_removal_capture_intent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(KwtRemovalCaptureIntent {
            authority,
            endpoint: resolved_endpoint.clone(),
            repository: repository.to_owned(),
            project_path: project_path.to_owned(),
            registration_fingerprint: registration_fingerprint.to_owned(),
            worktree_path: worktree_path.to_owned(),
            generation: generation.to_owned(),
        });
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
        let scene = Arc::clone(&self.scene);
        self.scene
            .runtime
            .refresh_runtime
            .spawn(
                "ghosthub-kwt-removal-identity",
                Box::new(move || capture_kwt_removal_authority(&scene, capture)),
            )
            .map_err(|error| WorkspaceError::new(format!("verify worktree session: {error}")))?;
        Ok(authority)
    }

    pub fn cancel_kwt_worktree_removal(&self) {
        let mut pending = self
            .scene
            .pending_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.scene
            .kwt_removal_generation
            .fetch_add(1, Ordering::AcqRel);
        *self
            .scene
            .kwt_removal_capture_intent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
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
                .scene
                .runtime
                .kwt_worktree_listing
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if active.as_ref().is_none_or(|listing| {
                // Another scene presenting this operation id is not the
                // owning dialog and must not release the owner's listing.
                listing.operation_id != operation_id || listing.scene_id != self.scene.id
            }) {
                return false;
            }
            let Some(listing) = active.take() else {
                return false;
            };
            listing
        };
        cancel_owned_kwt_listing(&self.scene, &listing);
        // The one step scene close skips: a live dialog wants fresh KWT
        // inventory after its cancelled listing.
        start_initial_kwt_refresh(&self.scene);
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
            &self.scene,
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
            restore_pending_kwt_removal(&self.scene, pending);
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
        // KWT reservations are constructive entries: held through the
        // reservation and task scheduling so a close cannot interleave — a
        // retained handle of a closed scene fails here instead of starting
        // host-side work whose events would be discarded.
        let _navigation = lock_live_navigation(&self.scene)?;
        let task = reserve_kwt_worktree_operation(
            &self.scene,
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
                .scene
                .runtime
                .kwt_worktree_listing
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(KwtWorktreeListing {
                generation: task.generation,
                operation_id,
                scene_id: self.scene.id,
                cancellation: task.cancellation.clone(),
            });
        }
        let task_scene = Arc::clone(&self.scene);
        let background_task = task.clone();
        if let Err(error) = self.scene.runtime.refresh_runtime.spawn(
            "ghosthub-kwt-worktree-operation",
            Box::new(move || run_kwt_worktree_operation(&task_scene, &background_task)),
        ) {
            finish_kwt_worktree_operation(&self.scene, &task);
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
        // Same close fence as worktree operations: reservation and
        // scheduling complete before a concurrent close proceeds, or fail
        // after it.
        let _navigation = lock_live_navigation(&self.scene)?;
        let task = reserve_kwt_project_mutation(&self.scene, host_id, endpoint, request)?;
        let task_scene = Arc::clone(&self.scene);
        if let Err(error) = self.scene.runtime.refresh_runtime.spawn(
            "ghosthub-kwt-project-mutation",
            Box::new(move || run_kwt_project_mutation(&task_scene, &task)),
        ) {
            finish_kwt_project_mutation(&self.scene, None);
            return Err(WorkspaceError::new(format!(
                "start KWT project operation: {error}"
            )));
        }
        Ok(())
    }

    /// Start the runtime event pump and the application-owned inventory
    /// cadence after the first frame.
    ///
    /// The pump, the timer, and every host read execute through the
    /// background refresh runtime. Calling this method never performs
    /// discovery itself and is idempotent for the lifetime of the workspace.
    ///
    /// # Errors
    ///
    /// Returns an error when the pump or the background cadence cannot be
    /// scheduled.
    pub fn start_inventory_cadence(&self) -> Result<(), WorkspaceError> {
        start_event_pump(&self.scene.runtime)?;
        if self.scene.runtime.wsl_config.is_none() {
            return Ok(());
        }
        if self
            .scene
            .runtime
            .inventory_cadence_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
            && let Err(error) = schedule_inventory_refresh(&self.scene)
        {
            self.scene
                .runtime
                .inventory_cadence_started
                .store(false, Ordering::Release);
            return Err(WorkspaceError::new(format!(
                "schedule inventory refresh cadence: {error}"
            )));
        }
        if self
            .scene
            .runtime
            .wsl_config
            .as_ref()
            .is_some_and(|config| config.kwt_bundle().is_some())
            && self
                .scene
                .runtime
                .kwt_cadence_started
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            && let Err(error) = schedule_kwt_refresh(&self.scene)
        {
            self.scene
                .runtime
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
        self.scene
            .inventory_polling_enabled
            .store(enabled, Ordering::Release);
    }

    fn refresh_if_ready(&self) -> Result<bool, WorkspaceError> {
        if !self.host_is_ready() || refresh_is_in_flight(&self.scene.runtime) {
            return Ok(false);
        }
        let config = self
            .scene
            .runtime
            .wsl_config
            .clone()
            .ok_or_else(|| WorkspaceError::new("preview workspace cannot refresh WSL"))?;
        let executable = self
            .scene
            .runtime
            .wsl_executable
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        self.start_refresh(config, executable, RefreshPresentation::PreserveReady);
        Ok(true)
    }

    fn host_is_ready(&self) -> bool {
        self.scene
            .runtime
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
        // A closed scene's retained handle cannot cancel the shared
        // refresh out from under live scenes; rejected, not performed.
        let Ok(_navigation) = lock_live_navigation(&self.scene) else {
            return false;
        };
        cancel_refresh(&self.scene.runtime)
    }

    /// Refresh shared inventory after a completed host-side mutation,
    /// re-anchoring on any surviving scene when the initiating scene
    /// closed before the mutation finished — the mutation succeeded, so
    /// surviving scenes must not be left with stale inventory.
    ///
    /// # Errors
    ///
    /// Returns the initiating scene's refresh error when no surviving
    /// scene could refresh either.
    pub(crate) fn refresh_reanchored(&self) -> Result<(), WorkspaceError> {
        let first = match self.refresh() {
            Ok(()) => return Ok(()),
            Err(error) => error,
        };
        for scene in live_scenes(&self.scene.runtime) {
            if Arc::ptr_eq(&scene, &self.scene) {
                continue;
            }
            let survivor = Self { scene };
            if survivor.refresh().is_ok() {
                return Ok(());
            }
        }
        Err(first)
    }

    #[must_use]
    pub fn snapshot(&self) -> WorkspaceSnapshot {
        read_scene_revision_consistent(&self.scene.runtime, &self.scene, |revision| {
            let mut hosts = self
                .scene
                .runtime
                .hosts
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone();
            let current_runtime = self
                .scene
                .runtime
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
                &self.scene.runtime.herdr_lifecycle,
            );
            // Snapshot fields must be owned before crossing into the
            // attachment locks. Presentation transitions take attachment
            // before publishing state, so retaining an RwLock guard here
            // would invert that order and could deadlock the UI.
            let content = {
                self.scene
                    .state
                    .read()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clone()
            };
            let selected_host = {
                self.scene
                    .selected_host
                    .read()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clone()
            };
            let notice = {
                self.scene
                    .terminal_notice
                    .read()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clone()
            };
            let active_selection = {
                let remote = self
                    .scene
                    .remote_active
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .as_ref()
                    .map(|active| active.selection.clone());
                remote.or_else(|| {
                    self.scene
                        .attachment
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .active()
                        .map(|active| active.request.selection())
                })
            };
            let retained_selections = {
                let mut selections = self
                    .scene
                    .retained_presentations
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .selections();
                selections.extend(
                    self.scene
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
                    .scene
                    .runtime
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
        })
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
                .scene
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
        let _navigation = lock_live_navigation(&self.scene)?;
        if self
            .scene
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
            let _navigation = lock_live_navigation(&self.scene)?;
            let navigation_generation = self.begin_navigation();
            self.settle_local_navigation_before_remote()?;
            let current_key = self.remote_presentation_key(selection);
            let active_matches = self
                .scene
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
                let request = capture_remote_herdr_attach_request(&self.scene.runtime, selection)?;
                return self.start_remote_herdr_attachment(request, navigation_generation);
            }
            if selection.kind() == SessionKind::Zellij {
                let request = capture_remote_zellij_attach_request(&self.scene.runtime, selection)?;
                return self.start_remote_zellij_attachment(request, navigation_generation);
            }
            let request = capture_remote_tmux_attach_request(&self.scene.runtime, selection)?;
            return self.start_remote_tmux_attachment(request, navigation_generation);
        }
        if self
            .scene
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
        {
            let _navigation = lock_live_navigation(&self.scene)?;
            let (key, request) = self.navigation_target(selection)?;
            let navigation_generation = self.begin_navigation();
            self.scene
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
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let _navigation = lock_live_navigation(&self.scene)?;
        self.switch_session_locked(selection)
    }

    fn is_remote_host(&self, host_id: &str) -> bool {
        self.scene
            .runtime
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
            .scene
            .runtime
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
        self.scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .invalidate();
        let surface = self
            .scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .map(TerminalWorker::surface_handle)
            .ok_or_else(|| WorkspaceError::new("the active remote presentation is unavailable"))?;
        let mut remote_active = self
            .scene
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
            set_scene_state(
                &self.scene,
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
                .scene
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
            &self.scene,
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
            self.scene
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
                .scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if self
                .scene
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
        let scene = Arc::clone(&self.scene);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-cross-host-attach".to_owned())
            .spawn(move || {
                run_attach_over_remote(
                    &scene,
                    &request,
                    AttachTerm::Xterm256Color,
                    generation,
                    navigation_generation,
                );
            })
        {
            self.scene
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
            .scene
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take(key)
        else {
            return Ok(false);
        };
        let snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let mut attachment = self
            .scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(generation) =
            reserve_retained_attachment(&mut attachment, &presentation.attachment, None)
        else {
            reinsert_retained_presentation(&self.scene, presentation);
            return Err(WorkspaceError::new(
                "a terminal presentation is already opening",
            ));
        };
        let geometry = self
            .scene
            .terminal_geometry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Err(error) = presentation.worker.resize_with_metadata(
            geometry.grid,
            geometry.sequence,
            geometry.pixels,
        ) {
            attachment.clear_if_current(generation);
            reinsert_retained_presentation(&self.scene, presentation);
            return Err(WorkspaceError::from_worker(&error));
        }
        let mut remote_active = self
            .scene
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active_remote) = remote_active.as_ref() else {
            attachment.clear_if_current(generation);
            reinsert_retained_presentation(&self.scene, presentation);
            return Err(WorkspaceError::new(
                "the remote terminal presentation is no longer active",
            ));
        };
        let mut workers = self
            .scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if workers.generation() != active_remote.worker_generation {
            attachment.clear_if_current(generation);
            reinsert_retained_presentation(&self.scene, presentation);
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
        reconcile_active_worker_cursor(&self.scene.runtime, &workers);
        let previous_remote = remote_active.take();
        clear_pending_paste(&self.scene);
        set_terminal_notice(&self.scene, term);
        set_scene_state(
            &self.scene,
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
            retire_clipboard_writes(&self.scene, &worker);
            let _cancelled = worker.cancel_paste();
            insert_remote_retained_presentation(
                &self.scene.runtime,
                &self.scene.remote_retained,
                RemoteRetainedPresentation { active, worker },
            );
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
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let _navigation = lock_live_navigation(&self.scene)?;
        let request = capture_kwt_worktree_request(
            &self.scene,
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
        let equivalent_tmux_key = equivalent_tmux_presentation_key(&self.scene.runtime, &request);
        let key = equivalent_tmux_key
            .filter(|key| presentation_is_open(&self.scene, key))
            .unwrap_or(worktree_key);
        if self
            .scene
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
            .scene
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
            self.scene
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
            .scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some();
        if same_visible_selection && !has_active_attachment {
            return Ok(());
        }
        if selection.kind() == SessionKind::Herdr
            && herdr_operation_pending_for_selection(&self.scene.runtime, selection)
        {
            return Err(WorkspaceError::new(
                "this Herdr session is already starting or changing lifecycle",
            ));
        }

        let (key, request) = self.navigation_target(selection)?;
        if self
            .scene
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
            .scene
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
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let name =
            SessionName::parse(name).map_err(|error| WorkspaceError::new(error.to_string()))?;
        let navigation = lock_live_navigation(&self.scene)?;
        let request = capture_create_request(&self.scene, host_id, endpoint, name)?;
        let navigation_generation = self.begin_navigation();
        let in_flight_fallback = self.supersede_inflight_attachment()?;
        let visible_previous = self.retain_active_presentation()?;
        let previous = in_flight_fallback.or(visible_previous);
        let cancellation = CancellationToken::new();
        *self
            .scene
            .pending_creation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(PendingCreation {
            navigation_generation,
            previous: previous.clone(),
            cancellation: cancellation.clone(),
            herdr_operation: None,
        });
        clear_terminal_notice(&self.scene);
        set_scene_state(
            &self.scene,
            WorkspaceContent::Attaching {
                host_id: request.host_id.clone(),
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.as_str().to_owned(),
                kind: SessionKind::Tmux,
            },
        );

        let scene = Arc::clone(&self.scene);
        let spawn_request = request.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-create".to_owned())
            .spawn(move || {
                run_create(&scene, &spawn_request, navigation_generation, &cancellation);
            })
        {
            drop(navigation);
            restore_inventory_after_creation_failure(
                &self.scene,
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
        let navigation = lock_live_navigation(&self.scene)?;
        if self.is_remote_host(host_id) {
            let request =
                capture_remote_herdr_create_request(&self.scene.runtime, host_id, endpoint, name)?;
            return self.start_remote_herdr_launch(request, navigation);
        }
        let request = capture_herdr_create_request(&self.scene, host_id, endpoint, name)?;
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
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let navigation = lock_live_navigation(&self.scene)?;
        if self.is_remote_host(host_id) {
            let request =
                capture_remote_zellij_create_request(&self.scene.runtime, host_id, endpoint, name)?;
            return self.start_remote_zellij_launch(request, navigation);
        }
        let request = capture_zellij_create_request(&self.scene, host_id, endpoint, name)?;
        let navigation_generation = self.begin_navigation();
        let in_flight_fallback = self.supersede_inflight_attachment()?;
        let visible_previous = self.retain_active_presentation()?;
        let previous = in_flight_fallback.or(visible_previous);
        let cancellation = CancellationToken::new();
        *self
            .scene
            .pending_creation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(PendingCreation {
            navigation_generation,
            previous,
            cancellation: cancellation.clone(),
            herdr_operation: None,
        });
        clear_terminal_notice(&self.scene);
        set_scene_state(
            &self.scene,
            WorkspaceContent::Attaching {
                host_id: request.host_id.clone(),
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.as_str().to_owned(),
                kind: SessionKind::Zellij,
            },
        );
        let scene = Arc::clone(&self.scene);
        let spawn_request = request.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-zellij-create".to_owned())
            .spawn(move || {
                run_zellij_create(&scene, &spawn_request, navigation_generation, &cancellation);
            })
        {
            drop(navigation);
            restore_inventory_after_creation_failure(
                &self.scene,
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
        let navigation = lock_live_navigation(&self.scene)?;
        if self.is_remote_host(selection.host_id()) {
            let request = capture_remote_herdr_restart_request(&self.scene.runtime, selection)?;
            return self.start_remote_herdr_launch(request, navigation);
        }
        let request = capture_herdr_restart_request(&self.scene, selection)?;
        self.start_herdr_launch(&request, navigation)
    }

    fn start_remote_herdr_launch(
        &self,
        request: RemoteHerdrCreateRequest,
        navigation: NavigationFence<'_>,
    ) -> Result<(), WorkspaceError> {
        self.reserve_remote_constructive()?;
        let navigation_generation = self.begin_navigation();
        let cancellation = CancellationToken::new();
        let launched = match register_remote_constructive(
            &self.scene.runtime,
            self.scene.id,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
            request.constructive_target(),
        ) {
            Ok(launched) => launched,
            Err(error) => {
                self.scene
                    .runtime
                    .remote_constructive_in_flight
                    .store(false, Ordering::Release);
                return Err(error);
            }
        };
        if let Err(error) = self.settle_local_navigation_before_remote() {
            cancellation.cancel();
            clear_remote_constructive_registration(&self.scene.runtime, &request.host_id);
            self.scene
                .runtime
                .remote_constructive_in_flight
                .store(false, Ordering::Release);
            return Err(error);
        }
        set_remote_herdr_launch_pending(
            &self.scene.runtime,
            &request.host_id,
            request.name.as_str(),
            true,
        );
        let pending_host_id = request.host_id.clone();
        let pending_name = request.name.as_str().to_owned();
        let scene = Arc::clone(&self.scene);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-herdr-launch".to_owned())
            .spawn(move || {
                run_remote_herdr_create(
                    &scene,
                    &request,
                    navigation_generation,
                    &cancellation,
                    &launched,
                );
            })
        {
            clear_remote_constructive_registration(&self.scene.runtime, &pending_host_id);
            self.scene
                .runtime
                .remote_constructive_in_flight
                .store(false, Ordering::Release);
            set_remote_herdr_launch_pending(
                &self.scene.runtime,
                &pending_host_id,
                &pending_name,
                false,
            );
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
        navigation: NavigationFence<'_>,
    ) -> Result<(), WorkspaceError> {
        self.reserve_remote_constructive()?;
        let navigation_generation = self.begin_navigation();
        let cancellation = CancellationToken::new();
        let launched = match register_remote_constructive(
            &self.scene.runtime,
            self.scene.id,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
            request.constructive_target(),
        ) {
            Ok(launched) => launched,
            Err(error) => {
                self.scene
                    .runtime
                    .remote_constructive_in_flight
                    .store(false, Ordering::Release);
                return Err(error);
            }
        };
        if let Err(error) = self.settle_local_navigation_before_remote() {
            cancellation.cancel();
            clear_remote_constructive_registration(&self.scene.runtime, &request.host_id);
            self.scene
                .runtime
                .remote_constructive_in_flight
                .store(false, Ordering::Release);
            return Err(error);
        }
        let pending_host_id = request.host_id.clone();
        let scene = Arc::clone(&self.scene);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-zellij-launch".to_owned())
            .spawn(move || {
                run_remote_zellij_create(
                    &scene,
                    &request,
                    navigation_generation,
                    &cancellation,
                    &launched,
                );
            })
        {
            clear_remote_constructive_registration(&self.scene.runtime, &pending_host_id);
            self.scene
                .runtime
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
            &self.scene.runtime,
            self.scene.id,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
        )?;
        let scene = Arc::clone(&self.scene);
        let host_id = request.host_id.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-zellij-attach".to_owned())
            .spawn(move || {
                run_remote_zellij_attach(&scene, &request, navigation_generation, &cancellation);
            })
        {
            clear_remote_attachment_registration(
                &self.scene.runtime,
                &host_id,
                navigation_generation,
            );
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
            &self.scene.runtime,
            self.scene.id,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
        )?;
        let scene = Arc::clone(&self.scene);
        let host_id = request.host_id.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-tmux-attach".to_owned())
            .spawn(move || {
                run_remote_tmux_attach(&scene, &request, navigation_generation, &cancellation);
            })
        {
            clear_remote_attachment_registration(
                &self.scene.runtime,
                &host_id,
                navigation_generation,
            );
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
            &self.scene.runtime,
            self.scene.id,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            navigation_generation,
            &cancellation,
        )?;
        let scene = Arc::clone(&self.scene);
        let host_id = request.host_id.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-remote-herdr-attach".to_owned())
            .spawn(move || {
                run_remote_herdr_attach(&scene, &request, navigation_generation, &cancellation);
            })
        {
            clear_remote_attachment_registration(
                &self.scene.runtime,
                &host_id,
                navigation_generation,
            );
            return Err(WorkspaceError::new(format!(
                "start remote Herdr attachment task: {error}"
            )));
        }
        Ok(())
    }

    fn reserve_remote_constructive(&self) -> Result<(), WorkspaceError> {
        self.scene
            .runtime
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
        navigation: NavigationFence<'_>,
    ) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let operation_key = request.operation_key();
        if !self
            .scene
            .runtime
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
                finish_herdr_launch(&self.scene.runtime, &operation_key);
                return Err(error);
            }
        };
        let visible_previous = match self.retain_active_presentation() {
            Ok(previous) => previous,
            Err(error) => {
                finish_herdr_launch(&self.scene.runtime, &operation_key);
                return Err(error);
            }
        };
        let previous = in_flight_fallback.or(visible_previous);
        let cancellation = CancellationToken::new();
        *self
            .scene
            .pending_creation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(PendingCreation {
            navigation_generation,
            previous: previous.clone(),
            cancellation: cancellation.clone(),
            herdr_operation: Some(operation_key),
        });
        clear_terminal_notice(&self.scene);
        set_scene_state(
            &self.scene,
            WorkspaceContent::Attaching {
                host_id: request.host_id.clone(),
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.as_str().to_owned(),
                kind: SessionKind::Herdr,
            },
        );

        let scene = Arc::clone(&self.scene);
        let spawn_request = request.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-herdr-launch".to_owned())
            .spawn(move || {
                run_herdr_create(&scene, &spawn_request, navigation_generation, &cancellation);
            })
        {
            drop(navigation);
            restore_inventory_after_creation_failure(
                &self.scene,
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
        begin_scene_navigation(&self.scene)
    }

    #[must_use]
    pub fn navigation_intent_is_current(&self, generation: u64) -> bool {
        self.scene.navigation_generation.load(Ordering::Acquire) == generation
    }

    fn retained_key_for_selection(&self, selection: &SessionSelection) -> Option<PresentationKey> {
        self.scene
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
        choose_navigation_target(retained, capture_attach_request(&self.scene, selection))
    }

    fn supersede_inflight_attachment(&self) -> Result<Option<PresentationKey>, WorkspaceError> {
        let mut attachment = self
            .scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let attaching = matches!(
            *self
                .scene
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
                .scene
                .pending_creation
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take()
                .ok_or_else(|| {
                    WorkspaceError::new("the in-flight terminal presentation is not available")
                })?;
            pending.cancellation.cancel();
            finish_pending_creation(&self.scene.runtime, &pending);
            pending.previous
        };
        clear_pending_paste(&self.scene);
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
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let mut attachment = self
            .scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active_attachment) = attachment.active() else {
            return Ok(None);
        };
        let selection = active_attachment.request.selection();
        let presentation_id = {
            let state = self
                .scene
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
            .scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if worker.active().is_none() {
            return Err(WorkspaceError::new(
                "the active terminal presentation is not available",
            ));
        }

        let active_attachment = attachment
            .take_active()
            .expect("active attachment was checked");
        let key = active_attachment.request.presentation_key();
        let active_worker = worker.invalidate().expect("active worker was checked");
        drop(worker);
        retire_clipboard_writes(&self.scene, &active_worker);
        let _cancelled = active_worker.cancel_paste();
        clear_pending_paste(&self.scene);
        clear_terminal_notice(&self.scene);
        insert_retained_presentation(
            &self.scene.runtime,
            &self.scene.retained_presentations,
            RetainedPresentation {
                key: key.clone(),
                selection: selection.clone(),
                attachment: active_attachment,
                worker: active_worker,
                presentation_id,
            },
        );
        self.restore_inventory_state();
        drop(attachment);
        Ok(Some(key))
    }

    fn activate_retained_presentation(
        &self,
        key: &PresentationKey,
        fallback: Option<FallbackAuthority>,
    ) -> Result<bool, WorkspaceError> {
        activate_retained_presentation(&self.scene, key, fallback)
    }

    fn start_attachment(
        &self,
        request: AttachRequest,
        fallback: Option<FallbackAuthority>,
        navigation_generation: u64,
    ) -> Result<(), WorkspaceError> {
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let generation;
        {
            let mut attachment = self
                .scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut state = self
                .scene
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
            clear_terminal_notice(&self.scene);
            *state = WorkspaceContent::Attaching {
                host_id: request.host_id.clone(),
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.clone(),
                kind: request.target.kind(),
            };
        }
        bump_scene_revision(&self.scene);
        let scene = Arc::clone(&self.scene);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-attach".to_owned())
            .spawn(move || {
                run_attach(&scene, &request, AttachTerm::Xterm256Color, generation);
            })
        {
            let mut attachment = self
                .scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some((_, fallback)) =
                failed_attachment_context(&self.scene, &attachment, generation)
            {
                let fallback = fallback
                    .filter(|fallback| fallback.navigation_generation == navigation_generation);
                attachment.clear_if_current(generation);
                drop(attachment);
                self.restore_inventory_state();
                restore_attach_fallback_locked(&self.scene, fallback);
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
            .scene
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
            .scene
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
        // Fenced and held through the worker confirmation: closure either
        // follows a fully delivered approval or the approval fails closed —
        // the close path's paste deny can no longer interleave with an
        // approval it then cannot see.
        let _navigation = lock_live_navigation(&self.scene)?;
        let paste = self
            .scene
            .pending_paste
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            .ok_or_else(|| WorkspaceError::new("no paste is awaiting confirmation"))?;
        let worker = self
            .scene
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
        cancel_pending_paste(&self.scene);
    }

    /// Query one session's live identity before exposing destructive
    /// confirmation to the presentation layer.
    ///
    /// # Errors
    ///
    /// Returns an error when the selection is not part of the current WSL
    /// inventory or the background query cannot be started.
    pub fn request_session_kill(&self, selection: &SessionSelection) -> Result<(), WorkspaceError> {
        // Destructive confirmations are constructive entries: a retained
        // handle of a closed scene must not re-arm a kill after the close
        // invalidated its confirmations.
        let _navigation = lock_live_navigation(&self.scene)?;
        let generation = invalidate_pending_kill(&self.scene);
        invalidate_pending_herdr_lifecycle(&self.scene);
        let request = capture_kill_request(&self.scene, selection, generation)?;
        if let KillCaptureRequest::Zellij(pending) = request {
            if !publish_pending_kill(&self.scene, pending) {
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
        // Record the capture's target before the task starts so a kill of
        // the same session completing mid-capture can fence the late
        // publication. Registration re-checks the fence under the slot
        // lock, so an overlapping newer request cannot lose its intent to
        // this one.
        register_kill_capture_intent(&self.scene, generation, &selection);
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
                            &workspace.scene,
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
                            .scene
                            .pending_kill
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        if workspace.scene.kill_generation.load(Ordering::Acquire) != generation {
                            return;
                        }
                        workspace.push_operation_error(error.to_string());
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
            .scene
            .pending_kill
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let generation = self.scene.kill_generation.load(Ordering::Acquire);
        pending_kill
            .as_ref()
            .filter(|pending| pending.generation == generation)
            .map(|pending| SessionKillConfirmation {
                selection: pending.selection.clone(),
            })
    }

    pub fn cancel_session_kill(&self) {
        invalidate_pending_kill(&self.scene);
    }

    /// Execute the identity-guarded kill approved by the user.
    ///
    /// # Errors
    ///
    /// Returns an error when no live confirmation is pending or the kill task
    /// cannot be started.
    pub fn confirm_session_kill(&self) -> Result<(), WorkspaceError> {
        // Held through scheduling: when closure wins this race, the fence
        // refuses before any host command is queued.
        let _navigation = lock_live_navigation(&self.scene)?;
        let pending = self
            .scene
            .pending_kill
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            .ok_or_else(|| WorkspaceError::new("no session kill is awaiting confirmation"))?;
        if self.scene.kill_generation.load(Ordering::Acquire) != pending.generation {
            return Err(WorkspaceError::new(
                "session kill confirmation is no longer current",
            ));
        }
        bump_scene_revision(&self.scene);
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
                    .scene
                    .runtime
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
                let _refresh_started = workspace.refresh_reanchored();
                workspace
                    .scene
                    .runtime
                    .revision
                    .fetch_add(1, Ordering::Release);
            })
        {
            *self
                .scene
                .pending_kill
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(retry);
            bump_scene_revision(&self.scene);
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
        // Same closed-scene fence as session kills.
        let _navigation = lock_live_navigation(&self.scene)?;
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let generation = invalidate_pending_herdr_lifecycle(&self.scene);
        self.cancel_session_kill();
        let pending = capture_herdr_lifecycle(&self.scene, selection, action, generation)?;
        let lifecycle = self
            .scene
            .runtime
            .herdr_lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut pending_slot = self
            .scene
            .pending_herdr_lifecycle
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
            .scene
            .herdr_lifecycle_generation
            .load(Ordering::Acquire)
            != generation
        {
            return Err(WorkspaceError::new(
                "Herdr lifecycle request is no longer current",
            ));
        }
        *pending_slot = Some(pending);
        drop(pending_slot);
        drop(lifecycle);
        bump_scene_revision(&self.scene);
        Ok(())
    }

    #[must_use]
    pub fn herdr_lifecycle_confirmation(&self) -> Option<HerdrLifecycleConfirmation> {
        let generation = self
            .scene
            .herdr_lifecycle_generation
            .load(Ordering::Acquire);
        self.scene
            .pending_herdr_lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|pending| pending.generation == generation)
            .map(|pending| HerdrLifecycleConfirmation {
                selection: pending.selection.clone(),
                action: pending.action,
            })
    }

    pub fn cancel_herdr_lifecycle(&self) {
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        invalidate_pending_herdr_lifecycle(&self.scene);
    }

    /// Execute the confirmed, freshly revalidated Herdr mutation.
    ///
    /// # Errors
    ///
    /// Returns an error when no confirmation is pending or the lifecycle task
    /// cannot be started.
    pub fn confirm_herdr_lifecycle(&self) -> Result<(), WorkspaceError> {
        // Held through scheduling, mirroring confirm_session_kill.
        let _navigation = lock_live_navigation(&self.scene)?;
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let mut lifecycle = self
            .scene
            .runtime
            .herdr_lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut pending_slot = self
            .scene
            .pending_herdr_lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let pending = pending_slot.take().ok_or_else(|| {
            WorkspaceError::new("no Herdr lifecycle action is awaiting confirmation")
        })?;
        if self
            .scene
            .herdr_lifecycle_generation
            .load(Ordering::Acquire)
            != pending.generation
        {
            return Err(WorkspaceError::new(
                "Herdr lifecycle confirmation is no longer current",
            ));
        }
        if let Err(error) = require_host_session_actions(&self.scene.runtime, &pending.selection) {
            *pending_slot = Some(pending);
            return Err(error);
        }
        if !lifecycle.start(&pending) {
            return Err(WorkspaceError::new(
                "a lifecycle action is already running for this Herdr session",
            ));
        }
        drop(pending_slot);
        drop(lifecycle);
        self.scene.runtime.revision.fetch_add(1, Ordering::Release);
        let workspace = self.clone();
        let retry = pending.clone();
        if let Err(error) = thread::Builder::new()
            .name(format!("ghosthub-herdr-{}", pending.action.command()))
            .spawn(move || run_herdr_lifecycle(&workspace, &pending))
        {
            let mut lifecycle = self
                .scene
                .runtime
                .herdr_lifecycle
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut pending_slot = self
                .scene
                .pending_herdr_lifecycle
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            lifecycle.finish(retry.operation_id);
            if self
                .scene
                .herdr_lifecycle_generation
                .load(Ordering::Acquire)
                == retry.generation
                && pending_slot.is_none()
            {
                *pending_slot = Some(retry);
            }
            drop(pending_slot);
            drop(lifecycle);
            self.scene.runtime.revision.fetch_add(1, Ordering::Release);
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
        scene::push_operation_event(&self.scene, event);
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

    /// Close every scene's active and retained presentations of one killed
    /// tmux session; the kill is a host-wide fact.
    fn finish_killed_presentation(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        identity: &session::SessionIdentity,
        target_name: &str,
        socket_name: Option<&str>,
    ) {
        // The session is gone, so a pending kill confirmation for it in any
        // scene is stale, and an in-flight identity capture for it must not
        // publish one; unrelated confirmations stay valid.
        drop_matching_kill_confirmations(
            &self.scene.runtime,
            |pending| match &pending.target {
                KillTarget::Tmux(target) => {
                    target.endpoint() == endpoint
                        && target.runtime() == runtime
                        && target.identity() == identity
                }
                KillTarget::Zellij { .. } => false,
            },
            |selection| {
                selection.kind() == SessionKind::Tmux
                    && selection.endpoint() == endpoint.distro()
                    && selection.session() == target_name
                    && selection.tmux_socket_name() == socket_name
            },
        );
        for_each_scene(&self.scene.runtime, |scene| {
            Self {
                scene: Arc::clone(scene),
            }
            .finish_killed_presentation_in_scene(
                endpoint,
                runtime,
                identity,
                target_name,
                socket_name,
            );
        });
    }

    fn finish_killed_presentation_in_scene(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        identity: &session::SessionIdentity,
        target_name: &str,
        socket_name: Option<&str>,
    ) {
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let _navigation = self
            .scene
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
            .scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some_and(|active| key_matches(&active.request));
        if active_matches {
            self.detach_locked();
        }
        let changed = self
            .scene
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
            bump_scene_revision(&self.scene);
        }
    }

    /// Close every scene's active and retained presentations of one killed
    /// Zellij session; the kill is a host-wide fact.
    fn finish_zellij_presentation(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        name: &str,
    ) {
        // As for killed tmux sessions: the killed Zellij session's pending
        // confirmations are stale in every scene.
        drop_matching_confirmations(
            &self.scene.runtime,
            |scene| &scene.pending_kill,
            |pending| {
                matches!(
                    &pending.target,
                    KillTarget::Zellij {
                        endpoint: pending_endpoint,
                        runtime: pending_runtime,
                        name: pending_name,
                        ..
                    } if pending_endpoint == endpoint
                        && pending_runtime == runtime
                        && pending_name == name
                )
            },
        );
        for_each_scene(&self.scene.runtime, |scene| {
            Self {
                scene: Arc::clone(scene),
            }
            .finish_zellij_presentation_in_scene(endpoint, runtime, name);
        });
    }

    fn finish_zellij_presentation_in_scene(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        name: &str,
    ) {
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let _navigation = self
            .scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let target_matches = |target: &AttachTarget| matches!(target, AttachTarget::Zellij { name: target_name, .. } if target_name == name);
        let active_matches = self
            .scene
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
            .scene
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove_matching(|key| {
                key.endpoint == endpoint.distro()
                    && key.runtime == *runtime
                    && target_matches(&key.target)
            });
        if changed {
            bump_scene_revision(&self.scene);
        }
    }

    fn close_zellij_presentations(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        name: &str,
    ) -> Option<SuppressedZellijPresentation> {
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let _navigation = self
            .scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let navigation_generation = self.scene.navigation_generation.load(Ordering::Acquire);
        let target_matches = |target: &AttachTarget| matches!(target, AttachTarget::Zellij { name: target_name, .. } if target_name == name);
        let mut attachment = self
            .scene
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
            self.scene
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .invalidate();
            clear_pending_paste(&self.scene);
            clear_terminal_notice(&self.scene);
            self.restore_inventory_state();
        }
        drop(attachment);

        let removed = self
            .scene
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
            bump_scene_revision(&self.scene);
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
        self.restore_suppressed_presentation(
            suppressed.retained,
            suppressed.active_selection,
            suppressed.navigation_generation,
            "could not restore a retained Zellij presentation after a failed kill",
            "could not restore the Zellij presentation after a failed kill",
        );
    }

    /// Restore one suppressed presentation after a failed destructive
    /// backend operation: reopen the suppressed retained presentation,
    /// then restore the suppressed active selection under the navigation
    /// lock and its captured navigation generation.
    ///
    /// The closed-scene fence lives here, once for every backend. A closed
    /// scene's presentation dies with it — the failed operation leaves the
    /// session alive host-side, but nothing may be resurrected in a dead
    /// scene. This early return skips the reopen entirely;
    /// `publish_restored_retained_presentation` re-checks under the
    /// retained lock, closing the race window this check alone leaves, and
    /// the active-selection branch is fenced by the navigation generation
    /// the close advanced.
    fn restore_suppressed_presentation(
        &self,
        retained: Option<ClosedRetainedPresentation>,
        active_selection: Option<SessionSelection>,
        navigation_generation: u64,
        retained_failure: &str,
        active_failure: &str,
    ) {
        if self.scene.closed.load(Ordering::Acquire) {
            return;
        }
        if let Some(retained) = retained {
            match reopen_closed_retained_presentation(&self.scene, retained) {
                Ok(presentation) => {
                    publish_restored_retained_presentation(&self.scene, presentation);
                }
                Err(error) => {
                    self.push_operation_error(format!("{retained_failure}: {error}"));
                }
            }
        }
        let Some(selection) = active_selection else {
            return;
        };
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let _navigation = self
            .scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self.scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            return;
        }
        if let Err(error) = self.switch_session_locked(&selection) {
            self.push_operation_error(format!("{active_failure}: {error}"));
        }
    }

    /// Close every scene's active and retained presentations of one Herdr
    /// session that stopped or was deleted; the transition is a host-wide
    /// fact.
    fn finish_herdr_presentation(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        record: &session::HerdrSessionRecord,
    ) {
        // The Herdr session's lifecycle just changed host-wide, so a pending
        // Stop or Delete confirmation for it in any scene is stale.
        drop_matching_confirmations(
            &self.scene.runtime,
            |scene| &scene.pending_herdr_lifecycle,
            |pending| {
                pending.endpoint == *endpoint
                    && pending.runtime == *runtime
                    && pending.record.name() == record.name()
            },
        );
        for_each_scene(&self.scene.runtime, |scene| {
            Self {
                scene: Arc::clone(scene),
            }
            .finish_herdr_presentation_in_scene(endpoint, runtime, record);
        });
    }

    fn finish_herdr_presentation_in_scene(
        &self,
        endpoint: &host::WslEndpoint,
        runtime: &host::WslRuntimeIdentity,
        record: &session::HerdrSessionRecord,
    ) {
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let _navigation = self
            .scene
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
            .scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some_and(|active| key_matches(&active.request));
        if active_matches {
            self.detach_locked();
        }
        let changed = self
            .scene
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove_matching(|key| {
                key.endpoint == endpoint.distro()
                    && key.runtime == *runtime
                    && key.target.herdr_matches(record)
            });
        if changed {
            bump_scene_revision(&self.scene);
        }
    }

    fn close_herdr_presentations(
        &self,
        pending: &PendingHerdrLifecycle,
    ) -> Option<SuppressedHerdrPresentation> {
        let _snapshot_write = begin_snapshot_write(&self.scene.runtime);
        let _navigation = self
            .scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let navigation_generation = self.scene.navigation_generation.load(Ordering::Acquire);
        let mut attachment = self
            .scene
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
            self.scene
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .invalidate();
            clear_pending_paste(&self.scene);
            clear_terminal_notice(&self.scene);
            self.restore_inventory_state();
        }
        drop(attachment);

        let removed = self
            .scene
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
            bump_scene_revision(&self.scene);
        }
        (active_selection.is_some() || retained.is_some()).then_some(SuppressedHerdrPresentation {
            scene_id: self.scene.id,
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
        self.restore_suppressed_presentation(
            suppressed.retained,
            suppressed.active_selection,
            suppressed.navigation_generation,
            "could not restore a retained Herdr presentation after a failed lifecycle action",
            "could not restore the Herdr presentation after a failed lifecycle action",
        );
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
                .scene
                .terminal_geometry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            geometry.grid = size;
            geometry.pixels = PixelSize::new(pixel_width, pixel_height);
            geometry.sequence = geometry.sequence.saturating_add(1);
            *geometry
        };
        if let Some(worker) = self
            .scene
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
        self.send_clipboard_response(request.worker_generation(), request.respond(contents))
    }

    /// Queue a response produced by an authorized local OSC 52 read.
    ///
    /// # Errors
    ///
    /// Returns an error when no terminal is active, its worker stopped,
    /// bounded input delivery is applying backpressure, or the response's
    /// originating worker was retired — the stale case is marked
    /// [`WorkspaceError::is_stale_input`] and should be dropped silently.
    pub fn send_clipboard_response(
        &self,
        worker_generation: u64,
        bytes: Vec<u8>,
    ) -> Result<(), WorkspaceError> {
        let worker = self
            .scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // Same fencing as paste confirmation: a response bound to a worker
        // navigation retired must never be typed into its successor.
        if worker.generation() != worker_generation {
            return Err(WorkspaceError::stale_input(
                "clipboard response belongs to a closed terminal",
            ));
        }
        worker
            .active()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .send_bytes(bytes)
            .map_err(|error| WorkspaceError::from_worker(&error))
    }

    pub fn detach(&self) {
        let _navigation = self
            .scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.detach_locked();
    }

    fn detach_locked(&self) {
        detach_scene_locked(&self.scene);
    }

    /// Close this scene: unregister it from the runtime, tear down its
    /// presentations and workers, release its remote leases, fence its
    /// pending confirmations, and cancel every outstanding addressed
    /// request fail-closed — blocked operations it initiated fail with
    /// their established cancellation errors and are never reassigned to
    /// another scene. This is the lifecycle end of a scene opened with
    /// [`Workspace::open_scene`]; a scene never closed explicitly closes
    /// when its last handle drops. Idempotent. Other scenes are untouched
    /// and may explicitly retry the cancelled operations from scratch.
    pub fn close(&self) {
        release_scene(&self.scene);
    }

    /// Read this scene's queued events. Lane-1 work — worker polling, exit
    /// classification, and lease monitoring — happens on the runtime event
    /// pump, never here: this is a cheap read of the scene's inbox, safe to
    /// call from a UI thread at frame cadence.
    #[must_use]
    pub fn drain_events(&self) -> (Vec<WorkspaceEvent>, bool) {
        let mut inbox = self
            .scene
            .operation_events
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let take = inbox.len().min(MAX_EVENTS_PER_DRAIN);
        let emitted = inbox.drain(..take).map(|entry| entry.event).collect();
        (emitted, !inbox.is_empty())
    }

    #[allow(
        clippy::too_many_lines,
        reason = "the runtime/scene split lengthens shared-state paths without adding logic"
    )]
    fn start_refresh(
        &self,
        config: WslConfig,
        executable: Option<WslExecutable>,
        presentation: RefreshPresentation,
    ) {
        let scene = Arc::clone(&self.scene);
        let cancellation = CancellationToken::new();
        let generation = begin_refresh(&scene, &cancellation, presentation);
        let deadline_scene = Arc::clone(&scene);
        let deadline_cancellation = cancellation.clone();
        if let Err(error) = scene.runtime.refresh_runtime.spawn_after(
            "ghosthub-wsl-refresh-deadline",
            refresh_budget(generation),
            deadline_cancellation.clone(),
            Box::new(move || {
                expire_refresh(&deadline_scene, generation, &deadline_cancellation);
            }),
        ) {
            fail_refresh_start(
                &scene,
                generation,
                &cancellation,
                "schedule WSL refresh deadline",
                &error,
            );
            return;
        }
        let discovery = Arc::clone(&scene.runtime.discovery);
        let existing_host = scene
            .runtime
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map(|published| published.value.host.clone());
        let task_scene = Arc::clone(&scene);
        let task_cancellation = cancellation.clone();
        let spawn_result = scene.runtime.refresh_runtime.spawn(
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
                let published = publish_refresh(&task_scene.runtime, generation, || {
                    if task_cancellation.is_cancelled() {
                        return;
                    }
                    match resolved {
                        Ok(context) => {
                            delayed_recoveries =
                                publish_discovered_host(&task_scene, context, generation);
                        }
                        Err(error) => {
                            set_wsl_host_unavailable(
                                &task_scene.runtime,
                                error.kind(),
                                error.to_string(),
                            );
                        }
                    }
                    task_scene
                        .runtime
                        .refresh_finished
                        .store(generation, Ordering::Release);
                });
                if published && let Some((snapshot, socket_directory)) = reconciliation {
                    reconcile_presentation_session_names(
                        &task_scene.runtime,
                        generation,
                        &snapshot,
                        socket_directory.as_deref(),
                    );
                }
                task_cancellation.cancel();
                if published {
                    Self::restore_delayed_herdr_presentations(&task_scene, delayed_recoveries);
                    start_initial_kwt_refresh(&task_scene);
                }
            }),
        );
        if let Err(error) = spawn_result {
            fail_refresh_start(
                &scene,
                generation,
                &cancellation,
                "start WSL discovery task",
                &error,
            );
        }
    }

    fn restore_delayed_herdr_presentations(
        scene: &Arc<Scene>,
        recoveries: Vec<SuppressedHerdrPresentation>,
    ) {
        if recoveries.is_empty() {
            return;
        }
        let _operation = scene
            .runtime
            .session_operations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for suppressed in recoveries {
            // The releasing refresh may run on any scene; the recovery
            // lands only on its owner. A closed owner's recovery is
            // dropped — the retained worker's Drop reaps its client.
            let Some(owner) = scene_by_id(&scene.runtime, suppressed.scene_id) else {
                continue;
            };
            let workspace = Self { scene: owner };
            workspace.restore_suppressed_herdr_presentation(Some(suppressed));
        }
    }

    fn restore_inventory_state(&self) {
        restore_scene_inventory_state(&self.scene);
    }
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
    /// The scene whose dialog owns this listing: only it may cancel, and
    /// closing it cancels the listing and frees the shared KWT lane.
    scene_id: SceneId,
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
    /// The scene whose `NewWorktree` dialog blocks on this creation; its
    /// settlement events are delivered losslessly to exactly this scene.
    scene: SceneId,
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
    scene: SceneId,
    task: &KwtWorktreeTask,
    branch: &str,
    navigation_generation: u64,
    baseline: Vec<KwtWorktreeIdentity>,
) -> PendingKwtCreation {
    PendingKwtCreation {
        scene,
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

const fn refresh_budget(generation: u64) -> Duration {
    if generation == 1 {
        Duration::from_secs(45)
    } else {
        Duration::from_secs(30)
    }
}

struct RemoteConstructiveReset<'a> {
    scene: &'a Scene,
    host_id: &'a str,
    navigation_generation: u64,
}

struct RemoteAttachmentReset<'a> {
    scene: &'a Scene,
    host_id: &'a str,
    navigation_generation: u64,
}

impl Drop for RemoteAttachmentReset<'_> {
    fn drop(&mut self) {
        clear_remote_attachment_registration(
            &self.scene.runtime,
            self.host_id,
            self.navigation_generation,
        );
    }
}

impl Drop for RemoteConstructiveReset<'_> {
    fn drop(&mut self) {
        let _pending = settle_remote_constructive_task(
            &self.scene.runtime,
            self.host_id,
            self.navigation_generation,
            false,
        );
        self.scene
            .runtime
            .remote_constructive_in_flight
            .store(false, Ordering::Release);
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

/// Cancel every scene's attach attempt on this entry. Only
/// connection-authority transitions (disconnect, reconnect, removal,
/// connection failure) may use this; scene-initiated cancellation goes
/// through `cancel_scene_remote_attachments`.
fn cancel_remote_attachment(entry: &mut RemoteEntry) {
    for attempt in entry.attachment_attempts.drain(..) {
        attempt.cancellation.cancel();
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

fn lock_session_operations<'a>(
    scene: &'a Scene,
    cancellation: &CancellationToken,
) -> Option<std::sync::MutexGuard<'a, ()>> {
    loop {
        match scene.runtime.session_operations.try_lock() {
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

fn run_herdr_lifecycle(workspace: &Workspace, pending: &PendingHerdrLifecycle) {
    let _operation = workspace
        .scene
        .runtime
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
            reserve_constructive_inventory(&workspace.scene.runtime);
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
            if let Err(error) = publish_herdr_lifecycle_response(&workspace.scene, pending, record)
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
                finish_herdr_lifecycle_state(&workspace.scene.runtime, pending.operation_id);
                let _reconciled = reconcile_herdr_lifecycle_inventory(&workspace.scene, pending);
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
    match reconcile_herdr_lifecycle_inventory(&workspace.scene, pending) {
        Ok(snapshot) => {
            finish_herdr_lifecycle_state(&workspace.scene.runtime, pending.operation_id);
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
            publish_herdr_lifecycle_uncertain(
                &workspace.scene.runtime,
                pending,
                suppressed,
                &message,
            );
            workspace.push_operation_error(message);
        }
    }
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

fn default_colors(appearance: &Appearance) -> DefaultColors {
    DefaultColors::new(rgb(appearance.foreground()), rgb(appearance.background()))
}

pub(crate) fn current_default_colors(runtime: &Runtime) -> DefaultColors {
    let appearance = runtime
        .appearance
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    default_colors(&appearance)
}

pub(crate) fn current_default_cursor_shape(runtime: &Runtime) -> CursorShape {
    runtime.cursor_default.load()
}

/// Push the new default cursor shape to every live worker across every
/// scene; existing surfaces reflect the setting without a restart.
fn update_default_cursor_shapes(initiator: &Arc<Scene>, shape: CursorShape) {
    for scene in live_scenes(&initiator.runtime) {
        if let Some(worker) = scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
        {
            worker.set_default_cursor_shape(shape);
        }
        {
            let retained = scene
                .retained_presentations
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for presentation in &retained.entries {
                presentation.worker.set_default_cursor_shape(shape);
            }
        }
        let remote = scene
            .remote_retained
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for presentation in &remote.entries {
            presentation.worker.set_default_cursor_shape(shape);
        }
    }
}

pub(crate) fn insert_retained_presentation(
    runtime: &Runtime,
    retained: &Mutex<crate::RetainedPresentations<TerminalWorker>>,
    presentation: RetainedPresentation<TerminalWorker>,
) {
    let mut retained = retained
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    presentation
        .worker
        .set_default_cursor_shape(current_default_cursor_shape(runtime));
    retained.insert(presentation);
}

pub(crate) fn insert_remote_retained_presentation(
    runtime: &Runtime,
    retained: &Mutex<crate::RemoteRetainedPresentations>,
    presentation: RemoteRetainedPresentation,
) {
    let mut retained = retained
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    presentation
        .worker
        .set_default_cursor_shape(current_default_cursor_shape(runtime));
    retained.insert(presentation);
}

pub(crate) fn reconcile_active_worker_cursor(
    runtime: &Runtime,
    workers: &WorkerState<TerminalWorker>,
) {
    workers
        .active()
        .expect("worker was published before cursor reconciliation")
        .set_default_cursor_shape(current_default_cursor_shape(runtime));
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
mod tests;
