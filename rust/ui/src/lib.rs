//! GPUI presentation for the Rust Ghosthub application.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, Focusable, FontWeight,
    IntoElement, KeyBinding, KeyDownEvent, KeyUpEvent, MouseButton as GpuiMouseButton,
    MouseDownEvent, MouseMoveEvent, MouseUpEvent, Render, ScrollWheelEvent, TitlebarOptions,
    Window, WindowBackgroundAppearance, WindowBounds, WindowControlArea, WindowDecorations,
    WindowOptions, actions, div, font, prelude::*, px, rgb, size,
};
use model::PortStatus;
use surface::{CellStyle, Damage, GridSize, Rgb, SurfaceFrame, SurfaceStore};
use workspace::{
    HostConnectionState, HostItem, KeyEvent as InputKeyEvent, KeyInput,
    Modifiers as InputModifiers, MouseAction, MouseButton, MouseInput, NamedKey, SessionSelection,
    Workspace, WorkspaceContent, WorkspaceEvent,
};

pub const WINDOW_TITLE: &str = "Ghosthub";
const APP_NAVIGATION_WIDTH: f32 = 260.0;
const APP_TITLEBAR_HEIGHT: f32 = 32.0;
const APP_CHROME_BACKGROUND: u32 = 0x0f_1116;
const NAVIGATION_HEADER_HEIGHT: f32 = 36.0;
const HOST_ROW_HEIGHT: f32 = 42.0;
const SESSION_ROW_HEIGHT: f32 = 30.0;
const CELL_LINE_GAP: f32 = 4.0;
const UI_INPUT_CAPACITY: usize = 512;
const MOUSE_RELEASE_RESERVE: usize = 3;
const MAX_WHEEL_EVENTS_PER_CALLBACK: usize = 64;
const UI_INPUT_BYTE_CAPACITY: usize = 512 * 1024;
const INPUT_BUFFERED_DIAGNOSTIC: &str = "Terminal is busy; input is buffered.";
const INPUT_BUFFER_FULL_DIAGNOSTIC: &str =
    "Terminal input buffer is full; wait for pending input to be delivered.";

actions!(ghosthub, [ToggleSidebar]);

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
    keyboard: TerminalKeyboard,
    pointer: TerminalPointer,
    sidebar_visible: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct WheelBatch {
    input: MouseInput,
    remaining: u32,
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

    fn input_for(
        &self,
        key: &str,
        event: InputKeyEvent,
        modifiers: InputModifiers,
    ) -> Option<KeyInput> {
        self.pressed.get(key).cloned().map(|mut input| {
            match &mut input {
                KeyInput::Text {
                    modifiers: input_modifiers,
                    ..
                }
                | KeyInput::Named {
                    modifiers: input_modifiers,
                    ..
                } => *input_modifiers = modifiers,
                KeyInput::Paste(_) => {}
            }
            input.with_event(event)
        })
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
    Wheel(WheelBatch),
    ClipboardResponse(Vec<u8>),
    Resize(TerminalResize),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TerminalResize {
    columns: usize,
    rows: usize,
    pixel_width: u16,
    pixel_height: u16,
}

struct QueuedUiInput {
    presentation_id: u64,
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
            Self::Key(KeyInput::Named { .. })
            | Self::Mouse(_)
            | Self::Wheel(_)
            | Self::Resize(_) => 0,
        }
    }

    const fn counts_toward_input_capacity(&self) -> bool {
        !matches!(self, Self::Resize(_))
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
    if !input.counts_toward_input_capacity() {
        return true;
    }
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
                        if scope_changed || handled || flushed || view.poll_changed() {
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
            keyboard: TerminalKeyboard::default(),
            pointer: TerminalPointer::default(),
            sidebar_visible: true,
        };
        view.resize_for_window(window);
        view
    }

    #[must_use]
    pub fn headline(&self) -> String {
        headline_text(&self.status)
    }

    fn attach(
        &mut self,
        selection: &SessionSelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Err(error) = self.workspace.attach(selection) {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
            window.focus(&self.focus);
        }
        cx.notify();
    }

    fn select_session(
        &mut self,
        selection: &SessionSelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let snapshot = self.workspace.snapshot();
        if active_session_selection(snapshot.content()).as_ref() == Some(selection) {
            if matches!(snapshot.content(), WorkspaceContent::Terminal { .. }) {
                window.focus(&self.focus);
            }
            return;
        }

        let switching = matches!(
            snapshot.content(),
            WorkspaceContent::Attaching { .. } | WorkspaceContent::Terminal { .. }
        );
        let result = if switching {
            self.workspace.switch_session(selection)
        } else {
            self.workspace.attach(selection)
        };
        if let Err(error) = result {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
            self.observed_presentation_id = None;
            self.clear_terminal_input();
            self.paint_cache.clear();
            self.resize_for_window(window);
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

    fn toggle_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sidebar_visible = !self.sidebar_visible;
        self.resize_for_window(window);
        if matches!(
            self.workspace.snapshot().content(),
            WorkspaceContent::Terminal { .. }
        ) {
            window.focus(&self.focus);
        }
        cx.notify();
    }

    fn navigation_width(&self, snapshot: &workspace::WorkspaceSnapshot) -> f32 {
        application_navigation_width(self.sidebar_visible, !snapshot.hosts().is_empty())
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

    fn presentation_accepts_input(&mut self, presentation_id: u64) -> bool {
        let _scope_changed = self.sync_terminal_scope();
        terminal_presentation_id(self.workspace.snapshot().content()) == Some(presentation_id)
    }

    fn clear_terminal_input(&mut self) {
        clear_terminal_input_state(
            &mut self.paste_confirmation,
            &mut self.pending_input,
            &mut self.pending_input_bytes,
            &mut self.input_refusal,
        );
        self.wheel_remainder = 0.0;
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
                    if let Some(presentation_id) =
                        terminal_presentation_id(self.workspace.snapshot().content())
                    {
                        self.enqueue_input(
                            presentation_id,
                            PendingUiInput::ClipboardResponse(request.respond(&contents)),
                        );
                    }
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

    fn on_key_down(
        &mut self,
        presentation_id: u64,
        event: &KeyDownEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        let keystroke = &event.keystroke;
        if is_toggle_sidebar_shortcut(keystroke) {
            // The application key binding owns this chord. Leave propagation
            // intact so GPUI dispatches ToggleSidebar, but never enqueue it as
            // terminal input.
            return;
        }
        if is_paste_shortcut(keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                self.send_key(presentation_id, KeyInput::paste(text));
            }
            cx.stop_propagation();
            return;
        }

        let event = if event.is_held {
            InputKeyEvent::Repeat
        } else {
            InputKeyEvent::Press
        };
        let input = terminal_key_input(keystroke, event).or_else(|| {
            self.keyboard
                .input_for(&keystroke.key, event, input_modifiers(keystroke.modifiers))
        });
        if let Some(input) = input {
            self.send_key_event(presentation_id, input, &keystroke.key, event);
            cx.stop_propagation();
        }
    }

    fn on_key_up(
        &mut self,
        presentation_id: u64,
        event: &KeyUpEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        if is_paste_shortcut(&event.keystroke) || is_toggle_sidebar_shortcut(&event.keystroke) {
            cx.stop_propagation();
            return;
        }
        if let Some(input) = self.keyboard.input_for(
            &event.keystroke.key,
            InputKeyEvent::Release,
            input_modifiers(event.keystroke.modifiers),
        ) {
            self.send_key_event(
                presentation_id,
                input,
                &event.keystroke.key,
                InputKeyEvent::Release,
            );
            cx.stop_propagation();
        }
    }

    fn on_mouse_down(
        &mut self,
        presentation_id: u64,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        window.focus(&self.focus);
        if let Some(button) = terminal_mouse_button(event.button) {
            let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
            if let Some(cell) = cell
                && self.send_mouse_at_cell(
                    presentation_id,
                    MouseAction::Press(button),
                    cell,
                    event.modifiers,
                )
            {
                self.pointer.press(button, cell);
            }
            cx.stop_propagation();
        }
    }

    fn on_mouse_up(
        &mut self,
        presentation_id: u64,
        event: &MouseUpEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        if let Some(button) = terminal_mouse_button(event.button) {
            let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
            if let Some(cell) = self.pointer.release_cell(button, cell) {
                if self.send_mouse_at_cell(
                    presentation_id,
                    MouseAction::Release(button),
                    cell,
                    event.modifiers,
                ) {
                    self.pointer.finish_release(button);
                }
                cx.stop_propagation();
            }
        }
    }

    fn on_mouse_move(
        &mut self,
        presentation_id: u64,
        event: &MouseMoveEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        let button = event.pressed_button.and_then(terminal_mouse_button);
        let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
        if let Some(cell) = self.pointer.observe(cell) {
            self.send_mouse_at_cell(
                presentation_id,
                MouseAction::Move(button),
                cell,
                event.modifiers,
            );
        }
        cx.stop_propagation();
    }

    fn on_scroll_wheel(
        &mut self,
        presentation_id: u64,
        event: &ScrollWheelEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        let delta = event
            .delta
            .pixel_delta(px(self.terminal_metrics.line_height));
        let vertical = f32::from(delta.y);
        if vertical == 0.0 {
            return;
        }
        if let Some(cell) = self.terminal_cell_at(event.position.x.into(), event.position.y.into())
        {
            let steps = terminal_wheel_steps(
                &mut self.wheel_remainder,
                vertical,
                self.terminal_metrics.line_height,
            );
            if let Some(action) = terminal_wheel_action(steps) {
                let input = MouseInput {
                    action,
                    column: cell.0,
                    row: cell.1,
                    modifiers: input_modifiers(event.modifiers),
                };
                let _accepted = self.enqueue_input(
                    presentation_id,
                    PendingUiInput::Wheel(WheelBatch {
                        input,
                        remaining: steps.unsigned_abs(),
                    }),
                );
            }
        }
        cx.stop_propagation();
    }

    fn terminal_cell_at(&self, x: f32, y: f32) -> Option<(usize, usize)> {
        let snapshot = self.workspace.snapshot();
        let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
            return None;
        };
        let size = surface.load().size();
        terminal_cell_at_with_offset(
            x,
            y,
            self.navigation_width(&snapshot),
            APP_TITLEBAR_HEIGHT,
            self.terminal_metrics.cell_width,
            self.terminal_metrics.line_height,
            size,
        )
    }

    fn send_mouse_at_cell(
        &mut self,
        presentation_id: u64,
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
        self.enqueue_input(presentation_id, PendingUiInput::Mouse(input))
    }

    fn send_key(&mut self, presentation_id: u64, input: KeyInput) {
        self.enqueue_input(presentation_id, PendingUiInput::Key(input));
    }

    fn send_key_event(
        &mut self,
        presentation_id: u64,
        input: KeyInput,
        key: &str,
        event: InputKeyEvent,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        if !self.keyboard.accepts(key, event) {
            return;
        }
        let reserved_key_releases = match event {
            InputKeyEvent::Press => self.keyboard.reservations_after_press(key),
            InputKeyEvent::Repeat | InputKeyEvent::Release => self.keyboard.reserved_releases(),
        };
        let pressed_input = (event == InputKeyEvent::Press).then(|| input.clone());
        if self.enqueue_input_with_reserve(
            presentation_id,
            PendingUiInput::Key(input),
            reserved_key_releases,
        ) {
            self.keyboard.finish_accepted(key, pressed_input, event);
        }
    }

    fn enqueue_input(&mut self, presentation_id: u64, input: PendingUiInput) -> bool {
        self.enqueue_input_with_reserve(presentation_id, input, self.keyboard.reserved_releases())
    }

    fn enqueue_input_with_reserve(
        &mut self,
        presentation_id: u64,
        input: PendingUiInput,
        reserved_key_releases: usize,
    ) -> bool {
        if !self.presentation_accepts_input(presentation_id) {
            return false;
        }
        if let PendingUiInput::Resize(resize) = &input
            && coalesce_last_resize(&mut self.pending_input, presentation_id, *resize)
        {
            return true;
        }
        if let PendingUiInput::Wheel(batch) = &input
            && coalesce_last_wheel(
                &mut self.pending_input,
                presentation_id,
                *batch,
                self.input_refusal.acceptance_marker(),
            )
        {
            return true;
        }
        if matches!(
            &input,
            PendingUiInput::Mouse(MouseInput {
                action: MouseAction::Move(_),
                ..
            })
        ) && let Some(last) = self.pending_input.back_mut()
            && last.presentation_id == presentation_id
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
            self.pending_input
                .iter()
                .filter(|queued| queued.input.counts_toward_input_capacity())
                .count(),
            self.pending_input_bytes,
            bytes,
            reserved_key_releases,
        ) {
            self.input_refusal.refuse();
            self.diagnostic = Some(INPUT_BUFFER_FULL_DIAGNOSTIC.to_owned());
            return false;
        }
        let accepted_after_refusal = input
            .counts_toward_input_capacity()
            .then(|| self.input_refusal.acceptance_marker())
            .flatten();
        self.pending_input_bytes += bytes;
        self.pending_input.push_back(QueuedUiInput {
            presentation_id,
            input,
            bytes,
            accepted_after_refusal,
        });
        let _changed = self.flush_pending_input();
        true
    }

    fn flush_pending_input(&mut self) -> bool {
        let mut changed = self.sync_terminal_scope();
        let mut delivered_wheel_steps = 0;
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
            if delivered_wheel_steps >= MAX_WHEEL_EVENTS_PER_CALLBACK
                && matches!(input.input, PendingUiInput::Wheel(_))
            {
                return changed;
            }
            let active_presentation = terminal_presentation_id(self.workspace.snapshot().content());
            if !queued_input_matches_presentation(input, active_presentation) {
                let stale = self.pending_input.pop_front().expect("front input exists");
                self.pending_input_bytes = self.pending_input_bytes.saturating_sub(stale.bytes);
                changed = true;
                continue;
            }
            let result = match &input.input {
                PendingUiInput::Key(input) => self.workspace.send_key(input.clone()),
                PendingUiInput::Mouse(input) => self.workspace.send_mouse(*input),
                PendingUiInput::Wheel(batch) => self.workspace.send_mouse(batch.input),
                PendingUiInput::ClipboardResponse(bytes) => {
                    self.workspace.send_clipboard_response(bytes.clone())
                }
                PendingUiInput::Resize(resize) => self.workspace.resize_with_pixels(
                    resize.columns,
                    resize.rows,
                    resize.pixel_width,
                    resize.pixel_height,
                ),
            };
            match result {
                Ok(()) => {
                    if let Some(QueuedUiInput {
                        input: PendingUiInput::Wheel(batch),
                        ..
                    }) = self.pending_input.front_mut()
                    {
                        debug_assert!(batch.remaining > 0);
                        batch.remaining = batch.remaining.saturating_sub(1);
                        delivered_wheel_steps += 1;
                        changed = true;
                        if batch.remaining > 0 {
                            if delivered_wheel_steps >= MAX_WHEEL_EVENTS_PER_CALLBACK {
                                return changed;
                            }
                            continue;
                        }
                    }
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
        let snapshot = self.workspace.snapshot();
        let width = f32::from(bounds.size.width) - self.navigation_width(&snapshot);
        let height = f32::from(bounds.size.height) - APP_TITLEBAR_HEIGHT;
        let (columns, rows) = terminal_grid_size(
            width,
            height,
            self.terminal_metrics.cell_width,
            self.terminal_metrics.line_height,
        );
        let content_width = width.max(1.0);
        let content_height = height.max(1.0);
        let pixel_width = content_width.min(f32::from(u16::MAX)) as u16;
        let pixel_height = content_height.min(f32::from(u16::MAX)) as u16;
        let resize = TerminalResize {
            columns,
            rows,
            pixel_width,
            pixel_height,
        };
        if let Some(presentation_id) = terminal_presentation_id(snapshot.content()) {
            let _accepted = self.enqueue_input(presentation_id, PendingUiInput::Resize(resize));
        } else if let Err(error) = self.workspace.resize_with_pixels(
            resize.columns,
            resize.rows,
            resize.pixel_width,
            resize.pixel_height,
        ) {
            self.diagnostic = Some(error.to_string());
        }
    }

    fn approve_paste(&mut self, presentation_id: u64, cx: &mut Context<Self>) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        if let Err(error) = self.workspace.approve_paste() {
            self.diagnostic = Some(error.to_string());
        }
        self.paste_confirmation = false;
        let _changed = self.flush_pending_input();
        cx.notify();
    }

    fn cancel_paste(&mut self, presentation_id: u64, cx: &mut Context<Self>) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        self.workspace.cancel_paste();
        self.paste_confirmation = false;
        let _changed = self.flush_pending_input();
        cx.notify();
    }

    fn terminal_element(
        &mut self,
        presentation_id: u64,
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
        let terminal = self.terminal_surface_element(presentation_id, appearance, rows, cx);

        div()
            .size_full()
            .flex()
            .flex_col()
            .overflow_hidden()
            .bg(rgb(appearance.background()))
            .child(terminal)
    }

    fn terminal_surface_element(
        &self,
        presentation_id: u64,
        appearance: &workspace::Appearance,
        rows: Vec<Arc<Vec<PaintRun>>>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .id("terminal-surface")
            .track_focus(&self.focus)
            .flex()
            .flex_col()
            .flex_1()
            .overflow_hidden()
            .bg(rgb(appearance.background()))
            .text_color(rgb(appearance.foreground()))
            .font_family(appearance.font_family().to_owned())
            .text_size(px(f32::from(appearance.font_size())))
            .line_height(px(self.terminal_metrics.line_height))
            .font_weight(FontWeight::NORMAL)
            .on_key_down(cx.listener(move |this, event, window, cx| {
                this.on_key_down(presentation_id, event, window, cx);
            }))
            .on_key_up(cx.listener(move |this, event, window, cx| {
                this.on_key_up(presentation_id, event, window, cx);
            }))
            .on_mouse_down(
                GpuiMouseButton::Left,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_down(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_down(
                GpuiMouseButton::Middle,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_down(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_down(
                GpuiMouseButton::Right,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_down(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up(
                GpuiMouseButton::Left,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up(
                GpuiMouseButton::Middle,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up(
                GpuiMouseButton::Right,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up_out(
                GpuiMouseButton::Left,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up_out(
                GpuiMouseButton::Middle,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up_out(
                GpuiMouseButton::Right,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_move(cx.listener(move |this, event, window, cx| {
                this.on_mouse_move(presentation_id, event, window, cx);
            }))
            .on_scroll_wheel(cx.listener(move |this, event, window, cx| {
                this.on_scroll_wheel(presentation_id, event, window, cx);
            }))
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
            }))
    }

    fn content_element(
        &mut self,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        if !snapshot.hosts().is_empty() {
            return self.application_shell(snapshot, cx);
        }
        match snapshot.content() {
            WorkspaceContent::Shell => centered("No terminal hosts are available."),
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
            WorkspaceContent::Attaching {
                endpoint, session, ..
            } => centered(format!("Attaching to {endpoint} · {session}…")),
            WorkspaceContent::Ready { endpoint, sessions } => {
                Self::ready_element(endpoint, sessions, None, cx)
            }
            WorkspaceContent::Terminal {
                endpoint: _,
                session: _,
                presentation_id,
                surface,
                ..
            } => self
                .terminal_element(*presentation_id, surface, snapshot, cx)
                .into_any_element(),
        }
    }

    fn application_shell(
        &mut self,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let hosts = snapshot.hosts();
        let selected = snapshot
            .selected_host()
            .and_then(|id| hosts.iter().find(|host| host.id() == id));
        let main = match snapshot.content() {
            WorkspaceContent::Terminal {
                endpoint: _,
                session: _,
                presentation_id,
                surface,
                ..
            } => self
                .terminal_element(*presentation_id, surface, snapshot, cx)
                .into_any_element(),
            WorkspaceContent::Attaching {
                endpoint, session, ..
            } => centered(format!("Attaching to {endpoint} · {session}…")),
            WorkspaceContent::Loading => centered("Starting WSL and discovering tmux sessions…"),
            WorkspaceContent::Error { message } => centered(message.clone()),
            WorkspaceContent::Shell | WorkspaceContent::Ready { .. } => selected.map_or_else(
                || centered("No terminal hosts are available."),
                |host| Self::host_landing_element(host, cx),
            ),
        };
        let mut shell = div().size_full().flex().min_w_0();
        if self.sidebar_visible {
            shell = shell.child(Self::workspace_tree(snapshot, cx));
        }
        shell
            .child(div().flex_1().min_w_0().h_full().child(main))
            .into_any_element()
    }

    fn title_bar(&self, title: String, cx: &mut Context<Self>) -> gpui::AnyElement {
        let toggle_label = if self.sidebar_visible {
            "Hide sidebar (Ctrl+Shift+B)"
        } else {
            "Show sidebar (Ctrl+Shift+B)"
        };

        div()
            .h(px(APP_TITLEBAR_HEIGHT))
            .w_full()
            .flex_none()
            .flex()
            .items_center()
            .bg(rgb(APP_CHROME_BACKGROUND))
            .border_b_1()
            .border_color(rgb(0x20_242c))
            .child(
                div()
                    .id("toggle-sidebar")
                    .w(px(APP_TITLEBAR_HEIGHT))
                    .h_full()
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .text_size(px(16.0))
                    .text_color(rgb(0xa5_acb8))
                    .hover(|style| style.bg(rgb(0x24_2933)).text_color(rgb(0xe5_e9f0)))
                    .child("☰")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.toggle_sidebar(window, cx);
                    })),
            )
            .child(
                div()
                    .id("window-drag-region")
                    .h_full()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .window_control_area(WindowControlArea::Drag)
                    .on_mouse_down(GpuiMouseButton::Left, |_, window, _| {
                        window.start_window_move();
                    })
                    .text_sm()
                    .text_color(rgb(0xc4_c9d2))
                    .child(title),
            )
            .child(window_control(
                "window-minimize",
                "−",
                WindowControlArea::Min,
            ))
            .child(window_control(
                "window-maximize",
                "□",
                WindowControlArea::Max,
            ))
            .child(window_control(
                "window-close",
                "×",
                WindowControlArea::Close,
            ))
            .on_mouse_down(GpuiMouseButton::Right, |event, window, _| {
                window.show_window_menu(event.position);
            })
            .child(
                div()
                    .id("sidebar-shortcut-description")
                    .absolute()
                    .invisible()
                    .child(toggle_label),
            )
            .into_any_element()
    }

    fn workspace_tree(
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut body = div()
            .id("workspace-tree-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .overflow_x_hidden();
        for (host_index, host) in snapshot.hosts().iter().enumerate() {
            body = body.child(Self::host_tree(
                host_index,
                host,
                snapshot.selected_host() == Some(host.id()),
                snapshot.content(),
                snapshot.retained_selections(),
                cx,
            ));
        }

        div()
            .w(px(APP_NAVIGATION_WIDTH))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .bg(rgb(APP_CHROME_BACKGROUND))
            .border_r_1()
            .border_color(rgb(0x25_2932))
            .child(
                div()
                    .h(px(NAVIGATION_HEADER_HEIGHT))
                    .flex_none()
                    .flex()
                    .items_center()
                    .px_2()
                    .border_b_1()
                    .border_color(rgb(0x1d_2028))
                    .text_xs()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(0xa5_ac_b8))
                    .child("WORKSPACES"),
            )
            .child(body)
            .into_any_element()
    }

    fn host_tree(
        host_index: usize,
        host: &HostItem,
        is_selected: bool,
        content: &WorkspaceContent,
        retained: &[SessionSelection],
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut host_tree =
            div()
                .flex()
                .flex_col()
                .child(Self::host_header(host_index, host, is_selected, cx));

        match host.connection() {
            HostConnectionState::Connecting => {
                host_tree = host_tree.child(Self::host_status_row(
                    host_index,
                    "Refreshing sessions…".to_owned(),
                    "Cancel",
                    true,
                    cx,
                ));
            }
            HostConnectionState::Unavailable => {
                let message = host.diagnostic().map_or_else(
                    || "Host unavailable".to_owned(),
                    |diagnostic| diagnostic.message().to_owned(),
                );
                host_tree = host_tree.child(Self::host_status_row(
                    host_index, message, "Retry", false, cx,
                ));
            }
            HostConnectionState::Disconnected => {
                host_tree = host_tree.child(Self::host_status_row(
                    host_index,
                    "Host disconnected".to_owned(),
                    "Connect",
                    false,
                    cx,
                ));
            }
            HostConnectionState::Ready => {}
        }

        let sessions = tree_sessions(host, content, retained);
        if host.connection() == HostConnectionState::Ready || !sessions.is_empty() {
            host_tree = host_tree.child(Self::session_tree(host_index, &sessions, cx));
        }
        host_tree.into_any_element()
    }

    fn host_header(
        host_index: usize,
        host: &HostItem,
        is_selected: bool,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let status_color = match host.connection() {
            HostConnectionState::Ready => 0x62_c0_7a,
            HostConnectionState::Connecting => 0xd3_a4_4a,
            HostConnectionState::Disconnected => 0x8f_96_a3,
            HostConnectionState::Unavailable => 0xd0_65_65,
        };
        let mut host_header = div()
            .id(("host", host_index))
            .h(px(HOST_ROW_HEIGHT))
            .flex()
            .items_center()
            .gap_1()
            .px_2()
            .bg(rgb(if is_selected { 0x16_1920 } else { 0x0f_1116 }))
            .child(
                div()
                    .w(px(12.0))
                    .flex_none()
                    .text_center()
                    .text_color(rgb(0x6f_7682))
                    .child("▾"),
            )
            .child(
                div()
                    .size(px(7.0))
                    .flex_none()
                    .rounded_full()
                    .bg(rgb(status_color)),
            )
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .truncate()
                            .text_sm()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(rgb(0xd2_d7_df))
                            .child(host.name().to_owned()),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_xs()
                            .text_color(rgb(0x71_7885))
                            .child(host.endpoint().to_owned()),
                    ),
            );
        if host.connection() == HostConnectionState::Ready {
            host_header = host_header.child(
                div()
                    .id(("refresh-host", host_index))
                    .flex_none()
                    .size(px(24.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_xs()
                    .text_color(rgb(0x8f_96_a3))
                    .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xd2_d7_df)))
                    .child("↻")
                    .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
            );
        }
        host_header.into_any_element()
    }

    fn session_tree(
        host_index: usize,
        sessions: &[TreeSession],
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut tree = div()
            .ml(px(18.0))
            .border_l_1()
            .border_color(rgb(0x25_2932))
            .flex()
            .flex_col()
            .child(
                div()
                    .h(px(24.0))
                    .flex()
                    .items_center()
                    .pl(px(17.0))
                    .text_xs()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(0x73_7a87))
                    .child("TMUX SESSIONS"),
            );
        if sessions.is_empty() {
            tree = tree.child(
                div()
                    .h(px(SESSION_ROW_HEIGHT))
                    .flex()
                    .items_center()
                    .pl(px(31.0))
                    .text_xs()
                    .text_color(rgb(0x73_7a87))
                    .child("No sessions"),
            );
        }
        for (session_index, session) in sessions.iter().enumerate() {
            tree = tree.child(Self::tree_session_row(
                host_index,
                session_index,
                &session.selection,
                session.active,
                session.show_endpoint,
                cx,
            ));
        }
        tree.into_any_element()
    }

    fn host_status_row(
        host_index: usize,
        message: String,
        action: &'static str,
        cancel: bool,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let action_id = if cancel {
            "cancel-host-refresh"
        } else {
            "retry-host-refresh"
        };
        div()
            .mx_2()
            .mb_1()
            .px_2()
            .py_2()
            .rounded_sm()
            .bg(rgb(0x16_1920))
            .child(div().text_xs().text_color(rgb(0x9b_a2ae)).child(message))
            .child(
                div()
                    .id((action_id, host_index))
                    .mt_1()
                    .cursor_pointer()
                    .text_xs()
                    .text_color(rgb(0x79_aee3))
                    .hover(|style| style.text_color(rgb(0xb6_d8_f8)))
                    .child(action)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if cancel {
                            this.cancel_refresh(cx);
                        } else {
                            this.refresh(cx);
                        }
                    })),
            )
            .into_any_element()
    }

    fn tree_session_row(
        host_index: usize,
        index: usize,
        selection: &SessionSelection,
        is_active: bool,
        show_endpoint: bool,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let selection = selection.clone();
        let open_selection = selection.clone();
        let name = selection.session().to_owned();
        let mut row = div()
            .id((
                gpui::ElementId::named_usize("tree-session-host", host_index),
                index.to_string(),
            ))
            .mr_1()
            .h(px(SESSION_ROW_HEIGHT))
            .flex()
            .items_center()
            .gap_1()
            .pl(px(14.0))
            .pr_2()
            .cursor_pointer()
            .bg(rgb(if is_active { 0x13_3d6a } else { 0x0f_1116 }))
            .hover(|style| style.bg(rgb(if is_active { 0x17_477a } else { 0x1b_1f27 })))
            .child(
                div()
                    .w(px(18.0))
                    .flex_none()
                    .text_xs()
                    .text_color(rgb(if is_active { 0x9d_c7ed } else { 0x7f_8794 }))
                    .child(">_"),
            )
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .truncate()
                    .text_sm()
                    .text_color(rgb(if is_active { 0xe5_ed_f7 } else { 0xc4_c9_d2 }))
                    .child(name.clone()),
            );
        if show_endpoint {
            row = row.child(
                div()
                    .flex_none()
                    .text_xs()
                    .text_color(rgb(0x73_7a87))
                    .child(format!("· {}", selection.endpoint())),
            );
        }
        if is_active {
            row = row.child(
                div()
                    .id("detach-terminal")
                    .flex_none()
                    .size(px(24.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_sm()
                    .text_color(rgb(0xa9_c9_ea))
                    .hover(|style| style.bg(rgb(0x25_527f)).text_color(rgb(0xff_ff_ff)))
                    .child("×")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.detach(cx);
                        cx.stop_propagation();
                    })),
            );
        } else {
            row = row.child(
                div()
                    .id((
                        gpui::ElementId::named_usize("open-tree-session-host", host_index),
                        index.to_string(),
                    ))
                    .flex_none()
                    .px_1()
                    .py_1()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_xs()
                    .text_color(rgb(0x79_aee3))
                    .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xb6_d8_f8)))
                    .child("Open")
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.select_session(&open_selection, window, cx);
                        cx.stop_propagation();
                    })),
            );
        }
        row.on_click(cx.listener(move |this, _, window, cx| {
            this.select_session(&selection, window, cx);
        }))
        .into_any_element()
    }

    fn host_landing_element(host: &HostItem, cx: &mut Context<Self>) -> gpui::AnyElement {
        if host.connection() == HostConnectionState::Ready {
            return centered(if host.sessions().is_empty() {
                "Start a tmux session in WSL, then refresh."
            } else {
                "Choose a session to open its terminal."
            });
        }
        Self::host_element(host, cx)
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
            let selection =
                SessionSelection::new(host.map_or("wsl", HostItem::id), endpoint, session.name());
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
                        this.attach(&selection, window, cx);
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct TreeSession {
    selection: SessionSelection,
    active: bool,
    show_endpoint: bool,
}

fn active_session_selection(content: &WorkspaceContent) -> Option<SessionSelection> {
    match content {
        WorkspaceContent::Attaching {
            host_id,
            endpoint,
            session,
        }
        | WorkspaceContent::Terminal {
            host_id,
            endpoint,
            session,
            ..
        } => Some(SessionSelection::new(host_id, endpoint, session)),
        WorkspaceContent::Shell
        | WorkspaceContent::Loading
        | WorkspaceContent::Ready { .. }
        | WorkspaceContent::Error { .. } => None,
    }
}

fn tree_sessions(
    host: &HostItem,
    content: &WorkspaceContent,
    retained: &[SessionSelection],
) -> Vec<TreeSession> {
    let active = active_session_selection(content);
    let active_for_host = active
        .as_ref()
        .filter(|active| active.host_id() == host.id());

    let mut selections = if host.connection() == HostConnectionState::Ready {
        host.sessions()
            .iter()
            .map(|session| SessionSelection::new(host.id(), host.endpoint(), session.name()))
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    for selection in retained
        .iter()
        .filter(|selection| selection.host_id() == host.id())
        .chain(active_for_host)
    {
        if !selections.contains(selection) {
            selections.push(selection.clone());
        }
    }
    selections
        .into_iter()
        .map(|selection| TreeSession {
            active: active.as_ref() == Some(&selection),
            show_endpoint: selection.endpoint() != host.endpoint(),
            selection,
        })
        .collect()
}

fn workspace_window_title(content: &WorkspaceContent) -> String {
    match content {
        WorkspaceContent::Attaching {
            endpoint, session, ..
        }
        | WorkspaceContent::Terminal {
            endpoint, session, ..
        } => format!("{session} — {endpoint} — {WINDOW_TITLE}"),
        WorkspaceContent::Ready { endpoint, .. } => format!("{endpoint} — {WINDOW_TITLE}"),
        WorkspaceContent::Shell | WorkspaceContent::Loading | WorkspaceContent::Error { .. } => {
            WINDOW_TITLE.to_owned()
        }
    }
}

const fn application_navigation_width(sidebar_visible: bool, has_hosts: bool) -> f32 {
    if sidebar_visible && has_hosts {
        APP_NAVIGATION_WIDTH
    } else {
        0.0
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

fn queued_input_matches_presentation(
    input: &QueuedUiInput,
    active_presentation: Option<u64>,
) -> bool {
    active_presentation == Some(input.presentation_id)
}

fn coalesce_last_resize(
    pending: &mut VecDeque<QueuedUiInput>,
    presentation_id: u64,
    resize: TerminalResize,
) -> bool {
    let Some(last) = pending.back_mut() else {
        return false;
    };
    if last.presentation_id != presentation_id || !matches!(last.input, PendingUiInput::Resize(_)) {
        return false;
    }
    last.input = PendingUiInput::Resize(resize);
    true
}

fn coalesce_last_wheel(
    pending: &mut VecDeque<QueuedUiInput>,
    presentation_id: u64,
    batch: WheelBatch,
    accepted_after_refusal: Option<u64>,
) -> bool {
    let Some(last) = pending.back_mut() else {
        return false;
    };
    let PendingUiInput::Wheel(pending_batch) = &mut last.input else {
        return false;
    };
    if last.presentation_id != presentation_id || pending_batch.input != batch.input {
        return false;
    }
    pending_batch.remaining = pending_batch.remaining.saturating_add(batch.remaining);
    last.accepted_after_refusal = accepted_after_refusal;
    true
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
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let _scope_changed = self.sync_terminal_scope();
        let _handled = self.handle_events(cx);
        let snapshot = self.workspace.snapshot();
        let title = workspace_window_title(snapshot.content());
        window.set_window_title(&title);
        self.observed_revision = snapshot.revision();
        if !matches!(snapshot.content(), WorkspaceContent::Terminal { .. }) {
            self.observed_surface_identity = None;
            self.observed_surface_generation = 0;
            self.paint_cache.clear();
        }
        let title_bar = self.title_bar(title, cx);
        let content = self.content_element(&snapshot, cx);
        let mut root = div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(snapshot.appearance().background()))
            .text_color(rgb(snapshot.appearance().foreground()))
            .on_action(cx.listener(|this, _: &ToggleSidebar, window, cx| {
                this.toggle_sidebar(window, cx);
            }))
            .child(title_bar)
            .child(div().flex_1().min_h_0().w_full().child(content));

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
        if self.paste_confirmation
            && let Some(presentation_id) = terminal_presentation_id(snapshot.content())
        {
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
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.cancel_paste(presentation_id, cx);
                                    })),
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
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.approve_paste(presentation_id, cx);
                                    })),
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

fn window_control(
    id: &'static str,
    label: &'static str,
    area: WindowControlArea,
) -> gpui::AnyElement {
    let control = div()
        .id(id)
        .w(px(46.0))
        .h_full()
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .window_control_area(area)
        .text_size(px(16.0))
        .text_color(rgb(0xb7_bcc6))
        .child(label)
        .on_click(move |_, window, _| match area {
            WindowControlArea::Min => window.minimize_window(),
            WindowControlArea::Max => window.zoom_window(),
            WindowControlArea::Close => window.remove_window(),
            WindowControlArea::Drag => {}
        });
    if area == WindowControlArea::Close {
        control
            .hover(|style| style.bg(rgb(0xc4_2b1c)).text_color(rgb(0xff_ffff)))
            .into_any_element()
    } else {
        control
            .hover(|style| style.bg(rgb(0x24_2933)).text_color(rgb(0xe5_e9f0)))
            .into_any_element()
    }
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
    if is_toggle_sidebar_shortcut(keystroke) {
        return None;
    }
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
    if let Some(text) =
        key_char.or_else(|| keystroke.key.eq_ignore_ascii_case("space").then_some(" "))
    {
        return Some(KeyInput::text_with_key(text, logical_key, modifiers).with_event(event));
    }
    ctrl_key_input(keystroke, event)
}

fn ctrl_key_input(keystroke: &gpui::Keystroke, event: InputKeyEvent) -> Option<KeyInput> {
    if !keystroke.modifiers.control {
        return None;
    }
    let mut characters = keystroke.key.chars();
    let raw = characters.next()?;
    if characters.next().is_some() {
        return None;
    }

    let mut modifiers = input_modifiers(keystroke.modifiers);
    let (logical, produced) = if modifiers.shift {
        shifted_control_pair(raw).unwrap_or((raw, raw))
    } else if let Some(logical) = unshifted_ascii_key(raw) {
        // GPUI folds Shift into punctuation keys on Windows and clears the
        // modifier. Restore both pieces so Kitty can report the base and
        // shifted codepoints independently.
        modifiers.shift = true;
        (logical, raw)
    } else if raw.is_ascii_uppercase() {
        modifiers.shift = true;
        (raw.to_ascii_lowercase(), raw)
    } else {
        (raw, raw)
    };
    if !is_ascii_control_chord(produced) {
        return None;
    }

    Some(
        KeyInput::text_with_key(produced.to_string(), logical.to_string(), modifiers)
            .with_event(event),
    )
}

fn shifted_control_pair(character: char) -> Option<(char, char)> {
    if character.is_ascii_lowercase() {
        return Some((character, character.to_ascii_uppercase()));
    }
    shifted_ascii_key(character).map(|shifted| (character, shifted))
}

const fn shifted_ascii_key(character: char) -> Option<char> {
    match character {
        '`' => Some('~'),
        '1' => Some('!'),
        '2' => Some('@'),
        '3' => Some('#'),
        '4' => Some('$'),
        '5' => Some('%'),
        '6' => Some('^'),
        '7' => Some('&'),
        '8' => Some('*'),
        '9' => Some('('),
        '0' => Some(')'),
        '-' => Some('_'),
        '=' => Some('+'),
        '[' => Some('{'),
        ']' => Some('}'),
        '\\' => Some('|'),
        ';' => Some(':'),
        '\'' => Some('"'),
        ',' => Some('<'),
        '.' => Some('>'),
        '/' => Some('?'),
        _ => None,
    }
}

const fn unshifted_ascii_key(character: char) -> Option<char> {
    match character {
        '~' => Some('`'),
        '!' => Some('1'),
        '@' => Some('2'),
        '#' => Some('3'),
        '$' => Some('4'),
        '%' => Some('5'),
        '^' => Some('6'),
        '&' => Some('7'),
        '*' => Some('8'),
        '(' => Some('9'),
        ')' => Some('0'),
        '_' => Some('-'),
        '+' => Some('='),
        '{' => Some('['),
        '}' => Some(']'),
        '|' => Some('\\'),
        ':' => Some(';'),
        '"' => Some('\''),
        '<' => Some(','),
        '>' => Some('.'),
        '?' => Some('/'),
        _ => None,
    }
}

fn is_ascii_control_chord(character: char) -> bool {
    character.is_ascii()
        && matches!(
            character as u8,
            b' ' | b'2'..=b'8' | b'/' | b'?' | b'@'..=b'_' | b'`' | b'a'..=b'z'
        )
}

fn is_paste_shortcut(keystroke: &gpui::Keystroke) -> bool {
    keystroke.modifiers.control
        && keystroke.modifiers.shift
        && keystroke.key.eq_ignore_ascii_case("v")
}

fn is_toggle_sidebar_shortcut(keystroke: &gpui::Keystroke) -> bool {
    keystroke.modifiers.control
        && keystroke.modifiers.shift
        && !keystroke.modifiers.alt
        && keystroke.key.eq_ignore_ascii_case("b")
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
    terminal_cell_at_with_offset(x, y, 0.0, 0.0, cell_width, line_height, size)
}

fn terminal_cell_at_with_offset(
    x: f32,
    y: f32,
    x_offset: f32,
    y_offset: f32,
    cell_width: f32,
    line_height: f32,
    size: surface::GridSize,
) -> Option<(usize, usize)> {
    let content_x = x - x_offset;
    let content_y = y - y_offset;
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
    let content_width = width.max(1.0);
    let content_height = height.max(1.0);
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
    let line_height = terminal_line_height(
        f32::from(font_size),
        f32::from(text_system.ascent(font_id, font_size)),
        f32::from(text_system.descent(font_id, font_size)),
    );
    TerminalMetrics {
        cell_width,
        line_height,
    }
}

fn normalize_cell_width(measured: f32) -> f32 {
    measured.max(1.0)
}

fn terminal_line_height(font_size: f32, ascent: f32, descent: f32) -> f32 {
    (ascent + descent + CELL_LINE_GAP)
        .max(font_size * 1.3)
        .ceil()
        .max(1.0)
}

#[must_use]
#[allow(
    clippy::cast_possible_truncation,
    reason = "completed wheel lines are represented by a bounded batch count"
)]
pub fn terminal_wheel_steps(remainder: &mut f32, vertical_delta: f32, line_height: f32) -> i32 {
    if !vertical_delta.is_finite() || !line_height.is_finite() || line_height <= 0.0 {
        return 0;
    }
    let total = *remainder + vertical_delta / line_height;
    let completed = total.trunc();
    *remainder = total.fract();
    completed as i32
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

        cx.bind_keys([KeyBinding::new("ctrl-shift-b", ToggleSidebar, None)]);

        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some(WINDOW_TITLE.into()),
                    appears_transparent: true,
                    ..Default::default()
                }),
                window_background: WindowBackgroundAppearance::Opaque,
                window_decorations: Some(WindowDecorations::Client),
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
        APP_NAVIGATION_WIDTH, APP_TITLEBAR_HEIGHT, INPUT_BUFFER_FULL_DIAGNOSTIC,
        INPUT_BUFFERED_DIAGNOSTIC, InputRefusal, PendingUiInput, QueuedUiInput, TerminalKeyboard,
        TerminalPointer, TerminalResize, UI_INPUT_BYTE_CAPACITY, UI_INPUT_CAPACITY, WheelBatch,
        active_session_selection, application_navigation_width, clear_terminal_input_state,
        clears_after_input_delivery, clears_when_input_queue_is_empty, coalesce_last_resize,
        coalesce_last_wheel, input_queue_has_capacity, is_toggle_sidebar_shortcut, named_key,
        normalize_cell_width, queued_input_matches_presentation, terminal_cell_at_with_offset,
        terminal_key_input, terminal_line_height, terminal_wheel_steps, transitioned_presentation,
        tree_sessions, workspace_window_title,
    };
    use std::sync::Arc;
    use surface::{GridSize, SurfaceFrame, SurfaceStore};
    use workspace::{
        HostConnectionState, HostItem, KeyEvent, KeyInput, Modifiers, MouseAction, MouseButton,
        MouseInput, NamedKey, SessionItem, SessionSelection, WorkspaceContent,
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
    fn terminal_and_attaching_states_expose_the_active_selection() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let terminal = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        let attaching = WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "other".to_owned(),
        };

        assert_eq!(
            active_session_selection(&terminal),
            Some(SessionSelection::new("wsl", "Ubuntu", "work"))
        );
        assert_eq!(
            active_session_selection(&attaching),
            Some(SessionSelection::new("wsl", "Ubuntu", "other"))
        );
        assert_eq!(active_session_selection(&WorkspaceContent::Shell), None);
    }

    #[test]
    fn active_terminal_context_moves_into_the_native_window_title() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let terminal = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "demo".to_owned(),
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        let attaching = WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "demo".to_owned(),
        };

        assert_eq!(
            workspace_window_title(&terminal),
            "demo — Ubuntu — Ghosthub"
        );
        assert_eq!(
            workspace_window_title(&attaching),
            "demo — Ubuntu — Ghosthub"
        );
        assert_eq!(workspace_window_title(&WorkspaceContent::Shell), "Ghosthub");
    }

    #[test]
    fn active_session_stays_in_the_tree_while_its_host_refreshes_or_fails() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let terminal = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "demo".to_owned(),
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        for state in [
            HostConnectionState::Connecting,
            HostConnectionState::Unavailable,
        ] {
            let host = HostItem::wsl(
                "Ubuntu",
                None,
                state,
                vec![SessionItem::new("other", 0)],
                None,
            );

            let rows = tree_sessions(&host, &terminal, &[]);
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].selection.session(), "demo");
            assert!(rows[0].active);
        }
    }

    #[test]
    fn refreshed_endpoint_does_not_alias_an_active_session_with_the_same_name() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let terminal = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "demo".to_owned(),
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        let host = HostItem::wsl(
            "Debian",
            None,
            HostConnectionState::Ready,
            vec![SessionItem::new("demo", 0)],
            None,
        );

        let rows = tree_sessions(&host, &terminal, &[]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].selection.endpoint(), "Debian");
        assert!(!rows[0].active);
        assert!(!rows[0].show_endpoint);
        assert_eq!(rows[1].selection.endpoint(), "Ubuntu");
        assert!(rows[1].active);
        assert!(rows[1].show_endpoint);
    }

    #[test]
    fn retained_session_from_a_previous_default_distro_is_endpoint_qualified() {
        let host = HostItem::wsl(
            "Debian",
            None,
            HostConnectionState::Ready,
            vec![SessionItem::new("demo", 0)],
            None,
        );
        let retained = vec![SessionSelection::new("wsl", "Ubuntu", "demo")];

        let rows = tree_sessions(&host, &WorkspaceContent::Shell, &retained);

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].selection.endpoint(), "Debian");
        assert!(!rows[0].show_endpoint);
        assert_eq!(rows[1].selection.endpoint(), "Ubuntu");
        assert!(rows[1].show_endpoint);
    }

    #[test]
    fn retained_sessions_stay_in_the_tree_while_the_host_is_unavailable() {
        let host = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Unavailable,
            Vec::new(),
            None,
        );
        let retained = vec![
            SessionSelection::new("wsl", "Ubuntu", "one"),
            SessionSelection::new("wsl", "Ubuntu", "two"),
        ];

        let rows = tree_sessions(&host, &WorkspaceContent::Shell, &retained);

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].selection.session(), "one");
        assert_eq!(rows[1].selection.session(), "two");
        assert!(rows.iter().all(|row| !row.active));
    }

    #[test]
    fn terminal_hit_testing_accounts_for_titlebar_and_collapsible_navigation() {
        let size = GridSize::new(80, 24).expect("valid grid");

        assert!(
            (application_navigation_width(true, true) - APP_NAVIGATION_WIDTH).abs() < f32::EPSILON
        );
        assert!(application_navigation_width(false, true).abs() < f32::EPSILON);
        assert!(application_navigation_width(true, false).abs() < f32::EPSILON);
        assert_eq!(
            terminal_cell_at_with_offset(
                APP_NAVIGATION_WIDTH + 12.0,
                APP_TITLEBAR_HEIGHT + 8.0,
                APP_NAVIGATION_WIDTH,
                APP_TITLEBAR_HEIGHT,
                8.0,
                16.0,
                size
            ),
            Some((1, 0))
        );
        assert_eq!(
            terminal_cell_at_with_offset(
                APP_NAVIGATION_WIDTH - 1.0,
                APP_TITLEBAR_HEIGHT + 8.0,
                APP_NAVIGATION_WIDTH,
                APP_TITLEBAR_HEIGHT,
                8.0,
                16.0,
                size
            ),
            None
        );
        assert_eq!(
            terminal_cell_at_with_offset(
                APP_NAVIGATION_WIDTH + 12.0,
                APP_TITLEBAR_HEIGHT - 1.0,
                APP_NAVIGATION_WIDTH,
                APP_TITLEBAR_HEIGHT,
                8.0,
                16.0,
                size
            ),
            None
        );
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
    fn control_chords_without_key_char_reach_the_terminal_encoder() {
        for key in ["a", "e", "2", "[", "/"] {
            let keystroke = gpui::Keystroke {
                modifiers: gpui::Modifiers::control(),
                key: key.to_owned(),
                key_char: None,
            };

            assert_eq!(
                terminal_key_input(&keystroke, KeyEvent::Press),
                Some(KeyInput::text_with_key(
                    key,
                    key,
                    Modifiers {
                        control: true,
                        ..Modifiers::default()
                    },
                ))
            );
        }
    }

    #[test]
    fn sidebar_shortcut_is_owned_by_the_application() {
        let keystroke = gpui::Keystroke {
            modifiers: gpui::Modifiers {
                control: true,
                shift: true,
                ..gpui::Modifiers::default()
            },
            key: "b".to_owned(),
            key_char: None,
        };

        assert!(is_toggle_sidebar_shortcut(&keystroke));
        assert_eq!(terminal_key_input(&keystroke, KeyEvent::Press), None);
        assert_eq!(terminal_key_input(&keystroke, KeyEvent::Repeat), None);
        assert_eq!(terminal_key_input(&keystroke, KeyEvent::Release), None);
    }

    #[test]
    fn shifted_control_fallback_preserves_kitty_key_parts() {
        let expected_modifiers = Modifiers {
            shift: true,
            control: true,
            ..Modifiers::default()
        };
        for (key, modifiers, produced, logical) in [
            (
                "a",
                gpui::Modifiers {
                    control: true,
                    shift: true,
                    ..gpui::Modifiers::default()
                },
                "A",
                "a",
            ),
            // GPUI folds Shift into Windows punctuation keys and clears the
            // modifier before delivering the keystroke.
            ("?", gpui::Modifiers::control(), "?", "/"),
            ("_", gpui::Modifiers::control(), "_", "-"),
            // Preserve the same result if a backend retains the modifier and
            // reports the unshifted logical key instead.
            (
                "/",
                gpui::Modifiers {
                    control: true,
                    shift: true,
                    ..gpui::Modifiers::default()
                },
                "?",
                "/",
            ),
        ] {
            let keystroke = gpui::Keystroke {
                modifiers,
                key: key.to_owned(),
                key_char: None,
            };

            assert_eq!(
                terminal_key_input(&keystroke, KeyEvent::Press),
                Some(KeyInput::text_with_key(
                    produced,
                    logical,
                    expected_modifiers
                ))
            );
        }
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
    fn completed_wheel_steps_leave_only_a_fractional_remainder() {
        let mut remainder = 0.5;

        assert_eq!(terminal_wheel_steps(&mut remainder, 130.0, 1.0), 130);
        assert!((remainder - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn wheel_batches_preserve_direction_target_and_modifiers() {
        let first = WheelBatch {
            input: MouseInput {
                action: MouseAction::WheelUp,
                column: 4,
                row: 7,
                modifiers: Modifiers::default(),
            },
            remaining: 54,
        };
        let mut pending = VecDeque::from([QueuedUiInput {
            presentation_id: 8,
            input: PendingUiInput::Wheel(first),
            bytes: 0,
            accepted_after_refusal: None,
        }]);
        let same_target = WheelBatch {
            remaining: 10,
            ..first
        };
        assert!(coalesce_last_wheel(&mut pending, 8, same_target, Some(2)));
        assert!(matches!(
            pending[0].input,
            PendingUiInput::Wheel(WheelBatch { remaining: 64, .. })
        ));

        let later_opposite_target = WheelBatch {
            input: MouseInput {
                action: MouseAction::WheelDown,
                column: 12,
                row: 9,
                modifiers: Modifiers {
                    alt: true,
                    ..Modifiers::default()
                },
            },
            remaining: 3,
        };
        assert!(!coalesce_last_wheel(
            &mut pending,
            8,
            later_opposite_target,
            None
        ));
        pending.push_back(QueuedUiInput {
            presentation_id: 8,
            input: PendingUiInput::Wheel(later_opposite_target),
            bytes: 0,
            accepted_after_refusal: None,
        });
        assert_eq!(pending.len(), 2);
        assert!(matches!(
            pending[0].input,
            PendingUiInput::Wheel(WheelBatch {
                input: MouseInput {
                    action: MouseAction::WheelUp,
                    column: 4,
                    row: 7,
                    ..
                },
                remaining: 64,
            })
        ));
        assert!(matches!(
            pending[1].input,
            PendingUiInput::Wheel(WheelBatch {
                input: MouseInput {
                    action: MouseAction::WheelDown,
                    column: 12,
                    row: 9,
                    modifiers: Modifiers { alt: true, .. },
                },
                remaining: 3,
            })
        ));
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
    fn resize_stays_behind_older_input_and_coalesces_in_place() {
        let mut pending = VecDeque::from([QueuedUiInput {
            presentation_id: 7,
            input: PendingUiInput::Key(KeyInput::named(NamedKey::Enter, Modifiers::default())),
            bytes: 0,
            accepted_after_refusal: None,
        }]);
        let first = TerminalResize {
            columns: 80,
            rows: 24,
            pixel_width: 800,
            pixel_height: 480,
        };
        let latest = TerminalResize {
            columns: 120,
            rows: 40,
            pixel_width: 1_200,
            pixel_height: 800,
        };

        assert!(!coalesce_last_resize(&mut pending, 7, first));
        pending.push_back(QueuedUiInput {
            presentation_id: 7,
            input: PendingUiInput::Resize(first),
            bytes: 0,
            accepted_after_refusal: None,
        });
        assert!(coalesce_last_resize(&mut pending, 7, latest));
        assert!(matches!(pending[0].input, PendingUiInput::Key(_)));
        assert!(matches!(pending[1].input, PendingUiInput::Resize(value) if value == latest));
        assert!(input_queue_has_capacity(
            &PendingUiInput::Resize(latest),
            UI_INPUT_CAPACITY,
            UI_INPUT_BYTE_CAPACITY,
            0,
            0,
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
        let release_modifiers = Modifiers {
            alt: true,
            ..Modifiers::default()
        };
        assert_eq!(
            keyboard.input_for("a", KeyEvent::Release, release_modifiers),
            Some(
                KeyInput::text_with_key("!", "1", release_modifiers).with_event(KeyEvent::Release)
            )
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
    fn terminal_line_height_keeps_readable_leading() {
        assert!((terminal_line_height(14.0, 10.0, 3.0) - 19.0).abs() < f32::EPSILON);
        assert!((terminal_line_height(14.0, 12.0, 4.0) - 20.0).abs() < f32::EPSILON);
    }

    #[test]
    fn presentation_transition_clears_all_terminal_input_state() {
        let mut observed = Some(7);
        let mut paste_confirmation = true;
        let mut pending_input = VecDeque::from([QueuedUiInput {
            presentation_id: 7,
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
            presentation_id: 7,
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

    #[test]
    fn queued_terminal_input_is_bound_to_its_originating_presentation() {
        let input = QueuedUiInput {
            presentation_id: 7,
            input: PendingUiInput::Key(KeyInput::named(NamedKey::Enter, Modifiers::default())),
            bytes: 0,
            accepted_after_refusal: None,
        };

        assert!(queued_input_matches_presentation(&input, Some(7)));
        assert!(!queued_input_matches_presentation(&input, Some(8)));
        assert!(!queued_input_matches_presentation(&input, None));
    }
}
