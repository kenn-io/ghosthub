use crate::{
    CancellationToken, RemoteTmuxSnapshot, Runtime, begin_snapshot_write, current_remote_context,
    remote_snapshot_authority_matches, set_remote_host_snapshot,
};

pub(crate) fn refresh_all(runtime: &Runtime) {
    let requests: Vec<_> = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .filter_map(|(id, entry)| {
            let context = current_remote_context(entry)?;
            let snapshot = &context.snapshot;
            if snapshot.sessions().is_empty()
                && snapshot.sessions_on(host::RemoteTmuxServer::Kwt).is_empty()
            {
                return None;
            }
            Some((
                id.clone(),
                entry.generation,
                context.host.clone(),
                snapshot.clone(),
            ))
        })
        .collect();
    for (id, generation, host, snapshot) in requests {
        let updated = host.refresh_agent_activity(&snapshot, &CancellationToken::new());
        publish(runtime, &id, generation, &snapshot, updated);
    }
}

fn publish(
    runtime: &Runtime,
    host_id: &str,
    generation: u64,
    expected: &RemoteTmuxSnapshot,
    updated: RemoteTmuxSnapshot,
) {
    let _publication = runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _snapshot_write = begin_snapshot_write(runtime);
    let mut entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get_mut(host_id) else {
        return;
    };
    if entry.generation != generation
        || !current_remote_context(entry)
            .is_some_and(|context| remote_snapshot_authority_matches(&context.snapshot, expected))
    {
        return;
    }
    let context = entry.context.as_mut().expect("checked current context");
    if context.snapshot.sessions() == updated.sessions()
        && context.snapshot.sessions_on(host::RemoteTmuxServer::Kwt)
            == updated.sessions_on(host::RemoteTmuxServer::Kwt)
    {
        return;
    }
    // Hook changes do not invalidate session operation or navigation authority.
    context.snapshot = updated;
    set_remote_host_snapshot(runtime, host_id, &context.snapshot);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::remote_kill_refresh_fixture;

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
                updated,
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
