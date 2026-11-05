use std::os::unix::fs::PermissionsExt;

use super::*;

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
#[allow(clippy::too_many_lines)] // One imported checkout through launch, retention, detach, and stale identity.
fn opens_imported_worktrees_through_protected_ssh_attachment() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::protected::opens_imported_worktrees_through_protected_ssh_attachment",
    ) else {
        return;
    };
    // Hold creation until readiness has observed the server without its target session.
    // Both commands still execute real tmux on the protected socket.
    let wrapper = fixture.root.join("tmux-bin/tmux");
    std::fs::create_dir(wrapper.parent().unwrap()).unwrap();
    std::fs::write(
        &wrapper,
        r#"#!/bin/sh
if test -e "$HOME/delay-protected-session"; then
    case " $* " in
        *" new-session "*)
            socket=$(cat "$HOME/protected-socket")
            env -u TMUX_TMPDIR /usr/bin/tmux -L "$socket" -f /dev/null start-server \; set-option -s exit-empty off || exit
            touch "$HOME/creating-protected-session"
            while ! test -e "$HOME/probed-protected-session"; do sleep 0.02; done
            rm -f "$HOME/delay-protected-session"
            ;;
        *" list-clients "*)
            if test -e "$HOME/creating-protected-session"; then
                /usr/bin/tmux "$@"
                result=$?
                touch "$HOME/probed-protected-session"
                exit "$result"
            fi
            ;;
    esac
fi
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
    let (project, row) = imported_worktree(&fixture);
    let path = project.path();
    let sentinel = fixture.root.join("layout-ran");
    std::fs::write(
        Path::new(row.path()).join(".kwt.toml"),
        format!(
            "[layouts]\ndefault = 'review'\n[[layouts.presets]]\nname = 'review'\npanes = ['touch {}']\n",
            sentinel.display()
        ),
    )
    .unwrap();
    assert_eq!(row.tmux_attach_mode(), host::KwtTmuxAttachMode::Protected);
    let socket = row.tmux_socket_name().expect("resolved protected socket");
    let name = row.session_name();
    let selection = SessionSelection::kwt_workspace(
        &fixture.host_id,
        &fixture.endpoint,
        name,
        row.tmux_attach_mode(),
        Some(socket.to_owned()),
        row.path(),
        row.generation().map(str::to_owned),
    );
    let open = || {
        fixture.workspace.open_kwt_worktree(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            path,
            project.registration_fingerprint(),
            row.path(),
            row.generation(),
            name,
            Some(socket),
            row.tmux_attach_mode(),
        )
    };
    fixture.tmux(&["new-session", "-d", "-s", name, "/bin/sh"]);
    let original = fixture.tmux(&[
        "display-message",
        "-p",
        "-t",
        &format!("={name}"),
        "#{pid}:#{session_id}",
    ]);
    let protected_tmux = |args: &[&str]| {
        let output = Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args(["-L", socket])
            .args(args)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        String::from_utf8(output.stdout).unwrap().trim().to_owned()
    };
    std::fs::write(fixture.root.join("home/protected-socket"), socket).unwrap();
    std::fs::write(fixture.root.join("home/delay-protected-session"), "").unwrap();
    open().unwrap();
    fixture.tmux_shell(name, "protected-open");
    assert!(fixture.root.join("home/probed-protected-session").exists());
    assert!(!sentinel.exists(), "imported checkout layout executed");
    let presentation = |workspace: &Workspace| match workspace.snapshot().content() {
        WorkspaceContent::Terminal {
            presentation_id, ..
        } => *presentation_id,
        _ => panic!("expected terminal"),
    };
    let first = presentation(&fixture.workspace);
    assert_eq!(
        fixture.workspace.snapshot().active_selection(),
        Some(&selection)
    );
    fixture.workspace.switch_session(&selection).unwrap();
    assert_eq!(presentation(&fixture.workspace), first);
    fixture.attach("review", "unrelated-open");
    fixture.workspace.switch_session(&selection).unwrap();
    assert_eq!(presentation(&fixture.workspace), first);
    fixture.tmux_shell(name, "protected-retained");
    fixture.connect();
    wait_kwt_ready(&fixture);
    assert_eq!(presentation(&fixture.workspace), first);
    fixture.tmux_shell(name, "protected-refreshed");
    fixture.workspace.detach();
    protected_tmux(&["has-session", "-t", &format!("={name}")]);
    assert_eq!(
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            &format!("={name}"),
            "#{pid}:#{session_id}"
        ]),
        original
    );
    open().unwrap();
    fixture.tmux_shell(name, "protected-reopened");
    assert_ne!(presentation(&fixture.workspace), first);
    // Closing a second scene must detach its client without stopping either server.
    let second = fixture.workspace.open_scene();
    second.switch_session(&selection).unwrap();
    fixture.wait(|_| {
        matches!(
            second.snapshot().content(),
            WorkspaceContent::Terminal { .. }
        )
    });
    second.close();
    protected_tmux(&["has-session", "-t", &format!("={name}")]);
    let reopened = presentation(&fixture.workspace);
    let displaced = fixture.root.join("displaced");
    std::fs::rename(row.path(), &displaced).unwrap();
    fixture.connect();
    wait_kwt_ready(&fixture);
    assert!(fixture.workspace.snapshot().hosts().iter().all(|host| {
        host.projects().iter().all(|project| {
            project
                .worktrees()
                .iter()
                .all(|worktree| worktree.path() != row.path())
        })
    }));
    fixture.workspace.switch_session(&selection).unwrap();
    assert_eq!(presentation(&fixture.workspace), reopened);
    fixture.attach("review", "checkout-removed");
    fixture.workspace.switch_session(&selection).unwrap();
    assert_eq!(presentation(&fixture.workspace), reopened);
    fixture.tmux_shell(name, "retained-without-checkout");
    let different_generation = SessionSelection::kwt_workspace(
        &fixture.host_id,
        &fixture.endpoint,
        name,
        row.tmux_attach_mode(),
        Some(socket.to_owned()),
        row.path(),
        Some("replacement-checkout".to_owned()),
    );
    assert!(
        fixture
            .workspace
            .switch_session(&different_generation)
            .is_err()
    );
    assert_eq!(presentation(&fixture.workspace), reopened);
    std::fs::rename(&displaced, row.path()).unwrap();
    fixture.connect();
    wait_kwt_ready(&fixture);

    // Model registration removed outside Ghosthub. KWT's ordinary Remove Project
    // action rejects a project while one of its protected sessions is live.
    let config_path = fixture.root.join("home/.config/kwt/config.toml");
    let registered_config = std::fs::read(&config_path).unwrap();
    std::fs::write(&config_path, "projects = []\n").unwrap();
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
            .is_empty()
    );
    open().unwrap();
    assert_eq!(presentation(&fixture.workspace), reopened);
    fixture.attach("review", "project-unregistered");
    open().unwrap();
    assert_eq!(presentation(&fixture.workspace), reopened);
    fixture.tmux_shell(name, "retained-without-project");
    fixture.workspace.detach();
    assert!(fixture.workspace.switch_session(&selection).is_err());
    assert!(open().is_err());
    std::fs::write(&config_path, registered_config).unwrap();
    fixture.connect();
    wait_kwt_ready(&fixture);
    std::fs::rename(row.path(), &displaced).unwrap();
    open().unwrap();
    fixture.wait_for_error("worktree identity changed");
    protected_tmux(&["has-session", "-t", &format!("={name}")]);
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
#[allow(clippy::too_many_lines)] // One protected endpoint through confirmation, reconnect, and cross-scene cleanup.
fn kills_protected_sessions_without_touching_other_servers() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::protected::kills_protected_sessions_without_touching_other_servers",
    ) else {
        return;
    };
    let (project, row) = imported_worktree(&fixture);
    let socket = row.tmux_socket_name().unwrap();
    let name = row.session_name();
    let selection = SessionSelection::kwt_workspace(
        &fixture.host_id,
        &fixture.endpoint,
        name,
        row.tmux_attach_mode(),
        Some(socket.to_owned()),
        row.path(),
        row.generation().map(str::to_owned),
    );
    let protected = |args: &[&str]| {
        let output = Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args(["-L", socket])
            .args(args)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
    };
    fixture.tmux(&["new-session", "-d", "-s", name, "/bin/sh"]);
    let original = fixture.tmux(&[
        "display-message",
        "-p",
        "-t",
        &format!("={name}"),
        "#{pid}:#{session_id}",
    ]);
    fixture
        .workspace
        .open_kwt_worktree(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            project.path(),
            project.registration_fingerprint(),
            row.path(),
            row.generation(),
            name,
            Some(socket),
            row.tmux_attach_mode(),
        )
        .unwrap();
    fixture.tmux_shell(name, "protected-before-kill");
    // An arbitrary socket selection is not authority to kill a remote session.
    let invented = SessionSelection::kwt_workspace(
        &fixture.host_id,
        &fixture.endpoint,
        name,
        row.tmux_attach_mode(),
        Some("kwt-unopened".to_owned()),
        row.path(),
        row.generation().map(str::to_owned),
    );
    assert!(fixture.workspace.request_session_kill(&invented).is_err());
    let request = || {
        fixture.workspace.request_session_kill(&selection).unwrap();
        fixture.wait(|_| fixture.workspace.session_kill_confirmation().is_some());
    };
    request();
    fixture.workspace.cancel_session_kill();
    assert!(fixture.workspace.confirm_session_kill().is_err());
    fixture.tmux_shell(name, "protected-cancelled");

    request();
    fixture.connect();
    wait_kwt_ready(&fixture);
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait_for_error("SSH connection changed");
    fixture.tmux_shell(name, "protected-after-reconnect");
    let other = fixture.open_scene();
    other.workspace.switch_session(&selection).unwrap();
    other.tmux_shell(name, "second-window");
    other.workspace.request_session_kill(&selection).unwrap();
    other.wait(|_| other.workspace.session_kill_confirmation().is_some());
    protected(&["new-session", "-d", "-s", "sentinel", "/bin/sh"]);
    fixture.attach("review", "unrelated-active");
    // The retained protected client still owns its endpoint after unregistration.
    std::fs::write(
        fixture.root.join("home/.config/kwt/config.toml"),
        "projects = []\n",
    )
    .unwrap();
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
            .is_empty()
    );
    request();
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait(|snapshot| {
        snapshot
            .retained_selections()
            .iter()
            .all(|retained| retained != &selection)
            && other.workspace.snapshot().active_selection().is_none()
            && other.workspace.session_kill_confirmation().is_none()
    });
    let gone = Command::new("/usr/bin/tmux")
        .env_remove("TMUX_TMPDIR")
        .args(["-L", socket, "has-session", "-t", &format!("={name}")])
        .status()
        .unwrap();
    assert!(!gone.success());
    protected(&["has-session", "-t", "=sentinel"]);
    assert_eq!(
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            &format!("={name}"),
            "#{pid}:#{session_id}"
        ]),
        original
    );
    assert!(
        Path::new(row.path()).is_dir(),
        "Kill must preserve the checkout"
    );
    fixture.tmux_shell("review", "unrelated-survived");
    other.workspace.close();
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn protected_kill_rejects_a_replaced_session() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::kwt::protected::protected_kill_rejects_a_replaced_session")
    else {
        return;
    };
    let (project, row) = imported_worktree(&fixture);
    let socket = row.tmux_socket_name().unwrap();
    let name = row.session_name();
    fixture
        .workspace
        .open_kwt_worktree(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            project.path(),
            project.registration_fingerprint(),
            row.path(),
            row.generation(),
            name,
            Some(socket),
            row.tmux_attach_mode(),
        )
        .unwrap();
    fixture.tmux_shell(name, "before-replacement");
    let selection = fixture
        .workspace
        .snapshot()
        .active_selection()
        .unwrap()
        .clone();
    fixture.workspace.request_session_kill(&selection).unwrap();
    fixture.wait(|_| fixture.workspace.session_kill_confirmation().is_some());
    let protected = |args: &[&str]| {
        let output = Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args(["-L", socket])
            .args(args)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
    };
    // Keep the server alive so the replacement has a distinct session ID.
    protected(&["new-session", "-d", "-s", "sentinel", "/bin/sh"]);
    protected(&["kill-session", "-t", &format!("={name}")]);
    protected(&["new-session", "-d", "-s", name, "/bin/sh"]);
    fixture.workspace.confirm_session_kill().unwrap();
    fixture.wait_for_error("no longer matches");
    protected(&["has-session", "-t", &format!("={name}")]);
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn protected_kill_rejects_a_reused_name_before_confirmation() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::kwt::protected::protected_kill_rejects_a_reused_name_before_confirmation",
    ) else {
        return;
    };
    let (project, row) = imported_worktree(&fixture);
    let socket = row.tmux_socket_name().unwrap();
    let name = row.session_name();
    fixture
        .workspace
        .open_kwt_worktree(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            project.path(),
            project.registration_fingerprint(),
            row.path(),
            row.generation(),
            name,
            Some(socket),
            row.tmux_attach_mode(),
        )
        .unwrap();
    fixture.tmux_shell(name, "before-rename");
    let selection = fixture
        .workspace
        .snapshot()
        .active_selection()
        .unwrap()
        .clone();
    let protected = |args: &[&str]| {
        let output = Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args(["-L", socket])
            .args(args)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
    };
    protected(&[
        "rename-session",
        "-t",
        &format!("={name}"),
        "renamed-review",
    ]);
    protected(&["new-session", "-d", "-s", name, "/bin/sh"]);
    for retained in [false, true] {
        if retained {
            fixture.attach("review", "protected-retained");
        }
        fixture.workspace.request_session_kill(&selection).unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let mut rejected = false;
            for event in fixture.workspace.drain_events().0 {
                if let WorkspaceEvent::Error(message) = event {
                    assert!(message.contains("session changed"), "{message}");
                    rejected = true;
                }
            }
            assert!(
                fixture.workspace.session_kill_confirmation().is_none(),
                "Kill offered for a different session reusing the open terminal's name (retained={retained})"
            );
            if rejected {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "missing identity-change rejection"
            );
            thread::sleep(Duration::from_millis(20));
        }
        assert!(fixture.workspace.confirm_session_kill().is_err());
        protected(&["has-session", "-t", "=renamed-review"]);
        protected(&["has-session", "-t", &format!("={name}")]);
    }
    fixture.workspace.switch_session(&selection).unwrap();
    fixture
        .workspace
        .send_key(KeyInput::text(
            "printf 'renamed-%s\\n' still-running",
            Modifiers::default(),
        ))
        .unwrap();
    fixture
        .workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .unwrap();
    fixture.wait(|_| fixture.terminal_text().contains("renamed-still-running"));
    fixture.workspace.close();
}

fn imported_worktree(fixture: &Fixture) -> (workspace::ProjectItem, workspace::WorktreeItem) {
    fixture.connect();
    wait_kwt_ready(fixture);
    let project_path = fixture.root.join("orbit 'review'");
    create_project(&project_path);
    assert!(
        Command::new("git")
            .arg("-C")
            .arg(&project_path)
            .args([
                "remote",
                "set-url",
                "origin",
                "https://github.com/acme/orbit.git"
            ])
            .status()
            .unwrap()
            .success()
    );
    let path = project_path.to_str().unwrap();
    remote_kwt(&["projects", "add", path, "--json"]);
    remote_kwt_in(path, &["add", "--branch", "pr-17", "--no-launch"]);
    let inventory: serde_json::Value =
        serde_json::from_slice(&remote_kwt(&["list", "--global", "--json"])).unwrap();
    // Seed the pinned helper's persisted import format, as the Swift contract fixture does.
    // Discovery and attachment still execute the real helper over SSH.
    let projects: serde_json::Value =
        serde_json::from_slice(&remote_kwt(&["projects", "--json"])).unwrap();
    let project = &projects[0];
    let worktree = inventory
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["branch"] == "pr-17")
        .unwrap();
    let repository = project["repository"].as_str().unwrap();
    let mut worktree = worktree.clone();
    // An import resolves its protected socket; it does not inherit the ordinary server.
    worktree.as_object_mut().unwrap().remove("tmux_socket_name");
    worktree["id"] = serde_json::json!("fixture-pr-17");
    worktree["state"] = serde_json::json!("ready");
    let import_id = format!("github:{repository}#17");
    let provenance = serde_json::json!({
        "version": 1,
        "imports": {import_id.clone(): {
            "pull_request_id": import_id,
            "provider": "github", "repository": repository, "number": 17,
            "url": "https://example.invalid/pull/17", "head_sha": "a".repeat(40),
            "source_repository": repository, "source_branch": "pr-17",
            "project": {"identity": repository, "name": project["name"], "path": path}, "workspace": worktree
        }}
    });
    std::fs::create_dir_all(fixture.root.join("home/.config/kwt")).unwrap();
    std::fs::write(
        fixture.root.join("home/.config/kwt/pull-requests.json"),
        serde_json::to_vec(&provenance).unwrap(),
    )
    .unwrap();
    fixture.connect();
    wait_kwt_ready(fixture);
    let snapshot = fixture.workspace.snapshot();
    let project = &snapshot
        .hosts()
        .iter()
        .find(|h| h.id() == fixture.host_id)
        .unwrap()
        .projects()[0];
    let row = project
        .worktrees()
        .iter()
        .find(|row| row.branch() == "pr-17")
        .unwrap();
    (project.clone(), row.clone())
}
