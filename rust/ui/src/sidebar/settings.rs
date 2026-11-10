use super::menus::{SORTS, sort_title};
use super::*;

pub(crate) const FIELD_COUNT: usize = 5;

fn choices(field: usize) -> &'static [&'static str] {
    match field {
        0 => &["Chip", "Text", "Dot"],
        1 => &["Regular", "Compact"],
        2 => &["Manual", "Name", "Backend"],
        _ => &["Off", "On"],
    }
}

fn selected(preferences: &SidebarPreferences, field: usize) -> usize {
    match field {
        0 => match preferences.backend_label {
            BackendLabel::Chip => 0,
            BackendLabel::Text => 1,
            BackendLabel::Dot => 2,
        },
        1 => usize::from(preferences.row_height == SidebarRowHeight::Compact),
        2 => SORTS
            .iter()
            .position(|sort| *sort == preferences.session_sort)
            .unwrap_or(0),
        3 => usize::from(preferences.hide_worktree_sessions),
        _ => usize::from(preferences.hide_root_checkout),
    }
}

fn choose(preferences: &mut SidebarPreferences, field: usize, value: usize) {
    match field {
        0 => {
            preferences.backend_label =
                [BackendLabel::Chip, BackendLabel::Text, BackendLabel::Dot][value];
        }
        1 => {
            preferences.row_height = if value == 0 {
                SidebarRowHeight::Regular
            } else {
                SidebarRowHeight::Compact
            }
        }
        2 => preferences.session_sort = SORTS[value],
        3 => preferences.hide_worktree_sessions = value != 0,
        _ => preferences.hide_root_checkout = value != 0,
    }
}

pub(super) fn sample_host() -> HostItem {
    HostItem::ssh(
        "preview",
        "Studio",
        "studio.example",
        HostConnectionState::Ready,
        vec![
            workspace::SessionItem::new("build", 0),
            workspace::SessionItem::new("atlas/main", 0),
        ],
        None,
    )
    .with_zellij_sessions(vec![workspace::SessionItem::new("design", 0)])
    .with_herdr_sessions(vec![
        workspace::HerdrSessionItem::new("review", false, HerdrSessionState::Running),
        workspace::HerdrSessionItem::new("notes", false, HerdrSessionState::Stopped),
    ])
    .with_kwt_inventory(
        vec![workspace::ProjectItem::new(
            "example/atlas",
            "Atlas",
            "/projects/atlas",
            "preview",
            vec![
                workspace::WorktreeItem::new(
                    "/projects/atlas",
                    "main",
                    true,
                    None,
                    "atlas/main",
                    (None, KwtTmuxAttachMode::Direct),
                    true,
                ),
                workspace::WorktreeItem::new(
                    "/projects/atlas-theme",
                    "feature/theme",
                    false,
                    None,
                    "atlas/theme",
                    (None, KwtTmuxAttachMode::Direct),
                    false,
                ),
            ],
        )],
        Vec::new(),
    )
}

impl RootView {
    fn choose_sidebar_setting(&mut self, field: usize, value: usize, cx: &mut Context<Self>) {
        let result = self
            .workspace
            .update_sidebar(|preferences| choose(preferences, field, value));
        if let Some(dialog) = &mut self.settings_dialog {
            dialog.sidebar_field = field;
            dialog.sidebar_focus = None;
            dialog.error = result.err().map(|error| error.to_string());
        }
        self.sidebar_preview_revision = self.sidebar_preview_revision.wrapping_add(1);
        cx.notify();
    }

    pub(crate) fn edit_sidebar_setting(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        let Some(dialog) = &self.settings_dialog else {
            return;
        };
        let key = event.keystroke.key.as_str();
        if matches!(key, "left" | "right" | "up" | "down" | "space" | "enter") {
            let field = dialog.sidebar_field;
            let count = choices(field).len();
            let current = selected(&self.workspace.configured_sidebar(), field);
            let next = (current
                + if matches!(key, "left" | "up") {
                    count - 1
                } else {
                    1
                })
                % count;
            self.choose_sidebar_setting(field, next, cx);
        }
        cx.stop_propagation();
    }

    #[allow(clippy::too_many_lines)] // Controls share one focus order and persistence path.
    pub(crate) fn settings_sidebar_editor(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let preferences = self.workspace.configured_sidebar();
        let mut controls = div()
            .flex_1()
            .min_w(px(360.0))
            .pt_2()
            .flex()
            .flex_col()
            .gap_5();
        for (field, title) in [
            "Backend label",
            "Row height",
            "Sort sessions by",
            "Hide sessions that belong to a worktree",
            "Hide the root checkout",
        ]
        .into_iter()
        .enumerate()
        {
            let focused = self.settings_dialog.as_ref().is_some_and(|dialog| {
                dialog.sidebar_focus.is_none() && dialog.sidebar_field == field
            });
            let current = selected(&preferences, field);
            let mut options = div()
                .flex_none()
                .flex()
                .p(px(3.0))
                .gap(px(3.0))
                .rounded_md()
                .bg(rgb(0x10_141b))
                .border_1()
                .border_color(rgb(if focused { 0x4a_8fcf } else { 0x2c_3441 }));
            for (index, title) in choices(field).iter().enumerate() {
                options = options.child(
                    div()
                        .id(gpui::SharedString::from(format!(
                            "sidebar-setting-{field}-{index}"
                        )))
                        .h(px(28.0))
                        .px_3()
                        .flex()
                        .items_center()
                        .rounded(px(4.0))
                        .cursor_pointer()
                        .text_size(px(12.0))
                        .bg(rgb(if index == current {
                            0x2c_3a4e
                        } else {
                            0x10_141b
                        }))
                        .text_color(rgb(if index == current {
                            0xe4_ebf5
                        } else {
                            0x97_a3b5
                        }))
                        .hover(|style| style.bg(rgb(0x28_3344)))
                        .child(*title)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.choose_sidebar_setting(field, index, cx);
                            window.focus(&this.settings_focus);
                        })),
                );
            }
            controls = controls.child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_4()
                    .child(
                        div()
                            .min_w_0()
                            .text_size(px(13.0))
                            .text_color(rgb(0xcd_d5e2))
                            .child(title),
                    )
                    .child(options),
            );
        }
        if let Some(error) = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.error.clone())
        {
            controls = controls.child(div().text_sm().text_color(rgb(0xe7_969b)).child(error));
        }
        div()
            .id("sidebar-settings-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p_6()
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_start()
                    .gap_6()
                    .child(self.sidebar_preview(&preferences))
                    .child(controls),
            )
            .into_any_element()
    }

    #[allow(clippy::too_many_lines)] // Declarative sample composed from the production row content.
    fn sidebar_preview(&self, preferences: &SidebarPreferences) -> gpui::AnyElement {
        use gpui::AnimationExt;
        let host = sample_host();
        let mut preview = div()
            .w(px(272.0))
            .flex_none()
            .p_2()
            .rounded_lg()
            .border_1()
            .border_color(rgb(0x30_3846))
            .bg(rgb(APP_CHROME_BACKGROUND))
            .child(
                div()
                    .px_2()
                    .h(px(28.0))
                    .flex()
                    .items_center()
                    .justify_between()
                    .text_size(px(11.0))
                    .text_color(rgb(0x8a_96a8))
                    .child("Workspaces")
                    .child(sort_title(preferences.session_sort)),
            )
            .child(
                div()
                    .px_2()
                    .h(px(28.0))
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_size(px(13.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(div().size(px(6.0)).rounded_full().bg(rgb(0x62_c07a)))
                    .child("Studio"),
            );
        for row in sessions(&host, None, &[], preferences) {
            preview = preview.child(
                div()
                    .px_2()
                    .h(px(row_height(preferences)))
                    .flex()
                    .items_center()
                    .child(content(&row, preferences, None)),
            );
        }
        preview = preview
            .child(
                div()
                    .px_2()
                    .pt_3()
                    .pb_1()
                    .text_size(px(11.0))
                    .text_color(rgb(0x7d_899b))
                    .child("Projects"),
            )
            .child(
                div()
                    .px_2()
                    .h(px(row_height(preferences)))
                    .flex()
                    .items_center()
                    .text_size(px(13.0))
                    .child("▾  Atlas"),
            );
        for name in [
            (!preferences.hide_root_checkout).then_some("main"),
            Some("feature/theme"),
        ]
        .into_iter()
        .flatten()
        {
            preview = preview.child(
                div()
                    .pl_5()
                    .h(px(row_height(preferences)))
                    .flex()
                    .items_center()
                    .text_size(px(13.0))
                    .text_color(rgb(0xb7_c3d4))
                    .child(name),
            );
        }
        div()
            .w(px(272.0))
            .flex_none()
            .flex()
            .flex_col()
            .gap_3()
            .child(preview.with_animation(
                ("sidebar-preview", self.sidebar_preview_revision),
                gpui::Animation::new(Duration::from_millis(650)),
                |el, delta| {
                    el.border_color(rgb(0x58_91ca).blend(gpui::Rgba {
                        a: delta,
                        ..rgb(0x30_38_46)
                    }))
                },
            ))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(rgb(0x93_a0b3))
                    .child("Settings save immediately in every window."),
            )
            .into_any_element()
    }
}
