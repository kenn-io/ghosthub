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
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum KeyInput {
    Text { text: String, modifiers: Modifiers },
    Named { key: NamedKey, modifiers: Modifiers },
    Paste(String),
}

impl KeyInput {
    #[must_use]
    pub fn text(text: impl Into<String>, modifiers: Modifiers) -> Self {
        Self::Text {
            text: text.into(),
            modifiers,
        }
    }

    #[must_use]
    pub const fn named(key: NamedKey, modifiers: Modifiers) -> Self {
        Self::Named { key, modifiers }
    }

    #[must_use]
    pub fn paste(text: impl Into<String>) -> Self {
        Self::Paste(text.into())
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TerminalModes {
    pub application_cursor: bool,
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
    fn ready(bytes: Vec<u8>) -> Self {
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
pub fn encode_input(input: &KeyInput, modes: TerminalModes) -> EncodedInput {
    match input {
        KeyInput::Text { text, modifiers } => EncodedInput::ready(encode_text(text, *modifiers)),
        KeyInput::Named { key, modifiers } => {
            EncodedInput::ready(encode_named(*key, *modifiers, modes))
        }
        KeyInput::Paste(text) if modes.bracketed_paste => {
            let mut bytes = Vec::with_capacity(text.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            if text.contains("\x1b[201~") {
                EncodedInput::confirmation_required(bytes)
            } else {
                EncodedInput::ready(bytes)
            }
        }
        KeyInput::Paste(text) => {
            let normalized = text.replace("\r\n", "\n").replace('\n', "\r");
            if text.chars().any(char::is_control) {
                EncodedInput::confirmation_required(normalized.into_bytes())
            } else {
                EncodedInput::ready(normalized.into_bytes())
            }
        }
    }
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

fn encode_text(text: &str, modifiers: Modifiers) -> Vec<u8> {
    let mut bytes = if modifiers.control {
        control_byte(text).map_or_else(|| text.as_bytes().to_vec(), |byte| vec![byte])
    } else {
        text.as_bytes().to_vec()
    };

    if modifiers.alt {
        bytes.insert(0, b'\x1b');
    }
    bytes
}

fn control_byte(text: &str) -> Option<u8> {
    let bytes = text.as_bytes();
    if bytes.len() != 1 {
        return None;
    }

    match bytes[0] {
        b'@'..=b'_' => Some(bytes[0] & 0x1f),
        b'a'..=b'z' => Some(bytes[0] - b'a' + 1),
        b'?' => Some(0x7f),
        _ => None,
    }
}

fn encode_named(key: NamedKey, modifiers: Modifiers, modes: TerminalModes) -> Vec<u8> {
    if key == NamedKey::Tab && modifiers.shift && !modifiers.alt && !modifiers.control {
        return b"\x1b[Z".to_vec();
    }
    if let Some(sequence) = modified_named_sequence(key, modifiers) {
        return sequence;
    }

    let sequence: &[u8] = match key {
        NamedKey::Enter => b"\r",
        NamedKey::Tab => b"\t",
        NamedKey::Backspace => b"\x7f",
        NamedKey::Escape => b"\x1b",
        NamedKey::ArrowUp if modes.application_cursor => b"\x1bOA",
        NamedKey::ArrowDown if modes.application_cursor => b"\x1bOB",
        NamedKey::ArrowRight if modes.application_cursor => b"\x1bOC",
        NamedKey::ArrowLeft if modes.application_cursor => b"\x1bOD",
        NamedKey::ArrowUp => b"\x1b[A",
        NamedKey::ArrowDown => b"\x1b[B",
        NamedKey::ArrowRight => b"\x1b[C",
        NamedKey::ArrowLeft => b"\x1b[D",
        NamedKey::Home => b"\x1b[H",
        NamedKey::End => b"\x1b[F",
        NamedKey::PageUp => b"\x1b[5~",
        NamedKey::PageDown => b"\x1b[6~",
        NamedKey::Insert => b"\x1b[2~",
        NamedKey::Delete => b"\x1b[3~",
        NamedKey::F(1) => b"\x1bOP",
        NamedKey::F(2) => b"\x1bOQ",
        NamedKey::F(3) => b"\x1bOR",
        NamedKey::F(4) => b"\x1bOS",
        NamedKey::F(5) => b"\x1b[15~",
        NamedKey::F(6) => b"\x1b[17~",
        NamedKey::F(7) => b"\x1b[18~",
        NamedKey::F(8) => b"\x1b[19~",
        NamedKey::F(9) => b"\x1b[20~",
        NamedKey::F(10) => b"\x1b[21~",
        NamedKey::F(11) => b"\x1b[23~",
        NamedKey::F(12) => b"\x1b[24~",
        NamedKey::F(_) => return Vec::new(),
    };

    let mut bytes = sequence.to_vec();
    if modifiers.alt && key != NamedKey::Escape {
        bytes.insert(0, b'\x1b');
    }
    bytes
}

fn modified_named_sequence(key: NamedKey, modifiers: Modifiers) -> Option<Vec<u8>> {
    let parameter = modifier_parameter(modifiers);
    if parameter == 1 {
        return None;
    }
    let sequence = match key {
        NamedKey::ArrowUp => format!("\x1b[1;{parameter}A"),
        NamedKey::ArrowDown => format!("\x1b[1;{parameter}B"),
        NamedKey::ArrowRight => format!("\x1b[1;{parameter}C"),
        NamedKey::ArrowLeft => format!("\x1b[1;{parameter}D"),
        NamedKey::Home => format!("\x1b[1;{parameter}H"),
        NamedKey::End => format!("\x1b[1;{parameter}F"),
        NamedKey::PageUp => format!("\x1b[5;{parameter}~"),
        NamedKey::PageDown => format!("\x1b[6;{parameter}~"),
        NamedKey::Insert => format!("\x1b[2;{parameter}~"),
        NamedKey::Delete => format!("\x1b[3;{parameter}~"),
        NamedKey::F(number @ 1..=4) => {
            let final_byte = char::from(b'P' + number - 1);
            format!("\x1b[1;{parameter}{final_byte}")
        }
        NamedKey::F(number @ 5..=12) => {
            let code = [15, 17, 18, 19, 20, 21, 23, 24][usize::from(number - 5)];
            format!("\x1b[{code};{parameter}~")
        }
        _ => return None,
    };
    Some(sequence.into_bytes())
}

const fn modifier_parameter(modifiers: Modifiers) -> u8 {
    1 + modifiers.shift as u8 + (modifiers.alt as u8 * 2) + (modifiers.control as u8 * 4)
}
