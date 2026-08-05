//! Backend-neutral terminal paint vocabulary.

use std::fmt;
use std::sync::{Arc, Mutex};

use arc_swap::ArcSwap;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GridSize {
    columns: usize,
    rows: usize,
}

impl GridSize {
    /// Create a non-empty terminal grid.
    ///
    /// # Errors
    ///
    /// Returns an error when either dimension is zero or the cell count
    /// overflows.
    pub fn new(columns: usize, rows: usize) -> Result<Self, GridSizeError> {
        if columns == 0 || rows == 0 || columns.checked_mul(rows).is_none() {
            return Err(GridSizeError);
        }
        Ok(Self { columns, rows })
    }

    #[must_use]
    pub const fn columns(self) -> usize {
        self.columns
    }

    #[must_use]
    pub const fn rows(self) -> usize {
        self.rows
    }

    #[must_use]
    pub const fn cell_count(self) -> usize {
        self.columns * self.rows
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GridSizeError;

impl fmt::Display for GridSizeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("terminal grid dimensions must be nonzero and fit in memory")
    }
}

impl std::error::Error for GridSizeError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Rgb {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl Rgb {
    pub const WHITE: Self = Self::new(0xee, 0xf0, 0xf4);
    pub const BLACK: Self = Self::new(0x11, 0x13, 0x18);

    #[must_use]
    pub const fn new(red: u8, green: u8, blue: u8) -> Self {
        Self { red, green, blue }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Cell {
    text: String,
    pub foreground: Rgb,
    pub background: Rgb,
    pub style: CellStyle,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct CellStyle(u8);

impl CellStyle {
    pub const BOLD: Self = Self(1 << 0);
    pub const ITALIC: Self = Self(1 << 1);
    pub const UNDERLINE: Self = Self(1 << 2);
    pub const INVERSE: Self = Self(1 << 3);
    pub const WIDE: Self = Self(1 << 4);
    pub const DIM: Self = Self(1 << 5);
    pub const HIDDEN: Self = Self(1 << 6);
    pub const STRIKE: Self = Self(1 << 7);

    #[must_use]
    pub const fn contains(self, style: Self) -> bool {
        self.0 & style.0 == style.0
    }

    pub fn insert(&mut self, style: Self) {
        self.0 |= style.0;
    }
}

impl Cell {
    #[must_use]
    pub fn plain(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            ..Self::default()
        }
    }

    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            text: " ".to_owned(),
            foreground: Rgb::WHITE,
            background: Rgb::BLACK,
            style: CellStyle::default(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Damage {
    Full,
    Scroll {
        top: usize,
        bottom: usize,
        delta: i32,
    },
    Rows {
        start: usize,
        end: usize,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Cursor {
    pub row: usize,
    pub column: usize,
    pub visible: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PixelSize {
    pub width: u16,
    pub height: u16,
}

impl PixelSize {
    #[must_use]
    pub const fn new(width: u16, height: u16) -> Self {
        Self { width, height }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SurfaceFrame {
    generation: u64,
    previous_generation: u64,
    size: GridSize,
    resize_sequence: u64,
    pixel_size: PixelSize,
    rows: Vec<Vec<Cell>>,
    cursor: Option<Cursor>,
    damage: Vec<Damage>,
}

impl SurfaceFrame {
    #[must_use]
    pub fn blank(generation: u64, size: GridSize) -> Self {
        Self {
            generation,
            previous_generation: generation,
            size,
            resize_sequence: 0,
            pixel_size: PixelSize::new(0, 0),
            rows: (0..size.rows())
                .map(|_| vec![Cell::default(); size.columns()])
                .collect(),
            cursor: None,
            damage: vec![Damage::Full],
        }
    }

    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    #[must_use]
    pub const fn previous_generation(&self) -> u64 {
        self.previous_generation
    }

    #[must_use]
    pub const fn size(&self) -> GridSize {
        self.size
    }

    #[must_use]
    pub const fn resize_sequence(&self) -> u64 {
        self.resize_sequence
    }

    #[must_use]
    pub const fn pixel_size(&self) -> PixelSize {
        self.pixel_size
    }

    pub fn set_resize_metadata(&mut self, sequence: u64, pixel_size: PixelSize) {
        self.resize_sequence = sequence;
        self.pixel_size = pixel_size;
    }

    pub fn cells(&self) -> impl Iterator<Item = &Cell> {
        self.rows.iter().flatten()
    }

    pub fn cells_mut(&mut self) -> impl Iterator<Item = &mut Cell> {
        self.rows.iter_mut().flatten()
    }

    #[must_use]
    pub fn cell(&self, index: usize) -> &Cell {
        let row = index / self.size.columns();
        let column = index % self.size.columns();
        &self.rows[row][column]
    }

    pub fn cell_mut(&mut self, index: usize) -> &mut Cell {
        let row = index / self.size.columns();
        let column = index % self.size.columns();
        &mut self.rows[row][column]
    }

    #[must_use]
    pub fn row(&self, row: usize) -> &[Cell] {
        &self.rows[row]
    }

    pub fn row_mut(&mut self, row: usize) -> &mut [Cell] {
        &mut self.rows[row]
    }

    #[must_use]
    pub const fn cursor(&self) -> Option<Cursor> {
        self.cursor
    }

    pub fn set_cursor(&mut self, cursor: Option<Cursor>) {
        self.cursor = cursor;
    }

    #[must_use]
    pub fn damage(&self) -> &[Damage] {
        &self.damage
    }

    pub fn set_damage(&mut self, damage: Vec<Damage>) {
        self.damage = damage;
    }

    #[must_use]
    pub const fn requires_full_repaint(&self, consumed_generation: u64) -> bool {
        consumed_generation != self.previous_generation
    }
}

#[derive(Debug)]
pub struct SurfaceStore {
    latest: ArcSwap<SurfaceFrame>,
    producer: Mutex<SurfaceFrame>,
}

impl SurfaceStore {
    #[must_use]
    pub fn new(initial: SurfaceFrame) -> Self {
        Self {
            producer: Mutex::new(initial.clone()),
            latest: ArcSwap::from_pointee(initial),
        }
    }

    #[must_use]
    pub fn publish(&self, mut frame: SurfaceFrame) -> bool {
        let latest = self.latest.load_full();
        if frame.generation() <= latest.generation() {
            return false;
        }
        frame.previous_generation = latest.generation();
        *self
            .producer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = frame.clone();
        self.latest.store(Arc::new(frame));
        true
    }

    /// Update the latest frame in place after applying structural damage.
    ///
    /// Scroll damage is applied before `render`, allowing a terminal backend
    /// to repaint only newly exposed or otherwise dirty rows.
    #[must_use]
    pub fn update(
        &self,
        generation: u64,
        size: GridSize,
        damage: &[Damage],
        mut render: impl FnMut(&mut SurfaceFrame),
    ) -> bool {
        let current_generation = self.latest.load().generation();
        if generation <= current_generation {
            return false;
        }

        let mut producer = self
            .producer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let previous_generation = producer.generation();
        prepare_frame(&mut producer, generation, size, damage);
        render(&mut producer);

        let published = std::mem::replace(&mut *producer, SurfaceFrame::blank(0, size));
        let retired = self.latest.swap(Arc::new(published));
        *producer = match Arc::try_unwrap(retired) {
            Ok(mut reusable) => {
                prepare_frame(&mut reusable, generation, size, damage);
                render(&mut reusable);
                reusable
            }
            Err(_) => self.latest.load_full().as_ref().clone(),
        };
        debug_assert_eq!(producer.generation(), generation);
        debug_assert_eq!(producer.previous_generation(), previous_generation);
        true
    }

    #[must_use]
    pub fn load(&self) -> SurfaceLease {
        self.latest.load_full()
    }
}

fn prepare_frame(frame: &mut SurfaceFrame, generation: u64, size: GridSize, damage: &[Damage]) {
    let previous_generation = frame.generation();
    if frame.size() == size {
        for entry in damage {
            if let Damage::Scroll { top, bottom, delta } = *entry {
                apply_scroll(frame, top, bottom, delta);
            }
        }
        frame.generation = generation;
        frame.previous_generation = previous_generation;
        frame.damage = damage.to_vec();
    } else {
        *frame = SurfaceFrame::blank(generation, size);
        frame.previous_generation = previous_generation;
    }
}

fn apply_scroll(frame: &mut SurfaceFrame, top: usize, bottom: usize, delta: i32) {
    let rows = frame.size.rows();
    if top >= bottom || bottom > rows || delta == 0 {
        return;
    }

    let height = bottom - top;
    let distance = usize::try_from(delta.unsigned_abs())
        .unwrap_or(usize::MAX)
        .min(height);
    let affected = &mut frame.rows[top..bottom];

    if delta < 0 {
        affected.rotate_left(distance);
        for row in &mut affected[height - distance..] {
            row.fill(Cell::default());
        }
    } else {
        affected.rotate_right(distance);
        for row in &mut affected[..distance] {
            row.fill(Cell::default());
        }
    }
}

pub type SurfaceLease = Arc<SurfaceFrame>;
