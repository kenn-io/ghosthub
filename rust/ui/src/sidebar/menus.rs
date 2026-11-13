use super::{
    APP_NAVIGATION_WIDTH, APP_TITLEBAR_HEIGHT, BackendLabel, Context, FluentBuilder,
    GpuiMouseButton, HostHeaderAction, HostItem, InteractiveElement, IntoElement, KeyDownEvent,
    NAVIGATION_HEADER_HEIGHT, NewSessionKind, ParentElement, RootView, SettingsPane,
    SidebarRowHeight, SidebarSort, StatefulInteractiveElement, Styled, Window, div,
    host_header_action, popup_position, px, rgb, session_creation_available, tooltip,
};

#[derive(Clone)]
pub(crate) enum SidebarMenu {
    Options,
    BackendLabel,
    RowHeight,
    Create(String),
    Host(String),
}

fn sort_title(sort: SidebarSort) -> &'static str {
    match sort {
        SidebarSort::Manual => "Manual",
        SidebarSort::Name => "Name",
        SidebarSort::Backend => "Backend",
        SidebarSort::Attention => "Needs Attention",
    }
}

pub(crate) const SORTS: [SidebarSort; 4] = [
    SidebarSort::Manual,
    SidebarSort::Name,
    SidebarSort::Backend,
    SidebarSort::Attention,
];
const LABELS: [(BackendLabel, &str); 3] = [
    (BackendLabel::Chip, "Chip"),
    (BackendLabel::Text, "Text"),
    (BackendLabel::Dot, "Dot"),
];
const HEIGHTS: [(SidebarRowHeight, &str); 2] = [
    (SidebarRowHeight::Regular, "Regular"),
    (SidebarRowHeight::Compact, "Compact"),
];
const BACKENDS: [NewSessionKind; 3] = [
    NewSessionKind::Tmux,
    NewSessionKind::Zellij,
    NewSessionKind::Herdr,
];

fn checked(title: &str, selected: bool) -> String {
    format!("{}{title}", if selected { "✓  " } else { "    " })
}

pub(super) fn options_icon(sort: SidebarSort) -> gpui::Div {
    let sorted = sort != SidebarSort::Manual;
    div()
        .size(px(28.0))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded_md()
        .child(
            div()
                .size(px(18.0))
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(2.5))
                .when(sorted, |el| el.rounded_full().bg(rgb(0x4a_8fcf)))
                .children([12.0, 8.0, 4.0].map(|width| {
                    div()
                        .w(px(width))
                        .h(px(1.5))
                        .rounded_full()
                        .bg(rgb(if sorted { 0xff_ffff } else { 0xad_b8c8 }))
                })),
        )
}

fn creation_reason(host: &HostItem, kind: NewSessionKind) -> Option<String> {
    if session_creation_available(host, kind) {
        return None;
    }
    if !host.accepts_session_actions() {
        return Some("Connect this host to create a session.".to_owned());
    }
    let diagnostic = match kind {
        NewSessionKind::Tmux => host.tmux_diagnostic(),
        NewSessionKind::Zellij => host.zellij_diagnostic(),
        NewSessionKind::Herdr => host.herdr_diagnostic(),
    };
    Some(diagnostic.map_or_else(
        || format!("{} is unavailable on this host.", creation_title(kind)),
        |error| error.message().to_owned(),
    ))
}

fn creation_title(kind: NewSessionKind) -> &'static str {
    match kind {
        NewSessionKind::Tmux => "tmux",
        NewSessionKind::Zellij => "Zellij",
        NewSessionKind::Herdr => "Herdr TUI",
    }
}

impl RootView {
    pub(crate) fn sidebar_options_button(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let sort = self.workspace.configured_sidebar().session_sort;
        let description = match sort {
            SidebarSort::Manual => "Manual order".to_owned(),
            _ => format!("Sorted by {}", sort_title(sort)),
        };
        let open = matches!(
            self.sidebar_menu,
            Some((
                SidebarMenu::Options | SidebarMenu::BackendLabel | SidebarMenu::RowHeight,
                _
            ))
        );
        options_icon(sort)
            .id("sidebar-options")
            .cursor_pointer()
            .hover(|style| style.bg(rgb(0x21_2732)))
            .when(open, |el| el.bg(rgb(0x21_2732)))
            .when(!open, |el| {
                el.tooltip(move |_, cx| tooltip(format!("Sidebar options · {description}"), cx))
            })
            .on_click(cx.listener(|this, _, window, cx| {
                let anchor = gpui::point(
                    px(APP_NAVIGATION_WIDTH - 8.0),
                    px(APP_TITLEBAR_HEIGHT + NAVIGATION_HEADER_HEIGHT),
                );
                this.open_sidebar_menu(SidebarMenu::Options, anchor, window, cx);
            }))
            .into_any_element()
    }

    pub(crate) fn host_create_button(host: &HostItem, cx: &mut Context<Self>) -> gpui::AnyElement {
        let host_id = host.id().to_owned();
        div()
            .id(gpui::SharedString::from(format!("create-on-{}", host.id())))
            .size(px(28.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded_md()
            .cursor_pointer()
            .text_color(rgb(0xad_b8c8))
            .child("+")
            .hover(|style| style.bg(rgb(0x25_2d39)))
            .tooltip(|_, cx| tooltip("New session or project".to_owned(), cx))
            .on_click(
                cx.listener(move |this, event: &gpui::ClickEvent, window, cx| {
                    this.open_sidebar_menu(
                        SidebarMenu::Create(host_id.clone()),
                        event.position(),
                        window,
                        cx,
                    );
                    cx.stop_propagation();
                }),
            )
            .into_any_element()
    }

    pub(crate) fn open_sidebar_menu(
        &mut self,
        menu: SidebarMenu,
        point: gpui::Point<gpui::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let preferences = self.workspace.configured_sidebar();
        self.sidebar_menu_index = match menu {
            SidebarMenu::Options => SORTS
                .iter()
                .position(|sort| *sort == preferences.session_sort),
            SidebarMenu::BackendLabel => LABELS
                .iter()
                .position(|(value, _)| *value == preferences.backend_label),
            SidebarMenu::RowHeight => HEIGHTS
                .iter()
                .position(|(value, _)| *value == preferences.row_height),
            SidebarMenu::Create(_) | SidebarMenu::Host(_) => None,
        }
        .unwrap_or(0);
        self.sidebar_menu = Some((menu, point));
        self.session_action_menu = None;
        window.focus(&self.sidebar_menu_focus);
        cx.notify();
    }

    fn choose_sidebar_menu(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some((menu, point)) = self.sidebar_menu.clone() else {
            return;
        };
        match menu {
            SidebarMenu::Host(host_id) => {
                let snapshot = self.workspace.snapshot();
                let Some(host) = snapshot.hosts().iter().find(|host| host.id() == host_id) else {
                    return;
                };
                if index != 0 {
                    return;
                }
                match host_header_action(host.connection()) {
                    HostHeaderAction::Cancel => self.cancel_host_connection(&host_id, cx),
                    HostHeaderAction::Connect
                    | HostHeaderAction::Refresh
                    | HostHeaderAction::Retry => self.connect_host(&host_id, cx),
                }
                window.focus(&self.focus);
            }
            SidebarMenu::Options if matches!(index, 4 | 5) => {
                let submenu = if index == 4 {
                    SidebarMenu::BackendLabel
                } else {
                    SidebarMenu::RowHeight
                };
                self.open_sidebar_menu(submenu, point, window, cx);
                return;
            }
            SidebarMenu::Options if index == 8 => {
                self.open_settings(window, cx);
                if let Some(dialog) = &mut self.settings_dialog {
                    dialog.pane = SettingsPane::Sidebar;
                    dialog.sidebar_focus = Some(SettingsPane::Sidebar);
                }
            }
            SidebarMenu::Options => {
                if let Err(error) = self.workspace.update_sidebar(|preferences| match index {
                    0..=3 => preferences.session_sort = SORTS[index],
                    6 => preferences.hide_worktree_sessions = !preferences.hide_worktree_sessions,
                    7 => preferences.hide_root_checkout = !preferences.hide_root_checkout,
                    _ => {}
                }) {
                    self.diagnostic = Some(error.to_string());
                }
                window.focus(&self.focus);
            }
            SidebarMenu::BackendLabel | SidebarMenu::RowHeight => {
                if let Err(error) = self.workspace.update_sidebar(|preferences| match menu {
                    SidebarMenu::BackendLabel => {
                        if let Some((value, _)) = LABELS.get(index) {
                            preferences.backend_label = *value;
                        }
                    }
                    SidebarMenu::RowHeight => {
                        if let Some((value, _)) = HEIGHTS.get(index) {
                            preferences.row_height = *value;
                        }
                    }
                    _ => {}
                }) {
                    self.diagnostic = Some(error.to_string());
                }
                window.focus(&self.focus);
            }
            SidebarMenu::Create(host_id) => {
                let snapshot = self.workspace.snapshot();
                let Some(host) = snapshot.hosts().iter().find(|host| host.id() == host_id) else {
                    return;
                };
                if let Some(kind) = BACKENDS.get(index) {
                    if creation_reason(host, *kind).is_some() {
                        return;
                    }
                    self.open_new_session(&host_id, host.endpoint(), *kind, window, cx);
                } else if index == BACKENDS.len() && host.can_add_kwt_project() {
                    self.open_add_project(&host_id, host.endpoint(), window, cx);
                } else {
                    return;
                }
            }
        }
        self.sidebar_menu = None;
        cx.notify();
    }

    fn parent_sidebar_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((menu, point)) = self.sidebar_menu.clone() else {
            return;
        };
        let index = match menu {
            SidebarMenu::BackendLabel => 4,
            SidebarMenu::RowHeight => 5,
            _ => return,
        };
        self.open_sidebar_menu(SidebarMenu::Options, point, window, cx);
        self.sidebar_menu_index = index;
    }

    #[allow(clippy::too_many_lines)] // Menu items and their focus behavior stay in visual order.
    pub(crate) fn sidebar_menu_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let (menu, point) = self.sidebar_menu.as_ref()?;
        let snapshot = self.workspace.snapshot();
        let preferences = self.workspace.configured_sidebar();
        let options: Vec<(String, Option<String>)> = match menu {
            SidebarMenu::Host(id) => {
                let host = snapshot.hosts().iter().find(|host| host.id() == id)?;
                let action = host_header_action(host.connection());
                let title = match action {
                    HostHeaderAction::Refresh => "Refresh",
                    HostHeaderAction::Cancel => "Cancel Connection",
                    _ => action.label(),
                };
                vec![(title.to_owned(), None)]
            }
            SidebarMenu::Options => SORTS
                .iter()
                .map(|sort| {
                    (
                        checked(sort_title(*sort), *sort == preferences.session_sort),
                        None,
                    )
                })
                .chain([
                    ("Backend Label".to_owned(), None),
                    ("Row Height".to_owned(), None),
                    (
                        checked("Hide Worktree Sessions", preferences.hide_worktree_sessions),
                        None,
                    ),
                    (
                        checked("Hide Root Checkout", preferences.hide_root_checkout),
                        None,
                    ),
                    ("Sidebar Settings…".to_owned(), None),
                ])
                .collect(),
            SidebarMenu::BackendLabel => LABELS
                .iter()
                .map(|(value, title)| (checked(title, *value == preferences.backend_label), None))
                .collect(),
            SidebarMenu::RowHeight => HEIGHTS
                .iter()
                .map(|(value, title)| (checked(title, *value == preferences.row_height), None))
                .collect(),
            SidebarMenu::Create(id) => {
                let host = snapshot.hosts().iter().find(|host| host.id() == id)?;
                let mut options: Vec<_> = BACKENDS
                    .iter()
                    .map(|kind| {
                        (
                            format!("New {} session", creation_title(*kind)),
                            creation_reason(host, *kind),
                        )
                    })
                    .collect();
                let reason = if host.can_add_kwt_project() {
                    None
                } else if !host.accepts_session_actions() {
                    Some("Connect this host to add a project.".to_owned())
                } else if host.kwt_mutating() {
                    Some("Wait for the current project operation to finish.".to_owned())
                } else {
                    Some("KWT is unavailable on this host.".to_owned())
                };
                options.push(("Add Project…".to_owned(), reason));
                options
            }
        };
        let count = options.len();
        let is_options = matches!(menu, SidebarMenu::Options);
        let heading = match menu {
            SidebarMenu::Options => Some("Sort Sessions By"),
            SidebarMenu::BackendLabel => Some("‹  Backend Label"),
            SidebarMenu::RowHeight => Some("‹  Row Height"),
            _ => None,
        };
        let (left, top) = popup_position(
            point.x.into(),
            point.y.into(),
            window.bounds().size.width.into(),
            window.bounds().size.height.into(),
            224.0,
            8.0 + 30.0 * f32::from(u16::try_from(count).expect("sidebar menu size"))
                + if heading.is_some() { 28.0 } else { 0.0 }
                + if is_options { 27.0 } else { 0.0 },
        );
        let mut items = div()
            .id("sidebar-menu")
            .track_focus(&self.sidebar_menu_focus)
            .absolute()
            .left(px(left))
            .top(px(top))
            .w(px(224.0))
            .p_1()
            .rounded_md()
            .border_1()
            .border_color(rgb(0x36_3c48))
            .bg(rgb(0x1b_1f27))
            .shadow_lg()
            .on_mouse_down(GpuiMouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
                match event.keystroke.key.as_str() {
                    "escape" => {
                        this.sidebar_menu = None;
                        window.focus(&this.focus);
                    }
                    "up" => this.sidebar_menu_index = (this.sidebar_menu_index + count - 1) % count,
                    "down" | "tab" => {
                        this.sidebar_menu_index = (this.sidebar_menu_index + 1) % count;
                    }
                    "enter" | "space" => {
                        this.choose_sidebar_menu(this.sidebar_menu_index, window, cx);
                    }
                    "right" if is_options && matches!(this.sidebar_menu_index, 4 | 5) => {
                        this.choose_sidebar_menu(this.sidebar_menu_index, window, cx);
                    }
                    "left" => this.parent_sidebar_menu(window, cx),
                    _ => {}
                }
                cx.stop_propagation();
                cx.notify();
            }));
        if let Some(heading) = heading {
            items = items.child(
                div()
                    .id("sidebar-menu-heading")
                    .h(px(28.0))
                    .px_2()
                    .flex()
                    .items_center()
                    .text_size(px(11.0))
                    .text_color(rgb(0x8a_96a8))
                    .when(!is_options, |el| {
                        el.cursor_pointer()
                            .hover(|style| style.bg(rgb(0x29_3342)))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.parent_sidebar_menu(window, cx);
                            }))
                    })
                    .child(heading),
            );
        }
        for (index, (title, reason)) in options.into_iter().enumerate() {
            if is_options && matches!(index, 4 | 6 | 8) {
                items = items.child(div().h(px(1.0)).my_1().bg(rgb(0x36_3c48)));
            }
            items = items.child(
                div()
                    .id(("sidebar-menu-option", index))
                    .h(px(30.0))
                    .px_2()
                    .rounded_sm()
                    .flex()
                    .items_center()
                    .text_sm()
                    .text_color(rgb(if reason.is_some() {
                        0x70_7886
                    } else {
                        0xd4_dae4
                    }))
                    .when(index == self.sidebar_menu_index, |el| el.bg(rgb(0x29_3342)))
                    .when(reason.is_none(), |el| {
                        el.cursor_pointer()
                            .hover(|style| style.bg(rgb(0x29_3342)))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.choose_sidebar_menu(index, window, cx);
                            }))
                    })
                    .when_some(reason, |el, reason| {
                        el.tooltip(move |_, cx| tooltip(reason.clone(), cx))
                    })
                    .child(div().flex_1().child(title))
                    .when(is_options && matches!(index, 4 | 5), |el| el.child("›")),
            );
        }
        Some(
            div()
                .occlude()
                .absolute()
                .inset_0()
                .on_mouse_down(
                    GpuiMouseButton::Left,
                    cx.listener(|this, _, window, cx| {
                        this.sidebar_menu = None;
                        window.focus(&this.focus);
                        cx.notify();
                    }),
                )
                .child(items)
                .into_any_element(),
        )
    }
}
