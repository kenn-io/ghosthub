use super::*;
use workspace::{AgentHookAction, AgentHookStatus};

fn note(text: &str, error: bool) -> gpui::Div {
    div()
        .text_sm()
        .text_color(rgb(if error { 0xd0_7070 } else { 0x8f_96a3 }))
        .child(text.to_owned())
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct Panel {
    attempted: bool,
    pending: Option<(u64, AgentHookAction)>,
    statuses: Vec<AgentHookStatus>,
    error: Option<String>,
    focus: usize,
}

impl Panel {
    fn needs_install(&self) -> bool {
        self.statuses
            .iter()
            .any(|status| status.available && !status.current)
    }

    pub(super) fn finish(&mut self, id: u64, result: Result<Vec<AgentHookStatus>, String>) {
        if self.pending.is_none_or(|(current, _)| current != id) {
            return;
        }
        self.pending = None;
        match result {
            Ok(statuses) => {
                self.statuses = statuses;
                self.error = None;
            }
            Err(error) => self.error = Some(error),
        }
        self.focus = self.focus.min(usize::from(self.needs_install()));
    }
}

#[derive(Clone, Copy)]
enum Action {
    Connect,
    Reload,
    Install,
}

impl RootView {
    fn hook_host(&self) -> Option<workspace::HostItem> {
        let dialog = self.settings_dialog.as_ref()?;
        let id = dialog.selected_host_id.as_deref()?;
        if let Some(editor) = &dialog.host_editor
            && !self
                .workspace
                .configured_ssh_hosts()
                .iter()
                .any(|host| host.id() == id && host.draft() == &editor.draft)
        {
            return None;
        }
        self.workspace
            .snapshot()
            .hosts()
            .iter()
            .find(|host| host.id() == id)
            .cloned()
    }

    fn hook_actions(&self) -> Vec<Action> {
        let Some(host) = self.hook_host() else {
            return Vec::new();
        };
        if !host.accepts_session_actions() {
            return vec![Action::Connect];
        }
        let mut actions = vec![Action::Reload];
        if self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.hook_panels.get(host.id()))
            .is_some_and(Panel::needs_install)
        {
            actions.push(Action::Install);
        }
        actions
    }

    pub(super) fn poll_agent_hooks(&mut self) -> bool {
        if !self
            .settings_dialog
            .as_ref()
            .is_some_and(|dialog| dialog.pane == SettingsPane::Hosts)
        {
            return false;
        }
        let Some(host) = self
            .hook_host()
            .filter(workspace::HostItem::accepts_session_actions)
        else {
            return false;
        };
        if self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.hook_panels.get(host.id()))
            .is_some_and(|panel| panel.attempted)
        {
            return false;
        }
        self.start_agent_hooks(host.id(), AgentHookAction::Status);
        true
    }

    fn start_agent_hooks(&mut self, id: &str, action: AgentHookAction) {
        let result = self.workspace.agent_hooks(id, action);
        if let Some(dialog) = &mut self.settings_dialog {
            let panel = dialog.hook_panels.entry(id.to_owned()).or_default();
            panel.attempted = true;
            panel.error = None;
            match result {
                Ok(operation_id) => panel.pending = Some((operation_id, action)),
                Err(error) => panel.error = Some(error.to_string()),
            }
        }
    }

    fn run_hook_action(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(action) = self.hook_actions().get(index).copied() else {
            return;
        };
        let Some(host) = self.hook_host() else {
            return;
        };
        let busy = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.hook_panels.get(host.id()))
            .is_some_and(|panel| panel.pending.is_some());
        if busy {
            return;
        }
        match action {
            Action::Connect => {
                let result = if host.connection() == HostConnectionState::Connecting {
                    let _cancelled = self.workspace.cancel_host_connection(host.id());
                    Ok(())
                } else {
                    self.workspace.connect_host(host.id())
                };
                if let Err(error) = result
                    && let Some(dialog) = &mut self.settings_dialog
                {
                    dialog
                        .hook_panels
                        .entry(host.id().to_owned())
                        .or_default()
                        .error = Some(error.to_string());
                }
            }
            Action::Reload => self.start_agent_hooks(host.id(), AgentHookAction::Status),
            Action::Install => self.start_agent_hooks(host.id(), AgentHookAction::Install),
        }
        cx.notify();
    }

    pub(super) fn advance_settings_tab(
        &mut self,
        reverse: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .settings_dialog
            .as_ref()
            .is_some_and(|dialog| dialog.pane == SettingsPane::Hosts)
            && self.tab_to_agent_hooks(reverse, window, cx)
        {
            return;
        }
        if let Some(dialog) = &mut self.settings_dialog {
            advance_settings_focus(dialog, reverse);
            cx.notify();
        }
    }

    fn tab_to_agent_hooks(
        &mut self,
        reverse: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let enter_hooks = self.settings_dialog.as_ref().is_some_and(|dialog| {
            if reverse && dialog.sidebar_focus == Some(SettingsPane::Appearance) {
                return true;
            }
            if dialog.host_editor.is_none() {
                dialog.selected_host_id.is_some()
                    && (dialog.sidebar_focus.is_none()
                        || (!reverse && dialog.sidebar_focus == Some(SettingsPane::Hosts)))
            } else {
                dialog.sidebar_focus.is_none()
                    && !reverse
                    && dialog
                        .host_editor
                        .as_ref()
                        .is_some_and(|editor| editor.field == SshField::SocketDirectory)
            }
        });
        enter_hooks && self.focus_agent_hooks(reverse, window, cx)
    }

    pub(super) fn focus_agent_hooks(
        &mut self,
        reverse: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let count = self.hook_actions().len();
        if count == 0 {
            return false;
        }
        if let Some(dialog) = &mut self.settings_dialog {
            dialog.sidebar_focus = None;
            if let Some(id) = &dialog.selected_host_id {
                dialog.hook_panels.entry(id.clone()).or_default().focus =
                    if reverse { count - 1 } else { 0 };
            }
        }
        if self
            .settings_dialog
            .as_ref()
            .is_some_and(|dialog| dialog.host_editor.is_some())
        {
            self.host_settings_scroll.scroll_to_bottom();
        }
        window.focus(&self.hooks_focus);
        cx.notify();
        true
    }

    fn edit_agent_hooks(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let count = self.hook_actions().len();
        let Some(dialog) = &mut self.settings_dialog else {
            return;
        };
        let Some(id) = dialog.selected_host_id.clone() else {
            return;
        };
        let focus = dialog
            .hook_panels
            .entry(id)
            .or_default()
            .focus
            .min(count.saturating_sub(1));
        match event.keystroke.key.as_str() {
            "escape" => self.close_settings(window, cx),
            "enter" | "space" if !event.is_held => self.run_hook_action(focus, cx),
            "tab" => {
                let reverse = event.keystroke.modifiers.shift;
                if (reverse && focus == 0) || (!reverse && focus + 1 >= count) {
                    dialog.sidebar_focus = if reverse && dialog.host_editor.is_some() {
                        None
                    } else {
                        Some(if reverse {
                            SettingsPane::Hosts
                        } else {
                            SettingsPane::Appearance
                        })
                    };
                    if let Some(editor) = &mut dialog.host_editor {
                        editor.field = SshField::SocketDirectory;
                    }
                    if reverse && dialog.host_editor.is_some() {
                        self.host_settings_scroll
                            .set_offset(gpui::point(px(0.0), px(0.0)));
                    }
                    window.focus(&self.settings_focus);
                } else if let Some(id) = &dialog.selected_host_id {
                    dialog.hook_panels.get_mut(id).unwrap().focus =
                        if reverse { focus - 1 } else { focus + 1 };
                }
            }
            _ => {}
        }
        cx.stop_propagation();
        cx.notify();
    }

    pub(super) fn agent_hooks_section(
        &self,
        id: &str,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let panel = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.hook_panels.get(id))
            .cloned()
            .unwrap_or_default();
        let Some(host) = self.hook_host().filter(|host| host.id() == id) else {
            return div()
                .pt_6()
                .text_sm()
                .text_color(rgb(0x8f_96a3))
                .child("Save Host before setting up agent hooks.")
                .into_any_element();
        };
        let pending = panel.pending.map(|(_, action)| action);
        let mut section = div()
            .id("agent-hooks-settings")
            .track_focus(&self.hooks_focus)
            .mt_6()
            .pt_5()
            .border_t_1()
            .border_color(rgb(0x2a_2f39))
            .flex()
            .flex_col()
            .gap_3()
            .on_key_down(cx.listener(Self::edit_agent_hooks))
            .child(
                div()
                    .text_lg()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Agent Hooks"),
            )
            .child(note(
                "Edits each agent's user settings on this host.",
                false,
            ));
        let available: Vec<_> = panel
            .statuses
            .iter()
            .filter(|status| status.available)
            .collect();
        if !host.accepts_session_actions() {
            section = section.child(note("Connect this host to read agent hook status.", false));
        } else if pending == Some(AgentHookAction::Status) || !panel.attempted {
            section = section.child(note("Loading…", false));
        } else if available.is_empty() && panel.error.is_none() {
            section = section.child(note("No supported agents found", false));
        }
        for status in available {
            let label = if status.current {
                "Installed"
            } else if status.installed {
                "Update available"
            } else {
                "Not installed"
            };
            section = section.child(
                div()
                    .flex()
                    .justify_between()
                    .text_sm()
                    .child(status.display_name.clone())
                    .child(div().text_color(rgb(0x8f_96a3)).child(label)),
            );
        }
        if panel
            .statuses
            .iter()
            .any(|status| status.agent == "codex" && status.installed)
        {
            section = section.child(note("Codex: open /hooks once to trust new hooks.", false));
        }
        if let Some(error) = &panel.error {
            section = section.child(note(error, true));
        }
        section
            .child(self.hook_buttons(&panel, &host, window, cx))
            .into_any_element()
    }

    fn hook_buttons(
        &self,
        panel: &Panel,
        host: &HostItem,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let pending = panel.pending.map(|(_, action)| action);
        let mut buttons = div().flex().gap_2().justify_end();
        for (index, action) in self.hook_actions().iter().enumerate() {
            let title = match action {
                Action::Connect if host.connection() == HostConnectionState::Connecting => {
                    "Cancel Connection"
                }
                Action::Connect => "Connect",
                Action::Reload => "Reload",
                Action::Install if pending == Some(AgentHookAction::Install) => "Installing…",
                Action::Install => "Install Hooks",
            };
            buttons = buttons.child(
                div()
                    .id(("agent-hook-action", index))
                    .px_3()
                    .py_2()
                    .rounded_md()
                    .text_sm()
                    .bg(rgb(if matches!(action, Action::Install) {
                        0x1d_5f9a
                    } else {
                        0x25_2d3a
                    }))
                    .when(
                        self.hooks_focus.is_focused(window) && panel.focus == index,
                        |el| el.border_1().border_color(rgb(0x4a_8fcf)),
                    )
                    .when(pending.is_some(), |el| el.opacity(0.5))
                    .when(pending.is_none(), |el| {
                        el.cursor_pointer()
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.focus_agent_hooks(false, window, cx);
                                if let Some(dialog) = &mut this.settings_dialog
                                    && let Some(id) = &dialog.selected_host_id
                                {
                                    dialog.hook_panels.entry(id.clone()).or_default().focus = index;
                                }
                                this.run_hook_action(index, cx);
                            }))
                    })
                    .child(title),
            );
        }
        buttons.into_any_element()
    }

    pub(super) fn local_hook_settings(
        &self,
        id: &str,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let name = self
            .workspace
            .snapshot()
            .hosts()
            .iter()
            .find(|host| host.id() == id)
            .map_or_else(|| "Local".to_owned(), |host| host.name().to_owned());
        div()
            .id("local-host-settings")
            .flex_1()
            .min_w_0()
            .h_full()
            .overflow_y_scroll()
            .px_6()
            .py_5()
            .child(
                div()
                    .w_full()
                    .max_w(px(620.0))
                    .child(
                        div()
                            .text_lg()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(name),
                    )
                    .child(self.agent_hooks_section(id, window, cx)),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(current: bool) -> AgentHookStatus {
        AgentHookStatus {
            agent: "codex".to_owned(),
            display_name: "Codex".to_owned(),
            available: true,
            installed: current,
            current,
        }
    }

    #[test]
    fn completed_setup_updates_the_button_and_old_results_do_not_replace_a_new_request() {
        let mut panel = Panel {
            attempted: true,
            pending: Some((12, AgentHookAction::Install)),
            statuses: vec![status(false)],
            focus: 1,
            ..Panel::default()
        };
        panel.finish(11, Ok(vec![status(true)]));
        assert!(panel.needs_install());
        assert!(panel.pending.is_some());
        panel.finish(12, Ok(vec![status(true)]));
        assert!(!panel.needs_install());
        assert!(panel.pending.is_none());
        assert_eq!(
            panel.focus, 0,
            "focus returns to Reload when Install disappears"
        );
        panel.pending = Some((13, AgentHookAction::Status));
        panel.finish(13, Err("Could not read hooks".to_owned()));
        assert_eq!(panel.error.as_deref(), Some("Could not read hooks"));
        assert!(panel.statuses[0].current);
    }
}
