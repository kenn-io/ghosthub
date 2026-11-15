use input::{Modifiers, MouseAction, MouseButton, MouseInput};
use surface::GridSize;
use terminal::TerminalEngine;

fn pointer(
    engine: &mut TerminalEngine,
    action: MouseAction,
    column: usize,
    row: usize,
    count: usize,
    shift: bool,
) -> Vec<u8> {
    engine.mouse_input(MouseInput {
        action,
        column,
        row,
        click_count: count,
        modifiers: Modifiers {
            shift,
            ..Modifiers::default()
        },
    })
}

#[test]
fn repeated_clicks_select_a_unicode_word_or_logical_line_without_dragging() {
    for (count, expected) in [
        (1, None),
        (2, Some("café")),
        (3, Some("hello café world")),
        (4, Some("hello café world")),
    ] {
        let mut engine = TerminalEngine::new(GridSize::new(24, 4).unwrap());
        let _ = engine.process("hello café world\r\nnext line".as_bytes());
        let _ = pointer(
            &mut engine,
            MouseAction::Press(MouseButton::Left),
            7,
            0,
            count,
            false,
        );
        let _ = pointer(
            &mut engine,
            MouseAction::Release(MouseButton::Left),
            7,
            0,
            count,
            false,
        );
        assert_eq!(engine.copy_selection().as_deref(), expected);
        assert_eq!(
            engine.surface().load().row(0)[7].selected,
            expected.is_some()
        );
    }
}

#[test]
fn word_drag_keeps_whole_words_in_both_directions_and_finishes_at_release() {
    for (start, moved, released, expected) in [
        (2, 8, 15, "alpha  beta gamma"),
        (15, 8, 2, "alpha  beta gamma"),
        (2, 8, 6, "alpha"),
    ] {
        let mut engine = TerminalEngine::new(GridSize::new(24, 4).unwrap());
        let _ = engine.process(b"alpha  beta gamma");
        let _ = pointer(
            &mut engine,
            MouseAction::Press(MouseButton::Left),
            start,
            0,
            2,
            false,
        );
        let _ = pointer(
            &mut engine,
            MouseAction::Move(Some(MouseButton::Left)),
            moved,
            0,
            0,
            false,
        );
        let _ = pointer(
            &mut engine,
            MouseAction::Release(MouseButton::Left),
            released,
            0,
            0,
            false,
        );
        assert_eq!(engine.copy_selection().as_deref(), Some(expected));
    }
}

#[test]
fn line_drag_follows_the_original_line_when_direction_changes() {
    for (start, moved, released, expected) in [
        (0, 1, 2, "first line\nsecond line\nthird line"),
        (2, 1, 0, "first line\nsecond line\nthird line"),
        (1, 0, 2, "second line\nthird line"),
    ] {
        let mut engine = TerminalEngine::new(GridSize::new(24, 5).unwrap());
        let _ = engine.process(b"first line\r\nsecond line\r\nthird line");
        let _ = pointer(
            &mut engine,
            MouseAction::Press(MouseButton::Left),
            3,
            start,
            3,
            false,
        );
        let _ = pointer(
            &mut engine,
            MouseAction::Move(Some(MouseButton::Left)),
            4,
            moved,
            0,
            false,
        );
        let _ = pointer(
            &mut engine,
            MouseAction::Release(MouseButton::Left),
            2,
            released,
            0,
            false,
        );
        assert_eq!(engine.copy_selection().as_deref(), Some(expected));
    }
}

#[test]
fn line_drag_includes_blank_endpoints_without_selecting_them_on_a_plain_triple_click() {
    for (start, end, expected) in [(0, 1, "first line"), (1, 2, "\nthird line")] {
        let mut engine = TerminalEngine::new(GridSize::new(24, 5).unwrap());
        let _ = engine.process(b"first line\r\n\r\nthird line");
        let _ = pointer(
            &mut engine,
            MouseAction::Press(MouseButton::Left),
            3,
            start,
            3,
            false,
        );
        if start == 1 {
            assert!(engine.copy_selection().is_none());
        }
        let _ = pointer(
            &mut engine,
            MouseAction::Move(Some(MouseButton::Left)),
            4,
            end,
            0,
            false,
        );
        let _ = pointer(
            &mut engine,
            MouseAction::Release(MouseButton::Left),
            2,
            end,
            0,
            false,
        );
        assert_eq!(engine.copy_selection().as_deref(), Some(expected));
        assert!(engine.surface().load().row(1)[0].selected);
    }
}

#[test]
fn triple_click_joins_wrapped_lines_and_respects_shell_prompt_boundaries() {
    for (columns, bytes, column, row, expected) in [
        (6, "abcdefghij", 1, 1, "abcdefghij"),
        (
            24,
            "\x1b]133;A\x07$ \x1b]133;B\x07git status\x1b]133;C\x07\r\nresult",
            5,
            0,
            "git status",
        ),
    ] {
        let mut engine = TerminalEngine::new(GridSize::new(columns, 4).unwrap());
        let _ = engine.process(bytes.as_bytes());
        let _ = pointer(
            &mut engine,
            MouseAction::Press(MouseButton::Left),
            column,
            row,
            3,
            false,
        );
        let _ = pointer(
            &mut engine,
            MouseAction::Release(MouseButton::Left),
            column,
            row,
            3,
            false,
        );
        assert_eq!(engine.copy_selection().as_deref(), Some(expected));
    }
}

#[test]
fn repeated_clicks_keep_application_mouse_reports_and_shift_overrides_them() {
    for (count, expected) in [(2, "world"), (3, "hello world")] {
        let mut engine = TerminalEngine::new(GridSize::new(24, 4).unwrap());
        let _ = engine.process(b"hello world\x1b[?1002h\x1b[?1006h");
        assert_eq!(
            pointer(
                &mut engine,
                MouseAction::Press(MouseButton::Left),
                7,
                0,
                count,
                false
            ),
            b"\x1b[<0;8;1M"
        );
        assert_eq!(
            pointer(
                &mut engine,
                MouseAction::Release(MouseButton::Left),
                7,
                0,
                count,
                false
            ),
            b"\x1b[<0;8;1m"
        );
        assert!(engine.copy_selection().is_none());
        assert!(
            pointer(
                &mut engine,
                MouseAction::Press(MouseButton::Left),
                7,
                0,
                count,
                true
            )
            .is_empty()
        );
        assert!(
            pointer(
                &mut engine,
                MouseAction::Release(MouseButton::Left),
                7,
                0,
                count,
                false
            )
            .is_empty()
        );
        assert_eq!(engine.copy_selection().as_deref(), Some(expected));
    }
}
