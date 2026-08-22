//! Loopback-only web server for the browser UI.
//!
//! This crate confines the async runtime (Tokio and Axum) behind a
//! synchronous [`Server`] API. The v1 security boundary from
//! `docs/web-ui.md` is enforced in code: an ephemeral loopback bind with no
//! non-loopback option, an in-memory startup credential compared in constant
//! time, exact `Host` validation before routing, exact `Origin` validation
//! on websocket upgrades and state-changing requests, embedded assets under
//! a strict Content-Security-Policy, and a shutdown that invalidates the
//! credential and closes websockets with proper close frames.

mod attach;
mod credential;
mod service;

use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::credential::Credential;
use crate::service::{ServerState, router};

pub use crate::service::{AUTH_QUERY_PARAMETER, CLIENT_HELLO_TIMEOUT, auth_cookie_name};

/// Version stated by both hello frames on `/ws/v1/hello`.
pub const PROTOCOL_VERSION: u32 = 1;

/// Largest websocket frame either side may send after the hello exchange.
pub const MAX_FRAME_BYTES: usize = 256 * 1024;

/// Bound on the per-connection output queue; a viewer that cannot drain
/// within this bound is disconnected rather than buffered without limit.
pub const MAX_QUEUED_OUTPUT_BYTES: usize = 2 * 1024 * 1024;

/// A running loopback web server.
///
/// Dropping the server shuts it down; [`Server::shutdown`] does the same
/// explicitly. There is deliberately no way to bind anything but an
/// ephemeral loopback port.
pub struct Server {
    addr: SocketAddr,
    token: String,
    credential: Arc<Credential>,
    shutdown: watch::Sender<bool>,
    running: Option<(Runtime, JoinHandle<io::Result<()>>)>,
}

impl Server {
    /// Bind `127.0.0.1` on an ephemeral port, mint the startup credential,
    /// and start serving.
    ///
    /// # Errors
    ///
    /// Fails when the runtime cannot start, the loopback bind fails, or the
    /// operating system entropy source is unavailable.
    pub fn start() -> io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_io()
            .enable_time()
            .build()?;
        let listener = runtime.block_on(TcpListener::bind((Ipv4Addr::LOCALHOST, 0)))?;
        let addr = listener.local_addr()?;

        let (credential, token) = Credential::mint()?;
        let credential = Arc::new(credential);
        let (shutdown, stopping) = watch::channel(false);
        let state = ServerState {
            attach_serial: Arc::new(tokio::sync::Mutex::new(())),
            authority: Arc::from(addr.to_string()),
            origin: Arc::from(format!("http://{addr}")),
            cookie_name: Arc::from(service::auth_cookie_name(addr.port())),
            credential: Arc::clone(&credential),
            shutdown: stopping.clone(),
        };

        let app = router(state);
        let serve = runtime.spawn(async move {
            let mut stopping = stopping;
            axum::serve(listener, app)
                .with_graceful_shutdown(async move {
                    // Release the watch borrow before every await so the
                    // future stays `Send`.
                    while !*stopping.borrow_and_update() {
                        if stopping.changed().await.is_err() {
                            return;
                        }
                    }
                })
                .await
        });

        Ok(Self {
            addr,
            token,
            credential,
            shutdown,
            running: Some((runtime, serve)),
        })
    }

    /// The bound loopback address.
    #[must_use]
    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    /// The startup credential. Hold it in memory only; never log it or
    /// write it to disk.
    #[must_use]
    pub fn token(&self) -> &str {
        &self.token
    }

    /// The one-time browser bootstrap URL: it stores a session value
    /// distinct from the bearer token in the port-suffixed session cookie
    /// and redirects with the credential stripped from the location.
    #[must_use]
    pub fn bootstrap_url(&self) -> String {
        format!(
            "http://{}/?{}={}",
            self.addr, AUTH_QUERY_PARAMETER, self.token
        )
    }

    /// Stop accepting connections, close open websockets with close
    /// frames, and invalidate the credential.
    pub fn shutdown(mut self) {
        self.stop();
    }

    fn stop(&mut self) {
        self.credential.invalidate();
        self.shutdown.send_replace(true);
        if let Some((runtime, mut serve)) = self.running.take() {
            // Every attachment handler awaits its relay teardown before it
            // returns, so the serving task completing means every relay and
            // PTY is torn down. A connection that ignores the shutdown
            // signal past the grace period is force-terminated, and the
            // runtime shutdown then drains relay teardowns that already
            // started on the blocking pool.
            let finished = runtime
                .block_on(async { tokio::time::timeout(SHUTDOWN_GRACE, &mut serve).await })
                .is_ok();
            if !finished {
                serve.abort();
                let _aborted = runtime.block_on(serve);
            }
            runtime.shutdown_timeout(SHUTDOWN_GRACE);
        }
    }
}

const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

impl Drop for Server {
    fn drop(&mut self) {
        self.stop();
    }
}
