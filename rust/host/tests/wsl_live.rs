#![cfg(windows)]

use std::env;
use std::process::{self, Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use host::{StdCommandRunner, WslConfig, WslHost};

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn discovers_an_isolated_wsl_tmux_session() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time")
        .as_millis();
    let distro = env::var("GHOSTHUB_WSL_DISTRO").unwrap_or_else(|_| "Ubuntu".to_owned());
    let suffix = format!("{}-{nonce}", process::id());
    let tmpdir = format!("/tmp/ghosthub-host-test-{suffix}");
    let session_name = format!("ghosthub-host-test-{suffix}");
    let cleanup = Cleanup {
        distro: distro.clone(),
        tmpdir: tmpdir.clone(),
        session_name: session_name.clone(),
    };

    assert_success(&run_wsl(&distro, ["/usr/bin/mkdir", "-p", "--", &tmpdir]));
    assert_success(&run_tmux(
        &distro,
        &tmpdir,
        ["new-session", "-d", "-s", &session_name],
    ));

    let host = WslHost::new(
        WslConfig::configured(Some(distro), "/usr/bin/tmux", Some(tmpdir))
            .expect("valid live config"),
        StdCommandRunner,
    );
    let snapshot = host.discover().expect("discover isolated tmux session");

    assert_eq!(snapshot.sessions().len(), 1);
    assert_eq!(snapshot.sessions()[0].name(), session_name);
    drop(cleanup);
}

struct Cleanup {
    distro: String,
    tmpdir: String,
    session_name: String,
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = run_tmux(
            &self.distro,
            &self.tmpdir,
            ["kill-session", "-t", &format!("={}", self.session_name)],
        );
        if self.tmpdir.starts_with("/tmp/ghosthub-host-test-") {
            let _ = run_wsl(&self.distro, ["/usr/bin/rm", "-rf", "--", &self.tmpdir]);
        }
    }
}

fn run_tmux<const N: usize>(distro: &str, tmpdir: &str, args: [&str; N]) -> Output {
    let mut command = Command::new("wsl.exe");
    command.args([
        "--distribution",
        distro,
        "--exec",
        "/usr/bin/env",
        &format!("TMUX_TMPDIR={tmpdir}"),
        "/usr/bin/tmux",
        "-f",
        "/dev/null",
    ]);
    command.args(args);
    command.output().expect("run isolated tmux command")
}

fn run_wsl<const N: usize>(distro: &str, args: [&str; N]) -> Output {
    Command::new("wsl.exe")
        .args(["--distribution", distro, "--exec"])
        .args(args)
        .output()
        .expect("run WSL command")
}

fn assert_success(output: &Output) {
    assert!(
        output.status.success(),
        "command failed: status={} stdout={} stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
