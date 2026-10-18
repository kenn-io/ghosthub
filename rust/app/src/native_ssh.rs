use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use workspace::{
    HostConnectionState, KeyInput, Modifiers, NamedKey, SessionSelection, Workspace,
    WorkspaceContent, WorkspaceEvent,
};

struct Fixture {
    workspace: Workspace,
    root: PathBuf,
    host_id: String,
    endpoint: String,
}

impl Fixture {
    fn new(root: PathBuf) -> Self {
        let roots = config::ApplicationConfig::current_roots().unwrap();
        let settings = config::ApplicationConfig::load(&roots).unwrap();
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
        }
    }

    #[track_caller]
    fn wait(&self, mut condition: impl FnMut() -> bool) -> usize {
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
            if condition() {
                return prompts;
            }
            let snapshot = self.workspace.snapshot();
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
        self.wait(|| {
            self.workspace.snapshot().hosts().iter().any(|host| {
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
        self.wait(|| matches!(self.workspace.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == name));
        self.wait(|| self.terminal_text().contains("$ "));
        self.workspace.send_key(KeyInput::text(
            format!("printf 'remote-%s:%s\\n' \"$(tmux display-message -p -t \"$TMUX_PANE\" '#S')\" {marker}"),
            Modifiers::default(),
        )).unwrap();
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .unwrap();
        self.wait(|| {
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
fn native_ssh_connects_attaches_and_preserves_sessions() {
    let Some(root) = std::env::var_os("GHOSTHUB_SSH_FIXTURE") else {
        let result = Command::new("/bin/sh")
            .arg(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../tools/run_rust_ssh_fixture.sh"
            ))
            .arg(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "native_ssh::native_ssh_connects_attaches_and_preserves_sessions",
                "--ignored",
                "--nocapture",
            ])
            .status()
            .unwrap();
        assert!(result.success());
        return;
    };
    let fixture = Fixture::new(root.into());
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
    let snapshot = fixture.workspace.snapshot();
    let host = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap();
    assert_eq!(host.sessions().len(), 2);
    fixture.attach("review", "ready");
    fixture.workspace.resize(91, 29).unwrap();
    fixture.wait(|| {
        fixture.tmux(&["list-clients", "-F", "#{client_width}:#{client_height}"]) == "91:29"
    });
    fixture.attach("notes 'one'", "quoted");
    fixture.attach("review", "returned");
    fixture.workspace.detach();
    fixture.wait(|| {
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
    fixture.wait(|| fixture.tmux(&["list-clients"]).is_empty());

    let reopened = Fixture::new(fixture.root.clone());
    assert_eq!(
        reopened.connect(),
        0,
        "accepted fixture key should be retained"
    );
    reopened.attach("review", "reopened");
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
