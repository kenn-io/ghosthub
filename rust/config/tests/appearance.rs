use config::{CursorStyle, TerminalAppearance, TerminalTheme};

#[test]
fn default_terminal_appearance_is_projectable_without_ui_dependencies() {
    let appearance = TerminalAppearance::default();

    assert_eq!(appearance.font_family(), "Cascadia Mono");
    assert_eq!(appearance.font_size(), 14);
    assert_eq!(appearance.theme(), TerminalTheme::ClearDark);
    assert_eq!(appearance.background(), 0x21_27_34);
    assert_eq!(appearance.foreground(), 0xe6_e6_e6);
    assert_eq!(appearance.cursor_style(), CursorStyle::Block);
    assert!(!appearance.allow_shell_integration_cursor());
    assert!(appearance.hide_mouse_while_typing());
}

#[test]
fn user_authored_terminal_appearance_is_validated() {
    let appearance = TerminalAppearance::new("Iosevka Term", 16, "#102030", "#f0e0d0", false)
        .expect("valid terminal appearance");

    assert_eq!(appearance.font_family(), "Iosevka Term");
    assert_eq!(appearance.font_size(), 16);
    assert_eq!(appearance.theme(), TerminalTheme::Custom);
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

#[test]
fn built_in_themes_supply_their_own_colors() {
    let appearance = TerminalAppearance::themed(
        TerminalTheme::Ocean,
        "Cascadia Mono",
        14,
        "not-a-color",
        "also-not-a-color",
        true,
    )
    .expect("built-in themes do not require custom colors");

    assert_eq!(appearance.theme(), TerminalTheme::Ocean);
    assert_eq!(appearance.background(), 0x2b_66_c9);
    assert_eq!(appearance.foreground(), 0xff_ff_ff);
}
