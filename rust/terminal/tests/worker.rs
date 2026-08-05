#[cfg(windows)]
mod windows {
    use std::ffi::OsString;
    use std::thread;
    use std::time::{Duration, Instant};

    use session::{AttachPlan, SessionIdentity};
    use surface::GridSize;
    use terminal::TerminalWorker;

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
            let text = surface
                .cells()
                .iter()
                .map(surface::Cell::text)
                .collect::<String>();
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
}
