use super::*;
use workspace::{HerdrLifecycleAction, HerdrSessionState};

impl Fixture {
    fn gate_herdr_second_probe(&self) {
        use std::os::unix::fs::PermissionsExt as _;
        let binary = self.root.join("bin/herdr");
        std::fs::rename(&binary, self.root.join("bin/herdr-real")).unwrap();
        std::fs::write(
            &binary,
            format!(
                r#"#!/bin/sh
if [ -n "${{SSH_CONNECTION:-}}" ] && [ "$1 $2" = 'session list' ]; then
  if mkdir '{root}/first-probe' 2>/dev/null; then
    :
  elif mkdir '{root}/probe-started' 2>/dev/null; then
    while [ ! -f '{root}/release-probe' ]; do sleep 0.02; done
  elif [ -f '{root}/hold-reconnect' ] && mkdir '{root}/reconnect-started' 2>/dev/null; then
    while [ ! -f '{root}/release-reconnect' ]; do sleep 0.02; done
  fi
fi
if [ "$1 $2 $3" = 'session stop guarded' ]; then touch '{root}/stop-started'; fi
exec '{root}/bin/herdr-real' "$@"
"#,
                root = self.root.display(),
            ),
        )
        .unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    fn gate_herdr_stop(&self, reject_stop: bool) {
        use std::os::unix::fs::PermissionsExt as _;
        let binary = self.root.join("bin/herdr");
        std::fs::rename(&binary, self.root.join("bin/herdr-real")).unwrap();
        // Hold the first inventory read while Stop owns the operation lane.
        std::fs::write(
            &binary,
            format!(
                r#"#!/bin/sh
if [ -n "${{SSH_CONNECTION:-}}" ] && [ "$1 $2" = 'session list' ] && mkdir '{root}/probe-started' 2>/dev/null; then
  while [ ! -f '{root}/release-probe' ]; do sleep 0.02; done
fi
if [ "$1 $2 $3" = 'session stop guarded' ]; then
  touch '{root}/stop-started'
  while [ ! -f '{root}/release-stop' ]; do sleep 0.02; done
fi
if [ "$1 $2 $3" = 'session stop guarded' ] && [ '{reject_stop}' = true ]; then
  printf '%s\n' '{{"error":{{"message":"fixture stop rejected"}}}}'
  exit 1
fi
exec '{root}/bin/herdr-real' "$@"
"#,
                root = self.root.display(),
            ),
        )
        .unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    fn local_session(&self, name: &str) -> SessionSelection {
        let output = Command::new("/usr/bin/tmux")
            .env("TMUX_TMPDIR", self.root.join("local-tmux"))
            .args([
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                name,
                "/bin/sh",
            ])
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        self.workspace.refresh().unwrap();
        self.wait(|snapshot| {
            snapshot.hosts().iter().any(|host| {
                !host.is_ssh() && host.sessions().iter().any(|session| session.name() == name)
            })
        });
        let snapshot = self.workspace.snapshot();
        let host = snapshot.hosts().iter().find(|host| !host.is_ssh()).unwrap();
        SessionSelection::new(host.id(), host.endpoint(), name)
    }

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
        QueuedNavigation::Remote,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_stop_preserves_navigation_queued_before_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::failed_stop_preserves_navigation_queued_before_suppression",
        true,
        QueuedNavigation::Remote,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn successful_stop_preserves_local_navigation_queued_before_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::successful_stop_preserves_local_navigation_queued_before_suppression",
        false,
        QueuedNavigation::Local,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_stop_preserves_local_navigation_queued_before_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::failed_stop_preserves_local_navigation_queued_before_suppression",
        true,
        QueuedNavigation::Local,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn successful_stop_allows_superseding_local_navigation_after_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::successful_stop_allows_superseding_local_navigation_after_suppression",
        false,
        QueuedNavigation::SupersededLocal,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_stop_allows_superseding_local_navigation_after_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::failed_stop_allows_superseding_local_navigation_after_suppression",
        true,
        QueuedNavigation::SupersededLocal,
    );
}

#[derive(Clone, Copy)]
enum QueuedNavigation {
    Remote,
    Local,
    SupersededLocal,
    ExitedLocal,
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_queued_local_attachment_settles_after_suppression() {
    stop_with_queued_navigation(
        "native_ssh::herdr::failed_queued_local_attachment_settles_after_suppression",
        false,
        QueuedNavigation::ExitedLocal,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn reconnect_during_stop_probe_preserves_existing_clients() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::herdr::reconnect_during_stop_probe_preserves_existing_clients",
    ) else {
        return;
    };
    fixture.connect();
    let selection = fixture.create_herdr("guarded");
    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.herdr_shell("before-reconnect");
    let presentation_id = |fixture: &Fixture| match fixture.workspace.snapshot().content() {
        WorkspaceContent::Terminal {
            presentation_id, ..
        } => *presentation_id,
        _ => panic!("expected a live Herdr presentation"),
    };
    let original = presentation_id(&fixture);
    let other_original = presentation_id(&other);
    fixture.gate_herdr_stop(false);
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait(|_| fixture.root.join("probe-started").exists());
    fixture.connect();
    assert_eq!(presentation_id(&fixture), original);
    assert_eq!(presentation_id(&other), other_original);
    std::fs::write(fixture.root.join("release-probe"), "").unwrap();
    fixture.wait_for_error("no longer current");
    assert!(!fixture.root.join("stop-started").exists());
    assert_eq!(presentation_id(&fixture), original);
    assert_eq!(presentation_id(&other), other_original);
    fixture.wait_herdr("guarded", Some(HerdrSessionState::Running));
    fixture.herdr_shell("original-client-preserved");
    other.herdr_shell("other-client-preserved");
    other.workspace.close();
    fixture.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn reconnect_during_second_stop_probe_recovers_unchanged_scenes() {
    stop_with_reconnect_after_suppression(
        "native_ssh::herdr::reconnect_during_second_stop_probe_recovers_unchanged_scenes",
        false,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn reconnect_finishing_after_rejected_stop_recovers_unchanged_scenes() {
    stop_with_reconnect_after_suppression(
        "native_ssh::herdr::reconnect_finishing_after_rejected_stop_recovers_unchanged_scenes",
        true,
    );
}

fn stop_with_reconnect_after_suppression(test_name: &str, delay_reconnect: bool) {
    let Some(fixture) = Fixture::isolated(test_name) else {
        return;
    };
    let destination = fixture.local_session("local-review");
    fixture.connect();
    let selection = fixture.create_herdr("guarded");
    let other = fixture.open_scene();
    let navigating = fixture.open_scene();
    for scene in [&other, &navigating] {
        scene.workspace.switch_session(&selection).unwrap();
        scene.herdr_shell("before-second-probe");
    }
    fixture.gate_herdr_second_probe();
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait(|_| fixture.root.join("probe-started").exists());
    for scene in [&fixture, &other, &navigating] {
        assert!(!matches!(
            scene.workspace.snapshot().content(),
            WorkspaceContent::Terminal { .. }
        ));
    }
    if delay_reconnect {
        std::fs::write(fixture.root.join("hold-reconnect"), "").unwrap();
        fixture.workspace.connect_host(&fixture.host_id).unwrap();
        fixture.wait(|_| fixture.root.join("reconnect-started").exists());
    } else {
        fixture.connect();
    }
    if !delay_reconnect {
        navigating.workspace.switch_session(&destination).unwrap();
    }
    std::fs::write(fixture.root.join("release-probe"), "").unwrap();
    fixture.wait_for_error("no longer current");
    assert!(!fixture.root.join("stop-started").exists());
    // This intent arrives after recovery was saved for the pending connection.
    if delay_reconnect {
        navigating.workspace.switch_session(&destination).unwrap();
    }
    std::fs::write(fixture.root.join("release-reconnect"), "").unwrap();
    fixture.wait_herdr("guarded", Some(HerdrSessionState::Running));
    fixture.herdr_shell("recovered-after-reconnect");
    other.herdr_shell("other-recovered-after-reconnect");
    navigating.tmux_shell("local-review", "after-reconnect");
    navigating.workspace.close();
    other.workspace.close();
    fixture.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn reconnect_during_second_stop_probe_does_not_restore_stopped_session() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::herdr::reconnect_during_second_stop_probe_does_not_restore_stopped_session",
    ) else {
        return;
    };
    fixture.connect();
    let selection = fixture.create_herdr("guarded");
    fixture.gate_herdr_second_probe();
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait(|_| fixture.root.join("probe-started").exists());
    let output = Command::new(fixture.root.join("bin/herdr-real"))
        .args(["session", "stop", "guarded", "--json"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    fixture.connect();
    std::fs::write(fixture.root.join("release-probe"), "").unwrap();
    fixture.wait_for_error("no longer running");
    assert!(!fixture.root.join("stop-started").exists());
    fixture.wait_herdr("guarded", Some(HerdrSessionState::Stopped));
    assert!(!matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Terminal { .. }
    ));
    let destination = SessionSelection::new(&fixture.host_id, &fixture.endpoint, "review");
    fixture.workspace.switch_session(&destination).unwrap();
    fixture.tmux_shell("review", "after-rejected-recovery");
    fixture.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn successful_stop_allows_superseding_queued_local_herdr_create() {
    stop_with_queued_local_herdr_launch(
        "native_ssh::herdr::successful_stop_allows_superseding_queued_local_herdr_create",
        false,
        false,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_stop_allows_superseding_queued_local_herdr_create() {
    stop_with_queued_local_herdr_launch(
        "native_ssh::herdr::failed_stop_allows_superseding_queued_local_herdr_create",
        true,
        false,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn successful_stop_allows_superseding_queued_local_herdr_restart() {
    stop_with_queued_local_herdr_launch(
        "native_ssh::herdr::successful_stop_allows_superseding_queued_local_herdr_restart",
        false,
        true,
    );
}

#[test]
#[ignore = "requires Linux KWT, Herdr, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn failed_stop_allows_superseding_queued_local_herdr_restart() {
    stop_with_queued_local_herdr_launch(
        "native_ssh::herdr::failed_stop_allows_superseding_queued_local_herdr_restart",
        true,
        true,
    );
}

fn stop_with_queued_local_herdr_launch(test_name: &str, reject_stop: bool, restart: bool) {
    let Some(fixture) = Fixture::isolated(test_name) else {
        return;
    };
    let destination = fixture.local_session("local-review");
    fixture.connect();
    let selection = fixture.create_herdr("guarded");
    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.herdr_shell("before-local-launch");
    let local = SessionSelection::herdr(
        destination.host_id(),
        destination.endpoint(),
        if restart { "default" } else { "local-draft" },
    );
    let launch = || {
        if restart {
            other.workspace.restart_herdr_session(&local)
        } else {
            other
                .workspace
                .create_herdr_session(local.host_id(), local.endpoint(), local.session())
        }
    };
    fixture.gate_herdr_stop(reject_stop);
    fixture
        .workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .unwrap();
    fixture.workspace.confirm_herdr_lifecycle().unwrap();
    fixture.wait(|_| fixture.root.join("probe-started").exists());
    launch().unwrap();
    std::fs::write(fixture.root.join("release-probe"), "").unwrap();
    fixture.wait(|_| fixture.root.join("stop-started").exists());
    other.workspace.switch_session(&destination).unwrap();
    std::fs::write(fixture.root.join("release-stop"), "").unwrap();
    if reject_stop {
        fixture.wait_for_error("fixture stop rejected");
        fixture.wait_herdr("guarded", Some(HerdrSessionState::Running));
    } else {
        fixture.wait_herdr("guarded", Some(HerdrSessionState::Stopped));
    }
    other.tmux_shell("local-review", "after-superseding-launch");
    // The superseded request must not create or restart its target.
    assert!(
        !fixture.herdr_list()["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["name"] == local.session() && record["running"] == true)
    );
    // Retry without detaching or closing the scene that owned the old request.
    launch().expect("superseding a queued launch must release its reservation");
    other.herdr_shell("local-launch-after-supersession");
    assert!(matches!(
        other.workspace.snapshot().content(),
        WorkspaceContent::Terminal { host_id, session, kind: workspace::SessionKind::Herdr, .. }
            if host_id == local.host_id() && session == local.session()
    ));
    other.workspace.close();
    fixture.workspace.close();
}

fn stop_with_queued_navigation(test_name: &str, reject_stop: bool, navigation: QueuedNavigation) {
    let Some(fixture) = Fixture::isolated(test_name) else {
        return;
    };
    let destination = match navigation {
        QueuedNavigation::Remote => {
            SessionSelection::new(&fixture.host_id, &fixture.endpoint, "review")
        }
        QueuedNavigation::Local
        | QueuedNavigation::SupersededLocal
        | QueuedNavigation::ExitedLocal => fixture.local_session("local-review"),
    };
    let replacement = matches!(
        navigation,
        QueuedNavigation::SupersededLocal | QueuedNavigation::ExitedLocal
    )
    .then(|| fixture.local_session("local-next"));
    fixture.connect();
    let selection = fixture.create_herdr("guarded");
    // Reselecting the current client still permits recovery after a rejected Stop.
    fixture.workspace.switch_session(&selection).unwrap();
    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.herdr_shell("before-probe");

    fixture.gate_herdr_stop(reject_stop);
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
    fixture.wait(|_| fixture.root.join("stop-started").exists());
    let destination = if let Some(replacement) = replacement
        .as_ref()
        .filter(|_| matches!(navigation, QueuedNavigation::SupersededLocal))
    {
        other.workspace.switch_session(replacement).unwrap();
        replacement.clone()
    } else {
        destination
    };
    if matches!(navigation, QueuedNavigation::ExitedLocal) {
        let output = Command::new("/usr/bin/tmux")
            .env("TMUX_TMPDIR", fixture.root.join("local-tmux"))
            .args(["kill-session", "-t", "=local-review"])
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
    }
    std::fs::write(fixture.root.join("release-stop"), "").unwrap();
    if reject_stop {
        fixture.wait_for_error("fixture stop rejected");
        fixture.wait_herdr("guarded", Some(HerdrSessionState::Running));
        fixture.herdr_shell("original-scene-restored");
    } else {
        fixture.wait_herdr("guarded", Some(HerdrSessionState::Stopped));
    }
    if matches!(navigation, QueuedNavigation::ExitedLocal) {
        other.wait_for_error("session no longer exists");
        assert!(!matches!(
            other.workspace.snapshot().content(),
            WorkspaceContent::Attaching { .. }
        ));
        let replacement = replacement.unwrap();
        other.workspace.switch_session(&replacement).unwrap();
        other.tmux_shell(replacement.session(), "after-failed-attachment");
    } else {
        // Probe the queued destination without selecting it again.
        other.tmux_shell(destination.session(), "queued-before-suppression");
    }
    other.workspace.close();
    fixture.workspace.close();
}
