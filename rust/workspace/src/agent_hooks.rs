use std::collections::HashMap;
use std::sync::Arc;

use crate::{
    AgentHookAction, AgentHookStatus, CancellationToken, Runtime, Scene, Workspace, WorkspaceError,
    WorkspaceEvent, current_remote_context, is_local_host_id, lock_live_navigation,
    next_operation_id,
};

#[derive(Default)]
pub(crate) struct State(HashMap<u64, Operation>);

struct Operation {
    host_id: String,
    scene: crate::SceneId,
    action: AgentHookAction,
    cancellation: CancellationToken,
}

enum Target {
    Local(crate::RuntimeHost, host::HostSnapshot),
    Remote(crate::RuntimeRemoteHost, Box<host::RemoteTmuxSnapshot>, u64),
}

impl Target {
    fn current(&self, runtime: &Runtime, id: &str) -> bool {
        match self {
            Self::Local(_, snapshot) => runtime
                .host
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_ref()
                .is_some_and(|current| {
                    current.value.snapshot.endpoint() == snapshot.endpoint()
                        && current.value.snapshot.runtime() == snapshot.runtime()
                }),
            Self::Remote(_, snapshot, generation) => runtime
                .remote_hosts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(id)
                .filter(|entry| entry.generation == *generation)
                .and_then(current_remote_context)
                .is_some_and(|context| {
                    context.snapshot.route_identity() == snapshot.route_identity()
                        && context.snapshot.lease_generation() == snapshot.lease_generation()
                }),
        }
    }

    fn run(
        &self,
        action: AgentHookAction,
        cancellation: &CancellationToken,
    ) -> Result<Vec<AgentHookStatus>, String> {
        match self {
            Self::Local(host, snapshot) => host
                .agent_hooks(
                    snapshot.endpoint(),
                    snapshot.runtime(),
                    action,
                    cancellation,
                )
                .map_err(|error| error.to_string()),
            Self::Remote(host, snapshot, _) => host
                .agent_hooks(snapshot, action, cancellation)
                .map_err(|error| error.to_string()),
        }
    }
}

fn capture(runtime: &Runtime, host_id: &str) -> Result<Target, WorkspaceError> {
    Ok(if is_local_host_id(host_id) {
        let current = runtime
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let context = &current
            .as_ref()
            .ok_or_else(|| WorkspaceError::new("Connect this host to set up agent hooks"))?
            .value;
        if context.snapshot.endpoint().host_id() != host_id {
            return Err(WorkspaceError::new(
                "The local host changed; reload its settings",
            ));
        }
        Target::Local(context.host.clone(), context.snapshot.clone())
    } else {
        let entries = runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let context = entries
            .get(host_id)
            .and_then(current_remote_context)
            .ok_or_else(|| WorkspaceError::new("Connect this host to set up agent hooks"))?;
        Target::Remote(
            context.host.clone(),
            Box::new(context.snapshot.clone()),
            context.generation,
        )
    })
}

impl Workspace {
    /// Read setup status or explicitly install agent hooks on one connected host.
    /// Results return only to this scene as `AgentHooksFinished`.
    ///
    /// # Errors
    /// Returns an error for a missing host, pending request, or unavailable worker.
    pub fn agent_hooks(
        &self,
        host_id: &str,
        action: AgentHookAction,
    ) -> Result<u64, WorkspaceError> {
        let publication = self
            .scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let navigation = lock_live_navigation(&self.scene)?;
        let target = capture(&self.scene.runtime, host_id)?;
        let id = next_operation_id(&self.scene.runtime);
        let cancellation = CancellationToken::new();
        {
            let mut state = self
                .scene
                .runtime
                .agent_hooks
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if action == AgentHookAction::Install
                && state.0.values().any(|operation| {
                    operation.host_id == host_id && operation.action == AgentHookAction::Install
                })
            {
                return Err(WorkspaceError::new(
                    "Agent hook setup is already running on this host",
                ));
            }
            state.0.insert(
                id,
                Operation {
                    host_id: host_id.to_owned(),
                    scene: self.scene.id,
                    action,
                    cancellation: cancellation.clone(),
                },
            );
        }
        drop(navigation);
        drop(publication);
        let runtime = Arc::clone(&self.scene.runtime);
        let scene = Arc::downgrade(&self.scene);
        let host_id = host_id.to_owned();
        let pending_host = host_id.clone();
        if let Err(error) = self.scene.runtime.refresh_runtime.spawn(
            "ghosthub-agent-hooks",
            Box::new(move || {
                let result =
                    if cancellation.is_cancelled() || !target.current(&runtime, &pending_host) {
                        Err("Agent hook request cancelled; reload the host's settings".to_owned())
                    } else {
                        target.run(action, &cancellation)
                    };
                let result = {
                    let _publication = runtime
                        .remote_publication
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if cancellation.is_cancelled() || !target.current(&runtime, &pending_host) {
                        Err("The host changed; reload agent hook status".to_owned())
                    } else {
                        result
                    }
                };
                finish(&runtime, id);
                if let Some(scene) = scene
                    .upgrade()
                    .filter(|scene| !scene.closed.load(std::sync::atomic::Ordering::Acquire))
                {
                    crate::scene::push_lossless_event(
                        &scene,
                        WorkspaceEvent::AgentHooksFinished {
                            host_id: pending_host,
                            operation_id: id,
                            action,
                            result,
                        },
                    );
                }
            }),
        ) {
            finish(&self.scene.runtime, id);
            return Err(WorkspaceError::new(format!(
                "Could not start agent hook setup: {error}"
            )));
        }
        Ok(id)
    }
}

fn finish(runtime: &Runtime, id: u64) {
    runtime
        .agent_hooks
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .0
        .remove(&id);
}

pub(crate) fn install_active(runtime: &Runtime, host_id: &str) -> bool {
    runtime
        .agent_hooks
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .0
        .values()
        .any(|operation| {
            operation.host_id == host_id
                && operation.action == AgentHookAction::Install
                && !operation.cancellation.is_cancelled()
        })
}

pub(crate) fn cancel_host(runtime: &Runtime, host_id: &str) {
    for operation in runtime
        .agent_hooks
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .0
        .values()
    {
        if operation.host_id == host_id {
            operation.cancellation.cancel();
        }
    }
}

pub(crate) fn cancel_scene(scene: &Scene) {
    for operation in scene
        .runtime
        .agent_hooks
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .0
        .values()
    {
        if operation.scene == scene.id {
            operation.cancellation.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::{ManualRefreshRuntime, remote_kill_refresh_fixture};

    fn fixture() -> (Workspace, Arc<ManualRefreshRuntime>) {
        let (source, _) = remote_kill_refresh_fixture();
        let refresh = Arc::new(ManualRefreshRuntime::default());
        let workspace = Workspace::application_with_services(
            config::TerminalAppearance::default(),
            None,
            Arc::new(crate::SystemLocalDiscovery::new()),
            refresh.clone(),
        );
        *workspace.scene.runtime.hosts.write().unwrap() = source.snapshot().hosts().to_vec();
        *workspace.scene.runtime.remote_hosts.lock().unwrap() =
            std::mem::take(&mut *source.scene.runtime.remote_hosts.lock().unwrap());
        (workspace, refresh)
    }

    #[test]
    fn setup_errors_settle_the_request_without_poisoning_host_inventory() {
        let (workspace, refresh) = fixture();
        let id = workspace
            .agent_hooks("ssh:studio", AgentHookAction::Status)
            .unwrap();
        refresh.run_next_work();
        let events = workspace.drain_events().0;
        assert!(events.iter().any(|event| matches!(event,
            WorkspaceEvent::AgentHooksFinished { operation_id, result: Err(_), .. } if *operation_id == id)));
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, WorkspaceEvent::Error(_)))
        );
        let snapshot = workspace.snapshot();
        assert_eq!(
            snapshot.hosts()[0].connection(),
            crate::HostConnectionState::Ready
        );
        assert!(snapshot.hosts()[0].kwt_diagnostic().is_none());
        assert!(
            workspace
                .scene
                .runtime
                .agent_hooks
                .lock()
                .unwrap()
                .0
                .is_empty()
        );
    }

    #[test]
    fn a_failed_worker_start_does_not_keep_installation_reserved() {
        let (workspace, refresh) = fixture();
        refresh.fail_next_work(|| {});
        assert!(
            workspace
                .agent_hooks("ssh:studio", AgentHookAction::Install)
                .is_err()
        );
        assert!(!install_active(&workspace.scene.runtime, "ssh:studio"));
        workspace
            .agent_hooks("ssh:studio", AgentHookAction::Install)
            .unwrap();
        refresh.run_next_work();
    }

    #[test]
    fn closing_one_scene_leaves_other_scenes_requests_running() {
        let (workspace, refresh) = fixture();
        let other = workspace.open_scene();
        let first = workspace
            .agent_hooks("ssh:studio", AgentHookAction::Status)
            .unwrap();
        let second = other
            .agent_hooks("ssh:studio", AgentHookAction::Status)
            .unwrap();
        let install = other
            .agent_hooks("ssh:studio", AgentHookAction::Install)
            .unwrap();
        let tokens = {
            let state = workspace.scene.runtime.agent_hooks.lock().unwrap();
            [first, second, install].map(|id| state.0[&id].cancellation.clone())
        };
        workspace.close();
        assert!(tokens[0].is_cancelled());
        assert!(!tokens[1].is_cancelled());
        assert!(!tokens[2].is_cancelled());
        for _ in 0..3 {
            refresh.run_next_work();
        }
        assert_eq!(
            other
                .drain_events()
                .0
                .iter()
                .filter(|event| matches!(event, WorkspaceEvent::AgentHooksFinished { .. }))
                .count(),
            2
        );
    }

    #[test]
    fn disposing_the_owner_cancels_hooks_before_the_worker_runs() {
        let (workspace, refresh) = fixture();
        let other = workspace.open_scene();
        let runtime = Arc::clone(&workspace.scene.runtime);
        let scene = Arc::downgrade(&workspace.scene);
        let install = workspace
            .agent_hooks("ssh:studio", AgentHookAction::Install)
            .unwrap();
        let status = other
            .agent_hooks("ssh:studio", AgentHookAction::Status)
            .unwrap();
        let tokens = {
            let state = runtime.agent_hooks.lock().unwrap();
            [install, status].map(|id| state.0[&id].cancellation.clone())
        };
        drop(workspace);
        assert!(
            tokens[0].is_cancelled(),
            "disposal cancels without resuming the worker"
        );
        assert!(
            scene.upgrade().is_none(),
            "pending hooks must not own the window's scene"
        );
        assert!(
            !tokens[1].is_cancelled(),
            "another window's request stays live"
        );
        refresh.run_next_work();
        refresh.run_next_work();
        assert!(runtime.agent_hooks.lock().unwrap().0.is_empty());
        assert!(other.drain_events().0.iter().any(|event| matches!(event,
            WorkspaceEvent::AgentHooksFinished { operation_id, .. } if *operation_id == status)));
    }

    #[test]
    fn host_removal_and_scene_close_cancel_registered_requests_before_execution() {
        for close in [false, true] {
            let (workspace, refresh) = fixture();
            let id = workspace
                .agent_hooks("ssh:studio", AgentHookAction::Install)
                .unwrap();
            let cancellation = workspace.scene.runtime.agent_hooks.lock().unwrap().0[&id]
                .cancellation
                .clone();
            if close {
                workspace.close();
            } else {
                let navigation = lock_live_navigation(&workspace.scene).unwrap();
                workspace.remove_ssh_host_runtime(&navigation, "ssh:studio", None);
            }
            assert!(
                cancellation.is_cancelled(),
                "registered request must cancel before work resumes"
            );
            refresh.run_next_work();
            assert!(
                workspace
                    .scene
                    .runtime
                    .agent_hooks
                    .lock()
                    .unwrap()
                    .0
                    .is_empty()
            );
        }
    }

    #[test]
    fn installations_hold_off_automatic_reconnect_and_allow_independent_status_reads() {
        let (workspace, refresh) = fixture();
        workspace
            .agent_hooks("ssh:studio", AgentHookAction::Install)
            .unwrap();
        workspace
            .agent_hooks("ssh:studio", AgentHookAction::Status)
            .unwrap();
        assert!(
            workspace
                .agent_hooks("ssh:studio", AgentHookAction::Install)
                .is_err()
        );
        let now = std::time::Instant::now();
        {
            let mut entries = workspace.scene.runtime.remote_hosts.lock().unwrap();
            let entry = entries.get_mut("ssh:studio").unwrap();
            entry.reconnect.enable();
            entry.reconnect.schedule(now);
        }
        {
            let _publication = workspace.scene.runtime.remote_publication.lock().unwrap();
            let _navigation = lock_live_navigation(&workspace.scene).unwrap();
            workspace
                .start_remote_connection(
                    "ssh:studio",
                    Some(now + std::time::Duration::from_secs(1)),
                )
                .unwrap();
        }
        assert_eq!(
            workspace.scene.runtime.remote_hosts.lock().unwrap()["ssh:studio"].generation,
            7
        );
        refresh.run_next_work();
        refresh.run_next_work();
        {
            let _publication = workspace.scene.runtime.remote_publication.lock().unwrap();
            let _navigation = lock_live_navigation(&workspace.scene).unwrap();
            workspace
                .start_remote_connection(
                    "ssh:studio",
                    Some(now + std::time::Duration::from_secs(1)),
                )
                .unwrap();
        }
        assert_ne!(
            workspace.scene.runtime.remote_hosts.lock().unwrap()["ssh:studio"].generation,
            7
        );
        let tasks = refresh.work.lock().unwrap().drain(..).collect::<Vec<_>>();
        drop(tasks);
    }
}
