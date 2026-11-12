use super::{
    CancellationToken, HostItem, HostSnapshot, KwtState, KwtTmuxAttachMode, ProjectItem,
    RemoteTmuxAttachRequest, Runtime, RuntimeHost, SceneId, SessionKind, SessionName,
    SessionSelection, Workspace, WorkspaceContent, WorkspaceError, WorkspaceEvent,
    capture_remote_tmux_attach_request, is_local_host_id, lock_live_navigation, next_operation_id,
    runtime, scene, session_order_id,
};
use std::thread;

/// The inventory identity reviewed when the Rename dialog opens.
#[derive(Clone)]
pub struct SessionRenameRequest {
    id: u64,
    selection: SessionSelection,
    target: Target,
}

#[derive(Clone)]
enum Target {
    Local(Box<LocalTarget>),
    Remote(Box<RemoteTmuxAttachRequest>),
}

#[derive(Clone)]
struct LocalTarget {
    host: RuntimeHost,
    snapshot: HostSnapshot,
    session: session::DiscoveredSession,
}

pub(crate) struct Reservation {
    pub(crate) scene: SceneId,
    id: u64,
    pub(crate) cancellation: CancellationToken,
}

impl SessionRenameRequest {
    #[must_use]
    pub const fn id(&self) -> u64 {
        self.id
    }

    #[must_use]
    pub const fn selection(&self) -> &SessionSelection {
        &self.selection
    }
}

fn kwt_owns(host: &HostItem, name: &str) -> bool {
    name.starts_with("kwt-wt-")
        || name.starts_with("kwt-workspace-")
        || host
            .projects()
            .iter()
            .flat_map(ProjectItem::worktrees)
            .any(|row| row.tmux_socket_name().is_none() && row.session_name() == name)
        || host
            .directory_workspaces()
            .iter()
            .any(|row| row.tmux_socket_name().is_none() && row.session_name() == name)
}

/// Whether a current default-server row offers Rename Session.
#[must_use]
pub fn can_rename_session(host: &HostItem, selection: &SessionSelection) -> bool {
    host.id() == selection.host_id()
        && host.endpoint() == selection.endpoint()
        && host.accepts_session_actions()
        && host.tmux_available()
        && host.tmux_diagnostic().is_none()
        && matches!(host.kwt_state, KwtState::Ready | KwtState::Unavailable)
        && host.kwt_diagnostic().is_none()
        && selection.kind() == SessionKind::Tmux
        && selection.tmux_socket_name().is_none()
        && selection.worktree_path().is_none()
        && selection.tmux_attach_mode() != Some(KwtTmuxAttachMode::Protected)
        && host
            .sessions()
            .iter()
            .any(|row| row.name() == selection.session())
        && !kwt_owns(host, selection.session())
}

impl Workspace {
    /// Capture the current session identity before editing its name.
    ///
    /// # Errors
    /// Returns an error for unsupported, unavailable, or KWT-owned sessions.
    pub fn session_rename_request(
        &self,
        selection: &SessionSelection,
    ) -> Result<SessionRenameRequest, WorkspaceError> {
        let _publication = self
            .scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = lock_live_navigation(&self.scene)?;
        require_eligible(&self.scene.runtime, selection)?;
        if matches!(self.scene.state.read().unwrap_or_else(std::sync::PoisonError::into_inner).clone(),
            WorkspaceContent::Attaching { host_id, session, .. } if host_id == selection.host_id() && session == selection.session())
        {
            return Err(WorkspaceError::new(
                "The session is still connecting. Try again in a moment.",
            ));
        }
        let target = if is_local_host_id(selection.host_id()) {
            let hosts = self
                .scene
                .runtime
                .host
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let context = &hosts
                .as_ref()
                .ok_or_else(|| WorkspaceError::new("Local inventory is not ready"))?
                .value;
            let session = context
                .snapshot
                .sessions()
                .iter()
                .find(|session| session.name() == selection.session())
                .ok_or_else(|| {
                    WorkspaceError::new("Refresh the host before renaming this session.")
                })?
                .clone();
            Target::Local(Box::new(LocalTarget {
                host: context.host.clone(),
                snapshot: context.snapshot.clone(),
                session,
            }))
        } else {
            Target::Remote(Box::new(capture_remote_tmux_attach_request(
                &self.scene.runtime,
                selection,
            )?))
        };
        Ok(SessionRenameRequest {
            id: next_operation_id(&self.scene.runtime),
            selection: selection.clone(),
            target,
        })
    }

    /// Validate an edited name against current inventory and KWT ownership.
    ///
    /// # Errors
    /// Returns an error for invalid, unchanged, reserved, or occupied names.
    pub fn session_rename_validation(
        &self,
        request: &SessionRenameRequest,
        name: &str,
    ) -> Result<SessionName, WorkspaceError> {
        let name =
            SessionName::parse(name).map_err(|error| WorkspaceError::new(error.to_string()))?;
        let hosts = self
            .scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let host = hosts
            .iter()
            .find(|host| {
                host.id() == request.selection.host_id()
                    && host.endpoint() == request.selection.endpoint()
            })
            .ok_or_else(|| {
                WorkspaceError::new("The host changed. Close this dialog and choose Rename again.")
            })?;
        if !can_rename_session(host, &request.selection) {
            return Err(WorkspaceError::new(
                "Refresh the host before renaming this session.",
            ));
        }
        if name.as_str() == request.selection.session() {
            return Err(WorkspaceError::new("Choose a different session name."));
        }
        if kwt_owns(host, name.as_str()) {
            return Err(WorkspaceError::new("This session name belongs to KWT."));
        }
        if host
            .sessions()
            .iter()
            .any(|row| row.name() == name.as_str())
        {
            return Err(WorkspaceError::new(
                "A session with this name already exists on this host.",
            ));
        }
        Ok(name)
    }

    /// Rename the reviewed session in the background, preserving terminal clients.
    ///
    /// # Errors
    /// Returns an error for a stale request, invalid name, or task-start failure.
    pub fn rename_session(
        &self,
        request: &SessionRenameRequest,
        name: &str,
    ) -> Result<(), WorkspaceError> {
        let _publication = self
            .scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = lock_live_navigation(&self.scene)?;
        let name = self.session_rename_validation(request, name)?;
        let cancellation = CancellationToken::new();
        if let Target::Remote(target) = &request.target {
            let mut entries = self
                .scene
                .runtime
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let entry = entries
                .get_mut(&target.host_id)
                .ok_or_else(|| WorkspaceError::new("The SSH host disconnected."))?;
            if entry
                .renames
                .iter()
                .any(|operation| operation.id == request.id)
            {
                return Err(WorkspaceError::new(
                    "This session is already being renamed.",
                ));
            }
            if entry.generation != target.connection_generation
                || entry.context.as_ref().is_none_or(|context| {
                    context.snapshot.route_identity() != target.snapshot.route_identity()
                        || context.snapshot.lease_generation() != target.snapshot.lease_generation()
                })
            {
                return Err(WorkspaceError::new(
                    "The SSH connection changed. Close this dialog and choose Rename again.",
                ));
            }
            entry.renames.push(Reservation {
                scene: self.scene.id,
                id: request.id,
                cancellation: cancellation.clone(),
            });
        }
        let workspace = self.clone();
        let task = request.clone();
        let result = thread::Builder::new()
            .name("ghosthub-session-rename".into())
            .spawn(move || {
                let _operation = workspace
                    .scene
                    .runtime
                    .session_operations
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let result =
                    run(&workspace, &task, &name, &cancellation).map_err(|error| error.to_string());
                finish(&workspace.scene.runtime, task.id);
                scene::push_lossless_event(
                    &workspace.scene,
                    WorkspaceEvent::SessionRenamed {
                        operation_id: task.id,
                        selection: task.selection,
                        name: name.as_str().to_owned(),
                        result,
                    },
                );
            });
        if let Err(error) = result {
            finish(&self.scene.runtime, request.id);
            return Err(WorkspaceError::new(format!("Rename failed: {error}")));
        }
        Ok(())
    }
}

fn require_eligible(runtime: &Runtime, selection: &SessionSelection) -> Result<(), WorkspaceError> {
    if runtime
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .any(|host| can_rename_session(host, selection))
    {
        Ok(())
    } else {
        Err(WorkspaceError::new(
            "Rename is available only for standalone tmux sessions on the default server.",
        ))
    }
}

fn run(
    workspace: &Workspace,
    request: &SessionRenameRequest,
    name: &SessionName,
    cancellation: &CancellationToken,
) -> Result<(), WorkspaceError> {
    {
        let _navigation = lock_live_navigation(&workspace.scene)?;
    }
    if cancellation.is_cancelled() {
        return Err(WorkspaceError::new("Rename was cancelled."));
    }
    workspace.session_rename_validation(request, name.as_str())?;
    match &request.target {
        Target::Local(target) => {
            let LocalTarget {
                host,
                snapshot,
                session,
            } = &**target;
            let current = workspace
                .scene
                .runtime
                .host
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if current.as_ref().is_none_or(|current| {
                current.value.snapshot.endpoint() != snapshot.endpoint()
                    || current.value.snapshot.runtime() != snapshot.runtime()
                    || current.value.host.socket_directory() != host.socket_directory()
            }) {
                return Err(WorkspaceError::new(
                    "The local host changed. Close this dialog and choose Rename again.",
                ));
            }
            drop(current);
            host.rename_live_session(snapshot, session, name, cancellation)
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            workspace.refresh()?;
        }
        Target::Remote(target) => {
            let (host, snapshot) = runtime::recapture_remote_attachment_context(
                &workspace.scene.runtime,
                &target.host_id,
                target.connection_generation,
                &target.snapshot,
            )?;
            host.rename_live_session(&snapshot, &target.session, name, cancellation)
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            while let Ok((host, snapshot)) = runtime::recapture_remote_attachment_context(
                &workspace.scene.runtime,
                &target.host_id,
                target.connection_generation,
                &snapshot,
            ) {
                let inventory = host
                    .refresh(snapshot.lease(), cancellation)
                    .map_err(|error| {
                        WorkspaceError::new(format!("Session renamed, but refresh failed: {error}"))
                    })?;
                if scene::publish_remote_inventory(
                    &workspace.scene,
                    &target.host_id,
                    target.connection_generation,
                    &snapshot,
                    cancellation,
                    inventory,
                )
                .is_ok()
                {
                    break;
                }
            }
        }
    }
    let has_settings = workspace
        .scene
        .runtime
        .settings
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .is_some();
    if has_settings {
        let old = session_order_id(&request.selection);
        let mut selection = request.selection.clone();
        name.as_str().clone_into(&mut selection.session);
        let new = session_order_id(&selection);
        workspace.update_sidebar(|settings| {
            if settings.session_order.contains(&old) {
                settings.session_order.retain(|id| id != &new);
                for id in &mut settings.session_order {
                    if *id == old {
                        id.clone_from(&new);
                    }
                }
            }
        })?;
    }
    Ok(())
}

fn finish(runtime: &Runtime, id: u64) {
    for entry in runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .values_mut()
    {
        entry.renames.retain(|operation| operation.id != id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DiagnosticKind, HostDiagnostic, set_remote_host_snapshot};
    use std::time::{Duration, Instant};

    #[test]
    fn rename_requires_resolved_workspace_ownership_at_capture_and_submission() {
        let (workspace, target) = crate::tests::remote_kill_refresh_fixture();
        set_remote_host_snapshot(&workspace.scene.runtime, &target.host_id, &target.snapshot);
        let set_ownership = |state, diagnostic| {
            let mut hosts = workspace.scene.runtime.hosts.write().unwrap();
            let host = hosts
                .iter_mut()
                .find(|host| host.id() == target.host_id)
                .unwrap();
            host.kwt_state = state;
            host.kwt_diagnostic = diagnostic;
        };
        set_ownership(KwtState::Ready, None);
        let request = workspace.session_rename_request(&target.selection).unwrap();
        for (state, failed) in [
            (KwtState::Uninitialized, false),
            (KwtState::Refreshing { available: false }, false),
            (KwtState::Refreshing { available: true }, false),
            (KwtState::Mutating, false),
            (KwtState::Unavailable, true),
            (KwtState::Ready, true),
        ] {
            set_ownership(
                state,
                failed.then(|| {
                    HostDiagnostic::new(DiagnosticKind::Transport, "KWT inventory failed")
                }),
            );
            assert!(
                workspace.session_rename_request(&target.selection).is_err(),
                "captured unresolved ownership: {state:?}"
            );
            assert!(
                workspace
                    .rename_session(&request, "custom-workspace")
                    .is_err(),
                "submitted unresolved ownership: {state:?}"
            );
        }
        // A host without KWT still supports ordinary tmux session renaming.
        set_ownership(KwtState::Unavailable, None);
        let absent = workspace.session_rename_request(&target.selection).unwrap();
        assert!(
            workspace
                .session_rename_validation(&absent, "release")
                .is_ok()
        );
        workspace.close();
    }

    #[test]
    fn queued_rename_defers_automatic_reconnect_and_close_cancels_it() {
        let (workspace, target) = crate::tests::remote_kill_refresh_fixture();
        set_remote_host_snapshot(&workspace.scene.runtime, &target.host_id, &target.snapshot);
        workspace.scene.runtime.hosts.write().unwrap()[0].kwt_state = KwtState::Ready;
        let request = workspace.session_rename_request(&target.selection).unwrap();
        let operation = workspace.scene.runtime.session_operations.lock().unwrap();
        let now = Instant::now();
        {
            let mut entries = workspace.scene.runtime.remote_hosts.lock().unwrap();
            let entry = entries.get_mut(&target.host_id).unwrap();
            entry.reconnect.enable();
            entry.reconnect.schedule(now);
        }
        workspace.rename_session(&request, "release").unwrap();
        let cancellation = workspace.scene.runtime.remote_hosts.lock().unwrap()[&target.host_id]
            .renames[0]
            .cancellation
            .clone();
        {
            let _publication = workspace.scene.runtime.remote_publication.lock().unwrap();
            let _navigation = lock_live_navigation(&workspace.scene).unwrap();
            workspace
                .start_remote_connection(&target.host_id, Some(now + Duration::from_secs(1)))
                .unwrap();
        }
        assert_eq!(
            workspace.scene.runtime.remote_hosts.lock().unwrap()[&target.host_id].generation,
            target.connection_generation
        );
        workspace.close();
        assert!(
            cancellation.is_cancelled(),
            "close must cancel before the queued command can execute"
        );
        drop(operation);
    }
}
