use super::{
    Context, FluentBuilder, GpuiMouseButton, HostItem, InteractiveElement, IntoElement,
    KeyDownEvent, NewSessionKind, ParentElement, RootView, SidebarSort, StatefulInteractiveElement,
    Styled, Window, div, popup_position, px, rgb, session_creation_available, tooltip,
};

#[derive(Clone)]
pub(crate) enum SidebarMenu {
    Sort,
    Create(String),
}

pub(crate) fn sort_title(sort: SidebarSort) -> &'static str {
    match sort {
        SidebarSort::Manual => "Manual",
        SidebarSort::Name => "Name",
        SidebarSort::Backend => "Backend",
    }
}

pub(crate) const SORTS: [SidebarSort; 3] =
    [SidebarSort::Manual, SidebarSort::Name, SidebarSort::Backend];
const BACKENDS: [NewSessionKind; 3] = [
    NewSessionKind::Tmux,
    NewSessionKind::Zellij,
    NewSessionKind::Herdr,
];

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
    pub(crate) fn sidebar_sort_button(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        div()
            .id("sidebar-sort")
            .h(px(28.0))
            .px_2()
            .flex()
            .items_center()
            .gap_1()
            .rounded_md()
            .text_size(px(11.0))
            .text_color(rgb(0x9c_a7b8))
            .cursor_pointer()
            .hover(|style| style.bg(rgb(0x21_2732)))
            .child("↕")
            .child(sort_title(self.workspace.configured_sidebar().session_sort))
            .tooltip(|_, cx| tooltip("Sort sessions".to_owned(), cx))
            .on_click(cx.listener(|this, event: &gpui::ClickEvent, window, cx| {
                this.open_sidebar_menu(SidebarMenu::Sort, event.position(), window, cx);
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
            .opacity(0.0)
            .group_hover(format!("host-{}", host.id()), |style| style.opacity(1.0))
            .hover(|style| style.bg(rgb(0x25_2d39)))
            .tooltip(|_, cx| tooltip("New session".to_owned(), cx))
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

    fn open_sidebar_menu(
        &mut self,
        menu: SidebarMenu,
        point: gpui::Point<gpui::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sidebar_menu = Some((menu, point));
        self.sidebar_menu_index = 0;
        self.session_action_menu = None;
        window.focus(&self.sidebar_menu_focus);
        cx.notify();
    }

    fn choose_sidebar_menu(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some((menu, _)) = self.sidebar_menu.clone() else {
            return;
        };
        match menu {
            SidebarMenu::Sort => {
                if let Some(sort) = SORTS.get(index)
                    && let Err(error) = self
                        .workspace
                        .update_sidebar(|preferences| preferences.session_sort = *sort)
                {
                    self.diagnostic = Some(error.to_string());
                }
                window.focus(&self.focus);
            }
            SidebarMenu::Create(host_id) => {
                let snapshot = self.workspace.snapshot();
                let Some(host) = snapshot.hosts().iter().find(|host| host.id() == host_id) else {
                    return;
                };
                let Some(kind) = BACKENDS.get(index) else {
                    return;
                };
                if creation_reason(host, *kind).is_some() {
                    return;
                }
                self.open_new_session(&host_id, host.endpoint(), *kind, window, cx);
            }
        }
        self.sidebar_menu = None;
        cx.notify();
    }

    #[allow(clippy::too_many_lines)] // Menu items and their focus behavior stay in visual order.
    pub(crate) fn sidebar_menu_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let (menu, point) = self.sidebar_menu.as_ref()?;
        let snapshot = self.workspace.snapshot();
        let options: Vec<(String, Option<String>)> = match menu {
            SidebarMenu::Sort => SORTS
                .iter()
                .map(|sort| {
                    (
                        format!(
                            "{}{}",
                            if *sort == self.workspace.configured_sidebar().session_sort {
                                "✓  "
                            } else {
                                "    "
                            },
                            sort_title(*sort)
                        ),
                        None,
                    )
                })
                .collect(),
            SidebarMenu::Create(id) => {
                let host = snapshot.hosts().iter().find(|host| host.id() == id)?;
                BACKENDS
                    .iter()
                    .map(|kind| {
                        (
                            format!("New {} session", creation_title(*kind)),
                            creation_reason(host, *kind),
                        )
                    })
                    .collect()
            }
        };
        let (left, top) = popup_position(
            point.x.into(),
            point.y.into(),
            window.bounds().size.width.into(),
            window.bounds().size.height.into(),
            224.0,
            98.0,
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
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                match event.keystroke.key.as_str() {
                    "escape" => {
                        this.sidebar_menu = None;
                        window.focus(&this.focus);
                    }
                    "up" => this.sidebar_menu_index = (this.sidebar_menu_index + 2) % 3,
                    "down" | "tab" => this.sidebar_menu_index = (this.sidebar_menu_index + 1) % 3,
                    "enter" | "space" => {
                        this.choose_sidebar_menu(this.sidebar_menu_index, window, cx);
                    }
                    _ => {}
                }
                cx.stop_propagation();
                cx.notify();
            }));
        for (index, (title, reason)) in options.into_iter().enumerate() {
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
                    .child(title),
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
