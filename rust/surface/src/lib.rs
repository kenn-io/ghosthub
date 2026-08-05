//! Backend-neutral terminal paint vocabulary.

use std::fmt;
use std::ops::Deref;
use std::sync::{RwLock, RwLockReadGuard};

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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SurfaceFrame {
    generation: u64,
    size: GridSize,
    cells: Vec<Cell>,
    cursor: Option<Cursor>,
    damage: Vec<Damage>,
}

impl SurfaceFrame {
    #[must_use]
    pub fn blank(generation: u64, size: GridSize) -> Self {
        Self {
            generation,
            size,
            cells: vec![Cell::default(); size.cell_count()],
            cursor: None,
            damage: vec![Damage::Full],
        }
    }

    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    #[must_use]
    pub const fn size(&self) -> GridSize {
        self.size
    }

    #[must_use]
    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }

    pub fn cells_mut(&mut self) -> &mut [Cell] {
        &mut self.cells
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
}

#[derive(Debug)]
pub struct SurfaceStore {
    latest: RwLock<SurfaceFrame>,
}

impl SurfaceStore {
    #[must_use]
    pub fn new(initial: SurfaceFrame) -> Self {
        Self {
            latest: RwLock::new(initial),
        }
    }

    #[must_use]
    pub fn publish(&self, frame: SurfaceFrame) -> bool {
        let mut latest = self
            .latest
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if frame.generation() <= latest.generation() {
            return false;
        }
        *latest = frame;
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
        damage: Vec<Damage>,
        render: impl FnOnce(&mut SurfaceFrame),
    ) -> bool {
        let mut latest = self
            .latest
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if generation <= latest.generation() {
            return false;
        }

        if latest.size() == size {
            for entry in &damage {
                if let Damage::Scroll { top, bottom, delta } = *entry {
                    apply_scroll(&mut latest, top, bottom, delta);
                }
            }
            latest.generation = generation;
            latest.damage = damage;
        } else {
            *latest = SurfaceFrame::blank(generation, size);
        }

        render(&mut latest);
        true
    }

    #[must_use]
    pub fn load(&self) -> SurfaceLease<'_> {
        SurfaceLease {
            frame: self
                .latest
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        }
    }
}

fn apply_scroll(frame: &mut SurfaceFrame, top: usize, bottom: usize, delta: i32) {
    let rows = frame.size.rows();
    let columns = frame.size.columns();
    if top >= bottom || bottom > rows || delta == 0 {
        return;
    }

    let height = bottom - top;
    let distance = usize::try_from(delta.unsigned_abs())
        .unwrap_or(usize::MAX)
        .min(height);
    let cells = &mut frame.cells[top * columns..bottom * columns];
    let cell_distance = distance * columns;
    let cell_count = cells.len();

    if delta < 0 {
        cells.rotate_left(cell_distance);
        cells[cell_count - cell_distance..].fill(Cell::default());
    } else {
        cells.rotate_right(cell_distance);
        cells[..cell_distance].fill(Cell::default());
    }
}

pub struct SurfaceLease<'a> {
    frame: RwLockReadGuard<'a, SurfaceFrame>,
}

impl Deref for SurfaceLease<'_> {
    type Target = SurfaceFrame;

    fn deref(&self) -> &Self::Target {
        &self.frame
    }
}
