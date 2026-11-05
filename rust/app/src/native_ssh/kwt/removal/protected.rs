use super::*;

fn imported(fixture: &Fixture) -> Target {
    let (project, worktree) = super::super::protected::imported_worktree(fixture);
    Target { project, worktree }
}

fn tmux(target: &Target, args: &[&str]) -> std::process::Output {
    Command::new("/usr/bin/tmux")
        .env_remove("TMUX_TMPDIR")
        .args(["-L", target.worktree.tmux_socket_name().unwrap()])
        .args(args)
        .output()
        .unwrap()
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn removes_a_running_protected_worktree_after_explicit_force_review() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::protected::removes_a_running_protected_worktree_after_explicit_force_review",
    ) else {
        return;
    };
    let target = imported(&fixture);
    let name = target.worktree.session_name();
    let other = fixture.open_scene();
    // Removal is available from inventory without an opened client in this scene.
    other
        .workspace
        .switch_session(&target.selection(&fixture))
        .unwrap();
    other.tmux_shell(name, "protected-before-removal");
    fixture.tmux(&["new-session", "-d", "-s", "keep-default", "/bin/sh"]);
    workspace_tmux(
        &fixture,
        true,
        &["new-session", "-d", "-s", "keep-kwt", "/bin/sh"],
    );
    let authority = target.request(&fixture);
    assert!(matches!(
        wait_worktree_event(&fixture, authority),
        WorkspaceEvent::KwtWorktreeRemovalReady {
            session_was_running: true,
            force_required: false,
            ..
        }
    ));
    let dirty = Path::new(target.worktree.path()).join("unfinished.txt");
    std::fs::write(&dirty, "preserve until explicitly discarded\n").unwrap();
    target.confirm(&fixture, authority, false).unwrap();
    assert!(failure(&fixture, authority).contains("has changes"));
    other.tmux_shell(name, "protected-after-rejected-removal");

    let authority = target.request(&fixture);
    assert!(matches!(
        wait_worktree_event(&fixture, authority),
        WorkspaceEvent::KwtWorktreeRemovalReady {
            session_was_running: true,
            force_required: true,
            ..
        }
    ));
    assert!(target.confirm(&fixture, authority, false).is_err());
    fixture.workspace.cancel_kwt_worktree_removal();
    assert!(target.confirm(&fixture, authority, true).is_err());
    assert_eq!(
        std::fs::read_to_string(&dirty).unwrap(),
        "preserve until explicitly discarded\n"
    );
    other.tmux_shell(name, "protected-after-cancel");

    let authority = target.ready(&fixture);
    let other_authority = target.ready(&other);
    target.confirm(&fixture, authority, true).unwrap();
    match wait_worktree_event(&fixture, authority) {
        WorkspaceEvent::KwtWorktreeRemoved { .. } => {}
        WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } => panic!("{message}"),
        _ => panic!("unexpected removal event"),
    }
    assert!(!Path::new(target.worktree.path()).exists());
    assert!(
        Command::new("git")
            .current_dir(target.project.path())
            .args(["show-ref", "--quiet", "--verify", "refs/heads/pr-17"])
            .status()
            .unwrap()
            .success()
    );
    assert!(
        !tmux(&target, &["has-session", "-t", &format!("={name}")])
            .status
            .success()
    );
    fixture.tmux(&["has-session", "-t", "=keep-default"]);
    workspace_tmux(&fixture, true, &["has-session", "-t", "=keep-kwt"]);
    other.wait(|snapshot| snapshot.active_selection().is_none());
    assert!(target.confirm(&other, other_authority, true).is_err());
    assert!(
        !fixture
            .workspace
            .snapshot()
            .hosts()
            .iter()
            .flat_map(workspace::HostItem::projects)
            .flat_map(workspace::ProjectItem::worktrees)
            .any(|row| row.path() == target.worktree.path())
    );
    fixture.workspace.close();
    other.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn idle_protected_removal_rejects_a_session_started_after_confirmation() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::protected::idle_protected_removal_rejects_a_session_started_after_confirmation",
    ) else {
        return;
    };
    let target = imported(&fixture);
    let name = target.worktree.session_name();
    let authority = target.request(&fixture);
    assert!(matches!(
        wait_worktree_event(&fixture, authority),
        WorkspaceEvent::KwtWorktreeRemovalReady {
            session_was_running: false,
            force_required: false,
            ..
        }
    ));
    assert!(
        tmux(&target, &["new-session", "-d", "-s", name, "/bin/sh"])
            .status
            .success()
    );
    target.confirm(&fixture, authority, false).unwrap();
    assert!(failure(&fixture, authority).contains("session started after confirmation"));
    assert!(Path::new(target.worktree.path()).is_dir());
    assert!(
        tmux(&target, &["has-session", "-t", &format!("={name}")])
            .status
            .success()
    );

    // Keep the named server alive without the target session for the next capture.
    assert!(
        tmux(&target, &["new-session", "-d", "-s", "sentinel", "/bin/sh"])
            .status
            .success()
    );
    assert!(
        tmux(&target, &["kill-session", "-t", &format!("={name}")])
            .status
            .success()
    );
    // A shared-server session cannot be killed through protected confirmation.
    fixture.tmux(&["new-session", "-d", "-s", name, "/bin/sh"]);
    let authority = target.ready(&fixture);
    target.confirm(&fixture, authority, false).unwrap();
    assert!(failure(&fixture, authority).contains("session started after confirmation"));
    assert!(Path::new(target.worktree.path()).is_dir());
    fixture.tmux(&["has-session", "-t", &format!("={name}")]);
    fixture.tmux(&["rename-session", "-t", &format!("={name}"), "keep-default"]);
    let authority = target.request(&fixture);
    assert!(matches!(
        wait_worktree_event(&fixture, authority),
        WorkspaceEvent::KwtWorktreeRemovalReady {
            session_was_running: false,
            ..
        }
    ));
    fixture.workspace.cancel_kwt_worktree_removal();
    // KWT requires a dedicated protected server for removal; leave the
    // unrelated session untouched until the fixture explicitly stops it.
    assert!(
        tmux(&target, &["has-session", "-t", "=sentinel"])
            .status
            .success()
    );
    assert!(
        tmux(&target, &["kill-session", "-t", "=sentinel"])
            .status
            .success()
    );
    let authority = target.ready(&fixture);
    target.confirm(&fixture, authority, false).unwrap();
    match wait_worktree_event(&fixture, authority) {
        WorkspaceEvent::KwtWorktreeRemoved { .. } => {}
        WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } => panic!("{message}"),
        _ => panic!("unexpected removal event"),
    }
    assert!(!Path::new(target.worktree.path()).exists());
    fixture.tmux(&["has-session", "-t", "=keep-default"]);
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn protected_removal_rejects_a_replacement_session() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::removal::protected::protected_removal_rejects_a_replacement_session",
    ) else {
        return;
    };
    let target = imported(&fixture);
    let name = target.worktree.session_name();
    fixture
        .workspace
        .switch_session(&target.selection(&fixture))
        .unwrap();
    fixture.tmux_shell(name, "before-replacement");
    let authority = target.ready(&fixture);
    assert!(
        tmux(&target, &["new-session", "-d", "-s", "sentinel", "/bin/sh"])
            .status
            .success()
    );
    assert!(
        tmux(&target, &["kill-session", "-t", &format!("={name}")])
            .status
            .success()
    );
    assert!(
        tmux(&target, &["new-session", "-d", "-s", name, "/bin/sh"])
            .status
            .success()
    );
    target.confirm(&fixture, authority, false).unwrap();
    assert!(!failure(&fixture, authority).is_empty());
    assert!(Path::new(target.worktree.path()).is_dir());
    assert!(
        tmux(&target, &["has-session", "-t", &format!("={name}")])
            .status
            .success()
    );
    fixture.workspace.close();
}
