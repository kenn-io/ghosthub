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
    pub sgr_mouse: bool,
}

#[must_use]
pub fn encode_input(input: &KeyInput, modes: TerminalModes) -> Vec<u8> {
    match input {
        KeyInput::Text { text, modifiers } => encode_text(text, *modifiers),
        KeyInput::Named { key, modifiers } => encode_named(*key, *modifiers, modes),
        KeyInput::Paste(text) if modes.bracketed_paste => {
            let mut bytes = Vec::with_capacity(text.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            bytes
        }
        KeyInput::Paste(text) => text.as_bytes().to_vec(),
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
