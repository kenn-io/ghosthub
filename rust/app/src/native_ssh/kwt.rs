use super::*;
use sha2::{Digest, Sha256};

#[test]
#[ignore = "requires the pinned KWT helper and isolated OpenSSH; run make rust-test-ssh-live"]
#[allow(clippy::too_many_lines)] // One real project through registration, restart, attachment, and removal.
fn registers_refreshes_and_removes_a_remote_project() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::kwt::registers_refreshes_and_removes_a_remote_project")
    else {
        return;
    };
    let project_path = fixture.root.join("orbit 'one'");
    create_project(&project_path);
    fixture.connect();
    fixture.wait(|snapshot| {
        snapshot.hosts().iter().any(|host| {
            host.id() == fixture.host_id && host.kwt_available() && !host.kwt_refreshing()
        })
    });
    let path = project_path.to_str().unwrap();
    fixture
        .workspace
        .add_kwt_project(&fixture.host_id, &fixture.endpoint, path)
        .unwrap();
    wait_mutation(&fixture).unwrap();
    fixture.wait(|snapshot| {
        snapshot.hosts().iter().any(|host| {
            host.id() == fixture.host_id
                && !host.kwt_mutating()
                && host.projects().iter().any(|project| project.path() == path)
        })
    });
    remote_kwt_in(path, &["add", "--branch", "feature", "--no-launch"]);
    fixture.workspace.close();
    let fixture = Fixture::new(fixture.root.clone());
    fixture.connect();
    fixture.wait(|snapshot| {
        snapshot.hosts().iter().any(|host| {
            host.id() == fixture.host_id
                && !host.kwt_refreshing()
                && host.projects().iter().any(|project| project.path() == path)
        })
    });
    let snapshot = fixture.workspace.snapshot();
    let project = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap()
        .projects()
        .iter()
        .find(|project| project.path() == path)
        .unwrap();
    let worktree = project
        .worktrees()
        .iter()
        .find(|item| item.branch() == "feature")
        .unwrap();
    let name = worktree.session_name();
    start_workspace_session(
        &fixture,
        false,
        name,
        worktree.path(),
        worktree.generation(),
    );
    fixture.connect();
    wait_kwt_ready(&fixture);
    let refreshed = fixture.workspace.snapshot();
    let worktree = refreshed
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap()
        .projects()[0]
        .worktrees()
        .iter()
        .find(|item| item.branch() == "feature")
        .unwrap();
    assert!(worktree.tmux_socket_name().is_none(), "{worktree:?}");
    let selection = SessionSelection::kwt_workspace(
        &fixture.host_id,
        &fixture.endpoint,
        name,
        worktree.tmux_attach_mode(),
        worktree.tmux_socket_name().map(str::to_owned),
        worktree.path(),
        worktree.generation().map(str::to_owned),
    );
    fixture.workspace.switch_session(&selection).unwrap();
    fixture.tmux_shell(name, "project-row");
    for (mode, socket) in [
        (
            host::KwtTmuxAttachMode::Direct,
            Some("dedicated".to_owned()),
        ),
        (host::KwtTmuxAttachMode::Protected, None),
    ] {
        let unsupported = SessionSelection::kwt_workspace(
            &fixture.host_id,
            &fixture.endpoint,
            name,
            mode,
            socket,
            worktree.path(),
            worktree.generation().map(str::to_owned),
        );
        assert!(fixture.workspace.switch_session(&unsupported).is_err());
    }
    fixture.tmux_shell(name, "wrong-socket-rejected");

    // A separate controller changes the registration after confirmation was captured.
    remote_kwt(&[
        "projects",
        "remove",
        path,
        "--expected-repository",
        project.repository(),
        "--expected-registration",
        project.registration_fingerprint(),
        "--json",
    ]);
    remote_kwt(&["projects", "add", path, "--json"]);
    fixture
        .workspace
        .remove_kwt_project(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            path,
            project.registration_fingerprint(),
        )
        .unwrap();
    assert!(
        wait_mutation(&fixture)
            .unwrap_err()
            .contains("registration changed")
    );
    fixture.connect();
    wait_kwt_ready(&fixture);
    let snapshot = fixture.workspace.snapshot();
    let project = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap()
        .projects()
        .iter()
        .find(|project| project.path() == path)
        .unwrap();
    fixture
        .workspace
        .remove_kwt_project(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            path,
            project.registration_fingerprint(),
        )
        .unwrap();
    wait_mutation(&fixture).unwrap();
    fixture.wait(|snapshot| {
        snapshot.hosts().iter().any(|host| {
            host.id() == fixture.host_id && !host.kwt_mutating() && host.projects().is_empty()
        })
    });
    assert!(project_path.join(".git").is_dir());
    fixture.tmux_shell(name, "after-project-removal");
    fixture.workspace.close();
}

fn start_workspace_session(
    fixture: &Fixture,
    kwt_socket: bool,
    name: &str,
    path: &str,
    generation: Option<&str>,
) {
    workspace_tmux(
        fixture,
        kwt_socket,
        &["new-session", "-d", "-s", name, "/bin/sh"],
    );
    workspace_tmux(
        fixture,
        kwt_socket,
        &[
            "set-option",
            "-t",
            name,
            "@kwt-workspace-id",
            &format!("{:x}", Sha256::digest(path.as_bytes())),
        ],
    );
    if let Some(generation) = generation {
        workspace_tmux(
            fixture,
            kwt_socket,
            &[
                "set-option",
                "-t",
                name,
                "@kwt-workspace-generation",
                generation,
            ],
        );
    }
}

fn workspace_tmux(fixture: &Fixture, kwt_socket: bool, args: &[&str]) -> String {
    if !kwt_socket {
        return fixture.tmux(args);
    }
    let output = Command::new("/usr/bin/tmux")
        .env_remove("TMUX_TMPDIR")
        .args(["-L", "kwt"])
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn opens_and_kills_workspaces_on_the_kwt_socket() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::kwt::opens_and_kills_workspaces_on_the_kwt_socket")
    else {
        return;
    };
    workspace_session_lifecycle(&fixture, true);
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn kills_only_confirmed_default_socket_workspace_sessions() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::kills_only_confirmed_default_socket_workspace_sessions",
    ) else {
        return;
    };
    workspace_session_lifecycle(&fixture, false);
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn opens_and_kills_kwt_sessions_when_default_inventory_fails() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::opens_and_kills_kwt_sessions_when_default_inventory_fails",
    ) else {
        return;
    };
    fixture.connect();
    wait_kwt_ready(&fixture);
    let directory = fixture.root.join("assets");
    std::fs::create_dir(&directory).unwrap();
    remote_kwt(&["workspace", "add", directory.to_str().unwrap()]);
    fixture.connect();
    wait_kwt_ready(&fixture);
    let snapshot = fixture.workspace.snapshot();
    let row = &snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap()
        .directory_workspaces()[0];
    start_workspace_session(&fixture, true, row.session_name(), row.path(), None);

    // A real filesystem error breaks only the configured default socket.
    // The executable and canonical KWT server remain healthy.
    let socket_directory = fixture.root.join("tmux");
    std::fs::rename(&socket_directory, fixture.root.join("tmux-saved")).unwrap();
    std::fs::write(&socket_directory, "not a directory").unwrap();
    fixture.connect();
    fixture.wait(|snapshot| {
        snapshot
            .hosts()
            .iter()
            .any(|host| host.id() == fixture.host_id && !host.kwt_refreshing())
    });
    let snapshot = fixture.workspace.snapshot();
    let host = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap();
    assert!(host.tmux_diagnostic().is_some(), "{host:?}");
    assert!(host.kwt_diagnostic().is_none(), "{host:?}");
    let row = &host.directory_workspaces()[0];
    assert!(row.session_available(), "{row:?}");
    assert_eq!(row.tmux_socket_name(), Some("kwt"));
    let selection = SessionSelection::kwt_workspace(
        &fixture.host_id,
        &fixture.endpoint,
        row.session_name(),
        row.tmux_attach_mode(),
        row.tmux_socket_name().map(str::to_owned),
        row.path(),
        None,
    );
    // This session has never had a retained client to mask skipped discovery.
    fixture.workspace.switch_session(&selection).unwrap();
    fixture.tmux_shell(selection.session(), "default-inventory-failed");
    fixture.workspace.request_session_kill(&selection).unwrap();
    fixture.wait(|_| fixture.workspace.session_kill_confirmation().is_some());
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait(|snapshot| {
        let output = Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args([
                "-L",
                "kwt",
                "has-session",
                "-t",
                &format!("={}", selection.session()),
            ])
            .output()
            .unwrap();
        !output.status.success()
            && snapshot.hosts().iter().any(|host| {
                host.id() == fixture.host_id
                    && host.directory_workspaces().iter().any(|row| {
                        row.session_name() == selection.session() && !row.session_available()
                    })
            })
    });
    assert!(directory.is_dir());
    fixture.workspace.close();
}

#[allow(clippy::too_many_lines)] // Both workspace kinds through discovery, switching, and confirmed kills.
fn workspace_session_lifecycle(fixture: &Fixture, kwt_socket: bool) {
    if kwt_socket {
        use std::os::unix::fs::PermissionsExt;
        let wrapper = fixture.root.join("tmux-probe");
        std::fs::write(&wrapper, "#!/bin/sh\nif [ -e \"$HOME/fail-tmux\" ] && [ \"$1\" = -V ]; then echo 'tmux probe unavailable' >&2; exit 42; fi\nif [ -e \"$HOME/fail-kwt\" ] && [ \"$1\" = -L ] && [ \"$2\" = kwt ] && [ \"$5\" = list-sessions ]; then echo 'kwt server inventory unavailable' >&2; exit 42; fi\nexec /usr/bin/tmux \"$@\"\n").unwrap();
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut draft = fixture.workspace.configured_ssh_hosts()[0].draft().clone();
        wrapper.to_str().unwrap().clone_into(&mut draft.tmux_binary);
        fixture
            .workspace
            .save_ssh_host(Some(&fixture.host_id), &draft)
            .unwrap();
    }
    let project_path = fixture.root.join("orbit");
    create_project(&project_path);
    let directory = fixture.root.join("assets");
    std::fs::create_dir(&directory).unwrap();
    fixture.connect();
    wait_kwt_ready(fixture);
    fixture
        .workspace
        .add_kwt_project(
            &fixture.host_id,
            &fixture.endpoint,
            project_path.to_str().unwrap(),
        )
        .unwrap();
    wait_mutation(fixture).unwrap();
    remote_kwt_in(
        project_path.to_str().unwrap(),
        &["add", "--branch", "feature", "--no-launch"],
    );
    remote_kwt(&["workspace", "add", directory.to_str().unwrap()]);
    fixture.connect();
    wait_kwt_ready(fixture);
    let selections = |snapshot: &WorkspaceSnapshot| {
        let host = snapshot
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap();
        let worktree = host.projects()[0]
            .worktrees()
            .iter()
            .find(|item| item.branch() == "feature")
            .unwrap();
        let directory = &host.directory_workspaces()[0];
        [
            SessionSelection::kwt_workspace(
                &fixture.host_id,
                &fixture.endpoint,
                worktree.session_name(),
                worktree.tmux_attach_mode(),
                worktree.tmux_socket_name().map(str::to_owned),
                worktree.path(),
                worktree.generation().map(str::to_owned),
            ),
            SessionSelection::kwt_workspace(
                &fixture.host_id,
                &fixture.endpoint,
                directory.session_name(),
                directory.tmux_attach_mode(),
                directory.tmux_socket_name().map(str::to_owned),
                directory.path(),
                None,
            ),
        ]
    };
    let snapshot = fixture.workspace.snapshot();
    for selection in &selections(&snapshot) {
        start_workspace_session(
            fixture,
            kwt_socket,
            selection.session(),
            selection.worktree_path().unwrap(),
            selection.worktree_generation(),
        );
    }
    fixture.connect();
    wait_kwt_ready(fixture);
    let snapshot = fixture.workspace.snapshot();
    for selection in &selections(&snapshot) {
        assert_eq!(selection.tmux_socket_name(), kwt_socket.then_some("kwt"));
        if kwt_socket {
            // A same-name session on the ordinary server must never receive this client or kill.
            fixture.tmux(&["new-session", "-d", "-s", selection.session(), "/bin/sh"]);
        }
        fixture.workspace.switch_session(selection).unwrap();
        fixture.tmux_shell(selection.session(), "workspace-before-kill");
        assert_eq!(
            workspace_tmux(
                fixture,
                kwt_socket,
                &[
                    "display-message",
                    "-p",
                    "-t",
                    selection.session(),
                    "#{session_attached}"
                ]
            ),
            "1"
        );
        fixture.attach("review", "switch-away");
        fixture.connect();
        wait_kwt_ready(fixture);
        fixture.workspace.switch_session(selection).unwrap();
        fixture.tmux_shell(selection.session(), "retained-after-refresh");
        assert_eq!(
            workspace_tmux(
                fixture,
                kwt_socket,
                &[
                    "display-message",
                    "-p",
                    "-t",
                    selection.session(),
                    "#{session_attached}"
                ]
            ),
            "1"
        );
        if kwt_socket && selection.worktree_generation().is_some() {
            for fault in ["fail-kwt", "fail-tmux"] {
                let marker = fixture.root.join("home").join(fault);
                std::fs::write(&marker, "").unwrap();
                fixture.attach("review", "before-failed-probe");
                fixture.connect();
                fixture.wait(|snapshot| {
                    snapshot.hosts().iter().any(|host| {
                        host.id() == fixture.host_id
                            && host.kwt_diagnostic().is_some()
                            && !host.kwt_refreshing()
                    })
                });
                assert!(
                    fixture
                        .workspace
                        .snapshot()
                        .retained_selections()
                        .iter()
                        .any(|retained| retained.session() == selection.session()
                            && retained.tmux_socket_name() == Some("kwt"))
                );
                if fault == "fail-kwt" {
                    fixture.tmux_shell("review", "ordinary-server-still-usable");
                }
                fixture.workspace.switch_session(selection).unwrap();
                fixture.tmux_shell(selection.session(), "retained-without-inventory");
                std::fs::remove_file(marker).unwrap();
                fixture.connect();
                wait_kwt_ready(fixture);
            }
            let project = &snapshot
                .hosts()
                .iter()
                .find(|host| host.id() == fixture.host_id)
                .unwrap()
                .projects()[0];
            fixture
                .workspace
                .remove_kwt_project(
                    &fixture.host_id,
                    &fixture.endpoint,
                    project.repository(),
                    project.path(),
                    project.registration_fingerprint(),
                )
                .unwrap();
            wait_mutation(fixture).unwrap();
            fixture.attach("review", "unregistered-project");
        }
        let live_selection = fixture
            .workspace
            .snapshot()
            .active_selection()
            .filter(|active| active.session() == selection.session())
            .cloned()
            .or_else(|| {
                fixture
                    .workspace
                    .snapshot()
                    .retained_selections()
                    .iter()
                    .find(|retained| retained.session() == selection.session())
                    .cloned()
            })
            .unwrap();
        fixture.workspace.switch_session(&live_selection).unwrap();
        fixture.tmux_shell(selection.session(), "live-client");
        for (mode, socket) in [
            (
                host::KwtTmuxAttachMode::Direct,
                Some("dedicated".to_owned()),
            ),
            (host::KwtTmuxAttachMode::Protected, None),
        ] {
            let unsupported = SessionSelection::kwt_workspace(
                &fixture.host_id,
                &fixture.endpoint,
                selection.session(),
                mode,
                socket,
                selection.worktree_path().unwrap(),
                selection.worktree_generation().map(str::to_owned),
            );
            assert!(
                fixture
                    .workspace
                    .request_session_kill(&unsupported)
                    .is_err()
            );
        }
        fixture
            .workspace
            .request_session_kill(&live_selection)
            .unwrap();
        fixture.wait(|_| fixture.workspace.session_kill_confirmation().is_some());
        fixture.workspace.cancel_session_kill();
        assert!(fixture.workspace.confirm_session_kill().is_err());
        fixture.tmux_shell(selection.session(), "workspace-kill-cancelled");
        fixture
            .workspace
            .request_session_kill(&live_selection)
            .unwrap();
        fixture.wait(|_| fixture.workspace.session_kill_confirmation().is_some());
        fixture.workspace.confirm_session_kill().unwrap();
        fixture.wait(|snapshot| {
            let output = Command::new("/usr/bin/tmux")
                .env(
                    "TMUX_TMPDIR",
                    if kwt_socket {
                        PathBuf::from("/tmp")
                    } else {
                        fixture.root.join("tmux")
                    },
                )
                .args(if kwt_socket {
                    vec!["-L", "kwt"]
                } else {
                    vec![]
                })
                .args(["has-session", "-t", &format!("={}", selection.session())])
                .output()
                .unwrap();
            let host = snapshot
                .hosts()
                .iter()
                .find(|host| host.id() == fixture.host_id)
                .unwrap();
            !output.status.success()
                && host
                    .projects()
                    .iter()
                    .flat_map(workspace::ProjectItem::worktrees)
                    .all(|row| {
                        row.session_name() != selection.session() || !row.session_available()
                    })
                && host.directory_workspaces().iter().all(|row| {
                    row.session_name() != selection.session() || !row.session_available()
                })
        });
        if kwt_socket {
            fixture.tmux(&["has-session", "-t", &format!("={}", selection.session())]);
        }
        assert!(Path::new(selection.worktree_path().unwrap()).is_dir());
    }
    fixture.attach("review", "unrelated-session-survives");
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn removing_host_cancels_in_flight_helper_provisioning() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::kwt::removing_host_cancels_in_flight_helper_provisioning")
    else {
        return;
    };
    cancel_provisioning_on_host_change(&fixture, false);
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn retargeting_host_cancels_in_flight_helper_provisioning() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::retargeting_host_cancels_in_flight_helper_provisioning",
    ) else {
        return;
    };
    cancel_provisioning_on_host_change(&fixture, true);
}

fn cancel_provisioning_on_host_change(fixture: &Fixture, retarget: bool) {
    use std::os::unix::fs::PermissionsExt;
    let bin = fixture.root.join("kwt-probe");
    std::fs::create_dir(&bin).unwrap();
    let probe = bin.join("uname");
    std::fs::write(&probe, "#!/bin/sh\nif [ \"$1\" = -s ]; then\n  : > \"$HOME/kwt-probe-started\"\n  while [ ! -e \"$HOME/kwt-probe-release\" ]; do sleep .02; done\nfi\nexec /usr/bin/uname \"$@\"\n").unwrap();
    std::fs::set_permissions(&probe, std::fs::Permissions::from_mode(0o700)).unwrap();
    let profile = fixture.root.join("home/.profile");
    let contents = std::fs::read_to_string(&profile).unwrap_or_default();
    std::fs::write(
        profile,
        format!("{contents}\nexport PATH='{}':\"$PATH\"\n", bin.display()),
    )
    .unwrap();
    fixture.connect();
    fixture.wait(|_| fixture.root.join("home/kwt-probe-started").exists());
    assert_eq!(
        fixture.daemon_status(&fixture.controller_home)["active_leases"],
        1
    );
    assert!(!managed_helper().exists());
    if retarget {
        let mut draft = fixture.workspace.configured_ssh_hosts()[0].draft().clone();
        "other.example".clone_into(&mut draft.hostname);
        fixture
            .workspace
            .save_ssh_host(Some(&fixture.host_id), &draft)
            .unwrap();
    } else {
        fixture.workspace.remove_ssh_host(&fixture.host_id).unwrap();
    }
    // The task owns the final lease while its SSH probe is blocked. Its
    // release proves cancellation settled before we let that probe proceed.
    let deadline = Instant::now() + Duration::from_secs(10);
    while fixture.daemon_status(&fixture.controller_home)["active_leases"] != 0 {
        assert!(
            Instant::now() < deadline,
            "removed host still owns a provisioning lease"
        );
        thread::sleep(Duration::from_millis(20));
    }
    std::fs::write(fixture.root.join("home/kwt-probe-release"), "").unwrap();
    assert!(
        !managed_helper().exists(),
        "cancelled provisioning activated a helper"
    );
    assert!(
        fixture
            .workspace
            .snapshot()
            .hosts()
            .iter()
            .all(|host| host.id() != fixture.host_id)
    );
    fixture.workspace.close();
}

fn wait_kwt_ready(fixture: &Fixture) {
    fixture.wait(|snapshot| {
        snapshot.hosts().iter().any(|host| {
            host.id() == fixture.host_id
                && host.kwt_available()
                && !host.kwt_refreshing()
                && host.kwt_diagnostic().is_none()
        })
    });
}

fn wait_mutation(fixture: &Fixture) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        for event in fixture.workspace.drain_events().0 {
            match event {
                WorkspaceEvent::KwtProjectMutationFinished { .. } => return Ok(()),
                WorkspaceEvent::KwtProjectMutationFailed { message, .. } => return Err(message),
                WorkspaceEvent::Error(message) => panic!("{message}"),
                _ => {}
            }
        }
        assert!(
            Instant::now() < deadline,
            "KWT project operation did not settle"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

fn managed_helper() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap())
        .join(".ghosthub/helpers/kwt")
        .join(env!("GHOSTHUB_KWT_REVISION"))
        .join("kwt")
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn repairs_the_remote_helper_and_scopes_failure_away_from_terminals() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::repairs_the_remote_helper_and_scopes_failure_away_from_terminals",
    ) else {
        return;
    };
    let helper = managed_helper();
    assert!(!helper.exists());
    fixture.connect();
    wait_kwt_ready(&fixture);
    let expected = std::fs::read(&helper).unwrap();
    assert_eq!(
        expected,
        super::super::bundled_remote_kwt()
            .into_iter()
            .find(|(target, _)| *target
                == if cfg!(target_arch = "aarch64") {
                    host::RemoteKwtTarget::LinuxArm64
                } else {
                    host::RemoteKwtTarget::LinuxAmd64
                })
            .unwrap()
            .1
            .bytes()
    );

    let corrupt = helper.with_extension("corrupt");
    std::fs::write(&corrupt, b"#!/bin/sh\nexit 99\n").unwrap();
    std::fs::rename(corrupt, &helper).unwrap();
    fixture.connect();
    wait_kwt_ready(&fixture);
    assert_eq!(std::fs::read(&helper).unwrap(), expected);

    let project_path = fixture.root.join("orbit");
    create_project(&project_path);
    fixture
        .workspace
        .add_kwt_project(
            &fixture.host_id,
            &fixture.endpoint,
            project_path.to_str().unwrap(),
        )
        .unwrap();
    wait_mutation(&fixture).unwrap();
    let directory = helper.parent().unwrap();
    let saved = directory.with_extension("saved");
    std::fs::rename(directory, &saved).unwrap();
    std::fs::write(directory, b"fixture blocks helper directory").unwrap();
    fixture.connect();
    fixture.wait(|snapshot| {
        snapshot.hosts().iter().any(|host| {
            host.id() == fixture.host_id
                && !host.kwt_refreshing()
                && host.kwt_diagnostic().is_some()
        })
    });
    assert!(
        fixture
            .workspace
            .snapshot()
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap()
            .projects()
            .iter()
            .any(|project| project.path() == project_path.to_str().unwrap())
    );
    fixture.attach("review", "helper-unavailable");
    std::fs::remove_file(directory).unwrap();
    std::fs::rename(saved, directory).unwrap();
    fixture.connect();
    wait_kwt_ready(&fixture);
    fixture
        .workspace
        .add_kwt_project(&fixture.host_id, &fixture.endpoint, "/does-not-exist")
        .unwrap();
    assert!(wait_mutation(&fixture).is_err());
    fixture.attach("notes 'one'", "after-rejected-add");
    fixture.workspace.close();
}

fn create_project(project_path: &Path) {
    std::fs::create_dir(project_path).unwrap();
    for args in [
        vec!["init", "-b", "main"],
        vec!["config", "user.name", "Fixture"],
        vec!["config", "user.email", "fixture@example.com"],
        vec![
            "remote",
            "add",
            "origin",
            "https://example.com/team/orbit.git",
        ],
        vec!["commit", "--allow-empty", "-m", "Initial"],
    ] {
        let output = Command::new("git")
            .current_dir(project_path)
            .args(args)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
    }
}

fn remote_kwt(args: &[&str]) -> Vec<u8> {
    remote_kwt_in("/", args)
}

fn remote_kwt_in(directory: &str, args: &[&str]) -> Vec<u8> {
    let quote = |value: &str| format!("'{}'", value.replace('\'', "'\\''"));
    let command = std::iter::once(managed_helper().to_str().unwrap().to_owned())
        .chain(args.iter().map(|arg| (*arg).to_owned()))
        .map(|arg| quote(&arg))
        .collect::<Vec<_>>()
        .join(" ");
    let command = format!("cd {} && {}", quote(directory), command);
    let output = Command::new("ssh")
        .args(["studio.example", &command])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    output.stdout
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn a_successful_registration_survives_failed_reconciliation() {
    use std::os::unix::fs::PermissionsExt;
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::a_successful_registration_survives_failed_reconciliation",
    ) else {
        return;
    };
    fixture.connect();
    wait_kwt_ready(&fixture);
    let project_path = fixture.root.join("orbit");
    create_project(&project_path);
    let bin = fixture.root.join("kwt-probe");
    std::fs::create_dir(&bin).unwrap();
    let probe = bin.join("sha256sum");
    std::fs::write(&probe, "#!/bin/sh\n[ ! -e \"$HOME/deny-kwt-probe\" ] || exit 1\n: > \"$HOME/deny-kwt-probe\"\nexec /usr/bin/sha256sum \"$@\"\n").unwrap();
    std::fs::set_permissions(&probe, std::fs::Permissions::from_mode(0o700)).unwrap();
    let profile = fixture.root.join("home/.profile");
    let contents = std::fs::read_to_string(&profile).unwrap_or_default();
    std::fs::write(
        profile,
        format!("{contents}\nexport PATH='{}':\"$PATH\"\n", bin.display()),
    )
    .unwrap();
    fixture
        .workspace
        .add_kwt_project(
            &fixture.host_id,
            &fixture.endpoint,
            project_path.to_str().unwrap(),
        )
        .unwrap();
    wait_mutation(&fixture).unwrap();
    let snapshot = fixture.workspace.snapshot();
    let host = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap();
    assert!(host.kwt_diagnostic().is_some());
    assert!(
        host.projects()
            .iter()
            .any(|project| project.path() == project_path.to_str().unwrap())
    );
    assert!(!host.kwt_mutating());
    fixture.attach("review", "registration-committed");
    std::fs::remove_file(probe).unwrap();
    fixture.connect();
    wait_kwt_ready(&fixture);
    assert!(
        fixture
            .workspace
            .snapshot()
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap()
            .projects()
            .iter()
            .any(|project| project.path() == project_path.to_str().unwrap())
    );
    fixture.workspace.close();
}
