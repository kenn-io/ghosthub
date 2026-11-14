use super::*;
use workspace::{KeyChord, KeyboardPreferences, ShortcutAction};

pub(super) const FIELD_COUNT: usize = ShortcutAction::ALL.len() * 3;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct Editor {
    pub focus: usize,
    pub recording: Option<ShortcutAction>,
    pub error: Option<String>,
}

impl Editor {
    pub fn cancel(&mut self) {
        self.recording = None;
        self.error = None;
    }
}

fn bindings(preferences: &KeyboardPreferences) -> Vec<(ShortcutAction, gpui::KeybindingKeystroke)> {
    ShortcutAction::ALL
        .into_iter()
        .filter_map(|action| {
            let chord = preferences.binding(action)?.gpui_value();
            let key = gpui::Keystroke::parse(&chord).expect("validated shortcut syntax");
            Some((action, gpui::KeybindingKeystroke::from_keystroke(key)))
        })
        .collect()
}

fn recorded_chord(key: &gpui::Keystroke) -> Result<KeyChord, String> {
    if key.modifiers.platform || key.modifiers.function {
        return Err("Use Ctrl or Alt with the key".to_owned());
    }
    let mut parts = Vec::new();
    if key.modifiers.control {
        parts.push("ctrl");
    }
    if key.modifiers.alt {
        parts.push("alt");
    }
    if key.modifiers.shift {
        parts.push("shift");
    }
    let name = if key.key == "+" { "plus" } else { &key.key };
    parts.push(name);
    KeyChord::parse(&parts.join("+")).map_err(|error| error.to_string())
}

impl RootView {
    pub(super) fn sync_keyboard_bindings(&mut self) {
        let preferences = self.workspace.configured_keyboard();
        if self.observed_keyboard.as_ref() == Some(&preferences) {
            return;
        }
        self.keyboard_bindings = bindings(&preferences);
        self.observed_keyboard = Some(preferences);
    }

    // Focused Settings and terminal handlers get first refusal, including held key pairs.
    pub(super) fn on_application_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings_dialog.is_some() {
            return;
        }
        self.sync_keyboard_bindings();
        let Some(action) = self.application_shortcut(&event.keystroke) else {
            return;
        };
        if !event.is_held {
            match action {
                ShortcutAction::ToggleSidebar => self.toggle_sidebar(window, cx),
                ShortcutAction::NextSession => self.cycle_session(false, window, cx),
                ShortcutAction::PreviousSession => self.cycle_session(true, window, cx),
            }
        }
        cx.stop_propagation();
    }

    pub(super) fn application_shortcut(&self, key: &gpui::Keystroke) -> Option<ShortcutAction> {
        self.keyboard_bindings
            .iter()
            .find_map(|(action, binding)| key.should_match(binding).then_some(*action))
    }

    pub(super) fn observe_shortcut_recording(window: &mut Window, cx: &mut Context<Self>) {
        cx.observe_window_activation(window, |view, window, cx| {
            if !window.is_window_active()
                && let Some(dialog) = &mut view.settings_dialog
            {
                dialog.keyboard_editor.cancel();
                cx.notify();
            }
        })
        .detach();
    }

    pub(super) fn record_shortcut(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) -> bool {
        let Some(action) = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.keyboard_editor.recording)
        else {
            return false;
        };
        if event.is_held {
            return true;
        }
        if event.keystroke.key == "escape"
            && event.keystroke.modifiers == gpui::Modifiers::default()
        {
            self.settings_dialog
                .as_mut()
                .unwrap()
                .keyboard_editor
                .cancel();
        } else if !matches!(
            event.keystroke.key.as_str(),
            "control" | "alt" | "shift" | "platform" | "function"
        ) {
            let result = recorded_chord(&event.keystroke).and_then(|binding| {
                self.workspace
                    .set_shortcut(action, Some(&binding.config_value()))
                    .map_err(|error| error.to_string())
            });
            let editor = &mut self.settings_dialog.as_mut().unwrap().keyboard_editor;
            match result {
                Ok(()) => editor.cancel(),
                Err(error) => editor.error = Some(error),
            }
            self.sync_keyboard_bindings();
        }
        cx.notify();
        true
    }

    pub(super) fn edit_keyboard_setting(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        if matches!(event.keystroke.key.as_str(), "enter" | "space") && !event.is_held {
            let focus = self.settings_dialog.as_ref().unwrap().keyboard_editor.focus;
            self.activate_keyboard_control(focus, cx);
        }
        cx.stop_propagation();
    }

    fn activate_keyboard_control(&mut self, index: usize, cx: &mut Context<Self>) {
        let action = ShortcutAction::ALL[index / 3];
        let editor = &mut self.settings_dialog.as_mut().unwrap().keyboard_editor;
        editor.focus = index;
        editor.cancel();
        if index.is_multiple_of(3) {
            editor.recording = Some(action);
        } else {
            let value = if index % 3 == 1 { Some("none") } else { None };
            if let Err(error) = self.workspace.set_shortcut(action, value) {
                self.settings_dialog.as_mut().unwrap().keyboard_editor.error =
                    Some(error.to_string());
            }
            self.sync_keyboard_bindings();
        }
        cx.notify();
    }

    fn keyboard_binding_row(
        &self,
        row: usize,
        action: ShortcutAction,
        preferences: &KeyboardPreferences,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let editor = &self.settings_dialog.as_ref().unwrap().keyboard_editor;
        let recording = editor.recording == Some(action);
        let title = if recording {
            "Type shortcut…".to_owned()
        } else {
            preferences
                .binding(action)
                .map_or_else(|| "None".to_owned(), |chord| chord.display())
        };
        let mut controls = div().flex().items_center().gap_2();
        for (column, label) in [title, "Clear".to_owned(), "Restore Default".to_owned()]
            .into_iter()
            .enumerate()
        {
            let index = row * 3 + column;
            controls = controls.child(
                div()
                    .id(("shortcut-control", index))
                    .px_3()
                    .py_2()
                    .rounded_md()
                    .text_sm()
                    .border_1()
                    .border_color(rgb(
                        if (self
                            .settings_dialog
                            .as_ref()
                            .is_some_and(|dialog| dialog.sidebar_focus.is_none())
                            && self.settings_focus.is_focused(window)
                            && editor.focus == index)
                            || (recording && column == 0)
                        {
                            0x4a_8fcf
                        } else {
                            0x2a_2f39
                        },
                    ))
                    .bg(rgb(if column == 0 { 0x20_2835 } else { 0x17_1b23 }))
                    .cursor_pointer()
                    .hover(|style| style.bg(rgb(0x25_2d3a)))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        let dialog = this.settings_dialog.as_mut().unwrap();
                        dialog.sidebar_focus = None;
                        window.focus(&this.settings_focus);
                        this.activate_keyboard_control(index, cx);
                    }))
                    .child(label),
            );
        }
        div()
            .py_4()
            .border_b_1()
            .border_color(rgb(0x2a_2f39))
            .flex()
            .items_center()
            .justify_between()
            .gap_4()
            .child(action.title())
            .child(controls)
            .into_any_element()
    }

    pub(super) fn settings_keyboard_editor(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let editor = &self.settings_dialog.as_ref().unwrap().keyboard_editor;
        let preferences = self.workspace.configured_keyboard();
        let mut rows = div().flex().flex_col();
        for (row, action) in ShortcutAction::ALL.into_iter().enumerate() {
            rows = rows.child(self.keyboard_binding_row(row, action, &preferences, window, cx));
        }
        div()
            .id("settings-keyboard-editor")
            .flex_1()
            .min_w_0()
            .h_full()
            .overflow_y_scroll()
            .px_6()
            .py_4()
            .child(rows)
            .when_some(editor.error.clone(), |el, error| {
                el.child(
                    div()
                        .mt_4()
                        .text_sm()
                        .text_color(rgb(0xd0_7070))
                        .child(error),
                )
            })
            .when(editor.recording.is_some(), |el| {
                el.child(
                    div()
                        .mt_4()
                        .text_sm()
                        .text_color(rgb(0x8f_96a3))
                        .child("Press Escape to cancel."),
                )
            })
            .child(
                div()
                    .mt_8()
                    .text_lg()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("System Shortcuts"),
            )
            .child(
                div()
                    .mt_3()
                    .flex()
                    .justify_between()
                    .text_sm()
                    .child("Paste")
                    .child("Ctrl+Shift+V"),
            )
            .child(div().mt_8().text_sm().text_color(rgb(0x8f_96a3)).child(
                "Pane, window, and split shortcuts are configured in tmux, Herdr, or Zellij.",
            ))
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(preferences: &KeyboardPreferences, value: &str) -> Option<ShortcutAction> {
        let key = gpui::Keystroke::parse(value).unwrap();
        bindings(preferences)
            .iter()
            .find_map(|(action, binding)| key.should_match(binding).then_some(*action))
    }

    #[test]
    fn shortcut_matching_uses_current_bindings_and_disabled_actions() {
        let mut preferences = KeyboardPreferences::default();
        assert_eq!(
            matches(&preferences, "ctrl-shift-b"),
            Some(ShortcutAction::ToggleSidebar)
        );
        preferences
            .set(ShortcutAction::ToggleSidebar, Some("alt+b"))
            .unwrap();
        assert_eq!(matches(&preferences, "ctrl-shift-b"), None);
        assert_eq!(
            matches(&preferences, "alt-b"),
            Some(ShortcutAction::ToggleSidebar)
        );
        preferences
            .set(ShortcutAction::NextSession, Some("none"))
            .unwrap();
        assert_eq!(matches(&preferences, "ctrl-tab"), None);
        assert_eq!(
            matches(&preferences, "ctrl-shift-tab"),
            Some(ShortcutAction::PreviousSession)
        );
        for value in ["ctrl+-", "alt+plus", "ctrl+f12", "ctrl+shift+left"] {
            preferences
                .set(ShortcutAction::ToggleSidebar, Some(value))
                .unwrap();
            let value = preferences
                .binding(ShortcutAction::ToggleSidebar)
                .unwrap()
                .gpui_value();
            assert_eq!(
                matches(&preferences, &value),
                Some(ShortcutAction::ToggleSidebar)
            );
        }
    }

    #[test]
    fn recording_rejects_typing_and_fixed_keys_and_uses_gpui_key_names() {
        for (value, expected) in [
            ("ctrl-shift-b", "ctrl+shift+b"),
            ("alt-enter", "alt+enter"),
            ("ctrl--", "ctrl+-"),
        ] {
            assert_eq!(
                recorded_chord(&gpui::Keystroke::parse(value).unwrap())
                    .unwrap()
                    .config_value(),
                expected
            );
        }
        for value in ["a", "shift-a", "ctrl-shift-v", "cmd-b", "alt-f4"] {
            assert!(
                recorded_chord(&gpui::Keystroke::parse(value).unwrap()).is_err(),
                "{value}"
            );
        }
    }
}
