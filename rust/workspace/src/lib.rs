//! Application workflow and capability boundary for GPUI.

use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;

use config::TerminalAppearance;
use host::{HostSnapshot, StdCommandRunner, WslConfig, WslHost};
pub use input::{KeyInput, Modifiers, NamedKey};
use surface::{GridSize, SurfaceStore};
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

struct Inner {
    appearance: Appearance,
    state: RwLock<WorkspaceContent>,
    revision: AtomicU64,
    host: Mutex<Option<HostContext>>,
    worker: Mutex<Option<TerminalWorker>>,
    pending_paste: Mutex<Option<input::EncodedInput>>,
    terminal_size: Mutex<GridSize>,
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
                state: RwLock::new(snapshot.content),
                revision: AtomicU64::new(snapshot.revision),
                host: Mutex::new(None),
                worker: Mutex::new(None),
                pending_paste: Mutex::new(None),
                terminal_size: Mutex::new(default_terminal_size()),
            }),
        }
    }

    #[must_use]
    pub fn start_wsl(config: WslConfig, appearance: TerminalAppearance) -> Self {
        let workspace = Self {
            inner: Arc::new(Inner {
                appearance: appearance.into(),
                state: RwLock::new(WorkspaceContent::Loading),
                revision: AtomicU64::new(0),
                host: Mutex::new(None),
                worker: Mutex::new(None),
                pending_paste: Mutex::new(None),
                terminal_size: Mutex::new(default_terminal_size()),
            }),
        };
        workspace.refresh(config);
        workspace
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
        if matches!(
            &*self
                .inner
                .state
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            WorkspaceContent::Attaching { .. } | WorkspaceContent::Terminal { .. }
        ) {
            return Err(WorkspaceError::new(
                "a terminal presentation is already opening",
            ));
        }

        let (plan, endpoint) = {
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
            let plan = context
                .host
                .attach_plan(context.snapshot.endpoint(), session)
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            (plan, context.snapshot.endpoint().distro().to_owned())
        };

        self.set_state(WorkspaceContent::Attaching {
            endpoint: endpoint.clone(),
            session: session_name.to_owned(),
        });
        let inner = Arc::clone(&self.inner);
        thread::Builder::new()
            .name("ghosthub-terminal-attach".to_owned())
            .spawn(move || {
                let size = *inner
                    .terminal_size
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                match TerminalWorker::attach(&plan, size) {
                    Ok(worker) => {
                        let surface = worker.surface_handle();
                        *inner
                            .worker
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(worker);
                        set_inner_state(
                            &inner,
                            WorkspaceContent::Terminal {
                                endpoint,
                                session: plan.target_name().to_owned(),
                                surface,
                            },
                        );
                    }
                    Err(error) => set_inner_state(
                        &inner,
                        WorkspaceContent::Error {
                            message: error.to_string(),
                        },
                    ),
                }
            })
            .map_err(|error| WorkspaceError::new(format!("start attach task: {error}")))?;
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
        worker
            .as_ref()
            .ok_or_else(|| WorkspaceError::new("no active terminal"))?
            .confirm_paste(paste)
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
        let size =
            GridSize::new(columns, rows).map_err(|error| WorkspaceError::new(error.to_string()))?;
        *self
            .inner
            .terminal_size
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = size;
        if let Some(worker) = self
            .inner
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            worker
                .resize(size)
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
                            *pending = Some(paste);
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
                        break;
                    }
                }
            }
        }
        if exited {
            self.inner
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take();
            self.restore_inventory_state();
        }
        emitted
    }

    fn refresh(&self, config: WslConfig) {
        let inner = Arc::clone(&self.inner);
        thread::Builder::new()
            .name("ghosthub-wsl-discovery".to_owned())
            .spawn(move || {
                let host = WslHost::new(config, StdCommandRunner);
                match host.discover() {
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

fn default_terminal_size() -> GridSize {
    GridSize::new(100, 30).unwrap_or_else(|_| unreachable!("fixed terminal grid is valid"))
}
