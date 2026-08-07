//! GPUI presentation for the Rust Ghosthub application.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, Focusable, FontWeight,
    IntoElement, KeyDownEvent, KeyUpEvent, MouseButton as GpuiMouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, Render, ScrollWheelEvent, TitlebarOptions, Window, WindowBounds,
    WindowOptions, div, font, prelude::*, px, rgb, size,
};
use model::PortStatus;
use surface::{CellStyle, Damage, GridSize, Rgb, SurfaceFrame, SurfaceStore};
use workspace::{
    HostConnectionState, HostItem, KeyEvent as InputKeyEvent, KeyInput,
    Modifiers as InputModifiers, MouseAction, MouseButton, MouseInput, NamedKey, Workspace,
    WorkspaceContent, WorkspaceEvent,
};

pub const WINDOW_TITLE: &str = "Ghosthub";
const TERMINAL_HEADER_HEIGHT: f32 = 42.0;
const TERMINAL_PADDING: f32 = 12.0;
const CELL_LINE_GAP: f32 = 2.0;
const UI_INPUT_CAPACITY: usize = 512;
const MOUSE_RELEASE_RESERVE: usize = 3;
const MAX_WHEEL_EVENTS_PER_CALLBACK: i16 = 64;
const UI_INPUT_BYTE_CAPACITY: usize = 512 * 1024;
const INPUT_BUFFERED_DIAGNOSTIC: &str = "Terminal is busy; input is buffered.";
const INPUT_BUFFER_FULL_DIAGNOSTIC: &str =
    "Terminal input buffer is full; wait for pending input to be delivered.";

#[must_use]
pub fn headline_text(status: &PortStatus) -> String {
    status.headline()
}

#[must_use]
pub fn host_status_text(host: &HostItem) -> String {
    match host.connection() {
        HostConnectionState::Disconnected => format!("{} is ready to connect", host.endpoint()),
        HostConnectionState::Connecting => {
            format!(
                "Connecting to {} and discovering tmux sessions…",
                host.endpoint()
            )
        }
        HostConnectionState::Ready => format!("Tmux sessions in {}", host.endpoint()),
        HostConnectionState::Unavailable => host.diagnostic().map_or_else(
            || "WSL host is unavailable".to_owned(),
            |error| error.message().to_owned(),
        ),
    }
}

#[must_use]
pub fn empty_inventory_text(host: &HostItem) -> String {
    let namespace = host
        .socket_directory()
        .unwrap_or("the default tmux socket namespace");
    format!(
        "No tmux server is running in {} using {namespace}. Review WSL host settings or start a tmux session, then choose Refresh.",
        host.endpoint()
    )
}

#[must_use]
pub fn surface_text_rows(frame: &SurfaceFrame) -> Vec<String> {
    surface_paint_rows(frame)
        .into_iter()
        .map(|row| row.into_iter().map(|run| run.text).collect())
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaintRun {
    text: String,
    columns: usize,
    foreground: u32,
    background: u32,
    style: CellStyle,
}

impl PaintRun {
    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }

    #[must_use]
    pub const fn columns(&self) -> usize {
        self.columns
    }

    #[must_use]
    pub const fn foreground(&self) -> u32 {
        self.foreground
    }

    #[must_use]
    pub const fn background(&self) -> u32 {
        self.background
    }

    #[must_use]
    pub const fn bold(&self) -> bool {
        self.style.contains(CellStyle::BOLD)
    }
}

#[must_use]
pub fn surface_paint_rows(frame: &SurfaceFrame) -> Vec<Vec<PaintRun>> {
    (0..frame.size().rows())
        .map(|row| surface_paint_row(frame, row))
        .collect()
}

fn surface_paint_row(frame: &SurfaceFrame, row_index: usize) -> Vec<PaintRun> {
    let cursor = frame.cursor().filter(|cursor| cursor.visible);
    let row = frame.row(row_index);
    let mut runs: Vec<PaintRun> = Vec::new();
    for (column, cell) in row.iter().enumerate() {
        if cell.text().is_empty() && column > 0 && row[column - 1].style.contains(CellStyle::WIDE) {
            continue;
        }
        let inverted = cell.style.contains(CellStyle::INVERSE)
            ^ cursor.is_some_and(|cursor| cursor.row == row_index && cursor.column == column);
        let (mut foreground, background) = if inverted {
            (cell.background, cell.foreground)
        } else {
            (cell.foreground, cell.background)
        };
        if cell.style.contains(CellStyle::DIM) {
            foreground = Rgb::new(
                foreground.red / 2,
                foreground.green / 2,
                foreground.blue / 2,
            );
        }
        if cell.style.contains(CellStyle::HIDDEN) {
            foreground = background;
        }
        let run = PaintRun {
            text: if cell.text().is_empty() {
                " ".to_owned()
            } else {
                cell.text().to_owned()
            },
            columns: usize::from(cell.style.contains(CellStyle::WIDE)) + 1,
            foreground: rgb_value(foreground),
            background: rgb_value(background),
            style: cell.style,
        };
        if let Some(previous) = runs.last_mut()
            && previous.foreground == run.foreground
            && previous.background == run.background
            && previous.style == run.style
        {
            previous.text.push_str(&run.text);
            previous.columns += run.columns;
        } else {
            runs.push(run);
        }
    }
    runs
}

#[derive(Default)]
pub struct SurfacePaintCache {
    generation: u64,
    size: Option<GridSize>,
    cursor: Option<surface::Cursor>,
    rows: Vec<Arc<Vec<PaintRun>>>,
}

impl SurfacePaintCache {
    pub fn clear(&mut self) {
        *self = Self::default();
    }

    pub fn update(&mut self, frame: &SurfaceFrame) -> &[Arc<Vec<PaintRun>>] {
        let scrolled = frame
            .damage()
            .iter()
            .any(|damage| matches!(damage, Damage::Scroll { .. }));
        let full = self.size != Some(frame.size())
            || self.rows.len() != frame.size().rows()
            || frame.requires_full_repaint(self.generation)
            || frame.damage().contains(&Damage::Full);
        if full {
            self.rows = surface_paint_rows(frame)
                .into_iter()
                .map(Arc::new)
                .collect();
        } else {
            let mut scrolled_cursor_rows = Vec::new();
            for damage in frame.damage() {
                match *damage {
                    Damage::Full => unreachable!("full damage was handled above"),
                    Damage::Scroll { top, bottom, delta } => {
                        if let Some(exposed) =
                            apply_cached_scroll(&mut self.rows, top, bottom, delta)
                        {
                            repaint_rows(&mut self.rows, frame, exposed.start, exposed.end);
                        }
                        if let Some(cursor) = self.cursor
                            && cursor.row >= top
                            && cursor.row < bottom
                            && let Ok(row) = usize::try_from(
                                i64::try_from(cursor.row).unwrap_or(i64::MAX) + i64::from(delta),
                            )
                            && row < self.rows.len()
                        {
                            scrolled_cursor_rows.push(row);
                        }
                    }
                    Damage::Rows { start, end } => {
                        repaint_rows(&mut self.rows, frame, start, end);
                    }
                }
            }
            for row in scrolled_cursor_rows {
                repaint_rows(&mut self.rows, frame, row, row + 1);
            }
            if scrolled || self.cursor != frame.cursor() {
                if let Some(cursor) = self.cursor {
                    repaint_rows(&mut self.rows, frame, cursor.row, cursor.row + 1);
                }
                if let Some(cursor) = frame.cursor() {
                    repaint_rows(&mut self.rows, frame, cursor.row, cursor.row + 1);
                }
            }
        }
        self.generation = frame.generation();
        self.size = Some(frame.size());
        self.cursor = frame.cursor();
        &self.rows
    }
}

fn repaint_rows(rows: &mut [Arc<Vec<PaintRun>>], frame: &SurfaceFrame, start: usize, end: usize) {
    for row in start..end.min(rows.len()) {
        rows[row] = Arc::new(surface_paint_row(frame, row));
    }
}

fn apply_cached_scroll(
    rows: &mut [Arc<Vec<PaintRun>>],
    top: usize,
    bottom: usize,
    delta: i32,
) -> Option<std::ops::Range<usize>> {
    if top >= bottom || bottom > rows.len() || delta == 0 {
        return None;
    }
    let affected = &mut rows[top..bottom];
    let distance = usize::try_from(delta.unsigned_abs())
        .unwrap_or(usize::MAX)
        .min(affected.len());
    if delta < 0 {
        affected.rotate_left(distance);
        Some(bottom - distance..bottom)
    } else {
        affected.rotate_right(distance);
        Some(top..top + distance)
    }
}

const fn rgb_value(color: Rgb) -> u32 {
    (color.red as u32) << 16 | (color.green as u32) << 8 | color.blue as u32
}

pub struct RootView {
    status: PortStatus,
    workspace: Workspace,
    focus: FocusHandle,
    diagnostic: Option<String>,
    paste_confirmation: bool,
    observed_presentation_id: Option<u64>,
    observed_revision: u64,
    observed_surface_generation: u64,
    observed_surface_identity: Option<usize>,
    paint_cache: SurfacePaintCache,
    terminal_metrics: TerminalMetrics,
    pending_input: VecDeque<QueuedUiInput>,
    pending_input_bytes: usize,
    input_refusal: InputRefusal,
    wheel_remainder: f32,
    wheel_target: Option<WheelTarget>,
    keyboard: TerminalKeyboard,
    pointer: TerminalPointer,
}

#[derive(Clone, Copy)]
struct WheelTarget {
    cell: (usize, usize),
    modifiers: gpui::Modifiers,
}

#[derive(Clone, Copy, Debug)]
struct TerminalMetrics {
    cell_width: f32,
    line_height: f32,
}

#[derive(Default)]
struct TerminalPointer {
    pressed: [bool; 3],
    last_cell: Option<(usize, usize)>,
}

#[derive(Default)]
struct TerminalKeyboard {
    pressed: HashMap<String, KeyInput>,
}

impl TerminalKeyboard {
    fn reserved_releases(&self) -> usize {
        self.pressed.len()
    }

    fn reservations_after_press(&self, key: &str) -> usize {
        self.pressed.len() + usize::from(!self.pressed.contains_key(key))
    }

    fn accepts(&self, key: &str, event: InputKeyEvent) -> bool {
        event == InputKeyEvent::Press || self.pressed.contains_key(key)
    }

    fn input_for(&self, key: &str, event: InputKeyEvent) -> Option<KeyInput> {
        self.pressed
            .get(key)
            .cloned()
            .map(|input| input.with_event(event))
    }

    fn finish_accepted(
        &mut self,
        key: &str,
        pressed_input: Option<KeyInput>,
        event: InputKeyEvent,
    ) {
        match event {
            InputKeyEvent::Press => {
                self.pressed.insert(
                    key.to_owned(),
                    pressed_input.expect("accepted press retains its input"),
                );
            }
            InputKeyEvent::Release => {
                self.pressed.remove(key);
            }
            InputKeyEvent::Repeat => {}
        }
    }
}

impl TerminalPointer {
    fn press(&mut self, button: MouseButton, cell: (usize, usize)) {
        self.pressed[mouse_button_index(button)] = true;
        self.last_cell = Some(cell);
    }

    fn observe(&mut self, cell: Option<(usize, usize)>) -> Option<(usize, usize)> {
        if cell.is_some() {
            self.last_cell = cell;
        }
        cell
    }

    fn release_cell(
        &mut self,
        button: MouseButton,
        cell: Option<(usize, usize)>,
    ) -> Option<(usize, usize)> {
        if !self.pressed[mouse_button_index(button)] {
            return None;
        }
        if cell.is_some() {
            self.last_cell = cell;
        }
        cell.or(self.last_cell)
    }

    fn finish_release(&mut self, button: MouseButton) {
        self.pressed[mouse_button_index(button)] = false;
    }
}

enum PendingUiInput {
    Key(KeyInput),
    Mouse(MouseInput),
    ClipboardResponse(Vec<u8>),
}

struct QueuedUiInput {
    input: PendingUiInput,
    bytes: usize,
    accepted_after_refusal: Option<u64>,
}

#[derive(Default)]
struct InputRefusal {
    generation: u64,
    pending: bool,
}

impl InputRefusal {
    fn refuse(&mut self) {
        self.generation = self.generation.checked_add(1).unwrap_or(1);
        self.pending = true;
    }

    const fn acceptance_marker(&self) -> Option<u64> {
        if self.pending {
            Some(self.generation)
        } else {
            None
        }
    }

    fn delivered(&mut self, marker: Option<u64>) -> bool {
        if self.pending && marker == Some(self.generation) {
            self.pending = false;
            true
        } else {
            false
        }
    }

    const fn is_pending(&self) -> bool {
        self.pending
    }
}

impl PendingUiInput {
    fn byte_len(&self) -> usize {
        match self {
            Self::Key(KeyInput::Text { text, .. } | KeyInput::Paste(text)) => text.len(),
            Self::ClipboardResponse(bytes) => bytes.len(),
            Self::Key(KeyInput::Named { .. }) | Self::Mouse(_) => 0,
        }
    }

    fn is_balancing_release(&self) -> bool {
        matches!(
            self,
            Self::Key(
                KeyInput::Text {
                    event: InputKeyEvent::Release,
                    ..
                } | KeyInput::Named {
                    event: InputKeyEvent::Release,
                    ..
                }
            ) | Self::Mouse(MouseInput {
                action: MouseAction::Release(_),
                ..
            })
        )
    }
}

fn input_queue_has_capacity(
    input: &PendingUiInput,
    pending_items: usize,
    pending_bytes: usize,
    input_bytes: usize,
    reserved_key_releases: usize,
) -> bool {
    let balancing_release = input.is_balancing_release();
    let item_capacity = if balancing_release {
        UI_INPUT_CAPACITY
    } else {
        UI_INPUT_CAPACITY.saturating_sub(MOUSE_RELEASE_RESERVE + reserved_key_releases)
    };
    pending_items < item_capacity
        && (balancing_release
            || pending_bytes.saturating_add(input_bytes) <= UI_INPUT_BYTE_CAPACITY)
}

impl RootView {
    #[must_use]
    pub fn new(
        status: PortStatus,
        workspace: Workspace,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.spawn(async move |view, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(33))
                    .await;
                if view
                    .update(cx, |view, cx| {
                        let scope_changed = view.sync_terminal_scope();
                        let handled = view.handle_events(cx);
                        let flushed = view.flush_pending_input();
                        let wheel_flushed = view.flush_wheel_input();
                        if scope_changed
                            || handled
                            || flushed
                            || wheel_flushed
                            || view.poll_changed()
                        {
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();

        cx.observe_window_bounds(window, |view, window, cx| {
            view.resize_for_window(window);
            cx.notify();
        })
        .detach();

        cx.on_next_frame(window, |view, _window, cx| {
            if let Err(error) = view.workspace.connect_enabled_hosts() {
                view.diagnostic = Some(error.to_string());
            }
            cx.notify();
        });

        let appearance = workspace.snapshot().appearance().clone();
        let terminal_metrics = measure_terminal_metrics(window, &appearance);
        let mut view = Self {
            status,
            workspace,
            focus: cx.focus_handle(),
            diagnostic: None,
            paste_confirmation: false,
            observed_presentation_id: None,
            observed_revision: u64::MAX,
            observed_surface_generation: u64::MAX,
            observed_surface_identity: None,
            paint_cache: SurfacePaintCache::default(),
            terminal_metrics,
            pending_input: VecDeque::new(),
            pending_input_bytes: 0,
            input_refusal: InputRefusal::default(),
            wheel_remainder: 0.0,
            wheel_target: None,
            keyboard: TerminalKeyboard::default(),
            pointer: TerminalPointer::default(),
        };
        view.resize_for_window(window);
        view
    }

    #[must_use]
    pub fn headline(&self) -> String {
        headline_text(&self.status)
    }

    fn attach(&mut self, session: &str, window: &mut Window, cx: &mut Context<Self>) {
        if let Err(error) = self.workspace.attach(session) {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
            window.focus(&self.focus);
        }
        cx.notify();
    }

    fn refresh(&mut self, cx: &mut Context<Self>) {
        if let Err(error) = self.workspace.refresh() {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
        }
        cx.notify();
    }

    fn cancel_refresh(&mut self, cx: &mut Context<Self>) {
        if self.workspace.cancel_refresh() {
            self.diagnostic = None;
        }
        cx.notify();
    }

    fn detach(&mut self, cx: &mut Context<Self>) {
        self.workspace.detach();
        self.observed_presentation_id = None;
        self.clear_terminal_input();
        self.paint_cache.clear();
        cx.notify();
    }

    fn sync_terminal_scope(&mut self) -> bool {
        let snapshot = self.workspace.snapshot();
        let presentation_id = terminal_presentation_id(snapshot.content());
        if !transitioned_presentation(&mut self.observed_presentation_id, presentation_id) {
            return false;
        }
        self.clear_terminal_input();
        true
    }

    fn clear_terminal_input(&mut self) {
        clear_terminal_input_state(
            &mut self.paste_confirmation,
            &mut self.pending_input,
            &mut self.pending_input_bytes,
            &mut self.input_refusal,
        );
        self.wheel_remainder = 0.0;
        self.wheel_target = None;
        self.keyboard = TerminalKeyboard::default();
        self.pointer = TerminalPointer::default();
        if matches!(
            self.diagnostic.as_deref(),
            Some(INPUT_BUFFERED_DIAGNOSTIC | INPUT_BUFFER_FULL_DIAGNOSTIC)
        ) {
            self.diagnostic = None;
        }
    }

    fn handle_events(&mut self, cx: &mut Context<Self>) -> bool {
        let (events, may_have_more) = self.workspace.drain_events();
        if may_have_more {
            cx.notify();
        }
        let mut handled = may_have_more;
        for event in events {
            handled = true;
            match event {
                WorkspaceEvent::ClipboardWrite { text, .. } => {
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                }
                WorkspaceEvent::ClipboardRead(request) => {
                    let contents = cx
                        .read_from_clipboard()
                        .and_then(|clipboard| clipboard.text())
                        .unwrap_or_default();
                    self.enqueue_input(PendingUiInput::ClipboardResponse(
                        request.respond(&contents),
                    ));
                }
                WorkspaceEvent::ConfirmPaste => self.paste_confirmation = true,
                WorkspaceEvent::Error(error) => self.diagnostic = Some(error),
            }
        }
        handled
    }

    fn poll_changed(&self) -> bool {
        let snapshot = self.workspace.snapshot();
        if snapshot.revision() != self.observed_revision {
            return true;
        }
        let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
            return self.observed_surface_identity.is_some();
        };
        let identity = Arc::as_ptr(surface).cast::<()>() as usize;
        Some(identity) != self.observed_surface_identity
            || surface.load().generation() != self.observed_surface_generation
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        if is_paste_shortcut(keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                self.send_key(KeyInput::paste(text));
            }
            cx.stop_propagation();
            return;
        }

        let event = if event.is_held {
            InputKeyEvent::Repeat
        } else {
            InputKeyEvent::Press
        };
        let input = terminal_key_input(keystroke, event)
            .or_else(|| self.keyboard.input_for(&keystroke.key, event));
        if let Some(input) = input {
            self.send_key_event(input, &keystroke.key, event);
            cx.stop_propagation();
        }
    }

    fn on_key_up(&mut self, event: &KeyUpEvent, _window: &mut Window, cx: &mut Context<Self>) {
        if is_paste_shortcut(&event.keystroke) {
            cx.stop_propagation();
            return;
        }
        if let Some(input) = self
            .keyboard
            .input_for(&event.keystroke.key, InputKeyEvent::Release)
        {
            self.send_key_event(input, &event.keystroke.key, InputKeyEvent::Release);
            cx.stop_propagation();
        }
    }

    fn on_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.focus);
        if let Some(button) = terminal_mouse_button(event.button) {
            let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
            if let Some(cell) = cell
                && self.send_mouse_at_cell(MouseAction::Press(button), cell, event.modifiers)
            {
                self.pointer.press(button, cell);
            }
            cx.stop_propagation();
        }
    }

    fn on_mouse_up(&mut self, event: &MouseUpEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let _scope_changed = self.sync_terminal_scope();
        if let Some(button) = terminal_mouse_button(event.button) {
            let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
            if let Some(cell) = self.pointer.release_cell(button, cell)
                && self.send_mouse_at_cell(MouseAction::Release(button), cell, event.modifiers)
            {
                self.pointer.finish_release(button);
            }
            cx.stop_propagation();
        }
    }

    fn on_mouse_move(
        &mut self,
        event: &MouseMoveEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let button = event.pressed_button.and_then(terminal_mouse_button);
        let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
        if let Some(cell) = self.pointer.observe(cell) {
            self.send_mouse_at_cell(MouseAction::Move(button), cell, event.modifiers);
        }
        cx.stop_propagation();
    }

    fn on_scroll_wheel(
        &mut self,
        event: &ScrollWheelEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let _scope_changed = self.sync_terminal_scope();
        let delta = event
            .delta
            .pixel_delta(px(self.terminal_metrics.line_height));
        let vertical = f32::from(delta.y);
        if vertical == 0.0 {
            return;
        }
        let _flushed = self.flush_wheel_input();
        if let Some(cell) = self.terminal_cell_at(event.position.x.into(), event.position.y.into())
        {
            if self.wheel_target.is_none() || self.wheel_remainder.abs() < 1.0 {
                self.wheel_target = Some(WheelTarget {
                    cell,
                    modifiers: event.modifiers,
                });
            }
            self.wheel_remainder += vertical / self.terminal_metrics.line_height;
            let _flushed = self.flush_wheel_input();
        }
        cx.stop_propagation();
    }

    fn flush_wheel_input(&mut self) -> bool {
        let Some(target) = self.wheel_target else {
            return false;
        };
        let steps = terminal_wheel_steps(&mut self.wheel_remainder, 0.0, 1.0);
        let Some(action) = terminal_wheel_action(steps) else {
            return false;
        };
        let mut delivered = 0;
        for _ in 0..steps.unsigned_abs() {
            if !self.send_mouse_at_cell(action, target.cell, target.modifiers) {
                break;
            }
            delivered += 1;
        }
        restore_undelivered_wheel_steps(&mut self.wheel_remainder, steps, delivered);
        if self.wheel_remainder.abs() < 1.0 {
            self.wheel_target = None;
        }
        delivered > 0
    }

    fn terminal_cell_at(&self, x: f32, y: f32) -> Option<(usize, usize)> {
        let snapshot = self.workspace.snapshot();
        let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
            return None;
        };
        let size = surface.load().size();
        terminal_cell_at(
            x,
            y,
            self.terminal_metrics.cell_width,
            self.terminal_metrics.line_height,
            size,
        )
    }

    fn send_mouse_at_cell(
        &mut self,
        action: MouseAction,
        (column, row): (usize, usize),
        modifiers: gpui::Modifiers,
    ) -> bool {
        let input = MouseInput {
            action,
            column,
            row,
            modifiers: input_modifiers(modifiers),
        };
        self.enqueue_input(PendingUiInput::Mouse(input))
    }

    fn send_key(&mut self, input: KeyInput) {
        self.enqueue_input(PendingUiInput::Key(input));
    }

    fn send_key_event(&mut self, input: KeyInput, key: &str, event: InputKeyEvent) {
        let _scope_changed = self.sync_terminal_scope();
        if !self.keyboard.accepts(key, event) {
            return;
        }
        let reserved_key_releases = match event {
            InputKeyEvent::Press => self.keyboard.reservations_after_press(key),
            InputKeyEvent::Repeat | InputKeyEvent::Release => self.keyboard.reserved_releases(),
        };
        let pressed_input = (event == InputKeyEvent::Press).then(|| input.clone());
        if self.enqueue_input_with_reserve(PendingUiInput::Key(input), reserved_key_releases) {
            self.keyboard.finish_accepted(key, pressed_input, event);
        }
    }

    fn enqueue_input(&mut self, input: PendingUiInput) -> bool {
        self.enqueue_input_with_reserve(input, self.keyboard.reserved_releases())
    }

    fn enqueue_input_with_reserve(
        &mut self,
        input: PendingUiInput,
        reserved_key_releases: usize,
    ) -> bool {
        let _scope_changed = self.sync_terminal_scope();
        if matches!(
            &input,
            PendingUiInput::Mouse(MouseInput {
                action: MouseAction::Move(_),
                ..
            })
        ) && let Some(last) = self.pending_input.back_mut()
            && matches!(
                last.input,
                PendingUiInput::Mouse(MouseInput {
                    action: MouseAction::Move(_),
                    ..
                })
            )
        {
            last.input = input;
            last.accepted_after_refusal = self.input_refusal.acceptance_marker();
            return true;
        }

        let bytes = input.byte_len();
        if !input_queue_has_capacity(
            &input,
            self.pending_input.len(),
            self.pending_input_bytes,
            bytes,
            reserved_key_releases,
        ) {
            self.input_refusal.refuse();
            self.diagnostic = Some(INPUT_BUFFER_FULL_DIAGNOSTIC.to_owned());
            return false;
        }
        let accepted_after_refusal = self.input_refusal.acceptance_marker();
        self.pending_input_bytes += bytes;
        self.pending_input.push_back(QueuedUiInput {
            input,
            bytes,
            accepted_after_refusal,
        });
        let _changed = self.flush_pending_input();
        true
    }

    fn flush_pending_input(&mut self) -> bool {
        let mut changed = self.sync_terminal_scope();
        if self.paste_confirmation {
            return changed;
        }
        loop {
            let Some(input) = self.pending_input.front() else {
                if clears_when_input_queue_is_empty(self.diagnostic.as_deref()) {
                    self.diagnostic = None;
                    changed = true;
                }
                return changed;
            };
            let result = match &input.input {
                PendingUiInput::Key(input) => self.workspace.send_key(input.clone()),
                PendingUiInput::Mouse(input) => self.workspace.send_mouse(*input),
                PendingUiInput::ClipboardResponse(bytes) => {
                    self.workspace.send_clipboard_response(bytes.clone())
                }
            };
            match result {
                Ok(()) => {
                    let delivered = self.pending_input.pop_front().expect("front input exists");
                    self.pending_input_bytes =
                        self.pending_input_bytes.saturating_sub(delivered.bytes);
                    let recovered = self
                        .input_refusal
                        .delivered(delivered.accepted_after_refusal);
                    if clears_after_input_delivery(
                        self.diagnostic.as_deref(),
                        recovered,
                        self.input_refusal.is_pending(),
                    ) {
                        self.diagnostic = None;
                    }
                    changed = true;
                }
                Err(error) if error.is_backpressure() => {
                    let diagnostic = if self.input_refusal.is_pending() {
                        INPUT_BUFFER_FULL_DIAGNOSTIC
                    } else {
                        INPUT_BUFFERED_DIAGNOSTIC
                    };
                    if self.diagnostic.as_deref() != Some(diagnostic) {
                        self.diagnostic = Some(diagnostic.to_owned());
                        changed = true;
                    }
                    return changed;
                }
                Err(error) => {
                    self.pending_input.clear();
                    self.pending_input_bytes = 0;
                    self.input_refusal = InputRefusal::default();
                    self.diagnostic = Some(error.to_string());
                    return true;
                }
            }
        }
    }

    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    fn resize_for_window(&mut self, window: &Window) {
        let bounds = window.bounds();
        let width = f32::from(bounds.size.width);
        let height = f32::from(bounds.size.height);
        let (columns, rows) = terminal_grid_size(
            width,
            height,
            self.terminal_metrics.cell_width,
            self.terminal_metrics.line_height,
        );
        let content_width = (width - TERMINAL_PADDING * 2.0).max(1.0);
        let content_height = (height - TERMINAL_HEADER_HEIGHT - TERMINAL_PADDING * 2.0).max(1.0);
        let pixel_width = content_width.min(f32::from(u16::MAX)) as u16;
        let pixel_height = content_height.min(f32::from(u16::MAX)) as u16;
        if let Err(error) =
            self.workspace
                .resize_with_pixels(columns, rows, pixel_width, pixel_height)
        {
            self.diagnostic = Some(error.to_string());
        }
    }

    fn approve_paste(&mut self, cx: &mut Context<Self>) {
        if let Err(error) = self.workspace.approve_paste() {
            self.diagnostic = Some(error.to_string());
        }
        self.paste_confirmation = false;
        let _changed = self.flush_pending_input();
        cx.notify();
    }

    fn cancel_paste(&mut self, cx: &mut Context<Self>) {
        self.workspace.cancel_paste();
        self.paste_confirmation = false;
        let _changed = self.flush_pending_input();
        cx.notify();
    }

    fn terminal_element(
        &mut self,
        endpoint: &str,
        session: &str,
        surface: &Arc<SurfaceStore>,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let frame = surface.load();
        let identity = Arc::as_ptr(surface).cast::<()>() as usize;
        if self.observed_surface_identity != Some(identity) {
            self.paint_cache.clear();
        }
        let rows = self.paint_cache.update(&frame).to_vec();
        self.observed_surface_identity = Some(identity);
        self.observed_surface_generation = frame.generation();
        let appearance = snapshot.appearance();
        let mut header = div()
            .h(px(42.0))
            .flex()
            .items_center()
            .justify_between()
            .px_4()
            .bg(rgb(0x1a_1d24))
            .text_color(rgb(0xc9_cd_d6))
            .child(format!("{endpoint}  ·  {session}"));
        header = header.child(
            div()
                .id("detach-terminal")
                .px_3()
                .py_1()
                .rounded_md()
                .cursor_pointer()
                .bg(rgb(0x2a_2f_3a))
                .child("Detach")
                .on_click(cx.listener(|this, _, _, cx| this.detach(cx))),
        );

        let terminal = div()
            .id("terminal-surface")
            .track_focus(&self.focus)
            .flex()
            .flex_col()
            .flex_1()
            .overflow_hidden()
            .p_3()
            .bg(rgb(appearance.background()))
            .text_color(rgb(appearance.foreground()))
            .font_family(appearance.font_family().to_owned())
            .text_size(px(f32::from(appearance.font_size())))
            .line_height(px(self.terminal_metrics.line_height))
            .on_key_down(cx.listener(Self::on_key_down))
            .on_key_up(cx.listener(Self::on_key_up))
            .on_mouse_down(GpuiMouseButton::Left, cx.listener(Self::on_mouse_down))
            .on_mouse_down(GpuiMouseButton::Middle, cx.listener(Self::on_mouse_down))
            .on_mouse_down(GpuiMouseButton::Right, cx.listener(Self::on_mouse_down))
            .on_mouse_up(GpuiMouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_up(GpuiMouseButton::Middle, cx.listener(Self::on_mouse_up))
            .on_mouse_up(GpuiMouseButton::Right, cx.listener(Self::on_mouse_up))
            .on_mouse_up_out(GpuiMouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_up_out(GpuiMouseButton::Middle, cx.listener(Self::on_mouse_up))
            .on_mouse_up_out(GpuiMouseButton::Right, cx.listener(Self::on_mouse_up))
            .on_mouse_move(cx.listener(Self::on_mouse_move))
            .on_scroll_wheel(cx.listener(Self::on_scroll_wheel))
            .children(rows.into_iter().map(|row| {
                div()
                    .flex()
                    .flex_none()
                    .h(px(self.terminal_metrics.line_height))
                    .whitespace_nowrap()
                    .children(
                        row.iter()
                            .cloned()
                            .map(|run| paint_run_element(run, self.terminal_metrics.cell_width)),
                    )
                    .into_any_element()
            }));

        div()
            .size_full()
            .flex()
            .flex_col()
            .child(header)
            .child(terminal)
    }

    fn content_element(
        &mut self,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        match snapshot.content() {
            WorkspaceContent::Shell => Self::shell_element(snapshot, cx),
            WorkspaceContent::Loading => centered("Starting WSL and discovering tmux sessions…"),
            WorkspaceContent::Error { message } => div()
                .size_full()
                .flex()
                .flex_col()
                .gap_3()
                .items_center()
                .justify_center()
                .text_color(rgb(0xb7_bc_c6))
                .child(message.clone())
                .child(
                    div()
                        .id("retry-wsl")
                        .px_3()
                        .py_1()
                        .rounded_md()
                        .cursor_pointer()
                        .bg(rgb(0x2a_2f_3a))
                        .child("Retry")
                        .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
                )
                .into_any_element(),
            WorkspaceContent::Attaching { endpoint, session } => {
                centered(format!("Attaching to {endpoint} · {session}…"))
            }
            WorkspaceContent::Ready { endpoint, sessions } => {
                Self::ready_element(endpoint, sessions, None, cx)
            }
            WorkspaceContent::Terminal {
                endpoint,
                session,
                surface,
                ..
            } => self
                .terminal_element(endpoint, session, surface, snapshot, cx)
                .into_any_element(),
        }
    }

    fn shell_element(
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let hosts = snapshot.hosts();
        let sidebar = div()
            .w(px(230.0))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
            .bg(rgb(0x12_14_19))
            .child(div().text_sm().text_color(rgb(0x8f_96_a3)).child("HOSTS"))
            .children(hosts.iter().enumerate().map(|(index, host)| {
                let status_color = match host.connection() {
                    HostConnectionState::Ready => 0x62_c0_7a,
                    HostConnectionState::Connecting => 0xd3_a4_4a,
                    HostConnectionState::Disconnected => 0x8f_96_a3,
                    HostConnectionState::Unavailable => 0xd0_65_65,
                };
                div()
                    .id(("host", index))
                    .p_3()
                    .rounded_md()
                    .bg(rgb(0x1a_1d24))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(div().text_color(rgb(status_color)).child("●"))
                            .child(host.name().to_owned()),
                    )
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(0x8f_96_a3))
                            .child(host.endpoint().to_owned()),
                    )
            }));

        let selected = snapshot
            .selected_host()
            .and_then(|id| hosts.iter().find(|host| host.id() == id));
        let main = selected.map_or_else(
            || centered("No terminal hosts are available."),
            |host| Self::host_element(host, cx),
        );
        div()
            .size_full()
            .flex()
            .child(sidebar)
            .child(div().flex_1().h_full().child(main))
            .into_any_element()
    }

    fn host_element(host: &HostItem, cx: &mut Context<Self>) -> gpui::AnyElement {
        match host.connection() {
            HostConnectionState::Disconnected => div()
                .size_full()
                .flex()
                .flex_col()
                .gap_3()
                .items_center()
                .justify_center()
                .text_color(rgb(0xb7_bc_c6))
                .child(host_status_text(host))
                .child(
                    div()
                        .id("connect-wsl-host")
                        .px_3()
                        .py_1()
                        .rounded_md()
                        .cursor_pointer()
                        .bg(rgb(0x2a_2f_3a))
                        .child("Connect")
                        .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
                )
                .into_any_element(),
            HostConnectionState::Connecting => div()
                .size_full()
                .flex()
                .flex_col()
                .gap_3()
                .items_center()
                .justify_center()
                .text_color(rgb(0xb7_bc_c6))
                .child(host_status_text(host))
                .child(
                    div()
                        .id("cancel-wsl-host-refresh")
                        .px_3()
                        .py_1()
                        .rounded_md()
                        .cursor_pointer()
                        .bg(rgb(0x2a_2f_3a))
                        .child("Cancel")
                        .on_click(cx.listener(|this, _, _, cx| this.cancel_refresh(cx))),
                )
                .into_any_element(),
            HostConnectionState::Ready => {
                Self::ready_element(host.endpoint(), host.sessions(), Some(host), cx)
            }
            HostConnectionState::Unavailable => div()
                .size_full()
                .flex()
                .flex_col()
                .gap_3()
                .items_center()
                .justify_center()
                .text_color(rgb(0xb7_bc_c6))
                .child(host_status_text(host))
                .child(
                    div()
                        .id("retry-wsl-host")
                        .px_3()
                        .py_1()
                        .rounded_md()
                        .cursor_pointer()
                        .bg(rgb(0x2a_2f_3a))
                        .child("Retry")
                        .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
                )
                .into_any_element(),
        }
    }

    fn ready_element(
        endpoint: &str,
        sessions: &[workspace::SessionItem],
        host: Option<&HostItem>,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut list = div().flex().flex_col().gap_2().p_6().max_w(px(720.0));
        list = list
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_xl()
                            .text_color(rgb(0xee_f0_f4))
                            .child(format!("Tmux sessions in {endpoint}")),
                    )
                    .child(
                        div()
                            .id("refresh-sessions")
                            .px_3()
                            .py_1()
                            .rounded_md()
                            .cursor_pointer()
                            .bg(rgb(0x2a_2f_3a))
                            .child("Refresh")
                            .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
                    ),
            )
            .child(div().text_sm().text_color(rgb(0x8f_96_a3)).mb_4().child(
                "Select an existing session. Ghosthub attaches as an ordinary tmux client.",
            ));
        if sessions.is_empty() {
            let empty = host.map_or_else(
                || "No tmux server is running in this distro. Start a tmux session in WSL, then choose Refresh.".to_owned(),
                empty_inventory_text,
            );
            list = list.child(div().p_4().rounded_md().bg(rgb(0x1a_1d24)).child(empty));
        }
        for (index, session) in sessions.iter().enumerate() {
            let name = session.name().to_owned();
            let detail = if session.attached_clients() == 0 {
                "detached".to_owned()
            } else {
                format!("{} client(s)", session.attached_clients())
            };
            list = list.child(
                div()
                    .id(("session", index))
                    .flex()
                    .items_center()
                    .justify_between()
                    .p_4()
                    .rounded_md()
                    .cursor_pointer()
                    .bg(rgb(0x1a_1d24))
                    .hover(|style| style.bg(rgb(0x25_2a34)))
                    .child(name.clone())
                    .child(div().text_sm().text_color(rgb(0x8f_96_a3)).child(detail))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.attach(&name, window, cx);
                    })),
            );
        }
        div()
            .size_full()
            .flex()
            .justify_center()
            .child(list)
            .into_any_element()
    }
}

fn clears_when_input_queue_is_empty(diagnostic: Option<&str>) -> bool {
    diagnostic == Some(INPUT_BUFFERED_DIAGNOSTIC)
}

fn clears_after_input_delivery(
    diagnostic: Option<&str>,
    recovered_refusal: bool,
    refusal_pending: bool,
) -> bool {
    (recovered_refusal && diagnostic == Some(INPUT_BUFFER_FULL_DIAGNOSTIC))
        || (!refusal_pending && diagnostic == Some(INPUT_BUFFERED_DIAGNOSTIC))
}

fn terminal_presentation_id(content: &WorkspaceContent) -> Option<u64> {
    match content {
        WorkspaceContent::Terminal {
            presentation_id, ..
        } => Some(*presentation_id),
        _ => None,
    }
}

fn transitioned_presentation(observed: &mut Option<u64>, current: Option<u64>) -> bool {
    if *observed == current {
        false
    } else {
        *observed = current;
        true
    }
}

fn clear_terminal_input_state(
    paste_confirmation: &mut bool,
    pending_input: &mut VecDeque<QueuedUiInput>,
    pending_input_bytes: &mut usize,
    input_refusal: &mut InputRefusal,
) {
    *paste_confirmation = false;
    pending_input.clear();
    *pending_input_bytes = 0;
    *input_refusal = InputRefusal::default();
}

impl Focusable for RootView {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for RootView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let _scope_changed = self.sync_terminal_scope();
        let _handled = self.handle_events(cx);
        let snapshot = self.workspace.snapshot();
        self.observed_revision = snapshot.revision();
        if !matches!(snapshot.content(), WorkspaceContent::Terminal { .. }) {
            self.observed_surface_identity = None;
            self.observed_surface_generation = 0;
            self.paint_cache.clear();
        }
        let mut root = div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(snapshot.appearance().background()))
            .text_color(rgb(snapshot.appearance().foreground()))
            .child(self.content_element(&snapshot, cx));

        if let Some(notice) = snapshot.notice() {
            root = root.child(
                div()
                    .absolute()
                    .left_4()
                    .bottom_4()
                    .px_3()
                    .py_2()
                    .rounded_md()
                    .bg(rgb(0x5a_49_20))
                    .text_color(rgb(0xf0_d7_8a))
                    .child(notice.to_owned()),
            );
        }
        if let Some(diagnostic) = &self.diagnostic {
            root = root.child(
                div()
                    .absolute()
                    .left_4()
                    .bottom_12()
                    .px_3()
                    .py_2()
                    .rounded_md()
                    .bg(rgb(0x6e_2a32))
                    .child(diagnostic.clone()),
            );
        }
        if self.paste_confirmation {
            root = root.child(
                div()
                    .absolute()
                    .left_4()
                    .right_4()
                    .bottom_4()
                    .flex()
                    .items_center()
                    .justify_between()
                    .p_4()
                    .rounded_md()
                    .bg(rgb(0x45_3520))
                    .child("Paste potentially unsafe text? It may execute commands immediately.")
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                div()
                                    .id("cancel-paste")
                                    .px_3()
                                    .py_1()
                                    .cursor_pointer()
                                    .child("Cancel")
                                    .on_click(cx.listener(|this, _, _, cx| this.cancel_paste(cx))),
                            )
                            .child(
                                div()
                                    .id("approve-paste")
                                    .px_3()
                                    .py_1()
                                    .rounded_md()
                                    .cursor_pointer()
                                    .bg(rgb(0x8a_62_2a))
                                    .child("Paste")
                                    .on_click(cx.listener(|this, _, _, cx| this.approve_paste(cx))),
                            ),
                    ),
            );
        }
        root
    }
}

fn centered(text: impl Into<String>) -> gpui::AnyElement {
    div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .text_color(rgb(0xb7_bc_c6))
        .child(text.into())
        .into_any_element()
}

fn paint_run_element(run: PaintRun, cell_width: f32) -> gpui::AnyElement {
    let columns = u16::try_from(run.columns).unwrap_or(u16::MAX);
    let width = cell_width * f32::from(columns);
    let mut element = div()
        .flex_none()
        .w(px(width))
        .overflow_hidden()
        .bg(rgb(run.background))
        .text_color(rgb(run.foreground))
        .child(run.text);
    if run.style.contains(CellStyle::BOLD) {
        element = element.font_weight(FontWeight::BOLD);
    }
    if run.style.contains(CellStyle::ITALIC) {
        element = element.italic();
    }
    if run.style.contains(CellStyle::UNDERLINE) {
        element = element.underline();
    }
    if run.style.contains(CellStyle::STRIKE) {
        element = element.line_through();
    }
    element.into_any_element()
}

fn named_key(key: &str) -> Option<NamedKey> {
    match key.to_ascii_lowercase().as_str() {
        "enter" => Some(NamedKey::Enter),
        "tab" => Some(NamedKey::Tab),
        "backspace" => Some(NamedKey::Backspace),
        "escape" => Some(NamedKey::Escape),
        "up" => Some(NamedKey::ArrowUp),
        "down" => Some(NamedKey::ArrowDown),
        "left" => Some(NamedKey::ArrowLeft),
        "right" => Some(NamedKey::ArrowRight),
        "home" => Some(NamedKey::Home),
        "end" => Some(NamedKey::End),
        "pageup" => Some(NamedKey::PageUp),
        "pagedown" => Some(NamedKey::PageDown),
        "insert" => Some(NamedKey::Insert),
        "delete" => Some(NamedKey::Delete),
        "numpaddecimal" | "kpdecimal" => Some(NamedKey::KeypadDecimal),
        "numpaddivide" | "kpdivide" => Some(NamedKey::KeypadDivide),
        "numpadmultiply" | "kpmultiply" => Some(NamedKey::KeypadMultiply),
        "numpadsubtract" | "kpsubtract" => Some(NamedKey::KeypadSubtract),
        "numpadadd" | "kpadd" => Some(NamedKey::KeypadAdd),
        "numpadenter" | "kpenter" => Some(NamedKey::KeypadEnter),
        "numpadequal" | "kpequal" => Some(NamedKey::KeypadEqual),
        value if value.starts_with("numpad") => value[6..].parse().ok().map(NamedKey::KeypadDigit),
        value if value.starts_with("kp") => value[2..].parse().ok().map(NamedKey::KeypadDigit),
        value if value.len() > 1 && value.starts_with('f') => {
            value[1..].parse().ok().map(NamedKey::F)
        }
        _ => None,
    }
}

fn terminal_key_input(keystroke: &gpui::Keystroke, event: InputKeyEvent) -> Option<KeyInput> {
    // GPUI's Windows backend removes the synthetic Ctrl+Alt pair generated by
    // right-Alt on AltGr layouts, while preserving genuine Ctrl+Alt chords.
    let modifiers = input_modifiers(keystroke.modifiers);
    let key_char = keystroke
        .key_char
        .as_deref()
        .filter(|text| !text.is_empty());
    let logical_key = if keystroke.key.eq_ignore_ascii_case("space") {
        " "
    } else {
        &keystroke.key
    };
    if let Some(key) = named_key(&keystroke.key) {
        return Some(KeyInput::named(key, modifiers).with_event(event));
    }
    let text = key_char.or_else(|| keystroke.key.eq_ignore_ascii_case("space").then_some(" "))?;
    Some(KeyInput::text_with_key(text, logical_key, modifiers).with_event(event))
}

fn is_paste_shortcut(keystroke: &gpui::Keystroke) -> bool {
    keystroke.modifiers.control
        && keystroke.modifiers.shift
        && keystroke.key.eq_ignore_ascii_case("v")
}

const fn input_modifiers(modifiers: gpui::Modifiers) -> InputModifiers {
    InputModifiers {
        shift: modifiers.shift,
        control: modifiers.control,
        alt: modifiers.alt,
    }
}

const fn terminal_mouse_button(button: GpuiMouseButton) -> Option<MouseButton> {
    match button {
        GpuiMouseButton::Left => Some(MouseButton::Left),
        GpuiMouseButton::Middle => Some(MouseButton::Middle),
        GpuiMouseButton::Right => Some(MouseButton::Right),
        GpuiMouseButton::Navigate(_) => None,
    }
}

const fn mouse_button_index(button: MouseButton) -> usize {
    match button {
        MouseButton::Left => 0,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    }
}

#[must_use]
pub fn terminal_cell_at(
    x: f32,
    y: f32,
    cell_width: f32,
    line_height: f32,
    size: surface::GridSize,
) -> Option<(usize, usize)> {
    let content_x = x - TERMINAL_PADDING;
    let content_y = y - TERMINAL_HEADER_HEIGHT - TERMINAL_PADDING;
    if content_x < 0.0 || content_y < 0.0 {
        return None;
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let column = (content_x / cell_width).floor() as usize;
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let row = (content_y / line_height).floor() as usize;
    (column < size.columns() && row < size.rows()).then_some((column, row))
}

#[must_use]
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub fn terminal_grid_size(
    width: f32,
    height: f32,
    cell_width: f32,
    line_height: f32,
) -> (usize, usize) {
    let content_width = (width - TERMINAL_PADDING * 2.0).max(1.0);
    let content_height = (height - TERMINAL_HEADER_HEIGHT - TERMINAL_PADDING * 2.0).max(1.0);
    (
        (content_width / cell_width).floor().max(1.0) as usize,
        (content_height / line_height).floor().max(1.0) as usize,
    )
}

fn measure_terminal_metrics(
    window: &Window,
    appearance: &workspace::Appearance,
) -> TerminalMetrics {
    let font_size = px(f32::from(appearance.font_size()));
    let text_system = window.text_system();
    let font_id = text_system.resolve_font(&font(appearance.font_family().to_owned()));
    let cell_width =
        normalize_cell_width(text_system.advance(font_id, font_size, '0').map_or_else(
            |_| f32::from(text_system.bounding_box(font_id, font_size).size.width),
            |advance| f32::from(advance.width),
        ));
    let line_height = (f32::from(text_system.ascent(font_id, font_size))
        + f32::from(text_system.descent(font_id, font_size))
        + CELL_LINE_GAP)
        .ceil()
        .max(1.0);
    TerminalMetrics {
        cell_width,
        line_height,
    }
}

fn normalize_cell_width(measured: f32) -> f32 {
    measured.max(1.0)
}

#[must_use]
#[allow(
    clippy::cast_possible_truncation,
    reason = "truncating completed fractional lines is the wheel-step boundary"
)]
pub fn terminal_wheel_steps(remainder: &mut f32, vertical_delta: f32, line_height: f32) -> i32 {
    if !vertical_delta.is_finite() || !line_height.is_finite() || line_height <= 0.0 {
        return 0;
    }
    let total = *remainder + vertical_delta / line_height;
    let completed = total.trunc();
    let wheel_limit = f32::from(MAX_WHEEL_EVENTS_PER_CALLBACK);
    let dispatched = completed.clamp(-wheel_limit, wheel_limit);
    *remainder = total - dispatched;
    dispatched as i32
}

fn restore_undelivered_wheel_steps(remainder: &mut f32, steps: i32, delivered: u32) {
    let undelivered = i16::try_from(steps.unsigned_abs().saturating_sub(delivered))
        .expect("wheel callback is bounded");
    let signed = if steps < 0 { -undelivered } else { undelivered };
    *remainder += f32::from(signed);
}

#[must_use]
pub const fn terminal_wheel_action(completed_steps: i32) -> Option<MouseAction> {
    if completed_steps > 0 {
        Some(MouseAction::WheelUp)
    } else if completed_steps < 0 {
        Some(MouseAction::WheelDown)
    } else {
        None
    }
}

/// Start the GPUI event loop and open Ghosthub's first native window.
///
/// # Panics
///
/// Panics if GPUI cannot create the application window.
pub fn run(status: PortStatus, workspace: Workspace) {
    Application::new().run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(1100.0), px(720.0)), cx);

        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some(WINDOW_TITLE.into()),
                    ..Default::default()
                }),
                ..Default::default()
            },
            move |window, cx| cx.new(|cx| RootView::new(status, workspace.clone(), window, cx)),
        )
        .expect("failed to open the Ghosthub window");

        cx.activate(true);
    });
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::{
        INPUT_BUFFER_FULL_DIAGNOSTIC, INPUT_BUFFERED_DIAGNOSTIC, InputRefusal, PendingUiInput,
        QueuedUiInput, TerminalKeyboard, TerminalPointer, UI_INPUT_BYTE_CAPACITY,
        UI_INPUT_CAPACITY, clear_terminal_input_state, clears_after_input_delivery,
        clears_when_input_queue_is_empty, input_queue_has_capacity, named_key,
        normalize_cell_width, restore_undelivered_wheel_steps, terminal_key_input,
        terminal_wheel_steps, transitioned_presentation,
    };
    use workspace::{
        KeyEvent, KeyInput, Modifiers, MouseAction, MouseButton, MouseInput, NamedKey,
    };

    #[test]
    fn a_refused_input_stays_visible_until_later_input_is_delivered() {
        assert!(clears_when_input_queue_is_empty(Some(
            INPUT_BUFFERED_DIAGNOSTIC
        )));
        assert!(!clears_when_input_queue_is_empty(Some(
            INPUT_BUFFER_FULL_DIAGNOSTIC
        )));

        let mut refusal = InputRefusal::default();
        let older_input = refusal.acceptance_marker();
        refusal.refuse();
        assert!(!refusal.delivered(older_input));
        assert!(refusal.is_pending());

        let later_input = refusal.acceptance_marker();
        assert!(refusal.delivered(later_input));
        assert!(!refusal.is_pending());
        assert!(!clears_after_input_delivery(
            Some("terminal exited"),
            true,
            false
        ));
        assert!(clears_after_input_delivery(
            Some(INPUT_BUFFER_FULL_DIAGNOSTIC),
            true,
            false
        ));
    }

    #[test]
    fn gpui_keypad_names_preserve_keypad_identity() {
        assert_eq!(named_key("numpad7"), Some(NamedKey::KeypadDigit(7)));
        assert_eq!(named_key("kpenter"), Some(NamedKey::KeypadEnter));
        assert_eq!(named_key("numpadadd"), Some(NamedKey::KeypadAdd));
    }

    #[test]
    fn gpui_keyboard_events_preserve_logical_keys_and_event_types() {
        let keystroke = gpui::Keystroke {
            modifiers: gpui::Modifiers {
                shift: true,
                ..gpui::Modifiers::default()
            },
            key: "1".to_owned(),
            key_char: Some("!".to_owned()),
        };

        assert_eq!(
            terminal_key_input(&keystroke, KeyEvent::Repeat),
            Some(
                KeyInput::text_with_key(
                    "!",
                    "1",
                    Modifiers {
                        shift: true,
                        ..Modifiers::default()
                    },
                )
                .with_event(KeyEvent::Repeat)
            )
        );
        assert_eq!(
            terminal_key_input(&keystroke, KeyEvent::Release),
            Some(
                KeyInput::text_with_key(
                    "!",
                    "1",
                    Modifiers {
                        shift: true,
                        ..Modifiers::default()
                    },
                )
                .with_event(KeyEvent::Release)
            )
        );
    }

    #[test]
    fn unsupported_keys_without_text_are_silent() {
        for key in ["capslock", "shift", "control", "alt", "meta", "printscreen"] {
            let keystroke = gpui::Keystroke {
                modifiers: gpui::Modifiers::default(),
                key: key.to_owned(),
                key_char: None,
            };

            assert_eq!(terminal_key_input(&keystroke, KeyEvent::Press), None);
            assert_eq!(terminal_key_input(&keystroke, KeyEvent::Release), None);
        }
    }

    #[test]
    fn space_without_key_char_remains_printable() {
        let keystroke = gpui::Keystroke {
            modifiers: gpui::Modifiers::default(),
            key: "space".to_owned(),
            key_char: None,
        };

        assert_eq!(
            terminal_key_input(&keystroke, KeyEvent::Press),
            Some(KeyInput::text_with_key(" ", " ", Modifiers::default()))
        );
    }

    #[test]
    fn pressed_mouse_button_releases_at_the_last_terminal_cell() {
        let mut pointer = TerminalPointer::default();

        pointer.press(MouseButton::Left, (4, 7));
        assert_eq!(pointer.observe(Some((8, 9))), Some((8, 9)));
        assert_eq!(pointer.release_cell(MouseButton::Left, None), Some((8, 9)));
        assert_eq!(pointer.release_cell(MouseButton::Left, None), Some((8, 9)));
        pointer.finish_release(MouseButton::Left);
        assert_eq!(pointer.release_cell(MouseButton::Left, None), None);
    }

    #[test]
    fn untracked_mouse_release_is_silent() {
        let mut pointer = TerminalPointer::default();

        assert_eq!(pointer.release_cell(MouseButton::Right, Some((2, 3))), None);
        assert_eq!(pointer.release_cell(MouseButton::Right, None), None);
    }

    #[test]
    fn refused_wheel_events_return_to_the_fractional_accumulator() {
        let mut remainder: f32 = 0.25;

        restore_undelivered_wheel_steps(&mut remainder, 64, 10);
        assert!((remainder - 54.25).abs() < f32::EPSILON);

        restore_undelivered_wheel_steps(&mut remainder, -64, 60);
        assert!((remainder - 50.25).abs() < f32::EPSILON);
    }

    #[test]
    fn pending_wheel_steps_drain_without_a_new_gesture() {
        let mut remainder: f32 = 130.5;

        assert_eq!(terminal_wheel_steps(&mut remainder, 0.0, 1.0), 64);
        assert_eq!(terminal_wheel_steps(&mut remainder, 0.0, 1.0), 64);
        assert_eq!(terminal_wheel_steps(&mut remainder, 0.0, 1.0), 2);
        assert!((remainder - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn shared_input_queue_reserves_capacity_for_balancing_releases() {
        let mouse_release = PendingUiInput::Mouse(MouseInput {
            action: MouseAction::Release(MouseButton::Left),
            column: 0,
            row: 0,
            modifiers: Modifiers::default(),
        });
        let key_release = PendingUiInput::Key(
            KeyInput::named(NamedKey::Enter, Modifiers::default()).with_event(KeyEvent::Release),
        );
        let key_repeat = PendingUiInput::Key(
            KeyInput::named(NamedKey::Enter, Modifiers::default()).with_event(KeyEvent::Repeat),
        );

        assert!(input_queue_has_capacity(
            &mouse_release,
            UI_INPUT_CAPACITY - 1,
            0,
            0,
            1,
        ));
        assert!(!input_queue_has_capacity(
            &mouse_release,
            UI_INPUT_CAPACITY,
            0,
            0,
            1,
        ));
        assert!(input_queue_has_capacity(
            &key_release,
            UI_INPUT_CAPACITY - 1,
            UI_INPUT_BYTE_CAPACITY,
            1,
            1,
        ));
        assert!(!input_queue_has_capacity(
            &key_repeat,
            UI_INPUT_CAPACITY - 4,
            0,
            0,
            1,
        ));
        assert!(input_queue_has_capacity(
            &key_repeat,
            UI_INPUT_CAPACITY - 5,
            0,
            0,
            1,
        ));
    }

    #[test]
    fn accepted_key_press_reserves_capacity_until_release_is_accepted() {
        let mut keyboard = TerminalKeyboard::default();
        let press = KeyInput::text_with_key("!", "1", Modifiers::default());
        let release_without_text = gpui::Keystroke {
            modifiers: gpui::Modifiers::default(),
            key: "a".to_owned(),
            key_char: None,
        };

        assert!(keyboard.accepts("a", KeyEvent::Press));
        assert!(!keyboard.accepts("a", KeyEvent::Repeat));
        assert!(!keyboard.accepts("a", KeyEvent::Release));
        assert_eq!(keyboard.reservations_after_press("a"), 1);
        keyboard.finish_accepted("a", Some(press.clone()), KeyEvent::Press);
        assert_eq!(keyboard.reserved_releases(), 1);
        assert_eq!(keyboard.reservations_after_press("a"), 1);
        assert!(keyboard.accepts("a", KeyEvent::Repeat));
        assert!(keyboard.accepts("a", KeyEvent::Release));
        assert!(!keyboard.accepts("b", KeyEvent::Repeat));
        assert!(!keyboard.accepts("b", KeyEvent::Release));
        assert_eq!(
            keyboard.input_for("a", KeyEvent::Release),
            Some(press.clone().with_event(KeyEvent::Release))
        );
        assert_eq!(
            terminal_key_input(&release_without_text, KeyEvent::Release),
            None
        );

        keyboard.finish_accepted("a", None, KeyEvent::Repeat);
        assert_eq!(keyboard.reserved_releases(), 1);
        keyboard.finish_accepted("a", None, KeyEvent::Release);
        assert_eq!(keyboard.reserved_releases(), 0);
        assert!(!keyboard.accepts("a", KeyEvent::Repeat));
        assert!(!keyboard.accepts("a", KeyEvent::Release));
    }

    #[test]
    fn measured_fractional_cell_width_is_not_rounded() {
        assert!((normalize_cell_width(8.25) - 8.25).abs() < f32::EPSILON);
        assert!((normalize_cell_width(0.5) - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn presentation_transition_clears_all_terminal_input_state() {
        let mut observed = Some(7);
        let mut paste_confirmation = true;
        let mut pending_input = VecDeque::from([QueuedUiInput {
            input: PendingUiInput::Key(KeyInput::Named {
                key: NamedKey::Enter,
                modifiers: Modifiers::default(),
                event: KeyEvent::Press,
            }),
            bytes: 0,
            accepted_after_refusal: None,
        }]);
        let mut pending_input_bytes = 64;
        let mut refusal = InputRefusal::default();
        refusal.refuse();

        assert!(transitioned_presentation(&mut observed, None));
        clear_terminal_input_state(
            &mut paste_confirmation,
            &mut pending_input,
            &mut pending_input_bytes,
            &mut refusal,
        );

        assert_eq!(observed, None);
        assert!(!paste_confirmation);
        assert!(pending_input.is_empty());
        assert_eq!(pending_input_bytes, 0);
        assert!(!refusal.is_pending());

        paste_confirmation = true;
        pending_input.push_back(QueuedUiInput {
            input: PendingUiInput::Key(KeyInput::Named {
                key: NamedKey::Enter,
                modifiers: Modifiers::default(),
                event: KeyEvent::Press,
            }),
            bytes: 0,
            accepted_after_refusal: None,
        });
        pending_input_bytes = 64;
        refusal.refuse();
        assert!(transitioned_presentation(&mut observed, Some(8)));
        clear_terminal_input_state(
            &mut paste_confirmation,
            &mut pending_input,
            &mut pending_input_bytes,
            &mut refusal,
        );

        assert_eq!(observed, Some(8));
        assert!(!paste_confirmation);
        assert!(pending_input.is_empty());
        assert_eq!(pending_input_bytes, 0);
        assert!(!refusal.is_pending());
        assert!(!transitioned_presentation(&mut observed, Some(8)));
    }
}
