//! Terminal engine and PTY client ownership.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::term::{ClipboardType, Config, Osc52, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::{
    Color, CursorShape as VteCursorShape, CursorStyle as VteCursorStyle, Handler,
    ModifyOtherKeys as VteModifyOtherKeys, NamedColor, NamedPrivateMode, PrivateMode, Processor,
};
use input::{KittyKeyboard, ModifyOtherKeys, MouseTracking, TerminalModes};
use surface::{
    Cell as SurfaceCell, CellStyle, Cursor, CursorShape, Damage, GridSize, PixelSize, Rgb,
    SurfaceFrame, SurfaceStore,
};

mod pty;
mod relay;
mod windows_job;
mod worker;

pub use pty::WorkerError;
pub use relay::{ByteRelayWorker, INPUT_BYTE_CAPACITY, RelayDisconnect, RelayOutput};
pub use worker::{TerminalEvent, TerminalStartup, TerminalWorker};

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
    parser: Processor,
    damage_parser: Processor,
    damage_boundary: StructuralBoundary,
    entered_alternate_screen: bool,
    term: Term<EventCollector>,
    events: EventCollector,
    surface: Arc<SurfaceStore>,
    size: GridSize,
    generation: u64,
    resize_sequence: u64,
    pixel_size: PixelSize,
    clipboard_policy: ClipboardPolicy,
    default_colors: DefaultColors,
    config: Config,
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
        let events = EventCollector::default();
        let config = Config {
            scrolling_history: 0,
            default_cursor_style: vte_cursor_style(default_cursor_shape),
            kitty_keyboard: true,
            osc52: Osc52::CopyPaste,
            ..Config::default()
        };
        let term = Term::new(config.clone(), &DimensionsValue(size), events.clone());
        let surface = Arc::new(SurfaceStore::new(SurfaceFrame::blank(0, size)));
        let mut engine = Self {
            parser: Processor::new(),
            damage_parser: Processor::new(),
            damage_boundary: StructuralBoundary::default(),
            entered_alternate_screen: false,
            term,
            events,
            surface,
            size,
            generation: 0,
            resize_sequence,
            pixel_size,
            clipboard_policy,
            default_colors,
            config,
        };
        engine.publish_full();
        engine.term.reset_damage();
        engine
    }

    pub fn set_default_cursor_shape(&mut self, shape: CursorShape) {
        self.config.default_cursor_style = vte_cursor_style(shape);
        self.term.set_options(self.config.clone());
        self.publish_full();
        self.term.reset_damage();
    }

    #[must_use]
    pub fn process(&mut self, bytes: &[u8]) -> EngineOutput {
        let mut segment_start = 0;
        for (index, byte) in bytes.iter().enumerate() {
            self.damage_parser
                .advance(&mut self.damage_boundary, std::slice::from_ref(byte));
            self.entered_alternate_screen |= self.damage_boundary.take_alternate_screen_entry();
            if !self.damage_boundary.take() {
                continue;
            }
            if segment_start < index {
                self.process_segment(&bytes[segment_start..index], false);
            }
            self.process_segment(&bytes[index..=index], true);
            segment_start = index + 1;
        }
        if segment_start < bytes.len() {
            self.process_segment(&bytes[segment_start..], false);
        }
        self.drain_events()
    }

    fn process_segment(&mut self, bytes: &[u8], observe_scroll: bool) {
        let before = observe_scroll.then(|| capture_grid(&self.term, self.size));
        self.parser.advance(&mut self.term, bytes);
        let scroll = before.and_then(|before| {
            let after = capture_grid(&self.term, self.size);
            detect_scroll(&before, &after)
        });
        self.publish_damage(scroll);
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
        let mode = self.term.mode();
        TerminalModes {
            application_cursor: mode.contains(TermMode::APP_CURSOR),
            application_keypad: mode.contains(TermMode::APP_KEYPAD),
            bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE),
            mouse_tracking: if mode.contains(TermMode::MOUSE_MOTION) {
                MouseTracking::Motion
            } else if mode.contains(TermMode::MOUSE_DRAG) {
                MouseTracking::Drag
            } else if mode.contains(TermMode::MOUSE_REPORT_CLICK) {
                MouseTracking::Click
            } else {
                MouseTracking::None
            },
            sgr_mouse: mode.contains(TermMode::SGR_MOUSE),
            modify_other_keys: self.damage_boundary.modify_other_keys,
            kitty_keyboard: KittyKeyboard {
                disambiguate_escape_codes: mode.contains(TermMode::DISAMBIGUATE_ESC_CODES),
                report_event_types: mode.contains(TermMode::REPORT_EVENT_TYPES),
                report_alternate_keys: mode.contains(TermMode::REPORT_ALTERNATE_KEYS),
                report_all_keys_as_escape_codes: mode.contains(TermMode::REPORT_ALL_KEYS_AS_ESC),
                report_associated_text: mode.contains(TermMode::REPORT_ASSOCIATED_TEXT),
            },
        }
    }

    fn has_entered_alternate_screen(&self) -> bool {
        self.entered_alternate_screen
    }

    pub fn resize(&mut self, size: GridSize) {
        self.resize_sequence = self.resize_sequence.saturating_add(1);
        self.resize_with_metadata(size, self.resize_sequence, PixelSize::default());
    }

    pub fn resize_with_metadata(
        &mut self,
        size: GridSize,
        resize_sequence: u64,
        pixel_size: PixelSize,
    ) {
        self.term.resize(DimensionsValue(size));
        self.size = size;
        self.resize_sequence = resize_sequence;
        self.pixel_size = pixel_size;
        self.publish_full();
        self.term.reset_damage();
    }

    fn publish_full(&mut self) {
        let damage = [Damage::Full];
        let (patches, _) = self.collect_patches(&damage, 0..self.size.rows());
        self.publish_patches(&damage, patches);
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
        let (patches, changed_rows) = self.collect_patches(&damage, rows);
        let mut effective_damage = damage
            .iter()
            .filter(|damage| matches!(damage, Damage::Full | Damage::Scroll { .. }))
            .cloned()
            .collect::<Vec<_>>();
        effective_damage.extend(coalesce_rows(&changed_rows));
        self.publish_patches(&effective_damage, patches);
    }

    fn collect_patches(
        &self,
        damage: &[Damage],
        rows: impl IntoIterator<Item = usize>,
    ) -> (Vec<(usize, SurfaceCell)>, Vec<usize>) {
        let columns = self.size.columns();
        let grid = self.term.grid();
        let colors = self.term.colors();
        let previous = self.surface.load();
        let full = damage.contains(&Damage::Full);
        let mut patches = Vec::new();
        let mut changed_rows = Vec::new();
        for row in rows {
            let line = i32::try_from(row).expect("terminal row fits an i32");
            let previous_row = previous_row_after_damage(row, damage);
            let mut changed = false;
            for column in 0..columns {
                let cell = convert_cell(
                    &grid[Line(line)][Column(column)],
                    colors,
                    self.default_colors,
                );
                let differs = if full {
                    true
                } else {
                    previous_row.map_or_else(
                        || cell != SurfaceCell::default(),
                        |row| cell != previous.row(row)[column],
                    )
                };
                if differs {
                    patches.push((row * columns + column, cell));
                    changed = true;
                }
            }
            if changed {
                changed_rows.push(row);
            }
        }
        (patches, changed_rows)
    }

    fn publish_patches(&mut self, damage: &[Damage], patches: Vec<(usize, SurfaceCell)>) {
        let renderable = self.term.renderable_content();
        let cursor = Cursor {
            row: usize::try_from(renderable.cursor.point.line.0).unwrap_or(0),
            column: renderable.cursor.point.column.0,
            visible: renderable.mode.contains(TermMode::SHOW_CURSOR)
                && renderable.cursor.shape != VteCursorShape::Hidden,
            shape: match renderable.cursor.shape {
                VteCursorShape::Block | VteCursorShape::HollowBlock => CursorShape::Block,
                VteCursorShape::Beam => CursorShape::Bar,
                VteCursorShape::Underline => CursorShape::Underline,
                VteCursorShape::Hidden => CursorShape::Hidden,
            },
        };
        let resize_sequence = self.resize_sequence;
        let pixel_size = self.pixel_size;

        self.generation += 1;
        let _published = self
            .surface
            .update(self.generation, self.size, damage, move |frame| {
                for (index, cell) in &patches {
                    *frame.cell_mut(*index) = cell.clone();
                }
                frame.set_cursor(Some(cursor));
                frame.set_resize_metadata(resize_sequence, pixel_size);
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

const fn vte_cursor_style(shape: CursorShape) -> VteCursorStyle {
    VteCursorStyle {
        shape: match shape {
            CursorShape::Block => VteCursorShape::Block,
            CursorShape::Bar => VteCursorShape::Beam,
            CursorShape::Underline => VteCursorShape::Underline,
            CursorShape::Hidden => VteCursorShape::Hidden,
        },
        blinking: false,
    }
}

struct GridObservation {
    row_identities: Vec<usize>,
}

struct ScrollObservation {
    top: usize,
    bottom: usize,
    delta: i32,
    dirty_rows: Vec<usize>,
}

#[derive(Default)]
struct StructuralBoundary {
    found: bool,
    entered_alternate_screen: bool,
    modify_other_keys: ModifyOtherKeys,
}

impl StructuralBoundary {
    fn mark(&mut self) {
        self.found = true;
    }

    fn take(&mut self) -> bool {
        std::mem::take(&mut self.found)
    }

    fn take_alternate_screen_entry(&mut self) -> bool {
        std::mem::take(&mut self.entered_alternate_screen)
    }
}

impl Handler for StructuralBoundary {
    fn set_modify_other_keys(&mut self, mode: VteModifyOtherKeys) {
        self.modify_other_keys = match mode {
            VteModifyOtherKeys::Reset => ModifyOtherKeys::Disabled,
            VteModifyOtherKeys::EnableExceptWellDefined => ModifyOtherKeys::ExceptWellDefined,
            VteModifyOtherKeys::EnableAll => ModifyOtherKeys::All,
        };
    }

    fn reset_state(&mut self) {
        self.modify_other_keys = ModifyOtherKeys::Disabled;
    }

    fn set_private_mode(&mut self, mode: PrivateMode) {
        if mode == NamedPrivateMode::SwapScreenAndSetRestoreCursor.into() {
            self.entered_alternate_screen = true;
        }
    }

    fn linefeed(&mut self) {
        self.mark();
    }

    fn newline(&mut self) {
        self.mark();
    }

    fn scroll_up(&mut self, _rows: usize) {
        self.mark();
    }

    fn scroll_down(&mut self, _rows: usize) {
        self.mark();
    }

    fn insert_blank_lines(&mut self, _count: usize) {
        self.mark();
    }

    fn delete_lines(&mut self, _count: usize) {
        self.mark();
    }

    fn reverse_index(&mut self) {
        self.mark();
    }
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

fn capture_grid(term: &Term<EventCollector>, size: GridSize) -> GridObservation {
    let grid = term.grid();
    let mut row_identities = Vec::with_capacity(size.rows());

    for row in 0..size.rows() {
        let line = i32::try_from(row).expect("terminal row fits an i32");
        let grid_row = &grid[Line(line)];
        row_identities.push(std::ptr::from_ref(grid_row).addr());
    }

    GridObservation { row_identities }
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

    let dirty_rows: Vec<_> = if delta < 0 {
        (bottom - distance..bottom).collect()
    } else {
        (top..top + distance).collect()
    };

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

fn convert_cell(
    cell: &alacritty_terminal::term::cell::Cell,
    colors: &Colors,
    default_colors: DefaultColors,
) -> SurfaceCell {
    #[cfg(test)]
    CONVERTED_CELLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut text = if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
        String::new()
    } else {
        cell.c.to_string()
    };
    if let Some(zerowidth) = cell.zerowidth() {
        text.extend(zerowidth);
    }
    let mut converted = SurfaceCell::plain(text);
    converted.foreground = convert_color(cell.fg, colors, true, default_colors);
    converted.background = convert_color(cell.bg, colors, false, default_colors);
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
    if cell.flags.contains(Flags::DIM) {
        converted.style.insert(CellStyle::DIM);
    }
    if cell.flags.contains(Flags::HIDDEN) {
        converted.style.insert(CellStyle::HIDDEN);
    }
    if cell.flags.contains(Flags::STRIKEOUT) {
        converted.style.insert(CellStyle::STRIKE);
    }
    converted
}

fn convert_color(
    color: Color,
    colors: &Colors,
    foreground: bool,
    default_colors: DefaultColors,
) -> Rgb {
    let configured = match color {
        Color::Spec(_) => None,
        Color::Indexed(index) => colors[usize::from(index)],
        Color::Named(named) => colors[named],
    };
    if let Some(color) = configured {
        return Rgb::new(color.r, color.g, color.b);
    }
    match color {
        Color::Spec(color) => Rgb::new(color.r, color.g, color.b),
        Color::Indexed(index) => indexed_color(index, default_colors),
        Color::Named(NamedColor::Foreground | NamedColor::BrightForeground) => {
            default_colors.foreground()
        }
        Color::Named(NamedColor::Background | NamedColor::Cursor) => default_colors.background(),
        Color::Named(NamedColor::DimForeground) => default_colors.foreground(),
        Color::Named(named) if standard_named_index(named).is_some() => indexed_color(
            standard_named_index(named).expect("standard color has an index"),
            default_colors,
        ),
        Color::Named(named) => dim_named_color(named, default_colors).unwrap_or({
            if foreground {
                default_colors.foreground()
            } else {
                default_colors.background()
            }
        }),
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

fn dim_named_color(color: NamedColor, default_colors: DefaultColors) -> Option<Rgb> {
    let index = match color {
        NamedColor::DimBlack => 0,
        NamedColor::DimRed => 1,
        NamedColor::DimGreen => 2,
        NamedColor::DimYellow => 3,
        NamedColor::DimBlue => 4,
        NamedColor::DimMagenta => 5,
        NamedColor::DimCyan => 6,
        NamedColor::DimWhite => 7,
        _ => return None,
    };
    Some(indexed_color(index, default_colors))
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
static CONVERTED_CELLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;
    use std::sync::atomic::Ordering;

    use surface::{GridSize, Rgb};

    use super::{
        CONVERTED_CELLS, DefaultColors, GridObservation, TermMode, TerminalEngine, detect_scroll,
    };

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
        assert!(!engine.term.mode().contains(TermMode::ALT_SCREEN));
    }

    #[test]
    fn row_identity_lookup_detects_a_partial_scroll_region() {
        let before = GridObservation {
            row_identities: (0..10).collect(),
        };
        let after = GridObservation {
            row_identities: vec![0, 1, 3, 4, 5, 6, 7, 2, 8, 9],
        };

        let scroll = detect_scroll(&before, &after).expect("partial scroll");

        assert_eq!(scroll.top, 2);
        assert_eq!(scroll.bottom, 8);
        assert_eq!(scroll.delta, -1);
        assert_eq!(scroll.dirty_rows, [7]);
    }

    #[test]
    fn one_line_scroll_converts_only_incremental_rows() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let mut engine = TerminalEngine::new(size);
        let mut initial = String::new();
        for row in 0..24 {
            write!(initial, "row-{row:02}\r\n").expect("write terminal fixture");
        }
        let _output = engine.process(initial.as_bytes());
        CONVERTED_CELLS.store(0, Ordering::Relaxed);

        let _output = engine.process(b"next\r\n");

        assert!(
            CONVERTED_CELLS.load(Ordering::Relaxed) <= size.columns() * 2,
            "one-line scroll converted the full grid"
        );
    }
}
