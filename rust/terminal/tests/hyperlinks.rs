use surface::GridSize;
use terminal::TerminalEngine;

#[test]
fn osc8_targets_are_owned_cell_metadata_separate_from_display_text() {
    let mut engine = TerminalEngine::new(GridSize::new(20, 4).unwrap());
    let _ = engine.process(b"before ");
    let _ = engine.process(b"\x1b]8;id=docs;https://example.com/docs?q=one%20two&lang=fr\x1b");
    let _ = engine.process("\\caf\u{e9}\x1b]8;;\x1b\\ after".as_bytes());
    let frame = engine.surface().load();
    assert_eq!(frame.row(0)[7].text(), "c");
    assert_eq!(frame.row(0)[10].text(), "é");
    for cell in &frame.row(0)[7..11] {
        assert_eq!(
            cell.hyperlink.as_deref(),
            Some("https://example.com/docs?q=one%20two&lang=fr")
        );
    }
    assert!(frame.row(0)[6].hyperlink.is_none());
    assert!(frame.row(0)[11].hyperlink.is_none());
    let _ = engine.process(b"\r\x1b[2Kplain text");
    assert!(
        engine
            .surface()
            .load()
            .row(0)
            .iter()
            .all(|cell| cell.hyperlink.is_none())
    );
    assert_eq!(
        frame.row(0)[7].hyperlink.as_deref(),
        Some("https://example.com/docs?q=one%20two&lang=fr")
    );
}

#[test]
fn links_follow_wrapped_wide_cells_resize_and_screen_switches() {
    let mut engine = TerminalEngine::new(GridSize::new(8, 4).unwrap());
    let _ = engine.process("\x1b]8;;https://example.com/界\x07abcdef界xy\x1b]8;;\x07".as_bytes());
    let frame = engine.surface().load();
    assert_eq!(frame.row(0)[6].text(), "界");
    assert_eq!(frame.hyperlink_at(7, 0), Some("https://example.com/界"));
    assert!(frame.hyperlink_at(8, 0).is_none());
    assert!(frame.hyperlink_at(0, 4).is_none());
    assert_eq!(
        frame.row(0)[6].hyperlink.as_deref(),
        Some("https://example.com/界")
    );
    assert_eq!(frame.row(1)[0].text(), "x");
    assert_eq!(
        frame.row(1)[1].hyperlink.as_deref(),
        Some("https://example.com/界")
    );
    engine.resize(GridSize::new(12, 4).unwrap());
    assert_eq!(engine.surface().load().row(0)[8].text(), "x");
    assert_eq!(
        engine.surface().load().row(0)[8].hyperlink.as_deref(),
        Some("https://example.com/界")
    );
    let _ =
        engine.process(b"\x1b[?1049h\x1b[H\x1b]8;;mailto:hello@example.com\x07Mail\x1b]8;;\x07");
    assert_eq!(
        engine.surface().load().row(0)[0].hyperlink.as_deref(),
        Some("mailto:hello@example.com")
    );
    let _ = engine.process(b"\x1b[?1049l");
    assert_eq!(
        engine.surface().load().row(0)[0].hyperlink.as_deref(),
        Some("https://example.com/界")
    );
}

#[test]
fn long_targets_are_not_truncated_and_invisible_text_is_not_a_hit_target() {
    let mut engine = TerminalEngine::new(GridSize::new(20, 4).unwrap());
    let target = format!("https://example.com/{}", "x".repeat(512));
    let _ = engine.process(
        format!("\x1b]8;;{target}\x1b\\visible\x1b[8msecret\x1b[0m\x1b]8;;\x1b\\").as_bytes(),
    );
    let frame = engine.surface().load();
    assert_eq!(frame.hyperlink_at(0, 0), Some(target.as_str()));
    assert!(frame.hyperlink_at(7, 0).is_none());
    assert!(frame.hyperlink_at(13, 0).is_none());
}

#[test]
fn replacing_a_target_without_changing_the_label_publishes_fresh_metadata() {
    let mut engine = TerminalEngine::new(GridSize::new(12, 3).unwrap());
    let _ = engine.process(b"\x1b]8;;https://example.com/first\x07Docs\x1b]8;;\x07");
    let before = engine.surface().load();
    let _ = engine.process(b"\r\x1b]8;;https://example.com/second\x07Docs\x1b]8;;\x07");
    let after = engine.surface().load();
    assert_eq!(before.row(0)[0].text(), after.row(0)[0].text());
    assert_eq!(before.hyperlink_at(0, 0), Some("https://example.com/first"));
    assert_eq!(after.hyperlink_at(0, 0), Some("https://example.com/second"));
    assert!(after.generation() > before.generation());
}

#[test]
fn linked_text_still_reports_application_mouse_input_and_copies_its_label() {
    use input::{Modifiers, MouseAction, MouseButton, MouseInput};
    let mut engine = TerminalEngine::new(GridSize::new(12, 3).unwrap());
    let _ = engine
        .process(b"\x1b]8;;https://example.com/docs\x07Docs\x1b]8;;\x07\x1b[?1000h\x1b[?1006h");
    let press = MouseInput {
        click_count: 0,
        action: MouseAction::Press(MouseButton::Left),
        column: 0,
        row: 0,
        modifiers: Modifiers::default(),
    };
    assert_eq!(engine.mouse_input(press), b"\x1b[<0;1;1M");
    assert_eq!(
        engine.mouse_input(MouseInput {
            action: MouseAction::Release(MouseButton::Left),
            ..press
        }),
        b"\x1b[<0;1;1m"
    );
    let shift = Modifiers {
        shift: true,
        ..Modifiers::default()
    };
    assert!(
        engine
            .mouse_input(MouseInput {
                modifiers: shift,
                ..press
            })
            .is_empty()
    );
    assert!(
        engine
            .mouse_input(MouseInput {
                action: MouseAction::Move(Some(MouseButton::Left)),
                column: 2,
                modifiers: shift,
                ..press
            })
            .is_empty()
    );
    assert!(
        engine
            .mouse_input(MouseInput {
                action: MouseAction::Release(MouseButton::Left),
                column: 3,
                modifiers: shift,
                ..press
            })
            .is_empty()
    );
    assert_eq!(engine.copy_selection().as_deref(), Some("Docs"));
}
