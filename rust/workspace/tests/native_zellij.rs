#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use config::TerminalAppearance;
use host::LocalConfig;
use workspace::{
    HostConnectionState, KeyInput, LocalHostSpec, Modifiers, NamedKey, SessionKind,
    SessionSelection, Workspace, WorkspaceContent, WorkspaceEvent,
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

    fn selection(&self, name: &str) -> SessionSelection {
        let snapshot = self.workspace.snapshot();
        let host = &snapshot.hosts()[0];
        SessionSelection::zellij(host.id(), host.endpoint(), name)
    }

    #[track_caller]
    fn wait(&self, mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            for event in self.workspace.drain_events().0 {
                if let WorkspaceEvent::Error(message) = event {
                    panic!("{message}");
                }
            }
            if condition() {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "Zellij timed out: {:?}; terminal: {}",
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

    #[track_caller]
    fn shell_probe(&self, name: &str, marker: &str) {
        self.wait(|| matches!(self.workspace.snapshot().content(), WorkspaceContent::Terminal { session, kind: SessionKind::Zellij, .. } if session == name));
        self.wait(|| self.terminal_text().contains('$'));
        self.send_command(&format!(
            "printf 'zellij-%s:%s\\n' \"$ZELLIJ_SESSION_NAME\" {marker}"
        ));
        self.wait(|| {
            self.terminal_text()
                .contains(&format!("zellij-{name}:{marker}"))
        });
    }

    fn send_command(&self, command: &str) {
        for character in command.chars() {
            self.workspace
                .send_key(KeyInput::text(character.to_string(), Modifiers::default()))
                .unwrap();
        }
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .unwrap();
    }

    fn session_list(&self) -> String {
        let output = Command::new(self.root.join("bin/zellij"))
            .args(["list-sessions", "--no-formatting"])
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        String::from_utf8(output.stdout).unwrap()
    }

    fn tmux(&self, args: &[&str]) -> Output {
        Command::new("/usr/bin/tmux")
            .env("TMUX_TMPDIR", self.root.join("tmux"))
            .args(["-f", "/dev/null"])
            .args(args)
            .output()
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.workspace.close();
    }
}

fn isolated_fixture() -> Option<Fixture> {
    let Some(root) = std::env::var_os("GHOSTHUB_ZELLIJ_FIXTURE") else {
        let helper = std::env::var_os("GHOSTHUB_ZELLIJ_TEST").expect("staged Linux Zellij binary");
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("gh-z-{}-{nonce:x}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        for dir in [
            "home",
            "bin",
            "config",
            "config/zellij",
            "config/zellij/layouts",
            "cache",
            "data",
            "state",
            "runtime",
            "tmux",
        ] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join(dir))
                .unwrap();
        }
        fs::copy(helper, root.join("bin/zellij")).unwrap();
        fs::copy(
            std::env::current_exe().unwrap(),
            root.join("bin/native_zellij"),
        )
        .unwrap();
        fs::write(
            root.join("home/.profile"),
            "export PATH=\"$HOME/../bin:/usr/bin:/bin\"\n",
        )
        .unwrap();
        fs::write(root.join("gitconfig"), "").unwrap();
        fs::write(
            root.join("config/zellij/config.kdl"),
            "default_shell \"/bin/sh\"\ndefault_layout \"test\"\npane_frames false\nshow_release_notes false\nshow_startup_tips false\n",
        )
        .unwrap();
        fs::write(
            root.join("config/zellij/layouts/test.kdl"),
            "layout { pane; }\n",
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
            .arg(root.join("bin/native_zellij"))
            .args([
                "--exact",
                "native_zellij_lifecycle",
                "--ignored",
                "--nocapture",
            ])
            .current_dir(&root)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", root.join("home"))
            .env("XDG_CONFIG_HOME", root.join("config"))
            .env("ZELLIJ_CONFIG_DIR", root.join("config/zellij"))
            .env("XDG_CACHE_HOME", root.join("cache"))
            .env("XDG_DATA_HOME", root.join("data"))
            .env("XDG_STATE_HOME", root.join("state"))
            .env("XDG_RUNTIME_DIR", root.join("runtime"))
            .env("GHOSTHUB_ZELLIJ_FIXTURE", &root)
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
#[ignore = "requires Linux Zellij and Bubblewrap; run make rust-test-zellij-live"]
#[allow(
    clippy::too_many_lines,
    reason = "one live session lifecycle shares the isolated server across scenes"
)]
fn native_zellij_lifecycle() {
    let Some(fixture) = isolated_fixture() else {
        return;
    };
    assert!(fixture.workspace.snapshot().hosts()[0].zellij_available());
    assert!(
        fixture
            .tmux(&["new-session", "-d", "-s", "review", "/bin/sh"])
            .status
            .success()
    );
    fixture
        .workspace
        .create_zellij_session("local", "Linux", "review")
        .unwrap();
    fixture.shell_probe("review", "created");
    fixture.workspace.resize(100, 32).unwrap();
    fixture.send_command("stty size");
    fixture.wait(|| fixture.terminal_text().contains("32 100"));

    fixture.workspace.detach();
    assert!(
        fixture
            .session_list()
            .lines()
            .any(|line| line.starts_with("review ") && !line.contains("EXITED"))
    );
    fixture
        .workspace
        .create_zellij_session("local", "Linux", "keep 'one'")
        .unwrap();
    fixture.shell_probe("keep 'one'", "keep");
    fixture.workspace.close();

    let fixture = Fixture::new(fixture.root.clone());
    let selection = fixture.selection("review");
    fixture.workspace.attach(&selection).unwrap();
    fixture.shell_probe("review", "reopened");
    fixture.workspace.request_session_kill(&selection).unwrap();
    assert!(fixture.workspace.session_kill_confirmation().is_some());
    fixture.workspace.cancel_session_kill();
    assert!(fixture.workspace.confirm_session_kill().is_err());
    fixture.shell_probe("review", "cancelled");

    let other = Fixture {
        workspace: fixture.workspace.open_scene(),
        root: fixture.root.clone(),
    };
    other.workspace.attach(&selection).unwrap();
    other.shell_probe("review", "second-client");
    // Save the real session so the kill leaves an exited inventory row.
    let saved = Command::new(fixture.root.join("bin/zellij"))
        .args(["--session", "review", "action", "save-session"])
        .output()
        .unwrap();
    assert!(saved.status.success(), "{saved:?}");
    fixture.wait(|| {
        fs::read_dir(fixture.root.join("cache/zellij"))
            .unwrap()
            .any(|entry| {
                entry
                    .unwrap()
                    .path()
                    .join("session_info/review/session-layout.kdl")
                    .is_file()
            })
    });
    fixture.workspace.request_session_kill(&selection).unwrap();
    other.workspace.request_session_kill(&selection).unwrap();
    assert!(fixture.workspace.session_kill_confirmation().is_some());
    assert!(other.workspace.session_kill_confirmation().is_some());
    fixture.workspace.confirm_session_kill().unwrap();
    for scene in [&fixture, &other] {
        scene.wait(|| {
            !scene.workspace.snapshot().hosts()[0]
                .zellij_sessions()
                .iter()
                .any(|session| session.name() == "review")
                && !matches!(
                    scene.workspace.snapshot().content(),
                    WorkspaceContent::Terminal { .. }
                )
                && scene.workspace.session_kill_confirmation().is_none()
        });
    }
    assert!(other.workspace.confirm_session_kill().is_err());
    assert!(
        fixture
            .tmux(&["has-session", "-t", "=review"])
            .status
            .success()
    );
    fixture.wait(|| {
        fixture
            .session_list()
            .lines()
            .any(|line| line.starts_with("review ") && line.contains("EXITED"))
    });
    fixture.workspace.close();
    other.workspace.close();
    let fixture = Fixture::new(fixture.root.clone());
    assert!(
        !fixture.workspace.snapshot().hosts()[0]
            .zellij_sessions()
            .iter()
            .any(|session| session.name() == "review")
    );
    assert!(fixture.workspace.attach(&selection).is_err());
    fixture
        .workspace
        .attach(&fixture.selection("keep 'one'"))
        .unwrap();
    fixture.shell_probe("keep 'one'", "survived");
    fixture.workspace.detach();

    // Zellij 0.45.1 servers panic when a list-sessions probe disconnects
    // before the first client initializes the session. Keep background
    // inventory from probing the external servers while they start.
    fixture.workspace.set_inventory_polling_enabled(false);
    for name in ["--review", "help", "options"] {
        assert!(
            fixture
                .workspace
                .create_zellij_session("local", "Linux", name)
                .is_err()
        );
        let executable = fixture.root.join("bin/zellij");
        // An external client can create names that the attach parser cannot address.
        let created = fixture.tmux(&[
            "new-session",
            "-d",
            "-s",
            "external-zellij",
            executable.to_str().unwrap(),
            &format!("--session={name}"),
        ]);
        assert!(created.status.success(), "{created:?}");
        // The shell prompt renders only after the session is initialized.
        fixture.wait(|| {
            let pane = fixture.tmux(&["capture-pane", "-p", "-t", "=external-zellij:"]);
            pane.status.success() && !String::from_utf8_lossy(&pane.stdout).trim().is_empty()
        });
        fixture.wait(|| {
            fixture
                .session_list()
                .lines()
                .any(|line| line.starts_with(&format!("{name} ")))
        });
        fixture.workspace.refresh().unwrap();
        fixture.wait(|| {
            fixture.workspace.snapshot().hosts()[0]
                .zellij_sessions()
                .iter()
                .any(|session| session.name() == name)
        });
        let error = fixture
            .workspace
            .attach(&fixture.selection(name))
            .unwrap_err();
        assert!(error.to_string().contains("Zellij cannot attach"));
        assert_eq!(
            fixture.workspace.snapshot().hosts()[0].connection(),
            HostConnectionState::Ready
        );
        fixture
            .workspace
            .request_session_kill(&fixture.selection(name))
            .unwrap();
        fixture.workspace.confirm_session_kill().unwrap();
        fixture.wait(|| {
            !fixture.workspace.snapshot().hosts()[0]
                .zellij_sessions()
                .iter()
                .any(|session| session.name() == name)
        });
        fixture.wait(|| {
            !fixture
                .tmux(&["has-session", "-t", "=external-zellij"])
                .status
                .success()
        });
    }
    fixture.workspace.set_inventory_polling_enabled(true);

    // Hide the optional executable through its login profile, leaving tmux usable.
    fs::write(
        fixture.root.join("home/.profile"),
        "export PATH=/nonexistent\n",
    )
    .unwrap();
    fixture.workspace.refresh().unwrap();
    fixture.wait(|| !fixture.workspace.snapshot().hosts()[0].zellij_available());
    assert!(
        fixture.workspace.snapshot().hosts()[0]
            .zellij_diagnostic()
            .is_none()
    );
    fixture
        .workspace
        .create_session("local", "Linux", "tmux-after-zellij")
        .unwrap();
    fixture.wait(|| matches!(fixture.workspace.snapshot().content(), WorkspaceContent::Terminal { session, kind: SessionKind::Tmux, .. } if session == "tmux-after-zellij"));
}
