use super::{
    Arc, KwtState, Ordering, Scene, Task, WorkspaceError, WorkspaceEvent, current_remote_context,
    finish, publish, reserve, scene, update_host,
};
use crate::{KwtWorktreeTarget, RemoteTmuxAttachRequest, SessionSelection, Workspace, runtime};

#[cfg(test)]
mod tests;

#[derive(Clone)]
pub(crate) struct Pending {
    task: Task,
    target: KwtWorktreeTarget,
    session: Option<session::DiscoveredSession>,
    ready: bool,
}

impl Pending {
    fn failure(&self, message: impl Into<String>) -> WorkspaceEvent {
        WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: self.task.id,
            project_path: self.target.project_path.clone(),
            worktree_path: Some(self.target.worktree_path.clone()),
            message: message.into(),
        }
    }

    fn selection(&self) -> SessionSelection {
        let t = &self.target;
        SessionSelection::kwt_workspace(
            &t.host_id,
            &t.endpoint,
            &t.session_name,
            t.tmux_attach_mode,
            t.tmux_socket_name.clone(),
            &t.worktree_path,
            t.generation.clone(),
        )
    }
}

pub(crate) fn request(
    scene: &Arc<Scene>,
    target: KwtWorktreeTarget,
) -> Result<u64, WorkspaceError> {
    if target
        .generation
        .as_deref()
        .is_none_or(|value| !crate::is_canonical_kwt_generation(value))
        || target.tmux_attach_mode != host::KwtTmuxAttachMode::Direct
        || !matches!(target.tmux_socket_name.as_deref(), None | Some("kwt"))
    {
        return Err(WorkspaceError::new(
            "Refresh the host before removing this worktree.",
        ));
    }
    cancel(scene);
    let pending = {
        let publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = scene::lock_live_navigation(scene)?;
        {
            let entries = scene
                .runtime
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let entry = entries
                .get(&target.host_id)
                .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
            let context = current_remote_context(entry)
                .filter(|context| context.snapshot.endpoint() == target.endpoint)
                .ok_or_else(|| {
                    WorkspaceError::new("Connect this SSH host before removing a worktree")
                })?;
            context
                .snapshot
                .lease()
                .ensure_live()
                .map_err(|e| WorkspaceError::new(e.to_string()))?;
            let inventory = entry.kwt.inventory.as_ref().ok_or_else(|| {
                WorkspaceError::new("Refresh KWT inventory before removing this worktree.")
            })?;
            find_target(inventory, &target)?;
        }
        let task = reserve(scene, &publication, &target.host_id, None)?;
        let pending = Pending {
            task,
            target,
            session: None,
            ready: false,
        };
        *scene
            .remote_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(pending.clone());
        pending
    };
    let id = pending.task.id;
    let background = pending.clone();
    let owner = Arc::clone(scene);
    if let Err(error) = scene.runtime.refresh_runtime.spawn(
        "ghosthub-remote-removal-capture",
        Box::new(move || capture(&owner, background)),
    ) {
        cancel(scene);
        finish(scene, &pending.task);
        return Err(WorkspaceError::new(error.to_string()));
    }
    Ok(id)
}

pub(crate) fn cancel(scene: &Scene) {
    let pending = {
        let _publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        scene
            .remote_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
    };
    if let Some(pending) = pending {
        pending.task.cancellation.cancel();
    }
}

fn capture(scene: &Arc<Scene>, mut pending: Pending) {
    let result = (|| {
        require_current(scene, &pending.task)?;
        let inventory = pending
            .task
            .host
            .discover_kwt(&pending.task.snapshot, &pending.task.cancellation)
            .map_err(|e| WorkspaceError::new(e.to_string()))?;
        let (project, worktree) = find_target(&inventory, &pending.target)?;
        pending
            .task
            .host
            .check_kwt_worktree_removal(
                &pending.task.snapshot,
                project,
                worktree,
                &pending.task.cancellation,
            )
            .map_err(|e| WorkspaceError::new(e.to_string()))?;
        let fresh = pending
            .task
            .host
            .refresh(pending.task.snapshot.lease(), &pending.task.cancellation)
            .map_err(|e| WorkspaceError::new(e.to_string()))?;
        pending.task.snapshot = pending.task.snapshot.with_inventory(fresh);
        let server = pending.selection().remote_tmux_server()?;
        let diagnostic = match server {
            host::RemoteTmuxServer::Default => pending.task.snapshot.tmux_diagnostic(),
            host::RemoteTmuxServer::Kwt => pending.task.snapshot.kwt_tmux_diagnostic(),
        };
        if let Some(diagnostic) = diagnostic {
            return Err(WorkspaceError::new(diagnostic.to_string()));
        }
        pending.session = pending
            .task
            .snapshot
            .sessions_on(server)
            .iter()
            .find(|s| s.name() == pending.target.session_name)
            .cloned();
        pending.ready = true;
        require_current(scene, &pending.task)?;
        let _publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = scene::lock_live_navigation(scene)?;
        runtime::recapture_remote_attachment_context(
            &scene.runtime,
            &pending.target.host_id,
            pending.task.generation,
            &pending.task.snapshot,
        )?;
        let mut slot = scene
            .remote_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if slot.as_ref().is_none_or(|p| p.task.id != pending.task.id)
            || pending.task.cancellation.is_cancelled()
        {
            return Err(WorkspaceError::new("Worktree removal was cancelled"));
        }
        *slot = Some(pending.clone());
        Ok(WorkspaceEvent::KwtWorktreeRemovalReady {
            project_path: pending.target.project_path.clone(),
            worktree_path: pending.target.worktree_path.clone(),
            authority: pending.task.id,
            session_was_running: pending.session.is_some(),
        })
    })();
    finish(scene, &pending.task);
    scene::push_lossless_event(
        scene,
        result.unwrap_or_else(|e| pending.failure(e.to_string())),
    );
}

#[allow(clippy::too_many_arguments)] // Confirmation binds every identity shown by the dialog.
pub(crate) fn confirm(
    scene: &Arc<Scene>,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration: &str,
    worktree_path: &str,
    generation: &str,
    session_name: &str,
    authority: u64,
) -> Result<(), WorkspaceError> {
    let pending = {
        let _publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = scene::lock_live_navigation(scene)?;
        let mut slot = scene
            .remote_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let pending = slot
            .as_mut()
            .filter(|p| {
                let t = &p.target;
                p.ready
                    && p.task.id == authority
                    && t.host_id == host_id
                    && t.endpoint == endpoint
                    && t.repository == repository
                    && t.project_path == project_path
                    && t.registration_fingerprint == registration
                    && t.worktree_path == worktree_path
                    && t.generation.as_deref() == Some(generation)
                    && t.session_name == session_name
            })
            .ok_or_else(|| WorkspaceError::new("Review the worktree removal again."))?;
        runtime::recapture_remote_attachment_context(
            &scene.runtime,
            host_id,
            pending.task.generation,
            &pending.task.snapshot,
        )?;
        // Consume confirmation, but keep cancellation reachable while queued.
        pending.ready = false;
        pending.clone()
    };
    let owner = Arc::clone(scene);
    let background = pending.clone();
    if let Err(error) = scene.runtime.refresh_runtime.spawn(
        "ghosthub-remote-worktree-remove",
        Box::new(move || run(&owner, &background)),
    ) {
        let _publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut slot = scene
            .remote_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if slot.as_ref().is_some_and(|p| p.task.id == pending.task.id) {
            slot.take().unwrap().task.cancellation.cancel();
        }
        return Err(WorkspaceError::new(error.to_string()));
    }
    Ok(())
}

fn run(scene: &Arc<Scene>, pending: &Pending) {
    let result = (|| {
        let _operation = crate::lock_session_operations(scene, &pending.task.cancellation)
            .ok_or_else(|| WorkspaceError::new("Worktree removal was cancelled"))?;
        // Workspace opens take this lane before reserving KWT. Removal must use
        // the same order so a queued removal cannot reject the open ahead of it.
        let task = {
            let publication = scene
                .runtime
                .remote_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let _navigation = scene::lock_live_navigation(scene)?;
            let mut slot = scene
                .remote_kwt_removal
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if pending.task.cancellation.is_cancelled()
                || slot.as_ref().is_none_or(|p| p.task.id != pending.task.id)
            {
                return Err(WorkspaceError::new("Worktree removal was cancelled"));
            }
            slot.take();
            let host_id = &pending.task.host_id;
            runtime::recapture_remote_attachment_context(
                &scene.runtime,
                host_id,
                pending.task.generation,
                &pending.task.snapshot,
            )?;
            let task = reserve(scene, &publication, host_id, None)?;
            let mut entries = scene
                .runtime
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let operation = entries
                .get_mut(host_id)
                .unwrap()
                .kwt
                .operation
                .as_mut()
                .unwrap();
            operation.mutation = true;
            // Destructive authority belongs to the reviewed connection, including
            // provisioning between its final identity check and the helper command.
            operation.removal = true;
            drop(entries);
            update_host(scene, host_id, |host| host.kwt_state = KwtState::Mutating);
            task
        };
        let result = remove(scene, &task, pending);
        // Settle KWT before releasing queued workspace opens on every outcome.
        finish(scene, &task);
        result
    })();
    scene::push_lossless_event(
        scene,
        result.unwrap_or_else(|e| pending.failure(e.to_string())),
    );
}

fn require_current(scene: &Scene, task: &Task) -> Result<(), WorkspaceError> {
    if !scene.closed.load(Ordering::Acquire) && publish(scene, task, |_, _| {}) {
        return Ok(());
    }
    Err(WorkspaceError::new(
        "SSH connection changed during worktree removal. Refresh the host.",
    ))
}

fn find_target<'a>(
    inventory: &'a host::KwtInventory,
    target: &KwtWorktreeTarget,
) -> Result<(&'a host::KwtProject, &'a host::KwtWorktree), WorkspaceError> {
    let project = inventory
        .projects()
        .iter()
        .find(|p| {
            p.project().repository() == target.repository
                && p.project().path() == target.project_path
                && p.project().registration_fingerprint() == target.registration_fingerprint
        })
        .ok_or_else(|| {
            WorkspaceError::new(
                "The project registration changed. Refresh and review the removal again.",
            )
        })?;
    let worktree = project
        .worktrees()
        .iter()
        .find(|w| {
            w.path() == target.worktree_path
                && w.generation() == target.generation.as_deref()
                && w.session_name() == target.session_name
                && w.tmux_socket_name() == target.tmux_socket_name.as_deref()
                && w.tmux_attach_mode() == target.tmux_attach_mode
                && !w.is_main()
        })
        .ok_or_else(|| {
            WorkspaceError::new("The worktree changed. Refresh and review the removal again.")
        })?;
    Ok((project.project(), worktree))
}

fn remove(
    scene: &Arc<Scene>,
    task: &Task,
    pending: &Pending,
) -> Result<WorkspaceEvent, WorkspaceError> {
    require_current(scene, task)?;
    let inventory = task
        .host
        .discover_kwt(&task.snapshot, &task.cancellation)
        .map_err(|e| WorkspaceError::new(e.to_string()))?;
    let (project, worktree) = find_target(&inventory, &pending.target)?;
    task.host
        .check_kwt_worktree_removal(&task.snapshot, project, worktree, &task.cancellation)
        .map_err(|e| WorkspaceError::new(e.to_string()))?;
    require_current(scene, task)?;
    let workspace = Workspace {
        scene: Arc::clone(scene),
    };
    if let Some(session) = &pending.session {
        task.host
            .kill_live_session(
                &pending.task.snapshot,
                pending.selection().remote_tmux_server()?,
                session,
                &task.cancellation,
            )
            .map_err(|e| WorkspaceError::new(e.to_string()))?;
        let request = RemoteTmuxAttachRequest {
            host_id: task.host_id.clone(),
            connection_generation: task.generation,
            selection: pending.selection(),
            host: task.host.clone(),
            snapshot: pending.task.snapshot.clone(),
            session: session.clone(),
        };
        workspace.finish_remote_tmux_kill(&request);
        workspace.refresh_after_remote_tmux_kill(&request, |host, snapshot, _| {
            host.refresh(snapshot.lease(), &task.cancellation)
        })?;
    }
    require_current(scene, task)?;
    let result =
        task.host
            .remove_kwt_worktree(&task.snapshot, project, worktree, &task.cancellation);
    if let Err(error) = &result
        && error.kind() != crate::DiagnosticKind::Timeout
    {
        return Err(WorkspaceError::new(error.to_string()));
    }
    if result.is_ok() {
        tombstone(scene, task, &pending.target);
    }
    let fresh = task
        .host
        .discover_kwt(&task.snapshot, &task.cancellation)
        .map_err(|e| {
            WorkspaceError::new(format!(
                "Worktree removal {}. Refresh the host before retrying: {e}",
                if result.is_ok() {
                    "completed, but refresh failed"
                } else {
                    "timed out and may have completed"
                }
            ))
        })?;
    let project = fresh
        .projects()
        .iter()
        .find(|p| {
            p.project().repository() == pending.target.repository
                && p.project().path() == pending.target.project_path
                && p.project().registration_fingerprint() == pending.target.registration_fingerprint
        })
        .ok_or_else(|| {
            WorkspaceError::new(
                "The project changed during removal. Refresh the host before retrying.",
            )
        })?;
    if project.worktrees().iter().any(|w| {
        w.path() == pending.target.worktree_path
            && w.generation() == pending.target.generation.as_deref()
    }) {
        return Err(WorkspaceError::new(
            "The worktree is still present. Refresh the host before retrying removal.",
        ));
    }
    tombstone(scene, task, &pending.target);
    if !publish(scene, task, |state, host| {
        scene::apply_kwt_inventory(host, &fresh);
        host.kwt_state = KwtState::Mutating;
        state.inventory = Some(fresh);
    }) {
        return Err(WorkspaceError::new(
            "Worktree removal completed. Refresh the SSH host.",
        ));
    }
    Ok(WorkspaceEvent::KwtWorktreeRemoved {
        operation_id: pending.task.id,
        project_path: pending.target.project_path.clone(),
        worktree_path: pending.target.worktree_path.clone(),
    })
}

fn tombstone(scene: &Scene, task: &Task, target: &KwtWorktreeTarget) {
    publish(scene, task, |state, host| {
        crate::remove_cached_kwt_worktree(
            host,
            &target.repository,
            &target.project_path,
            &target.registration_fingerprint,
            &target.worktree_path,
            target.generation.as_deref().unwrap(),
        );
        state.inventory = None;
        for other in runtime::live_scenes(&scene.runtime) {
            let mut slot = other
                .remote_kwt_removal
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if slot.as_ref().is_some_and(|p| p.target == *target) {
                slot.take().unwrap().task.cancellation.cancel();
            }
        }
    });
}
