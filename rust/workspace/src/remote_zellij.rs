use crate::{
    CancellationToken, KillTarget, RemotePresentationKey, RemoteSessionIdentity,
    RemoteZellijAttachRequest, Runtime, Workspace, WorkspaceError, ZellijInventory, ZellijKillKey,
    begin_snapshot_write, drop_matching_kill_confirmations, lock_live_navigation,
    release_zellij_kill, remote_recovery, runtime, scene, zellij_kill_is_current,
};

pub(crate) fn key_for(host_id: &str, route: &str, name: &str) -> ZellijKillKey {
    (host_id.to_owned(), route.to_owned(), name.to_owned())
}

pub(crate) fn key(request: &RemoteZellijAttachRequest) -> ZellijKillKey {
    key_for(
        &request.host_id,
        request.snapshot.route_identity(),
        &request.name,
    )
}

pub(crate) fn require_attach_revision(
    runtime: &Runtime,
    request: &RemoteZellijAttachRequest,
) -> Result<(), WorkspaceError> {
    if !zellij_kill_is_current(runtime, &key(request), request.kill_revision) {
        return Err(WorkspaceError::new(
            "the Zellij session was killed after this request",
        ));
    }
    Ok(())
}

pub(crate) fn run(workspace: &Workspace, request: &RemoteZellijAttachRequest) {
    let cancellation = CancellationToken::new();
    let mut suppressed = Vec::new();
    let result = (|| {
        {
            let _navigation = lock_live_navigation(&workspace.scene)?;
            require_attach_revision(&workspace.scene.runtime, request)?;
            runtime::recapture_remote_attachment_context(
                &workspace.scene.runtime,
                &request.host_id,
                request.connection_generation,
                &request.snapshot,
            )?;
        }
        request
            .host
            .kill_zellij_session(
                &request.snapshot,
                &request.executable,
                &request.name,
                &cancellation,
                || {
                    let _publication = workspace
                        .scene
                        .runtime
                        .remote_publication
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    let current = || {
                        !workspace.scene.closed.load(crate::Ordering::Acquire)
                            && runtime::recapture_remote_attachment_context(
                                &workspace.scene.runtime,
                                &request.host_id,
                                request.connection_generation,
                                &request.snapshot,
                            )
                            .is_ok()
                    };
                    if !current() {
                        return false;
                    }
                    suppressed.extend(
                        workspace
                            .close_remote_presentations(|key| matches_presentation(request, key)),
                    );
                    current()
                },
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))
    })();
    let succeeded = result.is_ok();
    if succeeded {
        finish(workspace, request);
        remove_inventory(workspace, request);
    }
    release_zellij_kill(&workspace.scene.runtime, &key(request), succeeded);
    let refreshed = refresh(workspace, request, &cancellation);
    let fresh_running = matches!(refreshed, Ok(Some(true)));
    if matches!(refreshed, Ok(Some(false))) {
        finish(workspace, request);
    }
    if !succeeded {
        remote_recovery::schedule(
            workspace,
            remote_recovery::Target::Zellij(request.clone()),
            suppressed,
            fresh_running,
        );
    }
    if let Err(error) = result {
        workspace.push_operation_error(error.to_string());
    }
    if let Err(error) = refreshed {
        workspace.push_operation_error(format!("Zellij inventory refresh failed: {error}"));
    }
}

fn matches_presentation(request: &RemoteZellijAttachRequest, key: &RemotePresentationKey) -> bool {
    key.host_id == request.host_id
        && key.endpoint == request.snapshot.endpoint()
        && key.route_identity == request.snapshot.route_identity()
        && key.lease_generation == request.snapshot.lease_generation()
        && key.session_identity == RemoteSessionIdentity::Zellij(request.name.clone())
}

fn finish(workspace: &Workspace, request: &RemoteZellijAttachRequest) {
    drop_matching_kill_confirmations(
        &workspace.scene.runtime,
        |pending| {
            matches!(&pending.target, KillTarget::RemoteZellij(other)
            if key(other) == key(request))
        },
        |selection| selection == &request.selection,
    );
    workspace.close_remote_presentations(|key| matches_presentation(request, key));
}

fn remove_inventory(workspace: &Workspace, request: &RemoteZellijAttachRequest) {
    let runtime = &workspace.scene.runtime;
    let _publication = runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _write = begin_snapshot_write(runtime);
    let mut entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get_mut(&request.host_id) else {
        return;
    };
    if entry.generation != request.connection_generation {
        return;
    }
    let Some(context) = entry.context.as_mut() else {
        return;
    };
    if context.snapshot.route_identity() != request.snapshot.route_identity()
        || context.snapshot.lease_generation() != request.snapshot.lease_generation()
    {
        return;
    }
    context.snapshot = context
        .snapshot
        .clone()
        .without_zellij_session(&request.name);
    let snapshot = context.snapshot.clone();
    drop(entries);
    runtime::set_remote_host_snapshot(runtime, &request.host_id, &snapshot);
}

fn refresh(
    workspace: &Workspace,
    request: &RemoteZellijAttachRequest,
    cancellation: &CancellationToken,
) -> Result<Option<bool>, WorkspaceError> {
    while let Ok((host, snapshot)) = runtime::recapture_remote_attachment_context(
        &workspace.scene.runtime,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    ) {
        let inventory = host
            .refresh(snapshot.lease(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let active = match inventory.zellij() {
            ZellijInventory::Available {
                executable,
                sessions,
            } => {
                executable == &request.executable
                    && sessions
                        .iter()
                        .any(|session| session.name() == request.name)
            }
            ZellijInventory::Unavailable => false,
            ZellijInventory::Failed(error) => return Err(WorkspaceError::new(error.to_string())),
        };
        if scene::publish_remote_inventory(
            &workspace.scene,
            &request.host_id,
            request.connection_generation,
            &snapshot,
            cancellation,
            inventory,
        )
        .is_ok()
        {
            return Ok(Some(active));
        }
    }
    Ok(None)
}
