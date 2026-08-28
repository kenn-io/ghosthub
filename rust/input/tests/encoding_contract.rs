use input::{
    KeyEvent, KeyInput, KittyKeyboard, Modifiers, ModifyOtherKeys, MouseAction, MouseButton,
    MouseInput, MouseTracking, NamedKey, TerminalModes, encode_input, encode_mouse,
};

fn ready(input: &KeyInput, modes: TerminalModes) -> Vec<u8> {
    let encoded = encode_input(input, modes);
    assert!(!encoded.requires_confirmation());
    encoded.approve()
}

#[test]
fn encodes_text_without_synthetic_altgr_modifiers() {
    let input = KeyInput::text("@", Modifiers::default());

    assert_eq!(ready(&input, TerminalModes::default()), b"@");
}

#[test]
fn encodes_control_text_as_ascii_control_bytes() {
    let input = KeyInput::text(
        "a",
        Modifiers {
            control: true,
            ..Modifiers::default()
        },
    );

    assert_eq!(ready(&input, TerminalModes::default()), b"\x01");
}

#[test]
fn encodes_conventional_control_key_aliases() {
    for (text, expected) in [
        (" ", 0x00),
        ("2", 0x00),
        ("`", 0x00),
        ("3", 0x1b),
        ("4", 0x1c),
        ("5", 0x1d),
        ("6", 0x1e),
        ("7", 0x1f),
        ("/", 0x1f),
        ("8", 0x7f),
    ] {
        let input = KeyInput::text(
            text,
            Modifiers {
                control: true,
                ..Modifiers::default()
            },
        );

        assert_eq!(ready(&input, TerminalModes::default()), [expected]);
    }
}

#[test]
fn prefixes_alt_text_with_escape() {
    let input = KeyInput::text(
        "x",
        Modifiers {
            alt: true,
            ..Modifiers::default()
        },
    );

    assert_eq!(ready(&input, TerminalModes::default()), b"\x1bx");
}

#[test]
fn application_cursor_mode_changes_arrow_encoding() {
    let input = KeyInput::named(NamedKey::ArrowUp, Modifiers::default());

    assert_eq!(ready(&input, TerminalModes::default()), b"\x1b[A");
    assert_eq!(
        ready(
            &input,
            TerminalModes {
                application_cursor: true,
                ..TerminalModes::default()
            },
        ),
        b"\x1bOA"
    );
}

#[test]
fn application_keypad_mode_preserves_keypad_identity() {
    let digit = KeyInput::named(NamedKey::KeypadDigit(7), Modifiers::default());
    let enter = KeyInput::named(NamedKey::KeypadEnter, Modifiers::default());

    assert_eq!(ready(&digit, TerminalModes::default()), b"7");
    assert_eq!(ready(&enter, TerminalModes::default()), b"\r");

    let modes = TerminalModes {
        application_keypad: true,
        ..TerminalModes::default()
    };
    assert_eq!(ready(&digit, modes), b"\x1bOw");
    assert_eq!(ready(&enter, modes), b"\x1bOM");
}

#[test]
fn modify_other_keys_preserves_well_defined_controls() {
    let alt_a = KeyInput::text(
        "a",
        Modifiers {
            alt: true,
            ..Modifiers::default()
        },
    );
    let control_space = KeyInput::text(
        " ",
        Modifiers {
            control: true,
            ..Modifiers::default()
        },
    );
    let modes = TerminalModes {
        modify_other_keys: ModifyOtherKeys::ExceptWellDefined,
        ..TerminalModes::default()
    };

    assert_eq!(ready(&alt_a, modes), b"\x1b[27;3;97~");
    assert_eq!(ready(&control_space, modes), b"\0");
}

#[test]
fn modify_other_keys_all_encodes_shifted_text() {
    let shifted_a = KeyInput::text(
        "A",
        Modifiers {
            shift: true,
            ..Modifiers::default()
        },
    );
    let modes = TerminalModes {
        modify_other_keys: ModifyOtherKeys::All,
        ..TerminalModes::default()
    };

    assert_eq!(ready(&shifted_a, modes), b"\x1b[27;2;65~");
}

#[test]
fn modify_other_keys_preserves_composed_text() {
    let composed = KeyInput::text(
        "e\u{301}",
        Modifiers {
            control: true,
            ..Modifiers::default()
        },
    );
    let modes = TerminalModes {
        modify_other_keys: ModifyOtherKeys::All,
        ..TerminalModes::default()
    };

    assert_eq!(ready(&composed, modes), "e\u{301}".as_bytes());
}

#[test]
fn kitty_disambiguates_modified_text_and_keypad_keys() {
    let control_a = KeyInput::text(
        "a",
        Modifiers {
            control: true,
            ..Modifiers::default()
        },
    );
    let keypad_one = KeyInput::named(NamedKey::KeypadDigit(1), Modifiers::default());
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            disambiguate_escape_codes: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };

    assert_eq!(ready(&control_a, modes), b"\x1b[97;5u");
    assert_eq!(ready(&keypad_one, modes), b"\x1b[57400u");
}

#[test]
fn kitty_reports_press_events_for_functional_keys() {
    let up = KeyInput::named(NamedKey::ArrowUp, Modifiers::default());
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            report_event_types: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };

    assert_eq!(ready(&up, modes), b"\x1b[1;1:1A");
}

#[test]
fn kitty_reports_shifted_alternate_key_codes() {
    let control_shift_a = KeyInput::text(
        "A",
        Modifiers {
            shift: true,
            control: true,
            ..Modifiers::default()
        },
    );
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            disambiguate_escape_codes: true,
            report_alternate_keys: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };

    assert_eq!(ready(&control_shift_a, modes), b"\x1b[97:65;6u");
}

#[test]
fn kitty_reports_shifted_punctuation_from_its_logical_key() {
    let control_shift_one = KeyInput::text_with_key(
        "!",
        "1",
        Modifiers {
            shift: true,
            control: true,
            ..Modifiers::default()
        },
    );
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            disambiguate_escape_codes: true,
            report_alternate_keys: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };

    assert_eq!(ready(&control_shift_one, modes), b"\x1b[49:33;6u");
}

#[test]
fn kitty_disambiguates_modified_control_keys() {
    let modifiers = Modifiers {
        control: true,
        ..Modifiers::default()
    };
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            disambiguate_escape_codes: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };

    for (key, expected) in [
        (NamedKey::Enter, b"\x1b[13;5u".as_slice()),
        (NamedKey::Tab, b"\x1b[9;5u".as_slice()),
        (NamedKey::Backspace, b"\x1b[127;5u".as_slice()),
    ] {
        assert_eq!(ready(&KeyInput::named(key, modifiers), modes), expected);
    }
}

#[test]
fn kitty_reports_press_repeat_and_release_events() {
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            report_event_types: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };
    let up = KeyInput::named(NamedKey::ArrowUp, Modifiers::default());

    assert_eq!(ready(&up, modes), b"\x1b[1;1:1A");
    assert_eq!(
        ready(&up.clone().with_event(KeyEvent::Repeat), modes),
        b"\x1b[1;1:2A"
    );
    assert_eq!(
        ready(&up.with_event(KeyEvent::Release), modes),
        b"\x1b[1;1:3A"
    );
}

#[test]
fn kitty_reports_events_for_disambiguated_text() {
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            disambiguate_escape_codes: true,
            report_event_types: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };
    let control_a = KeyInput::text(
        "a",
        Modifiers {
            control: true,
            ..Modifiers::default()
        },
    );

    assert_eq!(
        ready(&control_a.clone().with_event(KeyEvent::Repeat), modes),
        b"\x1b[97;5:2u"
    );
    assert_eq!(
        ready(&control_a.with_event(KeyEvent::Release), modes),
        b"\x1b[97;5:3u"
    );
}

#[test]
fn kitty_release_omits_associated_text() {
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            report_event_types: true,
            report_all_keys_as_escape_codes: true,
            report_associated_text: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };
    let release = KeyInput::text("a", Modifiers::default()).with_event(KeyEvent::Release);

    assert_eq!(ready(&release, modes), b"\x1b[97;1:3u");
}

#[test]
fn kitty_event_types_alone_preserve_legacy_text_and_control_keys() {
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            report_event_types: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };
    let text = KeyInput::text("a", Modifiers::default());
    let enter = KeyInput::named(NamedKey::Enter, Modifiers::default());

    assert_eq!(ready(&text, modes), b"a");
    assert_eq!(
        ready(&text.clone().with_event(KeyEvent::Repeat), modes),
        b"a"
    );
    assert!(
        ready(&text.with_event(KeyEvent::Release), modes).is_empty(),
        "text releases require report-all"
    );
    assert_eq!(ready(&enter, modes), b"\r");
    assert_eq!(
        ready(&enter.clone().with_event(KeyEvent::Repeat), modes),
        b"\r"
    );
    assert!(
        ready(&enter.with_event(KeyEvent::Release), modes).is_empty(),
        "Enter releases require report-all"
    );
}

#[test]
fn named_releases_require_event_type_reporting() {
    let escape =
        KeyInput::named(NamedKey::Escape, Modifiers::default()).with_event(KeyEvent::Release);
    let keypad = KeyInput::named(NamedKey::KeypadDigit(1), Modifiers::default())
        .with_event(KeyEvent::Release);

    for kitty_keyboard in [
        KittyKeyboard {
            disambiguate_escape_codes: true,
            ..KittyKeyboard::default()
        },
        KittyKeyboard {
            report_all_keys_as_escape_codes: true,
            ..KittyKeyboard::default()
        },
    ] {
        let modes = TerminalModes {
            kitty_keyboard,
            ..TerminalModes::default()
        };
        assert!(ready(&escape, modes).is_empty());
        assert!(ready(&keypad, modes).is_empty());
    }
}

#[test]
fn release_events_are_silent_without_negotiated_reporting() {
    let release = KeyInput::text("x", Modifiers::default()).with_event(KeyEvent::Release);

    assert!(ready(&release, TerminalModes::default()).is_empty());
}

#[test]
fn kitty_can_report_all_keys_with_associated_text() {
    let input = KeyInput::text("a", Modifiers::default());
    let all_keys = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            report_all_keys_as_escape_codes: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };
    let associated_text = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            report_all_keys_as_escape_codes: true,
            report_associated_text: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };

    assert_eq!(ready(&input, all_keys), b"\x1b[97u");
    assert_eq!(ready(&input, associated_text), b"\x1b[97;1;97u");
}

#[test]
fn kitty_preserves_composed_text_that_is_not_one_key() {
    let modes = TerminalModes {
        kitty_keyboard: KittyKeyboard {
            report_event_types: true,
            report_all_keys_as_escape_codes: true,
            report_associated_text: true,
            ..KittyKeyboard::default()
        },
        ..TerminalModes::default()
    };
    let composed = KeyInput::text_with_key(
        "\u{1f469}\u{200d}\u{1f4bb}",
        "compose",
        Modifiers {
            alt: true,
            ..Modifiers::default()
        },
    );

    assert_eq!(
        ready(&composed, modes),
        "\u{1f469}\u{200d}\u{1f4bb}".as_bytes()
    );
    assert!(
        ready(&composed.with_event(KeyEvent::Release), modes).is_empty(),
        "a release must not recommit composed text"
    );
}

#[test]
fn bracketed_paste_is_mode_dependent() {
    let input = KeyInput::paste("line one\nline two");

    let unbracketed = encode_input(&input, TerminalModes::default());
    assert!(unbracketed.requires_confirmation());
    assert_eq!(unbracketed.approve(), b"line one\rline two");
    assert_eq!(
        ready(
            &input,
            TerminalModes {
                bracketed_paste: true,
                ..TerminalModes::default()
            },
        ),
        b"\x1b[200~line one\rline two\x1b[201~"
    );
}

#[test]
fn bracketed_paste_normalizes_windows_line_endings() {
    let input = KeyInput::paste("first\r\nsecond\rthird\nfourth");

    assert_eq!(
        ready(
            &input,
            TerminalModes {
                bracketed_paste: true,
                ..TerminalModes::default()
            },
        ),
        b"\x1b[200~first\rsecond\rthird\rfourth\x1b[201~"
    );
}

#[test]
fn single_line_paste_is_safe_without_bracketed_mode() {
    let input = KeyInput::paste("single line");

    assert_eq!(ready(&input, TerminalModes::default()), b"single line");
}

#[test]
fn control_characters_require_confirmation_without_bracketed_mode() {
    let input = KeyInput::paste("echo safe\x1b[2J");

    let encoded = encode_input(&input, TerminalModes::default());

    // The control still gates the paste, and the delivered bytes have the
    // ESC stripped rather than passing the control sequence through.
    assert!(encoded.requires_confirmation());
    assert_eq!(encoded.approve(), b"echo safe[2J");
}

#[test]
fn embedded_bracketed_paste_terminator_requires_confirmation() {
    let input = KeyInput::paste("safe\x1b[201~echo injected\n");
    let encoded = encode_input(
        &input,
        TerminalModes {
            bracketed_paste: true,
            ..TerminalModes::default()
        },
    );

    assert!(encoded.requires_confirmation());
}

#[test]
fn legacy_modified_keys_preserve_terminal_modifiers() {
    let shift_tab = KeyInput::named(
        NamedKey::Tab,
        Modifiers {
            shift: true,
            ..Modifiers::default()
        },
    );
    assert_eq!(ready(&shift_tab, TerminalModes::default()), b"\x1b[Z");

    let control_alt_up = KeyInput::named(
        NamedKey::ArrowUp,
        Modifiers {
            control: true,
            alt: true,
            ..Modifiers::default()
        },
    );
    assert_eq!(
        ready(&control_alt_up, TerminalModes::default()),
        b"\x1b[1;7A"
    );
}

#[test]
fn sgr_mouse_encodes_coordinates_beyond_the_legacy_limit() {
    let input = MouseInput {
        action: MouseAction::Press(MouseButton::Left),
        column: 119,
        row: 39,
        modifiers: Modifiers::default(),
    };
    let modes = TerminalModes {
        mouse_tracking: MouseTracking::Click,
        sgr_mouse: true,
        ..TerminalModes::default()
    };

    assert_eq!(encode_mouse(input, modes), b"\x1b[<0;120;40M");
}

#[test]
fn sgr_mouse_preserves_modifiers_motion_and_release() {
    let modes = TerminalModes {
        mouse_tracking: MouseTracking::Drag,
        sgr_mouse: true,
        ..TerminalModes::default()
    };
    let modifiers = Modifiers {
        shift: true,
        control: true,
        alt: false,
    };

    assert_eq!(
        encode_mouse(
            MouseInput {
                action: MouseAction::Move(Some(MouseButton::Right)),
                column: 4,
                row: 2,
                modifiers,
            },
            modes,
        ),
        b"\x1b[<54;5;3M"
    );
    assert_eq!(
        encode_mouse(
            MouseInput {
                action: MouseAction::Release(MouseButton::Right),
                column: 4,
                row: 2,
                modifiers,
            },
            modes,
        ),
        b"\x1b[<22;5;3m"
    );
}

#[test]
fn mouse_input_is_silent_when_the_application_did_not_enable_tracking() {
    let input = MouseInput {
        action: MouseAction::WheelUp,
        column: 1,
        row: 1,
        modifiers: Modifiers::default(),
    };

    assert!(encode_mouse(input, TerminalModes::default()).is_empty());
}
