//! Parserless byte relay between one PTY client and one remote viewer.
//!
//! The relay moves raw PTY output into a bounded per-connection queue and
//! client bytes back into the PTY with no VT interpreter anywhere on the
//! path: no parsing, no mode tracking, no reply synthesis. The only bytes
//! ever written to the PTY are bytes the client sent. A relay is single-use;
//! a viewer that disconnects creates a fresh attachment rather than resuming
//! this one.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender, TrySendError, bounded, select};
use session::{AttachPlan, HerdrAttachPlan, ZellijAttachPlan};
use surface::{GridSize, PixelSize};

use crate::pty::{
    CHILD_EXIT_POLL_INTERVAL, PtyProcess, ReaderMessage, SpawnedPty, StartupPty, WorkerError,
    child_exit_drain_expired,
};

const INPUT_CAPACITY: usize = 256;
/// Bound on undelivered client input bytes; a producer exceeding it gets
/// a backpressure refusal. Public so transport tests can size overflow
/// scenarios against the real budget.
pub const INPUT_BYTE_CAPACITY: usize = 1024 * 1024;

/// One delivery from the relay's bounded output queue.
#[derive(Debug, Eq, PartialEq)]
pub enum RelayOutput {
    /// Raw PTY output bytes, delivered in order without interpretation.
    Bytes(Vec<u8>),
    /// The relay's terminal outcome, delivered after every queued byte.
    Disconnected(RelayDisconnect),
}

/// Why a relay stopped. Each relay reports exactly one outcome, after all
/// previously queued output has been drained.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RelayDisconnect {
    /// The PTY client exited; remaining output was drained first.
    Exited { code: u32 },
    /// The viewer failed to drain the bounded output queue in time. The
    /// stream is cut cleanly: nothing after the last delivered byte was
    /// dropped mid-stream, and the client and PTY are torn down.
    Backpressure,
    /// PTY input or output failed.
    Failed(String),
    /// The owning handle shut the relay down.
    Closed,
}

struct ResizeRequest {
    size: GridSize,
    pixel_size: PixelSize,
}

/// Client requests in submission order. Input and resize share one ordered
/// queue so a write can never overtake the resize submitted before it.
enum Ingress {
    Bytes(Vec<u8>),
    Resize(ResizeRequest),
}

#[derive(Debug, Eq, PartialEq)]
struct OutputOverflow;

#[derive(Default)]
struct OutputState {
    chunks: VecDeque<Vec<u8>>,
    bytes: usize,
    disconnect: Option<RelayDisconnect>,
}

/// Bounded byte-accounted handoff from the relay thread to one viewer.
struct OutputQueue {
    max_bytes: usize,
    state: Mutex<OutputState>,
    ready: Condvar,
}

impl OutputQueue {
    fn new(max_bytes: usize) -> Self {
        Self {
            max_bytes,
            state: Mutex::new(OutputState::default()),
            ready: Condvar::new(),
        }
    }

    /// Queue one output chunk, refusing it when the viewer has not drained
    /// within the bound. A refused chunk is never partially delivered; the
    /// producer must close the stream with a backpressure outcome.
    fn push(&self, chunk: Vec<u8>) -> Result<(), OutputOverflow> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.disconnect.is_some() {
            return Ok(());
        }
        let total = state.bytes.saturating_add(chunk.len());
        if total > self.max_bytes {
            return Err(OutputOverflow);
        }
        state.bytes = total;
        state.chunks.push_back(chunk);
        drop(state);
        self.ready.notify_all();
        Ok(())
    }

    /// Record the relay's terminal outcome. The first outcome wins; queued
    /// bytes remain drainable ahead of it.
    fn close(&self, disconnect: RelayDisconnect) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.disconnect.get_or_insert(disconnect);
        drop(state);
        self.ready.notify_all();
    }

    /// Wait up to `timeout` for the next delivery. Returns `None` on
    /// timeout; after the terminal outcome drains, repeats it.
    fn pop(&self, timeout: Duration) -> Option<RelayOutput> {
        let deadline = Instant::now().checked_add(timeout);
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        loop {
            if let Some(chunk) = state.chunks.pop_front() {
                state.bytes = state.bytes.saturating_sub(chunk.len());
                return Some(RelayOutput::Bytes(chunk));
            }
            if let Some(disconnect) = &state.disconnect {
                return Some(RelayOutput::Disconnected(disconnect.clone()));
            }
            let remaining = deadline?.checked_duration_since(Instant::now())?;
            let (next, wait) = self
                .ready
                .wait_timeout(state, remaining)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state = next;
            if wait.timed_out() && state.chunks.is_empty() && state.disconnect.is_none() {
                return None;
            }
        }
    }
}

fn reserve_input_bytes(budget: &AtomicUsize, len: usize) -> bool {
    let mut current = budget.load(Ordering::Acquire);
    loop {
        let Some(next) = current.checked_add(len) else {
            return false;
        };
        if next > INPUT_BYTE_CAPACITY {
            return false;
        }
        match budget.compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => return true,
            Err(observed) => current = observed,
        }
    }
}

fn release_input_bytes(budget: &AtomicUsize, len: usize) {
    let _previous = budget.fetch_sub(len, Ordering::AcqRel);
}

/// Byte relay worker for one remote viewer's PTY client.
///
/// Construction requires the viewer's real initial geometry; the PTY opens
/// at that size and the client never launches at a default size. The output
/// bound is the consumer's per-connection queue limit in bytes.
pub struct ByteRelayWorker {
    ingress: Sender<Ingress>,
    input_bytes: Arc<AtomicUsize>,
    closed: Arc<AtomicBool>,
    shutdown: Sender<()>,
    writer_stop: Sender<()>,
    output: Arc<OutputQueue>,
    threads: Option<(thread::JoinHandle<()>, thread::JoinHandle<()>)>,
}

impl ByteRelayWorker {
    /// Spawn the resolved attach client inside a native pseudoterminal at
    /// the viewer's initial geometry and relay its raw bytes.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established. A containment failure tears down the child
    /// before returning. `max_queued_output_bytes` must be at least one
    /// PTY read chunk (64 KiB); a smaller bound panics.
    pub fn attach(
        plan: &AttachPlan,
        size: GridSize,
        pixel_size: PixelSize,
        max_queued_output_bytes: usize,
    ) -> Result<Self, WorkerError> {
        Self::launch(
            plan.program(),
            plan.args(),
            size,
            pixel_size,
            max_queued_output_bytes,
        )
    }

    /// Spawn an attach-only Herdr client at the viewer's initial geometry.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established. `max_queued_output_bytes` must be at least
    /// one PTY read chunk (64 KiB); a smaller bound panics.
    pub fn attach_herdr(
        plan: &HerdrAttachPlan,
        size: GridSize,
        pixel_size: PixelSize,
        max_queued_output_bytes: usize,
    ) -> Result<Self, WorkerError> {
        Self::launch(
            plan.program(),
            plan.args(),
            size,
            pixel_size,
            max_queued_output_bytes,
        )
    }

    /// Spawn an attach-only Zellij client at the viewer's initial geometry.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established. `max_queued_output_bytes` must be at least
    /// one PTY read chunk (64 KiB); a smaller bound panics.
    pub fn attach_zellij(
        plan: &ZellijAttachPlan,
        size: GridSize,
        pixel_size: PixelSize,
        max_queued_output_bytes: usize,
    ) -> Result<Self, WorkerError> {
        Self::launch(
            plan.program(),
            plan.args(),
            size,
            pixel_size,
            max_queued_output_bytes,
        )
    }

    /// Spawn an arbitrary local client program (for example a console
    /// shell) inside a native pseudoterminal at the viewer's initial
    /// geometry and relay its raw bytes.
    ///
    /// # Errors
    ///
    /// Returns an error when the PTY, child process, or relay containment
    /// cannot be established. `max_queued_output_bytes` must be at least
    /// one PTY read chunk (64 KiB); a smaller bound panics.
    pub fn attach_command(
        program: &std::ffi::OsStr,
        args: &[std::ffi::OsString],
        size: GridSize,
        pixel_size: PixelSize,
        max_queued_output_bytes: usize,
    ) -> Result<Self, WorkerError> {
        Self::launch(program, args, size, pixel_size, max_queued_output_bytes)
    }

    fn launch(
        program: &std::ffi::OsStr,
        args: &[std::ffi::OsString],
        size: GridSize,
        pixel_size: PixelSize,
        max_queued_output_bytes: usize,
    ) -> Result<Self, WorkerError> {
        // A bound below one reader chunk would report backpressure for a
        // single read against a fully drained viewer; the queue has no
        // oversized-chunk split.
        assert!(
            max_queued_output_bytes >= crate::pty::READ_BUFFER_SIZE,
            "max_queued_output_bytes must be at least one PTY read chunk \
             ({} bytes)",
            crate::pty::READ_BUFFER_SIZE,
        );
        let SpawnedPty {
            process,
            reader,
            writer,
        } = PtyProcess::spawn(program, args, size, pixel_size)?;

        let output = Arc::new(OutputQueue::new(max_queued_output_bytes));
        let relay_output = Arc::clone(&output);
        let (ingress, ingress_receiver) = bounded(INPUT_CAPACITY);
        let input_bytes = Arc::new(AtomicUsize::new(0));
        let writer_input_bytes = Arc::clone(&input_bytes);
        let closed = Arc::new(AtomicBool::new(false));
        let relay_closed = Arc::clone(&closed);
        let (write_failure_sender, write_failures) = bounded(1);
        let (resize_request_sender, resize_requests) = bounded(1);
        let (resize_ack_sender, resize_acks) = bounded(1);
        let (writer_stop, writer_stop_receiver) = bounded(1);
        let relay_writer_stop = writer_stop.clone();
        let (shutdown, shutdown_receiver) = bounded(1);

        let startup = StartupPty::new(process);
        let writer_thread = match thread::Builder::new()
            .name("ghosthub-relay-writer".to_owned())
            .spawn(move || {
                let channels = WriterChannels {
                    ingress: ingress_receiver,
                    stop: writer_stop_receiver,
                    resize_requests: resize_request_sender,
                    resize_acks,
                    failures: write_failure_sender,
                };
                write_relay_input(writer, &channels, &writer_input_bytes);
            }) {
            Ok(handle) => handle,
            Err(error) => {
                drop(startup);
                return Err(WorkerError::new("spawn relay writer", error));
            }
        };

        let relay_thread = match thread::Builder::new()
            .name("ghosthub-byte-relay".to_owned())
            .spawn(move || {
                let process = startup.into_inner();
                let channels = RelayChannels {
                    reader,
                    shutdown: shutdown_receiver,
                    resize_requests,
                    resize_acks: resize_ack_sender,
                    write_failures,
                    writer_stop: relay_writer_stop,
                };
                run_relay(process, &relay_output, &channels, &relay_closed);
            }) {
            Ok(handle) => handle,
            Err(error) => {
                // The failed spawn dropped its closure, so the startup
                // guard already killed and reaped the child; stop and join
                // the writer thread it would have partnered with.
                let _ignored = writer_stop.try_send(());
                drop(ingress);
                let _ignored = writer_thread.join();
                return Err(WorkerError::new("spawn byte relay", error));
            }
        };

        Ok(Self {
            ingress,
            input_bytes,
            closed,
            shutdown,
            writer_stop,
            output,
            threads: Some((relay_thread, writer_thread)),
        })
    }

    /// Send client bytes to the PTY exactly as received. Input is ordered
    /// after every resize submitted before it.
    ///
    /// # Errors
    ///
    /// Returns a backpressure error when the bounded input budget is full,
    /// and an ordinary error after the relay has stopped.
    pub fn send_bytes(&self, bytes: Vec<u8>) -> Result<(), WorkerError> {
        if bytes.is_empty() {
            return Ok(());
        }
        if self.closed.load(Ordering::Acquire) {
            return Err(WorkerError::new(
                "send relay input",
                "byte relay has stopped",
            ));
        }
        let len = bytes.len();
        if !reserve_input_bytes(&self.input_bytes, len) {
            return Err(WorkerError::backpressure(
                "send relay input",
                "relay input byte budget is full",
            ));
        }
        match self.ingress.try_send(Ingress::Bytes(bytes)) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => {
                release_input_bytes(&self.input_bytes, len);
                Err(WorkerError::backpressure(
                    "send relay input",
                    "relay input queue is full",
                ))
            }
            Err(TrySendError::Disconnected(_)) => {
                release_input_bytes(&self.input_bytes, len);
                Err(WorkerError::new(
                    "send relay input",
                    "byte relay has stopped",
                ))
            }
        }
    }

    /// Apply new viewer geometry to the PTY, ordered against input: input
    /// submitted after a resize is written only once that resize has been
    /// applied. Only consecutive resizes with no input between them coalesce
    /// to the latest value.
    ///
    /// # Errors
    ///
    /// Returns a backpressure error when the input queue is full, and an
    /// ordinary error after the relay has stopped.
    pub fn resize(&self, size: GridSize, pixel_size: PixelSize) -> Result<(), WorkerError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(WorkerError::new(
                "resize relay PTY",
                "byte relay has stopped",
            ));
        }
        match self
            .ingress
            .try_send(Ingress::Resize(ResizeRequest { size, pixel_size }))
        {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => Err(WorkerError::backpressure(
                "resize relay PTY",
                "relay input queue is full",
            )),
            Err(TrySendError::Disconnected(_)) => Err(WorkerError::new(
                "resize relay PTY",
                "byte relay has stopped",
            )),
        }
    }

    /// Wait up to `timeout` for relayed output or the relay's terminal
    /// outcome. Returns `None` on timeout. Once the outcome is delivered it
    /// repeats on every later call.
    #[must_use]
    pub fn recv_output(&self, timeout: Duration) -> Option<RelayOutput> {
        self.output.pop(timeout)
    }
}

impl Drop for ByteRelayWorker {
    /// Shut down and wait for teardown: after drop returns, the child is
    /// reaped and both relay threads have exited, so a fresh attachment
    /// never races a predecessor's teardown.
    fn drop(&mut self) {
        self.closed.store(true, Ordering::Release);
        let _ignored = self.shutdown.try_send(());
        let _ignored = self.writer_stop.try_send(());
        if let Some((relay, writer)) = self.threads.take() {
            let _ignored = relay.join();
            let _ignored = writer.join();
        }
    }
}

struct WriterChannels {
    ingress: Receiver<Ingress>,
    stop: Receiver<()>,
    resize_requests: Sender<ResizeRequest>,
    resize_acks: Receiver<()>,
    failures: Sender<String>,
}

/// Consume the ordered ingress queue: write input bytes to the PTY and hand
/// resize requests to the relay thread, waiting for each acknowledgment so
/// later input never lands at stale geometry. Consecutive resizes coalesce
/// to the latest value; input acts as an ordering barrier between them.
fn write_relay_input(
    mut writer: Box<dyn std::io::Write + Send>,
    channels: &WriterChannels,
    budget: &AtomicUsize,
) {
    loop {
        select! {
            recv(channels.stop) -> _ => return,
            recv(channels.ingress) -> message => {
                let Ok(message) = message else { return };
                match message {
                    Ingress::Bytes(bytes) => {
                        let delivered =
                            write_chunk(writer.as_mut(), &bytes, &channels.failures);
                        release_input_bytes(budget, bytes.len());
                        if !delivered {
                            return;
                        }
                    }
                    Ingress::Resize(request) => {
                        let (request, pending) = coalesce_resizes(&channels.ingress, request);
                        if channels.resize_requests.send(request).is_err()
                            || channels.resize_acks.recv().is_err()
                        {
                            if let Some(bytes) = pending {
                                release_input_bytes(budget, bytes.len());
                            }
                            return;
                        }
                        if let Some(bytes) = pending {
                            let delivered =
                                write_chunk(writer.as_mut(), &bytes, &channels.failures);
                            release_input_bytes(budget, bytes.len());
                            if !delivered {
                                return;
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Merge queued back-to-back resizes into the latest one, stopping at the
/// first input chunk so the barrier between resize and later input holds.
fn coalesce_resizes(
    ingress: &Receiver<Ingress>,
    first: ResizeRequest,
) -> (ResizeRequest, Option<Vec<u8>>) {
    let mut latest = first;
    loop {
        match ingress.try_recv() {
            Ok(Ingress::Resize(request)) => latest = request,
            Ok(Ingress::Bytes(bytes)) => return (latest, Some(bytes)),
            Err(_) => return (latest, None),
        }
    }
}

fn write_chunk(writer: &mut dyn std::io::Write, bytes: &[u8], failures: &Sender<String>) -> bool {
    let result = writer.write_all(bytes).and_then(|()| writer.flush());
    if let Err(error) = result {
        let _ignored = failures.try_send(error.to_string());
        return false;
    }
    true
}

struct RelayChannels {
    reader: Receiver<ReaderMessage>,
    shutdown: Receiver<()>,
    resize_requests: Receiver<ResizeRequest>,
    resize_acks: Sender<()>,
    write_failures: Receiver<String>,
    writer_stop: Sender<()>,
}

/// Whether a drain-window failure defers to the child's observed clean
/// exit. Only incidental resize/write failures against the dead PTY do;
/// reader failures and viewer backpressure keep their own outcomes — both
/// can mean the viewer lost output and must know.
fn prefer_observed_exit(
    exit_observed: bool,
    incidental_failure: bool,
    disconnect: &RelayDisconnect,
) -> bool {
    exit_observed && incidental_failure && matches!(disconnect, RelayDisconnect::Failed(_))
}

fn run_relay(
    mut pty: PtyProcess,
    output: &OutputQueue,
    channels: &RelayChannels,
    closed: &AtomicBool,
) {
    let mut report_exit = false;
    let mut observed_exit = None;
    let mut next_child_poll = Instant::now();
    let mut disconnect = RelayDisconnect::Closed;
    // Resize and write failures against an already-exited child are
    // incidental; reader failures are not — they can mean output was
    // truncated, which a clean exit report would falsely deny.
    let mut incidental_failure = false;
    loop {
        if child_exit_drain_expired(
            &mut observed_exit,
            &mut next_child_poll,
            Instant::now(),
            || pty.poll_exit(),
        ) {
            report_exit = true;
            break;
        }
        select! {
            recv(channels.shutdown) -> _ => break,
            recv(channels.reader) -> message => match message {
                Ok(ReaderMessage::Bytes(bytes)) => {
                    if output.push(bytes).is_err() {
                        disconnect = RelayDisconnect::Backpressure;
                        break;
                    }
                }
                Ok(ReaderMessage::Error(error)) => {
                    disconnect = RelayDisconnect::Failed(error);
                    break;
                }
                Ok(ReaderMessage::Eof) | Err(_) => {
                    report_exit = true;
                    break;
                }
            },
            recv(channels.resize_requests) -> message => {
                let Ok(request) = message else {
                    // The writer thread exited; a write failure, if any, is
                    // waiting on the failure channel.
                    if let Ok(error) = channels.write_failures.try_recv() {
                        disconnect = RelayDisconnect::Failed(error);
                        incidental_failure = true;
                    }
                    break;
                };
                if let Err(error) = pty.resize(request.size, request.pixel_size) {
                    disconnect = RelayDisconnect::Failed(error.to_string());
                    incidental_failure = true;
                    break;
                }
                let _acknowledged = channels.resize_acks.try_send(());
            },
            recv(channels.write_failures) -> message => match message {
                Ok(error) => {
                    disconnect = RelayDisconnect::Failed(error);
                    incidental_failure = true;
                    break;
                }
                // The writer exited without a failure, which is a shutdown.
                Err(_) => break,
            },
            default(CHILD_EXIT_POLL_INTERVAL) => {}
        }
    }

    if prefer_observed_exit(observed_exit.is_some(), incidental_failure, &disconnect) {
        report_exit = true;
    }
    let exit_code = pty.reap(report_exit, observed_exit.map(|(code, _)| code));
    if report_exit {
        disconnect = RelayDisconnect::Exited { code: exit_code };
    }
    // The closed flag precedes the queue outcome so a client that has
    // observed the disconnect can never send input successfully afterward.
    closed.store(true, Ordering::Release);
    output.close(disconnect);
    let _stopped = channels.writer_stop.try_send(());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_incidental_failures_defer_to_an_observed_exit() {
        let failed = RelayDisconnect::Failed("io".to_owned());
        assert!(
            prefer_observed_exit(true, true, &failed),
            "a resize or write failure against the exited child's PTY defers"
        );
        assert!(
            !prefer_observed_exit(true, false, &failed),
            "a reader failure can mean truncated output; it must be reported"
        );
        assert!(
            !prefer_observed_exit(false, true, &failed),
            "no observed exit, nothing to defer to"
        );
        assert!(
            !prefer_observed_exit(true, true, &RelayDisconnect::Backpressure),
            "viewer backpressure keeps its own outcome"
        );
    }

    #[test]
    fn output_queue_refuses_chunks_beyond_the_bound() {
        let queue = OutputQueue::new(8);

        queue.push(vec![1; 5]).expect("first chunk fits the bound");
        assert_eq!(queue.push(vec![2; 4]), Err(OutputOverflow));

        queue.close(RelayDisconnect::Backpressure);
        assert_eq!(
            queue.pop(Duration::ZERO),
            Some(RelayOutput::Bytes(vec![1; 5])),
            "queued bytes drain ahead of the disconnect"
        );
        assert_eq!(
            queue.pop(Duration::ZERO),
            Some(RelayOutput::Disconnected(RelayDisconnect::Backpressure))
        );
        assert_eq!(
            queue.pop(Duration::ZERO),
            Some(RelayOutput::Disconnected(RelayDisconnect::Backpressure)),
            "the terminal outcome repeats"
        );
    }

    #[test]
    fn draining_the_queue_releases_its_byte_budget() {
        let queue = OutputQueue::new(8);

        queue.push(vec![1; 8]).expect("fill the bound exactly");
        assert_eq!(queue.push(vec![2; 1]), Err(OutputOverflow));
        assert_eq!(
            queue.pop(Duration::ZERO),
            Some(RelayOutput::Bytes(vec![1; 8]))
        );

        queue
            .push(vec![3; 8])
            .expect("drained bytes return to the budget");
    }

    #[test]
    fn empty_open_queue_times_out_without_output() {
        let queue = OutputQueue::new(8);
        assert_eq!(queue.pop(Duration::ZERO), None);
        assert_eq!(queue.pop(Duration::from_millis(10)), None);
    }

    #[test]
    fn first_disconnect_outcome_wins() {
        let queue = OutputQueue::new(8);

        queue.close(RelayDisconnect::Exited { code: 3 });
        queue.close(RelayDisconnect::Closed);

        assert_eq!(
            queue.pop(Duration::ZERO),
            Some(RelayOutput::Disconnected(RelayDisconnect::Exited {
                code: 3
            }))
        );
    }

    #[test]
    fn late_output_after_disconnect_is_not_queued() {
        let queue = OutputQueue::new(8);

        queue.close(RelayDisconnect::Closed);
        queue
            .push(vec![1; 4])
            .expect("late output is discarded, not an overflow");

        assert_eq!(
            queue.pop(Duration::ZERO),
            Some(RelayOutput::Disconnected(RelayDisconnect::Closed))
        );
    }

    #[test]
    fn input_budget_bounds_reservations_until_release() {
        let budget = AtomicUsize::new(0);

        assert!(reserve_input_bytes(&budget, INPUT_BYTE_CAPACITY));
        assert!(!reserve_input_bytes(&budget, 1));

        release_input_bytes(&budget, INPUT_BYTE_CAPACITY);
        assert!(reserve_input_bytes(&budget, 1));
    }

    #[derive(Debug, Eq, PartialEq)]
    enum Event {
        Resize(GridSize),
        Write(Vec<u8>),
    }

    struct LogSink(Arc<Mutex<Vec<Event>>>);

    impl std::io::Write for LogSink {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0
                .lock()
                .expect("event log")
                .push(Event::Write(buf.to_vec()));
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Run the writer loop over a pre-filled ingress queue against a fake
    /// relay thread that logs and acknowledges each applied resize. The
    /// shared log gives a total order across writes and resize applications.
    fn replay_ingress(messages: Vec<Ingress>) -> Vec<Event> {
        let log = Arc::new(Mutex::new(Vec::new()));
        let (ingress_sender, ingress) = bounded(INPUT_CAPACITY);
        for message in messages {
            assert!(ingress_sender.try_send(message).is_ok(), "pre-fill ingress");
        }
        drop(ingress_sender);
        let (_stop_sender, stop) = bounded(1);
        let (resize_requests_sender, resize_requests) = bounded::<ResizeRequest>(1);
        let (resize_acks_sender, resize_acks) = bounded(1);
        let (failures, _failure_receiver) = bounded(1);

        let relay_log = Arc::clone(&log);
        let fake_relay = thread::spawn(move || {
            while let Ok(request) = resize_requests.recv() {
                relay_log
                    .lock()
                    .expect("event log")
                    .push(Event::Resize(request.size));
                if resize_acks_sender.send(()).is_err() {
                    return;
                }
            }
        });

        let writer_log = Arc::clone(&log);
        let budget = AtomicUsize::new(0);
        let channels = WriterChannels {
            ingress,
            stop,
            resize_requests: resize_requests_sender,
            resize_acks,
            failures,
        };
        write_relay_input(Box::new(LogSink(writer_log)), &channels, &budget);
        drop(channels);
        fake_relay.join().expect("fake relay thread");

        Arc::try_unwrap(log)
            .expect("all loggers finished")
            .into_inner()
            .expect("event log")
    }

    fn grid(columns: usize, rows: usize) -> GridSize {
        GridSize::new(columns, rows).expect("valid grid")
    }

    fn resize_message(columns: usize, rows: usize) -> Ingress {
        Ingress::Resize(ResizeRequest {
            size: grid(columns, rows),
            pixel_size: PixelSize::new(640, 480),
        })
    }

    #[test]
    fn input_is_ordered_after_the_resize_submitted_before_it() {
        let events = replay_ingress(vec![
            resize_message(100, 30),
            Ingress::Bytes(b"x".to_vec()),
            resize_message(120, 40),
        ]);

        assert_eq!(
            events,
            vec![
                Event::Resize(grid(100, 30)),
                Event::Write(b"x".to_vec()),
                Event::Resize(grid(120, 40)),
            ],
            "input crosses neither the earlier nor the later resize"
        );
    }

    #[test]
    fn only_consecutive_resizes_coalesce() {
        let events = replay_ingress(vec![
            resize_message(90, 25),
            resize_message(100, 30),
            Ingress::Bytes(b"x".to_vec()),
            resize_message(120, 40),
        ]);

        assert_eq!(
            events,
            vec![
                Event::Resize(grid(100, 30)),
                Event::Write(b"x".to_vec()),
                Event::Resize(grid(120, 40)),
            ],
            "back-to-back resizes merge to the latest; input is a barrier"
        );
    }
}
