use config::{ApplicationConfig, KeyChord, ShortcutAction};

#[test]
fn shortcuts_resolve_defaults_and_validate_overrides_before_saving() {
    let mut keyboard = ApplicationConfig::default().keyboard().clone();
    assert_eq!(
        keyboard
            .binding(ShortcutAction::NextSession)
            .unwrap()
            .config_value(),
        "ctrl+tab"
    );
    keyboard
        .set(ShortcutAction::ToggleSidebar, Some("Alt+Shift+B"))
        .unwrap();
    assert_eq!(
        keyboard
            .binding(ShortcutAction::ToggleSidebar)
            .unwrap()
            .config_value(),
        "alt+shift+b"
    );
    keyboard
        .set(ShortcutAction::NextSession, Some("none"))
        .unwrap();
    assert!(keyboard.binding(ShortcutAction::NextSession).is_none());
    keyboard
        .set(ShortcutAction::ToggleSidebar, Some("ctrl+tab"))
        .unwrap();
    let before = keyboard.clone();
    assert!(keyboard.set(ShortcutAction::NextSession, None).is_err());
    assert_eq!(
        keyboard, before,
        "a conflicting reset keeps the previous bindings"
    );
    keyboard.set(ShortcutAction::ToggleSidebar, None).unwrap();
    keyboard.set(ShortcutAction::NextSession, None).unwrap();
    assert_eq!(keyboard, ApplicationConfig::default().keyboard().clone());
}

#[test]
fn invalid_or_conflicting_shortcuts_reject_the_configuration() {
    for chord in [
        "b",
        "shift+b",
        "ctrl+ctrl+b",
        "ctrl+shift+v",
        "ctrl+shift+c",
        "alt+f4",
        "ctrl+alt+delete",
        "ctrl+unknown",
        "ctrl+f01",
        "ctrl+",
        "ctrl+a+b",
    ] {
        assert!(KeyChord::parse(chord).is_err(), "{chord}");
    }
    for content in [
        "[keyboard.shortcuts]\nnext-session = 'ctrl+shift+b'",
        "[keyboard.shortcuts]\ntoggle-sidebar = 'ctrl+shift+v'",
        "[keyboard.shortcuts]\nunknown = 'ctrl+k'",
    ] {
        assert!(ApplicationConfig::from_toml(content).is_err(), "{content}");
    }
    let config = ApplicationConfig::from_toml(
        "[keyboard.shortcuts]\nnext-session = 'alt+right'\nprevious-session = 'none'",
    )
    .unwrap();
    assert_eq!(
        config
            .keyboard()
            .binding(ShortcutAction::NextSession)
            .unwrap()
            .display(),
        "Alt+Right"
    );
    assert!(
        config
            .keyboard()
            .binding(ShortcutAction::PreviousSession)
            .is_none()
    );
}
