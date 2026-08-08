//! Application workflow and capability boundary for GPUI.

use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::Duration;

use config::TerminalAppearance;
use host::{
    AdmissionAttacher, AttachTerm, CancellationToken, CommandRunner, HostError, HostSnapshot,
    StdCommandRunner, WslConfig, WslExecutable, WslHost,
};
pub use input::{KeyEvent, KeyInput, Modifiers, MouseAction, MouseButton, MouseInput, NamedKey};
use model::DiagnosticKind;
use surface::{GridSize, PixelSize, Rgb, SurfaceStore};
use terminal::{
    ClipboardPolicy, ClipboardReadRequest as TerminalClipboardRead, ClipboardTarget, DefaultColors,
    TerminalEvent, TerminalWorker,
};

const REDUCED_COLOR_NOTICE: &str =
    "Using TERM=xterm because xterm-256color terminfo is unavailable in WSL";

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
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostConnectionState {
    Disconnected,
    Connecting,
    Ready,
    Unavailable,
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
        }
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
    },
    Terminal {
        host_id: String,
        endpoint: String,
        session: String,
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
    ClipboardWrite { text: String, primary: bool },
    ClipboardRead(ClipboardRead),
    ConfirmPaste,
    Error(String),
}

const MAX_EVENTS_PER_DRAIN: usize = 32;

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
        cancellation: &CancellationToken,
    ) -> Result<HostContext, HostError> {
        let host = WslHost::new(config, Arc::clone(&self.runner), executable);
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

#[derive(Clone)]
struct AttachRequest {
    host_id: String,
    host: RuntimeHost,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    identity: session::SessionIdentity,
    name: String,
    inventory_generation: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PresentationKey {
    host_id: String,
    endpoint: String,
    socket_directory: Option<String>,
    runtime: host::WslRuntimeIdentity,
    identity: session::SessionIdentity,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FallbackAuthority {
    presentation: PresentationKey,
    navigation_generation: u64,
}

impl AttachRequest {
    fn presentation_key(&self) -> PresentationKey {
        PresentationKey {
            host_id: self.host_id.clone(),
            endpoint: self.endpoint.distro().to_owned(),
            socket_directory: self.host.socket_directory().map(str::to_owned),
            runtime: self.runtime.clone(),
            identity: self.identity.clone(),
        }
    }
}

enum AttachFreshError {
    Host(WorkspaceError),
    SessionChanged {
        error: WorkspaceError,
        snapshot: HostSnapshot,
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
                presentation.selection = SessionSelection::new(
                    &presentation.key.host_id,
                    presentation.key.endpoint.clone(),
                    name,
                );
                presentation.attachment.request.name = name.to_owned();
                changed = true;
            }
        }
        for presentation in &mut self.restarting {
            if let Some(name) =
                refreshed_session_name(&presentation.key, snapshot, socket_directory)
                && name != presentation.attachment.request.name
            {
                presentation.selection = SessionSelection::new(
                    &presentation.key.host_id,
                    presentation.key.endpoint.clone(),
                    name,
                );
                presentation.attachment.request.name = name.to_owned();
                changed = true;
            }
        }
        changed
    }

    fn finish_restart(&mut self, key: &PresentationKey, worker: T) -> bool {
        let Some(index) = self.restarting.iter().position(|entry| &entry.key == key) else {
            return false;
        };
        let restart = self.restarting.remove(index);
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

fn refreshed_session_name<'a>(
    key: &PresentationKey,
    snapshot: &'a HostSnapshot,
    socket_directory: Option<&str>,
) -> Option<&'a str> {
    (key.host_id == "wsl"
        && key.endpoint == snapshot.endpoint().distro()
        && key.socket_directory.as_deref() == socket_directory
        && key.runtime == *snapshot.runtime())
    .then(|| {
        snapshot
            .sessions()
            .iter()
            .find(|session| session.identity() == &key.identity)
            .map(session::DiscoveredSession::name)
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
                Ok(Some(TerminalEvent::ClipboardWrite(_) | TerminalEvent::ClipboardRead(_))) => {
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
    presentation_generation: AtomicU64,
    navigation_generation: AtomicU64,
    navigation: Mutex<()>,
    host: Mutex<Option<Published<HostContext>>>,
    discovery_cancel: Mutex<Option<CancellationToken>>,
    event_drain: Mutex<()>,
    worker: Mutex<WorkerState<TerminalWorker>>,
    retained_presentations: Mutex<RetainedPresentations<TerminalWorker>>,
    pending_paste: Mutex<Option<PendingPaste>>,
    terminal_geometry: Mutex<TerminalGeometry>,
    allow_remote_clipboard_write: bool,
    refresh_generation: AtomicU64,
    refresh_finished: AtomicU64,
    refresh_publication: Mutex<()>,
    discovery: Arc<dyn WslDiscovery>,
    refresh_runtime: Arc<dyn RefreshRuntime>,
    attachment: Mutex<AttachmentState<AttachRequest>>,
    terminal_notice: RwLock<Option<String>>,
}

#[derive(Clone)]
pub struct Workspace {
    inner: Arc<Inner>,
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
                presentation_generation: AtomicU64::new(presentation_generation),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                event_drain: Mutex::new(()),
                worker: Mutex::new(WorkerState::new()),
                retained_presentations: Mutex::new(RetainedPresentations::new()),
                pending_paste: Mutex::new(None),
                terminal_geometry: Mutex::new(default_terminal_geometry()),
                allow_remote_clipboard_write: true,
                refresh_generation: AtomicU64::new(0),
                refresh_finished: AtomicU64::new(0),
                refresh_publication: Mutex::new(()),
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
                presentation_generation: AtomicU64::new(0),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                event_drain: Mutex::new(()),
                worker: Mutex::new(WorkerState::new()),
                retained_presentations: Mutex::new(RetainedPresentations::new()),
                pending_paste: Mutex::new(None),
                terminal_geometry: Mutex::new(default_terminal_geometry()),
                allow_remote_clipboard_write,
                refresh_generation: AtomicU64::new(0),
                refresh_finished: AtomicU64::new(0),
                refresh_publication: Mutex::new(()),
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
                presentation_generation: AtomicU64::new(0),
                navigation_generation: AtomicU64::new(0),
                navigation: Mutex::new(()),
                host: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                event_drain: Mutex::new(()),
                worker: Mutex::new(WorkerState::new()),
                retained_presentations: Mutex::new(RetainedPresentations::new()),
                pending_paste: Mutex::new(None),
                terminal_geometry: Mutex::new(default_terminal_geometry()),
                allow_remote_clipboard_write,
                refresh_generation: AtomicU64::new(0),
                refresh_finished: AtomicU64::new(0),
                refresh_publication: Mutex::new(()),
                discovery: Arc::new(SystemWslDiscovery::new()),
                refresh_runtime: Arc::new(ThreadRefreshRuntime),
                attachment: Mutex::new(AttachmentState::new()),
                terminal_notice: RwLock::new(None),
            }),
        };
        workspace.start_refresh(config, None);
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
            self.start_refresh(config, executable);
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
        self.start_refresh(config, executable);
        Ok(())
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
        WorkspaceSnapshot {
            revision: self.inner.revision.load(Ordering::Acquire),
            appearance: self.inner.appearance.clone(),
            content: self
                .inner
                .state
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone(),
            hosts: self
                .inner
                .hosts
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone(),
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
        if let Some(key) = self.retained_key_for_selection(selection) {
            if self.activate_retained_presentation(&key, None)? {
                return Ok(());
            }
            return Err(WorkspaceError::new(
                "the retained terminal presentation is no longer available",
            ));
        }

        let request = capture_attach_request(&self.inner, selection)?;
        self.start_attachment(request, None, navigation_generation)
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
        let _navigation = self
            .inner
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let same_visible_selection = matches!(
            self.inner
                .state
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone(),
            WorkspaceContent::Terminal { host_id, endpoint, session, .. }
                if host_id == selection.host_id()
                    && endpoint == selection.endpoint()
                    && session == selection.session()
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

        let (key, request) = if let Some(key) = self.retained_key_for_selection(selection) {
            (key, None)
        } else {
            let request = capture_attach_request(&self.inner, selection)?;
            (request.presentation_key(), Some(request))
        };
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
            return Err(WorkspaceError::new(
                "the retained terminal presentation is no longer available",
            ));
        };
        self.start_attachment(request, fallback, navigation_generation)
    }

    fn begin_navigation(&self) -> u64 {
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
        let active = attachment.take_active().ok_or_else(|| {
            WorkspaceError::new("the in-flight terminal presentation is not available")
        })?;
        let fallback = active.fallback.map(|fallback| fallback.presentation);
        drop(attachment);
        clear_pending_paste(&self.inner);
        self.restore_inventory_state();
        Ok(fallback)
    }

    fn retain_active_presentation(&self) -> Result<Option<PresentationKey>, WorkspaceError> {
        let mut attachment = self
            .inner
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active_attachment) = attachment.active() else {
            return Ok(None);
        };
        let selection = SessionSelection::new(
            &active_attachment.request.host_id,
            active_attachment.request.endpoint.distro(),
            &active_attachment.request.name,
        );
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
        self.begin_navigation();
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
        let _drain = self
            .inner
            .event_drain
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut emitted = Vec::new();
        let mut exited = false;
        let mut exited_attachment = None;
        let mut exited_worker_generation = None;
        let mut exit_error = None;
        let mut retry_term = false;
        let mut processed = 0;
        for _ in 0..MAX_EVENTS_PER_DRAIN {
            let Some((event, source_worker_generation, client_confirmed_live)) =
                self.next_terminal_event()
            else {
                break;
            };
            match event {
                Ok(Some(TerminalEvent::ClipboardWrite(write))) => {
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
        let retained_budget = retained_event_budget(processed, exited);
        processed += self.drain_retained_events(retained_budget, &mut emitted);
        (emitted, event_drain_may_have_more(processed, exited))
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
        let fallback = fallback
            .filter(|fallback| fallback_owns_visible_request(&self.inner, fallback, &request));
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

    fn start_refresh(&self, config: WslConfig, executable: Option<WslExecutable>) {
        let inner = Arc::clone(&self.inner);
        let cancellation = CancellationToken::new();
        let generation = begin_refresh(&inner, &cancellation);
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
                            discovery.discover(config, executable, &task_cancellation)
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
                let published = publish_refresh(&task_inner, generation, || {
                    if task_cancellation.is_cancelled() {
                        return;
                    }
                    match resolved {
                        Ok(context) => {
                            let state = ready_content(&context.snapshot);
                            *task_inner
                                .host
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                                Some(Published::new(context, generation));
                            set_inventory_state(&task_inner, state);
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

fn activate_retained_presentation(
    inner: &Inner,
    key: &PresentationKey,
    fallback: Option<FallbackAuthority>,
) -> Result<bool, WorkspaceError> {
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
        .map(|active| {
            SessionSelection::new(
                &active.request.host_id,
                active.request.endpoint.distro(),
                &active.request.name,
            )
        })
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

const fn event_drain_may_have_more(processed: usize, exited: bool) -> bool {
    !exited && processed == MAX_EVENTS_PER_DRAIN
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
        let session = context
            .snapshot
            .sessions()
            .iter()
            .find(|session| session.name() == selection.session())
            .ok_or_else(|| WorkspaceError::new("session is not in the current inventory"))?;
        Ok(AttachRequest {
            host_id: selection.host_id().to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            identity: session.identity().clone(),
            name: session.name().to_owned(),
            inventory_generation,
        })
    })
}

fn begin_refresh(inner: &Inner, cancellation: &CancellationToken) -> u64 {
    let generation = reserve_refresh(inner, cancellation);
    publish_refresh(inner, generation, || {
        set_inventory_state(inner, WorkspaceContent::Loading);
    });
    generation
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

fn publish_refresh(inner: &Inner, generation: u64, publish: impl FnOnce()) -> bool {
    let _publication = inner
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if inner.refresh_generation.load(Ordering::Acquire) != generation {
        return false;
    }
    publish();
    true
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

fn run_attach(inner: &Inner, request: &AttachRequest, term: AttachTerm, generation: u64) {
    match attach_fresh(inner, request, term) {
        Ok((worker, snapshot, attached_session, initial_geometry)) => {
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
            let visible_request = attachment
                .active()
                .expect("current attachment was checked")
                .request
                .clone();
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
                    .filter(|fallback| {
                        fallback_owns_visible_request(inner, fallback, &visible_request)
                    });
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
                    presentation_id,
                    surface,
                },
            );
        }
        Err(error) => {
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
                    publish_stale_attachment_failure(inner, &current_request, snapshot, &error);
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
        .map(str::to_owned)
}

fn run_retained_retry(inner: &Inner, retry: &RetainedRetry) {
    match attach_fresh(inner, &retry.request, AttachTerm::Xterm) {
        Ok((worker, snapshot, _, initial_geometry)) => {
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
                .finish_restart(&retry.key, worker);
            if published {
                publish_attach_inventory(inner, &retry.request, snapshot);
                inner.revision.fetch_add(1, Ordering::Release);
            }
        }
        Err(AttachFreshError::Host(error)) => {
            fail_retained_retry(inner, &retry.key, Some(error.to_string()));
        }
        Err(AttachFreshError::SessionChanged { error, snapshot }) => {
            remove_failed_retained_retry(inner, &retry.key);
            publish_retained_stale_failure(inner, &retry.request, snapshot, &error);
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

fn fallback_owns_visible_request(
    inner: &Inner,
    fallback: &FallbackAuthority,
    request: &AttachRequest,
) -> bool {
    if inner.navigation_generation.load(Ordering::Acquire) != fallback.navigation_generation {
        return false;
    }
    matches!(
        &*inner
            .state
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner),
        WorkspaceContent::Attaching { host_id, endpoint, session }
            | WorkspaceContent::Terminal { host_id, endpoint, session, .. }
            if host_id == &request.host_id
                && endpoint == request.endpoint.distro()
                && session == &request.name
    )
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
        .filter(|fallback| fallback_owns_visible_request(inner, fallback, &request));
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

fn publish_attach_inventory(inner: &Inner, request: &AttachRequest, snapshot: HostSnapshot) {
    publish_refresh(inner, request.inventory_generation, || {
        set_attach_inventory(inner, request, snapshot);
    });
}

fn set_attach_inventory(inner: &Inner, request: &AttachRequest, snapshot: HostSnapshot) {
    let inventory_state = ready_content(&snapshot);
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
            name.to_owned(),
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

fn attach_fresh(
    inner: &Inner,
    request: &AttachRequest,
    term: AttachTerm,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let fresh = request
        .host
        .discover(&ConptyAdmissionAttacher::new())
        .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    if fresh.endpoint() != &request.endpoint || fresh.runtime() != &request.runtime {
        return Err(AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "WSL runtime changed since session discovery; refresh and try again",
            ),
            snapshot: fresh,
        });
    }
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
            snapshot: fresh,
        });
    };
    if session.identity() != &request.identity {
        return Err(AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "session identity changed since discovery; refusing stale attachment",
            ),
            snapshot: fresh,
        });
    }
    let plan = request
        .host
        .attach_plan_with_term(fresh.endpoint(), &session, term);
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
    Ok((worker, fresh, plan.target_name().to_owned(), geometry))
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
                    host.endpoint.clone_from(endpoint);
                    host.connection = HostConnectionState::Ready;
                    host.sessions.clone_from(sessions);
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

fn publish_terminfo_retry_boundary(inner: &Inner, host_id: &str, endpoint: &str, session: &str) {
    clear_pending_paste(inner);
    set_inner_state(
        inner,
        WorkspaceContent::Attaching {
            host_id: host_id.to_owned(),
            endpoint: endpoint.to_owned(),
            session: session.to_owned(),
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
    use std::collections::VecDeque;
    use std::sync::Barrier;

    #[derive(Default)]
    struct ManualRefreshRuntime {
        work: Mutex<VecDeque<RefreshTask>>,
        deadlines: Mutex<VecDeque<(Duration, CancellationToken, RefreshTask)>>,
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
    }

    impl RefreshRuntime for ManualRefreshRuntime {
        fn spawn(&self, _name: &str, task: RefreshTask) -> std::io::Result<()> {
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

    struct FixedDiscovery {
        snapshot: HostSnapshot,
    }

    impl WslDiscovery for FixedDiscovery {
        fn discover(
            &self,
            config: WslConfig,
            executable: WslExecutable,
            _cancellation: &CancellationToken,
        ) -> Result<HostContext, HostError> {
            let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
            Ok(HostContext {
                host: WslHost::new(config, runner, executable),
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
            identity,
        }
    }

    fn fallback_fixture(
        kernel_boot_id: &str,
        init_start_ticks: u64,
        identity: session::SessionIdentity,
        navigation_generation: u64,
    ) -> FallbackAuthority {
        FallbackAuthority {
            presentation: presentation_key_fixture(kernel_boot_id, init_start_ticks, identity),
            navigation_generation,
        }
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
            identity,
            name: name.to_owned(),
            inventory_generation: 1,
        }
    }

    #[test]
    fn terminal_event_drain_requests_continuation_only_after_exhausting_its_budget() {
        assert!(!event_drain_may_have_more(MAX_EVENTS_PER_DRAIN - 1, false));
        assert!(event_drain_may_have_more(MAX_EVENTS_PER_DRAIN, false));
        assert!(!event_drain_may_have_more(MAX_EVENTS_PER_DRAIN, true));
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
        let newer_generation = begin_refresh(&workspace.inner, &CancellationToken::new());
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "stale".to_owned(),
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
            identity: identity.clone(),
            name: "replacement".to_owned(),
            inventory_generation: 1,
        };
        let key = request.presentation_key();
        let fallback = FallbackAuthority {
            presentation: PresentationKey {
                identity: session::SessionIdentity::new(100, "$2", 201),
                ..key.clone()
            },
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
            identity: session::SessionIdentity::new(100, "$1", 200),
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
            navigation_generation,
        };
        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Attaching {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "replacement".to_owned(),
            },
        );

        assert!(fallback_owns_visible_request(
            &workspace.inner,
            &fallback,
            &request
        ));
        workspace.detach();
        assert!(!fallback_owns_visible_request(
            &workspace.inner,
            &fallback,
            &request
        ));
    }

    #[cfg(windows)]
    #[test]
    fn failed_attachment_context_uses_the_reconciled_session_name() {
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
        let fallback = fallback_fixture(
            "boot-id",
            42,
            session::SessionIdentity::new(100, "$2", 201),
            navigation_generation,
        );
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
                session: "renamed".to_owned(),
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
    fn terminfo_retry_unpublishes_terminal_and_clears_pending_paste() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let workspace = Workspace::preview(WorkspaceSnapshot {
            revision: 1,
            appearance: Appearance::default(),
            content: WorkspaceContent::Terminal {
                host_id: "wsl".to_owned(),
                endpoint: "Ubuntu".to_owned(),
                session: "work".to_owned(),
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

        publish_terminfo_retry_boundary(&workspace.inner, "wsl", "Ubuntu", "work");

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
            WorkspaceContent::Attaching { host_id, endpoint, session }
                if host_id == "wsl" && endpoint == "Ubuntu" && session == "work"
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
                presentation_id: 1,
                surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
                    1,
                    GridSize::new(80, 24).expect("valid grid"),
                ))),
            },
        );

        let refresh_generation = begin_refresh(&workspace.inner, &CancellationToken::new());
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
        let current_generation = begin_refresh(&workspace.inner, &current_cancellation);
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
        let opening = capture_attach_request(
            &workspace.inner,
            &SessionSelection::new("wsl", "Ubuntu", "opening"),
        )
        .expect("opening request");
        let selected = capture_attach_request(
            &workspace.inner,
            &SessionSelection::new("wsl", "Ubuntu", "selected"),
        )
        .expect("selected request");
        let opening_navigation = workspace.begin_navigation();
        let fallback = fallback_fixture(
            "boot-id",
            42,
            session::SessionIdentity::new(100, "$3", 202),
            opening_navigation,
        );
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
            },
        );

        let carried_fallback = workspace
            .supersede_inflight_attachment()
            .expect("supersede opening attachment");
        let selected_navigation = workspace.begin_navigation();
        let carried_fallback = carried_fallback.map(|presentation| FallbackAuthority {
            presentation,
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
        assert_eq!(active.request.name, "selected");
        assert_eq!(
            attachment.fallback_if_current(selected_generation).as_ref(),
            Some(&FallbackAuthority {
                presentation: fallback.presentation,
                navigation_generation: selected_navigation,
            })
        );
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
    fn refresh_deadlines_and_retry_order_are_manually_driven() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let discovery = Arc::new(FixedDiscovery {
            snapshot: HostSnapshot::test_fixture(
                "Ubuntu",
                "boot",
                42,
                vec![session::DiscoveredSession::new(
                    "work",
                    session::SessionIdentity::new(100, "$1", 200),
                    0,
                )],
            ),
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

        set_inner_state(
            &workspace.inner,
            WorkspaceContent::Error {
                message: "attachment failed".to_owned(),
            },
        );
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

    #[test]
    fn cancelling_refresh_invalidates_work_and_restores_disconnected_host() {
        let runtime = Arc::new(ManualRefreshRuntime::default());
        let discovery = Arc::new(FixedDiscovery {
            snapshot: HostSnapshot::test_fixture(
                "Ubuntu",
                "boot",
                42,
                vec![session::DiscoveredSession::new(
                    "work",
                    session::SessionIdentity::new(100, "$1", 200),
                    0,
                )],
            ),
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
        let stale_generation = begin_refresh(&workspace.inner, &stale);
        let current = CancellationToken::new();
        let current_generation = begin_refresh(&workspace.inner, &current);

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
