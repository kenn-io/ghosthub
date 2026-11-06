use super::*;

impl Fixture {
    pub(super) fn interrupt_ssh(&self) {
        let listener = std::fs::read_to_string(self.root.join("sshd.pid")).unwrap();
        let listener = listener.trim();
        let mut connections = Vec::new();
        for entry in std::fs::read_dir("/proc").unwrap().flatten() {
            if let Ok(comm) = std::fs::read_to_string(entry.path().join("comm"))
                && matches!(comm.trim(), "sshd" | "sshd-session" | "sshd-auth")
                && entry.file_name() != listener
            {
                connections.push(entry);
            }
        }
        assert!(!connections.is_empty(), "expected a live SSH connection");
        // The privileged monitor can exit without closing its unprivileged child's sockets.
        // Kill both in this private PID namespace; tmux and the listener survive.
        for connection in connections {
            let status = Command::new("kill")
                .arg("-KILL")
                .arg(connection.file_name())
                .status()
                .unwrap();
            assert!(
                status.success() || !connection.path().exists(),
                "could not interrupt fixture SSH process"
            );
        }
        self.wait_for_error("status 255");
        assert!(matches!(
            self.workspace.snapshot().content(),
            WorkspaceContent::Shell
        ));
    }
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn reconnect_restores_the_original_tmux_session_after_rename() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::reconnect_restores_the_original_tmux_session_after_rename",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-loss");
    fixture.interrupt_ssh();
    fixture.tmux(&["rename-session", "-t", "=review", "renamed"]);
    fixture.tmux(&["new-session", "-d", "-s", "review", "/bin/sh"]);
    fixture.connect();
    fixture.tmux_shell("renamed", "after-reconnect");
    assert!(
        fixture
            .terminal_text()
            .contains("remote-review:before-loss")
    );
    assert!(
        fixture
            .tmux(&["list-clients", "-t", "=review", "-F", "#{client_pid}"])
            .is_empty()
    );
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn reconnect_does_not_open_a_replacement_tmux_session() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::reconnect_does_not_open_a_replacement_tmux_session",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-loss");
    fixture.interrupt_ssh();
    fixture.tmux(&["kill-session", "-t", "=review"]);
    fixture.tmux(&["new-session", "-d", "-s", "review", "/bin/sh"]);
    fixture.workspace.connect_host(&fixture.host_id).unwrap();
    fixture.wait_for_error("interrupted tmux session is no longer running");
    assert!(matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Shell
    ));
    assert!(
        fixture
            .tmux(&["list-clients", "-t", "=review", "-F", "#{client_pid}"])
            .is_empty()
    );
    // A new explicit selection can still open the replacement.
    fixture.attach("review", "replacement-selected");
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn reconnect_respects_detach_in_one_window_and_restores_another() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::reconnect_respects_detach_in_one_window_and_restores_another",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-loss");
    let other = fixture.open_scene();
    other.attach("notes 'one'", "other-before-loss");
    fixture.interrupt_ssh();
    other.wait_for_error("status 255");
    fixture.workspace.detach();
    other.connect();
    other.tmux_shell("notes 'one'", "other-after-reconnect");
    assert!(matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Shell
    ));
    assert!(
        fixture
            .tmux(&["list-clients", "-t", "=review", "-F", "#{client_pid}"])
            .is_empty()
    );
    fixture.attach("review", "explicit-selection");
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn clean_tmux_detach_is_not_reopened_by_host_refresh() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::clean_tmux_detach_is_not_reopened_by_host_refresh",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-detach");
    fixture.tmux(&["detach-client", "-s", "=review"]);
    fixture.wait(|snapshot| matches!(snapshot.content(), WorkspaceContent::Shell));
    fixture.connect();
    assert!(matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Shell
    ));
    fixture.attach("notes 'one'", "later-navigation");
    assert!(
        fixture
            .tmux(&["list-clients", "-t", "=review", "-F", "#{client_pid}"])
            .is_empty()
    );
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn failed_host_reconnect_preserves_the_interrupted_session_for_retry() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::failed_host_reconnect_preserves_the_interrupted_session_for_retry",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-loss");
    fixture.interrupt_ssh();
    let config_path = PathBuf::from(std::env::var_os("HOME").unwrap()).join(".ssh/config");
    let original = std::fs::read_to_string(&config_path).unwrap();
    let unavailable = original
        .lines()
        .map(|line| {
            if line.trim_start().starts_with("Port ") {
                "  Port 1"
            } else {
                line
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(&config_path, unavailable).unwrap();
    fixture.workspace.connect_host(&fixture.host_id).unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let snapshot = fixture.workspace.snapshot();
        let host = snapshot
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap();
        if host.connection() == HostConnectionState::Unavailable {
            assert!(host.diagnostic().is_some());
            break;
        }
        assert!(
            Instant::now() < deadline,
            "connection failure was not published"
        );
        thread::sleep(Duration::from_millis(20));
    }
    std::fs::write(&config_path, original).unwrap();
    fixture.connect();
    fixture.tmux_shell("review", "retry-resumed-original");
    assert!(
        fixture
            .terminal_text()
            .contains("remote-review:before-loss")
    );
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn a_second_host_refresh_preserves_recovery_waiting_to_attach() {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::a_second_host_refresh_preserves_recovery_waiting_to_attach",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-loss");
    fixture.interrupt_ssh();
    let home = PathBuf::from(std::env::var_os("HOME").unwrap());
    let bin = home.join("recovery-bin");
    std::fs::create_dir(&bin).unwrap();
    let probe = bin.join("infocmp");
    std::fs::write(&probe, "#!/bin/sh\nif [ ! -f \"$HOME/recovery-release\" ]; then\n  : > \"$HOME/recovery-started\"\n  while [ ! -f \"$HOME/recovery-release\" ]; do sleep 0.02; done\nfi\nexec /usr/bin/infocmp \"$@\"\n").unwrap();
    std::fs::set_permissions(&probe, std::fs::Permissions::from_mode(0o700)).unwrap();
    writeln!(
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(home.join(".profile"))
            .unwrap(),
        "\nexport PATH=\"$HOME/recovery-bin:$PATH\""
    )
    .unwrap();
    fixture.connect();
    fixture.wait(|_| home.join("recovery-started").exists());
    // Refresh supersedes the connection while the recovered client has not launched.
    fixture.connect();
    std::fs::write(home.join("recovery-release"), "").unwrap();
    fixture.tmux_shell("review", "second-refresh-resumed-original");
}
