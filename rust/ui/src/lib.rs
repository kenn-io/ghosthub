//! GPUI presentation for the Rust Ghosthub application.

use std::sync::Arc;
use std::time::Duration;

use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, Focusable, FontWeight,
    IntoElement, KeyDownEvent, MouseButton as GpuiMouseButton, MouseDownEvent, MouseMoveEvent,
    MouseUpEvent, Render, ScrollWheelEvent, TitlebarOptions, Window, WindowBounds, WindowOptions,
    div, prelude::*, px, rgb, size,
};
use model::PortStatus;
use surface::{CellStyle, Damage, GridSize, Rgb, SurfaceFrame, SurfaceStore};
use workspace::{
    KeyInput, Modifiers as InputModifiers, MouseAction, MouseButton, MouseInput, NamedKey,
    Workspace, WorkspaceContent, WorkspaceEvent,
};

pub const WINDOW_TITLE: &str = "Ghosthub";
const TERMINAL_HEADER_HEIGHT: f32 = 42.0;
const TERMINAL_PADDING: f32 = 12.0;
const CELL_WIDTH_RATIO: f32 = 0.6;
const CELL_LINE_GAP: f32 = 2.0;

#[must_use]
pub fn headline_text(status: &PortStatus) -> String {
    status.headline()
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
            for damage in frame.damage() {
                match *damage {
                    Damage::Full => unreachable!("full damage was handled above"),
                    Damage::Scroll { top, bottom, delta } => {
                        apply_cached_scroll(&mut self.rows, top, bottom, delta);
                    }
                    Damage::Rows { start, end } => {
                        repaint_rows(&mut self.rows, frame, start, end);
                    }
                }
            }
            if self.cursor != frame.cursor() {
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

fn apply_cached_scroll(rows: &mut [Arc<Vec<PaintRun>>], top: usize, bottom: usize, delta: i32) {
    if top >= bottom || bottom > rows.len() || delta == 0 {
        return;
    }
    let affected = &mut rows[top..bottom];
    let distance = usize::try_from(delta.unsigned_abs())
        .unwrap_or(usize::MAX)
        .min(affected.len());
    if delta < 0 {
        affected.rotate_left(distance);
    } else {
        affected.rotate_right(distance);
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
    observed_revision: u64,
    observed_surface_generation: u64,
    observed_surface_identity: Option<usize>,
    paint_cache: SurfacePaintCache,
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
                        if view.handle_events(cx) || view.poll_changed() {
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

        let mut view = Self {
            status,
            workspace,
            focus: cx.focus_handle(),
            diagnostic: None,
            paste_confirmation: false,
            observed_revision: u64::MAX,
            observed_surface_generation: u64::MAX,
            observed_surface_identity: None,
            paint_cache: SurfacePaintCache::default(),
        };
        view.resize_for_window(window);
        view
    }

    #[must_use]
    pub fn headline(&self) -> String {
        headline_text(&self.status)
    }

    fn attach(&mut self, session: &str, cx: &mut Context<Self>) {
        if let Err(error) = self.workspace.attach(session) {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
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

    fn detach(&mut self, cx: &mut Context<Self>) {
        self.workspace.detach();
        self.paste_confirmation = false;
        self.paint_cache.clear();
        cx.notify();
    }

    fn handle_events(&mut self, cx: &mut Context<Self>) -> bool {
        let mut handled = false;
        for event in self.workspace.drain_events() {
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
                    if let Err(error) = self.workspace.complete_clipboard_read(&request, &contents)
                    {
                        self.diagnostic = Some(error.to_string());
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

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        if keystroke.modifiers.control
            && keystroke.modifiers.shift
            && keystroke.key.eq_ignore_ascii_case("v")
        {
            if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                self.send_key(KeyInput::paste(text));
            }
            cx.stop_propagation();
            return;
        }

        let input = terminal_key_input(keystroke);
        if let Some(input) = input {
            self.send_key(input);
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
            self.send_mouse_at(
                MouseAction::Press(button),
                event.position.x.into(),
                event.position.y.into(),
                event.modifiers,
            );
            cx.stop_propagation();
        }
    }

    fn on_mouse_up(&mut self, event: &MouseUpEvent, _window: &mut Window, cx: &mut Context<Self>) {
        if let Some(button) = terminal_mouse_button(event.button) {
            self.send_mouse_at(
                MouseAction::Release(button),
                event.position.x.into(),
                event.position.y.into(),
                event.modifiers,
            );
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
        self.send_mouse_at(
            MouseAction::Move(button),
            event.position.x.into(),
            event.position.y.into(),
            event.modifiers,
        );
        cx.stop_propagation();
    }

    fn on_scroll_wheel(
        &mut self,
        event: &ScrollWheelEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let line_height =
            f32::from(self.workspace.snapshot().appearance().font_size()) + CELL_LINE_GAP;
        let delta = event.delta.pixel_delta(px(line_height));
        let vertical = f32::from(delta.y);
        let Some(action) = terminal_wheel_action(vertical) else {
            return;
        };
        self.send_mouse_at(
            action,
            event.position.x.into(),
            event.position.y.into(),
            event.modifiers,
        );
        cx.stop_propagation();
    }

    fn send_mouse_at(&mut self, action: MouseAction, x: f32, y: f32, modifiers: gpui::Modifiers) {
        let snapshot = self.workspace.snapshot();
        let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
            return;
        };
        let size = surface.load().size();
        let font_size = f32::from(snapshot.appearance().font_size());
        let Some((column, row)) = terminal_cell_at(x, y, font_size, size) else {
            return;
        };
        let input = MouseInput {
            action,
            column,
            row,
            modifiers: input_modifiers(modifiers),
        };
        if let Err(error) = self.workspace.send_mouse(input) {
            self.diagnostic = Some(error.to_string());
        }
    }

    fn send_key(&mut self, input: KeyInput) {
        if let Err(error) = self.workspace.send_key(input) {
            self.diagnostic = Some(error.to_string());
        }
    }

    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    fn resize_for_window(&mut self, window: &Window) {
        let bounds = window.bounds();
        let width = f32::from(bounds.size.width);
        let height = f32::from(bounds.size.height);
        let font_size = f32::from(self.workspace.snapshot().appearance().font_size());
        let columns = ((width - TERMINAL_PADDING * 2.0) / (font_size * CELL_WIDTH_RATIO))
            .floor()
            .max(1.0) as usize;
        let rows = ((height - TERMINAL_HEADER_HEIGHT - TERMINAL_PADDING * 2.0)
            / (font_size + CELL_LINE_GAP))
            .floor()
            .max(1.0) as usize;
        let pixel_width = width.max(1.0).min(f32::from(u16::MAX)) as u16;
        let pixel_height = height.max(1.0).min(f32::from(u16::MAX)) as u16;
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
        cx.notify();
    }

    fn cancel_paste(&mut self, cx: &mut Context<Self>) {
        self.workspace.cancel_paste();
        self.paste_confirmation = false;
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
            .line_height(px(f32::from(appearance.font_size()) + 2.0))
            .on_key_down(cx.listener(Self::on_key_down))
            .on_mouse_down(GpuiMouseButton::Left, cx.listener(Self::on_mouse_down))
            .on_mouse_down(GpuiMouseButton::Middle, cx.listener(Self::on_mouse_down))
            .on_mouse_down(GpuiMouseButton::Right, cx.listener(Self::on_mouse_down))
            .on_mouse_up(GpuiMouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_up(GpuiMouseButton::Middle, cx.listener(Self::on_mouse_up))
            .on_mouse_up(GpuiMouseButton::Right, cx.listener(Self::on_mouse_up))
            .on_mouse_move(cx.listener(Self::on_mouse_move))
            .on_scroll_wheel(cx.listener(Self::on_scroll_wheel))
            .children(rows.into_iter().map(|row| {
                div()
                    .flex()
                    .flex_none()
                    .whitespace_nowrap()
                    .children(row.iter().cloned().map(paint_run_element))
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
                Self::ready_element(endpoint, sessions, cx)
            }
            WorkspaceContent::Terminal {
                endpoint,
                session,
                surface,
            } => self
                .terminal_element(endpoint, session, surface, snapshot, cx)
                .into_any_element(),
        }
    }

    fn ready_element(
        endpoint: &str,
        sessions: &[workspace::SessionItem],
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
            list = list.child(
                div()
                    .p_4()
                    .rounded_md()
                    .bg(rgb(0x1a_1d24))
                    .child("No tmux server is running in this distro. Start a tmux session in WSL, then choose Refresh."),
            );
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
                    .on_click(cx.listener(move |this, _, _, cx| this.attach(&name, cx))),
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

impl Focusable for RootView {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for RootView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
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

        if let Some(diagnostic) = &self.diagnostic {
            root = root.child(
                div()
                    .absolute()
                    .left_4()
                    .bottom_4()
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

fn paint_run_element(run: PaintRun) -> gpui::AnyElement {
    let mut element = div()
        .flex_none()
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
        value if value.len() > 1 && value.starts_with('f') => {
            value[1..].parse().ok().map(NamedKey::F)
        }
        _ => None,
    }
}

fn terminal_key_input(keystroke: &gpui::Keystroke) -> Option<KeyInput> {
    // GPUI's Windows backend removes the synthetic Ctrl+Alt pair generated by
    // right-Alt on AltGr layouts, while preserving genuine Ctrl+Alt chords.
    let modifiers = input_modifiers(keystroke.modifiers);
    let key_char = keystroke
        .key_char
        .as_deref()
        .filter(|text| !text.is_empty());
    named_key(&keystroke.key)
        .map(|key| KeyInput::named(key, modifiers))
        .or_else(|| {
            let text = key_char.unwrap_or(&keystroke.key);
            (!text.is_empty()).then(|| KeyInput::text(text, modifiers))
        })
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

#[must_use]
pub fn terminal_cell_at(
    x: f32,
    y: f32,
    font_size: f32,
    size: surface::GridSize,
) -> Option<(usize, usize)> {
    let content_x = x - TERMINAL_PADDING;
    let content_y = y - TERMINAL_HEADER_HEIGHT - TERMINAL_PADDING;
    if content_x < 0.0 || content_y < 0.0 {
        return None;
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let column = (content_x / (font_size * CELL_WIDTH_RATIO)).floor() as usize;
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let row = (content_y / (font_size + CELL_LINE_GAP)).floor() as usize;
    (column < size.columns() && row < size.rows()).then_some((column, row))
}

#[must_use]
pub fn terminal_wheel_action(vertical_delta: f32) -> Option<MouseAction> {
    if vertical_delta > 0.0 {
        Some(MouseAction::WheelUp)
    } else if vertical_delta < 0.0 {
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
