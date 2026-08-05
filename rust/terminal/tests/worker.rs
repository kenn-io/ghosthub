#[cfg(windows)]
mod windows {
    use std::ffi::OsString;
    use std::thread;
    use std::time::{Duration, Instant};

    use session::{AttachPlan, SessionIdentity};
    use surface::{GridSize, PixelSize};
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
                Ok(Some(TerminalEvent::Exited(code))) => {
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
}
