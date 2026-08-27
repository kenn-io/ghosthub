//! Per-client scene state layered over the shared runtime.

use crate::{
    Arc, AtomicBool, AtomicU64, AttachFreshError, AttachRequest, AttachTarget, AttachTerm,
    AttachmentState, CREATE_IDENTITY_TIMEOUT, CancellationToken, ClipboardPolicy,
    ClosedRetainedPresentation, ConptyAdmissionAttacher, CreateRequest, DiagnosticKind,
    DirectoryWorkspaceItem, Duration, FallbackAuthority, HERDR_STARTUP_BACKOFF, HerdrCreateRequest,
    HerdrInventory, HerdrLaunchPrecondition, HerdrLaunchTarget, HerdrLifecycleAction,
    HerdrSessionName, HerdrSessionState, HostConnectionState, HostContext, HostDiagnostic,
    HostError, HostItem, HostSnapshot, INVENTORY_REFRESH_INTERVAL, Instant, KWT_REFRESH_BUDGET,
    KWT_REFRESH_INTERVAL, KillCaptureIntent, KillCaptureRequest, KillTarget, KwtBranchItem,
    KwtInventory, KwtProjectAction, KwtProjectMutationRequest, KwtProjectMutationTask,
    KwtPullRequestImportRequest, KwtPullRequestItem, KwtRefresh, KwtRemovalCapture,
    KwtRemovalCaptureIntent, KwtState, KwtTmuxAttachMode, KwtWorktreeOperation, KwtWorktreeOutcome,
    KwtWorktreeTarget, KwtWorktreeTask, Mutex, Ordering, PendingCreation, PendingHerdrLifecycle,
    PendingKill, PendingKwtCreation, PendingKwtRemoval, PendingPaste, PresentationKey, ProjectItem,
    Published, REDUCED_COLOR_NOTICE, RecvTimeoutError, RefreshPresentation, RemoteActive,
    RemoteAttachmentReset, RemoteConstructiveReset, RemoteConstructiveState,
    RemoteConstructiveTarget, RemoteHerdrAttachRequest, RemoteHerdrCreateRequest,
    RemoteHostContext, RemoteInventory, RemotePresentationKey, RemotePublicationFence,
    RemotePublishError, RemoteReconcile, RemoteRetainedPresentation, RemoteRetainedPresentations,
    RemoteSessionIdentity, RemoteSessionInventory, RemoteTmuxAttachRequest, RemoteTmuxSnapshot,
    RemoteZellijAttachRequest, RemoteZellijCreateRequest, RetainedPresentation,
    RetainedPresentations, RetainedRetry, Runtime, RuntimeHost, RuntimeRemoteHost, RwLock,
    SCENE_INBOX_LIMIT, SSH_PROMPT_TIMEOUT, SceneId, SessionKind, SessionName, SessionSelection,
    SshLeasePrompt, SshPromptRequest, SuppressedHerdrPresentation, TMUX_CREATE_DISCOVERY_ATTEMPTS,
    TMUX_CREATE_DISCOVERY_DELAY, TerminalGeometry, TerminalWorker, TryLockError,
    WORKTREE_CLIENT_STARTUP_BACKOFF, WorkerState, Workspace, WorkspaceContent, WorkspaceError,
    WorkspaceEvent, WorkspaceNotice, WorktreeClientStartupError, WorktreeItem, WorktreeLaunchError,
    ZellijCreateRequest, ZellijInventory, ZellijSessionName, begin_snapshot_write,
    cadence_fallback_scene, cancel_remote_attachment, cancel_remote_constructive,
    cancel_scene_remote_attachments, cancel_superseded_remote_constructive_navigation,
    capture_kwt_creation_baseline, clear_pending_remote_constructive, created_session,
    creation_launch_geometry, current_default_colors, current_default_cursor_shape,
    current_inventory_session_name, default_terminal_geometry, discover_fresh_runtime,
    finish_pending_creation, fmt, for_each_scene, fresh_herdr_session, herdr_launch_result_matches,
    insert_remote_retained_presentation, insert_retained_presentation, invalidate_kwt_inventory,
    kwt_attachment_failure, kwt_pull_request_import_failure, live_scenes, lock_session_operations,
    next_operation_id, next_presentation_id, next_scene_id, normalize_attached_worktree_target,
    pending_kwt_creation, pending_kwt_creation_target, pending_remote_constructive_snapshot,
    poll_session_startup, preflight_kwt_worktree_remove, publish_refresh,
    publish_worker_at_latest_geometry, ready_content, recapture_remote_herdr_attach_request,
    recapture_remote_herdr_create_request, recapture_remote_tmux_attach_request,
    recapture_remote_zellij_attach_request, recapture_remote_zellij_create_request,
    reconcile_active_worker_cursor, reconcile_herdr_lifecycle_fences,
    reconcile_kwt_session_availability, refresh_budget, refreshed_session_name, register_scene,
    remember_pending_kwt_creation, remote_constructive_is_current,
    remote_constructive_target_is_present, remove_cached_kwt_worktree,
    require_current_protected_selection, require_host_session_actions, require_wsl_host_id,
    reserve_constructive_inventory, reserve_refresh, reserve_retained_attachment,
    resize_terminal_worker, resolve_remote_herdr_attach_target,
    resolve_remote_zellij_attach_target, resolve_retained_retry_request, retain_remote_session,
    set_herdr_inventory, set_remote_herdr_launch_pending, set_remote_host_snapshot,
    set_remote_host_state, set_zellij_inventory, settle_remote_constructive_task, sync_channel,
    thread, unregister_scene, validate_herdr_launch_precondition, validate_kwt_worktree_operation,
    validate_protected_worktree_inventory, validate_remote_publication_fence,
    wait_for_worktree_client_startup, with_current_remote_constructive, with_herdr_launch_fence,
};
pub(crate) fn presentation_is_open(scene: &Scene, key: &PresentationKey) -> bool {
    let active = scene
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .active()
        .is_some_and(|active| active.request.presentation_key() == *key);
    if active {
        return true;
    }
    scene
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .contains(key)
}

/// Per-client state: published content, selection, navigation intent, the
/// active and retained presentations, viewer geometry, pending
/// confirmations, and the client's event queue. Today exactly one `Scene`
/// exists per `Workspace`; it reaches shared state through `runtime`.
pub(crate) struct Scene {
    pub(crate) id: SceneId,
    /// Whether this scene has been closed. Set exactly once by
    /// `release_scene`; after that every event push cancels instead of
    /// enqueueing, the blocked SSH prompt loop fails closed, and no new
    /// addressed request is minted for this scene. Background tasks may
    /// still hold strong references to a closed scene, so liveness in the
    /// registry alone cannot express this state.
    pub(crate) closed: AtomicBool,
    /// Scene-local revision counter layered on the runtime revision; a
    /// scene's published snapshot revision is the sum of both, so it stays
    /// monotonic whether a change was scene-local or a runtime broadcast.
    pub(crate) revision: AtomicU64,
    pub(crate) runtime: Arc<Runtime>,
    pub(crate) state: RwLock<WorkspaceContent>,
    pub(crate) selected_host: RwLock<Option<String>>,
    pub(crate) navigation_generation: AtomicU64,
    /// Whether this scene's client wants automatic inventory reads; the
    /// shared cadence runs while any live scene wants them.
    pub(crate) inventory_polling_enabled: AtomicBool,
    pub(crate) navigation: Mutex<()>,
    pub(crate) remote_active: Mutex<Option<RemoteActive>>,
    pub(crate) remote_retained: Mutex<RemoteRetainedPresentations>,
    pub(crate) worker: Mutex<WorkerState<TerminalWorker>>,
    pub(crate) retained_presentations: Mutex<RetainedPresentations<TerminalWorker>>,
    pub(crate) pending_paste: Mutex<Option<PendingPaste>>,
    pub(crate) pending_creation: Mutex<Option<PendingCreation>>,
    pub(crate) pending_kill: Mutex<Option<PendingKill>>,
    /// Target of this scene's in-flight asynchronous kill identity capture;
    /// completed mutations fence matching captures through it. Lock order:
    /// `pending_kill` first when both are held.
    pub(crate) kill_capture_intent: Mutex<Option<KillCaptureIntent>>,
    /// Confirmation fence for this scene's pending kill dialog. Advancing it
    /// invalidates only this scene's confirmation; other scenes' dialogs
    /// stay valid. Runtime-wide mutation serialization is separate
    /// (`session_operations`).
    pub(crate) kill_generation: AtomicU64,
    pub(crate) pending_herdr_lifecycle: Mutex<Option<PendingHerdrLifecycle>>,
    /// Confirmation fence for this scene's pending Herdr lifecycle dialog.
    /// The runtime-wide in-flight registry (`Runtime::herdr_lifecycle`)
    /// identifies operations by a runtime-minted `operation_id`, never by
    /// this per-scene counter.
    pub(crate) herdr_lifecycle_generation: AtomicU64,
    pub(crate) pending_kwt_removal: Mutex<Option<PendingKwtRemoval>>,
    /// Target of this scene's in-flight asynchronous KWT removal identity
    /// capture; confirmed removals fence matching captures through it. Lock
    /// order: `pending_kwt_removal` first when both are held.
    pub(crate) kwt_removal_capture_intent: Mutex<Option<KwtRemovalCaptureIntent>>,
    /// Confirmation authority for this scene's pending KWT worktree
    /// removal. KWT mutation serialization stays runtime-wide
    /// (`kwt_mutation_in_flight`).
    pub(crate) kwt_removal_generation: AtomicU64,
    /// The scene's event inbox: FIFO of tagged entries. Lossless entries
    /// (the pump's terminal-originated events and KWT operation
    /// settlements) are never shed — see `push_lossless_event` for their
    /// growth bounds; operation and broadcast entries may be shed on
    /// overflow, with cancellation for addressed requests.
    pub(crate) operation_events: Mutex<std::collections::VecDeque<InboxEvent>>,
    /// Advances under the `operation_events` lock each time queued clipboard
    /// writes are purged; a pump pass captures it before extracting worker
    /// events and its clipboard pushes are dropped when it moved.
    pub(crate) clipboard_epoch: AtomicU64,
    pub(crate) terminal_geometry: Mutex<TerminalGeometry>,
    pub(crate) attachment: Mutex<AttachmentState<AttachRequest>>,
    pub(crate) terminal_notice: RwLock<Option<WorkspaceNotice>>,
}

/// Build a scene over the shared runtime and register it so runtime
/// broadcasts reach it. Every scene starts with empty per-scene
/// presentation, confirmation, and event state.
pub(crate) fn attach_scene(
    runtime: Arc<Runtime>,
    state: WorkspaceContent,
    selected_host: Option<String>,
    notice: Option<WorkspaceNotice>,
) -> Arc<Scene> {
    let id = next_scene_id(&runtime);
    let scene = Arc::new(Scene {
        id,
        closed: AtomicBool::new(false),
        revision: AtomicU64::new(0),
        runtime,
        state: RwLock::new(state),
        selected_host: RwLock::new(selected_host),
        navigation_generation: AtomicU64::new(0),
        inventory_polling_enabled: AtomicBool::new(false),
        navigation: Mutex::new(()),
        remote_active: Mutex::new(None),
        remote_retained: Mutex::new(RemoteRetainedPresentations::new()),
        worker: Mutex::new(WorkerState::new()),
        retained_presentations: Mutex::new(RetainedPresentations::new()),
        pending_paste: Mutex::new(None),
        pending_creation: Mutex::new(None),
        pending_kill: Mutex::new(None),
        kill_capture_intent: Mutex::new(None),
        kill_generation: AtomicU64::new(0),
        pending_herdr_lifecycle: Mutex::new(None),
        herdr_lifecycle_generation: AtomicU64::new(0),
        pending_kwt_removal: Mutex::new(None),
        kwt_removal_capture_intent: Mutex::new(None),
        kwt_removal_generation: AtomicU64::new(0),
        operation_events: Mutex::new(std::collections::VecDeque::new()),
        clipboard_epoch: AtomicU64::new(0),
        terminal_geometry: Mutex::new(default_terminal_geometry()),
        attachment: Mutex::new(AttachmentState::new()),
        terminal_notice: RwLock::new(notice),
    });
    register_scene(&scene.runtime, &scene);
    scene
}

/// Register a new scene on a live runtime and project the current shared
/// state into it without missing a concurrent publication.
///
/// Registration happens first, so every broadcast that collects recipients
/// after this point includes the scene. The initial projection then re-reads
/// shared state until the runtime revision is quiescent — the same protocol
/// snapshot reads use. A publication that lands between the read and the
/// projection holds the global snapshot-write guard across its store write
/// and revision bump, so the trailing check fails and the projection re-runs
/// against the newer state; the scene can therefore never finish joining
/// with content staler than the runtime's store.
pub(crate) fn join_runtime(runtime: Arc<Runtime>) -> Arc<Scene> {
    let scene = attach_scene(runtime, WorkspaceContent::Shell, None, None);
    loop {
        let revision = scene.runtime.revision.load(Ordering::Acquire);
        let state = if scene.runtime.host_scoped_inventory {
            WorkspaceContent::Shell
        } else {
            scene
                .runtime
                .inventory_state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone()
        };
        let selected_host = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .first()
            .map(|host| host.id.clone());
        *scene
            .state
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = state;
        *scene
            .selected_host
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = selected_host;
        // The projection is final only when no publication was in flight
        // around it: the snapshot-write gate quiescent and the revision
        // unmoved. Projecting before waiting keeps the wait boundary
        // observable — a join blocked behind a publication has already
        // projected the pre-publication store into its scene.
        if scene.runtime.snapshot_writers.load(Ordering::Acquire) == 0
            && scene.runtime.revision.load(Ordering::Acquire) == revision
        {
            return scene;
        }
        while scene.runtime.snapshot_writers.load(Ordering::Acquire) != 0 {
            std::thread::yield_now();
        }
    }
}

/// Begin a navigation intent for this scene: drop its pending kill and
/// Herdr lifecycle confirmations, cancel its in-flight remote attach
/// attempts, advance its navigation generation to a fresh runtime-minted
/// operation id, and cancel its superseded un-launched constructive
/// operations. Other scenes' confirmations and attempts are untouched.
pub(crate) fn begin_scene_navigation(scene: &Scene) -> u64 {
    invalidate_pending_kill(scene);
    invalidate_pending_herdr_lifecycle(scene);
    cancel_scene_remote_attachments(&scene.runtime, scene.id);
    let generation = next_operation_id(&scene.runtime);
    scene
        .navigation_generation
        .fetch_max(generation, Ordering::AcqRel);
    cancel_superseded_remote_constructive_navigation(&scene.runtime, scene.id, generation);
    generation
}

/// Detach this scene's active presentation under its held navigation lock:
/// cancel and settle its pending creation, invalidate the attachment slot,
/// release the remote presentation and its SSH lease, clear the withheld
/// paste and notice, stop the active worker, and restore published
/// inventory content.
pub(crate) fn detach_scene_locked(scene: &Scene) {
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    begin_scene_navigation(scene);
    if let Some(pending) = scene
        .pending_creation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        pending.cancellation.cancel();
        finish_pending_creation(&scene.runtime, &pending);
    }
    scene
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .invalidate();
    scene
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
    // Deny the withheld paste AT THE WORKER while it is still live — a
    // fresh confirmation may have been registered by the pump at any point
    // before this lock was taken, and clearing the slot alone would leave
    // the deny unsent. The worker dies just below either way, but every
    // path that swallows a paste confirmation goes through the worker deny.
    cancel_pending_paste(scene);
    clear_terminal_notice(scene);
    // The hidden presentation's clipboard authority dies with it: queued
    // and in-flight writes are purged unconditionally — an earlier
    // transition may have cleared the worker slot while writes lingered —
    // and a still-live worker additionally has its writes disabled before
    // it is dropped.
    if let Some(worker) = scene
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .invalidate()
    {
        retire_clipboard_writes(scene, &worker);
    } else {
        purge_queued_clipboard_writes(scene);
    }
    restore_scene_inventory_state(scene);
}

/// Project the runtime's stored inventory content back into this scene.
pub(crate) fn restore_scene_inventory_state(scene: &Scene) {
    let state = scene
        .runtime
        .inventory_state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    set_scene_state(scene, state);
}

/// Close one scene, fail-closed. Runs exactly once; `Drop` re-invokes it
/// for scenes never explicitly closed.
///
/// The scene is unregistered first, so no later broadcast, fan-out, or
/// pump pass collects it; the closed flag makes every straggling push —
/// from a task that captured the scene before the close — cancel instead
/// of enqueue. Presentations tear down through the ordinary detach path
/// (active worker stopped, remote lease released so lease-liveness
/// monitoring is not pinned by a dead scene), retained presentations and
/// their workers are dropped, confirmations are fenced, and every
/// addressed request still in the inbox is cancelled through its
/// capability — the initiating operation fails with its established
/// cancellation error and is never re-queued to another scene. Lossless
/// settlements drain with the inbox: the dialog they would settle died
/// with the scene.
pub(crate) fn release_scene(scene: &Scene) {
    if scene.closed.swap(true, Ordering::AcqRel) {
        return;
    }
    unregister_scene(&scene.runtime, scene.id);
    {
        // The detach denies the withheld paste at the worker before killing
        // it. Constructive entry points parked on this mutex observe the
        // closed flag on wake (`lock_live_navigation`) and fail instead of
        // re-arming a presentation in the dead scene.
        let _navigation = scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        detach_scene_locked(scene);
    }
    invalidate_pending_kwt_removal(scene);
    // A listing owned by this scene's dialog dies with the dialog: cancel
    // it and free the shared KWT lane instead of leaving the lane occupied
    // until the orphaned task settles.
    let owned_listing = {
        let mut active = scene
            .runtime
            .kwt_worktree_listing
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if active
            .as_ref()
            .is_some_and(|listing| listing.scene_id == scene.id)
        {
            active.take()
        } else {
            None
        }
    };
    if let Some(listing) = owned_listing {
        cancel_owned_kwt_listing(scene, &listing);
    }
    let retained = std::mem::replace(
        &mut *scene
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner),
        RetainedPresentations::new(),
    );
    let remote_retained = std::mem::replace(
        &mut *scene
            .remote_retained
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner),
        RemoteRetainedPresentations::new(),
    );
    let outstanding: Vec<InboxEvent> = scene
        .operation_events
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .drain(..)
        .collect();
    for entry in outstanding {
        cancel_closed_event(scene, entry.event);
    }
    // Retained workers and remote lease clones drop outside every lock.
    drop(retained);
    drop(remote_retained);
}

impl Drop for Scene {
    fn drop(&mut self) {
        release_scene(self);
    }
}

/// Proof that the holder took one specific scene's live-navigation fence.
/// Only `lock_live_navigation` mints it, so an API requiring this type
/// cannot be satisfied by some other same-typed mutex guard — and
/// `fences` lets the callee assert it was handed the right scene's.
pub(crate) struct NavigationFence<'scene> {
    scene: &'scene Scene,
    _guard: std::sync::MutexGuard<'scene, ()>,
}

impl NavigationFence<'_> {
    /// Whether this fence belongs to exactly `scene`.
    pub(crate) fn fences(&self, scene: &Scene) -> bool {
        std::ptr::eq(self.scene, scene)
    }
}

/// Acquire this scene's navigation lock for a constructive operation,
/// failing closed when the scene is closed. The check happens under the
/// lock — the same lock `release_scene` holds for its detach — so an entry
/// point that parked on the mutex while the scene closed observes the
/// closed flag on wake and cannot mint a fresh navigation generation,
/// publish a worker, or re-arm a remote lease in a dead scene.
///
/// # Errors
///
/// Returns the scene-closed cancellation error; the caller's operation
/// never starts.
pub(crate) fn lock_live_navigation(scene: &Scene) -> Result<NavigationFence<'_>, WorkspaceError> {
    let guard = scene
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.closed.load(Ordering::Acquire) {
        return Err(WorkspaceError::new(
            "the scene closed before this operation could start",
        ));
    }
    Ok(NavigationFence {
        scene,
        _guard: guard,
    })
}

/// Route one SSH prompt to the initiating scene's inbox and block the
/// calling connect task until the prompt's one-shot capability is answered,
/// the prompt expires, or the operation is cancelled.
///
/// The prompt is addressed to exactly the scene that initiated the connect
/// — never broadcast, never reassigned. When that scene closes the request
/// fails closed with `prompt_cancelled`, whether the scene closed before
/// the request was minted, while it sat undelivered in the inbox, or after
/// a client drained it: the loop below observes `Scene::closed` alongside
/// the operation's cancellation token, and a response that raced the close
/// is refused. Another scene may explicitly retry the connect from the
/// beginning, minting a fresh request addressed to itself.
pub(crate) fn request_ssh_prompt(
    scene: &Scene,
    host_id: &str,
    generation: u64,
    prompt: &SshLeasePrompt,
    cancellation: &CancellationToken,
) -> Result<String, host::SshError> {
    if scene.closed.load(Ordering::Acquire) {
        return Err(host::SshError::prompt_cancelled());
    }
    let wait = prompt.remaining()?.min(SSH_PROMPT_TIMEOUT);
    if wait.is_zero() {
        return Err(host::SshError::prompt_cancelled());
    }
    let deadline = Instant::now() + wait;
    let (sender, receiver) = sync_channel(1);
    let request = SshPromptRequest {
        host_id: host_id.to_owned(),
        generation,
        prompt: prompt.clone(),
        response: Arc::new(Mutex::new(Some(sender))),
    };
    push_operation_event(scene, WorkspaceEvent::SshPrompt(request));
    let result = loop {
        if cancellation.is_cancelled() || scene.closed.load(Ordering::Acquire) {
            break Err(host::SshError::prompt_cancelled());
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break Err(host::SshError::prompt_cancelled());
        }
        match receiver.recv_timeout(remaining.min(Duration::from_millis(100))) {
            Ok(Some(value)) => {
                // A value that raced the scene's close is refused: scene
                // disappearance fails the operation, never the reverse.
                if scene.closed.load(Ordering::Acquire) {
                    break Err(host::SshError::prompt_cancelled());
                }
                break Ok(value);
            }
            Ok(None) | Err(RecvTimeoutError::Disconnected) => {
                break Err(host::SshError::prompt_cancelled());
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
    };
    push_operation_event(
        scene,
        WorkspaceEvent::SshPromptDismissed {
            host_id: host_id.to_owned(),
            generation,
        },
    );
    result
}

pub(crate) fn publish_remote_connection(
    scene: &Scene,
    host_id: &str,
    generation: u64,
    result: Result<(RuntimeRemoteHost, RemoteTmuxSnapshot), host::RemoteTmuxError>,
) {
    let publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let snapshot_write = begin_snapshot_write(&scene.runtime);
    let mut stale_presentations = Vec::new();
    let pending_reconciliation;
    let mut entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get_mut(host_id) else {
        return;
    };
    if entry.generation != generation {
        return;
    }
    entry.cancellation = None;
    match result {
        Ok((host, snapshot)) => {
            let endpoint = snapshot.endpoint().to_owned();
            let route_identity = snapshot.route_identity().to_owned();
            let lease_generation = snapshot.lease_generation();
            pending_reconciliation =
                entry
                    .constructive_cancellation
                    .as_ref()
                    .and_then(|operation| match operation {
                        RemoteConstructiveState::PendingReconciliation(target) => {
                            Some((host.clone(), snapshot.clone(), target.clone()))
                        }
                        RemoteConstructiveState::Active { .. } => None,
                    });
            entry.context = Some(RemoteHostContext {
                generation,
                host,
                snapshot: snapshot.clone(),
            });
            drop(entries);
            stale_presentations = reconcile_remote_presentations(
                &scene.runtime,
                host_id,
                &endpoint,
                &route_identity,
                lease_generation,
                Some(RemoteInventory::from(&snapshot)),
            );
            set_remote_host_snapshot(&scene.runtime, host_id, &snapshot);
        }
        Err(error) => {
            let diagnostic = HostDiagnostic::new(error.kind(), error.to_string());
            cancel_remote_constructive(entry);
            cancel_remote_attachment(entry);
            let stale_context = entry.context.take();
            drop(entries);
            set_remote_host_state(
                &scene.runtime,
                host_id,
                HostConnectionState::Unavailable,
                None,
                Some(diagnostic),
            );
            drop(snapshot_write);
            drop(stale_context);
            drop(stale_presentations);
            drop(publication);
            return;
        }
    }
    drop(snapshot_write);
    drop(stale_presentations);
    drop(publication);
    if let Some((host, snapshot, target)) = pending_reconciliation {
        reconcile_remote_constructive_after_connection(
            scene, host_id, generation, &host, snapshot, &target,
        );
    }
}

pub(crate) fn reconcile_remote_constructive_after_connection(
    scene: &Scene,
    host_id: &str,
    generation: u64,
    host: &RuntimeRemoteHost,
    snapshot: RemoteTmuxSnapshot,
    target: &RemoteConstructiveTarget,
) {
    reconcile_remote_constructive_with_backoff(
        scene,
        host_id,
        generation,
        snapshot,
        target,
        &HERDR_STARTUP_BACKOFF,
        |snapshot, cancellation| host.refresh(snapshot.lease(), cancellation),
    );
}

pub(crate) fn reconcile_remote_constructive_with_backoff<E>(
    scene: &Scene,
    host_id: &str,
    generation: u64,
    mut snapshot: RemoteTmuxSnapshot,
    target: &RemoteConstructiveTarget,
    backoff: &[Duration],
    mut refresh: impl FnMut(
        &RemoteTmuxSnapshot,
        &CancellationToken,
    ) -> Result<RemoteSessionInventory, E>,
) {
    if remote_constructive_target_is_present(&snapshot, target) {
        clear_pending_remote_constructive(&scene.runtime, host_id, generation, target);
        return;
    }
    let cancellation = CancellationToken::new();
    for delay in backoff {
        thread::sleep(*delay);
        let Some(current) =
            pending_remote_constructive_snapshot(&scene.runtime, host_id, generation, target)
        else {
            return;
        };
        snapshot = current;
        if remote_constructive_target_is_present(&snapshot, target) {
            clear_pending_remote_constructive(&scene.runtime, host_id, generation, target);
            return;
        }
        let Ok(inventory) = refresh(&snapshot, &cancellation) else {
            continue;
        };
        let Ok(refreshed) = publish_remote_inventory(
            scene,
            host_id,
            generation,
            &snapshot,
            &cancellation,
            inventory,
        ) else {
            // Another same-connection probe may have published first. The
            // next attempt must reconcile against that authoritative snapshot
            // rather than leaving the constructive operation permanently
            // reserved by stale publication authority.
            continue;
        };
        snapshot = refreshed;
        if remote_constructive_target_is_present(&snapshot, target) {
            clear_pending_remote_constructive(&scene.runtime, host_id, generation, target);
            return;
        }
    }
    clear_pending_remote_constructive(&scene.runtime, host_id, generation, target);
}

/// Reconcile the remote presentations of every registered scene against one
/// host's current inventory, returning all stale retained presentations.
pub(crate) fn reconcile_remote_presentations(
    runtime: &Runtime,
    host_id: &str,
    endpoint: &str,
    route_identity: &str,
    lease_generation: u64,
    inventory: Option<RemoteInventory<'_>>,
) -> Vec<RemoteRetainedPresentation> {
    let mut stale = Vec::new();
    for_each_scene(runtime, |scene| {
        stale.extend(reconcile_scene_remote_presentations(
            scene,
            host_id,
            endpoint,
            route_identity,
            lease_generation,
            inventory,
        ));
    });
    stale
}

fn reconcile_scene_remote_presentations(
    scene: &Scene,
    host_id: &str,
    endpoint: &str,
    route_identity: &str,
    lease_generation: u64,
    inventory: Option<RemoteInventory<'_>>,
) -> Vec<RemoteRetainedPresentation> {
    let _navigation = scene
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let terminal_update = {
        let mut remote_active = scene
            .remote_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(active) = remote_active
            .as_mut()
            .filter(|active| active.key.host_id == host_id)
        else {
            return scene
                .remote_retained
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .reconcile(
                    host_id,
                    endpoint,
                    route_identity,
                    lease_generation,
                    inventory,
                );
        };
        match active
            .key
            .reconcile(endpoint, route_identity, lease_generation, inventory)
        {
            RemoteReconcile::Found(kind, name) => {
                active.retainable = retain_remote_session(kind);
                let selection = SessionSelection::for_kind(host_id, endpoint, name, kind);
                if active.selection == selection {
                    None
                } else {
                    active.selection = selection;
                    let worker = scene
                        .worker
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if worker.generation() == active.worker_generation {
                        worker.active().map(|worker| {
                            (
                                active.selection.clone(),
                                active.presentation_id,
                                worker.surface_handle(),
                            )
                        })
                    } else {
                        None
                    }
                }
            }
            RemoteReconcile::Unknown => None,
            RemoteReconcile::Stale => {
                active.retainable = false;
                None
            }
        }
    };
    let stale = scene
        .remote_retained
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .reconcile(
            host_id,
            endpoint,
            route_identity,
            lease_generation,
            inventory,
        );
    if let Some((selection, presentation_id, surface)) = terminal_update {
        set_scene_state(
            scene,
            WorkspaceContent::Terminal {
                host_id: selection.host_id().to_owned(),
                endpoint: selection.endpoint().to_owned(),
                session: selection.session().to_owned(),
                kind: selection.kind(),
                presentation_id,
                surface,
            },
        );
    }
    stale
}

pub(crate) fn publish_pending_kill(scene: &Scene, pending: PendingKill) -> bool {
    let mut pending_kill = scene
        .pending_kill
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.kill_generation.load(Ordering::Acquire) != pending.generation {
        return false;
    }
    *pending_kill = Some(pending);
    // The capture this intent tracked has published; nothing is in flight.
    *scene
        .kill_capture_intent
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    drop(pending_kill);
    bump_scene_revision(scene);
    true
}

/// Advance the kill fence and register the new capture's intent in the
/// same critical section, so a same-session kill completing between the
/// mint and the registration cannot slip past the fence and let the
/// in-flight capture resurrect a confirmation for a dead session.
pub(crate) fn invalidate_pending_kill_with_intent(
    scene: &Scene,
    selection: &SessionSelection,
) -> u64 {
    let mut pending_kill = scene
        .pending_kill
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = scene.kill_generation.fetch_add(1, Ordering::AcqRel) + 1;
    *scene
        .kill_capture_intent
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(KillCaptureIntent {
        generation,
        selection: selection.clone(),
    });
    let removed = pending_kill.take().is_some();
    drop(pending_kill);
    if removed {
        bump_scene_revision(scene);
    }
    generation
}

/// Advance this scene's kill confirmation fence and drop any pending kill
/// dialog it fenced. Only the invalidating scene re-renders; other scenes'
/// confirmations are untouched.
pub(crate) fn invalidate_pending_kill(scene: &Scene) -> u64 {
    let mut pending_kill = scene
        .pending_kill
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = scene.kill_generation.fetch_add(1, Ordering::AcqRel) + 1;
    *scene
        .kill_capture_intent
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    let removed = pending_kill.take().is_some();
    drop(pending_kill);
    if removed {
        bump_scene_revision(scene);
    }
    generation
}

/// Advance this scene's Herdr lifecycle confirmation fence and drop any
/// pending confirmation it fenced, exactly as `invalidate_pending_kill`.
pub(crate) fn invalidate_pending_herdr_lifecycle(scene: &Scene) -> u64 {
    let mut pending = scene
        .pending_herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = scene
        .herdr_lifecycle_generation
        .fetch_add(1, Ordering::AcqRel)
        + 1;
    let removed = pending.take().is_some();
    drop(pending);
    if removed {
        bump_scene_revision(scene);
    }
    generation
}

/// Advance this scene's KWT removal confirmation fence and drop any
/// pending removal dialog and in-flight capture intent it fenced, exactly
/// as `invalidate_pending_kill` does for kills.
pub(crate) fn invalidate_pending_kwt_removal(scene: &Scene) -> u64 {
    let mut pending = scene
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = scene.kwt_removal_generation.fetch_add(1, Ordering::AcqRel) + 1;
    *scene
        .kwt_removal_capture_intent
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    let removed = pending.take().is_some();
    drop(pending);
    if removed {
        bump_scene_revision(scene);
    }
    generation
}

/// Drop every scene's pending confirmation whose target matches a completed
/// host-wide destructive mutation and re-render those scenes. The target is
/// gone or changed, so a still-pending dialog for it anywhere is stale;
/// confirmations for unrelated targets stay valid. This target-based
/// invalidation complements the per-scene confirmation fences: one scene's
/// request or cancel never touches another scene, but a mutation that
/// actually completed invalidates every matching dialog.
pub(crate) fn drop_matching_confirmations<T>(
    runtime: &Runtime,
    slot: impl Fn(&Scene) -> &Mutex<Option<T>>,
    matches: impl Fn(&T) -> bool,
) {
    for_each_scene(runtime, |scene| {
        let mut pending = slot(scene)
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if pending.as_ref().is_some_and(&matches) {
            pending.take();
            drop(pending);
            bump_scene_revision(scene);
        }
    });
}

/// Drop every scene's pending kill confirmation for one killed session and
/// fence in-flight kill identity captures for the same target. The fence
/// advance happens under the slot lock, so a capture that straddled the
/// kill fails its generation check at publication instead of resurrecting
/// a dialog for a dead target; unrelated captures and dialogs stay valid.
pub(crate) fn drop_matching_kill_confirmations(
    runtime: &Runtime,
    matches_pending: impl Fn(&PendingKill) -> bool,
    matches_capture: impl Fn(&SessionSelection) -> bool,
) {
    for_each_scene(runtime, |scene| {
        let mut pending = scene
            .pending_kill
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut intent = scene
            .kill_capture_intent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if intent.as_ref().is_some_and(|intent| {
            intent.generation == scene.kill_generation.load(Ordering::Acquire)
                && matches_capture(&intent.selection)
        }) {
            intent.take();
            scene.kill_generation.fetch_add(1, Ordering::AcqRel);
        }
        drop(intent);
        let removed = pending.as_ref().is_some_and(&matches_pending);
        if removed {
            pending.take();
        }
        drop(pending);
        if removed {
            bump_scene_revision(scene);
        }
    });
}

/// Drop every scene's pending removal confirmation for one removed KWT
/// worktree and fence in-flight removal identity captures for it, exactly
/// as `drop_matching_kill_confirmations` does for kills.
pub(crate) fn drop_matching_kwt_removal_confirmations(
    runtime: &Runtime,
    endpoint: &host::WslEndpoint,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: &str,
) {
    let matches_intent = |intent: &KwtRemovalCaptureIntent| {
        intent.endpoint == *endpoint
            && intent.repository == repository
            && intent.project_path == project_path
            && intent.registration_fingerprint == registration_fingerprint
            && intent.worktree_path == worktree_path
            && intent.generation == generation
    };
    for_each_scene(runtime, |scene| {
        let mut pending = scene
            .pending_kwt_removal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut intent = scene
            .kwt_removal_capture_intent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if intent.as_ref().is_some_and(|intent| {
            intent.authority == scene.kwt_removal_generation.load(Ordering::Acquire)
                && matches_intent(intent)
        }) {
            intent.take();
            scene.kwt_removal_generation.fetch_add(1, Ordering::AcqRel);
        }
        drop(intent);
        let removed = pending.as_ref().is_some_and(|pending| {
            pending.endpoint == *endpoint
                && pending.repository == repository
                && pending.project_path == project_path
                && pending.registration_fingerprint == registration_fingerprint
                && pending.worktree_path == worktree_path
                && pending.generation == generation
        });
        if removed {
            pending.take();
        }
        drop(pending);
        if removed {
            bump_scene_revision(scene);
        }
    });
}

pub(crate) fn activate_retained_presentation(
    scene: &Scene,
    key: &PresentationKey,
    fallback: Option<FallbackAuthority>,
) -> Result<bool, WorkspaceError> {
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    let mut attachment = scene
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(presentation) = scene
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take(key)
    else {
        return Ok(false);
    };
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let term = presentation.attachment.term;
    let Some(generation) =
        reserve_retained_attachment(&mut attachment, &presentation.attachment, fallback)
    else {
        drop(attachment);
        reinsert_retained_presentation(scene, presentation);
        return Err(WorkspaceError::new(
            "a terminal presentation is already opening",
        ));
    };
    if let Err(error) =
        presentation
            .worker
            .resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
    {
        attachment.clear_if_current(generation);
        drop(attachment);
        reinsert_retained_presentation(scene, presentation);
        return Err(WorkspaceError::from_worker(&error));
    }
    let mut workers = scene
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if workers.active().is_some() {
        attachment.clear_if_current(generation);
        drop(workers);
        drop(attachment);
        reinsert_retained_presentation(scene, presentation);
        return Err(WorkspaceError::new(
            "a terminal presentation is already open",
        ));
    }
    let selection = attachment
        .active()
        .map(|active| active.request.selection())
        .expect("retained attachment was just reserved");
    let RetainedPresentation {
        key: _,
        selection: _,
        attachment: _,
        worker,
        presentation_id,
    } = presentation;
    worker.set_clipboard_writes_enabled(false);
    let surface = worker.surface_handle();
    let worker_generation = workers.publish(worker);
    reconcile_active_worker_cursor(&scene.runtime, &workers);
    drop(workers);

    clear_pending_paste(scene);
    set_terminal_notice(scene, term);
    set_scene_state(
        scene,
        WorkspaceContent::Terminal {
            host_id: selection.host_id().to_owned(),
            endpoint: selection.endpoint().to_owned(),
            session: selection.session().to_owned(),
            kind: selection.kind(),
            presentation_id,
            surface,
        },
    );
    drop(attachment);
    let workers = scene
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if workers.generation() == worker_generation
        && let Some(worker) = workers.active()
    {
        worker.set_clipboard_writes_enabled(true);
    }
    Ok(true)
}

pub(crate) fn reinsert_retained_presentation(
    scene: &Scene,
    presentation: RetainedPresentation<TerminalWorker>,
) {
    insert_retained_presentation(&scene.runtime, &scene.retained_presentations, presentation);
}

#[allow(
    clippy::too_many_lines,
    reason = "the runtime/scene split lengthens shared-state paths without adding logic"
)]
pub(crate) fn capture_attach_request(
    scene: &Scene,
    selection: &SessionSelection,
) -> Result<AttachRequest, WorkspaceError> {
    if matches!(selection.kind(), SessionKind::Herdr | SessionKind::Zellij) {
        require_host_session_actions(&scene.runtime, selection)?;
    }
    let selected_host = scene
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if selected_host.as_deref() != Some(selection.host_id()) {
        return Err(WorkspaceError::new("host is not selected"));
    }
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, inventory_generation| {
        if context.snapshot.endpoint().distro() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the session selection",
            ));
        }
        let (target, name) = match selection.kind() {
            SessionKind::Tmux => {
                let session = context
                    .snapshot
                    .sessions()
                    .iter()
                    .find(|session| session.name() == selection.session())
                    .ok_or_else(|| {
                        WorkspaceError::new("session is not in the current inventory")
                    })?;
                (
                    AttachTarget::Tmux(session.identity().clone()),
                    session.name().to_owned(),
                )
            }
            SessionKind::Herdr => {
                let HerdrInventory::Available {
                    executable,
                    sessions,
                } = context.snapshot.herdr()
                else {
                    return Err(WorkspaceError::new("Herdr is not available on this host"));
                };
                let session = sessions
                    .iter()
                    .find(|session| session.name() == selection.session())
                    .ok_or_else(|| {
                        WorkspaceError::new("Herdr session is not in the current inventory")
                    })?;
                if session.state() != HerdrSessionState::Running {
                    return Err(WorkspaceError::new(
                        "Herdr session is stopped; restart it before opening",
                    ));
                }
                (
                    AttachTarget::Herdr {
                        executable: executable.clone(),
                        is_default: session.is_default(),
                        session_directory: session.session_directory().to_owned(),
                        socket_path: session.socket_path().to_owned(),
                    },
                    session.name().to_owned(),
                )
            }
            SessionKind::Zellij => {
                let ZellijInventory::Available {
                    executable,
                    sessions,
                } = context.snapshot.zellij()
                else {
                    return Err(WorkspaceError::new("Zellij is not available on this host"));
                };
                let session = sessions
                    .iter()
                    .find(|session| session.name() == selection.session())
                    .ok_or_else(|| {
                        WorkspaceError::new("Zellij session is not in the current inventory")
                    })?;
                (
                    AttachTarget::Zellij {
                        executable: executable.clone(),
                        name: session.name().to_owned(),
                    },
                    session.name().to_owned(),
                )
            }
        };
        Ok(AttachRequest {
            host_id: selection.host_id().to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            target,
            name,
            inventory_generation,
        })
    })
}

#[allow(
    clippy::too_many_lines,
    reason = "one request's inventory validation and target capture read as a single flow"
)]
pub(crate) fn capture_kill_request(
    scene: &Scene,
    selection: &SessionSelection,
    generation: u64,
) -> Result<KillCaptureRequest, WorkspaceError> {
    require_wsl_host_id(selection.host_id())?;
    if !matches!(selection.kind(), SessionKind::Tmux | SessionKind::Zellij) {
        return Err(WorkspaceError::new(
            "Kill Session is available only for tmux and Zellij sessions",
        ));
    }
    if scene
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_deref()
        != Some(selection.host_id())
    {
        return Err(WorkspaceError::new("host is not selected"));
    }
    if let Some(request) = scene
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .active()
        .map(|active| active.request.clone())
        .filter(|request| request.selection() == *selection)
    {
        return Ok(KillCaptureRequest::Tmux {
            selection: selection.clone(),
            host: request.host,
            endpoint: request.endpoint,
            runtime: request.runtime,
        });
    }
    require_current_protected_selection(&scene.runtime, selection)?;
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the session selection",
            ));
        }
        match selection.kind() {
            SessionKind::Tmux => {
                if selection.tmux_socket_name().is_none()
                    && !context
                        .snapshot
                        .sessions()
                        .iter()
                        .any(|session| session.name() == selection.session())
                {
                    return Err(WorkspaceError::new(
                        "session is not in the current inventory",
                    ));
                }
                Ok(KillCaptureRequest::Tmux {
                    selection: selection.clone(),
                    host: context.host.clone(),
                    endpoint: context.snapshot.endpoint().clone(),
                    runtime: context.snapshot.runtime().clone(),
                })
            }
            SessionKind::Zellij => {
                let ZellijInventory::Available {
                    executable,
                    sessions,
                } = context.snapshot.zellij()
                else {
                    return Err(WorkspaceError::new("Zellij is not available on this host"));
                };
                if !sessions
                    .iter()
                    .any(|session| session.name() == selection.session())
                {
                    return Err(WorkspaceError::new(
                        "Zellij session is not in the current inventory",
                    ));
                }
                Ok(KillCaptureRequest::Zellij(PendingKill {
                    generation,
                    selection: selection.clone(),
                    host: context.host.clone(),
                    target: KillTarget::Zellij {
                        endpoint: context.snapshot.endpoint().clone(),
                        runtime: context.snapshot.runtime().clone(),
                        executable: executable.clone(),
                        name: selection.session().to_owned(),
                        revision: crate::runtime::zellij_kill_revision(
                            &scene.runtime,
                            &crate::zellij_kill_key(
                                context.snapshot.endpoint(),
                                context.snapshot.runtime(),
                                selection.session(),
                            ),
                        ),
                    },
                }))
            }
            SessionKind::Herdr => unreachable!("Herdr was rejected above"),
        }
    })
}

pub(crate) fn capture_herdr_lifecycle(
    scene: &Scene,
    selection: &SessionSelection,
    action: HerdrLifecycleAction,
    generation: u64,
) -> Result<PendingHerdrLifecycle, WorkspaceError> {
    require_wsl_host_id(selection.host_id())?;
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "Herdr lifecycle actions require a Herdr session",
        ));
    }
    require_host_session_actions(&scene.runtime, selection)?;
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the Herdr session selection",
            ));
        }
        let HerdrInventory::Available {
            executable,
            sessions,
        } = context.snapshot.herdr()
        else {
            return Err(WorkspaceError::new("Herdr is not available on this host"));
        };
        let record = sessions
            .iter()
            .find(|session| session.name() == selection.session())
            .cloned()
            .ok_or_else(|| WorkspaceError::new("Herdr session is not in current inventory"))?;
        if record.state() != action.expected_state() {
            let expected = match action.expected_state() {
                HerdrSessionState::Running => "running",
                HerdrSessionState::Stopped => "stopped",
            };
            return Err(WorkspaceError::new(format!(
                "Herdr session is no longer {expected}"
            )));
        }
        if action == HerdrLifecycleAction::Delete && record.is_default() {
            return Err(WorkspaceError::new(
                "Herdr's default session cannot be deleted",
            ));
        }
        Ok(PendingHerdrLifecycle {
            generation,
            operation_id: next_operation_id(&scene.runtime),
            selection: selection.clone(),
            action,
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            executable: executable.clone(),
            record,
        })
    })
}

pub(crate) fn capture_create_request(
    scene: &Scene,
    host_id: &str,
    endpoint: &str,
    name: SessionName,
) -> Result<CreateRequest, WorkspaceError> {
    require_wsl_host_id(host_id)?;
    // The selection guard drops before the host-list read: the global
    // order is hosts before selected_host (select_host holds the list
    // guard through its selection write), and holding both here in the
    // other order can wedge three threads through the writer-preferring
    // host-list lock.
    {
        let selected_host = scene
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if selected_host.as_deref() != Some(host_id) {
            return Err(WorkspaceError::new("host is not selected"));
        }
    }
    let hosts = scene
        .runtime
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let selected = hosts
        .iter()
        .find(|host| host.id == host_id)
        .ok_or_else(|| WorkspaceError::new("host is not available"))?;
    if selected.endpoint != endpoint {
        return Err(WorkspaceError::new(
            "the WSL endpoint changed; choose the host again before creating a session",
        ));
    }
    if matches!(
        selected.connection,
        HostConnectionState::Disconnected | HostConnectionState::Unavailable
    ) {
        return Err(WorkspaceError::new(
            "connect the WSL host before creating a tmux session",
        ));
    }
    if selected
        .sessions
        .iter()
        .any(|session| session.name == name.as_str())
    {
        return Err(WorkspaceError::new(
            "a tmux session with this name already exists",
        ));
    }
    drop(hosts);
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "the WSL endpoint changed; choose the host again before creating a session",
            ));
        }
        Ok(CreateRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            name,
        })
    })
}

pub(crate) fn capture_herdr_create_request(
    scene: &Scene,
    host_id: &str,
    endpoint: &str,
    name: HerdrSessionName,
) -> Result<HerdrCreateRequest, WorkspaceError> {
    require_wsl_host_id(host_id)?;
    if scene
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_deref()
        != Some(host_id)
    {
        return Err(WorkspaceError::new("host is not selected"));
    }
    require_host_session_actions(
        &scene.runtime,
        &SessionSelection::herdr(host_id, endpoint, name.as_str()),
    )?;
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "the WSL endpoint changed; choose the host again before creating a session",
            ));
        }
        let HerdrInventory::Available {
            executable,
            sessions,
        } = context.snapshot.herdr()
        else {
            return Err(WorkspaceError::new("Herdr is not available on this host"));
        };
        if sessions
            .iter()
            .any(|session| session.name() == name.as_str())
        {
            return Err(WorkspaceError::new(
                "a Herdr session with this name already exists; restart it instead",
            ));
        }
        Ok(HerdrCreateRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            executable: executable.clone(),
            term: context.snapshot.creation_term(),
            name: HerdrLaunchTarget::created(name),
            precondition: HerdrLaunchPrecondition::Absent,
        })
    })
}

pub(crate) fn capture_zellij_create_request(
    scene: &Scene,
    host_id: &str,
    endpoint: &str,
    name: ZellijSessionName,
) -> Result<ZellijCreateRequest, WorkspaceError> {
    require_wsl_host_id(host_id)?;
    if scene
        .selected_host
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_deref()
        != Some(host_id)
    {
        return Err(WorkspaceError::new("host is not selected"));
    }

    require_host_session_actions(
        &scene.runtime,
        &SessionSelection::zellij(host_id, endpoint, name.as_str()),
    )?;
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "the WSL endpoint changed; choose the host again before creating a session",
            ));
        }
        let ZellijInventory::Available {
            executable,
            sessions,
        } = context.snapshot.zellij()
        else {
            return Err(WorkspaceError::new("Zellij is not available on this host"));
        };
        if sessions
            .iter()
            .any(|session| session.name() == name.as_str())
        {
            return Err(WorkspaceError::new(
                "a Zellij session with this name already exists",
            ));
        }
        Ok(ZellijCreateRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            executable: executable.clone(),
            term: context.snapshot.creation_term(),
            name,
        })
    })
}

pub(crate) fn capture_herdr_restart_request(
    scene: &Scene,
    selection: &SessionSelection,
) -> Result<HerdrCreateRequest, WorkspaceError> {
    require_wsl_host_id(selection.host_id())?;
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "the selected session is not a Herdr session",
        ));
    }
    require_host_session_actions(&scene.runtime, selection)?;
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, _inventory_generation| {
        if context.snapshot.endpoint().distro() != selection.endpoint() {
            return Err(WorkspaceError::new(
                "the WSL endpoint changed; refresh before restarting the session",
            ));
        }
        let HerdrInventory::Available {
            executable,
            sessions,
        } = context.snapshot.herdr()
        else {
            return Err(WorkspaceError::new("Herdr is not available on this host"));
        };
        let record = sessions
            .iter()
            .find(|session| session.name() == selection.session())
            .cloned()
            .ok_or_else(|| WorkspaceError::new("Herdr session is no longer in inventory"))?;
        if record.state() != HerdrSessionState::Stopped {
            return Err(WorkspaceError::new("Herdr session is already running"));
        }
        let name = HerdrLaunchTarget::discovered(&record);
        Ok(HerdrCreateRequest {
            host_id: selection.host_id().to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            executable: executable.clone(),
            term: context.snapshot.creation_term(),
            name,
            precondition: HerdrLaunchPrecondition::Stopped(record),
        })
    })
}

pub(crate) fn begin_refresh(
    scene: &Scene,
    cancellation: &CancellationToken,
    presentation: RefreshPresentation,
) -> u64 {
    let generation = reserve_refresh(&scene.runtime, cancellation);
    if presentation == RefreshPresentation::Connecting {
        publish_refresh(&scene.runtime, generation, || {
            if scene.runtime.host_scoped_inventory {
                let mut hosts = scene
                    .runtime
                    .hosts
                    .write()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") {
                    host.connection = HostConnectionState::Connecting;
                    host.diagnostic = None;
                }
                scene.runtime.revision.fetch_add(1, Ordering::Release);
            } else {
                set_inventory_state(&scene.runtime, &WorkspaceContent::Loading);
            }
        });
    }
    generation
}

pub(crate) fn reserve_current_constructive_inventory(
    scene: &Scene,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Option<u64> {
    // The live fence, as at the remote launch boundaries: a create task
    // that wins the mutex inside the closed-but-not-yet-detached window
    // must not consume creation authority for a dead scene.
    let _navigation = lock_live_navigation(scene).ok()?;
    if cancellation.is_cancelled()
        || scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
    {
        return None;
    }
    Some(reserve_constructive_inventory(&scene.runtime))
}

pub(crate) fn settle_constructive_inventory(scene: &Scene, generation: u64) {
    let _publication = scene
        .runtime
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.runtime.refresh_generation.load(Ordering::Acquire) != generation {
        return;
    }
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    let ready = {
        let mut host = scene
            .runtime
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(published) = host.as_mut() else {
            return;
        };
        published.generation = generation;
        ready_content(&published.value.snapshot)
    };
    set_inventory_state(&scene.runtime, &ready);
}

pub(crate) fn publish_discovered_host(
    scene: &Scene,
    context: HostContext,
    generation: u64,
) -> Vec<SuppressedHerdrPresentation> {
    let kwt_context_changed = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|published| {
            published.value.snapshot.endpoint() != context.snapshot.endpoint()
                || published.value.snapshot.runtime() != context.snapshot.runtime()
        });
    if kwt_context_changed {
        invalidate_kwt_inventory(&scene.runtime);
    }
    let state = ready_content(&context.snapshot);
    let reconciliation =
        reconcile_herdr_lifecycle_fences(&scene.runtime, &context.snapshot, generation, true);
    set_herdr_inventory(&scene.runtime, context.snapshot.herdr());
    set_zellij_inventory(&scene.runtime, context.snapshot.zellij());
    *scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) =
        Some(Published::new(context, generation));
    set_inventory_state(&scene.runtime, &state);
    reconciliation.recoveries
}

/// Whether any live scene currently wants automatic inventory reads. One
/// scene suspending its polling (a hidden window) never pauses the cadence
/// for another scene that still wants it.
pub(crate) fn inventory_polling_wanted(runtime: &Runtime) -> bool {
    live_scenes(runtime)
        .iter()
        .any(|scene| scene.inventory_polling_enabled.load(Ordering::Acquire))
}

/// Resolve the scene a cadence tick anchors on: the initiating scene while
/// it is alive and not closed — a retained handle can hold a closed
/// scene's allocation alive, and a closed scene never anchors the cadence
/// — else any live scene, else none after clearing the cadence's started
/// flag atomically with scene registration.
fn cadence_anchor(
    weak_scene: &std::sync::Weak<Scene>,
    weak_runtime: &std::sync::Weak<Runtime>,
    started: impl Fn(&Runtime) -> &AtomicBool,
) -> Option<Arc<Scene>> {
    weak_scene
        .upgrade()
        .filter(|scene| !scene.closed.load(Ordering::Acquire))
        .or_else(|| {
            weak_runtime
                .upgrade()
                .and_then(|runtime| cadence_fallback_scene(&runtime, started(&runtime)))
        })
}

pub(crate) fn schedule_inventory_refresh(scene: &Arc<Scene>) -> std::io::Result<()> {
    let weak_scene = Arc::downgrade(scene);
    let weak_runtime = Arc::downgrade(&scene.runtime);
    scene.runtime.refresh_runtime.spawn_after(
        "ghosthub-inventory-cadence",
        INVENTORY_REFRESH_INTERVAL,
        CancellationToken::new(),
        Box::new(move || {
            // The cadence belongs to the runtime: prefer the initiating
            // scene, fall back to any live scene when it closed, and with
            // no scenes left clear the started flag — atomically with
            // scene registration — so the next scene's startup restarts
            // the cadence.
            let Some(scene) = cadence_anchor(&weak_scene, &weak_runtime, |runtime| {
                &runtime.inventory_cadence_started
            }) else {
                return;
            };
            let workspace = Workspace {
                scene: Arc::clone(&scene),
            };
            if inventory_polling_wanted(&scene.runtime) {
                let operation = match scene.runtime.session_operations.try_lock() {
                    Ok(operation) => Some(operation),
                    Err(TryLockError::Poisoned(error)) => Some(error.into_inner()),
                    Err(TryLockError::WouldBlock) => None,
                };
                if let Some(_operation) = operation {
                    let _refresh_started = workspace.refresh_if_ready();
                }
            }
            if let Err(error) = schedule_inventory_refresh(&scene) {
                scene
                    .runtime
                    .inventory_cadence_started
                    .store(false, Ordering::Release);
                broadcast_event(&scene.runtime, || {
                    WorkspaceEvent::Error(format!("inventory refresh cadence stopped: {error}"))
                });
            }
        }),
    )
}

pub(crate) fn schedule_kwt_refresh(scene: &Arc<Scene>) -> std::io::Result<()> {
    let weak_scene = Arc::downgrade(scene);
    let weak_runtime = Arc::downgrade(&scene.runtime);
    scene.runtime.refresh_runtime.spawn_after(
        "ghosthub-kwt-inventory-cadence",
        KWT_REFRESH_INTERVAL,
        CancellationToken::new(),
        Box::new(move || {
            // Same runtime anchoring as the inventory cadence: survive the
            // initiating scene, and clear the started flag — atomically
            // with scene registration — when no scene remains so a future
            // scene restarts the cadence.
            let Some(scene) = cadence_anchor(&weak_scene, &weak_runtime, |runtime| {
                &runtime.kwt_cadence_started
            }) else {
                return;
            };
            if inventory_polling_wanted(&scene.runtime) {
                start_kwt_refresh(&scene, false);
            }
            if let Err(error) = schedule_kwt_refresh(&scene) {
                scene
                    .runtime
                    .kwt_cadence_started
                    .store(false, Ordering::Release);
                broadcast_event(&scene.runtime, || {
                    WorkspaceEvent::Error(format!("KWT inventory cadence stopped: {error}"))
                });
            }
        }),
    )
}

pub(crate) fn start_initial_kwt_refresh(scene: &Arc<Scene>) {
    let should_start = scene
        .runtime
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .find(|host| host.id == "wsl")
        .is_some_and(|host| !host.kwt_initialized() && !host.kwt_refreshing());
    if should_start {
        start_kwt_refresh(scene, false);
    }
}

pub(crate) fn capture_kwt_removal_authority(scene: &Scene, capture: KwtRemovalCapture) {
    let cancellation = CancellationToken::new();
    let running = if let Some(socket_name) = capture.socket_name.as_deref() {
        capture.host.session_is_running_on_socket(
            &capture.endpoint,
            &capture.runtime,
            socket_name,
            &capture.session_name,
            &cancellation,
        )
    } else {
        capture.host.session_is_running(
            &capture.endpoint,
            &capture.runtime,
            &capture.session_name,
            &cancellation,
        )
    };
    let live_target = match running {
        Ok(false) => None,
        Ok(true) => match capture.socket_name.as_deref().map_or_else(
            || {
                capture.host.capture_live_session(
                    &capture.endpoint,
                    &capture.runtime,
                    &capture.session_name,
                    &cancellation,
                )
            },
            |socket_name| {
                capture.host.capture_live_session_on_socket(
                    &capture.endpoint,
                    &capture.runtime,
                    socket_name,
                    &capture.session_name,
                    &cancellation,
                )
            },
        ) {
            Ok(target) => Some(Arc::new(target)),
            Err(error) => {
                publish_kwt_removal_capture_failure(
                    scene,
                    capture.authority,
                    &capture.project_path,
                    &capture.worktree_path,
                    error.to_string(),
                );
                return;
            }
        },
        Err(error) => {
            publish_kwt_removal_capture_failure(
                scene,
                capture.authority,
                &capture.project_path,
                &capture.worktree_path,
                error.to_string(),
            );
            return;
        }
    };
    publish_captured_kwt_removal(scene, capture, live_target);
}

/// Publish one completed removal identity capture as this scene's pending
/// confirmation. The authority check under the slot lock is the fence a
/// confirmed removal advances, so a capture that straddled the removal
/// cannot publish a dialog for a worktree that is already gone.
pub(crate) fn publish_captured_kwt_removal(
    scene: &Scene,
    capture: KwtRemovalCapture,
    live_target: Option<Arc<host::LiveSessionTarget>>,
) {
    let session_was_running = live_target.is_some();
    let mut pending = scene
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.kwt_removal_generation.load(Ordering::Acquire) != capture.authority {
        return;
    }
    let project_path = capture.project_path.clone();
    let worktree_path = capture.worktree_path.clone();
    *pending = Some(PendingKwtRemoval {
        authority: capture.authority,
        endpoint: capture.endpoint,
        repository: capture.repository,
        project_path: capture.project_path,
        registration_fingerprint: capture.registration_fingerprint,
        worktree_path: capture.worktree_path,
        generation: capture.generation,
        session_name: capture.session_name,
        socket_name: capture.socket_name,
        attach_mode: capture.attach_mode,
        live_target,
    });
    // The capture this intent tracked has published; nothing is in flight.
    *scene
        .kwt_removal_capture_intent
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    drop(pending);
    push_lossless_event(
        scene,
        WorkspaceEvent::KwtWorktreeRemovalReady {
            project_path,
            worktree_path,
            authority: capture.authority,
            session_was_running,
        },
    );
}

pub(crate) fn publish_kwt_removal_capture_failure(
    scene: &Scene,
    authority: u64,
    project_path: &str,
    worktree_path: &str,
    message: String,
) {
    let _pending = scene
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.kwt_removal_generation.load(Ordering::Acquire) != authority {
        return;
    }
    push_lossless_event(
        scene,
        WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: authority,
            project_path: project_path.to_owned(),
            worktree_path: Some(worktree_path.to_owned()),
            message,
        },
    );
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn take_pending_kwt_removal(
    scene: &Scene,
    authority: u64,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: &str,
    session_name: &str,
    tmux_attach_mode: KwtTmuxAttachMode,
) -> Result<PendingKwtRemoval, WorkspaceError> {
    let pending = scene
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
        .ok_or_else(|| WorkspaceError::new("review the worktree removal again"))?;
    let matches = pending.authority == authority
        && pending.endpoint.distro() == endpoint
        && pending.repository == repository
        && pending.project_path == project_path
        && pending.registration_fingerprint == registration_fingerprint
        && pending.worktree_path == worktree_path
        && pending.generation == generation
        && pending.session_name == session_name
        && pending.attach_mode == tmux_attach_mode;
    if !matches || scene.kwt_removal_generation.load(Ordering::Acquire) != authority {
        return Err(WorkspaceError::new(
            "the worktree changed after confirmation; review the removal again",
        ));
    }
    Ok(pending)
}

pub(crate) fn restore_pending_kwt_removal(scene: &Scene, pending: PendingKwtRemoval) {
    let mut slot = scene
        .pending_kwt_removal
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.kwt_removal_generation.load(Ordering::Acquire) == pending.authority && slot.is_none() {
        *slot = Some(pending);
    }
}

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    reason = "reservation keeps host identity validation and publication fencing atomic"
)]
pub(crate) fn reserve_kwt_worktree_operation(
    scene: &Arc<Scene>,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    operation: KwtWorktreeOperation,
) -> Result<KwtWorktreeTask, WorkspaceError> {
    if host_id != "wsl" {
        return Err(WorkspaceError::new(
            "KWT worktrees are available only on WSL",
        ));
    }
    if scene
        .runtime
        .kwt_mutation_in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err(WorkspaceError::new(
            "another KWT operation is already running",
        ));
    }
    let captured = (|| {
        let (host, resolved_endpoint, runtime) = scene
            .runtime
            .host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|published| published.value.snapshot.endpoint().distro() == endpoint)
            .map(|published| {
                (
                    published.value.host.clone(),
                    published.value.snapshot.endpoint().clone(),
                    published.value.snapshot.runtime().clone(),
                )
            })
            .ok_or_else(|| WorkspaceError::new("refresh WSL before changing worktrees"))?;
        let hosts = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let item = hosts
            .iter()
            .find(|item| item.id == host_id && item.endpoint == endpoint)
            .ok_or_else(|| WorkspaceError::new("the selected WSL host is unavailable"))?;
        if item.connection != HostConnectionState::Ready
            || !item.kwt_available()
            || item.kwt_diagnostic.is_some()
        {
            return Err(WorkspaceError::new(
                "refresh KWT inventory before changing worktrees",
            ));
        }
        let project = item.projects.iter().find(|project| {
            project.repository == repository
                && project.path == project_path
                && project.registration_fingerprint == registration_fingerprint
        });
        let Some(project) = project else {
            return Err(WorkspaceError::new(
                "the selected KWT project is no longer in current inventory",
            ));
        };
        validate_kwt_worktree_operation(project, &operation)?;
        drop(hosts);
        let cancellation = CancellationToken::new();
        let generation = {
            let _publication = scene
                .runtime
                .kwt_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let generation = scene
                .runtime
                .kwt_refresh_generation
                .fetch_add(1, Ordering::AcqRel)
                + 1;
            if let Some(previous) = scene
                .runtime
                .kwt_discovery_cancel
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take()
            {
                previous.cancel();
            }
            let _snapshot_write = begin_snapshot_write(&scene.runtime);
            if let Some(item) = scene
                .runtime
                .hosts
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter_mut()
                .find(|item| item.id == host_id && item.endpoint == endpoint)
            {
                item.kwt_state = KwtState::Mutating;
                scene.runtime.revision.fetch_add(1, Ordering::Release);
            }
            generation
        };
        let operation_id = match &operation {
            KwtWorktreeOperation::Branches | KwtWorktreeOperation::PullRequests => {
                next_operation_id(&scene.runtime)
            }
            KwtWorktreeOperation::ImportPullRequest {
                navigation_generation,
                ..
            }
            | KwtWorktreeOperation::Create {
                navigation_generation,
                ..
            } => *navigation_generation,
            KwtWorktreeOperation::Remove { operation_id, .. } => *operation_id,
        };
        Ok(KwtWorktreeTask {
            host,
            endpoint: resolved_endpoint,
            runtime,
            cancellation,
            generation,
            operation_id,
            repository: repository.to_owned(),
            project_path: project_path.to_owned(),
            registration_fingerprint: registration_fingerprint.to_owned(),
            operation,
        })
    })();
    if captured.is_err() {
        scene
            .runtime
            .kwt_mutation_in_flight
            .store(false, Ordering::Release);
    }
    captured
}

#[allow(
    clippy::too_many_lines,
    reason = "one exhaustive dispatch keeps KWT operation settlement and refresh behavior aligned"
)]
pub(crate) fn run_kwt_worktree_operation(scene: &Arc<Scene>, task: &KwtWorktreeTask) {
    let outcome = match &task.operation {
        KwtWorktreeOperation::Branches => {
            match task.host.list_kwt_branches(
                &task.endpoint,
                &task.runtime,
                &task.project_path,
                &task.cancellation,
            ) {
                Ok(branches) => push_kwt_listing_event(
                    scene,
                    task,
                    WorkspaceEvent::KwtBranchesLoaded {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        branches: branches
                            .into_iter()
                            .map(|branch| {
                                KwtBranchItem::new(
                                    branch.name(),
                                    branch.source(),
                                    branch.is_remote(),
                                )
                            })
                            .collect(),
                    },
                ),
                Err(error) => push_kwt_listing_event(
                    scene,
                    task,
                    WorkspaceEvent::KwtWorktreeOperationFailed {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        worktree_path: None,
                        message: error.to_string(),
                    },
                ),
            }
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            KwtWorktreeOutcome::default()
        }
        KwtWorktreeOperation::PullRequests => {
            match task.host.list_kwt_pull_requests(
                &task.endpoint,
                &task.runtime,
                &task.project_path,
                &task.cancellation,
            ) {
                Ok(pull_requests) => push_kwt_listing_event(
                    scene,
                    task,
                    WorkspaceEvent::KwtPullRequestsLoaded {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        pull_requests: pull_requests
                            .iter()
                            .map(KwtPullRequestItem::from_host)
                            .collect(),
                    },
                ),
                Err(error) => push_kwt_listing_event(
                    scene,
                    task,
                    WorkspaceEvent::KwtWorktreeOperationFailed {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        worktree_path: None,
                        message: error.to_string(),
                    },
                ),
            }
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            KwtWorktreeOutcome::default()
        }
        KwtWorktreeOperation::ImportPullRequest {
            selector,
            navigation_generation,
        } => run_kwt_pull_request_import(scene, task, selector, *navigation_generation),
        KwtWorktreeOperation::Create {
            branch,
            source,
            creates_branch,
            navigation_generation,
        } => KwtWorktreeOutcome {
            refresh_kwt: run_kwt_worktree_create(
                scene,
                task,
                branch,
                source.as_deref(),
                *creates_branch,
                *navigation_generation,
            ),
            refresh_tmux: false,
        },
        operation @ KwtWorktreeOperation::Remove { .. } => {
            run_kwt_worktree_remove(scene, task, operation)
        }
    };
    finish_kwt_worktree_operation(scene, task);
    if outcome.refresh_tmux {
        let workspace = Workspace {
            scene: Arc::clone(scene),
        };
        if let Err(error) = workspace.refresh_reanchored() {
            workspace.push_operation_error(format!(
                "the worktree was removed, but session inventory could not refresh: {error}"
            ));
        }
    }
    if outcome.refresh_kwt {
        start_kwt_refresh(scene, false);
    }
}

#[allow(
    clippy::too_many_lines,
    reason = "import validates the complete KWT response and refreshed protected-workspace identity"
)]
pub(crate) fn run_kwt_pull_request_import(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    selector: &str,
    navigation_generation: u64,
) -> KwtWorktreeOutcome {
    let request = KwtPullRequestImportRequest::new(
        &task.project_path,
        &task.repository,
        &task.registration_fingerprint,
        selector,
    );
    let imported = match task.host.import_kwt_pull_request(
        &task.endpoint,
        &task.runtime,
        &request,
        &task.cancellation,
    ) {
        Ok(imported) => imported,
        Err(error) => {
            let (outcome, message) =
                kwt_pull_request_import_failure(error.kind(), &error.to_string());
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: None,
                    message,
                },
            );
            return outcome;
        }
    };
    let workspace = imported.workspace();
    let exact_response = imported.project_identity() == task.repository
        && imported.project_path() == task.project_path
        && workspace.repository() == task.repository
        && workspace.generation().is_some()
        && workspace.tmux_socket_name().is_some()
        && workspace.tmux_attach_mode() == KwtTmuxAttachMode::Protected;
    if !exact_response {
        publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
        push_lossless_event(
            scene,
            WorkspaceEvent::KwtWorktreeOperationFailed {
                operation_id: task.operation_id,
                project_path: task.project_path.clone(),
                worktree_path: None,
                message: "KWT imported the pull request but returned an inconsistent protected workspace; refresh before opening it."
                    .to_owned(),
            },
        );
        return KwtWorktreeOutcome {
            refresh_kwt: true,
            refresh_tmux: false,
        };
    }
    let Ok(Some(inventory)) =
        task.host
            .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
    else {
        publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
        push_lossless_event(
            scene,
            WorkspaceEvent::KwtWorktreeOperationFailed {
                operation_id: task.operation_id,
                project_path: task.project_path.clone(),
                worktree_path: Some(workspace.path().to_owned()),
                message: "The pull request was imported, but KWT inventory is temporarily unavailable. Ghosthub will refresh it automatically."
                    .to_owned(),
            },
        );
        return KwtWorktreeOutcome {
            refresh_kwt: true,
            refresh_tmux: false,
        };
    };
    let exact = inventory.projects().iter().find_map(|project| {
        (project.project().repository() == task.repository
            && project.project().path() == task.project_path
            && project.project().registration_fingerprint() == task.registration_fingerprint)
            .then(|| {
                project.worktrees().iter().find(|worktree| {
                    worktree.path() == workspace.path()
                        && worktree.generation() == workspace.generation()
                        && worktree.session_name() == workspace.session_name()
                        && worktree.tmux_socket_name() == workspace.tmux_socket_name()
                        && worktree.tmux_attach_mode() == workspace.tmux_attach_mode()
                })
            })
            .flatten()
    });
    let Some(exact) = exact else {
        publish_kwt_inventory(
            scene,
            task.generation,
            &task.endpoint,
            &task.runtime,
            &inventory,
        );
        push_lossless_event(
            scene,
            WorkspaceEvent::KwtWorktreeOperationFailed {
                operation_id: task.operation_id,
                project_path: task.project_path.clone(),
                worktree_path: Some(workspace.path().to_owned()),
                message: "The imported pull request changed before KWT inventory could confirm it. Refresh and choose it again."
                    .to_owned(),
            },
        );
        return KwtWorktreeOutcome::default();
    };
    let target = KwtWorktreeTarget {
        host_id: "wsl".to_owned(),
        endpoint: task.endpoint.distro().to_owned(),
        repository: task.repository.clone(),
        project_path: task.project_path.clone(),
        registration_fingerprint: task.registration_fingerprint.clone(),
        worktree_path: exact.path().to_owned(),
        generation: exact.generation().map(str::to_owned),
        session_name: exact.session_name().to_owned(),
        tmux_socket_name: exact.tmux_socket_name().map(str::to_owned),
        tmux_attach_mode: exact.tmux_attach_mode(),
    };
    publish_kwt_inventory(
        scene,
        task.generation,
        &task.endpoint,
        &task.runtime,
        &inventory,
    );
    broadcast_event_with_lossless_owner(&scene.runtime, scene.id, || {
        WorkspaceEvent::KwtWorktreeCreated {
            target: target.clone(),
            navigation_generation,
        }
    });
    KwtWorktreeOutcome::default()
}

pub(crate) fn run_kwt_worktree_remove(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    operation: &KwtWorktreeOperation,
) -> KwtWorktreeOutcome {
    let KwtWorktreeOperation::Remove {
        worktree_path,
        generation,
        session_name,
        socket_name,
        attach_mode,
        live_target,
        ..
    } = operation
    else {
        unreachable!("worktree removal requires a remove operation");
    };
    let socket_name = socket_name.as_deref();
    let live_target = live_target.as_deref();
    let _session_operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Err(error) = preflight_kwt_worktree_remove(
        task,
        worktree_path,
        generation,
        session_name,
        socket_name,
        *attach_mode,
    ) {
        fail_kwt_worktree_remove(scene, task, error);
        return KwtWorktreeOutcome::default();
    }

    if let Some(target) = live_target {
        if let Err(error) = task.host.kill_live_session(target, &task.cancellation) {
            fail_kwt_worktree_remove(scene, task, error.to_string());
            return KwtWorktreeOutcome::default();
        }
        Workspace {
            scene: Arc::clone(scene),
        }
        .finish_session_kill(target);
    }

    if let Err(error) = task.host.remove_kwt_worktree(
        &task.endpoint,
        &task.runtime,
        &task.project_path,
        worktree_path,
        generation,
        session_name,
        socket_name,
        &task.cancellation,
    ) {
        if error.kind() == DiagnosticKind::Timeout {
            return reconcile_timed_out_kwt_worktree_remove(
                scene,
                task,
                worktree_path,
                generation,
                live_target.is_some(),
            );
        }
        fail_kwt_worktree_remove(scene, task, error.to_string());
        return KwtWorktreeOutcome::default();
    }
    tombstone_removed_kwt_worktree(scene, task, worktree_path, generation);

    KwtWorktreeOutcome {
        refresh_kwt: reconcile_removed_kwt_worktree(scene, task, worktree_path, generation),
        refresh_tmux: live_target.is_some(),
    }
}

pub(crate) fn reconcile_timed_out_kwt_worktree_remove(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
    session_killed: bool,
) -> KwtWorktreeOutcome {
    settle_timed_out_kwt_worktree_remove(
        scene,
        task,
        worktree_path,
        generation,
        session_killed,
        task.host
            .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation),
    )
}

/// Settle one timed-out removal against a discovery outcome. Split from
/// the discovery call so the branch behavior - only a verified absence
/// drops other scenes' confirmations - is directly testable.
pub(crate) fn settle_timed_out_kwt_worktree_remove(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
    session_killed: bool,
    discovery: Result<Option<KwtInventory>, HostError>,
) -> KwtWorktreeOutcome {
    match discovery {
        Ok(Some(inventory)) => {
            let still_present = inventory.projects().iter().any(|project| {
                project.worktrees().iter().any(|worktree| {
                    worktree.path() == worktree_path && worktree.generation() == Some(generation)
                })
            });
            publish_kwt_inventory(
                scene,
                task.generation,
                &task.endpoint,
                &task.runtime,
                &inventory,
            );
            if still_present {
                push_lossless_event(
                    scene,
                    WorkspaceEvent::KwtWorktreeOperationFailed {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        worktree_path: Some(worktree_path.to_owned()),
                        message: "Worktree removal timed out. KWT still reports the worktree; Ghosthub will keep refreshing its inventory."
                            .to_owned(),
                    },
                );
            } else {
                // Discovery proved the worktree gone despite the timeout:
                // this is the confirmed-removal point, so stale removal
                // confirmations in other scenes drop here and only here.
                drop_matching_kwt_removal_confirmations(
                    &scene.runtime,
                    &task.endpoint,
                    &task.repository,
                    &task.project_path,
                    &task.registration_fingerprint,
                    worktree_path,
                    generation,
                );
                tombstone_removed_kwt_worktree(scene, task, worktree_path, generation);
                push_lossless_event(
                    scene,
                    WorkspaceEvent::KwtWorktreeRemoved {
                        operation_id: task.operation_id,
                        project_path: task.project_path.clone(),
                        worktree_path: worktree_path.to_owned(),
                    },
                );
            }
        }
        Ok(None) => {
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: Some(worktree_path.to_owned()),
                    message: "Worktree removal timed out and KWT inventory is temporarily unavailable. Ghosthub will reconcile it automatically."
                        .to_owned(),
                },
            );
        }
        Err(error) => {
            publish_kwt_error(
                scene,
                task.generation,
                &task.endpoint,
                &task.runtime,
                HostDiagnostic::new(error.kind(), error.to_string()),
            );
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: Some(worktree_path.to_owned()),
                    message: "Worktree removal timed out and its result could not be confirmed. Ghosthub will reconcile it automatically."
                        .to_owned(),
                },
            );
        }
    }
    KwtWorktreeOutcome {
        refresh_kwt: true,
        refresh_tmux: session_killed,
    }
}

pub(crate) fn tombstone_removed_kwt_worktree(
    scene: &Scene,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
) {
    publish_kwt(
        scene,
        task.generation,
        &task.endpoint,
        &task.runtime,
        |host| {
            remove_cached_kwt_worktree(
                host,
                &task.repository,
                &task.project_path,
                &task.registration_fingerprint,
                worktree_path,
                generation,
            );
        },
    );
}

pub(crate) fn reconcile_removed_kwt_worktree(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
) -> bool {
    settle_removed_kwt_worktree(
        scene,
        task,
        worktree_path,
        generation,
        task.host
            .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation),
    )
}

/// Settle one reportedly successful removal against a discovery outcome.
/// Split from the discovery call so the branch behavior - only a verified
/// absence drops other scenes' confirmations, and a still-present worktree
/// preserves them - is directly testable.
pub(crate) fn settle_removed_kwt_worktree(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    worktree_path: &str,
    generation: &str,
    discovery: Result<Option<KwtInventory>, HostError>,
) -> bool {
    match discovery {
        Ok(Some(inventory)) => {
            let still_present = inventory.projects().iter().any(|project| {
                project.worktrees().iter().any(|worktree| {
                    worktree.path() == worktree_path && worktree.generation() == Some(generation)
                })
            });
            if still_present {
                return fail_kwt_worktree_remove(
                    scene,
                    task,
                    "KWT reported success but the worktree is still present; refresh before retrying."
                        .to_owned(),
                );
            }
            // Only a reconciliation that proves the worktree gone may drop
            // other scenes' confirmations; KWT's own success report is not
            // enough, and the still-present path above preserves them.
            drop_matching_kwt_removal_confirmations(
                &scene.runtime,
                &task.endpoint,
                &task.repository,
                &task.project_path,
                &task.registration_fingerprint,
                worktree_path,
                generation,
            );
            publish_kwt_inventory(
                scene,
                task.generation,
                &task.endpoint,
                &task.runtime,
                &inventory,
            );
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeRemoved {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: worktree_path.to_owned(),
                },
            );
            true
        }
        Ok(None) => {
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeRemoved {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: worktree_path.to_owned(),
                },
            );
            true
        }
        Err(error) => {
            publish_kwt_error(
                scene,
                task.generation,
                &task.endpoint,
                &task.runtime,
                HostDiagnostic::new(error.kind(), error.to_string()),
            );
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeRemoved {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: worktree_path.to_owned(),
                },
            );
            true
        }
    }
}

pub(crate) fn fail_kwt_worktree_remove(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    message: String,
) -> bool {
    publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
    push_lossless_event(
        scene,
        WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: task.operation_id,
            project_path: task.project_path.clone(),
            worktree_path: match &task.operation {
                KwtWorktreeOperation::Remove { worktree_path, .. } => Some(worktree_path.clone()),
                KwtWorktreeOperation::Branches
                | KwtWorktreeOperation::PullRequests
                | KwtWorktreeOperation::ImportPullRequest { .. }
                | KwtWorktreeOperation::Create { .. } => None,
            },
            message,
        },
    );
    false
}

pub(crate) fn run_kwt_worktree_create(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    branch: &str,
    source: Option<&str>,
    creates_branch: bool,
    navigation_generation: u64,
) -> bool {
    let baseline = match capture_kwt_creation_baseline(task) {
        Ok(baseline) => baseline,
        Err(error) => {
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: None,
                    message: error.to_string(),
                },
            );
            return false;
        }
    };
    let result = task.host.create_kwt_worktree(
        &task.endpoint,
        &task.runtime,
        &host::KwtWorktreeCreate::new(
            &task.project_path,
            &task.repository,
            &task.registration_fingerprint,
            branch,
            source.map(str::to_owned),
            creates_branch,
        ),
        &task.cancellation,
    );
    match result {
        Ok(()) => {
            let pending =
                pending_kwt_creation(scene.id, task, branch, navigation_generation, baseline);
            remember_pending_kwt_creation(&scene.runtime, pending.clone());
            reconcile_created_kwt_worktree(scene, task, &pending, true)
        }
        Err(error) if error.kind() == DiagnosticKind::Timeout => {
            let pending =
                pending_kwt_creation(scene.id, task, branch, navigation_generation, baseline);
            remember_pending_kwt_creation(&scene.runtime, pending.clone());
            reconcile_created_kwt_worktree(scene, task, &pending, false)
        }
        Err(error) => {
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id: task.operation_id,
                    project_path: task.project_path.clone(),
                    worktree_path: None,
                    message: error.to_string(),
                },
            );
            false
        }
    }
}

pub(crate) fn reconcile_created_kwt_worktree(
    scene: &Arc<Scene>,
    task: &KwtWorktreeTask,
    pending: &PendingKwtCreation,
    mutation_confirmed: bool,
) -> bool {
    match task
        .host
        .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation)
    {
        Ok(Some(inventory)) => {
            let target = pending_kwt_creation_target(pending, &inventory);
            publish_kwt_inventory(
                scene,
                task.generation,
                &task.endpoint,
                &task.runtime,
                &inventory,
            );
            if target.is_some() {
                false
            } else {
                push_lossless_event(
                    scene,
                    WorkspaceEvent::KwtWorktreeCreationPending {
                        project_path: task.project_path.clone(),
                        message: if mutation_confirmed {
                            "Worktree created. Waiting for KWT to refresh it.".to_owned()
                        } else {
                            "Worktree creation timed out. Ghosthub will reconcile KWT inventory automatically."
                                .to_owned()
                        },
                        navigation_generation: pending.navigation_generation,
                    },
                );
                true
            }
        }
        Ok(None) => {
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeCreationPending {
                    project_path: task.project_path.clone(),
                    message: if mutation_confirmed {
                        "Worktree created. Waiting for KWT to become available.".to_owned()
                    } else {
                        "Worktree creation timed out and KWT inventory is temporarily unavailable. Ghosthub will reconcile it automatically."
                            .to_owned()
                    },
                    navigation_generation: pending.navigation_generation,
                },
            );
            true
        }
        Err(error) => {
            publish_kwt_error(
                scene,
                task.generation,
                &task.endpoint,
                &task.runtime,
                HostDiagnostic::new(error.kind(), error.to_string()),
            );
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtWorktreeCreationPending {
                    project_path: task.project_path.clone(),
                    message: if mutation_confirmed {
                        "Worktree created. KWT inventory is temporarily unavailable; Ghosthub will retry."
                            .to_owned()
                    } else {
                        "Worktree creation timed out and its result could not be confirmed. Ghosthub will reconcile it automatically."
                            .to_owned()
                    },
                    navigation_generation: pending.navigation_generation,
                },
            );
            true
        }
    }
}

pub(crate) fn resolve_pending_kwt_creations(
    scene: &Scene,
    endpoint: &host::WslEndpoint,
    inventory: &KwtInventory,
) {
    resolve_pending_kwt_creations_at(scene, endpoint, inventory, Instant::now());
}

pub(crate) fn resolve_pending_kwt_creations_at(
    scene: &Scene,
    endpoint: &host::WslEndpoint,
    inventory: &KwtInventory,
    now: Instant,
) {
    let mut resolved = Vec::new();
    let mut expired = Vec::new();
    let mut pending = scene
        .runtime
        .pending_kwt_creations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    pending.retain_mut(|candidate| {
        if candidate.endpoint != *endpoint {
            return true;
        }
        if now >= candidate.deadline {
            expired.push((
                candidate.project_path.clone(),
                candidate.navigation_generation,
                candidate.scene,
            ));
            false
        } else if let Some(target) = pending_kwt_creation_target(candidate, inventory) {
            resolved.push((target, candidate.navigation_generation, candidate.scene));
            false
        } else {
            candidate.refreshes_remaining = candidate.refreshes_remaining.saturating_sub(1);
            if candidate.refreshes_remaining > 0 {
                return true;
            }
            expired.push((
                candidate.project_path.clone(),
                candidate.navigation_generation,
                candidate.scene,
            ));
            false
        }
    });
    drop(pending);
    for (target, navigation_generation, owner) in resolved {
        broadcast_event_with_lossless_owner(&scene.runtime, owner, || {
            WorkspaceEvent::KwtWorktreeCreated {
                target: target.clone(),
                navigation_generation,
            }
        });
    }
    for (project_path, navigation_generation, owner) in expired {
        // Any scene's refresh may resolve a pending creation; the expiry
        // settles the OWNING scene's dialog, so it is delivered losslessly
        // to that scene. A gone owner has no dialog left to settle.
        push_lossless_to_scene(
            &scene.runtime,
            owner,
            WorkspaceEvent::KwtWorktreeCreationExpired {
                project_path,
                message: "KWT did not report the created worktree before reconciliation expired. Refresh the project before trying again."
                    .to_owned(),
                navigation_generation,
            },
        );
    }
}

pub(crate) fn reserve_kwt_refresh(scene: &Arc<Scene>, supersede: bool) -> Option<KwtRefresh> {
    if scene.runtime.kwt_mutation_in_flight.load(Ordering::Acquire) {
        return None;
    }
    if scene
        .runtime
        .wsl_config
        .as_ref()
        .is_none_or(|config| config.kwt_bundle().is_none())
    {
        return None;
    }
    let (host, endpoint, runtime) = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .map(|published| {
            (
                published.value.host.clone(),
                published.value.snapshot.endpoint().clone(),
                published.value.snapshot.runtime().clone(),
            )
        })?;
    if !supersede {
        let eligible = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .find(|item| item.id == "wsl" && item.endpoint == endpoint.distro())
            .is_some_and(|item| {
                item.connection == HostConnectionState::Ready && !item.kwt_refreshing()
            });
        if !eligible {
            return None;
        }
    }
    let cancellation = CancellationToken::new();
    let generation = {
        let _publication = scene
            .runtime
            .kwt_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if scene.runtime.kwt_mutation_in_flight.load(Ordering::Acquire) {
            return None;
        }
        let generation = scene
            .runtime
            .kwt_refresh_generation
            .fetch_add(1, Ordering::AcqRel)
            + 1;
        if let Some(previous) = scene
            .runtime
            .kwt_discovery_cancel
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replace(cancellation.clone())
        {
            previous.cancel();
        }
        let _snapshot_write = begin_snapshot_write(&scene.runtime);
        if let Some(item) = scene
            .runtime
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter_mut()
            .find(|item| item.id == "wsl" && item.endpoint == endpoint.distro())
        {
            item.kwt_state = KwtState::Refreshing {
                available: item.kwt_available(),
            };
            scene.runtime.revision.fetch_add(1, Ordering::Release);
        }
        generation
    };
    Some(KwtRefresh {
        host,
        endpoint,
        runtime,
        cancellation,
        generation,
    })
}

pub(crate) fn reserve_kwt_project_mutation(
    scene: &Arc<Scene>,
    host_id: &str,
    endpoint: &str,
    request: KwtProjectMutationRequest,
) -> Result<KwtProjectMutationTask, WorkspaceError> {
    if host_id != "wsl" {
        return Err(WorkspaceError::new(
            "KWT projects are available only on WSL",
        ));
    }
    if scene
        .runtime
        .kwt_mutation_in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err(WorkspaceError::new(
            "another KWT project operation is already running",
        ));
    }
    match capture_kwt_project_mutation(scene, endpoint, request) {
        Ok(task) => Ok(task),
        Err(error) => {
            scene
                .runtime
                .kwt_mutation_in_flight
                .store(false, Ordering::Release);
            Err(error)
        }
    }
}

pub(crate) fn capture_kwt_project_mutation(
    scene: &Arc<Scene>,
    endpoint: &str,
    request: KwtProjectMutationRequest,
) -> Result<KwtProjectMutationTask, WorkspaceError> {
    let (host, resolved_endpoint, runtime) = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .filter(|published| published.value.snapshot.endpoint().distro() == endpoint)
        .map(|published| {
            (
                published.value.host.clone(),
                published.value.snapshot.endpoint().clone(),
                published.value.snapshot.runtime().clone(),
            )
        })
        .ok_or_else(|| WorkspaceError::new("refresh WSL before changing KWT projects"))?;
    {
        let hosts = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let item = hosts
            .iter()
            .find(|item| item.id == "wsl" && item.endpoint == endpoint)
            .ok_or_else(|| WorkspaceError::new("the selected WSL host is no longer available"))?;
        match &request {
            KwtProjectMutationRequest::Add { .. } => {
                if !item.can_add_kwt_project() {
                    return Err(WorkspaceError::new(
                        "the pinned KWT helper is unavailable on this host",
                    ));
                }
            }
            KwtProjectMutationRequest::Remove {
                repository,
                path,
                registration_fingerprint,
            } => {
                if !item.can_remove_kwt_project() {
                    return Err(WorkspaceError::new(
                        "refresh KWT inventory before removing a project",
                    ));
                }
                if !item.projects.iter().any(|project| {
                    project.repository == *repository
                        && project.path == *path
                        && project.registration_fingerprint == *registration_fingerprint
                }) {
                    return Err(WorkspaceError::new(
                        "the selected KWT project is no longer in the current inventory",
                    ));
                }
            }
        }
    }
    let cancellation = CancellationToken::new();
    let generation = {
        let _publication = scene
            .runtime
            .kwt_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let generation = scene
            .runtime
            .kwt_refresh_generation
            .fetch_add(1, Ordering::AcqRel)
            + 1;
        if let Some(previous) = scene
            .runtime
            .kwt_discovery_cancel
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            previous.cancel();
        }
        let _snapshot_write = begin_snapshot_write(&scene.runtime);
        if let Some(item) = scene
            .runtime
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter_mut()
            .find(|item| item.id == "wsl" && item.endpoint == endpoint)
        {
            item.kwt_state = KwtState::Mutating;
            scene.runtime.revision.fetch_add(1, Ordering::Release);
        }
        generation
    };
    Ok(KwtProjectMutationTask {
        host,
        endpoint: resolved_endpoint,
        runtime,
        cancellation,
        generation,
        request,
    })
}

pub(crate) fn run_kwt_project_mutation(scene: &Arc<Scene>, task: &KwtProjectMutationTask) {
    let action = task.request.action();
    let mutation = match &task.request {
        KwtProjectMutationRequest::Add { path } => {
            task.host
                .register_kwt_project(&task.endpoint, &task.runtime, path, &task.cancellation)
        }
        KwtProjectMutationRequest::Remove {
            repository,
            path,
            registration_fingerprint,
        } => task.host.remove_kwt_project(
            &task.endpoint,
            &task.runtime,
            path,
            repository,
            registration_fingerprint,
            &task.cancellation,
        ),
    };
    match mutation {
        Ok(project) => {
            publish_kwt_project_mutation(
                scene,
                task.generation,
                &task.endpoint,
                &task.runtime,
                action,
                &project,
            );
            let refreshed =
                task.host
                    .discover_kwt(&task.endpoint, &task.runtime, &task.cancellation);
            match refreshed {
                Ok(Some(inventory)) => {
                    publish_kwt_inventory(
                        scene,
                        task.generation,
                        &task.endpoint,
                        &task.runtime,
                        &inventory,
                    );
                }
                Ok(None) => publish_kwt_error(
                    scene,
                    task.generation,
                    &task.endpoint,
                    &task.runtime,
                    HostDiagnostic::new(
                        DiagnosticKind::ExecutableNotFound,
                        "The pinned KWT helper became unavailable after changing the project",
                    ),
                ),
                Err(error) => publish_kwt_error(
                    scene,
                    task.generation,
                    &task.endpoint,
                    &task.runtime,
                    HostDiagnostic::new(error.kind(), error.to_string()),
                ),
            }
            push_lossless_event(scene, WorkspaceEvent::KwtProjectMutationFinished { action });
        }
        Err(error) => {
            publish_kwt_mutation_failure(scene, task.generation, &task.endpoint, &task.runtime);
            push_lossless_event(
                scene,
                WorkspaceEvent::KwtProjectMutationFailed {
                    action,
                    message: error.to_string(),
                },
            );
        }
    }
    finish_kwt_project_mutation(scene, Some((&task.endpoint, &task.runtime)));
}

pub(crate) fn publish_kwt_project_mutation(
    scene: &Scene,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    action: KwtProjectAction,
    project: &host::KwtProject,
) {
    publish_kwt(scene, generation, endpoint, runtime, |host| {
        match action {
            KwtProjectAction::Add => {
                let worktrees = host
                    .projects
                    .iter()
                    .find(|item| {
                        item.repository == project.repository() && item.path == project.path()
                    })
                    .map(|item| item.worktrees.clone())
                    .unwrap_or_default();
                host.projects.retain(|item| {
                    item.repository != project.repository() && item.path != project.path()
                });
                host.projects.push(ProjectItem::new(
                    project.repository(),
                    project.name(),
                    project.path(),
                    project.registration_fingerprint(),
                    worktrees,
                ));
                host.projects.sort_by(|left, right| {
                    left.name
                        .cmp(&right.name)
                        .then_with(|| left.path.cmp(&right.path))
                });
            }
            KwtProjectAction::Remove => {
                host.projects.retain(|item| {
                    item.repository != project.repository() || item.path != project.path()
                });
            }
        }
        host.kwt_state = KwtState::Ready;
        host.kwt_diagnostic = None;
    });
}

pub(crate) fn publish_kwt_mutation_failure(
    scene: &Scene,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
) {
    publish_kwt(scene, generation, endpoint, runtime, |host| {
        host.kwt_state = KwtState::Ready;
    });
}

/// Cancel a KWT worktree listing owned by a closing scene: invalidate its
/// publication generation, reset any mutating host badge, and release the
/// shared KWT lane — the teardown user cancellation performs, minus the
/// dead scene's dialog bookkeeping. A late task completion is fenced by
/// the removed ownership record and the bumped generation.
pub(crate) fn cancel_owned_kwt_listing(scene: &Scene, listing: &crate::KwtWorktreeListing) {
    listing.cancellation.cancel();
    {
        let _publication = scene
            .runtime
            .kwt_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _generation = scene.runtime.kwt_refresh_generation.compare_exchange(
            listing.generation,
            listing.generation.saturating_add(1),
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    for host in scene
        .runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter_mut()
    {
        if host.kwt_mutating() {
            host.kwt_state = KwtState::Ready;
        }
    }
    scene
        .runtime
        .kwt_mutation_in_flight
        .store(false, Ordering::Release);
    scene.runtime.revision.fetch_add(1, Ordering::Release);
}

pub(crate) fn finish_kwt_project_mutation(
    scene: &Arc<Scene>,
    target: Option<(&host::WslEndpoint, &host::WslRuntimeIdentity)>,
) {
    {
        let _snapshot_write = begin_snapshot_write(&scene.runtime);
        if let Some((endpoint, runtime)) = target {
            let current_matches = scene
                .runtime
                .host
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_ref()
                .is_some_and(|published| {
                    published.value.snapshot.endpoint() == endpoint
                        && published.value.snapshot.runtime() == runtime
                });
            if current_matches
                && let Some(host) = scene
                    .runtime
                    .hosts
                    .write()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .iter_mut()
                    .find(|host| host.id == "wsl" && host.endpoint == endpoint.distro())
            {
                host.kwt_state = KwtState::Ready;
            }
        } else {
            for host in scene
                .runtime
                .hosts
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter_mut()
            {
                if host.kwt_mutating() {
                    host.kwt_state = KwtState::Ready;
                }
            }
        }
        scene
            .runtime
            .kwt_mutation_in_flight
            .store(false, Ordering::Release);
        scene.runtime.revision.fetch_add(1, Ordering::Release);
    }
    start_initial_kwt_refresh(scene);
}

pub(crate) fn finish_kwt_worktree_operation(scene: &Arc<Scene>, task: &KwtWorktreeTask) {
    if task.is_listing() {
        let owns_listing = {
            let mut active = scene
                .runtime
                .kwt_worktree_listing
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if active.as_ref().is_some_and(|listing| {
                listing.generation == task.generation && listing.operation_id == task.operation_id
            }) {
                active.take();
                true
            } else {
                false
            }
        };
        if !owns_listing {
            return;
        }
    }
    finish_kwt_project_mutation(scene, Some((&task.endpoint, &task.runtime)));
}

pub(crate) fn push_kwt_listing_event(scene: &Scene, task: &KwtWorktreeTask, event: WorkspaceEvent) {
    let active = scene
        .runtime
        .kwt_worktree_listing
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if active.as_ref().is_some_and(|listing| {
        listing.generation == task.generation
            && listing.operation_id == task.operation_id
            && !task.cancellation.is_cancelled()
    }) {
        match &event {
            // A listing failure settles the dialog's pending operation and
            // must not be shed; loaded data is re-requestable and may be.
            WorkspaceEvent::KwtWorktreeOperationFailed { .. } => {
                push_lossless_event(scene, event);
            }
            _ => push_operation_event(scene, event),
        }
    }
    drop(active);
}

/// One queued inbox entry. `sheddable` entries (operation and broadcast
/// pushes) may be evicted when the inbox overflows; lossless entries never
/// are — the pump's per-scene headroom check and the KWT settlement bounds
/// documented on `push_lossless_event` keep their growth finite.
pub(crate) struct InboxEvent {
    pub(crate) event: WorkspaceEvent,
    pub(crate) sheddable: bool,
}

/// Disable clipboard writes on a worker that until now drove this scene's
/// visible presentation, and drop the scene's undelivered queued clipboard
/// writes. This mirrors the worker's own deferred-event purge on the same
/// transition: a write emitted while the presentation was visible but not
/// yet delivered when it stops being visible is dropped, never applied
/// late. Callers that merely assert the disabled initial state of a worker
/// that was never visible must call `set_clipboard_writes_enabled(false)`
/// directly instead — purging there could drop a still-visible sibling
/// worker's pending writes.
///
/// The purge takes only the inbox lock, so callers may hold any scene
/// guard. In-flight pump passes are handled by the clipboard epoch instead
/// of by blocking on the pass lock: the purge advances the epoch under the
/// inbox lock, and a pass's deferred clipboard pushes are dropped when the
/// epoch moved after the pass captured it. One benign window is accepted:
/// a retirement racing a pass that already extracted the replacement
/// worker's first write drops that write too; the loss is one fresh
/// clipboard write, recoverable by copying again.
pub(crate) fn retire_clipboard_writes(scene: &Scene, worker: &TerminalWorker) {
    worker.set_clipboard_writes_enabled(false);
    purge_queued_clipboard_writes(scene);
}

/// Drop every queued-but-undelivered clipboard write from this scene's
/// inbox and advance the clipboard epoch, both under the inbox lock, so a
/// concurrent pump pass either pushes before the purge (and is purged) or
/// observes the moved epoch and drops its stale pushes.
pub(crate) fn purge_queued_clipboard_writes(scene: &Scene) {
    let mut events = scene
        .operation_events
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    scene.clipboard_epoch.fetch_add(1, Ordering::AcqRel);
    events.retain(|queued| !matches!(queued.event, WorkspaceEvent::ClipboardWrite { .. }));
}

/// Enqueue one pump-extracted clipboard write, unless the scene's clipboard
/// epoch moved since `observed_epoch` was captured at the start of the pump
/// pass — a retirement in between means the write's presentation is no
/// longer visible and the write is dropped, matching the purge semantics.
/// The epoch comparison and the insertion happen under the same inbox lock
/// the purge advances the epoch under, so no interleaving lets a stale
/// write survive.
pub(crate) fn push_clipboard_write_event(
    scene: &Scene,
    event: WorkspaceEvent,
    observed_epoch: u64,
) {
    push_lossless_gated(scene, event, Some(observed_epoch));
}

/// Enqueue one lane-3 addressed event on exactly this scene's inbox and
/// advance this scene's revision so only its clients re-poll. The scene
/// passed here must be the operation's initiating scene; broadcasts go
/// through `broadcast_event` instead.
pub(crate) fn push_operation_event(scene: &Scene, event: WorkspaceEvent) {
    let (undeliverable, dropped) = {
        let mut events = scene
            .operation_events
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // The closed check happens under the inbox lock, the same lock the
        // close path drains under, so an event is either cancelled here or
        // enqueued before the drain and cancelled there — a request
        // addressed to a scene that died before delivery is never silently
        // dropped.
        if scene.closed.load(Ordering::Acquire) {
            (Some(event), None)
        } else {
            let dropped = if events.len() >= SCENE_INBOX_LIMIT {
                // Shed the oldest sheddable entry; terminal-originated entries
                // are lossless and skipped. When every queued entry is
                // terminal-originated the push proceeds without eviction — the
                // pump's headroom check keeps that excess transient and small.
                events
                    .iter()
                    .position(|queued| queued.sheddable)
                    .and_then(|index| events.remove(index))
            } else {
                None
            };
            events.push_back(InboxEvent {
                event,
                sheddable: true,
            });
            (None, dropped)
        }
    };
    if let Some(event) = undeliverable {
        cancel_closed_event(scene, event);
        return;
    }
    if let Some(dropped) = dropped {
        cancel_dropped_event(scene, dropped.event);
    }
    bump_scene_revision(scene);
}

/// Enqueue one never-lose event. These entries are never shed, because the
/// receiving client cannot recover them any other way. Two producers exist,
/// each with bounded growth:
///
/// - The pump's terminal-originated events: bounded by the per-scene
///   headroom check — the pump refuses to poll a scene's workers without
///   inbox room for a full pass.
/// - KWT operation settlements (`KwtWorktreeRemoved`,
///   `KwtProjectMutationFinished`/`Failed`, `KwtWorktreeOperationFailed`):
///   the initiating scene's dialog blocks on exactly one of these, so
///   losing one wedges the dialog. Growth is structurally bounded: the
///   runtime serializes KWT mutations behind `kwt_mutation_in_flight` and
///   worktree listings behind the single `kwt_worktree_listing` slot, and a
///   scene's dialog blocks further submissions until the outcome drains, so
///   at most one mutation settlement and one listing settlement can be
///   pending per scene at a time. The dialog-arming and dialog-closing
///   events (`KwtWorktreeRemovalReady`, `KwtWorktreeCreationPending` and
///   `Expired`, and the owning scene's `KwtWorktreeCreated` copy) obey the
///   same shape: each scene has at most one `NewWorktree` and one
///   `RemoveWorktree` flow at a time, so at most one create settlement and
///   one removal-capture settlement can be pending per scene.
pub(crate) fn push_lossless_event(scene: &Scene, event: WorkspaceEvent) {
    push_lossless_gated(scene, event, None);
}

/// Shared lossless push. With an epoch gate, the event is dropped when the
/// scene's clipboard epoch moved since the gate was captured; the
/// comparison and the insertion happen under the same inbox lock the purge
/// advances the epoch under, so no interleaving lets a stale write survive.
fn push_lossless_gated(scene: &Scene, event: WorkspaceEvent, epoch_gate: Option<u64>) {
    let undeliverable = {
        let mut events = scene
            .operation_events
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // Checked under the inbox lock for the same reason as
        // `push_operation_event`: an event either cancels here or lands
        // before the close path's drain and cancels there.
        if scene.closed.load(Ordering::Acquire) {
            Some(event)
        } else if epoch_gate
            .is_some_and(|observed| scene.clipboard_epoch.load(Ordering::Acquire) != observed)
        {
            return;
        } else {
            events.push_back(InboxEvent {
                event,
                sheddable: false,
            });
            None
        }
    };
    match undeliverable {
        // A closed scene has no dialog left to settle: capability-bearing
        // requests are cancelled, settlements are dropped with the scene.
        Some(event) => cancel_closed_event(scene, event),
        None => bump_scene_revision(scene),
    }
}

/// A full inbox sheds its oldest entry, but an addressed request is
/// cancelled — its capability observes the cancellation — never silently
/// discarded. Broadcast facts and capability-free notifications drop as
/// before.
fn cancel_dropped_event(scene: &Scene, event: WorkspaceEvent) {
    match event {
        WorkspaceEvent::SshPrompt(request) => request.respond(None),
        // The withheld paste is denied with its dialog request. The owning
        // worker suspended command intake awaiting the verdict, so the deny
        // must reach the worker or the terminal freezes with no dialog left
        // to answer it.
        WorkspaceEvent::ConfirmPaste => cancel_pending_paste(scene),
        // Dropping a clipboard read is its deny path: nothing blocks on the
        // response and the unanswered terminal query expires upstream.
        WorkspaceEvent::ClipboardRead(_)
        | WorkspaceEvent::ClipboardWrite { .. }
        | WorkspaceEvent::SshPromptDismissed { .. }
        | WorkspaceEvent::KwtBranchesLoaded { .. }
        | WorkspaceEvent::KwtPullRequestsLoaded { .. }
        | WorkspaceEvent::KwtWorktreeCreated { .. }
        | WorkspaceEvent::Error(_) => {}
        // Dialog-settling events travel the lossless lane and are never
        // enqueued as sheddable entries, so overflow cannot hand them to
        // this cancellation path. (`KwtWorktreeCreated` above is the one
        // exception: only NON-owning scenes' informational copies shed.)
        WorkspaceEvent::KwtProjectMutationFinished { .. }
        | WorkspaceEvent::KwtProjectMutationFailed { .. }
        | WorkspaceEvent::KwtWorktreeRemovalReady { .. }
        | WorkspaceEvent::KwtWorktreeRemoved { .. }
        | WorkspaceEvent::KwtWorktreeCreationPending { .. }
        | WorkspaceEvent::KwtWorktreeCreationExpired { .. }
        | WorkspaceEvent::KwtWorktreeOperationFailed { .. } => {
            debug_assert!(false, "a lossless-lane settlement cannot be shed");
        }
    }
}

/// Cancel one event that can no longer be delivered because its scene
/// closed. Addressed requests observe the cancellation through the same
/// paths a shed entry uses — the prompt capability answers `None`, the
/// withheld paste is denied at the worker — so their blocked initiators
/// fail closed instead of hanging. Everything else, lossless dialog
/// settlements included, is dropped: the dialog they would settle died
/// with the scene, and broadcast copies were informational.
fn cancel_closed_event(scene: &Scene, event: WorkspaceEvent) {
    match event {
        WorkspaceEvent::SshPrompt(request) => request.respond(None),
        WorkspaceEvent::ConfirmPaste => cancel_pending_paste(scene),
        _ => {}
    }
}

/// Clone one lane-2 fact into every live scene's inbox, delivering the
/// owning scene's copy losslessly: that copy settles the initiator's
/// blocked dialog, while other scenes' copies are informational and may
/// shed.
pub(crate) fn broadcast_event_with_lossless_owner(
    runtime: &Runtime,
    owner: SceneId,
    event: impl Fn() -> WorkspaceEvent,
) {
    for scene in &live_scenes(runtime) {
        if scene.id == owner {
            push_lossless_event(scene, event());
        } else {
            push_operation_event(scene, event());
        }
    }
}

/// Deliver one dialog-settling event losslessly to the owning scene. A
/// scene that no longer exists has no dialog to settle; the event is
/// dropped fail-closed.
pub(crate) fn push_lossless_to_scene(runtime: &Runtime, owner: SceneId, event: WorkspaceEvent) {
    if let Some(scene) = live_scenes(runtime).iter().find(|scene| scene.id == owner) {
        push_lossless_event(scene, event);
    }
}

/// Clone one lane-2 broadcast fact into every live scene's inbox. Each
/// receiving scene's revision advances as it enqueues; delivery to one
/// scene never consumes the notification for another.
pub(crate) fn broadcast_event(runtime: &Runtime, event: impl Fn() -> WorkspaceEvent) {
    for scene in &live_scenes(runtime) {
        push_operation_event(scene, event());
    }
}

pub(crate) fn start_kwt_refresh(scene: &Arc<Scene>, supersede: bool) -> bool {
    let Some(refresh) = reserve_kwt_refresh(scene, supersede) else {
        return false;
    };
    let KwtRefresh {
        host,
        endpoint,
        runtime,
        cancellation,
        generation,
    } = refresh;

    let deadline_scene = Arc::clone(scene);
    let deadline_cancellation = cancellation.clone();
    let deadline_endpoint = endpoint.clone();
    let deadline_runtime = runtime.clone();
    if let Err(error) = scene.runtime.refresh_runtime.spawn_after(
        "ghosthub-kwt-refresh-deadline",
        KWT_REFRESH_BUDGET,
        deadline_cancellation.clone(),
        Box::new(move || {
            deadline_cancellation.cancel();
            publish_kwt_error(
                &deadline_scene,
                generation,
                &deadline_endpoint,
                &deadline_runtime,
                HostDiagnostic::new(DiagnosticKind::Timeout, "KWT inventory timed out"),
            );
        }),
    ) {
        cancellation.cancel();
        publish_kwt_error(
            scene,
            generation,
            &endpoint,
            &runtime,
            HostDiagnostic::new(
                DiagnosticKind::Transport,
                format!("schedule KWT inventory deadline: {error}"),
            ),
        );
        return false;
    }

    let task_scene = Arc::clone(scene);
    let task_cancellation = cancellation.clone();
    let task_endpoint = endpoint.clone();
    let task_runtime = runtime.clone();
    if let Err(error) = scene.runtime.refresh_runtime.spawn(
        "ghosthub-kwt-discovery",
        Box::new(move || {
            let result = host.discover_kwt(&task_endpoint, &task_runtime, &task_cancellation);
            if task_cancellation.is_cancelled() {
                return;
            }
            match result {
                Ok(Some(inventory)) => {
                    publish_kwt_inventory(
                        &task_scene,
                        generation,
                        &task_endpoint,
                        &task_runtime,
                        &inventory,
                    );
                }
                Ok(None) => {
                    publish_kwt_unavailable(&task_scene, generation, &task_endpoint, &task_runtime);
                }
                Err(error) => publish_kwt_error(
                    &task_scene,
                    generation,
                    &task_endpoint,
                    &task_runtime,
                    HostDiagnostic::new(error.kind(), error.to_string()),
                ),
            }
            task_cancellation.cancel();
        }),
    ) {
        cancellation.cancel();
        publish_kwt_error(
            scene,
            generation,
            &endpoint,
            &runtime,
            HostDiagnostic::new(
                DiagnosticKind::Transport,
                format!("start KWT inventory task: {error}"),
            ),
        );
        return false;
    }
    true
}

pub(crate) fn publish_kwt_inventory(
    scene: &Scene,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    inventory: &KwtInventory,
) -> bool {
    let published = publish_kwt(scene, generation, endpoint, runtime, |host| {
        let session_names = host
            .sessions
            .iter()
            .map(|session| session.name.as_str())
            .collect::<std::collections::HashSet<_>>();
        host.projects = inventory
            .projects()
            .iter()
            .map(|project| {
                ProjectItem::new(
                    project.project().repository(),
                    project.project().name(),
                    project.project().path(),
                    project.project().registration_fingerprint(),
                    project
                        .worktrees()
                        .iter()
                        .map(|worktree| {
                            let available = worktree.tmux_attach_mode()
                                == KwtTmuxAttachMode::Direct
                                && worktree.tmux_socket_name().is_none()
                                && session_names.contains(worktree.session_name());
                            WorktreeItem::new(
                                worktree.path(),
                                worktree.branch(),
                                worktree.is_main(),
                                worktree.generation().map(str::to_owned),
                                worktree.session_name(),
                                crate::KwtTmuxEndpoint::new(
                                    worktree.tmux_socket_name().map(str::to_owned),
                                    worktree.tmux_attach_mode(),
                                ),
                                available,
                            )
                        })
                        .collect(),
                )
            })
            .collect();
        host.directory_workspaces = inventory
            .directory_workspaces()
            .iter()
            .map(|workspace| {
                DirectoryWorkspaceItem::new(
                    workspace.name(),
                    workspace.path(),
                    workspace.session_name(),
                    workspace.tmux_socket_name().map(str::to_owned),
                    workspace.tmux_attach_mode(),
                    workspace.session_live(),
                )
            })
            .collect();
        host.kwt_state = KwtState::Ready;
        host.kwt_diagnostic = None;
    });
    if published {
        resolve_pending_kwt_creations(scene, endpoint, inventory);
    }
    published
}

pub(crate) fn publish_kwt_error(
    scene: &Scene,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    diagnostic: HostDiagnostic,
) {
    publish_kwt(scene, generation, endpoint, runtime, |host| {
        host.kwt_state = if host.kwt_available() {
            KwtState::Ready
        } else {
            KwtState::Unavailable
        };
        host.kwt_diagnostic = Some(diagnostic);
    });
}

pub(crate) fn publish_kwt_unavailable(
    scene: &Scene,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
) {
    publish_kwt(scene, generation, endpoint, runtime, |host| {
        host.projects.clear();
        host.directory_workspaces.clear();
        host.kwt_state = KwtState::Unavailable;
        host.kwt_diagnostic = None;
    });
}

pub(crate) fn publish_kwt(
    scene: &Scene,
    generation: u64,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    publish: impl FnOnce(&mut HostItem),
) -> bool {
    let _publication = scene
        .runtime
        .kwt_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.runtime.kwt_refresh_generation.load(Ordering::Acquire) != generation {
        return false;
    }
    let current_matches = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|published| {
            published.value.snapshot.endpoint() == endpoint
                && published.value.snapshot.runtime() == runtime
        });
    if !current_matches {
        return false;
    }
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    if let Some(host) = scene
        .runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter_mut()
        .find(|host| host.id == "wsl" && host.endpoint == endpoint.distro())
    {
        publish(host);
        scene.runtime.revision.fetch_add(1, Ordering::Release);
        true
    } else {
        false
    }
}

pub(crate) fn expire_refresh(
    scene: &Scene,
    generation: u64,
    cancellation: &CancellationToken,
) -> bool {
    publish_refresh(&scene.runtime, generation, || {
        if scene.runtime.refresh_finished.load(Ordering::Acquire) == generation {
            return;
        }
        cancellation.cancel();
        scene
            .runtime
            .refresh_finished
            .store(generation, Ordering::Release);
        set_wsl_host_unavailable(
            &scene.runtime,
            DiagnosticKind::Timeout,
            format!(
                "WSL host refresh timed out after {} seconds",
                refresh_budget(generation).as_secs()
            ),
        );
    }) && cancellation.is_cancelled()
}

pub(crate) fn fail_refresh_start(
    scene: &Scene,
    generation: u64,
    cancellation: &CancellationToken,
    context: &str,
    error: &std::io::Error,
) {
    cancellation.cancel();
    publish_refresh(&scene.runtime, generation, || {
        scene
            .runtime
            .refresh_finished
            .store(generation, Ordering::Release);
        set_wsl_host_unavailable(
            &scene.runtime,
            DiagnosticKind::Transport,
            format!("{context}: {error}"),
        );
    });
}

pub(crate) fn run_create(
    scene: &Scene,
    request: &CreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(inventory_publication) =
        reserve_current_constructive_inventory(scene, navigation_generation, cancellation)
    else {
        return;
    };
    let created = create_fresh(scene, request, navigation_generation, cancellation);
    let (worker, snapshot, session, initial_geometry, term) = match created {
        Ok(created) => created,
        Err(error) => {
            settle_constructive_inventory(scene, inventory_publication);
            restore_inventory_after_creation_failure(
                scene,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        settle_constructive_inventory(scene, inventory_publication);
        drop(worker);
        return;
    }

    let inventory_generation =
        match merge_created_inventory(scene, request, snapshot.clone(), inventory_publication) {
            Ok(generation) => generation,
            Err(error) => {
                settle_constructive_inventory(scene, inventory_publication);
                drop(worker);
                restore_inventory_after_creation_failure(
                    scene,
                    None,
                    navigation_generation,
                    error.to_string(),
                );
                return;
            }
        };
    let attached = AttachRequest {
        host_id: request.host_id.clone(),
        host: request.host.clone(),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Tmux(session.identity().clone()),
        name: session.name().to_owned(),
        inventory_generation,
    };
    publish_created_presentation(
        scene,
        attached,
        worker,
        initial_geometry,
        term,
        navigation_generation,
    );
}

pub(crate) fn remote_attachment_is_current(
    scene: &Scene,
    host_id: &str,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> bool {
    !cancellation.is_cancelled()
        && scene.navigation_generation.load(Ordering::Acquire) == navigation_generation
        && scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(host_id)
            .is_some_and(|entry| {
                entry.attachment_attempts.iter().any(|attempt| {
                    attempt.navigation_generation == navigation_generation
                        && !attempt.cancellation.is_cancelled()
                })
            })
}

pub(crate) fn with_current_remote_attachment_launch<'scene, T>(
    scene: &'scene Scene,
    host_id: &str,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launch: impl FnOnce() -> Result<T, WorkspaceError>,
) -> Result<(NavigationFence<'scene>, T), WorkspaceError> {
    // The live fence, not the raw mutex: a task parked here while the
    // scene closed must fail on wake instead of launching into the window
    // before release_scene advances generations and cancels requests. The
    // fence is returned so the caller holds it through resize and
    // publication — the launched worker is never left unregistered and
    // unretireable in a close/navigation gap.
    let navigation = lock_live_navigation(scene)?;
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new("remote attachment was superseded"));
    }
    {
        let entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let current = entries.get(host_id).is_some_and(|entry| {
            entry.attachment_attempts.iter().any(|attempt| {
                attempt.navigation_generation == navigation_generation
                    && !attempt.cancellation.is_cancelled()
            })
        });
        if cancellation.is_cancelled() || !current {
            return Err(WorkspaceError::new("remote attachment was superseded"));
        }
    }
    let value = launch()?;
    Ok((navigation, value))
}

pub(crate) fn with_current_remote_constructive_launch<T>(
    scene: &Scene,
    request_host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launch: impl FnOnce() -> Result<T, WorkspaceError>,
) -> Result<T, WorkspaceError> {
    // Same live fence as the attach launch boundary: closure observed on
    // wake fails the launch before creation authority is consumed.
    let _navigation = lock_live_navigation(scene)?;
    if cancellation.is_cancelled()
        || scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
    {
        return Err(WorkspaceError::new(
            "remote session creation was superseded",
        ));
    }
    with_current_remote_constructive(
        &scene.runtime,
        request_host_id,
        connection_generation,
        expected,
        cancellation,
        launch,
    )
}

pub(crate) fn run_remote_tmux_attach(
    scene: &Scene,
    request: &RemoteTmuxAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _reset = RemoteAttachmentReset {
        scene,
        host_id: &request.host_id,
        navigation_generation,
    };
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !remote_attachment_is_current(scene, &request.host_id, navigation_generation, cancellation) {
        return;
    }
    let result =
        recapture_remote_tmux_attach_request(&scene.runtime, request).and_then(|request| {
            prepare_remote_tmux_attachment(scene, &request, navigation_generation, cancellation)
                .and_then(|(navigation, worker, term, identity_mismatch_marker)| {
                    // The launch fence rides into publication: the same
                    // guard that authorized the spawn covers the publish, so
                    // a close cannot strand the worker unregistered.
                    let key = RemotePresentationKey {
                        host_id: request.host_id.clone(),
                        endpoint: request.snapshot.endpoint().to_owned(),
                        route_identity: request.snapshot.route_identity().to_owned(),
                        lease_generation: request.snapshot.lease_generation(),
                        session_identity: RemoteSessionIdentity::Tmux(
                            request.session.identity().clone(),
                        ),
                    };
                    let published = publish_remote_worker(
                        scene,
                        worker,
                        key,
                        &request.selection,
                        request.snapshot.lease().clone(),
                        next_presentation_id(&scene.runtime),
                        term,
                        Some(identity_mismatch_marker),
                        Some(&RemotePublicationFence {
                            host_id: &request.host_id,
                            connection_generation: request.connection_generation,
                            snapshot: &request.snapshot,
                            cancellation,
                        }),
                    )
                    .map_err(|error| error.error);
                    drop(navigation);
                    published?;
                    Ok(())
                })
        });
    if let Err(error) = result
        && remote_attachment_is_current(
            scene,
            &request.host_id,
            navigation_generation,
            cancellation,
        )
    {
        push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
    }
}

pub(crate) fn prepare_remote_tmux_attachment<'scene>(
    scene: &'scene Scene,
    request: &RemoteTmuxAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<(NavigationFence<'scene>, TerminalWorker, AttachTerm, String), WorkspaceError> {
    let term = request
        .host
        .probe_terminal_term(&request.snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let (plan, identity_mismatch_marker) = request
        .host
        .attach_plan(&request.snapshot, &request.session, term.as_str())
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (navigation, worker) = with_current_remote_attachment_launch(
        scene,
        &request.host_id,
        navigation_generation,
        cancellation,
        || {
            TerminalWorker::attach_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
                current_default_colors(&scene.runtime),
                current_default_cursor_shape(&scene.runtime),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    )?;
    Ok((navigation, worker, term, identity_mismatch_marker))
}

pub(crate) fn run_remote_herdr_attach(
    scene: &Scene,
    request: &RemoteHerdrAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _reset = RemoteAttachmentReset {
        scene,
        host_id: &request.host_id,
        navigation_generation,
    };
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !remote_attachment_is_current(scene, &request.host_id, navigation_generation, cancellation) {
        return;
    }
    let result =
        recapture_remote_herdr_attach_request(&scene.runtime, request).and_then(|request| {
            prepare_remote_herdr_attachment(scene, &request, navigation_generation, cancellation)
                .and_then(|(navigation, worker, snapshot, session, geometry, term)| {
                    // The launch fence rides into resize and publication, so
                    // a close cannot strand the worker unregistered.
                    if let Err(error) = worker.resize_with_metadata(
                        geometry.grid,
                        geometry.sequence,
                        geometry.pixels,
                    ) {
                        return Err(WorkspaceError::from_worker(&error));
                    }
                    let key = RemotePresentationKey {
                        host_id: request.host_id.clone(),
                        endpoint: snapshot.endpoint().to_owned(),
                        route_identity: snapshot.route_identity().to_owned(),
                        lease_generation: snapshot.lease_generation(),
                        session_identity: RemoteSessionIdentity::Herdr {
                            name: session.name().to_owned(),
                            is_default: session.is_default(),
                            session_directory: session.session_directory().to_owned(),
                            socket_path: session.socket_path().to_owned(),
                        },
                    };
                    let published = publish_remote_worker(
                        scene,
                        worker,
                        key,
                        &request.selection,
                        snapshot.lease().clone(),
                        next_presentation_id(&scene.runtime),
                        term,
                        None,
                        Some(&RemotePublicationFence {
                            host_id: &request.host_id,
                            connection_generation: request.connection_generation,
                            snapshot: &snapshot,
                            cancellation,
                        }),
                    )
                    .map_err(|error| error.error);
                    drop(navigation);
                    published?;
                    Ok(())
                })
        });
    if let Err(error) = result
        && remote_attachment_is_current(
            scene,
            &request.host_id,
            navigation_generation,
            cancellation,
        )
    {
        push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
    }
}

pub(crate) fn prepare_remote_herdr_attachment<'scene>(
    scene: &'scene Scene,
    request: &RemoteHerdrAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        NavigationFence<'scene>,
        TerminalWorker,
        RemoteTmuxSnapshot,
        session::HerdrSessionRecord,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let inventory = request
        .host
        .refresh(request.snapshot.lease(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new(
            "remote Herdr attachment was superseded",
        ));
    }
    let snapshot = publish_remote_inventory(
        scene,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
        cancellation,
        inventory,
    )?;
    let (executable, session) = resolve_remote_herdr_attach_target(
        snapshot.herdr(),
        &request.executable,
        &request.session,
    )?;
    let term = request
        .host
        .probe_terminal_term(&snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let plan = request
        .host
        .herdr_attach_plan(&snapshot, &executable, &session, term.as_str())
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (navigation, worker) = with_current_remote_attachment_launch(
        scene,
        &request.host_id,
        navigation_generation,
        cancellation,
        || {
            TerminalWorker::attach_herdr_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
                current_default_colors(&scene.runtime),
                current_default_cursor_shape(&scene.runtime),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    )?;
    Ok((navigation, worker, snapshot, session, geometry, term))
}

pub(crate) fn run_remote_zellij_attach(
    scene: &Scene,
    request: &RemoteZellijAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _reset = RemoteAttachmentReset {
        scene,
        host_id: &request.host_id,
        navigation_generation,
    };
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !remote_attachment_is_current(scene, &request.host_id, navigation_generation, cancellation) {
        return;
    }
    let result =
        recapture_remote_zellij_attach_request(&scene.runtime, request).and_then(|request| {
            prepare_remote_zellij_attachment(scene, &request, navigation_generation, cancellation)
                .and_then(|(navigation, worker, snapshot, session, geometry, term)| {
                    // The launch fence rides into resize and publication, so
                    // a close cannot strand the worker unregistered.
                    if let Err(error) = worker.resize_with_metadata(
                        geometry.grid,
                        geometry.sequence,
                        geometry.pixels,
                    ) {
                        return Err(WorkspaceError::from_worker(&error));
                    }
                    let key = RemotePresentationKey {
                        host_id: request.host_id.clone(),
                        endpoint: snapshot.endpoint().to_owned(),
                        route_identity: snapshot.route_identity().to_owned(),
                        lease_generation: snapshot.lease_generation(),
                        session_identity: RemoteSessionIdentity::Zellij(session.name().to_owned()),
                    };
                    let published = publish_remote_worker(
                        scene,
                        worker,
                        key,
                        &request.selection,
                        snapshot.lease().clone(),
                        next_presentation_id(&scene.runtime),
                        term,
                        None,
                        Some(&RemotePublicationFence {
                            host_id: &request.host_id,
                            connection_generation: request.connection_generation,
                            snapshot: &snapshot,
                            cancellation,
                        }),
                    )
                    .map_err(|error| error.error);
                    drop(navigation);
                    published?;
                    Ok(())
                })
        });
    if let Err(error) = result
        && remote_attachment_is_current(
            scene,
            &request.host_id,
            navigation_generation,
            cancellation,
        )
    {
        push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
    }
}

pub(crate) fn prepare_remote_zellij_attachment<'scene>(
    scene: &'scene Scene,
    request: &RemoteZellijAttachRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        NavigationFence<'scene>,
        TerminalWorker,
        RemoteTmuxSnapshot,
        session::ZellijSessionRecord,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let inventory = request
        .host
        .refresh(request.snapshot.lease(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new(
            "remote Zellij attachment was superseded",
        ));
    }
    let snapshot = publish_remote_inventory(
        scene,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
        cancellation,
        inventory,
    )?;
    let (executable, session) =
        resolve_remote_zellij_attach_target(snapshot.zellij(), &request.executable, &request.name)?;
    let term = request
        .host
        .probe_terminal_term(&snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let plan = request
        .host
        .zellij_attach_plan(&snapshot, &executable, &session, term.as_str())
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (navigation, worker) = with_current_remote_attachment_launch(
        scene,
        &request.host_id,
        navigation_generation,
        cancellation,
        || {
            TerminalWorker::attach_zellij_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
                current_default_colors(&scene.runtime),
                current_default_cursor_shape(&scene.runtime),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    )?;
    Ok((navigation, worker, snapshot, session, geometry, term))
}

#[allow(
    clippy::too_many_lines,
    reason = "the runtime/scene split lengthens shared-state paths without adding logic"
)]
pub(crate) fn run_remote_herdr_create(
    scene: &Scene,
    request: &RemoteHerdrCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launched: &AtomicBool,
) {
    let _reset = RemoteConstructiveReset {
        scene,
        host_id: &request.host_id,
        navigation_generation,
    };
    let Some(operation) = lock_session_operations(scene, cancellation) else {
        return;
    };
    // Another scene's operation may have published newer same-connection
    // inventory while this construction waited for the operation lane.
    // Recapture the latest snapshot and revalidate the target so the
    // unchanged connection does not read as stale at the launch fence;
    // connection-generation checks are unchanged.
    let recaptured = match recapture_remote_herdr_create_request(&scene.runtime, request) {
        Ok(recaptured) => recaptured,
        Err(error) => {
            if scene.navigation_generation.load(Ordering::Acquire) == navigation_generation
                && remote_constructive_is_current(&scene.runtime, &request.host_id, cancellation)
            {
                push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
            }
            set_remote_herdr_launch_pending(
                &scene.runtime,
                &request.host_id,
                request.name.as_str(),
                false,
            );
            drop(operation);
            return;
        }
    };
    let request = &recaptured;
    let result = create_remote_herdr_fresh(
        scene,
        request,
        navigation_generation,
        cancellation,
        launched,
    )
    .and_then(|(worker, inventory, session, geometry, term)| {
        let snapshot = publish_remote_inventory(
            scene,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            cancellation,
            inventory,
        )?;
        if let Err(error) =
            worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
        {
            return Err(WorkspaceError::from_worker(&error));
        }
        let navigation = scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            drop(worker);
            drop(navigation);
            return Ok(());
        }
        let selection =
            SessionSelection::herdr(&request.host_id, snapshot.endpoint(), session.name());
        let key = RemotePresentationKey {
            host_id: request.host_id.clone(),
            endpoint: snapshot.endpoint().to_owned(),
            route_identity: snapshot.route_identity().to_owned(),
            lease_generation: snapshot.lease_generation(),
            session_identity: RemoteSessionIdentity::Herdr {
                name: session.name().to_owned(),
                is_default: session.is_default(),
                session_directory: session.session_directory().to_owned(),
                socket_path: session.socket_path().to_owned(),
            },
        };
        let published = publish_remote_worker(
            scene,
            worker,
            key,
            &selection,
            snapshot.lease().clone(),
            next_presentation_id(&scene.runtime),
            term,
            None,
            Some(&RemotePublicationFence {
                host_id: &request.host_id,
                connection_generation: request.connection_generation,
                snapshot: &snapshot,
                cancellation,
            }),
        )
        .map_err(|error| error.error);
        drop(navigation);
        published?;
        Ok(())
    });
    if let Err(error) = &result
        && scene.navigation_generation.load(Ordering::Acquire) == navigation_generation
        && remote_constructive_is_current(&scene.runtime, &request.host_id, cancellation)
    {
        push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
    }
    set_remote_herdr_launch_pending(
        &scene.runtime,
        &request.host_id,
        request.name.as_str(),
        false,
    );
    let pending = settle_remote_constructive_task(
        &scene.runtime,
        &request.host_id,
        navigation_generation,
        result.is_ok(),
    );
    drop(operation);
    if let Some(target) = pending {
        reconcile_remote_constructive_after_connection(
            scene,
            &request.host_id,
            request.connection_generation,
            &request.host,
            request.snapshot.clone(),
            &target,
        );
    }
}

#[allow(
    clippy::too_many_lines,
    reason = "recapture, launch, publication, and settlement stay one auditable sequence"
)]
pub(crate) fn run_remote_zellij_create(
    scene: &Scene,
    request: &RemoteZellijCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launched: &AtomicBool,
) {
    let _reset = RemoteConstructiveReset {
        scene,
        host_id: &request.host_id,
        navigation_generation,
    };
    let Some(operation) = lock_session_operations(scene, cancellation) else {
        return;
    };
    // As for Herdr constructions: recapture the latest same-connection
    // snapshot after acquiring the operation lane so another scene's
    // publication does not read as staleness.
    let recaptured = match recapture_remote_zellij_create_request(&scene.runtime, request) {
        Ok(recaptured) => recaptured,
        Err(error) => {
            if scene.navigation_generation.load(Ordering::Acquire) == navigation_generation
                && remote_constructive_is_current(&scene.runtime, &request.host_id, cancellation)
            {
                push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
            }
            drop(operation);
            return;
        }
    };
    let request = &recaptured;
    let result = create_remote_zellij_fresh(
        scene,
        request,
        navigation_generation,
        cancellation,
        launched,
    )
    .and_then(|(worker, inventory, session, geometry, term)| {
        let snapshot = publish_remote_inventory(
            scene,
            &request.host_id,
            request.connection_generation,
            &request.snapshot,
            cancellation,
            inventory,
        )?;
        if let Err(error) =
            worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
        {
            return Err(WorkspaceError::from_worker(&error));
        }
        let navigation = scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            drop(worker);
            drop(navigation);
            return Ok(());
        }
        let selection =
            SessionSelection::zellij(&request.host_id, snapshot.endpoint(), session.name());
        let key = RemotePresentationKey {
            host_id: request.host_id.clone(),
            endpoint: snapshot.endpoint().to_owned(),
            route_identity: snapshot.route_identity().to_owned(),
            lease_generation: snapshot.lease_generation(),
            session_identity: RemoteSessionIdentity::Zellij(session.name().to_owned()),
        };
        let published = publish_remote_worker(
            scene,
            worker,
            key,
            &selection,
            snapshot.lease().clone(),
            next_presentation_id(&scene.runtime),
            term,
            None,
            Some(&RemotePublicationFence {
                host_id: &request.host_id,
                connection_generation: request.connection_generation,
                snapshot: &snapshot,
                cancellation,
            }),
        )
        .map_err(|error| error.error);
        drop(navigation);
        published?;
        Ok(())
    });
    if let Err(error) = &result
        && scene.navigation_generation.load(Ordering::Acquire) == navigation_generation
        && remote_constructive_is_current(&scene.runtime, &request.host_id, cancellation)
    {
        push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
    }
    let pending = settle_remote_constructive_task(
        &scene.runtime,
        &request.host_id,
        navigation_generation,
        result.is_ok(),
    );
    drop(operation);
    if let Some(target) = pending {
        reconcile_remote_constructive_after_connection(
            scene,
            &request.host_id,
            request.connection_generation,
            &request.host,
            request.snapshot.clone(),
            &target,
        );
    }
}

pub(crate) fn create_remote_herdr_fresh(
    scene: &Scene,
    request: &RemoteHerdrCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launched: &AtomicBool,
) -> Result<
    (
        TerminalWorker,
        RemoteSessionInventory,
        session::HerdrSessionRecord,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .refresh(request.snapshot.lease(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let HerdrInventory::Available {
        executable,
        sessions,
    } = before.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    if executable != &request.executable {
        return Err(WorkspaceError::new(
            "the remote Herdr executable changed; refresh before creating the session",
        ));
    }
    let current = sessions
        .iter()
        .find(|session| session.name() == request.name.as_str());
    validate_herdr_launch_precondition(&request.precondition, current)?;
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new("remote Herdr creation was superseded"));
    }
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let term = request
        .host
        .probe_terminal_term(&request.snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let worker = with_current_remote_constructive_launch(
        scene,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
        navigation_generation,
        cancellation,
        || {
            let authority = request
                .host
                .herdr_launch_once(
                    &request.snapshot,
                    &request.executable,
                    request.name.clone(),
                    request.precondition.is_default(),
                    term.as_str(),
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            // Constructing the worker consumes the one-shot launch authority
            // even when PTY or containment setup subsequently fails.
            launched.store(true, Ordering::Release);
            let worker = TerminalWorker::launch_herdr_with_metadata(
                authority,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
                current_default_colors(&scene.runtime),
                current_default_cursor_shape(&scene.runtime),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
            Ok(worker)
        },
    )?;
    let expected_name = request.name.as_str();
    let discovered = poll_session_startup("Herdr", cancellation, &HERDR_STARTUP_BACKOFF, || {
        // Launch authority has already been consumed. Navigation may suppress
        // presentation, but inventory must still converge on the mutation.
        let inventory = request
            .host
            .refresh(request.snapshot.lease(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let session = match inventory.herdr() {
            HerdrInventory::Available {
                executable,
                sessions,
            } if executable == &request.executable => sessions
                .iter()
                .find(|session| {
                    herdr_launch_result_matches(&request.precondition, expected_name, session)
                })
                .cloned(),
            _ => None,
        };
        Ok(session.map(|session| (inventory, session)))
    })?;
    if let Some((inventory, session)) = discovered {
        Ok((worker, inventory, session, geometry, term))
    } else {
        drop(worker);
        Err(WorkspaceError::new(
            "Herdr started, but the remote session did not appear in inventory; refresh before trying again",
        ))
    }
}

pub(crate) fn create_remote_zellij_fresh(
    scene: &Scene,
    request: &RemoteZellijCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    launched: &AtomicBool,
) -> Result<
    (
        TerminalWorker,
        RemoteSessionInventory,
        session::ZellijSessionRecord,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .refresh(request.snapshot.lease(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let ZellijInventory::Available {
        executable,
        sessions,
    } = before.zellij()
    else {
        return Err(WorkspaceError::new(
            "Zellij is not available on this SSH host",
        ));
    };
    if executable != &request.executable {
        return Err(WorkspaceError::new(
            "the remote Zellij executable changed; refresh before creating the session",
        ));
    }
    if sessions
        .iter()
        .any(|session| session.name() == request.name.as_str())
    {
        return Err(WorkspaceError::new(
            "a Zellij session with this name already exists",
        ));
    }
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return Err(WorkspaceError::new("remote Zellij creation was superseded"));
    }
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let term = request
        .host
        .probe_terminal_term(&request.snapshot, cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    let worker = with_current_remote_constructive_launch(
        scene,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
        navigation_generation,
        cancellation,
        || {
            let authority = request
                .host
                .zellij_launch_once(
                    &request.snapshot,
                    &request.executable,
                    request.name.clone(),
                    term.as_str(),
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
            // Constructing the worker consumes the one-shot launch authority
            // even when PTY or containment setup subsequently fails.
            launched.store(true, Ordering::Release);
            let worker = TerminalWorker::launch_zellij_with_metadata(
                authority,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
                current_default_colors(&scene.runtime),
                current_default_cursor_shape(&scene.runtime),
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
            Ok(worker)
        },
    )?;
    let expected_name = request.name.as_str();
    let discovered = poll_session_startup("Zellij", cancellation, &HERDR_STARTUP_BACKOFF, || {
        // Launch authority has already been consumed. Navigation may suppress
        // presentation, but inventory must still converge on the mutation.
        let inventory = request
            .host
            .refresh(request.snapshot.lease(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let session = match inventory.zellij() {
            ZellijInventory::Available {
                executable,
                sessions,
            } if executable == &request.executable => sessions
                .iter()
                .find(|session| session.name() == expected_name)
                .cloned(),
            _ => None,
        };
        Ok(session.map(|session| (inventory, session)))
    })?;
    if let Some((inventory, session)) = discovered {
        Ok((worker, inventory, session, geometry, term))
    } else {
        drop(worker);
        Err(WorkspaceError::new(
            "Zellij started, but the remote session did not appear in inventory; refresh before trying again",
        ))
    }
}

pub(crate) fn publish_remote_inventory(
    scene: &Scene,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    cancellation: &CancellationToken,
    inventory: RemoteSessionInventory,
) -> Result<RemoteTmuxSnapshot, WorkspaceError> {
    let _publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let snapshot_write = begin_snapshot_write(&scene.runtime);
    let mut entries = scene
        .runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get_mut(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected during the operation"))?;
    let fence = RemotePublicationFence {
        host_id,
        connection_generation,
        snapshot: expected,
        cancellation,
    };
    validate_remote_publication_fence(entry, &fence)?;
    let context = entry
        .context
        .as_mut()
        .expect("the publication fence requires a remote context");
    let snapshot = expected.with_inventory(inventory);
    context.snapshot = snapshot.clone();
    drop(entries);
    let stale_presentations = reconcile_remote_presentations(
        &scene.runtime,
        host_id,
        snapshot.endpoint(),
        snapshot.route_identity(),
        snapshot.lease_generation(),
        Some(RemoteInventory::from(&snapshot)),
    );
    set_remote_host_snapshot(&scene.runtime, host_id, &snapshot);
    drop(snapshot_write);
    drop(stale_presentations);
    Ok(snapshot)
}

pub(crate) fn run_herdr_create(
    scene: &Scene,
    request: &HerdrCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(inventory_publication) =
        reserve_current_constructive_inventory(scene, navigation_generation, cancellation)
    else {
        return;
    };
    let created = create_herdr_fresh(scene, request, navigation_generation, cancellation);
    let (worker, snapshot, session, initial_geometry) = match created {
        Ok(created) => created,
        Err(error) => {
            settle_constructive_inventory(scene, inventory_publication);
            restore_inventory_after_creation_failure(
                scene,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        settle_constructive_inventory(scene, inventory_publication);
        drop(worker);
        return;
    }
    let inventory_generation = match merge_herdr_created_inventory(
        scene,
        request,
        snapshot.clone(),
        inventory_publication,
    ) {
        Ok(generation) => generation,
        Err(error) => {
            settle_constructive_inventory(scene, inventory_publication);
            drop(worker);
            restore_inventory_after_creation_failure(
                scene,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    let attached = AttachRequest {
        host_id: request.host_id.clone(),
        host: request.host.clone(),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Herdr {
            executable: request.executable.clone(),
            is_default: session.is_default(),
            session_directory: session.session_directory().to_owned(),
            socket_path: session.socket_path().to_owned(),
        },
        name: session.name().to_owned(),
        inventory_generation,
    };
    publish_created_presentation(
        scene,
        attached,
        worker,
        initial_geometry,
        request.term,
        navigation_generation,
    );
}

pub(crate) fn run_zellij_create(
    scene: &Scene,
    request: &ZellijCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) {
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(inventory_publication) =
        reserve_current_constructive_inventory(scene, navigation_generation, cancellation)
    else {
        return;
    };
    let created = create_zellij_fresh(scene, request, navigation_generation, cancellation);
    let (worker, snapshot, session, initial_geometry) = match created {
        Ok(created) => created,
        Err(error) => {
            settle_constructive_inventory(scene, inventory_publication);
            restore_inventory_after_creation_failure(
                scene,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        settle_constructive_inventory(scene, inventory_publication);
        drop(worker);
        return;
    }
    let inventory_generation = match merge_constructive_inventory(
        scene,
        &request.host,
        &request.endpoint,
        &request.runtime,
        snapshot.clone(),
        inventory_publication,
        "the created Zellij session",
    ) {
        Ok(generation) => generation,
        Err(error) => {
            settle_constructive_inventory(scene, inventory_publication);
            drop(worker);
            restore_inventory_after_creation_failure(
                scene,
                None,
                navigation_generation,
                error.to_string(),
            );
            return;
        }
    };
    let attached = AttachRequest {
        host_id: request.host_id.clone(),
        host: request.host.clone(),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Zellij {
            executable: request.executable.clone(),
            name: session.name().to_owned(),
        },
        name: session.name().to_owned(),
        inventory_generation,
    };
    publish_created_presentation(
        scene,
        attached,
        worker,
        initial_geometry,
        request.term,
        navigation_generation,
    );
}

#[allow(
    clippy::too_many_lines,
    reason = "one Herdr create: fenced commit, then startup-discovery poll"
)]
pub(crate) fn create_herdr_fresh(
    scene: &Scene,
    request: &HerdrCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        session::HerdrSessionRecord,
        TerminalGeometry,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if before.endpoint() != &request.endpoint || before.runtime() != &request.runtime {
        return Err(WorkspaceError::new(
            "WSL changed; refresh before creating the Herdr session",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = before.herdr()
    else {
        return Err(WorkspaceError::new("Herdr is not available on this host"));
    };
    if executable != &request.executable {
        return Err(WorkspaceError::new(
            "the Herdr executable changed; refresh before creating the session",
        ));
    }
    let current = sessions
        .iter()
        .find(|session| session.name() == request.name.as_str());
    validate_herdr_launch_precondition(&request.precondition, current)?;
    // Fence the commit: the liveness re-check and the launch are atomic
    // under the live-navigation lock, so a scene closed before the commit
    // never starts a Herdr session. Released before the slow startup poll
    // below so discovery never stalls closure or navigation. (navigation →
    // herdr_lifecycle is safe: herdr_lifecycle is a leaf that never
    // acquires navigation.)
    let (worker, geometry) = {
        let _navigation = lock_live_navigation(scene).map_err(|_| {
            WorkspaceError::new("the scene closed before the Herdr session was created")
        })?;
        if cancellation.is_cancelled()
            || scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
        {
            return Err(WorkspaceError::new("Herdr creation was superseded"));
        }
        with_herdr_launch_fence(
            &scene.runtime.herdr_lifecycle,
            &request.operation_key(),
            || {
                WorkspaceError::new(
                    "Herdr session lifecycle is changing; wait for inventory to refresh",
                )
            },
            || {
                let authority = request.host.herdr_launch_once(
                    before.endpoint(),
                    &request.executable,
                    request.name.clone(),
                    request.precondition.is_default(),
                    request.term,
                );
                let geometry = *scene
                    .terminal_geometry
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let worker = TerminalWorker::launch_herdr_with_metadata(
                    authority,
                    geometry.grid,
                    geometry.sequence,
                    geometry.pixels,
                    ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
                    current_default_colors(&scene.runtime),
                    current_default_cursor_shape(&scene.runtime),
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))?;
                Ok((worker, geometry))
            },
        )?
    };

    let expected_name = request.name.as_str();
    let discovered = poll_session_startup("Zellij", cancellation, &HERDR_STARTUP_BACKOFF, || {
        if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            return Err(WorkspaceError::new("Herdr creation was superseded"));
        }
        let snapshot = request
            .host
            .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        if snapshot.endpoint() != &request.endpoint || snapshot.runtime() != &request.runtime {
            return Err(WorkspaceError::new(
                "WSL changed while creating the Herdr session",
            ));
        }
        let session = match snapshot.herdr() {
            HerdrInventory::Available {
                executable,
                sessions,
            } if executable == &request.executable => sessions
                .iter()
                .find(|session| {
                    herdr_launch_result_matches(&request.precondition, expected_name, session)
                })
                .cloned(),
            _ => None,
        };
        Ok(session.map(|session| (snapshot, session)))
    })?;
    if let Some((snapshot, session)) = discovered {
        return Ok((worker, snapshot, session, geometry));
    }
    drop(worker);
    Err(WorkspaceError::new(
        "Herdr started, but the new session did not appear in inventory; refresh before trying again",
    ))
}

pub(crate) fn create_zellij_fresh(
    scene: &Scene,
    request: &ZellijCreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        session::ZellijSessionRecord,
        TerminalGeometry,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if before.endpoint() != &request.endpoint || before.runtime() != &request.runtime {
        return Err(WorkspaceError::new(
            "WSL changed; refresh before creating the Zellij session",
        ));
    }
    let ZellijInventory::Available {
        executable,
        sessions,
    } = before.zellij()
    else {
        return Err(WorkspaceError::new("Zellij is not available on this host"));
    };
    if executable != &request.executable {
        return Err(WorkspaceError::new(
            "the Zellij executable changed; refresh before creating the session",
        ));
    }
    if sessions
        .iter()
        .any(|session| session.name() == request.name.as_str())
    {
        return Err(WorkspaceError::new(
            "a Zellij session with this name already exists",
        ));
    }
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    // Fence the launch: the liveness re-check, zellij_launch_once, and the
    // session-creating launch_zellij_with_metadata launch are atomic under
    // the live-navigation lock, so a scene closed before the launch never
    // creates an orphan Zellij session. Released before the startup poll.
    let worker = {
        let _navigation = lock_live_navigation(scene).map_err(|_| {
            WorkspaceError::new("the scene closed before the Zellij session was created")
        })?;
        if cancellation.is_cancelled()
            || scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
        {
            return Err(WorkspaceError::new("Zellij creation was superseded"));
        }
        let authority = request.host.zellij_launch_once(
            before.endpoint(),
            &request.executable,
            request.name.clone(),
            request.term,
        );
        TerminalWorker::launch_zellij_with_metadata(
            authority,
            geometry.grid,
            geometry.sequence,
            geometry.pixels,
            ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
            current_default_colors(&scene.runtime),
            current_default_cursor_shape(&scene.runtime),
        )
        .map_err(|error| WorkspaceError::new(error.to_string()))?
    };

    let expected_name = request.name.as_str();
    let discovered = poll_session_startup("Herdr", cancellation, &HERDR_STARTUP_BACKOFF, || {
        if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            return Err(WorkspaceError::new("Zellij creation was superseded"));
        }
        let snapshot = request
            .host
            .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        if snapshot.endpoint() != &request.endpoint || snapshot.runtime() != &request.runtime {
            return Err(WorkspaceError::new(
                "WSL changed while creating the Zellij session",
            ));
        }
        let session = match snapshot.zellij() {
            ZellijInventory::Available {
                executable,
                sessions,
            } if executable == &request.executable => sessions
                .iter()
                .find(|session| session.name() == expected_name)
                .cloned(),
            _ => None,
        };
        Ok(session.map(|session| (snapshot, session)))
    })?;
    if let Some((snapshot, session)) = discovered {
        return Ok((worker, snapshot, session, geometry));
    }
    drop(worker);
    Err(WorkspaceError::new(
        "Zellij started, but the new session did not appear in inventory; refresh before trying again",
    ))
}

pub(crate) fn publish_created_presentation(
    scene: &Scene,
    attached: AttachRequest,
    worker: TerminalWorker,
    initial_geometry: TerminalGeometry,
    term: AttachTerm,
    navigation_generation: u64,
) {
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    let navigation = scene
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        drop(navigation);
        drop(worker);
        return;
    }
    let pending = scene
        .pending_creation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
        .filter(|pending| pending.navigation_generation == navigation_generation);
    let Some(pending) = pending else {
        drop(navigation);
        drop(worker);
        return;
    };
    let key = attached.presentation_key();
    let fallback = pending
        .previous
        .clone()
        .map(|presentation| FallbackAuthority {
            presentation,
            target: key,
            navigation_generation,
        });
    let mut attachment = scene
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(generation) =
        attachment.reserve_with_fallback(attached.clone(), term, fallback.clone())
    else {
        finish_pending_creation(&scene.runtime, &pending);
        drop(attachment);
        drop(navigation);
        drop(worker);
        restore_inventory_after_creation_failure(
            scene,
            fallback.map(|fallback| fallback.presentation),
            navigation_generation,
            "another terminal presentation replaced the creation request".to_owned(),
        );
        return;
    };
    let surface = worker.surface_handle();
    if let Err(error) = publish_worker_at_latest_geometry(
        &scene.terminal_geometry,
        &scene.worker,
        worker,
        initial_geometry,
        resize_terminal_worker,
        |worker| worker.set_default_cursor_shape(current_default_cursor_shape(&scene.runtime)),
    ) {
        attachment.clear_if_current(generation);
        finish_pending_creation(&scene.runtime, &pending);
        drop(attachment);
        drop(navigation);
        restore_inventory_after_creation_failure(
            scene,
            fallback.map(|fallback| fallback.presentation),
            navigation_generation,
            error.to_string(),
        );
        return;
    }
    set_terminal_notice(scene, term);
    set_scene_state(
        scene,
        WorkspaceContent::Terminal {
            host_id: attached.host_id,
            endpoint: attached.endpoint.distro().to_owned(),
            session: attached.name,
            kind: attached.target.kind(),
            presentation_id: next_presentation_id(&scene.runtime),
            surface,
        },
    );
    finish_pending_creation(&scene.runtime, &pending);
    drop(attachment);
    drop(navigation);
}

pub(crate) fn create_fresh(
    scene: &Scene,
    request: &CreateRequest,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        session::DiscoveredSession,
        TerminalGeometry,
        AttachTerm,
    ),
    WorkspaceError,
> {
    let before = request
        .host
        .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    if before.endpoint() != &request.endpoint {
        return Err(WorkspaceError::new(
            "the default WSL distro changed; refresh before creating the session",
        ));
    }
    if before.runtime() != &request.runtime {
        return Err(WorkspaceError::new(
            "WSL restarted; refresh before creating the session",
        ));
    }
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let launch_geometry = creation_launch_geometry(geometry);
    // Fence the launch: the liveness re-check, create_once, and the
    // session-creating create_with_metadata launch are atomic under the
    // live-navigation lock, so a scene that closed before the launch never
    // creates an orphan host-side tmux session. Released before the slow
    // creation-identity wait so it never stalls closure or navigation.
    let (worker, receipt, term) = {
        let _navigation = lock_live_navigation(scene)
            .map_err(|_| WorkspaceError::new("the scene closed before the session was created"))?;
        if cancellation.is_cancelled()
            || scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
        {
            return Err(WorkspaceError::new("tmux creation was superseded"));
        }
        let (authority, receipt, term) = request
            .host
            .create_once(before.endpoint(), before.runtime(), request.name.clone())
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        let worker = TerminalWorker::create_with_metadata(
            authority,
            launch_geometry.grid,
            launch_geometry.sequence,
            launch_geometry.pixels,
            ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
            current_default_colors(&scene.runtime),
            current_default_cursor_shape(&scene.runtime),
        )
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
        (worker, receipt, term)
    };
    let client_identity = request
        .host
        .wait_for_creation_identity(
            before.endpoint(),
            &receipt,
            cancellation,
            CREATE_IDENTITY_TIMEOUT,
        )
        .map_err(|error| WorkspaceError::new(error.to_string()))?;
    for attempt in 0..TMUX_CREATE_DISCOVERY_ATTEMPTS {
        if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
            drop(worker);
            return Err(WorkspaceError::new("tmux creation was superseded"));
        }
        let snapshot = request
            .host
            .discover_after_create(
                before.endpoint(),
                &request.runtime,
                before.creation_term(),
                before.herdr(),
                before.zellij(),
                cancellation,
            )
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        if let Some(session) = created_session(&snapshot, &client_identity) {
            return Ok((worker, snapshot, session, launch_geometry, term));
        }
        if attempt + 1 < TMUX_CREATE_DISCOVERY_ATTEMPTS {
            thread::sleep(TMUX_CREATE_DISCOVERY_DELAY);
        }
    }
    drop(worker);
    Err(WorkspaceError::new(
        "the one-shot tmux client started, but its exact session did not appear; refresh to inspect the host before trying again",
    ))
}

pub(crate) fn restore_inventory_after_creation_failure(
    scene: &Scene,
    previous: Option<PresentationKey>,
    navigation_generation: u64,
    message: String,
) {
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    let _navigation = scene
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation {
        return;
    }
    let pending = scene
        .pending_creation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
        .filter(|pending| pending.navigation_generation == navigation_generation);
    if let Some(pending) = &pending {
        pending.cancellation.cancel();
        finish_pending_creation(&scene.runtime, pending);
    }
    let previous = pending.and_then(|pending| pending.previous).or(previous);
    restore_presentation_inventory(scene);
    if let Some(previous) = previous {
        match activate_retained_presentation(scene, &previous, None) {
            Ok(true) => {}
            Ok(false) => set_local_notice(
                scene,
                "the previous terminal presentation is no longer available".to_owned(),
            ),
            Err(error) => set_local_notice(
                scene,
                format!("could not restore the previous terminal presentation: {error}"),
            ),
        }
    }
    publish_local_notice(scene, message);
}

#[allow(
    clippy::too_many_lines,
    reason = "the runtime/scene split lengthens shared-state paths without adding logic"
)]
pub(crate) fn run_attach(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    generation: u64,
) {
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !scene
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .is_current(generation)
    {
        return;
    }
    match attach_fresh(scene, request, term) {
        Ok((_navigation, worker, snapshot, attached_session, initial_geometry, attached_term)) => {
            let _snapshot_write = begin_snapshot_write(&scene.runtime);
            let mut attachment = scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !attachment.is_current(generation) {
                drop(worker);
                return;
            }
            if let Some(active) = attachment.active_mut() {
                normalize_attached_worktree_target(active, &snapshot, &attached_session);
                active.term = attached_term;
            }
            let surface = worker.surface_handle();
            let endpoint = snapshot.endpoint().distro().to_owned();
            publish_attach_inventory(scene, request, snapshot);
            let key = attachment
                .active()
                .expect("current attachment was checked")
                .request
                .presentation_key();
            let session =
                current_inventory_session_name(&scene.runtime, &key).unwrap_or(attached_session);
            if let Some(active) = attachment.active_mut() {
                session.clone_into(&mut active.request.name);
            }
            if let Err(error) = publish_worker_at_latest_geometry(
                &scene.terminal_geometry,
                &scene.worker,
                worker,
                initial_geometry,
                resize_terminal_worker,
                |worker| {
                    worker.set_default_cursor_shape(current_default_cursor_shape(&scene.runtime));
                },
            ) {
                let current_request = attachment
                    .active()
                    .expect("current attachment was checked")
                    .request
                    .clone();
                let fallback = attachment
                    .fallback_if_current(generation)
                    .filter(|fallback| fallback_owns_request(scene, fallback, &current_request));
                attachment.clear_if_current(generation);
                drop(attachment);
                publish_attachment_failure(scene, request.inventory_generation, error);
                restore_attach_fallback(scene, fallback);
                return;
            }
            set_terminal_notice(scene, attached_term);
            let presentation_id = next_presentation_id(&scene.runtime);
            set_scene_state(
                scene,
                WorkspaceContent::Terminal {
                    host_id: request.host_id.clone(),
                    endpoint,
                    session,
                    kind: request.target.kind(),
                    presentation_id,
                    surface,
                },
            );
        }
        Err(error) => {
            let _snapshot_write = begin_snapshot_write(&scene.runtime);
            let mut attachment = scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some((current_request, fallback)) =
                failed_attachment_context(scene, &attachment, generation)
            else {
                return;
            };
            attachment.clear_if_current(generation);
            drop(attachment);
            match error {
                AttachFreshError::Host(error) => {
                    publish_attachment_failure(scene, current_request.inventory_generation, error);
                }
                AttachFreshError::SessionChanged { error, snapshot } => {
                    publish_stale_attachment_failure(scene, &current_request, *snapshot, &error);
                }
                // The fenced launch refused a closed scene before spawning.
                AttachFreshError::SceneClosed => {}
            }
            restore_attach_fallback(scene, fallback);
        }
    }
}

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    reason = "remote publication keeps explicit worker, presentation, and connection authority in one atomic swap"
)]
pub(crate) fn publish_remote_worker(
    scene: &Scene,
    worker: TerminalWorker,
    key: RemotePresentationKey,
    selection: &SessionSelection,
    lease: host::SshLease,
    presentation_id: u64,
    term: AttachTerm,
    identity_mismatch_marker: Option<String>,
    fence: Option<&RemotePublicationFence<'_>>,
) -> Result<(), Box<RemotePublishError>> {
    let surface = worker.surface_handle();
    let snapshot_write = begin_snapshot_write(&scene.runtime);
    let remote_entries = if let Some(fence) = fence {
        if fence.host_id != selection.host_id() || fence.host_id != key.host_id {
            return Err(Box::new(RemotePublishError {
                error: WorkspaceError::new("the remote publication target changed"),
                worker,
            }));
        }
        let entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(entry) = entries.get(fence.host_id) else {
            return Err(Box::new(RemotePublishError {
                error: WorkspaceError::new("the SSH host disconnected during the operation"),
                worker,
            }));
        };
        if let Err(error) = validate_remote_publication_fence(entry, fence) {
            return Err(Box::new(RemotePublishError { error, worker }));
        }
        Some(entries)
    } else {
        None
    };
    let mut attachment = scene
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let geometry = scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Err(error) =
        worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
    {
        return Err(Box::new(RemotePublishError {
            error: WorkspaceError::from_worker(&error),
            worker,
        }));
    }
    let previous_presentation_id = match &*scene
        .state
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
    {
        WorkspaceContent::Terminal {
            presentation_id, ..
        } => Some(*presentation_id),
        _ => None,
    };
    let mut remote_active = scene
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut workers = scene
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(active) = remote_active.as_ref()
        && workers.generation() != active.worker_generation
    {
        return Err(Box::new(RemotePublishError {
            error: WorkspaceError::new(
                "the active remote presentation changed while switching sessions",
            ),
            worker,
        }));
    }
    if (remote_active.is_some() || attachment.active().is_some()) && workers.active().is_none() {
        return Err(Box::new(RemotePublishError {
            error: WorkspaceError::new("the current terminal presentation is unavailable"),
            worker,
        }));
    }
    if attachment.active().is_some() && previous_presentation_id.is_none() {
        return Err(Box::new(RemotePublishError {
            error: WorkspaceError::new("the current terminal presentation identity is unavailable"),
            worker,
        }));
    }

    let previous_attachment = if remote_active.is_none() {
        attachment.take_active()
    } else {
        attachment.invalidate();
        None
    };
    let (worker_generation, previous_worker) = workers.replace(worker);
    reconcile_active_worker_cursor(&scene.runtime, &workers);
    let previous_remote = remote_active.replace(RemoteActive {
        key,
        selection: selection.clone(),
        worker_generation,
        lease,
        presentation_id,
        term,
        retainable: retain_remote_session(selection.kind()),
        identity_mismatch_marker,
    });
    clear_pending_paste(scene);
    set_terminal_notice(scene, term);
    set_scene_state(
        scene,
        WorkspaceContent::Terminal {
            host_id: selection.host_id().to_owned(),
            endpoint: selection.endpoint().to_owned(),
            session: selection.session().to_owned(),
            kind: selection.kind(),
            presentation_id,
            surface,
        },
    );
    drop(remote_entries);
    drop(workers);
    drop(remote_active);
    drop(geometry);
    drop(attachment);

    match (previous_worker, previous_remote, previous_attachment) {
        (Some(worker), Some(active), _) if active.retainable => {
            retire_clipboard_writes(scene, &worker);
            let _cancelled = worker.cancel_paste();
            insert_remote_retained_presentation(
                &scene.runtime,
                &scene.remote_retained,
                RemoteRetainedPresentation { active, worker },
            );
        }
        // A dropped (non-retained) previous worker retires the same way:
        // its queued and in-flight clipboard writes must not land after
        // the switch.
        (Some(worker), Some(_), _) => {
            retire_clipboard_writes(scene, &worker);
        }
        (Some(worker), None, Some(attachment)) => {
            retire_clipboard_writes(scene, &worker);
            let _cancelled = worker.cancel_paste();
            let selection = attachment.request.selection();
            let key = attachment.request.presentation_key();
            insert_retained_presentation(
                &scene.runtime,
                &scene.retained_presentations,
                RetainedPresentation {
                    key,
                    selection,
                    attachment,
                    worker,
                    presentation_id: previous_presentation_id
                        .expect("active local presentation identity was checked"),
                },
            );
        }
        _ => {}
    }
    drop(snapshot_write);
    Ok(())
}

#[allow(
    clippy::too_many_lines,
    reason = "cross-host attachment keeps preparation, authority validation, and swap together"
)]
pub(crate) fn run_attach_over_remote(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    generation: u64,
    navigation_generation: u64,
) {
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
        || !scene
            .attachment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_current(generation)
    {
        return;
    }
    let result = attach_fresh(scene, request, term);
    let (_navigation, worker, snapshot, attached_session, initial_geometry, attached_term) =
        match result {
            Ok(prepared) => prepared,
            Err(AttachFreshError::SceneClosed) => return,
            Err(error) => {
                let snapshot_write = begin_snapshot_write(&scene.runtime);
                let mut attachment = scene
                    .attachment
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
                    || !attachment.is_current(generation)
                {
                    return;
                }
                attachment.clear_if_current(generation);
                drop(attachment);
                let message = match error {
                    AttachFreshError::Host(error)
                    | AttachFreshError::SessionChanged { error, .. } => error.to_string(),
                    AttachFreshError::SceneClosed => unreachable!("handled above"),
                };
                push_operation_event(scene, WorkspaceEvent::Error(message));
                drop(snapshot_write);
                return;
            }
        };
    let snapshot_write = begin_snapshot_write(&scene.runtime);
    let mut attachment = scene
        .attachment
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.navigation_generation.load(Ordering::Acquire) != navigation_generation
        || !attachment.is_current(generation)
    {
        return;
    }
    if let Some(active) = attachment.active_mut() {
        normalize_attached_worktree_target(active, &snapshot, &attached_session);
        active.term = attached_term;
    }
    let surface = worker.surface_handle();
    publish_attach_inventory(scene, request, snapshot);
    let key = attachment
        .active()
        .expect("current attachment was checked")
        .request
        .presentation_key();
    let session = current_inventory_session_name(&scene.runtime, &key).unwrap_or(attached_session);
    if let Some(active) = attachment.active_mut() {
        session.clone_into(&mut active.request.name);
    }
    let geometry = scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if *geometry != initial_geometry
        && let Err(error) =
            worker.resize_with_metadata(geometry.grid, geometry.sequence, geometry.pixels)
    {
        attachment.clear_if_current(generation);
        drop(attachment);
        push_operation_event(scene, WorkspaceEvent::Error(error.to_string()));
        return;
    }
    let mut remote_active = scene
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(active_remote) = remote_active.as_ref() else {
        attachment.clear_if_current(generation);
        return;
    };
    let mut workers = scene
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if workers.generation() != active_remote.worker_generation {
        attachment.clear_if_current(generation);
        return;
    }
    let (_, previous_worker) = workers.replace(worker);
    reconcile_active_worker_cursor(&scene.runtime, &workers);
    let previous_remote = remote_active.take();
    set_terminal_notice(scene, attached_term);
    let presentation_id = next_presentation_id(&scene.runtime);
    set_scene_state(
        scene,
        WorkspaceContent::Terminal {
            host_id: request.host_id.clone(),
            endpoint: request.endpoint.distro().to_owned(),
            session,
            kind: request.target.kind(),
            presentation_id,
            surface,
        },
    );
    drop(workers);
    drop(remote_active);
    drop(geometry);
    drop(attachment);
    match (previous_worker, previous_remote) {
        (Some(worker), Some(active)) if active.retainable => {
            retire_clipboard_writes(scene, &worker);
            let _cancelled = worker.cancel_paste();
            insert_remote_retained_presentation(
                &scene.runtime,
                &scene.remote_retained,
                RemoteRetainedPresentation { active, worker },
            );
        }
        // A dropped previous worker retires the same way.
        (Some(worker), _) => retire_clipboard_writes(scene, &worker),
        _ => {}
    }
    drop(snapshot_write);
}

pub(crate) fn run_retained_retry(scene: &Scene, retry: &RetainedRetry) {
    // Lock order matches every remote attach/create path: session
    // operations first, navigation second — the reverse completes an ABBA
    // cycle against those paths' seconds-long SSH work under the
    // operations lock. The pump may have extracted this retry just before
    // the scene closed; the closed-check here keeps a fresh PTY client
    // from ever starting for a dead scene. Discovery runs unfenced so a
    // slow host never stalls scene closure or navigation; the launch and
    // its publication then sit under one live-navigation fence acquired
    // inside attach_fresh_retained, so a scene closing after discovery
    // never spawns a client at all.
    let _operation = scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    {
        let Ok(_navigation) = lock_live_navigation(scene) else {
            return;
        };
    }
    // The registration is verified under the operation lane immediately
    // before launching: a destructive mutation of the same session revoked
    // it during suppression, and launching anyway would attach a client to
    // whatever same-name replacement appears next.
    if !scene
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .has_restart(&retry.key)
    {
        return;
    }
    match attach_fresh_retained(scene, retry) {
        // The launch's fence rides into publication: the same guard that
        // authorized the spawn covers finish_restart and inventory.
        Ok((_navigation, worker, snapshot, resolved_request, initial_geometry)) => {
            let _snapshot_write = begin_snapshot_write(&scene.runtime);
            let latest_geometry = *scene
                .terminal_geometry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if latest_geometry != initial_geometry
                && let Err(error) = worker.resize_with_metadata(
                    latest_geometry.grid,
                    latest_geometry.sequence,
                    latest_geometry.pixels,
                )
            {
                fail_retained_retry(scene, &retry.key, Some(error.to_string()));
                return;
            }
            worker.set_clipboard_writes_enabled(false);
            worker.set_default_cursor_shape(current_default_cursor_shape(&scene.runtime));
            let published = scene
                .retained_presentations
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .finish_restart(&retry.key, worker, &retry.request.name, &resolved_request);
            if published {
                publish_attach_inventory(scene, &resolved_request, snapshot);
                bump_scene_revision(scene);
            }
        }
        Err(AttachFreshError::SceneClosed) => {}
        // Failure publication re-fences: a closure that won the race during
        // the unfenced discovery is observed here, and the failure is
        // neither pushed into the dead scene as a notice nor allowed to
        // mutate runtime-wide inventory on its behalf.
        Err(AttachFreshError::Host(error)) => {
            let Ok(_navigation) = lock_live_navigation(scene) else {
                return;
            };
            let _snapshot_write = begin_snapshot_write(&scene.runtime);
            fail_retained_retry(scene, &retry.key, Some(error.to_string()));
        }
        Err(AttachFreshError::SessionChanged { error, snapshot }) => {
            let Ok(_navigation) = lock_live_navigation(scene) else {
                return;
            };
            let _snapshot_write = begin_snapshot_write(&scene.runtime);
            remove_failed_retained_retry(scene, &retry.key);
            publish_retained_stale_failure(scene, &retry.request, *snapshot, &error);
        }
    }
}

pub(crate) fn fail_retained_retry(
    scene: &Scene,
    key: &PresentationKey,
    diagnostic: Option<String>,
) {
    remove_failed_retained_retry(scene, key);
    if let Some(diagnostic) = diagnostic {
        publish_local_notice(scene, diagnostic);
    }
}

pub(crate) fn remove_failed_retained_retry(scene: &Scene, key: &PresentationKey) {
    let removed = scene
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .fail_restart(key);
    if removed.is_some() {
        bump_scene_revision(scene);
    }
}

pub(crate) fn fallback_owns_request(
    scene: &Scene,
    fallback: &FallbackAuthority,
    request: &AttachRequest,
) -> bool {
    scene.navigation_generation.load(Ordering::Acquire) == fallback.navigation_generation
        && fallback.target == request.presentation_key()
}

pub(crate) fn failed_attachment_context(
    scene: &Scene,
    attachment: &AttachmentState<AttachRequest>,
    generation: u64,
) -> Option<(AttachRequest, Option<FallbackAuthority>)> {
    if !attachment.is_current(generation) {
        return None;
    }
    let request = attachment.active()?.request.clone();
    let fallback = attachment
        .fallback_if_current(generation)
        .filter(|fallback| fallback_owns_request(scene, fallback, &request));
    Some((request, fallback))
}

pub(crate) fn restore_attach_fallback(scene: &Scene, fallback: Option<FallbackAuthority>) {
    let _navigation = scene
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    restore_attach_fallback_locked(scene, fallback);
}

pub(crate) fn restore_attach_fallback_locked(scene: &Scene, fallback: Option<FallbackAuthority>) {
    let Some(fallback) = fallback else {
        return;
    };
    if scene.navigation_generation.load(Ordering::Acquire) != fallback.navigation_generation {
        return;
    }
    let preserved_notice = scene
        .terminal_notice
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    match activate_retained_presentation(scene, &fallback.presentation, None) {
        Ok(true) => {
            if let Some(notice) = preserved_notice {
                *scene
                    .terminal_notice
                    .write()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(notice);
            }
        }
        Ok(false) => set_local_notice(
            scene,
            "the previous terminal presentation is no longer available".to_owned(),
        ),
        Err(error) => set_local_notice(
            scene,
            format!("could not restore the previous terminal presentation: {error}"),
        ),
    }
}

pub(crate) fn merge_created_inventory(
    scene: &Scene,
    request: &CreateRequest,
    snapshot: HostSnapshot,
    publication_generation: u64,
) -> Result<u64, WorkspaceError> {
    merge_constructive_inventory(
        scene,
        &request.host,
        &request.endpoint,
        &request.runtime,
        snapshot,
        publication_generation,
        "the created tmux session",
    )
}

pub(crate) fn merge_herdr_created_inventory(
    scene: &Scene,
    request: &HerdrCreateRequest,
    snapshot: HostSnapshot,
    publication_generation: u64,
) -> Result<u64, WorkspaceError> {
    merge_constructive_inventory(
        scene,
        &request.host,
        &request.endpoint,
        &request.runtime,
        snapshot,
        publication_generation,
        "the created Herdr session",
    )
}

pub(crate) fn merge_herdr_lifecycle_inventory(
    scene: &Scene,
    pending: &PendingHerdrLifecycle,
    snapshot: HostSnapshot,
    publication_generation: u64,
) -> Result<u64, WorkspaceError> {
    merge_constructive_inventory(
        scene,
        &pending.host,
        &pending.endpoint,
        &pending.runtime,
        snapshot,
        publication_generation,
        "the Herdr lifecycle result",
    )
}

pub(crate) fn publish_herdr_lifecycle_response(
    scene: &Scene,
    pending: &PendingHerdrLifecycle,
    record: session::HerdrSessionRecord,
) -> Result<u64, WorkspaceError> {
    let publication_generation = reserve_constructive_inventory(&scene.runtime);
    let snapshot = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .filter(|published| {
            published.value.snapshot.endpoint() == &pending.endpoint
                && published.value.snapshot.runtime() == &pending.runtime
        })
        .map(|published| published.value.snapshot.clone())
        .ok_or_else(|| {
            WorkspaceError::new(
                "the WSL endpoint changed while publishing the Herdr lifecycle response",
            )
        })?
        .with_herdr_lifecycle(pending.action, &pending.executable, &pending.record, record)
        .ok_or_else(|| {
            WorkspaceError::new(
                "the Herdr lifecycle response no longer matches published inventory",
            )
        })?;
    merge_herdr_lifecycle_inventory(scene, pending, snapshot, publication_generation)
}

pub(crate) fn reconcile_herdr_lifecycle_inventory(
    scene: &Scene,
    pending: &PendingHerdrLifecycle,
) -> Result<HostSnapshot, WorkspaceError> {
    let publication_generation = reserve_constructive_inventory(&scene.runtime);
    let snapshot = match pending.host.discover(&ConptyAdmissionAttacher::new()) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            settle_constructive_inventory(scene, publication_generation);
            return Err(WorkspaceError::new(error.to_string()));
        }
    };
    match snapshot.herdr() {
        HerdrInventory::Available { .. } => {}
        HerdrInventory::Failed(error) => {
            settle_constructive_inventory(scene, publication_generation);
            return Err(WorkspaceError::new(error.to_string()));
        }
        HerdrInventory::Unavailable => {
            settle_constructive_inventory(scene, publication_generation);
            return Err(WorkspaceError::new(
                "Herdr became unavailable while reconciling the lifecycle action",
            ));
        }
    }
    merge_herdr_lifecycle_inventory(scene, pending, snapshot.clone(), publication_generation)?;
    Ok(snapshot)
}

pub(crate) fn merge_constructive_inventory(
    scene: &Scene,
    runtime_host: &RuntimeHost,
    endpoint: &host::WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    snapshot: HostSnapshot,
    publication_generation: u64,
    operation: &str,
) -> Result<u64, WorkspaceError> {
    let _publication = scene
        .runtime
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if scene.runtime.refresh_generation.load(Ordering::Acquire) != publication_generation {
        return Err(WorkspaceError::new(format!(
            "newer inventory superseded {operation}; refresh before trying again"
        )));
    }
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    if snapshot.endpoint() != endpoint || snapshot.runtime() != runtime {
        return Err(WorkspaceError::new(format!(
            "WSL changed while publishing {operation}"
        )));
    }
    let published_generation = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .and_then(|published| {
            (published.value.snapshot.endpoint() == endpoint
                && published.value.snapshot.runtime() == runtime)
                .then_some(published.generation)
        })
        .ok_or_else(|| {
            WorkspaceError::new(format!(
                "the WSL endpoint changed while publishing {operation}; refresh before trying again"
            ))
        })?;
    if published_generation > publication_generation {
        return Err(WorkspaceError::new(
            "session inventory generation moved backwards during publication",
        ));
    }
    let inventory_generation = publication_generation;

    let inventory_state = ready_content(&snapshot);
    reconcile_herdr_lifecycle_fences(&scene.runtime, &snapshot, publication_generation, false);
    set_herdr_inventory(&scene.runtime, snapshot.herdr());
    set_zellij_inventory(&scene.runtime, snapshot.zellij());
    reconcile_retained_session_names(&scene.runtime, &snapshot, runtime_host.socket_directory());
    *scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
        HostContext {
            host: runtime_host.clone(),
            snapshot,
        },
        inventory_generation,
    ));
    set_inventory_state(&scene.runtime, &inventory_state);
    Ok(inventory_generation)
}

pub(crate) fn publish_attach_inventory(
    scene: &Scene,
    request: &AttachRequest,
    snapshot: HostSnapshot,
) {
    publish_refresh(&scene.runtime, request.inventory_generation, || {
        set_attach_inventory(scene, request, snapshot);
    });
}

pub(crate) fn set_attach_inventory(scene: &Scene, request: &AttachRequest, snapshot: HostSnapshot) {
    let inventory_state = ready_content(&snapshot);
    set_herdr_inventory(&scene.runtime, snapshot.herdr());
    set_zellij_inventory(&scene.runtime, snapshot.zellij());
    reconcile_retained_session_names(&scene.runtime, &snapshot, request.host.socket_directory());
    *scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
        HostContext {
            host: request.host.clone(),
            snapshot,
        },
        request.inventory_generation,
    ));
    set_inventory_state(&scene.runtime, &inventory_state);
}

/// Propagate refreshed session names into every registered scene's active
/// and retained presentations as one atomic pass under the refresh
/// publication fence.
pub(crate) fn reconcile_presentation_session_names(
    runtime: &Runtime,
    refresh_generation: u64,
    snapshot: &HostSnapshot,
    socket_directory: Option<&str>,
) {
    let _snapshot_write = begin_snapshot_write(runtime);
    // Every scene's attachment lock is acquired first — in registration
    // order, the one global order for multi-scene attachment acquisition —
    // and only then is the refresh publication fence taken, once, for the
    // whole pass. Attachment locks must come before the fence because
    // attachment completion holds `attachment` across
    // `publish_attach_inventory`, which waits on `refresh_publication`;
    // taking the fence first would close an ABBA cycle and deadlock a
    // concurrent refresh against a finishing attachment. Holding the fence
    // across all scenes keeps the pass atomic: a refresh generation cannot
    // advance mid-pass (for example from a superseding or constructive
    // reservation that never re-reconciles) and leave later scenes
    // stale-named while earlier scenes were already renamed — either every
    // scene is renamed under the publishing generation or none is.
    let scenes = live_scenes(runtime);
    let mut attachments: Vec<_> = scenes
        .iter()
        .map(|scene| {
            scene
                .attachment
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
        })
        .collect();
    let _publication = runtime
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let authoritative;
    let (snapshot, socket_directory) =
        if runtime.refresh_generation.load(Ordering::Acquire) == refresh_generation {
            (snapshot, socket_directory)
        } else {
            // The publishing refresh was superseded after its inventory
            // landed — for example by a constructive reservation, whose own
            // publication reconciles only retained names. Skipping the pass
            // would leave active presentations permanently stale-named
            // relative to the published inventory, so it retries against
            // the authoritative published snapshot instead: renames that
            // already reached the store still reach every scene, while a
            // supersession that has not published yet cannot have changed
            // the published names this pass applies.
            let Some(published) = runtime
                .host
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_ref()
                .map(|published| {
                    (
                        published.value.snapshot.clone(),
                        published.value.host.socket_directory().map(str::to_owned),
                    )
                })
            else {
                return;
            };
            authoritative = published;
            (&authoritative.0, authoritative.1.as_deref())
        };
    for (scene, attachment) in scenes.iter().zip(attachments.iter_mut()) {
        reconcile_scene_presentation_session_names(scene, attachment, snapshot, socket_directory);
    }
}

fn reconcile_scene_presentation_session_names(
    scene: &Scene,
    attachment: &mut AttachmentState<AttachRequest>,
    snapshot: &HostSnapshot,
    socket_directory: Option<&str>,
) {
    reconcile_scene_retained_session_names(scene, snapshot, socket_directory);
    let renamed = attachment.active_mut().and_then(|active| {
        let name = refreshed_session_name(
            &active.request.presentation_key(),
            snapshot,
            socket_directory,
        )?;
        if name == active.request.name {
            return None;
        }
        name.clone_into(&mut active.request.name);
        Some((
            active.request.host_id.clone(),
            active.request.endpoint.distro().to_owned(),
            name,
        ))
    });
    let Some((renamed_host, renamed_endpoint, renamed_session)) = renamed else {
        return;
    };
    let changed = {
        let mut state = scene
            .state
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match &mut *state {
            WorkspaceContent::Attaching {
                host_id,
                endpoint,
                session,
                ..
            }
            | WorkspaceContent::Terminal {
                host_id,
                endpoint,
                session,
                ..
            } if host_id == &renamed_host && endpoint == &renamed_endpoint => {
                session.clone_from(&renamed_session);
                true
            }
            _ => false,
        }
    };
    if changed {
        bump_scene_revision(scene);
    }
}

/// Propagate refreshed session names into every registered scene's retained
/// presentations.
pub(crate) fn reconcile_retained_session_names(
    runtime: &Runtime,
    snapshot: &HostSnapshot,
    socket_directory: Option<&str>,
) {
    for_each_scene(runtime, |scene| {
        reconcile_scene_retained_session_names(scene, snapshot, socket_directory);
    });
}

fn reconcile_scene_retained_session_names(
    scene: &Scene,
    snapshot: &HostSnapshot,
    socket_directory: Option<&str>,
) {
    let changed = scene
        .retained_presentations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .reconcile_session_names(snapshot, socket_directory);
    if changed {
        bump_scene_revision(scene);
    }
}

pub(crate) fn publish_stale_attachment_failure(
    scene: &Scene,
    request: &AttachRequest,
    snapshot: HostSnapshot,
    error: &WorkspaceError,
) {
    clear_pending_paste(scene);
    restore_presentation_inventory(scene);
    publish_refresh(&scene.runtime, request.inventory_generation, || {
        set_local_notice(scene, error.to_string());
        set_attach_inventory(scene, request, snapshot);
    });
}

pub(crate) fn publish_retained_stale_failure(
    scene: &Scene,
    request: &AttachRequest,
    snapshot: HostSnapshot,
    error: &WorkspaceError,
) {
    publish_refresh(&scene.runtime, request.inventory_generation, || {
        set_local_notice(scene, error.to_string());
        set_attach_inventory(scene, request, snapshot);
    });
}

pub(crate) fn publish_attachment_failure(
    scene: &Scene,
    inventory_generation: u64,
    error: impl fmt::Display,
) {
    let message = error.to_string();
    clear_pending_paste(scene);
    restore_presentation_inventory(scene);
    publish_refresh(&scene.runtime, inventory_generation, || {
        if scene.runtime.host_scoped_inventory {
            set_wsl_host_unavailable(&scene.runtime, DiagnosticKind::Transport, message);
        } else {
            set_scene_state(scene, WorkspaceContent::Error { message });
        }
    });
}

pub(crate) fn restore_presentation_inventory(scene: &Scene) {
    let state = scene
        .runtime
        .inventory_state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    set_scene_state(scene, state);
}

pub(crate) fn reopen_closed_retained_presentation(
    scene: &Scene,
    mut closed: ClosedRetainedPresentation,
) -> Result<RetainedPresentation<TerminalWorker>, WorkspaceError> {
    let term = closed.attachment.term;
    let (_navigation, worker, _snapshot, attached_name, initial_geometry, attached_term) =
        attach_fresh(scene, &closed.attachment.request, term).map_err(|error| match error {
            AttachFreshError::Host(error) | AttachFreshError::SessionChanged { error, .. } => error,
            // The fenced launch refused a closed scene before spawning.
            AttachFreshError::SceneClosed => WorkspaceError::new("the scene closed"),
        })?;
    let latest_geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if latest_geometry != initial_geometry {
        worker
            .resize_with_metadata(
                latest_geometry.grid,
                latest_geometry.sequence,
                latest_geometry.pixels,
            )
            .map_err(|error| WorkspaceError::from_worker(&error))?;
    }
    attached_name.clone_into(&mut closed.attachment.request.name);
    closed.attachment.term = attached_term;
    let selection = closed.attachment.request.selection();
    worker.set_clipboard_writes_enabled(false);
    Ok(RetainedPresentation {
        key: closed.key,
        selection,
        attachment: closed.attachment,
        worker,
        presentation_id: closed.presentation_id,
    })
}

pub(crate) fn publish_restored_retained_presentation(
    scene: &Scene,
    presentation: RetainedPresentation<TerminalWorker>,
) {
    let _snapshot_write = begin_snapshot_write(&scene.runtime);
    let refused = {
        let mut retained = scene
            .retained_presentations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // Checked under the retained lock — `release_scene` sets the closed
        // flag before it drains this container under the same lock — so a
        // restore racing the close either refuses here or inserts before
        // the drain and is swapped out by it. No reopened worker outlives
        // its scene through either interleaving.
        if scene.closed.load(Ordering::Acquire) {
            Some(presentation)
        } else {
            presentation
                .worker
                .set_default_cursor_shape(current_default_cursor_shape(&scene.runtime));
            retained.insert(presentation);
            None
        }
    };
    match refused {
        // The reopened worker dies with the scene it can no longer rejoin.
        Some(presentation) => drop(presentation),
        None => bump_scene_revision(scene),
    }
}

#[allow(
    clippy::too_many_lines,
    reason = "all backend attachment capabilities share one audited dispatch boundary"
)]
pub(crate) fn attach_fresh<'scene>(
    scene: &'scene Scene,
    request: &AttachRequest,
    term: AttachTerm,
) -> Result<
    (
        NavigationFence<'scene>,
        TerminalWorker,
        HostSnapshot,
        String,
        TerminalGeometry,
        AttachTerm,
    ),
    AttachFreshError,
> {
    let fresh = discover_fresh_runtime(request)?;
    // Discovery ran unfenced so a slow host never stalls scene closure or
    // navigation; the launch and its publication then hold one
    // live-navigation fence, so a scene closing during discovery never
    // spawns a client that could touch multiplexer focus or sizing.
    let Ok(navigation) = lock_live_navigation(scene) else {
        return Err(AttachFreshError::SceneClosed);
    };
    let (worker, snapshot, name, geometry, actual_term) = match &request.target {
        AttachTarget::Tmux(identity) => {
            let session = fresh
                .sessions()
                .iter()
                .find(|session| session.name() == request.name)
                .cloned();
            let Some(session) = session else {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new(
                        "session no longer exists; refresh and choose another session",
                    ),
                    snapshot: Box::new(fresh),
                });
            };
            if identity != session.identity() {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new(
                        "session identity changed since discovery; refusing stale attachment",
                    ),
                    snapshot: Box::new(fresh),
                });
            }
            let (worker, snapshot, name, geometry) =
                launch_fresh_tmux(scene, request, term, &fresh, &session)?;
            (worker, snapshot, name, geometry, term)
        }
        AttachTarget::Worktree {
            repository,
            registration_fingerprint,
            path,
            generation,
            session_name,
            tmux_socket_name,
        } => {
            let cancellation = CancellationToken::new();
            let open = host::KwtWorktreeOpen::new(
                path,
                repository,
                registration_fingerprint,
                generation.as_deref().ok_or_else(|| {
                    kwt_attachment_failure(
                        &fresh,
                        "worktree generation is unavailable; refresh KWT inventory before opening it",
                    )
                })?,
                session_name,
                tmux_socket_name.clone(),
            );
            launch_fresh_worktree(scene, request, term, &fresh, &open, &cancellation)?
        }
        AttachTarget::ProtectedWorktree {
            repository,
            project_path,
            registration_fingerprint,
            path,
            generation,
            session_name,
            tmux_socket_name,
        } => {
            let cancellation = CancellationToken::new();
            let open = host::KwtProtectedWorktreeOpen::new(
                path,
                project_path,
                repository,
                registration_fingerprint,
                generation,
                session_name,
                tmux_socket_name,
            );
            launch_fresh_protected_worktree(scene, request, term, &fresh, &open, &cancellation)?
        }
        AttachTarget::DirectoryWorkspace {
            path,
            session_name,
            tmux_socket_name,
        } => {
            let cancellation = CancellationToken::new();
            let open =
                host::KwtDirectoryWorkspaceOpen::new(path, session_name, tmux_socket_name.clone());
            launch_fresh_directory_workspace(scene, request, term, &fresh, &open, &cancellation)?
        }
        AttachTarget::Herdr { .. } => {
            let Some(session) = fresh_herdr_session(&fresh, &request.target) else {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new(
                        "Herdr session changed since discovery; refresh and choose it again",
                    ),
                    snapshot: Box::new(fresh),
                });
            };
            let (worker, snapshot, name, geometry) =
                launch_fresh_herdr(scene, request, term, &fresh, &session)?;
            (worker, snapshot, name, geometry, term)
        }
        AttachTarget::Zellij { executable, name } => {
            let ZellijInventory::Available {
                executable: current_executable,
                sessions,
            } = fresh.zellij()
            else {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new("Zellij is no longer available on this host"),
                    snapshot: Box::new(fresh),
                });
            };
            let Some(session) = sessions
                .iter()
                .find(|session| session.name() == name && current_executable == executable)
                .cloned()
            else {
                return Err(AttachFreshError::SessionChanged {
                    error: WorkspaceError::new(
                        "Zellij session changed since discovery; refresh and choose it again",
                    ),
                    snapshot: Box::new(fresh),
                });
            };
            let (worker, snapshot, name, geometry) =
                launch_fresh_zellij(scene, request, term, &fresh, &session)?;
            (worker, snapshot, name, geometry, term)
        }
    };
    Ok((navigation, worker, snapshot, name, geometry, actual_term))
}

#[allow(
    clippy::too_many_lines,
    reason = "retained restart dispatch covers every multiplexer capability without erasing backend identity"
)]
pub(crate) fn attach_fresh_retained<'scene>(
    scene: &'scene Scene,
    retry: &RetainedRetry,
) -> Result<
    (
        NavigationFence<'scene>,
        TerminalWorker,
        HostSnapshot,
        AttachRequest,
        TerminalGeometry,
    ),
    AttachFreshError,
> {
    let fresh = discover_fresh_runtime(&retry.request)?;
    let Some(resolved_request) = resolve_retained_retry_request(retry, &fresh) else {
        return Err(AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "session identity changed since discovery; refusing stale attachment",
            ),
            snapshot: Box::new(fresh),
        });
    };
    // The launch is fenced: a scene closing after the slow, unfenced
    // discovery must not spawn a client that could touch multiplexer
    // focus or sizing before the post-launch check discards it. The guard
    // is returned so publication happens under the same fence.
    let Ok(navigation) = lock_live_navigation(scene) else {
        return Err(AttachFreshError::SceneClosed);
    };
    let (worker, snapshot, _, geometry) = match &retry.key.target {
        AttachTarget::Tmux(identity) => {
            let session = fresh
                .sessions()
                .iter()
                .find(|session| session.identity() == identity)
                .cloned()
                .expect("resolved retained request has a matching tmux session");
            launch_fresh_tmux(
                scene,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                &session,
            )?
        }
        AttachTarget::Worktree {
            repository,
            registration_fingerprint,
            path,
            generation,
            session_name,
            tmux_socket_name,
        } => {
            let cancellation = CancellationToken::new();
            let open = host::KwtWorktreeOpen::new(
                path,
                repository,
                registration_fingerprint,
                generation.as_deref().ok_or_else(|| {
                    kwt_attachment_failure(
                        &fresh,
                        "worktree generation is unavailable; refresh KWT inventory before opening it",
                    )
                })?,
                session_name,
                tmux_socket_name.clone(),
            );
            let (worker, snapshot, name, geometry, _actual_term) = launch_fresh_worktree(
                scene,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                &open,
                &cancellation,
            )?;
            (worker, snapshot, name, geometry)
        }
        AttachTarget::ProtectedWorktree {
            repository,
            project_path,
            registration_fingerprint,
            path,
            generation,
            session_name,
            tmux_socket_name,
        } => {
            let cancellation = CancellationToken::new();
            let open = host::KwtProtectedWorktreeOpen::new(
                path,
                project_path,
                repository,
                registration_fingerprint,
                generation,
                session_name,
                tmux_socket_name,
            );
            let (worker, snapshot, name, geometry, _actual_term) = launch_fresh_protected_worktree(
                scene,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                &open,
                &cancellation,
            )?;
            (worker, snapshot, name, geometry)
        }
        AttachTarget::DirectoryWorkspace {
            path,
            session_name,
            tmux_socket_name,
        } => {
            let cancellation = CancellationToken::new();
            let open =
                host::KwtDirectoryWorkspaceOpen::new(path, session_name, tmux_socket_name.clone());
            let (worker, snapshot, name, geometry, _actual_term) =
                launch_fresh_directory_workspace(
                    scene,
                    &resolved_request,
                    AttachTerm::Xterm,
                    &fresh,
                    &open,
                    &cancellation,
                )?;
            (worker, snapshot, name, geometry)
        }
        AttachTarget::Herdr { .. } => {
            let session = fresh_herdr_session(&fresh, &retry.key.target)
                .expect("resolved retained request has a matching Herdr session");
            launch_fresh_herdr(
                scene,
                &resolved_request,
                AttachTerm::Xterm,
                &fresh,
                &session,
            )?
        }
        AttachTarget::Zellij { executable, name } => {
            let ZellijInventory::Available {
                executable: current_executable,
                sessions,
            } = fresh.zellij()
            else {
                unreachable!("resolved retained request has Zellij inventory");
            };
            let session = sessions
                .iter()
                .find(|session| session.name() == name && current_executable == executable)
                .expect("resolved retained request has a matching Zellij session");
            launch_fresh_zellij(scene, &resolved_request, AttachTerm::Xterm, &fresh, session)?
        }
    };
    Ok((navigation, worker, snapshot, resolved_request, geometry))
}

pub(crate) fn launch_fresh_tmux(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    session: &session::DiscoveredSession,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let plan = request
        .host
        .attach_plan_with_term(fresh.endpoint(), session, term);
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::attach_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
        current_default_colors(&scene.runtime),
        current_default_cursor_shape(&scene.runtime),
    )
    .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    Ok((
        worker,
        fresh.clone(),
        plan.target_name().to_owned(),
        geometry,
    ))
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn capture_kwt_worktree_request(
    scene: &Scene,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: Option<&str>,
    session_name: &str,
    tmux_socket_name: Option<&str>,
    tmux_attach_mode: KwtTmuxAttachMode,
) -> Result<AttachRequest, WorkspaceError> {
    if host_id != "wsl"
        || scene
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref()
            != Some(host_id)
    {
        return Err(WorkspaceError::new("the WSL host is not selected"));
    }
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the worktree selection",
            ));
        }
        let hosts = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let host_item = hosts
            .iter()
            .find(|host| host.id == host_id && host.endpoint == endpoint)
            .ok_or_else(|| WorkspaceError::new("the selected WSL host is unavailable"))?;
        if host_item.connection != HostConnectionState::Ready || !host_item.kwt_available() {
            return Err(WorkspaceError::new(
                "refresh KWT inventory before opening this worktree",
            ));
        }
        let worktree = host_item
            .projects
            .iter()
            .find(|project| {
                project.repository == repository
                    && project.path == project_path
                    && project.registration_fingerprint == registration_fingerprint
            })
            .and_then(|project| {
                project.worktrees.iter().find(|worktree| {
                    worktree.path == worktree_path
                        && worktree.generation.as_deref() == generation
                        && worktree.session_name == session_name
                        && worktree.tmux_socket_name.as_deref() == tmux_socket_name
                        && worktree.tmux_attach_mode == tmux_attach_mode
                })
            })
            .ok_or_else(|| {
                WorkspaceError::new(
                    "the selected worktree is no longer in authoritative KWT inventory",
                )
            })?;
        Ok(AttachRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            target: if worktree.tmux_attach_mode == KwtTmuxAttachMode::Protected {
                let tmux_socket_name = worktree.tmux_socket_name.clone().ok_or_else(|| {
                    WorkspaceError::new(
                        "protected worktree endpoint is unresolved; refresh KWT inventory",
                    )
                })?;
                AttachTarget::ProtectedWorktree {
                    repository: repository.to_owned(),
                    project_path: project_path.to_owned(),
                    registration_fingerprint: registration_fingerprint.to_owned(),
                    path: worktree.path.clone(),
                    generation: worktree.generation.clone().ok_or_else(|| {
                        WorkspaceError::new(
                            "protected worktree generation is unavailable; refresh KWT inventory",
                        )
                    })?,
                    session_name: worktree.session_name.clone(),
                    tmux_socket_name,
                }
            } else {
                AttachTarget::Worktree {
                    repository: repository.to_owned(),
                    registration_fingerprint: registration_fingerprint.to_owned(),
                    path: worktree.path.clone(),
                    generation: worktree.generation.clone(),
                    session_name: worktree.session_name.clone(),
                    tmux_socket_name: worktree.tmux_socket_name.clone(),
                }
            },
            name: worktree.session_name.clone(),
            inventory_generation,
        })
    })
}

pub(crate) fn capture_kwt_directory_workspace_request(
    scene: &Scene,
    host_id: &str,
    endpoint: &str,
    path: &str,
    session_name: &str,
    tmux_socket_name: Option<&str>,
    tmux_attach_mode: KwtTmuxAttachMode,
) -> Result<AttachRequest, WorkspaceError> {
    if host_id != "wsl"
        || scene
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref()
            != Some(host_id)
    {
        return Err(WorkspaceError::new("the WSL host is not selected"));
    }
    if tmux_attach_mode != KwtTmuxAttachMode::Direct {
        return Err(WorkspaceError::new(
            "protected directory workspaces are not attachable through KWT open",
        ));
    }
    let host = scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let context = host
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("WSL inventory is not ready"))?;
    context.map(|context, inventory_generation| {
        if context.snapshot.endpoint().distro() != endpoint {
            return Err(WorkspaceError::new(
                "host endpoint changed; refresh the directory workspace selection",
            ));
        }
        let hosts = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let host_item = hosts
            .iter()
            .find(|host| host.id == host_id && host.endpoint == endpoint)
            .ok_or_else(|| WorkspaceError::new("the selected WSL host is unavailable"))?;
        if host_item.connection != HostConnectionState::Ready || !host_item.kwt_available() {
            return Err(WorkspaceError::new(
                "refresh KWT inventory before opening this directory workspace",
            ));
        }
        let workspace = host_item
            .directory_workspaces
            .iter()
            .find(|workspace| {
                workspace.path == path
                    && workspace.session_name == session_name
                    && workspace.tmux_socket_name.as_deref() == tmux_socket_name
                    && workspace.tmux_attach_mode == tmux_attach_mode
            })
            .ok_or_else(|| {
                WorkspaceError::new(
                    "the selected directory workspace is no longer in authoritative KWT inventory",
                )
            })?;
        Ok(AttachRequest {
            host_id: host_id.to_owned(),
            host: context.host.clone(),
            endpoint: context.snapshot.endpoint().clone(),
            runtime: context.snapshot.runtime().clone(),
            target: AttachTarget::DirectoryWorkspace {
                path: workspace.path.clone(),
                session_name: workspace.session_name.clone(),
                tmux_socket_name: workspace.tmux_socket_name.clone(),
            },
            name: workspace.session_name.clone(),
            inventory_generation,
        })
    })
}

pub(crate) fn launch_fresh_worktree(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtWorktreeOpen,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        String,
        TerminalGeometry,
        AttachTerm,
    ),
    AttachFreshError,
> {
    match launch_fresh_worktree_once(scene, request, term, fresh, open, cancellation) {
        Ok((worker, snapshot, name, geometry)) => Ok((worker, snapshot, name, geometry, term)),
        Err(WorktreeLaunchError::RetryWithXterm) if term == AttachTerm::Xterm256Color => {
            let (worker, snapshot, name, geometry) = launch_fresh_worktree_once(
                scene,
                request,
                AttachTerm::Xterm,
                fresh,
                open,
                cancellation,
            )
            .map_err(WorktreeLaunchError::into_attach_error)?;
            Ok((worker, snapshot, name, geometry, AttachTerm::Xterm))
        }
        Err(error) => Err(error.into_attach_error()),
    }
}

pub(crate) fn launch_fresh_directory_workspace(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtDirectoryWorkspaceOpen,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        String,
        TerminalGeometry,
        AttachTerm,
    ),
    AttachFreshError,
> {
    match launch_fresh_directory_workspace_once(scene, request, term, fresh, open, cancellation) {
        Ok((worker, snapshot, name, geometry)) => Ok((worker, snapshot, name, geometry, term)),
        Err(WorktreeLaunchError::RetryWithXterm) if term == AttachTerm::Xterm256Color => {
            let (worker, snapshot, name, geometry) = launch_fresh_directory_workspace_once(
                scene,
                request,
                AttachTerm::Xterm,
                fresh,
                open,
                cancellation,
            )
            .map_err(WorktreeLaunchError::into_attach_error)?;
            Ok((worker, snapshot, name, geometry, AttachTerm::Xterm))
        }
        Err(error) => Err(error.into_attach_error()),
    }
}

fn validate_opened_kwt_client(
    request: &AttachRequest,
    fresh: &HostSnapshot,
    socket_name: Option<&str>,
    session_name: &str,
    client_identity: &session::SessionIdentity,
    cancellation: &CancellationToken,
    workspace_kind: &str,
) -> Result<HostSnapshot, WorktreeLaunchError> {
    if let Some(socket_name) = socket_name {
        let live = request
            .host
            .capture_live_session_on_socket(
                fresh.endpoint(),
                fresh.runtime(),
                socket_name,
                session_name,
                cancellation,
            )
            .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
        if live.identity() != client_identity {
            return Err(WorktreeLaunchError::Attach(kwt_attachment_failure(
                fresh,
                format!(
                    "KWT attached its client to a session that did not match the {workspace_kind} endpoint"
                ),
            )));
        }
        return Ok(fresh.clone());
    }
    let discovered = request
        .host
        .discover_with_cancel(&ConptyAdmissionAttacher::new(), cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
    if discovered.endpoint() != &request.endpoint || discovered.runtime() != &request.runtime {
        return Err(WorktreeLaunchError::Attach(kwt_attachment_failure(
            fresh,
            format!("WSL changed while opening the {workspace_kind} session"),
        )));
    }
    let identity_matches = discovered
        .sessions()
        .iter()
        .any(|session| session.name() == session_name && session.identity() == client_identity);
    if !identity_matches {
        return Err(WorktreeLaunchError::Attach(kwt_attachment_failure(
            fresh,
            format!(
                "KWT attached its client to a session that did not match the {workspace_kind} inventory"
            ),
        )));
    }
    Ok(discovered)
}

fn launch_fresh_directory_workspace_once(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtDirectoryWorkspaceOpen,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), WorktreeLaunchError> {
    let exact = request
        .host
        .discover_kwt(fresh.endpoint(), fresh.runtime(), cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?
        .is_some_and(|inventory| {
            inventory.directory_workspaces().iter().any(|workspace| {
                workspace.path() == open.path()
                    && workspace.session_name() == open.session_name()
                    && workspace.tmux_socket_name() == open.tmux_socket_name()
                    && workspace.tmux_attach_mode() == KwtTmuxAttachMode::Direct
            })
        });
    if !exact {
        return Err(WorktreeLaunchError::Attach(kwt_attachment_failure(
            fresh,
            "directory workspace endpoint changed; refresh and choose it again",
        )));
    }
    let plan = request
        .host
        .kwt_directory_open_plan(fresh.endpoint(), fresh.runtime(), open, term, cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::repair_or_open_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
        current_default_colors(&scene.runtime),
        current_default_cursor_shape(&scene.runtime),
    )
    .map_err(|error| {
        WorktreeLaunchError::Attach(AttachFreshError::Host(WorkspaceError::new(
            error.to_string(),
        )))
    })?;
    let readiness_path = plan.readiness_path().to_owned();
    let client_identity = wait_for_worktree_client_startup(
        term,
        cancellation,
        &WORKTREE_CLIENT_STARTUP_BACKOFF,
        || {
            worker
                .startup_status()
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
        || {
            request
                .host
                .kwt_client_session_identity(
                    fresh.endpoint(),
                    fresh.runtime(),
                    &readiness_path,
                    open.tmux_socket_name(),
                    cancellation,
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    );
    request.host.remove_kwt_client_readiness(
        fresh.endpoint(),
        &readiness_path,
        &CancellationToken::new(),
    );
    let client_identity = match client_identity {
        Ok(identity) => identity,
        Err(error) => {
            drop(worker);
            return Err(match error {
                WorktreeClientStartupError::RetryWithXterm => WorktreeLaunchError::RetryWithXterm,
                WorktreeClientStartupError::Failed(error) => {
                    WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error))
                }
            });
        }
    };
    let opened = validate_opened_kwt_client(
        request,
        fresh,
        open.tmux_socket_name(),
        open.session_name(),
        &client_identity,
        cancellation,
        "directory workspace",
    );
    match opened {
        Ok(snapshot) => Ok((worker, snapshot, plan.target_name().to_owned(), geometry)),
        Err(error) => {
            drop(worker);
            Err(error)
        }
    }
}

pub(crate) fn launch_fresh_protected_worktree(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtProtectedWorktreeOpen,
    cancellation: &CancellationToken,
) -> Result<
    (
        TerminalWorker,
        HostSnapshot,
        String,
        TerminalGeometry,
        AttachTerm,
    ),
    AttachFreshError,
> {
    match launch_fresh_protected_worktree_once(scene, request, term, fresh, open, cancellation) {
        Ok((worker, snapshot, name, geometry)) => Ok((worker, snapshot, name, geometry, term)),
        Err(WorktreeLaunchError::RetryWithXterm) if term == AttachTerm::Xterm256Color => {
            let (worker, snapshot, name, geometry) = launch_fresh_protected_worktree_once(
                scene,
                request,
                AttachTerm::Xterm,
                fresh,
                open,
                cancellation,
            )
            .map_err(WorktreeLaunchError::into_attach_error)?;
            Ok((worker, snapshot, name, geometry, AttachTerm::Xterm))
        }
        Err(error) => Err(error.into_attach_error()),
    }
}

pub(crate) fn launch_fresh_protected_worktree_once(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtProtectedWorktreeOpen,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), WorktreeLaunchError> {
    validate_protected_worktree_inventory(request, cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
    let plan = request
        .host
        .kwt_protected_attach_plan(fresh.endpoint(), fresh.runtime(), open, term, cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::repair_or_open_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
        current_default_colors(&scene.runtime),
        current_default_cursor_shape(&scene.runtime),
    )
    .map_err(|error| {
        WorktreeLaunchError::Attach(AttachFreshError::Host(WorkspaceError::new(
            error.to_string(),
        )))
    })?;
    let readiness_path = plan.readiness_path().to_owned();
    let client_identity = wait_for_worktree_client_startup(
        term,
        cancellation,
        &WORKTREE_CLIENT_STARTUP_BACKOFF,
        || {
            worker
                .startup_status()
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
        || {
            request
                .host
                .kwt_protected_client_session_identity(
                    fresh.endpoint(),
                    fresh.runtime(),
                    &readiness_path,
                    open.tmux_socket_name(),
                    cancellation,
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    );
    request.host.remove_kwt_client_readiness(
        fresh.endpoint(),
        &readiness_path,
        &CancellationToken::new(),
    );
    match client_identity {
        Ok(_) => {
            validate_protected_worktree_inventory(request, cancellation).map_err(|error| {
                WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error))
            })?;
            Ok((
                worker,
                fresh.clone(),
                plan.target_name().to_owned(),
                geometry,
            ))
        }
        Err(error) => {
            drop(worker);
            Err(match error {
                WorktreeClientStartupError::RetryWithXterm => WorktreeLaunchError::RetryWithXterm,
                WorktreeClientStartupError::Failed(error) => {
                    WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error))
                }
            })
        }
    }
}

pub(crate) fn launch_fresh_worktree_once(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    open: &host::KwtWorktreeOpen,
    cancellation: &CancellationToken,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), WorktreeLaunchError> {
    let plan = request
        .host
        .kwt_repair_or_open_plan(fresh.endpoint(), fresh.runtime(), open, term, cancellation)
        .map_err(|error| WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error)))?;
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::repair_or_open_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
        current_default_colors(&scene.runtime),
        current_default_cursor_shape(&scene.runtime),
    )
    .map_err(|error| {
        WorktreeLaunchError::Attach(AttachFreshError::Host(WorkspaceError::new(
            error.to_string(),
        )))
    })?;
    let readiness_path = plan.readiness_path().to_owned();
    let client_identity = wait_for_worktree_client_startup(
        term,
        cancellation,
        &WORKTREE_CLIENT_STARTUP_BACKOFF,
        || {
            worker
                .startup_status()
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
        || {
            request
                .host
                .kwt_client_session_identity(
                    fresh.endpoint(),
                    fresh.runtime(),
                    &readiness_path,
                    open.tmux_socket_name(),
                    cancellation,
                )
                .map_err(|error| WorkspaceError::new(error.to_string()))
        },
    );
    request.host.remove_kwt_client_readiness(
        fresh.endpoint(),
        &readiness_path,
        &CancellationToken::new(),
    );
    let client_identity = match client_identity {
        Ok(identity) => identity,
        Err(error) => {
            drop(worker);
            return Err(match error {
                WorktreeClientStartupError::RetryWithXterm => WorktreeLaunchError::RetryWithXterm,
                WorktreeClientStartupError::Failed(error) => {
                    WorktreeLaunchError::Attach(kwt_attachment_failure(fresh, error))
                }
            });
        }
    };
    let opened = validate_opened_kwt_client(
        request,
        fresh,
        open.tmux_socket_name(),
        open.session_name(),
        &client_identity,
        cancellation,
        "worktree",
    );
    match opened {
        Ok(snapshot) => Ok((worker, snapshot, plan.target_name().to_owned(), geometry)),
        Err(error) => {
            drop(worker);
            Err(error)
        }
    }
}

pub(crate) fn launch_fresh_herdr(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    session: &session::HerdrSessionRecord,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let AttachTarget::Herdr { executable, .. } = &request.target else {
        unreachable!("Herdr launch requires a Herdr target");
    };
    let operation_key = request
        .herdr_operation_key()
        .expect("Herdr launch has an operation key");
    let (worker, geometry) = with_herdr_launch_fence(
        &scene.runtime.herdr_lifecycle,
        &operation_key,
        || AttachFreshError::SessionChanged {
            error: WorkspaceError::new(
                "Herdr session lifecycle is changing; wait for inventory to refresh",
            ),
            snapshot: Box::new(fresh.clone()),
        },
        || {
            let plan = request
                .host
                .herdr_attach_plan(fresh.endpoint(), executable, session, term);
            let geometry = *scene
                .terminal_geometry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let worker = TerminalWorker::attach_herdr_with_metadata(
                &plan,
                geometry.grid,
                geometry.sequence,
                geometry.pixels,
                ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
                current_default_colors(&scene.runtime),
                current_default_cursor_shape(&scene.runtime),
            )
            .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
            Ok((worker, geometry))
        },
    )?;
    Ok((worker, fresh.clone(), session.name().to_owned(), geometry))
}

pub(crate) fn launch_fresh_zellij(
    scene: &Scene,
    request: &AttachRequest,
    term: AttachTerm,
    fresh: &HostSnapshot,
    session: &session::ZellijSessionRecord,
) -> Result<(TerminalWorker, HostSnapshot, String, TerminalGeometry), AttachFreshError> {
    let AttachTarget::Zellij { executable, .. } = &request.target else {
        unreachable!("Zellij launch requires a Zellij target");
    };
    let plan = request
        .host
        .zellij_attach_plan(fresh.endpoint(), executable, session, term);
    let geometry = *scene
        .terminal_geometry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let worker = TerminalWorker::attach_zellij_with_metadata(
        &plan,
        geometry.grid,
        geometry.sequence,
        geometry.pixels,
        ClipboardPolicy::remote(scene.runtime.allow_remote_clipboard_write),
        current_default_colors(&scene.runtime),
        current_default_cursor_shape(&scene.runtime),
    )
    .map_err(|error| AttachFreshError::Host(WorkspaceError::new(error.to_string())))?;
    Ok((worker, fresh.clone(), session.name().to_owned(), geometry))
}

pub(crate) fn set_terminal_notice(scene: &Scene, term: AttachTerm) {
    let notice = (term == AttachTerm::Xterm).then(|| WorkspaceNotice {
        message: REDUCED_COLOR_NOTICE.to_owned(),
        transient: true,
    });
    *scene
        .terminal_notice
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = notice;
}

pub(crate) fn set_local_notice(scene: &Scene, message: String) {
    *scene
        .terminal_notice
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(WorkspaceNotice {
        message,
        transient: false,
    });
}

pub(crate) fn publish_local_notice(scene: &Scene, message: String) {
    set_local_notice(scene, message);
    bump_scene_revision(scene);
}

pub(crate) fn clear_terminal_notice(scene: &Scene) {
    *scene
        .terminal_notice
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
}

/// Record one scene-local change so only this scene's snapshot revision
/// advances; runtime broadcasts keep bumping the runtime revision.
pub(crate) fn bump_scene_revision(scene: &Scene) {
    scene.revision.fetch_add(1, Ordering::Release);
}

pub(crate) fn set_scene_state(scene: &Scene, state: WorkspaceContent) {
    *scene
        .state
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = state;
    bump_scene_revision(scene);
}

/// Publish one inventory transition to the runtime host list and project it
/// into every registered scene that is not presenting a terminal.
pub(crate) fn set_inventory_state(runtime: &Runtime, state: &WorkspaceContent) {
    let host_updated = {
        let mut hosts = runtime
            .hosts
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") {
            match state {
                WorkspaceContent::Loading => {
                    host.connection = HostConnectionState::Connecting;
                    host.diagnostic = None;
                }
                WorkspaceContent::Ready { endpoint, sessions } => {
                    if host.endpoint != *endpoint {
                        host.projects.clear();
                        host.directory_workspaces.clear();
                        host.kwt_state = KwtState::Uninitialized;
                        host.kwt_diagnostic = None;
                    }
                    host.endpoint.clone_from(endpoint);
                    host.connection = HostConnectionState::Ready;
                    host.sessions.clone_from(sessions);
                    reconcile_kwt_session_availability(host);
                    host.diagnostic = None;
                }
                WorkspaceContent::Error { message } => {
                    host.connection = HostConnectionState::Unavailable;
                    host.diagnostic = Some(HostDiagnostic::new(
                        DiagnosticKind::Transport,
                        message.clone(),
                    ));
                }
                WorkspaceContent::Shell
                | WorkspaceContent::Attaching { .. }
                | WorkspaceContent::Terminal { .. } => {}
            }
            true
        } else {
            false
        }
    };
    if host_updated && runtime.host_scoped_inventory {
        for_each_scene(runtime, |scene| {
            let mut current = scene
                .state
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !matches!(
                *current,
                WorkspaceContent::Shell
                    | WorkspaceContent::Attaching { .. }
                    | WorkspaceContent::Terminal { .. }
            ) {
                *current = WorkspaceContent::Shell;
            }
        });
        runtime.revision.fetch_add(1, Ordering::Release);
        return;
    }
    publish_legacy_inventory_state(runtime, state);
}

/// Store the legacy top-level inventory state and project it into every
/// registered scene that is not attaching to or presenting a terminal.
pub(crate) fn publish_legacy_inventory_state(runtime: &Runtime, state: &WorkspaceContent) {
    *runtime
        .inventory_state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = state.clone();
    let mut projected = false;
    for_each_scene(runtime, |scene| {
        let mut current = scene
            .state
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if matches!(
            &*current,
            WorkspaceContent::Attaching { .. } | WorkspaceContent::Terminal { .. }
        ) {
            return;
        }
        *current = state.clone();
        projected = true;
    });
    if projected {
        runtime.revision.fetch_add(1, Ordering::Release);
    }
}

pub(crate) fn set_wsl_host_unavailable(runtime: &Runtime, kind: DiagnosticKind, message: String) {
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") {
        host.connection = HostConnectionState::Unavailable;
        host.diagnostic = Some(HostDiagnostic::new(kind, message.clone()));
        if runtime.host_scoped_inventory {
            runtime.revision.fetch_add(1, Ordering::Release);
            return;
        }
    }
    drop(hosts);
    publish_legacy_inventory_state(runtime, &WorkspaceContent::Error { message });
}

/// Deny the scene's withheld paste: clear the confirmation slot and send
/// the paste cancel to the owning worker so it resumes suspended command
/// intake. Every path that swallows a paste confirmation must come through
/// here (or send the worker cancel itself); clearing the slot alone leaves
/// the worker suspended with no dialog able to release it.
pub(crate) fn cancel_pending_paste(scene: &Scene) {
    let paste = scene
        .pending_paste
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
    let Some(paste) = paste else {
        return;
    };
    let worker = scene
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if paste.worker_generation == worker.generation()
        && let Some(worker) = worker.active()
    {
        let _cancelled = worker.cancel_paste();
    }
}

pub(crate) fn clear_pending_paste(scene: &Scene) {
    scene
        .pending_paste
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
}

pub(crate) fn publish_terminfo_retry_boundary(
    scene: &Scene,
    host_id: &str,
    endpoint: &str,
    session: &str,
    kind: SessionKind,
) {
    clear_pending_paste(scene);
    set_scene_state(
        scene,
        WorkspaceContent::Attaching {
            host_id: host_id.to_owned(),
            endpoint: endpoint.to_owned(),
            session: session.to_owned(),
            kind,
        },
    );
}
