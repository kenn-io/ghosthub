//! Application workflow and capability boundary for GPUI.

use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;

use config::TerminalAppearance;
use host::{CancellationToken, HostSnapshot, StdCommandRunner, WslConfig, WslHost};
pub use input::{KeyInput, Modifiers, MouseAction, MouseButton, MouseInput, NamedKey};
use surface::{GridSize, PixelSize, SurfaceStore};
use terminal::{
    ClipboardReadRequest as TerminalClipboardRead, ClipboardTarget, TerminalEvent, TerminalWorker,
};

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

#[derive(Clone)]
pub enum WorkspaceContent {
    Loading,
    Ready {
        endpoint: String,
        sessions: Vec<SessionItem>,
    },
    Attaching {
        endpoint: String,
        session: String,
    },
    Terminal {
        endpoint: String,
        session: String,
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceError(String);

impl WorkspaceError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for WorkspaceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for WorkspaceError {}

struct HostContext {
    host: WslHost<StdCommandRunner>,
    snapshot: HostSnapshot,
}

struct PendingPaste {
    worker_generation: u64,
    input: input::EncodedInput,
}

struct AttachRequest {
    host: WslHost<StdCommandRunner>,
    endpoint: host::WslEndpoint,
    runtime: host::WslRuntimeIdentity,
    identity: session::SessionIdentity,
    name: String,
}

#[derive(Clone, Copy)]
struct TerminalGeometry {
    grid: GridSize,
    pixels: PixelSize,
    sequence: u64,
}

struct Inner {
    appearance: Appearance,
    wsl_config: Option<WslConfig>,
    state: RwLock<WorkspaceContent>,
    revision: AtomicU64,
    host: Mutex<Option<HostContext>>,
    discovery_cancel: Mutex<Option<CancellationToken>>,
    worker: Mutex<Option<TerminalWorker>>,
    pending_paste: Mutex<Option<PendingPaste>>,
    worker_generation: AtomicU64,
    terminal_geometry: Mutex<TerminalGeometry>,
}

#[derive(Clone)]
pub struct Workspace {
    inner: Arc<Inner>,
}

impl Workspace {
    #[must_use]
    pub fn preview(snapshot: WorkspaceSnapshot) -> Self {
        Self {
            inner: Arc::new(Inner {
                appearance: snapshot.appearance,
                wsl_config: None,
                state: RwLock::new(snapshot.content),
                revision: AtomicU64::new(snapshot.revision),
                host: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                worker: Mutex::new(None),
                pending_paste: Mutex::new(None),
                worker_generation: AtomicU64::new(0),
                terminal_geometry: Mutex::new(default_terminal_geometry()),
            }),
        }
    }

    #[must_use]
    pub fn start_wsl(config: WslConfig, appearance: TerminalAppearance) -> Self {
        let workspace = Self {
            inner: Arc::new(Inner {
                appearance: appearance.into(),
                wsl_config: Some(config.clone()),
                state: RwLock::new(WorkspaceContent::Loading),
                revision: AtomicU64::new(0),
                host: Mutex::new(None),
                discovery_cancel: Mutex::new(None),
                worker: Mutex::new(None),
                pending_paste: Mutex::new(None),
                worker_generation: AtomicU64::new(0),
                terminal_geometry: Mutex::new(default_terminal_geometry()),
            }),
        };
        workspace.start_refresh(config);
        workspace
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
        self.set_state(WorkspaceContent::Loading);
        self.start_refresh(config);
        Ok(())
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
        }
    }

    /// Begin an attach-only presentation for one discovered session.
    ///
    /// # Errors
    ///
    /// Returns an error if another presentation is active or the requested
    /// session is not in the latest resolved inventory.
    pub fn attach(&self, session_name: &str) -> Result<(), WorkspaceError> {
        if self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
        {
            return Err(WorkspaceError::new(
                "a terminal presentation is already open",
            ));
        }
        let request = {
            let host = self
                .inner
                .host
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let context = host
                .as_ref()
                .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
            let session = context
                .snapshot
                .sessions()
                .iter()
                .find(|session| session.name() == session_name)
                .ok_or_else(|| WorkspaceError::new("session is not in the current inventory"))?;
            AttachRequest {
                host: context.host.clone(),
                endpoint: context.snapshot.endpoint().clone(),
                runtime: context.snapshot.runtime().clone(),
                identity: session.identity().clone(),
                name: session.name().to_owned(),
            }
        };

        {
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
            *state = WorkspaceContent::Attaching {
                endpoint: request.endpoint.distro().to_owned(),
                session: request.name.clone(),
            };
        }
        self.inner.revision.fetch_add(1, Ordering::Release);
        let inner = Arc::clone(&self.inner);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-attach".to_owned())
            .spawn(move || run_attach(&inner, request))
        {
            self.restore_inventory_state();
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
            .as_ref()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .send_key(input)
            .map_err(|error| WorkspaceError::new(error.to_string()))
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
            .as_ref()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .send_mouse(input)
            .map_err(|error| WorkspaceError::new(error.to_string()))
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
        if paste.worker_generation != self.inner.worker_generation.load(Ordering::Acquire) {
            return Err(WorkspaceError::new(
                "paste confirmation belongs to a closed terminal",
            ));
        }
        let worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        worker
            .as_ref()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .confirm_paste(paste.input)
            .map_err(|error| WorkspaceError::new(error.to_string()))
    }

    pub fn cancel_paste(&self) {
        self.inner
            .pending_paste
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
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
            .as_ref()
        {
            worker
                .resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
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
        let bytes = request.respond(contents);
        let worker = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        worker
            .as_ref()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .send_bytes(bytes)
            .map_err(|error| WorkspaceError::new(error.to_string()))
    }

    pub fn detach(&self) {
        clear_pending_paste(&self.inner);
        self.inner.worker_generation.fetch_add(1, Ordering::AcqRel);
        self.inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        self.restore_inventory_state();
    }

    #[must_use]
    pub fn drain_events(&self) -> Vec<WorkspaceEvent> {
        let mut emitted = Vec::new();
        let mut exited = false;
        if let Some(worker) = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            loop {
                match worker.try_event() {
                    Ok(Some(TerminalEvent::ClipboardWrite(write))) => {
                        emitted.push(WorkspaceEvent::ClipboardWrite {
                            text: write.text,
                            primary: write.target == ClipboardTarget::Selection,
                        });
                    }
                    Ok(Some(TerminalEvent::ClipboardRead(read))) => {
                        emitted.push(WorkspaceEvent::ClipboardRead(ClipboardRead { inner: read }));
                    }
                    Ok(Some(TerminalEvent::ConfirmPaste(paste))) => {
                        let mut pending = self
                            .inner
                            .pending_paste
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        if pending.is_none() {
                            *pending = Some(PendingPaste {
                                worker_generation: self
                                    .inner
                                    .worker_generation
                                    .load(Ordering::Acquire),
                                input: paste,
                            });
                            emitted.push(WorkspaceEvent::ConfirmPaste);
                        }
                    }
                    Ok(Some(TerminalEvent::Exited(_))) => {
                        exited = true;
                        break;
                    }
                    Ok(Some(TerminalEvent::Error(error))) => {
                        emitted.push(WorkspaceEvent::Error(error));
                    }
                    Ok(None) => break,
                    Err(error) => {
                        emitted.push(WorkspaceEvent::Error(error.to_string()));
                        exited = true;
                        break;
                    }
                }
            }
        }
        if exited {
            clear_pending_paste(&self.inner);
            self.inner.worker_generation.fetch_add(1, Ordering::AcqRel);
            self.inner
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take();
            self.restore_inventory_state();
        }
        emitted
    }

    fn start_refresh(&self, config: WslConfig) {
        let inner = Arc::clone(&self.inner);
        let cancellation = CancellationToken::new();
        if let Some(previous) = inner
            .discovery_cancel
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replace(cancellation.clone())
        {
            previous.cancel();
        }
        thread::Builder::new()
            .name("ghosthub-wsl-discovery".to_owned())
            .spawn(move || {
                let host = WslHost::new(config, StdCommandRunner);
                let result = host.discover_with_cancel(&cancellation);
                if cancellation.is_cancelled() {
                    return;
                }
                match result {
                    Ok(snapshot) => {
                        let state = ready_content(&snapshot);
                        *inner
                            .host
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner) =
                            Some(HostContext { host, snapshot });
                        set_inner_state(&inner, state);
                    }
                    Err(error) => set_inner_state(
                        &inner,
                        WorkspaceContent::Error {
                            message: error.to_string(),
                        },
                    ),
                }
            })
            .expect("spawn WSL discovery task");
    }

    fn restore_inventory_state(&self) {
        let state = self
            .inner
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(
                || WorkspaceContent::Error {
                    message: "WSL inventory is unavailable".to_owned(),
                },
                |context| ready_content(&context.snapshot),
            );
        self.set_state(state);
    }

    fn set_state(&self, state: WorkspaceContent) {
        set_inner_state(&self.inner, state);
    }
}

fn run_attach(inner: &Inner, request: AttachRequest) {
    match attach_fresh(inner, &request) {
        Ok((worker, snapshot, session)) => {
            let surface = worker.surface_handle();
            let endpoint = snapshot.endpoint().distro().to_owned();
            *inner
                .host
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(HostContext {
                host: request.host,
                snapshot,
            });
            inner.worker_generation.fetch_add(1, Ordering::AcqRel);
            *inner
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(worker);
            set_inner_state(
                inner,
                WorkspaceContent::Terminal {
                    endpoint,
                    session,
                    surface,
                },
            );
        }
        Err(error) => {
            clear_pending_paste(inner);
            set_inner_state(
                inner,
                WorkspaceContent::Error {
                    message: error.to_string(),
                },
            );
        }
    }
}

fn attach_fresh(
    inner: &Inner,
    request: &AttachRequest,
) -> Result<(TerminalWorker, HostSnapshot, String), WorkspaceError> {
    let fresh = request
        .host
        .discover()
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if fresh.endpoint() != &request.endpoint || fresh.runtime() != &request.runtime {
        return Err(WorkspaceError::new(
            "WSL runtime changed since session discovery; refresh and try again",
        ));
    }
    let session = fresh
        .sessions()
        .iter()
        .find(|session| session.name() == request.name)
        .ok_or_else(|| {
            WorkspaceError::new("session no longer exists; refresh and choose another session")
        })?;
    if session.identity() != &request.identity {
        return Err(WorkspaceError::new(
            "session identity changed since discovery; refusing stale attachment",
        ));
    }
    let plan = request
        .host
        .attach_plan(fresh.endpoint(), session)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let geometry = *inner
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::attach_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
    )
    .map_err(|error| WorkspaceError::new(error.to_string()))?;
    Ok((worker, fresh, plan.target_name().to_owned()))
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

fn clear_pending_paste(inner: &Inner) {
    inner
        .pending_paste
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
}

fn default_terminal_geometry() -> TerminalGeometry {
    TerminalGeometry {
        grid: GridSize::new(100, 30)
            .unwrap_or_else(|_| unreachable!("fixed terminal grid is valid")),
        pixels: PixelSize::default(),
        sequence: 0,
    }
}
