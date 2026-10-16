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
    HostConnectionState, KeyInput, LocalHostSpec, Modifiers, NamedKey, SessionSelection, Workspace,
    WorkspaceContent, WorkspaceEvent,
};

struct Fixture {
    workspace: Workspace,
    root: PathBuf,
}

impl Fixture {
    fn new(test_name: &str) -> Option<Self> {
        let root = if let Some(root) = std::env::var_os("GHOSTHUB_NATIVE_FIXTURE") {
            PathBuf::from(root)
        } else {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root =
                std::env::temp_dir().join(format!("gh-native-{}-{nonce:x}", std::process::id()));
            fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            for dir in ["home", "config", "state", "runtime"] {
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(root.join(dir))
                    .unwrap();
            }
            fs::write(root.join("gitconfig"), "").unwrap();
            // Optional backend discovery must see fixture configuration even when
            // Herdr is installed on the developer's machine.
            let result = Command::new(std::env::current_exe().unwrap())
                .args(["--exact", test_name, "--nocapture"])
                .env_clear()
                .env("GHOSTHUB_NATIVE_FIXTURE", &root)
                .env("HOME", root.join("home"))
                .env("XDG_CONFIG_HOME", root.join("config"))
                .env("XDG_STATE_HOME", root.join("state"))
                .env("XDG_RUNTIME_DIR", root.join("runtime"))
                .env("GIT_CONFIG_GLOBAL", root.join("gitconfig"))
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("PATH", "/usr/bin:/bin")
                .env("SHELL", "/bin/sh")
                .env("LANG", "C.UTF-8")
                .status()
                .unwrap();
            fs::remove_dir_all(root).unwrap();
            assert!(result.success());
            return None;
        };
        let config =
            LocalConfig::native("/usr/bin/tmux", Some(root.display().to_string())).unwrap();
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(LocalHostSpec::native(config)),
        );
        let fixture = Self { workspace, root };
        fixture.run(&["new-session", "-d", "-s", "keep", "/bin/sh"]);
        fixture.run(&["set-option", "-g", "default-shell", "/bin/sh"]);
        fixture.run(&["set-option", "-g", "default-command", "/bin/sh"]);
        let socket = fixture.text(&["display-message", "-p", "#{socket_path}"]);
        assert!(PathBuf::from(socket).starts_with(&fixture.root));
        fixture.run(&["new-session", "-d", "-s", "work", "/bin/sh"]);
        fixture
            .workspace
            .start_inventory_cadence()
            .expect("event pump");
        fixture
            .workspace
            .connect_host("local")
            .expect("connect native host");
        fixture.wait(|| {
            fixture.workspace.snapshot().hosts()[0].connection() == HostConnectionState::Ready
        });
        Some(fixture)
    }

    fn command(&self, args: &[&str]) -> Output {
        Command::new("/usr/bin/tmux")
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .env_remove("ENV")
            .env_remove("BASH_ENV")
            .env("TMUX_TMPDIR", &self.root)
            .args(["-f", "/dev/null"])
            .args(args)
            .output()
            .expect("isolated tmux")
    }

    fn run(&self, args: &[&str]) -> Output {
        let output = self.command(args);
        assert!(
            output.status.success(),
            "tmux {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        output
    }

    fn text(&self, args: &[&str]) -> String {
        String::from_utf8(self.run(args).stdout)
            .unwrap()
            .trim()
            .to_owned()
    }

    fn identity(&self, name: &str) -> String {
        self.text(&[
            "display-message",
            "-p",
            "-t",
            &format!("={name}:"),
            "#{pid}:#{session_id}:#{session_created}",
        ])
    }

    fn selection(&self, name: &str) -> SessionSelection {
        let snapshot = self.workspace.snapshot();
        let host = &snapshot.hosts()[0];
        SessionSelection::new(host.id(), host.endpoint(), name)
    }

    #[track_caller]
    fn wait(&self, mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !condition() {
            let snapshot = self.workspace.snapshot();
            assert!(
                Instant::now() < deadline,
                "native workspace timed out: {:?}",
                snapshot.hosts()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_terminal(&self, name: &str) {
        self.wait(|| matches!(self.workspace.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == name));
    }

    fn shell_probe(&self) {
        self.workspace
            .send_key(KeyInput::text(
                "printf 'native-%s\\n' ready",
                Modifiers::default(),
            ))
            .expect("type command");
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .expect("execute command");
        self.wait(|| {
            let snapshot = self.workspace.snapshot();
            let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
                return false;
            };
            surface
                .load()
                .cells()
                .map(surface::Cell::text)
                .collect::<String>()
                .contains("native-ready")
        });
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.workspace.close();
        let _ = self.command(&["kill-server"]);
    }
}

#[test]
fn native_sessions_attach_resize_create_and_survive_detach_and_close() {
    let Some(fixture) =
        Fixture::new("native_sessions_attach_resize_create_and_survive_detach_and_close")
    else {
        return;
    };
    let identity = fixture.identity("work");
    let selection = fixture.selection("work");
    fixture
        .workspace
        .attach(&selection)
        .expect("attach discovered native session");
    fixture.wait_terminal("work");
    fixture.shell_probe();
    fixture
        .workspace
        .resize(91, 29)
        .expect("resize native terminal");
    fixture.wait(|| {
        fixture.text(&["list-clients", "-F", "#{client_width}:#{client_height}"]) == "91:29"
    });

    fixture.workspace.detach();
    fixture.wait(|| {
        fixture.text(&[
            "display-message",
            "-p",
            "-t",
            "=work:",
            "#{session_attached}",
        ]) == "0"
    });
    assert_eq!(fixture.identity("work"), identity);

    fixture
        .workspace
        .create_session("local", selection.endpoint(), "created here")
        .expect("create native session");
    fixture.wait_terminal("created here");
    fixture.shell_probe();
    let created_identity = fixture.identity("created here");
    fixture.workspace.close();
    fixture.wait(|| {
        fixture.text(&[
            "display-message",
            "-p",
            "-t",
            "=created here:",
            "#{session_attached}",
        ]) == "0"
    });
    assert_eq!(fixture.identity("created here"), created_identity);
    assert_eq!(fixture.identity("work"), identity);
}

#[test]
fn native_kill_confirmation_preserves_cancelled_and_replaced_sessions() {
    let Some(fixture) =
        Fixture::new("native_kill_confirmation_preserves_cancelled_and_replaced_sessions")
    else {
        return;
    };
    let selection = fixture.selection("work");
    let original = fixture.identity("work");
    fixture
        .workspace
        .request_session_kill(&selection)
        .expect("request kill");
    fixture.wait(|| fixture.workspace.session_kill_confirmation().is_some());
    fixture.workspace.cancel_session_kill();
    assert_eq!(fixture.identity("work"), original);

    fixture
        .workspace
        .request_session_kill(&selection)
        .expect("request kill again");
    fixture.wait(|| fixture.workspace.session_kill_confirmation().is_some());
    fixture.run(&["kill-session", "-t", "=work"]);
    fixture.run(&["new-session", "-d", "-s", "work", "/bin/sh"]);
    let replacement = fixture.identity("work");
    assert_ne!(replacement, original);
    fixture
        .workspace
        .confirm_session_kill()
        .expect("confirm stale identity");
    fixture.wait(|| fixture.workspace.drain_events().0.iter().any(|event| matches!(event, WorkspaceEvent::Error(message) if message.contains("replaced after confirmation"))));
    assert_eq!(fixture.identity("work"), replacement);

    fixture
        .workspace
        .request_session_kill(&selection)
        .expect("request replacement kill");
    fixture.wait(|| fixture.workspace.session_kill_confirmation().is_some());
    fixture
        .workspace
        .confirm_session_kill()
        .expect("confirm replacement identity");
    fixture.wait(|| {
        !fixture
            .command(&["has-session", "-t", "=work"])
            .status
            .success()
    });
    assert!(
        fixture
            .command(&["has-session", "-t", "=keep"])
            .status
            .success()
    );
}
