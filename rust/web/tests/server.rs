//! End-to-end coverage of the loopback security boundary over real sockets.

use std::fmt::Write as _;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::{Duration, Instant};

use tungstenite::protocol::{Message, Role, WebSocket};
use web::{CLIENT_HELLO_TIMEOUT, MAX_FRAME_BYTES, PROTOCOL_VERSION, Server, auth_cookie_name};

struct Reply {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

impl Reply {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(header, _)| header.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

fn request(addr: SocketAddr, method: &str, target: &str, headers: &[(&str, &str)]) -> Reply {
    let mut stream = TcpStream::connect(addr).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("read timeout");
    let mut raw = format!("{method} {target} HTTP/1.1\r\n");
    for (name, value) in headers {
        write!(raw, "{name}: {value}\r\n").expect("write header");
    }
    raw.push_str("Connection: close\r\n\r\n");
    stream.write_all(raw.as_bytes()).expect("send request");

    let mut response = Vec::new();
    stream.read_to_end(&mut response).expect("read response");
    parse(&String::from_utf8(response).expect("utf-8 response"))
}

fn parse(response: &str) -> Reply {
    let (head, body) = response.split_once("\r\n\r\n").expect("header terminator");
    let mut lines = head.lines();
    let status_line = lines.next().expect("status line");
    let status = status_line
        .split_whitespace()
        .nth(1)
        .expect("status code")
        .parse()
        .expect("numeric status");
    let headers = lines
        .map(|line| {
            let (name, value) = line.split_once(':').expect("header line");
            (name.trim().to_owned(), value.trim().to_owned())
        })
        .collect();
    Reply {
        status,
        headers,
        body: body.to_owned(),
    }
}

fn host(addr: SocketAddr) -> String {
    addr.to_string()
}

fn origin(addr: SocketAddr) -> String {
    format!("http://{addr}")
}

fn bearer(server: &Server) -> String {
    format!("Bearer {}", server.token())
}

#[test]
fn unauthenticated_page_fetch_is_denied() {
    let server = Server::start().expect("start server");
    let reply = request(server.addr(), "GET", "/", &[("Host", &host(server.addr()))]);
    assert_eq!(reply.status, 401);
    assert!(reply.header("set-cookie").is_none());
    assert!(!reply.body.contains("Ghosthub"));
}

#[test]
fn bearer_token_fetches_the_page_with_a_strict_csp() {
    let server = Server::start().expect("start server");
    let reply = request(
        server.addr(),
        "GET",
        "/",
        &[
            ("Host", &host(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(reply.status, 200);
    let expected_policy = format!(
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; \
         img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; \
         connect-src 'self' ws://{}",
        host(server.addr())
    );
    assert_eq!(
        reply.header("content-security-policy"),
        Some(expected_policy.as_str())
    );
    assert_eq!(
        reply.header("content-type"),
        Some("text/html; charset=utf-8")
    );
    assert!(reply.body.contains("Ghosthub"));
}

#[test]
fn hashed_assets_are_served_immutable_and_coherent_with_the_page() {
    let server = Server::start().expect("start server");
    let page = request(
        server.addr(),
        "GET",
        "/",
        &[
            ("Host", &host(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(page.status, 200);

    // Pull a hashed asset path out of the served page and prove it is
    // actually served — end to end, not a source-string assertion.
    let start = page
        .body
        .find("/assets/")
        .expect("the page references a hashed asset");
    let reference = &page.body[start..];
    let end = reference.find('"').expect("the asset reference is quoted");
    let asset_path = &reference[..end];
    assert_ne!(asset_path, "/assets/", "the reference carries a filename");
    assert!(
        asset_path.matches('.').count() >= 2,
        "the reference is content-hashed (stem.hash.ext): {asset_path}"
    );

    let asset = request(
        server.addr(),
        "GET",
        asset_path,
        &[
            ("Host", &host(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(asset.status, 200, "hashed asset {asset_path} is served");
    assert_eq!(
        asset.header("cache-control"),
        Some("public, max-age=31536000, immutable"),
        "content-addressed assets are immutable"
    );
    let content_type = asset.header("content-type").expect("asset content type");
    assert!(
        content_type.starts_with("text/javascript") || content_type.starts_with("text/css"),
        "unexpected asset content type: {content_type}"
    );
}

#[test]
fn an_unknown_asset_name_returns_404_not_the_spa_shell() {
    let server = Server::start().expect("start server");
    // A well-formed but stale hashed name: nothing in the table matches.
    let reply = request(
        server.addr(),
        "GET",
        "/assets/app.0000000000000000.js",
        &[
            ("Host", &host(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(reply.status, 404, "a stale hashed name must fail loudly");
    assert!(
        !reply.body.contains("Ghosthub"),
        "a missing asset must never fall back to the page shell"
    );
}

#[test]
fn wrong_bearer_token_is_denied() {
    let server = Server::start().expect("start server");
    let reply = request(
        server.addr(),
        "GET",
        "/",
        &[
            ("Host", &host(server.addr())),
            ("Authorization", "Bearer 0000"),
        ],
    );
    assert_eq!(reply.status, 401);
}

/// Bootstrap the server and return the full `name=value` cookie pair.
fn bootstrap_cookie(server: &Server) -> String {
    let target = format!("/?auth_token={}", server.token());
    let reply = request(
        server.addr(),
        "GET",
        &target,
        &[("Host", &host(server.addr()))],
    );
    assert_eq!(reply.status, 303);
    let cookie = reply.header("set-cookie").expect("bootstrap cookie");
    cookie.split(';').next().expect("cookie pair").to_owned()
}

#[test]
fn query_bootstrap_sets_the_cookie_and_strips_the_parameter() {
    let server = Server::start().expect("start server");
    let target = format!("/?auth_token={}", server.token());
    let reply = request(
        server.addr(),
        "GET",
        &target,
        &[("Host", &host(server.addr()))],
    );
    assert_eq!(reply.status, 303);
    let location = reply.header("location").expect("redirect location");
    assert!(location.starts_with("/#mint="), "{location}");
    assert_eq!(location.len(), "/#mint=".len() + 64, "64-hex mint code");
    let cookie = reply.header("set-cookie").expect("bootstrap cookie");
    let cookie_name = auth_cookie_name(server.addr().port());
    assert!(cookie.starts_with(&format!("{cookie_name}=")));
    assert!(cookie.contains("HttpOnly"));
    assert!(cookie.contains("SameSite=Strict"));
    assert!(cookie.contains("Path=/"));

    let cookie_value = cookie.split(';').next().expect("cookie pair").to_owned();
    let reply = request(
        server.addr(),
        "GET",
        "/",
        &[("Host", &host(server.addr())), ("Cookie", &cookie_value)],
    );
    assert_eq!(reply.status, 200);
}

#[test]
fn bootstrap_redirects_even_when_already_authenticated() {
    let server = Server::start().expect("start server");
    let cookie = bootstrap_cookie(&server);

    let target = format!("/?auth_token={}", server.token());
    let reply = request(
        server.addr(),
        "GET",
        &target,
        &[("Host", &host(server.addr())), ("Cookie", &cookie)],
    );
    assert_eq!(
        reply.status, 303,
        "an authenticated revisit must still strip the token from the location"
    );
    let location = reply.header("location").expect("redirect location");
    assert!(location.starts_with("/#mint="), "{location}");
    assert_eq!(location.len(), "/#mint=".len() + 64, "64-hex mint code");
}

#[test]
fn cookie_value_is_a_session_value_not_the_bearer_token() {
    let server = Server::start().expect("start server");
    let cookie = bootstrap_cookie(&server);
    let session = cookie.split_once('=').expect("cookie pair").1;
    assert_ne!(session, server.token());

    let as_bearer = format!("Bearer {session}");
    let reply = request(
        server.addr(),
        "GET",
        "/",
        &[
            ("Host", &host(server.addr())),
            ("Authorization", &as_bearer),
        ],
    );
    assert_eq!(
        reply.status, 401,
        "the session value grants no bearer access"
    );

    let token_as_cookie = format!(
        "{}={}",
        auth_cookie_name(server.addr().port()),
        server.token()
    );
    let reply = request(
        server.addr(),
        "GET",
        "/",
        &[("Host", &host(server.addr())), ("Cookie", &token_as_cookie)],
    );
    assert_eq!(reply.status, 401, "the bearer token is not a session value");
}

#[test]
fn concurrent_servers_use_distinct_cookies() {
    let first = Server::start().expect("start first server");
    let second = Server::start().expect("start second server");
    assert_ne!(
        auth_cookie_name(first.addr().port()),
        auth_cookie_name(second.addr().port())
    );

    let first_cookie = bootstrap_cookie(&first);
    let second_cookie = bootstrap_cookie(&second);

    // A browser sends every loopback cookie to every loopback port; each
    // server must accept its own session and ignore the sibling's.
    let both = format!("{first_cookie}; {second_cookie}");
    let reply = request(
        first.addr(),
        "GET",
        "/",
        &[("Host", &host(first.addr())), ("Cookie", &both)],
    );
    assert_eq!(reply.status, 200);
    let reply = request(
        second.addr(),
        "GET",
        "/",
        &[("Host", &host(second.addr())), ("Cookie", &both)],
    );
    assert_eq!(reply.status, 200);

    let reply = request(
        first.addr(),
        "GET",
        "/",
        &[("Host", &host(first.addr())), ("Cookie", &second_cookie)],
    );
    assert_eq!(reply.status, 401, "a sibling's cookie grants nothing");
}

#[test]
fn bootstrap_preserves_other_query_parameters() {
    let server = Server::start().expect("start server");
    let target = format!("/?view=hosts&auth_token={}", server.token());
    let reply = request(
        server.addr(),
        "GET",
        &target,
        &[("Host", &host(server.addr()))],
    );
    assert_eq!(reply.status, 303);
    let location = reply.header("location").expect("redirect location");
    assert!(location.starts_with("/?view=hosts#mint="), "{location}");
}

#[test]
fn wrong_query_token_is_denied_without_a_cookie() {
    let server = Server::start().expect("start server");
    let reply = request(
        server.addr(),
        "GET",
        "/?auth_token=0000",
        &[("Host", &host(server.addr()))],
    );
    assert_eq!(reply.status, 401);
    assert!(reply.header("set-cookie").is_none());
}

#[test]
fn wrong_host_is_rejected_before_routing() {
    let server = Server::start().expect("start server");
    let reply = request(
        server.addr(),
        "GET",
        "/",
        &[
            ("Host", "ghosthub.example:80"),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(reply.status, 421);
}

#[test]
fn absent_host_is_rejected() {
    let server = Server::start().expect("start server");
    let reply = request(
        server.addr(),
        "GET",
        "/",
        &[("Authorization", &bearer(&server))],
    );
    assert!(
        reply.status == 421 || reply.status == 400,
        "expected rejection, got {}",
        reply.status
    );
}

#[test]
fn state_changing_request_requires_the_exact_origin() {
    let server = Server::start().expect("start server");
    let denied = request(
        server.addr(),
        "POST",
        "/",
        &[
            ("Host", &host(server.addr())),
            ("Authorization", &bearer(&server)),
            ("Content-Length", "0"),
        ],
    );
    assert_eq!(denied.status, 403);

    let routed = request(
        server.addr(),
        "POST",
        "/",
        &[
            ("Host", &host(server.addr())),
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
            ("Content-Length", "0"),
        ],
    );
    assert_eq!(routed.status, 405, "past the origin gate, no POST route");
}

/// Perform the websocket upgrade by hand so both accepted and rejected
/// upgrades can be observed as plain HTTP.
fn upgrade(
    addr: SocketAddr,
    extra_headers: &[(&str, &str)],
) -> (u16, Option<WebSocket<TcpStream>>) {
    upgrade_at(addr, "/ws/v1/hello", extra_headers)
}

fn upgrade_at(
    addr: SocketAddr,
    path: &str,
    extra_headers: &[(&str, &str)],
) -> (u16, Option<WebSocket<TcpStream>>) {
    let mut stream = TcpStream::connect(addr).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("read timeout");
    let mut raw = format!(
        "GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    );
    for (name, value) in extra_headers {
        write!(raw, "{name}: {value}\r\n").expect("write header");
    }
    raw.push_str("\r\n");
    stream.write_all(raw.as_bytes()).expect("send upgrade");

    let mut head = Vec::new();
    let mut byte = [0_u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).expect("read upgrade reply");
        head.push(byte[0]);
    }
    let head = String::from_utf8(head).expect("utf-8 upgrade reply");
    let status = head
        .split_whitespace()
        .nth(1)
        .expect("status code")
        .parse()
        .expect("numeric status");
    if status == 101 {
        let socket = WebSocket::from_raw_socket(stream, Role::Client, None);
        (status, Some(socket))
    } else {
        (status, None)
    }
}

#[test]
fn hello_websocket_exchanges_capabilities_and_closes() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade(
        server.addr(),
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");

    let hello = match socket.read().expect("server hello") {
        Message::Text(frame) => frame,
        other => panic!("expected text hello, got {other:?}"),
    };
    let hello: serde_json::Value = serde_json::from_str(hello.as_str()).expect("hello json");
    assert_eq!(hello["protocol"], PROTOCOL_VERSION);
    assert_eq!(hello["capabilities"]["replay"], false);
    assert_eq!(hello["capabilities"]["kitty_keyboard"], false);
    assert_eq!(hello["capabilities"]["unicode_width"], 11);
    assert_eq!(hello["limits"]["max_frame_bytes"], MAX_FRAME_BYTES);
    assert_eq!(hello["limits"]["max_message_bytes"], MAX_FRAME_BYTES);
    assert!(hello["limits"]["max_queued_output_bytes"].is_u64());

    let scene = establish_scene(&server);
    socket
        .send(Message::Text(compatible_client_hello(&scene).into()))
        .expect("client hello");

    match socket.read().expect("close frame") {
        Message::Close(Some(frame)) => {
            assert_eq!(u16::from(frame.code), 1000, "normal closure");
        }
        other => panic!("expected close frame, got {other:?}"),
    }
}

fn compatible_client_hello(scene: &(String, String)) -> String {
    let (scene_id, scene_secret) = scene;
    format!(
        "{{\"protocol\":{PROTOCOL_VERSION},\"scene_id\":\"{scene_id}\",\
         \"scene_secret\":\"{scene_secret}\",\"capabilities\":{{\"unicode_width\":11,\
         \"ignores_conpty_mode_requests\":true}}}}"
    )
}

#[test]
fn client_hello_without_required_capabilities_is_rejected() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade(
        server.addr(),
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };

    let (scene_id, scene_secret) = establish_scene(&server);
    socket
        .send(Message::Text(
            format!(
                "{{\"protocol\":{PROTOCOL_VERSION},\"scene_id\":\"{scene_id}\",\
                 \"scene_secret\":\"{scene_secret}\"}}"
            )
            .into(),
        ))
        .expect("client hello without capabilities");

    match socket.read().expect("close frame") {
        Message::Close(Some(frame)) => {
            assert_eq!(
                u16::from(frame.code),
                1008,
                "missing required capabilities must close with the policy code"
            );
        }
        other => panic!("expected close frame, got {other:?}"),
    }
}

#[test]
fn oversized_hello_frame_is_rejected() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade(
        server.addr(),
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };

    let oversized = "a".repeat(MAX_FRAME_BYTES + 1);
    socket
        .send(Message::Text(oversized.into()))
        .expect("send oversized frame");

    // The advertised limit is enforced: the frame is never processed as a
    // hello, so the exchange must not end in a normal closure.
    match socket.read() {
        Ok(Message::Close(frame)) => {
            let code = frame.map_or(0, |frame| u16::from(frame.code));
            assert_ne!(code, 1000, "oversized frame must not complete the hello");
        }
        Ok(other) => panic!("expected close or connection error, got {other:?}"),
        Err(_) => {}
    }
}

/// Write one raw client websocket frame with a zero mask key, so fragmented
/// messages can be produced below tungstenite's public API.
fn write_raw_frame(stream: &mut TcpStream, fin: bool, opcode: u8, payload: &[u8]) {
    let mut frame = Vec::with_capacity(payload.len() + 14);
    frame.push(if fin { 0x80 | opcode } else { opcode });
    let len = payload.len();
    if len < 126 {
        frame.push(0x80 | u8::try_from(len).expect("small length"));
    } else if let Ok(len) = u16::try_from(len) {
        frame.push(0x80 | 0x7E);
        frame.extend_from_slice(&len.to_be_bytes());
    } else {
        frame.push(0x80 | 0x7F);
        frame.extend_from_slice(&(len as u64).to_be_bytes());
    }
    frame.extend_from_slice(&[0, 0, 0, 0]);
    frame.extend_from_slice(payload);
    stream.write_all(&frame).expect("write raw frame");
}

#[test]
fn oversized_fragmented_message_is_rejected() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade(
        server.addr(),
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };

    // Each fragment respects the frame limit; the reassembled message does
    // not. The advertised max_message_bytes must reject it.
    let fragment = vec![b'a'; MAX_FRAME_BYTES / 2 + 1024];
    let stream = socket.get_mut();
    write_raw_frame(stream, false, 0x1, &fragment);
    write_raw_frame(stream, true, 0x0, &fragment);

    match socket.read() {
        Ok(Message::Close(frame)) => {
            let code = frame.map_or(0, |frame| u16::from(frame.code));
            assert_ne!(code, 1000, "oversized message must not complete the hello");
        }
        Ok(other) => panic!("expected close or connection error, got {other:?}"),
        Err(_) => {}
    }
}

#[test]
fn authenticated_and_bootstrap_responses_are_uncacheable_and_referrer_free() {
    let server = Server::start().expect("start server");

    let target = format!("/?auth_token={}", server.token());
    let redirect = request(
        server.addr(),
        "GET",
        &target,
        &[("Host", &host(server.addr()))],
    );
    assert_eq!(redirect.status, 303);
    assert_eq!(redirect.header("cache-control"), Some("no-store"));
    assert_eq!(redirect.header("referrer-policy"), Some("no-referrer"));

    let page = request(
        server.addr(),
        "GET",
        "/",
        &[
            ("Host", &host(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(page.status, 200);
    assert_eq!(page.header("cache-control"), Some("no-store"));
    assert_eq!(page.header("referrer-policy"), Some("no-referrer"));
}

#[test]
fn silent_client_hello_times_out_with_a_policy_close() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade(
        server.addr(),
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    socket
        .get_mut()
        .set_read_timeout(Some(CLIENT_HELLO_TIMEOUT + Duration::from_secs(10)))
        .expect("extend read timeout past the hello deadline");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };

    // Send nothing: the server must close the idle upgrade on its own.
    let started = Instant::now();
    match socket.read().expect("timeout close frame") {
        Message::Close(Some(frame)) => {
            assert_eq!(u16::from(frame.code), 1008, "policy close on timeout");
        }
        other => panic!("expected close frame, got {other:?}"),
    }
    assert!(
        started.elapsed() + Duration::from_secs(1) >= CLIENT_HELLO_TIMEOUT,
        "the close must come from the hello deadline, not an early failure"
    );
}

#[test]
fn websocket_upgrade_rejects_a_wrong_origin() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade(
        server.addr(),
        &[
            ("Origin", "http://ghosthub.example"),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 403);
    assert!(socket.is_none());
}

#[test]
fn websocket_upgrade_rejects_a_missing_origin() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade(server.addr(), &[("Authorization", &bearer(&server))]);
    assert_eq!(status, 403);
    assert!(socket.is_none());
}

#[test]
fn websocket_upgrade_rejects_missing_credentials() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade(server.addr(), &[("Origin", &origin(server.addr()))]);
    assert_eq!(status, 401);
    assert!(socket.is_none());
}

#[test]
fn shutdown_closes_open_websockets_and_stops_the_listener() {
    let server = Server::start().expect("start server");
    let addr = server.addr();
    let (status, socket) = upgrade(
        addr,
        &[
            ("Origin", &origin(addr)),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };

    server.shutdown();

    match socket.read().expect("shutdown close frame") {
        Message::Close(Some(frame)) => {
            assert_eq!(u16::from(frame.code), 1001, "going away");
        }
        other => panic!("expected close frame, got {other:?}"),
    }

    assert!(
        TcpStream::connect(addr).is_err(),
        "listener must stop accepting after shutdown"
    );
}

/// Full live path: an authenticated attach upgrade, hello with initial
/// geometry, then a real shell round-trip — bytes sent as input come back
/// through the relay as PTY output, and exiting the shell closes normally.
#[test]
fn attach_websocket_runs_a_live_shell() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    socket
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(30)))
        .expect("extend read timeout for shell startup");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };

    let scene = establish_scene(&server);
    let hello = full_hello(&scene);
    socket
        .send(Message::Text(hello.into()))
        .expect("client hello");

    await_echo(&mut socket, "ghosthub-web-live");

    socket
        .send(Message::Binary(b"exit\r".to_vec().into()))
        .expect("send exit");
    let deadline = Instant::now() + Duration::from_mins(1);
    loop {
        assert!(Instant::now() < deadline, "close frame never arrived");
        match socket.read().expect("read after exit") {
            Message::Binary(_) | Message::Ping(_) | Message::Pong(_) => {}
            Message::Close(Some(frame)) => {
                assert_eq!(u16::from(frame.code), 1000, "shell exit closes normally");
                break;
            }
            other => panic!("expected close frame, got {other:?}"),
        }
    }
}

/// Echo `marker` through the attached shell and read until it comes back,
/// answering the `ConPTY` startup cursor query opportunistically when it
/// appears — conhost stalls the child until the viewer answers, while Unix
/// shells never emit one. Proves the shell is live and echoing.
fn await_echo(socket: &mut WebSocket<TcpStream>, marker: &str) {
    let probe = format!("echo {marker}\r");
    socket
        .send(Message::Binary(probe.into_bytes().into()))
        .expect("send echo probe");
    let deadline = Instant::now() + Duration::from_mins(1);
    let mut collected = Vec::new();
    let mut answered = false;
    while !contains(&collected, marker.as_bytes()) {
        assert!(Instant::now() < deadline, "shell echo never arrived");
        match socket.read().expect("shell output") {
            Message::Binary(bytes) => {
                collected.extend_from_slice(&bytes);
                if !answered && contains(&collected, b"[6n") {
                    socket
                        .send(Message::Binary(
                            vec![0x1b, b'[', b'1', b';', b'1', b'R'].into(),
                        ))
                        .expect("answer cursor query");
                    answered = true;
                }
            }
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("expected binary output, got {other:?}"),
        }
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// Input larger than the advertised message limit arrives as ordered
/// chunks; the server accepts an aggregate beyond the single-message limit
/// because the relay treats input as a byte stream, and the attachment
/// stays usable afterward.
#[test]
fn attach_accepts_chunked_input_beyond_the_message_limit() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    socket
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(30)))
        .expect("extend read timeout for shell startup");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };
    let scene = establish_scene(&server);
    let hello = full_hello(&scene);
    socket
        .send(Message::Text(hello.into()))
        .expect("client hello");

    // Let the shell become ready first — flooding the input pipe before
    // the startup cursor query is answered stalls the console host itself.
    await_echo(&mut socket, "chunk-ready");

    // 300 KiB of input across two frames, each under the 256 KiB message
    // limit, followed by a line cancel so the shell never executes it.
    let chunk = vec![b'a'; 150 * 1024];
    socket
        .send(Message::Binary(chunk.clone().into()))
        .expect("first chunk");
    socket
        .send(Message::Binary(chunk.into()))
        .expect("second chunk");
    socket
        .send(Message::Binary(vec![0x03].into()))
        .expect("cancel the pending line");
    socket
        .send(Message::Binary(b"exit\r".to_vec().into()))
        .expect("send exit");

    let deadline = Instant::now() + Duration::from_mins(1);
    loop {
        assert!(Instant::now() < deadline, "close frame never arrived");
        match socket.read().expect("read after chunked input") {
            Message::Binary(_) | Message::Ping(_) | Message::Pong(_) => {}
            Message::Close(Some(frame)) => {
                assert_eq!(
                    u16::from(frame.code),
                    1000,
                    "chunked input beyond the message limit never kills the attachment"
                );
                break;
            }
            other => panic!("expected output or close, got {other:?}"),
        }
    }
}

/// Attachments serialize: a second viewer's PTY never spawns while the
/// first is alive, and an abrupt first-socket drop (no close handshake)
/// still releases the second only after the first's teardown.
#[test]
fn attachments_serialize_across_an_abrupt_closure() {
    let server = Server::start().expect("start server");
    let scene = establish_scene(&server);
    let attach = |timeout: Duration| {
        let (status, socket) = upgrade_at(
            server.addr(),
            "/ws/v1/attach",
            &[
                ("Origin", &origin(server.addr())),
                ("Authorization", &bearer(&server)),
            ],
        );
        assert_eq!(status, 101);
        let mut socket = socket.expect("upgraded socket");
        socket
            .get_mut()
            .set_read_timeout(Some(timeout))
            .expect("read timeout");
        let Message::Text(_) = socket.read().expect("server hello") else {
            panic!("expected server hello");
        };
        let hello = full_hello(&scene);
        socket
            .send(Message::Text(hello.into()))
            .expect("client hello");
        socket
    };

    // First attachment reaches a live shell, proven by an echoed marker.
    let mut first = attach(Duration::from_secs(30));
    await_echo(&mut first, "first-ready");

    // Second attachment completes its hello but its PTY spawn is parked on
    // the serialization lock: no output while the first is alive.
    let mut second = attach(Duration::from_secs(2));
    match second.read() {
        Err(_) => {}
        Ok(other) => panic!("second attachment produced output while the first lived: {other:?}"),
    }
    // The first was alive and serviced during that silent window — the
    // negative read discriminates serialization, not a slow second spawn.
    await_echo(&mut first, "serialized-first");

    // Abrupt drop: no close frame, mirroring an abnormal browser closure.
    drop(first);

    // The second's shell flows once the first's teardown releases the lock.
    second
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(30)))
        .expect("extend read timeout");
    let deadline = Instant::now() + Duration::from_mins(1);
    loop {
        assert!(Instant::now() < deadline, "second shell never started");
        match second.read().expect("second shell output") {
            Message::Binary(_) => break,
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("expected binary output, got {other:?}"),
        }
    }
}

/// The cookie a real browser upgrade presents is sufficient on its own:
/// the SPA never holds the bearer token.
#[test]
fn cookie_only_attach_upgrade_succeeds() {
    let server = Server::start().expect("start server");
    let cookie = bootstrap_cookie(&server);
    let (status, socket) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[("Origin", &origin(server.addr())), ("Cookie", &cookie)],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    socket
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(30)))
        .expect("read timeout");
    let Message::Text(hello) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };
    assert!(hello.contains("\"protocol\""));
}

#[test]
fn unauthenticated_inventory_and_attach_are_denied() {
    let server = Server::start().expect("start server");
    let reply = request(
        server.addr(),
        "GET",
        "/api/v1/inventory",
        &[("Host", &host(server.addr()))],
    );
    assert_eq!(reply.status, 401);
    let (status, _socket) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[("Origin", &origin(server.addr()))],
    );
    assert_eq!(status, 401);
}

/// A valid resize is applied silently; the shell stays live. A malformed
/// or out-of-range control frame is a protocol violation closed with
/// POLICY, exactly like the hello path.
#[test]
fn resize_controls_round_trip_and_violations_close_the_connection() {
    let server = Server::start().expect("start server");
    let mut socket = attach_shell(&server);
    await_echo(&mut socket, "resize-ready");
    socket
        .send(Message::Text(
            "{\"resize\":{\"columns\":120,\"rows\":40,\"pixel_width\":960,\"pixel_height\":640}}"
                .into(),
        ))
        .expect("send resize");
    await_echo(&mut socket, "resize-applied");

    socket
        .send(Message::Text(
            "{\"resize\":{\"columns\":2000,\"rows\":40,\"pixel_width\":960,\"pixel_height\":640}}"
                .into(),
        ))
        .expect("send oversized resize");
    expect_policy_close(&mut socket, "invalid resize");

    let mut second = attach_shell(&server);
    await_echo(&mut second, "second-ready");
    second
        .send(Message::Text("{not json".into()))
        .expect("send malformed control");
    expect_policy_close(&mut second, "invalid resize");
}

/// Input beyond the relay's bounded budget cuts the connection with the
/// advertised POLICY close instead of dropping bytes mid-stream.
#[test]
fn input_overflow_closes_the_connection_with_policy() {
    let server = Server::start().expect("start server");
    let mut socket = attach_shell(&server);
    await_echo(&mut socket, "overflow-ready");
    // The shell is told to stop reading input before the flood: an
    // interactive line editor would otherwise consume the burst and keep
    // releasing budget (bash reads arbitrarily long lines; only Windows
    // conhost stalls on its own). The marker is concatenated in the
    // command so its echo-back as typed text cannot satisfy the wait —
    // seeing it assembled in output proves the command executed and the
    // shell is gone or blocked. On POSIX the stty runs first: a canonical
    // tty discards over-long line input instead of blocking the master
    // writer, so raw mode is what makes the flood genuinely back up, and
    // the marker's arrival proves it was already in effect.
    #[cfg(windows)]
    let stall = "echo ('pre-st'+'all'); Start-Sleep -Seconds 600\r";
    #[cfg(not(windows))]
    let stall = "stty raw -echo && echo pre-st''all && exec sleep 600\r";
    socket
        .send(Message::Binary(stall.as_bytes().to_vec().into()))
        .expect("send stall command");
    let deadline = Instant::now() + Duration::from_mins(1);
    let mut output = Vec::new();
    while !contains(&output, b"pre-stall") {
        assert!(Instant::now() < deadline, "stall command never executed");
        match socket.read().expect("stall confirmation") {
            Message::Binary(bytes) => output.extend_from_slice(&bytes),
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("expected binary output, got {other:?}"),
        }
    }
    // Sizing is exact so the close arrives over a graceful FIN: four
    // maximum-size chunks fill the relay budget to the byte, and the
    // fifth — the last frame sent — overflows after the server has read
    // it, leaving no unread data whose teardown-time discard would reset
    // the connection and destroy the buffered close frame this test must
    // observe. The stalled child's terminal input buffer absorbs far less
    // than one chunk, so it cannot free a chunk of budget mid-burst.
    socket
        .get_mut()
        .set_write_timeout(Some(Duration::from_secs(10)))
        .expect("bounded write timeout");
    assert_eq!(
        4 * MAX_FRAME_BYTES,
        terminal::INPUT_BYTE_CAPACITY,
        "burst sizing assumes four maximum-size chunks fill the relay input \
         budget exactly; resize the burst if either constant moves"
    );
    let chunk = vec![b'z'; MAX_FRAME_BYTES];
    for _burst in 0..5 {
        socket
            .send(Message::Binary(chunk.clone().into()))
            .expect("burst send fits the transport");
    }
    socket
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(30)))
        .expect("read timeout");
    let deadline = Instant::now() + Duration::from_mins(1);
    loop {
        assert!(Instant::now() < deadline, "overflow close never arrived");
        if let Message::Close(Some(frame)) = socket.read().expect("read until the advertised close")
        {
            assert_eq!(u16::from(frame.code), 1008, "policy close");
            assert_eq!(frame.reason.as_str(), "input overflow");
            return;
        }
    }
}

/// An expired scene is closed even while the connection is continuously
/// busy. The relay loop's liveness check runs on a persistent timer, so a
/// hot `recv` branch cannot starve it; a fresh per-iteration timer would
/// cancel and restart on every frame and never fire, holding it open.
///
/// Pings are the vector: they are the one client frame the relay ignores
/// without refreshing the scene, so a steady stream of them keeps the loop
/// busy without itself renewing the deadline.
#[test]
fn continuous_activity_does_not_starve_the_scene_deadline_check() {
    // A poll interval far shorter than the real minute so the deadline check
    // is observable within the test, and shorter still than the ping cadence
    // below so the buggy per-iteration timer would provably never elapse;
    // expiry is forced directly rather than waiting out the real bounds.
    let server = Server::start_for_test(Duration::from_millis(200)).expect("start server");
    let scene = establish_scene(&server);
    let mut socket = attach_shell_in_scene(&server, &scene);
    await_echo(&mut socket, "deadline-ready");

    // Read in short slices so each loop turn sends another ping; the server
    // then sees a data frame far more often than every 200ms.
    socket
        .get_ref()
        .set_read_timeout(Some(Duration::from_millis(5)))
        .expect("short read timeout");
    server.expire_scenes();

    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        assert!(
            Instant::now() < deadline,
            "the deadline check never closed the continuously busy attachment"
        );
        socket
            .send(Message::Ping(Vec::new().into()))
            .expect("send keepalive ping");
        match socket.read() {
            Ok(Message::Close(Some(frame))) => {
                assert_eq!(u16::from(frame.code), 1008, "policy close");
                assert_eq!(frame.reason.as_str(), "scene expired");
                return;
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(error) => panic!("unexpected read error: {error:?}"),
        }
    }
}

/// Input typed by a viewer queued behind the serialization lock is
/// buffered and replayed into its shell once the lock frees, so a
/// reconnecting viewer loses no keystrokes while it waits.
#[test]
fn queued_input_replays_into_the_shell_after_the_lock_frees() {
    let server = Server::start().expect("start server");
    let scene = establish_scene(&server);
    let mut first = attach_shell_in_scene(&server, &scene);
    await_echo(&mut first, "first-live");

    // The second attachment completes its hello, then waits on the lock the
    // first still holds. Input sent now must be buffered, not discarded.
    let mut second = attach_shell_in_scene(&server, &scene);
    second
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(30)))
        .expect("read timeout");
    second
        .send(Message::Binary(b"echo queued-marker\r".to_vec().into()))
        .expect("send queued input");

    // Tearing down the first releases the lock; the second's shell then
    // launches and replays the buffered input.
    drop(first);

    let deadline = Instant::now() + Duration::from_mins(1);
    let mut output = Vec::new();
    let mut answered = false;
    while !contains(&output, b"queued-marker") {
        assert!(
            Instant::now() < deadline,
            "replayed input never reached the shell"
        );
        match second.read().expect("second shell output") {
            Message::Binary(bytes) => {
                output.extend_from_slice(&bytes);
                if !answered && contains(&output, b"[6n") {
                    second
                        .send(Message::Binary(
                            vec![0x1b, b'[', b'1', b';', b'1', b'R'].into(),
                        ))
                        .expect("answer cursor query");
                    answered = true;
                }
            }
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("expected binary output, got {other:?}"),
        }
    }
}

/// A malformed resize control from an attachment still queued behind the
/// serialization lock is a protocol violation, closed with the same POLICY
/// as the post-launch path — enforcement is not timing-dependent.
#[test]
fn a_queued_attachments_invalid_resize_closes_with_policy() {
    let server = Server::start().expect("start server");
    let scene = establish_scene(&server);
    let mut first = attach_shell_in_scene(&server, &scene);
    await_echo(&mut first, "first-live");

    // The second completes its hello, then waits on the lock the first
    // holds; a malformed control frame sent now must be refused.
    let mut second = attach_shell_in_scene(&server, &scene);
    second
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(30)))
        .expect("read timeout");
    second
        .send(Message::Text("{not json".into()))
        .expect("send malformed control while queued");
    expect_policy_close(&mut second, "invalid resize");
}

/// A viewer that stops reading must not hold the per-instance attachment
/// lock: the stalled connection's bounded/cancellable send cuts it, so a
/// queued replacement still gets its shell.
#[test]
fn a_stalled_reader_releases_the_attachment_lock() {
    let server = Server::start().expect("start server");
    let scene = establish_scene(&server);
    let mut first = attach_shell_in_scene(&server, &scene);
    await_echo(&mut first, "first-live");
    // Make the shell emit far more than the socket buffer plus the relay
    // output queue, then never read `first` again: the bridge's outbound
    // send blocks on the non-draining peer until the send timeout cuts it.
    let flood = format!("1..40000 | ForEach-Object {{ '{}' }}\r", "x".repeat(50));
    first
        .send(Message::Binary(flood.into_bytes().into()))
        .expect("send flood-producing command");

    // Queued behind the lock the stalled first still holds; it can only
    // reach a live shell once that first is torn down and the lock frees.
    let mut second = attach_shell_in_scene(&server, &scene);
    second
        .get_mut()
        .set_read_timeout(Some(Duration::from_mins(1)))
        .expect("read timeout");
    await_echo(&mut second, "second-live");
}

/// A queued attachment that abandons its connection before its turn must
/// not hold or wedge the serialization lock: a later attachment still
/// reaches a live shell. (The exact lock-and-close-ready-in-one-poll race
/// is timing-dependent; this guards the observable property — the lock
/// cycles cleanly through the abandoned attachment.)
#[test]
fn a_queued_attachment_that_closes_does_not_wedge_the_lock() {
    let server = Server::start().expect("start server");
    let scene = establish_scene(&server);
    let mut first = attach_shell_in_scene(&server, &scene);
    await_echo(&mut first, "first-live");

    // Two more complete their hellos and queue behind the lock the first
    // holds; the middle one then abandons its connection.
    let abandoned = attach_shell_in_scene(&server, &scene);
    let mut third = attach_shell_in_scene(&server, &scene);
    third
        .get_mut()
        .set_read_timeout(Some(Duration::from_mins(1)))
        .expect("read timeout");
    drop(abandoned);

    // Releasing the first must let the lock cycle past the abandoned
    // attachment to the third.
    drop(first);
    await_echo(&mut third, "third-live");
}

/// Open an authenticated attach socket and complete the hello exchange.
/// A hello without a scene credential is refused before any PTY work,
/// even though it authenticated the upgrade with a valid bearer.
#[test]
fn an_attach_hello_without_a_scene_credential_is_refused() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    socket
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("read timeout");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };
    let hello = format!(
        "{{\"protocol\":{PROTOCOL_VERSION},\"capabilities\":{{\"unicode_width\":11,\"ignores_conpty_mode_requests\":true}},\"initial\":{{\"columns\":100,\"rows\":30,\"pixel_width\":800,\"pixel_height\":480}}}}"
    );
    socket
        .send(Message::Text(hello.into()))
        .expect("scene-less hello");
    match socket.read().expect("close frame") {
        Message::Close(Some(frame)) => {
            assert_eq!(u16::from(frame.code), 1008, "policy close");
            assert_eq!(frame.reason.as_str(), "invalid scene credential");
        }
        other => panic!("expected close frame, got {other:?}"),
    }
}

/// A hello with an unknown or wrong scene credential is refused.
#[test]
fn an_attach_hello_with_a_wrong_scene_credential_is_refused() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    socket
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("read timeout");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };
    let forged = ("f".repeat(64), "0".repeat(64));
    socket
        .send(Message::Text(full_hello(&forged).into()))
        .expect("forged-scene hello");
    match socket.read().expect("close frame") {
        Message::Close(Some(frame)) => {
            assert_eq!(u16::from(frame.code), 1008, "policy close");
            assert_eq!(frame.reason.as_str(), "invalid scene credential");
        }
        other => panic!("expected close frame, got {other:?}"),
    }
}

/// The session cookie alone cannot mint a scene: with no bearer and no
/// mint code, the exchange is unauthorized.
#[test]
fn the_session_cookie_alone_cannot_mint_a_scene() {
    let server = Server::start().expect("start server");
    let cookie = bootstrap_cookie(&server);
    let reply = request(
        server.addr(),
        "POST",
        "/api/v1/scene",
        &[
            ("Host", &host(server.addr())),
            ("Origin", &origin(server.addr())),
            ("Cookie", &cookie),
        ],
    );
    assert_eq!(
        reply.status, 401,
        "cookie without a mint code mints nothing"
    );
}

/// A bootstrap mint code, delivered in the redirect fragment, exchanges
/// once for a scene and never again.
#[test]
fn a_bootstrap_mint_code_exchanges_once() {
    let server = Server::start().expect("start server");
    let target = format!("/?auth_token={}", server.token());
    let redirect = request(
        server.addr(),
        "GET",
        &target,
        &[("Host", &host(server.addr()))],
    );
    assert_eq!(redirect.status, 303);
    let location = redirect.header("location").expect("redirect location");
    let code = location
        .split("#mint=")
        .nth(1)
        .expect("mint code in fragment");
    let set_cookie = redirect.header("set-cookie").expect("bootstrap cookie");
    let cookie = set_cookie
        .split(';')
        .next()
        .expect("cookie pair")
        .to_owned();

    let exchange = request(
        server.addr(),
        "POST",
        "/api/v1/scene",
        &[
            ("Host", &host(server.addr())),
            ("Origin", &origin(server.addr())),
            ("Cookie", &cookie),
            ("x-ghosthub-mint", code),
        ],
    );
    assert_eq!(exchange.status, 200, "the mint code redeems for a scene");
    let scene: serde_json::Value = serde_json::from_str(&exchange.body).expect("scene json");
    assert_eq!(scene["scene_id"].as_str().expect("scene_id").len(), 64);

    // Single-use: the same code is spent.
    let replay = request(
        server.addr(),
        "POST",
        "/api/v1/scene",
        &[
            ("Host", &host(server.addr())),
            ("Origin", &origin(server.addr())),
            ("Cookie", &cookie),
            ("x-ghosthub-mint", code),
        ],
    );
    assert_eq!(replay.status, 401, "a spent mint code mints nothing");
}

/// Establish a scene via the exchange endpoint (bearer path) and return
/// its (`scene_id`, `scene_secret`), for hellos that must carry a valid scene
/// credential.
fn establish_scene(server: &Server) -> (String, String) {
    let reply = request(
        server.addr(),
        "POST",
        "/api/v1/scene",
        &[
            ("Host", &host(server.addr())),
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(server)),
        ],
    );
    assert_eq!(reply.status, 200, "scene exchange");
    let body: serde_json::Value = serde_json::from_str(&reply.body).expect("scene json");
    (
        body["scene_id"].as_str().expect("scene_id").to_owned(),
        body["scene_secret"]
            .as_str()
            .expect("scene_secret")
            .to_owned(),
    )
}

/// A complete, valid client hello carrying the scene credential plus the
/// standard capabilities and geometry.
fn full_hello(scene: &(String, String)) -> String {
    let (scene_id, scene_secret) = scene;
    format!(
        "{{\"protocol\":{PROTOCOL_VERSION},\"scene_id\":\"{scene_id}\",\
         \"scene_secret\":\"{scene_secret}\",\"capabilities\":{{\"unicode_width\":11,\
         \"ignores_conpty_mode_requests\":true}},\"initial\":{{\"columns\":100,\"rows\":30,\
         \"pixel_width\":800,\"pixel_height\":480}}}}"
    )
}

fn attach_shell(server: &Server) -> WebSocket<TcpStream> {
    let scene = establish_scene(server);
    attach_shell_in_scene(server, &scene)
}

/// Complete an attach in a specific scene. Two attachments in the same
/// scene serialize on that scene's lock (a replacement waits for its
/// predecessor's teardown); separate scenes never block each other.
fn attach_shell_in_scene(server: &Server, scene: &(String, String)) -> WebSocket<TcpStream> {
    let (status, socket) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    socket
        .get_mut()
        .set_read_timeout(Some(Duration::from_secs(30)))
        .expect("read timeout");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };
    socket
        .send(Message::Text(full_hello(scene).into()))
        .expect("client hello");
    socket
}

/// Read until the close frame and assert it is the named POLICY close.
fn expect_policy_close(socket: &mut WebSocket<TcpStream>, reason: &str) {
    let deadline = Instant::now() + Duration::from_mins(1);
    loop {
        assert!(Instant::now() < deadline, "policy close never arrived");
        if let Message::Close(Some(frame)) = socket.read().expect("read until close") {
            assert_eq!(u16::from(frame.code), 1008, "policy close");
            assert_eq!(frame.reason.as_str(), reason);
            return;
        }
    }
}

/// An attach hello that satisfies the capability contract but omits the
/// viewer's initial geometry must be rejected: the PTY never opens at a
/// default size.
#[test]
fn attach_hello_without_geometry_is_rejected() {
    let server = Server::start().expect("start server");
    let (status, socket) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[
            ("Origin", &origin(server.addr())),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 101);
    let mut socket = socket.expect("upgraded socket");
    let Message::Text(_) = socket.read().expect("server hello") else {
        panic!("expected server hello");
    };

    let scene = establish_scene(&server);
    socket
        .send(Message::Text(compatible_client_hello(&scene).into()))
        .expect("client hello without geometry");

    match socket.read().expect("close frame") {
        Message::Close(Some(frame)) => {
            assert_eq!(
                u16::from(frame.code),
                1008,
                "missing geometry is a policy violation"
            );
        }
        other => panic!("expected close frame, got {other:?}"),
    }
}

/// The attach upgrade sits behind the same origin gate as the hello
/// endpoint.
#[test]
fn attach_upgrade_rejects_a_wrong_origin() {
    let server = Server::start().expect("start server");
    let (status, _) = upgrade_at(
        server.addr(),
        "/ws/v1/attach",
        &[
            ("Origin", "http://evil.example"),
            ("Authorization", &bearer(&server)),
        ],
    );
    assert_eq!(status, 403);
}
