use std::ffi::OsString;
use std::io;
use std::thread;
use std::time::{Duration, Instant};

use host::{CancellationToken, CommandRunner, StdCommandRunner};

#[test]
fn cancellation_terminates_a_stalled_child() {
    let cancellation = CancellationToken::new();
    let trigger = cancellation.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(50));
        trigger.cancel();
    });
    let started = Instant::now();

    let error = StdCommandRunner
        .run(
            std::env::current_exe()
                .expect("current test executable")
                .as_os_str(),
            &helper_args(),
            &cancellation,
            Duration::from_secs(5),
        )
        .expect_err("cancelled child must fail");

    assert_eq!(error.kind(), io::ErrorKind::Interrupted);
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn deadline_terminates_a_stalled_child() {
    let started = Instant::now();

    let error = StdCommandRunner
        .run(
            std::env::current_exe()
                .expect("current test executable")
                .as_os_str(),
            &helper_args(),
            &CancellationToken::new(),
            Duration::from_millis(50),
        )
        .expect_err("timed-out child must fail");

    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(2));
}

fn helper_args() -> Vec<OsString> {
    ["--ignored", "--exact", "blocking_runner_helper"]
        .into_iter()
        .map(OsString::from)
        .collect()
}

#[test]
#[ignore = "subprocess helper selected explicitly by the runner tests"]
fn blocking_runner_helper() {
    loop {
        thread::sleep(Duration::from_secs(1));
    }
}
