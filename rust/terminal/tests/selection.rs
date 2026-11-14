use input::{Modifiers, MouseAction, MouseButton, MouseInput};
use surface::GridSize;
use terminal::TerminalEngine;

fn mouse(
    engine: &mut TerminalEngine,
    action: MouseAction,
    column: usize,
    row: usize,
    shift: bool,
) -> Vec<u8> {
    engine.mouse_input(MouseInput {
        action,
        column,
        row,
        modifiers: Modifiers {
            shift,
            ..Modifiers::default()
        },
    })
}

#[test]
fn drag_selection_copies_library_text_and_publishes_highlights() {
    let mut engine = TerminalEngine::new(GridSize::new(12, 4).unwrap());
    let _ = engine.process("hello world\r\ncafé 界e\u{301}".as_bytes());
    assert!(
        mouse(
            &mut engine,
            MouseAction::Press(MouseButton::Left),
            0,
            0,
            false
        )
        .is_empty()
    );
    assert!(
        mouse(
            &mut engine,
            MouseAction::Move(Some(MouseButton::Left)),
            4,
            0,
            false
        )
        .is_empty()
    );
    let _ = mouse(
        &mut engine,
        MouseAction::Release(MouseButton::Left),
        4,
        0,
        false,
    );
    assert_eq!(engine.copy_selection().as_deref(), Some("hello"));
    let frame = engine.surface().load();
    assert!(frame.row(0)[..5].iter().all(|cell| cell.selected));
    assert!(frame.row(0)[5..].iter().all(|cell| !cell.selected));
    let _ = mouse(
        &mut engine,
        MouseAction::Press(MouseButton::Left),
        0,
        1,
        false,
    );
    let _ = mouse(
        &mut engine,
        MouseAction::Move(Some(MouseButton::Left)),
        7,
        1,
        false,
    );
    let _ = mouse(
        &mut engine,
        MouseAction::Release(MouseButton::Left),
        7,
        1,
        false,
    );
    assert_eq!(engine.copy_selection().as_deref(), Some("café 界e\u{301}"));
    engine.clear_selection();
    assert!(engine.copy_selection().is_none());
    assert!(engine.surface().load().cells().all(|cell| !cell.selected));
}

#[test]
fn mouse_tracking_keeps_application_reports_and_shift_drag_selects_locally() {
    let mut engine = TerminalEngine::new(GridSize::new(12, 4).unwrap());
    let _ = engine.process(b"hello world\x1b[?1002h\x1b[?1006h");
    assert_eq!(
        mouse(
            &mut engine,
            MouseAction::Press(MouseButton::Left),
            0,
            0,
            false
        ),
        b"\x1b[<0;1;1M"
    );
    assert_eq!(
        mouse(
            &mut engine,
            MouseAction::Move(Some(MouseButton::Left)),
            4,
            0,
            false
        ),
        b"\x1b[<32;5;1M"
    );
    assert_eq!(
        mouse(
            &mut engine,
            MouseAction::Release(MouseButton::Left),
            4,
            0,
            false
        ),
        b"\x1b[<0;5;1m"
    );
    assert!(engine.copy_selection().is_none());
    let _ = mouse(
        &mut engine,
        MouseAction::Press(MouseButton::Left),
        0,
        0,
        true,
    );
    assert!(
        mouse(
            &mut engine,
            MouseAction::Move(Some(MouseButton::Left)),
            4,
            0,
            false
        )
        .is_empty()
    );
    assert!(
        mouse(
            &mut engine,
            MouseAction::Release(MouseButton::Left),
            4,
            0,
            false
        )
        .is_empty()
    );
    assert_eq!(engine.copy_selection().as_deref(), Some("hello"));
}

#[test]
fn selection_handles_reverse_drag_wrapped_text_and_resize() {
    let mut engine = TerminalEngine::new(GridSize::new(6, 4).unwrap());
    let _ = engine.process(b"abcdefghij\r\nnext");
    let _ = mouse(
        &mut engine,
        MouseAction::Press(MouseButton::Left),
        3,
        1,
        false,
    );
    let _ = mouse(
        &mut engine,
        MouseAction::Move(Some(MouseButton::Left)),
        0,
        0,
        false,
    );
    let _ = mouse(
        &mut engine,
        MouseAction::Release(MouseButton::Left),
        0,
        0,
        false,
    );
    assert_eq!(engine.copy_selection().as_deref(), Some("abcdefghij"));
    engine.resize(GridSize::new(10, 4).unwrap());
    assert!(engine.copy_selection().is_none());
    assert!(engine.surface().load().cells().all(|cell| !cell.selected));
}

#[test]
fn a_screen_switch_during_drag_does_not_select_the_other_screen() {
    let mut engine = TerminalEngine::new(GridSize::new(12, 4).unwrap());
    let _ = engine.process(b"hello world");
    let _ = mouse(
        &mut engine,
        MouseAction::Press(MouseButton::Left),
        0,
        0,
        false,
    );
    let _ = engine.process(b"\x1b[?1049halternate");
    let _ = mouse(
        &mut engine,
        MouseAction::Move(Some(MouseButton::Left)),
        4,
        0,
        false,
    );
    let _ = mouse(
        &mut engine,
        MouseAction::Release(MouseButton::Left),
        4,
        0,
        false,
    );
    assert!(engine.copy_selection().is_none());
}

#[test]
fn typing_clears_selection_without_forwarding_the_local_drags_release() {
    let mut engine = TerminalEngine::new(GridSize::new(12, 4).unwrap());
    let _ = engine.process(b"hello world\x1b[?1002h\x1b[?1006h");
    let _ = mouse(
        &mut engine,
        MouseAction::Press(MouseButton::Left),
        0,
        0,
        true,
    );
    let _ = mouse(
        &mut engine,
        MouseAction::Move(Some(MouseButton::Left)),
        4,
        0,
        true,
    );
    assert_eq!(engine.copy_selection().as_deref(), Some("hello"));
    let _ = engine.encode_input(&input::KeyInput::text("x", Modifiers::default()));
    assert!(engine.copy_selection().is_none());
    assert!(
        mouse(
            &mut engine,
            MouseAction::Release(MouseButton::Left),
            4,
            0,
            false
        )
        .is_empty()
    );
}

#[test]
fn explicit_copy_reaches_the_worker_even_with_remote_clipboard_writes_disabled() {
    use std::{
        ffi::OsString,
        thread,
        time::{Duration, Instant},
    };
    use terminal::{ClipboardPolicy, TerminalEvent, TerminalWorker};
    #[cfg(unix)]
    let (program, args) = (
        "/bin/sh",
        vec!["-c", "printf 'copy-target\\r\\n'; read -r line"],
    );
    #[cfg(windows)]
    let (program, args) = (
        "cmd.exe",
        vec!["/d", "/c", "echo copy-target & set /p line= & exit /b 0"],
    );
    let plan = session::AttachPlan::attach_only(
        program,
        args.into_iter().map(OsString::from).collect(),
        "copy-test",
        session::SessionIdentity::new(1, "$1", 1),
    );
    let worker = TerminalWorker::attach(&plan, GridSize::new(40, 4).unwrap()).unwrap();
    worker.set_clipboard_policy(ClipboardPolicy::remote(false));
    let deadline = Instant::now() + Duration::from_secs(5);
    while !worker
        .surface()
        .load()
        .cells()
        .map(surface::Cell::text)
        .collect::<String>()
        .contains("copy-target")
    {
        assert!(Instant::now() < deadline, "child output did not arrive");
        thread::sleep(Duration::from_millis(5));
    }
    for action in [
        MouseAction::Press(MouseButton::Left),
        MouseAction::Move(Some(MouseButton::Left)),
        MouseAction::Release(MouseButton::Left),
    ] {
        worker
            .send_mouse(MouseInput {
                action,
                column: if matches!(action, MouseAction::Press(_)) {
                    0
                } else {
                    10
                },
                row: 0,
                modifiers: Modifiers::default(),
            })
            .unwrap();
    }
    worker.copy_selection().unwrap();
    loop {
        match worker.try_event().unwrap() {
            Some(TerminalEvent::ClipboardWrite { write, .. }) => {
                assert_eq!(write.text, "copy-target");
                break;
            }
            Some(TerminalEvent::Error(error)) => panic!("{error}"),
            _ => {}
        }
        assert!(
            Instant::now() < deadline,
            "selection did not reach the clipboard event"
        );
        thread::sleep(Duration::from_millis(5));
    }
    worker.copy_selection().unwrap();
    worker.set_clipboard_writes_enabled(false);
    worker.set_clipboard_writes_enabled(true);
    worker.send_bytes(b"\n".to_vec()).unwrap();
    loop {
        match worker.try_event().unwrap() {
            Some(TerminalEvent::ClipboardWrite { .. }) => {
                panic!("hidden selection copy was delivered")
            }
            Some(TerminalEvent::Exited { code, .. }) => {
                assert_eq!(code, 0);
                break;
            }
            Some(TerminalEvent::Error(error)) => panic!("{error}"),
            _ => {}
        }
        assert!(
            Instant::now() < deadline,
            "worker did not finish after copy"
        );
        thread::sleep(Duration::from_millis(5));
    }
}
