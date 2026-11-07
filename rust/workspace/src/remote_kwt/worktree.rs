use super::{
    Arc, DiagnosticKind, KwtState, Ordering, Scene, Task, WorkspaceError, WorkspaceEvent,
    current_remote_context, fail, finish, publish, reserve, scene, schedule, update_host,
};
use crate::{KwtBranchItem, KwtWorktreeOperation, KwtWorktreeTarget};

#[cfg(all(test, unix))]
mod tests;

#[derive(Clone)]
pub(super) struct Request {
    project: host::KwtProject,
    operation: KwtWorktreeOperation,
}

impl Request {
    pub(super) fn failure(&self, task: &Task, message: String) -> WorkspaceEvent {
        WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: self.operation_id(task.id),
            project_path: self.project.path().to_owned(),
            worktree_path: None,
            message,
        }
    }

    fn operation_id(&self, listing_id: u64) -> u64 {
        match self.operation {
            KwtWorktreeOperation::Create {
                navigation_generation,
                ..
            }
            | KwtWorktreeOperation::ImportPullRequest {
                navigation_generation,
                ..
            } => navigation_generation,
            KwtWorktreeOperation::Branches
            | KwtWorktreeOperation::PullRequests
            | KwtWorktreeOperation::Remove { .. } => listing_id,
        }
    }

    fn project_in<'a>(
        &self,
        inventory: &'a host::KwtInventory,
    ) -> Result<&'a host::KwtProjectInventory, WorkspaceError> {
        inventory
            .projects()
            .iter()
            .find(|item| {
                let project = item.project();
                project.repository() == self.project.repository()
                    && project.path() == self.project.path()
                    && project.registration_fingerprint() == self.project.registration_fingerprint()
            })
            .ok_or_else(|| {
                WorkspaceError::new(
                    "The selected project changed; refresh it before changing worktrees",
                )
            })
    }
}

#[allow(clippy::too_many_arguments)] // The dialog carries exact project and endpoint identity.
pub(crate) fn start_worktree(
    scene: &Arc<Scene>,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration: &str,
    operation: KwtWorktreeOperation,
) -> Result<u64, WorkspaceError> {
    if matches!(operation, KwtWorktreeOperation::Remove { .. }) {
        return Err(WorkspaceError::new(
            "Use the removal confirmation for this worktree",
        ));
    }
    let mutation = matches!(
        operation,
        KwtWorktreeOperation::Create { .. } | KwtWorktreeOperation::ImportPullRequest { .. }
    );
    let task = {
        let publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = scene::lock_live_navigation(scene)?;
        let project = {
            let entries = scene
                .runtime
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let entry = entries
                .get(host_id)
                .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
            let context = current_remote_context(entry)
                .filter(|context| context.snapshot.endpoint() == endpoint)
                .ok_or_else(|| {
                    WorkspaceError::new("SSH endpoint changed; refresh and try again")
                })?;
            context
                .snapshot
                .lease()
                .ensure_live()
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            entry
                .kwt
                .inventory
                .as_ref()
                .and_then(|inventory| {
                    inventory.projects().iter().find(|item| {
                        item.project().repository() == repository
                            && item.project().path() == project_path
                            && item.project().registration_fingerprint() == registration
                    })
                })
                .map(|item| item.project().clone())
                .ok_or_else(|| {
                    WorkspaceError::new("Refresh KWT inventory before changing worktrees")
                })?
        };
        let mut task = reserve(scene, &publication, host_id, None)?;
        let mut entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let reservation = entries
            .get_mut(host_id)
            .unwrap()
            .kwt
            .operation
            .as_mut()
            .unwrap();
        reservation.mutation = mutation;
        reservation.listing = !mutation;
        task.worktree = Some(Request { project, operation });
        update_host(scene, host_id, |host| host.kwt_state = KwtState::Mutating);
        task
    };
    let operation = task.worktree.as_ref().unwrap().operation_id(task.id);
    schedule(scene, &task);
    Ok(operation)
}

pub(crate) fn cancel_listing(scene: &Arc<Scene>, id: u64) -> bool {
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
    for (host_id, entry) in entries.iter_mut() {
        if entry
            .kwt
            .operation
            .as_ref()
            .is_some_and(|op| op.id == id && op.scene_id == scene.id && op.listing)
        {
            entry.kwt.operation.take().unwrap().cancellation.cancel();
            update_host(scene, host_id, |host| host.kwt_state = KwtState::Ready);
            return true;
        }
    }
    false
}

pub(super) fn run(scene: &Arc<Scene>, task: &Task, request: &Request) {
    let result = execute(scene, task, request).and_then(|mut event| {
        if let WorkspaceEvent::KwtWorktreeCreated {
            navigation_generation,
            opening,
            ..
        } = &mut event
        {
            *opening = reserve_open(scene, task, *navigation_generation)?;
        }
        Ok(event)
    });
    // The UI may immediately open the result or submit the next operation.
    finish(scene, task);
    scene::push_lossless_event(
        scene,
        result.unwrap_or_else(|error| request.failure(task, error.to_string())),
    );
}

fn reserve_open(
    scene: &Scene,
    task: &Task,
    navigation: u64,
) -> Result<Option<crate::KwtWorktreeOpening>, WorkspaceError> {
    let _publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Ok(_navigation) = scene::lock_live_navigation(scene) else {
        return Ok(None);
    };
    if scene.navigation_generation.load(Ordering::Acquire) != navigation {
        return Ok(None);
    }
    let cancellation = host::CancellationToken::new();
    crate::register_remote_attachment(
        &scene.runtime,
        scene.id,
        &task.host_id,
        task.generation,
        &task.snapshot,
        navigation,
        &cancellation,
    )?;
    Ok(Some(crate::KwtWorktreeOpening { cancellation }))
}

fn execute(
    scene: &Arc<Scene>,
    task: &Task,
    request: &Request,
) -> Result<WorkspaceEvent, WorkspaceError> {
    let require_current = || {
        if !scene.closed.load(Ordering::Acquire) && publish(scene, task, |_, _| {}) {
            Ok(())
        } else {
            Err(WorkspaceError::new(
                "SSH connection changed during the worktree operation",
            ))
        }
    };
    require_current()?;
    let baseline =
        inventory(scene, task).map_err(|error| WorkspaceError::new(error.to_string()))?;
    let project = request.project_in(&baseline)?;
    require_current()?;
    match &request.operation {
        KwtWorktreeOperation::Branches => {
            let branches = task
                .host
                .list_kwt_branches(&task.snapshot, request.project.path(), &task.cancellation)
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            require_current()?;
            Ok(WorkspaceEvent::KwtBranchesLoaded {
                operation_id: task.id,
                project_path: request.project.path().to_owned(),
                branches: branches
                    .iter()
                    .map(|branch| {
                        KwtBranchItem::new(branch.name(), branch.source(), branch.is_remote())
                    })
                    .collect(),
            })
        }
        KwtWorktreeOperation::PullRequests => {
            let pull_requests = task
                .host
                .list_kwt_pull_requests(&task.snapshot, request.project.path(), &task.cancellation)
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            require_current()?;
            Ok(WorkspaceEvent::KwtPullRequestsLoaded {
                operation_id: task.id,
                project_path: request.project.path().to_owned(),
                pull_requests: pull_requests
                    .iter()
                    .map(crate::KwtPullRequestItem::from_host)
                    .collect(),
            })
        }
        KwtWorktreeOperation::ImportPullRequest {
            selector,
            navigation_generation,
        } => import_pull_request(scene, task, request, selector, *navigation_generation),
        KwtWorktreeOperation::Create {
            branch,
            source,
            creates_branch,
            navigation_generation,
        } => {
            let create = host::KwtWorktreeCreate::new(
                request.project.path(),
                request.project.repository(),
                request.project.registration_fingerprint(),
                branch,
                source.clone(),
                *creates_branch,
            );
            create_worktree(
                scene,
                task,
                request,
                project,
                &create,
                *navigation_generation,
            )
        }
        KwtWorktreeOperation::Remove { .. } => Err(WorkspaceError::new(
            "Use the removal confirmation for this worktree",
        )),
    }
}

// Only failed inventory reads affect the host's project availability. Provider
// errors and rejected mutations are reported by their owning dialog.
fn inventory(scene: &Scene, task: &Task) -> Result<host::KwtInventory, host::RemoteTmuxError> {
    task.host
        .discover_kwt(&task.snapshot, &task.cancellation)
        .inspect_err(|error| fail(scene, task, error))
}

fn create_worktree(
    scene: &Arc<Scene>,
    task: &Task,
    request: &Request,
    project: &host::KwtProjectInventory,
    create: &host::KwtWorktreeCreate,
    navigation_generation: u64,
) -> Result<WorkspaceEvent, WorkspaceError> {
    let baseline: Vec<_> = project
        .worktrees()
        .iter()
        .map(crate::kwt_worktree_identity)
        .collect();
    let result = task
        .host
        .create_kwt_worktree(&task.snapshot, create, &task.cancellation);
    if let Err(error) = &result
        && error.kind() != DiagnosticKind::Timeout
    {
        return Err(WorkspaceError::new(error.to_string()));
    }
    let inventory = inventory(scene, task).map_err(|error| {
        WorkspaceError::new(format!(
            "Worktree creation {}. Refresh the host before trying again: {error}",
            if result.is_ok() {
                "completed, but inventory could not be read"
            } else {
                "timed out and may have completed"
            }
        ))
    })?;
    let target = request
        .project_in(&inventory)?
        .worktrees()
        .iter()
        .find(|worktree| {
            worktree.branch() == create.branch()
                && !crate::kwt_identity_was_in_baseline(&baseline, worktree)
        })
        .map(|worktree| KwtWorktreeTarget {
            host_id: task.host_id.clone(),
            endpoint: task.snapshot.endpoint().to_owned(),
            repository: request.project.repository().to_owned(),
            project_path: request.project.path().to_owned(),
            registration_fingerprint: request.project.registration_fingerprint().to_owned(),
            worktree_path: worktree.path().to_owned(),
            generation: worktree.generation().map(str::to_owned),
            session_name: worktree.session_name().to_owned(),
            tmux_socket_name: worktree.tmux_socket_name().map(str::to_owned),
            tmux_attach_mode: worktree.tmux_attach_mode(),
        });
    if !publish(scene, task, |state, host| {
        scene::apply_kwt_inventory(host, &inventory);
        host.kwt_state = KwtState::Mutating;
        state.inventory = Some(inventory);
    }) {
        return Err(WorkspaceError::new(
            "SSH connection changed after worktree creation; refresh the host",
        ));
    }
    let target = target.ok_or_else(|| {
        WorkspaceError::new(
            "KWT has not reported the new worktree. Refresh the host before trying again.",
        )
    })?;
    Ok(WorkspaceEvent::KwtWorktreeCreated {
        target,
        navigation_generation,
        opening: None,
    })
}

fn import_pull_request(
    scene: &Arc<Scene>,
    task: &Task,
    request: &Request,
    selector: &str,
    navigation_generation: u64,
) -> Result<WorkspaceEvent, WorkspaceError> {
    let project = &request.project;
    let imported = task.host.import_kwt_pull_request(
        &task.snapshot,
        &host::KwtPullRequestImportRequest::new(
            project.path(),
            project.repository(),
            project.registration_fingerprint(),
            selector,
        ),
        &task.cancellation,
    );
    if let Err(error) = &imported
        && !matches!(
            error.kind(),
            DiagnosticKind::Timeout | DiagnosticKind::MalformedOutput
        )
    {
        return Err(WorkspaceError::new(error.to_string()));
    }
    // A timed-out mutation may have committed. Refresh once, never replay it.
    let inventory = inventory(scene, task).map_err(|error| {
        WorkspaceError::new(format!(
            "Pull-request import {}, but inventory could not be read. Refresh the host before trying again: {error}",
            if imported.is_ok() { "completed" } else { "may have completed" }
        ))
    })?;
    let target = imported.as_ref().ok().and_then(|imported| {
        let workspace = imported.workspace();
        let same_repository = |identity: &str| {
            identity == project.repository()
                || (project.repository().starts_with("github.com/")
                    && identity.eq_ignore_ascii_case(project.repository()))
        };
        if !same_repository(imported.project_identity())
            || imported.project_path() != project.path()
            || !same_repository(workspace.repository())
            || workspace.generation().is_none()
        {
            return None;
        }
        request
            .project_in(&inventory)
            .ok()?
            .worktrees()
            .iter()
            .find(|worktree| {
                worktree.path() == workspace.path()
                    && worktree.generation() == workspace.generation()
                    && worktree.session_name() == workspace.session_name()
                    && worktree.tmux_socket_name() == workspace.tmux_socket_name()
                    && worktree.tmux_attach_mode() == workspace.tmux_attach_mode()
            })
            .map(|worktree| KwtWorktreeTarget {
                host_id: task.host_id.clone(),
                endpoint: task.snapshot.endpoint().to_owned(),
                repository: project.repository().to_owned(),
                project_path: project.path().to_owned(),
                registration_fingerprint: project.registration_fingerprint().to_owned(),
                worktree_path: worktree.path().to_owned(),
                generation: worktree.generation().map(str::to_owned),
                session_name: worktree.session_name().to_owned(),
                tmux_socket_name: worktree.tmux_socket_name().map(str::to_owned),
                tmux_attach_mode: worktree.tmux_attach_mode(),
            })
    });
    if !publish(scene, task, |state, host| {
        scene::apply_kwt_inventory(host, &inventory);
        host.kwt_state = KwtState::Mutating;
        state.inventory = Some(inventory);
    }) {
        return Err(WorkspaceError::new(
            "SSH connection changed during import; refresh the host",
        ));
    }
    if let Err(error) = imported {
        return Err(WorkspaceError::new(format!(
            "Pull-request import may have completed. Inventory has been refreshed; check the project before trying again. {error}"
        )));
    }
    let target = target.ok_or_else(|| WorkspaceError::new(
        "The imported pull request changed before inventory could confirm it. Refresh and choose it again."
    ))?;
    Ok(WorkspaceEvent::KwtWorktreeCreated {
        target,
        navigation_generation,
        opening: None,
    })
}
