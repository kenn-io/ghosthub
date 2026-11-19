//! A Rex window owns one control channel and one ordinary client per tiled pane.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, MutexGuard};
use std::time::{Duration, Instant};

use host::rex::{Direction, Layout, Message, WindowView};
use serde_json::json;
use surface::{GridSize, PixelSize, SurfaceStore};

use crate::{
    CancellationToken, Ordering, Scene, SessionKind, SessionSelection, TerminalWorker, Workspace,
    WorkspaceContent, WorkspaceError, WorkspaceEvent, bump_scene_revision, next_presentation_id,
    runtime, scene,
};

use host::rex::Channel;
mod focus;
mod inventory;
mod pane;
mod ssh;
pub(crate) use inventory::{Refresh, cancel, cancel_scene, refresh};
pub(crate) use pane::prompt_connection_generation;
pub(crate) use ssh::Connections;

pub const PANE_HEADER_HEIGHT: f32 = 26.0;
pub const DIVIDER_WIDTH: f32 = 5.0;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RexRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Clone)]
pub struct RexPaneSnapshot {
    pub id: String,
    pub title: String,
    pub presentation_id: u64,
    pub surface: Arc<SurfaceStore>,
    pub rect: RexRect,
    pub focused: bool,
    pub connecting: bool,
    pub error: Option<String>,
}

#[derive(Clone, Debug)]
pub struct RexDivider {
    pub id: String,
    pub before: String,
    pub after: String,
    pub rect: RexRect,
    pub parent: RexRect,
    pub direction: Direction,
    pub ratio: f64,
}

#[derive(Clone)]
pub struct RexWindowSnapshot {
    pub selection: SessionSelection,
    pub title: String,
    pub panes: Vec<RexPaneSnapshot>,
    pub dividers: Vec<RexDivider>,
    pub error: Option<String>,
}

struct Pane {
    id: u64,
    title: String,
    surface: Arc<SurfaceStore>,
    worker: Option<TerminalWorker>,
    pending: Option<pane::Pending>,
    queued: bool,
    generation: u64,
    rect: RexRect,
    accepted_size: Option<(GridSize, PixelSize)>,
    error: Option<String>,
}

struct Control {
    channel: Channel,
    connection: ssh::Connection,
}

pub(crate) struct Window {
    selection: SessionSelection,
    connection_generation: u64,
    snapshot: host::RemoteTmuxSnapshot,
    host: crate::RuntimeRemoteHost,
    helper: String,
    session_id: String,
    navigation: u64,
    cancellation: CancellationToken,
    control: Option<Control>,
    started: Instant,
    title: String,
    detail: String,
    view: Option<WindowView>,
    revision: Option<u64>,
    panes: BTreeMap<String, Pane>,
    focused: Option<String>,
    requests: BTreeMap<u64, Option<String>>,
    requested_focus: focus::Focus,
    next_request: u64,
    term: host::AttachTerm,
    error: Option<String>,
    ended: bool,
    geometry: (f32, f32, f32, f32),
    dividers: Vec<RexDivider>,
    resize_pending: bool,
}

fn lock(scene: &Scene) -> MutexGuard<'_, Option<Window>> {
    scene
        .rex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn error(message: impl Into<String>) -> WorkspaceError {
    WorkspaceError::new(message)
}

pub(crate) fn snapshot(scene: &Scene) -> Option<RexWindowSnapshot> {
    lock(scene).as_ref().map(|w| RexWindowSnapshot {
        selection: w.selection.clone(),
        title: w.title.clone(),
        error: w.error.clone(),
        panes: w
            .panes
            .iter()
            .map(|(id, p)| RexPaneSnapshot {
                id: id.clone(),
                title: p.title.clone(),
                presentation_id: p.id,
                surface: p.surface.clone(),
                rect: p.rect,
                focused: w.focused.as_ref() == Some(id),
                connecting: p.queued || p.pending.is_some(),
                error: p.error.clone(),
            })
            .collect(),
        dividers: w.dividers.clone(),
    })
}

pub(crate) fn project_inventory(scene: &Scene, hosts: &mut [crate::HostItem]) {
    let state = lock(scene);
    let Some(w) = state.as_ref() else {
        return;
    };
    let Some(host) = hosts
        .iter_mut()
        .find(|h| h.id() == w.selection.host_id() && h.endpoint() == w.selection.endpoint())
    else {
        return;
    };
    if let Some(row) = host
        .rex_windows
        .iter_mut()
        .find(|row| row.id == w.selection.session())
    {
        row.title.clone_from(&w.title);
        row.detail.clone_from(&w.detail);
    } else {
        host.rex_windows.push(host::rex::Window {
            id: w.selection.session().to_owned(),
            session_id: w.session_id.clone(),
            title: w.title.clone(),
            detail: w.detail.clone(),
        });
    }
}

pub(crate) fn detach(scene: &Scene) {
    let previous = lock(scene).take();
    if previous.is_some() {
        drop(take_active_worker(scene));
    }
    if previous.is_some() || pending_on_host(scene, None) {
        scene::restore_scene_inventory_state(scene);
    }
    drop(previous);
}

pub(crate) fn is_on_host(scene: &Scene, host_id: &str) -> bool {
    lock(scene)
        .as_ref()
        .is_some_and(|window| window.selection.host_id() == host_id)
        || pending_on_host(scene, Some(host_id))
}

fn pending_on_host(scene: &Scene, host: Option<&str>) -> bool {
    matches!(
        &*scene.state.read().unwrap_or_else(std::sync::PoisonError::into_inner),
        WorkspaceContent::Attaching { kind: SessionKind::Rex, host_id, .. }
            if host.is_none_or(|id| id == host_id)
    )
}

fn take_active_worker(scene: &Scene) -> Option<TerminalWorker> {
    scene::cancel_pending_paste(scene);
    let worker = scene
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .invalidate();
    if let Some(worker) = &worker {
        scene::retire_clipboard_writes(scene, worker);
    }
    crate::clear_terminal_notice(scene);
    worker
}

/// The active event pump owns clipboard and lifecycle events for the focused
/// pane. Match the worker's surface so a focus change during event extraction
/// still retires the right client, even if that pane is now in the background.
pub(crate) fn pane_failed(scene: &Scene, surface: &Arc<SurfaceStore>, message: String) -> bool {
    if lock(scene).is_none() {
        return false;
    }
    let Ok(_navigation) = scene::lock_live_navigation(scene) else {
        return false;
    };
    let mut state = lock(scene);
    let Some(window) = state.as_mut() else {
        return false;
    };
    let Some((id, pane)) = window
        .panes
        .iter_mut()
        .find(|(_, pane)| Arc::ptr_eq(&pane.surface, surface))
    else {
        return false;
    };
    if window.focused.as_ref() == Some(id) {
        drop(take_active_worker(scene));
    } else {
        pane.worker.take();
    }

    pane.error = Some(message);
    bump_scene_revision(scene);
    true
}

#[allow(
    clippy::too_many_lines,
    reason = "Keep the fenced navigation and background handoff together."
)]
pub(crate) fn open(
    workspace: &Workspace,
    selection: &SessionSelection,
) -> Result<(), WorkspaceError> {
    let scene = &workspace.scene;
    let _publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _navigation = scene::lock_live_navigation(scene)?;
    if lock(scene).as_ref().is_some_and(|w| {
        &w.selection == selection
            && w.error.is_none()
            && runtime::recapture_remote_attachment_context(
                &scene.runtime,
                selection.host_id(),
                w.connection_generation,
                &w.snapshot,
            )
            .is_ok()
    }) {
        return Ok(());
    }
    runtime::require_host_session_actions(&scene.runtime, selection)?;
    let (generation, host, snapshot) = {
        let entries = scene
            .runtime
            .remote_hosts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = entries
            .get(selection.host_id())
            .ok_or_else(|| error("SSH host is no longer configured"))?;
        let context = crate::current_remote_context(entry)
            .ok_or_else(|| error("Connect this SSH host before opening Rex."))?;
        (
            entry.generation,
            context.host.clone(),
            context.snapshot.clone(),
        )
    };
    if snapshot.endpoint() != selection.endpoint() {
        return Err(error("SSH endpoint changed; choose the Rex window again."));
    }
    let (helper, window) = {
        let hosts = scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let item = hosts
            .iter()
            .find(|h| h.id() == selection.host_id())
            .ok_or_else(|| error("SSH host is no longer configured"))?;
        if item.rex_diagnostic.is_some() {
            return Err(error("Refresh Rex inventory before opening this window."));
        }
        let helper = item
            .rex_helper
            .clone()
            .ok_or_else(|| error("Rex discovery is still loading."))?;
        let window = item
            .rex_windows
            .iter()
            .find(|w| w.id == selection.session())
            .cloned()
            .ok_or_else(|| error("Rex window is no longer available."))?;
        (helper, window)
    };
    let navigation = workspace.begin_navigation();
    workspace.settle_local_navigation_before_remote()?;
    workspace.retain_active_presentation()?;
    let previous = scene
        .remote_active
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
    if let Some(active) = previous {
        let worker = take_active_worker(scene);
        if let Some(worker) = worker
            && active.retainable
        {
            crate::insert_remote_retained_presentation(
                &scene.runtime,
                &scene.remote_retained,
                crate::RemoteRetainedPresentation { active, worker },
            );
        }
        scene::restore_scene_inventory_state(scene);
    }
    let cancellation = CancellationToken::new();
    runtime::register_remote_attachment(
        &scene.runtime,
        scene.id,
        selection.host_id(),
        generation,
        &snapshot,
        navigation,
        &cancellation,
    )?;
    scene::set_scene_state(
        scene,
        WorkspaceContent::Attaching {
            host_id: selection.host_id().to_owned(),
            endpoint: selection.endpoint().to_owned(),
            session: window.title.clone(),
            kind: SessionKind::Rex,
        },
    );
    let registered_host = selection.host_id().to_owned();
    let task_scene = Arc::clone(scene);
    let selection = selection.clone();
    let task = move || {
        let result: Result<(), WorkspaceError> = (|| {
            let connection = ssh::Connection::acquire(
                &task_scene,
                &host,
                &snapshot,
                selection.host_id(),
                navigation,
                &cancellation,
            )?;
            let term = host
                .probe_term_on_lease(&connection.lease, &cancellation)
                .map_err(|e| error(e.to_string()))?;
            let plan = host
                .rex_plan(&connection.lease, &helper, &window.id, None)
                .map_err(|e| error(e.to_string()))?;
            let channel = Channel::start(&plan).map_err(error)?;
            let _publication = task_scene
                .runtime
                .remote_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let _navigation = scene::lock_live_navigation(&task_scene)?;
            if !scene::remote_attachment_is_current(
                &task_scene,
                selection.host_id(),
                navigation,
                &cancellation,
            ) {
                return Ok(());
            }
            runtime::recapture_remote_attachment_context(
                &task_scene.runtime,
                selection.host_id(),
                generation,
                &snapshot,
            )?;
            *lock(&task_scene) = Some(Window {
                selection: selection.clone(),
                connection_generation: generation,
                snapshot,
                host,
                helper,
                session_id: window.session_id,
                title: window.title,
                detail: window.detail,
                navigation,
                cancellation,
                control: Some(Control {
                    channel,
                    connection,
                }),
                started: Instant::now(),
                view: None,
                revision: None,
                panes: BTreeMap::new(),
                focused: None,
                requests: BTreeMap::new(),
                requested_focus: focus::Focus::default(),
                next_request: 1,
                term,
                error: None,
                ended: false,
                geometry: (800.0, 600.0, 8.0, 18.0),
                dividers: Vec::new(),
                resize_pending: false,
            });
            bump_scene_revision(&task_scene);
            Ok(())
        })();
        if let Err(e) = result
            && let Ok(_navigation) = scene::lock_live_navigation(&task_scene)
        {
            runtime::clear_remote_attachment_registration(
                &task_scene.runtime,
                selection.host_id(),
                navigation,
            );
            if task_scene.navigation_generation.load(Ordering::Acquire) == navigation {
                scene::restore_scene_inventory_state(&task_scene);
                scene::push_lossless_event(&task_scene, WorkspaceEvent::Error(e.to_string()));
            }
        }
    };
    scene
        .runtime
        .refresh_runtime
        .spawn("ghosthub-rex-window", Box::new(task))
        .map_err(|e| {
            runtime::clear_remote_attachment_registration(
                &scene.runtime,
                &registered_host,
                navigation,
            );
            scene::restore_scene_inventory_state(scene);
            error(format!("Cannot open Rex: {e}"))
        })
}

#[allow(
    clippy::too_many_lines,
    reason = "Control messages and pane exits settle under the same publication fence."
)]
pub(crate) fn tick(scene: &Arc<Scene>) {
    let _publication = scene
        .runtime
        .remote_publication
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Ok(_navigation) = scene::lock_live_navigation(scene) else {
        return;
    };
    let mut state = lock(scene);
    let Some(window) = state.as_mut() else {
        return;
    };
    if window.error.is_some() {
        return;
    }
    let result: Result<(), WorkspaceError> = (|| {
        if window.cancellation.is_cancelled() {
            return Err(error("The Rex connection changed."));
        }
        runtime::recapture_remote_attachment_context(
            &scene.runtime,
            window.selection.host_id(),
            window.connection_generation,
            &window.snapshot,
        )?;
        if window.view.is_none() && window.started.elapsed() > Duration::from_secs(20) {
            return Err(error("Rex did not send a window layout. Try reconnecting."));
        }
        let control = window
            .control
            .as_ref()
            .ok_or_else(|| error("The Rex connection closed."))?;
        control
            .connection
            .lease
            .ensure_live()
            .map_err(|e| error(e.to_string()))?;
        for _ in 0..8 {
            let Some(message) = window.control.as_ref().and_then(|c| c.channel.next()) else {
                break;
            };
            match message.map_err(error)? {
                Message::View { view, terminals } => {
                    if view.session_id != window.session_id {
                        return Err(error("The Rex window changed sessions. Choose it again."));
                    }
                    if window
                        .revision
                        .is_some_and(|revision| view.revision < revision)
                    {
                        continue;
                    }
                    let Some(view_window) = view
                        .windows
                        .into_iter()
                        .find(|w| w.window_id == window.selection.session())
                    else {
                        window.ended = true;
                        return Ok(());
                    };
                    let pane_name = view_window
                        .focused_block_id
                        .as_ref()
                        .and_then(|id| terminals.get(id))
                        .map_or("", |t| t.name.as_str());
                    window.title = host::rex::window_title(
                        view_window.label.as_deref().unwrap_or_default(),
                        pane_name,
                    );
                    let count = view_window
                        .layout()
                        .map_or(0, |layout| layout.panes().len());
                    let count = if count == 1 {
                        "1 pane".to_owned()
                    } else {
                        format!("{count} panes")
                    };
                    window.detail = view
                        .label
                        .as_deref()
                        .filter(|s| !s.trim().is_empty())
                        .map_or_else(|| count.clone(), |label| format!("{label} · {count}"));
                    window.revision = Some(view.revision);
                    window.view = Some(view_window);
                    window.apply_view(scene, &terminals)?;
                }
                Message::Reply {
                    id,
                    result,
                    error: reply_error,
                } => {
                    let focus = window.requests.remove(&id).flatten();
                    window.requested_focus.reply(
                        id,
                        result.and_then(|r| r.revision),
                        reply_error.is_some(),
                        window.revision,
                    );
                    if focus.is_some()
                        && window.requested_focus.requested().is_none()
                        && let Some(id) = window
                            .view
                            .as_ref()
                            .and_then(|v| v.focused_block_id.as_ref())
                            .filter(|id| window.panes.contains_key(*id))
                            .cloned()
                    {
                        window.focus(scene, &id)?;
                    }
                    if let Some(e) = reply_error {
                        scene::push_lossless_event(scene, WorkspaceEvent::Error(e.message));
                    }
                }
                Message::Ended => {
                    window.ended = true;
                    return Ok(());
                }
            }
        }
        let mut changed = window.poll_pane_launch(scene)?;
        for (id, pane) in &mut window.panes {
            let mut stopped = None;
            if let Some(worker) = &pane.worker {
                for _ in 0..8 {
                    match worker.try_event() {
                        Ok(Some(terminal::TerminalEvent::ConfirmPaste(_))) => {
                            let _ = worker.cancel_paste();
                        }
                        Ok(Some(
                            terminal::TerminalEvent::ClipboardRead(_)
                            | terminal::TerminalEvent::ClipboardWrite { .. },
                        )) => {}
                        Ok(Some(terminal::TerminalEvent::Exited { code, .. })) => {
                            stopped = Some(if code == 0 {
                                "Program ended.".to_owned()
                            } else {
                                "Attachment closed.".to_owned()
                            });
                            break;
                        }
                        Ok(Some(terminal::TerminalEvent::Error(e))) => {
                            stopped = Some(e);
                            break;
                        }
                        Ok(None) => break,
                        Err(e) => {
                            stopped = Some(e.to_string());
                            break;
                        }
                    }
                }
            } else if window.focused.as_ref() == Some(id)
                && pane.error.is_none()
                && !pane.queued
                && pane.pending.is_none()
                && scene
                    .worker
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .active()
                    .is_none()
            {
                stopped = Some("Attachment closed.".to_owned());
            }
            if let Some(message) = stopped {
                pane.worker.take();

                pane.error = Some(message);
                changed = true;
            }
            let generation = pane.surface.load().generation();
            changed |= pane.generation != generation;
            pane.generation = generation;
        }
        if window.resize_pending {
            changed |= window.resize_panes(scene)?;
        }
        if changed {
            if let Some(id) = window.focused.clone() {
                window.focus(scene, &id)?;
            }
            bump_scene_revision(scene);
        }
        Ok(())
    })();
    if window.ended {
        drop(take_active_worker(scene));
        runtime::clear_remote_attachment_registration(
            &scene.runtime,
            window.selection.host_id(),
            window.navigation,
        );
        state.take();
        scene::restore_scene_inventory_state(scene);
    } else if let Err(e) = result {
        window.error = Some(e.to_string());
        window.control.take();
        drop(take_active_worker(scene));
        for pane in window.panes.values_mut() {
            pane.worker.take();

            pane.pending.take();
            pane.queued = false;
        }
        runtime::clear_remote_attachment_registration(
            &scene.runtime,
            window.selection.host_id(),
            window.navigation,
        );
        bump_scene_revision(scene);
    }
}

impl Window {
    fn apply_view(
        &mut self,
        scene: &Scene,
        titles: &BTreeMap<String, host::rex::PaneTitle>,
    ) -> Result<(), WorkspaceError> {
        let view = self
            .view
            .as_ref()
            .ok_or_else(|| error("Rex layout unavailable"))?;
        let ids: BTreeSet<_> = view
            .layout()
            .map(Layout::panes)
            .unwrap_or_default()
            .into_iter()
            .map(str::to_owned)
            .collect();
        if self.focused.as_ref().is_some_and(|id| !ids.contains(id)) {
            scene::cancel_pending_paste(scene);
            scene
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .invalidate();
            self.focused = None;
        }
        self.panes.retain(|id, _| ids.contains(id));
        for id in &ids {
            self.panes
                .entry(id.clone())
                .or_insert_with(|| Pane::new(scene));
            if let Some(title) = titles.get(id) {
                self.panes
                    .get_mut(id)
                    .unwrap()
                    .title
                    .clone_from(&title.name);
            }
        }
        self.requested_focus.view(self.revision.unwrap_or(0), &ids);
        let selected = self
            .requested_focus
            .requested()
            .map(str::to_owned)
            .or_else(|| view.focused_block_id.clone().filter(|id| ids.contains(id)))
            .or_else(|| self.focused.clone().filter(|id| ids.contains(id)))
            .or_else(|| ids.first().cloned());
        if let Some(id) = selected {
            self.focus(scene, &id)?;
        }
        self.resize(scene)?;
        // The live control channel keeps this scene's attachment reservation.
        // A tmux inventory retry must not replace its SSH connection.
        bump_scene_revision(scene);
        Ok(())
    }

    fn focus(&mut self, scene: &Scene, id: &str) -> Result<(), WorkspaceError> {
        if !self.panes.contains_key(id) {
            return Err(error("The Rex pane closed."));
        }
        if self.focused.as_deref() != Some(id) {
            scene::cancel_pending_paste(scene);
            let mut workers = scene
                .worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let previous = workers.invalidate();
            if let Some(worker) = &previous {
                scene::retire_clipboard_writes(scene, worker);
            }
            if let Some(pane) = self.focused.as_ref().and_then(|id| self.panes.get_mut(id)) {
                pane.worker = previous;
            }
            let pane = self.panes.get_mut(id).unwrap();
            if let Some(worker) = pane.worker.take() {
                crate::reconcile_worker_terminal_settings(&scene.runtime, &worker);
                worker.set_clipboard_writes_enabled(true);
                workers.publish(worker);
            }
            self.focused = Some(id.to_owned());
        }
        let pane = &self.panes[id];
        scene::set_scene_state(
            scene,
            WorkspaceContent::Terminal {
                host_id: self.selection.host_id().to_owned(),
                endpoint: self.selection.endpoint().to_owned(),
                session: self.title.clone(),
                kind: SessionKind::Rex,
                presentation_id: pane.id,
                surface: pane.surface.clone(),
            },
        );
        Ok(())
    }

    fn request(
        &mut self,
        method: &str,
        params: &serde_json::Value,
        focus: Option<String>,
    ) -> Result<(), WorkspaceError> {
        if self.error.is_some() {
            return Err(error("Reconnect this Rex window before changing panes."));
        }
        if self.requests.len() >= 64 {
            return Err(error("Rex is still handling earlier pane requests."));
        }
        let id = self.next_request;
        self.control
            .as_ref()
            .ok_or_else(|| error("The Rex connection closed."))?
            .channel
            .send(id, method, params)
            .map_err(error)?;
        self.next_request += 1;
        if let Some(target) = &focus {
            self.requested_focus.request(id, target.clone());
        }
        self.requests.insert(id, focus);
        Ok(())
    }

    fn resize(&mut self, scene: &Scene) -> Result<(), WorkspaceError> {
        self.dividers.clear();
        let (width, height, _, _) = self.geometry;
        let mut rects = BTreeMap::new();
        if let Some(view) = &self.view {
            let rect = RexRect {
                x: 0.0,
                y: 0.0,
                width,
                height,
            };
            if let Some(id) = view
                .zoomed_block_id
                .as_ref()
                .filter(|id| self.panes.contains_key(*id))
            {
                rects.insert(id.clone(), rect);
            } else if let Some(layout) = view.layout() {
                layout_rects(layout, rect, &mut rects, &mut self.dividers);
            }
        }
        for (id, pane) in &mut self.panes {
            pane.rect = rects.get(id).copied().unwrap_or_default();
        }
        self.resize_panes(scene)?;
        Ok(())
    }

    // Layout is visible immediately. A busy terminal can apply its new
    // grid later, and one pane's queue must never block its neighbors.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    fn resize_panes(&mut self, scene: &Scene) -> Result<bool, WorkspaceError> {
        self.resize_pending = false;
        let (_, _, cell, line) = self.geometry;
        let mut failed = false;
        for (id, pane) in &mut self.panes {
            let rect = pane.rect;
            if rect.width <= 0.0 || rect.height <= 0.0 || pane.error.is_some() {
                continue;
            }
            let pixel_width = rect.width.max(1.0).min(f32::from(u16::MAX)) as u16;
            let pixel_height = (rect.height - PANE_HEADER_HEIGHT)
                .max(1.0)
                .min(f32::from(u16::MAX)) as u16;
            let grid = GridSize::new(
                (rect.width / cell).floor().max(1.0) as usize,
                ((rect.height - PANE_HEADER_HEIGHT) / line).floor().max(1.0) as usize,
            )
            .map_err(|e| error(e.to_string()))?;
            let pixels = PixelSize::new(pixel_width, pixel_height);
            if pane.accepted_size == Some((grid, pixels)) {
                continue;
            }
            let focused = self.focused.as_ref() == Some(id);
            let result = {
                let active = scene
                    .worker
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let worker = if focused {
                    active.active()
                } else {
                    pane.worker.as_ref()
                };
                worker.map(|worker| {
                    worker.resize_with_metadata(grid, next_presentation_id(&scene.runtime), pixels)
                })
            };
            match result {
                Some(Ok(())) => pane.accepted_size = Some((grid, pixels)),
                Some(Err(error)) if error.is_backpressure() => self.resize_pending = true,
                Some(Err(error)) => {
                    if focused {
                        drop(take_active_worker(scene));
                    } else {
                        pane.worker.take();
                    }

                    pane.error = Some(error.to_string());
                    failed = true;
                }
                None => {}
            }
        }
        Ok(failed)
    }
}

#[allow(clippy::cast_possible_truncation)]
pub fn layout_rects(
    layout: &Layout,
    rect: RexRect,
    panes: &mut BTreeMap<String, RexRect>,
    dividers: &mut Vec<RexDivider>,
) {
    match layout {
        Layout::Pane { block_id } => {
            panes.insert(block_id.clone(), rect);
        }
        Layout::Split { split } => {
            let mut first = rect;
            let mut second = rect;
            let mut divider = rect;
            match split.direction {
                Direction::Horizontal => {
                    let available = (rect.width - DIVIDER_WIDTH).max(0.0);
                    first.width = available * split.ratio as f32;
                    second.x += first.width + DIVIDER_WIDTH;
                    second.width = available - first.width;
                    divider.x += first.width;
                    divider.width = DIVIDER_WIDTH;
                }
                Direction::Vertical => {
                    let available = (rect.height - DIVIDER_WIDTH).max(0.0);
                    first.height = available * split.ratio as f32;
                    second.y += first.height + DIVIDER_WIDTH;
                    second.height = available - first.height;
                    divider.y += first.height;
                    divider.height = DIVIDER_WIDTH;
                }
            }
            dividers.push(RexDivider {
                id: split.split_id.clone(),
                before: edge_pane(&split.before, split.direction, true).to_owned(),
                after: edge_pane(&split.after, split.direction, false).to_owned(),
                rect: divider,
                parent: rect,
                direction: split.direction,
                ratio: split.ratio,
            });
            layout_rects(&split.before, first, panes, dividers);
            layout_rects(&split.after, second, panes, dividers);
        }
    }
}

fn edge_pane(layout: &Layout, direction: Direction, trailing: bool) -> &str {
    match layout {
        Layout::Pane { block_id } => block_id,
        Layout::Split { split } => {
            let child = if direction == split.direction && trailing {
                &split.after
            } else {
                &split.before
            };
            edge_pane(child, direction, trailing)
        }
    }
}

impl Workspace {
    /// Move within the shown Rex window, independently of Rex's active window.
    ///
    /// # Errors
    /// Returns a closed-window, stale-connection, or request failure.
    pub fn move_rex_focus(&self, cycle: i8, dx: i8, dy: i8) -> Result<(), WorkspaceError> {
        self.with_rex(|w, scene| {
            let Some(layout) = w.view.as_ref().and_then(WindowView::layout) else {
                return Ok(());
            };
            let ids = layout.panes();
            let Some(current) = w.focused.as_deref() else {
                return Ok(());
            };
            let target = if cycle != 0 {
                let index = ids.iter().position(|id| *id == current).unwrap_or(0);
                ids[(index
                    + if cycle > 0 {
                        1
                    } else {
                        ids.len().saturating_sub(1)
                    })
                    % ids.len()]
                .to_owned()
            } else {
                let mut rects = BTreeMap::new();
                layout_rects(
                    layout,
                    RexRect {
                        x: 0.0,
                        y: 0.0,
                        width: w.geometry.0,
                        height: w.geometry.1,
                    },
                    &mut rects,
                    &mut Vec::new(),
                );
                let Some(origin) = rects.get(current) else {
                    return Ok(());
                };
                let candidate = rects
                    .iter()
                    .filter_map(|(id, r)| {
                        let distance = match (dx, dy) {
                            (-1, _) => origin.x - r.x - r.width,
                            (1, _) => r.x - origin.x - origin.width,
                            (_, -1) => origin.y - r.y - r.height,
                            _ => r.y - origin.y - origin.height,
                        };
                        let overlap = if dx != 0 {
                            (origin.y + origin.height).min(r.y + r.height) - origin.y.max(r.y)
                        } else {
                            (origin.x + origin.width).min(r.x + r.width) - origin.x.max(r.x)
                        };
                        (id != current && distance >= 0.0 && overlap > 0.0)
                            .then_some((id, (distance, overlap)))
                    })
                    .min_by(|a, b| {
                        a.1.0
                            .total_cmp(&b.1.0)
                            .then_with(|| b.1.1.total_cmp(&a.1.1))
                    });
                let Some((id, _)) = candidate else {
                    return Ok(());
                };
                id.clone()
            };
            w.request(
                "session.focus_block",
                &json!({"block_id":target}),
                Some(target.clone()),
            )?;
            w.focus(scene, &target)
        })
    }
    /// Reattach to this existing block without creating a program.
    ///
    /// # Errors
    /// Rejects a stale pane or SSH connection, or returns a client startup error.
    pub fn reconnect_rex_pane(&self, presentation: u64) -> Result<(), WorkspaceError> {
        self.with_rex(|w, scene| {
            if w.error.is_some() {
                return Err(error("Reconnect the Rex window first."));
            }
            let pane = w
                .panes
                .values_mut()
                .find(|pane| pane.id == presentation)
                .ok_or_else(|| error("The Rex pane closed."))?;
            if pane.error.take().is_some() {
                pane.queued = true;
            }
            bump_scene_revision(scene);
            Ok(())
        })
    }

    /// # Errors
    /// Rejects a closed pane or a changed SSH connection.
    pub fn focus_rex_pane(&self, presentation: u64) -> Result<(), WorkspaceError> {
        self.with_rex(|w, scene| {
            let id = w
                .panes
                .iter()
                .find(|(_, p)| p.id == presentation)
                .map(|(id, _)| id.clone())
                .ok_or_else(|| error("The Rex pane closed."))?;
            if w.focused.as_ref() == Some(&id) {
                return Ok(());
            }
            w.request(
                "session.focus_block",
                &json!({"block_id":id}),
                Some(id.clone()),
            )?;
            w.focus(scene, &id)
        })
    }

    /// # Errors
    /// Rejects a closed window or a changed SSH connection.
    pub fn split_rex_pane(&self, down: bool) -> Result<(), WorkspaceError> {
        self.with_rex(|w, _| {
            let id = w.focused.as_ref().ok_or_else(|| error("Choose a Rex pane first."))?;
            w.request("session.new_split", &json!({"anchor_id":id,"direction":if down {"vertical"} else {"horizontal"},
                "side":"after","focus":true,"layout":{"block":{"flavor":"com.superlogical.terminal.shell"}}}), None)
        })
    }

    /// # Errors
    /// Rejects a closed pane or a changed SSH connection.
    pub fn zoom_rex_pane(&self) -> Result<(), WorkspaceError> {
        self.with_rex(|w, _| {
            let id = w
                .focused
                .as_ref()
                .ok_or_else(|| error("Choose a Rex pane first."))?;
            w.request("session.zoom_block", &json!({"block_id":id}), None)
        })
    }

    /// Ends the chosen pane's program after UI confirmation of this exact presentation.
    ///
    /// # Errors
    /// Rejects confirmations from closed or replaced panes and connections.
    pub fn close_rex_pane(&self, presentation: u64) -> Result<(), WorkspaceError> {
        self.with_rex(|w, _| {
            let id = w
                .panes
                .iter()
                .find(|(_, p)| p.id == presentation)
                .map(|(id, _)| id.clone())
                .ok_or_else(|| error("The Rex pane closed."))?;
            w.request("block.close", &json!({"block_id":id}), None)
        })
    }

    /// # Errors
    /// Rejects an obsolete divider or a changed SSH connection.
    pub fn resize_rex_split(&self, id: &str, ratio: f64) -> Result<(), WorkspaceError> {
        self.with_rex(|w, _| {
            if !ratio.is_finite() || !(0.05..=0.95).contains(&ratio) || !w.dividers.iter().any(|d| d.id == id) {
                return Err(error("The Rex divider changed."));
            }
            let divider = w.dividers.iter().find(|d| d.id == id).ok_or_else(|| error("The Rex divider changed."))?;
            w.request("session.resize_pane", &json!({"before_block_id":divider.before,"after_block_id":divider.after,
                "direction":if divider.direction == Direction::Horizontal {"horizontal"} else {"vertical"}, "ratio":ratio}), None)
        })
    }

    /// Resize every visible pane to its own libghostty grid.
    ///
    /// # Errors
    /// Returns a terminal resize failure.
    pub fn resize_rex_window(
        &self,
        width: f32,
        height: f32,
        cell: f32,
        line: f32,
    ) -> Result<(), WorkspaceError> {
        let _navigation = scene::lock_live_navigation(&self.scene)?;
        if ![width, height, cell, line]
            .into_iter()
            .all(|n| n.is_finite() && n > 0.0)
        {
            return Err(error("Invalid terminal dimensions."));
        }
        if let Some(w) = lock(&self.scene).as_mut() {
            let geometry = (width, height, cell, line);
            if w.geometry != geometry {
                w.geometry = geometry;
                w.resize(&self.scene)?;
                bump_scene_revision(&self.scene);
            }
        }
        Ok(())
    }

    fn with_rex<T>(
        &self,
        body: impl FnOnce(&mut Window, &Scene) -> Result<T, WorkspaceError>,
    ) -> Result<T, WorkspaceError> {
        let _publication = self
            .scene
            .runtime
            .remote_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _navigation = scene::lock_live_navigation(&self.scene)?;
        let mut state = lock(&self.scene);
        let w = state
            .as_mut()
            .ok_or_else(|| error("No Rex window is open."))?;
        runtime::recapture_remote_attachment_context(
            &self.scene.runtime,
            w.selection.host_id(),
            w.connection_generation,
            &w.snapshot,
        )?;
        body(w, &self.scene)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nested_layout_keeps_real_divider_neighbors_and_separate_grids() {
        let layout: Layout = serde_json::from_str(r#"{"split":{"split_id":"split:outer","direction":"horizontal","ratio":0.5,
            "before":{"split":{"split_id":"split:left","direction":"vertical","ratio":0.5,"before":{"block_id":"block:a"},"after":{"block_id":"block:b"}}},
            "after":{"block_id":"block:c"}}}"#).unwrap();
        let mut panes = BTreeMap::new();
        let mut dividers = Vec::new();
        layout_rects(
            &layout,
            RexRect {
                x: 0.0,
                y: 0.0,
                width: 1005.0,
                height: 600.0,
            },
            &mut panes,
            &mut dividers,
        );
        assert_eq!(
            panes["block:a"],
            RexRect {
                x: 0.0,
                y: 0.0,
                width: 500.0,
                height: 297.5
            }
        );
        assert_eq!(
            panes["block:b"],
            RexRect {
                x: 0.0,
                y: 302.5,
                width: 500.0,
                height: 297.5
            }
        );
        assert_eq!(
            panes["block:c"],
            RexRect {
                x: 505.0,
                y: 0.0,
                width: 500.0,
                height: 600.0
            }
        );
        assert_eq!(
            (&*dividers[0].before, &*dividers[0].after),
            ("block:a", "block:c")
        );
        assert_eq!(
            (&*dividers[1].before, &*dividers[1].after),
            ("block:a", "block:b")
        );
    }
}
