use surface::{Cell, Damage, GridSize, SurfaceFrame, SurfaceStore};

#[test]
fn frame_carries_the_grid_dimensions_it_was_built_for() {
    let size = GridSize::new(80, 24).expect("valid grid");
    let frame = SurfaceFrame::blank(7, size);

    assert_eq!(frame.generation(), 7);
    assert_eq!(frame.size(), size);
    assert_eq!(frame.cells().len(), 80 * 24);
}

#[test]
fn rejects_zero_sized_grids() {
    assert!(GridSize::new(0, 24).is_err());
    assert!(GridSize::new(80, 0).is_err());
}

#[test]
fn latest_value_store_drops_an_older_generation() {
    let size = GridSize::new(2, 1).expect("valid grid");
    let store = SurfaceStore::new(SurfaceFrame::blank(3, size));

    assert!(!store.publish(SurfaceFrame::blank(2, size)));
    assert_eq!(store.load().generation(), 3);
}

#[test]
fn damage_vocabulary_represents_scroll_and_dirty_rows() {
    let damage = vec![
        Damage::Scroll {
            top: 0,
            bottom: 22,
            delta: -1,
        },
        Damage::Rows { start: 22, end: 24 },
    ];
    let mut frame = SurfaceFrame::blank(4, GridSize::new(80, 24).expect("valid grid"));
    frame.set_damage(damage.clone());

    assert_eq!(frame.damage(), damage.as_slice());
}

#[test]
fn cells_are_owned_values() {
    let mut frame = SurfaceFrame::blank(1, GridSize::new(1, 1).expect("valid grid"));
    frame.cells_mut()[0] = Cell::plain("界");

    assert_eq!(frame.cells()[0].text(), "界");
}
