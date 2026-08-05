use input::{KeyInput, Modifiers, NamedKey, TerminalModes, encode_input};

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
