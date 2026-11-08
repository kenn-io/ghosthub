//! Backend-neutral terminal input vocabulary.

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Modifiers {
    pub shift: bool,
    pub control: bool,
    pub alt: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NamedKey {
    Enter,
    Tab,
    Backspace,
    Escape,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    F(u8),
    KeypadDigit(u8),
    KeypadDecimal,
    KeypadDivide,
    KeypadMultiply,
    KeypadSubtract,
    KeypadAdd,
    KeypadEnter,
    KeypadEqual,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum KeyInput {
    Text {
        text: String,
        logical_key: Option<String>,
        modifiers: Modifiers,
        event: KeyEvent,
    },
    Named {
        key: NamedKey,
        modifiers: Modifiers,
        event: KeyEvent,
    },
    Paste(String),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum KeyEvent {
    #[default]
    Press,
    Repeat,
    Release,
}

impl KeyInput {
    #[must_use]
    pub fn text(text: impl Into<String>, modifiers: Modifiers) -> Self {
        Self::Text {
            text: text.into(),
            logical_key: None,
            modifiers,
            event: KeyEvent::Press,
        }
    }

    #[must_use]
    pub fn text_with_key(
        text: impl Into<String>,
        logical_key: impl Into<String>,
        modifiers: Modifiers,
    ) -> Self {
        Self::Text {
            text: text.into(),
            logical_key: Some(logical_key.into()),
            modifiers,
            event: KeyEvent::Press,
        }
    }

    #[must_use]
    pub const fn named(key: NamedKey, modifiers: Modifiers) -> Self {
        Self::Named {
            key,
            modifiers,
            event: KeyEvent::Press,
        }
    }

    #[must_use]
    pub fn paste(text: impl Into<String>) -> Self {
        Self::Paste(text.into())
    }

    #[must_use]
    pub fn with_event(mut self, event: KeyEvent) -> Self {
        match &mut self {
            Self::Text {
                event: input_event, ..
            }
            | Self::Named {
                event: input_event, ..
            } => *input_event = event,
            Self::Paste(_) => {}
        }
        self
    }
}

// These booleans are independent terminal protocol modes, not mutually
// exclusive application states.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TerminalModes {
    pub application_cursor: bool,
    pub application_keypad: bool,
    pub bracketed_paste: bool,
    pub mouse_tracking: MouseTracking,
    pub sgr_mouse: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum MouseTracking {
    #[default]
    None,
    Click,
    Drag,
    Motion,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MouseButton {
    Left,
    Middle,
    Right,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MouseAction {
    Press(MouseButton),
    Release(MouseButton),
    Move(Option<MouseButton>),
    WheelUp,
    WheelDown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MouseInput {
    pub action: MouseAction,
    pub column: usize,
    pub row: usize,
    pub modifiers: Modifiers,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EncodedInput {
    bytes: Vec<u8>,
    requires_confirmation: bool,
}

impl EncodedInput {
    #[must_use]
    pub fn ready(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            requires_confirmation: false,
        }
    }

    fn confirmation_required(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            requires_confirmation: true,
        }
    }

    #[must_use]
    pub const fn requires_confirmation(&self) -> bool {
        self.requires_confirmation
    }

    /// Release the encoded bytes after any required user confirmation.
    #[must_use]
    pub fn approve(self) -> Vec<u8> {
        self.bytes
    }
}

#[must_use]
pub fn encode_paste(text: &str, bracketed: bool) -> EncodedInput {
    let sanitized = sanitize_paste(text);
    if bracketed {
        let mut bytes = Vec::with_capacity(sanitized.len() + 12);
        bytes.extend_from_slice(b"\x1b[200~");
        bytes.extend_from_slice(sanitized.as_bytes());
        bytes.extend_from_slice(b"\x1b[201~");
        // Rewritten embedded controls still require approval. Newlines and
        // tabs are ordinary content inside bracketed paste.
        if text.chars().any(is_unsafe_control) {
            EncodedInput::confirmation_required(bytes)
        } else {
            EncodedInput::ready(bytes)
        }
    } else if text.chars().any(char::is_control) {
        // A bare newline can execute a shell command.
        EncodedInput::confirmation_required(sanitized.into_bytes())
    } else {
        EncodedInput::ready(sanitized.into_bytes())
    }
}

/// A control the paste policy strips: every C0/C1/DEL control except the tab
/// and the carriage return and line feed that newline normalization keeps.
fn is_unsafe_control(character: char) -> bool {
    character.is_control() && character != '\t' && character != '\r' && character != '\n'
}

/// Apply the shared paste-sanitization policy: normalize every line ending to
/// a lone carriage return (CRLF and bare LF both become CR; a bare CR is
/// kept), then drop unsafe controls by code point. Stripping ESC also defuses
/// an embedded bracketed-paste end marker.
fn sanitize_paste(text: &str) -> String {
    let mut sanitized = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        match character {
            '\r' => {
                if characters.peek() == Some(&'\n') {
                    characters.next();
                }
                sanitized.push('\r');
            }
            '\n' => sanitized.push('\r'),
            other if is_unsafe_control(other) => {}
            other => sanitized.push(other),
        }
    }
    sanitized
}

/// Encode one terminal-grid mouse event using SGR 1006 coordinates.
///
/// Events are suppressed unless the hosted application enabled both mouse
/// reporting and SGR encoding. Motion is further restricted to the mode the
/// application selected, matching normal terminal behavior.
#[must_use]
pub fn encode_mouse(input: MouseInput, modes: TerminalModes) -> Vec<u8> {
    if modes.mouse_tracking == MouseTracking::None || !modes.sgr_mouse {
        return Vec::new();
    }

    let (base, terminator) = match input.action {
        MouseAction::Press(button) => (mouse_button_code(button), 'M'),
        MouseAction::Release(button) => (mouse_button_code(button), 'm'),
        MouseAction::Move(button)
            if modes.mouse_tracking == MouseTracking::Motion
                || (modes.mouse_tracking == MouseTracking::Drag && button.is_some()) =>
        {
            (button.map_or(3, mouse_button_code) + 32, 'M')
        }
        MouseAction::Move(_) => return Vec::new(),
        MouseAction::WheelUp => (64, 'M'),
        MouseAction::WheelDown => (65, 'M'),
    };
    let modifiers = u8::from(input.modifiers.shift) * 4
        + u8::from(input.modifiers.alt) * 8
        + u8::from(input.modifiers.control) * 16;
    format!(
        "\x1b[<{};{};{}{}",
        base + modifiers,
        input.column.saturating_add(1),
        input.row.saturating_add(1),
        terminator
    )
    .into_bytes()
}

const fn mouse_button_code(button: MouseButton) -> u8 {
    match button {
        MouseButton::Left => 0,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    }
}
