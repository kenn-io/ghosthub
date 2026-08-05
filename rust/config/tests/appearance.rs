use config::TerminalAppearance;

#[test]
fn default_terminal_appearance_is_projectable_without_ui_dependencies() {
    let appearance = TerminalAppearance::default();

    assert_eq!(appearance.font_family(), "Cascadia Mono");
    assert_eq!(appearance.font_size(), 14);
    assert_eq!(appearance.background(), 0x11_13_18);
    assert_eq!(appearance.foreground(), 0xee_f0_f4);
}
