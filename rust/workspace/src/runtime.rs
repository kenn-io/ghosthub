//! Process-wide runtime state shared by every scene.

use crate::{
    Appearance, Arc, AtomicBool, AtomicU64, AtomicUsize, AttachRequest, CancellationToken,
    DiagnosticKind, HashMap, HerdrInventory, HerdrLaunchPrecondition, HerdrLaunchTarget,
    HerdrLifecycleReconciliation, HerdrLifecycleState, HerdrOperationKey, HerdrSessionName,
    HerdrSessionState, HostConnectionState, HostContext, HostDiagnostic, HostItem, HostSnapshot,
    KwtSshExecutable, KwtState, KwtWorktreeListing, Mutex, Ordering, PendingCreation,
    PendingHerdrLifecycle, PendingKwtCreation, PresentationKey, ProjectItem, Published,
    RefreshRuntime, RemoteAttachmentAttempt, RemoteConstructiveState, RemoteConstructiveTarget,
    RemoteEntry, RemoteHerdrAttachRequest, RemoteHerdrCreateRequest, RemoteTmuxAttachRequest,
    RemoteTmuxConfig, RemoteTmuxSnapshot, RemoteZellijAttachRequest, RemoteZellijCreateRequest,
    RuntimeHost, RuntimeRemoteHost, RwLock, Scene, SessionItem, SessionKind, SessionSelection,
    SettingsState, SharedCommandRunner, SshExecutable, SuppressedHerdrPresentation, Weak,
    WorkspaceContent, WorkspaceError, WslConfig, WslDiscovery, WslExecutable, ZellijInventory,
    ZellijSessionName, apply_herdr_inventory, apply_zellij_inventory, current_remote_context,
    refreshed_session_name, remote_snapshot_authority_matches, resolve_remote_herdr_attach_target,
    resolve_remote_zellij_attach_target, validate_herdr_launch_precondition,
    worktree_tmux_presentation_key,
};
pub(crate) fn equivalent_tmux_presentation_key(
    runtime: &Runtime,
    request: &AttachRequest,
) -> Option<PresentationKey> {
    let published_host = runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let host = published_host.as_ref().filter(|published| {
        published.value.snapshot.endpoint() == &request.endpoint
            && published.value.snapshot.runtime() == &request.runtime
    })?;
    worktree_tmux_presentation_key(request, &host.value.snapshot)
}

/// Process-wide state: host connections, inventory discovery and
/// reconciliation, mutation serialization, and generation-fenced revision
/// publication. One `Runtime` exists per process and is shared by every
/// `Scene`.
#[allow(
    clippy::struct_field_names,
    reason = "`refresh_runtime` keeps the established RefreshRuntime service name"
)]
pub(crate) struct Runtime {
    pub(crate) appearance: RwLock<Appearance>,
    pub(crate) cursor_default: crate::CursorDefault,
    pub(crate) host_scoped_inventory: bool,
    pub(crate) wsl_config: Option<WslConfig>,
    pub(crate) wsl_executable: Mutex<Option<WslExecutable>>,
    pub(crate) hosts: RwLock<Vec<HostItem>>,
    pub(crate) inventory_state: Mutex<WorkspaceContent>,
    pub(crate) revision: AtomicU64,
    pub(crate) snapshot_writers: AtomicUsize,
    pub(crate) remote_publication: Mutex<()>,
    pub(crate) presentation_generation: AtomicU64,
    pub(crate) operation_sequence: AtomicU64,
    pub(crate) host: Mutex<Option<Published<HostContext>>>,
    pub(crate) remote_hosts: Mutex<HashMap<String, RemoteEntry>>,
    pub(crate) remote_runner: SharedCommandRunner,
    pub(crate) remote_controller: Option<KwtSshExecutable>,
    pub(crate) ssh_executable: Option<SshExecutable>,
    pub(crate) settings: Mutex<Option<SettingsState>>,
    /// Serializes every settings mutation from persistence through runtime
    /// publication, so concurrent scenes cannot publish out of persistence
    /// order and an edit cannot republish a host a racing removal deleted.
    /// Acquired before any scene navigation lock.
    pub(crate) settings_mutation: Mutex<()>,
    pub(crate) discovery_cancel: Mutex<Option<CancellationToken>>,
    /// Serializes pump passes; with `Workspace::drain_events` reduced to an
    /// inbox read, the pump is structurally the only internal consumer of
    /// worker events.
    pub(crate) event_drain: Mutex<()>,
    /// Latched once the background event pump is scheduled.
    pub(crate) zellij_kills: Mutex<ZellijKillState>,
    pub(crate) pump_started: AtomicBool,
    /// Serializes pump scheduling so `pump_started` is truthful (see
    /// `start_event_pump`).
    pub(crate) pump_scheduling: Mutex<()>,
    pub(crate) herdr_lifecycle: Mutex<HerdrLifecycleState>,
    pub(crate) session_operations: Mutex<()>,
    pub(crate) remote_constructive_in_flight: AtomicBool,
    pub(crate) allow_remote_clipboard_write: bool,
    pub(crate) refresh_generation: AtomicU64,
    pub(crate) refresh_finished: AtomicU64,
    pub(crate) refresh_publication: Mutex<()>,
    pub(crate) inventory_cadence_started: AtomicBool,
    pub(crate) kwt_cadence_started: AtomicBool,
    pub(crate) kwt_refresh_generation: AtomicU64,
    pub(crate) kwt_discovery_cancel: Mutex<Option<CancellationToken>>,
    pub(crate) kwt_publication: Mutex<()>,
    pub(crate) kwt_mutation_in_flight: AtomicBool,
    pub(crate) kwt_worktree_listing: Mutex<Option<KwtWorktreeListing>>,
    pub(crate) pending_kwt_creations: Mutex<Vec<PendingKwtCreation>>,
    pub(crate) discovery: Arc<dyn WslDiscovery>,
    pub(crate) refresh_runtime: Arc<dyn RefreshRuntime>,
    pub(crate) scene_sequence: AtomicU64,
    pub(crate) scenes: Mutex<Vec<(SceneId, Weak<Scene>)>>,
}

/// Opaque identity of one scene over the shared runtime, minted
/// monotonically for the life of the process.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct SceneId(u64);

pub(crate) fn next_scene_id(runtime: &Runtime) -> SceneId {
    SceneId(
        runtime
            .scene_sequence
            .fetch_add(1, Ordering::AcqRel)
            .checked_add(1)
            .expect("workspace scene sequence exhausted"),
    )
}

pub(crate) fn register_scene(runtime: &Runtime, scene: &Arc<Scene>) {
    let mut scenes = runtime
        .scenes
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    scenes.retain(|(_, registered)| registered.strong_count() > 0);
    scenes.push((scene.id, Arc::downgrade(scene)));
}

/// Remove one closed scene from the registry so no later broadcast,
/// fan-out, or pump pass collects it, even while background tasks still
/// hold strong references to it. Idempotent; dead registrations are pruned
/// on the way through.
pub(crate) fn unregister_scene(runtime: &Runtime, id: SceneId) {
    runtime
        .scenes
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .retain(|(registered, scene)| *registered != id && scene.strong_count() > 0);
}

/// Collect strong references to every live scene in registration order,
/// pruning dead registrations. The registry lock is released before the
/// references are returned, so scene locks are only ever taken after
/// runtime locks and no caller can observe a scene mid-drop. Callers that
/// hold locks on multiple scenes at once must acquire them in the returned
/// registration order so multi-scene acquisition has one global order.
pub(crate) fn live_scenes(runtime: &Runtime) -> Vec<Arc<Scene>> {
    let mut registry = runtime
        .scenes
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    registry.retain(|(_, registered)| registered.strong_count() > 0);
    registry
        .iter()
        .filter_map(|(_, registered)| registered.upgrade())
        .collect()
}

/// Find one live scene to re-anchor a cadence on, or clear the cadence's
/// started flag when none remains. The lookup and the clear happen under
/// the scene registry lock — the same lock scene registration takes — so a
/// concurrently registering scene is either found here or registers after
/// the clear and restarts the cadence through its startup gate. No
/// interleaving leaves a live scene behind a cleared, unscheduled cadence.
pub(crate) fn cadence_fallback_scene(
    runtime: &Runtime,
    started: &AtomicBool,
) -> Option<Arc<Scene>> {
    let mut registry = runtime
        .scenes
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    registry.retain(|(_, registered)| registered.strong_count() > 0);
    if let Some(scene) = registry.iter().find_map(|(_, registered)| {
        registered
            .upgrade()
            .filter(|scene| !scene.closed.load(Ordering::Acquire))
    }) {
        return Some(scene);
    }
    started.store(false, Ordering::Release);
    None
}

/// One reservable Zellij kill target. Zellij sessions have no stable
/// generations, so identity is by name on one host runtime; the fence
/// keeps two confirmed kills for the same name from queuing, where the
/// later one would kill a newly discovered same-name replacement.
pub(crate) type ZellijKillKey = (String, String, String);

#[derive(Default)]
pub(crate) struct ZellijKillState {
    in_flight: std::collections::HashSet<ZellijKillKey>,
    revisions: std::collections::HashMap<ZellijKillKey, u64>,
}

/// Reserve one Zellij kill; `None` means a kill for the same target is
/// already confirmed or running and this one must be refused. The returned
/// revision is rechecked after the operation lane is acquired.
pub(crate) fn reserve_zellij_kill(runtime: &Runtime, key: ZellijKillKey) -> Option<u64> {
    let mut kills = runtime
        .zellij_kills
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let revision = kills.revisions.get(&key).copied().unwrap_or(0);
    if !kills.in_flight.insert(key) {
        return None;
    }
    Some(revision)
}

/// Whether a reserved kill is still current once its task holds the
/// operation lane; a completed kill of the same target advanced the
/// revision, and the stale task must refuse rather than kill again.
pub(crate) fn zellij_kill_is_current(
    runtime: &Runtime,
    key: &ZellijKillKey,
    revision: u64,
) -> bool {
    let kills = runtime
        .zellij_kills
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    kills.revisions.get(key).copied().unwrap_or(0) == revision
}

/// Release one reserved kill; a completed kill advances the target's
/// revision so anything still holding the old one is fenced.
pub(crate) fn release_zellij_kill(runtime: &Runtime, key: &ZellijKillKey, completed: bool) {
    let mut kills = runtime
        .zellij_kills
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    kills.in_flight.remove(key);
    if completed {
        *kills.revisions.entry(key.clone()).or_insert(0) += 1;
    }
}

/// Find one live, not-closed scene by id, for work that must land on
/// exactly its owning scene or nowhere.
pub(crate) fn scene_by_id(runtime: &Runtime, id: SceneId) -> Option<Arc<Scene>> {
    let registry = runtime
        .scenes
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    registry
        .iter()
        .find(|(scene_id, _)| *scene_id == id)
        .and_then(|(_, registered)| registered.upgrade())
        .filter(|scene| !scene.closed.load(Ordering::Acquire))
}

/// Visit every live scene with strong references collected before any
/// scene lock is taken.
pub(crate) fn for_each_scene(runtime: &Runtime, mut visit: impl FnMut(&Arc<Scene>)) {
    for scene in &live_scenes(runtime) {
        visit(scene);
    }
}

pub(crate) struct SnapshotWrite<'a> {
    pub(crate) writers: &'a AtomicUsize,
}

pub(crate) fn remote_host_for_connection(
    runtime: &Runtime,
    config: RemoteTmuxConfig,
    native_host: Option<RuntimeRemoteHost>,
    cancellation: &CancellationToken,
) -> Result<RuntimeRemoteHost, host::RemoteTmuxError> {
    if let Some(host) = native_host {
        return Ok(host);
    }
    let (wsl_host, snapshot) = runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .map(|context| (context.value.host.clone(), context.value.snapshot.clone()))
        .ok_or_else(|| {
            host::RemoteTmuxError::transport("Connect the WSL host before connecting an SSH host")
        })?;
    wsl_host
        .remote_tmux_host(
            snapshot.endpoint(),
            snapshot.runtime(),
            config,
            cancellation,
        )
        .map_err(|error| host::RemoteTmuxError::from_host(&error))
}

pub(crate) fn pending_remote_constructive_snapshot(
    runtime: &Runtime,
    host_id: &str,
    generation: u64,
    target: &RemoteConstructiveTarget,
) -> Option<RemoteTmuxSnapshot> {
    runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(host_id)
        .and_then(|entry| {
            (entry.generation == generation
                && matches!(
                    entry.constructive_cancellation.as_ref(),
                    Some(RemoteConstructiveState::PendingReconciliation(current))
                        if current == target
                ))
            .then_some(entry.context.as_ref())
            .flatten()
            .filter(|context| context.generation == generation)
            .map(|context| context.snapshot.clone())
        })
}

#[cfg(test)]
pub(crate) fn pending_remote_constructive_target(
    runtime: &Runtime,
    host_id: &str,
) -> Option<RemoteConstructiveTarget> {
    runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(host_id)
        .and_then(|entry| match entry.constructive_cancellation.as_ref() {
            Some(RemoteConstructiveState::PendingReconciliation(target)) => Some(target.clone()),
            Some(RemoteConstructiveState::Active { .. }) | None => None,
        })
}

pub(crate) fn clear_pending_remote_constructive(
    runtime: &Runtime,
    host_id: &str,
    generation: u64,
    target: &RemoteConstructiveTarget,
) {
    let mut entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(entry) = entries.get_mut(host_id) else {
        return;
    };
    if entry.generation == generation
        && matches!(
            entry.constructive_cancellation.as_ref(),
            Some(RemoteConstructiveState::PendingReconciliation(current)) if current == target
        )
    {
        entry.constructive_cancellation = None;
    }
}

pub(crate) fn set_remote_host_snapshot(
    runtime: &Runtime,
    host_id: &str,
    snapshot: &RemoteTmuxSnapshot,
) {
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == host_id) else {
        return;
    };
    host.connection = HostConnectionState::Ready;
    host.sessions = snapshot
        .sessions()
        .iter()
        .map(|session| SessionItem::new(session.name(), session.attached_clients()))
        .collect();
    host.diagnostic = None;
    host.tmux_available = snapshot.tmux_binary().is_some();
    host.tmux_diagnostic = snapshot
        .tmux_diagnostic()
        .map(|error| HostDiagnostic::new(error.kind(), error.to_string()));
    apply_herdr_inventory(host, snapshot.herdr());
    apply_zellij_inventory(host, snapshot.zellij());
    runtime.revision.fetch_add(1, Ordering::Release);
}

pub(crate) fn set_remote_herdr_launch_pending(
    runtime: &Runtime,
    host_id: &str,
    name: &str,
    pending: bool,
) {
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(session) = hosts
        .iter_mut()
        .find(|host| host.id == host_id)
        .and_then(|host| {
            host.herdr_sessions
                .iter_mut()
                .find(|session| session.name == name)
        })
    else {
        return;
    };
    if session.launch_pending != pending {
        session.launch_pending = pending;
        runtime.revision.fetch_add(1, Ordering::Release);
    }
}

pub(crate) fn set_remote_host_state(
    runtime: &Runtime,
    host_id: &str,
    connection: HostConnectionState,
    sessions: Option<Vec<SessionItem>>,
    diagnostic: Option<HostDiagnostic>,
) {
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == host_id) else {
        return;
    };
    host.connection = connection;
    if let Some(sessions) = sessions {
        host.sessions = sessions;
    }
    host.diagnostic = diagnostic;
    runtime.revision.fetch_add(1, Ordering::Release);
}

impl Drop for SnapshotWrite<'_> {
    fn drop(&mut self) {
        self.writers.fetch_sub(1, Ordering::Release);
    }
}

pub(crate) fn begin_snapshot_write(runtime: &Runtime) -> SnapshotWrite<'_> {
    runtime.snapshot_writers.fetch_add(1, Ordering::AcqRel);
    SnapshotWrite {
        writers: &runtime.snapshot_writers,
    }
}

/// Read one scene's snapshot at a revision composed from the runtime and
/// scene revision counters. The global snapshot-writer gate still spans
/// cross-tier writes, and the composed revision is monotonic because both
/// counters only grow.
pub(crate) fn read_scene_revision_consistent<T>(
    runtime: &Runtime,
    scene: &Scene,
    mut read: impl FnMut(u64) -> T,
) -> T {
    loop {
        while runtime.snapshot_writers.load(Ordering::Acquire) != 0 {
            std::thread::yield_now();
        }
        let runtime_before = runtime.revision.load(Ordering::Acquire);
        let scene_before = scene.revision.load(Ordering::Acquire);
        let value = read(runtime_before.saturating_add(scene_before));
        if runtime.snapshot_writers.load(Ordering::Acquire) == 0
            && runtime.revision.load(Ordering::Acquire) == runtime_before
            && scene.revision.load(Ordering::Acquire) == scene_before
        {
            return value;
        }
    }
}

#[cfg(test)]
pub(crate) fn read_revision_consistent<T>(
    revision: &AtomicU64,
    writers: &AtomicUsize,
    mut read: impl FnMut(u64) -> T,
) -> T {
    loop {
        while writers.load(Ordering::Acquire) != 0 {
            std::thread::yield_now();
        }
        let before = revision.load(Ordering::Acquire);
        let value = read(before);
        if writers.load(Ordering::Acquire) == 0 && revision.load(Ordering::Acquire) == before {
            return value;
        }
    }
}

pub(crate) fn finish_herdr_launch(runtime: &Runtime, key: &HerdrOperationKey) {
    if runtime
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .finish_launch(key)
    {
        runtime.revision.fetch_add(1, Ordering::Release);
    }
}

pub(crate) fn finish_pending_creation(runtime: &Runtime, pending: &PendingCreation) {
    if let Some(key) = &pending.herdr_operation {
        finish_herdr_launch(runtime, key);
    }
}

pub(crate) fn require_current_protected_selection(
    runtime: &Runtime,
    selection: &SessionSelection,
) -> Result<(), WorkspaceError> {
    let Some(socket_name) = selection.tmux_socket_name() else {
        return Ok(());
    };
    let exact_worktree = runtime
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .filter(|host| {
            host.id() == selection.host_id()
                && host.endpoint() == selection.endpoint()
                && host.connection() == HostConnectionState::Ready
        })
        .flat_map(HostItem::projects)
        .flat_map(ProjectItem::worktrees)
        .any(|worktree| {
            worktree.session_name() == selection.session()
                && worktree.tmux_socket_name() == Some(socket_name)
                && worktree.path() == selection.worktree_path().unwrap_or_default()
                && worktree.generation() == selection.worktree_generation()
        });
    if exact_worktree {
        Ok(())
    } else {
        Err(WorkspaceError::new(
            "protected worktree is not in the current inventory",
        ))
    }
}

pub(crate) fn capture_remote_herdr_create_request(
    runtime: &Runtime,
    host_id: &str,
    endpoint: &str,
    name: HerdrSessionName,
) -> Result<RemoteHerdrCreateRequest, WorkspaceError> {
    require_host_session_actions(
        runtime,
        &SessionSelection::herdr(host_id, endpoint, name.as_str()),
    )?;
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(host_id)
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before creating a session"))?;
    if context.snapshot.endpoint() != endpoint {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before creating the session",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = context.snapshot.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    if sessions
        .iter()
        .any(|session| session.name() == name.as_str())
    {
        return Err(WorkspaceError::new(
            "a Herdr session with this name already exists; restart it instead",
        ));
    }
    Ok(RemoteHerdrCreateRequest {
        host_id: host_id.to_owned(),
        connection_generation: entry.generation,
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        name: HerdrLaunchTarget::created(name),
        precondition: HerdrLaunchPrecondition::Absent,
    })
}

pub(crate) fn capture_remote_zellij_create_request(
    runtime: &Runtime,
    host_id: &str,
    endpoint: &str,
    name: ZellijSessionName,
) -> Result<RemoteZellijCreateRequest, WorkspaceError> {
    require_host_session_actions(
        runtime,
        &SessionSelection::zellij(host_id, endpoint, name.as_str()),
    )?;
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(host_id)
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before creating a session"))?;
    if context.snapshot.endpoint() != endpoint {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before creating the session",
        ));
    }
    let ZellijInventory::Available {
        executable,
        sessions,
    } = context.snapshot.zellij()
    else {
        return Err(WorkspaceError::new(
            "Zellij is not available on this SSH host",
        ));
    };
    if sessions
        .iter()
        .any(|session| session.name() == name.as_str())
    {
        return Err(WorkspaceError::new(
            "a Zellij session with this name already exists",
        ));
    }
    Ok(RemoteZellijCreateRequest {
        host_id: host_id.to_owned(),
        connection_generation: entry.generation,
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        name,
    })
}

pub(crate) fn capture_remote_tmux_attach_request(
    runtime: &Runtime,
    selection: &SessionSelection,
) -> Result<RemoteTmuxAttachRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Tmux {
        return Err(WorkspaceError::new(
            "the selected session is not a tmux session",
        ));
    }
    require_host_session_actions(runtime, selection)?;
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before opening a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before opening the session",
        ));
    }
    let session = context
        .snapshot
        .sessions()
        .iter()
        .find(|session| session.name() == selection.session())
        .cloned()
        .ok_or_else(|| WorkspaceError::new("session is not in current remote inventory"))?;
    Ok(RemoteTmuxAttachRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        selection: selection.clone(),
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        session,
    })
}

pub(crate) fn capture_remote_zellij_attach_request(
    runtime: &Runtime,
    selection: &SessionSelection,
) -> Result<RemoteZellijAttachRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Zellij {
        return Err(WorkspaceError::new(
            "the selected session is not a Zellij session",
        ));
    }
    require_host_session_actions(runtime, selection)?;
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before opening a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before opening the session",
        ));
    }
    let ZellijInventory::Available {
        executable,
        sessions,
    } = context.snapshot.zellij()
    else {
        return Err(WorkspaceError::new(
            "Zellij is not available on this SSH host",
        ));
    };
    let session = sessions
        .iter()
        .find(|session| session.name() == selection.session())
        .ok_or_else(|| WorkspaceError::new("Zellij session is no longer active"))?;
    Ok(RemoteZellijAttachRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        selection: selection.clone(),
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        name: session.name().to_owned(),
    })
}

pub(crate) fn capture_remote_herdr_attach_request(
    runtime: &Runtime,
    selection: &SessionSelection,
) -> Result<RemoteHerdrAttachRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "the selected session is not a Herdr session",
        ));
    }
    require_host_session_actions(runtime, selection)?;
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before opening a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before opening the session",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = context.snapshot.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    let session = sessions
        .iter()
        .find(|session| {
            session.name() == selection.session() && session.state() == HerdrSessionState::Running
        })
        .cloned()
        .ok_or_else(|| WorkspaceError::new("Herdr session is no longer running"))?;
    Ok(RemoteHerdrAttachRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        selection: selection.clone(),
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        session,
    })
}

pub(crate) fn capture_remote_herdr_restart_request(
    runtime: &Runtime,
    selection: &SessionSelection,
) -> Result<RemoteHerdrCreateRequest, WorkspaceError> {
    if selection.kind() != SessionKind::Herdr {
        return Err(WorkspaceError::new(
            "the selected session is not a Herdr session",
        ));
    }
    require_host_session_actions(runtime, selection)?;
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(selection.host_id())
        .ok_or_else(|| WorkspaceError::new("SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("Connect this SSH host before restarting a session"))?;
    if context.snapshot.endpoint() != selection.endpoint() {
        return Err(WorkspaceError::new(
            "SSH endpoint changed; refresh before restarting the session",
        ));
    }
    let HerdrInventory::Available {
        executable,
        sessions,
    } = context.snapshot.herdr()
    else {
        return Err(WorkspaceError::new(
            "Herdr is not available on this SSH host",
        ));
    };
    let record = sessions
        .iter()
        .find(|session| session.name() == selection.session())
        .cloned()
        .ok_or_else(|| WorkspaceError::new("Herdr session is no longer in inventory"))?;
    if record.state() != HerdrSessionState::Stopped {
        return Err(WorkspaceError::new("Herdr session is already running"));
    }
    Ok(RemoteHerdrCreateRequest {
        host_id: selection.host_id().to_owned(),
        connection_generation: entry.generation,
        host: context.host.clone(),
        snapshot: context.snapshot.clone(),
        executable: executable.clone(),
        name: HerdrLaunchTarget::discovered(&record),
        precondition: HerdrLaunchPrecondition::Stopped(record),
    })
}

pub(crate) fn require_host_session_actions(
    runtime: &Runtime,
    selection: &SessionSelection,
) -> Result<(), WorkspaceError> {
    let hosts = runtime
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let host = hosts
        .iter()
        .find(|host| host.id == selection.host_id() && host.endpoint == selection.endpoint())
        .ok_or_else(|| WorkspaceError::new("the selected host is not available"))?;
    if !host.accepts_session_actions() {
        let message = if host.id == "wsl" {
            "connect the WSL host before changing a session"
        } else {
            "wait for the SSH host connection to be ready before changing a session"
        };
        return Err(WorkspaceError::new(message));
    }
    match selection.kind() {
        SessionKind::Herdr if host.herdr_diagnostic.is_some() => {
            return Err(WorkspaceError::new(
                "refresh Herdr inventory before changing a session",
            ));
        }
        SessionKind::Zellij if host.zellij_diagnostic.is_some() => {
            return Err(WorkspaceError::new(
                "refresh Zellij inventory before changing a session",
            ));
        }
        SessionKind::Tmux | SessionKind::Herdr | SessionKind::Zellij => {}
    }
    Ok(())
}

pub(crate) fn herdr_operation_pending_for_selection(
    runtime: &Runtime,
    selection: &SessionSelection,
) -> bool {
    let lifecycle = runtime
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    lifecycle.launches.iter().any(|operation| {
        operation.endpoint.distro() == selection.endpoint() && operation.name == selection.session()
    }) || lifecycle.in_flight.iter().any(|operation| {
        operation.key.endpoint.distro() == selection.endpoint()
            && operation.key.name == selection.session()
    })
}

pub(crate) fn refresh_is_in_flight(runtime: &Runtime) -> bool {
    runtime
        .discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|cancellation| !cancellation.is_cancelled())
}

pub(crate) fn reserve_refresh(runtime: &Runtime, cancellation: &CancellationToken) -> u64 {
    let _publication = runtime
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = runtime.refresh_generation.fetch_add(1, Ordering::AcqRel) + 1;
    if let Some(previous) = runtime
        .discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .replace(cancellation.clone())
    {
        previous.cancel();
    }
    generation
}

pub(crate) fn reserve_constructive_inventory(runtime: &Runtime) -> u64 {
    let _publication = runtime
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let generation = runtime.refresh_generation.fetch_add(1, Ordering::AcqRel) + 1;
    if let Some(previous) = runtime
        .discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        previous.cancel();
    }
    generation
}

pub(crate) fn publish_refresh(runtime: &Runtime, generation: u64, publish: impl FnOnce()) -> bool {
    let _publication = runtime
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if runtime.refresh_generation.load(Ordering::Acquire) != generation {
        return false;
    }
    let _snapshot_write = begin_snapshot_write(runtime);
    publish();
    true
}

pub(crate) fn invalidate_kwt_inventory(runtime: &Runtime) {
    let _publication = runtime
        .kwt_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    runtime
        .kwt_refresh_generation
        .fetch_add(1, Ordering::AcqRel);
    if let Some(cancellation) = runtime
        .kwt_discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        cancellation.cancel();
    }
    if let Some(host) = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter_mut()
        .find(|host| host.id == "wsl")
    {
        host.projects.clear();
        host.directory_workspaces.clear();
        host.kwt_state = KwtState::Uninitialized;
        host.kwt_diagnostic = None;
    }
}

pub(crate) fn cancel_refresh(runtime: &Runtime) -> bool {
    let _publication = runtime
        .refresh_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let connecting = runtime
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .any(|host| host.id == "wsl" && host.connection == HostConnectionState::Connecting);
    if !connecting {
        return false;
    }
    runtime.refresh_generation.fetch_add(1, Ordering::AcqRel);
    if let Some(cancellation) = runtime
        .discovery_cancel
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        cancellation.cancel();
    }
    set_wsl_host_disconnected(runtime);
    true
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn capture_kwt_worktree_removal_context(
    runtime: &Runtime,
    host_id: &str,
    endpoint: &str,
    repository: &str,
    project_path: &str,
    registration_fingerprint: &str,
    worktree_path: &str,
    generation: &str,
    session_name: &str,
    tmux_socket_name: Option<&str>,
) -> Result<
    (
        RuntimeHost,
        host::WslEndpoint,
        host::WslRuntimeIdentity,
        Option<String>,
    ),
    WorkspaceError,
> {
    if host_id != "wsl" {
        return Err(WorkspaceError::new(
            "KWT worktrees are available only on WSL",
        ));
    }
    let context = runtime
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
        .ok_or_else(|| WorkspaceError::new("refresh WSL before removing a worktree"))?;
    let hosts = runtime
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
            "refresh KWT inventory before removing this worktree",
        ));
    }
    let worktree = item
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
                    && worktree.generation.as_deref() == Some(generation)
                    && worktree.session_name == session_name
                    && worktree.tmux_socket_name.as_deref() == tmux_socket_name
            })
        })
        .ok_or_else(|| {
            WorkspaceError::new("the selected worktree changed; refresh and choose it again")
        })?;
    if worktree.is_main {
        return Err(WorkspaceError::new(
            "the primary checkout cannot be removed",
        ));
    }
    Ok((
        context.0,
        context.1,
        context.2,
        worktree.tmux_socket_name.clone(),
    ))
}

pub(crate) fn remember_pending_kwt_creation(runtime: &Runtime, pending: PendingKwtCreation) {
    let mut creations = runtime
        .pending_kwt_creations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    creations.retain(|candidate| {
        candidate.endpoint != pending.endpoint
            || candidate.repository != pending.repository
            || candidate.project_path != pending.project_path
            || candidate.registration_fingerprint != pending.registration_fingerprint
            || candidate.branch != pending.branch
    });
    creations.push(pending);
}

pub(crate) fn next_operation_id(runtime: &Runtime) -> u64 {
    runtime
        .operation_sequence
        .fetch_add(1, Ordering::AcqRel)
        .checked_add(1)
        .expect("workspace operation sequence exhausted")
}

#[allow(
    clippy::too_many_arguments,
    reason = "constructive registration binds scene, connection, navigation, and target authority in one fence"
)]
pub(crate) fn register_remote_constructive(
    runtime: &Runtime,
    scene: SceneId,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    navigation_generation: u64,
    cancellation: &CancellationToken,
    target: RemoteConstructiveTarget,
) -> Result<Arc<AtomicBool>, WorkspaceError> {
    let mut entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get_mut(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host is no longer configured"))?;
    let context = entry
        .context
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected before session creation"))?;
    if entry.generation != connection_generation
        || !remote_snapshot_authority_matches(&context.snapshot, expected)
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed before session creation; refresh before trying again",
        ));
    }
    if entry.constructive_cancellation.is_some() {
        return Err(WorkspaceError::new(
            "another remote session is already being created or restarted",
        ));
    }
    let launched = Arc::new(AtomicBool::new(false));
    entry.constructive_cancellation = Some(RemoteConstructiveState::Active {
        scene,
        navigation_generation,
        cancellation: cancellation.clone(),
        launched: Arc::clone(&launched),
        target,
    });
    Ok(launched)
}

pub(crate) fn clear_remote_constructive_registration(runtime: &Runtime, host_id: &str) {
    if let Some(entry) = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get_mut(host_id)
    {
        entry.constructive_cancellation = None;
    }
}

pub(crate) fn settle_remote_constructive_task(
    runtime: &Runtime,
    host_id: &str,
    navigation_generation: u64,
    succeeded: bool,
) -> Option<RemoteConstructiveTarget> {
    let mut entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries.get_mut(host_id)?;
    let operation = entry.constructive_cancellation.take()?;
    match operation {
        RemoteConstructiveState::Active {
            navigation_generation: current_generation,
            launched,
            target,
            ..
        } if current_generation == navigation_generation => {
            if succeeded || !launched.load(Ordering::Acquire) {
                None
            } else {
                entry.constructive_cancellation = Some(
                    RemoteConstructiveState::PendingReconciliation(target.clone()),
                );
                Some(target)
            }
        }
        current => {
            entry.constructive_cancellation = Some(current);
            None
        }
    }
}

/// Cancel un-launched constructive operations the initiating scene's newer
/// navigation superseded. Other scenes' constructive operations are never
/// touched; only connection-authority changes cancel across scenes.
pub(crate) fn cancel_superseded_remote_constructive_navigation(
    runtime: &Runtime,
    scene: SceneId,
    generation: u64,
) {
    for entry in runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .values_mut()
    {
        let Some(RemoteConstructiveState::Active {
            scene: initiating_scene,
            navigation_generation,
            cancellation,
            launched,
            ..
        }) = entry.constructive_cancellation.as_ref()
        else {
            continue;
        };
        if *initiating_scene == scene
            && *navigation_generation < generation
            && !launched.load(Ordering::Acquire)
        {
            cancellation.cancel();
        }
    }
}

pub(crate) fn remote_constructive_is_current(
    runtime: &Runtime,
    host_id: &str,
    cancellation: &CancellationToken,
) -> bool {
    !cancellation.is_cancelled()
        && runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(host_id)
            .and_then(|entry| entry.constructive_cancellation.as_ref())
            .is_some_and(|operation| {
                matches!(
                    operation,
                    RemoteConstructiveState::Active {
                        cancellation: current,
                        ..
                    } if !current.is_cancelled()
                )
            })
}

/// Register one scene's attach attempt against a host. A previous attempt
/// by the same scene is superseded and cancelled; other scenes' in-flight
/// attempts on the same host are untouched.
pub(crate) fn register_remote_attachment(
    runtime: &Runtime,
    scene: SceneId,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    navigation_generation: u64,
    cancellation: &CancellationToken,
) -> Result<(), WorkspaceError> {
    let mut entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get_mut(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host is no longer configured"))?;
    let context = entry
        .context
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected before attachment"))?;
    if entry.generation != connection_generation
        || !remote_snapshot_authority_matches(&context.snapshot, expected)
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed before attachment; refresh before trying again",
        ));
    }
    entry.attachment_attempts.retain(|attempt| {
        if attempt.scene == scene {
            attempt.cancellation.cancel();
            false
        } else {
            true
        }
    });
    entry.attachment_attempts.push(RemoteAttachmentAttempt {
        scene,
        navigation_generation,
        cancellation: cancellation.clone(),
    });
    Ok(())
}

pub(crate) fn clear_remote_attachment_registration(
    runtime: &Runtime,
    host_id: &str,
    navigation_generation: u64,
) {
    let mut entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(entry) = entries.get_mut(host_id) {
        // Navigation generations are runtime-minted and unique, so the
        // generation alone identifies the finished attempt.
        entry
            .attachment_attempts
            .retain(|attempt| attempt.navigation_generation != navigation_generation);
    }
}

/// Cancel and remove one scene's attach attempts on every host. Navigation
/// in one scene must not cancel another scene's in-flight attempt, so this
/// is the only scene-initiated cancellation path.
pub(crate) fn cancel_scene_remote_attachments(runtime: &Runtime, scene: SceneId) {
    for entry in runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .values_mut()
    {
        entry.attachment_attempts.retain(|attempt| {
            if attempt.scene == scene {
                attempt.cancellation.cancel();
                false
            } else {
                true
            }
        });
    }
}

pub(crate) fn with_current_remote_constructive<T>(
    runtime: &Runtime,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
    cancellation: &CancellationToken,
    launch: impl FnOnce() -> Result<T, WorkspaceError>,
) -> Result<T, WorkspaceError> {
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host is no longer configured"))?;
    let context = entry
        .context
        .as_ref()
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected before session creation"))?;
    let active = entry
        .constructive_cancellation
        .as_ref()
        .is_some_and(|operation| {
            matches!(
                operation,
                RemoteConstructiveState::Active {
                    cancellation: current,
                    ..
                } if !current.is_cancelled()
            )
        });
    if cancellation.is_cancelled()
        || !active
        || entry.generation != connection_generation
        || !remote_snapshot_authority_matches(&context.snapshot, expected)
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed before session creation; refresh before trying again",
        ));
    }
    launch()
}

pub(crate) fn recapture_remote_attachment_context(
    runtime: &Runtime,
    host_id: &str,
    connection_generation: u64,
    expected: &RemoteTmuxSnapshot,
) -> Result<(RuntimeRemoteHost, RemoteTmuxSnapshot), WorkspaceError> {
    let entries = runtime
        .remote_hosts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = entries
        .get(host_id)
        .ok_or_else(|| WorkspaceError::new("the SSH host is no longer configured"))?;
    let context = current_remote_context(entry)
        .ok_or_else(|| WorkspaceError::new("the SSH host disconnected before attachment"))?;
    if entry.generation != connection_generation
        || context.snapshot.endpoint() != expected.endpoint()
        || context.snapshot.route_identity() != expected.route_identity()
        || context.snapshot.lease_generation() != expected.lease_generation()
    {
        return Err(WorkspaceError::new(
            "the SSH connection changed before attachment; refresh before trying again",
        ));
    }
    Ok((context.host.clone(), context.snapshot.clone()))
}

pub(crate) fn recapture_remote_tmux_attach_request(
    runtime: &Runtime,
    request: &RemoteTmuxAttachRequest,
) -> Result<RemoteTmuxAttachRequest, WorkspaceError> {
    let (host, snapshot) = recapture_remote_attachment_context(
        runtime,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    )?;
    let session = snapshot
        .sessions()
        .iter()
        .find(|session| session.identity() == request.session.identity())
        .cloned()
        .ok_or_else(|| {
            WorkspaceError::new(
                "the remote tmux session changed while waiting; refresh before opening it",
            )
        })?;
    Ok(RemoteTmuxAttachRequest {
        host_id: request.host_id.clone(),
        connection_generation: request.connection_generation,
        selection: SessionSelection::new(&request.host_id, snapshot.endpoint(), session.name()),
        host,
        snapshot,
        session,
    })
}

pub(crate) fn recapture_remote_herdr_attach_request(
    runtime: &Runtime,
    request: &RemoteHerdrAttachRequest,
) -> Result<RemoteHerdrAttachRequest, WorkspaceError> {
    let (host, snapshot) = recapture_remote_attachment_context(
        runtime,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    )?;
    let (executable, session) = resolve_remote_herdr_attach_target(
        snapshot.herdr(),
        &request.executable,
        &request.session,
    )?;
    Ok(RemoteHerdrAttachRequest {
        host_id: request.host_id.clone(),
        connection_generation: request.connection_generation,
        selection: SessionSelection::herdr(&request.host_id, snapshot.endpoint(), session.name()),
        host,
        snapshot,
        executable,
        session,
    })
}

pub(crate) fn recapture_remote_zellij_attach_request(
    runtime: &Runtime,
    request: &RemoteZellijAttachRequest,
) -> Result<RemoteZellijAttachRequest, WorkspaceError> {
    let (host, snapshot) = recapture_remote_attachment_context(
        runtime,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    )?;
    let (executable, session) =
        resolve_remote_zellij_attach_target(snapshot.zellij(), &request.executable, &request.name)?;
    Ok(RemoteZellijAttachRequest {
        host_id: request.host_id.clone(),
        connection_generation: request.connection_generation,
        selection: SessionSelection::zellij(&request.host_id, snapshot.endpoint(), session.name()),
        host,
        snapshot,
        executable,
        name: session.name().to_owned(),
    })
}

/// Recapture a queued remote Herdr construction against the latest
/// same-connection snapshot and revalidate its launch target.
///
/// Another scene's operation may publish refreshed inventory while a
/// construction waits for the operation lane; the connection is unchanged,
/// so only the inventory generation moved. Launch and publication must use
/// the recaptured snapshot or the launch fence would misread the queued
/// construction as stale. Connection-generation checks are unchanged.
pub(crate) fn recapture_remote_herdr_create_request(
    runtime: &Runtime,
    request: &RemoteHerdrCreateRequest,
) -> Result<RemoteHerdrCreateRequest, WorkspaceError> {
    let (host, snapshot) = recapture_remote_attachment_context(
        runtime,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    )
    .map_err(|_| {
        WorkspaceError::new(
            "the SSH connection changed before session creation; refresh before trying again",
        )
    })?;
    let HerdrInventory::Available {
        executable,
        sessions,
    } = snapshot.herdr()
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
    Ok(RemoteHerdrCreateRequest {
        host_id: request.host_id.clone(),
        connection_generation: request.connection_generation,
        host,
        snapshot,
        executable: request.executable.clone(),
        name: request.name.clone(),
        precondition: request.precondition.clone(),
    })
}

/// Recapture a queued remote Zellij construction exactly as
/// `recapture_remote_herdr_create_request` does for Herdr.
pub(crate) fn recapture_remote_zellij_create_request(
    runtime: &Runtime,
    request: &RemoteZellijCreateRequest,
) -> Result<RemoteZellijCreateRequest, WorkspaceError> {
    let (host, snapshot) = recapture_remote_attachment_context(
        runtime,
        &request.host_id,
        request.connection_generation,
        &request.snapshot,
    )
    .map_err(|_| {
        WorkspaceError::new(
            "the SSH connection changed before session creation; refresh before trying again",
        )
    })?;
    let ZellijInventory::Available {
        executable,
        sessions,
    } = snapshot.zellij()
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
    Ok(RemoteZellijCreateRequest {
        host_id: request.host_id.clone(),
        connection_generation: request.connection_generation,
        host,
        snapshot,
        executable: request.executable.clone(),
        name: request.name.clone(),
    })
}

pub(crate) fn finish_herdr_lifecycle_state(runtime: &Runtime, operation_id: u64) {
    let _snapshot_write = begin_snapshot_write(runtime);
    runtime
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .finish(operation_id);
    runtime.revision.fetch_add(1, Ordering::Release);
}

pub(crate) fn current_inventory_session_name(
    runtime: &Runtime,
    key: &PresentationKey,
) -> Option<String> {
    runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .and_then(|published| {
            refreshed_session_name(
                key,
                &published.value.snapshot,
                published.value.host.socket_directory(),
            )
        })
}

pub(crate) fn publish_herdr_lifecycle_uncertain(
    runtime: &Runtime,
    pending: &PendingHerdrLifecycle,
    suppressed: Option<SuppressedHerdrPresentation>,
    message: &str,
) {
    let _snapshot_write = begin_snapshot_write(runtime);
    let reconcile_after_generation = runtime.refresh_generation.load(Ordering::Acquire);
    runtime
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .mark_uncertain(pending, reconcile_after_generation, suppressed);
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(host) = hosts
        .iter_mut()
        .find(|host| host.endpoint == pending.endpoint.distro())
    {
        host.herdr_diagnostic = Some(HostDiagnostic::new(
            DiagnosticKind::Transport,
            message.to_owned(),
        ));
        runtime.revision.fetch_add(1, Ordering::Release);
    }
}

pub(crate) fn set_herdr_inventory(runtime: &Runtime, inventory: &HerdrInventory) {
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") else {
        return;
    };
    apply_herdr_inventory(host, inventory);
}

pub(crate) fn set_zellij_inventory(runtime: &Runtime, inventory: &ZellijInventory) {
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") else {
        return;
    };
    apply_zellij_inventory(host, inventory);
}

pub(crate) fn reconcile_herdr_lifecycle_fences(
    runtime: &Runtime,
    snapshot: &HostSnapshot,
    publication_generation: u64,
    release_recoveries: bool,
) -> HerdrLifecycleReconciliation {
    runtime
        .herdr_lifecycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .reconcile(snapshot, publication_generation, release_recoveries)
}

pub(crate) fn set_wsl_host_disconnected(runtime: &Runtime) {
    let mut hosts = runtime
        .hosts
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(host) = hosts.iter_mut().find(|host| host.id == "wsl") {
        host.connection = HostConnectionState::Disconnected;
        host.diagnostic = None;
        runtime.revision.fetch_add(1, Ordering::Release);
    }
}

pub(crate) fn next_presentation_id(runtime: &Runtime) -> u64 {
    runtime
        .presentation_generation
        .fetch_add(1, Ordering::AcqRel)
        .wrapping_add(1)
}
