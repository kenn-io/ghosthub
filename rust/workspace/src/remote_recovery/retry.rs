use std::time::{Duration, Instant};

use crate::{Arc, CancellationToken, Ordering, Runtime, Scene, Workspace, lock_live_navigation};

const INTERVALS: [u64; 6] = [1, 2, 4, 8, 16, 30];

#[derive(Default)]
pub(crate) struct Retry {
    enabled: bool,
    interval: usize,
    next: Option<Instant>,
    started: Option<Instant>,
}

impl Retry {
    pub(crate) fn enable(&mut self) {
        self.enabled = true;
        self.interval = 0;
        self.next = None;
        self.started = None;
    }

    pub(crate) fn pause(&mut self) -> bool {
        let waiting = self.next.take().is_some();
        self.enabled = false;
        self.started = None;
        waiting
    }

    pub(crate) fn schedule(&mut self, now: Instant) {
        if self.enabled && self.next.is_none() {
            self.next =
                Some(self.started.unwrap_or(now) + Duration::from_secs(INTERVALS[self.interval]));
            self.interval = (self.interval + 1).min(INTERVALS.len() - 1);
        }
    }

    pub(crate) fn connected(&mut self) {
        self.next = None;
        self.started = None;
    }

    pub(crate) fn restored(&mut self) {
        self.interval = 0;
        self.connected();
    }

    pub(crate) fn enabled(&self) -> bool {
        self.enabled
    }

    #[cfg(feature = "test-support")]
    pub(crate) fn interval(&self) -> Duration {
        Duration::from_secs(INTERVALS[self.interval])
    }

    fn due(&self, now: Instant) -> bool {
        self.enabled && self.next.is_some_and(|next| next <= now)
    }
}

/// The caller holds publication. An existing connection attempt will schedule any next retry.
pub(crate) fn schedule(scene: &Scene, host_id: &str) {
    if let Some(entry) = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get_mut(host_id)
        && entry.cancellation.is_none()
    {
        entry.reconnect.schedule(Instant::now());
    }
}

/// Wait outside publication, navigation and session locks for tmux to acknowledge its client.
pub(crate) fn confirm_restoration(
    scene: &Scene,
    request: &crate::RemoteTmuxAttachRequest,
    receipt: &host::CreationReceipt,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let identity = request.host.wait_for_creation_identity(
        &request.snapshot,
        receipt,
        cancellation,
        Duration::from_secs(15),
    );
    if identity.as_ref().ok() != Some(request.session.identity()) {
        return;
    }
    let _publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Ok(_navigation) = lock_live_navigation(scene) else {
        return;
    };
    if cancellation.is_cancelled()
        || scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
    {
        return;
    }
    let mut entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(entry) = entries.get_mut(&request.host_id)
        && entry.generation == request.connection_generation
        && scene
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_some_and(|active| {
                active.connection_generation == request.connection_generation
                    && active.navigation_generation == navigation_generation
            })
    {
        entry.reconnect.restored();
    }
}

/// One host attempt serves every scene awaiting that host. No timer owns a scene or lease.
pub(crate) fn tick(scenes: &[Arc<Scene>], now: Instant) {
    let Some(first) = scenes.first() else {
        return;
    };
    let _publication = first
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let hosts: Vec<_> = first
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .filter(|(_, entry)| {
            entry.cancellation.is_none()
                && entry.attachment_attempts.is_empty()
                && entry.reconnect.enabled
        })
        .map(|(id, _)| id.clone())
        .collect();
    for host_id in hosts {
        let mut owner = None;
        for scene in scenes {
            let Ok(navigation) = lock_live_navigation(scene) else {
                continue;
            };
            let pending = scene
                .interrupted_tmux
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if pending.as_ref().is_some_and(|pending| {
                pending.key.host_id == host_id
                    && pending.navigation_generation
                        == scene.navigation_generation.load(crate::Ordering::Acquire)
            }) {
                drop(pending);
                owner = Some((scene, navigation));
                break;
            }
        }
        let start = if let Some(entry) = first
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get_mut(&host_id)
        {
            if owner.is_some() {
                entry.reconnect.schedule(now);
                if entry.reconnect.due(now) {
                    entry.reconnect.next = None;
                    entry.reconnect.started = Some(now);
                    true
                } else {
                    false
                }
            } else {
                entry.reconnect.next = None;
                false
            }
        } else {
            false
        };
        if start && let Some((scene, _navigation)) = owner {
            let workspace = Workspace {
                scene: Arc::clone(scene),
            };
            if let Err(error) = workspace.start_remote_connection(&host_id, false) {
                workspace.push_operation_error(error.to_string());
            }
        }
    }
}

/// Automatic probes are bounded and never leave an orphaned deadline after completion.
pub(crate) fn attempt<T>(
    runtime: &Runtime,
    cancellation: &CancellationToken,
    interactive: bool,
    connect: impl FnOnce() -> Result<T, host::RemoteTmuxError>,
) -> Result<T, host::RemoteTmuxError> {
    if interactive {
        return connect();
    }
    let deadline = CancellationToken::new();
    let expired = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let deadline_expired = Arc::clone(&expired);
    let connection_cancel = cancellation.clone();
    runtime
        .refresh_runtime
        .spawn_after(
            "ghosthub-ssh-reconnect-deadline",
            Duration::from_secs(15),
            deadline.clone(),
            Box::new(move || {
                deadline_expired.store(true, Ordering::Release);
                connection_cancel.cancel();
            }),
        )
        .map_err(|error| host::RemoteTmuxError::transport(format!("Reconnect failed: {error}")))?;
    let result = connect();
    deadline.cancel();
    if expired.load(Ordering::Acquire) {
        Err(host::RemoteTmuxError::timeout("SSH reconnect timed out"))
    } else {
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_recovery_obeys_the_deadline_and_cancellation_before_spawning() {
        for cancel in [None, Some("cancel"), Some("detach"), Some("close")] {
            let refresh = Arc::new(crate::tests::ManualRefreshRuntime::default());
            let workspace = Workspace::application_with_services(
                crate::TerminalAppearance::default(),
                None,
                Arc::new(crate::SystemLocalDiscovery::new()),
                refresh.clone(),
            );
            let (source, request) = crate::tests::remote_kill_refresh_fixture();
            let mut entry = source
                .scene
                .runtime
                .remote_hosts
                .lock()
                .unwrap()
                .remove("ssh:studio")
                .unwrap();
            entry.reconnect.enable();
            workspace
                .scene
                .runtime
                .remote_hosts
                .lock()
                .unwrap()
                .insert("ssh:studio".to_owned(), entry);
            *workspace.scene.runtime.hosts.write().unwrap() = source.snapshot().hosts().to_vec();
            let other = workspace.open_scene();
            for scene in [&workspace.scene, &other.scene] {
                *scene.interrupted_tmux.lock().unwrap() = Some(super::super::InterruptedTmux {
                    key: crate::RemotePresentationKey {
                        host_id: "ssh:studio".to_owned(),
                        endpoint: "studio.example".to_owned(),
                        route_identity: request.snapshot.route_identity().to_owned(),
                        lease_generation: 7,
                        session_identity: crate::RemoteSessionIdentity::Tmux(
                            request.session.identity().clone(),
                        ),
                    },
                    navigation_generation: scene.navigation_generation.load(Ordering::Acquire),
                });
            }
            let scenes = [Arc::clone(&workspace.scene), Arc::clone(&other.scene)];
            let now = Instant::now();
            tick(&scenes, now);
            tick(&scenes, now + Duration::from_millis(999));
            assert!(workspace.snapshot().notice().is_some());
            assert!(
                refresh.work.lock().unwrap().is_empty(),
                "wait before connecting"
            );
            match cancel {
                Some("cancel") => assert!(workspace.cancel_host_connection("ssh:studio")),
                Some("detach") => {
                    workspace.detach();
                    other.detach();
                }
                Some("close") => {
                    workspace.close();
                    other.close();
                }
                None => {}
                _ => unreachable!(),
            }
            if matches!(cancel, Some("detach" | "close")) {
                assert!(workspace.snapshot().notice().is_none());
            }
            tick(&scenes, now + Duration::from_secs(1));
            tick(&scenes, now + Duration::from_mins(1));
            let work = refresh.work.lock().unwrap().drain(..).collect::<Vec<_>>();
            assert_eq!(
                work.len(),
                usize::from(cancel.is_none()),
                "two windows share one attempt; {cancel:?}"
            );
            drop(work);
        }
    }

    #[test]
    fn retries_back_off_and_explicit_retry_resets_the_wait() {
        let mut retry = Retry::default();
        let mut now = Instant::now();
        retry.enable();
        for seconds in [1, 2, 4, 8, 16, 30, 30] {
            retry.schedule(now);
            // Repeated pump passes must not postpone the same attempt.
            retry.schedule(now + Duration::from_millis(500));
            assert!(!retry.due(now + Duration::from_millis(seconds * 1000 - 1)));
            now += Duration::from_secs(seconds);
            assert!(retry.due(now));
            retry.next = None;
            retry.started = Some(now);
        }
        retry.schedule(now);
        assert!(retry.pause());
        retry.schedule(now + Duration::from_mins(1));
        assert!(!retry.due(now + Duration::from_mins(2)));
        retry.enable();
        retry.schedule(now);
        assert!(retry.due(now + Duration::from_secs(1)));
    }

    #[test]
    fn a_connection_without_a_restored_terminal_keeps_the_backoff() {
        let mut retry = Retry::default();
        let now = Instant::now();
        retry.enable();
        retry.schedule(now);
        retry.connected();
        retry.schedule(now);
        assert!(!retry.due(now + Duration::from_millis(1999)));
        assert!(retry.due(now + Duration::from_secs(2)));
        retry.connected();
        retry.schedule(now);
        assert!(!retry.due(now + Duration::from_millis(3999)));
        assert!(retry.due(now + Duration::from_secs(4)));
    }

    #[test]
    fn expired_automatic_probe_cancels_work_and_rejects_late_success() {
        let refresh = Arc::new(crate::tests::ManualRefreshRuntime::default());
        let workspace = Workspace::application_with_services(
            crate::TerminalAppearance::default(),
            None,
            Arc::new(crate::SystemLocalDiscovery::new()),
            refresh.clone(),
        );
        let cancellation = CancellationToken::new();
        let error = attempt(&workspace.scene.runtime, &cancellation, false, || {
            refresh.run_next_deadline();
            assert!(cancellation.is_cancelled());
            Ok(())
        })
        .expect_err("late completion must not publish a connection");
        assert!(error.retryable_transport());

        let cancellation = CancellationToken::new();
        attempt(&workspace.scene.runtime, &cancellation, false, || Ok(())).unwrap();
        refresh.run_next_deadline();
        assert!(
            !cancellation.is_cancelled(),
            "finished probe must retire its deadline"
        );
    }
}
