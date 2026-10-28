use crate::{
    CancellationToken, DiagnosticKind, HerdrInventory, HerdrLifecycleAction, HerdrSessionState,
    PendingHerdrLifecycle, RemoteHerdrAttachRequest, RemotePresentationKey, RemoteSessionIdentity,
    Scene, SessionKind, SessionSelection, Workspace, WorkspaceError, begin_snapshot_write,
    current_remote_context, drop_matching_confirmations, finish_herdr_lifecycle_state,
    lock_live_navigation, lock_session_operations, next_operation_id, require_host_session_actions,
    runtime, scene,
};

#[derive(Clone)]
pub(crate) struct RemoteHerdrLifecycle {
    pub(crate) generation: u64,
    pub(crate) operation_id: u64,
    pub(crate) action: HerdrLifecycleAction,
    pub(crate) request: RemoteHerdrAttachRequest,
}

pub(crate) fn capture(
    scene: &Scene,
    selection: &SessionSelection,
    action: HerdrLifecycleAction,
    generation: u64,
) -> Result<RemoteHerdrLifecycle, WorkspaceError> {
    require_host_session_actions(&scene.runtime, selection)?;
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "Herdr lifecycle actions require a Herdr session",
        ));
    }
    let entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before changing a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before trying again",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = context.snapshot.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    let record = sessions
        .iter()
        .find(|record| record.name() == selection.session())
        .filter(|record| record.state() == action.expected_state())
        .cloned()
        .ok_or_else(|| WorkspaceError::new("Herdr session changed; refresh before trying again"))?;
    if action == HerdrLifecycleAction::Delete && record.is_default() {
        return Err(WorkspaceError::new(
            "Herdr's default session cannot be deleted",
        ));
    }
    if matches!(entry.constructive_cancellation.as_ref(),
        Some(crate::RemoteConstructiveState::Active { target: crate::RemoteConstructiveTarget::Herdr { name, .. }, .. }
            | crate::RemoteConstructiveState::PendingReconciliation(crate::RemoteConstructiveTarget::Herdr { name, .. }))
            if name == selection.session())
    {
        return Err(WorkspaceError::new("a remote session is still starting"));
    }
    Ok(RemoteHerdrLifecycle {
        generation,
        operation_id: next_operation_id(&scene.runtime),
        action,
        request: RemoteHerdrAttachRequest {
            host_id: selection.host_id().to_owned(),
            connection_generation: entry.generation,
            selection: selection.clone(),
            host: context.host.clone(),
            snapshot: context.snapshot.clone(),
            executable: executable.clone(),
            session: record,
        },
    })
}

pub(crate) fn run(workspace: &Workspace, pending: &RemoteHerdrLifecycle) {
    let cancellation = CancellationToken::new();
    let _operation = lock_session_operations(&workspace.scene, &cancellation);
    let request = &pending.request;
    let mut suppressed = Vec::new();
    let result =
        (|| {
            {
                let _navigation = lock_live_navigation(&workspace.scene)?;
                runtime::recapture_remote_attachment_context(
                    &workspace.scene.runtime,
                    &request.host_id,
                    request.connection_generation,
                    &request.snapshot,
                )?;
            }
            request
                .host
                .mutate_herdr_session(
                    &request.snapshot,
                    &request.executable,
                    &request.session,
                    pending.action,
                    &cancellation,
                    || {
                        // Connection changes and presentation suppression share this fence.
                        let _publication = workspace
                            .scene
                            .runtime
                            .remote_publication
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        let is_current = || {
                            !workspace.scene.closed.load(crate::Ordering::Acquire)
                                && runtime::recapture_remote_attachment_context(
                                    &workspace.scene.runtime,
                                    &request.host_id,
                                    request.connection_generation,
                                    &request.snapshot,
                                )
                                .is_ok()
                        };
                        if !is_current() {
                            return false;
                        }
                        if pending.action == HerdrLifecycleAction::Stop {
                            suppressed.extend(workspace.close_remote_presentations(|key| {
                                matches_presentation(request, key)
                            }));
                        }
                        is_current()
                    },
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))
        })();
    if result.is_ok() {
        finish_presentations(workspace, pending);
    }
    let refreshed = refresh(workspace, pending, &cancellation);
    let restore = result.is_err();
    let fresh_running = matches!(refreshed, Ok(Some(true)));
    let mut operation_error = result.err().map(|error| error.to_string());
    match refreshed {
        Ok(Some(false)) => finish_presentations(workspace, pending),
        Ok(_) => {}
        Err(error) => {
            publish_refresh_failure(workspace, request, &error);
            operation_error = Some(format!(
                "{}; refresh failed: {error}",
                operation_error
                    .unwrap_or_else(|| format!("Herdr {} completed", pending.action.command()))
            ));
        }
    }
    finish_herdr_lifecycle_state(&workspace.scene.runtime, pending.operation_id);
    if restore {
        crate::remote_recovery::schedule(
            workspace,
            crate::remote_recovery::Target::Herdr(request.clone()),
            suppressed,
            fresh_running,
        );
    }
    if let Some(error) = operation_error {
        workspace.push_operation_error(error);
    }
}

fn publish_refresh_failure(
    workspace: &Workspace,
    request: &RemoteHerdrAttachRequest,
    error: &WorkspaceError,
) {
    // Keep a failed backend refresh visible without disabling another multiplexer.
    let _snapshot_write = begin_snapshot_write(&workspace.scene.runtime);
    let entries = workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if entries.get(&request.host_id).is_some_and(|entry| {
        entry.generation == request.connection_generation
            && current_remote_context(entry).is_some_and(|context| {
                context.snapshot.route_identity() == request.snapshot.route_identity()
                    && context.snapshot.lease_generation() == request.snapshot.lease_generation()
            })
    }) {
        let mut hosts = workspace
            .scene
            .runtime
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(host) = hosts.iter_mut().find(|host| host.id == request.host_id) {
            host.herdr_diagnostic = Some(crate::HostDiagnostic::new(
                DiagnosticKind::Transport,
                error.to_string(),
            ));
        }
    }
}

fn refresh(
    workspace: &Workspace,
    pending: &RemoteHerdrLifecycle,
    cancellation: &CancellationToken,
) -> Result<Option<bool>, WorkspaceError> {
    let request = &pending.request;
    while let Ok((host, snapshot)) = runtime::recapture_remote_attachment_context(
        &workspace.scene.runtime,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    ) {
        let inventory = host
            .refresh(snapshot.lease(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let still_running = match inventory.herdr() {
            HerdrInventory::Available {
                executable,
                sessions,
            } => {
                executable == &request.executable
                    && sessions.iter().any(|record| {
                        record.name() == request.session.name()
                            && record.is_default() == request.session.is_default()
                            && record.session_directory() == request.session.session_directory()
                            && record.socket_path() == request.session.socket_path()
                            && record.state() == HerdrSessionState::Running
                    })
            }
            HerdrInventory::Unavailable => false,
            HerdrInventory::Failed(error) => return Err(WorkspaceError::new(error.to_string())),
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
            return Ok(Some(still_running));
        }
    }
    Ok(None)
}

fn finish_presentations(workspace: &Workspace, pending: &RemoteHerdrLifecycle) {
    let request = &pending.request;
    drop_matching_confirmations(
        &workspace.scene.runtime,
        |scene| &scene.pending_herdr_lifecycle,
        |other| {
            matches!(other, PendingHerdrLifecycle::Remote(other)
            if other.request.selection == request.selection
                && other.request.connection_generation == request.connection_generation)
        },
    );
    workspace.close_remote_presentations(|key| matches_presentation(request, key));
}

fn matches_presentation(request: &RemoteHerdrAttachRequest, key: &RemotePresentationKey) -> bool {
    let identity = RemoteSessionIdentity::Herdr {
        name: request.session.name().to_owned(),
        is_default: request.session.is_default(),
        session_directory: request.session.session_directory().to_owned(),
        socket_path: request.session.socket_path().to_owned(),
    };
    key.host_id == request.host_id
        && key.endpoint == request.snapshot.endpoint()
        && key.route_identity == request.snapshot.route_identity()
        && key.lease_generation == request.snapshot.lease_generation()
        && key.session_identity == identity
}
