//! Terminal engine and PTY client ownership.

use std::collections::HashMap;
use std::sync::Arc;

use base64::Engine as _;
use input::{MouseTracking, TerminalModes};
use surface::{
    Cell as SurfaceCell, Cursor, CursorShape, Damage, GridSize, PixelSize, Rgb, SurfaceFrame,
    SurfaceStore,
};

mod pty;
mod relay;
#[cfg(unix)]
mod unix_io;
mod vt;
mod windows_job;
mod worker;

pub use pty::WorkerError;
pub use relay::{ByteRelayWorker, INPUT_BYTE_CAPACITY, RelayDisconnect, RelayOutput};
pub use worker::{TerminalEvent, TerminalStartup, TerminalWorker};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClipboardTarget {
    Clipboard,
    Selection,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ClipboardPolicy {
    allow_osc52_read: bool,
    allow_osc52_write: bool,
}

impl ClipboardPolicy {
    #[must_use]
    pub const fn local(allow_osc52_read: bool, allow_osc52_write: bool) -> Self {
        Self {
            allow_osc52_read,
            allow_osc52_write,
        }
    }

    #[must_use]
    pub const fn remote(allow_osc52_write: bool) -> Self {
        Self {
            allow_osc52_read: false,
            allow_osc52_write,
        }
    }

    #[must_use]
    pub const fn allows_osc52_write(self) -> bool {
        self.allow_osc52_write
    }
}

impl Default for ClipboardPolicy {
    fn default() -> Self {
        Self::remote(true)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DefaultColors {
    foreground: Rgb,
    background: Rgb,
}

impl DefaultColors {
    #[must_use]
    pub const fn new(foreground: Rgb, background: Rgb) -> Self {
        Self {
            foreground,
            background,
        }
    }

    #[must_use]
    pub const fn foreground(self) -> Rgb {
        self.foreground
    }

    #[must_use]
    pub const fn background(self) -> Rgb {
        self.background
    }
}

impl Default for DefaultColors {
    fn default() -> Self {
        Self::new(Rgb::WHITE, Rgb::BLACK)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardWrite {
    pub target: ClipboardTarget,
    pub text: String,
}

#[derive(Clone)]
pub struct ClipboardReadRequest {
    target: ClipboardTarget,
    formatter: Arc<dyn Fn(&str) -> String + Send + Sync + 'static>,
}

impl ClipboardReadRequest {
    /// Fixture for consumers testing response routing.
    #[cfg(feature = "test-support")]
    #[must_use]
    pub fn test_fixture() -> Self {
        Self {
            target: ClipboardTarget::Clipboard,
            formatter: Arc::new(|text: &str| text.to_owned()),
        }
    }

    #[must_use]
    pub const fn target(&self) -> ClipboardTarget {
        self.target
    }

    #[must_use]
    pub fn respond(&self, text: &str) -> Vec<u8> {
        (self.formatter)(text).into_bytes()
    }
}

#[derive(Default)]
pub struct EngineOutput {
    pty_writes: Vec<Vec<u8>>,
    clipboard_writes: Vec<ClipboardWrite>,
    clipboard_reads: Vec<ClipboardReadRequest>,
}

impl EngineOutput {
    #[must_use]
    pub fn pty_writes(&self) -> &[Vec<u8>] {
        &self.pty_writes
    }

    #[must_use]
    pub fn clipboard_writes(&self) -> &[ClipboardWrite] {
        &self.clipboard_writes
    }

    #[must_use]
    pub fn clipboard_reads(&self) -> &[ClipboardReadRequest] {
        &self.clipboard_reads
    }
}

pub struct TerminalEngine {
    vt: vt::Vt,
    entered_alternate_screen: bool,
    surface: Arc<SurfaceStore>,
    rows: GridObservation,
    size: GridSize,
    generation: u64,
    resize_sequence: u64,
    pixel_size: PixelSize,
    clipboard_policy: ClipboardPolicy,
}

impl TerminalEngine {
    #[must_use]
    pub fn new(size: GridSize) -> Self {
        Self::with_clipboard_policy(size, ClipboardPolicy::default())
    }

    #[must_use]
    pub fn with_clipboard_policy(size: GridSize, clipboard_policy: ClipboardPolicy) -> Self {
        Self::with_geometry(size, 0, PixelSize::default(), clipboard_policy)
    }

    #[must_use]
    pub fn with_default_colors(size: GridSize, default_colors: DefaultColors) -> Self {
        Self::with_geometry_and_colors(
            size,
            0,
            PixelSize::default(),
            ClipboardPolicy::default(),
            default_colors,
        )
    }

    #[must_use]
    pub fn with_geometry(
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
    ) -> Self {
        Self::with_geometry_and_colors(
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            DefaultColors::default(),
        )
    }

    #[must_use]
    pub fn with_geometry_and_colors(
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
    ) -> Self {
        Self::with_geometry_and_defaults(
            size,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
            CursorShape::Block,
        )
    }

    #[must_use]
    pub fn with_geometry_and_defaults(
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
        clipboard_policy: ClipboardPolicy,
        default_colors: DefaultColors,
        default_cursor_shape: CursorShape,
    ) -> Self {
        let mut vt = vt::Vt::new(size);
        let mut colors = [0; 774];
        for (index, rgb) in [default_colors.foreground(), default_colors.background()]
            .into_iter()
            .chain((0..=255).map(|index| indexed_color(index, default_colors)))
            .enumerate()
        {
            colors[index * 3..index * 3 + 3].copy_from_slice(&[rgb.red, rgb.green, rgb.blue]);
        }
        vt.colors(&colors);
        vt.cursor(default_cursor_shape);
        let mut engine = Self {
            vt,
            entered_alternate_screen: false,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(0, size))),
            rows: GridObservation {
                row_identities: Vec::new(),
            },
            size,
            generation: 0,
            resize_sequence,
            pixel_size,
            clipboard_policy,
        };
        engine.publish(true);
        engine
    }

    pub fn set_default_cursor_shape(&mut self, shape: CursorShape) {
        self.vt.cursor(shape);
        self.publish(true);
    }

    pub fn set_clipboard_policy(&mut self, policy: ClipboardPolicy) {
        self.clipboard_policy = policy;
    }

    #[must_use]
    pub fn process(&mut self, bytes: &[u8]) -> EngineOutput {
        // Publish at line/escape boundaries to keep structural scrolling and
        // alternate-screen entry visible even when a read contains an entire
        // start/redraw/exit. libghostty alone parses the sequences themselves.
        for segment in bytes.split_inclusive(|byte| *byte == b'\n') {
            self.entered_alternate_screen |= self.vt.write(segment);
            self.publish(false);
        }
        self.drain_events()
    }

    #[must_use]
    pub fn surface(&self) -> &SurfaceStore {
        &self.surface
    }

    #[must_use]
    pub fn surface_handle(&self) -> Arc<SurfaceStore> {
        Arc::clone(&self.surface)
    }

    #[must_use]
    pub fn modes(&self) -> TerminalModes {
        TerminalModes {
            application_cursor: self.vt.mode(1),
            application_keypad: self.vt.mode(66),
            bracketed_paste: self.vt.mode(2004),
            mouse_tracking: if self.vt.mode(1003) {
                MouseTracking::Motion
            } else if self.vt.mode(1002) {
                MouseTracking::Drag
            } else if self.vt.mode(1000) {
                MouseTracking::Click
            } else {
                MouseTracking::None
            },
            sgr_mouse: self.vt.mode(1006),
        }
    }

    fn has_entered_alternate_screen(&self) -> bool {
        self.entered_alternate_screen
    }

    #[must_use]
    pub fn encode_input(&mut self, key: &input::KeyInput) -> input::EncodedInput {
        if let input::KeyInput::Paste(text) = key {
            input::encode_paste(text, self.modes().bracketed_paste)
        } else {
            input::EncodedInput::ready(self.vt.key(key))
        }
    }

    pub fn resize(&mut self, size: GridSize) {
        self.resize_with_metadata(
            size,
            self.resize_sequence.saturating_add(1),
            PixelSize::default(),
        );
    }

    /// # Panics
    /// Panics if either grid dimension exceeds libghostty's u16 limit.
    pub fn resize_with_metadata(
        &mut self,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
    ) {
        let width =
            u32::from(pixel_size.width) / u32::try_from(size.columns()).expect("columns fit u32");
        let height =
            u32::from(pixel_size.height) / u32::try_from(size.rows()).expect("rows fit u32");
        self.vt.resize(size, width, height);
        self.size = size;
        self.resize_sequence = resize_sequence;
        self.pixel_size = pixel_size;
        self.publish(true);
    }

    fn publish(&mut self, force: bool) {
        let (full, cursor) = self.vt.snapshot();
        let mut rows = GridObservation {
            row_identities: Vec::with_capacity(self.size.rows()),
        };
        let mut rendered = Vec::new();
        while let Some((id, dirty)) = self.vt.row() {
            let row = rows.row_identities.len();
            rows.row_identities.push(id);
            if force || dirty {
                let mut cells = Vec::with_capacity(self.size.columns());
                while let Some(cell) = self.vt.cell() {
                    cells.push(cell);
                }
                assert_eq!(cells.len(), self.size.columns());
                rendered.push((row, cells));
            }
        }
        self.vt.clean();
        assert_eq!(rows.row_identities.len(), self.size.rows());
        let scroll = if force {
            None
        } else {
            detect_scroll(&self.rows, &rows)
        };
        self.rows = rows;
        let damage = if force || (full && scroll.is_none()) {
            vec![Damage::Full]
        } else {
            scroll.map_or_else(Vec::new, |scroll| {
                vec![Damage::Scroll {
                    top: scroll.top,
                    bottom: scroll.bottom,
                    delta: scroll.delta,
                }]
            })
        };
        let previous = self.surface.load();
        let mut patches = Vec::new();
        let mut changed = Vec::new();
        for (row, cells) in rendered {
            let old_row = previous_row_after_damage(row, &damage);
            let mut row_changed = false;
            for (column, cell) in cells.into_iter().enumerate() {
                let differs = damage.contains(&Damage::Full)
                    || old_row.map_or_else(
                        || cell != SurfaceCell::default(),
                        |old| cell != previous.row(old)[column],
                    );
                if differs {
                    patches.push((row * self.size.columns() + column, cell));
                    row_changed = true;
                }
            }
            if row_changed {
                changed.push(row);
            }
        }
        let mut damage = damage;
        if !damage.contains(&Damage::Full) {
            damage.extend(coalesce_rows(&changed));
        }
        if damage.is_empty() && previous.cursor() == Some(cursor) {
            return;
        }
        self.publish_patches(&damage, &patches, cursor);
    }

    fn publish_patches(
        &mut self,
        damage: &[Damage],
        patches: &[(usize, SurfaceCell)],
        cursor: Cursor,
    ) {
        self.generation += 1;
        let _published = self
            .surface
            .update(self.generation, self.size, damage, |frame| {
                for (index, cell) in patches {
                    *frame.cell_mut(*index) = cell.clone();
                }
                frame.set_cursor(Some(cursor));
                frame.set_resize_metadata(self.resize_sequence, self.pixel_size);
            });
    }

    fn drain_events(&mut self) -> EngineOutput {
        let mut output = EngineOutput::default();
        for event in self.vt.effects() {
            if event.kind == 0 {
                output.pty_writes.push(event.bytes);
                continue;
            }
            let Some(body) = event.bytes.strip_prefix(b"52;") else {
                continue;
            };
            let Some(separator) = body.iter().position(|byte| *byte == b';') else {
                continue;
            };
            if !matches!(&body[..separator], b"" | b"c") {
                continue;
            }
            let payload = &body[separator + 1..];
            if payload == b"?" {
                let terminator = if event.kind == 3 { "\x07" } else { "\x1b\\" };
                let formatter: Arc<dyn Fn(&str) -> String + Send + Sync> = Arc::new(move |text| {
                    format!(
                        "\x1b]52;c;{}{terminator}",
                        base64::engine::general_purpose::STANDARD.encode(text)
                    )
                });
                if self.clipboard_policy.allow_osc52_read {
                    output.clipboard_reads.push(ClipboardReadRequest {
                        target: ClipboardTarget::Clipboard,
                        formatter,
                    });
                } else {
                    output.pty_writes.push(formatter("").into_bytes());
                }
            } else if self.clipboard_policy.allow_osc52_write {
                // The same strict policy as the web surface: canonical base64,
                // a one-MiB decoded limit, and valid UTF-8 on the clipboard.
                let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(payload) else {
                    continue;
                };
                if decoded.len() > 1024 * 1024 {
                    continue;
                }
                if let Ok(text) = String::from_utf8(decoded) {
                    output.clipboard_writes.push(ClipboardWrite {
                        target: ClipboardTarget::Clipboard,
                        text,
                    });
                }
            }
        }
        output
    }
}

struct GridObservation {
    row_identities: Vec<[u64; 2]>,
}
struct ScrollObservation {
    top: usize,
    bottom: usize,
    delta: i32,
}

fn previous_row_after_damage(row: usize, damage: &[Damage]) -> Option<usize> {
    damage.iter().rev().try_fold(row, |row, damage| {
        let Damage::Scroll { top, bottom, delta } = *damage else {
            return Some(row);
        };
        if row < top || row >= bottom {
            return Some(row);
        }
        let previous = i64::try_from(row).ok()? - i64::from(delta);
        usize::try_from(previous)
            .ok()
            .filter(|row| *row >= top && *row < bottom)
    })
}

fn detect_scroll(before: &GridObservation, after: &GridObservation) -> Option<ScrollObservation> {
    let row_count = before.row_identities.len();
    if row_count != after.row_identities.len() || row_count < 2 {
        return None;
    }

    let old_rows = before
        .row_identities
        .iter()
        .copied()
        .enumerate()
        .map(|(row, identity)| (identity, row))
        .collect::<HashMap<_, _>>();
    let mut best: Option<(usize, usize, i32)> = None;
    let mut run: Option<(usize, usize, usize, i32)> = None;
    for (new_row, identity) in after.row_identities.iter().enumerate() {
        let Some(&old_row) = old_rows.get(identity) else {
            run = None;
            continue;
        };
        let delta = i32::try_from(new_row).ok()? - i32::try_from(old_row).ok()?;
        if delta == 0 {
            run = None;
            continue;
        }
        let (start, length) = match run {
            Some((start, length, previous_old, run_delta))
                if run_delta == delta && previous_old.checked_add(1) == Some(old_row) =>
            {
                (start, length + 1)
            }
            _ => (new_row, 1),
        };
        run = Some((start, length, old_row, delta));
        if best.is_none_or(|(_, best_length, _)| length > best_length) {
            best = Some((start, length, delta));
        }
    }

    let (match_start, match_length, delta) = best?;
    let distance = usize::try_from(delta.unsigned_abs()).ok()?;
    let match_end = match_start + match_length;
    let (top, bottom) = if delta < 0 {
        (match_start, match_end + distance)
    } else {
        (match_start.checked_sub(distance)?, match_end)
    };
    if bottom > row_count {
        return None;
    }

    Some(ScrollObservation { top, bottom, delta })
}

fn coalesce_rows(rows: &[usize]) -> Vec<Damage> {
    let Some((&first, rest)) = rows.split_first() else {
        return Vec::new();
    };
    let mut damage = Vec::new();
    let mut start = first;
    let mut previous = first;

    for &row in rest {
        if row != previous + 1 {
            damage.push(Damage::Rows {
                start,
                end: previous + 1,
            });
            start = row;
        }
        previous = row;
    }
    damage.push(Damage::Rows {
        start,
        end: previous + 1,
    });
    damage
}

fn indexed_color(index: u8, default_colors: DefaultColors) -> Rgb {
    const DARK_ANSI: [Rgb; 16] = [
        Rgb::new(0x11, 0x13, 0x18),
        Rgb::new(0xcc, 0x66, 0x66),
        Rgb::new(0x7e, 0xc6, 0x99),
        Rgb::new(0xd9, 0xb8, 0x72),
        Rgb::new(0x71, 0x9c, 0xd6),
        Rgb::new(0xb4, 0x80, 0xd6),
        Rgb::new(0x70, 0xc0, 0xc9),
        Rgb::new(0xd5, 0xd8, 0xde),
        Rgb::new(0x66, 0x6b, 0x78),
        Rgb::new(0xe3, 0x7a, 0x7a),
        Rgb::new(0x98, 0xd8, 0xad),
        Rgb::new(0xe7, 0xc9, 0x88),
        Rgb::new(0x89, 0xb1, 0xe5),
        Rgb::new(0xc6, 0x99, 0xe8),
        Rgb::new(0x88, 0xd1, 0xd8),
        Rgb::new(0xee, 0xf0, 0xf4),
    ];
    const LIGHT_ANSI: [Rgb; 16] = [
        Rgb::new(0x1e, 0x1e, 0x1e),
        Rgb::new(0xb5, 0x20, 0x20),
        Rgb::new(0x12, 0x6a, 0x00),
        Rgb::new(0x70, 0x58, 0x00),
        Rgb::new(0x04, 0x51, 0xa5),
        Rgb::new(0x8f, 0x2a, 0x8f),
        Rgb::new(0x00, 0x66, 0x6d),
        Rgb::new(0x55, 0x59, 0x5e),
        Rgb::new(0x45, 0x49, 0x4f),
        Rgb::new(0x9c, 0x1c, 0x1c),
        Rgb::new(0x00, 0x64, 0x00),
        Rgb::new(0x5f, 0x51, 0x00),
        Rgb::new(0x00, 0x3e, 0xaa),
        Rgb::new(0x76, 0x20, 0x76),
        Rgb::new(0x00, 0x5f, 0x66),
        Rgb::new(0x3a, 0x48, 0x51),
    ];
    if index < 16 {
        let background = default_colors.background();
        let brightness = 299 * u32::from(background.red)
            + 587 * u32::from(background.green)
            + 114 * u32::from(background.blue);
        let palette = if brightness >= 128_000 {
            LIGHT_ANSI
        } else {
            DARK_ANSI
        };
        return palette[usize::from(index)];
    }
    if index < 232 {
        let value = index - 16;
        let component = |position: u8| {
            let level = (value / position) % 6;
            if level == 0 { 0 } else { 55 + level * 40 }
        };
        return Rgb::new(component(36), component(6), component(1));
    }
    let gray = 8 + (index - 232).min(23) * 10;
    Rgb::new(gray, gray, gray)
}

#[cfg(test)]
thread_local! {
    static CONVERTED_CELLS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;

    use surface::{GridSize, Rgb};

    use super::{CONVERTED_CELLS, DefaultColors, GridObservation, TerminalEngine, detect_scroll};

    #[test]
    fn configured_default_colors_apply_to_terminal_cells() {
        let size = GridSize::new(2, 1).expect("valid grid");
        let colors = DefaultColors::new(Rgb::new(0x12, 0x34, 0x56), Rgb::new(0x65, 0x43, 0x21));
        let mut engine = TerminalEngine::with_default_colors(size, colors);

        let _output = engine.process(b"x");
        let frame = engine.surface().load();
        let cell = &frame.row(0)[0];

        assert_eq!(cell.foreground, colors.foreground());
        assert_eq!(cell.background, colors.background());
    }

    #[test]
    fn dynamic_palette_changes_apply_to_rendered_cells() {
        let size = GridSize::new(3, 1).expect("valid grid");
        let mut engine = TerminalEngine::new(size);

        let _output = engine.process(
            b"\x1b]4;1;#123456\x1b\\\x1b]10;#abcdef\x1b\\\x1b]11;#654321\x1b\\\
              \x1b[31mx\x1b[39my",
        );
        let frame = engine.surface().load();

        assert_eq!(frame.row(0)[0].foreground, Rgb::new(0x12, 0x34, 0x56));
        assert_eq!(frame.row(0)[1].foreground, Rgb::new(0xab, 0xcd, 0xef));
        assert_eq!(frame.row(0)[0].background, Rgb::new(0x65, 0x43, 0x21));
        assert_eq!(frame.row(0)[1].background, Rgb::new(0x65, 0x43, 0x21));
    }

    #[test]
    fn alternate_screen_entry_is_sticky_within_one_process_call() {
        let mut engine = TerminalEngine::new(GridSize::new(2, 1).expect("valid grid"));

        let _output = engine.process(b"\x1b[?1049h\x1b[?1049l");

        assert!(engine.has_entered_alternate_screen());
        assert!(!engine.vt.mode(1049));
    }

    #[test]
    fn row_identity_lookup_detects_a_partial_scroll_region() {
        let before = GridObservation {
            row_identities: (0..10).map(|value| [value, 0]).collect(),
        };
        let after = GridObservation {
            row_identities: [0, 1, 3, 4, 5, 6, 7, 2, 8, 9]
                .map(|value| [value, 0])
                .to_vec(),
        };

        let scroll = detect_scroll(&before, &after).expect("partial scroll");

        assert_eq!(scroll.top, 2);
        assert_eq!(scroll.bottom, 8);
        assert_eq!(scroll.delta, -1);
    }

    #[test]
    fn editing_one_row_converts_only_that_row() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let mut engine = TerminalEngine::new(size);
        let mut initial = String::new();
        for row in 0..24 {
            write!(initial, "row-{row:02}\r\n").expect("write terminal fixture");
        }
        let _output = engine.process(initial.as_bytes());
        CONVERTED_CELLS.set(0);

        let _output = engine.process(b"\x1b[12;1Hnext");

        assert!(
            CONVERTED_CELLS.get() <= size.columns() * 2,
            "one-row edit converted the full grid"
        );
    }
}
