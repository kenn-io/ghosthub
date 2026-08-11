use std::collections::VecDeque;
use std::fmt;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender, TryRecvError, TrySendError, bounded, never, select};
use input::{EncodedInput, KeyInput, MouseAction, MouseInput, encode_input, encode_mouse};
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use session::{
    AdmissionPlan, AttachPlan, CreateOnce, HerdrAttachPlan, HerdrLaunchOnce, RepairOrOpenPlan,
    ZellijAttachPlan, ZellijLaunchOnce,
};
use surface::{GridSize, PixelSize, SurfaceStore};

use crate::windows_job::RelayJob;
use crate::{ClipboardPolicy, ClipboardReadRequest, ClipboardWrite, DefaultColors, TerminalEngine};

const READ_BUFFER_SIZE: usize = 64 * 1024;
const EVENT_CAPACITY: usize = 64;
const COMMAND_CAPACITY: usize = 256;
const COMMAND_BYTE_CAPACITY: usize = 1024 * 1024;
const WRITE_HIGH_WATER: usize = 1024 * 1024;
const WRITE_BATCH_MAX: usize = COMMAND_BYTE_CAPACITY + READ_BUFFER_SIZE;
const WRITE_UI_MAX_BYTES: usize = WRITE_HIGH_WATER + WRITE_BATCH_MAX;
const WRITE_PARSER_RESERVE: usize = WRITE_BATCH_MAX;
const WRITE_MAX_BYTES: usize = WRITE_UI_MAX_BYTES + WRITE_PARSER_RESERVE;
const CHILD_EXIT_POLL_INTERVAL: Duration = Duration::from_millis(50);
const CHILD_OUTPUT_DRAIN_GRACE: Duration = Duration::from_millis(250);
const REAP_ATTEMPTS: usize = 20;
const REAP_POLL_DELAY: Duration = Duration::from_millis(25);

pub enum TerminalEvent {
    ClipboardWrite {
        write: ClipboardWrite,
        visibility: u64,
    },
    ClipboardRead(ClipboardReadRequest),
    ConfirmPaste(EncodedInput),
    Exited {
        code: u32,
        output_tail: String,
    },
    Error(String),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkerErrorKind {
    Other,
    Backpressure,
}

#[derive(Debug)]
pub struct WorkerError {
    message: String,
    kind: WorkerErrorKind,
}

impl WorkerError {
    fn new(subject: &str, error: impl fmt::Display) -> Self {
        Self {
            message: format!("{subject}: {error}"),
            kind: WorkerErrorKind::Other,
        }
    }

    fn backpressure(subject: &str, error: impl fmt::Display) -> Self {
        Self {
            message: format!("{subject}: {error}"),
            kind: WorkerErrorKind::Backpressure,
        }
    }

    #[must_use]
    pub fn is_backpressure(&self) -> bool {
        self.kind == WorkerErrorKind::Backpressure
    }
}

impl fmt::Display for WorkerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for WorkerError {}

enum Command {
    Input(Vec<u8>),
    Key(KeyInput),
    Mouse(MouseInput),
}

struct QueuedCommand {
    command: Command,
    bytes: usize,
    preceding_resize: Option<ResizeCommand>,
}

enum PasteAction {
    Confirm(EncodedInput),
    Cancel,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PasteControl {
    Resume,
    Error(&'static str),
    None,
}

#[derive(Clone, Copy)]
struct ResizeCommand {
    size: GridSize,
    sequence: u64,
    pixel_size: PixelSize,
}

#[derive(Default)]
struct IngressState {
    resize: Option<ResizeCommand>,
    mouse_motion: Option<MouseInput>,
    queued_bytes: usize,
}

enum ReaderMessage {
    Bytes(Vec<u8>),
    Eof,
    Error(String),
}

enum WriterMessage {
    Completed,
    Error(String),
}

#[derive(Default)]
struct PendingWrites {
    queue: VecDeque<Vec<u8>>,
    bytes: usize,
    in_flight: Option<usize>,
}

#[derive(Clone, Copy)]
enum WriteSource {
    Ui,
    Parser,
}

impl PendingWrites {
    fn accepts_ui_sources(&self) -> bool {
        self.bytes < WRITE_HIGH_WATER
    }

    fn is_empty(&self) -> bool {
        self.bytes == 0
    }

    fn enqueue(&mut self, bytes: Vec<u8>, source: WriteSource) -> Result<(), WorkerError> {
        if bytes.is_empty() {
            return Ok(());
        }
        let total = self.bytes.saturating_add(bytes.len());
        let limit = match source {
            WriteSource::Ui => WRITE_UI_MAX_BYTES,
            WriteSource::Parser => WRITE_MAX_BYTES,
        };
        if bytes.len() > WRITE_BATCH_MAX || total > limit {
            return Err(WorkerError::backpressure(
                "queue PTY write",
                match source {
                    WriteSource::Ui => "terminal input byte budget is full",
                    WriteSource::Parser => "terminal parser reply reserve is full",
                },
            ));
        }
        self.bytes = total;
        self.queue.push_back(bytes);
        Ok(())
    }

    fn flush_one(&mut self, writer: &Sender<Vec<u8>>) -> WriteFlush {
        if self.in_flight.is_some() {
            return WriteFlush::Full;
        }
        let Some(bytes) = self.queue.pop_front() else {
            return WriteFlush::Empty;
        };
        let length = bytes.len();
        match writer.try_send(bytes) {
            Ok(()) => {
                self.in_flight = Some(length);
                WriteFlush::Sent
            }
            Err(TrySendError::Full(bytes)) => {
                self.queue.push_front(bytes);
                WriteFlush::Full
            }
            Err(TrySendError::Disconnected(_)) => WriteFlush::Disconnected,
        }
    }

    fn complete_write(&mut self) -> bool {
        let Some(length) = self.in_flight.take() else {
            return false;
        };
        self.bytes = self.bytes.saturating_sub(length);
        true
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WriteFlush {
    Empty,
    Sent,
    Full,
    Disconnected,
}

pub struct TerminalWorker {
    commands: Sender<QueuedCommand>,
    paste_actions: Sender<PasteAction>,
    ingress: Arc<Mutex<IngressState>>,
    coalesced_wake: Sender<()>,
    shutdown: Sender<()>,
    events: Receiver<TerminalEvent>,
    deferred_events: Mutex<VecDeque<TerminalEvent>>,
    surface: Arc<SurfaceStore>,
    confirmed_live: Arc<AtomicBool>,
    clipboard_visibility: Arc<AtomicU64>,
    thread: Option<thread::JoinHandle<()>>,
}

impl TerminalWorker {
    /// Spawn the resolved attach client inside a native pseudoterminal.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established. A containment failure tears down the child
    /// before returning.
    pub fn attach(plan: &AttachPlan, size: GridSize) -> Result<Self, WorkerError> {
        Self::attach_with_metadata(
            plan,
            size,
            0,
            PixelSize::default(),
            ClipboardPolicy::default(),
            DefaultColors::default(),
        )
    }

    /// Spawn an attached client with UI-derived initial dimensions.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established.
    pub fn attach_with_metadata(
        plan: &AttachPlan,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Result<Self, WorkerError> {
        Self::launch(
            plan.program(),
            plan.args(),
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
        )
    }

    /// Spawn an attach-only Herdr client with UI-derived initial dimensions.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established.
    pub fn attach_herdr_with_metadata(
        plan: &HerdrAttachPlan,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Result<Self, WorkerError> {
        Self::launch(
            plan.program(),
            plan.args(),
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
        )
    }

    /// Consume one Herdr launch-or-attach authority and spawn its ordinary
    /// client inside a native pseudoterminal.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established. The consumed authority is never returned.
    pub fn launch_herdr_with_metadata(
        plan: HerdrLaunchOnce,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Result<Self, WorkerError> {
        let (program, args, _target_name) = plan.into_parts();
        Self::launch(
            &program,
            &args,
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
        )
    }

    /// Spawn an attach-only Zellij client with UI-derived initial dimensions.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established.
    pub fn attach_zellij_with_metadata(
        plan: &ZellijAttachPlan,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Result<Self, WorkerError> {
        Self::launch(
            plan.program(),
            plan.args(),
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
        )
    }

    /// Spawn a re-runnable KWT repair-or-open client for one exact worktree.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY or ordinary KWT/tmux client cannot be
    /// established.
    pub fn repair_or_open_with_metadata(
        plan: &RepairOrOpenPlan,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Result<Self, WorkerError> {
        Self::launch(
            plan.program(),
            plan.args(),
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
        )
    }

    /// Consume one Zellij creation authority and spawn its ordinary client.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established. The consumed creation authority is never
    /// returned for a retry.
    pub fn launch_zellij_with_metadata(
        plan: ZellijLaunchOnce,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Result<Self, WorkerError> {
        let (program, args, _target_name) = plan.into_parts();
        Self::launch(
            &program,
            &args,
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
        )
    }

    /// Consume one local create-or-attach authority and spawn its ordinary
    /// client inside a native pseudoterminal.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established. The consumed creation authority is never
    /// returned for a retry.
    pub fn create_with_metadata(
        plan: CreateOnce,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Result<Self, WorkerError> {
        let (program, args, _target_name) = plan.into_parts();
        Self::launch(
            &program,
            &args,
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
        )
    }

    /// Spawn one isolated mux-admission client inside a native pseudoterminal.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established.
    pub fn admission(plan: &AdmissionPlan, size: GridSize) -> Result<Self, WorkerError> {
        Self::launch(
            plan.program(),
            plan.args(),
            size,
            0,
            PixelSize::default(),
            ClipboardPolicy::default(),
            DefaultColors::default(),
        )
    }

    #[allow(
        clippy::too_many_arguments,
        clippy::too_many_lines,
        reason = "PTY setup and ownership transfer stay together for lifecycle auditing"
    )]
    fn launch(
        program: &std::ffi::OsStr,
        args: &[std::ffi::OsString],
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Result<Self, WorkerError> {
        let pty_size = pty_size(size, pixel_size)?;
        let job = RelayJob::new().map_err(|error| WorkerError::new("create relay job", error))?;
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(pty_size)
            .map_err(|error| WorkerError::new("open pseudoterminal", error))?;
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|error| WorkerError::new("clone PTY reader", error))?;
        let writer = pair
            .master
            .take_writer()
            .map_err(|error| WorkerError::new("take PTY writer", error))?;

        let mut command = CommandBuilder::new(program);
        command.args(args);
        let mut child = pair
            .slave
            .spawn_command(command)
            .map_err(|error| WorkerError::new("spawn terminal client", error))?;
        drop(pair.slave);

        if let Err(error) = job.assign_and_verify(child.as_ref()) {
            drop(writer);
            drop(pair.master);
            let _ignored = child.kill();
            let _ignored = child.wait();
            return Err(WorkerError::new("contain terminal client", error));
        }

        let engine = TerminalEngine::with_geometry_and_colors(
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
        );
        let surface = engine.surface_handle();
        let (commands, command_receiver) = bounded(COMMAND_CAPACITY);
        let (paste_actions, paste_action_receiver) = bounded(1);
        let ingress = Arc::new(Mutex::new(IngressState::default()));
        let worker_ingress = Arc::clone(&ingress);
        let (coalesced_wake, coalesced_wake_receiver) = bounded(1);
        let worker_coalesced_wake = coalesced_wake.clone();
        let (shutdown, shutdown_receiver) = bounded(1);
        let (events_sender, events) = bounded(EVENT_CAPACITY);
        let (reader_sender, reader_receiver) = bounded(1);
        let (write_sender, write_receiver) = bounded(1);
        let (write_complete_sender, write_complete_receiver) = bounded(1);
        let confirmed_live = Arc::new(AtomicBool::new(false));
        let worker_confirmed_live = Arc::clone(&confirmed_live);
        let clipboard_visibility = Arc::new(AtomicU64::new(1));
        let worker_clipboard_visibility = Arc::clone(&clipboard_visibility);

        thread::Builder::new()
            .name("ghosthub-pty-writer".to_owned())
            .spawn(move || {
                write_pty(writer, &write_receiver, &write_complete_sender);
            })
            .map_err(|error| WorkerError::new("spawn PTY writer", error))?;
        thread::Builder::new()
            .name("ghosthub-pty-reader".to_owned())
            .spawn(move || read_pty(&mut reader, &reader_sender))
            .map_err(|error| WorkerError::new("spawn PTY reader", error))?;

        let worker_thread = thread::Builder::new()
            .name("ghosthub-terminal-worker".to_owned())
            .spawn(move || {
                run_worker(
                    engine,
                    pair.master,
                    child,
                    job,
                    &command_receiver,
                    &paste_action_receiver,
                    &worker_ingress,
                    &worker_coalesced_wake,
                    &coalesced_wake_receiver,
                    &shutdown_receiver,
                    &reader_receiver,
                    &write_sender,
                    &write_complete_receiver,
                    &events_sender,
                    &worker_confirmed_live,
                    &worker_clipboard_visibility,
                );
            })
            .map_err(|error| WorkerError::new("spawn terminal worker", error))?;

        Ok(Self {
            commands,
            paste_actions,
            ingress,
            coalesced_wake,
            shutdown,
            events,
            deferred_events: Mutex::new(VecDeque::new()),
            surface,
            confirmed_live,
            clipboard_visibility,
            thread: Some(worker_thread),
        })
    }

    #[must_use]
    pub fn surface(&self) -> &SurfaceStore {
        &self.surface
    }

    #[must_use]
    pub fn surface_handle(&self) -> Arc<SurfaceStore> {
        Arc::clone(&self.surface)
    }

    /// Whether the attached terminal emitted its initialization control stream.
    #[must_use]
    pub fn is_confirmed_live(&self) -> bool {
        self.confirmed_live.load(Ordering::Acquire)
    }

    /// Enable or suppress clipboard writes emitted by this presentation.
    ///
    /// Disabling also discards writes already queued for the UI while retaining
    /// lifecycle and diagnostic events for normal processing.
    pub fn set_clipboard_writes_enabled(&self, enabled: bool) {
        advance_clipboard_visibility(&self.clipboard_visibility, enabled);
        if enabled {
            return;
        }
        let mut deferred = self
            .deferred_events
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        discard_clipboard_events(&self.events, &mut deferred);
    }

    /// Queue one neutral key or paste event for mode-aware encoding.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn send_key(&self, input: KeyInput) -> Result<(), WorkerError> {
        try_send_ordered(
            &self.commands,
            &self.ingress,
            Command::Key(input),
            "send terminal key",
        )
    }

    /// Queue one grid-relative mouse event for mode-aware SGR encoding.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn send_mouse(&self, input: MouseInput) -> Result<(), WorkerError> {
        if matches!(input.action, MouseAction::Move(_)) {
            self.ingress
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .mouse_motion = Some(input);
            wake_coalesced(&self.coalesced_wake, "send terminal mouse event")
        } else {
            try_send_ordered(
                &self.commands,
                &self.ingress,
                Command::Mouse(input),
                "send terminal mouse event",
            )
        }
    }

    /// Approve and queue a paste previously reported for confirmation.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn confirm_paste(&self, input: EncodedInput) -> Result<(), WorkerError> {
        try_send_paste_action(
            &self.paste_actions,
            PasteAction::Confirm(input),
            "confirm terminal paste",
        )
    }

    /// Cancel a paste awaiting confirmation and resume queued input.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn cancel_paste(&self) -> Result<(), WorkerError> {
        try_send_paste_action(
            &self.paste_actions,
            PasteAction::Cancel,
            "cancel terminal paste",
        )
    }

    /// Send already-authorized bytes to the attached client.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn send_bytes(&self, bytes: Vec<u8>) -> Result<(), WorkerError> {
        try_send_ordered(
            &self.commands,
            &self.ingress,
            Command::Input(bytes),
            "send terminal input",
        )
    }

    /// Resize the VT grid and PTY in one ordered worker operation.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn resize(&self, size: GridSize) -> Result<(), WorkerError> {
        self.resize_with_metadata(size, 0, PixelSize::default())
    }

    /// Resize with UI-derived pixel dimensions and an ordered sequence.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn resize_with_metadata(
        &self,
        size: GridSize,
        sequence: u64,
        pixel_size: PixelSize,
    ) -> Result<(), WorkerError> {
        set_ordered_resize(
            &self.commands,
            &self.ingress,
            ResizeCommand {
                size,
                sequence,
                pixel_size,
            },
        )?;
        wake_coalesced(&self.coalesced_wake, "send terminal resize")
    }

    /// Read one pending semantic terminal event without blocking.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal event channel has disconnected.
    pub fn try_event(&self) -> Result<Option<TerminalEvent>, WorkerError> {
        loop {
            let deferred = self
                .deferred_events
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .pop_front();
            let event = match deferred {
                Some(event) => event,
                None => match self.events.try_recv() {
                    Ok(event) => event,
                    Err(TryRecvError::Empty) => return Ok(None),
                    Err(error @ TryRecvError::Disconnected) => {
                        return Err(WorkerError::new("receive terminal event", error));
                    }
                },
            };
            if clipboard_event_is_visible(&event, self.clipboard_visibility.load(Ordering::Acquire))
            {
                return Ok(Some(event));
            }
        }
    }
}

const fn clipboard_visibility_is_enabled(visibility: u64) -> bool {
    visibility & 1 == 1
}

fn advance_clipboard_visibility(visibility: &AtomicU64, enabled: bool) -> u64 {
    let mut current = visibility.load(Ordering::Acquire);
    loop {
        let next = (current.wrapping_add(2) & !1) | u64::from(enabled);
        match visibility.compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => return next,
            Err(observed) => current = observed,
        }
    }
}

fn clipboard_event_is_visible(event: &TerminalEvent, current_visibility: u64) -> bool {
    match event {
        TerminalEvent::ClipboardWrite { visibility, .. } => {
            clipboard_visibility_is_enabled(current_visibility) && *visibility == current_visibility
        }
        TerminalEvent::ClipboardRead(_)
        | TerminalEvent::ConfirmPaste(_)
        | TerminalEvent::Exited { .. }
        | TerminalEvent::Error(_) => true,
    }
}

fn discard_clipboard_events(
    events: &Receiver<TerminalEvent>,
    deferred: &mut VecDeque<TerminalEvent>,
) {
    deferred.retain(|event| !matches!(event, TerminalEvent::ClipboardWrite { .. }));
    while let Ok(event) = events.try_recv() {
        if !matches!(event, TerminalEvent::ClipboardWrite { .. }) {
            deferred.push_back(event);
        }
    }
}

impl Drop for TerminalWorker {
    fn drop(&mut self) {
        let _ignored = self.shutdown.try_send(());
        let _detached = self.thread.take();
    }
}

fn read_pty(reader: &mut dyn Read, sender: &Sender<ReaderMessage>) {
    loop {
        let mut bytes = vec![0; READ_BUFFER_SIZE];
        match reader.read(&mut bytes) {
            Ok(0) => {
                let _ignored = sender.send(ReaderMessage::Eof);
                return;
            }
            Ok(count) => {
                bytes.truncate(count);
                if sender.send(ReaderMessage::Bytes(bytes)).is_err() {
                    return;
                }
            }
            Err(error) => {
                let _ignored = sender.send(ReaderMessage::Error(error.to_string()));
                return;
            }
        }
    }
}

fn write_pty(
    mut writer: Box<dyn Write + Send>,
    receiver: &Receiver<Vec<u8>>,
    completions: &Sender<WriterMessage>,
) {
    while let Ok(bytes) = receiver.recv() {
        if let Err(error) = writer.write_all(&bytes).and_then(|()| writer.flush()) {
            let _ignored = completions.try_send(WriterMessage::Error(error.to_string()));
            return;
        }
        if completions.try_send(WriterMessage::Completed).is_err() {
            return;
        }
    }
}

#[allow(clippy::too_many_arguments)]
#[allow(
    clippy::too_many_lines,
    reason = "the serial worker loop keeps command and PTY ordering visible"
)]
fn run_worker(
    mut engine: TerminalEngine,
    master: Box<dyn MasterPty + Send>,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    job: RelayJob,
    commands: &Receiver<QueuedCommand>,
    paste_actions: &Receiver<PasteAction>,
    ingress: &Mutex<IngressState>,
    coalesced_wake_sender: &Sender<()>,
    coalesced_wake: &Receiver<()>,
    shutdown: &Receiver<()>,
    reader: &Receiver<ReaderMessage>,
    writer: &Sender<Vec<u8>>,
    write_completions: &Receiver<WriterMessage>,
    events: &Sender<TerminalEvent>,
    confirmed_live: &AtomicBool,
    clipboard_visibility: &AtomicU64,
) {
    let mut report_exit = false;
    let mut observed_exit = None;
    let mut next_child_poll = Instant::now();
    let mut output_tail = Vec::new();
    let mut pending_paste = None;
    let mut approved_paste = None;
    let mut pending_writes = PendingWrites::default();
    let suspended_commands = never();
    'worker: loop {
        if child_exit_drain_expired(
            &mut observed_exit,
            &mut next_child_poll,
            Instant::now(),
            || {
                child
                    .try_wait()
                    .ok()
                    .flatten()
                    .map(|status| status.exit_code())
            },
        ) {
            report_exit = true;
            break;
        }
        match paste_actions.try_recv() {
            Ok(action) => {
                if !service_paste_action(
                    action,
                    &mut pending_paste,
                    &mut approved_paste,
                    coalesced_wake_sender,
                    shutdown,
                    events,
                ) {
                    break;
                }
                continue;
            }
            Err(TryRecvError::Disconnected) => break,
            Err(TryRecvError::Empty) => {}
        }
        match pending_writes.flush_one(writer) {
            WriteFlush::Sent => {
                let _ignored =
                    wake_coalesced(coalesced_wake_sender, "resume coalesced terminal work");
                continue;
            }
            WriteFlush::Disconnected => break,
            WriteFlush::Empty | WriteFlush::Full => {}
        }
        if pending_writes.accepts_ui_sources()
            && let Some(approved) = approved_paste.take()
        {
            if !queue_write(
                &mut pending_writes,
                WriteSource::Ui,
                shutdown,
                events,
                approved,
            ) {
                break;
            }
            let _ignored = wake_coalesced(coalesced_wake_sender, "resume terminal input");
            continue;
        }
        let accepts_ui_sources = pending_writes.accepts_ui_sources();
        let ordered_work_ready = pending_writes.is_empty();
        let active_commands = if pending_paste.is_some()
            || approved_paste.is_some()
            || !accepts_ui_sources
            || !ordered_work_ready
        {
            &suspended_commands
        } else {
            commands
        };
        select! {
            recv(shutdown) -> _ => break,
            recv(paste_actions) -> message => match message {
                Ok(action) => if !service_paste_action(
                    action,
                    &mut pending_paste,
                    &mut approved_paste,
                    coalesced_wake_sender,
                    shutdown,
                    events,
                ) {
                    break 'worker;
                },
                Err(_) => break,
            },
            recv(write_completions) -> message => match message {
                Ok(WriterMessage::Completed) if pending_writes.complete_write() => {
                    let _ignored = wake_coalesced(
                        coalesced_wake_sender,
                        "resume ordered terminal work",
                    );
                }
                Ok(WriterMessage::Completed) => {
                    let _ignored = emit_event(
                        events,
                        shutdown,
                        TerminalEvent::Error("unexpected PTY write completion".to_owned()),
                    );
                    break 'worker;
                }
                Ok(WriterMessage::Error(error)) => {
                    let _ignored = emit_event(events, shutdown, TerminalEvent::Error(error));
                    report_exit = true;
                    break 'worker;
                }
                Err(_) => {
                    let _ignored = emit_event(
                        events,
                        shutdown,
                        TerminalEvent::Error("PTY writer stopped".to_owned()),
                    );
                    report_exit = true;
                    break 'worker;
                }
            },
            recv(active_commands) -> message => match message {
                Ok(queued) => {
                    let bytes = queued.bytes;
                    let keep_running = process_queued_command(
                        queued,
                        &mut engine,
                        &*master,
                        &mut pending_writes,
                        shutdown,
                        events,
                        &mut pending_paste,
                    );
                    release_command_bytes(ingress, bytes);
                    if !keep_running {
                        break 'worker;
                    }
                },
                Err(_) => break,
            },
            recv(coalesced_wake) -> _ => {
                if !process_coalesced(
                    commands,
                    ingress,
                    pending_paste.is_none()
                        && approved_paste.is_none()
                        && accepts_ui_sources
                        && ordered_work_ready,
                    coalesced_wake_sender,
                    &mut engine,
                    &*master,
                    &mut pending_writes,
                    shutdown,
                    events,
                    &mut pending_paste,
                ) {
                    break 'worker;
                }
            },
            recv(reader) -> message => match message {
                Ok(ReaderMessage::Bytes(bytes)) => {
                    retain_output_tail(&mut output_tail, &bytes);
                    let output = engine.process(&bytes);
                    if engine.has_entered_alternate_screen() {
                        confirmed_live.store(true, Ordering::Release);
                    }
                    for bytes in output.pty_writes {
                        if !queue_write(&mut pending_writes, WriteSource::Parser, shutdown, events, bytes) {
                            break 'worker;
                        }
                    }
                    for write in output.clipboard_writes {
                        let visibility = clipboard_visibility.load(Ordering::Acquire);
                        if clipboard_visibility_is_enabled(visibility)
                            && !emit_event(
                                events,
                                shutdown,
                                TerminalEvent::ClipboardWrite { write, visibility },
                            )
                        {
                            break 'worker;
                        }
                    }
                    for read in output.clipboard_reads {
                        if !emit_event(events, shutdown, TerminalEvent::ClipboardRead(read)) {
                            break 'worker;
                        }
                    }
                }
                Ok(ReaderMessage::Error(error)) => {
                    let _ignored = emit_event(events, shutdown, TerminalEvent::Error(error));
                    report_exit = true;
                    break 'worker;
                }
                Ok(ReaderMessage::Eof) | Err(_) => {
                    report_exit = true;
                    break 'worker;
                },
            },
            default(CHILD_EXIT_POLL_INTERVAL) => {}
        }
    }

    drop(master);
    let reaped_exit_code = reap_with_lifetime_guard(
        job,
        report_exit,
        observed_exit.map(|(code, _)| code),
        |mode| match mode {
            ReapMode::Natural => wait_for_child_exit(&mut *child),
            ReapMode::Contained => Some(reap_child(&mut *child)),
        },
    );
    if report_exit {
        let _ignored = emit_event(
            events,
            shutdown,
            TerminalEvent::Exited {
                code: reaped_exit_code,
                output_tail: String::from_utf8_lossy(&output_tail).into_owned(),
            },
        );
    }
}

fn child_exit_drain_expired(
    observed_exit: &mut Option<(u32, Instant)>,
    next_poll: &mut Instant,
    now: Instant,
    try_wait: impl FnOnce() -> Option<u32>,
) -> bool {
    if let Some((_, deadline)) = observed_exit {
        return now >= *deadline;
    }
    if now < *next_poll {
        return false;
    }

    *next_poll = now + CHILD_EXIT_POLL_INTERVAL;
    if let Some(exit_code) = try_wait() {
        *observed_exit = Some((exit_code, now + CHILD_OUTPUT_DRAIN_GRACE));
    }
    false
}

fn process_paste_action(
    action: PasteAction,
    pending: &mut Option<EncodedInput>,
    approved: &mut Option<Vec<u8>>,
) -> PasteControl {
    match action {
        PasteAction::Confirm(input) if pending.as_ref() == Some(&input) => {
            *approved = pending.take().map(EncodedInput::approve);
            PasteControl::Resume
        }
        PasteAction::Confirm(_) if pending.is_some() => {
            PasteControl::Error("paste confirmation does not match the pending input")
        }
        PasteAction::Cancel if pending.is_some() => {
            *pending = None;
            PasteControl::Resume
        }
        PasteAction::Confirm(_) => PasteControl::Error("no paste is awaiting confirmation"),
        PasteAction::Cancel => PasteControl::None,
    }
}

fn service_paste_action(
    action: PasteAction,
    pending: &mut Option<EncodedInput>,
    approved: &mut Option<Vec<u8>>,
    coalesced_wake: &Sender<()>,
    shutdown: &Receiver<()>,
    events: &Sender<TerminalEvent>,
) -> bool {
    match process_paste_action(action, pending, approved) {
        PasteControl::Resume => {
            let _ignored = wake_coalesced(coalesced_wake, "resume terminal input");
            true
        }
        PasteControl::Error(error) => {
            emit_event(events, shutdown, TerminalEvent::Error(error.to_owned()))
        }
        PasteControl::None => true,
    }
}

#[allow(clippy::too_many_arguments)]
fn process_ready_command(
    command: Command,
    engine: &mut TerminalEngine,
    pending_writes: &mut PendingWrites,
    shutdown: &Receiver<()>,
    events: &Sender<TerminalEvent>,
    pending_paste: &mut Option<EncodedInput>,
) -> bool {
    match command {
        Command::Input(bytes) => {
            queue_write(pending_writes, WriteSource::Ui, shutdown, events, bytes)
        }
        Command::Key(input) => {
            let encoded = encode_input(&input, engine.modes());
            if encoded.requires_confirmation() {
                *pending_paste = Some(encoded.clone());
                emit_event(events, shutdown, TerminalEvent::ConfirmPaste(encoded))
            } else {
                queue_write(
                    pending_writes,
                    WriteSource::Ui,
                    shutdown,
                    events,
                    encoded.approve(),
                )
            }
        }
        Command::Mouse(input) => {
            let encoded = encode_mouse(input, engine.modes());
            encoded.is_empty()
                || queue_write(pending_writes, WriteSource::Ui, shutdown, events, encoded)
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn process_queued_command(
    queued: QueuedCommand,
    engine: &mut TerminalEngine,
    master: &dyn MasterPty,
    pending_writes: &mut PendingWrites,
    shutdown: &Receiver<()>,
    events: &Sender<TerminalEvent>,
    pending_paste: &mut Option<EncodedInput>,
) -> bool {
    if let Some(resize) = queued.preceding_resize
        && !process_resize(resize, engine, master, shutdown, events)
    {
        return false;
    }
    process_ready_command(
        queued.command,
        engine,
        pending_writes,
        shutdown,
        events,
        pending_paste,
    )
}

#[allow(clippy::too_many_arguments)]
fn process_coalesced(
    commands: &Receiver<QueuedCommand>,
    ingress: &Mutex<IngressState>,
    accept_mouse_motion: bool,
    coalesced_wake: &Sender<()>,
    engine: &mut TerminalEngine,
    master: &dyn MasterPty,
    pending_writes: &mut PendingWrites,
    shutdown: &Receiver<()>,
    events: &Sender<TerminalEvent>,
    pending_paste: &mut Option<EncodedInput>,
) -> bool {
    let CoalescedWork {
        resize,
        input,
        wake_again,
    } = take_coalesced_work(commands, ingress, accept_mouse_motion);

    if let Some(resize) = resize
        && !process_resize(resize, engine, master, shutdown, events)
    {
        return false;
    }
    let keep_running = match input {
        CoalescedInput::None => true,
        CoalescedInput::Motion(input) => process_ready_command(
            Command::Mouse(input),
            engine,
            pending_writes,
            shutdown,
            events,
            pending_paste,
        ),
        CoalescedInput::Command(queued) => {
            let bytes = queued.bytes;
            debug_assert!(queued.preceding_resize.is_none());
            let keep_running = process_queued_command(
                queued,
                engine,
                master,
                pending_writes,
                shutdown,
                events,
                pending_paste,
            );
            release_command_bytes(ingress, bytes);
            keep_running
        }
        CoalescedInput::Disconnected => false,
    };
    if wake_again {
        let _ignored = wake_coalesced(coalesced_wake, "continue terminal input");
    }
    keep_running
}

enum CoalescedInput {
    None,
    Motion(MouseInput),
    Command(QueuedCommand),
    Disconnected,
}

struct CoalescedWork {
    resize: Option<ResizeCommand>,
    input: CoalescedInput,
    wake_again: bool,
}

fn take_coalesced_work(
    commands: &Receiver<QueuedCommand>,
    ingress: &Mutex<IngressState>,
    accept_mouse_motion: bool,
) -> CoalescedWork {
    // Ordered senders hold this same lock while flushing an older motion and
    // enqueueing their command. Checking the queue and taking a newer motion
    // under the lock therefore forms one atomic ordering decision.
    let mut state = ingress
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (resize, input, wake_again) = if accept_mouse_motion {
        match commands.try_recv() {
            Ok(mut command) => {
                let resize = command.preceding_resize.take();
                (
                    resize,
                    CoalescedInput::Command(command),
                    state.resize.is_some() || state.mouse_motion.is_some(),
                )
            }
            Err(TryRecvError::Empty) => (
                state.resize.take(),
                state
                    .mouse_motion
                    .take()
                    .map_or(CoalescedInput::None, CoalescedInput::Motion),
                false,
            ),
            Err(TryRecvError::Disconnected) => {
                (state.resize.take(), CoalescedInput::Disconnected, false)
            }
        }
    } else {
        // Outstanding writes and queued commands predate this coalesced work.
        // Leave both resize and motion pending until the writer acknowledges
        // completion; channel acceptance alone is not a PTY ordering boundary.
        (None, CoalescedInput::None, false)
    };
    CoalescedWork {
        resize,
        input,
        wake_again,
    }
}

fn process_resize(
    command: ResizeCommand,
    engine: &mut TerminalEngine,
    master: &dyn MasterPty,
    shutdown: &Receiver<()>,
    events: &Sender<TerminalEvent>,
) -> bool {
    match pty_size(command.size, command.pixel_size).and_then(|pty_size| {
        master
            .resize(pty_size)
            .map_err(|error| WorkerError::new("resize PTY", error))
    }) {
        Ok(()) => {
            engine.resize_with_metadata(command.size, command.sequence, command.pixel_size);
            true
        }
        Err(error) => emit_event(events, shutdown, TerminalEvent::Error(error.to_string())),
    }
}

fn try_send_ordered(
    sender: &Sender<QueuedCommand>,
    ingress: &Mutex<IngressState>,
    command: Command,
    subject: &str,
) -> Result<(), WorkerError> {
    let mut ingress = ingress
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    flush_mouse_motion(sender, &mut ingress)?;
    enqueue_command(sender, &mut ingress, command, subject)
}

fn set_ordered_resize(
    sender: &Sender<QueuedCommand>,
    ingress: &Mutex<IngressState>,
    resize: ResizeCommand,
) -> Result<(), WorkerError> {
    let mut ingress = ingress
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    flush_mouse_motion(sender, &mut ingress)?;
    ingress.resize = Some(resize);
    Ok(())
}

fn flush_mouse_motion(
    sender: &Sender<QueuedCommand>,
    ingress: &mut IngressState,
) -> Result<(), WorkerError> {
    if let Some(motion) = ingress.mouse_motion.take()
        && let Err(error) = enqueue_command(
            sender,
            ingress,
            Command::Mouse(motion),
            "preserve terminal mouse ordering",
        )
    {
        ingress.mouse_motion = Some(motion);
        return Err(error);
    }
    Ok(())
}

fn enqueue_command(
    sender: &Sender<QueuedCommand>,
    ingress: &mut IngressState,
    command: Command,
    subject: &str,
) -> Result<(), WorkerError> {
    let bytes = command_bytes(&command);
    if ingress.queued_bytes.saturating_add(bytes) > COMMAND_BYTE_CAPACITY {
        return Err(WorkerError::backpressure(
            subject,
            "terminal input byte budget is full",
        ));
    }
    let preceding_resize = ingress.resize.take();
    match sender.try_send(QueuedCommand {
        command,
        bytes,
        preceding_resize,
    }) {
        Ok(()) => {
            ingress.queued_bytes += bytes;
            Ok(())
        }
        Err(TrySendError::Full(queued)) => {
            ingress.resize = queued.preceding_resize;
            Err(WorkerError::backpressure(
                subject,
                "terminal input queue is full",
            ))
        }
        Err(TrySendError::Disconnected(queued)) => {
            ingress.resize = queued.preceding_resize;
            Err(WorkerError::new(subject, "terminal worker has stopped"))
        }
    }
}

const fn command_bytes(command: &Command) -> usize {
    match command {
        Command::Input(bytes) => bytes.len(),
        Command::Key(KeyInput::Text { text, .. } | KeyInput::Paste(text)) => text.len(),
        Command::Key(KeyInput::Named { .. }) | Command::Mouse(_) => 0,
    }
}

fn release_command_bytes(ingress: &Mutex<IngressState>, bytes: usize) {
    let mut ingress = ingress
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    ingress.queued_bytes = ingress.queued_bytes.saturating_sub(bytes);
}

fn try_send_paste_action(
    sender: &Sender<PasteAction>,
    action: PasteAction,
    subject: &str,
) -> Result<(), WorkerError> {
    sender
        .try_send(action)
        .map_err(|error| bounded_send_error(subject, &error))
}

fn bounded_send_error<T>(subject: &str, error: &TrySendError<T>) -> WorkerError {
    match error {
        TrySendError::Full(_) => {
            WorkerError::backpressure(subject, "terminal control queue is full")
        }
        TrySendError::Disconnected(_) => WorkerError::new(subject, "terminal worker has stopped"),
    }
}

fn wake_coalesced(sender: &Sender<()>, subject: &str) -> Result<(), WorkerError> {
    match sender.try_send(()) {
        Ok(()) | Err(TrySendError::Full(())) => Ok(()),
        Err(TrySendError::Disconnected(())) => {
            Err(WorkerError::new(subject, "terminal worker has stopped"))
        }
    }
}

fn retain_output_tail(tail: &mut Vec<u8>, bytes: &[u8]) {
    const LIMIT: usize = 8 * 1024;
    if bytes.len() >= LIMIT {
        tail.clear();
        tail.extend_from_slice(&bytes[bytes.len() - LIMIT..]);
        return;
    }
    let overflow = tail.len().saturating_add(bytes.len()).saturating_sub(LIMIT);
    if overflow > 0 {
        tail.drain(..overflow);
    }
    tail.extend_from_slice(bytes);
}

fn queue_write(
    pending_writes: &mut PendingWrites,
    source: WriteSource,
    shutdown: &Receiver<()>,
    events: &Sender<TerminalEvent>,
    bytes: Vec<u8>,
) -> bool {
    match pending_writes.enqueue(bytes, source) {
        Ok(()) => true,
        Err(error) => {
            let _ignored = emit_event(events, shutdown, TerminalEvent::Error(error.to_string()));
            false
        }
    }
}

fn emit_event(
    events: &Sender<TerminalEvent>,
    shutdown: &Receiver<()>,
    event: TerminalEvent,
) -> bool {
    select! {
        send(events, event) -> result => result.is_ok(),
        recv(shutdown) -> _ => false,
    }
}

fn reap_child(child: &mut dyn portable_pty::Child) -> u32 {
    if let Some(exit_code) = wait_for_child_exit(child) {
        return exit_code;
    }
    let _ignored = child.kill();
    child.wait().map_or(u32::MAX, |status| status.exit_code())
}

fn wait_for_child_exit(child: &mut dyn portable_pty::Child) -> Option<u32> {
    for _ in 0..REAP_ATTEMPTS {
        if let Ok(Some(status)) = child.try_wait() {
            return Some(status.exit_code());
        }
        thread::sleep(REAP_POLL_DELAY);
    }
    None
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReapMode {
    Natural,
    Contained,
}

fn reap_with_lifetime_guard<G, F>(
    guard: G,
    preserve_natural_exit: bool,
    observed_exit: Option<u32>,
    mut reap: F,
) -> u32
where
    F: FnMut(ReapMode) -> Option<u32>,
{
    if preserve_natural_exit
        && let Some(exit_code) = observed_exit.or_else(|| reap(ReapMode::Natural))
    {
        drop(guard);
        return exit_code;
    }
    drop(guard);
    reap(ReapMode::Contained).unwrap_or(u32::MAX)
}

fn pty_size(size: GridSize, pixel_size: PixelSize) -> Result<PtySize, WorkerError> {
    Ok(PtySize {
        rows: u16::try_from(size.rows())
            .map_err(|error| WorkerError::new("PTY row count", error))?,
        cols: u16::try_from(size.columns())
            .map_err(|error| WorkerError::new("PTY column count", error))?,
        pixel_width: pixel_size.width,
        pixel_height: pixel_size.height,
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use input::{Modifiers, MouseAction, MouseButton, MouseInput, TerminalModes};

    use super::*;
    use crate::ClipboardTarget;

    #[derive(Debug)]
    struct DropProbe(Arc<Mutex<Vec<&'static str>>>);

    impl Drop for DropProbe {
        fn drop(&mut self) {
            self.0.lock().expect("event log").push("drop");
        }
    }

    struct RecordingWriter(Arc<Mutex<Vec<&'static str>>>);

    #[test]
    fn hiding_a_presentation_discards_queued_clipboard_writes_only() {
        let (sender, receiver) = bounded(4);
        sender
            .send(TerminalEvent::ClipboardWrite {
                write: ClipboardWrite {
                    target: ClipboardTarget::Clipboard,
                    text: "hidden".to_owned(),
                },
                visibility: 1,
            })
            .expect("queue clipboard write");
        sender
            .send(TerminalEvent::Error("preserved".to_owned()))
            .expect("queue diagnostic");
        let mut deferred = VecDeque::new();

        discard_clipboard_events(&receiver, &mut deferred);

        assert!(matches!(
            deferred.pop_front(),
            Some(TerminalEvent::Error(error)) if error == "preserved"
        ));
        assert!(deferred.is_empty());
        assert!(receiver.is_empty());
    }

    #[test]
    fn clipboard_visibility_rejects_writes_enqueued_after_hiding() {
        let visibility = AtomicU64::new(1);
        let stale = TerminalEvent::ClipboardWrite {
            write: ClipboardWrite {
                target: ClipboardTarget::Clipboard,
                text: "stale".to_owned(),
            },
            visibility: visibility.load(Ordering::Acquire),
        };

        let hidden = advance_clipboard_visibility(&visibility, false);
        assert!(!clipboard_event_is_visible(&stale, hidden));

        let visible_again = advance_clipboard_visibility(&visibility, true);
        assert!(!clipboard_event_is_visible(&stale, visible_again));
        assert!(clipboard_event_is_visible(
            &TerminalEvent::ClipboardWrite {
                write: ClipboardWrite {
                    target: ClipboardTarget::Clipboard,
                    text: "current".to_owned(),
                },
                visibility: visible_again,
            },
            visible_again,
        ));
    }

    impl Write for RecordingWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().expect("event log").push("write");
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            self.0.lock().expect("event log").push("flush");
            Ok(())
        }
    }

    #[test]
    fn reported_exit_is_reaped_before_the_lifetime_guard_closes() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let reap_events = Arc::clone(&events);

        let exit_code =
            reap_with_lifetime_guard(DropProbe(Arc::clone(&events)), true, None, |mode| {
                assert_eq!(mode, ReapMode::Natural);
                reap_events.lock().expect("event log").push("reap");
                Some(7)
            });

        assert_eq!(exit_code, 7);
        assert_eq!(*events.lock().expect("event log"), ["reap", "drop"]);
    }

    #[test]
    fn explicit_shutdown_closes_the_lifetime_guard_before_reaping() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let reap_events = Arc::clone(&events);

        let exit_code =
            reap_with_lifetime_guard(DropProbe(Arc::clone(&events)), false, None, |mode| {
                assert_eq!(mode, ReapMode::Contained);
                reap_events.lock().expect("event log").push("reap");
                Some(1)
            });

        assert_eq!(exit_code, 1);
        assert_eq!(*events.lock().expect("event log"), ["drop", "reap"]);
    }

    #[test]
    fn pty_failure_closes_the_guard_after_a_bounded_natural_wait() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let reap_events = Arc::clone(&events);

        let exit_code =
            reap_with_lifetime_guard(DropProbe(Arc::clone(&events)), true, None, |mode| {
                let mut events = reap_events.lock().expect("event log");
                match mode {
                    ReapMode::Natural => {
                        events.push("wait");
                        None
                    }
                    ReapMode::Contained => {
                        events.push("reap");
                        Some(9)
                    }
                }
            });

        assert_eq!(exit_code, 9);
        assert_eq!(*events.lock().expect("event log"), ["wait", "drop", "reap"]);
    }

    #[test]
    fn continuous_reader_activity_cannot_starve_exit_drain_deadline() {
        let (reader_sender, reader) = bounded(1);
        reader_sender.send(()).expect("prime reader");
        let started_at = Instant::now();
        let mut observed_exit = None;
        let mut next_poll = started_at;

        assert!(!child_exit_drain_expired(
            &mut observed_exit,
            &mut next_poll,
            started_at,
            || Some(7),
        ));

        for elapsed_ms in (10..250).step_by(10) {
            reader.try_recv().expect("reader stays active");
            reader_sender.try_send(()).expect("refill reader");
            assert!(!child_exit_drain_expired(
                &mut observed_exit,
                &mut next_poll,
                started_at + Duration::from_millis(elapsed_ms),
                || panic!("an observed child must not be polled again"),
            ));
        }

        assert!(child_exit_drain_expired(
            &mut observed_exit,
            &mut next_poll,
            started_at + CHILD_OUTPUT_DRAIN_GRACE,
            || panic!("an observed child must not be polled again"),
        ));
        assert_eq!(observed_exit.map(|(code, _)| code), Some(7));
    }

    #[test]
    fn button_events_form_ordering_barriers_for_coalesced_motion() {
        let (sender, receiver) = bounded(COMMAND_CAPACITY);
        let ingress = Mutex::new(IngressState {
            mouse_motion: Some(MouseInput {
                action: MouseAction::Move(None),
                column: 4,
                row: 2,
                modifiers: Modifiers::default(),
            }),
            ..IngressState::default()
        });

        try_send_ordered(
            &sender,
            &ingress,
            Command::Mouse(MouseInput {
                action: MouseAction::Press(MouseButton::Left),
                column: 4,
                row: 2,
                modifiers: Modifiers::default(),
            }),
            "test mouse ordering",
        )
        .expect("queue motion and press");

        let first = receiver.try_recv().expect("queued motion");
        let second = receiver.try_recv().expect("queued press");
        assert!(matches!(
            first.command,
            Command::Mouse(MouseInput {
                action: MouseAction::Move(None),
                ..
            })
        ));
        assert!(matches!(
            second.command,
            Command::Mouse(MouseInput {
                action: MouseAction::Press(MouseButton::Left),
                ..
            })
        ));
    }

    #[test]
    fn input_payloads_share_a_total_byte_budget() {
        let (sender, receiver) = bounded(COMMAND_CAPACITY);
        let ingress = Mutex::new(IngressState::default());

        let error = try_send_ordered(
            &sender,
            &ingress,
            Command::Input(vec![0; COMMAND_BYTE_CAPACITY + 1]),
            "test byte budget",
        )
        .expect_err("oversized payload must be refused");

        assert!(error.is_backpressure());
        assert!(receiver.is_empty());
    }

    #[test]
    fn writer_acknowledges_only_after_flushing_the_pty() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let (write_sender, write_receiver) = bounded(1);
        let (completion_sender, completion_receiver) = bounded(1);
        let writer_events = Arc::clone(&events);
        let writer = thread::spawn(move || {
            write_pty(
                Box::new(RecordingWriter(writer_events)),
                &write_receiver,
                &completion_sender,
            );
        });

        write_sender.send(vec![1, 2, 3]).expect("send PTY write");
        assert!(matches!(
            completion_receiver.recv().expect("write completion"),
            WriterMessage::Completed
        ));
        assert_eq!(*events.lock().expect("event log"), ["write", "flush"]);

        drop(write_sender);
        writer.join().expect("join writer");
    }

    #[test]
    fn stalled_writer_throttles_ui_and_reserves_parser_reply_capacity() {
        let (writer, receiver) = bounded(1);
        writer.send(vec![0]).expect("fill writer handoff");
        let mut pending = PendingWrites::default();
        pending
            .enqueue(vec![1; WRITE_HIGH_WATER - 1], WriteSource::Ui)
            .expect("queue UI input below the throttle point");

        assert_eq!(pending.flush_one(&writer), WriteFlush::Full);
        assert!(pending.accepts_ui_sources());

        pending
            .enqueue(vec![2; WRITE_BATCH_MAX], WriteSource::Ui)
            .expect("one selected UI batch may cross the throttle point");
        assert!(!pending.accepts_ui_sources());
        assert_eq!(pending.bytes, WRITE_UI_MAX_BYTES - 1);

        pending
            .enqueue(vec![3; WRITE_PARSER_RESERVE], WriteSource::Parser)
            .expect("parser replies retain reserved capacity");
        pending
            .enqueue(vec![4], WriteSource::Parser)
            .expect("parser replies may use the full reserve");
        assert_eq!(pending.bytes, WRITE_MAX_BYTES);
        assert!(
            pending.enqueue(vec![5], WriteSource::Parser).is_err(),
            "the parser reserve remains bounded"
        );

        assert_eq!(receiver.recv().expect("release writer handoff"), vec![0]);
        assert_eq!(pending.flush_one(&writer), WriteFlush::Sent);
        assert_eq!(pending.bytes, WRITE_MAX_BYTES);
        assert!(!pending.is_empty());
        assert_eq!(pending.flush_one(&writer), WriteFlush::Full);
        assert_eq!(
            receiver.recv().expect("receive in-flight PTY write").len(),
            WRITE_HIGH_WATER - 1
        );
        assert!(pending.complete_write());
        assert!(pending.bytes < WRITE_MAX_BYTES);
        assert!(
            !pending.complete_write(),
            "one write produces one completion"
        );
    }

    #[test]
    fn saturated_writer_keeps_paste_controls_live_and_defers_approval() {
        let mut writes = PendingWrites::default();
        writes
            .enqueue(vec![0; WRITE_HIGH_WATER], WriteSource::Ui)
            .expect("saturate UI writes");
        assert!(!writes.accepts_ui_sources());
        let encoded = encode_input(
            &KeyInput::paste("echo approved\necho second"),
            TerminalModes::default(),
        );
        assert!(encoded.requires_confirmation());

        let mut pending = Some(encoded.clone());
        let mut approved = None;
        assert_eq!(
            process_paste_action(
                PasteAction::Confirm(encoded.clone()),
                &mut pending,
                &mut approved
            ),
            PasteControl::Resume
        );
        assert!(pending.is_none());
        assert_eq!(approved, Some(encoded.approve()));
        assert!(
            !writes.accepts_ui_sources(),
            "approval does not bypass backpressure"
        );

        let cancel_input = encode_input(
            &KeyInput::paste("echo cancelled\necho second"),
            TerminalModes::default(),
        );
        let mut pending = Some(cancel_input);
        let mut approved = None;
        assert_eq!(
            process_paste_action(PasteAction::Cancel, &mut pending, &mut approved),
            PasteControl::Resume
        );
        assert!(pending.is_none());
        assert!(approved.is_none());
    }

    #[test]
    fn outstanding_write_keeps_resize_and_motion_pending() {
        let mut pending = PendingWrites::default();
        pending
            .enqueue(vec![0; WRITE_HIGH_WATER], WriteSource::Ui)
            .expect("fill pending writes to the UI throttle");
        assert!(!pending.accepts_ui_sources());

        let (_sender, receiver) = bounded(COMMAND_CAPACITY);
        let expected = GridSize::new(132, 43).expect("valid grid");
        let ingress = Mutex::new(IngressState {
            resize: Some(ResizeCommand {
                size: expected,
                sequence: 7,
                pixel_size: PixelSize::new(1_320, 860),
            }),
            mouse_motion: Some(MouseInput {
                action: MouseAction::Move(None),
                column: 3,
                row: 2,
                modifiers: Modifiers::default(),
            }),
            queued_bytes: 0,
        });

        let blocked = take_coalesced_work(&receiver, &ingress, pending.is_empty());

        assert!(blocked.resize.is_none());
        assert!(matches!(blocked.input, CoalescedInput::None));
        let state = ingress
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        assert_eq!(state.resize.expect("resize remains pending").size, expected);
        assert!(state.mouse_motion.is_some(), "mouse motion remains pending");
        drop(state);

        let ready = take_coalesced_work(&receiver, &ingress, true);
        assert_eq!(
            ready.resize.expect("resize follows write completion").size,
            expected
        );
        assert!(matches!(ready.input, CoalescedInput::Motion(_)));
    }

    #[test]
    fn saturated_writer_does_not_move_resize_ahead_of_queued_input() {
        let mut pending = PendingWrites::default();
        pending
            .enqueue(vec![0; WRITE_HIGH_WATER], WriteSource::Ui)
            .expect("fill pending writes to the UI throttle");
        assert!(!pending.accepts_ui_sources());

        let (sender, receiver) = bounded(COMMAND_CAPACITY);
        let ingress = Mutex::new(IngressState::default());
        try_send_ordered(
            &sender,
            &ingress,
            Command::Input(b"older input".to_vec()),
            "queue input before resize",
        )
        .expect("queue older input");
        let expected = GridSize::new(132, 43).expect("valid grid");
        ingress
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .resize = Some(ResizeCommand {
            size: expected,
            sequence: 7,
            pixel_size: PixelSize::new(1_320, 860),
        });

        let blocked = take_coalesced_work(&receiver, &ingress, pending.accepts_ui_sources());
        assert!(blocked.resize.is_none());
        assert!(matches!(blocked.input, CoalescedInput::None));
        assert_eq!(receiver.len(), 1, "older input remains queued");

        let input = take_coalesced_work(&receiver, &ingress, true);
        assert!(input.resize.is_none());
        assert!(matches!(input.input, CoalescedInput::Command(_)));
        assert!(input.wake_again, "the pending resize schedules more work");

        let resize = take_coalesced_work(&receiver, &ingress, true);
        assert_eq!(
            resize.resize.expect("newer resize remains pending").size,
            expected
        );
        assert!(matches!(resize.input, CoalescedInput::None));
    }

    #[test]
    fn queued_input_precedes_a_newer_coalesced_motion_atomically() {
        let (sender, receiver) = bounded(COMMAND_CAPACITY);
        let ingress = Mutex::new(IngressState::default());
        try_send_ordered(
            &sender,
            &ingress,
            Command::Mouse(MouseInput {
                action: MouseAction::Press(MouseButton::Left),
                column: 3,
                row: 2,
                modifiers: Modifiers::default(),
            }),
            "test ordered input",
        )
        .expect("queue press");
        ingress
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .mouse_motion = Some(MouseInput {
            action: MouseAction::Move(Some(MouseButton::Left)),
            column: 4,
            row: 2,
            modifiers: Modifiers::default(),
        });

        let first = take_coalesced_work(&receiver, &ingress, true);
        assert!(matches!(
            first.input,
            CoalescedInput::Command(QueuedCommand {
                command: Command::Mouse(MouseInput {
                    action: MouseAction::Press(MouseButton::Left),
                    ..
                }),
                ..
            })
        ));
        assert!(first.wake_again);

        let second = take_coalesced_work(&receiver, &ingress, true);
        assert!(matches!(
            second.input,
            CoalescedInput::Motion(MouseInput {
                action: MouseAction::Move(Some(MouseButton::Left)),
                ..
            })
        ));
    }

    #[test]
    fn resize_stays_behind_older_coalesced_motion() {
        let (sender, receiver) = bounded(COMMAND_CAPACITY);
        let first_size = GridSize::new(80, 24).expect("valid first grid");
        let second_size = GridSize::new(120, 40).expect("valid second grid");
        let ingress = Mutex::new(IngressState {
            resize: Some(ResizeCommand {
                size: first_size,
                sequence: 1,
                pixel_size: PixelSize::default(),
            }),
            mouse_motion: Some(MouseInput {
                action: MouseAction::Move(None),
                column: 79,
                row: 23,
                modifiers: Modifiers::default(),
            }),
            queued_bytes: 0,
        });

        set_ordered_resize(
            &sender,
            &ingress,
            ResizeCommand {
                size: second_size,
                sequence: 2,
                pixel_size: PixelSize::default(),
            },
        )
        .expect("queue resize behind motion");

        let first = take_coalesced_work(&receiver, &ingress, true);
        assert_eq!(first.resize.expect("resize before motion").size, first_size);
        assert!(matches!(
            first.input,
            CoalescedInput::Command(QueuedCommand {
                command: Command::Mouse(MouseInput {
                    action: MouseAction::Move(None),
                    column: 79,
                    row: 23,
                    ..
                }),
                ..
            })
        ));
        assert!(first.wake_again, "newer resize remains scheduled");

        let second = take_coalesced_work(&receiver, &ingress, true);
        assert_eq!(
            second.resize.expect("resize after motion").size,
            second_size
        );
        assert!(matches!(second.input, CoalescedInput::None));
    }

    #[test]
    fn resize_is_an_ordering_barrier_before_queued_input() {
        let (sender, receiver) = bounded(COMMAND_CAPACITY);
        let first_size = GridSize::new(80, 24).expect("valid first grid");
        let second_size = GridSize::new(120, 40).expect("valid second grid");
        let ingress = Mutex::new(IngressState {
            resize: Some(ResizeCommand {
                size: first_size,
                sequence: 1,
                pixel_size: PixelSize::default(),
            }),
            ..IngressState::default()
        });

        try_send_ordered(
            &sender,
            &ingress,
            Command::Input(b"input".to_vec()),
            "test resize ordering",
        )
        .expect("queue input behind resize");
        ingress
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .resize = Some(ResizeCommand {
            size: second_size,
            sequence: 2,
            pixel_size: PixelSize::default(),
        });

        let first = take_coalesced_work(&receiver, &ingress, true);
        assert_eq!(first.resize.expect("preceding resize").size, first_size);
        assert!(matches!(first.input, CoalescedInput::Command(_)));
        assert!(first.wake_again);

        let second = take_coalesced_work(&receiver, &ingress, true);
        assert_eq!(second.resize.expect("newer resize").size, second_size);
        assert!(matches!(second.input, CoalescedInput::None));
    }
}
