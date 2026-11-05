use super::*;
use crate::tests::remote_kill_refresh_fixture;
use host::{CommandOutput, CommandRunner};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::ffi::{OsStr, OsString};
use std::io;
use std::sync::Mutex;
use std::time::Duration;

const PROJECTS: &str = r#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","registration_fingerprint":"registration"}]"#;
const WORKTREES: &str = r#"[{"repository":"github.com/acme/widget","branch":"pr-17","path":"/work/widget/pr-17","commit_hash":"abc","is_main":false,"generation":"checkout-17","session_name":"widget-pr-17","tmux_socket_name":"kwt-pr-17","tmux_attach_mode":"protected"}]"#;

fn receipt() -> Value {
    let repository = json!({"provider":"github", "identity":"github.com/acme/widget",
        "host":"github.com", "owner":"acme", "name":"widget"});
    let branch = json!({"branch":"main", "repository":repository, "is_fork":false});
    json!({
        "status":"created",
        "project":{"identity":"github.com/acme/widget", "name":"widget", "path":"/code/widget"},
        "workspace":{"id":"pr-17", "repository":"github.com/acme/widget", "branch":"pr-17",
            "path":"/work/widget/pr-17", "generation":"checkout-17", "state":"ready",
            "session_name":"widget-pr-17", "tmux_socket_name":"kwt-pr-17", "tmux_attach_mode":"protected"},
        "pull_request":{"id":"github:github.com/acme/widget#17", "provider":"github", "repository":repository,
            "number":17, "url":"https://github.com/acme/widget/pull/17", "title":"Improve rendering",
            "author":"octocat", "source":branch, "target":branch, "draft":false, "state":"open",
            "head_sha":"0123456789abcdef0123456789abcdef01234567", "imported":true}
    })
}

type Reply = (&'static str, io::Result<CommandOutput>);

#[allow(clippy::unnecessary_wraps)] // Scripted replies mix command results and transport failures.
fn output(status: i32, body: &str) -> io::Result<CommandOutput> {
    Ok(CommandOutput {
        status,
        stdout: body.as_bytes().to_vec(),
        stderr: Vec::new(),
    })
}

struct Runner(Mutex<VecDeque<Reply>>);

impl CommandRunner for Runner {
    fn run(
        &self,
        _: &OsStr,
        args: &[OsString],
        _: &host::CancellationToken,
        _: Duration,
    ) -> io::Result<CommandOutput> {
        let command = args.last().unwrap().to_str().unwrap();
        let marker = command
            .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
            .find(|word| word.starts_with("GHOSTHUB_KWT_") && word.contains("_BEGIN_"))
            .unwrap();
        let end = marker.replace("_BEGIN_", "_END_");
        let reply = if marker.starts_with("GHOSTHUB_KWT_TARGET_") {
            output(0, "Linux\nx86_64\n/home/fixture\n")?
        } else if marker.starts_with("GHOSTHUB_KWT_READY_") {
            output(0, "")?
        } else {
            assert!(marker.starts_with("GHOSTHUB_KWT_COMMAND_"));
            let (expected, result) = self
                .0
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected command or replay");
            assert!(command.contains(expected), "expected {expected}: {command}");
            result?
        };
        Ok(CommandOutput {
            status: 0,
            stdout: [
                format!("{marker}\n").as_bytes(),
                &reply.stdout,
                format!("{end}_STATUS_{}\n{end}\n", reply.status).as_bytes(),
            ]
            .concat(),
            stderr: format!("{marker}\n{end}\n").into_bytes(),
        })
    }
}

// The real lease client owns a live disposable controller. A snapshot with no
// controller would reject the operation before reaching any command assertions.
fn lease() -> host::SshLease {
    let target = host::SshTarget::new("studio.example", None, None).unwrap();
    let logical = json!({"hostname":"studio.example", "user":null, "port":null});
    let route = json!({"logical_target":logical, "targets":[{
        "logical_target":logical, "effective_target":logical, "display_target":"studio.example",
        "host_key_alias":null, "strict_host_key_checking":"ask",
        "projection":{"arguments":["-F","/dev/null"], "private_config":[]}}],
        "route_identity":"a".repeat(64), "projection_policy":"kwt.openssh.projection.v2",
        "observed_at":"2026-08-15T12:00:00Z"});
    let route =
        host::SshRouteSnapshot::parse(&serde_json::to_vec(&route).unwrap(), &target).unwrap();
    let complete = json!({"operation_id":"op-1", "sequence":1, "kind":"complete", "result":{
        "lease_id":"lease-1", "route_identity":"a".repeat(64), "generation":7, "mode":"multiplexed",
        "arguments":["-S","control-path", "-o","ProxyCommand=/usr/bin/false"]}});
    host::KwtSshLeaseClient::test_with_command(
        "/bin/sh",
        vec![
            "-c".into(),
            format!("printf '%s\\n' '{complete}'; read -r reply").into(),
        ],
    )
    .acquire(
        &route,
        &host::CancellationToken::new(),
        |_| Err(host::SshError::prompt_cancelled()),
        |_| {},
    )
    .unwrap()
}

fn import(replies: Vec<Reply>) -> (crate::Workspace, WorkspaceEvent) {
    let (workspace, original) = remote_kill_refresh_fixture();
    let runner = Arc::new(Runner(Mutex::new(replies.into())));
    let config = host::RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        host::SshTarget::new("studio.example", None, None).unwrap(),
        "/usr/bin/tmux",
        None,
    )
    .unwrap()
    .with_kwt_bundles(vec![(
        host::RemoteKwtTarget::LinuxAmd64,
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), vec![1_u8]).unwrap(),
    )]);
    let host = host::RemoteTmuxHost::new(
        config,
        &host::KwtSshExecutable::from_absolute("/fixture/controller").unwrap(),
        &host::SshExecutable::from_absolute("/bin/sh").unwrap(),
        std::path::Path::new("/fixture/controller-home"),
        Arc::clone(&runner) as crate::SharedCommandRunner,
    );
    let snapshot = original.snapshot.with_test_lease(lease());
    let inventory = host::KwtInventory::parse(PROJECTS.as_bytes(), b"[]", b"[]").unwrap();
    let request = Request {
        project: inventory.projects()[0].project().clone(),
        operation: KwtWorktreeOperation::ImportPullRequest {
            selector: "17".to_owned(),
            navigation_generation: 42,
        },
    };
    let task = Task {
        host_id: "ssh:studio".to_owned(),
        generation: 7,
        id: 43,
        host,
        snapshot: snapshot.clone(),
        cancellation: host::CancellationToken::new(),
        mutation: None,
        worktree: Some(request.clone()),
    };
    {
        let mut entries = workspace.scene.runtime.remote_hosts.lock().unwrap();
        let entry = entries.get_mut("ssh:studio").unwrap();
        entry.context.as_mut().unwrap().snapshot = snapshot;
        entry.kwt.inventory = Some(inventory.clone());
        entry.kwt.operation = Some(super::super::Operation {
            id: task.id,
            cancellation: task.cancellation.clone(),
            mutation: true,
            removal: false,
            scene_id: workspace.scene.id,
            listing: false,
        });
    }
    update_host(&workspace.scene, "ssh:studio", |host| {
        scene::apply_kwt_inventory(host, &inventory);
        host.kwt_state = KwtState::Mutating;
    });
    run(&workspace.scene, &task, &request);
    assert!(
        runner.0.lock().unwrap().is_empty(),
        "all expected commands must execute"
    );
    assert!(!workspace.snapshot().hosts()[0].kwt_mutating());
    let mut events = workspace.drain_events().0;
    assert_eq!(events.len(), 1);
    (workspace, events.remove(0))
}

fn replies(import: io::Result<CommandOutput>, projects: io::Result<CommandOutput>) -> Vec<Reply> {
    vec![
        ("projects", output(0, PROJECTS)),
        ("--global", output(0, "[]")),
        ("workspace", output(0, "[]")),
        ("--expected-registration", import),
        ("projects", projects),
        ("--global", output(0, WORKTREES)),
        ("workspace", output(0, "[]")),
    ]
}

fn failure(event: WorkspaceEvent) -> String {
    match event {
        WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: 42,
            message,
            ..
        } => message,
        _ => panic!("expected dialog failure"),
    }
}

#[test]
fn import_reconciles_uncertain_results_without_replay_or_opening() {
    for result in [
        Err(io::Error::new(io::ErrorKind::TimedOut, "import timed out")),
        output(0, "truncated"),
    ] {
        let (workspace, event) = import(replies(result, output(0, PROJECTS)));
        assert!(failure(event).contains("Inventory has been refreshed"));
        let snapshot = workspace.snapshot();
        let host = &snapshot.hosts()[0];
        assert_eq!(
            host.projects()[0].worktrees()[0].path(),
            "/work/widget/pr-17"
        );
        assert!(host.kwt_diagnostic().is_none());
        assert!(host.can_remove_kwt_project());
        workspace.close();
    }
}

#[test]
fn import_distinguishes_committed_and_uncertain_results_when_inventory_fails() {
    for (result, expected) in [
        (output(0, &receipt().to_string()), "import completed"),
        (
            Err(io::Error::new(io::ErrorKind::TimedOut, "import timed out")),
            "import may have completed",
        ),
    ] {
        let mut commands = replies(result, output(1, "inventory unavailable"));
        commands.truncate(5);
        let (workspace, event) = import(commands);
        assert!(failure(event).contains(expected));
        assert!(workspace.snapshot().hosts()[0].kwt_diagnostic().is_some());
        workspace.close();
    }
}

#[test]
fn import_opens_only_the_exact_receipt_confirmed_by_fresh_inventory() {
    let (workspace, event) = import(replies(
        output(0, &receipt().to_string()),
        output(0, PROJECTS),
    ));
    assert!(
        matches!(event, WorkspaceEvent::KwtWorktreeCreated { target, navigation_generation:42 }
        if target.worktree_path == "/work/widget/pr-17" && target.session_name == "widget-pr-17")
    );
    workspace.close();
    for (pointer, replacement) in [
        ("/project/identity", json!("github.com/acme/other")),
        ("/project/path", json!("/other")),
        ("/workspace/repository", json!("github.com/acme/other")),
        ("/workspace/path", json!("/other")),
        ("/workspace/generation", json!("replacement")),
        ("/workspace/generation", Value::Null),
        ("/workspace/session_name", json!("other")),
        ("/workspace/tmux_socket_name", json!("kwt-pr-other")),
        ("/workspace/tmux_socket_name", Value::Null),
        ("/workspace/tmux_attach_mode", json!("direct")),
    ] {
        let mut response = receipt();
        *response.pointer_mut(pointer).unwrap() = replacement;
        let (workspace, event) = import(replies(
            output(0, &response.to_string()),
            output(0, PROJECTS),
        ));
        failure(event);
        assert!(
            workspace.snapshot().hosts()[0].kwt_diagnostic().is_none(),
            "{pointer}"
        );
        workspace.close();
    }
    let (workspace, event) = import(replies(
        output(0, &receipt().to_string()),
        output(0, &PROJECTS.replace("registration\"", "replacement\"")),
    ));
    failure(event);
    workspace.close();
    // A valid protected receipt cannot open inventory that has changed server
    // or attachment mode since the import completed.
    for worktrees in [
        WORKTREES.replace("protected", "direct"),
        WORKTREES.replace("\"kwt-pr-17\"", "null"),
    ] {
        let mut commands = replies(output(0, &receipt().to_string()), output(0, PROJECTS));
        commands[5].1 = output(0, &worktrees);
        let (workspace, event) = import(commands);
        failure(event);
        workspace.close();
    }
}
