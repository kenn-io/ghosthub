use model::PortStatus;
use surface::{Cell, GridSize, SurfaceFrame};
use ui::{WINDOW_TITLE, headline_text, surface_text_rows};

#[test]
fn exposes_model_status_for_rendering() {
    assert_eq!(
        headline_text(&PortStatus::new("Windows")),
        "Ghosthub Rust port · Windows"
    );
    assert_eq!(WINDOW_TITLE, "Ghosthub");
}

#[test]
fn terminal_rows_preserve_fixed_grid_columns() {
    let size = GridSize::new(3, 2).expect("valid grid");
    let mut frame = SurfaceFrame::blank(1, size);
    frame.cells_mut()[0] = Cell::plain("a");
    frame.cells_mut()[1] = Cell::plain("");
    frame.cells_mut()[3] = Cell::plain("b");

    assert_eq!(surface_text_rows(&frame), ["a  ", "b  "]);
}
