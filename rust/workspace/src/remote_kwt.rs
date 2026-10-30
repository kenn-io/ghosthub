use crate::{
    Arc, CancellationToken, DiagnosticKind, HostDiagnostic, HostItem, KwtProjectMutationRequest,
    KwtState, Ordering, RemoteEntry, RemoteTmuxSnapshot, RuntimeRemoteHost, Scene, WorkspaceError,
    WorkspaceEvent, begin_snapshot_write, current_remote_context, next_operation_id, scene,
};

mod worktree;
pub(crate) use worktree::{cancel_listing, start_worktree};

#[derive(Default)]
pub(crate) struct State {
    inventory: Option<host::KwtInventory>,
    operation: Option<Operation>,
}

struct Operation {
    id: u64,
    cancellation: CancellationToken,
    mutation: bool,
    scene_id: crate::SceneId,
    listing: bool,
}

#[derive(Clone)]
enum Mutation {
    Add(String),
    Remove(host::KwtProject),
}

#[derive(Clone)]
struct Task {
    host_id: String,
    generation: u64,
    id: u64,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    cancellation: CancellationToken,
    mutation: Option<Mutation>,
    worktree: Option<worktree::Request>,
}

pub(crate) struct WorkspaceInventory<'a> {
    scene: &'a Arc<Scene>,
    task: Task,
}

impl WorkspaceInventory<'_> {
    pub(crate) fn publish(&self, inventory: host::KwtInventory) -> Result<(), WorkspaceError> {
        if publish(self.scene, &self.task, |state, host| {
            scene::apply_kwt_inventory(host, &inventory);
            host.kwt_state = KwtState::Mutating;
            state.inventory = Some(inventory);
        }) {
            Ok(())
        } else {
            Err(WorkspaceError::new(
                "SSH connection changed while opening the workspace",
            ))
        }
    }
}

impl Drop for WorkspaceInventory<'_> {
    fn drop(&mut self) {
        finish(self.scene, &self.task);
    }
}

pub(crate) fn reserve_workspace<'a>(
    scene: &'a Arc<Scene>,
    fence: &crate::RemotePublicationFence<'_>,
) -> Result<WorkspaceInventory<'a>, WorkspaceError> {
    let publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    {
        let mut entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = entries
            .get_mut(fence.host_id)
            .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
        crate::validate_remote_publication_fence(entry, fence)?;
        if entry
            .kwt
            .operation
            .as_ref()
            .is_some_and(|operation| operation.mutation)
        {
            return Err(WorkspaceError::new(
                "another KWT project operation is already running",
            ));
        }
        // An older read must not restore the socket captured before this open.
        if let Some(operation) = entry.kwt.operation.take() {
            operation.cancellation.cancel();
        }
    }
    let mut task = reserve(scene, &publication, fence.host_id, None)?;
    task.cancellation = fence.cancellation.clone();
    {
        let mut entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let operation = entries
            .get_mut(fence.host_id)
            .unwrap()
            .kwt
            .operation
            .as_mut()
            .unwrap();
        operation.mutation = true;
        operation.cancellation = task.cancellation.clone();
    }
    update_host(scene, fence.host_id, |host| {
        host.kwt_state = KwtState::Mutating;
    });
    Ok(WorkspaceInventory { scene, task })
}

pub(crate) fn cancel(entry: &RemoteEntry) {
    if let Some(operation) = &entry.kwt.operation {
        operation.cancellation.cancel();
    }
}

pub(crate) fn cancel_read(entry: &RemoteEntry) {
    if let Some(operation) = &entry.kwt.operation
        && !operation.mutation
    {
        operation.cancellation.cancel();
    }
}

pub(crate) fn cancel_scene(scene: &Scene) {
    let entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    for entry in entries.values() {
        if let Some(operation) = &entry.kwt.operation
            && operation.scene_id == scene.id
        {
            operation.cancellation.cancel();
        }
    }
}

pub(crate) fn refresh_all(scene: &Arc<Scene>) {
    let ids: Vec<_> = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .keys()
        .cloned()
        .collect();
    for id in ids {
        start(scene, &id);
    }
}

pub(crate) fn start(scene: &Arc<Scene>, host_id: &str) {
    if scene.closed.load(Ordering::Acquire) || scene.runtime.remote_kwt_bundles.is_empty() {
        return;
    }
    let task = {
        let publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        reserve(scene, &publication, host_id, None)
    };
    if let Ok(task) = task {
        schedule(scene, &task);
    }
}

pub(crate) fn mutate(
    scene: &Arc<Scene>,
    host_id: &str,
    endpoint: &str,
    request: KwtProjectMutationRequest,
) -> Result<(), WorkspaceError> {
    let task = {
        // Publication reconciles scenes under their navigation locks. Keep
        // that order when reserving a project mutation as well.
        let publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = scene::lock_live_navigation(scene)?;
        reserve(scene, &publication, host_id, Some((endpoint, request)))?
    };
    // Close or host removal can now cancel the registered task. Scheduling
    // outside the fences also lets spawn-failure cleanup publish its result.
    schedule(scene, &task);
    Ok(())
}

fn reserve(
    scene: &Scene,
    _publication: &std::sync::MutexGuard<'_, ()>,
    host_id: &str,
    mutation: Option<(&str, KwtProjectMutationRequest)>,
) -> Result<Task, WorkspaceError> {
    let mut entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get_mut(host_id)
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    if entry.kwt.operation.is_some() {
        return Err(WorkspaceError::new(
            "another KWT project operation is already running",
        ));
    }
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before changing projects"))?;
    let mutation = mutation
        .map(|(endpoint, request)| {
            if context.snapshot.endpoint() != endpoint {
                return Err(WorkspaceError::new(
                    "SSH endpoint changed; refresh and try again",
                ));
            }
            match request {
                KwtProjectMutationRequest::Add { path } => {
                    if !path.starts_with('/') || path.chars().any(char::is_control) {
                        return Err(WorkspaceError::new(
                            "Enter an absolute path on the SSH host.",
                        ));
                    }
                    Ok(Mutation::Add(path))
                }
                KwtProjectMutationRequest::Remove {
                    repository,
                    path,
                    registration_fingerprint,
                } => {
                    let project = entry
                        .kwt
                        .inventory
                        .as_ref()
                        .and_then(|inventory| {
                            inventory
                                .projects()
                                .iter()
                                .map(host::KwtProjectInventory::project)
                                .find(|project| {
                                    project.repository() == repository
                                        && project.path() == path
                                        && project.registration_fingerprint()
                                            == registration_fingerprint
                                })
                        })
                        .ok_or_else(|| {
                            WorkspaceError::new(
                                "The project registration changed; refresh and try again",
                            )
                        })?;
                    Ok(Mutation::Remove(project.clone()))
                }
            }
        })
        .transpose()?;
    let task = Task {
        host_id: host_id.to_owned(),
        generation: entry.generation,
        id: next_operation_id(&scene.runtime),
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        cancellation: CancellationToken::new(),
        mutation,
        worktree: None,
    };
    entry.kwt.operation = Some(Operation {
        id: task.id,
        cancellation: task.cancellation.clone(),
        mutation: task.mutation.is_some(),
        scene_id: scene.id,
        listing: false,
    });
    update_host(scene, host_id, |host| {
        host.kwt_state = if task.mutation.is_some() {
            KwtState::Mutating
        } else {
            KwtState::Refreshing {
                available: host.kwt_available(),
            }
        };
    });
    Ok(task)
}

fn schedule(scene: &Arc<Scene>, task: &Task) {
    let task_scene = Arc::clone(scene);
    let background = task.clone();
    if let Err(error) = scene.runtime.refresh_runtime.spawn(
        "ghosthub-remote-kwt",
        Box::new(move || run(&task_scene, &background)),
    ) {
        fail(scene, task, &error);
        finish(scene, task);
        mutation_event(scene, task, Err(WorkspaceError::new(error.to_string())));
        if let Some(request) = &task.worktree {
            scene::push_lossless_event(scene, request.failure(task, error.to_string()));
        }
    }
}

fn run(scene: &Arc<Scene>, task: &Task) {
    if let Some(request) = &task.worktree {
        worktree::run(scene, task, request);
        return;
    }
    let mut committed = false;
    let result = (|| {
        if scene.closed.load(Ordering::Acquire) || !publish(scene, task, |_, _| {}) {
            return Err(WorkspaceError::new(
                "SSH connection changed before the project operation",
            ));
        }
        if let Some(mutation) = &task.mutation {
            let (action, project) = match mutation {
                Mutation::Add(path) => (
                    crate::KwtProjectAction::Add,
                    task.host
                        .register_kwt_project(&task.snapshot, path, &task.cancellation),
                ),
                Mutation::Remove(project) => (
                    crate::KwtProjectAction::Remove,
                    task.host
                        .remove_kwt_project(&task.snapshot, project, &task.cancellation),
                ),
            };
            let project = project.map_err(|error| WorkspaceError::new(error.to_string()))?;
            committed = true;
            // Publish the mutation receipt before reconciliation, so a failed read
            // cannot hide a successful add or restore a removed registration.
            publish(scene, task, |state, host| {
                state.inventory = None;
                scene::apply_kwt_project_mutation(host, action, &project);
                host.kwt_state = KwtState::Mutating;
            });
        }
        let inventory = task
            .host
            .discover_kwt(&task.snapshot, &task.cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        publish(scene, task, |state, host| {
            scene::apply_kwt_inventory(host, &inventory);
            if task.mutation.is_some() {
                host.kwt_state = KwtState::Mutating;
            }
            state.inventory = Some(inventory);
        });
        Ok(())
    })();
    if let Err(error) = &result {
        fail(scene, task, error);
    }
    finish(scene, task);
    mutation_event(scene, task, if committed { Ok(()) } else { result });
}

fn mutation_event(scene: &Scene, task: &Task, result: Result<(), WorkspaceError>) {
    if let Some(mutation) = &task.mutation {
        let action = match mutation {
            Mutation::Add(_) => crate::KwtProjectAction::Add,
            Mutation::Remove(_) => crate::KwtProjectAction::Remove,
        };
        scene::push_lossless_event(
            scene,
            match result {
                Ok(()) => WorkspaceEvent::KwtProjectMutationFinished { action },
                Err(error) => WorkspaceEvent::KwtProjectMutationFailed {
                    action,
                    message: error.to_string(),
                },
            },
        );
    }
}

fn fail(scene: &Scene, task: &Task, error: &dyn std::fmt::Display) {
    publish(scene, task, |_, host| {
        host.kwt_diagnostic = Some(HostDiagnostic::new(
            DiagnosticKind::Transport,
            error.to_string(),
        ));
    });
}

fn finish(scene: &Arc<Scene>, task: &Task) {
    let changed = {
        let _publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(entry) = entries.get_mut(&task.host_id) else {
            return;
        };
        if entry
            .kwt
            .operation
            .as_ref()
            .is_none_or(|operation| operation.id != task.id)
        {
            return;
        }
        entry.kwt.operation = None;
        update_host(scene, &task.host_id, |host| {
            host.kwt_state = if entry.kwt.inventory.is_some() || !host.projects.is_empty() {
                KwtState::Ready
            } else {
                KwtState::Unavailable
            };
        });
        entry.generation != task.generation
    };
    if changed {
        start(scene, &task.host_id);
    }
}

fn publish(scene: &Scene, task: &Task, publish: impl FnOnce(&mut State, &mut HostItem)) -> bool {
    let _publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get_mut(&task.host_id) else {
        return false;
    };
    if task.cancellation.is_cancelled()
        || entry.generation != task.generation
        || current_remote_context(entry).is_none()
        || entry
            .kwt
            .operation
            .as_ref()
            .is_none_or(|operation| operation.id != task.id)
    {
        return false;
    }
    update_host(scene, &task.host_id, |host| publish(&mut entry.kwt, host));
    true
}

fn update_host(scene: &Scene, host_id: &str, update: impl FnOnce(&mut HostItem)) {
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    let mut hosts = scene
        .runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(host) = hosts.iter_mut().find(|host| host.id == host_id) {
        update(host);
        scene.runtime.revision.fetch_add(1, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worktree_open_supersedes_reads_and_excludes_project_mutations() {
        let (workspace, _) = crate::tests::remote_kill_refresh_fixture();
        let scene = &workspace.scene;
        let publication = scene.runtime.remote_publication.lock().unwrap();
        let read = reserve(scene, &publication, "ssh:studio", None).unwrap();
        drop(publication);
        let cancellation = CancellationToken::new();
        let operation = reserve_workspace(
            scene,
            &crate::RemotePublicationFence {
                host_id: "ssh:studio",
                connection_generation: read.generation,
                snapshot: &read.snapshot,
                cancellation: &cancellation,
            },
        )
        .unwrap();
        assert!(read.cancellation.is_cancelled());
        assert!(!publish(scene, &read, |_, host| host.sessions.clear()));
        finish(scene, &read);
        assert!(
            workspace
                .add_kwt_project("ssh:studio", "studio.example", "/projects/orbit")
                .is_err()
        );
        operation
            .publish(host::KwtInventory::parse(b"[]", b"[]", b"[]").unwrap())
            .unwrap();
        assert!(workspace.snapshot().hosts()[0].kwt_mutating());
        drop(operation);
        assert!(!workspace.snapshot().hosts()[0].kwt_mutating());
        workspace
            .add_kwt_project("ssh:studio", "studio.example", "/projects/orbit")
            .unwrap();
        workspace.close();
    }

    #[test]
    fn project_mutation_holds_publication_before_navigation() {
        let (workspace, _) = crate::tests::remote_kill_refresh_fixture();
        let runtime = Arc::clone(&workspace.scene.runtime);
        *workspace.scene.before_navigation_lock.lock().unwrap() = Some(Box::new(move || {
            assert!(matches!(
                runtime.remote_publication.try_lock(),
                Err(std::sync::TryLockError::WouldBlock)
            ));
        }));
        workspace
            .add_kwt_project("ssh:studio", "studio.example", "/projects/orbit")
            .unwrap();
        workspace.close();
    }

    #[test]
    fn close_cancels_queued_project_mutation_before_execution() {
        let (workspace, _) = crate::tests::remote_kill_refresh_fixture();
        let publication = workspace.scene.runtime.remote_publication.lock().unwrap();
        let task = reserve(
            &workspace.scene,
            &publication,
            "ssh:studio",
            Some((
                "studio.example",
                KwtProjectMutationRequest::Add {
                    path: "/projects/orbit".to_owned(),
                },
            )),
        )
        .unwrap();
        drop(publication);
        assert!(!task.cancellation.is_cancelled());
        workspace.close();
        assert!(task.cancellation.is_cancelled());
        run(&workspace.scene, &task);
        assert!(
            workspace.scene.runtime.remote_hosts.lock().unwrap()["ssh:studio"]
                .kwt
                .operation
                .is_none()
        );
    }

    #[test]
    fn superseded_inventory_cannot_replace_the_new_connection() {
        let (workspace, _) = crate::tests::remote_kill_refresh_fixture();
        let publication = workspace.scene.runtime.remote_publication.lock().unwrap();
        let task = reserve(&workspace.scene, &publication, "ssh:studio", None).unwrap();
        drop(publication);
        {
            let mut entries = workspace.scene.runtime.remote_hosts.lock().unwrap();
            let entry = entries.get_mut("ssh:studio").unwrap();
            entry.generation += 1;
            entry.context = None;
        }
        assert!(!publish(&workspace.scene, &task, |_, host| host
            .sessions
            .clear()));
        let snapshot = workspace.snapshot();
        assert_eq!(snapshot.hosts()[0].sessions()[0].name(), "review");
        finish(&workspace.scene, &task);
        assert!(!workspace.snapshot().hosts()[0].kwt_refreshing());
    }
}
