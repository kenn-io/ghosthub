use input::{
    KeyInput, Modifiers, MouseAction, MouseButton, MouseInput, MouseTracking, NamedKey,
    TerminalModes, encode_input, encode_mouse,
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
        b"\x1b[200~line one\nline two\x1b[201~"
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

    assert!(encoded.requires_confirmation());
    assert_eq!(encoded.approve(), b"echo safe\x1b[2J");
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
