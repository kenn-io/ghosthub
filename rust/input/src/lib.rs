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
    pub modify_other_keys: ModifyOtherKeys,
    pub kitty_keyboard: KittyKeyboard,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ModifyOtherKeys {
    #[default]
    Disabled,
    ExceptWellDefined,
    All,
}

// Kitty defines these as independently negotiated bit flags.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct KittyKeyboard {
    pub disambiguate_escape_codes: bool,
    pub report_event_types: bool,
    pub report_alternate_keys: bool,
    pub report_all_keys_as_escape_codes: bool,
    pub report_associated_text: bool,
}

impl KittyKeyboard {
    const fn enabled(self) -> bool {
        self.disambiguate_escape_codes
            || self.report_event_types
            || self.report_alternate_keys
            || self.report_all_keys_as_escape_codes
            || self.report_associated_text
    }
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
        KeyInput::Text {
            text,
            logical_key,
            modifiers,
            event,
        } => EncodedInput::ready(encode_text(
            text,
            logical_key.as_deref(),
            *modifiers,
            *event,
            modes,
        )),
        KeyInput::Named {
            key,
            modifiers,
            event,
        } => EncodedInput::ready(encode_named(*key, *modifiers, *event, modes)),
        KeyInput::Paste(text) if modes.bracketed_paste => {
            let sanitized = sanitize_paste(text);
            let mut bytes = Vec::with_capacity(sanitized.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(sanitized.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            // The sanitized bytes above carry no smuggled controls, but an
            // embedded control in the source still gates the paste: it is a
            // signal the user pasted something that was rewritten. Newlines
            // and tabs are ordinary paste content, not that signal.
            let embedded_control = text.chars().any(is_unsafe_control);
            if embedded_control {
                EncodedInput::confirmation_required(bytes)
            } else {
                EncodedInput::ready(bytes)
            }
        }
        KeyInput::Paste(text) => {
            let sanitized = sanitize_paste(text);
            // A bare (unbracketed) paste reaches the shell as typed input, so
            // any control in the source — a newline auto-executes — gates it.
            // The delivered bytes are sanitized regardless.
            if text.chars().any(char::is_control) {
                EncodedInput::confirmation_required(sanitized.into_bytes())
            } else {
                EncodedInput::ready(sanitized.into_bytes())
            }
        }
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

fn encode_text(
    text: &str,
    logical_key: Option<&str>,
    modifiers: Modifiers,
    event: KeyEvent,
    modes: TerminalModes,
) -> Vec<u8> {
    if !is_single_key_text(text, logical_key) {
        return if event == KeyEvent::Release {
            Vec::new()
        } else {
            text.as_bytes().to_vec()
        };
    }
    if should_encode_kitty_text(modifiers, modes.kitty_keyboard) {
        return encode_kitty_text(text, logical_key, modifiers, event, modes.kitty_keyboard);
    }
    if event == KeyEvent::Release {
        return Vec::new();
    }
    if should_encode_modify_other_keys(text, modifiers, modes.modify_other_keys) {
        return encode_modify_other_keys(text, modifiers);
    }

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

fn is_single_key_text(text: &str, logical_key: Option<&str>) -> bool {
    has_one_scalar(text) && logical_key.is_none_or(has_one_scalar)
}

fn has_one_scalar(text: &str) -> bool {
    let mut chars = text.chars();
    chars.next().is_some() && chars.next().is_none()
}

fn encode_modify_other_keys(text: &str, modifiers: Modifiers) -> Vec<u8> {
    let mut chars = text.chars();
    let Some(character) = chars.next() else {
        return Vec::new();
    };
    if chars.next().is_some() {
        return Vec::new();
    }
    format!(
        "\x1b[27;{};{}~",
        modifier_parameter(modifiers),
        u32::from(character)
    )
    .into_bytes()
}

fn should_encode_kitty_text(modifiers: Modifiers, kitty: KittyKeyboard) -> bool {
    // Event-type reporting annotates keys already encoded as Kitty events; it
    // does not promote ordinary text into key events. Report-all is the
    // protocol flag that performs that promotion.
    kitty.report_all_keys_as_escape_codes
        || (kitty.disambiguate_escape_codes && (modifiers.control || modifiers.alt))
}

fn should_encode_modify_other_keys(
    text: &str,
    modifiers: Modifiers,
    mode: ModifyOtherKeys,
) -> bool {
    if modifier_parameter(modifiers) == 1 {
        return false;
    }
    match mode {
        ModifyOtherKeys::Disabled => false,
        ModifyOtherKeys::All => true,
        ModifyOtherKeys::ExceptWellDefined => {
            if modifiers.control && control_byte(text).is_some() {
                return false;
            }
            let byte = text.as_bytes().first().copied();
            let one_modifier =
                u8::from(modifiers.shift) + u8::from(modifiers.control) + u8::from(modifiers.alt)
                    == 1;
            !(text.len() == 1
                && byte.is_some_and(|byte| (b'@'..=b'\x7f').contains(&byte))
                && one_modifier
                && !modifiers.alt)
        }
    }
}

fn encode_kitty_text(
    text: &str,
    logical_key: Option<&str>,
    modifiers: Modifiers,
    event: KeyEvent,
    kitty: KittyKeyboard,
) -> Vec<u8> {
    if event == KeyEvent::Release && !kitty.report_event_types {
        return Vec::new();
    }
    let primary = text_key_code(text, logical_key, modifiers);
    let shifted = kitty
        .report_alternate_keys
        .then(|| shifted_key_code(text, modifiers))
        .flatten()
        .filter(|shifted| *shifted != primary);
    let associated = (kitty.report_associated_text && event != KeyEvent::Release)
        .then(|| text.chars().map(u32::from).collect::<Vec<_>>());
    encode_csi_u(
        primary,
        modifiers,
        kitty.report_event_types.then_some(event),
        shifted,
        associated.as_deref(),
    )
}

fn text_key_code(text: &str, logical_key: Option<&str>, modifiers: Modifiers) -> u32 {
    let key = logical_key.unwrap_or(text);
    let mut chars = key.chars();
    let Some(character) = chars.next() else {
        return 0;
    };
    if chars.next().is_some() {
        return 0;
    }
    if modifiers.shift {
        character.to_lowercase().next().map_or(0, u32::from)
    } else {
        u32::from(character)
    }
}

fn shifted_key_code(text: &str, modifiers: Modifiers) -> Option<u32> {
    modifiers.shift.then(|| {
        let mut chars = text.chars();
        let character = chars.next()?;
        chars.next().is_none().then_some(u32::from(character))
    })?
}

fn encode_csi_u(
    key_code: u32,
    modifiers: Modifiers,
    event: Option<KeyEvent>,
    shifted_key: Option<u32>,
    associated_text: Option<&[u32]>,
) -> Vec<u8> {
    let mut sequence = format!("\x1b[{key_code}");
    if let Some(shifted_key) = shifted_key {
        sequence.push(':');
        sequence.push_str(&shifted_key.to_string());
    }
    if modifier_parameter(modifiers) != 1 || event.is_some() || associated_text.is_some() {
        sequence.push(';');
        sequence.push_str(&modifier_parameter(modifiers).to_string());
        if let Some(event) = event {
            sequence.push(':');
            sequence.push(char::from(b'0' + key_event_parameter(event)));
        }
    }
    if let Some(associated_text) = associated_text {
        sequence.push(';');
        for (index, codepoint) in associated_text.iter().enumerate() {
            if index != 0 {
                sequence.push(':');
            }
            sequence.push_str(&codepoint.to_string());
        }
    }
    sequence.push('u');
    sequence.into_bytes()
}

const fn key_event_parameter(event: KeyEvent) -> u8 {
    match event {
        KeyEvent::Press => 1,
        KeyEvent::Repeat => 2,
        KeyEvent::Release => 3,
    }
}

fn control_byte(text: &str) -> Option<u8> {
    let bytes = text.as_bytes();
    if bytes.len() != 1 {
        return None;
    }

    match bytes[0] {
        b' ' | b'2' | b'`' => Some(0x00),
        b'3' => Some(0x1b),
        b'4' => Some(0x1c),
        b'5' => Some(0x1d),
        b'6' => Some(0x1e),
        b'7' | b'/' => Some(0x1f),
        b'8' | b'?' => Some(0x7f),
        b'@'..=b'_' => Some(bytes[0] & 0x1f),
        b'a'..=b'z' => Some(bytes[0] - b'a' + 1),
        _ => None,
    }
}

fn encode_named(
    key: NamedKey,
    modifiers: Modifiers,
    event: KeyEvent,
    modes: TerminalModes,
) -> Vec<u8> {
    if event == KeyEvent::Release && !modes.kitty_keyboard.report_event_types {
        return Vec::new();
    }
    if let Some(sequence) = encode_kitty_named(key, modifiers, event, modes.kitty_keyboard) {
        return sequence;
    }
    if event == KeyEvent::Release {
        return Vec::new();
    }
    if let Some(sequence) = encode_keypad(key, modes.application_keypad) {
        return sequence;
    }
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
        NamedKey::KeypadDigit(_)
        | NamedKey::KeypadDecimal
        | NamedKey::KeypadDivide
        | NamedKey::KeypadMultiply
        | NamedKey::KeypadSubtract
        | NamedKey::KeypadAdd
        | NamedKey::KeypadEnter
        | NamedKey::KeypadEqual => unreachable!("keypad keys are handled before legacy keys"),
    };

    let mut bytes = sequence.to_vec();
    if modifiers.alt && key != NamedKey::Escape {
        bytes.insert(0, b'\x1b');
    }
    bytes
}

fn encode_keypad(key: NamedKey, application_mode: bool) -> Option<Vec<u8>> {
    let sequence: &[u8] = match (key, application_mode) {
        (NamedKey::KeypadDigit(digit), true) if digit <= 9 => {
            return Some(vec![b'\x1b', b'O', b'p' + digit]);
        }
        (NamedKey::KeypadDigit(digit), false) if digit <= 9 => {
            return Some(vec![b'0' + digit]);
        }
        (NamedKey::KeypadDigit(_), _) => return Some(Vec::new()),
        (NamedKey::KeypadDecimal, true) => b"\x1bOn",
        (NamedKey::KeypadDivide, true) => b"\x1bOo",
        (NamedKey::KeypadMultiply, true) => b"\x1bOj",
        (NamedKey::KeypadSubtract, true) => b"\x1bOm",
        (NamedKey::KeypadAdd, true) => b"\x1bOk",
        (NamedKey::KeypadEnter, true) => b"\x1bOM",
        (NamedKey::KeypadEqual, true) => b"\x1bOX",
        (NamedKey::KeypadDecimal, false) => b".",
        (NamedKey::KeypadDivide, false) => b"/",
        (NamedKey::KeypadMultiply, false) => b"*",
        (NamedKey::KeypadSubtract, false) => b"-",
        (NamedKey::KeypadAdd, false) => b"+",
        (NamedKey::KeypadEnter, false) => b"\r",
        (NamedKey::KeypadEqual, false) => b"=",
        _ => return None,
    };
    Some(sequence.to_vec())
}

fn encode_kitty_named(
    key: NamedKey,
    modifiers: Modifiers,
    event: KeyEvent,
    kitty: KittyKeyboard,
) -> Option<Vec<u8>> {
    if !kitty.enabled() {
        return None;
    }

    let all_keys = kitty.report_all_keys_as_escape_codes;
    let modified = modifier_parameter(modifiers) != 1;
    // Kitty keeps Enter, Tab, and Backspace usable as legacy controls under
    // event-type reporting alone. Their releases exist only in report-all.
    let csi_u_code = match key {
        NamedKey::Escape if kitty.disambiguate_escape_codes || all_keys => Some(27),
        NamedKey::Enter if all_keys || (kitty.disambiguate_escape_codes && modified) => Some(13),
        NamedKey::Tab if all_keys || (kitty.disambiguate_escape_codes && modified) => Some(9),
        NamedKey::Backspace if all_keys || (kitty.disambiguate_escape_codes && modified) => {
            Some(127)
        }
        NamedKey::KeypadDigit(digit)
            if digit <= 9 && (kitty.disambiguate_escape_codes || all_keys) =>
        {
            Some(57_399 + u32::from(digit))
        }
        NamedKey::KeypadDecimal if kitty.disambiguate_escape_codes || all_keys => Some(57_409),
        NamedKey::KeypadDivide if kitty.disambiguate_escape_codes || all_keys => Some(57_410),
        NamedKey::KeypadMultiply if kitty.disambiguate_escape_codes || all_keys => Some(57_411),
        NamedKey::KeypadSubtract if kitty.disambiguate_escape_codes || all_keys => Some(57_412),
        NamedKey::KeypadAdd if kitty.disambiguate_escape_codes || all_keys => Some(57_413),
        NamedKey::KeypadEnter if kitty.disambiguate_escape_codes || all_keys => Some(57_414),
        NamedKey::KeypadEqual if kitty.disambiguate_escape_codes || all_keys => Some(57_415),
        _ => None,
    };
    if let Some(key_code) = csi_u_code {
        return Some(encode_csi_u(
            key_code,
            modifiers,
            kitty.report_event_types.then_some(event),
            None,
            None,
        ));
    }

    kitty
        .report_event_types
        .then(|| encode_named_with_event_type(key, modifiers, event))
        .flatten()
}

fn encode_named_with_event_type(
    key: NamedKey,
    modifiers: Modifiers,
    event: KeyEvent,
) -> Option<Vec<u8>> {
    let parameter = modifier_parameter(modifiers);
    let event = key_event_parameter(event);
    let sequence = match key {
        NamedKey::ArrowUp => format!("\x1b[1;{parameter}:{event}A"),
        NamedKey::ArrowDown => format!("\x1b[1;{parameter}:{event}B"),
        NamedKey::ArrowRight => format!("\x1b[1;{parameter}:{event}C"),
        NamedKey::ArrowLeft => format!("\x1b[1;{parameter}:{event}D"),
        NamedKey::Home => format!("\x1b[1;{parameter}:{event}H"),
        NamedKey::End => format!("\x1b[1;{parameter}:{event}F"),
        NamedKey::PageUp => format!("\x1b[5;{parameter}:{event}~"),
        NamedKey::PageDown => format!("\x1b[6;{parameter}:{event}~"),
        NamedKey::Insert => format!("\x1b[2;{parameter}:{event}~"),
        NamedKey::Delete => format!("\x1b[3;{parameter}:{event}~"),
        NamedKey::F(number @ 1..=4) => {
            let final_byte = char::from(b'P' + number - 1);
            format!("\x1b[1;{parameter}:{event}{final_byte}")
        }
        NamedKey::F(number @ 5..=12) => {
            let code = [15, 17, 18, 19, 20, 21, 23, 24][usize::from(number - 5)];
            format!("\x1b[{code};{parameter}:{event}~")
        }
        _ => return None,
    };
    Some(sequence.into_bytes())
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
