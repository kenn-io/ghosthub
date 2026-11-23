use std::sync::Arc;

use gpui::{
    Context, IntoElement, KeyDownEvent, MouseMoveEvent, MouseUpEvent, Window, div, prelude::*, px,
    rgb, rgba,
};

use super::{APP_TITLEBAR_HEIGHT, CursorShape, CursorStyle, GpuiMouseButton, RootView, sidebar};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum PaneAction {
    SplitRight,
    SplitDown,
    Zoom,
    Close,
    Next,
    Previous,
    Left,
    Right,
    Up,
    Down,
}

impl PaneAction {
    pub(super) const fn title(self) -> &'static str {
        match self {
            Self::SplitRight => "Split Right",
            Self::SplitDown => "Split Down",
            Self::Zoom => "Zoom Pane",
            Self::Close => "Close Pane…",
            Self::Next => "Next Pane",
            Self::Previous => "Previous Pane",
            Self::Left => "Focus Pane Left",
            Self::Right => "Focus Pane Right",
            Self::Up => "Focus Pane Above",
            Self::Down => "Focus Pane Below",
        }
    }
}

pub(super) fn shortcut(key: &gpui::Keystroke) -> Option<PaneAction> {
    if !key.modifiers.control || key.modifiers.platform {
        return None;
    }
    match (key.modifiers.alt, key.modifiers.shift, key.key.as_str()) {
        (false, true, "d") => Some(PaneAction::SplitRight),
        (false, true, "e") => Some(PaneAction::SplitDown),
        (false, true, "enter") => Some(PaneAction::Zoom),
        (false, false, "]") => Some(PaneAction::Next),
        (false, false, "[") => Some(PaneAction::Previous),
        (true, false, "left") => Some(PaneAction::Left),
        (true, false, "right") => Some(PaneAction::Right),
        (true, false, "up") => Some(PaneAction::Up),
        (true, false, "down") => Some(PaneAction::Down),
        _ => None,
    }
}

fn focused_rex_presentation(snapshot: &workspace::WorkspaceSnapshot) -> Option<u64> {
    snapshot.rex_window()?.panes.iter().find_map(|pane| {
        (pane.focused && pane.rect.width > 0.0 && pane.rect.height > 0.0)
            .then_some(pane.presentation_id)
    })
}

impl RootView {
    pub(super) fn run_rex_action(
        &mut self,
        presentation: u64,
        action: PaneAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let result = match action {
            PaneAction::SplitRight => self.workspace.split_rex_pane(presentation, false),
            PaneAction::SplitDown => self.workspace.split_rex_pane(presentation, true),
            PaneAction::Zoom => self.workspace.zoom_rex_pane(presentation),
            PaneAction::Close => {
                if let Some(pane) = self
                    .workspace
                    .snapshot()
                    .rex_window()
                    .and_then(|w| w.panes.iter().find(|p| p.presentation_id == presentation))
                {
                    self.rex_close = Some((presentation, pane.title.clone(), false));
                    window.focus(&self.kill_focus);
                }
                Ok(())
            }
            PaneAction::Next => self.workspace.move_rex_focus(1, 0, 0),
            PaneAction::Previous => self.workspace.move_rex_focus(-1, 0, 0),
            PaneAction::Left => self.workspace.move_rex_focus(0, -1, 0),
            PaneAction::Right => self.workspace.move_rex_focus(0, 1, 0),
            PaneAction::Up => self.workspace.move_rex_focus(0, 0, -1),
            PaneAction::Down => self.workspace.move_rex_focus(0, 0, 1),
        };
        if let Err(e) = result {
            self.diagnostic = Some(e.to_string());
        }
        if action != PaneAction::Close {
            window.focus(&self.focus);
        }
        cx.notify();
    }

    #[allow(
        clippy::too_many_lines,
        clippy::cast_possible_truncation,
        reason = "Keep the pane and divider composition in one native view."
    )]
    pub(super) fn rex_window_element(
        &mut self,
        snapshot: &workspace::WorkspaceSnapshot,
        rex: &workspace::RexWindowSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut body = div()
            .relative()
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this, event, window, cx| {
                if let Some(id) = focused_rex_presentation(&this.workspace.snapshot()) {
                    this.on_key_down(id, event, window, cx);
                }
            }))
            .on_key_up(cx.listener(|this, event, window, cx| {
                if let Some(id) = focused_rex_presentation(&this.workspace.snapshot()) {
                    this.on_key_up(id, event, window, cx);
                }
            }))
            .size_full()
            .overflow_hidden()
            .bg(rgb(snapshot.appearance().background()));
        for pane in &rex.panes {
            if pane.rect.width <= 0.0 || pane.rect.height <= 0.0 {
                continue;
            }
            let presentation = pane.presentation_id;
            let frame = pane.surface.load();
            if pane.focused {
                self.observed_surface_identity =
                    Some(Arc::as_ptr(&pane.surface).cast::<()>() as usize);
                self.observed_surface_generation = frame.generation();
            }
            let mut frame = (*frame).clone();
            if !pane.focused {
                frame.set_cursor(None);
            }
            let cache = self.rex_paint.entry(presentation).or_default();
            let cursor_override =
                (!snapshot.appearance().allow_shell_integration_cursor()).then(|| {
                    match snapshot.appearance().cursor_style() {
                        CursorStyle::Block => CursorShape::Block,
                        CursorStyle::Bar => CursorShape::Bar,
                        CursorStyle::Underline => CursorShape::Underline,
                    }
                });
            let rows = cache.update(&frame, cursor_override).to_vec();
            let terminal = self
                .terminal_surface_element(
                    presentation,
                    snapshot.appearance(),
                    &frame,
                    rows,
                    false,
                    cx,
                )
                .into_any_element();
            let mut header = div()
                .h(px(26.0))
                .w_full()
                .flex_none()
                .flex()
                .items_center()
                .justify_between()
                .px_2()
                .bg(rgb(if pane.focused { 0x22_2935 } else { 0x16_1b23 }))
                .text_size(px(11.0))
                .text_color(rgb(if pane.focused { 0xd6_deeb } else { 0x84_8c9a }))
                .child(div().min_w_0().truncate().child(if pane.title.is_empty() {
                    "Terminal".to_owned()
                } else {
                    pane.title.clone()
                }));
            let mut buttons = div().flex().items_center().gap_1();
            for (action, label, tip) in [
                (PaneAction::SplitRight, "◫", "Split Right (Ctrl+Shift+D)"),
                (PaneAction::SplitDown, "⬒", "Split Down (Ctrl+Shift+E)"),
                (PaneAction::Zoom, "⛶", "Zoom Pane (Ctrl+Shift+Enter)"),
                (PaneAction::Close, "×", "Close Pane…"),
            ] {
                buttons = buttons.child(
                    div()
                        .id((gpui::ElementId::from(("rex-control", presentation)), label))
                        .size(px(21.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_sm()
                        .cursor_pointer()
                        .hover(|el| el.bg(rgb(0x34_3e4e)))
                        .child(label)
                        .tooltip(move |_, cx| sidebar::tooltip(tip.into(), cx))
                        .on_mouse_down(GpuiMouseButton::Left, |_, _, cx| cx.stop_propagation())
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.run_rex_action(presentation, action, window, cx);
                            cx.stop_propagation();
                        })),
                );
            }
            let mut pane_body = div()
                .relative()
                .flex()
                .flex_col()
                .flex_1()
                .min_h_0()
                .overflow_hidden()
                .child(terminal);
            if pane.connecting {
                pane_body = pane_body.child(
                    div()
                        .absolute()
                        .inset_0()
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_sm()
                        .child("Connecting…"),
                );
            } else if let Some(message) = &pane.error {
                pane_body = pane_body.child(
                    div()
                        .absolute()
                        .inset_0()
                        .occlude()
                        .flex()
                        .flex_col()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .bg(rgba(0x0c10_16dd))
                        .on_mouse_down(GpuiMouseButton::Left, |_, _, cx| cx.stop_propagation())
                        .child(div().text_sm().child(message.clone()))
                        .child(
                            div()
                                .id(("rex-pane-reconnect", presentation))
                                .px_3()
                                .py_1()
                                .rounded_md()
                                .cursor_pointer()
                                .bg(rgb(0x29_3b55))
                                .text_sm()
                                .child("Reconnect")
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.diagnostic = this
                                        .workspace
                                        .reconnect_rex_pane(presentation)
                                        .err()
                                        .map(|e| e.to_string());
                                    window.focus(&this.focus);
                                    cx.notify();
                                })),
                        ),
                );
            }
            header = header.child(buttons);
            body = body.child(
                div()
                    .id(("rex-pane", presentation))
                    .absolute()
                    .left(px(pane.rect.x))
                    .top(px(pane.rect.y))
                    .w(px(pane.rect.width))
                    .h(px(pane.rect.height))
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .on_mouse_down(
                        GpuiMouseButton::Left,
                        cx.listener(move |this, _, window, cx| {
                            if let Err(e) = this.workspace.focus_rex_pane(presentation)
                                && !e.is_stale_input()
                            {
                                this.diagnostic = Some(e.to_string());
                            }
                            window.focus(&this.focus);
                            cx.notify();
                        }),
                    )
                    .child(header)
                    .child(pane_body),
            );
        }
        for divider in &rex.dividers {
            let drag = divider.clone();
            body = body.child(
                div()
                    .id((gpui::ElementId::from("rex-divider"), divider.id.clone()))
                    .absolute()
                    .left(px(divider.rect.x))
                    .top(px(divider.rect.y))
                    .w(px(divider.rect.width))
                    .h(px(divider.rect.height))
                    .bg(rgb(0x0c_1016))
                    .cursor(
                        if divider.direction == workspace::RexDirection::Horizontal {
                            gpui::CursorStyle::ResizeLeftRight
                        } else {
                            gpui::CursorStyle::ResizeUpDown
                        },
                    )
                    .hover(|el| el.bg(rgb(0x54_82b9)))
                    .on_mouse_down(
                        GpuiMouseButton::Left,
                        cx.listener(move |this, _, _, cx| {
                            this.rex_drag = Some((drag.clone(), drag.ratio));
                            cx.stop_propagation();
                            cx.notify();
                        }),
                    ),
            );
        }
        if let Some((divider, ratio)) = &self.rex_drag {
            let horizontal = divider.direction == workspace::RexDirection::Horizontal;
            let x = divider.parent.x
                + if horizontal {
                    (divider.parent.width - 5.0) * *ratio as f32
                } else {
                    0.0
                };
            let y = divider.parent.y
                + if horizontal {
                    0.0
                } else {
                    (divider.parent.height - 5.0) * *ratio as f32
                };
            body = body.child(
                div()
                    .absolute()
                    .left(px(x))
                    .top(px(y))
                    .w(px(if horizontal {
                        5.0
                    } else {
                        divider.parent.width
                    }))
                    .h(px(if horizontal {
                        divider.parent.height
                    } else {
                        5.0
                    }))
                    .bg(rgb(0x67_98d6)),
            );
        }
        body = body
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                this.update_rex_drag(event.position, cx);
            }))
            .on_mouse_up(
                GpuiMouseButton::Left,
                cx.listener(|this, event: &MouseUpEvent, _, cx| {
                    this.update_rex_drag(event.position, cx);
                    this.finish_rex_drag(cx);
                }),
            )
            .on_mouse_up_out(
                GpuiMouseButton::Left,
                cx.listener(|this, event: &MouseUpEvent, _, cx| {
                    this.update_rex_drag(event.position, cx);
                    this.finish_rex_drag(cx);
                }),
            );
        if let Some(message) = &rex.error {
            let selection = rex.selection.clone();
            body = body.child(
                div()
                    .absolute()
                    .inset_0()
                    .flex()
                    .flex_col()
                    .items_center()
                    .justify_center()
                    .gap_3()
                    .bg(rgba(0x0c10_16e8))
                    .child(message.clone())
                    .child(
                        div()
                            .id("rex-reconnect")
                            .px_3()
                            .py_1()
                            .rounded_md()
                            .bg(rgb(0x29_3b55))
                            .cursor_pointer()
                            .child("Reconnect")
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.diagnostic = this
                                    .workspace
                                    .switch_session(&selection)
                                    .err()
                                    .map(|e| e.to_string());
                                window.focus(&this.focus);
                                cx.notify();
                            })),
                    ),
            );
        }
        if let Some((presentation, name, confirm)) = &self.rex_close {
            let presentation = *presentation;
            let name = if name.is_empty() { "this pane" } else { name };
            body = body.child(
                div()
                    .absolute()
                    .inset_0()
                    .occlude()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(rgba(0x0000_00a8))
                    .on_mouse_down(GpuiMouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .id("rex-close-dialog")
                            .track_focus(&self.kill_focus)
                            .w(px(380.0))
                            .p_5()
                            .rounded_lg()
                            .bg(rgb(0x1b_202a))
                            .border_1()
                            .border_color(rgb(0x35_3f50))
                            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                                if !event.is_held {
                                    match event.keystroke.key.as_str() {
                                        "escape" => {
                                            this.rex_close = None;
                                            window.focus(&this.focus);
                                        }
                                        "tab" | "left" | "right" => {
                                            if let Some((_, _, confirm)) = &mut this.rex_close {
                                                *confirm = !*confirm;
                                            }
                                        }
                                        "enter" | "space" => {
                                            if let Some((presentation, _, true)) =
                                                this.rex_close.take()
                                            {
                                                this.diagnostic = this
                                                    .workspace
                                                    .close_rex_pane(presentation)
                                                    .err()
                                                    .map(|e| e.to_string());
                                            }
                                            window.focus(&this.focus);
                                        }
                                        _ => {}
                                    }
                                    cx.notify();
                                }
                                cx.stop_propagation();
                            }))
                            .child(div().text_lg().mb_3().child("Close Pane?"))
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(rgb(0xad_b6c6))
                                    .child(format!("This ends the program in {name}.")),
                            )
                            .child(
                                div()
                                    .flex()
                                    .justify_end()
                                    .gap_3()
                                    .mt_5()
                                    .child(
                                        div()
                                            .id("rex-close-cancel")
                                            .border_1()
                                            .border_color(rgb(if *confirm {
                                                0x2a_3240
                                            } else {
                                                0x78_a7e2
                                            }))
                                            .px_3()
                                            .py_1()
                                            .rounded_md()
                                            .bg(rgb(0x2a_3240))
                                            .cursor_pointer()
                                            .child("Cancel")
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.rex_close = None;
                                                window.focus(&this.focus);
                                                cx.notify();
                                            })),
                                    )
                                    .child(
                                        div()
                                            .id("rex-close-confirm")
                                            .border_1()
                                            .border_color(rgb(if *confirm {
                                                0xf0_a1ad
                                            } else {
                                                0x8f_3544
                                            }))
                                            .px_3()
                                            .py_1()
                                            .rounded_md()
                                            .bg(rgb(0x8f_3544))
                                            .cursor_pointer()
                                            .child("Close Pane")
                                            .on_click(cx.listener(move |this, _, window, cx| {
                                                this.diagnostic = this
                                                    .workspace
                                                    .close_rex_pane(presentation)
                                                    .err()
                                                    .map(|e| e.to_string());
                                                this.rex_close = None;
                                                window.focus(&this.focus);
                                                cx.notify();
                                            })),
                                    ),
                            ),
                    ),
            );
        }
        body.into_any_element()
    }

    pub(super) fn update_rex_drag(
        &mut self,
        position: gpui::Point<gpui::Pixels>,
        cx: &mut Context<Self>,
    ) {
        let offset = self.navigation_width(&self.workspace.snapshot());
        if let Some((divider, ratio)) = &mut self.rex_drag {
            let (position, length) = if divider.direction == workspace::RexDirection::Horizontal {
                (
                    f32::from(position.x) - offset - divider.parent.x,
                    divider.parent.width - 5.0,
                )
            } else {
                (
                    f32::from(position.y) - APP_TITLEBAR_HEIGHT - divider.parent.y,
                    divider.parent.height - 5.0,
                )
            };
            *ratio = f64::from((position / length.max(1.0)).clamp(0.05, 0.95));
            cx.notify();
            cx.stop_propagation();
        }
    }

    pub(super) fn finish_rex_drag(&mut self, cx: &mut Context<Self>) {
        if let Some((divider, ratio)) = self.rex_drag.take() {
            self.diagnostic = self
                .workspace
                .resize_rex_split(&divider.id, ratio)
                .err()
                .map(|e| e.to_string());
            cx.notify();
            cx.stop_propagation();
        }
    }
}
