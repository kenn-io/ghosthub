use super::{RootView, dialog_text, is_paste_shortcut};
use gpui::{Context, FontWeight, KeyDownEvent, Window, div, prelude::*, px, rgb, rgba};
use workspace::SessionSelection;

#[derive(Clone)]
pub(super) struct Draft {
    request: workspace::SessionRenameRequest,
    name: String,
    selected: bool,
    submitting: bool,
    error: Option<String>,
}

impl RootView {
    pub(super) fn open_session_rename(
        &mut self,
        selection: &SessionSelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match self.workspace.session_rename_request(selection) {
            Ok(request) => {
                self.renaming_session = Some(Draft {
                    request,
                    name: selection.session().to_owned(),
                    selected: true,
                    submitting: false,
                    error: None,
                });
                self.diagnostic = None;
                window.focus(&self.create_focus);
            }
            Err(error) => self.diagnostic = Some(error.to_string()),
        }
        cx.notify();
    }

    pub(super) fn finish_session_rename(&mut self, id: u64, result: Result<(), String>) {
        if let Some(draft) = &mut self.renaming_session
            && draft.request.id() == id
        {
            match result {
                Ok(()) => {
                    self.renaming_session = None;
                    self.restore_focus = true;
                }
                Err(error) => {
                    draft.error = Some(error);
                    draft.submitting = false;
                }
            }
        }
    }

    fn cancel_session_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .renaming_session
            .as_ref()
            .is_some_and(|draft| !draft.submitting)
        {
            self.renaming_session = None;
            window.focus(&self.focus);
            cx.notify();
        }
    }

    fn submit_session_rename(&mut self, cx: &mut Context<Self>) {
        let Some(draft) = &mut self.renaming_session else {
            return;
        };
        if draft.submitting {
            return;
        }
        match self.workspace.rename_session(&draft.request, &draft.name) {
            Ok(()) => {
                draft.submitting = true;
                draft.error = None;
            }
            Err(error) => draft.error = Some(error.to_string()),
        }
        cx.notify();
    }

    fn session_rename_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.stop_propagation();
        let Some(draft) = &mut self.renaming_session else {
            return;
        };
        if draft.submitting {
            return;
        }
        let key = event.keystroke.key.to_ascii_lowercase();
        if key == "a" && (event.keystroke.modifiers.control || event.keystroke.modifiers.platform) {
            draft.selected = true;
        } else if is_paste_shortcut(&event.keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                if draft.selected {
                    draft.name.clear();
                }
                draft.selected = false;
                draft
                    .name
                    .extend(text.chars().filter(|character| !character.is_control()));
                draft.error = None;
            }
        } else {
            match key.as_str() {
                "escape" if !event.is_held => self.cancel_session_rename(window, cx),
                "enter" if !event.is_held => self.submit_session_rename(cx),
                "backspace" => {
                    if draft.selected {
                        draft.name.clear();
                    } else {
                        draft.name.pop();
                    }
                    draft.selected = false;
                    draft.error = None;
                }
                _ => {
                    if let Some(text) = dialog_text(&event.keystroke) {
                        if draft.selected {
                            draft.name.clear();
                        }
                        draft.selected = false;
                        draft
                            .name
                            .extend(text.chars().filter(|character| !character.is_control()));
                        draft.error = None;
                    }
                }
            }
        }
        cx.notify();
    }

    #[allow(clippy::too_many_lines)] // One modal's input, validation and action controls.
    pub(super) fn session_rename_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let draft = self.renaming_session.as_ref()?;
        let unchanged = draft.name.trim() == draft.request.selection().session();
        let validation = self
            .workspace
            .session_rename_validation(&draft.request, &draft.name)
            .err()
            .map(|error| error.to_string());
        let can_submit = !draft.submitting && validation.is_none();
        let error = draft.error.clone().or_else(|| {
            (!unchanged && !draft.name.trim().is_empty())
                .then_some(validation)
                .flatten()
        });
        let focused = self.create_focus.is_focused(window);
        let text = if focused && !draft.selected {
            format!("{}▏", draft.name)
        } else {
            draft.name.clone()
        };
        Some(
            div()
                .occlude()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x00_00_00_80))
                .child(
                    div()
                        .id("rename-session-dialog")
                        .track_focus(&self.create_focus)
                        .w(px(420.0))
                        .flex()
                        .flex_col()
                        .rounded_lg()
                        .border_1()
                        .border_color(rgb(0x36_3c48))
                        .bg(rgb(0x18_1b22))
                        .shadow_lg()
                        .on_key_down(cx.listener(|this, event, window, cx| {
                            this.session_rename_key_down(event, window, cx);
                        }))
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_b_1()
                                .border_color(rgb(0x2a_2f39))
                                .text_sm()
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(rgb(0xe0_e4eb))
                                .child("Rename tmux session"),
                        )
                        .child(
                            div()
                                .id("rename-session-name")
                                .m_4()
                                .px_3()
                                .h(px(38.0))
                                .flex()
                                .items_center()
                                .rounded_md()
                                .border_1()
                                .border_color(rgb(if focused { 0x4a_8f_cf } else { 0x3a_404c }))
                                .bg(rgb(0x0f_1218))
                                .cursor_text()
                                .text_sm()
                                .text_color(rgb(0xe1_e5ec))
                                .child(
                                    div()
                                        .when(focused && draft.selected, |el| el.bg(rgb(0x25_4f7a)))
                                        .child(text),
                                )
                                .on_click(cx.listener(|this, _, window, cx| {
                                    window.focus(&this.create_focus);
                                    cx.notify();
                                })),
                        )
                        .children(error.map(|message| {
                            div()
                                .px_4()
                                .pb_3()
                                .text_xs()
                                .text_color(rgb(0xd0_7070))
                                .child(message)
                        }))
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_t_1()
                                .border_color(rgb(0x2a_2f39))
                                .flex()
                                .justify_end()
                                .gap_2()
                                .child(
                                    div()
                                        .id("cancel-session-rename")
                                        .px_3()
                                        .py_1()
                                        .rounded_sm()
                                        .text_sm()
                                        .text_color(rgb(0xb6_bcc7))
                                        .when(!draft.submitting, |el| {
                                            el.cursor_pointer()
                                                .hover(|style| style.bg(rgb(0x29_2e38)))
                                                .on_click(cx.listener(|this, _, window, cx| {
                                                    this.cancel_session_rename(window, cx);
                                                }))
                                        })
                                        .child("Cancel"),
                                )
                                .child(
                                    div()
                                        .id("submit-session-rename")
                                        .px_3()
                                        .py_1()
                                        .rounded_sm()
                                        .text_sm()
                                        .bg(rgb(if can_submit { 0x1d_5f9a } else { 0x2b_3039 }))
                                        .text_color(rgb(if can_submit {
                                            0xf1_f5fa
                                        } else {
                                            0x72_7986
                                        }))
                                        .child(if draft.submitting {
                                            "Renaming…"
                                        } else {
                                            "Rename"
                                        })
                                        .when(can_submit, |el| {
                                            el.cursor_pointer().on_click(cx.listener(
                                                |this, _, _, cx| this.submit_session_rename(cx),
                                            ))
                                        }),
                                ),
                        ),
                )
                .into_any_element(),
        )
    }
}
