use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use super::Message;
use crate::command_process::{self, CommandContainment};
use crate::{CancellationToken, RemoteTmuxError};

const MAX_LINE: u64 = 1024 * 1024;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(20);
const POLL_INTERVAL: Duration = Duration::from_millis(25);

pub struct Channel {
    containment: CommandContainment,
    child: Child,
    requests: Option<SyncSender<Vec<u8>>>,
    events: Receiver<Result<Message, String>>,
}

impl Channel {
    /// # Errors
    /// Returns a process, transport, or control startup failure.
    #[allow(
        clippy::too_many_lines,
        reason = "The three pipe workers share process startup and teardown."
    )]
    pub fn start(
        plan: &session::RexPlan,
        cancellation: &CancellationToken,
    ) -> Result<Self, RemoteTmuxError> {
        let io_error = |error: std::io::Error| RemoteTmuxError::transport(error.to_string());
        let mut command = Command::new(plan.program());
        command
            .args(plan.args())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command_process::prepare(&mut command);
        let mut child = command.spawn().map_err(io_error)?;
        let containment = match CommandContainment::attach(&mut child) {
            Ok(containment) => containment,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(io_error(e));
            }
        };
        let (requests, request_reader) = sync_channel::<Vec<u8>>(32);
        let (writer, events) = sync_channel(8);
        let mut channel = Self {
            child,
            containment,
            requests: Some(requests),
            events,
        };
        let mut input = channel
            .child
            .stdin
            .take()
            .ok_or_else(|| RemoteTmuxError::transport("Rex input unavailable"))?;
        let output = channel
            .child
            .stdout
            .take()
            .ok_or_else(|| RemoteTmuxError::transport("Rex output unavailable"))?;
        let errors = channel
            .child
            .stderr
            .take()
            .ok_or_else(|| RemoteTmuxError::transport("Rex errors unavailable"))?;
        // Drain stderr independently so a login script cannot block the control stream.
        let error_text = Arc::new(Mutex::new(Vec::new()));
        let capture = Arc::clone(&error_text);
        let stderr = thread::Builder::new()
            .name("rex-errors".into())
            .spawn(move || {
                let mut reader = BufReader::new(errors);
                let mut bytes = [0; 1024];
                while let Ok(count @ 1..) = reader.read(&mut bytes) {
                    let mut text = capture
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    let remaining = 4096_usize.saturating_sub(text.len());
                    text.extend_from_slice(&bytes[..count.min(remaining)]);
                }
            })
            .map_err(io_error)?;
        let failures = writer.clone();
        thread::Builder::new()
            .name("rex-input".into())
            .spawn(move || {
                while let Ok(bytes) = request_reader.recv() {
                    if let Err(e) = input.write_all(&bytes) {
                        let _ = failures.send(Err(format!("Rex request failed: {e}")));
                        break;
                    }
                }
            })
            .map_err(io_error)?;
        let (ready, startup) = sync_channel(1);
        let output_errors = Arc::clone(&error_text);
        thread::Builder::new()
            .name("rex-output".into())
            .spawn(move || {
                let mut output = BufReader::new(output);
                let mut ready = Some(ready);
                loop {
                    let mut line = Vec::new();
                    match output
                        .by_ref()
                        .take(MAX_LINE + 1)
                        .read_until(b'\n', &mut line)
                    {
                        Ok(0) => break,
                        Ok(_) if line.len() as u64 > MAX_LINE => {
                            let _ = writer.send(Err("Cannot read the Rex window layout.".into()));
                            return;
                        }
                        Ok(_) => {
                            if let Some(signal) = &ready {
                                let line = line.strip_suffix(b"\n").unwrap_or(&line);
                                if line.strip_suffix(b"\r").unwrap_or(line)
                                    == b"GHOSTHUB_REX_CONTROL"
                                {
                                    if signal.send(()).is_err() {
                                        return;
                                    }
                                    ready = None;
                                }
                                continue;
                            }
                            if line.iter().all(u8::is_ascii_whitespace) {
                                continue;
                            }
                            let message = Message::parse(&line);
                            let stop = message.is_err() || matches!(message, Ok(Message::Ended));
                            if writer.send(message).is_err() || stop {
                                return;
                            }
                        }
                        Err(e) => {
                            let _ = writer.send(Err(e.to_string()));
                            return;
                        }
                    }
                }
                // Before the marker, the caller needs the SSH exit status and
                // complete stderr to distinguish a refusal from a broken channel.
                if ready.is_none() {
                    let _ = writer.send(Err(connection_error(&output_errors)));
                }
            })
            .map_err(io_error)?;
        channel.wait_for_start(&startup, &stderr, &error_text, cancellation)?;
        Ok(channel)
    }

    fn wait_for_start(
        &mut self,
        startup: &Receiver<()>,
        stderr: &JoinHandle<()>,
        errors: &Mutex<Vec<u8>>,
        cancellation: &CancellationToken,
    ) -> Result<(), RemoteTmuxError> {
        let started = Instant::now();
        while !cancellation.is_cancelled() && started.elapsed() < STARTUP_TIMEOUT {
            match startup.recv_timeout(POLL_INTERVAL) {
                Ok(()) => return Ok(()),
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => {}
            }
            if let Some(Err(error)) = self.next() {
                return Err(RemoteTmuxError::transport(error));
            }
            // stdout can reach EOF before the stderr reader sees the refusal.
            if let Some(status) = self
                .child
                .try_wait()
                .map_err(|error| RemoteTmuxError::transport(error.to_string()))?
                && stderr.is_finished()
            {
                return Err(RemoteTmuxError::ssh_exit(
                    status.code(),
                    connection_error(errors),
                ));
            }
            if cancellation.wait_cancelled(POLL_INTERVAL) {
                break;
            }
        }
        if cancellation.is_cancelled() {
            Err(RemoteTmuxError::transport("Rex connection cancelled."))
        } else {
            Err(RemoteTmuxError::timeout(
                "Rex did not start. Try reconnecting.",
            ))
        }
    }

    /// # Errors
    /// Returns an error when the bounded request queue is full or closed.
    pub fn send(&self, id: u64, method: &str, params: &serde_json::Value) -> Result<(), String> {
        let mut bytes =
            serde_json::to_vec(&serde_json::json!({"id":id, "method":method, "params":params}))
                .map_err(|e| e.to_string())?;
        bytes.push(b'\n');
        self.requests
            .as_ref()
            .ok_or("The Rex connection closed.")?
            .try_send(bytes)
            .map_err(|e| match e {
                std::sync::mpsc::TrySendError::Full(_) => "Rex is busy. Try again.".to_owned(),
                std::sync::mpsc::TrySendError::Disconnected(_) => {
                    "The Rex connection closed.".to_owned()
                }
            })
    }

    #[must_use]
    pub fn next(&self) -> Option<Result<Message, String>> {
        self.events.try_recv().ok()
    }
}

fn connection_error(errors: &Mutex<Vec<u8>>) -> String {
    let errors = errors
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let text = String::from_utf8_lossy(&errors);
    if text.trim().is_empty() {
        "The Rex connection closed.".to_owned()
    } else {
        text.trim().to_owned()
    }
}

impl Drop for Channel {
    fn drop(&mut self) {
        self.requests.take();
        self.containment.terminate();
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn control_skips_login_output_and_delivers_requests_and_replies() {
        let script = r#"
            printf '%s\n' 'Welcome to the build host' 'GHOSTHUB_REX_CONTROL'
            read -r request
            case "$request" in
              *'"id":7'*'"method":"session.zoom_block"'*'"block_id":"block:editor"'*)
                printf '%s\n' '{"type":"reply","id":7,"result":{"revision":9}}' ;;
              *) printf '%s\n' '{"type":"reply","id":99,"error":{"code":"wrong_request","message":"wrong request"}}' ;;
            esac
            read -r request
        "#;
        let plan = session::RexPlan::attach_only("/bin/sh", vec!["-c".into(), script.into()]);
        let channel = Channel::start(&plan, &CancellationToken::new()).unwrap();
        channel
            .send(
                7,
                "session.zoom_block",
                &serde_json::json!({"block_id":"block:editor"}),
            )
            .unwrap();
        let reply = channel
            .events
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap()
            .unwrap();
        assert_eq!(
            reply,
            Message::Reply {
                id: 7,
                result: Some(crate::rex::ControlResult { revision: Some(9) }),
                error: None
            }
        );
        let pid = channel.child.id();
        drop(channel);
        let status = Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(!status.success(), "control process survived detach");
    }

    #[test]
    fn control_startup_classifies_the_actual_mux_refusal() {
        for (message, code, refused) in [
            (
                "mux_client_request_session: session request failed: Session open refused by peer",
                "255",
                true,
            ),
            (
                "mux_client_request_session: session request failed: Session open refused by peer",
                "1",
                false,
            ),
            ("Permission denied (publickey).", "255", false),
        ] {
            let plan = session::RexPlan::attach_only(
                "/bin/sh",
                vec![
                    "-c".into(),
                    "printf '%s\\n' \"$1\" >&2; exit \"$2\"".into(),
                    "ssh".into(),
                    message.into(),
                    code.into(),
                ],
            );
            let Err(error) = Channel::start(&plan, &CancellationToken::new()) else {
                panic!("control startup accepted a failed process");
            };
            assert_eq!(error.session_refused(), refused);
            assert_eq!(error.to_string(), message);
        }
    }
}
