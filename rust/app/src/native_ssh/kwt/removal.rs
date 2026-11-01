use super::*;

struct Target {
    project: workspace::ProjectItem,
    worktree: workspace::WorktreeItem,
}

impl Target {
    fn ready(&self, fixture: &Fixture) -> u64 {
        let authority = self.request(fixture);
        match wait_worktree_event(fixture, authority) {
            WorkspaceEvent::KwtWorktreeRemovalReady { .. } => authority,
            WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } => panic!("{message}"),
            _ => panic!("unexpected removal event"),
        }
    }
    fn current(fixture: &Fixture, branch: &str) -> Self {
        let snapshot = fixture.workspace.snapshot();
        let project = snapshot
            .hosts()
            .iter()
            .find(|h| h.id() == fixture.host_id)
            .unwrap()
            .projects()[0]
            .clone();
        let worktree = project
            .worktrees()
            .iter()
            .find(|w| w.branch() == branch)
            .unwrap()
            .clone();
        Self { project, worktree }
    }

    fn request(&self, fixture: &Fixture) -> u64 {
        fixture
            .workspace
            .request_kwt_worktree_removal(
                &fixture.host_id,
                &fixture.endpoint,
                self.project.repository(),
                self.project.path(),
                self.project.registration_fingerprint(),
                self.worktree.path(),
                self.worktree.generation().unwrap(),
                self.worktree.session_name(),
                self.worktree.tmux_socket_name(),
                self.worktree.tmux_attach_mode(),
            )
            .unwrap()
    }

    fn confirm(&self, fixture: &Fixture, authority: u64) -> Result<(), workspace::WorkspaceError> {
        fixture.workspace.remove_kwt_worktree(
            &fixture.host_id,
            &fixture.endpoint,
            self.project.repository(),
            self.project.path(),
            self.project.registration_fingerprint(),
            self.worktree.path(),
            self.worktree.generation().unwrap(),
            self.worktree.session_name(),
            authority,
        )
    }

    fn selection(&self, fixture: &Fixture) -> SessionSelection {
        SessionSelection::kwt_workspace(
            &fixture.host_id,
            &fixture.endpoint,
            self.worktree.session_name(),
            self.worktree.tmux_attach_mode(),
            self.worktree.tmux_socket_name().map(str::to_owned),
            self.worktree.path(),
            self.worktree.generation().map(str::to_owned),
        )
    }
}

fn project(fixture: &Fixture) -> PathBuf {
    let path = fixture.root.join("orbit 'one'");
    create_project(&path);
    fixture.connect();
    wait_kwt_ready(fixture);
    remote_kwt(&["projects", "add", path.to_str().unwrap(), "--json"]);
    path
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn removes_remote_worktrees_and_keeps_their_branches() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::removes_remote_worktrees_and_keeps_their_branches",
    ) else {
        return;
    };
    let path = project(&fixture);
    for (branch, socket) in [
        ("idle", None),
        ("default", Some(false)),
        ("named", Some(true)),
    ] {
        remote_kwt_in(
            path.to_str().unwrap(),
            &["add", "--branch", branch, "--no-launch"],
        );
        fixture.connect();
        wait_kwt_ready(&fixture);
        let target = Target::current(&fixture, branch);
        if let Some(kwt_socket) = socket {
            start_workspace_session(
                &fixture,
                kwt_socket,
                target.worktree.session_name(),
                target.worktree.path(),
                target.worktree.generation(),
            );
            fixture.connect();
            wait_kwt_ready(&fixture);
        }
        let target = Target::current(&fixture, branch);
        let other = fixture.open_scene();
        if socket.is_some() {
            other
                .workspace
                .switch_session(&target.selection(&fixture))
                .unwrap();
            other.tmux_shell(target.worktree.session_name(), "before-worktree-removal");
        }
        let cancelled = target.ready(&fixture);
        fixture.workspace.cancel_kwt_worktree_removal();
        assert!(target.confirm(&fixture, cancelled).is_err());
        assert!(Path::new(target.worktree.path()).is_dir());
        let authority = target.request(&fixture);
        let event = wait_worktree_event(&fixture, authority);
        let WorkspaceEvent::KwtWorktreeRemovalReady {
            session_was_running,
            ..
        } = event
        else {
            panic!("removal confirmation failed")
        };
        assert_eq!(session_was_running, socket.is_some());
        let other_authority = target.ready(&other);
        target.confirm(&fixture, authority).unwrap();
        let event = wait_worktree_event(&fixture, authority);
        match event {
            WorkspaceEvent::KwtWorktreeRemoved { .. } => {}
            WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } => panic!("{message}"),
            _ => panic!("unexpected removal event"),
        }
        assert!(!Path::new(target.worktree.path()).exists());
        let branch_exists = Command::new("git")
            .current_dir(&path)
            .args([
                "show-ref",
                "--quiet",
                "--verify",
                &format!("refs/heads/{branch}"),
            ])
            .status()
            .unwrap();
        assert!(branch_exists.success());
        assert!(target.confirm(&other, other_authority).is_err());
        other.wait(|s| s.active_selection().is_none());
        assert!(
            fixture
                .workspace
                .snapshot()
                .hosts()
                .iter()
                .find(|h| h.id() == fixture.host_id)
                .unwrap()
                .projects()[0]
                .worktrees()
                .iter()
                .all(|w| w.path() != target.worktree.path())
        );
        other.workspace.close();
    }
    fixture.attach("review", "unrelated-session-survives-removal");
    fixture.workspace.close();
}

fn seed(fixture: &Fixture, path: &Path, branch: &str, socket: Option<bool>) -> Target {
    remote_kwt_in(
        path.to_str().unwrap(),
        &["add", "--branch", branch, "--no-launch"],
    );
    fixture.connect();
    wait_kwt_ready(fixture);
    let target = Target::current(fixture, branch);
    if let Some(kwt_socket) = socket {
        start_workspace_session(
            fixture,
            kwt_socket,
            target.worktree.session_name(),
            target.worktree.path(),
            target.worktree.generation(),
        );
        fixture.connect();
        wait_kwt_ready(fixture);
    }
    Target::current(fixture, branch)
}

fn failure(fixture: &Fixture, authority: u64) -> String {
    match wait_worktree_event(fixture, authority) {
        WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } => message,
        _ => panic!("expected rejected removal"),
    }
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn dirty_remote_worktrees_keep_the_checkout_and_running_session() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::dirty_remote_worktrees_keep_the_checkout_and_running_session",
    ) else {
        return;
    };
    let path = project(&fixture);
    let target = seed(&fixture, &path, "dirty", Some(false));
    let dirty = Path::new(target.worktree.path()).join("unfinished.txt");
    std::fs::write(&dirty, "keep this work\n").unwrap();
    assert!(failure(&fixture, target.request(&fixture)).contains("has changes"));
    workspace_tmux(
        &fixture,
        false,
        &["has-session", "-t", target.worktree.session_name()],
    );
    std::fs::remove_file(&dirty).unwrap();
    let authority = target.ready(&fixture);
    std::fs::write(&dirty, "changes made after confirmation\n").unwrap();
    target.confirm(&fixture, authority).unwrap();
    assert!(failure(&fixture, authority).contains("has changes"));
    assert_eq!(
        std::fs::read_to_string(&dirty).unwrap(),
        "changes made after confirmation\n"
    );
    workspace_tmux(
        &fixture,
        false,
        &["has-session", "-t", target.worktree.session_name()],
    );
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn remote_removal_rejects_new_and_replacement_sessions() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::remote_removal_rejects_new_and_replacement_sessions",
    ) else {
        return;
    };
    let path = project(&fixture);
    for (branch, socket) in [
        ("idle", None),
        ("default", Some(false)),
        ("named", Some(true)),
    ] {
        let target = seed(&fixture, &path, branch, socket);
        let authority = target.ready(&fixture);
        if let Some(kwt_socket) = socket {
            workspace_tmux(
                &fixture,
                kwt_socket,
                &["kill-session", "-t", target.worktree.session_name()],
            );
        }
        start_workspace_session(
            &fixture,
            socket.unwrap_or(false),
            target.worktree.session_name(),
            target.worktree.path(),
            target.worktree.generation(),
        );
        target.confirm(&fixture, authority).unwrap();
        let _message = failure(&fixture, authority);
        assert!(Path::new(target.worktree.path()).is_dir());
        workspace_tmux(
            &fixture,
            socket.unwrap_or(false),
            &["has-session", "-t", target.worktree.session_name()],
        );
    }
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn remote_removal_rejects_replaced_checkouts_registrations_and_connections() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::remote_removal_rejects_replaced_checkouts_registrations_and_connections",
    ) else {
        return;
    };
    let path = project(&fixture);
    let target = seed(&fixture, &path, "replacement", None);
    let authority = target.ready(&fixture);
    remote_kwt_in(
        path.to_str().unwrap(),
        &[
            "remove",
            "--if-generation",
            target.worktree.generation().unwrap(),
            target.worktree.path(),
        ],
    );
    remote_kwt_in(
        path.to_str().unwrap(),
        &["add", "replacement", "--no-launch"],
    );
    target.confirm(&fixture, authority).unwrap();
    assert!(failure(&fixture, authority).contains("worktree changed"));
    assert!(Path::new(target.worktree.path()).is_dir());
    fixture.connect();
    wait_kwt_ready(&fixture);
    let replacement = Target::current(&fixture, "replacement");
    assert_ne!(
        replacement.worktree.generation(),
        target.worktree.generation()
    );
    let authority = replacement.ready(&fixture);
    remote_kwt(&[
        "projects",
        "remove",
        path.to_str().unwrap(),
        "--expected-repository",
        replacement.project.repository(),
        "--expected-registration",
        replacement.project.registration_fingerprint(),
        "--json",
    ]);
    remote_kwt(&["projects", "add", path.to_str().unwrap(), "--json"]);
    replacement.confirm(&fixture, authority).unwrap();
    assert!(failure(&fixture, authority).contains("registration changed"));
    fixture.connect();
    wait_kwt_ready(&fixture);
    let target = Target::current(&fixture, "replacement");
    let authority = target.ready(&fixture);
    fixture.connect();
    wait_kwt_ready(&fixture);
    assert!(target.confirm(&fixture, authority).is_err());
    assert!(Path::new(target.worktree.path()).is_dir());
    assert!(path.join(".git").is_dir());
    fixture.workspace.close();
}

fn block_probe(fixture: &Fixture, after: u32) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = fixture.root.join("removal-probe");
    std::fs::create_dir_all(&bin).unwrap();
    let probe = bin.join("sha256sum");
    std::fs::write(&probe, format!("#!/bin/sh\ncount=$(cat \"$HOME/removal-count\" 2>/dev/null || echo 0)\ncount=$((count + 1))\nprintf '%s' \"$count\" > \"$HOME/removal-count\"\nif [ \"$count\" = {after} ]; then\n : > \"$HOME/removal-started\"\n while [ ! -e \"$HOME/removal-release\" ]; do sleep .02; done\nfi\nexec /usr/bin/sha256sum \"$@\"\n")).unwrap();
    std::fs::set_permissions(&probe, std::fs::Permissions::from_mode(0o700)).unwrap();
    let profile = fixture.root.join("home/.profile");
    let contents = std::fs::read_to_string(&profile).unwrap_or_default();
    std::fs::write(
        profile,
        format!("{contents}\nexport PATH='{}':\"$PATH\"\n", bin.display()),
    )
    .unwrap();
    fixture.root.join("home/removal-release")
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn reconnect_cancels_removal_before_the_final_helper_command() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::reconnect_cancels_removal_before_the_final_helper_command",
    ) else {
        return;
    };
    let path = project(&fixture);
    let target = seed(&fixture, &path, "reconnect", None);
    let authority = target.ready(&fixture);
    // Block provisioning for remove, after inventory and the clean inspection.
    let release = block_probe(&fixture, 3);
    target.confirm(&fixture, authority).unwrap();
    fixture.wait(|_| fixture.root.join("home/removal-started").exists());
    fixture.workspace.connect_host(&fixture.host_id).unwrap();
    std::fs::write(release, "").unwrap();
    let _message = failure(&fixture, authority);
    assert!(Path::new(target.worktree.path()).is_dir());
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn removal_preserves_navigation_queued_during_preflight() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::removal_preserves_navigation_queued_during_preflight",
    ) else {
        return;
    };
    let path = project(&fixture);
    let target = seed(&fixture, &path, "navigation", Some(false));
    let other = fixture.open_scene();
    other
        .workspace
        .switch_session(&target.selection(&fixture))
        .unwrap();
    other.tmux_shell(target.worktree.session_name(), "before-remove-navigation");
    let authority = target.ready(&fixture);
    let release = block_probe(&fixture, 1);
    target.confirm(&fixture, authority).unwrap();
    fixture.wait(|_| fixture.root.join("home/removal-started").exists());
    other
        .workspace
        .switch_session(&SessionSelection::new(
            &fixture.host_id,
            &fixture.endpoint,
            "review",
        ))
        .unwrap();
    std::fs::write(release, "").unwrap();
    assert!(matches!(
        wait_worktree_event(&fixture, authority),
        WorkspaceEvent::KwtWorktreeRemoved { .. }
    ));
    other.tmux_shell("review", "after-remove-navigation");
    assert!(!Path::new(target.worktree.path()).exists());
    other.workspace.close();
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn cancelling_and_closing_removal_releases_the_operation_lane() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::cancelling_and_closing_removal_releases_the_operation_lane",
    ) else {
        return;
    };
    let path = project(&fixture);
    let target = seed(&fixture, &path, "cancel", Some(false));
    let release = block_probe(&fixture, 1);
    let authority = target.request(&fixture);
    fixture.wait(|_| fixture.root.join("home/removal-started").exists());
    fixture.workspace.cancel_kwt_worktree_removal();
    let _message = failure(&fixture, authority);
    assert!(target.confirm(&fixture, authority).is_err());
    std::fs::write(&release, "").unwrap();
    let other = fixture.open_scene();
    let authority = target.ready(&other);
    std::fs::remove_file(&release).unwrap();
    std::fs::remove_file(fixture.root.join("home/removal-started")).unwrap();
    std::fs::remove_file(fixture.root.join("home/removal-count")).unwrap();
    target.confirm(&other, authority).unwrap();
    fixture.wait(|_| fixture.root.join("home/removal-started").exists());
    other.workspace.close();
    fixture.wait(|s| {
        s.hosts()
            .iter()
            .any(|h| h.id() == fixture.host_id && !h.kwt_mutating())
    });
    std::fs::write(release, "").unwrap();
    assert!(Path::new(target.worktree.path()).is_dir());
    fixture
        .workspace
        .switch_session(&target.selection(&fixture))
        .unwrap();
    fixture.tmux_shell(target.worktree.session_name(), "after-cancelled-removal");
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn removal_keeps_a_same_named_session_on_the_other_server() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::removal_keeps_a_same_named_session_on_the_other_server",
    ) else {
        return;
    };
    let path = project(&fixture);
    let target = seed(&fixture, &path, "two-servers", Some(true));
    let authority = target.ready(&fixture);
    fixture.tmux(&[
        "new-session",
        "-d",
        "-s",
        target.worktree.session_name(),
        "/bin/sh",
    ]);
    target.confirm(&fixture, authority).unwrap();
    assert!(failure(&fixture, authority).contains("session started after confirmation"));
    fixture.tmux(&[
        "has-session",
        "-t",
        &format!("={}", target.worktree.session_name()),
    ]);
    assert!(Path::new(target.worktree.path()).is_dir());
    fixture.workspace.close();
}
