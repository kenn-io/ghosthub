use std::fs;
use std::sync::Arc;

use host::{
    CancellationToken, KwtBundle, StdCommandRunner, SystemWslPresence, WslConfig, WslHost,
    WslPresence,
};

#[test]
#[ignore = "requires Windows, WSL2, and a staged pinned Linux KWT helper"]
fn installs_the_pinned_helper_and_reads_real_kwt_inventory() {
    let bundle_path = std::env::var_os("GHOSTHUB_KWT_BUNDLE_TEST")
        .expect("set GHOSTHUB_KWT_BUNDLE_TEST to the staged Linux helper");
    let digest = std::env::var("GHOSTHUB_KWT_SHA256_TEST")
        .expect("set GHOSTHUB_KWT_SHA256_TEST to its lowercase digest");
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("host crate is nested under rust/");
    let revision = fs::read_to_string(repo.join("KWT_REVISION"))
        .expect("read KWT revision")
        .trim()
        .to_owned();
    let bundle = KwtBundle::new(
        revision,
        digest,
        Arc::<[u8]>::from(fs::read(bundle_path).expect("read staged helper")),
    )
    .expect("valid helper bundle");
    let executable = SystemWslPresence
        .resolve()
        .expect("resolve WSL presence")
        .expect("WSL is installed");
    let host = WslHost::new(
        WslConfig::default().with_kwt_bundle(bundle),
        StdCommandRunner,
        executable,
    );

    let snapshot = host
        .discover_kwt_current(&CancellationToken::new())
        .expect("KWT inventory succeeds");

    assert!(snapshot.inventory().is_some());
    assert!(!snapshot.endpoint().distro().is_empty());
}
