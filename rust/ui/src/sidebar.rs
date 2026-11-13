use super::*;
use workspace::{BackendLabel, SidebarPreferences, SidebarRowHeight, SidebarSort};

#[derive(Clone)]
pub(super) enum SidebarSession {
    Session(TreeSession),
    Herdr(TreeHerdrSession),
}

impl SidebarSession {
    fn title(&self) -> String {
        let show_endpoint = match self {
            Self::Session(row) => row.show_endpoint,
            Self::Herdr(row) => row.show_endpoint,
        };
        let selection = self.selection();
        if show_endpoint {
            format!("{} · {}", selection.session(), selection.endpoint())
        } else {
            selection.session().to_owned()
        }
    }

    fn selection(&self) -> &SessionSelection {
        match self {
            Self::Session(row) => &row.selection,
            Self::Herdr(row) => &row.selection,
        }
    }

    fn action_selection(&self) -> &SessionSelection {
        match self {
            Self::Session(row) => &row.kill_selection,
            Self::Herdr(row) => &row.selection,
        }
    }

    fn stopped(&self) -> bool {
        matches!(self, Self::Herdr(row) if row.inventory.as_ref().is_some_and(|item| item.state() == HerdrSessionState::Stopped))
    }

    fn active(&self) -> bool {
        match self {
            Self::Session(row) => row.state.is_active(),
            Self::Herdr(row) => row.active,
        }
    }

    fn can_navigate(&self) -> bool {
        match self {
            Self::Session(row) => row.state.can_open(),
            Self::Herdr(row) => {
                !self.stopped()
                    && row.access.can_open()
                    && row
                        .inventory
                        .as_ref()
                        .and_then(herdr_operation_label)
                        .is_none()
            }
        }
    }

    fn activity(&self) -> Option<&workspace::AgentActivity> {
        match self {
            Self::Session(row) => row.agent_activity.as_ref(),
            Self::Herdr(_) => None,
        }
    }

    fn attention_rank(&self) -> u8 {
        match self.activity().map(workspace::AgentActivity::state) {
            Some(workspace::AgentState::Approval | workspace::AgentState::Input) => 0,
            Some(workspace::AgentState::Working) => 1,
            None => 2,
        }
    }

    fn actions(&self, host: &HostItem) -> Vec<SessionRowAction> {
        match self {
            Self::Session(row) => {
                let mut actions = tmux_row_actions(row.state.is_active(), row.state.can_kill());
                if workspace::can_rename_session(host, &row.selection) {
                    actions.insert(usize::from(row.state.is_active()), SessionRowAction::Rename);
                }
                actions
            }
            Self::Herdr(row) => herdr_session_menu_actions(
                row.active,
                row.inventory.as_ref().map_or_else(Vec::new, |item| {
                    available_herdr_row_actions(row.access, item)
                }),
            ),
        }
    }
}

use workspace::session_order_id as order_id;

fn backend_rank(kind: workspace::SessionKind) -> u8 {
    match kind {
        workspace::SessionKind::Tmux => 0,
        workspace::SessionKind::Zellij => 1,
        workspace::SessionKind::Herdr => 2,
    }
}

fn compare_names(left: &str, right: &str) -> std::cmp::Ordering {
    let left = left.to_lowercase();
    let right = right.to_lowercase();
    let mut left = left.chars().peekable();
    let mut right = right.chars().peekable();
    loop {
        if left.peek().is_some_and(char::is_ascii_digit)
            && right.peek().is_some_and(char::is_ascii_digit)
        {
            let mut left_digits = String::new();
            let mut right_digits = String::new();
            while left.peek().is_some_and(char::is_ascii_digit) {
                left_digits.push(left.next().expect("digit"));
            }
            while right.peek().is_some_and(char::is_ascii_digit) {
                right_digits.push(right.next().expect("digit"));
            }
            let left_digits = left_digits.trim_start_matches('0');
            let right_digits = right_digits.trim_start_matches('0');
            let order = left_digits
                .len()
                .cmp(&right_digits.len())
                .then_with(|| left_digits.cmp(right_digits));
            if !order.is_eq() {
                return order;
            }
        } else {
            let pair = (left.next(), right.next());
            match pair {
                (None, None) => return std::cmp::Ordering::Equal,
                (left, right) if left != right => return left.cmp(&right),
                _ => {}
            }
        }
    }
}

pub(super) fn sessions(
    host: &HostItem,
    active: Option<&SessionSelection>,
    retained: &[SessionSelection],
    preferences: &SidebarPreferences,
) -> Vec<SidebarSession> {
    let mut rows: Vec<_> =
        tree_sessions(host, active, retained, preferences.hide_worktree_sessions)
            .into_iter()
            .filter(|row| !preferences.hides_tmux_session(row.selection.session()))
            .chain(tree_zellij_sessions(host, active, retained))
            .map(SidebarSession::Session)
            .chain(
                tree_herdr_sessions(host, active, retained)
                    .into_iter()
                    .map(SidebarSession::Herdr),
            )
            .collect();
    rows.sort_by(|left, right| {
        backend_rank(left.selection().kind())
            .cmp(&backend_rank(right.selection().kind()))
            .then_with(|| compare_names(left.selection().session(), right.selection().session()))
            .then_with(|| order_id(left.selection()).cmp(&order_id(right.selection())))
    });
    match preferences.session_sort {
        SidebarSort::Backend => {}
        SidebarSort::Name => {
            rows.sort_by(|left, right| {
                compare_names(left.selection().session(), right.selection().session())
            });
        }
        SidebarSort::Manual | SidebarSort::Attention => {
            let positions: HashMap<_, _> = preferences
                .session_order
                .iter()
                .enumerate()
                .map(|(index, key)| (key, index))
                .collect();
            rows.sort_by_cached_key(|row| {
                positions
                    .get(&order_id(row.selection()))
                    .copied()
                    .unwrap_or(usize::MAX)
            });
        }
    }
    if preferences.session_sort == SidebarSort::Attention {
        rows.sort_by_key(SidebarSession::attention_rank);
    }
    rows.sort_by_key(SidebarSession::stopped);
    rows
}

fn move_session(
    preferences: &mut SidebarPreferences,
    rows: &[SidebarSession],
    source: &str,
    target: &str,
) {
    if preferences.session_sort != SidebarSort::Manual || source == target {
        return;
    }
    let mut ids: Vec<_> = rows.iter().map(|row| order_id(row.selection())).collect();
    let (Some(from), Some(to)) = (
        ids.iter().position(|id| id == source),
        ids.iter().position(|id| id == target),
    ) else {
        return;
    };
    let moved = ids.remove(from);
    ids.insert(to, moved);
    let group: HashSet<_> = ids.iter().cloned().collect();
    preferences.session_order.retain(|id| !group.contains(id));
    preferences.session_order.extend(ids);
}

pub(super) fn row_height(preferences: &SidebarPreferences) -> f32 {
    match preferences.row_height {
        SidebarRowHeight::Regular => 28.0,
        SidebarRowHeight::Compact => 24.0,
    }
}

fn backend_label(kind: workspace::SessionKind) -> &'static str {
    match kind {
        workspace::SessionKind::Tmux => "tmux",
        workspace::SessionKind::Zellij => "zellij",
        workspace::SessionKind::Herdr => "herdr tui",
    }
}

fn backend_tint(kind: workspace::SessionKind) -> u32 {
    match kind {
        workspace::SessionKind::Tmux => 0x54_c4bd,
        workspace::SessionKind::Zellij => 0xd9_b552,
        workspace::SessionKind::Herdr => 0x85_a3f2,
    }
}

fn label(kind: workspace::SessionKind, style: BackendLabel) -> gpui::AnyElement {
    let color = backend_tint(kind);
    if style == BackendLabel::Dot {
        return div()
            .size(px(6.0))
            .flex_none()
            .rounded_full()
            .bg(rgb(color))
            .into_any_element();
    }
    div()
        .flex_none()
        .text_size(px(10.0))
        .font_family(UI_MONOSPACE_FONT)
        .text_color(rgb(color))
        .px(px(5.0))
        .py(px(2.0))
        .rounded(px(4.0))
        .when(style == BackendLabel::Chip, |el| {
            el.bg(rgba((color << 8) | 0x1f))
        })
        .child(backend_label(kind))
        .into_any_element()
}

pub(super) fn activity_badge(activity: &workspace::AgentActivity) -> gpui::Div {
    let color = match activity.state() {
        workspace::AgentState::Approval => 0xe8_ad66,
        workspace::AgentState::Input => 0xc0_9be8,
        workspace::AgentState::Working => 0x79_c9a3,
    };
    div()
        .flex_none()
        .flex()
        .items_center()
        .gap(px(3.0))
        .text_size(px(10.0))
        .font_weight(gpui::FontWeight::SEMIBOLD)
        .text_color(rgb(color))
        .child(div().size(px(5.0)).rounded_full().bg(rgb(color)))
        .child(activity.title())
}

fn content(row: &SidebarSession, preferences: &SidebarPreferences) -> gpui::AnyElement {
    let selection = row.selection();
    let mut body = div()
        .flex_1()
        .min_w_0()
        .flex()
        .items_center()
        .gap(px(6.0))
        .when(preferences.backend_label == BackendLabel::Dot, |el| {
            el.child(label(selection.kind(), BackendLabel::Dot))
        })
        .child(
            div()
                .min_w_0()
                .flex_1()
                .truncate()
                .text_size(px(13.0))
                .text_color(rgb(if row.stopped() { 0x84_8c9a } else { 0xd4_dae4 }))
                .child(row.title()),
        );
    if row.stopped() {
        body = body.child(
            div()
                .text_size(px(11.0))
                .text_color(rgb(0x84_8c9a))
                .child("stopped"),
        );
    }
    if let SidebarSession::Herdr(row) = row
        && let Some(operation) = row.inventory.as_ref().and_then(herdr_operation_label)
    {
        body = body.child(
            div()
                .text_size(px(11.0))
                .text_color(rgb(0x84_8c9a))
                .child(operation),
        );
    }
    if let Some(activity) = row.activity() {
        body = body.child(activity_badge(activity));
    }
    body.when(preferences.backend_label != BackendLabel::Dot, |el| {
        el.child(label(selection.kind(), preferences.backend_label))
    })
    .pr(px(14.0))
    .into_any_element()
}

#[derive(Clone)]
struct SessionDrag {
    selection: SessionSelection,
}

impl Render for SessionDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .when(cfg!(target_os = "linux"), |el| el.font_family("Inter"))
            .px_3()
            .py_1()
            .rounded_md()
            .bg(rgb(0x25_2d3a))
            .text_color(rgb(0xe1_e5ec))
            .text_sm()
            .child(self.selection.session().to_owned())
    }
}

struct SidebarTooltip(String);
impl Render for SidebarTooltip {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .when(cfg!(target_os = "linux"), |el| el.font_family("Inter"))
            .max_w(px(360.0))
            .px_2()
            .py_1()
            .rounded_md()
            .bg(rgb(0x25_2d3a))
            .text_color(rgb(0xe1_e5ec))
            .text_xs()
            .child(self.0.clone())
    }
}

pub(super) fn tooltip(text: String, cx: &mut App) -> gpui::AnyView {
    cx.new(|_| SidebarTooltip(text)).into()
}

impl RootView {
    #[allow(clippy::too_many_lines)] // One row keeps its click, drag and action targets together.
    pub(super) fn flat_session_row(
        row: &SidebarSession,
        host: &HostItem,
        preferences: &SidebarPreferences,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let selection = row.selection().clone();
        let group = format!("session-{}", order_id(&selection));
        let actions = row.actions(host);
        let interactive = row.can_navigate()
            || matches!(row, SidebarSession::Herdr(item) if row.stopped() && item.access.can_restart() && item.inventory.as_ref().and_then(herdr_operation_label).is_none());
        let stopped = row.stopped();
        let mut hint = format!(
            "{} · {} · {}",
            backend_label(selection.kind()),
            selection.session(),
            selection.endpoint()
        );
        if let Some(socket) = selection.tmux_socket_name() {
            hint.push_str(" · ");
            hint.push_str(socket);
        }
        if let Some(activity) = row.activity() {
            hint.push_str(" · ");
            hint.push_str(&activity.label());
        }
        let mut element = div()
            .id(gpui::SharedString::from(order_id(&selection)))
            .group(group.clone())
            .relative()
            .mx_1()
            .h(px(row_height(preferences)))
            .px_2()
            .flex()
            .items_center()
            .rounded(px(5.0))
            .bg(rgb(if row.active() {
                0x20_3349
            } else {
                APP_CHROME_BACKGROUND
            }))
            .when(interactive, |el| {
                el.cursor_pointer()
                    .hover(|style| style.bg(rgb(if row.active() { 0x26_3e58 } else { 0x1b_2029 })))
            })
            .when(!interactive, |el| el.opacity(0.55))
            .tooltip(move |_, cx| tooltip(hint.clone(), cx))
            .child(content(row, preferences));
        if !actions.is_empty() {
            let action_selection = row.action_selection().clone();
            let context_selection = action_selection.clone();
            let context_actions = actions.clone();
            element = element
                .on_mouse_down(
                    GpuiMouseButton::Right,
                    cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                        this.open_session_action_menu(
                            context_selection.clone(),
                            context_actions.clone(),
                            event.position,
                            window,
                            cx,
                        );
                    }),
                )
                .child(
                    div().absolute().right(px(2.0)).child(
                        Self::session_action_menu_button(
                            0,
                            order_id(&selection),
                            action_selection,
                            actions,
                            group,
                            cx,
                        )
                        .w(px(20.0))
                        .h(px(row_height(preferences)))
                        .when(row.active(), |el| el.opacity(1.0)),
                    ),
                );
        }
        if preferences.session_sort == SidebarSort::Manual {
            let target = selection.clone();
            element = element
                .on_drag(
                    SessionDrag {
                        selection: selection.clone(),
                    },
                    |drag, _, _, cx| cx.new(|_| drag.clone()),
                )
                .drag_over::<SessionDrag>(|style, _, _, _| style.bg(rgb(0x2b_4563)))
                .on_drop(cx.listener(move |this, drag: &SessionDrag, _, cx| {
                    if drag.selection.host_id() != target.host_id() {
                        return;
                    }
                    let snapshot = this.workspace.snapshot();
                    let Some(host) = snapshot
                        .hosts()
                        .iter()
                        .find(|host| host.id() == target.host_id())
                    else {
                        return;
                    };
                    let result = this.workspace.update_sidebar(|preferences| {
                        let rows = sessions(
                            host,
                            snapshot.active_selection(),
                            snapshot.retained_selections(),
                            preferences,
                        );
                        move_session(
                            preferences,
                            &rows,
                            &order_id(&drag.selection),
                            &order_id(&target),
                        );
                    });
                    if let Err(error) = result {
                        this.diagnostic = Some(error.to_string());
                    }
                    cx.notify();
                }));
        }
        element
            .when(interactive, |el| {
                el.on_click(cx.listener(move |this, _, window, cx| {
                    if stopped {
                        this.restart_herdr_session(&selection, window, cx);
                    } else {
                        this.select_session(&selection, window, cx);
                    }
                }))
            })
            .into_any_element()
    }

    pub(super) fn cycle_session(
        &mut self,
        backwards: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(selection) = self.session_navigation_target(backwards) {
            self.select_session(&selection, window, cx);
        }
    }

    pub(super) fn session_navigation_target(&self, backwards: bool) -> Option<SessionSelection> {
        if self.settings_dialog.is_some()
            || self.new_session.is_some()
            || self.project_dialog.is_some()
            || self.sidebar_menu.is_some()
            || self.session_action_menu.is_some()
            || !self.ssh_prompts.is_empty()
            || self.workspace.session_kill_confirmation().is_some()
            || self.workspace.herdr_lifecycle_confirmation().is_some()
        {
            return None;
        }
        let snapshot = self.workspace.snapshot();
        let active = snapshot
            .active_selection()
            .cloned()
            .or_else(|| active_session_selection(snapshot.content()));
        let host_id = active
            .as_ref()
            .map(SessionSelection::host_id)
            .or(snapshot.selected_host());
        let host = snapshot
            .hosts()
            .iter()
            .find(|host| Some(host.id()) == host_id)?;
        let rows = sessions(
            host,
            active.as_ref(),
            snapshot.retained_selections(),
            &self.workspace.configured_sidebar(),
        );
        adjacent_session(&rows, active.as_ref(), backwards)
    }
}

fn adjacent_session(
    rows: &[SidebarSession],
    active: Option<&SessionSelection>,
    backwards: bool,
) -> Option<SessionSelection> {
    let available: Vec<_> = rows.iter().filter(|row| row.can_navigate()).collect();
    let Some(index) = available
        .iter()
        .position(|row| Some(row.selection()) == active)
    else {
        return if backwards {
            available.last()
        } else {
            available.first()
        }
        .map(|row| row.selection().clone());
    };
    if available.len() == 1 {
        return None;
    }
    let next = if backwards {
        (index + available.len() - 1) % available.len()
    } else {
        (index + 1) % available.len()
    };
    Some(available[next].selection().clone())
}

pub(super) mod menus;
pub(super) mod settings;
#[cfg(test)]
mod tests;
