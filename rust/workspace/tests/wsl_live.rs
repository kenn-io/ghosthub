#![cfg(windows)]

use std::ffi::OsStr;
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant};

use config::TerminalAppearance;
use host::WslConfig;
use workspace::{KeyInput, Modifiers, NamedKey, Workspace, WorkspaceContent, WorkspaceEvent};

struct IsolatedServer {
    tmpdir: String,
}

impl IsolatedServer {
    fn start(label: &str) -> Self {
        let tmpdir = format!(
            "/tmp/ghosthub-workspace-test-{}-{label}",
            std::process::id()
        );
        assert!(tmpdir.starts_with("/tmp/ghosthub-workspace-test-"));
        let server = Self { tmpdir };
        server.run_tmux(["new-session", "-d", "-s", "workspace-live"]);
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

impl Drop for IsolatedServer {
    fn drop(&mut self) {
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
        assert!(self.tmpdir.starts_with("/tmp/ghosthub-workspace-test-"));
        let _ignored = Command::new("wsl.exe")
            .args(["--exec", "/usr/bin/rm", "-rf", "--", &self.tmpdir])
            .output();
    }
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn discovers_attaches_renders_and_detaches_through_workspace() {
    let server = IsolatedServer::start("roundtrip");
    let identity = server.identity();
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "workspace-live")
        )
    });
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
        workspace.drain_events().into_iter().any(|event| {
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
    let server = IsolatedServer::start("stale-identity");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "workspace-live")
        )
    });
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

fn wait_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "condition did not become true");
        thread::sleep(Duration::from_millis(25));
    }
}
