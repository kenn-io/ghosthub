//! Shared PTY process layer for parsed and byte-relay terminal workers.
//!
//! Owns command intake, PTY creation at the initial geometry, child spawn,
//! Windows Job Object containment, resize delivery, shutdown ordering, and
//! child reaping. Workers own their presentation semantics; this layer owns
//! the process lifetime exactly once.

use std::fmt;
use std::io::{Read, Write};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender, TrySendError, bounded};
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use surface::{GridSize, PixelSize};

use crate::windows_job::RelayJob;

pub(crate) const READ_BUFFER_SIZE: usize = 64 * 1024;
pub(crate) const CHILD_EXIT_POLL_INTERVAL: Duration = Duration::from_millis(50);
pub(crate) const CHILD_OUTPUT_DRAIN_GRACE: Duration = Duration::from_millis(250);
const REAP_ATTEMPTS: usize = 20;
const REAP_POLL_DELAY: Duration = Duration::from_millis(25);

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
    pub(crate) fn new(subject: &str, error: impl fmt::Display) -> Self {
        Self {
            message: format!("{subject}: {error}"),
            kind: WorkerErrorKind::Other,
        }
    }

    pub(crate) fn backpressure(subject: &str, error: impl fmt::Display) -> Self {
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

pub(crate) enum ReaderMessage {
    Bytes(Vec<u8>),
    Eof,
    Error(String),
}

/// One contained PTY child with its master handle and lifetime guard.
pub(crate) struct PtyProcess {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
    job: RelayJob,
}

/// A spawned PTY process together with its dedicated reader handoff and the
/// writer handle the consuming worker feeds from its own write path.
pub(crate) struct SpawnedPty {
    pub(crate) process: PtyProcess,
    pub(crate) reader: Receiver<ReaderMessage>,
    pub(crate) writer: Box<dyn Write + Send>,
}

impl PtyProcess {
    /// Open a PTY at the initial geometry, spawn the resolved client inside
    /// it, and contain the child before returning.
    ///
    /// A containment failure tears down the child before returning. The
    /// dedicated reader thread is already running on success; dropping the
    /// returned value kills the contained child through its Job Object.
    pub(crate) fn spawn(
        program: &std::ffi::OsStr,
        args: &[std::ffi::OsString],
        size: GridSize,
        pixel_size: PixelSize,
    ) -> Result<SpawnedPty, WorkerError> {
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
        // The client starts running before the Job Object assignment below:
        // portable_pty exposes no suspended-spawn, so a descendant forked in
        // that millisecond window escapes kill-on-close containment. This
        // accepted limitation is tracked for upstream suspended-spawn
        // support; the assignment-failure path still kills the client
        // itself.
        let child = pair
            .slave
            .spawn_command(command)
            .map_err(|error| WorkerError::new("spawn terminal client", error))?;
        drop(pair.slave);

        if let Err(error) = job.assign_and_verify(child.as_ref()) {
            tear_down_unstarted(writer, pair.master, child);
            return Err(WorkerError::new("contain terminal client", error));
        }

        let (reader_sender, reader_receiver) = bounded(1);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-pty-reader".to_owned())
            .spawn(move || read_pty(&mut reader, &reader_sender))
        {
            tear_down_unstarted(writer, pair.master, child);
            return Err(WorkerError::new("spawn PTY reader", error));
        }

        Ok(SpawnedPty {
            process: Self {
                master: pair.master,
                child,
                job,
            },
            reader: reader_receiver,
            writer,
        })
    }

    /// Apply one grid-and-pixel geometry to the PTY.
    pub(crate) fn resize(&self, size: GridSize, pixel_size: PixelSize) -> Result<(), WorkerError> {
        let pty_size = pty_size(size, pixel_size)?;
        self.master
            .resize(pty_size)
            .map_err(|error| WorkerError::new("resize PTY", error))
    }

    /// Observe the child's exit code without blocking.
    ///
    /// On unix this observation is non-reaping: the exited child stays a
    /// zombie so its PID — and therefore its process-group id — cannot
    /// recycle before teardown sweeps the group and then reaps it.
    pub(crate) fn poll_exit(&mut self) -> Option<u32> {
        #[cfg(unix)]
        {
            peek_child_exit(self.child.process_id())
        }
        #[cfg(not(unix))]
        {
            self.child
                .try_wait()
                .ok()
                .flatten()
                .map(|status| status.exit_code())
        }
    }

    /// Tear down the PTY and reap the child under the containment guard.
    ///
    /// A preserved natural exit is reaped before the guard closes; every
    /// other path closes the kill-on-close guard first and then collects the
    /// contained child.
    pub(crate) fn reap(self, preserve_natural_exit: bool, observed_exit: Option<u32>) -> u32 {
        let Self {
            master,
            mut child,
            job,
        } = self;
        drop(master);
        // Captured before the child is reaped, so the group id stays valid
        // through the sweep. Because poll_exit is non-reaping on unix, the
        // child is still an unreaped zombie here when it exited on its own.
        let group_pid = child.process_id();
        reap_with_lifetime_guard(
            job,
            preserve_natural_exit,
            observed_exit,
            |step| match step {
                ReapStep::Peek => peek_natural_exit(&mut *child, group_pid),
                ReapStep::Reap => reap_zombie(&mut *child),
                ReapStep::Contained => Some(reap_child(&mut *child)),
            },
            || kill_process_group(group_pid),
        )
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

pub(crate) fn child_exit_drain_expired(
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

pub(crate) fn wake_coalesced(sender: &Sender<()>, subject: &str) -> Result<(), WorkerError> {
    match sender.try_send(()) {
        Ok(()) | Err(TrySendError::Full(())) => Ok(()),
        Err(TrySendError::Disconnected(())) => {
            Err(WorkerError::new(subject, "terminal worker has stopped"))
        }
    }
}

/// Kill and reap a child whose startup could not complete, on every
/// platform: job containment only covers Windows, so nothing may rely on
/// it for cleanup.
fn tear_down_unstarted(
    writer: Box<dyn std::io::Write + Send>,
    master: Box<dyn portable_pty::MasterPty + Send>,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
) {
    drop(writer);
    drop(master);
    let _ignored = child.kill();
    let _ignored = child.wait();
}

/// Owns a spawned PTY until a worker's threads take it: a startup failure
/// that drops this guard kills and reaps the child instead of leaking it —
/// job containment only covers Windows.
pub(crate) struct StartupPty(Option<PtyProcess>);

impl StartupPty {
    pub(crate) fn new(process: PtyProcess) -> Self {
        Self(Some(process))
    }

    pub(crate) fn into_inner(mut self) -> PtyProcess {
        self.0.take().expect("startup guard consumed once")
    }
}

impl Drop for StartupPty {
    fn drop(&mut self) {
        if let Some(process) = self.0.take() {
            let _exit = process.reap(false, None);
        }
    }
}

fn reap_child(child: &mut dyn portable_pty::Child) -> u32 {
    // Forced teardown: sweep the whole group first so a descendant holding
    // the slave dies too, then take the direct child's status. Killing an
    // already-exited direct child is harmless, and polling for a natural
    // exit here would add up to half a second to every teardown on hosts
    // whose process-lifetime guard is a no-op — the relay joins this path
    // on every viewer disconnect.
    kill_process_group(child.process_id());
    if let Ok(Some(status)) = child.try_wait() {
        return status.exit_code();
    }
    let _ignored = child.kill();
    child.wait().map_or(u32::MAX, |status| status.exit_code())
}

/// Kill a PTY child's whole process group on POSIX. The child is a
/// session leader, so its descendants share the group; killing only the
/// direct child could leave a descendant holding the PTY slave open, which
/// keeps the relay's writer blocked in `write_all` and turns teardown's
/// thread joins — and everything serialized behind them — unbounded. The
/// pid is captured before the child is waited on, so the group id is
/// always live here. On Windows the Job object already contains the tree.
#[cfg(unix)]
fn kill_process_group(pid: Option<u32>) {
    if let Some(pid) = pid
        && let Ok(pid) = i32::try_from(pid)
    {
        // SAFETY: signalling a process group id derived from our own child.
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
        }
    }
}

#[cfg(not(unix))]
fn kill_process_group(_pid: Option<u32>) {}

/// Poll for a natural exit without reaping, so the exited child remains a
/// zombie that pins its process-group id until the caller sweeps and reaps.
fn peek_natural_exit(child: &mut dyn portable_pty::Child, pid: Option<u32>) -> Option<u32> {
    for _ in 0..REAP_ATTEMPTS {
        #[cfg(unix)]
        if let Some(code) = peek_child_exit(pid) {
            return Some(code);
        }
        #[cfg(not(unix))]
        if let Ok(Some(status)) = child.try_wait() {
            return Some(status.exit_code());
        }
        thread::sleep(REAP_POLL_DELAY);
    }
    let _ = (child, pid);
    None
}

/// Consume a child already confirmed exited by [`peek_natural_exit`]; the
/// authoritative exit code comes from this reaping wait.
fn reap_zombie(child: &mut dyn portable_pty::Child) -> Option<u32> {
    child
        .try_wait()
        .ok()
        .flatten()
        .map(|status| status.exit_code())
}

/// Non-reaping unix exit check: `WNOWAIT` leaves the child reapable, so its
/// PID and process-group id stay reserved until it is reaped explicitly.
#[cfg(unix)]
fn peek_child_exit(pid: Option<u32>) -> Option<u32> {
    let pid = i32::try_from(pid?).ok()?;
    let mut status: libc::c_int = 0;
    // SAFETY: querying our own child by pid; WNOWAIT leaves it reapable.
    let observed = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG | libc::WNOWAIT) };
    if observed != pid {
        return None;
    }
    if libc::WIFEXITED(status) {
        Some(libc::WEXITSTATUS(status) as u32)
    } else if libc::WIFSIGNALED(status) {
        Some(128 + libc::WTERMSIG(status) as u32)
    } else {
        None
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReapStep {
    /// Non-reaping check that the child exited on its own.
    Peek,
    /// Consume the confirmed zombie, after the group sweep.
    Reap,
    /// Forced termination of the group and the child.
    Contained,
}

fn reap_with_lifetime_guard<G, F, S>(
    guard: G,
    preserve_natural_exit: bool,
    observed_exit: Option<u32>,
    mut step: F,
    sweep_descendants: S,
) -> u32
where
    F: FnMut(ReapStep) -> Option<u32>,
    S: FnOnce(),
{
    if preserve_natural_exit && let Some(exit_code) = observed_exit.or_else(|| step(ReapStep::Peek))
    {
        // The child exited on its own and is still an unreaped zombie, so
        // its PID/PGID cannot recycle. Sweep any descendant holding the PTY
        // slave open — a writer blocked in write_all unblocks and the joins
        // stay bounded — then reap the zombie. The group signal cannot
        // reach the zombie leader, so its exit code is preserved.
        sweep_descendants();
        let reaped = step(ReapStep::Reap).unwrap_or(exit_code);
        drop(guard);
        return reaped;
    }
    drop(guard);
    step(ReapStep::Contained).unwrap_or(u32::MAX)
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
    use std::sync::{Arc, Mutex};

    use super::*;

    #[derive(Debug)]
    struct DropProbe(Arc<Mutex<Vec<&'static str>>>);

    impl Drop for DropProbe {
        fn drop(&mut self) {
            self.0.lock().expect("event log").push("drop");
        }
    }

    #[test]
    fn reported_exit_is_reaped_before_the_lifetime_guard_closes() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let reap_events = Arc::clone(&events);

        let exit_code = reap_with_lifetime_guard(
            DropProbe(Arc::clone(&events)),
            true,
            None,
            |step| match step {
                ReapStep::Peek => Some(7),
                ReapStep::Reap => {
                    reap_events.lock().expect("event log").push("reap");
                    Some(7)
                }
                ReapStep::Contained => unreachable!("a peeked exit never forces containment"),
            },
            || {},
        );

        assert_eq!(exit_code, 7);
        assert_eq!(*events.lock().expect("event log"), ["reap", "drop"]);
    }

    #[test]
    fn explicit_shutdown_closes_the_lifetime_guard_before_reaping() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let reap_events = Arc::clone(&events);

        let exit_code = reap_with_lifetime_guard(
            DropProbe(Arc::clone(&events)),
            false,
            None,
            |step| {
                assert_eq!(step, ReapStep::Contained);
                reap_events.lock().expect("event log").push("reap");
                Some(1)
            },
            || {},
        );

        assert_eq!(exit_code, 1);
        assert_eq!(*events.lock().expect("event log"), ["drop", "reap"]);
    }

    #[test]
    fn pty_failure_closes_the_guard_after_a_bounded_natural_wait() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let reap_events = Arc::clone(&events);

        let exit_code = reap_with_lifetime_guard(
            DropProbe(Arc::clone(&events)),
            true,
            None,
            |step| {
                let mut events = reap_events.lock().expect("event log");
                match step {
                    ReapStep::Peek => {
                        events.push("wait");
                        None
                    }
                    ReapStep::Reap => unreachable!("no peeked exit to reap"),
                    ReapStep::Contained => {
                        events.push("reap");
                        Some(9)
                    }
                }
            },
            || {},
        );

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
}
