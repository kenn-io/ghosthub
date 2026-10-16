#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use config::TerminalAppearance;
use host::LocalConfig;
use workspace::{
    HerdrLifecycleAction, HerdrSessionState, HostConnectionState, KeyInput, LocalHostSpec,
    Modifiers, NamedKey, SessionSelection, Workspace, WorkspaceContent, WorkspaceEvent,
};

struct Fixture {
    workspace: Workspace,
    root: PathBuf,
}

impl Fixture {
    fn new(root: PathBuf) -> Self {
        let config = LocalConfig::native(
            "/usr/bin/tmux",
            Some(root.join("tmux").display().to_string()),
        )
        .unwrap();
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(LocalHostSpec::native(config)),
        );
        let fixture = Self { workspace, root };
        fixture.workspace.start_inventory_cadence().unwrap();
        fixture.workspace.connect_host("local").unwrap();
        fixture.wait(|| {
            fixture.workspace.snapshot().hosts()[0].connection() == HostConnectionState::Ready
        });
        fixture
    }

    fn selection(&self) -> SessionSelection {
        let snapshot = self.workspace.snapshot();
        let host = &snapshot.hosts()[0];
        SessionSelection::herdr(host.id(), host.endpoint(), "review")
    }

    #[track_caller]
    fn wait(&self, mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !condition() {
            for event in self.workspace.drain_events().0 {
                if let WorkspaceEvent::Error(message) = event {
                    panic!("{message}");
                }
            }
            assert!(
                Instant::now() < deadline,
                "Herdr timed out: {:?}; terminal: {}",
                self.workspace.snapshot().hosts(),
                self.terminal_text(),
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn terminal_text(&self) -> String {
        let snapshot = self.workspace.snapshot();
        let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
            return String::new();
        };
        surface.load().cells().map(surface::Cell::text).collect()
    }

    fn wait_session(&self, state: HerdrSessionState) {
        self.wait(|| {
            self.workspace.snapshot().hosts()[0]
                .herdr_sessions()
                .iter()
                .any(|session| {
                    session.name() == "review"
                        && session.state() == state
                        && session.lifecycle_action().is_none()
                        && !session.launch_pending()
                })
        });
    }

    fn shell_probe(&self, marker: &str) {
        self.wait(|| matches!(self.workspace.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "review"));
        self.wait(|| self.terminal_text().contains('$'));
        // Fresh Herdr sessions start in navigation mode; Enter focuses the pane.
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .unwrap();
        self.workspace
            .send_key(KeyInput::text(
                format!("printf 'herdr-%s\\n' {marker}"),
                Modifiers::default(),
            ))
            .unwrap();
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .unwrap();
        self.wait(|| self.terminal_text().contains(&format!("herdr-{marker}")));
    }

    fn lifecycle(&self, action: HerdrLifecycleAction) {
        self.workspace
            .request_herdr_lifecycle(&self.selection(), action)
            .unwrap();
        self.workspace.confirm_herdr_lifecycle().unwrap();
    }

    fn session_list(&self) -> serde_json::Value {
        let output = Command::new(self.root.join("bin/herdr"))
            .args(["session", "list", "--json"])
            .output()
            .unwrap();
        assert!(output.status.success());
        serde_json::from_slice(&output.stdout).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.workspace.close();
        // The PID namespace also reaps descendants if the test panics.
        let _ = Command::new(self.root.join("bin/herdr"))
            .args(["session", "stop", "review", "--json"])
            .output();
    }
}

fn isolated_fixture() -> Option<Fixture> {
    let Some(root) = std::env::var_os("GHOSTHUB_HERDR_FIXTURE") else {
        let helper = std::env::var_os("GHOSTHUB_HERDR_TEST").expect("staged Linux Herdr binary");
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("gh-h-{}-{nonce:x}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        for dir in [
            "home",
            "bin",
            "config",
            "config/herdr",
            "state",
            "runtime",
            "tmux",
        ] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join(dir))
                .unwrap();
        }
        fs::copy(helper, root.join("bin/herdr")).unwrap();
        fs::copy(
            std::env::current_exe().unwrap(),
            root.join("bin/native_herdr"),
        )
        .unwrap();
        fs::write(
            root.join("home/.profile"),
            "export PATH=\"$HOME/../bin:/usr/bin:/bin\"\n",
        )
        .unwrap();
        fs::write(root.join("gitconfig"), "").unwrap();
        fs::write(
            root.join("config/herdr/config.toml"),
            "onboarding = false\n[terminal]\ndefault_shell = '/bin/sh'\nshell_mode = 'non_login'\n",
        )
        .unwrap();
        let result = Command::new("bwrap")
            .args([
                "--unshare-user",
                "--unshare-pid",
                "--unshare-net",
                "--die-with-parent",
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--bind",
            ])
            .arg(&root)
            .arg(&root)
            .args(["--proc", "/proc", "--dev", "/dev"])
            .arg(root.join("bin/native_herdr"))
            .args([
                "--exact",
                "native_herdr_lifecycle",
                "--ignored",
                "--nocapture",
            ])
            .current_dir(&root)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", root.join("home"))
            .env("XDG_CONFIG_HOME", root.join("config"))
            .env("XDG_STATE_HOME", root.join("state"))
            .env("XDG_RUNTIME_DIR", root.join("runtime"))
            .env("GHOSTHUB_HERDR_FIXTURE", &root)
            .env("GIT_CONFIG_GLOBAL", root.join("gitconfig"))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("SHELL", "/bin/sh")
            .env("LANG", "C.UTF-8")
            .env("TERM", "xterm-256color")
            .status()
            .unwrap();
        fs::remove_dir_all(root).unwrap();
        assert!(result.success());
        return None;
    };
    Some(Fixture::new(root.into()))
}

#[test]
#[ignore = "requires Linux Herdr and Bubblewrap; run make rust-test-herdr-live"]
fn native_herdr_lifecycle() {
    let Some(fixture) = isolated_fixture() else {
        return;
    };
    assert!(fixture.workspace.snapshot().hosts()[0].herdr_available());
    fixture
        .workspace
        .create_herdr_session("local", "Linux", "review")
        .unwrap();
    fixture.wait_session(HerdrSessionState::Running);
    fixture.shell_probe("created");

    fixture.workspace.detach();
    let inventory = fixture.session_list();
    let record = inventory["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["name"] == "review")
        .unwrap();
    assert_eq!(record["running"], true);
    assert!(PathBuf::from(record["session_dir"].as_str().unwrap()).starts_with(&fixture.root));
    assert!(PathBuf::from(record["socket_path"].as_str().unwrap()).starts_with(&fixture.root));
    fixture.workspace.attach(&fixture.selection()).unwrap();
    fixture.shell_probe("reattached");

    fixture
        .workspace
        .request_herdr_lifecycle(&fixture.selection(), HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.cancel_herdr_lifecycle();
    assert!(fixture.workspace.confirm_herdr_lifecycle().is_err());
    fixture.shell_probe("cancelled");

    fixture.lifecycle(HerdrLifecycleAction::Stop);
    fixture.wait_session(HerdrSessionState::Stopped);
    assert!(fixture.workspace.attach(&fixture.selection()).is_err());
    fixture
        .workspace
        .restart_herdr_session(&fixture.selection())
        .unwrap();
    fixture.wait_session(HerdrSessionState::Running);
    fixture.shell_probe("restarted");
    fixture.workspace.close();
    assert!(
        fixture.session_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|session| session["name"] == "review" && session["running"] == true)
    );
    let fixture = Fixture::new(fixture.root.clone());
    fixture.workspace.attach(&fixture.selection()).unwrap();
    fixture.shell_probe("reopened");

    fixture
        .workspace
        .request_herdr_lifecycle(&fixture.selection(), HerdrLifecycleAction::Stop)
        .unwrap();
    let stopped = Command::new(fixture.root.join("bin/herdr"))
        .args(["session", "stop", "review", "--json"])
        .output()
        .unwrap();
    assert!(stopped.status.success());
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait(|| fixture.workspace.drain_events().0.iter().any(|event| matches!(event, WorkspaceEvent::Error(message) if message.contains("no longer running"))));
    fixture.wait_session(HerdrSessionState::Stopped);
    fixture.lifecycle(HerdrLifecycleAction::Delete);
    fixture.wait(|| {
        !fixture.workspace.snapshot().hosts()[0]
            .herdr_sessions()
            .iter()
            .any(|session| session.name() == "review")
    });
    assert!(
        !fixture.session_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|session| session["name"] == "review")
    );

    // The optional backend disappears silently; ordinary tmux remains usable.
    fs::write(
        fixture.root.join("home/.profile"),
        "export PATH=/nonexistent\n",
    )
    .unwrap();
    fixture.workspace.refresh().unwrap();
    fixture.wait(|| !fixture.workspace.snapshot().hosts()[0].herdr_available());
    let snapshot = fixture.workspace.snapshot();
    assert!(snapshot.hosts()[0].herdr_diagnostic().is_none());
    assert_eq!(snapshot.hosts()[0].connection(), HostConnectionState::Ready);
    fixture
        .workspace
        .create_session("local", "Linux", "tmux-after-herdr")
        .unwrap();
    fixture.wait(|| matches!(fixture.workspace.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "tmux-after-herdr"));
}
