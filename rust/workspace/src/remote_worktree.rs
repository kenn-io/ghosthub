use crate::{
    Arc, AttachTerm, CancellationToken, HostConnectionState, KwtInventory, KwtTmuxAttachMode,
    ProjectItem, RemoteAttachmentReset, RemotePresentationKey, RemotePublicationFence,
    RemoteSessionIdentity, RemoteTmuxSnapshot, RuntimeRemoteHost, Scene, SessionKind,
    SessionSelection, TerminalWorker, WORKTREE_CLIENT_STARTUP_BACKOFF, Workspace, WorkspaceError,
    WorkspaceEvent, WorktreeClientStartupError, WorktreeItem, clear_remote_attachment_registration,
    current_default_colors, current_default_cursor_shape, current_remote_clipboard_policy,
    current_remote_context, lock_live_navigation, lock_session_operations, next_presentation_id,
    register_remote_attachment, runtime, scene, validate_remote_publication_fence,
    wait_for_worktree_client_startup,
};
use host::RemoteTmuxServer;

struct Request {
    host_id: String,
    connection_generation: u64,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    project: ProjectItem,
    worktree: WorktreeItem,
    prior_session: Option<session::DiscoveredSession>,
}

impl Request {
    fn selection(&self) -> SessionSelection {
        SessionSelection::kwt_workspace(
            &self.host_id,
            self.snapshot.endpoint(),
            &self.worktree.session_name,
            self.worktree.tmux_attach_mode,
            self.worktree.tmux_socket_name.clone(),
            &self.worktree.path,
            self.worktree.generation.clone(),
        )
    }

    fn validate(&self, inventory: &KwtInventory) -> Result<RemoteTmuxServer, WorkspaceError> {
        let row = inventory
            .projects()
            .iter()
            .find(|item| {
                let project = item.project();
                project.repository() == self.project.repository
                    && project.path() == self.project.path
                    && project.registration_fingerprint() == self.project.registration_fingerprint
            })
            .and_then(|project| {
                project.worktrees().iter().find(|worktree| {
                    worktree.path() == self.worktree.path
                        && worktree.generation() == self.worktree.generation.as_deref()
                        && worktree.session_name() == self.worktree.session_name
                        && worktree.tmux_attach_mode() == KwtTmuxAttachMode::Direct
                })
            })
            .ok_or_else(|| {
                WorkspaceError::new("The worktree identity changed; refresh and try again")
            })?;
        match row.tmux_socket_name() {
            None => Ok(RemoteTmuxServer::Default),
            Some("kwt") => Ok(RemoteTmuxServer::Kwt),
            Some(_) => Err(WorkspaceError::new(
                "This worktree uses an unsupported tmux server",
            )),
        }
    }
}

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    reason = "capture and navigation reservation share one live navigation fence"
)]
pub(super) fn open(
    workspace: &Workspace,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: Option<&str>,
    session_name: &str,
    socket: Option<&str>,
    mode: KwtTmuxAttachMode,
) -> Result<(), WorkspaceError> {
    let scene = &workspace.scene;
    let _navigation = lock_live_navigation(scene)?;
    let request = {
        let entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = entries
            .get(host_id)
            .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
        let context = current_remote_context(entry).ok_or_else(|| {
            WorkspaceError::new("Connect this SSH host before opening a worktree")
        })?;
        if context.snapshot.endpoint() != endpoint {
            return Err(WorkspaceError::new(
                "SSH endpoint changed; refresh and try again",
            ));
        }
        let hosts = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let host = hosts
            .iter()
            .find(|host| {
                host.id == host_id
                    && host.connection == HostConnectionState::Ready
                    && host.kwt_available()
            })
            .ok_or_else(|| {
                WorkspaceError::new("Refresh KWT inventory before opening this worktree")
            })?;
        let project = host
            .projects
            .iter()
            .find(|project| {
                project.repository == repository
                    && project.path == project_path
                    && project.registration_fingerprint == registration_fingerprint
            })
            .ok_or_else(|| {
                WorkspaceError::new("The project registration changed; refresh and try again")
            })?;
        let worktree = project
            .worktrees
            .iter()
            .find(|worktree| {
                worktree.path == worktree_path
                    && worktree.generation.as_deref() == generation
                    && generation.is_some()
                    && worktree.session_name == session_name
                    && worktree.tmux_socket_name.as_deref() == socket
                    && worktree.tmux_attach_mode == mode
                    && mode == KwtTmuxAttachMode::Direct
                    && matches!(socket, None | Some("kwt"))
            })
            .ok_or_else(|| {
                WorkspaceError::new("The worktree identity changed; refresh and try again")
            })?;
        Request {
            host_id: host_id.to_owned(),
            connection_generation: entry.generation,
            host: context.host.clone(),
            snapshot: context.snapshot.clone(),
            project: project.clone(),
            worktree: worktree.clone(),
            prior_session: context
                .snapshot
                .sessions_on(if socket == Some("kwt") {
                    RemoteTmuxServer::Kwt
                } else {
                    RemoteTmuxServer::Default
                })
                .iter()
                .find(|session| session.name() == session_name)
                .cloned(),
        }
    };
    let selection = request.selection();
    let navigation_generation = workspace.begin_navigation();
    workspace.settle_local_navigation_before_remote()?;
    let key = workspace.remote_presentation_key(&selection);
    if scene
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|active| key.as_ref().is_some_and(|key| active.key == *key))
    {
        return workspace.refresh_active_remote_selection(&selection, key.as_ref());
    }
    if workspace.activate_remote_retained(&selection, key.as_ref())? {
        return Ok(());
    }
    let cancellation = CancellationToken::new();
    register_remote_attachment(
        &scene.runtime,
        scene.id,
        host_id,
        request.connection_generation,
        &request.snapshot,
        navigation_generation,
        &cancellation,
    )?;
    let task_scene = Arc::clone(scene);
    if let Err(error) = scene.runtime.refresh_runtime.spawn(
        "ghosthub-remote-worktree",
        Box::new(move || {
            run(&task_scene, request, navigation_generation, &cancellation);
        }),
    ) {
        clear_remote_attachment_registration(&scene.runtime, host_id, navigation_generation);
        return Err(WorkspaceError::new(error.to_string()));
    }
    Ok(())
}

#[allow(
    clippy::too_many_lines,
    reason = "revalidation and publication remain one ordered lifecycle operation"
)]
fn run(scene: &Scene, mut request: Request, navigation: u64, cancellation: &CancellationToken) {
    let host_id = request.host_id.clone();
    let _reset = RemoteAttachmentReset {
        scene,
        host_id: &host_id,
        navigation_generation: navigation,
    };
    let Some(_operation) = lock_session_operations(scene, cancellation) else {
        return;
    };
    let result = (|| {
        let (host, snapshot) = runtime::recapture_remote_attachment_context(
            &scene.runtime,
            &host_id,
            request.connection_generation,
            &request.snapshot,
        )?;
        request.host = host;
        request.snapshot = snapshot;
        if !scene::remote_attachment_is_current(scene, &host_id, navigation, cancellation) {
            return Ok(());
        }
        // A queued open of a running session must not undo a preceding confirmed kill.
        if let Some(prior) = &request.prior_session {
            let current = request
                .host
                .capture_live_session(
                    &request.snapshot,
                    request.selection().remote_tmux_server()?,
                    prior.name(),
                    cancellation,
                )
                .map_err(error)?;
            if current.identity() != prior.identity() {
                return Err(WorkspaceError::new(
                    "The worktree session changed; refresh and try again",
                ));
            }
        }
        let inventory = request
            .host
            .discover_kwt(&request.snapshot, cancellation)
            .map_err(error)?;
        let server = request.validate(&inventory)?;
        let (worker, term, identity) = launch(scene, &request, server, navigation, cancellation)?;
        let inventory = request
            .host
            .discover_kwt(&request.snapshot, cancellation)
            .map_err(error)?;
        if request.validate(&inventory)? != server {
            return Err(WorkspaceError::new(
                "KWT attached to a different tmux server; refresh and try again",
            ));
        }
        let inventory = request
            .host
            .refresh(request.snapshot.lease(), cancellation)
            .map_err(error)?;
        let snapshot = request.snapshot.with_inventory(inventory.clone());
        let session = snapshot
            .sessions_on(server)
            .iter()
            .find(|session| {
                session.name() == request.worktree.session_name && session.identity() == &identity
            })
            .ok_or_else(|| WorkspaceError::new("KWT client does not match the worktree session"))?
            .clone();
        let snapshot = scene::publish_remote_inventory(
            scene,
            &host_id,
            request.connection_generation,
            &request.snapshot,
            cancellation,
            inventory,
        )?;
        let _navigation = lock_live_navigation(scene)?;
        if !scene::remote_attachment_is_current(scene, &host_id, navigation, cancellation) {
            return Ok(());
        }
        let key = RemotePresentationKey {
            host_id: host_id.clone(),
            endpoint: snapshot.endpoint().to_owned(),
            route_identity: snapshot.route_identity().to_owned(),
            lease_generation: snapshot.lease_generation(),
            session_identity: RemoteSessionIdentity::tmux(server, identity),
        };
        let selection = key.selection(SessionKind::Tmux, session.name());
        scene::publish_remote_worker(
            scene,
            worker,
            key,
            &selection,
            snapshot.lease().clone(),
            next_presentation_id(&scene.runtime),
            term,
            None,
            Some(&RemotePublicationFence {
                host_id: &host_id,
                connection_generation: request.connection_generation,
                snapshot: &snapshot,
                cancellation,
            }),
        )
        .map_err(|error| error.error)?;
        Ok(())
    })();
    if let Err(error) = result
        && scene::remote_attachment_is_current(scene, &host_id, navigation, cancellation)
    {
        scene::push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
    }
}

fn launch(
    scene: &Scene,
    request: &Request,
    server: RemoteTmuxServer,
    navigation: u64,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, AttachTerm, session::SessionIdentity), WorkspaceError> {
    let term = request
        .host
        .probe_terminal_term(&request.snapshot, cancellation)
        .map_err(error)?;
    let open = host::KwtWorktreeOpen::new(
        &request.worktree.path,
        &request.project.repository,
        &request.project.registration_fingerprint,
        request
            .worktree
            .generation
            .as_ref()
            .expect("captured generation"),
        &request.worktree.session_name,
    );
    let plan = request
        .host
        .kwt_worktree_open_plan(&request.snapshot, &open, term.as_str(), cancellation)
        .map_err(error)?;
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (fence, worker) = scene::with_current_remote_attachment_launch(
        scene,
        &request.host_id,
        navigation,
        cancellation,
        || {
            let entries = scene
                .runtime
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let entry = entries
                .get(&request.host_id)
                .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
            validate_remote_publication_fence(
                entry,
                &RemotePublicationFence {
                    host_id: &request.host_id,
                    connection_generation: request.connection_generation,
                    snapshot: &request.snapshot,
                    cancellation,
                },
            )?;
            TerminalWorker::repair_or_open_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                current_remote_clipboard_policy(&scene.runtime),
                current_default_colors(&scene.runtime),
                current_default_cursor_shape(&scene.runtime),
            )
            .map_err(error)
        },
    )?;
    drop(fence);
    let identity = wait_for_worktree_client_startup(
        term,
        cancellation,
        &WORKTREE_CLIENT_STARTUP_BACKOFF,
        || worker.startup_status().map_err(error),
        || {
            request
                .host
                .kwt_client_identity(&request.snapshot, &plan, server, cancellation)
                .map_err(error)
        },
    );
    request
        .host
        .remove_kwt_client_readiness(&request.snapshot, &plan);
    let identity = identity.map_err(|error| match error {
        WorktreeClientStartupError::Failed(error) => error,
        WorktreeClientStartupError::RetryWithXterm => {
            WorkspaceError::new("Remote terminfo changed; reconnect and try again")
        }
    })?;
    Ok((worker, term, identity))
}

fn error(error: impl std::fmt::Display) -> WorkspaceError {
    WorkspaceError::new(error.to_string())
}
