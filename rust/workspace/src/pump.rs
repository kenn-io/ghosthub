//! The runtime event pump: the single internal consumer of lane-1 events.
//!
//! One pump pass drains every scene's terminal workers, classifies exits,
//! monitors remote lease liveness, and spawns retained retries. Client-facing
//! events produced along the way are enqueued on the owning scene's inbox;
//! `Workspace::drain_events` is a cheap read of that inbox and never performs
//! lane-1 work itself. `Runtime::event_drain` serializes pump passes, so the
//! single-internal-consumer invariant is structural: no other path consumes
//! worker events.

use crate::PendingPaste;
use crate::scene::{push_clipboard_write_event, push_lossless_event};
use crate::{
    ACTIVE_EVENT_BUDGET, Arc, AttachRequest, AttachTerm, ClipboardRead, ClipboardTarget,
    EVENT_PUMP_INTERVAL, FallbackAuthority, HostConnectionState, HostDiagnostic,
    MAX_EVENTS_PER_DRAIN, Ordering, RetainedRetry, Runtime, SCENE_INBOX_LIMIT, TerminalEvent, Weak,
    Workspace, WorkspaceError, WorkspaceEvent, begin_snapshot_write, bump_scene_revision,
    cancel_remote_attachment, cancel_remote_constructive, claim_terminal_exit,
    classify_remote_terminal_exit, classify_terminal_exit_event, clear_pending_paste,
    clear_terminal_notice, current_remote_context, fail_retained_retry, failed_attachment_context,
    fallback_owns_request, live_scenes, publish_terminfo_retry_boundary,
    reconcile_remote_presentations, restore_attach_fallback, run_attach, run_retained_retry,
    set_remote_host_state, thread,
};

/// Start the background pump through the runtime's refresh service. The
/// production thread runtime drives `pump_once` on a fixed cadence; the
/// manual test runtime records the pump so tests keep driving passes
/// explicitly. Idempotent for the life of the runtime.
///
/// # Errors
///
/// Returns an error when the background pump cannot be scheduled.
pub(crate) fn start_event_pump(runtime: &Arc<Runtime>) -> Result<(), WorkspaceError> {
    if runtime
        .pump_started
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Ok(());
    }
    let weak: Weak<Runtime> = Arc::downgrade(runtime);
    let result = runtime.refresh_runtime.start_pump(
        "ghosthub-event-pump",
        EVENT_PUMP_INTERVAL,
        Box::new(move || {
            weak.upgrade()
                .map(|runtime| {
                    let _backlog = pump_once(&runtime);
                })
                .is_some()
        }),
    );
    if let Err(error) = result {
        runtime.pump_started.store(false, Ordering::Release);
        return Err(WorkspaceError::new(format!("start event pump: {error}")));
    }
    Ok(())
}

/// Run one synchronous pump pass over every live scene.
///
/// This is the deterministic test entry point and the body of every
/// production tick. The pass holds the `event_drain` lock — the pump's
/// serialization — and the global snapshot-write guard, monitors remote
/// lease liveness once, then consumes each scene's worker events within the
/// same per-pass budgets the drain path used previously. Returns whether any
/// scene exhausted a budget, meaning another pass would find more work.
pub(crate) fn pump_once(runtime: &Runtime) -> bool {
    let _drain = runtime
        .event_drain
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _snapshot_write = begin_snapshot_write(runtime);
    monitor_remote_lease_liveness(runtime);
    let mut backlog = false;
    for scene in live_scenes(runtime) {
        let workspace = Workspace { scene };
        backlog |= workspace.pump_scene();
    }
    backlog
}

/// Fail remote hosts whose SSH lease died, exactly as the drain path did:
/// under the remote publication lock so lease death and inventory
/// publication cannot interleave.
pub(crate) fn monitor_remote_lease_liveness(runtime: &Runtime) {
    let _publication = runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _snapshot_write = begin_snapshot_write(runtime);
    let failed = {
        let mut entries = runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        entries
            .iter_mut()
            .filter_map(|(host_id, entry)| {
                let error = current_remote_context(entry)?
                    .snapshot
                    .lease()
                    .ensure_live()
                    .err()?;
                entry.generation = entry.generation.wrapping_add(1).max(1);
                if let Some(cancellation) = entry.cancellation.take() {
                    cancellation.cancel();
                }
                cancel_remote_constructive(entry);
                cancel_remote_attachment(entry);
                let context = entry.context.take()?;
                Some((host_id.clone(), error, context))
            })
            .collect::<Vec<_>>()
    };
    for (host_id, error, context) in failed {
        let stale_presentations = reconcile_remote_presentations(
            runtime,
            &host_id,
            context.snapshot.endpoint(),
            context.snapshot.route_identity(),
            context.snapshot.lease_generation(),
            None,
        );
        set_remote_host_state(
            runtime,
            &host_id,
            HostConnectionState::Unavailable,
            None,
            Some(HostDiagnostic::new(error.kind(), error.to_string())),
        );
        drop(stale_presentations);
        drop(context);
    }
}

impl Workspace {
    /// Consume one pump pass of this scene's worker events: the active
    /// worker within `ACTIVE_EVENT_BUDGET`, exit classification and
    /// handling, then the retained and remote-retained drains within the
    /// remaining budget. Every client-facing event lands on this scene's
    /// inbox.
    #[must_use]
    #[allow(
        clippy::too_many_lines,
        reason = "event pumping keeps active and retained terminal ordering in one boundary"
    )]
    fn pump_scene(&self) -> bool {
        // Captured before any worker event is extracted: clipboard writes
        // extracted by this pass are dropped at flush when a retirement
        // advanced the epoch in between.
        let clipboard_epoch = self.scene.clipboard_epoch.load(Ordering::Acquire);
        // Per-scene backpressure: never poll workers without inbox headroom
        // for everything one pass can emit. Terminal-originated events are
        // therefore never shed — they wait inside the worker until this
        // scene's client drains — and a stalled scene pauses only itself.
        let queued = self
            .scene
            .operation_events
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len();
        if SCENE_INBOX_LIMIT.saturating_sub(queued) < MAX_EVENTS_PER_DRAIN {
            return self.scene_has_worker_sources();
        }
        let mut emitted = Vec::new();
        let mut exited = false;
        let mut exited_attachment = None;
        let mut exited_worker_generation = None;
        let mut exit_error = None;
        let mut retry_term = false;
        let mut processed = 0;
        for _ in 0..ACTIVE_EVENT_BUDGET {
            let Some((event, source_worker_generation, client_confirmed_live)) =
                self.next_terminal_event()
            else {
                break;
            };
            match event {
                Ok(Some(TerminalEvent::ClipboardWrite { write, .. })) => {
                    processed += 1;
                    emitted.push(WorkspaceEvent::ClipboardWrite {
                        text: write.text,
                        primary: write.target == ClipboardTarget::Selection,
                    });
                }
                Ok(Some(TerminalEvent::ClipboardRead(read))) => {
                    processed += 1;
                    emitted.push(WorkspaceEvent::ClipboardRead(ClipboardRead {
                        inner: read,
                        worker_generation: source_worker_generation,
                    }));
                }
                Ok(Some(TerminalEvent::ConfirmPaste(paste))) => {
                    processed += 1;
                    let mut pending = self
                        .scene
                        .pending_paste
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if pending.is_none() {
                        *pending = Some(PendingPaste {
                            worker_generation: source_worker_generation,
                            input: paste,
                        });
                        emitted.push(WorkspaceEvent::ConfirmPaste);
                    }
                }
                Ok(Some(TerminalEvent::Exited { code, output_tail })) => {
                    processed += 1;
                    let Some((request, term, generation, fallback)) =
                        self.attachment_for_worker(source_worker_generation)
                    else {
                        if self.handle_remote_terminal_exit(
                            source_worker_generation,
                            self.classify_active_remote_terminal_exit(
                                source_worker_generation,
                                code,
                                &output_tail,
                            ),
                            &mut emitted,
                        ) {
                            exited = true;
                        }
                        break;
                    };
                    (retry_term, exit_error) = classify_terminal_exit_event(
                        code,
                        &output_tail,
                        term,
                        client_confirmed_live,
                    );
                    exited_attachment = Some((request, generation, fallback));
                    exited_worker_generation = Some(source_worker_generation);
                    exited = true;
                    break;
                }
                Ok(Some(TerminalEvent::Error(error))) => {
                    processed += 1;
                    emitted.push(WorkspaceEvent::Error(error));
                }
                Ok(None) => break,
                Err(error) => {
                    let Some((request, _, generation, fallback)) =
                        self.attachment_for_worker(source_worker_generation)
                    else {
                        if self.handle_remote_terminal_exit(
                            source_worker_generation,
                            Some(error.to_string()),
                            &mut emitted,
                        ) {
                            exited = true;
                        }
                        break;
                    };
                    exit_error = Some(error.to_string());
                    exited_attachment = Some((request, generation, fallback));
                    exited_worker_generation = Some(source_worker_generation);
                    exited = true;
                    break;
                }
            }
        }
        if exited && let Some(worker_generation) = exited_worker_generation {
            self.handle_terminal_exit(
                exited_attachment,
                worker_generation,
                retry_term,
                exit_error,
                &mut emitted,
            );
        }
        let active_processed = processed;
        let retained_budget = retained_event_budget(processed, exited);
        let remote_retained_budget = retained_budget.div_ceil(2);
        let local_retained_budget = retained_budget - remote_retained_budget;
        let retained_processed = self.drain_retained_events(local_retained_budget, &mut emitted);
        let remote_retained_processed =
            self.drain_remote_retained_events(remote_retained_budget, &mut emitted);
        for event in emitted {
            if matches!(event, WorkspaceEvent::ClipboardWrite { .. }) {
                push_clipboard_write_event(&self.scene, event, clipboard_epoch);
            } else {
                push_lossless_event(&self.scene, event);
            }
        }
        event_source_may_have_more(active_processed, ACTIVE_EVENT_BUDGET, exited)
            || event_source_may_have_more(retained_processed, local_retained_budget, false)
            || event_source_may_have_more(remote_retained_processed, remote_retained_budget, false)
    }

    /// Whether this scene has any worker whose events the pump would
    /// consume; a paused scene reports backlog only when there is work to
    /// resume.
    fn scene_has_worker_sources(&self) -> bool {
        self.scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active()
            .is_some()
            || self
                .scene
                .retained_presentations
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .has_workers()
            || self
                .scene
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .has_workers()
    }

    fn handle_remote_terminal_exit(
        &self,
        worker_generation: u64,
        error: Option<String>,
        emitted: &mut Vec<WorkspaceEvent>,
    ) -> bool {
        let mut remote_active = self
            .scene
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if remote_active
            .as_ref()
            .is_none_or(|active| active.worker_generation != worker_generation)
        {
            return false;
        }
        let mut worker = self
            .scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if worker.generation() != worker_generation {
            return false;
        }
        let _closed = worker.invalidate_if_generation(worker_generation);
        let _active = remote_active.take();
        drop(worker);
        drop(remote_active);
        clear_pending_paste(&self.scene);
        clear_terminal_notice(&self.scene);
        self.restore_inventory_state();
        if let Some(error) = error {
            emitted.push(WorkspaceEvent::Error(error));
        }
        true
    }

    fn classify_active_remote_terminal_exit(
        &self,
        worker_generation: u64,
        code: u32,
        output_tail: &str,
    ) -> Option<String> {
        let remote_active = self
            .scene
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let active = remote_active
            .as_ref()
            .filter(|active| active.worker_generation == worker_generation)?;
        classify_remote_terminal_exit(
            code,
            output_tail,
            active.identity_mismatch_marker.as_deref(),
        )
    }

    fn next_terminal_event(
        &self,
    ) -> Option<(
        Result<Option<TerminalEvent>, terminal::WorkerError>,
        u64,
        bool,
    )> {
        let (event, worker_generation, confirmed) = {
            let worker = self
                .scene
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let (worker, generation) = worker.active_with_generation()?;
            (worker.try_event(), generation, worker.is_confirmed_live())
        };
        if confirmed {
            self.mark_attachment_confirmed(worker_generation);
        }
        Some((event, worker_generation, confirmed))
    }

    fn drain_retained_events(&self, budget: usize, emitted: &mut Vec<WorkspaceEvent>) -> usize {
        let drain = self
            .scene
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .drain_events(budget);
        if drain.changed {
            bump_scene_revision(&self.scene);
        }
        emitted.extend(drain.emitted);
        for retry in drain.retries {
            self.retry_retained_with_xterm(retry, emitted);
        }
        drain.processed
    }

    fn drain_remote_retained_events(
        &self,
        budget: usize,
        emitted: &mut Vec<WorkspaceEvent>,
    ) -> usize {
        let drain = self
            .scene
            .remote_retained
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .drain_events(budget);
        if drain.changed {
            bump_scene_revision(&self.scene);
        }
        emitted.extend(drain.emitted);
        drain.processed
    }

    fn attachment_for_worker(
        &self,
        worker_generation: u64,
    ) -> Option<(AttachRequest, AttachTerm, u64, Option<FallbackAuthority>)> {
        if self
            .scene
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_some_and(|active| active.worker_generation == worker_generation)
        {
            return None;
        }
        let attachment = self
            .scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self
            .scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .generation()
            != worker_generation
        {
            return None;
        }
        attachment.active().map(|active| {
            (
                active.request.clone(),
                active.term,
                active.generation,
                active.fallback.clone(),
            )
        })
    }

    fn mark_attachment_confirmed(&self, worker_generation: u64) {
        let mut attachment = self
            .scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self
            .scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .generation()
            != worker_generation
        {
            return;
        }
        if let Some(generation) = attachment.active().map(|active| active.generation) {
            attachment.confirm_if_current(generation);
        }
    }

    fn handle_terminal_exit(
        &self,
        attachment: Option<(AttachRequest, u64, Option<FallbackAuthority>)>,
        worker_generation: u64,
        retry_term: bool,
        exit_error: Option<String>,
        emitted: &mut Vec<WorkspaceEvent>,
    ) {
        let Some((request, generation, fallback)) = attachment else {
            return;
        };
        let fallback =
            fallback.filter(|fallback| fallback_owns_request(&self.scene, fallback, &request));
        {
            let mut attachment = self
                .scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut worker = self
                .scene
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !claim_terminal_exit(
                &mut attachment,
                &mut worker,
                generation,
                worker_generation,
                retry_term,
            ) {
                return;
            }
            if let Some(error) = exit_error {
                emitted.push(WorkspaceEvent::Error(error));
            }
            if retry_term {
                publish_terminfo_retry_boundary(
                    &self.scene,
                    &request.host_id,
                    request.endpoint.distro(),
                    &request.name,
                    request.target.kind(),
                );
            } else {
                clear_pending_paste(&self.scene);
                clear_terminal_notice(&self.scene);
                self.restore_inventory_state();
            }
        }
        if retry_term {
            self.retry_with_xterm(request, generation, emitted);
        } else {
            restore_attach_fallback(&self.scene, fallback);
        }
    }

    fn retry_with_xterm(
        &self,
        request: AttachRequest,
        generation: u64,
        emitted: &mut Vec<WorkspaceEvent>,
    ) {
        {
            let mut attachment = self
                .scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !attachment.promote_if_current(generation, AttachTerm::Xterm) {
                return;
            }
        }
        let scene = Arc::clone(&self.scene);
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-terminal-terminfo-retry".to_owned())
            .spawn(move || run_attach(&scene, &request, AttachTerm::Xterm, generation))
        {
            let mut attachment = self
                .scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some((_, fallback)) =
                failed_attachment_context(&self.scene, &attachment, generation)
            {
                attachment.clear_if_current(generation);
                drop(attachment);
                self.restore_inventory_state();
                restore_attach_fallback(&self.scene, fallback);
                emitted.push(WorkspaceEvent::Error(format!(
                    "start TERM=xterm retry: {error}"
                )));
            }
        }
    }

    fn retry_retained_with_xterm(&self, retry: RetainedRetry, emitted: &mut Vec<WorkspaceEvent>) {
        let scene = Arc::clone(&self.scene);
        let key = retry.key.clone();
        if let Err(error) = thread::Builder::new()
            .name("ghosthub-retained-terminal-terminfo-retry".to_owned())
            .spawn(move || run_retained_retry(&scene, &retry))
        {
            fail_retained_retry(&self.scene, &key, None);
            emitted.push(WorkspaceEvent::Error(format!(
                "start retained TERM=xterm retry: {error}"
            )));
        }
    }
}

pub(crate) const fn event_source_may_have_more(
    processed: usize,
    budget: usize,
    exited: bool,
) -> bool {
    budget > 0 && !exited && processed == budget
}

pub(crate) const fn retained_event_budget(processed: usize, exited: bool) -> usize {
    if exited {
        0
    } else {
        MAX_EVENTS_PER_DRAIN.saturating_sub(processed)
    }
}
