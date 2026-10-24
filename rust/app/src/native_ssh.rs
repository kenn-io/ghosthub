use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use workspace::{
    HostConnectionState, KeyInput, Modifiers, NamedKey, SessionSelection, Workspace,
    WorkspaceContent, WorkspaceEvent, WorkspaceSnapshot,
};

struct Fixture {
    workspace: Workspace,
    root: PathBuf,
    host_id: String,
    endpoint: String,
    kwt: PathBuf,
    account_home: PathBuf,
    controller_home: PathBuf,
}

impl Fixture {
    fn isolated(test_name: &str) -> Option<Self> {
        if let Some(root) = std::env::var_os("GHOSTHUB_SSH_FIXTURE") {
            return Some(Self::new(root.into()));
        }
        let result = Command::new("/bin/sh")
            .arg(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../tools/run_rust_ssh_fixture.sh"
            ))
            .arg(std::env::current_exe().unwrap())
            .args(["--exact", test_name, "--ignored", "--nocapture"])
            .status()
            .unwrap();
        assert!(result.success());
        None
    }

    fn new(root: PathBuf) -> Self {
        let roots = config::ApplicationConfig::current_roots().unwrap();
        let settings = config::ApplicationConfig::load(&roots).unwrap();
        let kwt = super::activate_bundled_kwt_controller(Path::new(&roots.helpers))
            .unwrap()
            .unwrap();
        let controller_home = Path::new(&roots.state).join("ssh/kwt");
        let workspace = super::workspace_for(&settings, roots, &host::SystemWslPresence).unwrap();
        let snapshot = workspace.snapshot();
        let host = snapshot.hosts().iter().find(|host| host.is_ssh()).unwrap();
        assert_eq!(host.connection(), HostConnectionState::Disconnected);
        assert!(host.diagnostic().is_none());
        let host_id = host.id().to_owned();
        let endpoint = host.endpoint().to_owned();
        workspace.start_inventory_cadence().unwrap();
        Self {
            workspace,
            root,
            host_id,
            endpoint,
            kwt: kwt.as_os_str().into(),
            account_home: std::env::var_os("KWT_HOME").unwrap().into(),
            controller_home,
        }
    }

    fn kwt(&self, home: &Path, arguments: &[&str]) -> Vec<u8> {
        let output = Command::new(&self.kwt)
            .env("KWT_HOME", home)
            .args(arguments)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        output.stdout
    }

    fn daemon_status(&self, home: &Path) -> serde_json::Value {
        serde_json::from_slice(&self.kwt(home, &["daemon", "status", "--json"])).unwrap()
    }

    #[track_caller]
    fn wait(&self, mut condition: impl FnMut(&WorkspaceSnapshot) -> bool) -> usize {
        let deadline = Instant::now() + Duration::from_secs(30);
        let mut prompts = 0;
        loop {
            for event in self.workspace.drain_events().0 {
                match event {
                    WorkspaceEvent::Error(message) => panic!("{message}"),
                    WorkspaceEvent::SshPrompt(prompt) => {
                        assert!(
                            prompt.host_key().is_some(),
                            "expected fixture host-key prompt"
                        );
                        assert_eq!(prompt.host_id(), self.host_id);
                        assert!(
                            self.workspace
                                .ssh_prompt_is_current(prompt.host_id(), prompt.generation())
                        );
                        prompt.respond(Some("yes".to_owned()));
                        prompts += 1;
                    }
                    _ => {}
                }
            }
            let snapshot = self.workspace.snapshot();
            if condition(&snapshot) {
                return prompts;
            }
            let host = snapshot
                .hosts()
                .iter()
                .find(|host| host.id() == self.host_id)
                .unwrap();
            assert_ne!(
                host.connection(),
                HostConnectionState::Unavailable,
                "{host:?}"
            );
            assert!(
                Instant::now() < deadline,
                "SSH timed out: {host:?}; {}",
                self.terminal_text()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn connect(&self) -> usize {
        self.workspace.connect_host(&self.host_id).unwrap();
        self.wait(|snapshot| {
            snapshot.hosts().iter().any(|host| {
                host.id() == self.host_id && host.connection() == HostConnectionState::Ready
            })
        })
    }

    fn open_scene(&self) -> Self {
        Self {
            workspace: self.workspace.open_scene(),
            root: self.root.clone(),
            host_id: self.host_id.clone(),
            endpoint: self.endpoint.clone(),
            kwt: self.kwt.clone(),
            account_home: self.account_home.clone(),
            controller_home: self.controller_home.clone(),
        }
    }

    fn request_kill(&self, name: &str) {
        self.workspace.select_host(&self.host_id).unwrap();
        self.workspace
            .request_session_kill(&SessionSelection::new(&self.host_id, &self.endpoint, name))
            .unwrap();
        self.wait(|_| self.workspace.session_kill_confirmation().is_some());
    }

    #[track_caller]
    fn wait_for_error(&self, expected: &str) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let mut found = false;
            for event in self.workspace.drain_events().0 {
                if let WorkspaceEvent::Error(message) = event {
                    assert!(message.contains(expected), "{message}");
                    found = true;
                }
            }
            if found {
                return;
            }
            assert!(Instant::now() < deadline, "missing error: {expected}");
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn tmux(&self, arguments: &[&str]) -> String {
        let output = Command::new("/usr/bin/tmux")
            .env("TMUX_TMPDIR", self.root.join("tmux"))
            .args(arguments)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        String::from_utf8(output.stdout).unwrap().trim().to_owned()
    }

    fn terminal_text(&self) -> String {
        let snapshot = self.workspace.snapshot();
        let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
            return String::new();
        };
        let mut text = String::new();
        for cell in surface.load().cells() {
            text.push_str(cell.text());
        }
        text
    }

    fn attach(&self, name: &str, marker: &str) {
        self.workspace
            .switch_session(&SessionSelection::new(&self.host_id, &self.endpoint, name))
            .unwrap();
        self.wait(|snapshot| matches!(snapshot.content(), WorkspaceContent::Terminal { session, .. } if session == name));
        self.wait(|_| self.terminal_text().contains("$ "));
        self.workspace.send_key(KeyInput::text(
            format!("printf 'remote-%s:%s\\n' \"$(tmux display-message -p -t \"$TMUX_PANE\" '#S')\" {marker}"),
            Modifiers::default(),
        )).unwrap();
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .unwrap();
        self.wait(|_| {
            self.terminal_text()
                .contains(&format!("remote-{name}:{marker}"))
        });
    }
}

#[test]
#[ignore = "requires the bundled Linux KWT helper, OpenSSH server, and Bubblewrap; run make rust-test-ssh-live"]
fn native_ssh_kill_cancels_then_closes_only_matching_clients_across_scenes() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::native_ssh_kill_cancels_then_closes_only_matching_clients_across_scenes",
    ) else {
        return;
    };
    fixture.connect();
    let name = "notes 'one'";
    let worktree = SessionSelection::kwt_workspace(
        &fixture.host_id,
        &fixture.endpoint,
        name,
        host::KwtTmuxAttachMode::Protected,
        Some("kwt".to_owned()),
        "/work/demo",
        None,
    );
    assert!(fixture.workspace.request_session_kill(&worktree).is_err());
    fixture.attach(name, "before-kill");
    fixture.request_kill(name);
    fixture.workspace.cancel_session_kill();
    assert!(fixture.workspace.confirm_session_kill().is_err());
    fixture.attach(name, "after-cancel");

    let other = fixture.open_scene();
    other.attach(name, "second-window");
    other.attach("review", "unrelated-window");
    assert!(
        other
            .workspace
            .snapshot()
            .retained_selections()
            .iter()
            .any(|s| s.session() == name)
    );
    other.request_kill(name);
    fixture.request_kill(name);
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait(|snapshot| {
        !matches!(snapshot.content(), WorkspaceContent::Terminal { session, .. } if session == name)
            && !fixture
                .tmux(&["list-sessions", "-F", "#{session_name}"])
                .lines()
                .any(|s| s == name)
    });
    other.wait(|snapshot| {
        !snapshot
            .retained_selections()
            .iter()
            .any(|s| s.session() == name)
            && other.workspace.session_kill_confirmation().is_none()
            && snapshot
                .hosts()
                .iter()
                .find(|h| h.id() == fixture.host_id)
                .unwrap()
                .sessions()
                .iter()
                .all(|s| s.name() != name)
    });
    assert!(
        matches!(other.workspace.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "review")
    );
    other.attach("review", "survived-kill");
    assert_eq!(
        fixture.tmux(&["list-sessions", "-F", "#{session_name}"]),
        "review"
    );
}

#[test]
#[ignore = "requires the bundled Linux KWT helper, OpenSSH server, and Bubblewrap; run make rust-test-ssh-live"]
fn native_ssh_kill_rejects_replacements_and_changed_connections() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::native_ssh_kill_rejects_replacements_and_changed_connections",
    ) else {
        return;
    };
    fixture.connect();
    fixture.request_kill("review");
    let old = fixture.tmux(&["display-message", "-p", "-t", "=review:", "#{session_id}"]);
    fixture.tmux(&["kill-session", "-t", "=review"]);
    fixture.tmux(&["new-session", "-d", "-s", "review", "/bin/sh"]);
    let replacement = fixture.tmux(&["display-message", "-p", "-t", "=review:", "#{session_id}"]);
    assert_ne!(old, replacement);
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait_for_error("tmux");
    assert_eq!(
        fixture.tmux(&["display-message", "-p", "-t", "=review:", "#{session_id}"]),
        replacement
    );

    fixture.connect();
    fixture.attach("review", "before-reconnect");
    fixture.request_kill("review");
    fixture.connect();
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait_for_error("SSH connection changed");
    assert!(
        matches!(fixture.workspace.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "review")
    );
    fixture.attach("review", "after-rejected-kill");
    assert_eq!(
        fixture.tmux(&["display-message", "-p", "-t", "=review:", "#{session_id}"]),
        replacement
    );
}

#[test]
#[ignore = "requires the bundled Linux KWT helper, OpenSSH server, and Bubblewrap; run make rust-test-ssh-live"]
fn native_ssh_kill_rejects_restarted_server_and_captures_fresh_identity() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::native_ssh_kill_rejects_restarted_server_and_captures_fresh_identity",
    ) else {
        return;
    };
    fixture.connect();
    fixture.request_kill("review");
    let old = fixture.tmux(&[
        "display-message",
        "-p",
        "-t",
        "=review:",
        "#{pid}|#{session_id}",
    ]);
    fixture.tmux(&["kill-server"]);
    fixture.tmux(&[
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        "review",
        "/bin/sh",
    ]);
    let replacement = fixture.tmux(&[
        "display-message",
        "-p",
        "-t",
        "=review:",
        "#{pid}|#{session_id}",
    ]);
    assert_ne!(old, replacement);
    assert_eq!(
        old.split('|').nth(1),
        replacement.split('|').nth(1),
        "session ID is reused on the new server"
    );
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait_for_error("no longer matches");
    assert_eq!(
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            "=review:",
            "#{pid}|#{session_id}"
        ]),
        replacement
    );

    // The UI inventory still describes the original server. Confirmation must
    // query the live session, not copy that cached identity.
    fixture.tmux(&["new-session", "-d", "-s", "survivor", "/bin/sh"]);
    fixture.request_kill("review");
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait(|snapshot| {
        snapshot
            .hosts()
            .iter()
            .find(|h| h.id() == fixture.host_id)
            .unwrap()
            .sessions()
            .iter()
            .all(|s| s.name() != "review")
    });
    assert_eq!(
        fixture.tmux(&["list-sessions", "-F", "#{session_name}"]),
        "survivor"
    );
    fixture.request_kill("survivor");
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait(|snapshot| {
        snapshot
            .hosts()
            .iter()
            .find(|h| h.id() == fixture.host_id)
            .unwrap()
            .sessions()
            .is_empty()
    });
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.workspace.close();
    }
}

#[test]
#[ignore = "requires the bundled Linux KWT helper, OpenSSH server, and Bubblewrap; run make rust-test-ssh-live"]
#[allow(
    clippy::too_many_lines,
    reason = "one real SSH and account-daemon lifecycle"
)]
fn native_ssh_connects_attaches_and_preserves_sessions() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::native_ssh_connects_attaches_and_preserves_sessions")
    else {
        return;
    };
    fixture.kwt(&fixture.account_home, &["daemon", "start"]);
    let account = fixture.daemon_status(&fixture.account_home);
    assert_eq!(account["state"], "ready");
    assert_eq!(account["active_leases"], 0);
    let project = fixture.root.join("atlas");
    std::fs::create_dir(&project).unwrap();
    for arguments in [
        vec!["init", "-b", "main"],
        vec!["config", "user.name", "Demo"],
        vec!["config", "user.email", "demo@example.invalid"],
        vec!["commit", "--allow-empty", "-m", "Initial"],
    ] {
        let output = Command::new("/usr/bin/git")
            .arg("-C")
            .arg(&project)
            .args(arguments)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
    }
    fixture.kwt(
        &fixture.account_home,
        &["projects", "add", project.to_str().unwrap(), "--json"],
    );
    fixture.workspace.connect_host("local").unwrap();
    fixture.wait(|snapshot| {
        snapshot.hosts().iter().any(|host| {
            host.id() == "local"
                && host
                    .projects()
                    .iter()
                    .any(|item| item.path() == project.to_str().unwrap())
        })
    });
    let identity = fixture.tmux(&[
        "display-message",
        "-p",
        "-t",
        "=review:",
        "#{pid}:#{session_id}:#{session_created}",
    ]);
    assert_eq!(
        fixture.connect(),
        1,
        "first connect must ask about the host key"
    );
    let account_after_connect = fixture.daemon_status(&fixture.account_home);
    assert_eq!(account_after_connect["pid"], account["pid"]);
    assert_eq!(
        account_after_connect["active_leases"], 0,
        "Ghosthub's SSH lease must not belong to the account daemon"
    );
    let controller = fixture.daemon_status(&fixture.controller_home);
    assert_eq!(controller["state"], "ready");
    assert_eq!(controller["active_leases"], 1);
    assert_ne!(controller["pid"], account["pid"]);
    let snapshot = fixture.workspace.snapshot();
    let host = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap();
    assert_eq!(host.sessions().len(), 2);
    fixture.attach("review", "ready");
    fixture.workspace.resize(91, 29).unwrap();
    fixture.wait(|_| {
        fixture.tmux(&["list-clients", "-F", "#{client_width}:#{client_height}"]) == "91:29"
    });
    fixture.attach("notes 'one'", "quoted");
    fixture.attach("review", "returned");
    fixture.workspace.detach();
    fixture.wait(|_| {
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            "=review:",
            "#{session_attached}",
        ]) == "0"
    });
    assert_eq!(
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            "=review:",
            "#{pid}:#{session_id}:#{session_created}"
        ]),
        identity
    );
    fixture.attach("review", "before-close");
    fixture.workspace.close();
    fixture.wait(|_| fixture.tmux(&["list-clients"]).is_empty());
    let account_after_close = fixture.daemon_status(&fixture.account_home);
    assert_eq!(account_after_close["state"], "ready");
    assert_eq!(account_after_close["pid"], account["pid"]);
    fixture.kwt(&fixture.account_home, &["daemon", "stop"]);
    assert_eq!(
        fixture.daemon_status(&fixture.account_home)["state"],
        "stopped"
    );

    let reopened = Fixture::new(fixture.root.clone());
    let draft = reopened.workspace.configured_ssh_hosts()[0].draft().clone();
    reopened
        .workspace
        .remove_ssh_host(&reopened.host_id)
        .unwrap();
    assert_eq!(
        reopened.workspace.save_ssh_host(None, &draft).unwrap(),
        reopened.host_id
    );
    assert_eq!(
        reopened.connect(),
        0,
        "accepted fixture key should be retained"
    );
    reopened.attach("review", "reopened");
    assert_eq!(
        reopened.daemon_status(&reopened.account_home)["state"],
        "stopped",
        "neither route resolution nor lease acquisition may restart the account daemon"
    );
    assert_eq!(
        reopened.tmux(&[
            "display-message",
            "-p",
            "-t",
            "=review:",
            "#{pid}:#{session_id}:#{session_created}"
        ]),
        identity
    );
}

#[test]
#[ignore = "requires the bundled Linux KWT helper, OpenSSH server, and Bubblewrap; run make rust-test-ssh-live"]
fn native_ssh_reports_authentication_failure_and_recovers() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::native_ssh_reports_authentication_failure_and_recovers")
    else {
        return;
    };
    let authorized_keys = fixture.root.join("authorized_keys");
    let original_keys = std::fs::read(&authorized_keys).unwrap();
    std::fs::write(&authorized_keys, "").unwrap();

    fixture.workspace.connect_host(&fixture.host_id).unwrap();
    assert_eq!(
        fixture.wait(|snapshot| {
            snapshot.hosts().iter().any(|host| {
                host.id() == fixture.host_id
                    && host.connection() == HostConnectionState::Unavailable
            })
        }),
        1
    );
    let snapshot = fixture.workspace.snapshot();
    let host = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap();
    let diagnostic = host.diagnostic().expect("failed SSH host has a diagnostic");
    assert_eq!(
        diagnostic.kind(),
        model::DiagnosticKind::Transport,
        "{diagnostic:?}"
    );
    assert!(
        diagnostic
            .message()
            .contains("Permission denied (publickey)"),
        "{diagnostic:?}"
    );
    assert!(
        diagnostic.message().contains("exit status 255"),
        "{diagnostic:?}"
    );
    assert!(matches!(snapshot.content(), WorkspaceContent::Shell));

    std::fs::write(&authorized_keys, original_keys).unwrap();
    assert_eq!(
        fixture.connect(),
        0,
        "accepted host key should remain trusted"
    );
    let recovered = fixture.workspace.snapshot();
    assert!(
        recovered
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap()
            .diagnostic()
            .is_none()
    );
    fixture.attach("review", "after-authentication-failure");
}

#[test]
#[ignore = "requires the bundled Linux KWT helper, OpenSSH server, and Bubblewrap; run make rust-test-ssh-live"]
fn native_ssh_first_tmux_session_preserves_login_locale() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::native_ssh_first_tmux_session_preserves_login_locale")
    else {
        return;
    };
    fixture.tmux(&["kill-server"]);
    std::fs::write(fixture.root.join("home/.profile"), "export LANG=C.UTF-8\n").unwrap();
    fixture.connect();
    assert!(fixture.workspace.snapshot().hosts().iter().any(|host| {
        host.id() == fixture.host_id && host.tmux_available() && host.sessions().is_empty()
    }));
    fixture
        .workspace
        .create_session(&fixture.host_id, &fixture.endpoint, "first")
        .unwrap();
    fixture.wait(|snapshot| matches!(snapshot.content(), WorkspaceContent::Terminal { session, .. } if session == "first"));
    fixture.wait(|_| fixture.terminal_text().contains("$ "));
    fixture
        .workspace
        .send_key(KeyInput::text(
            "printf 'locale-%s:%s:%s\\n' \"$LANG\" \"$(locale charmap)\" 'café'",
            Modifiers::default(),
        ))
        .unwrap();
    fixture
        .workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .unwrap();
    fixture.wait(|_| {
        fixture
            .terminal_text()
            .contains("locale-C.UTF-8:UTF-8:café")
    });
}

#[test]
#[ignore = "requires the bundled Linux KWT helper, OpenSSH server, and Bubblewrap; run make rust-test-ssh-live"]
fn native_ssh_creates_exact_tmux_session_and_preserves_it() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::native_ssh_creates_exact_tmux_session_and_preserves_it")
    else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-create");
    assert!(
        fixture
            .workspace
            .create_session(&fixture.host_id, &fixture.endpoint, "review")
            .is_err()
    );

    let name = "build 'two' $(false)";
    fixture
        .workspace
        .create_session(&fixture.host_id, &fixture.endpoint, name)
        .unwrap();
    fixture.wait(|snapshot| matches!(snapshot.content(), WorkspaceContent::Terminal { session, .. } if session == name));
    fixture.attach(name, "created");
    let target = format!("={name}:");
    let identity = fixture.tmux(&[
        "display-message",
        "-p",
        "-t",
        &target,
        "#{pid}|#{session_id}|#{session_created}",
    ]);
    assert_eq!(
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            &target,
            "#{session_attached}"
        ]),
        "1"
    );
    assert!(!std::fs::read_dir("/tmp").unwrap().any(|entry| {
        entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".ghosthub-create-")
    }));

    fixture.workspace.detach();
    fixture.wait(|_| {
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            &target,
            "#{session_attached}",
        ]) == "0"
    });
    fixture.workspace.close();
    fixture.wait(|_| fixture.tmux(&["list-clients"]).is_empty());
    assert_eq!(
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            &target,
            "#{pid}|#{session_id}|#{session_created}"
        ]),
        identity
    );

    let reopened = Fixture::new(fixture.root.clone());
    assert_eq!(reopened.connect(), 0);
    reopened.attach(name, "reopened");
    assert_eq!(
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            &target,
            "#{pid}|#{session_id}|#{session_created}"
        ]),
        identity
    );
}
