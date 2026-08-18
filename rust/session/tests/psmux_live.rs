#![cfg(windows)]

use std::{
    env, process,
    time::{SystemTime, UNIX_EPOCH},
};

use session::probe::{ProbeNamespace, probe_psmux};
use session::{ExecutablePlatform, ResolveErrorKind, resolve_tmux_binary};

#[test]
#[ignore = "requires an explicitly resolved psmux executable and creates an isolated server"]
fn installed_psmux_remains_inadmissible() {
    let executable = env::var("GHOSTHUB_PSMUX_EXE")
        .expect("set GHOSTHUB_PSMUX_EXE to an absolute psmux.exe path");
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time")
        .as_millis();
    let namespace = ProbeNamespace::new(&format!("ghosthub-test-{}-{nonce}", process::id()))
        .expect("generated namespace");

    let report = probe_psmux(&executable, &namespace).expect("run isolated psmux probe");
    let exact_targets = report
        .observations()
        .iter()
        .find(|observation| observation.name == "exact-targets")
        .expect("exact-target observation");
    assert!(
        !exact_targets.is_supported(),
        "this psmux build unexpectedly passed the exact-target probe: {report:#?}"
    );

    let error = resolve_tmux_binary(
        ExecutablePlatform::Windows,
        &executable,
        report.version_output(),
        report.observations(),
    )
    .expect_err("this psmux build must remain inadmissible");

    assert_eq!(error.kind(), ResolveErrorKind::MissingCapability);
}
