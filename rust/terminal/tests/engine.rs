use input::{ModifyOtherKeys, MouseTracking};
use surface::{CellStyle, CursorShape, Damage, GridSize, PixelSize, Rgb};
use terminal::{ClipboardPolicy, ClipboardTarget, DefaultColors, TerminalEngine};

#[test]
fn processes_bytes_into_an_owned_surface() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let output = engine.process(b"hi\x1b[31m!");

    assert!(output.pty_writes().is_empty());
    let surface = engine.surface().load();
    assert_eq!(surface.cell(0).text(), "h");
    assert_eq!(surface.cell(1).text(), "i");
    assert_eq!(surface.cell(2).text(), "!");
    assert_eq!(surface.cell(2).foreground, Rgb::new(0xcc, 0x66, 0x66));
}

#[test]
fn exposes_modes_that_control_input_encoding() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let _output = engine.process(b"\x1b[?1h\x1b[?2004h\x1b[?1002h\x1b[?1006h");

    let modes = engine.modes();
    assert!(modes.application_cursor);
    assert!(modes.bracketed_paste);
    assert_eq!(modes.mouse_tracking, MouseTracking::Drag);
    assert!(modes.sgr_mouse);
}

#[test]
fn publishes_application_requested_cursor_shapes() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let _output = engine.process(b"\x1b[6 q");
    assert_eq!(
        engine.surface().load().cursor().map(|cursor| cursor.shape),
        Some(CursorShape::Bar)
    );

    let _output = engine.process(b"\x1b[4 q");
    assert_eq!(
        engine.surface().load().cursor().map(|cursor| cursor.shape),
        Some(CursorShape::Underline)
    );
}

#[test]
fn configured_cursor_shape_is_the_initial_and_resettable_engine_default() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::with_geometry_and_defaults(
        size,
        0,
        PixelSize::default(),
        ClipboardPolicy::default(),
        DefaultColors::default(),
        CursorShape::Bar,
    );

    assert_eq!(
        engine.surface().load().cursor().map(|cursor| cursor.shape),
        Some(CursorShape::Bar)
    );

    let _output = engine.process(b"\x1b[4 q");
    engine.set_default_cursor_shape(CursorShape::Block);
    assert_eq!(
        engine.surface().load().cursor().map(|cursor| cursor.shape),
        Some(CursorShape::Underline),
        "changing the default must not discard an active application override"
    );

    let _output = engine.process(b"\x1b[0 q");
    assert_eq!(
        engine.surface().load().cursor().map(|cursor| cursor.shape),
        Some(CursorShape::Block)
    );

    engine.set_default_cursor_shape(CursorShape::Bar);
    assert_eq!(
        engine.surface().load().cursor().map(|cursor| cursor.shape),
        Some(CursorShape::Bar),
        "an open terminal without an override must receive the new default"
    );
}

#[test]
fn exposes_negotiated_keypad_and_extended_keyboard_modes() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let _output = engine.process(b"\x1b=\x1b[>4;2m\x1b[=31u");

    let modes = engine.modes();
    assert!(modes.application_keypad);
    assert_eq!(modes.modify_other_keys, ModifyOtherKeys::All);
    assert!(modes.kitty_keyboard.disambiguate_escape_codes);
    assert!(modes.kitty_keyboard.report_event_types);
    assert!(modes.kitty_keyboard.report_alternate_keys);
    assert!(modes.kitty_keyboard.report_all_keys_as_escape_codes);
    assert!(modes.kitty_keyboard.report_associated_text);
}

#[test]
fn preserves_wide_cells_without_copying_ffi_state() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let _output = engine.process("界".as_bytes());

    let surface = engine.surface().load();
    assert_eq!(surface.cell(0).text(), "界");
    assert!(surface.cell(0).style.contains(CellStyle::WIDE));
    assert_eq!(surface.cell(1).text(), "");
}

#[test]
fn preserves_conceal_dim_and_strike_attributes() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let _output = engine.process(b"\x1b[2ma\x1b[8mb\x1b[9mc");

    let surface = engine.surface().load();
    assert!(surface.cell(0).style.contains(CellStyle::DIM));
    assert!(surface.cell(1).style.contains(CellStyle::HIDDEN));
    assert!(surface.cell(2).style.contains(CellStyle::STRIKE));
}

#[test]
fn resize_publishes_a_self_describing_full_frame() {
    let initial = GridSize::new(4, 2).expect("valid grid");
    let resized = GridSize::new(6, 3).expect("valid grid");
    let mut engine = TerminalEngine::new(initial);

    engine.resize(resized);

    let surface = engine.surface().load();
    assert_eq!(surface.size(), resized);
    assert_eq!(surface.cells().count(), 18);
    assert_eq!(surface.damage(), &[Damage::Full]);
}

#[test]
fn resize_publication_carries_order_and_pixel_dimensions() {
    let initial = GridSize::new(8, 2).expect("valid grid");
    let resized = GridSize::new(12, 4).expect("valid grid");
    let mut engine = TerminalEngine::new(initial);

    engine.resize_with_metadata(resized, 17, PixelSize::new(960, 640));

    let frame = engine.surface().load();
    assert_eq!(frame.size(), resized);
    assert_eq!(frame.resize_sequence(), 17);
    assert_eq!(frame.pixel_size(), PixelSize::new(960, 640));
}

#[test]
fn osc_52_write_is_reported_for_the_windows_clipboard() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let output = engine.process(b"\x1b]52;c;SGVsbG8=\x07");

    assert!(output.pty_writes().is_empty());
    assert_eq!(output.clipboard_writes().len(), 1);
    assert_eq!(
        output.clipboard_writes()[0].target,
        ClipboardTarget::Clipboard
    );
    assert_eq!(output.clipboard_writes()[0].text, "Hello");
}

#[test]
fn remote_osc_52_read_gets_an_empty_response() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let output = engine.process(b"\x1b]52;c;?\x07");

    assert!(output.clipboard_reads().is_empty());
    assert_eq!(output.pty_writes(), &[b"\x1b]52;c;\x07".to_vec()]);
}

#[test]
fn configured_local_osc_52_read_can_be_completed_by_the_ui() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine =
        TerminalEngine::with_clipboard_policy(size, ClipboardPolicy::local(true, true));

    let output = engine.process(b"\x1b]52;c;?\x07");

    assert_eq!(output.clipboard_reads().len(), 1);
    assert_eq!(
        output.clipboard_reads()[0].respond("secret"),
        b"\x1b]52;c;c2VjcmV0\x07"
    );
}

#[test]
fn sustained_output_reports_scroll_then_only_the_exposed_row() {
    let size = GridSize::new(3, 3).expect("valid grid");
    let mut engine = TerminalEngine::new(size);
    let _output = engine.process(b"a\r\nb\r\nc");

    let _output = engine.process(b"\r\n");

    let scroll = engine.surface().load();
    assert_eq!(
        scroll.damage(),
        &[Damage::Scroll {
            top: 0,
            bottom: 3,
            delta: -1,
        }]
    );
    drop(scroll);

    let _output = engine.process(b"d");

    let surface = engine.surface().load();
    assert_eq!(surface.damage(), &[Damage::Rows { start: 2, end: 3 }]);
    assert_eq!(surface.cell(0).text(), "b");
    assert_eq!(surface.cell(3).text(), "c");
    assert_eq!(surface.cell(6).text(), "d");
}

#[test]
fn damage_after_scroll_is_relative_to_the_immediately_previous_frame() {
    let size = GridSize::new(3, 3).expect("valid grid");
    let mut engine = TerminalEngine::new(size);
    let _output = engine.process(b"a\r\nb\r\nc");

    let _output = engine.process(b"\r\nd\x1b[1;1HZ");

    let surface = engine.surface().load();
    assert_eq!(surface.cell(0).text(), "Z");
    assert_eq!(surface.cell(6).text(), "d");
    assert_eq!(
        surface.damage(),
        &[
            Damage::Rows { start: 0, end: 1 },
            Damage::Rows { start: 2, end: 3 },
        ]
    );
    assert_eq!(surface.previous_generation(), surface.generation() - 1);
}

#[test]
fn denied_remote_osc_52_write_emits_no_clipboard_event() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::with_clipboard_policy(size, ClipboardPolicy::remote(false));

    let output = engine.process(b"\x1b]52;c;SGVsbG8=\x07");

    assert!(output.clipboard_writes().is_empty());
}
