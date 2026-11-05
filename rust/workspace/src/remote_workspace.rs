use crate::{
    Arc, AttachTerm, CancellationToken, DirectoryWorkspaceItem, HostConnectionState, KwtInventory,
    KwtTmuxAttachMode, ProjectItem, RemoteAttachmentReset, RemotePresentationKey,
    RemotePublicationFence, RemoteSessionIdentity, RemoteTmuxSnapshot, RuntimeRemoteHost, Scene,
    SessionKind, SessionSelection, TerminalWorker, WORKTREE_CLIENT_STARTUP_BACKOFF, Workspace,
    WorkspaceError, WorkspaceEvent, WorktreeClientStartupError, WorktreeItem,
    clear_remote_attachment_registration, current_default_colors, current_default_cursor_shape,
    current_remote_clipboard_policy, current_remote_context, lock_live_navigation,
    lock_session_operations, next_presentation_id, register_remote_attachment, runtime, scene,
    validate_remote_publication_fence, wait_for_worktree_client_startup,
};
use host::RemoteTmuxServer;

#[derive(Eq, Hash, PartialEq)]
pub(crate) struct KillKey {
    host_id: String,
    endpoint: String,
    route_identity: String,
    socket: String,
    session: String,
}

impl KillKey {
    fn new(selection: &SessionSelection, snapshot: &RemoteTmuxSnapshot) -> Self {
        Self {
            host_id: selection.host_id().to_owned(),
            endpoint: snapshot.endpoint().to_owned(),
            route_identity: snapshot.route_identity().to_owned(),
            socket: selection
                .tmux_socket_name()
                .expect("protected socket")
                .to_owned(),
            session: selection.session().to_owned(),
        }
    }
}

// The session operation lane keeps this advance ordered with queued opens.
pub(crate) fn record_kill(runtime: &runtime::Runtime, request: &crate::RemoteTmuxAttachRequest) {
    if request.selection.tmux_attach_mode() == Some(KwtTmuxAttachMode::Protected) {
        let mut revisions = runtime
            .protected_tmux_kills
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let revision = revisions
            .entry(KillKey::new(&request.selection, &request.snapshot))
            .or_default();
        *revision = revision
            .checked_add(1)
            .expect("protected Kill revision exhausted");
    }
}

pub(crate) fn capture_kill(
    scene: &Scene,
    selection: &SessionSelection,
) -> Result<crate::RemoteTmuxAttachRequest, WorkspaceError> {
    runtime::require_host_session_actions(&scene.runtime, selection)?;
    let entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before killing a session"))?;
    // The client owns this endpoint even if its checkout or registration has
    // disappeared. Never authorize an arbitrary named socket from a selection.
    let identity = |active: &crate::RemoteActive| {
        let key = &active.key;
        if key.host_id != selection.host_id()
            || key.endpoint != selection.endpoint()
            || key.endpoint != context.snapshot.endpoint()
            || key.route_identity != context.snapshot.route_identity()
            || key.lease_generation != context.snapshot.lease_generation()
        {
            return None;
        }
        match &key.session_identity {
            RemoteSessionIdentity::ProtectedWorktree {
                selection: opened,
                identity,
            } if opened.session() == selection.session()
                && opened.tmux_socket_name() == selection.tmux_socket_name()
                && opened.tmux_socket_name().is_some() =>
            {
                Some(identity.clone())
            }
            _ => None,
        }
    };
    let active_identity = scene
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .and_then(identity);
    let session_identity = active_identity
        .or_else(|| {
            scene
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .entries
                .iter()
                .find_map(|entry| identity(&entry.active))
        })
        .ok_or_else(|| {
            WorkspaceError::new("Open this protected worktree before killing its session")
        })?;
    Ok(crate::RemoteTmuxAttachRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        selection: selection.clone(),
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        session: session::DiscoveredSession::new(selection.session(), session_identity, 0),
    })
}

struct Request {
    host_id: String,
    connection_generation: u64,
    host: RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    selection: SessionSelection,
    target: Target,
    prior_session: Option<session::DiscoveredSession>,
    kill_revision: Option<(KillKey, u64)>,
}

enum Target {
    Worktree {
        project: ProjectItem,
        worktree: WorktreeItem,
    },
    Directory(DirectoryWorkspaceItem),
}

impl Request {
    fn validate(
        &self,
        inventory: &KwtInventory,
    ) -> Result<Option<RemoteTmuxServer>, WorkspaceError> {
        let socket = match &self.target {
            Target::Worktree {
                project: expected_project,
                worktree: expected_worktree,
            } => {
                let row = inventory
                    .projects()
                    .iter()
                    .find(|item| {
                        let project = item.project();
                        project.repository() == expected_project.repository
                            && project.path() == expected_project.path
                            && project.registration_fingerprint()
                                == expected_project.registration_fingerprint
                    })
                    .and_then(|project| {
                        project.worktrees().iter().find(|worktree| {
                            worktree.path() == expected_worktree.path
                                && worktree.generation() == expected_worktree.generation.as_deref()
                                && worktree.session_name() == expected_worktree.session_name
                                && worktree.tmux_attach_mode() == expected_worktree.tmux_attach_mode
                        })
                    })
                    .ok_or_else(|| {
                        WorkspaceError::new("The worktree identity changed; refresh and try again")
                    })?;
                if expected_worktree.tmux_attach_mode == KwtTmuxAttachMode::Protected {
                    if row.tmux_socket_name().is_none()
                        || row.tmux_socket_name() != expected_worktree.tmux_socket_name.as_deref()
                    {
                        return Err(WorkspaceError::new(
                            "The protected workspace endpoint changed; refresh and try again",
                        ));
                    }
                    return Ok(None);
                }
                row.tmux_socket_name()
            }
            Target::Directory(expected) => inventory
                .directory_workspaces()
                .iter()
                .find(|row| {
                    row.path() == expected.path
                        && row.session_name() == expected.session_name
                        && row.tmux_attach_mode() == KwtTmuxAttachMode::Direct
                })
                .ok_or_else(|| {
                    WorkspaceError::new(
                        "The directory workspace identity changed; refresh and try again",
                    )
                })?
                .tmux_socket_name(),
        };
        match socket {
            None => Ok(Some(RemoteTmuxServer::Default)),
            Some("kwt") => Ok(Some(RemoteTmuxServer::Kwt)),
            Some(_) => Err(WorkspaceError::new(
                "This workspace uses an unsupported tmux server",
            )),
        }
    }
}

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    reason = "capture and navigation reservation share one live navigation fence"
)]
pub(super) fn open_worktree(
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
    let _publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _navigation = lock_live_navigation(scene)?;
    let selection = SessionSelection::kwt_workspace(
        host_id,
        endpoint,
        session_name,
        mode,
        socket.map(str::to_owned),
        worktree_path,
        generation.map(str::to_owned),
    );
    if reuse_protected(workspace, &selection)? {
        return Ok(());
    }
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
                    && match mode {
                        KwtTmuxAttachMode::Direct => matches!(socket, None | Some("kwt")),
                        KwtTmuxAttachMode::Protected => socket.is_some_and(|name| !name.is_empty()),
                    }
            })
            .ok_or_else(|| {
                WorkspaceError::new("The worktree identity changed; refresh and try again")
            })?;
        let kill_revision = (mode == KwtTmuxAttachMode::Protected).then(|| {
            let key = KillKey::new(&selection, &context.snapshot);
            let revision = scene
                .runtime
                .protected_tmux_kills
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(&key)
                .copied()
                .unwrap_or_default();
            (key, revision)
        });
        Request {
            host_id: host_id.to_owned(),
            connection_generation: entry.generation,
            host: context.host.clone(),
            snapshot: context.snapshot.clone(),
            selection,
            kill_revision,
            target: Target::Worktree {
                project: project.clone(),
                worktree: worktree.clone(),
            },
            prior_session: (mode == KwtTmuxAttachMode::Direct)
                .then(|| {
                    context
                        .snapshot
                        .sessions_on(if socket == Some("kwt") {
                            RemoteTmuxServer::Kwt
                        } else {
                            RemoteTmuxServer::Default
                        })
                        .iter()
                        .find(|session| session.name() == session_name)
                        .cloned()
                })
                .flatten(),
        }
    };
    let selection = request.selection.clone();
    let navigation_generation = workspace.begin_navigation();
    workspace.settle_local_navigation_before_remote()?;
    if mode == KwtTmuxAttachMode::Protected {
        return schedule(scene, request, navigation_generation);
    }
    let key = workspace.remote_presentation_key(&selection);
    if scene
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|active| {
            key.as_ref().map_or_else(
                || active.selection == selection.remote_client(),
                |key| active.key == *key,
            )
        })
    {
        return workspace.refresh_active_remote_selection(&selection, key.as_ref());
    }
    if workspace.activate_remote_retained(&selection, key.as_ref())? {
        return Ok(());
    }
    schedule(scene, request, navigation_generation)
}

pub(super) fn open_protected_selection(
    workspace: &Workspace,
    selection: &SessionSelection,
) -> Result<(), WorkspaceError> {
    {
        let _publication = workspace
            .scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = lock_live_navigation(&workspace.scene)?;
        if reuse_protected(workspace, selection)? {
            return Ok(());
        }
    }
    let snapshot = workspace.snapshot();
    let (project, worktree) = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == selection.host_id() && host.endpoint() == selection.endpoint())
        .and_then(|host| {
            host.projects().iter().find_map(|project| {
                project
                    .worktrees()
                    .iter()
                    .find(|worktree| {
                        worktree.path() == selection.worktree_path().unwrap_or_default()
                            && worktree.generation() == selection.worktree_generation()
                            && worktree.session_name() == selection.session()
                            && worktree.tmux_socket_name() == selection.tmux_socket_name()
                            && Some(worktree.tmux_attach_mode()) == selection.tmux_attach_mode()
                    })
                    .map(|worktree| (project, worktree))
            })
        })
        .ok_or_else(|| {
            WorkspaceError::new("The protected worktree identity changed; refresh and try again")
        })?;
    open_worktree(
        workspace,
        selection.host_id(),
        selection.endpoint(),
        project.repository(),
        project.path(),
        project.registration_fingerprint(),
        worktree.path(),
        worktree.generation(),
        worktree.session_name(),
        worktree.tmux_socket_name(),
        worktree.tmux_attach_mode(),
    )
}

// Inventory is required to launch a new client, but an exact live presentation can
// outlast its checkout or project registration. Keep connection and navigation
// publication fenced until that presentation has been activated. The caller
// holds remote_publication, then the scene's navigation lock.
fn reuse_protected(
    workspace: &Workspace,
    selection: &SessionSelection,
) -> Result<bool, WorkspaceError> {
    if selection.tmux_attach_mode() != Some(KwtTmuxAttachMode::Protected) {
        return Ok(false);
    }
    let scene = &workspace.scene;
    let (active, retained) = {
        let entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(context) = entries
            .get(selection.host_id())
            .and_then(current_remote_context)
        else {
            return Ok(false);
        };
        let matches = |key: &RemotePresentationKey| {
            key.host_id == selection.host_id()
                && key.endpoint == selection.endpoint()
                && key.endpoint == context.snapshot.endpoint()
                && key.route_identity == context.snapshot.route_identity()
                && key.lease_generation == context.snapshot.lease_generation()
                && matches!(&key.session_identity,
                    RemoteSessionIdentity::ProtectedWorktree { selection: opened, .. }
                    if opened == selection)
        };
        let active = scene
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|active| matches(&active.key))
            .map(|active| active.key.clone());
        let retained = scene
            .remote_retained
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entries
            .iter()
            .find(|entry| matches(&entry.active.key))
            .map(|entry| entry.active.key.clone());
        (active, retained)
    };
    if active.is_none() && retained.is_none() {
        return Ok(false);
    }
    workspace.begin_navigation();
    workspace.settle_local_navigation_before_remote()?;
    if let Some(key) = active {
        workspace.refresh_active_remote_selection(selection, Some(&key))?;
        return Ok(true);
    }
    workspace.activate_remote_retained(selection, retained.as_ref())
}

// The caller holds the navigation fence and has already checked retained clients.
pub(super) fn open_directory(
    workspace: &Workspace,
    selection: &SessionSelection,
    navigation_generation: u64,
) -> Result<(), WorkspaceError> {
    let scene = &workspace.scene;
    let request = {
        let entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = entries
            .get(selection.host_id())
            .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
        let context = current_remote_context(entry).ok_or_else(|| {
            WorkspaceError::new("Connect this SSH host before opening a directory")
        })?;
        if context.snapshot.endpoint() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "SSH endpoint changed; refresh and try again",
            ));
        }
        let hosts = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let directory = hosts
            .iter()
            .find(|host| {
                host.id == selection.host_id()
                    && host.connection == HostConnectionState::Ready
                    && host.kwt_available()
            })
            .and_then(|host| {
                host.directory_workspaces.iter().find(|row| {
                    row.path == selection.worktree_path().unwrap_or_default()
                        && row.session_name == selection.session()
                        && Some(row.tmux_attach_mode) == selection.tmux_attach_mode()
                        && row.tmux_socket_name.as_deref() == selection.tmux_socket_name()
                })
            })
            .ok_or_else(|| {
                WorkspaceError::new("Refresh KWT inventory before opening this directory workspace")
            })?;
        Request {
            host_id: selection.host_id().to_owned(),
            connection_generation: entry.generation,
            host: context.host.clone(),
            snapshot: context.snapshot.clone(),
            selection: selection.clone(),
            kill_revision: None,
            target: Target::Directory(directory.clone()),
            prior_session: context
                .snapshot
                .sessions_on(selection.remote_tmux_server()?)
                .iter()
                .find(|session| session.name() == selection.session())
                .cloned(),
        }
    };
    schedule(scene, request, navigation_generation)
}

fn schedule(
    scene: &Arc<Scene>,
    request: Request,
    navigation_generation: u64,
) -> Result<(), WorkspaceError> {
    let host_id = request.host_id.clone();
    let cancellation = CancellationToken::new();
    register_remote_attachment(
        &scene.runtime,
        scene.id,
        &host_id,
        request.connection_generation,
        &request.snapshot,
        navigation_generation,
        &cancellation,
    )?;
    let task_scene = Arc::clone(scene);
    if let Err(error) = scene.runtime.refresh_runtime.spawn(
        "ghosthub-remote-workspace",
        Box::new(move || {
            run(&task_scene, request, navigation_generation, &cancellation);
        }),
    ) {
        clear_remote_attachment_registration(&scene.runtime, &host_id, navigation_generation);
        return Err(WorkspaceError::new(error.to_string()));
    }
    Ok(())
}

#[allow(
    clippy::too_many_lines,
    reason = "revalidation and publication remain one ordered lifecycle operation"
)]
fn run(
    scene: &Arc<Scene>,
    mut request: Request,
    navigation: u64,
    cancellation: &CancellationToken,
) {
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
        if let Some((key, revision)) = &request.kill_revision
            && scene
                .runtime
                .protected_tmux_kills
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(key)
                .copied()
                .unwrap_or_default()
                != *revision
        {
            return Err(WorkspaceError::new(
                "The protected session was killed after this request; open it again to restart",
            ));
        }
        let kwt_inventory = crate::remote_kwt::reserve_workspace(
            scene,
            &RemotePublicationFence {
                host_id: &host_id,
                connection_generation: request.connection_generation,
                snapshot: &request.snapshot,
                cancellation,
            },
        )?;
        // A queued open of a running session must not undo a preceding confirmed kill.
        if let Some(prior) = &request.prior_session {
            let current = request
                .host
                .capture_live_session(
                    &request.snapshot,
                    request.selection.remote_tmux_server()?,
                    prior.name(),
                    cancellation,
                )
                .map_err(error)?;
            if current.identity() != prior.identity() {
                return Err(WorkspaceError::new(
                    "The workspace session changed; refresh and try again",
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
        kwt_inventory.publish(inventory)?;
        let inventory = request
            .host
            .refresh(request.snapshot.lease(), cancellation)
            .map_err(error)?;
        let snapshot = request.snapshot.with_inventory(inventory.clone());
        let session = if let Some(server) = server {
            snapshot
                .sessions_on(server)
                .iter()
                .find(|session| session.name() == request.selection.session())
                .cloned()
                .ok_or_else(|| {
                    WorkspaceError::new("KWT client does not match the workspace session")
                })?
        } else {
            request
                .host
                .capture_protected_kwt_session(
                    &request.snapshot,
                    request
                        .selection
                        .tmux_socket_name()
                        .expect("captured protected socket"),
                    request.selection.session(),
                    cancellation,
                )
                .map_err(error)?
        };
        if session.identity() != &identity {
            return Err(WorkspaceError::new(
                "KWT client does not match the workspace session",
            ));
        }
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
            session_identity: match server {
                Some(server) => RemoteSessionIdentity::tmux(server, identity),
                None => RemoteSessionIdentity::ProtectedWorktree {
                    selection: request.selection.clone(),
                    identity,
                },
            },
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

fn client_plan(
    request: &Request,
    term: AttachTerm,
    cancellation: &CancellationToken,
) -> Result<session::RepairOrOpenPlan, WorkspaceError> {
    match &request.target {
        Target::Worktree { project, worktree }
            if worktree.tmux_attach_mode == KwtTmuxAttachMode::Protected =>
        {
            request.host.kwt_protected_attach_plan(
                &request.snapshot,
                &host::KwtProtectedWorktreeOpen::new(
                    &worktree.path,
                    &project.path,
                    &project.repository,
                    &project.registration_fingerprint,
                    worktree.generation.as_ref().expect("captured generation"),
                    &worktree.session_name,
                    worktree
                        .tmux_socket_name
                        .as_ref()
                        .expect("captured protected socket"),
                ),
                term.as_str(),
                cancellation,
            )
        }
        Target::Worktree { project, worktree } => {
            let open = host::KwtWorktreeOpen::new(
                &worktree.path,
                &project.repository,
                &project.registration_fingerprint,
                worktree.generation.as_ref().expect("captured generation"),
                &worktree.session_name,
            );
            request.host.kwt_worktree_open_plan(
                &request.snapshot,
                &open,
                term.as_str(),
                cancellation,
            )
        }
        Target::Directory(directory) => request.host.kwt_directory_workspace_open_plan(
            &request.snapshot,
            &host::KwtDirectoryWorkspaceOpen::new(&directory.path, &directory.session_name),
            term.as_str(),
            cancellation,
        ),
    }
    .map_err(error)
}

fn launch(
    scene: &Scene,
    request: &Request,
    server: Option<RemoteTmuxServer>,
    navigation: u64,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, AttachTerm, session::SessionIdentity), WorkspaceError> {
    let term = request
        .host
        .probe_terminal_term(&request.snapshot, cancellation)
        .map_err(error)?;
    let plan = client_plan(request, term, cancellation)?;
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
            match server {
                Some(server) => {
                    request
                        .host
                        .kwt_client_identity(&request.snapshot, &plan, server, cancellation)
                }
                None => request.host.kwt_protected_client_identity(
                    &request.snapshot,
                    &plan,
                    request
                        .selection
                        .tmux_socket_name()
                        .expect("captured protected socket"),
                    cancellation,
                ),
            }
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
