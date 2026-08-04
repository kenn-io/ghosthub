//! GPUI presentation for the Rust Ghosthub application.

use gpui::{
    App, Application, Bounds, Context, Render, TitlebarOptions, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, rgb, size,
};
use model::PortStatus;

pub const WINDOW_TITLE: &str = "Ghosthub";

/// The first native Ghosthub view shared by the Windows and Linux shells.
pub struct RootView {
    status: PortStatus,
}

impl RootView {
    #[must_use]
    pub const fn new(status: PortStatus) -> Self {
        Self { status }
    }

    #[must_use]
    pub fn headline(&self) -> String {
        self.status.headline()
    }
}

impl Render for RootView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .size_full()
            .items_center()
            .justify_center()
            .bg(rgb(0x11_13_18))
            .text_color(rgb(0xe6_e9_ef))
            .text_xl()
            .child(self.headline())
    }
}

/// Start the GPUI event loop and open Ghosthub's first native window.
///
/// # Panics
///
/// Panics if GPUI cannot create the application window.
pub fn run(status: PortStatus) {
    Application::new().run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(960.0), px(640.0)), cx);

        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some(WINDOW_TITLE.into()),
                    ..Default::default()
                }),
                ..Default::default()
            },
            move |_window, cx| cx.new(|_| RootView::new(status)),
        )
        .expect("failed to open the Ghosthub window");

        cx.activate(true);
    });
}
