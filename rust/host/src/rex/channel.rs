use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};

use super::Message;
use crate::command_process::{self, CommandContainment};

const MAX_LINE: u64 = 1024 * 1024;

pub struct Channel {
    containment: CommandContainment,
    child: Child,
    requests: Option<SyncSender<Vec<u8>>>,
    events: Receiver<Result<Message, String>>,
}

impl Channel {
    /// # Errors
    /// Returns a process or pipe-worker startup failure.
    #[allow(
        clippy::too_many_lines,
        reason = "The three pipe workers share process startup and teardown."
    )]
    pub fn start(plan: &session::RexPlan) -> Result<Self, String> {
        let mut command = Command::new(plan.program());
        command
            .args(plan.args())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command_process::prepare(&mut command);
        let mut child = command.spawn().map_err(|e| e.to_string())?;
        let containment = match CommandContainment::attach(&mut child) {
            Ok(containment) => containment,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e.to_string());
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
        let mut input = channel.child.stdin.take().ok_or("Rex input unavailable")?;
        let output = channel
            .child
            .stdout
            .take()
            .ok_or("Rex output unavailable")?;
        let errors = channel
            .child
            .stderr
            .take()
            .ok_or("Rex errors unavailable")?;
        // Drain stderr independently so a login script cannot block the control stream.
        let error_text = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let capture = error_text.clone();
        std::thread::Builder::new()
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
            .map_err(|e| e.to_string())?;
        let failures = writer.clone();
        std::thread::Builder::new()
            .name("rex-input".into())
            .spawn(move || {
                while let Ok(bytes) = request_reader.recv() {
                    if let Err(e) = input.write_all(&bytes) {
                        let _ = failures.send(Err(format!("Rex request failed: {e}")));
                        break;
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        std::thread::Builder::new()
            .name("rex-output".into())
            .spawn(move || {
                let mut output = BufReader::new(output);
                let mut framed = false;
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
                            if !framed {
                                framed = line
                                    .strip_suffix(b"\n")
                                    .unwrap_or(&line)
                                    .strip_suffix(b"\r")
                                    .unwrap_or(line.strip_suffix(b"\n").unwrap_or(&line))
                                    == b"GHOSTHUB_REX_CONTROL";
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
                let text = error_text
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let text = String::from_utf8_lossy(&text).trim().to_owned();
                let _ = writer.send(Err(if text.is_empty() {
                    "The Rex connection closed.".into()
                } else {
                    text
                }));
            })
            .map_err(|e| e.to_string())?;
        Ok(channel)
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
        let channel = Channel::start(&plan).unwrap();
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
}
