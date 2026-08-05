//! Terminal engine and PTY client ownership.

use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{ClipboardType, Config, Osc52, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor};
use input::TerminalModes;
use surface::{
    Cell as SurfaceCell, CellStyle, Cursor, Damage, GridSize, Rgb, SurfaceFrame, SurfaceStore,
};

#[derive(Clone, Debug, Default)]
struct EventCollector {
    pending: Arc<Mutex<Vec<Event>>>,
}

impl EventListener for EventCollector {
    fn send_event(&self, event: Event) {
        self.pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(event);
    }
}

#[derive(Clone, Copy)]
struct DimensionsValue(GridSize);

impl Dimensions for DimensionsValue {
    fn total_lines(&self) -> usize {
        self.0.rows()
    }

    fn screen_lines(&self) -> usize {
        self.0.rows()
    }

    fn columns(&self) -> usize {
        self.0.columns()
    }
}

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
}

impl Default for ClipboardPolicy {
    fn default() -> Self {
        Self::remote(true)
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
    parser: Processor,
    term: Term<EventCollector>,
    events: EventCollector,
    surface: Arc<SurfaceStore>,
    size: GridSize,
    generation: u64,
    clipboard_policy: ClipboardPolicy,
}

impl TerminalEngine {
    #[must_use]
    pub fn new(size: GridSize) -> Self {
        Self::with_clipboard_policy(size, ClipboardPolicy::default())
    }

    #[must_use]
    pub fn with_clipboard_policy(size: GridSize, clipboard_policy: ClipboardPolicy) -> Self {
        let events = EventCollector::default();
        let config = Config {
            scrolling_history: 0,
            kitty_keyboard: true,
            osc52: Osc52::CopyPaste,
            ..Config::default()
        };
        let term = Term::new(config, &DimensionsValue(size), events.clone());
        let surface = Arc::new(SurfaceStore::new(SurfaceFrame::blank(0, size)));
        let mut engine = Self {
            parser: Processor::new(),
            term,
            events,
            surface,
            size,
            generation: 0,
            clipboard_policy,
        };
        engine.publish_full();
        engine.term.reset_damage();
        engine
    }

    #[must_use]
    pub fn process(&mut self, bytes: &[u8]) -> EngineOutput {
        let before = capture_grid(&self.term, self.size);
        self.parser.advance(&mut self.term, bytes);
        let after = capture_grid(&self.term, self.size);
        self.publish_damage(detect_scroll(&before, &after));
        self.drain_events()
    }

    #[must_use]
    pub fn surface(&self) -> &SurfaceStore {
        &self.surface
    }

    #[must_use]
    pub fn modes(&self) -> TerminalModes {
        let mode = self.term.mode();
        TerminalModes {
            application_cursor: mode.contains(TermMode::APP_CURSOR),
            bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE),
            sgr_mouse: mode.contains(TermMode::SGR_MOUSE),
        }
    }

    pub fn resize(&mut self, size: GridSize) {
        self.term.resize(DimensionsValue(size));
        self.size = size;
        self.publish_full();
        self.term.reset_damage();
    }

    fn publish_full(&mut self) {
        let rows = 0..self.size.rows();
        self.publish_rows(vec![Damage::Full], rows);
    }

    fn publish_damage(&mut self, scroll: Option<ScrollObservation>) {
        let (damage, rows) = match self.term.damage() {
            TermDamage::Full => match scroll {
                Some(scroll) => {
                    let mut damage = vec![Damage::Scroll {
                        top: scroll.top,
                        bottom: scroll.bottom,
                        delta: scroll.delta,
                    }];
                    damage.extend(coalesce_rows(&scroll.dirty_rows));
                    (damage, scroll.dirty_rows)
                }
                None => (vec![Damage::Full], (0..self.size.rows()).collect()),
            },
            TermDamage::Partial(entries) => {
                let rows: Vec<_> = entries.map(|entry| entry.line).collect();
                let damage = coalesce_rows(&rows);
                (damage, rows)
            }
        };
        self.term.reset_damage();

        if damage.is_empty() {
            return;
        }
        self.publish_rows(damage, rows);
    }

    fn publish_rows(&mut self, damage: Vec<Damage>, rows: impl IntoIterator<Item = usize>) {
        let columns = self.size.columns();
        let grid = self.term.grid();
        let patches: Vec<_> = rows
            .into_iter()
            .flat_map(|row| {
                let line = i32::try_from(row).expect("terminal row fits an i32");
                (0..columns).map(move |column| {
                    let cell = &grid[Line(line)][Column(column)];
                    (row * columns + column, convert_cell(cell))
                })
            })
            .collect();
        let renderable = self.term.renderable_content();
        let cursor = Cursor {
            row: usize::try_from(renderable.cursor.point.line.0).unwrap_or(0),
            column: renderable.cursor.point.column.0,
            visible: renderable.mode.contains(TermMode::SHOW_CURSOR),
        };

        self.generation += 1;
        let _published = self
            .surface
            .update(self.generation, self.size, damage, move |frame| {
                for (index, cell) in patches {
                    frame.cells_mut()[index] = cell;
                }
                frame.set_cursor(Some(cursor));
            });
    }

    fn drain_events(&self) -> EngineOutput {
        let events = std::mem::take(
            &mut *self
                .events
                .pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        let mut output = EngineOutput::default();
        for event in events {
            match event {
                Event::PtyWrite(text) => output.pty_writes.push(text.into_bytes()),
                Event::ClipboardStore(target, text) if self.clipboard_policy.allow_osc52_write => {
                    output.clipboard_writes.push(ClipboardWrite {
                        target: convert_clipboard_target(target),
                        text,
                    });
                }
                Event::ClipboardLoad(target, formatter)
                    if self.clipboard_policy.allow_osc52_read =>
                {
                    output.clipboard_reads.push(ClipboardReadRequest {
                        target: convert_clipboard_target(target),
                        formatter,
                    });
                }
                Event::ClipboardLoad(_, formatter) => {
                    output.pty_writes.push(formatter("").into_bytes());
                }
                _ => {}
            }
        }
        output
    }
}

struct GridObservation {
    row_identities: Vec<usize>,
    row_fingerprints: Vec<u64>,
}

struct ScrollObservation {
    top: usize,
    bottom: usize,
    delta: i32,
    dirty_rows: Vec<usize>,
}

fn capture_grid(term: &Term<EventCollector>, size: GridSize) -> GridObservation {
    let grid = term.grid();
    let mut row_identities = Vec::with_capacity(size.rows());
    let mut row_fingerprints = Vec::with_capacity(size.rows());

    for row in 0..size.rows() {
        let line = i32::try_from(row).expect("terminal row fits an i32");
        let grid_row = &grid[Line(line)];
        row_identities.push(std::ptr::from_ref(grid_row).addr());

        let mut hasher = DefaultHasher::new();
        for column in 0..size.columns() {
            let cell = &grid_row[Column(column)];
            cell.c.hash(&mut hasher);
            cell.flags.bits().hash(&mut hasher);
            cell.zerowidth().hash(&mut hasher);
            hash_color(cell.fg, true, &mut hasher);
            hash_color(cell.bg, false, &mut hasher);
        }
        row_fingerprints.push(hasher.finish());
    }

    GridObservation {
        row_identities,
        row_fingerprints,
    }
}

fn hash_color(color: Color, foreground: bool, hasher: &mut impl Hasher) {
    let color = convert_color(color, foreground);
    color.red.hash(hasher);
    color.green.hash(hasher);
    color.blue.hash(hasher);
}

fn detect_scroll(before: &GridObservation, after: &GridObservation) -> Option<ScrollObservation> {
    let row_count = before.row_identities.len();
    if row_count != after.row_identities.len() || row_count < 2 {
        return None;
    }

    let limit = i32::try_from(row_count).ok()?;
    let mut best: Option<(usize, usize, i32)> = None;
    for delta in (1 - limit)..limit {
        if delta == 0 {
            continue;
        }

        let mut run_start = 0;
        let mut run_length = 0;
        for new_row in 0..row_count {
            let old_row = i32::try_from(new_row).ok()? - delta;
            let matches = usize::try_from(old_row)
                .ok()
                .filter(|old_row| *old_row < row_count)
                .is_some_and(|old_row| {
                    after.row_identities[new_row] == before.row_identities[old_row]
                });
            if matches {
                if run_length == 0 {
                    run_start = new_row;
                }
                run_length += 1;
                if best.is_none_or(|(_, length, _)| run_length > length) {
                    best = Some((run_start, run_length, delta));
                }
            } else {
                run_length = 0;
            }
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

    let dirty_rows = (0..row_count)
        .filter(|&new_row| {
            let old_row = if (top..bottom).contains(&new_row) {
                i32::try_from(new_row).expect("terminal row fits an i32") - delta
            } else {
                i32::try_from(new_row).expect("terminal row fits an i32")
            };
            usize::try_from(old_row)
                .ok()
                .filter(|old_row| *old_row < row_count)
                .is_none_or(|old_row| {
                    before.row_fingerprints[old_row] != after.row_fingerprints[new_row]
                })
        })
        .collect();

    Some(ScrollObservation {
        top,
        bottom,
        delta,
        dirty_rows,
    })
}

const fn convert_clipboard_target(target: ClipboardType) -> ClipboardTarget {
    match target {
        ClipboardType::Clipboard => ClipboardTarget::Clipboard,
        ClipboardType::Selection => ClipboardTarget::Selection,
    }
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

fn convert_cell(cell: &alacritty_terminal::term::cell::Cell) -> SurfaceCell {
    let mut text = if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
        String::new()
    } else {
        cell.c.to_string()
    };
    if let Some(zerowidth) = cell.zerowidth() {
        text.extend(zerowidth);
    }
    let mut converted = SurfaceCell::plain(text);
    converted.foreground = convert_color(cell.fg, true);
    converted.background = convert_color(cell.bg, false);
    if cell.flags.contains(Flags::BOLD) {
        converted.style.insert(CellStyle::BOLD);
    }
    if cell.flags.contains(Flags::ITALIC) {
        converted.style.insert(CellStyle::ITALIC);
    }
    if cell.flags.intersects(Flags::ALL_UNDERLINES) {
        converted.style.insert(CellStyle::UNDERLINE);
    }
    if cell.flags.contains(Flags::INVERSE) {
        converted.style.insert(CellStyle::INVERSE);
    }
    if cell.flags.contains(Flags::WIDE_CHAR) {
        converted.style.insert(CellStyle::WIDE);
    }
    converted
}

fn convert_color(color: Color, foreground: bool) -> Rgb {
    match color {
        Color::Spec(color) => Rgb::new(color.r, color.g, color.b),
        Color::Indexed(index) => indexed_color(index),
        Color::Named(NamedColor::Foreground | NamedColor::BrightForeground) => Rgb::WHITE,
        Color::Named(NamedColor::Background | NamedColor::Cursor) => Rgb::BLACK,
        Color::Named(named) if standard_named_index(named).is_some() => {
            indexed_color(standard_named_index(named).expect("standard color has an index"))
        }
        Color::Named(named) => {
            dim_named_color(named).unwrap_or(if foreground { Rgb::WHITE } else { Rgb::BLACK })
        }
    }
}

fn standard_named_index(color: NamedColor) -> Option<u8> {
    match color {
        NamedColor::Black => Some(0),
        NamedColor::Red => Some(1),
        NamedColor::Green => Some(2),
        NamedColor::Yellow => Some(3),
        NamedColor::Blue => Some(4),
        NamedColor::Magenta => Some(5),
        NamedColor::Cyan => Some(6),
        NamedColor::White => Some(7),
        NamedColor::BrightBlack => Some(8),
        NamedColor::BrightRed => Some(9),
        NamedColor::BrightGreen => Some(10),
        NamedColor::BrightYellow => Some(11),
        NamedColor::BrightBlue => Some(12),
        NamedColor::BrightMagenta => Some(13),
        NamedColor::BrightCyan => Some(14),
        NamedColor::BrightWhite => Some(15),
        _ => None,
    }
}

fn dim_named_color(color: NamedColor) -> Option<Rgb> {
    let index = match color {
        NamedColor::DimBlack => 0,
        NamedColor::DimRed => 1,
        NamedColor::DimGreen => 2,
        NamedColor::DimYellow => 3,
        NamedColor::DimBlue => 4,
        NamedColor::DimMagenta => 5,
        NamedColor::DimCyan => 6,
        NamedColor::DimWhite | NamedColor::DimForeground => 7,
        _ => return None,
    };
    Some(indexed_color(index))
}

fn indexed_color(index: u8) -> Rgb {
    const ANSI: [Rgb; 16] = [
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
    if index < 16 {
        return ANSI[usize::from(index)];
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
