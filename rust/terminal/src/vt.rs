//! Owning, single-worker binding to the pinned libghostty-vt C API.
//!
//! C handles and borrowed cells never leave this module. Frames and effects
//! contain Rust-owned data before returning to the terminal worker.
#![allow(unsafe_code)]

use std::{ffi::c_void, ptr::NonNull};

use surface::{Cell, CellStyle, Cursor, CursorShape, GridSize, Rgb};

#[repr(C)]
#[derive(Default)]
struct RawCursor {
    x: u16,
    y: u16,
    visible: u8,
    shape: u8,
}

#[repr(C)]
struct RawCell {
    text: *const u8,
    len: usize,
    foreground: [u8; 3],
    background: [u8; 3],
    style: u8,
    selected: bool,
}

type EffectCallback = unsafe extern "C" fn(*mut c_void, u32, *const u8, usize);
unsafe extern "C" {
    fn vt_new(
        columns: u16,
        rows: u16,
        userdata: *mut c_void,
        effect: EffectCallback,
    ) -> *mut c_void;
    fn vt_free(vt: *mut c_void);
    fn vt_colors(vt: *mut c_void, rgb: *const u8);
    fn vt_cursor(vt: *mut c_void, shape: u8);
    fn vt_write(vt: *mut c_void, bytes: *const u8, len: usize) -> bool;
    fn vt_resize(vt: *mut c_void, columns: u16, rows: u16, width: u32, height: u32);
    fn vt_mode(vt: *mut c_void, mode: u16) -> bool;
    fn vt_snapshot(vt: *mut c_void, cursor: *mut RawCursor) -> i32;
    fn vt_row(vt: *mut c_void, identity: *mut u64, dirty: *mut bool) -> bool;
    fn vt_cell(vt: *mut c_void, cell: *mut RawCell) -> bool;
    fn vt_clean(vt: *mut c_void);
    fn vt_clear_selection(vt: *mut c_void) -> bool;
    fn vt_select(vt: *mut c_void, action: u8, x: u16, y: u16);
    fn vt_copy_selection(vt: *mut c_void, text: *mut *const u8, len: *mut usize) -> bool;
    fn vt_key(
        vt: *mut c_void,
        named: u32,
        codepoint: u32,
        modifiers: u16,
        action: u8,
        text: *const u8,
        text_len: usize,
        output: *mut u8,
        capacity: usize,
    ) -> usize;
}

pub(super) struct Effect {
    pub kind: u32,
    pub bytes: Vec<u8>,
}

pub(super) struct Vt {
    handle: NonNull<c_void>,
    // The allocation stays at the same address when the engine moves to its
    // worker. libghostty invokes callbacks only during our exclusive calls.
    #[allow(clippy::box_collection)]
    effects: Box<Vec<Effect>>,
}

// SAFETY: the entire instance moves to one terminal worker. libghostty creates
// no threads; handles and callbacks are accessed only through &mut Vt. It is
// deliberately not Sync and no borrowed state is returned.
unsafe impl Send for Vt {}

unsafe extern "C" fn effect(userdata: *mut c_void, kind: u32, bytes: *const u8, len: usize) {
    // SAFETY: userdata points to the live boxed collection registered in new.
    // libghostty owns bytes for this callback; copy before it returns. A zero
    // length permits a null pointer and must not form a slice from it.
    let effects = unsafe { &mut *userdata.cast::<Vec<Effect>>() };
    let bytes = if len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec()
    };
    effects.push(Effect { kind, bytes });
}

impl Vt {
    pub fn select(&mut self, action: u8, column: usize, row: usize) {
        // SAFETY: the engine checks the coordinates against its current grid.
        unsafe {
            vt_select(
                self.handle.as_ptr(),
                action,
                dimension(column),
                dimension(row),
            );
        };
    }

    pub fn clear_selection(&mut self) -> bool {
        // SAFETY: the handle is live and exclusively borrowed.
        unsafe { vt_clear_selection(self.handle.as_ptr()) }
    }

    pub fn copy_selection(&mut self) -> Option<String> {
        let mut text = std::ptr::null();
        let mut len = 0;
        // SAFETY: the bridge owns the returned bytes until its next copy call.
        if !unsafe { vt_copy_selection(self.handle.as_ptr(), &raw mut text, &raw mut len) } {
            return None;
        }
        // SAFETY: successful copies return a nonempty allocation of len bytes.
        Some(String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(text, len) }).into_owned())
    }

    pub fn key(&mut self, input: &input::KeyInput) -> Vec<u8> {
        use input::{KeyEvent, KeyInput, NamedKey};
        let (named, codepoint, text, modifiers, event) = match input {
            KeyInput::Text {
                text,
                logical_key,
                modifiers,
                event,
            } => {
                let logical = logical_key.as_deref().unwrap_or(text);
                let codepoint = logical
                    .chars()
                    .next()
                    .filter(|_| logical.chars().count() == 1)
                    .map_or(0, |ch| u32::from(ch.to_ascii_lowercase()));
                (0, codepoint, text.as_str(), modifiers, event)
            }
            KeyInput::Named {
                key,
                modifiers,
                event,
            } => {
                let named = match key {
                    NamedKey::Enter => 1,
                    NamedKey::Tab => 2,
                    NamedKey::Backspace => 3,
                    NamedKey::Escape => 4,
                    NamedKey::ArrowUp => 5,
                    NamedKey::ArrowDown => 6,
                    NamedKey::ArrowLeft => 7,
                    NamedKey::ArrowRight => 8,
                    NamedKey::Home => 9,
                    NamedKey::End => 10,
                    NamedKey::PageUp => 11,
                    NamedKey::PageDown => 12,
                    NamedKey::Insert => 13,
                    NamedKey::Delete => 14,
                    NamedKey::KeypadDecimal => 15,
                    NamedKey::KeypadDivide => 16,
                    NamedKey::KeypadMultiply => 17,
                    NamedKey::KeypadSubtract => 18,
                    NamedKey::KeypadAdd => 19,
                    NamedKey::KeypadEnter => 20,
                    NamedKey::KeypadEqual => 21,
                    NamedKey::F(number) if (1..=25).contains(number) => 99 + u32::from(*number),
                    NamedKey::KeypadDigit(number) if *number <= 9 => 200 + u32::from(*number),
                    NamedKey::F(_) | NamedKey::KeypadDigit(_) => return Vec::new(),
                };
                (named, 0, "", modifiers, event)
            }
            KeyInput::Paste(_) => unreachable!("pastes use Ghosthub's approval policy"),
        };
        let modifiers = u16::from(modifiers.shift)
            | (u16::from(modifiers.control) << 1)
            | (u16::from(modifiers.alt) << 2);
        let action = match event {
            KeyEvent::Press => 0,
            KeyEvent::Repeat => 1,
            KeyEvent::Release => 2,
        };
        let mut output = vec![0; text.len().saturating_mul(16).saturating_add(128)];
        // SAFETY: the input and output allocations remain live for the call;
        // the bridge clears the event's borrowed text before returning.
        let written = unsafe {
            vt_key(
                self.handle.as_ptr(),
                named,
                codepoint,
                modifiers,
                action,
                text.as_ptr(),
                text.len(),
                output.as_mut_ptr(),
                output.len(),
            )
        };
        assert!(written <= output.len(), "key encoding exceeded its buffer");
        output.truncate(written);
        output
    }

    pub fn new(size: GridSize) -> Self {
        let mut effects = Box::new(Vec::new());
        // SAFETY: the boxed callback state outlives the C handle. Dimensions
        // are checked before crossing the API's 16-bit boundary.
        let handle = unsafe {
            vt_new(
                dimension(size.columns()),
                dimension(size.rows()),
                std::ptr::from_mut(effects.as_mut()).cast(),
                effect,
            )
        };
        Self {
            handle: NonNull::new(handle).expect("create libghostty terminal"),
            effects,
        }
    }

    pub fn colors(&mut self, rgb: &[u8; 774]) {
        // SAFETY: C copies exactly two colors and 256 palette entries.
        unsafe { vt_colors(self.handle.as_ptr(), rgb.as_ptr()) };
    }

    pub fn cursor(&mut self, shape: CursorShape) {
        let shape = match shape {
            CursorShape::Bar => 1,
            CursorShape::Underline => 2,
            _ => 0,
        };
        // SAFETY: the handle is live and exclusively borrowed.
        unsafe { vt_cursor(self.handle.as_ptr(), shape) };
    }

    pub fn write(&mut self, bytes: &[u8]) -> bool {
        // SAFETY: the input slice remains valid during this synchronous call.
        unsafe { vt_write(self.handle.as_ptr(), bytes.as_ptr(), bytes.len()) }
    }

    pub fn resize(&mut self, size: GridSize, width: u32, height: u32) {
        // SAFETY: dimensions fit the API; the handle is exclusively borrowed.
        unsafe {
            vt_resize(
                self.handle.as_ptr(),
                dimension(size.columns()),
                dimension(size.rows()),
                width,
                height,
            );
        };
    }

    pub fn mode(&self, mode: u16) -> bool {
        // SAFETY: this query does not modify the terminal or invoke callbacks.
        unsafe { vt_mode(self.handle.as_ptr(), mode) }
    }

    pub fn snapshot(&mut self) -> (bool, Cursor) {
        let mut cursor = RawCursor::default();
        // SAFETY: cursor is writable storage of the C bridge's exact layout.
        let dirty = unsafe { vt_snapshot(self.handle.as_ptr(), &raw mut cursor) };
        (
            dirty == 2,
            Cursor {
                column: usize::from(cursor.x),
                row: usize::from(cursor.y),
                visible: cursor.visible != 0,
                shape: match cursor.shape {
                    1 => CursorShape::Bar,
                    2 => CursorShape::Underline,
                    _ => CursorShape::Block,
                },
            },
        )
    }

    pub fn row(&mut self) -> Option<([u64; 2], bool)> {
        let mut identity = [0; 2];
        let mut dirty = false;
        // SAFETY: the iterator belongs to this snapshot, with valid outputs.
        unsafe { vt_row(self.handle.as_ptr(), identity.as_mut_ptr(), &raw mut dirty) }
            .then_some((identity, dirty))
    }

    pub fn cell(&mut self) -> Option<Cell> {
        let mut cell = RawCell {
            selected: false,
            text: std::ptr::null(),
            len: 0,
            foreground: [0; 3],
            background: [0; 3],
            style: 0,
        };
        // SAFETY: the current row initializes all fields on a successful read.
        if !unsafe { vt_cell(self.handle.as_ptr(), &raw mut cell) } {
            return None;
        }
        #[cfg(test)]
        super::CONVERTED_CELLS.set(super::CONVERTED_CELLS.get() + 1);
        let text = if cell.len == 0 {
            String::new()
        } else {
            // SAFETY: C's buffer remains live until the next cell call. Copy it.
            String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(cell.text, cell.len) })
                .into_owned()
        };
        let mut converted = Cell::plain(text);
        converted.selected = cell.selected;
        converted.foreground = Rgb::new(cell.foreground[0], cell.foreground[1], cell.foreground[2]);
        converted.background = Rgb::new(cell.background[0], cell.background[1], cell.background[2]);
        for (bit, style) in [
            CellStyle::BOLD,
            CellStyle::ITALIC,
            CellStyle::UNDERLINE,
            CellStyle::INVERSE,
            CellStyle::WIDE,
            CellStyle::DIM,
            CellStyle::HIDDEN,
            CellStyle::STRIKE,
        ]
        .into_iter()
        .enumerate()
        {
            if cell.style & (1 << bit) != 0 {
                converted.style.insert(style);
            }
        }
        Some(converted)
    }

    pub fn clean(&mut self) {
        // SAFETY: this acknowledges our current render snapshot.
        unsafe { vt_clean(self.handle.as_ptr()) };
    }

    pub fn effects(&mut self) -> Vec<Effect> {
        std::mem::take(self.effects.as_mut())
    }
}

impl Drop for Vt {
    fn drop(&mut self) {
        // SAFETY: the handle is owned exactly once. Callback storage remains
        // alive until after every library allocation has been released.
        unsafe { vt_free(self.handle.as_ptr()) };
    }
}

fn dimension(value: usize) -> u16 {
    u16::try_from(value).expect("terminal dimension fits u16")
}
