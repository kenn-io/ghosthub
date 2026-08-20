#[cfg(windows)]
mod windows {
    use std::ffi::OsString;
    use std::thread;
    use std::time::{Duration, Instant};

    use input::{KeyInput, Modifiers};
    use session::{AttachPlan, SessionIdentity};
    use surface::{CursorShape, GridSize, PixelSize};
    use terminal::{TerminalEvent, TerminalWorker};

    #[test]
    fn conpty_relay_publishes_child_output() {
        let plan = AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/c", "echo worker-ready"]
                .into_iter()
                .map(OsString::from)
                .collect(),
            "worker-test",
            SessionIdentity::new(1, "$1", 1),
        );
        let size = GridSize::new(40, 4).expect("valid grid");

        let worker = TerminalWorker::attach(&plan, size).expect("attach ConPTY client");

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let surface = worker.surface().load();
            let text = surface.cells().map(surface::Cell::text).collect::<String>();
            if text.contains("worker-ready") {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "child output did not reach surface"
            );
            drop(surface);
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn cursor_default_updates_reach_an_open_terminal_engine() {
        let plan = AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/c", "ping -n 4 127.0.0.1 >nul"]
                .into_iter()
                .map(OsString::from)
                .collect(),
            "worker-cursor-test",
            SessionIdentity::new(1, "$1", 1),
        );
        let worker = TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
            .expect("attach ConPTY client");

        worker.set_default_cursor_shape(CursorShape::Underline);

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let shape = worker.surface().load().cursor().map(|cursor| cursor.shape);
            if shape == Some(CursorShape::Underline) {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "cursor default did not reach the terminal engine"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn conpty_eof_reports_the_child_exit_status() {
        let plan = AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/c", "exit 7"]
                .into_iter()
                .map(OsString::from)
                .collect(),
            "worker-exit-test",
            SessionIdentity::new(1, "$1", 1),
        );
        let worker = TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
            .expect("attach ConPTY client");
        let deadline = Instant::now() + Duration::from_secs(5);

        loop {
            match worker.try_event() {
                Ok(Some(TerminalEvent::Exited { code, .. })) => {
                    assert_eq!(code, 7);
                    break;
                }
                Ok(Some(_) | None) => {}
                Err(error) => panic!("event channel disconnected before exit: {error}"),
            }
            assert!(Instant::now() < deadline, "child exit was not reported");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn alternate_screen_output_confirms_a_live_client() {
        let command = format!(
            "echo {}[?1049h{}[?1049l & ping -n 4 127.0.0.1 >nul",
            '\x1b', '\x1b'
        );
        let plan = AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/c", &command]
                .into_iter()
                .map(OsString::from)
                .collect(),
            "worker-live-test",
            SessionIdentity::new(1, "$1", 1),
        );
        let worker = TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
            .expect("attach ConPTY client");
        let deadline = Instant::now() + Duration::from_secs(5);

        while !worker.is_confirmed_live() {
            assert!(
                Instant::now() < deadline,
                "alternate-screen output did not confirm the live client"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn delayed_plain_startup_failure_is_not_confirmed_live() {
        let plan = AttachPlan::attach_only(
            "cmd.exe",
            [
                "/d",
                "/c",
                "ping -n 2 127.0.0.1 >nul & echo missing or unsuitable terminal: xterm-256color & exit /b 7",
            ]
            .into_iter()
            .map(OsString::from)
            .collect(),
            "worker-delayed-failure-test",
            SessionIdentity::new(1, "$1", 1),
        );
        let worker = TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
            .expect("attach ConPTY client");
        let deadline = Instant::now() + Duration::from_secs(5);

        loop {
            match worker.try_event() {
                Ok(Some(TerminalEvent::Exited { code, output_tail })) => {
                    assert_eq!(code, 7);
                    assert!(output_tail.contains("missing or unsuitable terminal"));
                    assert!(
                        !worker.is_confirmed_live(),
                        "plain startup output was treated as terminal initialization: {}",
                        output_tail.escape_debug()
                    );
                    break;
                }
                Ok(Some(_) | None) => {}
                Err(error) => panic!("event channel disconnected before exit: {error}"),
            }
            assert!(
                Instant::now() < deadline,
                "delayed startup failure was not reported"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn exit_event_includes_output_written_immediately_before_exit() {
        let plan = AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/c", "echo missing or unsuitable terminal& exit /b 7"]
                .into_iter()
                .map(OsString::from)
                .collect(),
            "worker-output-tail-test",
            SessionIdentity::new(1, "$1", 1),
        );
        let worker = TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
            .expect("attach ConPTY client");
        let deadline = Instant::now() + Duration::from_secs(5);

        loop {
            match worker.try_event() {
                Ok(Some(TerminalEvent::Exited { code, output_tail })) => {
                    assert_eq!(code, 7);
                    assert!(output_tail.contains("missing or unsuitable terminal"));
                    break;
                }
                Ok(Some(_) | None) => {}
                Err(error) => panic!("event channel disconnected before exit: {error}"),
            }
            assert!(Instant::now() < deadline, "child exit was not reported");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn ordered_resize_reaches_the_published_surface() {
        let plan = AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/c", "ping -n 4 127.0.0.1 >nul"]
                .into_iter()
                .map(OsString::from)
                .collect(),
            "worker-resize-test",
            SessionIdentity::new(1, "$1", 1),
        );
        let initial = GridSize::new(40, 4).expect("valid grid");
        let resized = GridSize::new(72, 18).expect("valid grid");
        let worker = TerminalWorker::attach(&plan, initial).expect("attach ConPTY client");

        worker
            .resize_with_metadata(resized, 9, PixelSize::new(900, 540))
            .expect("queue ordered resize");

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let frame = worker.surface().load();
            if frame.resize_sequence() == 9 {
                assert_eq!(frame.size(), resized);
                assert_eq!(frame.pixel_size(), PixelSize::new(900, 540));
                break;
            }
            assert!(Instant::now() < deadline, "resize was not published");
            drop(frame);
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn unsafe_paste_blocks_later_input_until_approval() {
        let worker = interactive_cmd_worker("worker-paste-order-test");

        worker
            .send_key(KeyInput::paste("echo paste-approved\n"))
            .expect("queue unsafe paste");
        let paste = wait_for_confirmation(&worker);
        worker
            .send_key(KeyInput::text("echo typed-later", Modifiers::default()))
            .expect("queue later text");
        worker
            .send_key(KeyInput::text("\r", Modifiers::default()))
            .expect("queue later enter");

        thread::sleep(Duration::from_millis(200));
        assert!(!surface_text(&worker).contains("typed-later"));

        worker.confirm_paste(paste).expect("approve unsafe paste");
        let output = wait_for_surface_text(&worker, "typed-later");
        assert!(
            output
                .find("paste-approved")
                .expect("approved paste output")
                < output.find("typed-later").expect("later input output")
        );
    }

    #[test]
    fn cancelling_unsafe_paste_discards_it_before_resuming_input() {
        let worker = interactive_cmd_worker("worker-paste-cancel-test");

        worker
            .send_key(KeyInput::paste("echo must-not-run\n"))
            .expect("queue unsafe paste");
        let _paste = wait_for_confirmation(&worker);
        worker
            .send_key(KeyInput::text("echo resumed", Modifiers::default()))
            .expect("queue later text");
        worker
            .send_key(KeyInput::text("\r", Modifiers::default()))
            .expect("queue later enter");
        worker.cancel_paste().expect("cancel unsafe paste");

        let output = wait_for_surface_text(&worker, "resumed");
        assert!(!output.contains("must-not-run"));
    }

    #[test]
    fn pending_paste_places_a_finite_bound_on_later_input() {
        let worker = interactive_cmd_worker("worker-paste-bound-test");

        worker
            .send_key(KeyInput::paste("echo blocked\n"))
            .expect("queue unsafe paste");
        let _paste = wait_for_confirmation(&worker);

        let rejected = (0..10_000).any(|_| {
            worker
                .send_key(KeyInput::text("x", Modifiers::default()))
                .is_err()
        });

        assert!(rejected, "pending input must have a finite capacity");
        worker
            .cancel_paste()
            .expect("cancel remains independently usable");
    }

    fn interactive_cmd_worker(name: &str) -> TerminalWorker {
        let plan = AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/q"].into_iter().map(OsString::from).collect(),
            name,
            SessionIdentity::new(1, "$1", 1),
        );
        TerminalWorker::attach(&plan, GridSize::new(80, 8).expect("valid grid"))
            .expect("attach interactive ConPTY client")
    }

    fn wait_for_confirmation(worker: &TerminalWorker) -> input::EncodedInput {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match worker.try_event() {
                Ok(Some(TerminalEvent::ConfirmPaste(paste))) => return paste,
                Ok(Some(_) | None) => {}
                Err(error) => panic!("event channel disconnected before confirmation: {error}"),
            }
            assert!(
                Instant::now() < deadline,
                "unsafe paste confirmation was not reported"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn wait_for_surface_text(worker: &TerminalWorker, expected: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let text = surface_text(worker);
            if text.contains(expected) {
                return text;
            }
            assert!(
                Instant::now() < deadline,
                "terminal surface did not contain {expected:?}"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn surface_text(worker: &TerminalWorker) -> String {
        worker
            .surface()
            .load()
            .cells()
            .map(surface::Cell::text)
            .collect()
    }
}
