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
    let output = Command::new("tmux")
        .env("TMUX_TMPDIR", fixture.root.join("tmux"))
        .args(["new-session", "-d", "-s", name, "/bin/sh"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    for (option, value) in [
        (
            "@kwt-workspace-id",
            format!("{:x}", Sha256::digest(worktree.path().as_bytes())),
        ),
        (
            "@kwt-workspace-generation",
            worktree.generation().unwrap().to_owned(),
        ),
    ] {
        let output = Command::new("tmux")
            .env("TMUX_TMPDIR", fixture.root.join("tmux"))
            .args(["set-option", "-t", name, option, &value])
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
    }
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
