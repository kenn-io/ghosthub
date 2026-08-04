use model::PortStatus;

#[test]
fn formats_the_platform_bootstrap_headline() {
    let status = PortStatus::new("Windows");

    assert_eq!(status.platform(), "Windows");
    assert_eq!(status.headline(), "Ghosthub Rust port · Windows");
}
