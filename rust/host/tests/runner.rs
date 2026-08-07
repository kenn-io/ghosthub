use std::ffi::OsString;
use std::io::{self, Write};
use std::process::Command;
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

#[test]
fn descendant_inheriting_output_pipe_cannot_stall_collection() {
    let started = Instant::now();

    let output = StdCommandRunner
        .run(
            std::env::current_exe()
                .expect("current test executable")
                .as_os_str(),
            &exact_helper_args("descendant_pipe_holder_helper"),
            &CancellationToken::new(),
            Duration::from_secs(5),
        )
        .expect("contained descendants must release inherited output pipes");

    assert_eq!(output.status, 0);
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("parent complete"),
        "parent output must be drained before the inherited pipe is contained"
    );
    assert!(started.elapsed() < Duration::from_secs(2));
}

fn helper_args() -> Vec<OsString> {
    exact_helper_args("blocking_runner_helper")
}

fn exact_helper_args(name: &str) -> Vec<OsString> {
    ["--ignored", "--exact", name]
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

#[test]
#[ignore = "subprocess helper selected explicitly by the runner tests"]
#[allow(
    clippy::zombie_processes,
    reason = "the parent must exit without waiting to reproduce an inherited-pipe descendant"
)]
fn descendant_pipe_holder_helper() {
    Command::new(std::env::current_exe().expect("current test executable"))
        .args(exact_helper_args("pipe_holder_helper"))
        .spawn()
        .expect("spawn inherited-pipe descendant");
    io::stdout()
        .write_all(b"parent complete\n")
        .expect("write parent output");
}

#[test]
#[ignore = "subprocess helper selected explicitly by the runner tests"]
fn pipe_holder_helper() {
    thread::sleep(Duration::from_secs(30));
}
