use super::*;

fn result(fixture: &Fixture, id: u64) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        for event in fixture.workspace.drain_events().0 {
            match event {
                WorkspaceEvent::SessionRenamed {
                    operation_id,
                    result,
                    ..
                } if operation_id == id => return result,
                WorkspaceEvent::Error(error) => panic!("{error}"),
                _ => {}
            }
        }
        assert!(Instant::now() < deadline, "rename did not settle");
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn rename_preserves_active_and_retained_ssh_clients() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::rename::rename_preserves_active_and_retained_ssh_clients")
    else {
        return;
    };
    fixture.tmux(&["new-session", "-d", "-s", "other", "/bin/sh"]);
    fixture.connect();
    super::kwt::wait_kwt_ready(&fixture);
    fixture.attach("review", "before-rename");
    let other = fixture.workspace.open_scene();
    other.select_host(&fixture.host_id).unwrap();
    other
        .switch_session(&SessionSelection::new(
            &fixture.host_id,
            &fixture.endpoint,
            "review",
        ))
        .unwrap();
    fixture.wait(|_| matches!(other.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "review"));
    other
        .switch_session(&SessionSelection::new(
            &fixture.host_id,
            &fixture.endpoint,
            "other",
        ))
        .unwrap();
    fixture.wait(|_| matches!(other.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "other")
        && fixture.tmux(&["display-message", "-p", "-t", "=other:", "#{session_attached}"]) == "1");
    let clients = fixture.tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"]);
    let identity = fixture.tmux(&[
        "display-message",
        "-p",
        "-t",
        "=review:",
        "#{pid}:#{session_id}:#{session_created}",
    ]);
    let selection = SessionSelection::new(&fixture.host_id, &fixture.endpoint, "review");
    let request = fixture
        .workspace
        .session_rename_request(&selection)
        .unwrap();
    let before_order = workspace::session_order_id(&selection);
    let name = "-release 'one";
    let stale_order = workspace::session_order_id(&SessionSelection::new(
        &fixture.host_id,
        &fixture.endpoint,
        name,
    ));
    fixture
        .workspace
        .update_sidebar(|sidebar| {
            sidebar.session_order = vec![stale_order.clone(), before_order.clone()];
        })
        .unwrap();
    fixture.workspace.rename_session(&request, name).unwrap();
    result(&fixture, request.id()).unwrap();
    assert_eq!(
        fixture.workspace.configured_sidebar().session_order,
        vec![workspace::session_order_id(&SessionSelection::new(
            &fixture.host_id,
            &fixture.endpoint,
            name
        ))]
    );
    fixture.tmux_shell(name, "after-rename");
    assert_eq!(
        fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            &format!("={name}:"),
            "#{pid}:#{session_id}:#{session_created}"
        ]),
        identity
    );
    assert_eq!(
        fixture.tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"]),
        clients
    );
    other
        .switch_session(&SessionSelection::new(
            &fixture.host_id,
            &fixture.endpoint,
            name,
        ))
        .unwrap();
    fixture.wait(|_| matches!(other.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == name));
    assert_eq!(
        fixture.tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"]),
        clients
    );
    other.close();
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn rename_refuses_an_ssh_session_that_reuses_the_reviewed_name() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::rename::rename_refuses_an_ssh_session_that_reuses_the_reviewed_name",
    ) else {
        return;
    };
    fixture.connect();
    super::kwt::wait_kwt_ready(&fixture);
    let request = fixture
        .workspace
        .session_rename_request(&SessionSelection::new(
            &fixture.host_id,
            &fixture.endpoint,
            "review",
        ))
        .unwrap();
    fixture.tmux(&["rename-session", "-t", "=review:", "original"]);
    fixture.tmux(&["new-session", "-d", "-s", "review", "/bin/sh"]);
    let replacement = fixture.tmux(&["display-message", "-p", "-t", "=review:", "#{session_id}"]);
    fixture.workspace.rename_session(&request, "wrong").unwrap();
    assert!(result(&fixture, request.id()).is_err());
    assert_eq!(
        fixture.tmux(&["display-message", "-p", "-t", "=review:", "#{session_id}"]),
        replacement
    );
    assert!(
        fixture
            .tmux(&["list-sessions", "-F", "#{session_name}"])
            .lines()
            .all(|name| name != "wrong")
    );
    fixture.workspace.close();
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn rename_requires_a_new_dialog_after_ssh_reconnect() {
    let Some(fixture) =
        Fixture::isolated("native_ssh::rename::rename_requires_a_new_dialog_after_ssh_reconnect")
    else {
        return;
    };
    fixture.connect();
    super::kwt::wait_kwt_ready(&fixture);
    let request = fixture
        .workspace
        .session_rename_request(&SessionSelection::new(
            &fixture.host_id,
            &fixture.endpoint,
            "review",
        ))
        .unwrap();
    fixture.connect();
    super::kwt::wait_kwt_ready(&fixture);
    fixture
        .workspace
        .session_rename_validation(&request, "wrong")
        .expect("current inventory and workspace ownership allow this name");
    let error = fixture
        .workspace
        .rename_session(&request, "wrong")
        .unwrap_err();
    assert!(
        error.to_string().contains("SSH connection changed"),
        "{error}"
    );
    assert!(
        fixture
            .tmux(&["list-sessions", "-F", "#{session_name}"])
            .lines()
            .any(|name| name == "review")
    );
    fixture.workspace.close();
}
