#![cfg(windows)]

use std::ffi::OsStr;
use std::process::{Command, Output};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use config::TerminalAppearance;
use host::WslConfig;
use workspace::{KeyInput, Modifiers, NamedKey, Workspace, WorkspaceContent, WorkspaceEvent};

struct IsolatedServer {
    tmpdir: String,
}

static WSL_LIVE: Mutex<()> = Mutex::new(());

#[test]
fn isolated_namespace_includes_a_cross_process_nonce() {
    assert_eq!(isolated_tmpdir("attach", 42, 100), "/tmp/ghw-2a-64-attach");
}

impl IsolatedServer {
    fn start(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let tmpdir = isolated_tmpdir(label, std::process::id(), nonce);
        assert!(tmpdir.starts_with("/tmp/ghw-"));
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
        server.run_tmux(["new-session", "-d", "-s", "workspace-live"]);
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

    fn identity(&self) -> String {
        let output = self.run_tmux([
            "list-sessions",
            "-F",
            "#{pid}:#{session_id}:#{session_created}",
        ]);
        String::from_utf8(output.stdout)
            .expect("UTF-8 tmux identity")
            .trim()
            .to_owned()
    }
}

fn isolated_tmpdir(label: &str, process_id: u32, nonce: u128) -> String {
    format!("/tmp/ghw-{process_id:x}-{nonce:x}-{label}")
}

impl Drop for IsolatedServer {
    fn drop(&mut self) {
        if !self.tmpdir.starts_with("/tmp/ghw-") {
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
fn discovers_attaches_renders_and_detaches_through_workspace() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("roundtrip");
    let identity = server.identity();
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.iter().any(|session| session.name() == "workspace-live")
            )
        },
        || workspace_diagnostic(&workspace),
    );
    workspace.attach("workspace-live").expect("attach session");
    assert!(
        workspace.attach("workspace-live").is_err(),
        "a second presentation must lose the single-window reservation"
    );
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "workspace-live"
        )
    });
    workspace
        .send_key(KeyInput::text("echo workspace-ready", Modifiers::default()))
        .expect("send text");
    workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .expect("send enter");
    wait_until(|| terminal_contains(&workspace, "workspace-ready"));

    server.run_tmux(["set-buffer", "-w", "Hello"]);
    wait_until(|| {
        workspace.drain_events().0.into_iter().any(|event| {
            matches!(
                event,
                WorkspaceEvent::ClipboardWrite { text, primary: false } if text == "Hello"
            )
        })
    });

    workspace.detach();
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { .. }
        )
    });
    assert_eq!(server.identity(), identity);
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn refuses_to_attach_when_the_discovered_session_was_replaced() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("stale-identity");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.iter().any(|session| session.name() == "workspace-live")
            )
        },
        || workspace_diagnostic(&workspace),
    );
    server.run_tmux(["kill-session", "-t", "=workspace-live"]);
    server.run_tmux(["new-session", "-d", "-s", "workspace-live"]);

    workspace
        .attach("workspace-live")
        .expect("begin guarded attach");

    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Error { message }
                if message.contains("identity changed")
        )
    });
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn detach_restores_the_inventory_revalidated_during_attachment() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("attach-inventory");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.len() == 1 && sessions[0].name() == "workspace-live"
            )
        },
        || workspace_diagnostic(&workspace),
    );
    server.run_tmux(["new-session", "-d", "-s", "appeared-before-attach"]);

    workspace
        .attach("workspace-live")
        .expect("attach session after inventory changed");
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "workspace-live"
        )
    });
    workspace.detach();

    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "appeared-before-attach")
        )
    });
}

fn terminal_contains(workspace: &Workspace, expected: &str) -> bool {
    let snapshot = workspace.snapshot();
    let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
        return false;
    };
    surface
        .load()
        .cells()
        .map(surface::Cell::text)
        .collect::<String>()
        .contains(expected)
}

#[track_caller]
fn wait_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "condition did not become true");
        thread::sleep(Duration::from_millis(25));
    }
}

#[track_caller]
fn wait_until_with_diagnostic(
    mut condition: impl FnMut() -> bool,
    diagnostic: impl Fn() -> String,
) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "condition did not become true: {}",
            diagnostic()
        );
        thread::sleep(Duration::from_millis(25));
    }
}

fn workspace_diagnostic(workspace: &Workspace) -> String {
    match workspace.snapshot().content() {
        WorkspaceContent::Shell => "shell".to_owned(),
        WorkspaceContent::Loading => "loading".to_owned(),
        WorkspaceContent::Ready { endpoint, sessions } => {
            format!("ready in {endpoint} with {} sessions", sessions.len())
        }
        WorkspaceContent::Attaching { endpoint, session } => {
            format!("attaching {session} in {endpoint}")
        }
        WorkspaceContent::Terminal {
            endpoint, session, ..
        } => format!("attached to {session} in {endpoint}"),
        WorkspaceContent::Error { message } => format!("error: {message}"),
    }
}
