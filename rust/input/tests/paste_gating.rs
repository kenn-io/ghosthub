//! The confirmation gate for bracketed pastes: embedded controls that
//! could smuggle an end marker (or its single-byte C1 equivalent) never
//! reach the PTY without explicit approval, while ordinary multi-line or
//! tabbed pastes flow through.

use input::{KeyInput, TerminalModes, encode_input};

fn bracketed() -> TerminalModes {
    TerminalModes {
        bracketed_paste: true,
        ..TerminalModes::default()
    }
}

#[test]
fn bracketed_pastes_gate_embedded_controls() {
    for smuggled in [
        "safe\u{001b}[201~rm -rf /",
        "a\u{009b}201~b",
        "red\u{001b}[31mtext",
        "a\u{0000}b",
        "a\u{0007}b",
        "a\u{007f}b",
        "a\u{0085}b",
    ] {
        assert!(
            encode_input(&KeyInput::paste(smuggled.to_owned()), bracketed())
                .requires_confirmation(),
            "an embedded control must gate the paste: {smuggled:?}"
        );
    }
}

#[test]
fn bracketed_pastes_without_controls_flow_through() {
    for benign in ["hello", "one\r\ntwo", "one\ntwo", "col\tumn"] {
        assert!(
            !encode_input(&KeyInput::paste(benign.to_owned()), bracketed()).requires_confirmation(),
            "ordinary text never requires confirmation: {benign:?}"
        );
    }
}
