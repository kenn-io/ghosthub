use model::PortStatus;
use surface::{Cell, CellStyle, Cursor, Damage, GridSize, Rgb, SurfaceFrame, SurfaceStore};
use ui::{
    SurfacePaintCache, WINDOW_TITLE, headline_text, surface_paint_rows, surface_text_rows,
    terminal_cell_at, terminal_wheel_action,
};
use workspace::MouseAction;

#[test]
fn exposes_model_status_for_rendering() {
    assert_eq!(
        headline_text(&PortStatus::new("Windows")),
        "Ghosthub Rust port · Windows"
    );
    assert_eq!(WINDOW_TITLE, "Ghosthub");
}

#[test]
fn paint_cache_applies_scroll_damage_and_repaints_exposed_rows() {
    let size = GridSize::new(1, 3).expect("valid grid");
    let mut initial = SurfaceFrame::blank(1, size);
    for (cell, text) in initial.cells_mut().zip(["a", "b", "c"]) {
        *cell = Cell::plain(text);
    }
    let store = SurfaceStore::new(initial);
    let mut cache = SurfacePaintCache::default();
    let _initial = cache.update(&store.load());

    assert!(store.update(
        2,
        size,
        &[
            Damage::Scroll {
                top: 0,
                bottom: 3,
                delta: -1,
            },
            Damage::Rows { start: 2, end: 3 },
        ],
        |frame| *frame.cell_mut(2) = Cell::plain("d"),
    ));

    let rows = cache.update(&store.load());
    let text: Vec<_> = rows.iter().map(|row| row[0].text()).collect();
    assert_eq!(text, ["b", "c", "d"]);
}

#[test]
fn terminal_rows_preserve_fixed_grid_columns() {
    let size = GridSize::new(3, 2).expect("valid grid");
    let mut frame = SurfaceFrame::blank(1, size);
    *frame.cell_mut(0) = Cell::plain("a");
    *frame.cell_mut(1) = Cell::plain("");
    *frame.cell_mut(3) = Cell::plain("b");

    assert_eq!(surface_text_rows(&frame), ["a  ", "b  "]);
}

#[test]
fn mouse_coordinates_map_to_the_rendered_grid() {
    let size = GridSize::new(120, 40).expect("valid grid");

    assert_eq!(terminal_cell_at(12.0, 54.0, 14.0, size), Some((0, 0)));
    assert_eq!(terminal_cell_at(1011.0, 678.0, 14.0, size), Some((118, 39)));
    assert_eq!(terminal_cell_at(8.0, 50.0, 14.0, size), None);
}

#[test]
fn terminal_paint_rows_preserve_cell_style_and_cursor() {
    let size = GridSize::new(3, 1).expect("valid grid");
    let mut frame = SurfaceFrame::blank(1, size);
    *frame.cell_mut(0) = Cell::plain("a");
    frame.cell_mut(0).foreground = Rgb::new(1, 2, 3);
    frame.cell_mut(0).background = Rgb::new(4, 5, 6);
    frame.cell_mut(0).style.insert(CellStyle::BOLD);
    *frame.cell_mut(1) = Cell::plain("b");
    frame.cell_mut(1).foreground = Rgb::new(1, 2, 3);
    frame.cell_mut(1).background = Rgb::new(4, 5, 6);
    frame.cell_mut(1).style.insert(CellStyle::BOLD);
    frame.set_cursor(Some(Cursor {
        row: 0,
        column: 1,
        visible: true,
    }));

    let rows = surface_paint_rows(&frame);

    assert_eq!(rows[0].len(), 3);
    assert_eq!(rows[0][0].text(), "a");
    assert_eq!(rows[0][0].foreground(), 0x01_02_03);
    assert_eq!(rows[0][0].background(), 0x04_05_06);
    assert!(rows[0][0].bold());
    assert_eq!(rows[0][1].text(), "b");
    assert_eq!(rows[0][1].foreground(), 0x04_05_06);
    assert_eq!(rows[0][1].background(), 0x01_02_03);
}

#[test]
fn positive_windows_wheel_delta_reports_wheel_up() {
    assert_eq!(terminal_wheel_action(3.0), Some(MouseAction::WheelUp));
    assert_eq!(terminal_wheel_action(-3.0), Some(MouseAction::WheelDown));
    assert_eq!(terminal_wheel_action(0.0), None);
}
