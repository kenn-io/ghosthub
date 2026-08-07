use model::DiagnosticKind;
use model::PortStatus;
use surface::{Cell, CellStyle, Cursor, Damage, GridSize, Rgb, SurfaceFrame, SurfaceStore};
use ui::{
    SurfacePaintCache, WINDOW_TITLE, empty_inventory_text, headline_text, host_status_text,
    surface_paint_rows, surface_text_rows, terminal_cell_at, terminal_grid_size,
    terminal_wheel_action, terminal_wheel_steps,
};
use workspace::{HostConnectionState, HostDiagnostic, HostItem, MouseAction};

#[test]
fn host_projection_keeps_connection_failures_scoped() {
    let host = HostItem::wsl(
        "Ubuntu",
        None,
        HostConnectionState::Unavailable,
        Vec::new(),
        Some(HostDiagnostic::new(
            DiagnosticKind::Timeout,
            "WSL host refresh timed out",
        )),
    );

    assert_eq!(host_status_text(&host), "WSL host refresh timed out");
}

#[test]
fn empty_inventory_copy_names_the_socket_namespace() {
    let host = HostItem::wsl(
        "Ubuntu",
        Some("/run/user/1000/tmux".to_owned()),
        HostConnectionState::Ready,
        Vec::new(),
        None,
    );

    assert_eq!(
        empty_inventory_text(&host),
        "No tmux server is running in Ubuntu using /run/user/1000/tmux. Review WSL host settings or start a tmux session, then choose Refresh."
    );
}

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
fn paint_cache_repaints_blank_rows_exposed_by_scroll_only_damage() {
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
        &[Damage::Scroll {
            top: 0,
            bottom: 3,
            delta: -1,
        }],
        |_| {},
    ));

    let rows = cache.update(&store.load());
    let text = rows.iter().map(|row| row[0].text()).collect::<Vec<_>>();
    assert_eq!(text, ["b", "c", " "]);
}

#[test]
fn paint_cache_does_not_replay_scroll_after_consuming_an_intermediate_frame() {
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
        &[Damage::Scroll {
            top: 0,
            bottom: 3,
            delta: -1,
        }],
        |_| {},
    ));
    let _intermediate = cache.update(&store.load());
    assert!(store.update(
        3,
        size,
        &[
            Damage::Rows { start: 0, end: 1 },
            Damage::Rows { start: 2, end: 3 },
        ],
        |frame| {
            *frame.cell_mut(0) = Cell::plain("Z");
            *frame.cell_mut(2) = Cell::plain("d");
        },
    ));

    let rows = cache.update(&store.load());
    let text = rows.iter().map(|row| row[0].text()).collect::<Vec<_>>();
    assert_eq!(text, ["Z", "c", "d"]);
}

#[test]
fn paint_cache_does_not_scroll_cursor_highlighting_with_cells() {
    let size = GridSize::new(1, 3).expect("valid grid");
    let mut initial = SurfaceFrame::blank(1, size);
    for (cell, text) in initial.cells_mut().zip(["a", "b", "c"]) {
        *cell = Cell::plain(text);
    }
    initial.set_cursor(Some(Cursor {
        row: 1,
        column: 0,
        visible: true,
    }));
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
        |frame| {
            *frame.cell_mut(2) = Cell::plain("d");
            frame.set_cursor(Some(Cursor {
                row: 1,
                column: 0,
                visible: true,
            }));
        },
    ));

    let rows = cache.update(&store.load());
    assert_eq!(rows[0][0].foreground(), 0xee_f0_f4);
    assert_eq!(rows[1][0].foreground(), 0x11_13_18);
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

    assert_eq!(terminal_cell_at(12.0, 54.0, 10.0, 18.0, size), Some((0, 0)));
    assert_eq!(
        terminal_cell_at(1_011.0, 678.0, 10.0, 18.0, size),
        Some((99, 34))
    );
    assert_eq!(terminal_cell_at(8.0, 50.0, 10.0, 18.0, size), None);
}

#[test]
fn grid_size_uses_the_same_measured_metrics_as_hit_testing() {
    assert_eq!(terminal_grid_size(1_100.0, 720.0, 10.0, 18.0), (107, 36));
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
fn wide_cells_reserve_two_measured_grid_columns() {
    let size = GridSize::new(2, 1).expect("valid grid");
    let mut frame = SurfaceFrame::blank(1, size);
    *frame.cell_mut(0) = Cell::plain("界");
    frame.cell_mut(0).style.insert(CellStyle::WIDE);
    *frame.cell_mut(1) = Cell::plain("");

    let rows = surface_paint_rows(&frame);

    assert_eq!(rows[0].len(), 1);
    assert_eq!(rows[0][0].columns(), 2);
}

#[test]
fn wheel_delta_accumulates_fractional_lines_and_preserves_magnitude() {
    let mut remainder = 0.0;

    assert_eq!(terminal_wheel_steps(&mut remainder, 5.0, 20.0), 0);
    assert!((remainder - 0.25).abs() < f32::EPSILON);
    assert_eq!(terminal_wheel_steps(&mut remainder, 55.0, 20.0), 3);
    assert!(remainder.abs() < f32::EPSILON);
    assert_eq!(terminal_wheel_steps(&mut remainder, -45.0, 20.0), -2);
    assert!((remainder + 0.25).abs() < f32::EPSILON);

    assert_eq!(terminal_wheel_action(3), Some(MouseAction::WheelUp));
    assert_eq!(terminal_wheel_action(-2), Some(MouseAction::WheelDown));
    assert_eq!(terminal_wheel_action(0), None);

    let mut large_remainder = 0.0;
    assert_eq!(
        terminal_wheel_steps(&mut large_remainder, 20_000.0, 20.0),
        64
    );
    assert!((large_remainder - 936.0).abs() < f32::EPSILON);
    assert_eq!(terminal_wheel_steps(&mut large_remainder, 0.0, 20.0), 64);
    assert!((large_remainder - 872.0).abs() < f32::EPSILON);
}
