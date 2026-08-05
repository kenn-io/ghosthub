use surface::{CellStyle, Damage, GridSize, Rgb};
use terminal::{ClipboardPolicy, ClipboardTarget, TerminalEngine};

#[test]
fn processes_bytes_into_an_owned_surface() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let output = engine.process(b"hi\x1b[31m!");

    assert!(output.pty_writes().is_empty());
    let surface = engine.surface().load();
    assert_eq!(surface.cells()[0].text(), "h");
    assert_eq!(surface.cells()[1].text(), "i");
    assert_eq!(surface.cells()[2].text(), "!");
    assert_eq!(surface.cells()[2].foreground, Rgb::new(0xcc, 0x66, 0x66));
}

#[test]
fn exposes_modes_that_control_input_encoding() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let _output = engine.process(b"\x1b[?1h\x1b[?2004h\x1b[?1006h");

    let modes = engine.modes();
    assert!(modes.application_cursor);
    assert!(modes.bracketed_paste);
    assert!(modes.sgr_mouse);
}

#[test]
fn preserves_wide_cells_without_copying_ffi_state() {
    let size = GridSize::new(4, 2).expect("valid grid");
    let mut engine = TerminalEngine::new(size);

    let _output = engine.process("界".as_bytes());

    let surface = engine.surface().load();
    assert_eq!(surface.cells()[0].text(), "界");
    assert!(surface.cells()[0].style.contains(CellStyle::WIDE));
    assert_eq!(surface.cells()[1].text(), "");
}

#[test]
fn resize_publishes_a_self_describing_full_frame() {
    let initial = GridSize::new(4, 2).expect("valid grid");
    let resized = GridSize::new(6, 3).expect("valid grid");
    let mut engine = TerminalEngine::new(initial);

    engine.resize(resized);

    let surface = engine.surface().load();
    assert_eq!(surface.size(), resized);
    assert_eq!(surface.cells().len(), 18);
    assert_eq!(surface.damage(), &[Damage::Full]);
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
fn sustained_output_reports_scroll_motion_and_only_the_exposed_row() {
    let size = GridSize::new(3, 3).expect("valid grid");
    let mut engine = TerminalEngine::new(size);
    let _output = engine.process(b"a\r\nb\r\nc");

    let _output = engine.process(b"\r\nd");

    let surface = engine.surface().load();
    assert_eq!(
        surface.damage(),
        &[
            Damage::Scroll {
                top: 0,
                bottom: 3,
                delta: -1,
            },
            Damage::Rows { start: 2, end: 3 },
        ]
    );
    assert_eq!(surface.cells()[0].text(), "b");
    assert_eq!(surface.cells()[3].text(), "c");
    assert_eq!(surface.cells()[6].text(), "d");
}
