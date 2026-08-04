#[test]
fn selects_the_current_target_platform() {
    assert_eq!(app::bootstrap_status().platform(), std::env::consts::OS,);
}
