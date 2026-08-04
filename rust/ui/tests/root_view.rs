use model::PortStatus;
use ui::{RootView, WINDOW_TITLE};

#[test]
fn exposes_model_status_for_rendering() {
    let view = RootView::new(PortStatus::new("Windows"));

    assert_eq!(view.headline(), "Ghosthub Rust port · Windows");
    assert_eq!(WINDOW_TITLE, "Ghosthub");
}
