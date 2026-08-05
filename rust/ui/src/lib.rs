//! GPUI presentation for the Rust Ghosthub application.

use std::sync::Arc;
use std::time::Duration;

use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, Focusable, IntoElement,
    KeyDownEvent, Render, TitlebarOptions, Window, WindowBounds, WindowOptions, div, prelude::*,
    px, rgb, size,
};
use model::PortStatus;
use surface::{SurfaceFrame, SurfaceStore};
use workspace::{
    KeyInput, Modifiers as InputModifiers, NamedKey, Workspace, WorkspaceContent, WorkspaceEvent,
};

pub const WINDOW_TITLE: &str = "Ghosthub";

#[must_use]
pub fn headline_text(status: &PortStatus) -> String {
    status.headline()
}

#[must_use]
pub fn surface_text_rows(frame: &SurfaceFrame) -> Vec<String> {
    let columns = frame.size().columns();
    frame
        .cells()
        .chunks(columns)
        .map(|row| {
            row.iter().fold(String::new(), |mut text, cell| {
                if cell.text().is_empty() {
                    text.push(' ');
                } else {
                    text.push_str(cell.text());
                }
                text
            })
        })
        .collect()
}

pub struct RootView {
    status: PortStatus,
    workspace: Workspace,
    focus: FocusHandle,
    diagnostic: Option<String>,
    paste_confirmation: bool,
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
                if view.update(cx, |_, cx| cx.notify()).is_err() {
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

    fn detach(&mut self, cx: &mut Context<Self>) {
        self.workspace.detach();
        self.paste_confirmation = false;
        cx.notify();
    }

    fn handle_events(&mut self, cx: &mut Context<Self>) {
        for event in self.workspace.drain_events() {
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

        let modifiers = InputModifiers {
            shift: keystroke.modifiers.shift,
            control: keystroke.modifiers.control,
            alt: keystroke.modifiers.alt,
        };
        let input = named_key(&keystroke.key)
            .map(|key| KeyInput::named(key, modifiers))
            .or_else(|| {
                let text = keystroke
                    .key_char
                    .as_deref()
                    .filter(|text| !text.is_empty())
                    .unwrap_or(&keystroke.key);
                (!text.is_empty()).then(|| KeyInput::text(text, modifiers))
            });
        if let Some(input) = input {
            self.send_key(input);
            cx.stop_propagation();
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
        let columns = ((width - 24.0) / (font_size * 0.6)).floor().max(1.0) as usize;
        let rows = ((height - 66.0) / (font_size + 2.0)).floor().max(1.0) as usize;
        if let Err(error) = self.workspace.resize(columns, rows) {
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
        &self,
        endpoint: &str,
        session: &str,
        surface: &Arc<SurfaceStore>,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let frame = surface.load();
        let rows = surface_text_rows(&frame);
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
            .on_click(cx.listener(|this, _, window, _| window.focus(&this.focus)))
            .on_key_down(cx.listener(Self::on_key_down))
            .children(rows.into_iter().map(|row| {
                div()
                    .flex_none()
                    .whitespace_nowrap()
                    .child(row)
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
        &self,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        match snapshot.content() {
            WorkspaceContent::Loading => centered("Starting WSL and discovering tmux sessions…"),
            WorkspaceContent::Error { message } => centered(message.clone()),
            WorkspaceContent::Attaching { endpoint, session } => {
                centered(format!("Attaching to {endpoint} · {session}…"))
            }
            WorkspaceContent::Ready { endpoint, sessions } => {
                let mut list = div().flex().flex_col().gap_2().p_6().max_w(px(720.0));
                list = list
                    .child(
                        div()
                            .text_xl()
                            .text_color(rgb(0xee_f0_f4))
                            .child(format!("Tmux sessions in {endpoint}")),
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
                            .child("No tmux server is running in this distro. Start a tmux session in WSL, then restart Ghosthub."),
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
            WorkspaceContent::Terminal {
                endpoint,
                session,
                surface,
            } => self
                .terminal_element(endpoint, session, surface, snapshot, cx)
                .into_any_element(),
        }
    }
}

impl Focusable for RootView {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for RootView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.handle_events(cx);
        let snapshot = self.workspace.snapshot();
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
