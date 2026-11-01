use super::*;
use crate::tests::{ManualRefreshRuntime, remote_kill_refresh_fixture};
use crate::{CancellationToken, RemotePublicationFence, SystemLocalDiscovery, TerminalAppearance};

fn ready_removal() -> (Workspace, Arc<ManualRefreshRuntime>, Pending) {
    let (source, request) = remote_kill_refresh_fixture();
    let scheduler = Arc::new(ManualRefreshRuntime::default());
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        None,
        Arc::new(SystemLocalDiscovery::new()),
        scheduler.clone(),
    );
    *workspace.scene.runtime.hosts.write().unwrap() = source.snapshot().hosts().to_vec();
    let entry = source
        .scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap()
        .remove("ssh:studio")
        .unwrap();
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap()
        .insert("ssh:studio".to_owned(), entry);
    // Capture is covered by the live SSH tests. Start at its ready confirmation
    // so the manual scheduler can control when the removal worker takes the lane.
    let pending = Pending {
        task: Task {
            host_id: "ssh:studio".to_owned(),
            generation: request.connection_generation,
            id: 42,
            host: request.host,
            snapshot: request.snapshot,
            cancellation: CancellationToken::new(),
            mutation: None,
            worktree: None,
        },
        target: KwtWorktreeTarget {
            host_id: "ssh:studio".to_owned(),
            endpoint: "studio.example".to_owned(),
            repository: "github.com/acme/widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            worktree_path: "/work/widget/topic".to_owned(),
            generation: Some("0123456789abcdef0123456789abcdef".to_owned()),
            session_name: "widget-topic".to_owned(),
            tmux_socket_name: None,
            tmux_attach_mode: host::KwtTmuxAttachMode::Direct,
        },
        session: None,
        ready: true,
    };
    *workspace.scene.remote_kwt_removal.lock().unwrap() = Some(pending.clone());
    (workspace, scheduler, pending)
}

fn confirm(workspace: &Workspace, pending: &Pending) -> Result<(), WorkspaceError> {
    let target = &pending.target;
    workspace.remove_kwt_worktree(
        &target.host_id,
        &target.endpoint,
        &target.repository,
        &target.project_path,
        &target.registration_fingerprint,
        &target.worktree_path,
        target.generation.as_deref().unwrap(),
        &target.session_name,
        pending.task.id,
    )
}

#[test]
fn workspace_open_can_take_the_lane_before_confirmed_removal_runs() {
    let (workspace, scheduler, pending) = ready_removal();
    let other = workspace.open_scene();
    confirm(&workspace, &pending).unwrap();
    // Another window reaches the workspace-open reservation while removal's
    // worker is still queued. This is the same arbitration used by both opens.
    let lane = other.scene.runtime.session_operations.lock().unwrap();
    let cancellation = CancellationToken::new();
    let open = crate::remote_kwt::reserve_workspace(
        &other.scene,
        &RemotePublicationFence {
            host_id: "ssh:studio",
            connection_generation: pending.task.generation,
            snapshot: &pending.task.snapshot,
            cancellation: &cancellation,
        },
    )
    .expect("a confirmed removal waiting for the lane must not reject the open");
    open.publish(host::KwtInventory::parse(b"[]", b"[]", b"[]").unwrap())
        .unwrap();
    drop(open);
    // Closing must cancel the queued removal without needing the lane.
    workspace.close();
    assert!(pending.task.cancellation.is_cancelled());
    drop(lane);
    scheduler.run_next_work();
    assert!(!other.snapshot().hosts()[0].kwt_mutating());
    other.close();
}

#[test]
fn queued_removal_cannot_reuse_confirmation_or_run_after_cancel() {
    let (workspace, scheduler, pending) = ready_removal();
    confirm(&workspace, &pending).unwrap();
    assert!(confirm(&workspace, &pending).is_err());
    workspace.cancel_kwt_worktree_removal();
    assert!(pending.task.cancellation.is_cancelled());
    scheduler.run_next_work();
    assert!(workspace.drain_events().0.iter().any(|event| matches!(
        event,
        WorkspaceEvent::KwtWorktreeOperationFailed { operation_id: 42, message, .. }
            if message == "Worktree removal was cancelled"
    )));
    assert!(!workspace.snapshot().hosts()[0].kwt_mutating());
    workspace.close();
}

#[test]
fn queued_removal_rechecks_the_connection_before_reserving_kwt() {
    let (workspace, scheduler, pending) = ready_removal();
    confirm(&workspace, &pending).unwrap();
    {
        let mut entries = workspace.scene.runtime.remote_hosts.lock().unwrap();
        let entry = entries.get_mut("ssh:studio").unwrap();
        entry.generation += 1;
        entry.context.as_mut().unwrap().generation = entry.generation;
    }
    scheduler.run_next_work();
    assert!(workspace.drain_events().0.iter().any(|event| matches!(
        event,
        WorkspaceEvent::KwtWorktreeOperationFailed { operation_id: 42, message, .. }
            if message.contains("SSH connection changed before attachment")
    )));
    assert!(!workspace.snapshot().hosts()[0].kwt_mutating());
    workspace.close();
}
