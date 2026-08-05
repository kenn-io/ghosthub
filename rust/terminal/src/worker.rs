use std::fmt;
use std::io::{Read, Write};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender, TryRecvError, bounded, select, unbounded};
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use session::AttachPlan;
use surface::{GridSize, SurfaceStore};

use crate::windows_job::RelayJob;
use crate::{ClipboardReadRequest, ClipboardWrite, TerminalEngine};

const READ_BUFFER_SIZE: usize = 64 * 1024;

pub enum TerminalEvent {
    ClipboardWrite(ClipboardWrite),
    ClipboardRead(ClipboardReadRequest),
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
    Resize(GridSize),
    Shutdown,
}

enum ReaderMessage {
    Bytes(Vec<u8>),
    Eof,
    Error(String),
}

pub struct TerminalWorker {
    commands: Sender<Command>,
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
        let pty_size = pty_size(size)?;
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

        let engine = TerminalEngine::new(size);
        let surface = engine.surface_handle();
        let (commands, command_receiver) = unbounded();
        let (events_sender, events) = unbounded();
        let (reader_sender, reader_receiver) = bounded(1);

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
                    writer,
                    child,
                    job,
                    &command_receiver,
                    &reader_receiver,
                    &events_sender,
                );
            })
            .map_err(|error| WorkerError::new("spawn terminal worker", error))?;

        Ok(Self {
            commands,
            events,
            surface,
            thread: Some(worker_thread),
        })
    }

    #[must_use]
    pub fn surface(&self) -> &SurfaceStore {
        &self.surface
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
        self.commands
            .send(Command::Resize(size))
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
        let _ignored = self.commands.send(Command::Shutdown);
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

#[allow(clippy::too_many_arguments)]
fn run_worker(
    mut engine: TerminalEngine,
    master: Box<dyn MasterPty + Send>,
    mut writer: Box<dyn Write + Send>,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    _job: RelayJob,
    commands: &Receiver<Command>,
    reader: &Receiver<ReaderMessage>,
    events: &Sender<TerminalEvent>,
) {
    loop {
        select! {
            recv(commands) -> message => match message {
                Ok(Command::Input(bytes)) => {
                    if let Err(error) = writer.write_all(&bytes).and_then(|()| writer.flush()) {
                        let _ignored = events.send(TerminalEvent::Error(error.to_string()));
                        break;
                    }
                }
                Ok(Command::Resize(size)) => {
                    match pty_size(size).and_then(|size| master.resize(size).map_err(|error| WorkerError::new("resize PTY", error))) {
                        Ok(()) => engine.resize(size),
                        Err(error) => { let _ignored = events.send(TerminalEvent::Error(error.to_string())); }
                    }
                }
                Ok(Command::Shutdown) | Err(_) => break,
            },
            recv(reader) -> message => match message {
                Ok(ReaderMessage::Bytes(bytes)) => {
                    let output = engine.process(&bytes);
                    for bytes in output.pty_writes {
                        if let Err(error) = writer.write_all(&bytes) {
                            let _ignored = events.send(TerminalEvent::Error(error.to_string()));
                            break;
                        }
                    }
                    for write in output.clipboard_writes {
                        let _ignored = events.send(TerminalEvent::ClipboardWrite(write));
                    }
                    for read in output.clipboard_reads {
                        let _ignored = events.send(TerminalEvent::ClipboardRead(read));
                    }
                }
                Ok(ReaderMessage::Error(error)) => {
                    let _ignored = events.send(TerminalEvent::Error(error));
                    break;
                }
                Ok(ReaderMessage::Eof) | Err(_) => break,
            },
            default(Duration::from_millis(50)) => {
                if let Ok(Some(status)) = child.try_wait() {
                    let _ignored = events.send(TerminalEvent::Exited(status.exit_code()));
                    break;
                }
            }
        }
    }

    drop(writer);
    drop(master);
    for _ in 0..20 {
        if child.try_wait().is_ok_and(|status| status.is_some()) {
            return;
        }
        thread::sleep(Duration::from_millis(25));
    }
    let _ignored = child.kill();
    let _ignored = child.wait();
}

fn pty_size(size: GridSize) -> Result<PtySize, WorkerError> {
    Ok(PtySize {
        rows: u16::try_from(size.rows())
            .map_err(|error| WorkerError::new("PTY row count", error))?,
        cols: u16::try_from(size.columns())
            .map_err(|error| WorkerError::new("PTY column count", error))?,
        pixel_width: 0,
        pixel_height: 0,
    })
}
