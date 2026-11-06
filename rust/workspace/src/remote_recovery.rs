use crate::{
    RemoteHerdrAttachRequest, RemoteTmuxSnapshot, RemoteZellijAttachRequest, Runtime, SceneId,
    Workspace, WorkspaceError, lock_live_navigation, runtime,
};

pub(crate) mod retry;

#[cfg(feature = "test-support")]
impl Workspace {
    /// Observe the delay selected for the next reconnect without starting or cancelling work.
    #[must_use]
    pub fn remote_reconnect_interval(&self, host_id: &str) -> Option<std::time::Duration> {
        self.scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(host_id)
            .map(|entry| entry.reconnect.interval())
    }

    /// Observe connection and attachment completion without cancelling the queued work.
    #[must_use]
    pub fn remote_attachment_pending(&self, host_id: &str) -> bool {
        // Ready is visible before recovery is scheduled. Wait for publication to finish
        // before inspecting registrations, which remain until attachment work returns.
        let _publication = self
            .scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(host_id)
            .is_some_and(|entry| {
                entry.cancellation.is_some()
                    || entry
                        .attachment_attempts
                        .iter()
                        .any(|attempt| attempt.scene == self.scene.id)
            })
    }
}

pub(crate) struct InterruptedTmux {
    key: crate::RemotePresentationKey,
    navigation_generation: u64,
}

/// Derive status from the saved target so success, cancellation and navigation cannot
/// leave a stale reconnect message in the UI. Do not hold the target lock across hosts.
pub(crate) fn notice(scene: &crate::Scene) -> Option<crate::WorkspaceNotice> {
    let host_id = {
        let interrupted = scene
            .interrupted_tmux
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let pending = interrupted.as_ref()?;
        if pending.navigation_generation
            != scene.navigation_generation.load(crate::Ordering::Acquire)
        {
            return None;
        }
        pending.key.host_id.clone()
    };
    let entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries.get(&host_id)?;
    Some(crate::WorkspaceNotice {
        message: if entry.reconnect.enabled() {
            "Connection interrupted. Reconnecting automatically."
        } else {
            "Connection interrupted. Choose Retry beside the host."
        }
        .to_owned(),
        transient: false,
    })
}

/// Preserve the selected ordinary tmux identity, even if SSH failed before terminal startup.
/// Called under the navigation fence; explicit navigation still cancels recovery.
pub(crate) fn remember_tmux(scene: &crate::Scene, active: &crate::RemoteActive) -> bool {
    if scene.closed.load(crate::Ordering::Acquire)
        || scene.navigation_generation.load(crate::Ordering::Acquire)
            != active.navigation_generation
        || !matches!(
            active.key.session_identity,
            crate::RemoteSessionIdentity::Tmux(_) | crate::RemoteSessionIdentity::KwtTmux(_)
        )
    {
        return false;
    }
    crate::runtime::cancel_scene_remote_attachments(&scene.runtime, scene.id);
    *scene
        .interrupted_tmux
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(InterruptedTmux {
        key: active.key.clone(),
        navigation_generation: active.navigation_generation,
    });
    retry::schedule(scene, &active.key.host_id);
    true
}

/// Reconnect may publish before the pump consumes the old client's exit.
/// The caller holds publication, but has released navigation before scheduling recovery.
pub(crate) fn restore_after_tmux_exit(
    scene: &crate::Arc<crate::Scene>,
    active: &crate::RemoteActive,
) {
    let fresh = {
        let entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        entries
            .get(&active.key.host_id)
            .and_then(crate::current_remote_context)
            .filter(|context| context.generation > active.connection_generation)
            .map(|context| {
                (
                    context.generation,
                    context.host.clone(),
                    context.snapshot.clone(),
                )
            })
    };
    if let Some((generation, host, snapshot)) = fresh {
        restore_tmux(
            std::slice::from_ref(scene),
            &active.key.host_id,
            generation,
            &host,
            &snapshot,
        );
    }
}

pub(crate) fn forget_tmux_host(scene: &crate::Scene, host_id: &str) {
    let mut interrupted = scene
        .interrupted_tmux
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if interrupted
        .as_ref()
        .is_some_and(|pending| pending.key.host_id == host_id)
    {
        interrupted.take();
    }
}

/// A successful reconnect supplies fresh inventory. Never create a missing session.
/// The caller holds publication and retains all scene handles until it releases that lock.
pub(crate) fn restore_tmux(
    scenes: &[crate::Arc<crate::Scene>],
    host_id: &str,
    generation: u64,
    host: &crate::RuntimeRemoteHost,
    snapshot: &RemoteTmuxSnapshot,
) {
    for scene in scenes {
        let Ok(_navigation) = lock_live_navigation(scene) else {
            continue;
        };
        let mut interrupted = scene
            .interrupted_tmux
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(pending) = interrupted
            .as_ref()
            .filter(|pending| pending.key.host_id == host_id)
        else {
            continue;
        };
        if pending.navigation_generation
            != scene.navigation_generation.load(crate::Ordering::Acquire)
        {
            interrupted.take();
            continue;
        }
        let (server, identity) = match &pending.key.session_identity {
            crate::RemoteSessionIdentity::Tmux(identity) => {
                (host::RemoteTmuxServer::Default, identity)
            }
            crate::RemoteSessionIdentity::KwtTmux(identity) => {
                (host::RemoteTmuxServer::Kwt, identity)
            }
            _ => unreachable!("only ordinary tmux clients are remembered"),
        };
        // Failed inventory is not evidence that the session ended. A later reconnect can retry.
        let diagnostic = match server {
            host::RemoteTmuxServer::Default => snapshot.tmux_diagnostic(),
            host::RemoteTmuxServer::Kwt => snapshot.kwt_tmux_diagnostic(),
        };
        if diagnostic.is_some() {
            continue;
        }
        let request = if pending.key.endpoint != snapshot.endpoint()
            || pending.key.route_identity != snapshot.route_identity()
        {
            Err(WorkspaceError::new(
                "The SSH route changed. Select a session to open it.",
            ))
        } else {
            snapshot
                .sessions_on(server)
                .iter()
                .find(|session| session.identity() == identity)
                .map(|session| crate::RemoteTmuxAttachRequest {
                    host_id: host_id.to_owned(),
                    connection_generation: generation,
                    selection: pending
                        .key
                        .selection(crate::SessionKind::Tmux, session.name()),
                    host: host.clone(),
                    snapshot: snapshot.clone(),
                    session: session.clone(),
                })
                .ok_or_else(|| {
                    WorkspaceError::new("The interrupted tmux session is no longer running.")
                })
        };
        let mut pending = interrupted.take().expect("matched interrupted session");
        drop(interrupted);
        let workspace = Workspace {
            scene: crate::Arc::clone(scene),
        };
        let result = request.and_then(|request| {
            let navigation = workspace.begin_navigation();
            // A second reconnect can cancel this queued attachment. Keep its target until
            // publication, when the active presentation takes ownership. User navigation
            // still clears it through begin_navigation.
            pending.navigation_generation = navigation;
            *scene
                .interrupted_tmux
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(pending);
            workspace.start_remote_tmux_attachment(request, navigation)
        });
        if let Err(error) = result {
            workspace.push_operation_error(error.to_string());
        }
    }
}

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
