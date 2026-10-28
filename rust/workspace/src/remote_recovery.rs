use crate::{
    RemoteHerdrAttachRequest, RemoteTmuxSnapshot, RemoteZellijAttachRequest, Runtime, SceneId,
    Workspace, WorkspaceError, lock_live_navigation, runtime,
};

#[derive(Clone)]
pub(crate) enum Target {
    Herdr(RemoteHerdrAttachRequest),
    Zellij(RemoteZellijAttachRequest),
}

impl Target {
    fn connection(&self) -> (&str, u64, &RemoteTmuxSnapshot) {
        match self {
            Self::Herdr(request) => (
                &request.host_id,
                request.connection_generation,
                &request.snapshot,
            ),
            Self::Zellij(request) => (
                &request.host_id,
                request.connection_generation,
                &request.snapshot,
            ),
        }
    }

    fn recapture(&self, runtime: &Runtime) -> Result<Self, WorkspaceError> {
        let fresh = match self {
            Self::Herdr(old) => {
                let fresh = runtime::capture_remote_herdr_attach_request(runtime, &old.selection)?;
                crate::resolve_remote_herdr_attach_target(
                    fresh.snapshot.herdr(),
                    &old.executable,
                    &old.session,
                )?;
                Self::Herdr(fresh)
            }
            Self::Zellij(old) => {
                crate::remote_zellij::require_attach_revision(runtime, old)?;
                let fresh = runtime::capture_remote_zellij_attach_request(runtime, &old.selection)?;
                crate::resolve_remote_zellij_attach_target(
                    fresh.snapshot.zellij(),
                    &old.executable,
                    &old.name,
                )?;
                Self::Zellij(fresh)
            }
        };
        if fresh.connection().2.route_identity() != self.connection().2.route_identity() {
            return Err(WorkspaceError::new(
                "the SSH route changed before session recovery",
            ));
        }
        Ok(fresh)
    }

    fn restore(&self, workspace: &Workspace) -> Result<(), WorkspaceError> {
        let navigation = workspace.begin_navigation();
        match self {
            Self::Herdr(request) => {
                workspace.start_remote_herdr_attachment(request.clone(), navigation)
            }
            Self::Zellij(request) => {
                workspace.start_remote_zellij_attachment(request.clone(), navigation)
            }
        }
    }
}

pub(crate) struct Recovery {
    target: Target,
    scenes: Vec<(SceneId, u64)>,
}

pub(crate) fn schedule(
    workspace: &Workspace,
    target: Target,
    scenes: Vec<(SceneId, u64)>,
    fresh_running: bool,
) {
    if scenes.is_empty() {
        return;
    }
    let runtime = &workspace.scene.runtime;
    let _publication = runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (host_id, generation, _) = target.connection();
    let host_id = host_id.to_owned();
    let Some(entry) = entries.get_mut(&host_id) else {
        return;
    };
    // A replacement connection supplies its own fresh inventory after reconnect.
    if entry.generation == generation && !fresh_running {
        return;
    }
    entry.session_recoveries.push(Recovery { target, scenes });
    drop(entries);
    restore_pending(runtime, &host_id);
}

/// Called under the publication fence, after publishing fresh inventory.
pub(crate) fn restore_pending(runtime: &Runtime, host_id: &str) {
    let recoveries = {
        let mut entries = runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(entry) = entries.get_mut(host_id) else {
            return;
        };
        if entry.cancellation.is_some() {
            return;
        }
        std::mem::take(&mut entry.session_recoveries)
    };
    for recovery in recoveries {
        let Ok(target) = recovery.target.recapture(runtime) else {
            continue;
        };
        for (scene_id, navigation_generation) in recovery.scenes {
            let Some(scene) = runtime::scene_by_id(runtime, scene_id) else {
                continue;
            };
            let Ok(_navigation) = lock_live_navigation(&scene) else {
                continue;
            };
            if scene.navigation_generation.load(crate::Ordering::Acquire) != navigation_generation {
                continue;
            }
            let workspace = Workspace {
                scene: crate::Arc::clone(&scene),
            };
            if let Err(error) = target.restore(&workspace) {
                workspace.push_operation_error(error.to_string());
            }
        }
    }
}
