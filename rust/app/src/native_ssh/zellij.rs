use super::*;
use workspace::SessionKind;

impl Fixture {
    fn zellij_selection(&self, name: &str) -> SessionSelection {
        SessionSelection::zellij(&self.host_id, &self.endpoint, name)
    }

    fn seed_zellij(&self, name: &str) -> SessionSelection {
        let output = Command::new("/usr/bin/tmux")
            .env("TMUX_TMPDIR", self.root.join("tmux"))
            .args(["new-session", "-d", "-s", &format!("seed-{name}")])
            .arg(self.root.join("bin/zellij"))
            .arg(format!("--session={name}"))
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        // Inventory probes can unlink a socket before its server listens.
        // Seed through the terminal before connecting the workspace to this host.
        let target = format!("=seed-{name}:");
        self.wait(|_| {
            self.tmux(&["capture-pane", "-p", "-t", &target])
                .lines()
                .any(|line| line.trim() == "$")
        });
        self.tmux(&[
            "send-keys",
            "-t",
            &target,
            "-l",
            "printf 'seed-%s:%s\\n' \"$ZELLIJ_SESSION_NAME\" ready",
        ]);
        self.tmux(&["send-keys", "-t", &target, "Enter"]);
        self.wait(|_| {
            self.tmux(&["capture-pane", "-p", "-t", &target])
                .contains(&format!("seed-{name}:ready"))
        });
        // Release the client used for seeding before exercising app-owned clients.
        self.tmux(&["send-keys", "-t", &target, "C-o", "d"]);
        self.wait(|_| {
            !Command::new("/usr/bin/tmux")
                .env("TMUX_TMPDIR", self.root.join("tmux"))
                .args(["has-session", "-t", &format!("=seed-{name}")])
                .output()
                .unwrap()
                .status
                .success()
        });
        self.zellij_selection(name)
    }

    fn attach_zellij(&self, selection: &SessionSelection) {
        self.workspace.switch_session(selection).unwrap();
        self.zellij_shell(selection.session(), "attached");
    }

    fn zellij_shell(&self, name: &str, marker: &str) {
        self.wait(|snapshot| matches!(snapshot.content(), WorkspaceContent::Terminal { session, kind: SessionKind::Zellij, .. } if session == name));
        self.wait(|_| self.terminal_text().contains("$ "));
        for character in
            format!("printf 'zellij-%s:%s\\n' \"$ZELLIJ_SESSION_NAME\" '{marker}'").chars()
        {
            self.workspace
                .send_key(KeyInput::text(character.to_string(), Modifiers::default()))
                .unwrap();
        }
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .unwrap();
        self.wait(|_| {
            self.terminal_text()
                .contains(&format!("zellij-{name}:{marker}"))
        });
    }

    fn request_zellij_kill(&self, selection: &SessionSelection) {
        self.workspace.request_session_kill(selection).unwrap();
        self.wait(|_| self.workspace.session_kill_confirmation().is_some());
    }

    fn zellij_list(&self) -> String {
        let output = Command::new(self.root.join("bin/zellij"))
            .args(["list-sessions", "--no-formatting"])
            .output()
            .unwrap();
        String::from_utf8(output.stdout).unwrap()
    }

    fn gate_zellij_kill(&self, second_probe: bool, reject: bool) {
        use std::os::unix::fs::PermissionsExt;
        let binary = self.root.join("bin/zellij");
        std::fs::rename(&binary, self.root.join("bin/zellij-real")).unwrap();
        std::fs::write(
            &binary,
            format!(
                r#"#!/bin/sh
if [ -n "${{SSH_CONNECTION:-}}" ] && [ "$1" = list-sessions ]; then
  if [ '{second_probe}' = true ] && mkdir '{root}/first-probe' 2>/dev/null; then
    :
  elif mkdir '{root}/probe-started' 2>/dev/null; then
    while [ ! -f '{root}/release-probe' ]; do sleep .02; done
  fi
fi
if [ "$1" = kill-session ]; then
  touch '{root}/kill-started'
  while [ ! -f '{root}/release-kill' ]; do sleep .02; done
  if [ '{reject}' = true ]; then echo 'fixture kill rejected' >&2; exit 1; fi
fi
exec '{root}/bin/zellij-real' "$@"
"#,
                root = self.root.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(binary, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
}

#[test]
#[ignore = "requires Linux KWT, Zellij, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn confirmed_kill_preserves_other_sessions_and_clears_every_matching_window() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::zellij::confirmed_kill_preserves_other_sessions_and_clears_every_matching_window",
    ) else {
        return;
    };
    let keep = fixture.seed_zellij("keep");
    let selection = fixture.seed_zellij("review 'one'");
    fixture.connect();
    fixture.attach_zellij(&keep);
    fixture.workspace.detach();
    fixture.attach_zellij(&selection);
    fixture.request_zellij_kill(&selection);
    fixture.workspace.cancel_session_kill();
    assert!(fixture.workspace.confirm_session_kill().is_err());
    fixture.zellij_shell(selection.session(), "cancelled");

    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.zellij_shell(selection.session(), "second-window");
    other.request_zellij_kill(&selection);
    fixture.request_zellij_kill(&selection);
    fixture.workspace.confirm_session_kill().unwrap();
    for scene in [&fixture, &other] {
        scene.wait(|snapshot| {
            !snapshot
                .hosts()
                .iter()
                .find(|host| host.id() == fixture.host_id)
                .unwrap()
                .zellij_sessions()
                .iter()
                .any(|record| record.name() == selection.session())
                && !matches!(snapshot.content(), WorkspaceContent::Terminal { .. })
                && scene.workspace.session_kill_confirmation().is_none()
        });
    }
    assert!(other.workspace.confirm_session_kill().is_err());
    assert!(
        !fixture
            .zellij_list()
            .lines()
            .any(|line| line.starts_with("review 'one' ") && !line.contains("EXITED"))
    );
    fixture.workspace.switch_session(&keep).unwrap();
    fixture.zellij_shell("keep", "survived");
    fixture.tmux(&["has-session", "-t", "=review"]);
    fixture.workspace.close();
    other.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Zellij, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn a_confirmed_kill_fences_competing_kills_and_queued_attachments() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::zellij::a_confirmed_kill_fences_competing_kills_and_queued_attachments",
    ) else {
        return;
    };
    let selection = fixture.seed_zellij("guarded");
    fixture.connect();
    fixture.attach_zellij(&selection);
    let other = fixture.open_scene();
    other.request_zellij_kill(&selection);
    fixture.request_zellij_kill(&selection);
    fixture.gate_zellij_kill(false, false);
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait(|_| fixture.root.join("probe-started").exists());
    assert!(
        other
            .workspace
            .confirm_session_kill()
            .unwrap_err()
            .to_string()
            .contains("already in progress")
    );
    other.workspace.switch_session(&selection).unwrap();
    std::fs::write(fixture.root.join("release-probe"), "").unwrap();
    fixture.wait(|_| fixture.root.join("kill-started").exists());
    std::fs::write(fixture.root.join("release-kill"), "").unwrap();
    other.wait_for_error("killed after this request");
    fixture.wait(|snapshot| {
        !snapshot
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap()
            .zellij_sessions()
            .iter()
            .any(|session| session.name() == "guarded")
    });
    assert!(
        !fixture
            .zellij_list()
            .lines()
            .any(|line| line.starts_with("guarded ") && !line.contains("EXITED"))
    );
    fixture.workspace.close();
    other.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Zellij, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn rejected_kill_restores_unchanged_windows_and_preserves_new_navigation() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::zellij::rejected_kill_restores_unchanged_windows_and_preserves_new_navigation",
    ) else {
        return;
    };
    let keep = fixture.seed_zellij("keep");
    let selection = fixture.seed_zellij("guarded");
    fixture.connect();
    fixture.attach_zellij(&keep);
    fixture.workspace.detach();
    fixture.attach_zellij(&selection);
    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.zellij_shell("guarded", "before");
    fixture.request_zellij_kill(&selection);
    fixture.gate_zellij_kill(false, true);
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait(|_| fixture.root.join("probe-started").exists());
    other.workspace.switch_session(&keep).unwrap();
    std::fs::write(fixture.root.join("release-probe"), "").unwrap();
    fixture.wait(|_| fixture.root.join("kill-started").exists());
    std::fs::write(fixture.root.join("release-kill"), "").unwrap();
    fixture.wait_for_error("fixture kill rejected");
    fixture.zellij_shell("guarded", "restored");
    other.zellij_shell("keep", "new-navigation");
    fixture.workspace.close();
    other.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Zellij, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn reconnect_after_suppression_recovers_the_running_session() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::zellij::reconnect_after_suppression_recovers_the_running_session",
    ) else {
        return;
    };
    let selection = fixture.seed_zellij("guarded");
    fixture.connect();
    fixture.attach_zellij(&selection);
    fixture.request_zellij_kill(&selection);
    fixture.gate_zellij_kill(true, false);
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait(|_| fixture.root.join("probe-started").exists());
    assert!(!matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Terminal { .. }
    ));
    fixture.connect();
    std::fs::write(fixture.root.join("release-probe"), "").unwrap();
    fixture.wait_for_error("no longer current");
    assert!(!fixture.root.join("kill-started").exists());
    fixture.zellij_shell("guarded", "reconnected");
    fixture.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Zellij, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn stale_confirmation_preserves_clients_and_rejects_an_exited_target() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::zellij::stale_confirmation_preserves_clients_and_rejects_an_exited_target",
    ) else {
        return;
    };
    let selection = fixture.seed_zellij("guarded");
    fixture.connect();
    fixture.attach_zellij(&selection);
    fixture.request_zellij_kill(&selection);
    fixture.connect();
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait_for_error("SSH connection changed");
    fixture.zellij_shell("guarded", "preserved");
    fixture.workspace.detach();
    fixture.request_zellij_kill(&selection);
    let output = Command::new(fixture.root.join("bin/zellij"))
        .args(["kill-session", "--", "guarded"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait_for_error("Zellij session or executable changed");
    fixture.workspace.close();
}

#[test]
#[ignore = "requires Linux KWT, Zellij, OpenSSH, and Bubblewrap; run make rust-test-ssh-live"]
fn kill_accepts_names_that_zellij_cannot_attach_to() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::zellij::kill_accepts_names_that_zellij_cannot_attach_to")
    else {
        return;
    };
    for name in ["--review", "help"] {
        fixture.seed_zellij(name);
    }
    fixture.connect();
    for name in ["--review", "help"] {
        let selection = fixture.zellij_selection(name);
        let error = fixture.workspace.switch_session(&selection).unwrap_err();
        assert!(
            error.to_string().contains("Zellij cannot attach"),
            "{name}: {error}"
        );
        fixture.request_zellij_kill(&selection);
        fixture.workspace.confirm_session_kill().unwrap();
        fixture.wait(|snapshot| {
            !snapshot
                .hosts()
                .iter()
                .find(|host| host.id() == fixture.host_id)
                .unwrap()
                .zellij_sessions()
                .iter()
                .any(|record| record.name() == name)
        });
        assert!(
            !fixture
                .zellij_list()
                .lines()
                .any(|line| line.starts_with(&format!("{name} ")) && !line.contains("EXITED"))
        );
    }
    fixture.workspace.close();
}
