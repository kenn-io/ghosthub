use input::{KeyInput, Modifiers, NamedKey, TerminalModes, encode_input};

#[test]
fn encodes_text_without_synthetic_altgr_modifiers() {
    let input = KeyInput::text("@", Modifiers::default());

    assert_eq!(encode_input(&input, TerminalModes::default()), b"@");
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

    assert_eq!(encode_input(&input, TerminalModes::default()), b"\x01");
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

    assert_eq!(encode_input(&input, TerminalModes::default()), b"\x1bx");
}

#[test]
fn application_cursor_mode_changes_arrow_encoding() {
    let input = KeyInput::named(NamedKey::ArrowUp, Modifiers::default());

    assert_eq!(encode_input(&input, TerminalModes::default()), b"\x1b[A");
    assert_eq!(
        encode_input(
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

    assert_eq!(
        encode_input(&input, TerminalModes::default()),
        b"line one\nline two"
    );
    assert_eq!(
        encode_input(
            &input,
            TerminalModes {
                bracketed_paste: true,
                ..TerminalModes::default()
            },
        ),
        b"\x1b[200~line one\nline two\x1b[201~"
    );
}
