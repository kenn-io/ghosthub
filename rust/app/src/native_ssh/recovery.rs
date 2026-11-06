use super::*;

impl Fixture {
    fn wait_for_automatic_recovery(&self) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            for event in self.workspace.drain_events().0 {
                match event {
                    WorkspaceEvent::SshPrompt(_) => {
                        panic!("automatic recovery opened an SSH prompt")
                    }
                    WorkspaceEvent::Error(error) => panic!("{error}"),
                    _ => {}
                }
            }
            if matches!(
                self.workspace.snapshot().content(),
                WorkspaceContent::Terminal { .. }
            ) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "automatic recovery did not reopen the terminal"
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    pub(super) fn interrupt_ssh(&self) {
        self.break_ssh_connections();
        self.wait_for_error("status 255");
        // These tests exercise explicit Refresh; stop the automatic retry first.
        let _ = self.workspace.cancel_host_connection(&self.host_id);
        assert!(matches!(
            self.workspace.snapshot().content(),
            WorkspaceContent::Shell
        ));
    }

    pub(super) fn break_ssh_connections(&self) {
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
    }
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn transport_loss_automatically_restores_the_selected_tmux_session() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::transport_loss_automatically_restores_the_selected_tmux_session",
    ) else {
        return;
    };
    fixture.tmux(&[
        "set-option",
        "-as",
        "terminal-overrides",
        ",*:smcup@:rmcup@",
    ]);
    fixture.connect();
    fixture.attach("review", "before-automatic-recovery");
    for marker in ["first-automatic-recovery", "second-automatic-recovery"] {
        fixture.break_ssh_connections();
        fixture.wait_for_error("status 255");
        fixture.wait_for_automatic_recovery();
        assert!(
            fixture.workspace.snapshot().notice().is_none(),
            "recovery must clear its notice"
        );
        fixture.tmux_shell("review", marker);
        fixture.wait(|_| {
            !fixture
                .workspace
                .remote_attachment_pending(&fixture.host_id)
        });
        assert_eq!(
            fixture
                .workspace
                .remote_reconnect_interval(&fixture.host_id),
            Some(Duration::from_secs(1)),
            "a restored terminal must give the next outage its initial delay"
        );
    }
    assert!(
        fixture
            .terminal_text()
            .contains("remote-review:before-automatic-recovery")
    );
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn reconnect_restores_tmux_without_alternate_screen_switching() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::reconnect_restores_tmux_without_alternate_screen_switching",
    ) else {
        return;
    };
    fixture.tmux(&[
        "set-option",
        "-as",
        "terminal-overrides",
        ",*:smcup@:rmcup@",
    ]);
    fixture.connect();
    fixture.attach("review", "without-alternate-screen");
    fixture.interrupt_ssh();
    fixture.connect();
    fixture.tmux_shell("review", "resumed-without-alternate-screen");
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn reconnect_published_before_terminal_exit_still_restores_tmux() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::reconnect_published_before_terminal_exit_still_restores_tmux",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-delayed-exit");
    let pump = fixture.workspace.pause_event_pump();
    fixture.break_ssh_connections();
    fixture.connect();
    // Connection publication has finished, but the old terminal exit is still queued.
    assert!(matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Terminal { .. }
    ));
    drop(pump);
    fixture.wait_for_error("status 255");
    fixture.tmux_shell("review", "resumed-after-delayed-exit");
    assert!(
        fixture
            .terminal_text()
            .contains("remote-review:before-delayed-exit")
    );
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn failed_recovery_startup_preserves_tmux_for_another_retry() {
    use std::os::unix::fs::PermissionsExt;
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::failed_recovery_startup_preserves_tmux_for_another_retry",
    ) else {
        return;
    };
    let wrapper = fixture.root.join("tmux-wrapper");
    std::fs::write(
        &wrapper,
        r#"#!/bin/sh
case " $* " in
    *"attach-session "*)
        if test -f "$HOME/block-tmux-attach"; then
            touch "$HOME/tmux-attach-started"
            while test -f "$HOME/block-tmux-attach"; do sleep 0.02; done
        fi
        ;;
esac
exec /usr/bin/tmux "$@"
"#,
    )
    .unwrap();
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut draft = fixture.workspace.configured_ssh_hosts()[0].draft().clone();
    wrapper.to_str().unwrap().clone_into(&mut draft.tmux_binary);
    fixture
        .workspace
        .save_ssh_host(Some(&fixture.host_id), &draft)
        .unwrap();
    fixture.connect();
    fixture.attach("review", "before-startup-failure");
    let home = fixture.root.join("home");
    std::fs::write(home.join("block-tmux-attach"), "").unwrap();
    fixture.break_ssh_connections();
    fixture.wait_for_error("status 255");
    fixture.wait(|snapshot| {
        home.join("tmux-attach-started").exists()
            && matches!(snapshot.content(), WorkspaceContent::Terminal { .. })
    });
    assert_eq!(
        fixture
            .workspace
            .remote_reconnect_interval(&fixture.host_id),
        Some(Duration::from_secs(2)),
        "launching SSH does not acknowledge tmux attachment"
    );
    fixture.break_ssh_connections();
    fixture.wait_for_error("status 255");
    assert_eq!(
        fixture
            .workspace
            .remote_reconnect_interval(&fixture.host_id),
        Some(Duration::from_secs(4)),
        "failed terminal startup must keep increasing the retry interval"
    );
    std::fs::remove_file(home.join("block-tmux-attach")).unwrap();
    fixture.wait_for_automatic_recovery();
    fixture.tmux_shell("review", "resumed-after-startup-failure");
    fixture.wait(|_| {
        !fixture
            .workspace
            .remote_attachment_pending(&fixture.host_id)
    });
    assert_eq!(
        fixture
            .workspace
            .remote_reconnect_interval(&fixture.host_id),
        Some(Duration::from_secs(1)),
    );
    assert!(
        fixture
            .terminal_text()
            .contains("remote-review:before-startup-failure")
    );
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
    fixture.wait(|_| {
        !fixture
            .workspace
            .remote_attachment_pending(&fixture.host_id)
    });
    assert!(matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Shell
    ));
    assert!(
        fixture
            .tmux(&["list-clients", "-t", "=review", "-F", "#{client_pid}"])
            .is_empty()
    );
    fixture.attach("notes 'one'", "later-navigation");
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

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn automatic_recovery_retries_an_unavailable_server() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::recovery::automatic_recovery_retries_an_unavailable_server")
    else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-outage");
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
    fixture.break_ssh_connections();
    fixture.wait_for_error("status 255");
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let snapshot = fixture.workspace.snapshot();
        let host = snapshot
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap();
        if host.connection() == HostConnectionState::Unavailable
            && host.diagnostic().is_some_and(|diagnostic| {
                diagnostic.message().contains("port 1:")
                    && diagnostic.message().contains("Connection refused")
            })
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "automatic connection to Port 1 did not fail: {:?}",
            host.diagnostic()
        );
        thread::sleep(Duration::from_millis(20));
    }
    std::fs::write(&config_path, original).unwrap();
    fixture.wait_for_automatic_recovery();
    fixture.tmux_shell("review", "after-outage");
    assert!(
        fixture
            .terminal_text()
            .contains("remote-review:before-outage")
    );
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn automatic_recovery_waits_for_explicit_host_key_review() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::automatic_recovery_waits_for_explicit_host_key_review",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-review");
    let known_hosts = PathBuf::from(std::env::var_os("HOME").unwrap()).join(".ssh/known_hosts");
    std::fs::remove_file(known_hosts).unwrap();
    fixture.break_ssh_connections();
    fixture.wait_for_error("status 255");
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        for event in fixture.workspace.drain_events().0 {
            assert!(
                !matches!(event, WorkspaceEvent::SshPrompt(_)),
                "automatic SSH must wait for Retry before prompting"
            );
        }
        let snapshot = fixture.workspace.snapshot();
        let host = snapshot
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap();
        if host.connection() == HostConnectionState::Unavailable {
            assert_eq!(
                host.diagnostic().unwrap().kind(),
                model::DiagnosticKind::PermissionDenied
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "host-key review was not surfaced"
        );
        thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        fixture.connect(),
        1,
        "explicit Retry must present host-key review"
    );
    fixture.tmux_shell("review", "after-review");
}

#[test]
#[ignore = "requires the isolated SSH fixture; run make rust-test-ssh-live"]
fn automatic_recovery_respects_detach_in_another_window() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::recovery::automatic_recovery_respects_detach_in_another_window",
    ) else {
        return;
    };
    fixture.connect();
    fixture.attach("review", "before-loss");
    let other = fixture.open_scene();
    other.attach("notes 'one'", "other-before-loss");
    fixture.break_ssh_connections();
    fixture.wait_for_error("status 255");
    other.wait_for_error("status 255");
    fixture.workspace.detach();
    other.wait_for_automatic_recovery();
    other.tmux_shell("notes 'one'", "other-recovered");
    assert!(
        !fixture
            .workspace
            .remote_attachment_pending(&fixture.host_id)
    );
    assert!(matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Shell
    ));
    assert!(
        fixture
            .tmux(&["list-clients", "-t", "=review", "-F", "#{client_pid}"])
            .is_empty()
    );
}
