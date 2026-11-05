use super::*;

#[test]
#[ignore = "requires GitHub authentication and OpenSSH; run make rust-test-ssh-pr-live"]
#[allow(clippy::too_many_lines)] // One real provider import through listing, idempotence, and protected attachment.
fn imports_pull_requests_over_ssh() {
    let Some(root) = std::env::var_os("GHOSTHUB_SSH_FIXTURE") else {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let result = Command::new("/bin/sh")
            .arg(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../tools/run_rust_ssh_fixture.sh"
            ))
            .env("GHOSTHUB_SSH_PR_TEST_PORT", port.to_string())
            .arg(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "native_ssh::kwt::pull_request::imports_pull_requests_over_ssh",
                "--ignored",
                "--nocapture",
            ])
            .status()
            .unwrap();
        assert!(result.success());
        return;
    };
    let fixture = Fixture::new(root.into());
    let project_path = fixture.root.join("hello 'world'");
    let clone = Command::new("git")
        .args([
            "clone",
            "--quiet",
            "https://github.com/octocat/Hello-World.git",
        ])
        .arg(&project_path)
        .output()
        .unwrap();
    assert!(clone.status.success(), "{clone:?}");
    fixture.connect();
    wait_kwt_ready(&fixture);
    let path = project_path.to_str().unwrap();
    fixture
        .workspace
        .add_kwt_project(&fixture.host_id, &fixture.endpoint, path)
        .unwrap();
    wait_mutation(&fixture).unwrap();
    let snapshot = fixture.workspace.snapshot();
    let project = &snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap()
        .projects()[0];
    // Listing failures belong to this dialog; they must not disconnect the host.
    let profile = fixture.root.join("home/.profile");
    let authenticated_profile = std::fs::read(&profile).unwrap();
    std::fs::write(&profile, "").unwrap();
    let unavailable = fixture
        .workspace
        .load_kwt_pull_requests(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            path,
            project.registration_fingerprint(),
        )
        .unwrap();
    assert!(matches!(wait_worktree_event(&fixture, unavailable),
        WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } if message.contains("GitHub authentication")
    ));
    assert_eq!(
        fixture
            .workspace
            .snapshot()
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .unwrap()
            .connection(),
        HostConnectionState::Ready
    );
    std::fs::write(&profile, authenticated_profile).unwrap();
    let listing = fixture
        .workspace
        .load_kwt_pull_requests(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            path,
            project.registration_fingerprint(),
        )
        .unwrap();
    let event = wait_worktree_event(&fixture, listing);
    let WorkspaceEvent::KwtPullRequestsLoaded { pull_requests, .. } = event else {
        if let WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } = event {
            panic!("{message}");
        }
        panic!("unexpected worktree event");
    };
    assert!(
        !pull_requests.is_empty(),
        "public fixture repository has open PRs"
    );
    assert!(pull_requests.iter().all(|pr| {
        pr.url()
            .starts_with("https://github.com/octocat/Hello-World/pull/")
    }));
    let mut previous: Option<workspace::KwtWorktreeTarget> = None;
    for selector in ["https://github.com/octocat/Hello-World/pull/1", "1"] {
        let operation = fixture
            .workspace
            .import_kwt_pull_request(
                &fixture.host_id,
                &fixture.endpoint,
                project.repository(),
                path,
                project.registration_fingerprint(),
                selector,
            )
            .unwrap();
        let event = wait_worktree_event(&fixture, operation);
        let WorkspaceEvent::KwtWorktreeCreated { target, .. } = event else {
            if let WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } = event {
                panic!("{message}");
            }
            panic!("unexpected worktree event");
        };
        assert_eq!(
            target.tmux_attach_mode(),
            host::KwtTmuxAttachMode::Protected
        );
        if let Some(first) = &previous {
            assert_eq!(target.worktree_path(), first.worktree_path());
            assert_eq!(target.generation(), first.generation());
        }
        fixture
            .workspace
            .open_kwt_worktree(
                target.host_id(),
                target.endpoint(),
                target.repository(),
                target.project_path(),
                target.registration_fingerprint(),
                target.worktree_path(),
                target.generation(),
                target.session_name(),
                target.tmux_socket_name(),
                target.tmux_attach_mode(),
            )
            .unwrap();
        fixture.tmux_shell(target.session_name(), "imported-over-ssh");
        fixture.workspace.detach();
        wait_kwt_ready(&fixture);
        previous = Some(target);
    }
    // Re-register outside the app while it still holds the old project identity.
    let target = previous.unwrap();
    let server = Command::new("/usr/bin/tmux")
        .env_remove("TMUX_TMPDIR")
        .args([
            "-L",
            target.tmux_socket_name().unwrap(),
            "display-message",
            "-p",
            "#{pid}",
        ])
        .output()
        .unwrap();
    assert!(server.status.success(), "{server:?}");
    let process = Path::new("/proc").join(String::from_utf8(server.stdout).unwrap().trim());
    let stopped = Command::new("/usr/bin/tmux")
        .env_remove("TMUX_TMPDIR")
        .args(["-L", target.tmux_socket_name().unwrap(), "kill-server"])
        .output()
        .unwrap();
    assert!(stopped.status.success(), "{stopped:?}");
    let deadline = Instant::now() + Duration::from_secs(30);
    while process.exists() {
        assert!(Instant::now() < deadline, "protected server did not exit");
        thread::sleep(Duration::from_millis(20));
    }
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
    let stale = fixture
        .workspace
        .import_kwt_pull_request(
            &fixture.host_id,
            &fixture.endpoint,
            project.repository(),
            path,
            project.registration_fingerprint(),
            "1",
        )
        .unwrap();
    assert!(matches!(wait_worktree_event(&fixture, stale),
        WorkspaceEvent::KwtWorktreeOperationFailed { message, .. } if message.contains("project changed")
    ));
    fixture.workspace.close();
}
