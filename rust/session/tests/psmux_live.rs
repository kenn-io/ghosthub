#![cfg(windows)]

use std::{
    env, process,
    time::{SystemTime, UNIX_EPOCH},
};

use session::probe::{ProbeNamespace, probe_psmux};
use session::{ExecutablePlatform, resolve_tmux_binary};

#[test]
#[ignore = "requires an explicitly resolved psmux executable and creates an isolated server"]
fn installed_psmux_proves_every_required_capability() {
    let executable = env::var("GHOSTHUB_PSMUX_EXE")
        .expect("set GHOSTHUB_PSMUX_EXE to an absolute psmux.exe path");
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time")
        .as_millis();
    let namespace = ProbeNamespace::new(&format!("ghosthub-test-{}-{nonce}", process::id()))
        .expect("generated namespace");

    let report = probe_psmux(&executable, &namespace).expect("run isolated psmux probe");
    let verified = resolve_tmux_binary(
        ExecutablePlatform::Windows,
        &executable,
        report.version_output(),
        report.observations(),
    );

    assert!(verified.is_ok(), "psmux is not admissible: {report:#?}");
}
