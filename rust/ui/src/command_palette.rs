use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
enum Action {
    Host(String),
    Connect(String),
    Session(SessionSelection),
    RestartHerdr(SessionSelection),
    Worktree(WorktreeOpenTarget),
    Settings(SettingsPane),
    ToggleSidebar,
    Rex(u64, rex_window::PaneAction),
}

#[derive(Clone)]
struct Entry {
    title: String,
    subtitle: String,
    action: Action,
}

#[allow(clippy::too_many_lines)] // Catalog follows the existing host, session and workspace groups.
fn entries(
    hosts: &[HostItem],
    active: Option<&SessionSelection>,
    retained: &[SessionSelection],
    preferences: &workspace::SidebarPreferences,
    sidebar_visible: bool,
) -> Vec<Entry> {
    let mut rows = Vec::new();
    for host in hosts {
        for session in sidebar::sessions(host, active, retained, preferences) {
            if session.can_open() {
                rows.push(Entry {
                    title: if session.stopped() {
                        format!("Restart {}", session.title())
                    } else {
                        session.title()
                    },
                    subtitle: format!(
                        "{} · {} · {}",
                        host.name(),
                        sidebar::backend_label(session.selection().kind()),
                        host.endpoint()
                    ),
                    action: if session.stopped() {
                        Action::RestartHerdr(session.selection().clone())
                    } else {
                        Action::Session(session.selection().clone())
                    },
                });
            }
        }
        for project in host.projects() {
            for worktree in project.worktrees() {
                if worktree.is_main() && preferences.hide_root_checkout {
                    continue;
                }
                let selection = SessionSelection::kwt_workspace(
                    host.id(),
                    host.endpoint(),
                    worktree.session_name(),
                    worktree.tmux_attach_mode(),
                    worktree.tmux_socket_name().map(str::to_owned),
                    worktree.path(),
                    worktree.generation().map(str::to_owned),
                );
                let presented = active
                    .into_iter()
                    .chain(retained)
                    .any(|item| kwt_selection_matches_presentation(&selection, item));
                let mode = worktree_row_open_mode(host, worktree, presented);
                if mode == WorktreeOpenMode::Disabled {
                    continue;
                }
                rows.push(Entry {
                    title: format!("{} / {}", project.name(), worktree.branch()),
                    subtitle: format!("{} · Worktree · {}", host.name(), worktree.path()),
                    action: if mode == WorktreeOpenMode::RepairOrOpen {
                        Action::Worktree(WorktreeOpenTarget {
                            host_id: host.id().into(),
                            endpoint: host.endpoint().into(),
                            repository: project.repository().into(),
                            project_path: project.path().into(),
                            registration_fingerprint: project.registration_fingerprint().into(),
                            worktree_path: worktree.path().into(),
                            generation: worktree.generation().map(str::to_owned),
                            session_name: worktree.session_name().into(),
                            tmux_socket_name: worktree.tmux_socket_name().map(str::to_owned),
                            tmux_attach_mode: worktree.tmux_attach_mode(),
                        })
                    } else {
                        Action::Session(selection)
                    },
                });
            }
        }
        for directory in host.directory_workspaces() {
            let selection = SessionSelection::kwt_workspace(
                host.id(),
                host.endpoint(),
                directory.session_name(),
                directory.tmux_attach_mode(),
                directory.tmux_socket_name().map(str::to_owned),
                directory.path(),
                None,
            );
            let presented = active
                .into_iter()
                .chain(retained)
                .any(|item| kwt_selection_matches_presentation(&selection, item));
            if directory_row_can_open(host, directory, presented) {
                rows.push(Entry {
                    title: directory.name().into(),
                    subtitle: format!("{} · Directory · {}", host.name(), directory.path()),
                    action: Action::Session(selection),
                });
            }
        }
        rows.push(Entry {
            title: format!("Select {}", host.name()),
            subtitle: host.endpoint().into(),
            action: Action::Host(host.id().into()),
        });
        if matches!(
            host.connection(),
            HostConnectionState::Disconnected | HostConnectionState::Unavailable
        ) {
            rows.push(Entry {
                title: format!("Connect to {}", host.name()),
                subtitle: host.endpoint().into(),
                action: Action::Connect(host.id().into()),
            });
        }
    }
    for pane in SettingsPane::ALL {
        rows.push(Entry {
            title: pane.title().into(),
            subtitle: "Settings".into(),
            action: Action::Settings(pane),
        });
    }
    rows.push(Entry {
        title: format!("{} Sidebar", if sidebar_visible { "Hide" } else { "Show" }),
        subtitle: "View".into(),
        action: Action::ToggleSidebar,
    });
    rows
}

fn matching<'a>(rows: &'a [Entry], query: &str) -> Vec<&'a Entry> {
    let words: Vec<_> = query.split_whitespace().map(str::to_lowercase).collect();
    rows.iter()
        .filter(|row| {
            let text = format!("{} {}", row.title, row.subtitle).to_lowercase();
            words.iter().all(|word| text.contains(word))
        })
        .collect()
}

// GPUI retains a mouse press by element ID between renders.
fn result_id(entry: &Entry) -> gpui::ElementId {
    gpui::ElementId::Name(
        format!(
            "palette-result:{:?}",
            (&entry.action, &entry.title, &entry.subtitle)
        )
        .into(),
    )
}

pub(super) struct Dialog {
    query: String,
    selected: Option<gpui::ElementId>,
    select_all: bool,
    scroll: gpui::ScrollHandle,
}

impl Dialog {
    fn new(rows: &[Entry]) -> Self {
        Self {
            query: String::new(),
            selected: rows.first().map(result_id),
            select_all: false,
            scroll: gpui::ScrollHandle::new(),
        }
    }

    fn chosen<'a>(&self, rows: &'a [Entry]) -> Option<&'a Entry> {
        matching(rows, &self.query)
            .into_iter()
            .find(|row| Some(result_id(row)).as_ref() == self.selected.as_ref())
    }

    fn set_query(&mut self, query: String, rows: &[Entry]) {
        self.query = query;
        self.select_all = false;
        self.selected = matching(rows, &self.query)
            .first()
            .map(|row| result_id(row));
        self.scroll.set_offset(gpui::point(px(0.0), px(0.0)));
    }

    fn move_selection(&mut self, rows: &[Entry], reverse: bool) {
        let matches = matching(rows, &self.query);
        if matches.is_empty() {
            return;
        }
        let index = matches
            .iter()
            .position(|row| Some(result_id(row)).as_ref() == self.selected.as_ref());
        let index = index.map_or(if reverse { matches.len() - 1 } else { 0 }, |index| {
            if reverse {
                (index + matches.len() - 1) % matches.len()
            } else {
                (index + 1) % matches.len()
            }
        });
        self.selected = Some(result_id(matches[index]));
        self.scroll.scroll_to_item(index);
    }
}

impl RootView {
    fn palette_entries(&self) -> Vec<Entry> {
        let snapshot = self.workspace.snapshot();
        let active = snapshot
            .active_selection()
            .cloned()
            .or_else(|| active_session_selection(snapshot.content()));
        let mut rows = entries(
            snapshot.hosts(),
            active.as_ref(),
            snapshot.retained_selections(),
            &self.workspace.configured_sidebar(),
            self.sidebar_visible,
        );
        if let Some(rex) = snapshot.rex_window().filter(|w| w.error.is_none())
            && let Some(pane) = rex.panes.iter().find(|p| p.focused)
        {
            use rex_window::PaneAction;
            for action in [
                PaneAction::SplitRight,
                PaneAction::SplitDown,
                PaneAction::Zoom,
                PaneAction::Next,
                PaneAction::Previous,
                PaneAction::Close,
            ] {
                rows.push(Entry {
                    title: action.title().into(),
                    subtitle: format!("Rex · {}", rex.title),
                    action: Action::Rex(pane.presentation_id, action),
                });
            }
        }
        rows
    }

    pub(super) fn open_command_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.rex_close.is_some()
            || self.new_session.is_some()
            || self.project_dialog.is_some()
            || self.settings_dialog.is_some()
            || self.renaming_session.is_some()
            || !self.ssh_prompts.is_empty()
            || self.paste_confirmation
            || self.workspace.session_kill_confirmation().is_some()
            || self.workspace.herdr_lifecycle_confirmation().is_some()
        {
            return;
        }
        self.sidebar_menu = None;
        self.session_action_menu = None;
        self.palette = Some(Dialog::new(&self.palette_entries()));
        window.focus(&self.palette_focus);
        cx.notify();
    }

    fn close_command_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.palette = None;
        window.focus(&self.focus);
        cx.notify();
    }

    fn run_palette_action(&mut self, action: &Action, window: &mut Window, cx: &mut Context<Self>) {
        if !self
            .palette_entries()
            .iter()
            .any(|row| &row.action == action)
        {
            return;
        }
        self.close_command_palette(window, cx);
        match action {
            Action::Session(selection) => self.select_session(selection, window, cx),
            Action::RestartHerdr(selection) => self.restart_herdr_session(selection, window, cx),
            Action::Worktree(target) => self.select_worktree(target, window, cx),
            Action::Host(id) => {
                self.diagnostic = self
                    .workspace
                    .select_host(id)
                    .err()
                    .map(|error| error.to_string());
                cx.notify();
            }
            Action::Connect(id) => self.connect_host(id, cx),
            Action::Settings(pane) => {
                self.open_settings(window, cx);
                let dialog = self.settings_dialog.as_mut().unwrap();
                dialog.pane = *pane;
                dialog.sidebar_focus = Some(*pane);
            }
            Action::ToggleSidebar => self.toggle_sidebar(window, cx),
            Action::Rex(presentation, action) => {
                self.run_rex_action(*presentation, *action, window, cx);
            }
        }
    }

    fn on_palette_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let rows = self.palette_entries();
        let dialog = self.palette.as_mut().unwrap();
        let key = &event.keystroke;
        match key.key.as_str() {
            "escape" => self.close_command_palette(window, cx),
            "enter" if !event.is_held => {
                let action = dialog.chosen(&rows).map(|row| row.action.clone());
                if let Some(action) = action {
                    self.run_palette_action(&action, window, cx);
                }
            }
            "up" | "down" => dialog.move_selection(&rows, key.key == "up"),
            "a" if key.modifiers.control => dialog.select_all = true,
            _ => {
                let mut query = dialog.query.clone();
                if key.key == "backspace" {
                    if dialog.select_all {
                        query.clear();
                    } else {
                        query.pop();
                    }
                } else if is_paste_shortcut(key) || (key.key == "v" && key.modifiers.control) {
                    if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                        if dialog.select_all {
                            query.clear();
                        }
                        append_non_control_characters(
                            &mut query,
                            &text,
                            SETTINGS_FIELD_CHARACTER_LIMIT,
                        );
                    }
                } else if let Some(text) = dialog_text(key) {
                    if dialog.select_all {
                        query.clear();
                    }
                    append_non_control_characters(&mut query, text, SETTINGS_FIELD_CHARACTER_LIMIT);
                }
                if query != dialog.query {
                    dialog.set_query(query, &rows);
                }
            }
        }
        cx.stop_propagation();
        cx.notify();
    }

    #[allow(clippy::too_many_lines)] // Keep the focused search field and its result list together.
    pub(super) fn command_palette_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let dialog = self.palette.as_ref()?;
        let rows = self.palette_entries();
        let matches = matching(&rows, &dialog.query);
        let width = (f32::from(window.viewport_size().width) - 32.0).min(560.0);
        let height = (f32::from(window.viewport_size().height) - 180.0).clamp(48.0, 352.0);
        let mut results = div()
            .id("palette-results")
            .max_h(px(height))
            .overflow_y_scroll()
            .track_scroll(&dialog.scroll);
        for entry in &matches {
            let action = entry.action.clone();
            let selected = Some(result_id(entry)).as_ref() == dialog.selected.as_ref();
            results = results.child(
                div()
                    .id(result_id(entry))
                    .h(px(44.0))
                    .px_4()
                    .flex()
                    .flex_col()
                    .justify_center()
                    .overflow_hidden()
                    .cursor_pointer()
                    .bg(rgb(if selected { 0x20_344b } else { 0x18_1b22 }))
                    .hover(|style| style.bg(rgb(0x25_2d3a)))
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(0xe5_e9f0))
                            .text_ellipsis()
                            .child(entry.title.clone()),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(0xa5_acb8))
                            .text_ellipsis()
                            .child(entry.subtitle.clone()),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.run_palette_action(&action, window, cx);
                    })),
            );
        }
        if matches.is_empty() {
            results = results.child(
                div()
                    .px_4()
                    .py_4()
                    .text_sm()
                    .text_color(rgb(0xa5_acb8))
                    .child("No matching commands"),
            );
        }
        Some(
            div()
                .occlude()
                .absolute()
                .inset_0()
                .size_full()
                .flex()
                .items_start()
                .justify_center()
                .bg(rgba(0x00_00_00_80))
                .on_mouse_down(
                    GpuiMouseButton::Left,
                    cx.listener(|this, _, window, cx| this.close_command_palette(window, cx)),
                )
                .child(
                    div()
                        .id("command-palette")
                        .occlude()
                        .track_focus(&self.palette_focus)
                        .mt(px(64.0))
                        .w(px(width))
                        .h_auto()
                        .flex()
                        .flex_col()
                        .rounded_lg()
                        .overflow_hidden()
                        .border_1()
                        .border_color(rgb(0x48_5568))
                        .bg(rgb(0x18_1b22))
                        .on_mouse_down(GpuiMouseButton::Left, |_, _, cx| cx.stop_propagation())
                        .on_key_down(cx.listener(Self::on_palette_key_down))
                        .on_key_up(cx.listener(|this, event, window, cx| {
                            if let Some(id) =
                                terminal_presentation_id(this.workspace.snapshot().content())
                            {
                                this.on_key_up(id, event, window, cx);
                            }
                            cx.stop_propagation();
                        }))
                        .child(
                            div()
                                .h(px(52.0))
                                .px_4()
                                .flex()
                                .items_center()
                                .border_b_1()
                                .border_color(rgb(0x36_3c48))
                                .text_size(px(16.0))
                                .child(
                                    div()
                                        .flex_1()
                                        .overflow_hidden()
                                        .text_ellipsis()
                                        .text_color(rgb(if dialog.query.is_empty() {
                                            0xa5_acb8
                                        } else {
                                            0xe5_e9f0
                                        }))
                                        .when(dialog.select_all, |el| el.bg(rgb(0x20_344b)))
                                        .child(if dialog.query.is_empty() {
                                            "Search commands…".into()
                                        } else {
                                            format!("{}▏", dialog.query)
                                        }),
                                )
                                .child(div().text_xs().text_color(rgb(0xa5_acb8)).child("Esc")),
                        )
                        .child(results),
                )
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_uses_all_words_across_host_backend_and_destination() {
        let host = HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            vec![workspace::SessionItem::new("Release REVIEW", 0)],
            None,
        );
        let rows = entries(
            &[host],
            None,
            &[],
            &workspace::SidebarPreferences::default(),
            true,
        );
        let matches = matching(&rows, " REVIEW  studio tmux ");
        assert_eq!(matches.len(), 1);
        assert!(matches[0].title.contains("Release REVIEW"));
        assert!(matching(&rows, "review absent").is_empty());
        assert_eq!(matching(&rows, "  ").len(), rows.len());
    }

    #[test]
    fn selection_wraps_preserves_identity_and_refuses_a_removed_destination() {
        let rows = vec![
            Entry {
                title: "Local".into(),
                subtitle: "Linux".into(),
                action: Action::Host("local".into()),
            },
            Entry {
                title: "Studio".into(),
                subtitle: "studio.example".into(),
                action: Action::Host("studio".into()),
            },
        ];
        let mut dialog = Dialog::new(&rows);
        assert_eq!(
            dialog.chosen(&rows).map(|row| &row.action),
            Some(&Action::Host("local".into()))
        );
        dialog.move_selection(&rows, true);
        assert_eq!(
            dialog.chosen(&rows).map(|row| &row.action),
            Some(&Action::Host("studio".into()))
        );
        dialog.move_selection(&rows, false);
        assert_eq!(
            dialog.chosen(&rows).map(|row| &row.action),
            Some(&Action::Host("local".into()))
        );
        let reordered = vec![rows[1].clone(), rows[0].clone()];
        assert_eq!(
            dialog.chosen(&reordered).map(|row| &row.action),
            Some(&Action::Host("local".into()))
        );
        assert!(dialog.chosen(&rows[1..]).is_none());
        dialog.set_query("STUDIO".into(), &rows);
        assert_eq!(
            dialog.chosen(&rows).map(|row| &row.action),
            Some(&Action::Host("studio".into()))
        );
        dialog.set_query("missing".into(), &rows);
        dialog.move_selection(&rows, false);
        assert!(dialog.chosen(&rows).is_none());
    }

    #[test]
    fn visibility_and_readiness_match_the_sidebar_without_hiding_project_worktrees() {
        let worktree = workspace::WorktreeItem::new(
            "/work/atlas/topic",
            "feature/theme",
            false,
            Some("generation".into()),
            "managed-topic",
            (None, KwtTmuxAttachMode::Direct),
            false,
        );
        let host = HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            vec![
                workspace::SessionItem::new("build", 0),
                workspace::SessionItem::new("secret", 0),
            ],
            None,
        )
        .with_herdr_sessions(vec![workspace::HerdrSessionItem::new(
            "notes",
            false,
            HerdrSessionState::Running,
        )])
        .with_kwt_inventory(
            vec![workspace::ProjectItem::new(
                "example.com/team/atlas",
                "Atlas",
                "/work/atlas",
                "registration",
                vec![worktree],
            )],
            Vec::new(),
        );
        let preferences = workspace::SidebarPreferences {
            hidden_session_patterns: vec!["secret".into()],
            ..workspace::SidebarPreferences::default()
        };
        let rows = entries(&[host], None, &[], &preferences, true);
        assert!(matching(&rows, "secret").is_empty());
        assert_eq!(matching(&rows, "build studio tmux").len(), 1);
        assert_eq!(matching(&rows, "notes herdr").len(), 1);
        let matches = matching(&rows, "atlas feature/theme");
        assert_eq!(matches.len(), 1);
        let Action::Worktree(target) = &matches[0].action else {
            panic!("expected a worktree open")
        };
        assert_eq!(target.generation.as_deref(), Some("generation"));
        assert_eq!(target.registration_fingerprint, "registration");
        assert_eq!(target.host_id, "ssh:studio");
        let unavailable = HostItem::ssh(
            "ssh:offline",
            "Offline",
            "offline.example",
            HostConnectionState::Unavailable,
            vec![workspace::SessionItem::new("cached", 0)],
            None,
        );
        let rows = entries(&[unavailable], None, &[], &preferences, true);
        assert!(
            !rows
                .iter()
                .any(|row| matches!(row.action, Action::Session(_)))
        );
        assert!(
            rows.iter()
                .any(|row| matches!(row.action, Action::Connect(_)))
        );
    }
    #[test]
    fn direct_worktrees_directories_and_retained_protected_clients_keep_their_open_paths() {
        let protected = SessionSelection::kwt_workspace(
            "ssh:studio",
            "studio.example",
            "review",
            KwtTmuxAttachMode::Protected,
            Some("protected-review".into()),
            "/work/removed",
            Some("old-checkout".into()),
        );
        let host = HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            vec![workspace::SessionItem::new("main", 0)],
            None,
        )
        .with_kwt_inventory(
            vec![workspace::ProjectItem::new(
                "example.com/team/atlas",
                "Atlas",
                "/work/atlas",
                "registration",
                vec![workspace::WorktreeItem::new(
                    "/work/atlas",
                    "main",
                    true,
                    None,
                    "main",
                    (None, KwtTmuxAttachMode::Direct),
                    true,
                )],
            )],
            vec![workspace::DirectoryWorkspaceItem::new(
                "Logs",
                "/work/logs",
                "logs",
                (Some("kwt".into()), KwtTmuxAttachMode::Direct),
                false,
            )],
        );
        let mut preferences = workspace::SidebarPreferences::default();
        let rows = entries(
            std::slice::from_ref(&host),
            None,
            std::slice::from_ref(&protected),
            &preferences,
            true,
        );
        let main = matching(&rows, "atlas main");
        assert_eq!(main.len(), 1);
        assert!(
            matches!(&main[0].action, Action::Session(selection) if selection.session() == "main" && selection.tmux_socket_name().is_none())
        );
        let logs = matching(&rows, "logs directory");
        assert_eq!(logs.len(), 1);
        assert!(
            matches!(&logs[0].action, Action::Session(selection) if selection.worktree_path() == Some("/work/logs") && selection.tmux_socket_name() == Some("kwt"))
        );
        let review = matching(&rows, "review");
        assert_eq!(review.len(), 1);
        assert!(matches!(&review[0].action, Action::Session(selection) if selection == &protected));
        preferences.hide_root_checkout = true;
        assert!(
            matching(
                &entries(&[host], None, &[protected], &preferences, true),
                "atlas main"
            )
            .is_empty()
        );
    }

    #[test]
    fn result_click_identity_follows_the_destination_across_reordering_and_replacement() {
        let studio = Entry {
            title: "Select Studio".into(),
            subtitle: "studio.example".into(),
            action: Action::Host("studio".into()),
        };
        let local = Entry {
            title: "Select Local".into(),
            subtitle: "Linux".into(),
            action: Action::Host("local".into()),
        };
        let before: Vec<_> = [&studio, &local].into_iter().map(result_id).collect();
        let after: Vec<_> = [&local, &studio].into_iter().map(result_id).collect();
        assert_eq!(before[0], after[1]);
        assert_ne!(before[0], after[0]);
        let replacement = Entry {
            action: Action::Host("replacement".into()),
            ..studio.clone()
        };
        assert_ne!(result_id(&studio), result_id(&replacement));
    }
    #[test]
    fn duplicate_workspace_destinations_remain_separately_navigable() {
        let host = HostItem::wsl(
            "Linux",
            None,
            HostConnectionState::Ready,
            vec![
                workspace::SessionItem::new("main", 0),
                workspace::SessionItem::new("logs", 0),
            ],
            None,
        )
        .with_kwt_inventory(
            vec![workspace::ProjectItem::new(
                "example.com/team/atlas",
                "Atlas",
                "/work/atlas",
                "registration",
                vec![workspace::WorktreeItem::new(
                    "/work/atlas",
                    "main",
                    true,
                    None,
                    "main",
                    (None, KwtTmuxAttachMode::Direct),
                    true,
                )],
            )],
            vec![workspace::DirectoryWorkspaceItem::new(
                "Logs",
                "/work/logs",
                "logs",
                (None, KwtTmuxAttachMode::Direct),
                true,
            )],
        );
        let preferences = workspace::SidebarPreferences {
            hide_worktree_sessions: false,
            ..workspace::SidebarPreferences::default()
        };
        let active = SessionSelection::kwt_workspace(
            host.id(),
            host.endpoint(),
            "main",
            KwtTmuxAttachMode::Direct,
            None,
            "/work/atlas",
            None,
        );
        let retained = SessionSelection::kwt_workspace(
            host.id(),
            host.endpoint(),
            "logs",
            KwtTmuxAttachMode::Direct,
            None,
            "/work/logs",
            None,
        );
        let rows = entries(&[host], Some(&active), &[retained], &preferences, true);
        let mut dialog = Dialog::new(&rows);
        for row in &rows {
            assert!(
                dialog.chosen(&rows).unwrap().title == row.title,
                "{} was skipped",
                row.title
            );
            dialog.move_selection(&rows, false);
        }
        assert!(dialog.chosen(&rows).unwrap().title == rows[0].title);
        for row in rows.iter().rev() {
            dialog.move_selection(&rows, true);
            assert!(
                dialog.chosen(&rows).unwrap().title == row.title,
                "{} was skipped",
                row.title
            );
        }
    }

    #[test]
    fn stopped_herdr_results_keep_the_restart_intent_when_inventory_changes() {
        for mut host in [
            HostItem::wsl("Linux", None, HostConnectionState::Ready, Vec::new(), None),
            HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
        ] {
            host = host.with_herdr_sessions(vec![workspace::HerdrSessionItem::new(
                "notes",
                false,
                HerdrSessionState::Stopped,
            )]);
            let rows = entries(
                std::slice::from_ref(&host),
                None,
                &[],
                &workspace::SidebarPreferences::default(),
                true,
            );
            let mut dialog = Dialog::new(&rows);
            dialog.set_query("notes".into(), &rows);
            let action = &dialog.chosen(&rows).unwrap().action;
            assert!(
                matches!(action, Action::RestartHerdr(selection) if selection.host_id() == host.id() && selection.session() == "notes")
            );
            host = host.with_herdr_sessions(vec![workspace::HerdrSessionItem::new(
                "notes",
                false,
                HerdrSessionState::Running,
            )]);
            let current = entries(
                &[host],
                None,
                &[],
                &workspace::SidebarPreferences::default(),
                true,
            );
            assert_eq!(matching(&current, "notes").len(), 1);
            assert!(dialog.chosen(&current).is_none());
            assert!(!current.iter().any(|row| &row.action == action));
        }
    }
}
