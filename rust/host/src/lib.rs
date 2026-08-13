//! WSL host resolution and tmux inventory.

use std::ffi::{OsStr, OsString};
use std::io::{self, Read, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub use model::DiagnosticKind as HostErrorKind;

mod command_process;
mod herdr;
mod kwt;
#[cfg(windows)]
mod windows_system;
mod wsl;
mod zellij;

pub use kwt::{
    KwtBranchCandidate, KwtBundle, KwtDirectoryWorkspace, KwtInventory, KwtProject,
    KwtProjectInventory, KwtWorktree, KwtWorktreeCreate, KwtWorktreeOpen,
    kwt_command_failure_message,
};
pub use wsl::{
    AdmissionAttacher, AttachTerm, CreationReceipt, HerdrInventory, HostError, HostSnapshot,
    KwtHostSnapshot, LiveSessionTarget, SystemWslPresence, WslConfig, WslEndpoint, WslExecutable,
    WslHost, WslPresence, WslRuntimeIdentity, ZellijInventory,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Debug, Default)]
struct CancellationState {
    cancelled: AtomicBool,
    mutex: Mutex<()>,
    wake: Condvar,
}

#[derive(Clone, Debug, Default)]
pub struct CancellationToken(Arc<CancellationState>);

impl CancellationToken {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        let _guard = self
            .0
            .mutex
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.0.cancelled.store(true, Ordering::Release);
        self.0.wake.notify_all();
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Acquire)
    }

    /// Wait until cancellation or the timeout expires.
    ///
    /// Returns `true` when cancellation woke the wait.
    #[must_use]
    pub fn wait_cancelled(&self, timeout: Duration) -> bool {
        if self.is_cancelled() {
            return true;
        }
        let guard = self
            .0
            .mutex
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _wait = self
            .0
            .wake
            .wait_timeout_while(guard, timeout, |()| !self.is_cancelled())
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.is_cancelled()
    }
}

pub trait CommandRunner: Send + Sync {
    /// Run one executable with exact argv and capture all output.
    ///
    /// # Errors
    ///
    /// Returns the platform spawn or wait error.
    fn run(
        &self,
        program: &OsStr,
        args: &[OsString],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput>;

    /// Run one executable with exact argv and finite binary standard input.
    ///
    /// Implementations that do not support input may retain the default for
    /// empty payloads. KWT helper installation is the only production caller
    /// that currently requires a non-empty payload.
    ///
    /// # Errors
    ///
    /// Returns the platform spawn, input, or wait error. The default rejects
    /// non-empty input as unsupported.
    fn run_with_input(
        &self,
        program: &OsStr,
        args: &[OsString],
        input: &[u8],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput> {
        if input.is_empty() {
            self.run(program, args, cancellation, timeout)
        } else {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "command runner does not accept standard input",
            ))
        }
    }
}

impl<R: CommandRunner + ?Sized> CommandRunner for Arc<R> {
    fn run(
        &self,
        program: &OsStr,
        args: &[OsString],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput> {
        (**self).run(program, args, cancellation, timeout)
    }

    fn run_with_input(
        &self,
        program: &OsStr,
        args: &[OsString],
        input: &[u8],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput> {
        (**self).run_with_input(program, args, input, cancellation, timeout)
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct StdCommandRunner;

const OUTPUT_CHUNK_BYTES: usize = 16 * 1024;
const OUTPUT_CHANNEL_DEPTH: usize = 16;
const MAX_CAPTURE_BYTES: usize = 8 * 1024 * 1024;
const OUTPUT_DRAIN_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy)]
enum OutputStream {
    Stdout,
    Stderr,
}

enum ReaderEvent {
    Chunk(OutputStream, Vec<u8>),
    Done(OutputStream, io::Result<()>),
}

#[derive(Default)]
struct CapturedOutput {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    stdout_done: bool,
    stderr_done: bool,
    reader_error: Option<io::Error>,
}

impl CommandRunner for StdCommandRunner {
    fn run(
        &self,
        program: &OsStr,
        args: &[OsString],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput> {
        run_command(program, args, None, cancellation, timeout)
    }

    fn run_with_input(
        &self,
        program: &OsStr,
        args: &[OsString],
        input: &[u8],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput> {
        run_command(program, args, Some(input), cancellation, timeout)
    }
}

#[allow(clippy::too_many_lines)]
fn run_command(
    program: &OsStr,
    args: &[OsString],
    input: Option<&[u8]>,
    cancellation: &CancellationToken,
    timeout: Duration,
) -> io::Result<CommandOutput> {
    let mut command = Command::new(program);
    command_process::prepare(&mut command);
    if input.is_some() {
        command.stdin(Stdio::piped());
    }
    let mut child = command
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut containment = match command_process::CommandContainment::attach(&mut child) {
        Ok(containment) => containment,
        Err(error) => {
            let _ignored = child.kill();
            let _ignored = child.wait();
            return Err(error);
        }
    };
    let stdin = input
        .map(|input| {
            let mut stdin = child.stdin.take().ok_or_else(|| {
                io::Error::new(io::ErrorKind::BrokenPipe, "child stdin was not captured")
            })?;
            let input = input.to_vec();
            Ok::<_, io::Error>(thread::spawn(move || {
                let result = stdin.write_all(&input);
                drop(stdin);
                result
            }))
        })
        .transpose()?;
    let stdout = child.stdout.take().ok_or_else(|| {
        io::Error::new(io::ErrorKind::BrokenPipe, "child stdout was not captured")
    })?;
    let stderr = child.stderr.take().ok_or_else(|| {
        io::Error::new(io::ErrorKind::BrokenPipe, "child stderr was not captured")
    })?;
    let (sender, receiver) = sync_channel(OUTPUT_CHANNEL_DEPTH);
    let stdout = spawn_reader(stdout, OutputStream::Stdout, sender.clone());
    let stderr = spawn_reader(stderr, OutputStream::Stderr, sender);
    let mut captured = CapturedOutput::default();
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Err(error) = drain_available(&receiver, &mut captured) {
            terminate_command(&mut child, &mut containment);
            finish_or_detach_readers(
                &receiver,
                &mut captured,
                &CancellationToken::new(),
                Instant::now() + OUTPUT_DRAIN_TIMEOUT,
                stdout,
                stderr,
            );
            finish_or_detach_writer(stdin);
            return Err(error);
        }
        if cancellation.is_cancelled() {
            terminate_command(&mut child, &mut containment);
            finish_or_detach_readers(
                &receiver,
                &mut captured,
                &CancellationToken::new(),
                Instant::now() + OUTPUT_DRAIN_TIMEOUT,
                stdout,
                stderr,
            );
            finish_or_detach_writer(stdin);
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "command cancelled",
            ));
        }
        if Instant::now() >= deadline {
            terminate_command(&mut child, &mut containment);
            finish_or_detach_readers(
                &receiver,
                &mut captured,
                &CancellationToken::new(),
                Instant::now() + OUTPUT_DRAIN_TIMEOUT,
                stdout,
                stderr,
            );
            finish_or_detach_writer(stdin);
            return Err(io::Error::new(io::ErrorKind::TimedOut, "command timed out"));
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(error) => {
                terminate_command(&mut child, &mut containment);
                finish_or_detach_readers(
                    &receiver,
                    &mut captured,
                    &CancellationToken::new(),
                    Instant::now() + OUTPUT_DRAIN_TIMEOUT,
                    stdout,
                    stderr,
                );
                finish_or_detach_writer(stdin);
                return Err(error);
            }
        }
        thread::sleep(Duration::from_millis(10));
    };
    containment.terminate();
    finish_readers(
        &receiver,
        &mut captured,
        cancellation,
        Instant::now() + OUTPUT_DRAIN_TIMEOUT,
    )?;
    join_readers(stdout, stderr)?;
    if let Some(stdin) = stdin {
        stdin
            .join()
            .map_err(|_| io::Error::other("command input writer panicked"))??;
    }
    if let Some(error) = captured.reader_error {
        return Err(error);
    }
    Ok(CommandOutput {
        status: status.code().unwrap_or(-1),
        stdout: captured.stdout,
        stderr: captured.stderr,
    })
}

fn finish_or_detach_writer(writer: Option<thread::JoinHandle<io::Result<()>>>) {
    if let Some(writer) = writer
        && writer.is_finished()
    {
        let _ignored = writer.join();
    }
    // A writer still blocked in the platform pipe is detached. Process-group
    // termination closes the read side and lets it settle without blocking
    // cancellation or the refresh runtime.
}

fn finish_or_detach_readers(
    receiver: &Receiver<ReaderEvent>,
    captured: &mut CapturedOutput,
    cancellation: &CancellationToken,
    deadline: Instant,
    stdout: thread::JoinHandle<()>,
    stderr: thread::JoinHandle<()>,
) {
    if finish_readers(receiver, captured, cancellation, deadline).is_ok() {
        let _ignored = join_readers(stdout, stderr);
    }
    // Dropping unfinished handles detaches only the bounded reader threads.
    // Their senders unblock as soon as this function's receiver is dropped.
}

fn spawn_reader(
    reader: impl Read + Send + 'static,
    stream: OutputStream,
    sender: SyncSender<ReaderEvent>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || read_chunks(reader, stream, &sender))
}

fn read_chunks(mut reader: impl Read, stream: OutputStream, sender: &SyncSender<ReaderEvent>) {
    let result = loop {
        let mut chunk = vec![0; OUTPUT_CHUNK_BYTES];
        match reader.read(&mut chunk) {
            Ok(0) => break Ok(()),
            Ok(read) => {
                chunk.truncate(read);
                if sender.send(ReaderEvent::Chunk(stream, chunk)).is_err() {
                    return;
                }
            }
            Err(error) => break Err(error),
        }
    };
    let _ignored = sender.send(ReaderEvent::Done(stream, result));
}

fn drain_available(
    receiver: &Receiver<ReaderEvent>,
    captured: &mut CapturedOutput,
) -> io::Result<()> {
    loop {
        match receiver.try_recv() {
            Ok(event) => capture_event(captured, event)?,
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => return Ok(()),
        }
    }
}

fn finish_readers(
    receiver: &Receiver<ReaderEvent>,
    captured: &mut CapturedOutput,
    cancellation: &CancellationToken,
    deadline: Instant,
) -> io::Result<()> {
    let mut cancelled = false;
    while !captured.stdout_done || !captured.stderr_done {
        if cancellation.is_cancelled() {
            cancelled = true;
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "command output collection timed out",
            ));
        }
        match receiver.recv_timeout(Duration::from_millis(10)) {
            Ok(event) => capture_event(captured, event)?,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "command output readers disconnected",
                ));
            }
        }
    }
    if cancelled {
        Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "command output collection cancelled",
        ))
    } else {
        Ok(())
    }
}

fn capture_event(captured: &mut CapturedOutput, event: ReaderEvent) -> io::Result<()> {
    match event {
        ReaderEvent::Chunk(OutputStream::Stdout, chunk) => {
            append_capped(&mut captured.stdout, &chunk)?;
        }
        ReaderEvent::Chunk(OutputStream::Stderr, chunk) => {
            append_capped(&mut captured.stderr, &chunk)?;
        }
        ReaderEvent::Done(OutputStream::Stdout, result) => {
            captured.stdout_done = true;
            record_reader_result(captured, result);
        }
        ReaderEvent::Done(OutputStream::Stderr, result) => {
            captured.stderr_done = true;
            record_reader_result(captured, result);
        }
    }
    Ok(())
}

fn append_capped(output: &mut Vec<u8>, chunk: &[u8]) -> io::Result<()> {
    if output.len().saturating_add(chunk.len()) > MAX_CAPTURE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "command output exceeded capture limit",
        ));
    }
    output.extend_from_slice(chunk);
    Ok(())
}

fn record_reader_result(captured: &mut CapturedOutput, result: io::Result<()>) {
    if let Err(error) = result
        && captured.reader_error.is_none()
    {
        captured.reader_error = Some(error);
    }
}

fn terminate_command(
    child: &mut std::process::Child,
    containment: &mut command_process::CommandContainment,
) {
    containment.terminate();
    let _ignored = child.kill();
    let _ignored = child.wait();
}

fn join_readers(stdout: thread::JoinHandle<()>, stderr: thread::JoinHandle<()>) -> io::Result<()> {
    stdout
        .join()
        .map_err(|_| io::Error::other("command stdout reader panicked"))?;
    stderr
        .join()
        .map_err(|_| io::Error::other("command stderr reader panicked"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captured_output_has_a_hard_limit() {
        let mut output = vec![0; MAX_CAPTURE_BYTES - 1];

        let error = append_capped(&mut output, &[1, 2])
            .expect_err("capture beyond the fixed limit must fail");

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(output.len(), MAX_CAPTURE_BYTES - 1);
    }

    #[test]
    fn cancellation_wakes_a_timed_wait() {
        let cancellation = CancellationToken::new();
        let waiting = cancellation.clone();
        let (sender, receiver) = std::sync::mpsc::channel();
        let thread = thread::spawn(move || {
            sender
                .send(waiting.wait_cancelled(Duration::from_secs(30)))
                .expect("receiver remains live");
        });

        cancellation.cancel();

        assert!(
            receiver
                .recv_timeout(Duration::from_secs(1))
                .expect("wait wakes promptly")
        );
        thread.join().expect("wait thread exits");
    }

    #[test]
    fn cancellation_uses_the_waiter_mutex_for_notification() {
        let cancellation = CancellationToken::new();
        let guard = cancellation.0.mutex.lock().expect("cancellation mutex");
        let cancelling = cancellation.clone();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let child_barrier = Arc::clone(&barrier);
        let (sender, receiver) = std::sync::mpsc::channel();
        let thread = thread::spawn(move || {
            child_barrier.wait();
            cancelling.cancel();
            sender.send(()).expect("receiver remains live");
        });

        barrier.wait();
        assert!(
            receiver.recv_timeout(Duration::from_millis(50)).is_err(),
            "cancel must synchronize with the condition-variable mutex"
        );
        drop(guard);

        receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("cancel proceeds after the waiter mutex is released");
        assert!(cancellation.is_cancelled());
        thread.join().expect("cancel thread exits");
    }
}
