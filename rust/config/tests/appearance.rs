use config::TerminalAppearance;

#[test]
fn default_terminal_appearance_is_projectable_without_ui_dependencies() {
    let appearance = TerminalAppearance::default();

    assert_eq!(appearance.font_family(), "Cascadia Mono");
    assert_eq!(appearance.font_size(), 14);
    assert_eq!(appearance.background(), 0x0c_0f_14);
    assert_eq!(appearance.foreground(), 0xd8_de_e9);
}

#[test]
fn user_authored_terminal_appearance_is_validated() {
    let appearance = TerminalAppearance::new("Iosevka Term", 16, "#102030", "#f0e0d0", false)
        .expect("valid terminal appearance");

    assert_eq!(appearance.font_family(), "Iosevka Term");
    assert_eq!(appearance.font_size(), 16);
    assert_eq!(appearance.background(), 0x10_20_30);
    assert_eq!(appearance.foreground(), 0xf0_e0_d0);
    assert!(!appearance.allow_remote_clipboard_write());

    for invalid in [
        TerminalAppearance::new("", 16, "#102030", "#f0e0d0", true),
        TerminalAppearance::new("Iosevka Term", 0, "#102030", "#f0e0d0", true),
        TerminalAppearance::new("Iosevka Term", 16, "102030", "#f0e0d0", true),
        TerminalAppearance::new("Iosevka Term", 16, "#102030", "#nope00", true),
    ] {
        assert!(invalid.is_err());
    }
}
