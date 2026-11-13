use super::*;

fn ssh_only_workspace() -> Workspace {
    let roots = config::ApplicationConfig::current_roots().unwrap();
    let settings = config::ApplicationConfig::load(&roots).unwrap();
    let controller = super::super::activate_bundled_kwt_controller(Path::new(&roots.helpers))
        .unwrap()
        .unwrap();
    let ssh = host::SshExecutable::system().unwrap();
    let configured = &settings.ssh_hosts()[0];
    let remote = host::RemoteTmuxConfig::new(
        configured.id(),
        configured.name(),
        host::SshTarget::new(
            configured.hostname(),
            configured.user().map(str::to_owned),
            configured.port(),
        )
        .unwrap(),
        configured.tmux_binary(),
        configured.socket_directory().map(str::to_owned),
    )
    .unwrap();
    Workspace::application_with_remote_hosts(
        settings.terminal().clone(),
        None,
        vec![workspace::RemoteHostSpec::available(
            remote,
            controller.clone(),
            ssh.clone(),
        )],
        settings,
        roots,
        Some(controller),
        Some(ssh),
        super::super::bundled_remote_kwt(),
    )
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn pane_hooks_are_scoped_to_the_remote_tmux_server() {
    let Some(mut fixture) =
        Fixture::isolated("native_ssh::attention::pane_hooks_are_scoped_to_the_remote_tmux_server")
    else {
        return;
    };
    fixture.workspace = ssh_only_workspace();
    assert_eq!(
        fixture.workspace.snapshot().hosts().len(),
        1,
        "SSH-only runtime"
    );
    fixture.workspace.start_inventory_cadence().unwrap();
    fixture.tmux(&[
        "set-option",
        "-p",
        "-t",
        "=review:",
        "@kwt_agent",
        "approval 100 codex",
    ]);
    super::kwt::workspace_tmux(
        &fixture,
        true,
        &["new-session", "-d", "-s", "review", "/bin/sh"],
    );
    super::kwt::workspace_tmux(
        &fixture,
        true,
        &[
            "set-option",
            "-p",
            "-t",
            "=review:",
            "@kwt_agent",
            "input 101 claude",
        ],
    );
    fixture.connect();
    fixture.workspace.set_inventory_polling_enabled(true);
    let snapshot = fixture.workspace.snapshot();
    let host = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap();
    assert_eq!(
        host.tmux_agent_activity("review", None).unwrap().label(),
        "Codex needs approval"
    );
    assert_eq!(
        host.tmux_agent_activity("review", Some("kwt"))
            .unwrap()
            .label(),
        "Claude is waiting for input"
    );
    assert!(host.tmux_agent_activity("review", Some("other")).is_none());

    fixture.attach("review", "attention-client");
    let clients = fixture.tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"]);
    fixture.tmux(&[
        "set-option",
        "-p",
        "-t",
        "=review:",
        "@kwt_agent",
        "working 102 codex",
    ]);
    fixture.wait(|snapshot| {
        snapshot
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .is_some_and(|host| {
                host.tmux_agent_activity("review", None)
                    .is_some_and(|activity| activity.label() == "Codex is working")
            })
    });
    assert_eq!(
        fixture.tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"]),
        clients
    );
    fixture.tmux(&[
        "set-option",
        "-p",
        "-t",
        "=review:",
        "@kwt_agent",
        "done 103 codex",
    ]);
    fixture.wait(|snapshot| {
        snapshot
            .hosts()
            .iter()
            .find(|host| host.id() == fixture.host_id)
            .is_some_and(|host| host.tmux_agent_activity("review", None).is_none())
    });
    super::kwt::workspace_tmux(&fixture, true, &["kill-server"]);
}
