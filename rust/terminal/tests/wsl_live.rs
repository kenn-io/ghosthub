#![cfg(windows)]

use std::ffi::{OsStr, OsString};
use std::fs;
use std::process::{Child, Command, Output};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use input::{KeyInput, Modifiers, NamedKey};
use session::{AttachPlan, SessionIdentity};
use surface::GridSize;
use terminal::TerminalWorker;

struct IsolatedServer {
    tmpdir: String,
}

static WSL_LIVE: Mutex<()> = Mutex::new(());

#[test]
fn isolated_namespace_includes_a_cross_process_nonce() {
    assert_eq!(isolated_tmpdir("detach", 42, 100), "/tmp/ght-2a-64-detach");
}

impl IsolatedServer {
    fn start(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let tmpdir = isolated_tmpdir(label, std::process::id(), nonce);
        assert!(tmpdir.starts_with("/tmp/ght-"));
        let mkdir = Command::new("wsl.exe")
            .args(["--exec", "/usr/bin/mkdir", "-p", "--", &tmpdir])
            .output()
            .expect("create isolated tmux directory");
        assert!(
            mkdir.status.success(),
            "create isolated tmux directory: {}",
            String::from_utf8_lossy(&mkdir.stderr)
        );
        let server = Self { tmpdir };
        server.run_tmux(["new-session", "-d", "-s", "ghosthub-live"]);
        let socket = server.run_tmux(["display-message", "-p", "#{socket_path}"]);
        let socket = String::from_utf8(socket.stdout).expect("UTF-8 tmux socket path");
        assert!(
            socket.trim().starts_with(&format!("{}/", server.tmpdir)),
            "test tmux escaped its isolated directory: {socket:?}"
        );
        server
    }

    fn run_tmux<I, S>(&self, args: I) -> Output
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let mut command = Command::new("wsl.exe");
        command.args([
            "--exec",
            "/usr/bin/env",
            &format!("TMUX_TMPDIR={}", self.tmpdir),
            "/usr/bin/tmux",
            "-f",
            "/dev/null",
        ]);
        command.args(args);
        let output = command.output().expect("run isolated WSL tmux command");
        assert!(
            output.status.success(),
            "isolated tmux failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        output
    }

    fn identity(&self) -> SessionIdentity {
        let output = self.run_tmux([
            "list-sessions",
            "-F",
            "#{pid}\t#{session_id}\t#{session_created}",
        ]);
        let text = String::from_utf8(output.stdout).expect("UTF-8 tmux identity");
        let fields = text.trim().split('\t').collect::<Vec<_>>();
        assert_eq!(fields.len(), 3);
        SessionIdentity::new(
            fields[0].parse().expect("server PID"),
            fields[1],
            fields[2].parse().expect("creation time"),
        )
    }

    fn attach_plan(&self, identity: SessionIdentity) -> AttachPlan {
        attach_plan(&self.tmpdir, identity)
    }

    fn client_count(&self) -> usize {
        let output = self.run_tmux(["list-clients", "-F", "#{client_pid}"]);
        String::from_utf8(output.stdout)
            .expect("UTF-8 client list")
            .lines()
            .count()
    }

    fn session_environment(&self, name: &str) -> String {
        let output = self.run_tmux(["show-environment", "-t", "=ghosthub-live", name]);
        String::from_utf8(output.stdout)
            .expect("UTF-8 tmux environment")
            .trim()
            .to_owned()
    }
}

fn isolated_tmpdir(label: &str, process_id: u32, nonce: u128) -> String {
    format!("/tmp/ght-{process_id:x}-{nonce:x}-{label}")
}

impl Drop for IsolatedServer {
    fn drop(&mut self) {
        if !self.tmpdir.starts_with("/tmp/ght-") {
            return;
        }
        let _ignored = Command::new("wsl.exe")
            .args([
                "--exec",
                "/usr/bin/env",
                &format!("TMUX_TMPDIR={}", self.tmpdir),
                "/usr/bin/tmux",
                "-f",
                "/dev/null",
                "kill-server",
            ])
            .output();
        let _ignored = Command::new("wsl.exe")
            .args(["--exec", "/usr/bin/rm", "-rf", "--", &self.tmpdir])
            .output();
    }
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn attach_detach_and_reattach_preserve_the_exact_session() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("detach");
    let identity = server.identity();
    let size = GridSize::new(80, 24).expect("valid grid");

    let plan = server.attach_plan(identity.clone());
    let worker = TerminalWorker::attach(&plan, size).expect("attach ordinary WSL tmux client");
    wait_for_client_count(&server, 1);
    wait_until(
        Duration::from_secs(5),
        "a real tmux attachment did not enter the alternate screen",
        || worker.is_confirmed_live(),
    );
    send_command(&worker, "echo relay-ready");
    wait_for_surface_text(&worker, "relay-ready");
    drop(worker);

    wait_for_client_count(&server, 0);
    assert_eq!(server.identity(), identity, "detach must preserve identity");

    let plan = server.attach_plan(identity.clone());
    let worker = TerminalWorker::attach(&plan, size).expect("reattach ordinary WSL tmux client");
    wait_for_client_count(&server, 1);
    send_command(&worker, "echo reattached");
    wait_for_surface_text(&worker, "reattached");
    assert_eq!(
        server.identity(),
        identity,
        "reattach must use the same session"
    );
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn conpty_attachment_proves_preserve_environment_with_a_positive_control() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("preserve-environment");
    let identity = server.identity();
    let size = GridSize::new(80, 24).expect("valid grid");
    server.run_tmux([
        "set-option",
        "-t",
        "ghosthub-live",
        "update-environment",
        "GHOSTHUB_PROBE",
    ]);
    server.run_tmux([
        "set-environment",
        "-t",
        "=ghosthub-live",
        "GHOSTHUB_PROBE",
        "session",
    ]);

    let control = TerminalWorker::attach(
        &attach_plan_with_environment(
            &server.tmpdir,
            identity.clone(),
            false,
            "GHOSTHUB_PROBE=control-client",
        ),
        size,
    )
    .expect("attach control client without -E");
    wait_for_client_count(&server, 1);
    assert_eq!(
        server.session_environment("GHOSTHUB_PROBE"),
        "GHOSTHUB_PROBE=control-client",
        "the control attachment must prove that update-environment is observable"
    );
    drop(control);
    wait_for_client_count(&server, 0);

    server.run_tmux([
        "set-environment",
        "-t",
        "=ghosthub-live",
        "GHOSTHUB_PROBE",
        "session",
    ]);
    let preserved = TerminalWorker::attach(
        &attach_plan_with_environment(
            &server.tmpdir,
            identity,
            true,
            "GHOSTHUB_PROBE=preserve-client",
        ),
        size,
    )
    .expect("attach proof client with -E");
    wait_for_client_count(&server, 1);
    assert_eq!(
        server.session_environment("GHOSTHUB_PROBE"),
        "GHOSTHUB_PROBE=session",
        "-E must preserve the session environment"
    );
    drop(preserved);
}

#[test]
#[ignore = "requires WSL2 and tmux; force-terminates an isolated helper process"]
fn forced_terminal_owner_exit_preserves_the_exact_session() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("force");
    let identity = server.identity();
    let (mut helper, ready, release) = spawn_owner_helper(&server, &identity, "force");

    wait_until(
        Duration::from_secs(10),
        "helper did not become ready",
        || ready.exists(),
    );
    wait_for_client_count(&server, 1);
    helper.kill().expect("force-terminate terminal owner");
    let status = helper.wait().expect("wait for terminated helper");
    assert!(!status.success(), "forced helper exit must be abnormal");

    wait_for_client_count(&server, 0);
    assert_eq!(
        server.identity(),
        identity,
        "forced application death must preserve the exact session"
    );

    let worker = TerminalWorker::attach(
        &server.attach_plan(identity.clone()),
        GridSize::new(80, 24).expect("valid grid"),
    )
    .expect("reattach after forced terminal-owner exit");
    wait_for_client_count(&server, 1);
    send_command(&worker, "echo force-reattached");
    wait_for_surface_text(&worker, "force-reattached");
    assert_eq!(server.identity(), identity);
    let _ignored = fs::remove_file(ready);
    let _ignored = fs::remove_file(release);
}

#[test]
#[ignore = "requires WSL2 and tmux; exits an isolated helper process gracefully"]
fn graceful_terminal_owner_exit_preserves_the_exact_session() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("graceful");
    let identity = server.identity();
    let (mut helper, ready, release) = spawn_owner_helper(&server, &identity, "graceful");

    wait_until(
        Duration::from_secs(10),
        "helper did not become ready",
        || ready.exists(),
    );
    wait_for_client_count(&server, 1);
    fs::write(&release, b"release").expect("release graceful helper");
    let status = helper.wait().expect("wait for graceful helper");
    assert!(status.success(), "graceful helper must exit successfully");

    wait_for_client_count(&server, 0);
    assert_eq!(
        server.identity(),
        identity,
        "graceful application exit must preserve the exact session"
    );
    let _ignored = fs::remove_file(ready);
    let _ignored = fs::remove_file(release);
}

#[test]
fn forced_exit_helper() {
    let Ok(tmpdir) = std::env::var("GHOSTHUB_WSL_FORCE_EXIT_TMPDIR") else {
        return;
    };
    let ready = std::env::var_os("GHOSTHUB_WSL_FORCE_EXIT_READY")
        .map(std::path::PathBuf::from)
        .expect("helper ready path");
    let identity = SessionIdentity::new(
        required_env_parse("GHOSTHUB_WSL_FORCE_EXIT_SERVER_PID"),
        std::env::var("GHOSTHUB_WSL_FORCE_EXIT_SESSION_ID").expect("helper session ID"),
        required_env_parse("GHOSTHUB_WSL_FORCE_EXIT_CREATED_AT"),
    );
    let worker = TerminalWorker::attach(
        &attach_plan(&tmpdir, identity),
        GridSize::new(80, 24).expect("valid grid"),
    )
    .expect("helper attach");
    fs::write(ready, b"ready").expect("publish helper readiness");
    let release = std::env::var_os("GHOSTHUB_WSL_FORCE_EXIT_RELEASE")
        .map(std::path::PathBuf::from)
        .expect("helper release path");
    while !release.exists() {
        std::hint::black_box(&worker);
        thread::sleep(Duration::from_millis(25));
    }
}

fn spawn_owner_helper(
    server: &IsolatedServer,
    identity: &SessionIdentity,
    label: &str,
) -> (Child, std::path::PathBuf, std::path::PathBuf) {
    let stem = format!("ghosthub-terminal-owner-{label}-{}", std::process::id());
    let ready = std::env::temp_dir().join(format!("{stem}.ready"));
    let release = std::env::temp_dir().join(format!("{stem}.release"));
    let _ignored = fs::remove_file(&ready);
    let _ignored = fs::remove_file(&release);
    let child = Command::new(std::env::current_exe().expect("current test executable"))
        .args(["--exact", "forced_exit_helper", "--nocapture"])
        .env("GHOSTHUB_WSL_FORCE_EXIT_TMPDIR", &server.tmpdir)
        .env("GHOSTHUB_WSL_FORCE_EXIT_READY", &ready)
        .env("GHOSTHUB_WSL_FORCE_EXIT_RELEASE", &release)
        .env(
            "GHOSTHUB_WSL_FORCE_EXIT_SERVER_PID",
            identity.server_pid().to_string(),
        )
        .env("GHOSTHUB_WSL_FORCE_EXIT_SESSION_ID", identity.session_id())
        .env(
            "GHOSTHUB_WSL_FORCE_EXIT_CREATED_AT",
            identity.created_at().to_string(),
        )
        .spawn()
        .expect("spawn isolated terminal-owner helper");
    (child, ready, release)
}

fn attach_plan(tmpdir: &str, identity: SessionIdentity) -> AttachPlan {
    attach_plan_with_environment(tmpdir, identity, true, "GHOSTHUB_PROBE=unused")
}

fn attach_plan_with_environment(
    tmpdir: &str,
    identity: SessionIdentity,
    preserve_environment: bool,
    environment: &str,
) -> AttachPlan {
    let mut arguments = vec![
        OsString::from("--exec"),
        OsString::from("/usr/bin/env"),
        OsString::from("TERM=xterm-256color"),
        OsString::from(environment),
        OsString::from(format!("TMUX_TMPDIR={tmpdir}")),
        OsString::from("/usr/bin/tmux"),
        OsString::from("attach-session"),
    ];
    if preserve_environment {
        arguments.push(OsString::from("-E"));
    }
    arguments.extend([OsString::from("-t"), OsString::from("=ghosthub-live")]);
    AttachPlan::attach_only("wsl.exe", arguments, "ghosthub-live", identity)
}

fn required_env_parse<T>(name: &str) -> T
where
    T: std::str::FromStr,
    T::Err: std::fmt::Debug,
{
    std::env::var(name)
        .unwrap_or_else(|_| panic!("missing helper environment {name}"))
        .parse()
        .unwrap_or_else(|error| panic!("invalid helper environment {name}: {error:?}"))
}

fn send_command(worker: &TerminalWorker, command: &str) {
    worker
        .send_key(KeyInput::text(command, Modifiers::default()))
        .expect("send terminal text");
    worker
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .expect("send terminal enter");
}

fn wait_for_client_count(server: &IsolatedServer, expected: usize) {
    wait_until(
        Duration::from_secs(5),
        &format!("tmux client count did not reach {expected}"),
        || server.client_count() == expected,
    );
}

fn wait_until(timeout: Duration, message: &str, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + timeout;
    while !condition() {
        assert!(Instant::now() < deadline, "{message}");
        thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_surface_text(worker: &TerminalWorker, expected: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let surface = worker.surface().load();
        let text = surface.cells().map(surface::Cell::text).collect::<String>();
        if text.contains(expected) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "surface never contained {expected:?}"
        );
        drop(surface);
        thread::sleep(Duration::from_millis(10));
    }
}
