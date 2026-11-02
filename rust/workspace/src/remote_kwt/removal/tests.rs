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

#[test]
fn publication_can_drop_the_last_handle_to_another_scene() {
    let (workspace, _, pending) = ready_removal();
    let other = workspace.open_scene();
    let mut other_pending = pending.clone();
    other_pending.task.cancellation = CancellationToken::new();
    let other_cancellation = other_pending.task.cancellation.clone();
    *other.scene.remote_kwt_removal.lock().unwrap() = Some(other_pending);
    let other_scene = Arc::downgrade(&other.scene);
    let task = {
        let publication = workspace.scene.runtime.remote_publication.lock().unwrap();
        reserve(&workspace.scene, &publication, "ssh:studio", None).unwrap()
    };

    // The owner is first in registration order. Pause its invalidation after
    // publication has collected the other scene, but before visiting it.
    let confirmation = workspace.scene.remote_kwt_removal.lock().unwrap();
    let owner = Arc::clone(&workspace.scene);
    let (finished, completion) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let operation = owner.runtime.session_operations.lock().unwrap();
        tombstone(&owner, &task, &pending.target);
        finish(&owner, &task);
        drop(operation);
        finished.send(()).unwrap();
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while other_scene.strong_count() != 2 {
        assert!(
            std::time::Instant::now() < deadline,
            "scene was not collected"
        );
        std::thread::yield_now();
    }
    // The removal worker now owns the final reference. Its eventual
    // drop must run real scene teardown without re-entering publication locks.
    drop(other);
    drop(confirmation);
    completion
        .recv_timeout(std::time::Duration::from_secs(10))
        .expect("removal publication and final scene teardown must complete");
    worker.join().unwrap();
    assert_eq!(other_scene.strong_count(), 0);
    assert!(other_cancellation.is_cancelled());
    assert!(!workspace.snapshot().hosts()[0].kwt_refreshing());
    workspace.close();
}

#[test]
fn inventory_publication_can_drop_the_last_handle_to_another_scene() {
    for pending_removal in [false, true] {
        let (workspace, _, pending) = ready_removal();
        let other = workspace.open_scene();
        let mut other_pending = pending.clone();
        other_pending.task.cancellation = CancellationToken::new();
        let other_cancellation = other_pending.task.cancellation.clone();
        if pending_removal {
            *other.scene.remote_kwt_removal.lock().unwrap() = Some(other_pending);
        }
        let other_scene = Arc::downgrade(&other.scene);
        // Pause reconciliation on the first scene after it collects both handles.
        let navigation = workspace.scene.navigation.lock().unwrap();
        let owner = Arc::clone(&workspace.scene);
        let (finished, completion) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let operation = owner.runtime.session_operations.lock().unwrap();
            let published = scene::publish_remote_inventory(
                &owner,
                &pending.task.host_id,
                pending.task.generation,
                &pending.task.snapshot,
                &CancellationToken::new(),
                crate::RemoteSessionInventory::test_fixture(
                    Some("/usr/bin/tmux".to_owned()),
                    vec![session::DiscoveredSession::new(
                        "refreshed",
                        session::SessionIdentity::new(42, "$2", 101),
                        0,
                    )],
                    crate::HerdrInventory::Unavailable,
                    crate::ZellijInventory::Unavailable,
                ),
            );
            drop(operation);
            finished.send(published).unwrap();
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while other_scene.strong_count() != 2 {
            assert!(
                std::time::Instant::now() < deadline,
                "scene was not collected"
            );
            std::thread::yield_now();
        }
        // Publication now owns the final handle and must finish real teardown
        // while still holding the publication fence and session operation lane.
        drop(other);
        drop(navigation);
        completion
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("inventory publication and final scene teardown must complete")
            .expect("fresh inventory must publish");
        worker.join().unwrap();
        assert_eq!(other_scene.strong_count(), 0);
        if pending_removal {
            assert!(other_cancellation.is_cancelled());
        }
        assert_eq!(
            workspace.snapshot().hosts()[0].sessions()[0].name(),
            "refreshed"
        );
        workspace.close();
    }
}
