use super::*;
use workspace::{HerdrLifecycleAction, HerdrSessionState};

impl Fixture {
    fn create_herdr(&self, name: &str) -> SessionSelection {
        self.workspace.select_host(&self.host_id).unwrap();
        self.workspace
            .create_herdr_session(&self.host_id, &self.endpoint, name)
            .unwrap();
        self.wait_herdr(name, Some(HerdrSessionState::Running));
        self.herdr_shell("created");
        self.herdr_selection(name)
    }

    fn herdr_selection(&self, name: &str) -> SessionSelection {
        SessionSelection::herdr(&self.host_id, &self.endpoint, name)
    }

    fn herdr_list(&self) -> serde_json::Value {
        let output = Command::new(self.root.join("bin/herdr"))
            .args(["session", "list", "--json"])
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        serde_json::from_slice(&output.stdout).unwrap()
    }

    fn wait_herdr(&self, name: &str, state: Option<HerdrSessionState>) {
        self.wait(|snapshot| {
            let host = snapshot
                .hosts()
                .iter()
                .find(|host| host.id() == self.host_id)
                .unwrap();
            let record = host
                .herdr_sessions()
                .iter()
                .find(|session| session.name() == name);
            match state {
                Some(state) => record.is_some_and(|record| {
                    record.state() == state && record.lifecycle_action().is_none()
                }),
                None => record.is_none(),
            }
        });
    }

    fn herdr_shell(&self, marker: &str) {
        self.wait(|_| self.terminal_text().contains("$ "));
        self.workspace
            .send_key(KeyInput::text(
                format!("printf 'herdr-%s\\n' '{marker}'"),
                Modifiers::default(),
            ))
            .unwrap();
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .unwrap();
        self.wait(|_| self.terminal_text().contains(&format!("herdr-{marker}")));
    }
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn stale_remote_herdr_confirmations_preserve_sessions() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::herdr::stale_remote_herdr_confirmations_preserve_sessions")
    else {
        return;
    };
    fixture.connect();
    let selection = fixture.create_herdr("guarded");
    fixture.workspace.detach();
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    let output = Command::new(fixture.root.join("bin/herdr"))
        .args(["session", "stop", "guarded", "--json"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait_for_error("no longer running");
    fixture.wait_herdr("guarded", Some(HerdrSessionState::Stopped));

    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Delete)
        .unwrap();
    fixture.workspace.cancel_herdr_lifecycle();
    assert!(fixture.workspace.confirm_herdr_lifecycle().is_err());
    assert!(
        fixture.herdr_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["name"] == "guarded")
    );
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Delete)
        .unwrap();
    let other = fixture.open_scene();
    other.workspace.restart_herdr_session(&selection).unwrap();
    other.wait_herdr("guarded", Some(HerdrSessionState::Running));
    other.herdr_shell("replacement");
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait_for_error("no longer stopped");
    other.herdr_shell("delete-rejected");

    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.connect();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait_for_error("SSH connection changed");
    assert!(
        fixture.herdr_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["name"] == "guarded" && record["running"] == true)
    );
    let default = fixture.herdr_list()["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|record| record["default"] == true)
        .cloned()
        .unwrap();
    assert!(
        fixture
            .workspace
            .request_herdr_lifecycle(
                &fixture.herdr_selection(default["name"].as_str().unwrap()),
                HerdrLifecycleAction::Delete
            )
            .is_err()
    );
    other.workspace.close();
    fixture.workspace.close();
    assert!(
        fixture.herdr_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["name"] == "guarded" && record["running"] == true)
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_remote_herdr_stop_restores_only_unchanged_scenes() {
    use std::os::unix::fs::PermissionsExt as _;
    let Some(fixture) = Fixture::isolated(
        "native_ssh::herdr::failed_remote_herdr_stop_restores_only_unchanged_scenes",
    ) else {
        return;
    };
    fixture.connect();
    let selection = fixture.create_herdr("guarded");
    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.herdr_shell("before-failure");
    let binary = fixture.root.join("bin/herdr");
    std::fs::rename(&binary, fixture.root.join("bin/herdr-real")).unwrap();
    std::fs::write(&binary, format!("#!/bin/sh\nif [ \"$1 $2 $3\" = 'session stop guarded' ]; then\n  touch '{}/stop-started'\n  while [ ! -f '{}/release-stop' ]; do sleep 0.02; done\n  printf '%s\\n' '{{\"error\":{{\"message\":\"fixture stop rejected\"}}}}'\n  exit 1\nfi\nexec '{}/bin/herdr-real' \"$@\"\n", fixture.root.display(), fixture.root.display(), fixture.root.display())).unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait(|_| fixture.root.join("stop-started").exists());
    assert!(!matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Terminal { .. }
    ));
    assert!(
        other
            .workspace
            .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
            .is_err()
    );
    assert!(other.workspace.restart_herdr_session(&selection).is_err());
    assert!(other.workspace.switch_session(&selection).is_err());
    other
        .workspace
        .switch_session(&SessionSelection::new(
            &fixture.host_id,
            &fixture.endpoint,
            "review",
        ))
        .unwrap();
    std::fs::write(fixture.root.join("release-stop"), "").unwrap();
    fixture.wait_for_error("fixture stop rejected");
    fixture.wait_herdr("guarded", Some(HerdrSessionState::Running));
    fixture.herdr_shell("restored");
    other.tmux_shell("review", "navigation-preserved");
    assert!(
        fixture.herdr_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["name"] == "guarded" && record["running"] == true)
    );
    other.workspace.close();
    fixture.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn stop_restart_and_delete_remote_herdr_across_scenes() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::herdr::stop_restart_and_delete_remote_herdr_across_scenes")
    else {
        return;
    };
    fixture.connect();
    let name = "review";
    fixture.workspace.select_host(&fixture.host_id).unwrap();
    fixture
        .workspace
        .create_herdr_session(&fixture.host_id, &fixture.endpoint, name)
        .unwrap();
    fixture.wait_herdr(name, Some(HerdrSessionState::Running));
    fixture.herdr_shell("created");
    let selection = fixture.herdr_selection(name);
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.cancel_herdr_lifecycle();
    assert!(fixture.workspace.confirm_herdr_lifecycle().is_err());
    fixture.herdr_shell("cancelled");

    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.herdr_shell("second-scene");
    other
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait_herdr(name, Some(HerdrSessionState::Stopped));
    other.wait(|snapshot| {
        !matches!(snapshot.content(), WorkspaceContent::Terminal { .. })
            && other.workspace.herdr_lifecycle_confirmation().is_none()
    });
    assert!(!matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Terminal { .. }
    ));
    assert!(
        fixture.herdr_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["name"] == name && record["running"] == false)
    );

    fixture.workspace.restart_herdr_session(&selection).unwrap();
    fixture.wait_herdr(name, Some(HerdrSessionState::Running));
    fixture.herdr_shell("restarted");
    fixture.workspace.detach();
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait_herdr(name, Some(HerdrSessionState::Stopped));
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Delete)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait_herdr(name, None);
    assert!(
        !fixture.herdr_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["name"] == name)
    );
    fixture.attach("review", "tmux-survived-herdr-delete");
    other.workspace.close();
    fixture.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn successful_stop_preserves_navigation_queued_before_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::successful_stop_preserves_navigation_queued_before_suppression",
        false,
        false,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_stop_preserves_navigation_queued_before_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::failed_stop_preserves_navigation_queued_before_suppression",
        true,
        false,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn successful_stop_preserves_local_navigation_queued_before_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::successful_stop_preserves_local_navigation_queued_before_suppression",
        false,
        true,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_stop_preserves_local_navigation_queued_before_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::failed_stop_preserves_local_navigation_queued_before_suppression",
        true,
        true,
    );
}

fn stop_with_queued_navigation(test_name: &str, reject_stop: bool, local_destination: bool) {
    use std::os::unix::fs::PermissionsExt as _;
    let Some(fixture) = Fixture::isolated(test_name) else {
        return;
    };
    let destination = if local_destination {
        let output = Command::new("/usr/bin/tmux")
            .env("TMUX_TMPDIR", fixture.root.join("local-tmux"))
            .args([
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "local-review",
                "/bin/sh",
            ])
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        fixture.workspace.refresh().unwrap();
        fixture.wait(|snapshot| {
            snapshot.hosts().iter().any(|host| {
                !host.is_ssh()
                    && host
                        .sessions()
                        .iter()
                        .any(|session| session.name() == "local-review")
            })
        });
        let snapshot = fixture.workspace.snapshot();
        let host = snapshot.hosts().iter().find(|host| !host.is_ssh()).unwrap();
        SessionSelection::new(host.id(), host.endpoint(), "local-review")
    } else {
        SessionSelection::new(&fixture.host_id, &fixture.endpoint, "review")
    };
    fixture.connect();
    let selection = fixture.create_herdr("guarded");
    // Reselecting the current client still permits recovery after a rejected Stop.
    fixture.workspace.switch_session(&selection).unwrap();
    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.herdr_shell("before-probe");

    let binary = fixture.root.join("bin/herdr");
    std::fs::rename(&binary, fixture.root.join("bin/herdr-real")).unwrap();
    // Hold the first inventory read while Stop owns the operation lane.
    std::fs::write(
        &binary,
        format!(
            r#"#!/bin/sh
if [ -n "${{SSH_CONNECTION:-}}" ] && [ "$1 $2" = 'session list' ] && mkdir '{root}/probe-started' 2>/dev/null; then
  while [ ! -f '{root}/release-probe' ]; do sleep 0.02; done
fi
if [ "$1 $2 $3" = 'session stop guarded' ] && [ '{reject_stop}' = true ]; then
  printf '%s\n' '{{"error":{{"message":"fixture stop rejected"}}}}'
  exit 1
fi
exec '{root}/bin/herdr-real' "$@"
"#,
            root = fixture.root.display(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait(|_| fixture.root.join("probe-started").exists());
    other.workspace.switch_session(&destination).unwrap();
    // The old client is still presented while the tmux request waits behind Stop.
    assert!(matches!(
        other.workspace.snapshot().content(),
        WorkspaceContent::Terminal {
            kind: workspace::SessionKind::Herdr,
            ..
        }
    ));
    std::fs::write(fixture.root.join("release-probe"), "").unwrap();
    if reject_stop {
        fixture.wait_for_error("fixture stop rejected");
        fixture.wait_herdr("guarded", Some(HerdrSessionState::Running));
        fixture.herdr_shell("original-scene-restored");
    } else {
        fixture.wait_herdr("guarded", Some(HerdrSessionState::Stopped));
    }
    // Probe the queued destination without selecting it again.
    other.tmux_shell(destination.session(), "queued-before-suppression");
    other.workspace.close();
    fixture.workspace.close();
}
