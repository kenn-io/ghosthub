use crate::{
    CancellationToken, RemoteTmuxSnapshot, Runtime, begin_snapshot_write, current_remote_context,
    remote_snapshot_authority_matches,
};

const MAX_POLLS: usize = 2;

#[derive(Default)]
pub(crate) struct Polls {
    queued: std::collections::VecDeque<String>,
    active: std::collections::HashSet<String>,
}

pub(crate) fn refresh_all(runtime: &std::sync::Arc<Runtime>) {
    let mut hosts: Vec<_> = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .filter_map(|(id, entry)| {
            let snapshot = &current_remote_context(entry)?.snapshot;
            (!snapshot.sessions().is_empty()
                || !snapshot.sessions_on(host::RemoteTmuxServer::Kwt).is_empty())
            .then(|| id.clone())
        })
        .collect();
    hosts.sort();
    {
        let mut polls = runtime
            .attention_polls
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for id in hosts {
            if !polls.active.contains(&id) && !polls.queued.contains(&id) {
                polls.queued.push_back(id);
            }
        }
    }
    start_queued(runtime);
}

fn start_queued(runtime: &std::sync::Arc<Runtime>) {
    if !crate::scene::inventory_polling_wanted(runtime) {
        runtime
            .attention_polls
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .queued
            .clear();
        return;
    }
    loop {
        let id = {
            let mut polls = runtime
                .attention_polls
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if polls.active.len() >= MAX_POLLS {
                return;
            }
            let Some(id) = polls.queued.pop_front() else {
                return;
            };
            polls.active.insert(id.clone());
            id
        };
        let weak = std::sync::Arc::downgrade(runtime);
        let host_id = id.clone();
        if runtime
            .refresh_runtime
            .spawn(
                "ghosthub-remote-attention",
                Box::new(move || {
                    let Some(runtime) = weak.upgrade() else {
                        return;
                    };
                    refresh_one(&runtime, &host_id);
                    runtime
                        .attention_polls
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .active
                        .remove(&host_id);
                    start_queued(&runtime);
                }),
            )
            .is_err()
        {
            runtime
                .attention_polls
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .active
                .remove(&id);
        }
    }
}

fn refresh_one(runtime: &Runtime, id: &str) {
    // Capture after leaving the queue so queued hosts retain no obsolete lease.
    let request = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(id)
        .and_then(|entry| {
            let context = current_remote_context(entry)?;
            Some((
                entry.generation,
                context.host.clone(),
                context.snapshot.clone(),
            ))
        });
    let Some((generation, host, snapshot)) = request else {
        return;
    };
    let updated = host.refresh_agent_activity(&snapshot, &CancellationToken::new());
    publish(runtime, id, generation, &snapshot, &updated);
}

fn publish(
    runtime: &Runtime,
    host_id: &str,
    generation: u64,
    expected: &RemoteTmuxSnapshot,
    updated: &RemoteTmuxSnapshot,
) {
    let _publication = runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _snapshot_write = begin_snapshot_write(runtime);
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get(host_id) else {
        return;
    };
    if entry.generation != generation
        || !current_remote_context(entry)
            .is_some_and(|context| remote_snapshot_authority_matches(&context.snapshot, expected))
    {
        return;
    }
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == host_id) else {
        return;
    };
    let mut changed = false;
    for (items, sessions) in [
        (&mut host.sessions, updated.sessions()),
        (
            &mut host.kwt_sessions,
            updated.sessions_on(host::RemoteTmuxServer::Kwt),
        ),
    ] {
        for item in items {
            let activity = sessions
                .iter()
                .find(|session| session.name() == item.name)
                .and_then(session::DiscoveredSession::agent_activity)
                .cloned();
            if item.agent_activity != activity {
                item.agent_activity = activity;
                changed = true;
            }
        }
    }
    if changed {
        runtime
            .revision
            .fetch_add(1, std::sync::atomic::Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::remote_kill_refresh_fixture;

    fn queued_workspace() -> (
        crate::Workspace,
        std::sync::Arc<crate::tests::ManualRefreshRuntime>,
    ) {
        let (source, _) = remote_kill_refresh_fixture();
        let refresh = std::sync::Arc::new(crate::tests::ManualRefreshRuntime::default());
        let workspace = crate::Workspace::application_with_services(
            config::TerminalAppearance::default(),
            None,
            std::sync::Arc::new(crate::SystemLocalDiscovery::new()),
            refresh.clone(),
        );
        *workspace.scene.runtime.hosts.write().unwrap() = source.snapshot().hosts().to_vec();
        *workspace.scene.runtime.remote_hosts.lock().unwrap() =
            std::mem::take(&mut *source.scene.runtime.remote_hosts.lock().unwrap());
        workspace.set_inventory_polling_enabled(true);
        (workspace, refresh)
    }

    fn add_host(workspace: &crate::Workspace, id: &str, endpoint: &str) {
        let (source, request) = remote_kill_refresh_fixture();
        let mut entry = source
            .scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap()
            .remove(&request.host_id)
            .unwrap();
        let config = host::RemoteTmuxConfig::new(
            id,
            id,
            host::SshTarget::new(endpoint, None, None).unwrap(),
            "/usr/bin/tmux",
            None,
        )
        .unwrap();
        let host = crate::tests::remote_host_fixture(&config);
        let snapshot = RemoteTmuxSnapshot::test_fixture(
            endpoint,
            request.snapshot.route_identity(),
            request.snapshot.lease_generation(),
            request.snapshot.sessions().to_vec(),
            host::HerdrInventory::Unavailable,
            host::ZellijInventory::Unavailable,
        );
        entry.config = config;
        entry.native_host = Some(host.clone());
        entry.context = Some(crate::RemoteHostContext {
            generation: 7,
            host,
            snapshot,
        });
        workspace
            .scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap()
            .insert(id.to_owned(), entry);
        workspace
            .scene
            .runtime
            .hosts
            .write()
            .unwrap()
            .push(crate::HostItem::ssh(
                id,
                id,
                endpoint,
                crate::HostConnectionState::Ready,
                vec![crate::SessionItem::new("review", 0)],
                None,
            ));
    }

    #[test]
    fn a_pending_host_leaves_capacity_for_other_hosts_and_bounds_all_polls() {
        let (workspace, refresh) = queued_workspace();
        add_host(&workspace, "ssh:alpha", "alpha.example");
        add_host(&workspace, "ssh:beta", "beta.example");
        refresh_all(&workspace.scene.runtime);
        refresh_all(&workspace.scene.runtime);
        assert_eq!(refresh.work.lock().unwrap().len(), 2);
        assert_eq!(
            workspace
                .scene
                .runtime
                .attention_polls
                .lock()
                .unwrap()
                .queued
                .len(),
            1
        );
        // Leave alpha's work pending while beta completes and starts Studio.
        let beta = refresh.work.lock().unwrap().pop_back().unwrap();
        beta();
        assert_eq!(refresh.work.lock().unwrap().len(), 2);
        {
            let polls = workspace.scene.runtime.attention_polls.lock().unwrap();
            assert_eq!(polls.active.len(), 2);
            assert!(polls.active.contains("ssh:alpha"));
            assert!(polls.active.contains("ssh:studio"));
            assert!(polls.queued.is_empty());
        }
        let studio = refresh.work.lock().unwrap().pop_back().unwrap();
        studio();
        assert_eq!(refresh.work.lock().unwrap().len(), 1);
        refresh.run_next_work();
        assert!(
            workspace
                .scene
                .runtime
                .attention_polls
                .lock()
                .unwrap()
                .active
                .is_empty()
        );
    }

    #[test]
    fn failed_worker_start_releases_the_host_for_the_next_tick() {
        let (workspace, refresh) = queued_workspace();
        refresh.fail_next_work(|| {});
        refresh_all(&workspace.scene.runtime);
        assert!(refresh.work.lock().unwrap().is_empty());
        refresh_all(&workspace.scene.runtime);
        assert_eq!(refresh.work.lock().unwrap().len(), 1);
        refresh.run_next_work();
    }

    #[test]
    fn attention_reads_do_not_run_on_the_cadence_or_overlap_for_a_host() {
        let (workspace, refresh) = queued_workspace();
        workspace.start_inventory_cadence().unwrap();
        refresh.run_next_deadline();
        assert_eq!(
            refresh.work.lock().unwrap().len(),
            1,
            "remote read is background work"
        );
        refresh.run_next_deadline();
        assert_eq!(
            refresh.work.lock().unwrap().len(),
            1,
            "a pending host is not polled twice"
        );
        refresh.run_next_work();
        refresh.run_next_deadline();
        assert_eq!(
            refresh.work.lock().unwrap().len(),
            1,
            "completion permits a later poll"
        );
    }

    #[test]
    fn hook_updates_preserve_backend_failures_and_pending_launches() {
        for pending in [false, true] {
            let (workspace, request) = remote_kill_refresh_fixture();
            let runtime = &workspace.scene.runtime;
            {
                let mut hosts = runtime.hosts.write().unwrap();
                hosts[0] = hosts[0]
                    .clone()
                    .with_herdr_sessions(vec![crate::HerdrSessionItem::new(
                        "api",
                        false,
                        crate::HerdrSessionState::Stopped,
                    )])
                    .with_zellij_sessions(vec![crate::SessionItem::new("build", 0)]);
                crate::apply_zellij_inventory(
                    &mut hosts[0],
                    &host::ZellijInventory::Failed(
                        host::WslExecutable::from_absolute("wsl.exe").unwrap_err(),
                    ),
                );
                if !pending {
                    crate::apply_herdr_inventory(
                        &mut hosts[0],
                        &host::HerdrInventory::Failed(
                            host::WslExecutable::from_absolute("wsl.exe").unwrap_err(),
                        ),
                    );
                }
            }
            if pending {
                crate::set_remote_herdr_launch_pending(runtime, &request.host_id, "api", true);
            }
            let before = workspace.snapshot().hosts()[0].clone();
            let mut sessions = request.snapshot.sessions().to_vec();
            session::apply_agent_activity(&mut sessions, b"42|$1|100|%0|input 101 codex\n");
            let updated = RemoteTmuxSnapshot::test_fixture(
                request.snapshot.endpoint(),
                request.snapshot.route_identity(),
                request.snapshot.lease_generation(),
                sessions,
                host::HerdrInventory::Unavailable,
                host::ZellijInventory::Unavailable,
            );
            publish(
                runtime,
                &request.host_id,
                request.connection_generation,
                &request.snapshot,
                &updated,
            );
            let after = workspace.snapshot();
            let host = &after.hosts()[0];
            assert_eq!(
                host.tmux_agent_activity("review", None).unwrap().label(),
                "Codex is waiting for input"
            );
            assert_eq!(host.herdr_sessions(), before.herdr_sessions());
            assert_eq!(host.herdr_diagnostic(), before.herdr_diagnostic());
            assert_eq!(host.herdr_available(), before.herdr_available());
            assert_eq!(host.zellij_sessions(), before.zellij_sessions());
            assert_eq!(host.zellij_diagnostic(), before.zellij_diagnostic());
        }
    }

    #[test]
    fn hook_publication_preserves_inventory_authority_and_rejects_superseded_reads() {
        for changed in ["none", "inventory", "connection", "removed"] {
            let (workspace, request) = remote_kill_refresh_fixture();
            let runtime = &workspace.scene.runtime;
            let mut sessions = request.snapshot.sessions().to_vec();
            session::apply_agent_activity(&mut sessions, b"42|$1|100|%0|input 101 codex\n");
            let updated = RemoteTmuxSnapshot::test_fixture(
                request.snapshot.endpoint(),
                request.snapshot.route_identity(),
                request.snapshot.lease_generation(),
                sessions,
                host::HerdrInventory::Unavailable,
                host::ZellijInventory::Unavailable,
            );
            {
                let mut entries = runtime.remote_hosts.lock().unwrap();
                if changed == "removed" {
                    entries.remove(&request.host_id);
                } else {
                    let entry = entries.get_mut(&request.host_id).unwrap();
                    if changed == "connection" {
                        entry.generation += 1;
                    } else if changed == "inventory" {
                        let current = &entry.context.as_ref().unwrap().snapshot;
                        let inventory = host::RemoteSessionInventory::test_fixture(
                            Some("/usr/bin/tmux".to_owned()),
                            current.sessions().to_vec(),
                            host::HerdrInventory::Unavailable,
                            host::ZellijInventory::Unavailable,
                        );
                        entry.context.as_mut().unwrap().snapshot =
                            current.with_inventory(inventory);
                    }
                }
            }
            publish(
                runtime,
                &request.host_id,
                request.connection_generation,
                &request.snapshot,
                &updated,
            );
            let snapshot = workspace.snapshot();
            let activity = snapshot.hosts()[0].tmux_agent_activity("review", None);
            assert_eq!(
                activity.map(crate::AgentActivity::label),
                (changed == "none").then(|| "Codex is waiting for input".to_owned()),
                "{changed}"
            );
            if changed == "none" {
                let entries = runtime.remote_hosts.lock().unwrap();
                let current = &entries[&request.host_id].context.as_ref().unwrap().snapshot;
                assert_eq!(
                    current.inventory_generation(),
                    request.snapshot.inventory_generation()
                );
            }
        }
    }
}
