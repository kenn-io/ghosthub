#[test]
fn selects_the_current_target_platform() {
    #[cfg(target_os = "windows")]
    let expected = "Windows";
    #[cfg(target_os = "linux")]
    let expected = "Linux";

    let status = app::bootstrap_status();

    assert_eq!(status.platform(), expected);
    assert_eq!(
        status.headline(),
        format!("Ghosthub Rust port · {expected}")
    );
}
