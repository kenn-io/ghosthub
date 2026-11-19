use crate::{
    Arc, CancellationToken, DiagnosticKind, HostDiagnostic, Ordering, RemoteEntry, Scene, SceneId,
    begin_snapshot_write, current_remote_context, next_operation_id,
};

pub(crate) struct Refresh {
    id: u64,
    scene: SceneId,
    cancellation: CancellationToken,
}

pub(crate) fn cancel(entry: &RemoteEntry) {
    if let Some(read) = &entry.rex_refresh {
        read.cancellation.cancel();
    }
}

pub(crate) fn cancel_scene(scene: &Scene) {
    let entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    for entry in entries.values() {
        if let Some(read) = &entry.rex_refresh
            && read.scene == scene.id
        {
            read.cancellation.cancel();
        }
    }
}

pub(crate) fn refresh(scene: &Arc<Scene>, host_id: &str) {
    if scene.closed.load(Ordering::Acquire) || scene.runtime.remote_kwt_bundles.is_empty() {
        return;
    }
    let (host, snapshot, generation, id, cancellation) = {
        let _publication = scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(entry) = entries.get_mut(host_id) else {
            return;
        };
        if entry
            .rex_refresh
            .as_ref()
            .is_some_and(|read| !read.cancellation.is_cancelled())
        {
            return;
        }
        let Some(context) = current_remote_context(entry) else {
            return;
        };
        let host = context.host.clone();
        let snapshot = context.snapshot.clone();
        let id = next_operation_id(&scene.runtime);
        let cancellation = CancellationToken::new();
        entry.rex_refresh = Some(Refresh {
            id,
            scene: scene.id,
            cancellation: cancellation.clone(),
        });
        (host, snapshot, entry.generation, id, cancellation)
    };
    let owner = Arc::downgrade(scene);
    let host_id = host_id.to_owned();
    let task_host_id = host_id.clone();
    let task_snapshot = snapshot.clone();
    let task_cancellation = cancellation.clone();
    if let Err(e) = scene.runtime.refresh_runtime.spawn(
        "ghosthub-rex-inventory",
        Box::new(move || {
            let result = host
                .discover_rex(&task_snapshot, &task_cancellation)
                .map_err(|e| HostDiagnostic::new(e.kind(), e.to_string()));
            if let Some(scene) = owner.upgrade() {
                finish(
                    &scene,
                    &task_host_id,
                    generation,
                    id,
                    &task_snapshot,
                    result,
                );
            }
        }),
    ) {
        finish(
            scene,
            &host_id,
            generation,
            id,
            &snapshot,
            Err(HostDiagnostic::new(
                DiagnosticKind::Transport,
                format!("Cannot read Rex windows: {e}"),
            )),
        );
    }
}

fn finish(
    scene: &Scene,
    host_id: &str,
    generation: u64,
    id: u64,
    snapshot: &host::RemoteTmuxSnapshot,
    result: Result<(String, Vec<host::rex::Window>), HostDiagnostic>,
) {
    let _publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get_mut(host_id) else {
        return;
    };
    if entry.rex_refresh.as_ref().is_none_or(|read| read.id != id) {
        return;
    }
    let read = entry.rex_refresh.take().unwrap();
    if read.cancellation.is_cancelled()
        || scene.closed.load(Ordering::Acquire)
        || entry.generation != generation
        || current_remote_context(entry).is_none_or(|c| {
            c.snapshot.route_identity() != snapshot.route_identity()
                || c.snapshot.lease_generation() != snapshot.lease_generation()
        })
    {
        return;
    }
    let _write = begin_snapshot_write(&scene.runtime);
    let mut hosts = scene
        .runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|h| h.id() == host_id) else {
        return;
    };
    match result {
        Ok((helper, windows)) => {
            host.rex_helper = Some(helper);
            host.rex_windows = windows;
            host.rex_diagnostic = None;
        }
        Err(e) => host.rex_diagnostic = Some(e),
    }
    scene.runtime.revision.fetch_add(1, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::remote_kill_refresh_fixture;

    #[test]
    fn discovery_updates_are_visible_to_every_scene() {
        let (workspace, request) = remote_kill_refresh_fixture();
        let observer = workspace.open_scene();
        let revision = observer.snapshot().revision();
        let window = host::rex::Window {
            id: "window:build".to_owned(),
            session_id: "session:studio".to_owned(),
            title: "Build".to_owned(),
            detail: "Studio · 1 pane".to_owned(),
        };
        for (id, result) in [
            (1, Ok(("/helper/kwt".to_owned(), vec![window.clone()]))),
            (
                2,
                Err(HostDiagnostic::new(
                    DiagnosticKind::Transport,
                    "Rex unavailable",
                )),
            ),
        ] {
            workspace
                .scene
                .runtime
                .remote_hosts
                .lock()
                .unwrap()
                .get_mut(&request.host_id)
                .unwrap()
                .rex_refresh = Some(Refresh {
                id,
                scene: workspace.scene.id,
                cancellation: CancellationToken::new(),
            });
            finish(
                &workspace.scene,
                &request.host_id,
                request.connection_generation,
                id,
                &request.snapshot,
                result,
            );
            let snapshot = observer.snapshot();
            let host = snapshot
                .hosts()
                .iter()
                .find(|h| h.id() == request.host_id)
                .unwrap();
            assert_eq!(host.rex_windows(), std::slice::from_ref(&window));
            assert_eq!(host.rex_diagnostic().is_some(), id == 2);
            assert_eq!(snapshot.revision(), revision + id);
        }
    }
}
