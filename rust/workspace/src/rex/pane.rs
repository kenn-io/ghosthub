use std::sync::mpsc::{Receiver, TryRecvError, sync_channel};

use std::sync::Arc;

use surface::{GridSize, PixelSize, SurfaceStore};

use crate::{
    CancellationToken, Scene, TerminalWorker, WorkspaceError, current_default_colors,
    current_default_cursor_shape, current_remote_clipboard_policy, next_presentation_id,
};

use super::{Pane, RexRect, Window, error, lock, ssh};

pub(super) struct Pending {
    id: u64,
    cancellation: CancellationToken,
    result: Receiver<Result<Attachment, WorkspaceError>>,
}

struct Attachment {
    worker: TerminalWorker,
    slot: Arc<ssh::Slot>,
}

impl Drop for Pending {
    fn drop(&mut self) {
        self.cancellation.cancel();
    }
}

pub(crate) fn prompt_connection_generation(scene: &Scene, host_id: &str, id: u64) -> Option<u64> {
    let state = lock(scene);
    let window = state.as_ref()?;
    (!window.cancellation.is_cancelled()
        && window.selection.host_id() == host_id
        && window.panes.values().any(|pane| {
            pane.pending
                .as_ref()
                .is_some_and(|p| p.id == id && !p.cancellation.is_cancelled())
        }))
    .then_some(window.connection_generation)
}

fn initial_grid() -> GridSize {
    GridSize::new(80, 24).expect("fixed initial Rex grid")
}

impl Pane {
    pub(super) fn new(scene: &Scene) -> Self {
        Self {
            id: next_presentation_id(&scene.runtime),
            title: String::new(),
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
                0,
                initial_grid(),
            ))),
            worker: None,
            slot: None,
            pending: None,
            queued: true,
            generation: 0,
            rect: RexRect::default(),
            accepted_size: None,
            error: None,
        }
    }

    pub(super) fn fail(&mut self, message: String, session_refused: bool) {
        if let Some(slot) = self.slot.take()
            && session_refused
        {
            slot.refused();
            self.queued = true;
        } else {
            self.error = Some(message);
        }
        self.worker.take();
    }
}

impl Window {
    // At most one terminal launch per window is in flight. KWT may need to
    // authenticate a new master and must never wait on the UI or event pump.
    pub(super) fn poll_pane_launch(&mut self, scene: &Arc<Scene>) -> Result<bool, WorkspaceError> {
        let mut changed = false;
        if let Some((id, pane)) = self.panes.iter_mut().find(|(_, p)| p.pending.is_some()) {
            let pending = pane.pending.as_ref().unwrap();
            let result = match pending.result.try_recv() {
                Ok(result) => result,
                Err(TryRecvError::Empty) => return Ok(false),
                Err(TryRecvError::Disconnected) => Err(error("Cannot open the Rex pane.")),
            };
            pane.pending.take();
            match result {
                Ok(Attachment { worker, slot }) => {
                    pane.id = next_presentation_id(&scene.runtime);
                    pane.surface = worker.surface_handle();
                    pane.slot = Some(slot);
                    pane.accepted_size = None;
                    if self.focused.as_ref() == Some(id) {
                        worker.set_clipboard_writes_enabled(true);
                        crate::reconcile_worker_terminal_settings(&scene.runtime, &worker);
                        scene
                            .worker
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .publish(worker);
                    } else {
                        pane.worker = Some(worker);
                    }
                    self.resize_panes(scene)?;
                }
                Err(error) => pane.error = Some(error.to_string()),
            }
            changed = true;
        }
        let next = self
            .focused
            .as_ref()
            .filter(|id| self.panes[*id].queued)
            .or_else(|| {
                self.panes
                    .iter()
                    .find_map(|(id, pane)| pane.queued.then_some(id))
            })
            .cloned();
        if let Some(id) = next {
            self.start_pane(scene, id);
            changed = true;
        }
        Ok(changed)
    }

    fn start_pane(&mut self, scene: &Arc<Scene>, block: String) {
        let pane = self.panes.get_mut(&block).expect("queued Rex pane");
        pane.queued = false;
        let id = crate::next_operation_id(&scene.runtime);
        let cancellation = CancellationToken::new();
        let (sender, result) = sync_channel(1);
        pane.pending = Some(Pending {
            id,
            cancellation: cancellation.clone(),
            result,
        });
        let owner = Arc::clone(scene);
        let host = self.host.clone();
        let snapshot = self.snapshot.clone();
        let host_id = self.selection.host_id().to_owned();
        let helper = self.helper.clone();
        let term = self.term;
        let spawn = scene.runtime.refresh_runtime.spawn(
            "ghosthub-rex-pane",
            Box::new(move || {
                let result = (|| {
                    let pool = owner
                        .runtime
                        .rex_connections
                        .pool(snapshot.route_identity());
                    let connection =
                        pool.acquire(&owner, &host, &snapshot, &host_id, id, &cancellation)?;
                    let plan = host
                        .rex_plan(&connection.lease, &helper, &block, Some(term.as_str()))
                        .map_err(|e| error(e.to_string()))?;
                    if cancellation.is_cancelled() {
                        return Err(error("Rex pane connection cancelled."));
                    }
                    let slot = Arc::clone(&connection.slot);
                    let worker = TerminalWorker::attach_rex_with_metadata(
                        &plan,
                        Box::new(connection),
                        initial_grid(),
                        0,
                        PixelSize::new(640, 432),
                        current_remote_clipboard_policy(&owner.runtime),
                        current_default_colors(&owner.runtime),
                        current_default_cursor_shape(&owner.runtime),
                    )
                    .map_err(|e| error(e.to_string()))?;
                    worker.set_clipboard_writes_enabled(false);
                    Ok(Attachment { worker, slot })
                })();
                let _ = sender.send(result);
            }),
        );
        if let Err(error) = spawn {
            pane.pending.take();
            pane.error = Some(error.to_string());
        }
    }
}
