use super::{
    RootView, SETTINGS_FIELD_CHARACTER_LIMIT, UI_MONOSPACE_FONT, dialog_text, is_paste_shortcut,
};
use gpui::{Context, FontWeight, KeyDownEvent, div, prelude::*, px, rgb};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct Editor {
    text: String,
    selected: bool,
    pub(super) clear_focused: bool,
}

impl Editor {
    pub(super) fn new(patterns: &[String]) -> Self {
        Self {
            text: patterns.join("\n"),
            selected: true,
            clear_focused: false,
        }
    }

    fn insert(&mut self, text: &str) {
        if self.selected {
            self.text.clear();
        }
        self.selected = false;
        for character in text.chars().filter(|c| *c == '\n' || !c.is_control()) {
            if self.text.chars().count() >= SETTINGS_FIELD_CHARACTER_LIMIT {
                break;
            }
            self.text.push(character);
        }
    }

    fn backspace(&mut self) {
        if self.selected {
            self.text.clear();
        } else {
            self.text.pop();
        }
        self.selected = false;
    }

    pub(super) fn advance_focus(&mut self, reverse: bool) -> bool {
        if reverse == self.clear_focused {
            self.clear_focused = !self.clear_focused;
            false
        } else {
            true
        }
    }

    fn patterns(&self) -> Vec<String> {
        self.text.lines().map(str::to_owned).collect()
    }
}

impl RootView {
    fn persist_worktree_patterns(&mut self, cx: &mut Context<Self>) {
        let Some(dialog) = &self.settings_dialog else {
            return;
        };
        let patterns = dialog.worktrees_editor.patterns();
        let result = self
            .workspace
            .update_sidebar(|settings| settings.hidden_session_patterns = patterns);
        if let Some(dialog) = &mut self.settings_dialog {
            dialog.error = result.err().map(|error| error.to_string());
        }
        cx.notify();
    }

    pub(super) fn edit_worktree_patterns(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        let key = event.keystroke.key.to_ascii_lowercase();
        let paste = is_paste_shortcut(&event.keystroke)
            .then(|| cx.read_from_clipboard().and_then(|item| item.text()))
            .flatten();
        let Some(dialog) = &mut self.settings_dialog else {
            return;
        };
        let editor = &mut dialog.worktrees_editor;
        let mut changed = false;
        if editor.clear_focused {
            if matches!(key.as_str(), "enter" | "space") && !event.is_held {
                editor.text.clear();
                editor.selected = false;
                changed = true;
            }
        } else if key == "a"
            && (event.keystroke.modifiers.control || event.keystroke.modifiers.platform)
        {
            editor.selected = true;
        } else if is_paste_shortcut(&event.keystroke) {
            if !event.is_held
                && let Some(text) = paste
            {
                editor.insert(&text);
                changed = true;
            }
        } else if key == "backspace" || (key == "delete" && editor.selected) {
            editor.backspace();
            changed = true;
        } else if key == "enter" {
            editor.insert("\n");
            changed = true;
        } else if let Some(text) = dialog_text(&event.keystroke) {
            editor.insert(text);
            changed = true;
        }
        if changed {
            self.persist_worktree_patterns(cx);
        }
        cx.notify();
        cx.stop_propagation();
    }

    pub(super) fn settings_worktrees_editor(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let dialog = self.settings_dialog.as_ref().expect("settings open");
        let editor = &dialog.worktrees_editor;
        let focused = dialog.sidebar_focus.is_none();
        let patterns_focused = focused && !editor.clear_focused;
        let display = if editor.text.is_empty() {
            if patterns_focused {
                "▏".into()
            } else {
                "scratch-*\nbuild-?".into()
            }
        } else if patterns_focused && !editor.selected {
            format!("{}▏", editor.text)
        } else {
            editor.text.clone()
        };
        div().flex_1().min_h_0().p_6().flex().flex_col().gap_3()
            .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).child("Hidden session patterns"))
            .child(div().id("hidden-session-patterns").min_h(px(140.0)).max_h(px(240.0)).overflow_y_scroll()
                .p_3().rounded_md().border_1().border_color(rgb(if patterns_focused { 0x4a_8fcf } else { 0x3a_404c }))
                .bg(rgb(0x0f_1218)).text_sm().font_family(UI_MONOSPACE_FONT).cursor_text()
                .text_color(rgb(if editor.text.is_empty() && !patterns_focused { 0x72_7986 } else { 0xe1_e5ec }))
                .child(div().when(patterns_focused && editor.selected && !editor.text.is_empty(), |el| el.bg(rgb(0x24_527c))).child(display))
                .on_click(cx.listener(|this, _, window, cx| {
                    if let Some(dialog) = &mut this.settings_dialog { dialog.sidebar_focus = None; dialog.worktrees_editor.clear_focused = false; }
                    window.focus(&this.settings_focus); cx.notify();
                })))
            .child(div().text_xs().text_color(rgb(0x9b_a4b3))
                .child("One case-sensitive pattern per line. * matches any number of characters; ? matches one."))
            .child(div().text_xs().text_color(rgb(0x9b_a4b3))
                .child("Matching tmux rows are hidden on every host. Project worktrees and running terminals stay available."))
            .child(div().flex().child(div().id("clear-session-patterns").px_3().py_1().rounded_sm().border_1()
                .border_color(rgb(if focused && editor.clear_focused { 0x4a_8fcf } else { 0x3a_404c }))
                .text_sm().child("Clear patterns").cursor_pointer().hover(|el| el.bg(rgb(0x29_2e38)))
                .on_click(cx.listener(|this, _, window, cx| {
                    if let Some(dialog) = &mut this.settings_dialog {
                        dialog.sidebar_focus = None; dialog.worktrees_editor.clear_focused = true;
                        dialog.worktrees_editor.text.clear(); dialog.worktrees_editor.selected = false;
                    }
                    window.focus(&this.settings_focus); this.persist_worktree_patterns(cx);
                }))))
            .when_some(dialog.error.as_ref(), |element, error| {
                element.child(div().text_xs().text_color(rgb(0xd0_7070)).child(error.clone()))
            })
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pattern_editor_replaces_selection_accepts_lines_and_clears_without_eating_spaces() {
        let mut editor = Editor::new(&["old*".into()]);
        editor.insert("scratch-*\r\nbuild ?\n");
        assert_eq!(editor.patterns(), ["scratch-*", "build ?"]);
        editor.insert("notes");
        assert_eq!(editor.patterns(), ["scratch-*", "build ?", "notes"]);
        editor.backspace();
        assert_eq!(editor.patterns(), ["scratch-*", "build ?", "note"]);
        editor.selected = true;
        editor.backspace();
        assert!(editor.patterns().is_empty());
    }
}
