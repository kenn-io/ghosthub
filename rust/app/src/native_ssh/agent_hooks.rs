use std::fmt::Write as _;

use super::*;
use workspace::{AgentHookAction, AgentHookStatus};

fn result(fixture: &Fixture, id: u64) -> Result<Vec<AgentHookStatus>, String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        for event in fixture.workspace.drain_events().0 {
            match event {
                WorkspaceEvent::AgentHooksFinished {
                    operation_id,
                    result,
                    ..
                } if operation_id == id => return result,
                WorkspaceEvent::Error(error) => panic!("unexpected application error: {error}"),
                _ => {}
            }
        }
        assert!(
            Instant::now() < deadline,
            "agent hook request did not settle"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

fn hooks(fixture: &Fixture, host_id: &str, action: AgentHookAction) -> Vec<AgentHookStatus> {
    let id = fixture.workspace.agent_hooks(host_id, action).unwrap();
    result(fixture, id).unwrap()
}

fn claude(statuses: &[AgentHookStatus]) -> &AgentHookStatus {
    statuses
        .iter()
        .find(|status| status.agent == "claude")
        .unwrap()
}

#[test]
#[ignore = "requires pinned helpers and isolated OpenSSH; run make rust-test-ssh-live"]
fn hook_setup_uses_the_selected_account_and_keeps_errors_out_of_host_inventory() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::agent_hooks::hook_setup_uses_the_selected_account_and_keeps_errors_out_of_host_inventory",
    ) else {
        return;
    };
    let local = PathBuf::from(std::env::var_os("HOME").unwrap()).join(".claude");
    let remote_home = fixture.root.join("remote-agent-account");
    let remote = remote_home.join(".claude");
    for path in [&local, &remote] {
        std::fs::create_dir_all(path).unwrap();
    }
    let original = br#"{"theme":"fixture","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo keep-existing-hook"}]}]}}"#;
    for path in [&local, &remote] {
        std::fs::write(path.join("settings.json"), original).unwrap();
    }
    // SSH's login profile selects a different account configuration from the GUI.
    let profile = fixture.root.join("home/.profile");
    let mut contents = std::fs::read_to_string(&profile).unwrap();
    write!(contents, "\nexport HOME='{}'\n", remote_home.display()).unwrap();
    std::fs::write(profile, contents).unwrap();
    fixture.workspace.connect_host("local").unwrap();
    fixture.connect();
    fixture.wait(|snapshot| {
        snapshot
            .hosts()
            .iter()
            .any(|host| host.id() == "local" && host.connection() == HostConnectionState::Ready)
    });
    super::kwt::wait_kwt_ready(&fixture);
    fixture.attach("review", "hooks-before");
    let clients = fixture.tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"]);

    for id in ["local", fixture.host_id.as_str()] {
        let statuses = hooks(&fixture, id, AgentHookAction::Status);
        assert!(claude(&statuses).available);
        assert!(!claude(&statuses).installed);
        assert!(!claude(&statuses).current);
    }
    assert_eq!(
        std::fs::read(local.join("settings.json")).unwrap(),
        original
    );
    assert!(claude(&hooks(&fixture, "local", AgentHookAction::Install)).current);
    assert_eq!(
        std::fs::read(remote.join("settings.json")).unwrap(),
        original,
        "local setup must not edit the SSH account"
    );
    assert!(claude(&hooks(&fixture, &fixture.host_id, AgentHookAction::Install)).current);
    for id in ["local", fixture.host_id.as_str()] {
        assert!(claude(&hooks(&fixture, id, AgentHookAction::Status)).current);
    }
    for path in [&local, &remote] {
        let bytes = std::fs::read(path.join("settings.json")).unwrap();
        let config: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(config["theme"], "fixture");
        assert!(
            String::from_utf8(bytes)
                .unwrap()
                .contains("echo keep-existing-hook")
        );
    }
    let installed = std::fs::read(remote.join("settings.json")).unwrap();
    std::fs::write(remote.join("settings.json"), b"invalid JSON").unwrap();
    let request = fixture
        .workspace
        .agent_hooks(&fixture.host_id, AgentHookAction::Status)
        .unwrap();
    assert!(result(&fixture, request).is_err());
    let snapshot = fixture.workspace.snapshot();
    let host = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == fixture.host_id)
        .unwrap();
    assert_eq!(host.connection(), HostConnectionState::Ready);
    assert!(host.kwt_diagnostic().is_none());
    std::fs::write(remote.join("settings.json"), installed).unwrap();
    assert!(claude(&hooks(&fixture, &fixture.host_id, AgentHookAction::Status)).current);
    assert_eq!(
        fixture.tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"]),
        clients
    );
    fixture.tmux_shell("review", "hooks-after");
}
