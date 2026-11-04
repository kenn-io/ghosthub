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
    fixture.connect();
    wait_kwt_ready(&fixture);
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
    wait_kwt_ready(&fixture);
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
    open().unwrap();
    fixture.tmux_shell(name, "protected-open");
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
    fixture.workspace.detach();
    let displaced = fixture.root.join("displaced");
    std::fs::rename(row.path(), &displaced).unwrap();
    open().unwrap();
    fixture.wait_for_error("worktree identity changed");
    protected_tmux(&["has-session", "-t", &format!("={name}")]);
    fixture.workspace.close();
}
