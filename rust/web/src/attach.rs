//! Live terminal websocket: bridges one browser viewer to a local client
//! process through the parserless byte relay.
//!
//! Demo approximation of the product attach path: the endpoint spawns a
//! local console shell rather than a resolved multiplexer attach plan, and
//! authenticates with the instance credential rather than a per-scene
//! secret. The wire shape matches `docs/web-ui.md`: an authenticated
//! upgrade with exact `Origin`, a versioned hello exchange that carries the
//! viewer's real initial geometry, then raw bytes both ways — binary frames
//! are PTY bytes, text frames are control messages, and the relay's
//! terminal outcome arrives as the close frame, which is sent only after
//! the relay threads have joined and the PTY child is reaped — the close
//! frame doubles as the teardown acknowledgment a viewer serializes its
//! replacement attachment behind.

use std::ffi::OsString;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::State;
use axum::extract::ws::{CloseFrame, Message, Utf8Bytes, WebSocket, WebSocketUpgrade, close_code};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use surface::{GridSize, PixelSize};
use terminal::{ByteRelayWorker, RelayDisconnect, RelayOutput};
use tokio::sync::{mpsc, watch};

use crate::service::{ServerState, exact_origin, server_hello, stopped, valid_client_hello};
use crate::{CLIENT_HELLO_TIMEOUT, MAX_FRAME_BYTES, MAX_QUEUED_OUTPUT_BYTES};

/// Largest grid dimension a viewer may request; anything bigger is a
/// protocol violation, not a resize the PTY should attempt. Advertised in
/// the server hello limits so a client can clamp rather than be surprised.
pub(crate) const MAX_GRID_DIMENSION: usize = 1000;

/// Cap on input buffered while an attachment waits for the serialization
/// lock, replayed into the shell once it launches. Comfortably under the
/// relay's own input budget so the replay never hits backpressure.
const MAX_QUEUED_INPUT_BYTES: usize = 64 * 1024;

/// How long the output pump waits per poll before rechecking whether the
/// viewer is gone.
const OUTPUT_POLL: Duration = Duration::from_millis(250);

struct Geometry {
    size: GridSize,
    pixels: PixelSize,
}

pub(crate) async fn ws_attach(
    State(state): State<ServerState>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    if !exact_origin(&headers, &state.origin) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let shutdown = state.shutdown.clone();
    let serial = Arc::clone(&state.attach_serial);
    upgrade
        .max_frame_size(MAX_FRAME_BYTES)
        .max_message_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| attach_session(socket, shutdown, serial))
}

#[allow(
    clippy::too_many_lines,
    reason = "one connection's hello, serialization, relay loop, and teardown read as a single lifecycle"
)]
async fn attach_session(
    mut socket: WebSocket,
    mut shutdown: watch::Receiver<bool>,
    serial: Arc<tokio::sync::Mutex<()>>,
) {
    if socket
        .send(Message::Text(server_hello().into()))
        .await
        .is_err()
    {
        return;
    }
    let Some(mut geometry) = client_hello_geometry(&mut socket, &mut shutdown).await else {
        return;
    };

    // Held from before the PTY spawn through teardown: a replacement
    // attachment waits here until the predecessor's relay threads joined
    // and its child was reaped, so clients never overlap even when the
    // browser-side close fired abnormally without the acknowledgment. The
    // wait also watches shutdown and the waiting socket itself, so neither
    // a stopping server nor an abandoned viewer spawns a doomed child.
    // Input frames sent while queued are discarded — there is no shell to
    // receive them yet — but resize frames are coalesced so the PTY spawns
    // at the viewer's current geometry rather than the hello's, and input
    // is buffered (bounded) and replayed into the shell once it launches,
    // so a reconnecting viewer that types before the lock frees loses no
    // keystrokes.
    let mut lock = std::pin::pin!(serial.lock());
    let mut queued_input: Vec<u8> = Vec::new();
    let _serial = loop {
        tokio::select! {
            // Biased: an uncontended lock wins immediately, so a prompt
            // viewer's first input frames are never consumed by the wait.
            biased;
            guard = &mut lock => break guard,
            () = stopped(&mut shutdown) => {
                close(&mut socket, close_code::AWAY, "server shutting down").await;
                return;
            }
            message = socket.recv() => match message {
                Some(Ok(Message::Text(frame))) => {
                    // A post-hello text frame is a resize control; enforce
                    // it the same way whether the attachment is queued or
                    // live, so a malformed or out-of-range frame is a
                    // protocol violation here too, not silently dropped.
                    let Some(resize) = parse_resize(&frame) else {
                        close(&mut socket, close_code::POLICY, "invalid resize").await;
                        return;
                    };
                    geometry = resize;
                }
                Some(Ok(Message::Binary(bytes))) => {
                    // Bounded: a viewer cannot make a queued attachment
                    // buffer unbounded pre-launch input. Past the bound the
                    // connection is cut rather than silently truncated.
                    if queued_input.len() + bytes.len() > MAX_QUEUED_INPUT_BYTES {
                        close(&mut socket, close_code::POLICY, "input overflow").await;
                        return;
                    }
                    queued_input.extend_from_slice(&bytes);
                }
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                _ => return,
            }
        }
    };
    let spawned = tokio::task::spawn_blocking(move || {
        let (program, args) = local_client();
        ByteRelayWorker::attach_command(
            &program,
            &args,
            geometry.size,
            geometry.pixels,
            MAX_QUEUED_OUTPUT_BYTES,
        )
    })
    .await;
    let Ok(Ok(worker)) = spawned else {
        close(&mut socket, close_code::ERROR, "terminal launch failed").await;
        return;
    };
    let worker = Arc::new(worker);

    // Replay input buffered while the attachment waited for its turn, so a
    // reconnecting viewer's early keystrokes reach the shell in order. A
    // backpressure refusal here is impossible: the bound above is well
    // under the relay's input budget and the shell has drained nothing yet.
    if !queued_input.is_empty() {
        let _ignored = worker.send_bytes(queued_input);
    }

    // Capacity one: the relay's bounded queue is the advertised
    // 2 MiB output limit, and a wider channel here would buffer
    // additional chunks beyond it. At most one chunk sits in this
    // handoff plus one in flight on the socket.
    let (output_sender, mut output) = mpsc::channel::<RelayOutput>(1);
    let pump_worker = Arc::clone(&worker);
    let pump = tokio::task::spawn_blocking(move || {
        loop {
            match pump_worker.recv_output(OUTPUT_POLL) {
                Some(RelayOutput::Bytes(bytes)) => {
                    if output_sender
                        .blocking_send(RelayOutput::Bytes(bytes))
                        .is_err()
                    {
                        return;
                    }
                }
                Some(RelayOutput::Disconnected(disconnect)) => {
                    let _ = output_sender.blocking_send(RelayOutput::Disconnected(disconnect));
                    return;
                }
                None => {
                    if output_sender.is_closed() {
                        return;
                    }
                }
            }
        }
    });

    let pending_close: Option<(u16, &'static str)> = loop {
        tokio::select! {
            delivery = output.recv() => match delivery {
                Some(RelayOutput::Bytes(bytes)) => {
                    if socket.send(Message::Binary(bytes.into())).await.is_err() {
                        break None;
                    }
                }
                Some(RelayOutput::Disconnected(disconnect)) => {
                    break Some(disconnect_close(&disconnect));
                }
                None => break None,
            },
            () = stopped(&mut shutdown) => {
                break Some((close_code::AWAY, "server shutting down"));
            }
            message = socket.recv() => match message {
                Some(Ok(Message::Binary(bytes))) => {
                    if let Err(error) = worker.send_bytes(bytes.to_vec())
                        && error.is_backpressure()
                    {
                        // Input overflow cuts the connection cleanly rather
                        // than dropping bytes mid-stream; a reconnect is a
                        // fresh attachment. A stopped relay is not an
                        // overflow: its terminal outcome (often a normal
                        // exit) is already queued on the output path and
                        // must not be masked by a policy close.
                        break Some((close_code::POLICY, "input overflow"));
                    }
                }
                Some(Ok(Message::Text(frame))) => {
                    // Post-hello text frames are resize controls and
                    // nothing else; a malformed or out-of-range one is a
                    // protocol violation that would otherwise leave stale
                    // geometry silently, the same reason the hello path
                    // refuses it.
                    let Some(resize) = parse_resize(&frame) else {
                        break Some((close_code::POLICY, "invalid resize"));
                    };
                    if let Err(error) = worker.resize(resize.size, resize.pixels)
                        && error.is_backpressure()
                    {
                        // Nothing retries a dropped resize, so stale
                        // geometry would persist until the next viewer
                        // resize; cut the connection instead — a reconnect
                        // is a fresh attachment at current geometry.
                        break Some((close_code::POLICY, "resize backpressure"));
                    }
                    // A resize failing on a stopped relay needs no handling
                    // here: the relay delivers its terminal outcome through
                    // the output path.
                }
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                _ => break None,
            }
        }
    };

    // Both handles drop in blocking contexts: teardown joins the relay
    // threads and reaps the child, which must never block the async
    // runtime. The close frame is sent only after both complete, making it
    // a teardown acknowledgment: a client that serializes its replacement
    // attachment behind this connection's close can never overlap two PTY
    // clients on one multiplexer session.
    drop(output);
    let teardown = tokio::task::spawn_blocking(move || drop(worker));
    let _ = pump.await;
    let _ = teardown.await;
    if let Some((code, reason)) = pending_close {
        close(&mut socket, code, reason).await;
    }
}

/// Await the client hello and return its initial geometry, closing the
/// socket and returning `None` on timeout, shutdown, or an invalid hello.
async fn client_hello_geometry(
    socket: &mut WebSocket,
    shutdown: &mut watch::Receiver<bool>,
) -> Option<Geometry> {
    let deadline = tokio::time::sleep(CLIENT_HELLO_TIMEOUT);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            () = &mut deadline => {
                close(socket, close_code::POLICY, "client hello timed out").await;
                return None;
            }
            () = stopped(shutdown) => {
                close(socket, close_code::AWAY, "server shutting down").await;
                return None;
            }
            message = socket.recv() => {
                match message {
                    Some(Ok(Message::Text(frame))) => {
                        let geometry = valid_client_hello(&frame)
                            .then(|| hello_geometry(&frame))
                            .flatten();
                        if geometry.is_none() {
                            close(socket, close_code::POLICY, "invalid client hello").await;
                        }
                        return geometry;
                    }
                    Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                    _ => return None,
                }
            }
        }
    }
}

fn hello_geometry(frame: &Utf8Bytes) -> Option<Geometry> {
    let hello = serde_json::from_str::<serde_json::Value>(frame.as_str()).ok()?;
    parse_geometry(hello.get("initial")?)
}

fn parse_resize(frame: &Utf8Bytes) -> Option<Geometry> {
    let control = serde_json::from_str::<serde_json::Value>(frame.as_str()).ok()?;
    parse_geometry(control.get("resize")?)
}

fn parse_geometry(value: &serde_json::Value) -> Option<Geometry> {
    let columns = usize::try_from(value.get("columns")?.as_u64()?).ok()?;
    let rows = usize::try_from(value.get("rows")?.as_u64()?).ok()?;
    if columns > MAX_GRID_DIMENSION || rows > MAX_GRID_DIMENSION {
        return None;
    }
    let size = GridSize::new(columns, rows).ok()?;
    let width = u16::try_from(value.get("pixel_width")?.as_u64()?).ok()?;
    let height = u16::try_from(value.get("pixel_height")?.as_u64()?).ok()?;
    Some(Geometry {
        size,
        pixels: PixelSize::new(width, height),
    })
}

fn local_client() -> (OsString, Vec<OsString>) {
    #[cfg(windows)]
    {
        (
            OsString::from("powershell.exe"),
            vec![OsString::from("-NoLogo")],
        )
    }
    #[cfg(not(windows))]
    {
        (
            std::env::var_os("SHELL").unwrap_or_else(|| OsString::from("/bin/sh")),
            Vec::new(),
        )
    }
}

fn disconnect_close(disconnect: &RelayDisconnect) -> (u16, &'static str) {
    match disconnect {
        RelayDisconnect::Exited { .. } => (close_code::NORMAL, "client exited"),
        RelayDisconnect::Backpressure => (close_code::POLICY, "output backpressure"),
        RelayDisconnect::Failed(_) => (close_code::ERROR, "relay failed"),
        RelayDisconnect::Closed => (close_code::AWAY, "relay closed"),
    }
}

async fn close(socket: &mut WebSocket, code: u16, reason: &'static str) {
    let _ = socket
        .send(Message::Close(Some(CloseFrame {
            code,
            reason: Utf8Bytes::from_static(reason),
        })))
        .await;
}
