//! Request routing, loopback security layers, and the versioned hello
//! websocket.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::Router;
use axum::extract::State;
use axum::extract::ws::{CloseFrame, Message, Utf8Bytes, WebSocket, WebSocketUpgrade, close_code};
use axum::http::{HeaderMap, Method, Request, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use tokio::sync::watch;

use crate::credential::Credential;
use crate::{MAX_FRAME_BYTES, MAX_QUEUED_OUTPUT_BYTES, PROTOCOL_VERSION};

/// Name of the session cookie set by the query-parameter bootstrap.
///
/// Cookies are scoped by hostname, never by port, so the name carries the
/// bound port to keep concurrent servers from replacing each other's
/// cookies. The value is a session value distinct from the bearer token.
#[must_use]
pub fn auth_cookie_name(port: u16) -> String {
    format!("ghosthub_auth_{port}")
}

/// Query parameter carrying the startup credential during browser bootstrap.
pub const AUTH_QUERY_PARAMETER: &str = "auth_token";

/// Policy for the embedded page: only same-origin embedded assets and the
/// same-origin websocket, nothing remote. `script-src` stays strict —
/// 'self', no inline — which is the XSS-relevant directive. `style-src`
/// allows inline styles because the embedded terminal library (xterm.js)
/// injects a `<style>` element at runtime for the terminal rows' font and
/// character metrics; blocking it drops the monospace rendering.
const CSP_PREFIX: &str = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; \
     img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; \
     connect-src 'self'";

/// Embedded single-page app. Every asset is compiled into the binary; the
/// strict CSP means nothing else can load.
const INDEX_PAGE: &str = include_str!("../assets/index.html");
const APP_CSS: &str = include_str!("../assets/app.css");
const APP_JS: &str = include_str!("../assets/app.js");
const XTERM_JS: &str = include_str!("../assets/vendor/xterm.js");
const XTERM_CSS: &str = include_str!("../assets/vendor/xterm.css");
const ADDON_FIT_JS: &str = include_str!("../assets/vendor/addon-fit.js");
const ADDON_UNICODE11_JS: &str = include_str!("../assets/vendor/addon-unicode11.js");

#[derive(Clone)]
pub(crate) struct ServerState {
    /// Serializes attachments: a replacement waits until its predecessor's
    /// relay threads have joined and its PTY child is reaped, so an
    /// abnormal browser-side closure cannot race an un-reaped client.
    /// Scene-scoped serialization replaces this per-server lock when scene
    /// credentials land.
    pub(crate) attach_serial: Arc<tokio::sync::Mutex<()>>,
    /// The literal bound authority, e.g. `127.0.0.1:49152`.
    pub(crate) authority: Arc<str>,
    /// The only acceptable `Origin`, e.g. `http://127.0.0.1:49152`.
    pub(crate) origin: Arc<str>,
    /// The port-suffixed session cookie name for this instance.
    pub(crate) cookie_name: Arc<str>,
    pub(crate) credential: Arc<Credential>,
    pub(crate) scenes: Arc<crate::scenes::SceneRegistry>,
    pub(crate) shutdown: watch::Receiver<bool>,
}

pub(crate) fn router(state: ServerState) -> Router {
    // Layer order: the last-added layer is outermost, so exact `Host`
    // validation runs before authentication, and both run before routing.
    Router::new()
        .route("/", get(index))
        .route("/assets/app.css", get(app_css))
        .route("/assets/app.js", get(app_js))
        .route("/assets/xterm.js", get(xterm_js))
        .route("/assets/xterm.css", get(xterm_css))
        .route("/assets/addon-fit.js", get(addon_fit_js))
        .route("/assets/addon-unicode11.js", get(addon_unicode11_js))
        .route("/api/v1/inventory", get(inventory))
        .route("/api/v1/scene", axum::routing::post(scene_exchange))
        .route("/ws/v1/hello", get(ws_hello))
        .route("/ws/v1/attach", get(crate::attach::ws_attach))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            require_credential,
        ))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            require_exact_host,
        ))
        .with_state(state)
}

/// Reject any request whose `Host` is not the literal bound authority
/// before it reaches routing.
async fn require_exact_host(
    State(state): State<ServerState>,
    request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|value| value.to_str().ok());
    if host != Some(state.authority.as_ref()) {
        return StatusCode::MISDIRECTED_REQUEST.into_response();
    }
    if let Some(authority) = request.uri().authority()
        && authority.as_str() != state.authority.as_ref()
    {
        return StatusCode::MISDIRECTED_REQUEST.into_response();
    }
    next.run(request).await
}

/// Enforce a credential on every request and exact `Origin` on every
/// state-changing request. Browsers bootstrap through `?auth_token=`, which
/// stores the session value in the cookie and redirects with the parameter
/// stripped; non-browser clients present the bearer token instead. The
/// cookie's session value never grants bearer access and vice versa.
async fn require_credential(
    State(state): State<ServerState>,
    request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    if state_changing(request.method()) && !exact_origin(request.headers(), &state.origin) {
        return StatusCode::FORBIDDEN.into_response();
    }

    // A bootstrap query is handled first and, when valid, always redirects
    // to a token-free URL — even for an already-authenticated client — so
    // the credential never survives in the location bar or history.
    {
        let query = request.uri().query().unwrap_or_default();
        if let Some(presented) = query_token(query) {
            if state.credential.matches_token(presented)
                && let Some(session) = state.credential.session_value()
            {
                // Mint a single-use scene code and hand it to the
                // page in the redirect fragment (browsers never send a
                // fragment to a server), so the credential the page
                // exchanges is not the ambient cookie.
                let mint = state.scenes.mint_code(Instant::now()).ok();
                return bootstrap_redirect(
                    request.uri().path(),
                    query,
                    &state.cookie_name,
                    &session,
                    mint.as_deref(),
                );
            }
            return StatusCode::UNAUTHORIZED.into_response();
        }
    }

    if let Some(presented) = bearer_token(request.headers())
        && state.credential.matches_token(presented)
    {
        return next.run(request).await;
    }

    if let Some(presented) = cookie_token(request.headers(), &state.cookie_name)
        && state.credential.matches_session(presented)
    {
        return next.run(request).await;
    }

    StatusCode::UNAUTHORIZED.into_response()
}

fn state_changing(method: &Method) -> bool {
    !matches!(*method, Method::GET | Method::HEAD | Method::OPTIONS)
}

pub(crate) fn exact_origin(headers: &HeaderMap, origin: &str) -> bool {
    headers
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok())
        == Some(origin)
}

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
}

fn cookie_token<'a>(headers: &'a HeaderMap, cookie_name: &str) -> Option<&'a str> {
    headers
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
        .and_then(|cookies| {
            cookies.split(';').find_map(|cookie| {
                let (name, value) = cookie.trim().split_once('=')?;
                (name == cookie_name).then_some(value)
            })
        })
}

fn query_token(query: &str) -> Option<&str> {
    query.split('&').find_map(|pair| {
        let (name, value) = pair.split_once('=')?;
        (name == AUTH_QUERY_PARAMETER).then_some(value)
    })
}

/// Store the session value in the cookie and redirect to the same path with
/// the credential parameter stripped, so the token never stays in the
/// location bar or browser history.
/// Header carrying the single-use bootstrap mint code from the page to
/// the scene-exchange endpoint. A header (not a query param) keeps the
/// code out of the request line that access logs capture.
pub(crate) const MINT_CODE_HEADER: &str = "x-ghosthub-mint";

/// Exchange authority for a scene credential: a browser redeems its
/// single-use mint code (the authenticating session cookie alone cannot);
/// a non-browser bearer client establishes a scene directly. Reached only
/// after the credential and exact-Origin gates in `require_credential`.
async fn scene_exchange(State(state): State<ServerState>, headers: HeaderMap) -> Response {
    if let Some(presented) = bearer_token(&headers)
        && state.credential.matches_token(presented)
    {
        return match state.scenes.establish_direct(Instant::now()) {
            Ok(credential) => scene_credential_response(&credential),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
    }
    let Some(code) = headers
        .get(MINT_CODE_HEADER)
        .and_then(|value| value.to_str().ok())
    else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    match state.scenes.redeem(code, Instant::now()) {
        Ok(Some(credential)) => scene_credential_response(&credential),
        Ok(None) => StatusCode::UNAUTHORIZED.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

fn scene_credential_response(credential: &crate::scenes::SceneCredential) -> Response {
    let body = serde_json::json!({
        "scene_id": credential.scene_id,
        "scene_secret": credential.scene_secret,
    })
    .to_string();
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/json; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        body,
    )
        .into_response()
}

fn bootstrap_redirect(
    path: &str,
    query: &str,
    cookie_name: &str,
    session: &str,
    mint_code: Option<&str>,
) -> Response {
    let remainder = query
        .split('&')
        .filter(|pair| {
            pair.split_once('=')
                .is_none_or(|(name, _)| name != AUTH_QUERY_PARAMETER)
        })
        .collect::<Vec<_>>()
        .join("&");
    let mut location = if remainder.is_empty() {
        path.to_owned()
    } else {
        format!("{path}?{remainder}")
    };
    // The mint code rides in the fragment: browsers do not transmit it to
    // the server, and the page strips it from history immediately.
    if let Some(code) = mint_code {
        location.push_str("#mint=");
        location.push_str(code);
    }
    let cookie = format!("{cookie_name}={session}; HttpOnly; SameSite=Strict; Path=/");
    (
        StatusCode::SEE_OTHER,
        [
            (header::LOCATION, location),
            (header::SET_COOKIE, cookie),
            // The redirect carries the credential in its request URL; it
            // must never be cached or leak through a referrer.
            (header::CACHE_CONTROL, "no-store".to_owned()),
            (header::REFERRER_POLICY, "no-referrer".to_owned()),
        ],
    )
        .into_response()
}

async fn index(State(state): State<ServerState>) -> Response {
    // Some browser versions do not extend `'self'` to websocket upgrades,
    // so the exact same-origin ws URL is stated explicitly.
    let policy = format!("{CSP_PREFIX} ws://{}", state.authority);
    (
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8".to_owned()),
            (header::CONTENT_SECURITY_POLICY, policy),
            (header::CACHE_CONTROL, "no-store".to_owned()),
            (header::REFERRER_POLICY, "no-referrer".to_owned()),
        ],
        INDEX_PAGE,
    )
        .into_response()
}

fn asset(content_type: &'static str, body: &'static str) -> Response {
    (
        [
            (header::CONTENT_TYPE, content_type),
            (header::CACHE_CONTROL, "no-store"),
        ],
        body,
    )
        .into_response()
}

async fn app_css() -> Response {
    asset("text/css; charset=utf-8", APP_CSS)
}

async fn app_js() -> Response {
    asset("text/javascript; charset=utf-8", APP_JS)
}

async fn xterm_js() -> Response {
    asset("text/javascript; charset=utf-8", XTERM_JS)
}

async fn xterm_css() -> Response {
    asset("text/css; charset=utf-8", XTERM_CSS)
}

async fn addon_fit_js() -> Response {
    asset("text/javascript; charset=utf-8", ADDON_FIT_JS)
}

async fn addon_unicode11_js() -> Response {
    asset("text/javascript; charset=utf-8", ADDON_UNICODE11_JS)
}

/// Demo inventory: the real local host carries a live console entry; every
/// other host, project, worktree, and session is synthetic fixture data so
/// the page approximates the product sidebar. Attach always lands on a
/// local console shell until the remote relay endpoints exist.
async fn inventory() -> Response {
    let local = std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "local".to_owned())
        .to_lowercase();
    let body = serde_json::json!({
        "demo": true,
        "hosts": [
            {
                "name": local,
                "kind": "local",
                "status": "ready",
                "endpoint": "local",
                "herdr_available": false,
                "zellij_available": false,
                "tmux_sessions": [],
                "herdr_sessions": [],
                "zellij_sessions": [],
                "projects": [],
                "console": { "name": "console", "subtitle": "Local console shell", "live": true },
            },
            {
                "name": "buildbox",
                "kind": "ssh",
                "status": "ready",
                "endpoint": "wes@buildbox",
                "herdr_available": true,
                "zellij_available": true,
                "tmux_sessions": [
                    { "name": "ghosthub/web-ui", "subtitle": "3 windows", "recent": true },
                    { "name": "ghosthub/main", "subtitle": "1 window" },
                    { "name": "scratch", "subtitle": "Tmux session" },
                ],
                "herdr_sessions": [
                    { "name": "kit-ui-extraction", "subtitle": "Herdr session" },
                    { "name": "nightly-audit", "subtitle": "Stopped", "stopped": true },
                ],
                "zellij_sessions": [
                    { "name": "ops", "subtitle": "Zellij session" },
                ],
                "projects": [
                    {
                        "name": "ghosthub",
                        "subtitle": "kenn-io/ghosthub",
                        "worktrees": [
                            { "name": "main", "primary": true, "session": "ghosthub/main" },
                            { "name": "web-ui", "session": "ghosthub/web-ui", "ahead": 3, "added": 61 },
                        ],
                    },
                ],
            },
        ],
    });
    (
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        body.to_string(),
    )
        .into_response()
}

/// Versioned hello endpoint: authenticated upgrade, exact `Origin`
/// required, one capabilities frame in each direction, then a clean close.
async fn ws_hello(
    State(state): State<ServerState>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    if !exact_origin(&headers, &state.origin) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let shutdown = state.shutdown.clone();
    upgrade
        .max_frame_size(MAX_FRAME_BYTES)
        .max_message_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| hello_exchange(socket, shutdown))
}

pub(crate) fn server_hello() -> String {
    serde_json::json!({
        "protocol": PROTOCOL_VERSION,
        "limits": {
            "max_frame_bytes": MAX_FRAME_BYTES,
            // The reassembled-message limit is enforced alongside the frame
            // limit; both are advertised so a fragmenting client cannot be
            // surprised by an undisclosed bound.
            "max_message_bytes": MAX_FRAME_BYTES,
            "max_queued_output_bytes": MAX_QUEUED_OUTPUT_BYTES,
            "max_grid_dimension": crate::attach::MAX_GRID_DIMENSION,
        },
        "capabilities": {
            "replay": false,
            "kitty_keyboard": false,
            "unicode_width": UNICODE_WIDTH_VERSION,
        },
    })
    .to_string()
}

/// Unicode version whose width tables both sides must apply, so tmux and
/// the browser agree on wide-character cells.
const UNICODE_WIDTH_VERSION: u32 = 11;

/// A client hello must state the protocol version and declare the required
/// capabilities: Unicode-11 width tables and tolerance for ConPTY-injected
/// mode requests. Anything else closes with a policy code.
/// Extract a borrowed (`scene_id`, `scene_secret`) pair from a client hello,
/// or None when either is absent or not a string. The caller validates
/// them against the scene registry.
pub(crate) fn hello_scene_credential(frame: &Utf8Bytes) -> Option<(String, String)> {
    let hello = serde_json::from_str::<serde_json::Value>(frame.as_str()).ok()?;
    let scene_id = hello.get("scene_id")?.as_str()?.to_owned();
    let scene_secret = hello.get("scene_secret")?.as_str()?.to_owned();
    Some((scene_id, scene_secret))
}

pub(crate) fn valid_client_hello(frame: &Utf8Bytes) -> bool {
    let Ok(hello) = serde_json::from_str::<serde_json::Value>(frame.as_str()) else {
        return false;
    };
    hello
        .get("protocol")
        .is_some_and(|protocol| *protocol == PROTOCOL_VERSION)
        && hello
            .pointer("/capabilities/unicode_width")
            .is_some_and(|width| *width == UNICODE_WIDTH_VERSION)
        && hello
            .pointer("/capabilities/ignores_conpty_mode_requests")
            .is_some_and(|ignores| *ignores == true)
}

/// Resolve once shutdown is signaled. A dropped sender also counts as
/// shutdown. The watch borrow is released before every await so the future
/// stays `Send`.
pub(crate) async fn stopped(shutdown: &mut watch::Receiver<bool>) {
    while !*shutdown.borrow_and_update() {
        if shutdown.changed().await.is_err() {
            return;
        }
    }
}

/// How long an upgraded socket may wait for the client hello before the
/// server closes it, so idle upgrades cannot hold resources indefinitely.
pub const CLIENT_HELLO_TIMEOUT: Duration = Duration::from_secs(10);

async fn hello_exchange(mut socket: WebSocket, mut shutdown: watch::Receiver<bool>) {
    if socket
        .send(Message::Text(server_hello().into()))
        .await
        .is_err()
    {
        return;
    }

    let deadline = tokio::time::sleep(CLIENT_HELLO_TIMEOUT);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            () = &mut deadline => {
                let _ = socket
                    .send(Message::Close(Some(CloseFrame {
                        code: close_code::POLICY,
                        reason: Utf8Bytes::from_static("client hello timed out"),
                    })))
                    .await;
                return;
            }
            () = stopped(&mut shutdown) => {
                let _ = socket
                    .send(Message::Close(Some(CloseFrame {
                        code: close_code::AWAY,
                        reason: Utf8Bytes::from_static("server shutting down"),
                    })))
                    .await;
                return;
            }
            message = socket.recv() => {
                match message {
                    Some(Ok(Message::Text(frame))) => {
                        let code = if valid_client_hello(&frame) {
                            close_code::NORMAL
                        } else {
                            close_code::POLICY
                        };
                        let _ = socket
                            .send(Message::Close(Some(CloseFrame {
                                code,
                                reason: Utf8Bytes::from_static("hello complete"),
                            })))
                            .await;
                        return;
                    }
                    Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                    _ => return,
                }
            }
        }
    }
}
