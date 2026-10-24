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
