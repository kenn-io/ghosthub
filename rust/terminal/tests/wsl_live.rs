#![cfg(windows)]

use std::ffi::{OsStr, OsString};
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant};

use session::{AttachPlan, SessionIdentity};
use surface::GridSize;
use terminal::TerminalWorker;

struct IsolatedServer {
    tmpdir: String,
}

impl IsolatedServer {
    fn start() -> Self {
        let tmpdir = format!("/tmp/ghosthub-terminal-test-{}", std::process::id());
        assert!(tmpdir.starts_with("/tmp/ghosthub-terminal-test-"));
        let server = Self { tmpdir };
        server.run_tmux(["new-session", "-d", "-s", "ghosthub-live"]);
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
        AttachPlan::attach_only(
            "wsl.exe",
            [
                "--exec",
                "/usr/bin/env",
                "TERM=xterm-256color",
                &format!("TMUX_TMPDIR={}", self.tmpdir),
                "/usr/bin/tmux",
                "attach-session",
                "-E",
                "-t",
                "=ghosthub-live",
            ]
            .into_iter()
            .map(OsString::from)
            .collect(),
            "ghosthub-live",
            identity,
        )
    }

    fn client_count(&self) -> usize {
        let output = self.run_tmux(["list-clients", "-F", "#{client_pid}"]);
        String::from_utf8(output.stdout)
            .expect("UTF-8 client list")
            .lines()
            .count()
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
        assert!(self.tmpdir.starts_with("/tmp/ghosthub-terminal-test-"));
        let _ignored = Command::new("wsl.exe")
            .args(["--exec", "/usr/bin/rm", "-rf", "--", &self.tmpdir])
            .output();
    }
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn attach_detach_and_reattach_preserve_the_exact_session() {
    let server = IsolatedServer::start();
    let identity = server.identity();
    let size = GridSize::new(80, 24).expect("valid grid");

    let plan = server.attach_plan(identity.clone());
    let worker = TerminalWorker::attach(&plan, size).expect("attach ordinary WSL tmux client");
    wait_for_client_count(&server, 1);
    worker
        .send_bytes(b"echo relay-ready\r".to_vec())
        .expect("send terminal input");
    wait_for_surface_text(&worker, "relay-ready");
    drop(worker);

    wait_for_client_count(&server, 0);
    assert_eq!(server.identity(), identity, "detach must preserve identity");

    let plan = server.attach_plan(identity.clone());
    let worker = TerminalWorker::attach(&plan, size).expect("reattach ordinary WSL tmux client");
    wait_for_client_count(&server, 1);
    worker
        .send_bytes(b"echo reattached\r".to_vec())
        .expect("send terminal input after reattach");
    wait_for_surface_text(&worker, "reattached");
    assert_eq!(
        server.identity(),
        identity,
        "reattach must use the same session"
    );
}

fn wait_for_client_count(server: &IsolatedServer, expected: usize) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if server.client_count() == expected {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "tmux client count did not reach {expected}"
        );
        thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_surface_text(worker: &TerminalWorker, expected: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let surface = worker.surface().load();
        let text = surface
            .cells()
            .iter()
            .map(surface::Cell::text)
            .collect::<String>();
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
