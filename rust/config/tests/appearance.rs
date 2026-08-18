use config::TerminalAppearance;

#[test]
fn default_terminal_appearance_is_projectable_without_ui_dependencies() {
    let appearance = TerminalAppearance::default();

    assert_eq!(appearance.font_family(), "Cascadia Mono");
    assert_eq!(appearance.font_size(), 14);
    assert_eq!(appearance.background(), 0x0c_0f_14);
    assert_eq!(appearance.foreground(), 0xd8_de_e9);
}
