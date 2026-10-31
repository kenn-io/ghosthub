use super::{
    Arc, DiagnosticKind, KwtState, Ordering, Scene, Task, WorkspaceError, WorkspaceEvent,
    current_remote_context, fail, finish, publish, reserve, scene, schedule, update_host,
};
use crate::{KwtBranchItem, KwtWorktreeOperation, KwtWorktreeTarget};

#[derive(Clone)]
pub(super) struct Request {
    project: host::KwtProject,
    create: Option<(host::KwtWorktreeCreate, u64)>,
}

impl Request {
    pub(super) fn failure(&self, task: &Task, message: String) -> WorkspaceEvent {
        WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: self
                .create
                .as_ref()
                .map_or(task.id, |(_, navigation)| *navigation),
            project_path: self.project.path().to_owned(),
            worktree_path: None,
            message,
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
                    "The selected project changed; refresh it before creating a worktree",
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
    let create = match operation {
        KwtWorktreeOperation::Branches => None,
        KwtWorktreeOperation::Create {
            branch,
            source,
            creates_branch,
            navigation_generation,
        } => Some((
            host::KwtWorktreeCreate::new(
                project_path,
                repository,
                registration,
                branch,
                source,
                creates_branch,
            ),
            navigation_generation,
        )),
        _ => {
            return Err(WorkspaceError::new(
                "This worktree operation is not available over SSH",
            ));
        }
    };
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
        let operation = entries
            .get_mut(host_id)
            .unwrap()
            .kwt
            .operation
            .as_mut()
            .unwrap();
        operation.mutation = create.is_some();
        operation.listing = create.is_none();
        task.worktree = Some(Request { project, create });
        update_host(scene, host_id, |host| host.kwt_state = KwtState::Mutating);
        task
    };
    let operation = task
        .worktree
        .as_ref()
        .unwrap()
        .create
        .as_ref()
        .map_or(task.id, |(_, navigation)| *navigation);
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
    let result = execute(scene, task, request);
    if let Err(error) = &result {
        fail(scene, task, error);
    }
    // The UI may immediately open the result or submit the next operation.
    finish(scene, task);
    scene::push_lossless_event(
        scene,
        result.unwrap_or_else(|error| request.failure(task, error.to_string())),
    );
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
    let baseline = task
        .host
        .discover_kwt(&task.snapshot, &task.cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let project = request.project_in(&baseline)?;
    require_current()?;
    let Some((create, navigation_generation)) = &request.create else {
        let branches = task
            .host
            .list_kwt_branches(&task.snapshot, request.project.path(), &task.cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        require_current()?;
        return Ok(WorkspaceEvent::KwtBranchesLoaded {
            operation_id: task.id,
            project_path: request.project.path().to_owned(),
            branches: branches
                .iter()
                .map(|branch| {
                    KwtBranchItem::new(branch.name(), branch.source(), branch.is_remote())
                })
                .collect(),
        });
    };
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
    let inventory = task
        .host
        .discover_kwt(&task.snapshot, &task.cancellation)
        .map_err(|error| {
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
        navigation_generation: *navigation_generation,
    })
}
