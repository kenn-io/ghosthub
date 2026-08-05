use std::fmt;
use std::io::{Read, Write};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender, TryRecvError, bounded, select, unbounded};
use input::{EncodedInput, KeyInput, MouseInput, encode_input, encode_mouse};
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use session::AttachPlan;
use surface::{GridSize, PixelSize, SurfaceStore};

use crate::windows_job::RelayJob;
use crate::{ClipboardReadRequest, ClipboardWrite, TerminalEngine};

const READ_BUFFER_SIZE: usize = 64 * 1024;
const EVENT_CAPACITY: usize = 64;

pub enum TerminalEvent {
    ClipboardWrite(ClipboardWrite),
    ClipboardRead(ClipboardReadRequest),
    ConfirmPaste(EncodedInput),
    Exited(u32),
    Error(String),
}

#[derive(Debug)]
pub struct WorkerError(String);

impl WorkerError {
    fn new(subject: &str, error: impl fmt::Display) -> Self {
        Self(format!("{subject}: {error}"))
    }
}

impl fmt::Display for WorkerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for WorkerError {}

enum Command {
    Input(Vec<u8>),
    Key(KeyInput),
    Mouse(MouseInput),
    ConfirmPaste(EncodedInput),
    Resize {
        size: GridSize,
        sequence: u64,
        pixel_size: PixelSize,
    },
}

enum ReaderMessage {
    Bytes(Vec<u8>),
    Eof,
    Error(String),
}

pub struct TerminalWorker {
    commands: Sender<Command>,
    shutdown: Sender<()>,
    events: Receiver<TerminalEvent>,
    surface: Arc<SurfaceStore>,
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
        Self::attach_with_metadata(plan, size, 0, PixelSize::default())
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

        let mut command = CommandBuilder::new(plan.program());
        command.args(plan.args());
        let mut child = pair
            .slave
            .spawn_command(command)
            .map_err(|error| WorkerError::new("spawn attach client", error))?;
        drop(pair.slave);

        if let Err(error) = job.assign_and_verify(child.as_ref()) {
            drop(writer);
            drop(pair.master);
            let _ignored = child.kill();
            let _ignored = child.wait();
            return Err(WorkerError::new("contain attach client", error));
        }

        let engine = TerminalEngine::with_geometry(
            size,
            resize_sequence,
            pixel_size,
            crate::ClipboardPolicy::default(),
        );
        let surface = engine.surface_handle();
        let (commands, command_receiver) = unbounded();
        let (shutdown, shutdown_receiver) = bounded(1);
        let (events_sender, events) = bounded(EVENT_CAPACITY);
        let (reader_sender, reader_receiver) = bounded(1);
        let (write_sender, write_receiver) = bounded(1);

        let writer_errors = reader_sender.clone();
        thread::Builder::new()
            .name("ghosthub-pty-writer".to_owned())
            .spawn(move || write_pty(writer, &write_receiver, &writer_errors))
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
                    &shutdown_receiver,
                    &reader_receiver,
                    &write_sender,
                    &events_sender,
                );
            })
            .map_err(|error| WorkerError::new("spawn terminal worker", error))?;

        Ok(Self {
            commands,
            shutdown,
            events,
            surface,
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

    /// Queue one neutral key or paste event for mode-aware encoding.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn send_key(&self, input: KeyInput) -> Result<(), WorkerError> {
        self.commands
            .send(Command::Key(input))
            .map_err(|error| WorkerError::new("send terminal key", error))
    }

    /// Queue one grid-relative mouse event for mode-aware SGR encoding.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn send_mouse(&self, input: MouseInput) -> Result<(), WorkerError> {
        self.commands
            .send(Command::Mouse(input))
            .map_err(|error| WorkerError::new("send terminal mouse event", error))
    }

    /// Approve and queue a paste previously reported for confirmation.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn confirm_paste(&self, input: EncodedInput) -> Result<(), WorkerError> {
        self.commands
            .send(Command::ConfirmPaste(input))
            .map_err(|error| WorkerError::new("confirm terminal paste", error))
    }

    /// Send already-authorized bytes to the attached client.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal worker has stopped.
    pub fn send_bytes(&self, bytes: Vec<u8>) -> Result<(), WorkerError> {
        self.commands
            .send(Command::Input(bytes))
            .map_err(|error| WorkerError::new("send terminal input", error))
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
        self.commands
            .send(Command::Resize {
                size,
                sequence,
                pixel_size,
            })
            .map_err(|error| WorkerError::new("send terminal resize", error))
    }

    /// Read one pending semantic terminal event without blocking.
    ///
    /// # Errors
    ///
    /// Returns an error after the terminal event channel has disconnected.
    pub fn try_event(&self) -> Result<Option<TerminalEvent>, WorkerError> {
        match self.events.try_recv() {
            Ok(event) => Ok(Some(event)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(error @ TryRecvError::Disconnected) => {
                Err(WorkerError::new("receive terminal event", error))
            }
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
    errors: &Sender<ReaderMessage>,
) {
    while let Ok(bytes) = receiver.recv() {
        if let Err(error) = writer.write_all(&bytes).and_then(|()| writer.flush()) {
            let _ignored = errors.send(ReaderMessage::Error(error.to_string()));
            return;
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn run_worker(
    mut engine: TerminalEngine,
    master: Box<dyn MasterPty + Send>,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    job: RelayJob,
    commands: &Receiver<Command>,
    shutdown: &Receiver<()>,
    reader: &Receiver<ReaderMessage>,
    writer: &Sender<Vec<u8>>,
    events: &Sender<TerminalEvent>,
) {
    let mut report_exit = false;
    let mut reported_exit = false;
    'worker: loop {
        select! {
            recv(shutdown) -> _ => break,
            recv(commands) -> message => match message {
                Ok(Command::Input(bytes)) => {
                    if !queue_write(writer, shutdown, bytes) {
                        break 'worker;
                    }
                }
                Ok(Command::Key(input)) => {
                    let encoded = encode_input(&input, engine.modes());
                    if encoded.requires_confirmation() {
                        if !emit_event(events, shutdown, TerminalEvent::ConfirmPaste(encoded)) {
                            break 'worker;
                        }
                    } else if !queue_write(writer, shutdown, encoded.approve()) {
                        break 'worker;
                    }
                }
                Ok(Command::Mouse(input)) => {
                    let encoded = encode_mouse(input, engine.modes());
                    if !encoded.is_empty() && !queue_write(writer, shutdown, encoded) {
                        break 'worker;
                    }
                }
                Ok(Command::ConfirmPaste(input)) => {
                    if !queue_write(writer, shutdown, input.approve()) {
                        break 'worker;
                    }
                }
                Ok(Command::Resize { size, sequence, pixel_size }) => {
                    match pty_size(size, pixel_size).and_then(|size| master.resize(size).map_err(|error| WorkerError::new("resize PTY", error))) {
                        Ok(()) => engine.resize_with_metadata(size, sequence, pixel_size),
                        Err(error) => if !emit_event(events, shutdown, TerminalEvent::Error(error.to_string())) {
                            break 'worker;
                        },
                    }
                }
                Err(_) => break,
            },
            recv(reader) -> message => match message {
                Ok(ReaderMessage::Bytes(bytes)) => {
                    let output = engine.process(&bytes);
                    for bytes in output.pty_writes {
                        if !queue_write(writer, shutdown, bytes) {
                            break 'worker;
                        }
                    }
                    for write in output.clipboard_writes {
                        if !emit_event(events, shutdown, TerminalEvent::ClipboardWrite(write)) {
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
            default(Duration::from_millis(50)) => {
                if let Ok(Some(status)) = child.try_wait() {
                    let _ignored = emit_event(events, shutdown, TerminalEvent::Exited(status.exit_code()));
                    reported_exit = true;
                    break 'worker;
                }
            }
        }
    }

    drop(master);
    drop(job);
    let exit_code = reap_child(&mut *child);
    if report_exit && !reported_exit {
        let _ignored = emit_event(events, shutdown, TerminalEvent::Exited(exit_code));
    }
}

fn queue_write(writer: &Sender<Vec<u8>>, shutdown: &Receiver<()>, bytes: Vec<u8>) -> bool {
    select! {
        send(writer, bytes) -> result => result.is_ok(),
        recv(shutdown) -> _ => false,
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
    for _ in 0..20 {
        if let Ok(Some(status)) = child.try_wait() {
            return status.exit_code();
        }
        thread::sleep(Duration::from_millis(25));
    }
    let _ignored = child.kill();
    child.wait().map_or(u32::MAX, |status| status.exit_code())
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
