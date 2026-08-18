//! GPUI presentation for the Rust Ghosthub application.

#[cfg(windows)]
#[allow(unsafe_code)]
mod windows_key;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, Focusable, FontWeight,
    IntoElement, KeyBinding, KeyDownEvent, KeyUpEvent, MouseButton as GpuiMouseButton,
    MouseDownEvent, MouseMoveEvent, MouseUpEvent, PathPromptOptions, Render, ScrollWheelEvent,
    TitlebarOptions, Window, WindowBackgroundAppearance, WindowBounds, WindowControlArea,
    WindowDecorations, WindowOptions, actions, div, font, prelude::*, px, rgb, rgba, size,
};
use model::PortStatus;
use surface::{CellStyle, Damage, GridSize, Rgb, SurfaceFrame, SurfaceStore};
use workspace::{
    AppearanceSettingsDraft, ConfiguredSshHost, HerdrSessionState, HostConnectionState, HostItem,
    KeyEvent as InputKeyEvent, KeyInput, KwtProjectAction, Modifiers as InputModifiers,
    MouseAction, MouseButton, MouseInput, NamedKey, SessionName, SessionSelection, SshHostDraft,
    SshPromptRequest, TerminalTheme, Workspace, WorkspaceContent, WorkspaceEvent,
};

pub const WINDOW_TITLE: &str = "Ghosthub";
const APP_NAVIGATION_WIDTH: f32 = 224.0;
const APP_TITLEBAR_HEIGHT: f32 = 32.0;
const APP_CHROME_BACKGROUND: u32 = 0x0f_1116;
const NAVIGATION_HEADER_HEIGHT: f32 = 32.0;
const HOST_ROW_HEIGHT: f32 = 28.0;
const SESSION_GROUP_ROW_HEIGHT: f32 = 24.0;
const SESSION_ROW_HEIGHT: f32 = 27.0;
const SESSION_GROUP_BACKGROUND: u32 = 0x12_151b;
const SESSION_GROUP_TEXT: u32 = 0x86_8e9b;
const SESSION_GROUP_INSET: f32 = 12.0;
const SESSION_ROW_INSET: f32 = 18.0;
const NESTED_SESSION_ROW_INSET: f32 = 28.0;
const CELL_LINE_GAP: f32 = 4.0;
const UI_INPUT_CAPACITY: usize = 512;
const MOUSE_RELEASE_RESERVE: usize = 3;
const MAX_WHEEL_EVENTS_PER_CALLBACK: usize = 64;
const UI_INPUT_BYTE_CAPACITY: usize = 512 * 1024;
const SETTINGS_FIELD_CHARACTER_LIMIT: usize = 4 * 1024;
const TERMINAL_FONT_SIZES: [u16; 10] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 24];
const SSH_PROMPT_CHARACTER_LIMIT: usize = 64 * 1024;
const INPUT_BUFFERED_DIAGNOSTIC: &str = "Terminal is busy; input is buffered.";
const INPUT_BUFFER_FULL_DIAGNOSTIC: &str =
    "Terminal input buffer is full; wait for pending input to be delivered.";
const TERMINAL_NOTICE_DURATION: Duration = Duration::from_secs(5);

actions!(ghosthub, [ToggleSidebar]);

#[must_use]
pub fn headline_text(status: &PortStatus) -> String {
    status.headline()
}

#[must_use]
pub fn host_status_text(host: &HostItem) -> String {
    match host.connection() {
        HostConnectionState::Disconnected => format!("{} is ready to connect", host.endpoint()),
        HostConnectionState::Connecting => {
            format!(
                "Connecting to {} and discovering sessions…",
                host.endpoint()
            )
        }
        HostConnectionState::Ready => format!("Sessions in {}", host.endpoint()),
        HostConnectionState::Unavailable => host.diagnostic().map_or_else(
            || "Host is unavailable".to_owned(),
            |error| error.message().to_owned(),
        ),
    }
}

#[must_use]
pub fn empty_inventory_text(host: &HostItem) -> String {
    let namespace = host
        .socket_directory()
        .unwrap_or("the default tmux socket namespace");
    format!("No tmux sessions in {} using {namespace}.", host.endpoint())
}

#[must_use]
pub fn surface_text_rows(frame: &SurfaceFrame) -> Vec<String> {
    surface_paint_rows(frame)
        .into_iter()
        .map(|row| row.into_iter().map(|run| run.text).collect())
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaintRun {
    text: String,
    columns: usize,
    foreground: u32,
    background: u32,
    style: CellStyle,
}

impl PaintRun {
    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }

    #[must_use]
    pub const fn columns(&self) -> usize {
        self.columns
    }

    #[must_use]
    pub const fn foreground(&self) -> u32 {
        self.foreground
    }

    #[must_use]
    pub const fn background(&self) -> u32 {
        self.background
    }

    #[must_use]
    pub const fn bold(&self) -> bool {
        self.style.contains(CellStyle::BOLD)
    }
}

#[must_use]
pub fn surface_paint_rows(frame: &SurfaceFrame) -> Vec<Vec<PaintRun>> {
    (0..frame.size().rows())
        .map(|row| surface_paint_row(frame, row))
        .collect()
}

fn surface_paint_row(frame: &SurfaceFrame, row_index: usize) -> Vec<PaintRun> {
    let cursor = frame.cursor().filter(|cursor| cursor.visible);
    let row = frame.row(row_index);
    let mut runs: Vec<PaintRun> = Vec::new();
    for (column, cell) in row.iter().enumerate() {
        if cell.text().is_empty() && column > 0 && row[column - 1].style.contains(CellStyle::WIDE) {
            continue;
        }
        let inverted = cell.style.contains(CellStyle::INVERSE)
            ^ cursor.is_some_and(|cursor| cursor.row == row_index && cursor.column == column);
        let (mut foreground, background) = if inverted {
            (cell.background, cell.foreground)
        } else {
            (cell.foreground, cell.background)
        };
        if cell.style.contains(CellStyle::DIM) {
            foreground = Rgb::new(
                foreground.red / 2,
                foreground.green / 2,
                foreground.blue / 2,
            );
        }
        if cell.style.contains(CellStyle::HIDDEN) {
            foreground = background;
        }
        let run = PaintRun {
            text: if cell.text().is_empty() {
                " ".to_owned()
            } else {
                cell.text().to_owned()
            },
            columns: usize::from(cell.style.contains(CellStyle::WIDE)) + 1,
            foreground: rgb_value(foreground),
            background: rgb_value(background),
            style: cell.style,
        };
        if let Some(previous) = runs.last_mut()
            && previous.foreground == run.foreground
            && previous.background == run.background
            && previous.style == run.style
        {
            previous.text.push_str(&run.text);
            previous.columns += run.columns;
        } else {
            runs.push(run);
        }
    }
    runs
}

#[derive(Default)]
pub struct SurfacePaintCache {
    generation: u64,
    size: Option<GridSize>,
    cursor: Option<surface::Cursor>,
    rows: Vec<Arc<Vec<PaintRun>>>,
}

impl SurfacePaintCache {
    pub fn clear(&mut self) {
        *self = Self::default();
    }

    pub fn update(&mut self, frame: &SurfaceFrame) -> &[Arc<Vec<PaintRun>>] {
        let scrolled = frame
            .damage()
            .iter()
            .any(|damage| matches!(damage, Damage::Scroll { .. }));
        let full = self.size != Some(frame.size())
            || self.rows.len() != frame.size().rows()
            || frame.requires_full_repaint(self.generation)
            || frame.damage().contains(&Damage::Full);
        if full {
            self.rows = surface_paint_rows(frame)
                .into_iter()
                .map(Arc::new)
                .collect();
        } else {
            let mut scrolled_cursor_rows = Vec::new();
            for damage in frame.damage() {
                match *damage {
                    Damage::Full => unreachable!("full damage was handled above"),
                    Damage::Scroll { top, bottom, delta } => {
                        if let Some(exposed) =
                            apply_cached_scroll(&mut self.rows, top, bottom, delta)
                        {
                            repaint_rows(&mut self.rows, frame, exposed.start, exposed.end);
                        }
                        if let Some(cursor) = self.cursor
                            && cursor.row >= top
                            && cursor.row < bottom
                            && let Ok(row) = usize::try_from(
                                i64::try_from(cursor.row).unwrap_or(i64::MAX) + i64::from(delta),
                            )
                            && row < self.rows.len()
                        {
                            scrolled_cursor_rows.push(row);
                        }
                    }
                    Damage::Rows { start, end } => {
                        repaint_rows(&mut self.rows, frame, start, end);
                    }
                }
            }
            for row in scrolled_cursor_rows {
                repaint_rows(&mut self.rows, frame, row, row + 1);
            }
            if scrolled || self.cursor != frame.cursor() {
                if let Some(cursor) = self.cursor {
                    repaint_rows(&mut self.rows, frame, cursor.row, cursor.row + 1);
                }
                if let Some(cursor) = frame.cursor() {
                    repaint_rows(&mut self.rows, frame, cursor.row, cursor.row + 1);
                }
            }
        }
        self.generation = frame.generation();
        self.size = Some(frame.size());
        self.cursor = frame.cursor();
        &self.rows
    }
}

fn repaint_rows(rows: &mut [Arc<Vec<PaintRun>>], frame: &SurfaceFrame, start: usize, end: usize) {
    for row in start..end.min(rows.len()) {
        rows[row] = Arc::new(surface_paint_row(frame, row));
    }
}

fn apply_cached_scroll(
    rows: &mut [Arc<Vec<PaintRun>>],
    top: usize,
    bottom: usize,
    delta: i32,
) -> Option<std::ops::Range<usize>> {
    if top >= bottom || bottom > rows.len() || delta == 0 {
        return None;
    }
    let affected = &mut rows[top..bottom];
    let distance = usize::try_from(delta.unsigned_abs())
        .unwrap_or(usize::MAX)
        .min(affected.len());
    if delta < 0 {
        affected.rotate_left(distance);
        Some(bottom - distance..bottom)
    } else {
        affected.rotate_right(distance);
        Some(top..top + distance)
    }
}

const fn rgb_value(color: Rgb) -> u32 {
    (color.red as u32) << 16 | (color.green as u32) << 8 | color.blue as u32
}

pub struct RootView {
    status: PortStatus,
    workspace: Workspace,
    focus: FocusHandle,
    create_focus: FocusHandle,
    project_focus: FocusHandle,
    settings_focus: FocusHandle,
    ssh_prompt_focus: FocusHandle,
    kill_focus: FocusHandle,
    diagnostic: Option<String>,
    terminal_notice: TransientNotice,
    paste_confirmation: bool,
    observed_presentation_id: Option<u64>,
    observed_revision: u64,
    observed_surface_generation: u64,
    observed_surface_identity: Option<usize>,
    paint_cache: SurfacePaintCache,
    terminal_metrics: TerminalMetrics,
    pending_input: VecDeque<QueuedUiInput>,
    pending_input_bytes: usize,
    input_refusal: InputRefusal,
    wheel_remainder: f32,
    keyboard: TerminalKeyboard,
    pointer: TerminalPointer,
    sidebar_visible: bool,
    collapsed_session_groups: HashSet<SessionGroupKey>,
    new_session: Option<NewSessionDraft>,
    project_dialog: Option<ProjectDialog>,
    settings_dialog: Option<SettingsDialog>,
    ssh_prompts: VecDeque<SshPromptDialog>,
    pending_worktree_navigation: Option<u64>,
    session_action_menu: Option<SessionActionMenu>,
    restore_focus: bool,
}

#[derive(Default)]
struct TransientNotice {
    source: Option<(Option<u64>, String)>,
    expires_at: Option<Instant>,
    visible: bool,
}

impl TransientNotice {
    fn synchronize(
        &mut self,
        presentation_id: Option<u64>,
        notice: Option<&str>,
        transient: bool,
        now: Instant,
    ) {
        let source = notice.map(|notice| (presentation_id, notice.to_owned()));
        if self.source != source {
            self.source = source;
            self.visible = self.source.is_some();
            self.expires_at = (self.visible && transient).then(|| now + TERMINAL_NOTICE_DURATION);
        }
    }

    fn expire(&mut self, now: Instant) -> bool {
        if self.expires_at.is_some_and(|deadline| now >= deadline) {
            self.expires_at = None;
            self.visible = false;
            true
        } else {
            false
        }
    }

    fn visible(&self) -> Option<&str> {
        self.visible
            .then(|| self.source.as_ref().map(|(_, notice)| notice.as_str()))
            .flatten()
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum SessionGroup {
    Tmux,
    Herdr,
    Zellij,
}

impl SessionGroup {
    const fn element_id(self) -> &'static str {
        match self {
            Self::Tmux => "toggle-tmux-sessions",
            Self::Herdr => "toggle-herdr-sessions",
            Self::Zellij => "toggle-zellij-sessions",
        }
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct SessionGroupKey {
    host_id: String,
    group: SessionGroup,
}

fn toggle_session_group_state(
    collapsed: &mut HashSet<SessionGroupKey>,
    host_id: &str,
    group: SessionGroup,
) {
    let key = SessionGroupKey {
        host_id: host_id.to_owned(),
        group,
    };
    if !collapsed.remove(&key) {
        collapsed.insert(key);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SshField {
    Name,
    Hostname,
    User,
    Port,
    TmuxBinary,
    SocketDirectory,
}

impl SshField {
    const fn adjacent(self, backwards: bool) -> Self {
        if backwards {
            match self {
                Self::Name => Self::SocketDirectory,
                Self::Hostname => Self::Name,
                Self::User => Self::Hostname,
                Self::Port => Self::User,
                Self::TmuxBinary => Self::Port,
                Self::SocketDirectory => Self::TmuxBinary,
            }
        } else {
            match self {
                Self::Name => Self::Hostname,
                Self::Hostname => Self::User,
                Self::User => Self::Port,
                Self::Port => Self::TmuxBinary,
                Self::TmuxBinary => Self::SocketDirectory,
                Self::SocketDirectory => Self::Name,
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SettingsPane {
    Appearance,
    Hosts,
}

impl SettingsPane {
    const ALL: [Self; 2] = [Self::Appearance, Self::Hosts];

    const fn title(self) -> &'static str {
        match self {
            Self::Appearance => "Appearance",
            Self::Hosts => "Hosts",
        }
    }

    const fn subtitle(self) -> &'static str {
        match self {
            Self::Appearance => "Choose a terminal theme and installed monospace font.",
            Self::Hosts => "Connect the machines and tmux sessions in your SSH network.",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AppearanceField {
    Theme,
    FontFamily,
    FontSize,
    Background,
    Foreground,
}

impl AppearanceField {
    const fn adjacent(self, reverse: bool) -> Self {
        if reverse {
            match self {
                Self::Theme => Self::Foreground,
                Self::FontFamily => Self::Theme,
                Self::FontSize => Self::FontFamily,
                Self::Background => Self::FontSize,
                Self::Foreground => Self::Background,
            }
        } else {
            match self {
                Self::Theme => Self::FontFamily,
                Self::FontFamily => Self::FontSize,
                Self::FontSize => Self::Background,
                Self::Background => Self::Foreground,
                Self::Foreground => Self::Theme,
            }
        }
    }
}

fn adjacent_appearance_field(
    field: AppearanceField,
    reverse: bool,
    custom_theme: bool,
) -> AppearanceField {
    let mut adjacent = field.adjacent(reverse);
    while !custom_theme
        && matches!(
            adjacent,
            AppearanceField::Background | AppearanceField::Foreground
        )
    {
        adjacent = adjacent.adjacent(reverse);
    }
    adjacent
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AppearancePicker {
    FontFamily,
    FontSize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AppearanceEditor {
    draft: AppearanceSettingsDraft,
    field: AppearanceField,
    open_picker: Option<AppearancePicker>,
    font_families: Vec<String>,
    error: Option<String>,
}

impl AppearanceEditor {
    fn new(draft: AppearanceSettingsDraft, font_families: Vec<String>) -> Self {
        Self {
            draft,
            field: AppearanceField::Theme,
            open_picker: None,
            font_families,
            error: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SshHostEditor {
    original_id: Option<String>,
    draft: SshHostDraft,
    field: SshField,
    error: Option<String>,
}

impl SshHostEditor {
    fn new(host: Option<&ConfiguredSshHost>) -> Self {
        Self {
            original_id: host.map(|host| host.id().to_owned()),
            draft: host.map_or_else(SshHostDraft::default, |host| host.draft().clone()),
            field: SshField::Name,
            error: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SettingsDialog {
    pane: SettingsPane,
    appearance_editor: AppearanceEditor,
    selected_host_id: Option<String>,
    host_editor: Option<SshHostEditor>,
    pending_remove: Option<ConfiguredSshHost>,
    error: Option<String>,
}

impl SettingsDialog {
    fn new(
        hosts: &[ConfiguredSshHost],
        appearance: AppearanceSettingsDraft,
        font_families: Vec<String>,
    ) -> Self {
        let selected = hosts.first();
        Self {
            pane: SettingsPane::Appearance,
            appearance_editor: AppearanceEditor::new(appearance, font_families),
            selected_host_id: selected.map(|host| host.id().to_owned()),
            host_editor: selected.map(|host| SshHostEditor::new(Some(host))),
            pending_remove: None,
            error: None,
        }
    }
}

#[derive(Clone)]
struct SshPromptDialog {
    request: SshPromptRequest,
    value: String,
}

fn ssh_draft_field_mut(draft: &mut SshHostDraft, field: SshField) -> &mut String {
    match field {
        SshField::Name => &mut draft.name,
        SshField::Hostname => &mut draft.hostname,
        SshField::User => &mut draft.user,
        SshField::Port => &mut draft.port,
        SshField::TmuxBinary => &mut draft.tmux_binary,
        SshField::SocketDirectory => &mut draft.socket_directory,
    }
}

fn appearance_draft_field_mut(
    draft: &mut AppearanceSettingsDraft,
    field: AppearanceField,
) -> Option<&mut String> {
    match field {
        AppearanceField::Background => Some(&mut draft.background),
        AppearanceField::Foreground => Some(&mut draft.foreground),
        AppearanceField::Theme | AppearanceField::FontFamily | AppearanceField::FontSize => None,
    }
}

fn appearance_preview_color(value: &str, fallback: u32) -> u32 {
    value
        .strip_prefix('#')
        .filter(|digits| digits.len() == 6)
        .and_then(|digits| u32::from_str_radix(digits, 16).ok())
        .unwrap_or(fallback)
}

fn appearance_draft_is_persistable(draft: &AppearanceSettingsDraft) -> bool {
    let valid_font_size = draft
        .font_size
        .trim()
        .parse::<u16>()
        .is_ok_and(|size| size > 0);
    let valid_color = |value: &str| {
        value
            .strip_prefix('#')
            .is_some_and(|digits| digits.len() == 6 && u32::from_str_radix(digits, 16).is_ok())
    };
    !draft.font_family.trim().is_empty()
        && valid_font_size
        && (draft.theme != TerminalTheme::Custom
            || (valid_color(&draft.background) && valid_color(&draft.foreground)))
}

fn appearance_preview_colors(draft: &AppearanceSettingsDraft) -> (u32, u32) {
    draft.theme.colors().unwrap_or_else(|| {
        (
            appearance_preview_color(&draft.background, 0x0c_0f_14),
            appearance_preview_color(&draft.foreground, 0xd8_de_e9),
        )
    })
}

fn terminal_font_families(cx: &Context<RootView>, configured: &str) -> Vec<String> {
    let text_system = cx.text_system();
    let mut families = text_system
        .all_font_names()
        .into_iter()
        .filter(|family| !family.starts_with('.'))
        .filter(|family| {
            let font_id = text_system.resolve_font(&font(family.clone()));
            let advances = ['i', 'W', '0', 'm', ' '].map(|character| {
                text_system
                    .advance(font_id, px(14.0), character)
                    .map(|advance| f32::from(advance.width))
                    .unwrap_or_default()
            });
            let minimum = advances.iter().copied().fold(f32::INFINITY, f32::min);
            let maximum = advances.iter().copied().fold(f32::NEG_INFINITY, f32::max);
            minimum > 0.0 && maximum - minimum < 0.1
        })
        .collect::<Vec<_>>();
    if !configured.trim().is_empty() && !families.iter().any(|family| family == configured) {
        families.push(configured.to_owned());
    }
    families.sort_by_key(|family| family.to_ascii_lowercase());
    families.dedup_by(|left, right| left.eq_ignore_ascii_case(right));
    families
}

fn ssh_draft_field(draft: &SshHostDraft, field: SshField) -> &str {
    match field {
        SshField::Name => &draft.name,
        SshField::Hostname => &draft.hostname,
        SshField::User => &draft.user,
        SshField::Port => &draft.port,
        SshField::TmuxBinary => &draft.tmux_binary,
        SshField::SocketDirectory => &draft.socket_directory,
    }
}

fn ssh_host_subtitle(draft: &SshHostDraft) -> String {
    let user = (!draft.user.trim().is_empty()).then(|| format!("{}@", draft.user.trim()));
    let port = (!draft.port.trim().is_empty()).then(|| format!(":{}", draft.port.trim()));
    format!(
        "{}{}{}",
        user.unwrap_or_default(),
        draft.hostname.trim(),
        port.unwrap_or_default()
    )
}

fn append_non_control_characters(value: &mut String, text: &str, limit: usize) {
    let remaining = limit.saturating_sub(value.chars().count());
    value.extend(
        text.chars()
            .filter(|character| !character.is_control())
            .take(remaining),
    );
}

fn ssh_prompt_input_text(value: &str, focused: bool) -> String {
    if value.is_empty() {
        return if focused {
            "▏".to_owned()
        } else {
            "Password or passphrase".to_owned()
        };
    }
    let mut displayed = "•".repeat(value.chars().count());
    if focused {
        displayed.push('▏');
    }
    displayed
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NewSessionDraft {
    host_id: String,
    endpoint: String,
    kind: NewSessionKind,
    name: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorktreeOpenTarget {
    host_id: String,
    endpoint: String,
    repository: String,
    project_path: String,
    registration_fingerprint: String,
    worktree_path: String,
    generation: Option<String>,
    session_name: String,
    tmux_socket_name: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorktreeRemoveTarget {
    open: WorktreeOpenTarget,
    project_name: String,
    branch: String,
    session_was_running: bool,
    authority: Option<u64>,
    operation_id: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NewSessionKind {
    Tmux,
    Herdr,
    Zellij,
}

impl NewSessionKind {
    const fn group(self) -> SessionGroup {
        match self {
            Self::Tmux => SessionGroup::Tmux,
            Self::Herdr => SessionGroup::Herdr,
            Self::Zellij => SessionGroup::Zellij,
        }
    }

    const fn group_title(self) -> &'static str {
        match self {
            Self::Tmux => "TMUX SESSIONS",
            Self::Herdr => "HERDR SESSIONS",
            Self::Zellij => "ZELLIJ SESSIONS",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct SessionActionMenu {
    selection: SessionSelection,
    actions: Vec<SessionRowAction>,
    anchor_x: f32,
    anchor_y: f32,
}

const SESSION_ACTION_MENU_WIDTH: f32 = 148.0;
const SESSION_ACTION_MENU_ITEM_HEIGHT: f32 = 26.0;
const SESSION_ACTION_MENU_VERTICAL_CHROME: f32 = 8.0;
const SESSION_ACTION_MENU_MARGIN: f32 = 4.0;
const SESSION_ACTION_MENU_OFFSET: f32 = 3.0;

#[derive(Clone, Debug, Eq, PartialEq)]
enum ProjectDialog {
    Add {
        host_id: String,
        endpoint: String,
        path: String,
        submitting: bool,
        error: Option<String>,
    },
    Remove {
        host_id: String,
        endpoint: String,
        name: String,
        repository: String,
        path: String,
        registration_fingerprint: String,
        submitting: bool,
        error: Option<String>,
    },
    NewWorktree {
        host_id: String,
        endpoint: String,
        project_name: String,
        repository: String,
        project_path: String,
        registration_fingerprint: String,
        branch: String,
        mode: NewWorktreeMode,
        selected_source: Option<String>,
        selected_pull_request: Option<String>,
        branches: Vec<workspace::KwtBranchItem>,
        pull_requests: Vec<workspace::KwtPullRequestItem>,
        operation_id: Option<u64>,
        loading: bool,
        loaded: bool,
        submitting: bool,
        error: Option<String>,
    },
    RemoveWorktree {
        target: WorktreeRemoveTarget,
        submitting: bool,
        error: Option<String>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NewWorktreeMode {
    Branch,
    PullRequest,
}

impl ProjectDialog {
    const fn action(&self) -> Option<KwtProjectAction> {
        match self {
            Self::Add { .. } => Some(KwtProjectAction::Add),
            Self::Remove { .. } => Some(KwtProjectAction::Remove),
            Self::NewWorktree { .. } | Self::RemoveWorktree { .. } => None,
        }
    }
}

fn kwt_operation_failure_owns_dialog(
    dialog: Option<&ProjectDialog>,
    operation_id: u64,
    project_path: &str,
    worktree_path: Option<&str>,
) -> bool {
    match dialog {
        Some(ProjectDialog::NewWorktree {
            project_path: dialog_project,
            operation_id: dialog_operation,
            ..
        }) => *dialog_operation == Some(operation_id) && dialog_project == project_path,
        Some(ProjectDialog::RemoveWorktree { target, .. }) => {
            target.operation_id == Some(operation_id)
                && target.open.project_path == project_path
                && worktree_path == Some(target.open.worktree_path.as_str())
        }
        Some(ProjectDialog::Add { .. } | ProjectDialog::Remove { .. }) | None => false,
    }
}

fn apply_worktree_removal_failure(
    dialog: &mut ProjectDialog,
    operation_id: u64,
    project_path: &str,
    worktree_path: Option<&str>,
    message: String,
) -> bool {
    let ProjectDialog::RemoveWorktree {
        target,
        submitting,
        error,
    } = dialog
    else {
        return false;
    };
    if target.open.project_path != project_path
        || target.operation_id != Some(operation_id)
        || worktree_path != Some(target.open.worktree_path.as_str())
    {
        return false;
    }
    *submitting = false;
    target.authority = None;
    target.operation_id = None;
    *error = Some(message);
    true
}

fn apply_new_worktree_failure(
    dialog: &mut ProjectDialog,
    operation_id: u64,
    project_path: &str,
    message: String,
) -> bool {
    let ProjectDialog::NewWorktree {
        project_path: dialog_path,
        operation_id: dialog_operation,
        loading,
        submitting,
        error,
        ..
    } = dialog
    else {
        return false;
    };
    if dialog_path != project_path || *dialog_operation != Some(operation_id) {
        return false;
    }
    *loading = false;
    *submitting = false;
    *error = Some(message);
    true
}

fn has_ambiguous_worktree_source(dialog: &ProjectDialog) -> bool {
    let ProjectDialog::NewWorktree {
        branch,
        mode: NewWorktreeMode::Branch,
        selected_source,
        branches,
        loaded: true,
        loading: false,
        submitting: false,
        ..
    } = dialog
    else {
        return false;
    };
    let normalized = branch.trim();
    selected_source.is_none()
        && branches
            .iter()
            .filter(|candidate| candidate.name() == normalized)
            .take(2)
            .count()
            > 1
}

fn visible_kwt_pull_requests<'a>(
    pull_requests: &'a [workspace::KwtPullRequestItem],
    query: &str,
) -> Vec<&'a workspace::KwtPullRequestItem> {
    let query = query.trim().to_ascii_lowercase();
    pull_requests
        .iter()
        .filter(|pull_request| {
            query.is_empty()
                || pull_request.number().to_string() == query
                || pull_request.id().to_ascii_lowercase().contains(&query)
                || pull_request.url().to_ascii_lowercase().contains(&query)
                || pull_request.title().to_ascii_lowercase().contains(&query)
                || pull_request.author().to_ascii_lowercase().contains(&query)
                || pull_request
                    .source_branch()
                    .to_ascii_lowercase()
                    .contains(&query)
        })
        .collect()
}

fn pull_request_import_selector(
    pull_requests: &[workspace::KwtPullRequestItem],
    query: &str,
    selected_pull_request: Option<&str>,
) -> Option<String> {
    let query = query.trim();
    if selected_pull_request == Some(query)
        && pull_requests
            .iter()
            .any(|pull_request| pull_request.id() == query)
    {
        return Some(query.to_owned());
    }
    if pull_requests
        .iter()
        .any(|pull_request| pull_request.id() == query)
    {
        return Some(query.to_owned());
    }
    let number = query.strip_prefix('#').unwrap_or(query);
    if let Ok(number) = number.parse::<u64>()
        && number > 0
    {
        return Some(number.to_string());
    }
    ((query.starts_with("https://") || query.starts_with("http://"))
        && !query.chars().any(char::is_whitespace))
    .then(|| query.to_owned())
}

fn visible_kwt_branch_candidates<'a>(
    branches: &'a [workspace::KwtBranchItem],
    branch: &str,
) -> Vec<&'a workspace::KwtBranchItem> {
    const FUZZY_SUGGESTION_LIMIT: usize = 7;

    let query = branch.trim();
    let folded_query = query.to_ascii_lowercase();
    let mut exact = branches
        .iter()
        .filter(|candidate| !query.is_empty() && candidate.name() == query)
        .collect::<Vec<_>>();
    let fuzzy_limit = FUZZY_SUGGESTION_LIMIT.saturating_sub(exact.len());
    exact.extend(
        branches
            .iter()
            .filter(|candidate| candidate.name() != query)
            .filter(|candidate| {
                folded_query.is_empty()
                    || candidate
                        .name()
                        .to_ascii_lowercase()
                        .contains(&folded_query)
                    || candidate
                        .source()
                        .to_ascii_lowercase()
                        .contains(&folded_query)
            })
            .take(fuzzy_limit),
    );
    exact
}

fn can_create_worktree(branch: &str, loaded: bool, loading: bool, submitting: bool) -> bool {
    workspace::is_valid_git_branch_name(branch.trim()) && loaded && !loading && !submitting
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorktreeOpenMode {
    Disabled,
    DirectTmux,
    RepairOrOpen,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct WorktreeOpenContext {
    authority: WorktreeAuthority,
    socket: WorktreeSocket,
    session: WorktreeSessionPresence,
    presentation: WorktreePresentation,
    host: WorktreeHostAccess,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorktreeAuthority {
    Generation,
    Generationless,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorktreeSocket {
    Default,
    Custom,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorktreeSessionPresence {
    Discovered,
    Absent,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorktreePresentation {
    ActiveOrRetained,
    Inactive,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorktreeRowPresence {
    Idle,
    Live,
    Active,
}

impl WorktreeRowPresence {
    const fn is_active(self) -> bool {
        matches!(self, Self::Active)
    }

    const fn is_live(self) -> bool {
        !matches!(self, Self::Idle)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorktreeHostAccess {
    Ready { kwt_available: bool },
    Unavailable,
}

const fn worktree_open_mode(context: WorktreeOpenContext) -> WorktreeOpenMode {
    if matches!(context.presentation, WorktreePresentation::ActiveOrRetained) {
        return WorktreeOpenMode::DirectTmux;
    }
    let WorktreeHostAccess::Ready { kwt_available } = context.host else {
        return WorktreeOpenMode::Disabled;
    };
    if matches!(context.authority, WorktreeAuthority::Generation) && kwt_available {
        WorktreeOpenMode::RepairOrOpen
    } else if matches!(context.authority, WorktreeAuthority::Generationless)
        && matches!(context.session, WorktreeSessionPresence::Discovered)
    {
        WorktreeOpenMode::DirectTmux
    } else {
        WorktreeOpenMode::Disabled
    }
}

const fn can_kill_worktree(
    host_can_attach: bool,
    socket: WorktreeSocket,
    session: WorktreeSessionPresence,
    authority: WorktreeAuthority,
) -> bool {
    host_can_attach
        && if matches!(socket, WorktreeSocket::Custom) {
            matches!(authority, WorktreeAuthority::Generation)
        } else {
            matches!(session, WorktreeSessionPresence::Discovered)
        }
}

fn owns_created_worktree_navigation(
    pending: Option<u64>,
    event_generation: u64,
    workspace_generation_is_current: bool,
    dialog_project_path: Option<&str>,
    created_project_path: &str,
) -> bool {
    pending == Some(event_generation)
        && workspace_generation_is_current
        && dialog_project_path.is_none_or(|path| path == created_project_path)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct WheelBatch {
    input: MouseInput,
    remaining: u32,
}

#[derive(Clone, Copy, Debug)]
struct TerminalMetrics {
    cell_width: f32,
    line_height: f32,
}

#[derive(Default)]
struct TerminalPointer {
    pressed: [bool; 3],
    last_cell: Option<(usize, usize)>,
}

#[derive(Default)]
struct TerminalKeyboard {
    pressed: HashMap<TerminalKeyIdentity, KeyInput>,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
enum TerminalKeyIdentity {
    Layout(u16),
    Logical(String),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct LayoutKey {
    virtual_key: u16,
    unshifted: Option<char>,
    shifted: Option<char>,
    shift_required: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CanonicalTerminalKey {
    identity: TerminalKeyIdentity,
    modifiers: InputModifiers,
    layout: Option<LayoutKey>,
}

impl TerminalKeyboard {
    fn reserved_releases(&self) -> usize {
        self.pressed.len()
    }

    fn reservations_after_press(&self, key: &TerminalKeyIdentity) -> usize {
        self.pressed.len() + usize::from(!self.pressed.contains_key(key))
    }

    fn accepts(&self, key: &TerminalKeyIdentity, event: InputKeyEvent) -> bool {
        event == InputKeyEvent::Press || self.pressed.contains_key(key)
    }

    fn input_for(
        &self,
        key: &TerminalKeyIdentity,
        event: InputKeyEvent,
        modifiers: InputModifiers,
    ) -> Option<KeyInput> {
        self.pressed.get(key).cloned().map(|mut input| {
            match &mut input {
                KeyInput::Text {
                    modifiers: input_modifiers,
                    ..
                }
                | KeyInput::Named {
                    modifiers: input_modifiers,
                    ..
                } => *input_modifiers = modifiers,
                KeyInput::Paste(_) => {}
            }
            input.with_event(event)
        })
    }

    fn finish_accepted(
        &mut self,
        key: &TerminalKeyIdentity,
        pressed_input: Option<KeyInput>,
        event: InputKeyEvent,
    ) {
        match event {
            InputKeyEvent::Press => {
                self.pressed.insert(
                    key.clone(),
                    pressed_input.expect("accepted press retains its input"),
                );
            }
            InputKeyEvent::Release => {
                self.pressed.remove(key);
            }
            InputKeyEvent::Repeat => {}
        }
    }
}

impl TerminalPointer {
    fn press(&mut self, button: MouseButton, cell: (usize, usize)) {
        self.pressed[mouse_button_index(button)] = true;
        self.last_cell = Some(cell);
    }

    fn observe(&mut self, cell: Option<(usize, usize)>) -> Option<(usize, usize)> {
        if cell.is_some() {
            self.last_cell = cell;
        }
        cell
    }

    fn release_cell(
        &mut self,
        button: MouseButton,
        cell: Option<(usize, usize)>,
    ) -> Option<(usize, usize)> {
        if !self.pressed[mouse_button_index(button)] {
            return None;
        }
        if cell.is_some() {
            self.last_cell = cell;
        }
        cell.or(self.last_cell)
    }

    fn finish_release(&mut self, button: MouseButton) {
        self.pressed[mouse_button_index(button)] = false;
    }
}

enum PendingUiInput {
    Key(KeyInput),
    Mouse(MouseInput),
    Wheel(WheelBatch),
    ClipboardResponse(Vec<u8>),
    Resize(TerminalResize),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TerminalResize {
    columns: usize,
    rows: usize,
    pixel_width: u16,
    pixel_height: u16,
}

struct QueuedUiInput {
    presentation_id: u64,
    input: PendingUiInput,
    bytes: usize,
    accepted_after_refusal: Option<u64>,
}

#[derive(Default)]
struct InputRefusal {
    generation: u64,
    pending: bool,
}

impl InputRefusal {
    fn refuse(&mut self) {
        self.generation = self.generation.checked_add(1).unwrap_or(1);
        self.pending = true;
    }

    const fn acceptance_marker(&self) -> Option<u64> {
        if self.pending {
            Some(self.generation)
        } else {
            None
        }
    }

    fn delivered(&mut self, marker: Option<u64>) -> bool {
        if self.pending && marker == Some(self.generation) {
            self.pending = false;
            true
        } else {
            false
        }
    }

    const fn is_pending(&self) -> bool {
        self.pending
    }
}

impl PendingUiInput {
    fn byte_len(&self) -> usize {
        match self {
            Self::Key(KeyInput::Text { text, .. } | KeyInput::Paste(text)) => text.len(),
            Self::ClipboardResponse(bytes) => bytes.len(),
            Self::Key(KeyInput::Named { .. })
            | Self::Mouse(_)
            | Self::Wheel(_)
            | Self::Resize(_) => 0,
        }
    }

    const fn counts_toward_input_capacity(&self) -> bool {
        !matches!(self, Self::Resize(_))
    }

    fn is_balancing_release(&self) -> bool {
        matches!(
            self,
            Self::Key(
                KeyInput::Text {
                    event: InputKeyEvent::Release,
                    ..
                } | KeyInput::Named {
                    event: InputKeyEvent::Release,
                    ..
                }
            ) | Self::Mouse(MouseInput {
                action: MouseAction::Release(_),
                ..
            })
        )
    }
}

fn input_queue_has_capacity(
    input: &PendingUiInput,
    pending_items: usize,
    pending_bytes: usize,
    input_bytes: usize,
    reserved_key_releases: usize,
) -> bool {
    if !input.counts_toward_input_capacity() {
        return true;
    }
    let balancing_release = input.is_balancing_release();
    let item_capacity = if balancing_release {
        UI_INPUT_CAPACITY
    } else {
        UI_INPUT_CAPACITY.saturating_sub(MOUSE_RELEASE_RESERVE + reserved_key_releases)
    };
    pending_items < item_capacity
        && (balancing_release
            || pending_bytes.saturating_add(input_bytes) <= UI_INPUT_BYTE_CAPACITY)
}

impl RootView {
    #[must_use]
    pub fn new(
        status: PortStatus,
        workspace: Workspace,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.spawn(async move |view, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(33))
                    .await;
                if view
                    .update(cx, |view, cx| {
                        let scope_changed = view.sync_terminal_scope();
                        let handled = view.handle_events(cx);
                        let flushed = view.flush_pending_input();
                        let notice_expired = view.terminal_notice.expire(Instant::now());
                        if scope_changed
                            || handled
                            || flushed
                            || notice_expired
                            || view.poll_changed()
                        {
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();

        cx.observe_window_bounds(window, |view, window, cx| {
            view.resize_for_window(window);
            cx.notify();
        })
        .detach();

        cx.observe_window_activation(window, |view, window, _cx| {
            view.workspace
                .set_inventory_polling_enabled(window.is_window_active());
        })
        .detach();

        cx.on_next_frame(window, |view, window, cx| {
            view.workspace
                .set_inventory_polling_enabled(window.is_window_active());
            if let Err(error) = view.workspace.connect_enabled_hosts() {
                view.diagnostic = Some(error.to_string());
            }
            if let Err(error) = view.workspace.start_inventory_cadence() {
                view.diagnostic = Some(error.to_string());
            }
            cx.notify();
        });

        let appearance = workspace.snapshot().appearance().clone();
        let terminal_metrics = measure_terminal_metrics(window, &appearance);
        let mut view = Self {
            status,
            workspace,
            focus: cx.focus_handle(),
            create_focus: cx.focus_handle(),
            project_focus: cx.focus_handle(),
            settings_focus: cx.focus_handle(),
            ssh_prompt_focus: cx.focus_handle(),
            kill_focus: cx.focus_handle(),
            diagnostic: None,
            terminal_notice: TransientNotice::default(),
            paste_confirmation: false,
            observed_presentation_id: None,
            observed_revision: u64::MAX,
            observed_surface_generation: u64::MAX,
            observed_surface_identity: None,
            paint_cache: SurfacePaintCache::default(),
            terminal_metrics,
            pending_input: VecDeque::new(),
            pending_input_bytes: 0,
            input_refusal: InputRefusal::default(),
            wheel_remainder: 0.0,
            keyboard: TerminalKeyboard::default(),
            pointer: TerminalPointer::default(),
            sidebar_visible: true,
            collapsed_session_groups: HashSet::new(),
            new_session: None,
            project_dialog: None,
            settings_dialog: None,
            ssh_prompts: VecDeque::new(),
            pending_worktree_navigation: None,
            session_action_menu: None,
            restore_focus: false,
        };
        view.resize_for_window(window);
        view
    }

    #[must_use]
    pub fn headline(&self) -> String {
        headline_text(&self.status)
    }

    fn attach(
        &mut self,
        selection: &SessionSelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Err(error) = self.workspace.attach(selection) {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
            window.focus(&self.focus);
        }
        cx.notify();
    }

    fn select_session(
        &mut self,
        selection: &SessionSelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let snapshot = self.workspace.snapshot();
        if snapshot
            .active_selection()
            .cloned()
            .or_else(|| active_session_selection(snapshot.content()))
            .as_ref()
            == Some(selection)
        {
            if matches!(snapshot.content(), WorkspaceContent::Terminal { .. }) {
                window.focus(&self.focus);
            }
            return;
        }

        let switching = matches!(
            snapshot.content(),
            WorkspaceContent::Attaching { .. } | WorkspaceContent::Terminal { .. }
        );
        let result = if switching {
            self.workspace.switch_session(selection)
        } else {
            self.workspace.attach(selection)
        };
        if let Err(error) = result {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
            self.observed_presentation_id = None;
            self.clear_terminal_input();
            self.paint_cache.clear();
            self.resize_for_window(window);
            window.focus(&self.focus);
        }
        cx.notify();
    }

    fn select_worktree(
        &mut self,
        target: &WorktreeOpenTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let result = self.workspace.open_kwt_worktree(
            &target.host_id,
            &target.endpoint,
            &target.repository,
            &target.project_path,
            &target.registration_fingerprint,
            &target.worktree_path,
            target.generation.as_deref(),
            &target.session_name,
            target.tmux_socket_name.as_deref(),
        );
        if let Err(error) = result {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
            self.observed_presentation_id = None;
            self.clear_terminal_input();
            self.paint_cache.clear();
            self.resize_for_window(window);
            window.focus(&self.focus);
        }
        cx.notify();
    }

    fn refresh(&mut self, cx: &mut Context<Self>) {
        if let Err(error) = self.workspace.refresh() {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
        }
        cx.notify();
    }

    fn connect_host(&mut self, host_id: &str, cx: &mut Context<Self>) {
        if let Err(error) = self.workspace.connect_host(host_id) {
            self.diagnostic = Some(error.to_string());
        } else {
            self.diagnostic = None;
        }
        cx.notify();
    }

    fn cancel_host_connection(&mut self, host_id: &str, cx: &mut Context<Self>) {
        if self.workspace.cancel_host_connection(host_id) {
            let mut retained = VecDeque::with_capacity(self.ssh_prompts.len());
            while let Some(prompt) = self.ssh_prompts.pop_front() {
                if prompt.request.host_id() == host_id {
                    prompt.request.respond(None);
                } else {
                    retained.push_back(prompt);
                }
            }
            self.ssh_prompts = retained;
            self.diagnostic = None;
        }
        cx.notify();
    }

    fn open_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let hosts = self.workspace.configured_ssh_hosts();
        let appearance = self.workspace.configured_appearance();
        let font_families = terminal_font_families(cx, &appearance.font_family);
        self.settings_dialog = Some(SettingsDialog::new(&hosts, appearance, font_families));
        self.session_action_menu = None;
        window.focus(&self.settings_focus);
        cx.notify();
    }

    fn close_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings_dialog = None;
        window.focus(&self.focus);
        cx.notify();
    }

    fn select_ssh_host(
        &mut self,
        host: &ConfiguredSshHost,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(dialog) = &mut self.settings_dialog {
            dialog.selected_host_id = Some(host.id().to_owned());
            dialog.host_editor = Some(SshHostEditor::new(Some(host)));
            dialog.pending_remove = None;
            dialog.error = None;
        }
        window.focus(&self.settings_focus);
        cx.notify();
    }

    fn add_ssh_host(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(dialog) = &mut self.settings_dialog {
            dialog.selected_host_id = None;
            dialog.host_editor = Some(SshHostEditor::new(None));
            dialog.pending_remove = None;
            dialog.error = None;
        }
        window.focus(&self.settings_focus);
        cx.notify();
    }

    fn save_ssh_host(&mut self, cx: &mut Context<Self>) {
        let Some(editor) = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.host_editor.as_ref())
        else {
            return;
        };
        let original_id = editor.original_id.clone();
        let draft = editor.draft.clone();
        match self.workspace.save_ssh_host(original_id.as_deref(), &draft) {
            Ok(id) => {
                let saved = self
                    .workspace
                    .configured_ssh_hosts()
                    .into_iter()
                    .find(|host| host.id() == id);
                if let Some(dialog) = &mut self.settings_dialog {
                    dialog.selected_host_id = Some(id);
                    dialog.host_editor = saved
                        .as_ref()
                        .map(|host| SshHostEditor::new(Some(host)))
                        .or_else(|| {
                            Some(SshHostEditor {
                                original_id: dialog.selected_host_id.clone(),
                                draft,
                                field: SshField::Name,
                                error: None,
                            })
                        });
                    dialog.error = None;
                }
            }
            Err(error) => {
                if let Some(editor) = self
                    .settings_dialog
                    .as_mut()
                    .and_then(|dialog| dialog.host_editor.as_mut())
                {
                    editor.error = Some(error.to_string());
                }
            }
        }
        cx.notify();
    }

    fn persist_appearance(&mut self, draft: &AppearanceSettingsDraft, cx: &mut Context<Self>) {
        if !appearance_draft_is_persistable(draft) {
            if let Some(dialog) = &mut self.settings_dialog {
                dialog.appearance_editor.error = None;
            }
            cx.notify();
            return;
        }
        match self.workspace.save_appearance(draft) {
            Ok(()) => {
                if let Some(dialog) = &mut self.settings_dialog {
                    dialog.appearance_editor.error = None;
                }
            }
            Err(error) => {
                if let Some(dialog) = &mut self.settings_dialog {
                    dialog.appearance_editor.error = Some(error.to_string());
                }
            }
        }
        cx.notify();
    }

    fn edit_appearance_field(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        let key = event.keystroke.key.to_ascii_lowercase();
        let Some(editor) = self
            .settings_dialog
            .as_mut()
            .map(|dialog| &mut dialog.appearance_editor)
        else {
            return;
        };
        editor.error = None;
        if !event.is_held && matches!(key.as_str(), "up" | "down" | "left" | "right") {
            let reverse = matches!(key.as_str(), "up" | "left");
            match editor.field {
                AppearanceField::Theme => {
                    let current = TerminalTheme::ALL
                        .iter()
                        .position(|theme| *theme == editor.draft.theme)
                        .unwrap_or_default();
                    let offset = if reverse {
                        TerminalTheme::ALL.len() - 1
                    } else {
                        1
                    };
                    editor.draft.theme =
                        TerminalTheme::ALL[(current + offset) % TerminalTheme::ALL.len()];
                }
                AppearanceField::FontFamily if !editor.font_families.is_empty() => {
                    let current = editor
                        .font_families
                        .iter()
                        .position(|family| family == &editor.draft.font_family)
                        .unwrap_or_default();
                    let offset = if reverse {
                        editor.font_families.len() - 1
                    } else {
                        1
                    };
                    editor.draft.font_family = editor.font_families
                        [(current + offset) % editor.font_families.len()]
                    .clone();
                }
                AppearanceField::FontSize => {
                    let current = TERMINAL_FONT_SIZES
                        .iter()
                        .position(|size| size.to_string() == editor.draft.font_size)
                        .unwrap_or_default();
                    let offset = if reverse {
                        TERMINAL_FONT_SIZES.len() - 1
                    } else {
                        1
                    };
                    editor.draft.font_size = TERMINAL_FONT_SIZES
                        [(current + offset) % TERMINAL_FONT_SIZES.len()]
                    .to_string();
                }
                _ => {}
            }
            editor.open_picker = None;
            let draft = editor.draft.clone();
            self.persist_appearance(&draft, cx);
            cx.stop_propagation();
            return;
        }
        if editor.draft.theme != TerminalTheme::Custom {
            return;
        }
        let Some(value) = appearance_draft_field_mut(&mut editor.draft, editor.field) else {
            return;
        };
        if is_paste_shortcut(&event.keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                append_non_control_characters(value, &text, SETTINGS_FIELD_CHARACTER_LIMIT);
            }
        } else if key == "backspace" {
            value.pop();
        } else if !event.keystroke.modifiers.control
            && !event.keystroke.modifiers.alt
            && !event.keystroke.modifiers.platform
            && !event.keystroke.modifiers.function
            && let Some(text) = &event.keystroke.key_char
        {
            append_non_control_characters(value, text, SETTINGS_FIELD_CHARACTER_LIMIT);
        }
        let draft = editor.draft.clone();
        self.persist_appearance(&draft, cx);
        cx.stop_propagation();
    }

    fn remove_ssh_host(&mut self, cx: &mut Context<Self>) {
        let Some(host) = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.pending_remove.clone())
        else {
            return;
        };
        match self.workspace.remove_ssh_host(host.id()) {
            Ok(()) => {
                let hosts = self.workspace.configured_ssh_hosts();
                let replacement = hosts.first();
                if let Some(dialog) = &mut self.settings_dialog {
                    dialog.selected_host_id = replacement.map(|host| host.id().to_owned());
                    dialog.host_editor = replacement.map(|host| SshHostEditor::new(Some(host)));
                    dialog.pending_remove = None;
                    dialog.error = None;
                }
            }
            Err(error) => {
                if let Some(dialog) = &mut self.settings_dialog {
                    dialog.error = Some(error.to_string());
                }
            }
        }
        cx.notify();
    }

    fn cancel_ssh_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(prompt) = self.ssh_prompts.pop_front() {
            let host_id = prompt.request.host_id().to_owned();
            prompt.request.respond(None);
            let _cancelled = self.workspace.cancel_host_connection(&host_id);
        }
        self.focus_after_ssh_prompt(window);
        cx.notify();
    }

    fn submit_ssh_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(prompt) = self.ssh_prompts.pop_front() else {
            return;
        };
        let response = if prompt.request.sensitive() {
            prompt.value
        } else {
            "yes".to_owned()
        };
        prompt.request.respond(Some(response));
        self.focus_after_ssh_prompt(window);
        cx.notify();
    }

    fn focus_after_ssh_prompt(&self, window: &mut Window) {
        if self.ssh_prompts.is_empty() {
            window.focus(&self.focus);
        } else {
            window.focus(&self.ssh_prompt_focus);
        }
    }

    fn on_settings_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = event.keystroke.key.to_ascii_lowercase();
        let pane = self
            .settings_dialog
            .as_ref()
            .map_or(SettingsPane::Appearance, |dialog| dialog.pane);
        if key == "escape" && !event.is_held {
            if self
                .settings_dialog
                .as_ref()
                .is_some_and(|dialog| dialog.pending_remove.is_some())
            {
                if let Some(dialog) = &mut self.settings_dialog {
                    dialog.pending_remove = None;
                    dialog.error = None;
                }
                cx.notify();
            } else {
                self.close_settings(window, cx);
            }
            cx.stop_propagation();
            return;
        }
        if key == "enter" && !event.is_held {
            if pane == SettingsPane::Appearance {
                cx.stop_propagation();
                return;
            } else if self
                .settings_dialog
                .as_ref()
                .is_some_and(|dialog| dialog.pending_remove.is_some())
            {
                self.remove_ssh_host(cx);
            } else {
                self.save_ssh_host(cx);
            }
            cx.stop_propagation();
            return;
        }
        if key == "tab" {
            if let Some(dialog) = &mut self.settings_dialog {
                if pane == SettingsPane::Appearance {
                    let custom = dialog.appearance_editor.draft.theme == TerminalTheme::Custom;
                    dialog.appearance_editor.field = adjacent_appearance_field(
                        dialog.appearance_editor.field,
                        event.keystroke.modifiers.shift,
                        custom,
                    );
                    dialog.appearance_editor.open_picker = None;
                    dialog.appearance_editor.error = None;
                } else if let Some(editor) = &mut dialog.host_editor {
                    editor.field = editor.field.adjacent(event.keystroke.modifiers.shift);
                    editor.error = None;
                }
                cx.notify();
            }
            cx.stop_propagation();
            return;
        }
        if pane == SettingsPane::Appearance {
            self.edit_appearance_field(event, cx);
            return;
        }
        let Some(editor) = self
            .settings_dialog
            .as_mut()
            .and_then(|dialog| dialog.host_editor.as_mut())
        else {
            return;
        };
        let value = ssh_draft_field_mut(&mut editor.draft, editor.field);
        editor.error = None;
        if is_paste_shortcut(&event.keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                append_non_control_characters(value, &text, SETTINGS_FIELD_CHARACTER_LIMIT);
            }
        } else if key == "backspace" {
            value.pop();
        } else if !event.keystroke.modifiers.control
            && !event.keystroke.modifiers.alt
            && !event.keystroke.modifiers.platform
            && !event.keystroke.modifiers.function
            && let Some(text) = &event.keystroke.key_char
        {
            append_non_control_characters(value, text, SETTINGS_FIELD_CHARACTER_LIMIT);
        }
        cx.notify();
        cx.stop_propagation();
    }

    fn on_ssh_prompt_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = event.keystroke.key.to_ascii_lowercase();
        if key == "escape" && !event.is_held {
            self.cancel_ssh_prompt(window, cx);
            cx.stop_propagation();
            return;
        }
        if key == "enter" && !event.is_held {
            self.submit_ssh_prompt(window, cx);
            cx.stop_propagation();
            return;
        }
        let Some(prompt) = self.ssh_prompts.front_mut() else {
            return;
        };
        if !prompt.request.sensitive() {
            cx.stop_propagation();
            return;
        }
        if is_paste_shortcut(&event.keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                append_non_control_characters(&mut prompt.value, &text, SSH_PROMPT_CHARACTER_LIMIT);
            }
        } else if key == "backspace" {
            prompt.value.pop();
        } else if !event.keystroke.modifiers.control
            && !event.keystroke.modifiers.alt
            && !event.keystroke.modifiers.platform
            && !event.keystroke.modifiers.function
            && let Some(text) = &event.keystroke.key_char
        {
            append_non_control_characters(&mut prompt.value, text, SSH_PROMPT_CHARACTER_LIMIT);
        }
        cx.notify();
        cx.stop_propagation();
    }

    fn open_new_session(
        &mut self,
        host_id: &str,
        endpoint: &str,
        kind: NewSessionKind,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.pending_worktree_navigation = None;
        self.new_session = Some(NewSessionDraft {
            host_id: host_id.to_owned(),
            endpoint: endpoint.to_owned(),
            kind,
            name: String::new(),
        });
        self.diagnostic = None;
        window.focus(&self.create_focus);
        cx.notify();
    }

    fn cancel_new_session(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.new_session = None;
        window.focus(&self.focus);
        cx.notify();
    }

    fn open_add_project(
        &mut self,
        host_id: &str,
        endpoint: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.pending_worktree_navigation = None;
        self.project_dialog = Some(ProjectDialog::Add {
            host_id: host_id.to_owned(),
            endpoint: endpoint.to_owned(),
            path: String::new(),
            submitting: false,
            error: None,
        });
        self.diagnostic = None;
        window.focus(&self.project_focus);
        cx.notify();
    }

    fn browse_for_project(&mut self, cx: &mut Context<Self>) {
        if !matches!(
            self.project_dialog.as_ref(),
            Some(ProjectDialog::Add {
                submitting: false,
                ..
            })
        ) {
            return;
        }
        let selection = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Choose project folder".into()),
        });
        cx.spawn(async move |view, cx| {
            let result = selection.await;
            let _ignored = view.update(cx, |view, cx| {
                let Some(ProjectDialog::Add {
                    path,
                    submitting: false,
                    error,
                    ..
                }) = &mut view.project_dialog
                else {
                    return;
                };
                match result {
                    Ok(Ok(Some(paths))) => {
                        if let Some(selected) = paths.into_iter().next() {
                            *path = selected.to_string_lossy().into_owned();
                            *error = None;
                        }
                    }
                    Ok(Ok(None)) | Err(_) => {}
                    Ok(Err(prompt_error)) => {
                        *error = Some(format!("Could not open the folder browser: {prompt_error}"));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn open_remove_project(
        &mut self,
        host_id: &str,
        endpoint: &str,
        project: &workspace::ProjectItem,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.pending_worktree_navigation = None;
        self.project_dialog = Some(ProjectDialog::Remove {
            host_id: host_id.to_owned(),
            endpoint: endpoint.to_owned(),
            name: project.name().to_owned(),
            repository: project.repository().to_owned(),
            path: project.path().to_owned(),
            registration_fingerprint: project.registration_fingerprint().to_owned(),
            submitting: false,
            error: None,
        });
        self.diagnostic = None;
        window.focus(&self.project_focus);
        cx.notify();
    }

    fn open_new_worktree(
        &mut self,
        host_id: &str,
        endpoint: &str,
        project: &workspace::ProjectItem,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.pending_worktree_navigation = None;
        let result = self.workspace.load_kwt_branches(
            host_id,
            endpoint,
            project.repository(),
            project.path(),
            project.registration_fingerprint(),
        );
        let (operation_id, error) = match result {
            Ok(operation_id) => (Some(operation_id), None),
            Err(error) => (None, Some(error.to_string())),
        };
        self.project_dialog = Some(ProjectDialog::NewWorktree {
            host_id: host_id.to_owned(),
            endpoint: endpoint.to_owned(),
            project_name: project.name().to_owned(),
            repository: project.repository().to_owned(),
            project_path: project.path().to_owned(),
            registration_fingerprint: project.registration_fingerprint().to_owned(),
            branch: String::new(),
            mode: NewWorktreeMode::Branch,
            selected_source: None,
            selected_pull_request: None,
            branches: Vec::new(),
            pull_requests: Vec::new(),
            operation_id,
            loading: operation_id.is_some(),
            loaded: false,
            submitting: false,
            error,
        });
        self.diagnostic = None;
        window.focus(&self.project_focus);
        cx.notify();
    }

    fn open_remove_worktree(
        &mut self,
        mut target: WorktreeRemoveTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.pending_worktree_navigation = None;
        let result = if let Some(generation) = target.open.generation.as_deref() {
            self.workspace.request_kwt_worktree_removal(
                &target.open.host_id,
                &target.open.endpoint,
                &target.open.repository,
                &target.open.project_path,
                &target.open.registration_fingerprint,
                &target.open.worktree_path,
                generation,
                &target.open.session_name,
                target.open.tmux_socket_name.as_deref(),
            )
        } else {
            target.authority = None;
            self.project_dialog = Some(ProjectDialog::RemoveWorktree {
                target,
                submitting: false,
                error: Some("Refresh KWT inventory before removing this worktree.".to_owned()),
            });
            self.diagnostic = None;
            window.focus(&self.project_focus);
            cx.notify();
            return;
        };
        target.authority = None;
        let (operation_id, error) = match result {
            Ok(operation_id) => (Some(operation_id), None),
            Err(error) => (None, Some(error.to_string())),
        };
        target.operation_id = operation_id;
        self.project_dialog = Some(ProjectDialog::RemoveWorktree {
            target,
            submitting: false,
            error,
        });
        self.diagnostic = None;
        window.focus(&self.project_focus);
        cx.notify();
    }

    fn switch_new_worktree_mode(&mut self, mode: NewWorktreeMode, cx: &mut Context<Self>) {
        let Some(ProjectDialog::NewWorktree {
            host_id,
            endpoint,
            repository,
            project_path,
            registration_fingerprint,
            mode: current_mode,
            branch,
            selected_source,
            selected_pull_request,
            operation_id,
            loading,
            loaded,
            submitting: false,
            error,
            ..
        }) = &mut self.project_dialog
        else {
            return;
        };
        if *current_mode == mode {
            return;
        }
        if *loading && let Some(active_operation) = operation_id.take() {
            let _cancelled = self.workspace.cancel_kwt_worktree_listing(active_operation);
            *loading = false;
        }
        *current_mode = mode;
        branch.clear();
        *selected_source = None;
        *selected_pull_request = None;
        *error = None;
        let result = match mode {
            NewWorktreeMode::Branch => self.workspace.load_kwt_branches(
                host_id,
                endpoint,
                repository,
                project_path,
                registration_fingerprint,
            ),
            NewWorktreeMode::PullRequest => self.workspace.load_kwt_pull_requests(
                host_id,
                endpoint,
                repository,
                project_path,
                registration_fingerprint,
            ),
        };
        match result {
            Ok(id) => {
                *operation_id = Some(id);
                *loading = true;
                *loaded = false;
            }
            Err(failure) => {
                *operation_id = None;
                *loading = false;
                *loaded = false;
                *error = Some(failure.to_string());
            }
        }
        cx.notify();
    }

    fn cancel_project_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .project_dialog
            .as_ref()
            .is_some_and(|dialog| match dialog {
                ProjectDialog::Add { submitting, .. }
                | ProjectDialog::Remove { submitting, .. }
                | ProjectDialog::NewWorktree { submitting, .. }
                | ProjectDialog::RemoveWorktree { submitting, .. } => *submitting,
            })
        {
            return;
        }
        if matches!(
            self.project_dialog,
            Some(ProjectDialog::RemoveWorktree { .. })
        ) {
            self.workspace.cancel_kwt_worktree_removal();
        }
        if let Some(ProjectDialog::NewWorktree {
            operation_id: Some(operation_id),
            loading: true,
            ..
        }) = &self.project_dialog
        {
            let _cancelled = self.workspace.cancel_kwt_worktree_listing(*operation_id);
        }
        self.project_dialog = None;
        window.focus(&self.focus);
        cx.notify();
    }

    fn set_project_dialog_error(&mut self, message: impl Into<String>) {
        let Some(dialog) = &mut self.project_dialog else {
            return;
        };
        let error = match dialog {
            ProjectDialog::Add { error, .. }
            | ProjectDialog::Remove { error, .. }
            | ProjectDialog::NewWorktree { error, .. }
            | ProjectDialog::RemoveWorktree { error, .. } => error,
        };
        *error = Some(message.into());
    }

    #[allow(
        clippy::too_many_lines,
        reason = "dialog submission keeps one exhaustive mapping from UI state to workspace capabilities"
    )]
    fn submit_project_dialog(&mut self, cx: &mut Context<Self>) {
        if self
            .project_dialog
            .as_ref()
            .is_some_and(has_ambiguous_worktree_source)
        {
            self.set_project_dialog_error("Choose which existing branch to use.");
            cx.notify();
            return;
        }
        if let Some(open) = self.project_dialog.as_ref().and_then(|dialog| {
            let ProjectDialog::RemoveWorktree {
                target,
                submitting: false,
                error: Some(_),
            } = dialog
            else {
                return None;
            };
            target.authority.is_none().then(|| target.open.clone())
        }) {
            let Some(generation) = open.generation.as_deref() else {
                self.set_project_dialog_error(
                    "Refresh KWT inventory before removing this worktree.",
                );
                cx.notify();
                return;
            };
            match self.workspace.request_kwt_worktree_removal(
                &open.host_id,
                &open.endpoint,
                &open.repository,
                &open.project_path,
                &open.registration_fingerprint,
                &open.worktree_path,
                generation,
                &open.session_name,
                open.tmux_socket_name.as_deref(),
            ) {
                Ok(operation_id) => {
                    if let Some(ProjectDialog::RemoveWorktree { target, error, .. }) =
                        &mut self.project_dialog
                    {
                        target.operation_id = Some(operation_id);
                        target.session_was_running = false;
                        *error = None;
                    }
                }
                Err(error) => self.set_project_dialog_error(error.to_string()),
            }
            cx.notify();
            return;
        }
        let invalid_pull_request = self.project_dialog.as_ref().is_some_and(|dialog| {
            let ProjectDialog::NewWorktree {
                branch,
                mode: NewWorktreeMode::PullRequest,
                selected_pull_request,
                pull_requests,
                loaded: true,
                loading: false,
                submitting: false,
                ..
            } = dialog
            else {
                return false;
            };
            pull_request_import_selector(pull_requests, branch, selected_pull_request.as_deref())
                .is_none()
        });
        if invalid_pull_request {
            self.set_project_dialog_error("Choose a pull request, or enter its number or URL.");
            cx.notify();
            return;
        }
        let result = match self.project_dialog.as_ref() {
            Some(ProjectDialog::Add {
                host_id,
                endpoint,
                path,
                submitting: false,
                ..
            }) => self
                .workspace
                .add_kwt_project(host_id, endpoint, path)
                .map(|()| None),
            Some(ProjectDialog::Remove {
                host_id,
                endpoint,
                repository,
                path,
                registration_fingerprint,
                submitting: false,
                ..
            }) => self
                .workspace
                .remove_kwt_project(
                    host_id,
                    endpoint,
                    repository,
                    path,
                    registration_fingerprint,
                )
                .map(|()| None),
            Some(ProjectDialog::NewWorktree {
                host_id,
                endpoint,
                repository,
                project_path,
                registration_fingerprint,
                branch,
                mode: NewWorktreeMode::Branch,
                selected_source,
                branches,
                loaded: true,
                loading: false,
                submitting: false,
                ..
            }) => {
                let normalized = branch.trim();
                let exact = branches
                    .iter()
                    .filter(|candidate| {
                        candidate.name() == normalized
                            && selected_source
                                .as_deref()
                                .is_none_or(|source| source == candidate.source())
                    })
                    .collect::<Vec<_>>();
                self.workspace
                    .create_kwt_worktree(
                        host_id,
                        endpoint,
                        repository,
                        project_path,
                        registration_fingerprint,
                        normalized,
                        exact.first().map(|candidate| candidate.source()),
                        exact.is_empty(),
                    )
                    .map(Some)
            }
            Some(ProjectDialog::NewWorktree {
                host_id,
                endpoint,
                repository,
                project_path,
                registration_fingerprint,
                branch,
                mode: NewWorktreeMode::PullRequest,
                selected_pull_request,
                pull_requests,
                loaded: true,
                loading: false,
                submitting: false,
                ..
            }) => {
                let selector = pull_request_import_selector(
                    pull_requests,
                    branch,
                    selected_pull_request.as_deref(),
                )
                .expect("pull request selector was validated before submission");
                self.workspace
                    .import_kwt_pull_request(
                        host_id,
                        endpoint,
                        repository,
                        project_path,
                        registration_fingerprint,
                        &selector,
                    )
                    .map(Some)
            }
            Some(ProjectDialog::RemoveWorktree {
                target,
                submitting: false,
                ..
            }) => {
                let Some(generation) = target.open.generation.as_deref() else {
                    self.set_project_dialog_error(
                        "Refresh KWT inventory before removing this worktree.",
                    );
                    cx.notify();
                    return;
                };
                let Some(authority) = target.authority else {
                    self.set_project_dialog_error(
                        "Wait for Ghosthub to verify the worktree session.",
                    );
                    cx.notify();
                    return;
                };
                self.workspace
                    .remove_kwt_worktree(
                        &target.open.host_id,
                        &target.open.endpoint,
                        &target.open.repository,
                        &target.open.project_path,
                        &target.open.registration_fingerprint,
                        &target.open.worktree_path,
                        generation,
                        &target.open.session_name,
                        authority,
                    )
                    .map(|()| None)
            }
            _ => return,
        };
        match result {
            Ok(navigation_generation) => {
                if let Some(navigation_generation) = navigation_generation {
                    self.pending_worktree_navigation = Some(navigation_generation);
                    if let Some(ProjectDialog::NewWorktree { operation_id, .. }) =
                        &mut self.project_dialog
                    {
                        *operation_id = Some(navigation_generation);
                    }
                }
                if let Some(dialog) = &mut self.project_dialog {
                    match dialog {
                        ProjectDialog::Add {
                            submitting, error, ..
                        }
                        | ProjectDialog::Remove {
                            submitting, error, ..
                        }
                        | ProjectDialog::NewWorktree {
                            submitting, error, ..
                        }
                        | ProjectDialog::RemoveWorktree {
                            submitting, error, ..
                        } => {
                            *submitting = true;
                            *error = None;
                        }
                    }
                }
            }
            Err(error) => {
                self.set_project_dialog_error(error.to_string());
            }
        }
        cx.notify();
    }

    fn on_project_dialog_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = event.keystroke.key.to_ascii_lowercase();
        if key == "escape" && !event.is_held {
            self.cancel_project_dialog(window, cx);
            cx.stop_propagation();
            return;
        }
        if key == "enter" && !event.is_held {
            self.submit_project_dialog(cx);
            cx.stop_propagation();
            return;
        }
        let Some(dialog) = &mut self.project_dialog else {
            return;
        };
        let (value, error) = match dialog {
            ProjectDialog::Add {
                path,
                submitting: false,
                error,
                ..
            } => (path, error),
            ProjectDialog::NewWorktree {
                branch,
                selected_source,
                selected_pull_request,
                submitting: false,
                error,
                ..
            } => {
                *selected_source = None;
                *selected_pull_request = None;
                (branch, error)
            }
            ProjectDialog::Remove { .. }
            | ProjectDialog::Add { .. }
            | ProjectDialog::NewWorktree { .. }
            | ProjectDialog::RemoveWorktree { .. } => {
                cx.stop_propagation();
                return;
            }
        };
        *error = None;
        if is_paste_shortcut(&event.keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                value.extend(text.chars().filter(|character| !character.is_control()));
                cx.notify();
            }
        } else if key == "backspace" {
            value.pop();
            cx.notify();
        } else if !event.keystroke.modifiers.control
            && !event.keystroke.modifiers.alt
            && !event.keystroke.modifiers.platform
            && !event.keystroke.modifiers.function
            && let Some(text) = &event.keystroke.key_char
        {
            value.extend(text.chars().filter(|character| !character.is_control()));
            cx.notify();
        }
        cx.stop_propagation();
    }

    fn submit_new_session(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(draft) = self.new_session.clone() else {
            return;
        };
        if draft.name.trim().is_empty() {
            return;
        }
        let snapshot = self.workspace.snapshot();
        if let Some(error) = new_session_validation(&snapshot, &draft) {
            self.diagnostic = Some(error);
            cx.notify();
            return;
        }
        let result = match draft.kind {
            NewSessionKind::Tmux => {
                self.workspace
                    .create_session(&draft.host_id, &draft.endpoint, &draft.name)
            }
            NewSessionKind::Herdr => {
                self.workspace
                    .create_herdr_session(&draft.host_id, &draft.endpoint, &draft.name)
            }
            NewSessionKind::Zellij => {
                self.workspace
                    .create_zellij_session(&draft.host_id, &draft.endpoint, &draft.name)
            }
        };
        match result {
            Ok(()) => {
                self.new_session = None;
                self.diagnostic = None;
                self.observed_presentation_id = None;
                self.clear_terminal_input();
                self.paint_cache.clear();
                window.focus(&self.focus);
            }
            Err(error) => self.diagnostic = Some(error.to_string()),
        }
        cx.notify();
    }

    fn on_new_session_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.diagnostic = None;
        if is_paste_shortcut(&event.keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
                && let Some(draft) = &mut self.new_session
            {
                draft
                    .name
                    .extend(text.chars().filter(|character| !character.is_control()));
                cx.notify();
            }
            cx.stop_propagation();
            return;
        }
        let key = event.keystroke.key.to_ascii_lowercase();
        match key.as_str() {
            "escape" if !event.is_held => self.cancel_new_session(window, cx),
            "enter" if !event.is_held => self.submit_new_session(window, cx),
            "backspace" => {
                if let Some(draft) = &mut self.new_session {
                    draft.name.pop();
                }
                cx.notify();
            }
            _ if !event.keystroke.modifiers.control
                && !event.keystroke.modifiers.alt
                && !event.keystroke.modifiers.platform
                && !event.keystroke.modifiers.function =>
            {
                if let Some(text) = &event.keystroke.key_char
                    && let Some(draft) = &mut self.new_session
                {
                    draft
                        .name
                        .extend(text.chars().filter(|character| !character.is_control()));
                    cx.notify();
                }
            }
            _ => {}
        }
        cx.stop_propagation();
    }

    fn toggle_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sidebar_visible = !self.sidebar_visible;
        self.resize_for_window(window);
        if matches!(
            self.workspace.snapshot().content(),
            WorkspaceContent::Terminal { .. }
        ) {
            window.focus(&self.focus);
        }
        cx.notify();
    }

    fn navigation_width(&self, snapshot: &workspace::WorkspaceSnapshot) -> f32 {
        application_navigation_width(self.sidebar_visible, !snapshot.hosts().is_empty())
    }

    fn request_session_kill(&mut self, selection: &SessionSelection, cx: &mut Context<Self>) {
        self.pending_worktree_navigation = None;
        match self.workspace.request_session_kill(selection) {
            Ok(()) => self.diagnostic = None,
            Err(error) => self.diagnostic = Some(error.to_string()),
        }
        cx.notify();
    }

    fn detach_session(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.workspace.detach();
        self.diagnostic = None;
        self.observed_presentation_id = None;
        self.clear_terminal_input();
        self.paint_cache.clear();
        self.resize_for_window(window);
        window.focus(&self.focus);
        cx.notify();
    }

    fn cancel_session_kill(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.workspace.cancel_session_kill();
        window.focus(&self.focus);
        cx.notify();
    }

    fn confirm_session_kill(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.workspace.confirm_session_kill() {
            Ok(()) => self.diagnostic = None,
            Err(error) => self.diagnostic = Some(error.to_string()),
        }
        window.focus(&self.focus);
        cx.notify();
    }

    fn restart_herdr_session(
        &mut self,
        selection: &SessionSelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match self.workspace.restart_herdr_session(selection) {
            Ok(()) => {
                self.diagnostic = None;
                self.observed_presentation_id = None;
                self.clear_terminal_input();
                self.paint_cache.clear();
                self.resize_for_window(window);
            }
            Err(error) => self.diagnostic = Some(error.to_string()),
        }
        window.focus(&self.focus);
        cx.notify();
    }

    fn request_herdr_lifecycle(
        &mut self,
        selection: &SessionSelection,
        action: workspace::HerdrLifecycleAction,
        cx: &mut Context<Self>,
    ) {
        self.pending_worktree_navigation = None;
        match self.workspace.request_herdr_lifecycle(selection, action) {
            Ok(()) => self.diagnostic = None,
            Err(error) => self.diagnostic = Some(error.to_string()),
        }
        cx.notify();
    }

    fn cancel_herdr_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.workspace.cancel_herdr_lifecycle();
        window.focus(&self.focus);
        cx.notify();
    }

    fn confirm_herdr_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.workspace.confirm_herdr_lifecycle() {
            Ok(()) => self.diagnostic = None,
            Err(error) => self.diagnostic = Some(error.to_string()),
        }
        window.focus(&self.focus);
        cx.notify();
    }

    fn sync_terminal_scope(&mut self) -> bool {
        let snapshot = self.workspace.snapshot();
        let presentation_id = terminal_presentation_id(snapshot.content());
        if !transitioned_presentation(&mut self.observed_presentation_id, presentation_id) {
            return false;
        }
        self.clear_terminal_input();
        true
    }

    fn presentation_accepts_input(&mut self, presentation_id: u64) -> bool {
        let _scope_changed = self.sync_terminal_scope();
        terminal_presentation_id(self.workspace.snapshot().content()) == Some(presentation_id)
    }

    fn clear_terminal_input(&mut self) {
        clear_terminal_input_state(
            &mut self.paste_confirmation,
            &mut self.pending_input,
            &mut self.pending_input_bytes,
            &mut self.input_refusal,
        );
        self.wheel_remainder = 0.0;
        self.keyboard = TerminalKeyboard::default();
        self.pointer = TerminalPointer::default();
        if matches!(
            self.diagnostic.as_deref(),
            Some(INPUT_BUFFERED_DIAGNOSTIC | INPUT_BUFFER_FULL_DIAGNOSTIC)
        ) {
            self.diagnostic = None;
        }
    }

    #[allow(
        clippy::too_many_lines,
        reason = "workspace events stay in one exhaustive UI-thread dispatch"
    )]
    fn handle_events(&mut self, cx: &mut Context<Self>) -> bool {
        let (events, may_have_more) = self.workspace.drain_events();
        if may_have_more {
            cx.notify();
        }
        let mut handled = may_have_more;
        for event in events {
            handled = true;
            match event {
                WorkspaceEvent::ClipboardWrite { text, .. } => {
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                }
                WorkspaceEvent::ClipboardRead(request) => {
                    let contents = cx
                        .read_from_clipboard()
                        .and_then(|clipboard| clipboard.text())
                        .unwrap_or_default();
                    if let Some(presentation_id) =
                        terminal_presentation_id(self.workspace.snapshot().content())
                    {
                        self.enqueue_input(
                            presentation_id,
                            PendingUiInput::ClipboardResponse(request.respond(&contents)),
                        );
                    }
                }
                WorkspaceEvent::ConfirmPaste => self.paste_confirmation = true,
                WorkspaceEvent::SshPrompt(request) => {
                    if !self
                        .workspace
                        .ssh_prompt_is_current(request.host_id(), request.generation())
                    {
                        request.respond(None);
                        continue;
                    }
                    self.ssh_prompts.push_back(SshPromptDialog {
                        request,
                        value: String::new(),
                    });
                    self.restore_focus = false;
                }
                WorkspaceEvent::SshPromptDismissed {
                    host_id,
                    generation,
                } => {
                    if let Some(index) = self.ssh_prompts.iter().position(|prompt| {
                        prompt.request.host_id() == host_id
                            && prompt.request.generation() == generation
                    }) && let Some(prompt) = self.ssh_prompts.remove(index)
                    {
                        prompt.request.respond(None);
                        self.restore_focus = index == 0 && self.ssh_prompts.is_empty();
                    }
                }
                WorkspaceEvent::KwtProjectMutationFinished { action, .. } => {
                    if self
                        .project_dialog
                        .as_ref()
                        .is_some_and(|dialog| dialog.action() == Some(action))
                    {
                        self.project_dialog = None;
                        self.restore_focus = true;
                    }
                    self.diagnostic = None;
                }
                WorkspaceEvent::KwtProjectMutationFailed { action, message } => {
                    if let Some(dialog) = &mut self.project_dialog
                        && dialog.action() == Some(action)
                    {
                        match dialog {
                            ProjectDialog::Add {
                                submitting, error, ..
                            }
                            | ProjectDialog::Remove {
                                submitting, error, ..
                            } => {
                                *submitting = false;
                                *error = Some(message);
                            }
                            ProjectDialog::NewWorktree { .. }
                            | ProjectDialog::RemoveWorktree { .. } => {}
                        }
                    } else {
                        self.diagnostic = Some(message);
                    }
                }
                WorkspaceEvent::KwtBranchesLoaded {
                    operation_id,
                    project_path,
                    branches,
                } => {
                    if let Some(ProjectDialog::NewWorktree {
                        project_path: dialog_path,
                        mode: NewWorktreeMode::Branch,
                        operation_id: dialog_operation,
                        branches: dialog_branches,
                        loading,
                        loaded,
                        error,
                        ..
                    }) = &mut self.project_dialog
                        && *dialog_path == project_path
                        && *dialog_operation == Some(operation_id)
                    {
                        *dialog_branches = branches;
                        *loading = false;
                        *loaded = true;
                        *error = None;
                    }
                }
                WorkspaceEvent::KwtPullRequestsLoaded {
                    operation_id,
                    project_path,
                    pull_requests,
                } => {
                    if let Some(ProjectDialog::NewWorktree {
                        project_path: dialog_path,
                        mode: NewWorktreeMode::PullRequest,
                        operation_id: dialog_operation,
                        pull_requests: dialog_pull_requests,
                        loading,
                        loaded,
                        error,
                        ..
                    }) = &mut self.project_dialog
                        && *dialog_path == project_path
                        && *dialog_operation == Some(operation_id)
                    {
                        *dialog_pull_requests = pull_requests;
                        *loading = false;
                        *loaded = true;
                        *error = None;
                    }
                }
                WorkspaceEvent::KwtWorktreeRemovalReady {
                    project_path,
                    worktree_path,
                    authority,
                    session_was_running,
                } => {
                    if let Some(ProjectDialog::RemoveWorktree {
                        target,
                        submitting: false,
                        error,
                    }) = &mut self.project_dialog
                        && target.open.project_path == project_path
                        && target.open.worktree_path == worktree_path
                        && target.operation_id == Some(authority)
                    {
                        target.authority = Some(authority);
                        target.session_was_running = session_was_running;
                        *error = None;
                    }
                }
                WorkspaceEvent::KwtWorktreeCreated {
                    target,
                    navigation_generation,
                } => {
                    let open = WorktreeOpenTarget {
                        host_id: target.host_id().to_owned(),
                        endpoint: target.endpoint().to_owned(),
                        repository: target.repository().to_owned(),
                        project_path: target.project_path().to_owned(),
                        registration_fingerprint: target.registration_fingerprint().to_owned(),
                        worktree_path: target.worktree_path().to_owned(),
                        generation: target.generation().map(str::to_owned),
                        session_name: target.session_name().to_owned(),
                        tmux_socket_name: target.tmux_socket_name().map(str::to_owned),
                    };
                    let dialog_project_path = self.project_dialog.as_ref().map(|dialog| {
                        if let ProjectDialog::NewWorktree { project_path, .. } = dialog {
                            project_path.as_str()
                        } else {
                            ""
                        }
                    });
                    let owns_navigation = owns_created_worktree_navigation(
                        self.pending_worktree_navigation,
                        navigation_generation,
                        self.workspace
                            .navigation_intent_is_current(navigation_generation),
                        dialog_project_path,
                        target.project_path(),
                    );
                    if self.pending_worktree_navigation == Some(navigation_generation) {
                        self.pending_worktree_navigation = None;
                    }
                    if !owns_navigation {
                        self.diagnostic =
                            Some(format!("Created worktree {}.", target.worktree_path()));
                        continue;
                    }
                    self.project_dialog = None;
                    self.restore_focus = true;
                    if let Err(error) = self.workspace.open_kwt_worktree(
                        &open.host_id,
                        &open.endpoint,
                        &open.repository,
                        &open.project_path,
                        &open.registration_fingerprint,
                        &open.worktree_path,
                        open.generation.as_deref(),
                        &open.session_name,
                        open.tmux_socket_name.as_deref(),
                    ) {
                        self.diagnostic = Some(error.to_string());
                    } else {
                        self.diagnostic = None;
                        self.observed_presentation_id = None;
                        self.clear_terminal_input();
                        self.paint_cache.clear();
                    }
                }
                WorkspaceEvent::KwtWorktreeRemoved {
                    operation_id,
                    project_path,
                    worktree_path,
                } => {
                    if self.project_dialog.as_ref().is_some_and(|dialog| {
                        matches!(
                            dialog,
                            ProjectDialog::RemoveWorktree { target, .. }
                                if target.open.project_path == project_path
                                    && target.open.worktree_path == worktree_path
                                    && target.operation_id == Some(operation_id)
                        )
                    }) {
                        self.project_dialog = None;
                        self.restore_focus = true;
                    }
                    self.diagnostic = None;
                }
                WorkspaceEvent::KwtWorktreeCreationPending {
                    project_path,
                    message,
                    navigation_generation,
                } => {
                    if self.pending_worktree_navigation == Some(navigation_generation)
                        && self.project_dialog.as_ref().is_some_and(|dialog| {
                            matches!(
                                dialog,
                                ProjectDialog::NewWorktree {
                                    project_path: dialog_path,
                                    ..
                                } if dialog_path == &project_path
                            )
                        })
                    {
                        self.project_dialog = None;
                        self.restore_focus = true;
                    }
                    self.diagnostic = Some(message);
                }
                WorkspaceEvent::KwtWorktreeCreationExpired {
                    project_path,
                    message,
                    navigation_generation,
                } => {
                    if self.pending_worktree_navigation == Some(navigation_generation) {
                        self.pending_worktree_navigation = None;
                    }
                    if self.project_dialog.as_ref().is_some_and(|dialog| {
                        matches!(
                            dialog,
                            ProjectDialog::NewWorktree {
                                project_path: dialog_path,
                                operation_id: Some(operation_id),
                                ..
                            } if dialog_path == &project_path
                                && *operation_id == navigation_generation
                        )
                    }) {
                        self.project_dialog = None;
                        self.restore_focus = true;
                    }
                    self.diagnostic = Some(message);
                }
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id,
                    project_path,
                    worktree_path,
                    message,
                } => {
                    if !kwt_operation_failure_owns_dialog(
                        self.project_dialog.as_ref(),
                        operation_id,
                        &project_path,
                        worktree_path.as_deref(),
                    ) {
                        continue;
                    }
                    if self.project_dialog.as_mut().is_some_and(|dialog| {
                        apply_worktree_removal_failure(
                            dialog,
                            operation_id,
                            &project_path,
                            worktree_path.as_deref(),
                            message.clone(),
                        )
                    }) {
                        continue;
                    }
                    if let Some(dialog) = &mut self.project_dialog {
                        apply_new_worktree_failure(dialog, operation_id, &project_path, message);
                    }
                }
                WorkspaceEvent::Error(error) => self.diagnostic = Some(error),
            }
        }
        handled
    }

    fn poll_changed(&self) -> bool {
        let snapshot = self.workspace.snapshot();
        if snapshot.revision() != self.observed_revision {
            return true;
        }
        let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
            return self.observed_surface_identity.is_some();
        };
        let identity = Arc::as_ptr(surface).cast::<()>() as usize;
        Some(identity) != self.observed_surface_identity
            || surface.load().generation() != self.observed_surface_generation
    }

    fn on_key_down(
        &mut self,
        presentation_id: u64,
        event: &KeyDownEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        let keystroke = &event.keystroke;
        if event.is_held
            && let Some((canonical, input)) =
                retained_key_event(&self.keyboard, keystroke, InputKeyEvent::Repeat)
        {
            self.send_key_event(
                presentation_id,
                input,
                &canonical.identity,
                InputKeyEvent::Repeat,
            );
            cx.stop_propagation();
            return;
        }
        if is_toggle_sidebar_shortcut(keystroke) {
            // The application key binding owns this chord. Leave propagation
            // intact so GPUI dispatches ToggleSidebar, but never enqueue it as
            // terminal input.
            if event.is_held {
                cx.stop_propagation();
            }
            return;
        }
        if is_paste_shortcut(keystroke) {
            if !event.is_held
                && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            {
                self.send_key(presentation_id, KeyInput::paste(text));
            }
            cx.stop_propagation();
            return;
        }

        let event = if event.is_held {
            InputKeyEvent::Repeat
        } else {
            InputKeyEvent::Press
        };
        let canonical = canonical_terminal_key(keystroke);
        let input = terminal_key_input_with_canonical(keystroke, event, &canonical).or_else(|| {
            self.keyboard
                .input_for(&canonical.identity, event, canonical.modifiers)
        });
        if let Some(input) = input {
            self.send_key_event(presentation_id, input, &canonical.identity, event);
            cx.stop_propagation();
        }
    }

    fn on_key_up(
        &mut self,
        presentation_id: u64,
        event: &KeyUpEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        if let Some((canonical, input)) =
            retained_key_event(&self.keyboard, &event.keystroke, InputKeyEvent::Release)
        {
            self.send_key_event(
                presentation_id,
                input,
                &canonical.identity,
                InputKeyEvent::Release,
            );
            cx.stop_propagation();
            return;
        }
        if is_paste_shortcut(&event.keystroke) || is_toggle_sidebar_shortcut(&event.keystroke) {
            cx.stop_propagation();
        }
    }

    fn on_mouse_down(
        &mut self,
        presentation_id: u64,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        window.focus(&self.focus);
        if let Some(button) = terminal_mouse_button(event.button) {
            let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
            if let Some(cell) = cell
                && self.send_mouse_at_cell(
                    presentation_id,
                    MouseAction::Press(button),
                    cell,
                    event.modifiers,
                )
            {
                self.pointer.press(button, cell);
            }
            cx.stop_propagation();
        }
    }

    fn on_mouse_up(
        &mut self,
        presentation_id: u64,
        event: &MouseUpEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        if let Some(button) = terminal_mouse_button(event.button) {
            let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
            if let Some(cell) = self.pointer.release_cell(button, cell) {
                if self.send_mouse_at_cell(
                    presentation_id,
                    MouseAction::Release(button),
                    cell,
                    event.modifiers,
                ) {
                    self.pointer.finish_release(button);
                }
                cx.stop_propagation();
            }
        }
    }

    fn on_mouse_move(
        &mut self,
        presentation_id: u64,
        event: &MouseMoveEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        let button = event.pressed_button.and_then(terminal_mouse_button);
        let cell = self.terminal_cell_at(event.position.x.into(), event.position.y.into());
        if let Some(cell) = self.pointer.observe(cell) {
            self.send_mouse_at_cell(
                presentation_id,
                MouseAction::Move(button),
                cell,
                event.modifiers,
            );
        }
        cx.stop_propagation();
    }

    fn on_scroll_wheel(
        &mut self,
        presentation_id: u64,
        event: &ScrollWheelEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        let delta = event
            .delta
            .pixel_delta(px(self.terminal_metrics.line_height));
        let vertical = f32::from(delta.y);
        if vertical == 0.0 {
            return;
        }
        if let Some(cell) = self.terminal_cell_at(event.position.x.into(), event.position.y.into())
        {
            let steps = terminal_wheel_steps(
                &mut self.wheel_remainder,
                vertical,
                self.terminal_metrics.line_height,
            );
            if let Some(action) = terminal_wheel_action(steps) {
                let input = MouseInput {
                    action,
                    column: cell.0,
                    row: cell.1,
                    modifiers: input_modifiers(event.modifiers),
                };
                let _accepted = self.enqueue_input(
                    presentation_id,
                    PendingUiInput::Wheel(WheelBatch {
                        input,
                        remaining: steps.unsigned_abs(),
                    }),
                );
            }
        }
        cx.stop_propagation();
    }

    fn terminal_cell_at(&self, x: f32, y: f32) -> Option<(usize, usize)> {
        let snapshot = self.workspace.snapshot();
        let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
            return None;
        };
        let size = surface.load().size();
        terminal_cell_at_with_offset(
            x,
            y,
            self.navigation_width(&snapshot),
            APP_TITLEBAR_HEIGHT,
            self.terminal_metrics.cell_width,
            self.terminal_metrics.line_height,
            size,
        )
    }

    fn send_mouse_at_cell(
        &mut self,
        presentation_id: u64,
        action: MouseAction,
        (column, row): (usize, usize),
        modifiers: gpui::Modifiers,
    ) -> bool {
        let input = MouseInput {
            action,
            column,
            row,
            modifiers: input_modifiers(modifiers),
        };
        self.enqueue_input(presentation_id, PendingUiInput::Mouse(input))
    }

    fn send_key(&mut self, presentation_id: u64, input: KeyInput) {
        self.enqueue_input(presentation_id, PendingUiInput::Key(input));
    }

    fn send_key_event(
        &mut self,
        presentation_id: u64,
        input: KeyInput,
        key: &TerminalKeyIdentity,
        event: InputKeyEvent,
    ) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        if !self.keyboard.accepts(key, event) {
            return;
        }
        let reserved_key_releases = match event {
            InputKeyEvent::Press => self.keyboard.reservations_after_press(key),
            InputKeyEvent::Repeat | InputKeyEvent::Release => self.keyboard.reserved_releases(),
        };
        let pressed_input = (event == InputKeyEvent::Press).then(|| input.clone());
        if self.enqueue_input_with_reserve(
            presentation_id,
            PendingUiInput::Key(input),
            reserved_key_releases,
        ) {
            self.keyboard.finish_accepted(key, pressed_input, event);
        }
    }

    fn enqueue_input(&mut self, presentation_id: u64, input: PendingUiInput) -> bool {
        self.enqueue_input_with_reserve(presentation_id, input, self.keyboard.reserved_releases())
    }

    fn enqueue_input_with_reserve(
        &mut self,
        presentation_id: u64,
        input: PendingUiInput,
        reserved_key_releases: usize,
    ) -> bool {
        if !self.presentation_accepts_input(presentation_id) {
            return false;
        }
        if let PendingUiInput::Resize(resize) = &input
            && coalesce_last_resize(&mut self.pending_input, presentation_id, *resize)
        {
            return true;
        }
        if let PendingUiInput::Wheel(batch) = &input
            && coalesce_last_wheel(
                &mut self.pending_input,
                presentation_id,
                *batch,
                self.input_refusal.acceptance_marker(),
            )
        {
            return true;
        }
        if matches!(
            &input,
            PendingUiInput::Mouse(MouseInput {
                action: MouseAction::Move(_),
                ..
            })
        ) && let Some(last) = self.pending_input.back_mut()
            && last.presentation_id == presentation_id
            && matches!(
                last.input,
                PendingUiInput::Mouse(MouseInput {
                    action: MouseAction::Move(_),
                    ..
                })
            )
        {
            last.input = input;
            last.accepted_after_refusal = self.input_refusal.acceptance_marker();
            return true;
        }

        let bytes = input.byte_len();
        if !input_queue_has_capacity(
            &input,
            self.pending_input
                .iter()
                .filter(|queued| queued.input.counts_toward_input_capacity())
                .count(),
            self.pending_input_bytes,
            bytes,
            reserved_key_releases,
        ) {
            self.input_refusal.refuse();
            self.diagnostic = Some(INPUT_BUFFER_FULL_DIAGNOSTIC.to_owned());
            return false;
        }
        let accepted_after_refusal = input
            .counts_toward_input_capacity()
            .then(|| self.input_refusal.acceptance_marker())
            .flatten();
        self.pending_input_bytes += bytes;
        self.pending_input.push_back(QueuedUiInput {
            presentation_id,
            input,
            bytes,
            accepted_after_refusal,
        });
        let _changed = self.flush_pending_input();
        true
    }

    fn flush_pending_input(&mut self) -> bool {
        let mut changed = self.sync_terminal_scope();
        let mut delivered_wheel_steps = 0;
        if self.paste_confirmation {
            return changed;
        }
        loop {
            let Some(input) = self.pending_input.front() else {
                if clears_when_input_queue_is_empty(self.diagnostic.as_deref()) {
                    self.diagnostic = None;
                    changed = true;
                }
                return changed;
            };
            if delivered_wheel_steps >= MAX_WHEEL_EVENTS_PER_CALLBACK
                && matches!(input.input, PendingUiInput::Wheel(_))
            {
                return changed;
            }
            let active_presentation = terminal_presentation_id(self.workspace.snapshot().content());
            if !queued_input_matches_presentation(input, active_presentation) {
                let stale = self.pending_input.pop_front().expect("front input exists");
                self.pending_input_bytes = self.pending_input_bytes.saturating_sub(stale.bytes);
                changed = true;
                continue;
            }
            let result = match &input.input {
                PendingUiInput::Key(input) => self.workspace.send_key(input.clone()),
                PendingUiInput::Mouse(input) => self.workspace.send_mouse(*input),
                PendingUiInput::Wheel(batch) => self.workspace.send_mouse(batch.input),
                PendingUiInput::ClipboardResponse(bytes) => {
                    self.workspace.send_clipboard_response(bytes.clone())
                }
                PendingUiInput::Resize(resize) => self.workspace.resize_with_pixels(
                    resize.columns,
                    resize.rows,
                    resize.pixel_width,
                    resize.pixel_height,
                ),
            };
            match result {
                Ok(()) => {
                    if let Some(QueuedUiInput {
                        input: PendingUiInput::Wheel(batch),
                        ..
                    }) = self.pending_input.front_mut()
                    {
                        debug_assert!(batch.remaining > 0);
                        batch.remaining = batch.remaining.saturating_sub(1);
                        delivered_wheel_steps += 1;
                        changed = true;
                        if batch.remaining > 0 {
                            if delivered_wheel_steps >= MAX_WHEEL_EVENTS_PER_CALLBACK {
                                return changed;
                            }
                            continue;
                        }
                    }
                    let delivered = self.pending_input.pop_front().expect("front input exists");
                    self.pending_input_bytes =
                        self.pending_input_bytes.saturating_sub(delivered.bytes);
                    let recovered = self
                        .input_refusal
                        .delivered(delivered.accepted_after_refusal);
                    if clears_after_input_delivery(
                        self.diagnostic.as_deref(),
                        recovered,
                        self.input_refusal.is_pending(),
                    ) {
                        self.diagnostic = None;
                    }
                    changed = true;
                }
                Err(error) if error.is_backpressure() => {
                    let diagnostic = if self.input_refusal.is_pending() {
                        INPUT_BUFFER_FULL_DIAGNOSTIC
                    } else {
                        INPUT_BUFFERED_DIAGNOSTIC
                    };
                    if self.diagnostic.as_deref() != Some(diagnostic) {
                        self.diagnostic = Some(diagnostic.to_owned());
                        changed = true;
                    }
                    return changed;
                }
                Err(error) => {
                    self.pending_input.clear();
                    self.pending_input_bytes = 0;
                    self.input_refusal = InputRefusal::default();
                    self.diagnostic = Some(error.to_string());
                    return true;
                }
            }
        }
    }

    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    fn resize_for_window(&mut self, window: &Window) {
        let bounds = window.bounds();
        let snapshot = self.workspace.snapshot();
        let width = f32::from(bounds.size.width) - self.navigation_width(&snapshot);
        let height = f32::from(bounds.size.height) - APP_TITLEBAR_HEIGHT;
        let (columns, rows) = terminal_grid_size(
            width,
            height,
            self.terminal_metrics.cell_width,
            self.terminal_metrics.line_height,
        );
        let content_width = width.max(1.0);
        let content_height = height.max(1.0);
        let pixel_width = content_width.min(f32::from(u16::MAX)) as u16;
        let pixel_height = content_height.min(f32::from(u16::MAX)) as u16;
        let resize = TerminalResize {
            columns,
            rows,
            pixel_width,
            pixel_height,
        };
        if let Some(presentation_id) = terminal_presentation_id(snapshot.content()) {
            let _accepted = self.enqueue_input(presentation_id, PendingUiInput::Resize(resize));
        } else if let Err(error) = self.workspace.resize_with_pixels(
            resize.columns,
            resize.rows,
            resize.pixel_width,
            resize.pixel_height,
        ) {
            self.diagnostic = Some(error.to_string());
        }
    }

    fn approve_paste(&mut self, presentation_id: u64, cx: &mut Context<Self>) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        if let Err(error) = self.workspace.approve_paste() {
            self.diagnostic = Some(error.to_string());
        }
        self.paste_confirmation = false;
        let _changed = self.flush_pending_input();
        cx.notify();
    }

    fn cancel_paste(&mut self, presentation_id: u64, cx: &mut Context<Self>) {
        if !self.presentation_accepts_input(presentation_id) {
            return;
        }
        self.workspace.cancel_paste();
        self.paste_confirmation = false;
        let _changed = self.flush_pending_input();
        cx.notify();
    }

    fn terminal_element(
        &mut self,
        presentation_id: u64,
        surface: &Arc<SurfaceStore>,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let frame = surface.load();
        let identity = Arc::as_ptr(surface).cast::<()>() as usize;
        if self.observed_surface_identity != Some(identity) {
            self.paint_cache.clear();
        }
        let rows = self.paint_cache.update(&frame).to_vec();
        self.observed_surface_identity = Some(identity);
        self.observed_surface_generation = frame.generation();
        let appearance = snapshot.appearance();
        let terminal = self.terminal_surface_element(presentation_id, appearance, rows, cx);

        div()
            .size_full()
            .flex()
            .flex_col()
            .overflow_hidden()
            .bg(rgb(appearance.background()))
            .child(terminal)
    }

    fn terminal_surface_element(
        &self,
        presentation_id: u64,
        appearance: &workspace::Appearance,
        rows: Vec<Arc<Vec<PaintRun>>>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .id("terminal-surface")
            .track_focus(&self.focus)
            .flex()
            .flex_col()
            .flex_1()
            .overflow_hidden()
            .bg(rgb(appearance.background()))
            .text_color(rgb(appearance.foreground()))
            .font_family(appearance.font_family().to_owned())
            .text_size(px(f32::from(appearance.font_size())))
            .line_height(px(self.terminal_metrics.line_height))
            .font_weight(FontWeight::NORMAL)
            .on_key_down(cx.listener(move |this, event, window, cx| {
                this.on_key_down(presentation_id, event, window, cx);
            }))
            .on_key_up(cx.listener(move |this, event, window, cx| {
                this.on_key_up(presentation_id, event, window, cx);
            }))
            .on_mouse_down(
                GpuiMouseButton::Left,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_down(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_down(
                GpuiMouseButton::Middle,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_down(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_down(
                GpuiMouseButton::Right,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_down(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up(
                GpuiMouseButton::Left,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up(
                GpuiMouseButton::Middle,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up(
                GpuiMouseButton::Right,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up_out(
                GpuiMouseButton::Left,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up_out(
                GpuiMouseButton::Middle,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_up_out(
                GpuiMouseButton::Right,
                cx.listener(move |this, event, window, cx| {
                    this.on_mouse_up(presentation_id, event, window, cx);
                }),
            )
            .on_mouse_move(cx.listener(move |this, event, window, cx| {
                this.on_mouse_move(presentation_id, event, window, cx);
            }))
            .on_scroll_wheel(cx.listener(move |this, event, window, cx| {
                this.on_scroll_wheel(presentation_id, event, window, cx);
            }))
            .children(rows.into_iter().map(|row| {
                div()
                    .flex()
                    .flex_none()
                    .h(px(self.terminal_metrics.line_height))
                    .whitespace_nowrap()
                    .children(
                        row.iter()
                            .cloned()
                            .map(|run| paint_run_element(run, self.terminal_metrics.cell_width)),
                    )
                    .into_any_element()
            }))
    }

    fn content_element(
        &mut self,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        if !snapshot.hosts().is_empty() {
            return self.application_shell(snapshot, cx);
        }
        match snapshot.content() {
            WorkspaceContent::Shell => centered("No terminal hosts are available."),
            WorkspaceContent::Loading => centered("Discovering sessions…"),
            WorkspaceContent::Error { message } => div()
                .size_full()
                .flex()
                .flex_col()
                .gap_3()
                .items_center()
                .justify_center()
                .text_color(rgb(0xb7_bc_c6))
                .child(message.clone())
                .child(
                    div()
                        .id("retry-wsl")
                        .px_3()
                        .py_1()
                        .rounded_md()
                        .cursor_pointer()
                        .bg(rgb(0x2a_2f_3a))
                        .child("Retry")
                        .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
                )
                .into_any_element(),
            WorkspaceContent::Attaching {
                endpoint, session, ..
            } => centered(format!("Attaching to {endpoint} · {session}…")),
            WorkspaceContent::Ready { endpoint, sessions } => {
                Self::ready_element(endpoint, sessions, None, cx)
            }
            WorkspaceContent::Terminal {
                endpoint: _,
                session: _,
                presentation_id,
                surface,
                ..
            } => self
                .terminal_element(*presentation_id, surface, snapshot, cx)
                .into_any_element(),
        }
    }

    fn application_shell(
        &mut self,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let hosts = snapshot.hosts();
        let selected = snapshot
            .selected_host()
            .and_then(|id| hosts.iter().find(|host| host.id() == id));
        let main = match snapshot.content() {
            WorkspaceContent::Terminal {
                endpoint: _,
                session: _,
                presentation_id,
                surface,
                ..
            } => self
                .terminal_element(*presentation_id, surface, snapshot, cx)
                .into_any_element(),
            WorkspaceContent::Attaching {
                endpoint, session, ..
            } => centered(format!("Attaching to {endpoint} · {session}…")),
            WorkspaceContent::Loading => centered("Starting WSL and discovering sessions…"),
            WorkspaceContent::Error { message } => centered(message.clone()),
            WorkspaceContent::Shell | WorkspaceContent::Ready { .. } => selected.map_or_else(
                || centered("No terminal hosts are available."),
                |host| Self::host_landing_element(host, cx),
            ),
        };
        let mut shell = div().size_full().flex().min_w_0();
        if self.sidebar_visible {
            shell = shell.child(self.workspace_tree(snapshot, cx));
        }
        shell
            .child(div().flex_1().min_w_0().h_full().child(main))
            .into_any_element()
    }

    fn title_bar(&self, title: String, cx: &mut Context<Self>) -> gpui::AnyElement {
        let toggle_label = if self.sidebar_visible {
            "Hide sidebar (Ctrl+Shift+B)"
        } else {
            "Show sidebar (Ctrl+Shift+B)"
        };

        div()
            .h(px(APP_TITLEBAR_HEIGHT))
            .w_full()
            .flex_none()
            .flex()
            .items_center()
            .bg(rgb(APP_CHROME_BACKGROUND))
            .border_b_1()
            .border_color(rgb(0x20_242c))
            .child(
                div()
                    .id("toggle-sidebar")
                    .w(px(APP_TITLEBAR_HEIGHT))
                    .h_full()
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .text_size(px(16.0))
                    .text_color(rgb(0xa5_acb8))
                    .hover(|style| style.bg(rgb(0x24_2933)).text_color(rgb(0xe5_e9f0)))
                    .child("☰")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.toggle_sidebar(window, cx);
                    })),
            )
            .child(
                div()
                    .id("window-drag-region")
                    .h_full()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .window_control_area(WindowControlArea::Drag)
                    .on_mouse_down(GpuiMouseButton::Left, |_, window, _| {
                        window.start_window_move();
                    })
                    .text_sm()
                    .text_color(rgb(0xc4_c9d2))
                    .child(title),
            )
            .child(
                div()
                    .id("open-settings")
                    .w(px(APP_TITLEBAR_HEIGHT))
                    .h_full()
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .text_size(px(15.0))
                    .text_color(rgb(0xa5_acb8))
                    .hover(|style| style.bg(rgb(0x24_2933)).text_color(rgb(0xe5_e9f0)))
                    .child("⚙")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.open_settings(window, cx);
                    })),
            )
            .child(window_control(
                "window-minimize",
                "−",
                WindowControlArea::Min,
            ))
            .child(window_control(
                "window-maximize",
                "□",
                WindowControlArea::Max,
            ))
            .child(window_control(
                "window-close",
                "×",
                WindowControlArea::Close,
            ))
            .on_mouse_down(GpuiMouseButton::Right, |event, window, _| {
                window.show_window_menu(event.position);
            })
            .child(
                div()
                    .id("sidebar-shortcut-description")
                    .absolute()
                    .invisible()
                    .child(toggle_label),
            )
            .into_any_element()
    }

    fn new_session_overlay(
        &self,
        snapshot: &workspace::WorkspaceSnapshot,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let draft = self.new_session.as_ref()?;
        let empty = draft.name.trim().is_empty();
        let validation = new_session_validation(snapshot, draft);
        let can_create = !empty && validation.is_none();
        let focused = self.create_focus.is_focused(window);

        Some(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x00_00_00_80))
                .child(
                    div()
                        .id("new-session-dialog")
                        .track_focus(&self.create_focus)
                        .w(px(460.0))
                        .flex()
                        .flex_col()
                        .rounded_lg()
                        .border_1()
                        .border_color(rgb(0x36_3c48))
                        .bg(rgb(0x18_1b22))
                        .shadow_lg()
                        .on_key_down(cx.listener(|this, event, window, cx| {
                            this.on_new_session_key_down(event, window, cx);
                        }))
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_b_1()
                                .border_color(rgb(0x2a_2f39))
                                .text_sm()
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(rgb(0xe0_e4eb))
                                .child(match draft.kind {
                                    NewSessionKind::Tmux => "New tmux session",
                                    NewSessionKind::Herdr => "New Herdr session",
                                    NewSessionKind::Zellij => "New Zellij session",
                                }),
                        )
                        .child(Self::new_session_name_input(draft, focused, cx))
                        .children(validation.map(|message| {
                            div()
                                .px_4()
                                .pb_3()
                                .text_xs()
                                .text_color(rgb(0xd0_7070))
                                .child(message)
                        }))
                        .child(Self::new_session_actions(can_create, cx)),
                )
                .into_any_element(),
        )
    }

    #[allow(clippy::too_many_lines)] // Declarative GPUI dialog hierarchy.
    fn project_overlay(&self, window: &Window, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let dialog = self.project_dialog.as_ref()?;
        let focused = self.project_focus.is_focused(window);
        let (title, body, action_label, submitting, can_submit, error) =
            match dialog {
                ProjectDialog::Add {
                    path,
                    submitting,
                    error,
                    ..
                } => {
                    let valid = workspace::is_absolute_project_path_input(path);
                    let text = if path.is_empty() && !focused {
                        "Choose a folder or enter a WSL path".to_owned()
                    } else if path.is_empty() {
                        "▏".to_owned()
                    } else {
                        format!("{path}▏")
                    };
                    let input = div()
                        .id("kwt-project-path-input")
                        .px_3()
                        .h(px(38.0))
                        .flex_1()
                        .flex()
                        .items_center()
                        .rounded_md()
                        .border_1()
                        .border_color(rgb(if focused { 0x4a_8f_cf } else { 0x3a_404c }))
                        .bg(rgb(0x0f_1218))
                        .cursor_text()
                        .text_sm()
                        .text_color(rgb(if path.is_empty() && !focused {
                            0x72_7986
                        } else {
                            0xe1_e5ec
                        }))
                        .child(text)
                        .on_click(cx.listener(|this, _, window, cx| {
                            window.focus(&this.project_focus);
                            cx.notify();
                        }))
                        .into_any_element();
                    let body = div()
                        .m_4()
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(input)
                        .child(
                            div()
                                .id("browse-kwt-project")
                                .h(px(38.0))
                                .px_3()
                                .flex()
                                .items_center()
                                .rounded_md()
                                .border_1()
                                .border_color(rgb(0x3a_404c))
                                .text_sm()
                                .text_color(rgb(if *submitting { 0x72_7986 } else { 0xc7_ccd5 }))
                                .child("Browse…")
                                .when(!*submitting, |element| {
                                    element
                                        .cursor_pointer()
                                        .hover(|style| style.bg(rgb(0x29_2e38)))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.browse_for_project(cx);
                                        }))
                                }),
                        )
                        .into_any_element();
                    (
                        "Add Project".to_owned(),
                        body,
                        if *submitting {
                            "Adding…"
                        } else {
                            "Add Project"
                        },
                        *submitting,
                        valid && !*submitting,
                        error.as_deref(),
                    )
                }
                ProjectDialog::Remove {
                    endpoint,
                    name,
                    path,
                    submitting,
                    error,
                    ..
                } => {
                    let body =
                        div()
                            .px_4()
                            .py_4()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .text_sm()
                            .text_color(rgb(0xb6_bcc7))
                            .child(format!("Remove “{name}” from {endpoint}?"))
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(rgb(0x8f_96_a3))
                                    .child(path.clone()),
                            )
                            .child(div().text_xs().text_color(rgb(0x8f_96_a3)).child(
                                "The repository, worktrees, and tmux sessions are not deleted.",
                            ))
                            .into_any_element();
                    (
                        "Remove Project".to_owned(),
                        body,
                        if *submitting { "Removing…" } else { "Remove" },
                        *submitting,
                        !*submitting,
                        error.as_deref(),
                    )
                }
                ProjectDialog::NewWorktree {
                    project_name,
                    branch,
                    mode,
                    selected_source,
                    selected_pull_request,
                    branches,
                    pull_requests,
                    loading,
                    loaded,
                    submitting,
                    error,
                    ..
                } => {
                    let visible_branches = visible_kwt_branch_candidates(branches, branch);
                    let visible_pull_requests = visible_kwt_pull_requests(pull_requests, branch);
                    let text = if branch.is_empty() && !focused {
                        match mode {
                            NewWorktreeMode::Branch => "Branch name".to_owned(),
                            NewWorktreeMode::PullRequest => {
                                "Pull request number, title, or URL".to_owned()
                            }
                        }
                    } else if branch.is_empty() {
                        "▏".to_owned()
                    } else {
                        format!("{branch}▏")
                    };
                    let tabs = div()
                        .flex()
                        .gap_1()
                        .child(
                            div()
                                .id("new-worktree-branch-mode")
                                .px_3()
                                .py_1()
                                .rounded_sm()
                                .cursor_pointer()
                                .bg(rgb(if *mode == NewWorktreeMode::Branch {
                                    0x25_3549
                                } else {
                                    0x13_161c
                                }))
                                .text_xs()
                                .child("Branch")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.switch_new_worktree_mode(NewWorktreeMode::Branch, cx);
                                })),
                        )
                        .child(
                            div()
                                .id("new-worktree-pr-mode")
                                .px_3()
                                .py_1()
                                .rounded_sm()
                                .cursor_pointer()
                                .bg(rgb(if *mode == NewWorktreeMode::PullRequest {
                                    0x25_3549
                                } else {
                                    0x13_161c
                                }))
                                .text_xs()
                                .child("Pull Request")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.switch_new_worktree_mode(NewWorktreeMode::PullRequest, cx);
                                })),
                        );
                    let mut body = div().m_4().flex().flex_col().gap_2().child(tabs).child(
                        div()
                            .id("kwt-worktree-branch-input")
                            .px_3()
                            .h(px(38.0))
                            .flex()
                            .items_center()
                            .rounded_md()
                            .border_1()
                            .border_color(rgb(if focused { 0x4a_8f_cf } else { 0x3a_404c }))
                            .bg(rgb(0x0f_1218))
                            .cursor_text()
                            .text_sm()
                            .text_color(rgb(if branch.is_empty() && !focused {
                                0x72_7986
                            } else {
                                0xe1_e5ec
                            }))
                            .child(text)
                            .on_click(cx.listener(|this, _, window, cx| {
                                window.focus(&this.project_focus);
                                cx.notify();
                            })),
                    );
                    if *loading {
                        body = body.child(div().text_xs().text_color(rgb(0x8f_96_a3)).child(
                            match mode {
                                NewWorktreeMode::Branch => "Loading branches…",
                                NewWorktreeMode::PullRequest => "Loading pull requests…",
                            },
                        ));
                    } else if *mode == NewWorktreeMode::Branch {
                        let mut candidates = div()
                            .id("kwt-branch-candidates")
                            .max_h(px(196.0))
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap_1();
                        for (index, candidate) in visible_branches.into_iter().enumerate() {
                            let name = candidate.name().to_owned();
                            let source = candidate.source().to_owned();
                            let selected = branch == &name
                                && selected_source
                                    .as_deref()
                                    .is_some_and(|value| value == source);
                            let detail = if candidate.is_remote() {
                                format!("{}  ·  {}", candidate.name(), candidate.source())
                            } else {
                                candidate.name().to_owned()
                            };
                            candidates = candidates.child(
                                div()
                                    .id(("kwt-branch-candidate", index))
                                    .h(px(28.0))
                                    .px_2()
                                    .flex()
                                    .items_center()
                                    .rounded_sm()
                                    .cursor_pointer()
                                    .bg(rgb(if selected { 0x1d_3f63 } else { 0x13_161c }))
                                    .text_xs()
                                    .text_color(rgb(0xc4_c9_d2))
                                    .hover(|style| style.bg(rgb(0x25_2a34)))
                                    .child(detail)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if let Some(ProjectDialog::NewWorktree {
                                            branch,
                                            selected_source,
                                            error,
                                            ..
                                        }) = &mut this.project_dialog
                                        {
                                            branch.clone_from(&name);
                                            *selected_source = Some(source.clone());
                                            *error = None;
                                        }
                                        window.focus(&this.project_focus);
                                        cx.notify();
                                    })),
                            );
                        }
                        body = body.child(candidates);
                    } else {
                        let mut candidates = div()
                            .id("kwt-pull-request-candidates")
                            .max_h(px(240.0))
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap_1();
                        for (index, pull_request) in visible_pull_requests.into_iter().enumerate() {
                            let id = pull_request.id().to_owned();
                            let selected = selected_pull_request.as_deref() == Some(id.as_str());
                            let imported = pull_request.imported();
                            let title = format!(
                                "#{}  {}{}",
                                pull_request.number(),
                                pull_request.title(),
                                if pull_request.draft() {
                                    "  ·  draft"
                                } else {
                                    ""
                                }
                            );
                            let detail = format!(
                                "{}  ·  {}",
                                pull_request.author(),
                                pull_request.source_branch()
                            );
                            candidates = candidates.child(
                                div()
                                    .id(("kwt-pull-request-candidate", index))
                                    .px_2()
                                    .py_1()
                                    .flex()
                                    .flex_col()
                                    .rounded_sm()
                                    .cursor_pointer()
                                    .bg(rgb(if selected { 0x1d_3f63 } else { 0x13_161c }))
                                    .text_xs()
                                    .text_color(rgb(0xc4_c9_d2))
                                    .hover(|style| style.bg(rgb(0x25_2a34)))
                                    .child(title)
                                    .child(div().text_color(rgb(0x78_808e)).child(if imported {
                                        format!("{detail}  ·  imported")
                                    } else {
                                        detail
                                    }))
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if let Some(ProjectDialog::NewWorktree {
                                            branch,
                                            mode: NewWorktreeMode::PullRequest,
                                            selected_pull_request,
                                            error,
                                            ..
                                        }) = &mut this.project_dialog
                                        {
                                            branch.clone_from(&id);
                                            *selected_pull_request = Some(id.clone());
                                            *error = None;
                                        }
                                        window.focus(&this.project_focus);
                                        cx.notify();
                                    })),
                            );
                        }
                        body = body.child(candidates);
                    }
                    (
                        format!("New worktree · {project_name}"),
                        body.into_any_element(),
                        if *submitting {
                            "Creating…"
                        } else if *mode == NewWorktreeMode::PullRequest {
                            "Import"
                        } else {
                            "Create"
                        },
                        *submitting,
                        match mode {
                            NewWorktreeMode::Branch => {
                                can_create_worktree(branch, *loaded, *loading, *submitting)
                            }
                            NewWorktreeMode::PullRequest => {
                                *loaded
                                    && !*loading
                                    && !*submitting
                                    && pull_request_import_selector(
                                        pull_requests,
                                        branch,
                                        selected_pull_request.as_deref(),
                                    )
                                    .is_some()
                            }
                        },
                        error.as_deref(),
                    )
                }
                ProjectDialog::RemoveWorktree {
                    target,
                    submitting,
                    error,
                } => {
                    let session_copy = if target.session_was_running {
                        " Its live tmux session will be terminated first."
                    } else {
                        ""
                    };
                    let checking = target.authority.is_none() && error.is_none();
                    let review_again = target.authority.is_none() && error.is_some();
                    let body = div()
                        .px_4()
                        .py_4()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .text_sm()
                        .text_color(rgb(0xb6_bcc7))
                        .child(format!(
                            "Remove “{}” from {}?{}",
                            target.branch, target.project_name, session_copy
                        ))
                        .child(
                            div()
                                .text_xs()
                                .text_color(rgb(0x8f_96_a3))
                                .child(target.open.worktree_path.clone()),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(rgb(0x8f_96_a3))
                                .child("The Git branch will be kept."),
                        )
                        .into_any_element();
                    (
                        "Remove Worktree".to_owned(),
                        body,
                        if *submitting {
                            "Removing…"
                        } else if checking {
                            "Checking…"
                        } else if review_again {
                            "Review Again"
                        } else {
                            "Remove Worktree"
                        },
                        *submitting,
                        (target.authority.is_some() || review_again) && !*submitting,
                        error.as_deref(),
                    )
                }
            };

        Some(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x00_00_00_80))
                .child(
                    div()
                        .id("kwt-project-dialog")
                        .track_focus(&self.project_focus)
                        .w(px(460.0))
                        .flex()
                        .flex_col()
                        .rounded_lg()
                        .border_1()
                        .border_color(rgb(0x36_3c48))
                        .bg(rgb(0x18_1b22))
                        .shadow_lg()
                        .on_key_down(cx.listener(|this, event, window, cx| {
                            this.on_project_dialog_key_down(event, window, cx);
                        }))
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_b_1()
                                .border_color(rgb(0x2a_2f39))
                                .text_sm()
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(rgb(0xe0_e4eb))
                                .child(title),
                        )
                        .child(body)
                        .children(error.map(|message| {
                            div()
                                .px_4()
                                .pb_3()
                                .text_xs()
                                .text_color(rgb(0xd0_7070))
                                .child(message.to_owned())
                        }))
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_t_1()
                                .border_color(rgb(0x2a_2f39))
                                .flex()
                                .items_center()
                                .justify_end()
                                .gap_2()
                                .child(
                                    div()
                                        .id("cancel-kwt-project")
                                        .px_3()
                                        .py_1()
                                        .rounded_sm()
                                        .text_sm()
                                        .text_color(rgb(if submitting {
                                            0x72_7986
                                        } else {
                                            0xb6_bcc7
                                        }))
                                        .child("Cancel")
                                        .when(!submitting, |element| {
                                            element
                                                .cursor_pointer()
                                                .hover(|style| style.bg(rgb(0x29_2e38)))
                                                .on_click(cx.listener(|this, _, window, cx| {
                                                    this.cancel_project_dialog(window, cx);
                                                }))
                                        }),
                                )
                                .child(
                                    div()
                                        .id("submit-kwt-project")
                                        .px_3()
                                        .py_1()
                                        .rounded_sm()
                                        .bg(rgb(if can_submit { 0x1d_5f9a } else { 0x2b_3039 }))
                                        .text_sm()
                                        .text_color(rgb(if can_submit {
                                            0xf1_f5fa
                                        } else {
                                            0x72_7986
                                        }))
                                        .child(action_label)
                                        .when(can_submit, |element| {
                                            element.cursor_pointer().on_click(cx.listener(
                                                |this, _, _, cx| this.submit_project_dialog(cx),
                                            ))
                                        }),
                                ),
                        ),
                )
                .into_any_element(),
        )
    }

    fn ssh_field_row(
        &self,
        label: &'static str,
        field: SshField,
        draft: &SshHostDraft,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let selected = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.host_editor.as_ref())
            .is_some_and(|editor| editor.field == field);
        let value = ssh_draft_field(draft, field);
        let placeholder = match field {
            SshField::Name => "Display name",
            SshField::Hostname => "Hostname or SSH alias",
            SshField::User | SshField::Port | SshField::SocketDirectory => "Optional",
            SshField::TmuxBinary => "Automatic",
        };
        let display = if value.is_empty() {
            if selected { "▏" } else { placeholder }.to_owned()
        } else if selected {
            format!("{value}▏")
        } else {
            value.to_owned()
        };
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().text_xs().text_color(rgb(0x8f_96_a3)).child(label))
            .child(
                div()
                    .id(("ssh-setting-field", field as usize))
                    .h(px(36.0))
                    .px_3()
                    .flex()
                    .items_center()
                    .rounded_md()
                    .border_1()
                    .border_color(rgb(if selected { 0x4a_8f_cf } else { 0x3a_404c }))
                    .bg(rgb(0x0f_1218))
                    .cursor_text()
                    .text_sm()
                    .text_color(rgb(if value.is_empty() && !selected {
                        0x72_7986
                    } else {
                        0xe1_e5ec
                    }))
                    .child(display)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if let Some(editor) = this
                            .settings_dialog
                            .as_mut()
                            .and_then(|dialog| dialog.host_editor.as_mut())
                        {
                            editor.field = field;
                        }
                        window.focus(&this.settings_focus);
                        cx.notify();
                    })),
            )
            .into_any_element()
    }

    fn appearance_theme_card(
        theme: TerminalTheme,
        draft: &AppearanceSettingsDraft,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let selected = draft.theme == theme;
        let (background, foreground) = theme
            .colors()
            .unwrap_or_else(|| appearance_preview_colors(draft));
        div()
            .id(("appearance-theme", theme as usize))
            .w(px(154.0))
            .h(px(88.0))
            .p_2()
            .flex()
            .flex_col()
            .gap_2()
            .rounded_md()
            .border_1()
            .border_color(rgb(if selected { 0x4a_8f_cf } else { 0x34_3a46 }))
            .bg(rgb(if selected { 0x20_2b3a } else { 0x11_141a }))
            .cursor_pointer()
            .child(
                div()
                    .h(px(34.0))
                    .px_2()
                    .flex()
                    .items_center()
                    .gap_2()
                    .rounded_sm()
                    .bg(rgb(background))
                    .child(
                        div()
                            .font_family(draft.font_family.clone())
                            .text_sm()
                            .text_color(rgb(foreground))
                            .child("$ _"),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .text_sm()
                    .text_color(rgb(if selected { 0xe8_ec_f3 } else { 0xb8_be_c9 }))
                    .child(theme.title())
                    .when(selected, |element| {
                        element.child(div().text_color(rgb(0x79_b8_f3)).child("✓"))
                    }),
            )
            .on_click(cx.listener(move |this, _, window, cx| {
                if let Some(dialog) = &mut this.settings_dialog {
                    dialog.appearance_editor.draft.theme = theme;
                    dialog.appearance_editor.field = AppearanceField::Theme;
                    dialog.appearance_editor.open_picker = None;
                    dialog.appearance_editor.error = None;
                }
                window.focus(&this.settings_focus);
                let draft = this
                    .settings_dialog
                    .as_ref()
                    .map(|dialog| dialog.appearance_editor.draft.clone());
                if let Some(draft) = draft {
                    this.persist_appearance(&draft, cx);
                }
            }))
            .into_any_element()
    }

    fn appearance_select(
        &self,
        label: &'static str,
        value: String,
        field: AppearanceField,
        picker: AppearancePicker,
        open: bool,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let selected = self
            .settings_dialog
            .as_ref()
            .is_some_and(|dialog| dialog.appearance_editor.field == field);
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().text_xs().text_color(rgb(0x8f_96_a3)).child(label))
            .child(
                div()
                    .id(("appearance-select", field as usize))
                    .h(px(38.0))
                    .px_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .rounded_md()
                    .border_1()
                    .border_color(rgb(if selected { 0x4a_8f_cf } else { 0x3a_404c }))
                    .bg(rgb(0x0f_1218))
                    .cursor_pointer()
                    .text_sm()
                    .text_color(rgb(0xe1_e5ec))
                    .child(value)
                    .child(if open { "▴" } else { "▾" })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if let Some(dialog) = &mut this.settings_dialog {
                            let editor = &mut dialog.appearance_editor;
                            editor.field = field;
                            editor.open_picker =
                                (editor.open_picker != Some(picker)).then_some(picker);
                            editor.error = None;
                        }
                        window.focus(&this.settings_focus);
                        cx.notify();
                    })),
            )
            .into_any_element()
    }

    fn appearance_font_options(
        editor: &AppearanceEditor,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut options = div()
            .id("appearance-font-options")
            .max_h(px(220.0))
            .overflow_y_scroll()
            .rounded_md()
            .border_1()
            .border_color(rgb(0x3a_404c))
            .bg(rgb(0x0f_1218));
        for (index, family) in editor.font_families.iter().enumerate() {
            let selected = family == &editor.draft.font_family;
            let selected_family = family.clone();
            options = options.child(
                div()
                    .id(("appearance-font-option", index))
                    .h(px(30.0))
                    .px_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .cursor_pointer()
                    .bg(rgb(if selected { 0x25_3448 } else { 0x0f_1218 }))
                    .font_family(family.clone())
                    .text_sm()
                    .text_color(rgb(0xd8_dd_e6))
                    .child(family.clone())
                    .when(selected, |element| element.child("✓"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(dialog) = &mut this.settings_dialog {
                            dialog
                                .appearance_editor
                                .draft
                                .font_family
                                .clone_from(&selected_family);
                            dialog.appearance_editor.open_picker = None;
                            dialog.appearance_editor.error = None;
                        }
                        let draft = this
                            .settings_dialog
                            .as_ref()
                            .map(|dialog| dialog.appearance_editor.draft.clone());
                        if let Some(draft) = draft {
                            this.persist_appearance(&draft, cx);
                        }
                    })),
            );
        }
        options.into_any_element()
    }

    fn appearance_size_options(
        editor: &AppearanceEditor,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut options = div()
            .flex()
            .flex_wrap()
            .gap_1()
            .p_2()
            .rounded_md()
            .border_1()
            .border_color(rgb(0x3a_404c))
            .bg(rgb(0x0f_1218));
        for size in TERMINAL_FONT_SIZES {
            let selected = editor.draft.font_size == size.to_string();
            options = options.child(
                div()
                    .id(("appearance-size-option", usize::from(size)))
                    .w(px(54.0))
                    .h(px(30.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_sm()
                    .cursor_pointer()
                    .bg(rgb(if selected { 0x2b_6495 } else { 0x19_1d25 }))
                    .text_sm()
                    .child(format!("{size} pt"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(dialog) = &mut this.settings_dialog {
                            dialog.appearance_editor.draft.font_size = size.to_string();
                            dialog.appearance_editor.open_picker = None;
                            dialog.appearance_editor.error = None;
                        }
                        let draft = this
                            .settings_dialog
                            .as_ref()
                            .map(|dialog| dialog.appearance_editor.draft.clone());
                        if let Some(draft) = draft {
                            this.persist_appearance(&draft, cx);
                        }
                    })),
            );
        }
        options.into_any_element()
    }

    fn appearance_color_field(
        &self,
        label: &'static str,
        value: &str,
        field: AppearanceField,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let selected = self
            .settings_dialog
            .as_ref()
            .is_some_and(|dialog| dialog.appearance_editor.field == field);
        let display = if selected {
            format!("{value}▏")
        } else {
            value.to_owned()
        };
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().text_xs().text_color(rgb(0x8f_96_a3)).child(label))
            .child(
                div()
                    .id(("appearance-color-field", field as usize))
                    .h(px(38.0))
                    .px_3()
                    .flex()
                    .items_center()
                    .rounded_md()
                    .border_1()
                    .border_color(rgb(if selected { 0x4a_8f_cf } else { 0x3a_404c }))
                    .bg(rgb(0x0f_1218))
                    .cursor_text()
                    .text_sm()
                    .child(display)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if let Some(dialog) = &mut this.settings_dialog {
                            dialog.appearance_editor.field = field;
                            dialog.appearance_editor.open_picker = None;
                            dialog.appearance_editor.error = None;
                        }
                        window.focus(&this.settings_focus);
                        cx.notify();
                    })),
            )
            .into_any_element()
    }

    fn appearance_theme_section(
        draft: &AppearanceSettingsDraft,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut themes = div().flex().flex_wrap().gap_2();
        for theme in TerminalTheme::ALL {
            themes = themes.child(Self::appearance_theme_card(theme, draft, cx));
        }
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_base()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Terminal theme"),
            )
            .child(themes)
            .child(
                div()
                    .text_xs()
                    .text_color(rgb(0x8f_96_a3))
                    .child(draft.theme.summary()),
            )
            .into_any_element()
    }

    fn appearance_font_section(
        &self,
        editor: &AppearanceEditor,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let draft = &editor.draft;
        let font_open = editor.open_picker == Some(AppearancePicker::FontFamily);
        let size_open = editor.open_picker == Some(AppearancePicker::FontSize);
        let mut section = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_base()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Terminal font"),
            )
            .child(
                div()
                    .flex()
                    .gap_3()
                    .child(div().flex_1().child(self.appearance_select(
                        "Font family",
                        draft.font_family.clone(),
                        AppearanceField::FontFamily,
                        AppearancePicker::FontFamily,
                        font_open,
                        cx,
                    )))
                    .child(div().w(px(170.0)).child(self.appearance_select(
                        "Font size",
                        format!("{} pt", draft.font_size),
                        AppearanceField::FontSize,
                        AppearancePicker::FontSize,
                        size_open,
                        cx,
                    ))),
            );
        if font_open {
            section = section.child(Self::appearance_font_options(editor, cx));
        } else if size_open {
            section = section.child(Self::appearance_size_options(editor, cx));
        }
        section.into_any_element()
    }

    fn appearance_custom_color_section(
        &self,
        draft: &AppearanceSettingsDraft,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_base()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Custom colors"),
            )
            .child(
                div()
                    .flex()
                    .gap_3()
                    .child(div().flex_1().child(self.appearance_color_field(
                        "Background",
                        &draft.background,
                        AppearanceField::Background,
                        cx,
                    )))
                    .child(div().flex_1().child(self.appearance_color_field(
                        "Foreground",
                        &draft.foreground,
                        AppearanceField::Foreground,
                        cx,
                    ))),
            )
            .into_any_element()
    }

    fn settings_appearance_editor(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let Some(editor) = self
            .settings_dialog
            .as_ref()
            .map(|dialog| &dialog.appearance_editor)
        else {
            return div().into_any_element();
        };
        let draft = &editor.draft;
        let mut form = div()
            .w_full()
            .max_w(px(1080.0))
            .flex()
            .flex_col()
            .gap_6()
            .child(Self::appearance_theme_section(draft, cx))
            .child(self.appearance_font_section(editor, cx));
        if draft.theme == TerminalTheme::Custom {
            form = form.child(self.appearance_custom_color_section(draft, cx));
        }
        form = form.child(Self::appearance_preview(draft));
        if let Some(error) = &editor.error {
            form = form.child(
                div()
                    .text_xs()
                    .text_color(rgb(0xd0_7070))
                    .child(error.clone()),
            );
        }
        div()
            .id("settings-appearance-editor")
            .flex_1()
            .min_w_0()
            .h_full()
            .overflow_y_scroll()
            .px_6()
            .py_5()
            .child(form)
            .into_any_element()
    }

    fn appearance_preview(draft: &AppearanceSettingsDraft) -> gpui::AnyElement {
        let (background, foreground) = appearance_preview_colors(draft);
        let font_size = draft
            .font_size
            .parse::<f32>()
            .ok()
            .filter(|size| *size > 0.0)
            .unwrap_or(14.0)
            .clamp(8.0, 32.0);
        let font_family = if draft.font_family.trim().is_empty() {
            "monospace".to_owned()
        } else {
            draft.font_family.clone()
        };
        let red = (foreground >> 16) & 0xff;
        let green = (foreground >> 8) & 0xff;
        let blue = foreground & 0xff;
        let light_foreground = red + green + blue > 0x17f;
        let accent = if light_foreground {
            0x78_b5_ff
        } else {
            0x1d_5f_9a
        };
        div()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .text_base()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Preview"),
            )
            .child(
                div()
                    .h(px(230.0))
                    .rounded_md()
                    .border_1()
                    .border_color(rgb(0x3a_404c))
                    .bg(rgb(background))
                    .overflow_hidden()
                    .child(
                        div()
                            .h(px(34.0))
                            .px_3()
                            .flex()
                            .items_center()
                            .justify_between()
                            .border_b_1()
                            .border_color(rgba(0xff_ff_ff_18))
                            .text_xs()
                            .text_color(rgb(foreground))
                            .child("ghosthub — workspace")
                            .child(draft.theme.title()),
                    )
                    .child(
                        div()
                            .px_4()
                            .py_3()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .font_family(font_family)
                            .text_size(px(font_size))
                            .text_color(rgb(foreground))
                            .child(
                                div()
                                    .flex()
                                    .gap_2()
                                    .child(div().text_color(rgb(accent)).child("~/ghosthub"))
                                    .child("on rust-port"),
                            )
                            .child("❯ cargo test --workspace")
                            .child(
                                div()
                                    .text_color(rgb(accent))
                                    .child("   Compiling ghosthub-ui v0.0.0"),
                            )
                            .child("   Finished test profile in 2.14s")
                            .child("   248 tests passed")
                            .child(
                                div()
                                    .flex()
                                    .gap_1()
                                    .child(div().text_color(rgb(accent)).child("❯"))
                                    .child("▏"),
                            ),
                    ),
            )
            .into_any_element()
    }

    fn settings_sidebar(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let active = self
            .settings_dialog
            .as_ref()
            .map_or(SettingsPane::Appearance, |dialog| dialog.pane);
        let mut panes = div().flex().flex_col().gap_1();
        for (index, pane) in SettingsPane::ALL.into_iter().enumerate() {
            panes = panes.child(
                div()
                    .id(("settings-pane", index))
                    .h(px(34.0))
                    .px_3()
                    .flex()
                    .items_center()
                    .gap_2()
                    .rounded_md()
                    .cursor_pointer()
                    .bg(rgb(if pane == active { 0x25_2d3a } else { 0x13_161c }))
                    .text_color(rgb(if pane == active { 0xe1_e5ec } else { 0xa0_a7b3 }))
                    .child("▣")
                    .child(pane.title())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(dialog) = &mut this.settings_dialog {
                            dialog.pane = pane;
                            dialog.error = None;
                        }
                        cx.notify();
                    })),
            );
        }
        div()
            .w(px(188.0))
            .h_full()
            .flex_none()
            .px_3()
            .py_4()
            .border_r_1()
            .border_color(rgb(0x2a_2f39))
            .bg(rgb(0x11_141a))
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .px_2()
                    .text_xs()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(0x78_808e))
                    .child("SETTINGS"),
            )
            .child(panes)
            .into_any_element()
    }

    #[allow(clippy::too_many_lines)] // Declarative GPUI host-list hierarchy.
    fn settings_host_list(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let hosts = self.workspace.configured_ssh_hosts();
        let selected = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.selected_host_id.as_deref());
        let mut rows = div()
            .id("settings-host-list")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .py_1();
        if hosts.is_empty() {
            rows = rows.child(
                div()
                    .px_3()
                    .py_4()
                    .text_sm()
                    .text_color(rgb(0x78_808e))
                    .child("No SSH hosts configured."),
            );
        }
        for (index, host) in hosts.into_iter().enumerate() {
            let is_selected = selected == Some(host.id());
            let target = host.clone();
            rows = rows.child(
                div()
                    .id(("settings-host-row", index))
                    .px_3()
                    .py_2()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .cursor_pointer()
                    .bg(rgb(if is_selected { 0x24_3040 } else { 0x14_171d }))
                    .hover(|style| style.bg(rgb(0x20_2630)))
                    .child(
                        div()
                            .text_sm()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(rgb(0xd7_dbe3))
                            .child(host.draft().name.clone()),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(0x7f_8794))
                            .child(ssh_host_subtitle(host.draft())),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.select_ssh_host(&target, window, cx);
                    })),
            );
        }

        let selected_host = self.settings_dialog.as_ref().and_then(|dialog| {
            let selected = dialog.selected_host_id.as_deref()?;
            self.workspace
                .configured_ssh_hosts()
                .into_iter()
                .find(|host| host.id() == selected)
        });
        let mut footer = div()
            .h(px(42.0))
            .px_3()
            .flex()
            .items_center()
            .justify_between()
            .border_t_1()
            .border_color(rgb(0x2a_2f39));
        if let Some(host) = selected_host {
            footer = footer.child(
                div()
                    .id("remove-selected-ssh-host")
                    .px_2()
                    .py_1()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_xs()
                    .text_color(rgb(0xd0_7070))
                    .hover(|style| style.bg(rgb(0x35_2228)))
                    .child("Remove")
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if let Some(dialog) = &mut this.settings_dialog {
                            dialog.pending_remove = Some(host.clone());
                            dialog.error = None;
                        }
                        window.focus(&this.settings_focus);
                        cx.notify();
                    })),
            );
        }
        footer = footer.child(
            div()
                .id("add-ssh-host")
                .px_2()
                .py_1()
                .rounded_sm()
                .cursor_pointer()
                .text_xs()
                .bg(rgb(0x1d_5f9a))
                .child("Add Host")
                .on_click(cx.listener(|this, _, window, cx| {
                    this.add_ssh_host(window, cx);
                })),
        );

        div()
            .w(px(248.0))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .border_r_1()
            .border_color(rgb(0x2a_2f39))
            .bg(rgb(0x14_171d))
            .child(
                div()
                    .h(px(42.0))
                    .px_3()
                    .flex()
                    .items_center()
                    .border_b_1()
                    .border_color(rgb(0x2a_2f39))
                    .text_xs()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(0x8f_96_a3))
                    .child("SSH HOSTS"),
            )
            .child(rows)
            .child(footer)
            .into_any_element()
    }

    fn settings_host_editor(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let Some(editor) = self
            .settings_dialog
            .as_ref()
            .and_then(|dialog| dialog.host_editor.as_ref())
        else {
            return div()
                .flex_1()
                .h_full()
                .flex()
                .items_center()
                .justify_center()
                .text_sm()
                .text_color(rgb(0x78_808e))
                .child("Select a host or add a new one.")
                .into_any_element();
        };

        let heading = if editor.original_id.is_some() {
            "SSH Tmux Host"
        } else {
            "New SSH Host"
        };
        let mut form = div()
            .w_full()
            .max_w(px(620.0))
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_lg()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(heading),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(rgb(0x8f_96_a3))
                    .child("Ghosthub connects through the system OpenSSH client and KWT."),
            )
            .child(self.ssh_field_row("Name", SshField::Name, &editor.draft, cx))
            .child(self.ssh_field_row("Host", SshField::Hostname, &editor.draft, cx))
            .child(
                div()
                    .flex()
                    .gap_3()
                    .child(div().flex_1().child(self.ssh_field_row(
                        "User",
                        SshField::User,
                        &editor.draft,
                        cx,
                    )))
                    .child(div().w(px(150.0)).child(self.ssh_field_row(
                        "Port",
                        SshField::Port,
                        &editor.draft,
                        cx,
                    ))),
            )
            .child(self.ssh_field_row("Tmux path", SshField::TmuxBinary, &editor.draft, cx))
            .child(self.ssh_field_row(
                "Tmux socket directory",
                SshField::SocketDirectory,
                &editor.draft,
                cx,
            ));
        if let Some(error) = &editor.error {
            form = form.child(
                div()
                    .text_xs()
                    .text_color(rgb(0xd0_7070))
                    .child(error.clone()),
            );
        }
        form = form.child(
            div().pt_2().flex().justify_end().child(
                div()
                    .id("save-ssh-host")
                    .px_4()
                    .py_2()
                    .rounded_md()
                    .cursor_pointer()
                    .bg(rgb(0x1d_5f9a))
                    .child("Save Host")
                    .on_click(cx.listener(|this, _, _, cx| this.save_ssh_host(cx))),
            ),
        );

        div()
            .id("settings-host-editor")
            .flex_1()
            .min_w_0()
            .h_full()
            .overflow_y_scroll()
            .px_6()
            .py_5()
            .child(form)
            .into_any_element()
    }

    fn settings_remove_confirmation(&self, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let dialog = self.settings_dialog.as_ref()?;
        let host = dialog.pending_remove.as_ref()?;
        let mut body = div()
            .px_4()
            .py_4()
            .flex()
            .flex_col()
            .gap_2()
            .text_sm()
            .child(format!("Remove “{}” from Ghosthub?", host.draft().name))
            .child(
                div()
                    .text_xs()
                    .text_color(rgb(0x8f_96_a3))
                    .child("Any open terminal client for this host will detach."),
            );
        if let Some(error) = &dialog.error {
            body = body.child(
                div()
                    .text_xs()
                    .text_color(rgb(0xd0_7070))
                    .child(error.clone()),
            );
        }
        Some(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x00_00_00_a0))
                .child(
                    div()
                        .id("remove-ssh-host-confirmation")
                        .w(px(440.0))
                        .rounded_lg()
                        .border_1()
                        .border_color(rgb(0x36_3c48))
                        .bg(rgb(0x18_1b22))
                        .shadow_lg()
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_b_1()
                                .border_color(rgb(0x2a_2f39))
                                .font_weight(FontWeight::SEMIBOLD)
                                .child("Remove SSH Host"),
                        )
                        .child(body)
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_t_1()
                                .border_color(rgb(0x2a_2f39))
                                .flex()
                                .justify_end()
                                .gap_2()
                                .child(
                                    div()
                                        .id("cancel-remove-ssh-host")
                                        .px_3()
                                        .py_1()
                                        .cursor_pointer()
                                        .child("Cancel")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            if let Some(dialog) = &mut this.settings_dialog {
                                                dialog.pending_remove = None;
                                                dialog.error = None;
                                            }
                                            cx.notify();
                                        })),
                                )
                                .child(
                                    div()
                                        .id("confirm-remove-ssh-host")
                                        .px_3()
                                        .py_1()
                                        .rounded_sm()
                                        .cursor_pointer()
                                        .bg(rgb(0x7a_3038))
                                        .child("Remove")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.remove_ssh_host(cx);
                                        })),
                                ),
                        ),
                )
                .into_any_element(),
        )
    }

    #[allow(clippy::too_many_lines)] // Declarative GPUI settings-shell hierarchy.
    fn settings_overlay(
        &self,
        _window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let dialog = self.settings_dialog.as_ref()?;
        let pane = dialog.pane;
        let detail = match pane {
            SettingsPane::Appearance => self.settings_appearance_editor(cx),
            SettingsPane::Hosts => div()
                .flex_1()
                .min_h_0()
                .flex()
                .child(self.settings_host_list(cx))
                .child(self.settings_host_editor(cx))
                .into_any_element(),
        };
        let pane_header = div()
            .px_6()
            .py_4()
            .flex_none()
            .flex()
            .items_center()
            .justify_between()
            .border_b_1()
            .border_color(rgb(0x2a_2f39))
            .child(
                div()
                    .child(
                        div()
                            .text_2xl()
                            .font_weight(FontWeight::BOLD)
                            .child(pane.title()),
                    )
                    .child(
                        div()
                            .pt_1()
                            .text_sm()
                            .text_color(rgb(0x8f_96_a3))
                            .child(pane.subtitle()),
                    ),
            );
        let confirmation = self.settings_remove_confirmation(cx);

        Some(
            div()
                .absolute()
                .inset_0()
                .bg(rgba(0x00_00_00_80))
                .child(
                    div()
                        .id("settings-shell")
                        .track_focus(&self.settings_focus)
                        .absolute()
                        .left(px(24.0))
                        .right(px(24.0))
                        .top(px(24.0))
                        .bottom(px(24.0))
                        .flex()
                        .flex_col()
                        .overflow_hidden()
                        .rounded_lg()
                        .border_1()
                        .border_color(rgb(0x36_3c48))
                        .bg(rgb(0x18_1b22))
                        .shadow_lg()
                        .on_key_down(cx.listener(|this, event, window, cx| {
                            this.on_settings_key_down(event, window, cx);
                        }))
                        .child(
                            div()
                                .h(px(50.0))
                                .px_4()
                                .flex_none()
                                .flex()
                                .items_center()
                                .justify_between()
                                .border_b_1()
                                .border_color(rgb(0x2a_2f39))
                                .child(
                                    div()
                                        .text_lg()
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .child("Settings"),
                                )
                                .child(
                                    div()
                                        .id("close-settings")
                                        .px_3()
                                        .py_1()
                                        .rounded_sm()
                                        .cursor_pointer()
                                        .hover(|style| style.bg(rgb(0x25_2a34)))
                                        .child("Done")
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.close_settings(window, cx);
                                        })),
                                ),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_h_0()
                                .flex()
                                .child(self.settings_sidebar(cx))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .flex()
                                        .flex_col()
                                        .child(pane_header)
                                        .child(detail),
                                ),
                        )
                        .children(confirmation),
                )
                .into_any_element(),
        )
    }

    #[allow(clippy::too_many_lines)] // Declarative GPUI SSH prompt hierarchy.
    fn ssh_prompt_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let prompt = self.ssh_prompts.front()?;
        let sensitive = prompt.request.sensitive();
        let focused = self.ssh_prompt_focus.is_focused(window);
        let displayed = if sensitive {
            ssh_prompt_input_text(&prompt.value, focused)
        } else {
            String::new()
        };
        let mut body = div()
            .px_4()
            .py_4()
            .flex()
            .flex_col()
            .gap_3()
            .text_sm()
            .child(prompt.request.message().to_owned())
            .child(
                div()
                    .text_xs()
                    .text_color(rgb(0x8f_96_a3))
                    .child(prompt.request.display_target().to_owned()),
            );
        if let Some(host_key) = prompt.request.host_key() {
            body = body.child(
                div()
                    .p_3()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .rounded_md()
                    .border_1()
                    .border_color(rgb(0x3a_404c))
                    .bg(rgb(0x0f_1218))
                    .child(host_key.host().to_owned())
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(0x8f_96_a3))
                            .child(host_key.algorithm().to_owned()),
                    )
                    .child(
                        div()
                            .font_family("monospace")
                            .text_xs()
                            .child(host_key.fingerprint().to_owned()),
                    ),
            );
        }
        if sensitive {
            body = body.child(
                div()
                    .id("ssh-prompt-input")
                    .h(px(38.0))
                    .px_3()
                    .flex()
                    .items_center()
                    .rounded_md()
                    .border_1()
                    .border_color(rgb(if focused { 0x4a_8f_cf } else { 0x3a_404c }))
                    .bg(rgb(0x0f_1218))
                    .cursor_text()
                    .text_color(rgb(if prompt.value.is_empty() && !focused {
                        0x72_7986
                    } else {
                        0xe1_e5ec
                    }))
                    .child(displayed)
                    .on_click(cx.listener(|this, _, window, cx| {
                        window.focus(&this.ssh_prompt_focus);
                        cx.notify();
                    })),
            );
        }
        Some(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x00_00_00_a0))
                .child(
                    div()
                        .id("ssh-prompt-dialog")
                        .track_focus(&self.ssh_prompt_focus)
                        .w(px(520.0))
                        .flex()
                        .flex_col()
                        .rounded_lg()
                        .border_1()
                        .border_color(rgb(0x36_3c48))
                        .bg(rgb(0x18_1b22))
                        .shadow_lg()
                        .on_key_down(cx.listener(|this, event, window, cx| {
                            this.on_ssh_prompt_key_down(event, window, cx);
                        }))
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_b_1()
                                .border_color(rgb(0x2a_2f39))
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(if sensitive {
                                    "Authenticate SSH Connection"
                                } else {
                                    "Verify SSH Host"
                                }),
                        )
                        .child(body)
                        .child(
                            div()
                                .px_4()
                                .py_3()
                                .border_t_1()
                                .border_color(rgb(0x2a_2f39))
                                .flex()
                                .justify_end()
                                .gap_2()
                                .child(
                                    div()
                                        .id("cancel-ssh-prompt")
                                        .px_3()
                                        .py_1()
                                        .cursor_pointer()
                                        .child("Cancel")
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.cancel_ssh_prompt(window, cx);
                                        })),
                                )
                                .child(
                                    div()
                                        .id("submit-ssh-prompt")
                                        .px_3()
                                        .py_1()
                                        .rounded_sm()
                                        .cursor_pointer()
                                        .bg(rgb(0x1d_5f9a))
                                        .child(if sensitive { "Continue" } else { "Trust Host" })
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.submit_ssh_prompt(window, cx);
                                        })),
                                ),
                        ),
                )
                .into_any_element(),
        )
    }

    fn session_kill_overlay(
        &self,
        confirmation: &workspace::SessionKillConfirmation,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let title = kill_confirmation_title(confirmation.selection());
        let description = kill_confirmation_description(confirmation.selection());
        div()
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(rgba(0x00_00_00_80))
            .child(
                div()
                    .id("kill-session-dialog")
                    .track_focus(&self.kill_focus)
                    .w(px(460.0))
                    .flex()
                    .flex_col()
                    .rounded_lg()
                    .border_1()
                    .border_color(rgb(0x36_3c48))
                    .bg(rgb(0x18_1b22))
                    .shadow_lg()
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key.eq_ignore_ascii_case("escape") && !event.is_held {
                            this.cancel_session_kill(window, cx);
                            cx.stop_propagation();
                        }
                    }))
                    .child(
                        div()
                            .px_4()
                            .py_3()
                            .border_b_1()
                            .border_color(rgb(0x2a_2f39))
                            .text_sm()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(rgb(0xe0_e4eb))
                            .child(title),
                    )
                    .child(
                        div()
                            .px_4()
                            .py_4()
                            .text_sm()
                            .text_color(rgb(0xb6_bcc7))
                            .child(description),
                    )
                    .child(
                        div()
                            .px_4()
                            .py_3()
                            .border_t_1()
                            .border_color(rgb(0x2a_2f39))
                            .flex()
                            .items_center()
                            .justify_end()
                            .gap_2()
                            .child(
                                div()
                                    .id("cancel-kill-session")
                                    .px_3()
                                    .py_1()
                                    .rounded_sm()
                                    .cursor_pointer()
                                    .text_sm()
                                    .text_color(rgb(0xb6_bcc7))
                                    .hover(|style| style.bg(rgb(0x29_2e38)))
                                    .child("Cancel")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.cancel_session_kill(window, cx);
                                    })),
                            )
                            .child(
                                div()
                                    .id("confirm-kill-session")
                                    .px_3()
                                    .py_1()
                                    .rounded_sm()
                                    .cursor_pointer()
                                    .bg(rgb(0xa9_3038))
                                    .hover(|style| style.bg(rgb(0xc1_3b43)))
                                    .text_sm()
                                    .text_color(rgb(0xff_f6f6))
                                    .child("Kill Session")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.confirm_session_kill(window, cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    fn pending_session_kill_overlay(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let confirmation = self.workspace.session_kill_confirmation()?;
        if !self.kill_focus.is_focused(window) {
            window.focus(&self.kill_focus);
        }
        Some(self.session_kill_overlay(&confirmation, cx))
    }

    fn herdr_lifecycle_overlay(
        &self,
        confirmation: &workspace::HerdrLifecycleConfirmation,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let (verb, title, description) = herdr_lifecycle_copy(confirmation);
        div()
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(rgba(0x00_00_00_80))
            .child(
                div()
                    .id("herdr-lifecycle-dialog")
                    .track_focus(&self.kill_focus)
                    .w(px(460.0))
                    .flex()
                    .flex_col()
                    .rounded_lg()
                    .border_1()
                    .border_color(rgb(0x36_3c48))
                    .bg(rgb(0x18_1b22))
                    .shadow_lg()
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key.eq_ignore_ascii_case("escape") && !event.is_held {
                            this.cancel_herdr_lifecycle(window, cx);
                            cx.stop_propagation();
                        }
                    }))
                    .child(
                        div()
                            .px_4()
                            .py_3()
                            .border_b_1()
                            .border_color(rgb(0x2a_2f39))
                            .text_sm()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(rgb(0xe0_e4eb))
                            .child(title),
                    )
                    .child(
                        div()
                            .px_4()
                            .py_4()
                            .text_sm()
                            .text_color(rgb(0xb6_bcc7))
                            .child(description),
                    )
                    .child(
                        div()
                            .px_4()
                            .py_3()
                            .border_t_1()
                            .border_color(rgb(0x2a_2f39))
                            .flex()
                            .items_center()
                            .justify_end()
                            .gap_2()
                            .child(
                                div()
                                    .id("cancel-herdr-lifecycle")
                                    .px_3()
                                    .py_1()
                                    .rounded_sm()
                                    .cursor_pointer()
                                    .text_sm()
                                    .text_color(rgb(0xb6_bcc7))
                                    .hover(|style| style.bg(rgb(0x29_2e38)))
                                    .child("Cancel")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.cancel_herdr_lifecycle(window, cx);
                                    })),
                            )
                            .child(
                                div()
                                    .id("confirm-herdr-lifecycle")
                                    .px_3()
                                    .py_1()
                                    .rounded_sm()
                                    .cursor_pointer()
                                    .bg(rgb(0xa9_3038))
                                    .hover(|style| style.bg(rgb(0xc1_3b43)))
                                    .text_sm()
                                    .text_color(rgb(0xff_f6f6))
                                    .child(verb)
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.confirm_herdr_lifecycle(window, cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    fn pending_herdr_lifecycle_overlay(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let confirmation = self.workspace.herdr_lifecycle_confirmation()?;
        if !self.kill_focus.is_focused(window) {
            window.focus(&self.kill_focus);
        }
        Some(self.herdr_lifecycle_overlay(&confirmation, cx))
    }

    fn session_action_menu_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let menu = self.session_action_menu.clone()?;
        let bounds = window.bounds();
        let (left, top) = session_action_menu_position(
            menu.anchor_x,
            menu.anchor_y,
            f32::from(bounds.size.width),
            f32::from(bounds.size.height),
            menu.actions.len(),
        );
        let mut items = div()
            .id("session-action-menu")
            .absolute()
            .left(px(left))
            .top(px(top))
            .w(px(SESSION_ACTION_MENU_WIDTH))
            .py_1()
            .rounded_md()
            .border_1()
            .border_color(rgb(0x36_3c48))
            .bg(rgb(0x1b_1f27))
            .shadow_lg()
            .on_mouse_down(GpuiMouseButton::Left, |_, _, cx| cx.stop_propagation());
        for action in menu.actions {
            items = items.child(Self::session_action_menu_item(
                menu.selection.clone(),
                action,
                cx,
            ));
        }
        Some(
            div()
                .absolute()
                .inset_0()
                .on_mouse_down(
                    GpuiMouseButton::Left,
                    cx.listener(|this, _, _, cx| {
                        this.session_action_menu = None;
                        cx.notify();
                    }),
                )
                .child(items)
                .into_any_element(),
        )
    }

    fn session_action_menu_item(
        selection: SessionSelection,
        action: SessionRowAction,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let (id, label, color) = match &action {
            SessionRowAction::Detach => ("session-action-detach", "Detach", 0x87_b9e8),
            SessionRowAction::KillSession => ("session-action-kill", "Kill", 0xd6_747a),
            SessionRowAction::RemoveWorktree(_) => {
                ("worktree-action-remove", "Remove Worktree", 0xd6_747a)
            }
            SessionRowAction::Herdr(HerdrRowAction::Stop) => {
                ("herdr-action-stop", "Stop", 0xd6_747a)
            }
            SessionRowAction::Herdr(HerdrRowAction::Restart) => {
                ("herdr-action-restart", "Restart", 0x87_b9e8)
            }
            SessionRowAction::Herdr(HerdrRowAction::Delete) => {
                ("herdr-action-delete", "Delete", 0xd6_747a)
            }
        };
        div()
            .id(id)
            .mx_1()
            .h(px(26.0))
            .px_2()
            .flex()
            .items_center()
            .rounded_sm()
            .cursor_pointer()
            .text_sm()
            .text_color(rgb(color))
            .hover(|style| style.bg(rgb(0x2a_2f39)))
            .child(label)
            .on_click(cx.listener(move |this, _, window, cx| {
                this.session_action_menu = None;
                match &action {
                    SessionRowAction::Detach => this.detach_session(window, cx),
                    SessionRowAction::KillSession => this.request_session_kill(&selection, cx),
                    SessionRowAction::RemoveWorktree(target) => {
                        this.open_remove_worktree(target.as_ref().clone(), window, cx);
                    }
                    SessionRowAction::Herdr(HerdrRowAction::Stop) => this.request_herdr_lifecycle(
                        &selection,
                        workspace::HerdrLifecycleAction::Stop,
                        cx,
                    ),
                    SessionRowAction::Herdr(HerdrRowAction::Restart) => {
                        this.restart_herdr_session(&selection, window, cx);
                    }
                    SessionRowAction::Herdr(HerdrRowAction::Delete) => this
                        .request_herdr_lifecycle(
                            &selection,
                            workspace::HerdrLifecycleAction::Delete,
                            cx,
                        ),
                }
                cx.stop_propagation();
            }))
            .into_any_element()
    }

    fn synchronize_render_state(&mut self, snapshot: &workspace::WorkspaceSnapshot) {
        self.observed_revision = snapshot.revision();
        self.terminal_notice.synchronize(
            terminal_presentation_id(snapshot.content()),
            snapshot.notice(),
            snapshot.notice_is_transient(),
            Instant::now(),
        );
        if !matches!(snapshot.content(), WorkspaceContent::Terminal { .. }) {
            self.observed_surface_identity = None;
            self.observed_surface_generation = 0;
            self.paint_cache.clear();
        }
    }

    fn new_session_name_input(
        draft: &NewSessionDraft,
        focused: bool,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let input_text = if draft.name.is_empty() && focused {
            "▏".to_owned()
        } else if draft.name.is_empty() {
            "Session name".to_owned()
        } else {
            format!("{}▏", draft.name)
        };
        div()
            .id("new-session-name-input")
            .m_4()
            .px_3()
            .h(px(38.0))
            .flex()
            .items_center()
            .rounded_md()
            .border_1()
            .border_color(rgb(if focused { 0x4a_8f_cf } else { 0x3a_404c }))
            .bg(rgb(0x0f_1218))
            .cursor_text()
            .text_sm()
            .text_color(rgb(if draft.name.is_empty() && !focused {
                0x72_7986
            } else {
                0xe1_e5ec
            }))
            .child(
                div()
                    .mr_2()
                    .flex_none()
                    .text_xs()
                    .text_color(rgb(0x72_7986))
                    .child(">_"),
            )
            .child(input_text)
            .on_click(cx.listener(|this, _, window, cx| {
                window.focus(&this.create_focus);
                cx.notify();
            }))
            .into_any_element()
    }

    fn new_session_actions(can_create: bool, cx: &mut Context<Self>) -> gpui::AnyElement {
        div()
            .px_4()
            .py_3()
            .border_t_1()
            .border_color(rgb(0x2a_2f39))
            .flex()
            .items_center()
            .justify_end()
            .gap_2()
            .child(
                div()
                    .id("cancel-new-session")
                    .px_3()
                    .py_1()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_sm()
                    .text_color(rgb(0xb6_bcc7))
                    .hover(|style| style.bg(rgb(0x29_2e38)))
                    .child("Cancel")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.cancel_new_session(window, cx);
                    })),
            )
            .child(
                div()
                    .id("create-new-session")
                    .px_3()
                    .py_1()
                    .rounded_sm()
                    .bg(rgb(if can_create { 0x1d_5f9a } else { 0x2b_3039 }))
                    .text_sm()
                    .text_color(rgb(if can_create { 0xf1_f5fa } else { 0x72_7986 }))
                    .child("Create")
                    .when(can_create, |element| {
                        element
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.submit_new_session(window, cx);
                            }))
                    }),
            )
            .into_any_element()
    }

    fn workspace_tree(
        &self,
        snapshot: &workspace::WorkspaceSnapshot,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let active = snapshot
            .active_selection()
            .cloned()
            .or_else(|| active_session_selection(snapshot.content()));
        let mut body = div()
            .id("workspace-tree-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .overflow_x_hidden();
        for (host_index, host) in snapshot.hosts().iter().enumerate() {
            body = body.child(self.host_tree(
                host_index,
                host,
                snapshot.selected_host() == Some(host.id()),
                active.as_ref(),
                snapshot.retained_selections(),
                cx,
            ));
        }

        div()
            .w(px(APP_NAVIGATION_WIDTH))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .bg(rgb(APP_CHROME_BACKGROUND))
            .border_r_1()
            .border_color(rgb(0x25_2932))
            .child(
                div()
                    .h(px(NAVIGATION_HEADER_HEIGHT))
                    .flex_none()
                    .flex()
                    .items_center()
                    .px_2()
                    .border_b_1()
                    .border_color(rgb(0x1d_2028))
                    .text_xs()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(0xa5_ac_b8))
                    .child("WORKSPACES"),
            )
            .child(body)
            .into_any_element()
    }

    fn host_tree(
        &self,
        host_index: usize,
        host: &HostItem,
        is_selected: bool,
        active: Option<&SessionSelection>,
        retained: &[SessionSelection],
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let mut host_tree =
            div()
                .flex()
                .flex_col()
                .child(Self::host_header(host_index, host, is_selected, cx));

        let sessions = tree_sessions(host, active, retained);
        let herdr_sessions = tree_herdr_sessions(host, active, retained);
        let zellij_sessions = tree_zellij_sessions(host, active, retained);
        let groups = session_group_visibility(host, &herdr_sessions, &zellij_sessions);
        if groups.tmux {
            host_tree = host_tree.child(
                self.session_tree(
                    host_index,
                    host,
                    &sessions,
                    NewSessionKind::Tmux,
                    host.tmux_diagnostic()
                        .map(|diagnostic| diagnostic.message().to_owned()),
                    cx,
                ),
            );
        }
        if groups.herdr {
            host_tree = host_tree.child(self.herdr_tree(host_index, host, &herdr_sessions, cx));
        }
        if groups.zellij {
            host_tree = host_tree.child(
                self.session_tree(
                    host_index,
                    host,
                    &zellij_sessions,
                    NewSessionKind::Zellij,
                    host.zellij_diagnostic()
                        .map(|diagnostic| diagnostic.message().to_owned()),
                    cx,
                ),
            );
        }
        if host.kwt_available()
            || !host.projects().is_empty()
            || !host.directory_workspaces().is_empty()
            || host.kwt_diagnostic().is_some()
        {
            host_tree = host_tree.child(Self::project_tree(host_index, host, active, retained, cx));
        }
        host_tree.into_any_element()
    }

    fn host_header(
        host_index: usize,
        host: &HostItem,
        is_selected: bool,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let status_color = match host.connection() {
            HostConnectionState::Ready => 0x62_c0_7a,
            HostConnectionState::Connecting => 0xd3_a4_4a,
            HostConnectionState::Disconnected => 0x8f_96_a3,
            HostConnectionState::Unavailable => 0xd0_65_65,
        };
        let mut host_header = div()
            .id(("host", host_index))
            .h(px(HOST_ROW_HEIGHT))
            .flex()
            .items_center()
            .gap_1()
            .px_2()
            .border_b_1()
            .border_color(rgb(0x20_242c))
            .bg(rgb(if is_selected { 0x18_1b22 } else { 0x14_171d }))
            .child(
                div()
                    .w(px(12.0))
                    .flex_none()
                    .text_center()
                    .text_color(rgb(0x6f_7682))
                    .child("▾"),
            )
            .child(
                div()
                    .size(px(7.0))
                    .flex_none()
                    .rounded_full()
                    .bg(rgb(status_color)),
            )
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .truncate()
                    .text_sm()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(0xd2_d7_df))
                    .child(host.name().to_owned()),
            );
        let select_host_id = host.id().to_owned();
        host_header = host_header
            .cursor_pointer()
            .on_click(cx.listener(move |this, _, _, cx| {
                if let Err(error) = this.workspace.select_host(&select_host_id) {
                    this.diagnostic = Some(error.to_string());
                }
                cx.notify();
            }));
        let host_id = host.id().to_owned();
        let action = host_header_action(host.connection());
        host_header = host_header.child(
            div()
                .id((action.element_id(), host_index))
                .flex_none()
                .h(px(24.0))
                .min_w(px(24.0))
                .px_1()
                .flex()
                .items_center()
                .justify_center()
                .rounded_sm()
                .cursor_pointer()
                .text_xs()
                .text_color(rgb(0x8f_96_a3))
                .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xd2_d7_df)))
                .child(action.label())
                .on_click(cx.listener(move |this, _, _, cx| match action {
                    HostHeaderAction::Cancel => this.cancel_host_connection(&host_id, cx),
                    HostHeaderAction::Connect
                    | HostHeaderAction::Refresh
                    | HostHeaderAction::Retry => this.connect_host(&host_id, cx),
                })),
        );
        host_header.into_any_element()
    }

    fn session_tree(
        &self,
        host_index: usize,
        host: &HostItem,
        sessions: &[TreeSession],
        create_kind: NewSessionKind,
        diagnostic: Option<String>,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let group = create_kind.group();
        let group_key = SessionGroupKey {
            host_id: host.id().to_owned(),
            group,
        };
        let collapsed = self.collapsed_session_groups.contains(&group_key);
        let mut tree = div().w_full().flex().flex_col().child({
            let mut header = div()
                .h(px(SESSION_GROUP_ROW_HEIGHT))
                .flex()
                .items_center()
                .pl(px(SESSION_GROUP_INSET))
                .pr_1()
                .bg(rgb(SESSION_GROUP_BACKGROUND))
                .text_xs()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(rgb(SESSION_GROUP_TEXT))
                .child(Self::session_group_toggle(
                    host_index,
                    host.id(),
                    group,
                    collapsed,
                    cx,
                ))
                .child(div().flex_1().child(create_kind.group_title()));
            if session_creation_available(host, create_kind) {
                let host_id = host.id().to_owned();
                let endpoint = host.endpoint().to_owned();
                header = header.child(
                    div()
                        .id((
                            if create_kind == NewSessionKind::Tmux {
                                "create-tmux-session"
                            } else {
                                "create-zellij-session"
                            },
                            host_index,
                        ))
                        .size(px(22.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_sm()
                        .cursor_pointer()
                        .text_sm()
                        .text_color(rgb(0x8f_96_a3))
                        .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xd2_d7_df)))
                        .child("+")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open_new_session(&host_id, &endpoint, create_kind, window, cx);
                        })),
                );
            }
            header
        });
        if collapsed {
            return tree.into_any_element();
        }
        if let Some(message) = diagnostic {
            let retry_id = match create_kind {
                NewSessionKind::Tmux => "retry-tmux",
                NewSessionKind::Herdr => "retry-herdr",
                NewSessionKind::Zellij => "retry-zellij",
            };
            tree = tree.child(Self::capability_diagnostic_row(
                host_index,
                host.id(),
                retry_id,
                message,
                cx,
            ));
        } else if sessions.is_empty() {
            tree = tree.child(
                div()
                    .h(px(SESSION_ROW_HEIGHT))
                    .flex()
                    .items_center()
                    .pl(px(SESSION_ROW_INSET))
                    .text_xs()
                    .text_color(rgb(0x73_7a87))
                    .child("No sessions"),
            );
        }
        for (session_index, session) in sessions.iter().enumerate() {
            tree = tree.child(Self::tree_session_row(
                host_index,
                session_index,
                session,
                cx,
            ));
        }
        tree.into_any_element()
    }

    fn session_group_toggle(
        host_index: usize,
        host_id: &str,
        group: SessionGroup,
        collapsed: bool,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let host_id = host_id.to_owned();
        div()
            .id((group.element_id(), host_index))
            .size(px(20.0))
            .mr_1()
            .flex()
            .items_center()
            .justify_center()
            .rounded_sm()
            .cursor_pointer()
            .text_xs()
            .text_color(rgb(0x8f_96_a3))
            .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xd2_d7_df)))
            .child(if collapsed { "▸" } else { "▾" })
            .on_click(cx.listener(move |this, _, _, cx| {
                toggle_session_group_state(&mut this.collapsed_session_groups, &host_id, group);
                this.session_action_menu = None;
                cx.notify();
            }))
            .into_any_element()
    }

    #[allow(clippy::too_many_lines)] // Declarative GPUI tree hierarchy.
    fn project_tree(
        host_index: usize,
        host: &HostItem,
        active: Option<&SessionSelection>,
        retained: &[SessionSelection],
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let can_add = host.can_add_kwt_project();
        let can_remove = host.can_remove_kwt_project();
        let mut tree = div().w_full().flex().flex_col().child({
            let mut header = div()
                .h(px(SESSION_GROUP_ROW_HEIGHT))
                .flex()
                .items_center()
                .pl(px(SESSION_GROUP_INSET))
                .pr_1()
                .bg(rgb(SESSION_GROUP_BACKGROUND))
                .text_xs()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(rgb(SESSION_GROUP_TEXT))
                .child(div().flex_1().child("PROJECTS"));
            if host.kwt_refreshing() {
                header = header.child(
                    div()
                        .px_1()
                        .text_xs()
                        .text_color(rgb(0x6f_7682))
                        .child(if host.kwt_mutating() { "…" } else { "↻" }),
                );
            }
            if can_add {
                let host_id = host.id().to_owned();
                let endpoint = host.endpoint().to_owned();
                header = header.child(
                    div()
                        .id(("add-kwt-project", host_index))
                        .size(px(22.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_sm()
                        .cursor_pointer()
                        .text_sm()
                        .text_color(rgb(0x8f_96_a3))
                        .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xd2_d7_df)))
                        .child("+")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open_add_project(&host_id, &endpoint, window, cx);
                        })),
                );
            }
            header
        });
        for (project_index, project) in host.projects().iter().enumerate() {
            let project_for_remove = project.clone();
            let project_for_create = project.clone();
            let host_id = host.id().to_owned();
            let endpoint = host.endpoint().to_owned();
            let mut row = div()
                .h(px(SESSION_ROW_HEIGHT))
                .flex()
                .items_center()
                .gap_1()
                .pl(px(SESSION_ROW_INSET))
                .pr_2()
                .text_sm()
                .text_color(rgb(0xb9_bfca))
                .child(
                    div()
                        .w(px(18.0))
                        .flex_none()
                        .text_xs()
                        .text_color(rgb(0x7f_8794))
                        .child("▾"),
                )
                .child(
                    div()
                        .min_w_0()
                        .flex_1()
                        .truncate()
                        .child(project.name().to_owned()),
                );
            if can_remove {
                let create_host_id = host_id.clone();
                let create_endpoint = endpoint.clone();
                row = row.child(
                    div()
                        .id(("create-kwt-worktree", project_index))
                        .size(px(22.0))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_sm()
                        .cursor_pointer()
                        .text_sm()
                        .text_color(rgb(0x7f_8794))
                        .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xd2_d7_df)))
                        .child("+")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open_new_worktree(
                                &create_host_id,
                                &create_endpoint,
                                &project_for_create,
                                window,
                                cx,
                            );
                        })),
                );
            }
            if can_remove {
                row = row.child(
                    div()
                        .id(("remove-kwt-project", project_index))
                        .size(px(22.0))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_sm()
                        .cursor_pointer()
                        .text_sm()
                        .text_color(rgb(0x7f_8794))
                        .hover(|style| style.bg(rgb(0x35_2329)).text_color(rgb(0xd0_7070)))
                        .child("×")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open_remove_project(
                                &host_id,
                                &endpoint,
                                &project_for_remove,
                                window,
                                cx,
                            );
                        })),
                );
            }
            tree = tree.child(row);
            for (worktree_index, worktree) in project.worktrees().iter().enumerate() {
                let selection = worktree
                    .tmux_socket_name()
                    .and_then(|socket| {
                        worktree.generation().map(|generation| {
                            SessionSelection::protected_worktree(
                                host.id(),
                                host.endpoint(),
                                worktree.session_name(),
                                socket,
                                worktree.path(),
                                generation,
                            )
                        })
                    })
                    .unwrap_or_else(|| {
                        SessionSelection::new(host.id(), host.endpoint(), worktree.session_name())
                    });
                let is_active = active == Some(&selection);
                let is_retained = retained.contains(&selection);
                let has_generation = worktree.generation().is_some();
                let host_can_attach = host.accepts_session_actions();
                let authority = if has_generation {
                    WorktreeAuthority::Generation
                } else {
                    WorktreeAuthority::Generationless
                };
                let socket = if worktree.tmux_socket_name().is_some() {
                    WorktreeSocket::Custom
                } else {
                    WorktreeSocket::Default
                };
                let session = if worktree.session_available() {
                    WorktreeSessionPresence::Discovered
                } else {
                    WorktreeSessionPresence::Absent
                };
                let open_mode = worktree_open_mode(WorktreeOpenContext {
                    authority,
                    socket,
                    session,
                    presentation: if is_active || is_retained {
                        WorktreePresentation::ActiveOrRetained
                    } else {
                        WorktreePresentation::Inactive
                    },
                    host: if host_can_attach {
                        WorktreeHostAccess::Ready {
                            kwt_available: host.kwt_available(),
                        }
                    } else {
                        WorktreeHostAccess::Unavailable
                    },
                });
                let can_open = open_mode != WorktreeOpenMode::Disabled;
                let can_kill = can_kill_worktree(host_can_attach, socket, session, authority);
                let open_target = WorktreeOpenTarget {
                    host_id: host.id().to_owned(),
                    endpoint: host.endpoint().to_owned(),
                    repository: project.repository().to_owned(),
                    project_path: project.path().to_owned(),
                    registration_fingerprint: project.registration_fingerprint().to_owned(),
                    worktree_path: worktree.path().to_owned(),
                    generation: worktree.generation().map(str::to_owned),
                    session_name: worktree.session_name().to_owned(),
                    tmux_socket_name: worktree.tmux_socket_name().map(str::to_owned),
                };
                let repair_open_target =
                    (open_mode == WorktreeOpenMode::RepairOrOpen).then(|| open_target.clone());
                let remove_target = (!worktree.is_main()
                    && worktree.generation().is_some()
                    && host.connection() == HostConnectionState::Ready
                    && host.kwt_available()
                    && host.kwt_diagnostic().is_none())
                .then(|| WorktreeRemoveTarget {
                    open: open_target.clone(),
                    project_name: project.name().to_owned(),
                    branch: worktree.branch().to_owned(),
                    session_was_running: worktree.session_available(),
                    authority: None,
                    operation_id: None,
                });
                tree = tree.child(Self::worktree_row(
                    host_index,
                    project_index,
                    worktree_index,
                    worktree.branch().to_owned(),
                    selection,
                    if is_active {
                        WorktreeRowPresence::Active
                    } else if worktree.session_available() || is_retained {
                        WorktreeRowPresence::Live
                    } else {
                        WorktreeRowPresence::Idle
                    },
                    can_open,
                    can_kill,
                    repair_open_target,
                    remove_target,
                    cx,
                ));
            }
        }
        tree.children(Self::directory_workspace_rows(
            host_index, host, active, retained, cx,
        ))
        .into_any_element()
    }

    fn directory_workspace_rows(
        host_index: usize,
        host: &HostItem,
        active: Option<&SessionSelection>,
        retained: &[SessionSelection],
        cx: &mut Context<Self>,
    ) -> Vec<gpui::AnyElement> {
        let mut rows = Vec::new();
        if !host.directory_workspaces().is_empty() {
            rows.push(
                div()
                    .h(px(SESSION_GROUP_ROW_HEIGHT))
                    .flex()
                    .items_center()
                    .pl(px(SESSION_ROW_INSET))
                    .text_xs()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(0x73_7a87))
                    .child("DIRECTORY WORKSPACES")
                    .into_any_element(),
            );
        }
        for (index, workspace) in host.directory_workspaces().iter().enumerate() {
            let selection =
                SessionSelection::new(host.id(), host.endpoint(), workspace.session_name());
            let is_active = active == Some(&selection);
            let is_retained = retained.contains(&selection);
            let can_open = is_active
                || is_retained
                || (workspace.session_available() && host.accepts_session_actions());
            let can_kill = workspace.session_available() && host.accepts_session_actions();
            rows.push(Self::worktree_row(
                host_index,
                usize::MAX,
                index,
                workspace.name().to_owned(),
                selection,
                if is_active {
                    WorktreeRowPresence::Active
                } else if workspace.session_available() || is_retained {
                    WorktreeRowPresence::Live
                } else {
                    WorktreeRowPresence::Idle
                },
                can_open,
                can_kill,
                None,
                None,
                cx,
            ));
        }
        rows
    }

    #[allow(clippy::too_many_arguments)]
    fn worktree_row(
        host_index: usize,
        project_index: usize,
        worktree_index: usize,
        label: String,
        selection: SessionSelection,
        presence: WorktreeRowPresence,
        can_open: bool,
        can_kill: bool,
        worktree_target: Option<WorktreeOpenTarget>,
        remove_target: Option<WorktreeRemoveTarget>,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let is_active = presence.is_active();
        let is_live = presence.is_live();
        let row_group = format!("worktree-actions-{host_index}-{project_index}-{worktree_index}");
        let mut row = div()
            .id((
                gpui::ElementId::named_usize("worktree-host", host_index),
                format!("{project_index}-{worktree_index}"),
            ))
            .group(row_group.clone())
            .mr_1()
            .h(px(SESSION_ROW_HEIGHT))
            .flex()
            .items_center()
            .gap_1()
            .pl(px(NESTED_SESSION_ROW_INSET))
            .pr_2()
            .bg(rgb(if is_active { 0x13_3d6a } else { 0x0f_1116 }))
            .when(can_open, |element| {
                element
                    .cursor_pointer()
                    .hover(|style| style.bg(rgb(if is_active { 0x17_477a } else { 0x1b_1f27 })))
            })
            .when(!can_open, |element| element.opacity(0.55))
            .child(
                div()
                    .w(px(18.0))
                    .flex_none()
                    .text_xs()
                    .text_color(rgb(if is_active {
                        0x9d_c7ed
                    } else if is_live {
                        0x79_c9_a3
                    } else {
                        0x7f_8794
                    }))
                    .child(if is_live { ">_" } else { "◇" }),
            )
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .truncate()
                    .text_sm()
                    .text_color(rgb(if is_active { 0xe5_ed_f7 } else { 0xc4_c9_d2 }))
                    .child(label),
            );
        let mut actions = tmux_row_actions(is_active, can_kill);
        if let Some(target) = remove_target {
            actions.push(SessionRowAction::RemoveWorktree(Box::new(target)));
        }
        if !actions.is_empty() {
            row = row.child(Self::session_action_menu_button(
                host_index,
                format!("worktree-{project_index}-{worktree_index}"),
                selection.clone(),
                actions,
                row_group,
                cx,
            ));
        }
        row.when(can_open, |element| {
            element.on_click(cx.listener(move |this, _, window, cx| {
                if let Some(target) = &worktree_target {
                    this.select_worktree(target, window, cx);
                } else {
                    this.select_session(&selection, window, cx);
                }
            }))
        })
        .into_any_element()
    }

    fn herdr_tree(
        &self,
        host_index: usize,
        host: &HostItem,
        sessions: &[TreeHerdrSession],
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let host_id = host.id().to_owned();
        let endpoint = host.endpoint().to_owned();
        let group_key = SessionGroupKey {
            host_id: host_id.clone(),
            group: SessionGroup::Herdr,
        };
        let collapsed = self.collapsed_session_groups.contains(&group_key);
        let mut tree = div().w_full().flex().flex_col().child({
            let mut header = div()
                .h(px(SESSION_GROUP_ROW_HEIGHT))
                .flex()
                .items_center()
                .pl(px(SESSION_GROUP_INSET))
                .pr_1()
                .bg(rgb(SESSION_GROUP_BACKGROUND))
                .text_xs()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(rgb(SESSION_GROUP_TEXT))
                .child(Self::session_group_toggle(
                    host_index,
                    &host_id,
                    SessionGroup::Herdr,
                    collapsed,
                    cx,
                ))
                .child(div().flex_1().child("HERDR SESSIONS"));
            if session_creation_available(host, NewSessionKind::Herdr) {
                let host_id = host_id.clone();
                let endpoint = endpoint.clone();
                header = header.child(
                    div()
                        .id(("create-herdr-session", host_index))
                        .size(px(22.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_sm()
                        .cursor_pointer()
                        .text_sm()
                        .text_color(rgb(0x8f_96_a3))
                        .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xd2_d7_df)))
                        .child("+")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open_new_session(
                                &host_id,
                                &endpoint,
                                NewSessionKind::Herdr,
                                window,
                                cx,
                            );
                        })),
                );
            }
            header
        });
        if collapsed {
            return tree.into_any_element();
        }
        if let Some(diagnostic) = host.herdr_diagnostic() {
            tree = tree.child(Self::capability_diagnostic_row(
                host_index,
                &host_id,
                "retry-herdr",
                diagnostic.message().to_owned(),
                cx,
            ));
        } else if sessions.is_empty() {
            tree = tree.child(
                div()
                    .h(px(SESSION_ROW_HEIGHT))
                    .flex()
                    .items_center()
                    .pl(px(SESSION_ROW_INSET))
                    .text_xs()
                    .text_color(rgb(0x73_7a87))
                    .child("No sessions"),
            );
        }
        for (index, session) in sessions.iter().enumerate() {
            tree = tree.child(Self::herdr_session_row(host_index, index, session, cx));
        }
        tree.into_any_element()
    }

    fn capability_diagnostic_row(
        host_index: usize,
        host_id: &str,
        retry_id: &'static str,
        message: String,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let host_id = host_id.to_owned();
        div()
            .mx_2()
            .mb_1()
            .px_2()
            .py_1()
            .rounded_sm()
            .bg(rgb(0x16_1920))
            .flex()
            .items_start()
            .gap_2()
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .text_xs()
                    .text_color(rgb(0x9b_a2ae))
                    .child(message),
            )
            .child(
                div()
                    .id((retry_id, host_index))
                    .flex_none()
                    .cursor_pointer()
                    .text_xs()
                    .text_color(rgb(0x79_aee3))
                    .child("Retry")
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.connect_host(&host_id, cx);
                    })),
            )
            .into_any_element()
    }

    #[allow(clippy::too_many_lines)] // Declarative row composition keeps controls in visual order.
    fn herdr_session_row(
        host_index: usize,
        index: usize,
        session: &TreeHerdrSession,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let running = session
            .inventory
            .as_ref()
            .is_none_or(|inventory| inventory.state() == HerdrSessionState::Running);
        let operation_label = session.inventory.as_ref().and_then(herdr_operation_label);
        let operation_pending = operation_label.is_some();
        let selection = session.selection.clone();
        let active = session.active;
        let actions = session
            .inventory
            .as_ref()
            .map_or_else(Vec::new, |inventory| {
                available_herdr_row_actions(session.access, inventory)
            });
        let row_is_actionable = if running {
            session.access.can_open()
        } else {
            session.access.can_restart()
        };
        let row_group = format!("herdr-session-actions-{host_index}-{index}");
        let mut row = div()
            .id((
                gpui::ElementId::named_usize("herdr-session-host", host_index),
                index.to_string(),
            ))
            .group(row_group.clone())
            .mr_1()
            .h(px(SESSION_ROW_HEIGHT))
            .flex()
            .items_center()
            .gap_1()
            .pl(px(SESSION_ROW_INSET))
            .pr_2()
            .bg(rgb(if active { 0x18_3f_68 } else { 0x0f_1116 }))
            .when(!operation_pending && row_is_actionable, |element| {
                element
                    .cursor_pointer()
                    .hover(|style| style.bg(rgb(0x1c_2028)))
            })
            .child(
                div()
                    .w(px(18.0))
                    .flex_none()
                    .text_xs()
                    .text_color(rgb(if running { 0x79_c9_a3 } else { 0x68_6f7a }))
                    .child(if running { ">_" } else { "○" }),
            )
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .truncate()
                    .text_sm()
                    .text_color(rgb(if running { 0xc4_c9_d2 } else { 0x7f_8794 }))
                    .child(selection.session().to_owned()),
            )
            .when_some(operation_label, |element, label| {
                element.child(
                    div()
                        .flex_none()
                        .text_xs()
                        .text_color(rgb(0x8f_96_a3))
                        .child(label),
                )
            });
        if session.show_endpoint {
            row = row.child(
                div()
                    .flex_none()
                    .text_xs()
                    .text_color(rgb(0x73_7a87))
                    .child(format!("· {}", selection.endpoint())),
            );
        }
        let menu_actions = herdr_session_menu_actions(active, actions);
        if !menu_actions.is_empty() {
            row = row.child(Self::session_action_menu_button(
                host_index,
                format!("herdr-{index}"),
                selection.clone(),
                menu_actions,
                row_group,
                cx,
            ));
        }
        row = if operation_pending {
            row
        } else if running && session.access.can_open() {
            row.on_click(cx.listener(move |this, _, window, cx| {
                this.select_session(&selection, window, cx);
            }))
        } else if session.access.can_restart() {
            row.on_click(cx.listener(move |this, _, window, cx| {
                this.restart_herdr_session(&selection, window, cx);
            }))
        } else {
            row
        };
        row.into_any_element()
    }

    fn session_action_menu_button(
        host_index: usize,
        row_id: String,
        selection: SessionSelection,
        actions: Vec<SessionRowAction>,
        row_group: String,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        div()
            .id((
                gpui::ElementId::named_usize("session-menu-host", host_index),
                row_id,
            ))
            .flex_none()
            .size(px(22.0))
            .flex()
            .items_center()
            .justify_center()
            .rounded_sm()
            .opacity(0.0)
            .group_hover(row_group, |style| style.opacity(1.0))
            .cursor_pointer()
            .text_xs()
            .text_color(rgb(0x9b_a2ae))
            .hover(|style| style.bg(rgb(0x25_2a34)).text_color(rgb(0xe1_e5ec)))
            .child("…")
            .on_click(cx.listener(move |this, event: &gpui::ClickEvent, _, cx| {
                let position = event.position();
                let x: f32 = position.x.into();
                let y: f32 = position.y.into();
                this.session_action_menu = Some(SessionActionMenu {
                    selection: selection.clone(),
                    actions: actions.clone(),
                    anchor_x: x,
                    anchor_y: y,
                });
                cx.stop_propagation();
                cx.notify();
            }))
            .into_any_element()
    }

    fn tree_session_row(
        host_index: usize,
        index: usize,
        session: &TreeSession,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let selection = session.selection.clone();
        let is_active = session.state.is_active();
        let can_open = session.state.can_open();
        let name = selection.session().to_owned();
        let backend = session_backend_id(selection.kind());
        let row_group = format!("{backend}-session-actions-{host_index}-{index}");
        let mut row = div()
            .id((
                gpui::ElementId::named_usize(session_row_element_id(selection.kind()), host_index),
                index.to_string(),
            ))
            .group(row_group.clone())
            .mr_1()
            .h(px(SESSION_ROW_HEIGHT))
            .flex()
            .items_center()
            .gap_1()
            .pl(px(SESSION_ROW_INSET))
            .pr_2()
            .bg(rgb(if is_active { 0x13_3d6a } else { 0x0f_1116 }))
            .when(can_open, |element| {
                element
                    .cursor_pointer()
                    .hover(|style| style.bg(rgb(if is_active { 0x17_477a } else { 0x1b_1f27 })))
            })
            .when(!can_open, |element| element.opacity(0.55))
            .child(
                div()
                    .w(px(18.0))
                    .flex_none()
                    .text_xs()
                    .text_color(rgb(if is_active { 0x9d_c7ed } else { 0x7f_8794 }))
                    .child(">_"),
            )
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .truncate()
                    .text_sm()
                    .text_color(rgb(if is_active { 0xe5_ed_f7 } else { 0xc4_c9_d2 }))
                    .child(name.clone()),
            );
        if session.show_endpoint {
            row = row.child(
                div()
                    .flex_none()
                    .text_xs()
                    .text_color(rgb(0x73_7a87))
                    .child(format!("· {}", selection.endpoint())),
            );
        }
        let actions = tmux_row_actions(is_active, session.state.can_kill());
        if !actions.is_empty() {
            row = row.child(Self::session_action_menu_button(
                host_index,
                format!("{backend}-{index}"),
                selection.clone(),
                actions,
                row_group,
                cx,
            ));
        }
        row.when(can_open, |element| {
            element.on_click(cx.listener(move |this, _, window, cx| {
                this.select_session(&selection, window, cx);
            }))
        })
        .into_any_element()
    }

    fn host_landing_element(host: &HostItem, cx: &mut Context<Self>) -> gpui::AnyElement {
        if host.connection() == HostConnectionState::Ready {
            return centered(host_landing_text(host));
        }
        Self::host_element(host, cx)
    }

    fn host_element(host: &HostItem, cx: &mut Context<Self>) -> gpui::AnyElement {
        match host.connection() {
            HostConnectionState::Disconnected
            | HostConnectionState::Connecting
            | HostConnectionState::Unavailable => centered(host_status_text(host)),
            HostConnectionState::Ready => {
                Self::ready_element(host.endpoint(), host.sessions(), Some(host), cx)
            }
        }
    }

    fn ready_element(
        endpoint: &str,
        sessions: &[workspace::SessionItem],
        host: Option<&HostItem>,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let refresh_host_id = host.map(|host| host.id().to_owned());
        let mut list = div().flex().flex_col().gap_2().p_6().max_w(px(720.0));
        list = list
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_xl()
                            .text_color(rgb(0xee_f0_f4))
                            .child(format!("Tmux sessions in {endpoint}")),
                    )
                    .child(
                        div()
                            .id("refresh-sessions")
                            .px_3()
                            .py_1()
                            .rounded_md()
                            .cursor_pointer()
                            .bg(rgb(0x2a_2f_3a))
                            .child("Refresh")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(host_id) = &refresh_host_id {
                                    this.connect_host(host_id, cx);
                                } else {
                                    this.refresh(cx);
                                }
                            })),
                    ),
            )
            .child(div().text_sm().text_color(rgb(0x8f_96_a3)).mb_4().child(
                "Select an existing session. Ghosthub attaches as an ordinary tmux client.",
            ));
        if sessions.is_empty() {
            let empty = host.map_or_else(|| "No tmux sessions.".to_owned(), empty_inventory_text);
            list = list.child(div().p_4().rounded_md().bg(rgb(0x1a_1d24)).child(empty));
        }
        for (index, session) in sessions.iter().enumerate() {
            let name = session.name().to_owned();
            let selection =
                SessionSelection::new(host.map_or("wsl", HostItem::id), endpoint, session.name());
            let detail = if session.attached_clients() == 0 {
                "detached".to_owned()
            } else {
                format!("{} client(s)", session.attached_clients())
            };
            list = list.child(
                div()
                    .id(("session", index))
                    .flex()
                    .items_center()
                    .justify_between()
                    .p_4()
                    .rounded_md()
                    .cursor_pointer()
                    .bg(rgb(0x1a_1d24))
                    .hover(|style| style.bg(rgb(0x25_2a34)))
                    .child(name.clone())
                    .child(div().text_sm().text_color(rgb(0x8f_96_a3)).child(detail))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.attach(&selection, window, cx);
                    })),
            );
        }
        div()
            .size_full()
            .flex()
            .justify_center()
            .child(list)
            .into_any_element()
    }
}

fn clears_when_input_queue_is_empty(diagnostic: Option<&str>) -> bool {
    diagnostic == Some(INPUT_BUFFERED_DIAGNOSTIC)
}

fn clears_after_input_delivery(
    diagnostic: Option<&str>,
    recovered_refusal: bool,
    refusal_pending: bool,
) -> bool {
    (recovered_refusal && diagnostic == Some(INPUT_BUFFER_FULL_DIAGNOSTIC))
        || (!refusal_pending && diagnostic == Some(INPUT_BUFFERED_DIAGNOSTIC))
}

fn terminal_presentation_id(content: &WorkspaceContent) -> Option<u64> {
    match content {
        WorkspaceContent::Terminal {
            presentation_id, ..
        } => Some(*presentation_id),
        _ => None,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TreeSession {
    selection: SessionSelection,
    state: TreeSessionState,
    show_endpoint: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TreeHerdrSession {
    selection: SessionSelection,
    inventory: Option<workspace::HerdrSessionItem>,
    active: bool,
    access: HerdrRowAccess,
    show_endpoint: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HerdrRowAccess {
    Cached,
    OpenOnly,
    Constructive,
    Mutable,
}

impl HerdrRowAccess {
    const fn can_open(self) -> bool {
        !matches!(self, Self::Cached)
    }

    const fn can_mutate(self) -> bool {
        matches!(self, Self::Mutable)
    }

    const fn can_restart(self) -> bool {
        matches!(self, Self::Constructive | Self::Mutable)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostHeaderAction {
    Connect,
    Cancel,
    Refresh,
    Retry,
}

impl HostHeaderAction {
    const fn element_id(self) -> &'static str {
        match self {
            Self::Connect => "connect-host",
            Self::Cancel => "cancel-host-refresh",
            Self::Refresh => "refresh-host",
            Self::Retry => "retry-host",
        }
    }

    const fn label(self) -> &'static str {
        match self {
            Self::Connect => "Connect",
            Self::Cancel => "×",
            Self::Refresh => "↻",
            Self::Retry => "Retry",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SessionGroupVisibility {
    tmux: bool,
    herdr: bool,
    zellij: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HerdrRowAction {
    Stop,
    Restart,
    Delete,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum SessionRowAction {
    Detach,
    KillSession,
    RemoveWorktree(Box<WorktreeRemoveTarget>),
    Herdr(HerdrRowAction),
}

fn herdr_lifecycle_copy(
    confirmation: &workspace::HerdrLifecycleConfirmation,
) -> (&'static str, String, &'static str) {
    let selection = confirmation.selection();
    match confirmation.action() {
        workspace::HerdrLifecycleAction::Stop => (
            "Stop Session",
            format!(
                "Stop “{}” on {}?",
                selection.session(),
                selection.endpoint()
            ),
            "This terminates every process in the session while preserving its saved workspace layout.",
        ),
        workspace::HerdrLifecycleAction::Delete => (
            "Delete Session",
            format!(
                "Delete “{}” on {}?",
                selection.session(),
                selection.endpoint()
            ),
            "This permanently removes the stopped session and its saved workspace layout.",
        ),
    }
}

fn herdr_row_actions(session: &workspace::HerdrSessionItem) -> Vec<HerdrRowAction> {
    if session.lifecycle_action().is_some() || session.launch_pending() {
        return Vec::new();
    }
    match session.state() {
        HerdrSessionState::Running => vec![HerdrRowAction::Stop],
        HerdrSessionState::Stopped if session.is_default() => vec![HerdrRowAction::Restart],
        HerdrSessionState::Stopped => vec![HerdrRowAction::Restart, HerdrRowAction::Delete],
    }
}

fn available_herdr_row_actions(
    access: HerdrRowAccess,
    session: &workspace::HerdrSessionItem,
) -> Vec<HerdrRowAction> {
    if access.can_mutate() {
        herdr_row_actions(session)
    } else if access.can_restart() && session.state() == HerdrSessionState::Stopped {
        vec![HerdrRowAction::Restart]
    } else {
        Vec::new()
    }
}

fn tmux_row_actions(active: bool, can_kill: bool) -> Vec<SessionRowAction> {
    let mut actions = Vec::with_capacity(2);
    if active {
        actions.push(SessionRowAction::Detach);
    }
    if can_kill {
        actions.push(SessionRowAction::KillSession);
    }
    actions
}

fn herdr_session_menu_actions(
    active: bool,
    lifecycle: Vec<HerdrRowAction>,
) -> Vec<SessionRowAction> {
    let mut actions = Vec::with_capacity(lifecycle.len() + usize::from(active));
    if active {
        actions.push(SessionRowAction::Detach);
    }
    actions.extend(lifecycle.into_iter().map(SessionRowAction::Herdr));
    actions
}

const fn session_backend_id(kind: workspace::SessionKind) -> &'static str {
    match kind {
        workspace::SessionKind::Tmux => "tmux",
        workspace::SessionKind::Herdr => "herdr",
        workspace::SessionKind::Zellij => "zellij",
    }
}

const fn session_row_element_id(kind: workspace::SessionKind) -> &'static str {
    match kind {
        workspace::SessionKind::Tmux => "tmux-session-host",
        workspace::SessionKind::Herdr => "herdr-session-host",
        workspace::SessionKind::Zellij => "zellij-session-host",
    }
}

fn herdr_operation_label(session: &workspace::HerdrSessionItem) -> Option<&'static str> {
    match session.lifecycle_action() {
        Some(workspace::HerdrLifecycleAction::Stop) => Some("Stopping…"),
        Some(workspace::HerdrLifecycleAction::Delete) => Some("Deleting…"),
        None if session.launch_pending() => Some("Starting…"),
        None => None,
    }
}

fn session_group_visibility(
    host: &HostItem,
    herdr_sessions: &[TreeHerdrSession],
    zellij_sessions: &[TreeSession],
) -> SessionGroupVisibility {
    SessionGroupVisibility {
        tmux: true,
        herdr: host.herdr_available()
            || !herdr_sessions.is_empty()
            || host.herdr_diagnostic().is_some(),
        zellij: host.zellij_available()
            || !zellij_sessions.is_empty()
            || host.zellij_diagnostic().is_some(),
    }
}

fn session_creation_available(host: &HostItem, kind: NewSessionKind) -> bool {
    if !host.accepts_session_actions() {
        return false;
    }
    match kind {
        NewSessionKind::Tmux => !host.is_ssh(),
        NewSessionKind::Herdr => host.herdr_available() && host.herdr_diagnostic().is_none(),
        NewSessionKind::Zellij => host.zellij_available() && host.zellij_diagnostic().is_none(),
    }
}

fn host_landing_text(host: &HostItem) -> &'static str {
    if host.sessions().is_empty()
        && host.herdr_sessions().is_empty()
        && host.zellij_sessions().is_empty()
    {
        "No sessions available."
    } else {
        "Choose a session to open its terminal."
    }
}

const fn host_header_action(connection: HostConnectionState) -> HostHeaderAction {
    match connection {
        HostConnectionState::Disconnected => HostHeaderAction::Connect,
        HostConnectionState::Connecting => HostHeaderAction::Cancel,
        HostConnectionState::Ready => HostHeaderAction::Refresh,
        HostConnectionState::Unavailable => HostHeaderAction::Retry,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TreeSessionState {
    Active,
    ActiveKillable,
    Retained,
    RetainedKillable,
    Fresh,
    FreshOpenOnly,
    Cached,
}

impl TreeSessionState {
    const fn is_active(self) -> bool {
        matches!(self, Self::Active | Self::ActiveKillable)
    }

    const fn can_open(self) -> bool {
        !matches!(self, Self::Cached)
    }

    const fn can_kill(self) -> bool {
        matches!(
            self,
            Self::ActiveKillable | Self::RetainedKillable | Self::Fresh
        )
    }
}

fn active_session_selection(content: &WorkspaceContent) -> Option<SessionSelection> {
    match content {
        WorkspaceContent::Attaching {
            host_id,
            endpoint,
            session,
            kind,
        }
        | WorkspaceContent::Terminal {
            host_id,
            endpoint,
            session,
            kind,
            ..
        } => Some(match kind {
            workspace::SessionKind::Tmux => SessionSelection::new(host_id, endpoint, session),
            workspace::SessionKind::Herdr => SessionSelection::herdr(host_id, endpoint, session),
            workspace::SessionKind::Zellij => SessionSelection::zellij(host_id, endpoint, session),
        }),
        WorkspaceContent::Shell
        | WorkspaceContent::Loading
        | WorkspaceContent::Ready { .. }
        | WorkspaceContent::Error { .. } => None,
    }
}

fn host_owns_worktree_presentation(host: &HostItem, selection: &SessionSelection) -> bool {
    if selection.tmux_socket_name().is_some() {
        host.kwt_owns_protected_presentation(selection)
    } else {
        selection.host_id() == host.id()
            && selection.endpoint() == host.endpoint()
            && host.kwt_owns_default_tmux_session(selection.session())
    }
}

fn tree_sessions(
    host: &HostItem,
    active: Option<&SessionSelection>,
    retained: &[SessionSelection],
) -> Vec<TreeSession> {
    let active_for_host = active.filter(|active| {
        active.host_id() == host.id() && active.kind() == workspace::SessionKind::Tmux
    });

    let mut selections = host
        .sessions()
        .iter()
        .filter(|session| !host.kwt_owns_default_tmux_session(session.name()))
        .map(|session| {
            (
                SessionSelection::new(host.id(), host.endpoint(), session.name()),
                true,
            )
        })
        .collect::<Vec<_>>();
    for selection in retained
        .iter()
        .filter(|selection| {
            selection.host_id() == host.id()
                && selection.kind() == workspace::SessionKind::Tmux
                && !host_owns_worktree_presentation(host, selection)
        })
        .chain(
            active_for_host
                .into_iter()
                .filter(|selection| !host_owns_worktree_presentation(host, selection)),
        )
    {
        if !selections
            .iter()
            .any(|(candidate, _)| candidate == selection)
        {
            selections.push((selection.clone(), false));
        }
    }
    let host_accepts_actions = host.accepts_session_actions();
    selections
        .into_iter()
        .map(|(selection, discovered)| {
            let retained = retained.contains(&selection);
            let is_active = active == Some(&selection);
            let can_kill = discovered && host_accepts_actions && !host.is_ssh();
            let state = match (is_active, retained, host_accepts_actions, can_kill) {
                (true, _, _, true) => TreeSessionState::ActiveKillable,
                (true, _, _, false) => TreeSessionState::Active,
                (false, true, _, true) => TreeSessionState::RetainedKillable,
                (false, true, _, false) => TreeSessionState::Retained,
                (false, false, true, true) => TreeSessionState::Fresh,
                (false, false, true, false) => TreeSessionState::FreshOpenOnly,
                (false, false, false, _) => TreeSessionState::Cached,
            };
            TreeSession {
                state,
                show_endpoint: selection.endpoint() != host.endpoint(),
                selection,
            }
        })
        .collect()
}

fn tree_herdr_sessions(
    host: &HostItem,
    active: Option<&SessionSelection>,
    retained: &[SessionSelection],
) -> Vec<TreeHerdrSession> {
    let active_for_host = active.filter(|selection| {
        selection.host_id() == host.id() && selection.kind() == workspace::SessionKind::Herdr
    });
    let mut sessions = host
        .herdr_sessions()
        .iter()
        .map(|inventory| TreeHerdrSession {
            selection: SessionSelection::herdr(host.id(), host.endpoint(), inventory.name()),
            inventory: Some(inventory.clone()),
            active: false,
            access: HerdrRowAccess::Cached,
            show_endpoint: false,
        })
        .collect::<Vec<_>>();
    for selection in retained
        .iter()
        .filter(|selection| {
            selection.host_id() == host.id() && selection.kind() == workspace::SessionKind::Herdr
        })
        .chain(active_for_host)
    {
        if !sessions
            .iter()
            .any(|candidate| candidate.selection == *selection)
        {
            sessions.push(TreeHerdrSession {
                selection: selection.clone(),
                inventory: None,
                active: false,
                access: HerdrRowAccess::Cached,
                show_endpoint: selection.endpoint() != host.endpoint(),
            });
        }
    }
    let host_can_open = host.accepts_session_actions() && host.herdr_diagnostic().is_none();
    let host_accepts_mutation = host_can_open && !host.is_ssh();
    for session in &mut sessions {
        session.active = active == Some(&session.selection);
        let retained = retained.contains(&session.selection);
        session.access = if session.inventory.is_some() && host_accepts_mutation {
            HerdrRowAccess::Mutable
        } else if session.inventory.is_some() && host_can_open && host.is_ssh() {
            HerdrRowAccess::Constructive
        } else if (session.inventory.is_some() && host_can_open) || session.active || retained {
            HerdrRowAccess::OpenOnly
        } else {
            HerdrRowAccess::Cached
        };
    }
    sessions
}

fn tree_zellij_sessions(
    host: &HostItem,
    active: Option<&SessionSelection>,
    retained: &[SessionSelection],
) -> Vec<TreeSession> {
    let active_for_host = active.filter(|selection| {
        selection.host_id() == host.id() && selection.kind() == workspace::SessionKind::Zellij
    });
    let mut selections = host
        .zellij_sessions()
        .iter()
        .map(|session| {
            (
                SessionSelection::zellij(host.id(), host.endpoint(), session.name()),
                true,
            )
        })
        .collect::<Vec<_>>();
    for selection in retained
        .iter()
        .filter(|selection| {
            selection.host_id() == host.id() && selection.kind() == workspace::SessionKind::Zellij
        })
        .chain(active_for_host)
    {
        if !selections
            .iter()
            .any(|(candidate, _)| candidate == selection)
        {
            selections.push((selection.clone(), false));
        }
    }
    let host_accepts_actions = host.accepts_session_actions() && host.zellij_diagnostic().is_none();
    selections
        .into_iter()
        .map(|(selection, discovered)| {
            let retained = retained.contains(&selection);
            let is_active = active == Some(&selection);
            let can_kill = discovered && host_accepts_actions && !host.is_ssh();
            let state = match (is_active, retained, host_accepts_actions, can_kill) {
                (true, _, _, true) => TreeSessionState::ActiveKillable,
                (true, _, _, false) => TreeSessionState::Active,
                (false, true, _, true) => TreeSessionState::RetainedKillable,
                (false, true, _, false) => TreeSessionState::Retained,
                (false, false, true, true) => TreeSessionState::Fresh,
                (false, false, true, false) => TreeSessionState::FreshOpenOnly,
                (false, false, false, _) => TreeSessionState::Cached,
            };
            TreeSession {
                show_endpoint: selection.endpoint() != host.endpoint(),
                selection,
                state,
            }
        })
        .collect()
}

fn kill_confirmation_title(selection: &SessionSelection) -> String {
    format!(
        "Kill “{}” on {}?",
        selection.session(),
        selection.endpoint()
    )
}

fn kill_confirmation_description(selection: &SessionSelection) -> String {
    format!(
        "This permanently terminates every window, pane, and process in this tmux session on {}.",
        selection.endpoint()
    )
}

fn workspace_window_title(content: &WorkspaceContent) -> String {
    match content {
        WorkspaceContent::Attaching {
            endpoint, session, ..
        }
        | WorkspaceContent::Terminal {
            endpoint, session, ..
        } => format!("{session} — {endpoint} — {WINDOW_TITLE}"),
        WorkspaceContent::Ready { endpoint, .. } => format!("{endpoint} — {WINDOW_TITLE}"),
        WorkspaceContent::Shell | WorkspaceContent::Loading | WorkspaceContent::Error { .. } => {
            WINDOW_TITLE.to_owned()
        }
    }
}

const fn application_navigation_width(sidebar_visible: bool, has_hosts: bool) -> f32 {
    if sidebar_visible && has_hosts {
        APP_NAVIGATION_WIDTH
    } else {
        0.0
    }
}

fn transitioned_presentation(observed: &mut Option<u64>, current: Option<u64>) -> bool {
    if *observed == current {
        false
    } else {
        *observed = current;
        true
    }
}

fn queued_input_matches_presentation(
    input: &QueuedUiInput,
    active_presentation: Option<u64>,
) -> bool {
    active_presentation == Some(input.presentation_id)
}

fn coalesce_last_resize(
    pending: &mut VecDeque<QueuedUiInput>,
    presentation_id: u64,
    resize: TerminalResize,
) -> bool {
    let Some(last) = pending.back_mut() else {
        return false;
    };
    if last.presentation_id != presentation_id || !matches!(last.input, PendingUiInput::Resize(_)) {
        return false;
    }
    last.input = PendingUiInput::Resize(resize);
    true
}

fn coalesce_last_wheel(
    pending: &mut VecDeque<QueuedUiInput>,
    presentation_id: u64,
    batch: WheelBatch,
    accepted_after_refusal: Option<u64>,
) -> bool {
    let Some(last) = pending.back_mut() else {
        return false;
    };
    let PendingUiInput::Wheel(pending_batch) = &mut last.input else {
        return false;
    };
    if last.presentation_id != presentation_id || pending_batch.input != batch.input {
        return false;
    }
    pending_batch.remaining = pending_batch.remaining.saturating_add(batch.remaining);
    last.accepted_after_refusal = accepted_after_refusal;
    true
}

fn clear_terminal_input_state(
    paste_confirmation: &mut bool,
    pending_input: &mut VecDeque<QueuedUiInput>,
    pending_input_bytes: &mut usize,
    input_refusal: &mut InputRefusal,
) {
    *paste_confirmation = false;
    pending_input.clear();
    *pending_input_bytes = 0;
    *input_refusal = InputRefusal::default();
}

impl Focusable for RootView {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for RootView {
    #[allow(clippy::too_many_lines)] // Root composition keeps overlay ordering explicit.
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let _scope_changed = self.sync_terminal_scope();
        let _handled = self.handle_events(cx);
        let snapshot = self.workspace.snapshot();
        if self.restore_focus {
            window.focus(&self.focus);
            self.restore_focus = false;
        }
        if !self.ssh_prompts.is_empty() && !self.ssh_prompt_focus.is_focused(window) {
            window.focus(&self.ssh_prompt_focus);
        }
        let title = workspace_window_title(snapshot.content());
        window.set_window_title(&title);
        self.synchronize_render_state(&snapshot);
        let content = self.content_element(&snapshot, cx);
        let creation_overlay = self.new_session_overlay(&snapshot, window, cx);
        let project_overlay = self.project_overlay(window, cx);
        let settings_overlay = self.settings_overlay(window, cx);
        let ssh_prompt_overlay = self.ssh_prompt_overlay(window, cx);
        let session_action_menu = self.session_action_menu_overlay(window, cx);
        let kill_overlay = self.pending_session_kill_overlay(window, cx);
        let herdr_lifecycle_overlay = self.pending_herdr_lifecycle_overlay(window, cx);
        let mut root = div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(snapshot.appearance().background()))
            .text_color(rgb(snapshot.appearance().foreground()))
            .on_action(cx.listener(|this, _: &ToggleSidebar, window, cx| {
                this.toggle_sidebar(window, cx);
            }))
            .child(self.title_bar(title, cx))
            .child(div().flex_1().min_h_0().w_full().child(content))
            .children(creation_overlay)
            .children(project_overlay)
            .children(settings_overlay)
            .children(session_action_menu)
            .children(kill_overlay)
            .children(herdr_lifecycle_overlay);

        if let Some(notice) = self.terminal_notice.visible() {
            root = root.child(
                div()
                    .absolute()
                    .left_4()
                    .bottom_4()
                    .px_3()
                    .py_2()
                    .rounded_md()
                    .bg(rgb(0x5a_49_20))
                    .text_color(rgb(0xf0_d7_8a))
                    .child(notice.to_owned()),
            );
        }
        if let Some(diagnostic) = &self.diagnostic {
            root = root.child(
                div()
                    .absolute()
                    .left_4()
                    .bottom_12()
                    .px_3()
                    .py_2()
                    .rounded_md()
                    .bg(rgb(0x6e_2a32))
                    .child(diagnostic.clone()),
            );
        }
        if self.paste_confirmation
            && let Some(presentation_id) = terminal_presentation_id(snapshot.content())
        {
            root = root.child(
                div()
                    .absolute()
                    .left_4()
                    .right_4()
                    .bottom_4()
                    .flex()
                    .items_center()
                    .justify_between()
                    .p_4()
                    .rounded_md()
                    .bg(rgb(0x45_3520))
                    .child("Paste potentially unsafe text? It may execute commands immediately.")
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                div()
                                    .id("cancel-paste")
                                    .px_3()
                                    .py_1()
                                    .cursor_pointer()
                                    .child("Cancel")
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.cancel_paste(presentation_id, cx);
                                    })),
                            )
                            .child(
                                div()
                                    .id("approve-paste")
                                    .px_3()
                                    .py_1()
                                    .rounded_md()
                                    .cursor_pointer()
                                    .bg(rgb(0x8a_62_2a))
                                    .child("Paste")
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.approve_paste(presentation_id, cx);
                                    })),
                            ),
                    ),
            );
        }
        root.children(ssh_prompt_overlay)
    }
}

fn session_action_menu_position(
    anchor_x: f32,
    anchor_y: f32,
    viewport_width: f32,
    viewport_height: f32,
    action_count: usize,
) -> (f32, f32) {
    let action_count = u16::try_from(action_count).unwrap_or(u16::MAX);
    let menu_height = f32::from(action_count) * SESSION_ACTION_MENU_ITEM_HEIGHT
        + SESSION_ACTION_MENU_VERTICAL_CHROME;
    let max_left = (viewport_width - SESSION_ACTION_MENU_WIDTH - SESSION_ACTION_MENU_MARGIN)
        .max(SESSION_ACTION_MENU_MARGIN);
    let left = (anchor_x - SESSION_ACTION_MENU_WIDTH).clamp(SESSION_ACTION_MENU_MARGIN, max_left);
    let max_top = (viewport_height - menu_height - SESSION_ACTION_MENU_MARGIN)
        .max(SESSION_ACTION_MENU_MARGIN);
    let below = anchor_y + SESSION_ACTION_MENU_OFFSET;
    let preferred_top = if below + menu_height > viewport_height - SESSION_ACTION_MENU_MARGIN {
        anchor_y - menu_height - SESSION_ACTION_MENU_OFFSET
    } else {
        below
    };
    let top = preferred_top.clamp(SESSION_ACTION_MENU_MARGIN, max_top);
    (left, top)
}

fn centered(text: impl Into<String>) -> gpui::AnyElement {
    div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .text_color(rgb(0xb7_bc_c6))
        .child(text.into())
        .into_any_element()
}

fn new_session_validation(
    snapshot: &workspace::WorkspaceSnapshot,
    draft: &NewSessionDraft,
) -> Option<String> {
    let Some(host) = snapshot
        .hosts()
        .iter()
        .find(|host| host.id() == draft.host_id.as_str())
    else {
        return Some("The selected host is no longer available.".to_owned());
    };
    if host.endpoint() != draft.endpoint {
        return Some(
            "The WSL endpoint changed. Close this dialog and choose the host again.".to_owned(),
        );
    }
    if !host.accepts_session_actions() {
        return Some(if host.is_ssh() {
            "Wait for the SSH host connection before creating a session.".to_owned()
        } else {
            "Reconnect the WSL host before creating a session.".to_owned()
        });
    }
    if draft.name.trim().is_empty() {
        return None;
    }
    match draft.kind {
        NewSessionKind::Tmux => {
            let Ok(name) = SessionName::parse(&draft.name) else {
                return Some(
                    "Use 1–100 characters without #, periods, colons, or line breaks.".to_owned(),
                );
            };
            host.sessions()
                .iter()
                .any(|session| session.name() == name.as_str())
                .then(|| "A tmux session with this name already exists on this host.".to_owned())
        }
        NewSessionKind::Herdr => {
            if !host.herdr_available() || host.herdr_diagnostic().is_some() {
                return Some("Herdr is not available on this host.".to_owned());
            }
            let Ok(name) = workspace::HerdrSessionName::parse(&draft.name) else {
                return Some(
                    "Use 1–64 ASCII letters, numbers, periods, underscores, or hyphens.".to_owned(),
                );
            };
            host.herdr_sessions()
                .iter()
                .any(|session| session.name() == name.as_str())
                .then(|| {
                    "A Herdr session with this name already exists on this host. Restart it instead."
                        .to_owned()
                })
        }
        NewSessionKind::Zellij => {
            if !host.zellij_available() || host.zellij_diagnostic().is_some() {
                return Some("Zellij is not available on this host.".to_owned());
            }
            let Ok(name) = workspace::ZellijSessionName::parse(&draft.name) else {
                return Some(
                    "Use a nonempty name without slashes or control characters.".to_owned(),
                );
            };
            host.zellij_sessions()
                .iter()
                .any(|session| session.name() == name.as_str())
                .then(|| "A Zellij session with this name already exists on this host.".to_owned())
        }
    }
}

fn window_control(
    id: &'static str,
    label: &'static str,
    area: WindowControlArea,
) -> gpui::AnyElement {
    let control = div()
        .id(id)
        .w(px(46.0))
        .h_full()
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .window_control_area(area)
        .text_size(px(16.0))
        .text_color(rgb(0xb7_bcc6))
        .child(label)
        .on_click(move |_, window, _| match area {
            WindowControlArea::Min => window.minimize_window(),
            WindowControlArea::Max => window.zoom_window(),
            WindowControlArea::Close => window.remove_window(),
            WindowControlArea::Drag => {}
        });
    if area == WindowControlArea::Close {
        control
            .hover(|style| style.bg(rgb(0xc4_2b1c)).text_color(rgb(0xff_ffff)))
            .into_any_element()
    } else {
        control
            .hover(|style| style.bg(rgb(0x24_2933)).text_color(rgb(0xe5_e9f0)))
            .into_any_element()
    }
}

fn paint_run_element(run: PaintRun, cell_width: f32) -> gpui::AnyElement {
    let columns = u16::try_from(run.columns).unwrap_or(u16::MAX);
    let width = cell_width * f32::from(columns);
    let mut element = div()
        .flex_none()
        .w(px(width))
        .overflow_hidden()
        .bg(rgb(run.background))
        .text_color(rgb(run.foreground))
        .child(run.text);
    if run.style.contains(CellStyle::BOLD) {
        element = element.font_weight(FontWeight::BOLD);
    }
    if run.style.contains(CellStyle::ITALIC) {
        element = element.italic();
    }
    if run.style.contains(CellStyle::UNDERLINE) {
        element = element.underline();
    }
    if run.style.contains(CellStyle::STRIKE) {
        element = element.line_through();
    }
    element.into_any_element()
}

fn named_key(key: &str) -> Option<NamedKey> {
    match key.to_ascii_lowercase().as_str() {
        "enter" => Some(NamedKey::Enter),
        "tab" => Some(NamedKey::Tab),
        "backspace" => Some(NamedKey::Backspace),
        "escape" => Some(NamedKey::Escape),
        "up" => Some(NamedKey::ArrowUp),
        "down" => Some(NamedKey::ArrowDown),
        "left" => Some(NamedKey::ArrowLeft),
        "right" => Some(NamedKey::ArrowRight),
        "home" => Some(NamedKey::Home),
        "end" => Some(NamedKey::End),
        "pageup" => Some(NamedKey::PageUp),
        "pagedown" => Some(NamedKey::PageDown),
        "insert" => Some(NamedKey::Insert),
        "delete" => Some(NamedKey::Delete),
        "numpaddecimal" | "kpdecimal" => Some(NamedKey::KeypadDecimal),
        "numpaddivide" | "kpdivide" => Some(NamedKey::KeypadDivide),
        "numpadmultiply" | "kpmultiply" => Some(NamedKey::KeypadMultiply),
        "numpadsubtract" | "kpsubtract" => Some(NamedKey::KeypadSubtract),
        "numpadadd" | "kpadd" => Some(NamedKey::KeypadAdd),
        "numpadenter" | "kpenter" => Some(NamedKey::KeypadEnter),
        "numpadequal" | "kpequal" => Some(NamedKey::KeypadEqual),
        value if value.starts_with("numpad") => value[6..].parse().ok().map(NamedKey::KeypadDigit),
        value if value.starts_with("kp") => value[2..].parse().ok().map(NamedKey::KeypadDigit),
        value if value.len() > 1 && value.starts_with('f') => {
            value[1..].parse().ok().map(NamedKey::F)
        }
        _ => None,
    }
}

#[cfg(test)]
fn terminal_key_input(keystroke: &gpui::Keystroke, event: InputKeyEvent) -> Option<KeyInput> {
    let canonical = canonical_terminal_key(keystroke);
    terminal_key_input_with_canonical(keystroke, event, &canonical)
}

fn terminal_key_input_with_canonical(
    keystroke: &gpui::Keystroke,
    event: InputKeyEvent,
    canonical: &CanonicalTerminalKey,
) -> Option<KeyInput> {
    if is_toggle_sidebar_shortcut(keystroke) {
        return None;
    }
    terminal_owned_key_input(keystroke, event, canonical)
}

fn terminal_owned_key_input(
    keystroke: &gpui::Keystroke,
    event: InputKeyEvent,
    canonical: &CanonicalTerminalKey,
) -> Option<KeyInput> {
    // GPUI's Windows backend removes the synthetic Ctrl+Alt pair generated by
    // right-Alt on AltGr layouts, while preserving genuine Ctrl+Alt chords.
    let modifiers = canonical.modifiers;
    let key_char = keystroke
        .key_char
        .as_deref()
        .filter(|text| !text.is_empty());
    let layout_logical;
    let logical_key = if keystroke.key.eq_ignore_ascii_case("space") {
        " "
    } else if let Some(unshifted) = canonical.layout.and_then(|layout| layout.unshifted) {
        layout_logical = unshifted.to_string();
        layout_logical.as_str()
    } else {
        &keystroke.key
    };
    if let Some(key) = named_key(&keystroke.key) {
        return Some(KeyInput::named(key, modifiers).with_event(event));
    }
    if let Some(text) =
        key_char.or_else(|| keystroke.key.eq_ignore_ascii_case("space").then_some(" "))
    {
        return Some(KeyInput::text_with_key(text, logical_key, modifiers).with_event(event));
    }
    ctrl_key_input(keystroke, event, canonical)
}

fn ctrl_key_input(
    keystroke: &gpui::Keystroke,
    event: InputKeyEvent,
    canonical: &CanonicalTerminalKey,
) -> Option<KeyInput> {
    if !keystroke.modifiers.control {
        return None;
    }
    if let Some(layout) = canonical.layout
        && let Some(logical) = layout.unshifted
        && let Some(produced) = if canonical.modifiers.shift {
            layout.shifted
        } else {
            layout.unshifted
        }
    {
        return Some(
            KeyInput::text_with_key(
                produced.to_string(),
                logical.to_string(),
                canonical.modifiers,
            )
            .with_event(event),
        );
    }

    let mut characters = keystroke.key.chars();
    let raw = characters.next()?;
    if characters.next().is_some() {
        return None;
    }

    let (logical, produced) = if canonical.modifiers.shift {
        (
            raw,
            if raw.is_ascii_lowercase() {
                raw.to_ascii_uppercase()
            } else {
                shifted_ascii_key(raw).unwrap_or(raw)
            },
        )
    } else {
        (raw, raw)
    };
    if !is_ascii_control_chord(produced) {
        return None;
    }

    Some(
        KeyInput::text_with_key(
            produced.to_string(),
            logical.to_string(),
            canonical.modifiers,
        )
        .with_event(event),
    )
}

const fn shifted_ascii_key(character: char) -> Option<char> {
    match character {
        '`' => Some('~'),
        '1' => Some('!'),
        '2' => Some('@'),
        '3' => Some('#'),
        '4' => Some('$'),
        '5' => Some('%'),
        '6' => Some('^'),
        '7' => Some('&'),
        '8' => Some('*'),
        '9' => Some('('),
        '0' => Some(')'),
        '-' => Some('_'),
        '=' => Some('+'),
        '[' => Some('{'),
        ']' => Some('}'),
        '\\' => Some('|'),
        ';' => Some(':'),
        '\'' => Some('"'),
        ',' => Some('<'),
        '.' => Some('>'),
        '/' => Some('?'),
        _ => None,
    }
}

fn canonical_terminal_key(keystroke: &gpui::Keystroke) -> CanonicalTerminalKey {
    canonical_terminal_key_with(keystroke, platform_layout_key)
}

fn retained_key_event(
    keyboard: &TerminalKeyboard,
    keystroke: &gpui::Keystroke,
    event: InputKeyEvent,
) -> Option<(CanonicalTerminalKey, KeyInput)> {
    retained_key_event_with(keyboard, keystroke, event, platform_layout_key)
}

fn retained_key_event_with(
    keyboard: &TerminalKeyboard,
    keystroke: &gpui::Keystroke,
    event: InputKeyEvent,
    resolve: impl FnOnce(char) -> Option<LayoutKey>,
) -> Option<(CanonicalTerminalKey, KeyInput)> {
    let canonical = canonical_terminal_key_with(keystroke, resolve);
    if !keyboard.accepts(&canonical.identity, event) {
        return None;
    }
    let input = match event {
        InputKeyEvent::Repeat => terminal_owned_key_input(keystroke, event, &canonical)
            .or_else(|| keyboard.input_for(&canonical.identity, event, canonical.modifiers)),
        InputKeyEvent::Release => {
            keyboard.input_for(&canonical.identity, event, canonical.modifiers)
        }
        InputKeyEvent::Press => None,
    }?;
    Some((canonical, input))
}

fn canonical_terminal_key_with(
    keystroke: &gpui::Keystroke,
    resolve: impl FnOnce(char) -> Option<LayoutKey>,
) -> CanonicalTerminalKey {
    let mut modifiers = input_modifiers(keystroke.modifiers);
    let layout = single_character(&keystroke.key).and_then(resolve);
    let identity = if let Some(layout) = layout {
        if layout.shift_required {
            modifiers.shift = true;
        }
        TerminalKeyIdentity::Layout(layout.virtual_key)
    } else {
        TerminalKeyIdentity::Logical(keystroke.key.clone())
    };
    CanonicalTerminalKey {
        identity,
        modifiers,
        layout,
    }
}

fn single_character(value: &str) -> Option<char> {
    let mut characters = value.chars();
    let character = characters.next()?;
    characters.next().is_none().then_some(character)
}

#[cfg(windows)]
fn platform_layout_key(character: char) -> Option<LayoutKey> {
    windows_key::resolve(character)
}

#[cfg(not(windows))]
const fn platform_layout_key(_character: char) -> Option<LayoutKey> {
    None
}

fn is_ascii_control_chord(character: char) -> bool {
    character.is_ascii()
        && matches!(
            character as u8,
            b' ' | b'2'..=b'8' | b'/' | b'?' | b'@'..=b'_' | b'`' | b'a'..=b'z'
        )
}

fn is_paste_shortcut(keystroke: &gpui::Keystroke) -> bool {
    keystroke.modifiers.control
        && keystroke.modifiers.shift
        && keystroke.key.eq_ignore_ascii_case("v")
}

fn is_toggle_sidebar_shortcut(keystroke: &gpui::Keystroke) -> bool {
    keystroke.modifiers.control
        && keystroke.modifiers.shift
        && !keystroke.modifiers.alt
        && keystroke.key.eq_ignore_ascii_case("b")
}

const fn input_modifiers(modifiers: gpui::Modifiers) -> InputModifiers {
    InputModifiers {
        shift: modifiers.shift,
        control: modifiers.control,
        alt: modifiers.alt,
    }
}

const fn terminal_mouse_button(button: GpuiMouseButton) -> Option<MouseButton> {
    match button {
        GpuiMouseButton::Left => Some(MouseButton::Left),
        GpuiMouseButton::Middle => Some(MouseButton::Middle),
        GpuiMouseButton::Right => Some(MouseButton::Right),
        GpuiMouseButton::Navigate(_) => None,
    }
}

const fn mouse_button_index(button: MouseButton) -> usize {
    match button {
        MouseButton::Left => 0,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    }
}

#[must_use]
pub fn terminal_cell_at(
    x: f32,
    y: f32,
    cell_width: f32,
    line_height: f32,
    size: surface::GridSize,
) -> Option<(usize, usize)> {
    terminal_cell_at_with_offset(x, y, 0.0, 0.0, cell_width, line_height, size)
}

fn terminal_cell_at_with_offset(
    x: f32,
    y: f32,
    x_offset: f32,
    y_offset: f32,
    cell_width: f32,
    line_height: f32,
    size: surface::GridSize,
) -> Option<(usize, usize)> {
    let content_x = x - x_offset;
    let content_y = y - y_offset;
    if content_x < 0.0 || content_y < 0.0 {
        return None;
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let column = (content_x / cell_width).floor() as usize;
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let row = (content_y / line_height).floor() as usize;
    (column < size.columns() && row < size.rows()).then_some((column, row))
}

#[must_use]
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub fn terminal_grid_size(
    width: f32,
    height: f32,
    cell_width: f32,
    line_height: f32,
) -> (usize, usize) {
    let content_width = width.max(1.0);
    let content_height = height.max(1.0);
    (
        (content_width / cell_width).floor().max(1.0) as usize,
        (content_height / line_height).floor().max(1.0) as usize,
    )
}

fn measure_terminal_metrics(
    window: &Window,
    appearance: &workspace::Appearance,
) -> TerminalMetrics {
    let font_size = px(f32::from(appearance.font_size()));
    let text_system = window.text_system();
    let font_id = text_system.resolve_font(&font(appearance.font_family().to_owned()));
    let cell_width =
        normalize_cell_width(text_system.advance(font_id, font_size, '0').map_or_else(
            |_| f32::from(text_system.bounding_box(font_id, font_size).size.width),
            |advance| f32::from(advance.width),
        ));
    let line_height = terminal_line_height(
        f32::from(font_size),
        f32::from(text_system.ascent(font_id, font_size)),
        f32::from(text_system.descent(font_id, font_size)),
    );
    TerminalMetrics {
        cell_width,
        line_height,
    }
}

fn normalize_cell_width(measured: f32) -> f32 {
    measured.max(1.0)
}

fn terminal_line_height(font_size: f32, ascent: f32, descent: f32) -> f32 {
    (ascent + descent + CELL_LINE_GAP)
        .max(font_size * 1.3)
        .ceil()
        .max(1.0)
}

#[must_use]
#[allow(
    clippy::cast_possible_truncation,
    reason = "completed wheel lines are represented by a bounded batch count"
)]
pub fn terminal_wheel_steps(remainder: &mut f32, vertical_delta: f32, line_height: f32) -> i32 {
    if !vertical_delta.is_finite() || !line_height.is_finite() || line_height <= 0.0 {
        return 0;
    }
    let total = *remainder + vertical_delta / line_height;
    let completed = total.trunc();
    *remainder = total.fract();
    completed as i32
}

#[must_use]
pub const fn terminal_wheel_action(completed_steps: i32) -> Option<MouseAction> {
    if completed_steps > 0 {
        Some(MouseAction::WheelUp)
    } else if completed_steps < 0 {
        Some(MouseAction::WheelDown)
    } else {
        None
    }
}

/// Start the GPUI event loop and open Ghosthub's first native window.
///
/// # Panics
///
/// Panics if GPUI cannot create the application window.
pub fn run(status: PortStatus, workspace: Workspace) {
    Application::new().run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(1100.0), px(720.0)), cx);

        cx.bind_keys([KeyBinding::new("ctrl-shift-b", ToggleSidebar, None)]);

        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some(WINDOW_TITLE.into()),
                    appears_transparent: true,
                    ..Default::default()
                }),
                window_background: WindowBackgroundAppearance::Opaque,
                window_decorations: Some(WindowDecorations::Client),
                ..Default::default()
            },
            move |window, cx| cx.new(|cx| RootView::new(status, workspace.clone(), window, cx)),
        )
        .expect("failed to open the Ghosthub window");

        cx.activate(true);
    });
}

#[cfg(test)]
mod tests {
    use std::collections::{HashSet, VecDeque};

    use super::{
        APP_NAVIGATION_WIDTH, APP_TITLEBAR_HEIGHT, AppearanceField, HerdrRowAccess, HerdrRowAction,
        HostHeaderAction, INPUT_BUFFER_FULL_DIAGNOSTIC, INPUT_BUFFERED_DIAGNOSTIC, InputRefusal,
        LayoutKey, NewSessionDraft, NewSessionKind, NewWorktreeMode, PendingUiInput, ProjectDialog,
        QueuedUiInput, SessionGroup, SessionGroupKey, SessionRowAction, SettingsDialog,
        SettingsPane, SshField, SshHostEditor, TERMINAL_NOTICE_DURATION, TerminalKeyIdentity,
        TerminalKeyboard, TerminalPointer, TerminalResize, TransientNotice, UI_INPUT_BYTE_CAPACITY,
        UI_INPUT_CAPACITY, WheelBatch, WorktreeAuthority, WorktreeHostAccess, WorktreeOpenContext,
        WorktreeOpenMode, WorktreeOpenTarget, WorktreePresentation, WorktreeRemoveTarget,
        WorktreeSessionPresence, WorktreeSocket, active_session_selection,
        adjacent_appearance_field, appearance_draft_is_persistable, appearance_preview_color,
        application_navigation_width, apply_new_worktree_failure, apply_worktree_removal_failure,
        available_herdr_row_actions, can_create_worktree, can_kill_worktree,
        canonical_terminal_key_with, clear_terminal_input_state, clears_after_input_delivery,
        clears_when_input_queue_is_empty, coalesce_last_resize, coalesce_last_wheel,
        has_ambiguous_worktree_source, herdr_row_actions, herdr_session_menu_actions,
        host_header_action, host_landing_text, input_queue_has_capacity,
        is_toggle_sidebar_shortcut, kill_confirmation_description, kill_confirmation_title,
        kwt_operation_failure_owns_dialog, named_key, new_session_validation, normalize_cell_width,
        owns_created_worktree_navigation, pull_request_import_selector,
        queued_input_matches_presentation, retained_key_event_with, session_action_menu_position,
        session_backend_id, session_creation_available, session_group_visibility,
        session_row_element_id, ssh_host_subtitle, ssh_prompt_input_text,
        terminal_cell_at_with_offset, terminal_key_input, terminal_key_input_with_canonical,
        terminal_line_height, terminal_wheel_steps, tmux_row_actions, toggle_session_group_state,
        transitioned_presentation, tree_herdr_sessions, tree_sessions, tree_zellij_sessions,
        visible_kwt_branch_candidates, visible_kwt_pull_requests, workspace_window_title,
        worktree_open_mode,
    };
    use model::DiagnosticKind;
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use surface::{GridSize, SurfaceFrame, SurfaceStore};
    use workspace::{
        AppearanceSettingsDraft, HerdrSessionItem, HerdrSessionState, HostConnectionState,
        HostDiagnostic, HostItem, KeyEvent, KeyInput, KwtBranchItem, KwtPullRequestItem, Modifiers,
        MouseAction, MouseButton, MouseInput, NamedKey, ProjectItem, SessionItem, SessionSelection,
        SshHostDraft, TerminalTheme, WorkspaceContent, WorkspaceSnapshot, WorktreeItem,
    };

    #[test]
    fn terminal_notice_expires_once_per_presentation_and_message() {
        let now = Instant::now();
        let mut notice = TransientNotice::default();

        notice.synchronize(Some(7), Some("reduced color"), true, now);
        assert_eq!(notice.visible(), Some("reduced color"));
        assert!(
            !notice.expire(now + TERMINAL_NOTICE_DURATION.saturating_sub(Duration::from_millis(1)))
        );
        assert!(notice.expire(now + TERMINAL_NOTICE_DURATION));
        assert_eq!(notice.visible(), None);

        notice.synchronize(
            Some(7),
            Some("reduced color"),
            true,
            now + TERMINAL_NOTICE_DURATION,
        );
        assert_eq!(notice.visible(), None);
        notice.synchronize(None, None, false, now + TERMINAL_NOTICE_DURATION);
        notice.synchronize(
            Some(8),
            Some("reduced color"),
            true,
            now + TERMINAL_NOTICE_DURATION,
        );
        assert_eq!(notice.visible(), Some("reduced color"));
    }

    #[test]
    fn operational_failure_notice_remains_visible_until_cleared() {
        let now = Instant::now();
        let mut notice = TransientNotice::default();

        notice.synchronize(None, Some("session launch failed"), false, now);
        assert_eq!(notice.visible(), Some("session launch failed"));
        assert!(!notice.expire(now + TERMINAL_NOTICE_DURATION * 10));
        assert_eq!(notice.visible(), Some("session launch failed"));

        notice.synchronize(None, None, false, now + TERMINAL_NOTICE_DURATION * 10);
        assert_eq!(notice.visible(), None);
    }

    #[test]
    fn settings_shell_opens_the_appearance_pane_without_a_transient_host_editor() {
        let appearance = AppearanceSettingsDraft {
            theme: TerminalTheme::Custom,
            font_family: "Cascadia Mono".to_owned(),
            font_size: "14".to_owned(),
            background: "#0c0f14".to_owned(),
            foreground: "#d8dee9".to_owned(),
        };
        let dialog = SettingsDialog::new(&[], appearance.clone(), vec!["Cascadia Mono".to_owned()]);

        assert_eq!(
            SettingsPane::ALL,
            [SettingsPane::Appearance, SettingsPane::Hosts]
        );
        assert_eq!(dialog.pane, SettingsPane::Appearance);
        assert_eq!(dialog.appearance_editor.draft, appearance);
        assert!(dialog.selected_host_id.is_none());
        assert!(dialog.host_editor.is_none());
        assert!(dialog.pending_remove.is_none());
    }

    #[test]
    fn appearance_fields_follow_tab_order_and_preview_only_accepts_rgb_hex() {
        assert_eq!(
            adjacent_appearance_field(AppearanceField::Theme, false, false),
            AppearanceField::FontFamily
        );
        assert_eq!(
            adjacent_appearance_field(AppearanceField::Theme, true, false),
            AppearanceField::FontSize
        );
        assert_eq!(
            adjacent_appearance_field(AppearanceField::Theme, true, true),
            AppearanceField::Foreground
        );
        assert_eq!(appearance_preview_color("#102030", 0), 0x10_20_30);
        assert_eq!(appearance_preview_color("102030", 0x12_34_56), 0x12_34_56);
    }

    #[test]
    fn appearance_auto_persistence_waits_for_complete_custom_colors() {
        let mut draft = AppearanceSettingsDraft {
            theme: TerminalTheme::ClearDark,
            font_family: "Cascadia Mono".to_owned(),
            font_size: "14".to_owned(),
            background: "#12".to_owned(),
            foreground: "#d8dee9".to_owned(),
        };

        assert!(appearance_draft_is_persistable(&draft));
        draft.theme = TerminalTheme::Custom;
        assert!(!appearance_draft_is_persistable(&draft));
        draft.background = "#102030".to_owned();
        assert!(appearance_draft_is_persistable(&draft));
        draft.font_size = "0".to_owned();
        assert!(!appearance_draft_is_persistable(&draft));
    }

    #[test]
    fn new_host_editor_and_endpoint_subtitle_preserve_optional_authority() {
        let mut editor = SshHostEditor::new(None);
        editor.draft.name = "Build host".to_owned();
        editor.draft.hostname = "build.internal".to_owned();
        editor.draft.user = "wesm".to_owned();
        editor.draft.port = "2222".to_owned();

        assert_eq!(editor.original_id, None);
        assert_eq!(ssh_host_subtitle(&editor.draft), "wesm@build.internal:2222");
        assert_eq!(
            ssh_host_subtitle(&SshHostDraft {
                hostname: "studio.local".to_owned(),
                ..SshHostDraft::default()
            }),
            "studio.local"
        );
    }

    #[test]
    fn ssh_host_fields_follow_tab_order_in_both_directions() {
        let fields = [
            SshField::Name,
            SshField::Hostname,
            SshField::User,
            SshField::Port,
            SshField::TmuxBinary,
            SshField::SocketDirectory,
        ];

        for (index, field) in fields.iter().copied().enumerate() {
            assert_eq!(field.adjacent(false), fields[(index + 1) % fields.len()]);
            assert_eq!(
                field.adjacent(true),
                fields[(index + fields.len() - 1) % fields.len()]
            );
        }
    }

    #[test]
    fn ambiguous_existing_branch_requires_an_explicit_source() {
        let mut dialog = ProjectDialog::NewWorktree {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            repository: "github.com/acme/widget".to_owned(),
            project_name: "widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            branch: "topic".to_owned(),
            mode: NewWorktreeMode::Branch,
            selected_source: None,
            selected_pull_request: None,
            branches: vec![
                KwtBranchItem::new("topic", "topic", false),
                KwtBranchItem::new("topic", "origin/topic", true),
            ],
            pull_requests: Vec::new(),
            operation_id: Some(1),
            loading: false,
            loaded: true,
            submitting: false,
            error: None,
        };

        assert!(has_ambiguous_worktree_source(&dialog));
        if let ProjectDialog::NewWorktree {
            selected_source, ..
        } = &mut dialog
        {
            *selected_source = Some("origin/topic".to_owned());
        }
        assert!(!has_ambiguous_worktree_source(&dialog));
    }

    #[test]
    fn worktree_creation_requires_successful_branch_inventory() {
        assert!(!can_create_worktree("feature/new", false, false, false));
        assert!(!can_create_worktree("feature/new", true, true, false));
        assert!(can_create_worktree("feature/new", true, false, false));
    }

    #[test]
    fn generationless_worktrees_attach_only_to_a_live_discovered_tmux_session() {
        assert_eq!(
            worktree_open_mode(WorktreeOpenContext {
                authority: WorktreeAuthority::Generationless,
                socket: WorktreeSocket::Default,
                session: WorktreeSessionPresence::Discovered,
                presentation: WorktreePresentation::Inactive,
                host: WorktreeHostAccess::Ready {
                    kwt_available: true,
                },
            }),
            WorktreeOpenMode::DirectTmux
        );
        assert_eq!(
            worktree_open_mode(WorktreeOpenContext {
                authority: WorktreeAuthority::Generationless,
                socket: WorktreeSocket::Default,
                session: WorktreeSessionPresence::Absent,
                presentation: WorktreePresentation::Inactive,
                host: WorktreeHostAccess::Ready {
                    kwt_available: true,
                },
            }),
            WorktreeOpenMode::Disabled
        );
        assert_eq!(
            worktree_open_mode(WorktreeOpenContext {
                authority: WorktreeAuthority::Generation,
                socket: WorktreeSocket::Default,
                session: WorktreeSessionPresence::Absent,
                presentation: WorktreePresentation::Inactive,
                host: WorktreeHostAccess::Ready {
                    kwt_available: true,
                },
            }),
            WorktreeOpenMode::RepairOrOpen
        );
    }

    #[test]
    fn retained_worktrees_reactivate_without_current_host_or_kwt_authority() {
        for (authority, socket) in [
            (WorktreeAuthority::Generation, WorktreeSocket::Default),
            (WorktreeAuthority::Generation, WorktreeSocket::Custom),
            (WorktreeAuthority::Generationless, WorktreeSocket::Default),
        ] {
            assert_eq!(
                worktree_open_mode(WorktreeOpenContext {
                    authority,
                    socket,
                    session: WorktreeSessionPresence::Absent,
                    presentation: WorktreePresentation::ActiveOrRetained,
                    host: WorktreeHostAccess::Unavailable,
                }),
                WorktreeOpenMode::DirectTmux
            );
        }
    }

    #[test]
    fn exact_branch_sources_are_ranked_ahead_of_the_fuzzy_limit() {
        let mut branches = (0..9)
            .map(|index| {
                workspace::KwtBranchItem::new(
                    format!("topic-{index}"),
                    format!("origin/topic-{index}"),
                    true,
                )
            })
            .collect::<Vec<_>>();
        branches.extend([
            workspace::KwtBranchItem::new("topic", "topic", false),
            workspace::KwtBranchItem::new("topic", "origin/topic", true),
        ]);

        let visible = visible_kwt_branch_candidates(&branches, "topic");
        let sources = visible
            .iter()
            .map(|candidate| candidate.source())
            .collect::<Vec<_>>();

        assert_eq!(&sources[..2], &["topic", "origin/topic"]);
        assert_eq!(sources.len(), 7);
    }

    #[test]
    fn every_ambiguous_exact_branch_source_remains_selectable() {
        let branches = (0..10)
            .map(|index| {
                workspace::KwtBranchItem::new("topic", format!("remote-{index}/topic"), true)
            })
            .collect::<Vec<_>>();

        let visible = visible_kwt_branch_candidates(&branches, "topic");

        assert_eq!(visible.len(), branches.len());
    }

    #[test]
    fn protected_generation_backed_worktrees_use_kwt_attach() {
        assert_eq!(
            worktree_open_mode(WorktreeOpenContext {
                authority: WorktreeAuthority::Generation,
                socket: WorktreeSocket::Custom,
                session: WorktreeSessionPresence::Absent,
                presentation: WorktreePresentation::Inactive,
                host: WorktreeHostAccess::Ready {
                    kwt_available: true,
                },
            }),
            WorktreeOpenMode::RepairOrOpen
        );
    }

    #[test]
    fn protected_worktrees_offer_fresh_named_socket_kill_capture() {
        assert!(can_kill_worktree(
            true,
            WorktreeSocket::Custom,
            WorktreeSessionPresence::Absent,
            WorktreeAuthority::Generation,
        ));
        assert!(!can_kill_worktree(
            false,
            WorktreeSocket::Custom,
            WorktreeSessionPresence::Absent,
            WorktreeAuthority::Generation,
        ));
        assert!(!can_kill_worktree(
            true,
            WorktreeSocket::Custom,
            WorktreeSessionPresence::Absent,
            WorktreeAuthority::Generationless,
        ));
        assert!(!can_kill_worktree(
            true,
            WorktreeSocket::Default,
            WorktreeSessionPresence::Absent,
            WorktreeAuthority::Generationless,
        ));
    }

    #[test]
    fn pull_requests_filter_by_provider_owned_fields() {
        let pull_requests = vec![
            KwtPullRequestItem::new(
                "github:github.com/acme/widget#17",
                17,
                "https://github.com/acme/widget/pull/17",
                "Improve rendering",
                "octocat",
                "feature/rendering",
                false,
                false,
            ),
            KwtPullRequestItem::new(
                "github:github.com/acme/widget#42",
                42,
                "https://github.com/acme/widget/pull/42",
                "Fix startup",
                "hubot",
                "fix/startup",
                true,
                true,
            ),
        ];
        for query in ["17", "rendering", "octocat", "feature/rendering", "pull/17"] {
            assert_eq!(
                visible_kwt_pull_requests(&pull_requests, query),
                [&pull_requests[0]]
            );
        }
        assert_eq!(
            visible_kwt_pull_requests(&pull_requests, "42"),
            [&pull_requests[1]]
        );
        assert_eq!(
            pull_request_import_selector(&pull_requests, "Improve rendering", None),
            None,
            "filter text is not an import selector"
        );
        assert_eq!(
            pull_request_import_selector(
                &pull_requests,
                "github:github.com/acme/widget#17",
                Some("github:github.com/acme/widget#17"),
            ),
            Some("github:github.com/acme/widget#17".to_owned())
        );
        assert_eq!(
            pull_request_import_selector(&pull_requests, "#42", None),
            Some("42".to_owned())
        );
        assert_eq!(
            pull_request_import_selector(
                &pull_requests,
                " https://github.com/acme/widget/pull/17 ",
                None,
            ),
            Some("https://github.com/acme/widget/pull/17".to_owned())
        );
    }

    #[test]
    fn worktree_failures_require_the_dialogs_exact_operation_and_target() {
        let create = ProjectDialog::NewWorktree {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            repository: "github.com/acme/widget".to_owned(),
            project_name: "widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            branch: "topic".to_owned(),
            mode: NewWorktreeMode::Branch,
            selected_source: None,
            selected_pull_request: None,
            branches: Vec::new(),
            pull_requests: Vec::new(),
            operation_id: Some(7),
            loading: false,
            loaded: true,
            submitting: true,
            error: None,
        };
        assert!(kwt_operation_failure_owns_dialog(
            Some(&create),
            7,
            "/code/widget",
            None,
        ));
        assert!(kwt_operation_failure_owns_dialog(
            Some(&create),
            7,
            "/code/widget",
            Some("/work/widget/imported-pr"),
        ));
        assert!(!kwt_operation_failure_owns_dialog(
            Some(&create),
            6,
            "/code/widget",
            None,
        ));

        let remove = ProjectDialog::RemoveWorktree {
            target: WorktreeRemoveTarget {
                open: WorktreeOpenTarget {
                    host_id: "wsl".to_owned(),
                    endpoint: "Ubuntu".to_owned(),
                    repository: "github.com/acme/widget".to_owned(),
                    project_path: "/code/widget".to_owned(),
                    registration_fingerprint: "registration".to_owned(),
                    worktree_path: "/work/widget/topic".to_owned(),
                    generation: Some("11111111111111111111111111111111".to_owned()),
                    session_name: "widget-topic".to_owned(),
                    tmux_socket_name: None,
                },
                project_name: "widget".to_owned(),
                branch: "topic".to_owned(),
                session_was_running: false,
                authority: Some(9),
                operation_id: Some(9),
            },
            submitting: true,
            error: None,
        };
        assert!(kwt_operation_failure_owns_dialog(
            Some(&remove),
            9,
            "/code/widget",
            Some("/work/widget/topic"),
        ));
        assert!(!kwt_operation_failure_owns_dialog(
            Some(&remove),
            9,
            "/code/widget",
            Some("/work/widget/other"),
        ));

        let mut failed = remove;
        assert!(apply_worktree_removal_failure(
            &mut failed,
            9,
            "/code/widget",
            Some("/work/widget/topic"),
            "remove failed".to_owned(),
        ));
        let ProjectDialog::RemoveWorktree {
            target,
            submitting,
            error,
        } = failed
        else {
            panic!("removal dialog remains active");
        };
        assert!(!submitting);
        assert_eq!(target.authority, None);
        assert_eq!(target.operation_id, None);
        assert_eq!(error.as_deref(), Some("remove failed"));
    }

    #[test]
    fn failed_worktree_creation_keeps_loaded_branches_retryable() {
        let mut dialog = ProjectDialog::NewWorktree {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            repository: "github.com/acme/widget".to_owned(),
            project_name: "widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            branch: "testing".to_owned(),
            mode: NewWorktreeMode::Branch,
            selected_source: None,
            selected_pull_request: None,
            branches: Vec::new(),
            pull_requests: Vec::new(),
            operation_id: Some(7),
            loading: false,
            loaded: true,
            submitting: true,
            error: None,
        };

        assert!(apply_new_worktree_failure(
            &mut dialog,
            7,
            "/code/widget",
            "branch already exists".to_owned(),
        ));

        let ProjectDialog::NewWorktree {
            loaded,
            submitting,
            error,
            ..
        } = dialog
        else {
            panic!("new-worktree dialog remains active");
        };
        assert!(loaded, "successful branch inventory remains reusable");
        assert!(!submitting);
        assert_eq!(error.as_deref(), Some("branch already exists"));
        assert!(can_create_worktree("testing2", loaded, false, submitting));
    }

    #[test]
    fn delayed_worktree_creation_does_not_override_newer_navigation_or_dialogs() {
        assert!(owns_created_worktree_navigation(
            Some(7),
            7,
            true,
            Some("/code/widget"),
            "/code/widget",
        ));
        assert!(!owns_created_worktree_navigation(
            Some(7),
            7,
            false,
            None,
            "/code/widget",
        ));
        assert!(!owns_created_worktree_navigation(
            Some(7),
            7,
            true,
            Some("/code/other"),
            "/code/widget",
        ));
        assert!(!owns_created_worktree_navigation(
            Some(8),
            7,
            true,
            None,
            "/code/widget",
        ));
    }

    #[test]
    fn new_session_dialog_matches_the_shipped_name_and_duplicate_rules() {
        let snapshot = WorkspaceSnapshot::shell(
            workspace::Appearance::default(),
            vec![HostItem::wsl(
                "Ubuntu",
                None,
                HostConnectionState::Ready,
                vec![SessionItem::new("existing", 0)],
                None,
            )],
        );
        let mut draft = NewSessionDraft {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            kind: NewSessionKind::Tmux,
            name: String::new(),
        };

        assert_eq!(new_session_validation(&snapshot, &draft), None);
        draft.name = "has.period".to_owned();
        assert_eq!(
            new_session_validation(&snapshot, &draft).as_deref(),
            Some("Use 1–100 characters without #, periods, colons, or line breaks.")
        );
        draft.name = "#(touch /tmp/ghosthub-owned)".to_owned();
        assert_eq!(
            new_session_validation(&snapshot, &draft).as_deref(),
            Some("Use 1–100 characters without #, periods, colons, or line breaks.")
        );
        draft.name = "existing".to_owned();
        assert_eq!(
            new_session_validation(&snapshot, &draft).as_deref(),
            Some("A tmux session with this name already exists on this host.")
        );
        draft.name = "  release work  ".to_owned();
        assert_eq!(new_session_validation(&snapshot, &draft), None);

        let refreshing = WorkspaceSnapshot::shell(
            workspace::Appearance::default(),
            vec![HostItem::wsl(
                "Ubuntu",
                None,
                HostConnectionState::Connecting,
                vec![SessionItem::new("existing", 0)],
                None,
            )],
        );
        assert_eq!(new_session_validation(&refreshing, &draft), None);
        draft.endpoint = "Debian".to_owned();
        assert!(new_session_validation(&refreshing, &draft).is_some());

        let connecting_ssh = WorkspaceSnapshot::shell(
            workspace::Appearance::default(),
            vec![HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Connecting,
                vec![SessionItem::new("existing", 0)],
                None,
            )],
        );
        draft.host_id = "ssh:studio".to_owned();
        draft.endpoint = "studio.example".to_owned();
        assert_eq!(
            new_session_validation(&connecting_ssh, &draft).as_deref(),
            Some("Wait for the SSH host connection before creating a session.")
        );
    }

    #[test]
    fn collapsed_session_groups_are_scoped_to_the_host_and_backend() {
        let mut collapsed = HashSet::new();

        toggle_session_group_state(&mut collapsed, "ssh:studio", SessionGroup::Tmux);

        assert!(collapsed.contains(&SessionGroupKey {
            host_id: "ssh:studio".to_owned(),
            group: SessionGroup::Tmux,
        }));
        assert!(!collapsed.contains(&SessionGroupKey {
            host_id: "ssh:studio".to_owned(),
            group: SessionGroup::Herdr,
        }));
        assert!(!collapsed.contains(&SessionGroupKey {
            host_id: "wsl".to_owned(),
            group: SessionGroup::Tmux,
        }));

        toggle_session_group_state(&mut collapsed, "ssh:studio", SessionGroup::Tmux);
        assert!(collapsed.is_empty());
    }

    #[test]
    fn remote_tmux_rows_open_without_exposing_unimplemented_mutations() {
        let host = HostItem::ssh(
            "ssh:wesm@studio.example:",
            "Studio",
            "wesm@studio.example",
            HostConnectionState::Ready,
            vec![SessionItem::new("build", 0)],
            None,
        );

        let rows = tree_sessions(&host, None, &[]);

        assert_eq!(rows.len(), 1);
        assert!(rows[0].state.can_open());
        assert!(!rows[0].state.can_kill());
    }

    #[test]
    fn connecting_hosts_apply_transport_specific_cached_action_policy() {
        let wsl = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Connecting,
            vec![SessionItem::new("local", 0)],
            None,
        );
        let ssh = HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Connecting,
            vec![SessionItem::new("remote", 0)],
            None,
        );

        let wsl_rows = tree_sessions(&wsl, None, &[]);
        let ssh_rows = tree_sessions(&ssh, None, &[]);

        assert!(wsl_rows[0].state.can_open());
        assert!(wsl_rows[0].state.can_kill());
        assert!(session_creation_available(&wsl, NewSessionKind::Tmux));
        assert!(!ssh_rows[0].state.can_open());
        assert!(!ssh_rows[0].state.can_kill());
        assert!(!session_creation_available(&ssh, NewSessionKind::Tmux));
    }

    #[test]
    fn remote_tmux_failure_keeps_optional_multiplexer_groups_usable() {
        let host = HostItem::ssh(
            "ssh:wesm@studio.example:",
            "Studio",
            "wesm@studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )
        .with_tmux_diagnostic(workspace::HostDiagnostic::new(
            model::DiagnosticKind::ExecutableNotFound,
            "tmux is unavailable",
        ))
        .with_herdr_sessions(vec![workspace::HerdrSessionItem::new(
            "agents",
            false,
            workspace::HerdrSessionState::Running,
        )])
        .with_zellij_sessions(vec![SessionItem::new("review", 0)]);

        let herdr = tree_herdr_sessions(&host, None, &[]);
        let zellij = tree_zellij_sessions(&host, None, &[]);
        let groups = session_group_visibility(&host, &herdr, &zellij);

        assert_eq!(host.connection(), HostConnectionState::Ready);
        assert!(host.tmux_diagnostic().is_some());
        assert!(groups.tmux);
        assert!(groups.herdr);
        assert!(groups.zellij);
        assert!(herdr[0].access.can_open());
        assert!(zellij[0].state.can_open());
        assert_eq!(
            host_landing_text(&host),
            "Choose a session to open its terminal."
        );
    }

    #[test]
    fn a_refused_input_stays_visible_until_later_input_is_delivered() {
        assert!(clears_when_input_queue_is_empty(Some(
            INPUT_BUFFERED_DIAGNOSTIC
        )));
        assert!(!clears_when_input_queue_is_empty(Some(
            INPUT_BUFFER_FULL_DIAGNOSTIC
        )));

        let mut refusal = InputRefusal::default();
        let older_input = refusal.acceptance_marker();
        refusal.refuse();
        assert!(!refusal.delivered(older_input));
        assert!(refusal.is_pending());

        let later_input = refusal.acceptance_marker();
        assert!(refusal.delivered(later_input));
        assert!(!refusal.is_pending());
        assert!(!clears_after_input_delivery(
            Some("terminal exited"),
            true,
            false
        ));
        assert!(clears_after_input_delivery(
            Some(INPUT_BUFFER_FULL_DIAGNOSTIC),
            true,
            false
        ));
    }

    #[test]
    fn gpui_keypad_names_preserve_keypad_identity() {
        assert_eq!(named_key("numpad7"), Some(NamedKey::KeypadDigit(7)));
        assert_eq!(named_key("kpenter"), Some(NamedKey::KeypadEnter));
        assert_eq!(named_key("numpadadd"), Some(NamedKey::KeypadAdd));
    }

    #[test]
    fn terminal_and_attaching_states_expose_the_active_selection() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let terminal = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: workspace::SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        let attaching = WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "other".to_owned(),
            kind: workspace::SessionKind::Tmux,
        };
        let herdr = WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "agent".to_owned(),
            kind: workspace::SessionKind::Herdr,
        };

        assert_eq!(
            active_session_selection(&terminal),
            Some(SessionSelection::new("wsl", "Ubuntu", "work"))
        );
        assert_eq!(
            active_session_selection(&attaching),
            Some(SessionSelection::new("wsl", "Ubuntu", "other"))
        );
        assert_eq!(
            active_session_selection(&herdr),
            Some(SessionSelection::herdr("wsl", "Ubuntu", "agent"))
        );
        assert_eq!(active_session_selection(&WorkspaceContent::Shell), None);
    }

    #[test]
    fn active_terminal_context_moves_into_the_native_window_title() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let terminal = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "demo".to_owned(),
            kind: workspace::SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        let attaching = WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "demo".to_owned(),
            kind: workspace::SessionKind::Tmux,
        };

        assert_eq!(
            workspace_window_title(&terminal),
            "demo — Ubuntu — Ghosthub"
        );
        assert_eq!(
            workspace_window_title(&attaching),
            "demo — Ubuntu — Ghosthub"
        );
        assert_eq!(workspace_window_title(&WorkspaceContent::Shell), "Ghosthub");
    }

    #[test]
    fn cached_and_active_sessions_stay_in_the_tree_while_the_host_refreshes_or_fails() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let terminal = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "demo".to_owned(),
            kind: workspace::SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        for state in [
            HostConnectionState::Connecting,
            HostConnectionState::Unavailable,
        ] {
            let host = HostItem::wsl(
                "Ubuntu",
                None,
                state,
                vec![SessionItem::new("other", 0)],
                None,
            );

            let active = active_session_selection(&terminal);
            let rows = tree_sessions(&host, active.as_ref(), &[]);
            assert_eq!(rows.len(), 2);
            assert_eq!(rows[0].selection.session(), "other");
            assert!(!rows[0].state.is_active());
            assert_eq!(
                rows[0].state.can_open(),
                state == HostConnectionState::Connecting
            );
            assert_eq!(
                rows[0].state.can_kill(),
                state == HostConnectionState::Connecting
            );
            assert_eq!(rows[1].selection.session(), "demo");
            assert!(rows[1].state.is_active());
            assert!(rows[1].state.can_open());
        }
    }

    #[test]
    fn project_owned_tmux_sessions_are_not_duplicated_in_the_unbound_group() {
        let host = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Ready,
            vec![
                SessionItem::new("project-main", 0),
                SessionItem::new("scratch", 0),
                SessionItem::new("custom-socket", 0),
            ],
            None,
        )
        .with_kwt_inventory(
            vec![ProjectItem::new(
                "project-id",
                "project",
                "/repos/project",
                "project-fingerprint",
                vec![
                    WorktreeItem::new(
                        "/repos/project",
                        "main",
                        true,
                        None,
                        "project-main",
                        None,
                        true,
                    ),
                    WorktreeItem::new(
                        "/repos/project-topic",
                        "topic",
                        false,
                        None,
                        "custom-socket",
                        Some("project-socket".to_owned()),
                        false,
                    ),
                ],
            )],
            Vec::new(),
        );

        let rows = tree_sessions(&host, None, &[]);

        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|row| row.selection.session() == "scratch"));
        assert!(
            rows.iter()
                .any(|row| row.selection.session() == "custom-socket"),
            "a custom-socket worktree cannot claim a default-socket tmux row"
        );
    }

    #[test]
    fn active_protected_worktree_is_shown_only_under_its_project() {
        let host = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Ready,
            vec![
                SessionItem::new("scratch", 0),
                SessionItem::new("project-pr-17", 0),
            ],
            None,
        )
        .with_kwt_inventory(
            vec![ProjectItem::new(
                "project-id",
                "project",
                "/repos/project",
                "project-fingerprint",
                vec![WorktreeItem::new(
                    "/repos/project-pr",
                    "pr-17",
                    false,
                    Some("0123456789abcdef0123456789abcdef".to_owned()),
                    "project-pr-17",
                    Some("kwt-pr-0123456789abcdef".to_owned()),
                    false,
                )],
            )],
            Vec::new(),
        );
        let active = SessionSelection::protected_worktree(
            "wsl",
            "Ubuntu",
            "project-pr-17",
            "kwt-pr-0123456789abcdef",
            "/repos/project-pr",
            "0123456789abcdef0123456789abcdef",
        );
        let rows = tree_sessions(&host, Some(&active), &[]);

        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|row| row.selection.session() == "scratch"));
        let same_named_default = rows
            .iter()
            .find(|row| row.selection.session() == "project-pr-17")
            .expect("separate default-socket session stays visible");
        assert!(!same_named_default.state.is_active());

        let changed_inventory =
            HostItem::wsl("Ubuntu", None, HostConnectionState::Ready, Vec::new(), None)
                .with_kwt_inventory(
                    vec![ProjectItem::new(
                        "project-id",
                        "project",
                        "/repos/project",
                        "project-fingerprint",
                        vec![WorktreeItem::new(
                            "/repos/project-pr",
                            "pr-17",
                            false,
                            Some("0123456789abcdef0123456789abcdef".to_owned()),
                            "project-pr-17",
                            Some("kwt-pr-replacement".to_owned()),
                            false,
                        )],
                    )],
                    Vec::new(),
                );
        let fallback_rows = tree_sessions(&changed_inventory, Some(&active), &[]);
        assert_eq!(fallback_rows.len(), 1);
        assert_eq!(fallback_rows[0].selection, active);
        assert!(fallback_rows[0].state.is_active());
    }

    #[test]
    fn host_connection_actions_stay_on_the_host_row() {
        assert_eq!(
            host_header_action(HostConnectionState::Disconnected),
            HostHeaderAction::Connect
        );
        assert_eq!(
            host_header_action(HostConnectionState::Connecting),
            HostHeaderAction::Cancel
        );
        assert_eq!(
            host_header_action(HostConnectionState::Ready),
            HostHeaderAction::Refresh
        );
        assert_eq!(
            host_header_action(HostConnectionState::Unavailable),
            HostHeaderAction::Retry
        );
    }

    #[test]
    fn retained_and_active_herdr_sessions_survive_unavailable_inventory() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let active = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "active".to_owned(),
            kind: workspace::SessionKind::Herdr,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        let host = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Unavailable,
            Vec::new(),
            None,
        );
        let retained = vec![SessionSelection::herdr(
            "wsl",
            "Ubuntu-Previous",
            "retained",
        )];

        let active = active_session_selection(&active);
        let rows = tree_herdr_sessions(&host, active.as_ref(), &retained);

        assert_eq!(rows.len(), 2);
        assert!(session_group_visibility(&host, &rows, &[]).herdr);
        assert_eq!(rows[0].selection.session(), "retained");
        assert!(rows[0].show_endpoint);
        assert!(rows[0].inventory.is_none());
        assert!(rows[0].access.can_open());
        assert!(!rows[0].access.can_mutate());
        assert_eq!(rows[1].selection.session(), "active");
        assert!(rows[1].active);
        assert!(rows[1].inventory.is_none());
        assert!(rows[1].access.can_open());
        assert!(!rows[1].access.can_mutate());
    }

    #[test]
    fn unavailable_cached_herdr_sessions_are_visible_but_not_actionable() {
        let host = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Unavailable,
            Vec::new(),
            None,
        )
        .with_herdr_sessions(vec![HerdrSessionItem::new(
            "cached",
            false,
            HerdrSessionState::Stopped,
        )]);

        let rows = tree_herdr_sessions(&host, None, &[]);

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].selection.session(), "cached");
        assert!(!rows[0].access.can_open());
        assert!(!rows[0].access.can_mutate());
    }

    #[test]
    fn remote_herdr_sessions_allow_attach_and_constructive_restart_only() {
        let host = HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )
        .with_herdr_sessions(vec![
            HerdrSessionItem::new("review", false, HerdrSessionState::Running),
            HerdrSessionItem::new("stopped", false, HerdrSessionState::Stopped),
        ]);

        let rows = tree_herdr_sessions(&host, None, &[]);

        assert_eq!(rows.len(), 2);
        assert!(rows[0].access.can_open());
        assert!(rows[0].access.can_restart());
        assert!(!rows[0].access.can_mutate());
        assert!(rows[1].access.can_restart());
        assert_eq!(
            available_herdr_row_actions(
                rows[1].access,
                rows[1].inventory.as_ref().expect("inventory")
            ),
            vec![HerdrRowAction::Restart]
        );
    }

    #[test]
    fn remote_zellij_sessions_are_openable_without_remote_kill_authority() {
        let host = HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )
        .with_zellij_sessions(vec![workspace::SessionItem::new("review", 0)]);

        let rows = tree_zellij_sessions(&host, None, &[]);

        assert_eq!(rows.len(), 1);
        assert!(rows[0].state.can_open());
        assert!(!rows[0].state.can_kill());
    }

    #[test]
    fn ready_remote_hosts_offer_constructive_herdr_and_zellij_actions() {
        let host = HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )
        .with_herdr_sessions(vec![HerdrSessionItem::new(
            "default",
            true,
            HerdrSessionState::Stopped,
        )])
        .with_zellij_sessions(Vec::new());

        assert!(session_creation_available(&host, NewSessionKind::Herdr));
        assert!(session_creation_available(&host, NewSessionKind::Zellij));
        assert!(!session_creation_available(&host, NewSessionKind::Tmux));
    }

    #[test]
    fn retained_and_active_zellij_sessions_survive_unavailable_inventory() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let active = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "active".to_owned(),
            kind: workspace::SessionKind::Zellij,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        let host = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Unavailable,
            Vec::new(),
            None,
        );
        let retained = vec![SessionSelection::zellij(
            "wsl",
            "Ubuntu-Previous",
            "retained",
        )];

        let active = active_session_selection(&active);
        let rows = tree_zellij_sessions(&host, active.as_ref(), &retained);

        assert_eq!(rows.len(), 2);
        assert!(session_group_visibility(&host, &[], &rows).zellij);
        assert_eq!(rows[0].selection.session(), "retained");
        assert!(rows[0].show_endpoint);
        assert!(rows[0].state.can_open());
        assert!(!rows[0].state.can_kill());
        assert_eq!(rows[1].selection.session(), "active");
        assert!(rows[1].state.is_active());
        assert!(rows[1].state.can_open());
        assert!(!rows[1].state.can_kill());
    }

    #[test]
    fn failed_current_zellij_inventory_exposes_cached_rows_only() {
        let host = HostItem::wsl("Ubuntu", None, HostConnectionState::Ready, Vec::new(), None)
            .with_zellij_sessions(vec![workspace::SessionItem::new("cached", 0)])
            .with_zellij_diagnostic(HostDiagnostic::new(
                DiagnosticKind::MalformedOutput,
                "invalid Zellij inventory",
            ));

        let rows = tree_zellij_sessions(&host, None, &[]);

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].selection.session(), "cached");
        assert!(!rows[0].state.can_open());
        assert!(!rows[0].state.can_kill());
    }

    #[test]
    fn failed_current_herdr_inventory_exposes_cached_rows_only() {
        let host = HostItem::wsl("Ubuntu", None, HostConnectionState::Ready, Vec::new(), None)
            .with_herdr_sessions(vec![HerdrSessionItem::new(
                "cached",
                false,
                HerdrSessionState::Running,
            )])
            .with_herdr_diagnostic(HostDiagnostic::new(
                DiagnosticKind::MalformedOutput,
                "invalid Herdr inventory",
            ));

        let rows = tree_herdr_sessions(&host, None, &[]);

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].access, HerdrRowAccess::Cached);
        assert!(!rows[0].access.can_open());
        assert!(!rows[0].access.can_mutate());
    }

    #[test]
    fn herdr_rows_expose_state_appropriate_lifecycle_actions() {
        let running = HerdrSessionItem::new("running", false, HerdrSessionState::Running);
        let default = HerdrSessionItem::new("default", true, HerdrSessionState::Stopped);
        let stopped = HerdrSessionItem::new("review", false, HerdrSessionState::Stopped);

        assert_eq!(herdr_row_actions(&running), vec![HerdrRowAction::Stop]);
        assert_eq!(herdr_row_actions(&default), vec![HerdrRowAction::Restart]);
        assert_eq!(
            herdr_row_actions(&stopped),
            vec![HerdrRowAction::Restart, HerdrRowAction::Delete]
        );
    }

    #[test]
    fn active_session_menus_include_detach_without_losing_backend_lifecycle() {
        assert_eq!(
            tmux_row_actions(true, true),
            vec![SessionRowAction::Detach, SessionRowAction::KillSession]
        );
        assert_eq!(
            herdr_session_menu_actions(true, vec![HerdrRowAction::Stop]),
            vec![
                SessionRowAction::Detach,
                SessionRowAction::Herdr(HerdrRowAction::Stop)
            ]
        );
        assert_eq!(
            tmux_row_actions(false, true),
            vec![SessionRowAction::KillSession]
        );
    }

    #[test]
    fn session_action_menus_open_upward_and_stay_inside_the_viewport() {
        let (left, top) = session_action_menu_position(325.0, 695.0, 1_100.0, 720.0, 4);

        assert!((left - 177.0).abs() <= f32::EPSILON);
        assert!((top - 580.0).abs() <= f32::EPSILON);
        assert!(top + 112.0 <= 716.0);

        let (left, top) = session_action_menu_position(2.0, 2.0, 100.0, 80.0, 4);
        assert!((left - 4.0).abs() <= f32::EPSILON);
        assert!((top - 4.0).abs() <= f32::EPSILON);
    }

    #[test]
    fn multiplexer_rows_have_backend_scoped_interaction_ids() {
        assert_ne!(
            session_backend_id(workspace::SessionKind::Tmux),
            session_backend_id(workspace::SessionKind::Zellij)
        );
        assert_ne!(
            session_row_element_id(workspace::SessionKind::Tmux),
            session_row_element_id(workspace::SessionKind::Zellij)
        );
    }

    #[test]
    fn kill_confirmation_names_the_exact_endpoint() {
        let selection = SessionSelection::new("wsl", "Ubuntu-24.04", "release");

        assert_eq!(
            kill_confirmation_title(&selection),
            "Kill “release” on Ubuntu-24.04?"
        );
        assert_eq!(
            kill_confirmation_description(&selection),
            "This permanently terminates every window, pane, and process in this tmux session on Ubuntu-24.04."
        );
    }

    #[test]
    fn refreshed_endpoint_does_not_alias_an_active_session_with_the_same_name() {
        let size = GridSize::new(80, 24).expect("valid grid");
        let terminal = WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "demo".to_owned(),
            kind: workspace::SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(SurfaceFrame::blank(1, size))),
        };
        let host = HostItem::wsl(
            "Debian",
            None,
            HostConnectionState::Ready,
            vec![SessionItem::new("demo", 0)],
            None,
        );

        let active = active_session_selection(&terminal);
        let rows = tree_sessions(&host, active.as_ref(), &[]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].selection.endpoint(), "Debian");
        assert!(!rows[0].state.is_active());
        assert!(!rows[0].show_endpoint);
        assert_eq!(rows[1].selection.endpoint(), "Ubuntu");
        assert!(rows[1].state.is_active());
        assert!(rows[1].show_endpoint);
    }

    #[test]
    fn retained_session_from_a_previous_default_distro_is_endpoint_qualified() {
        let host = HostItem::wsl(
            "Debian",
            None,
            HostConnectionState::Ready,
            vec![SessionItem::new("demo", 0)],
            None,
        );
        let retained = vec![SessionSelection::new("wsl", "Ubuntu", "demo")];

        let rows = tree_sessions(&host, None, &retained);

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].selection.endpoint(), "Debian");
        assert!(!rows[0].show_endpoint);
        assert!(rows[0].state.can_kill());
        assert_eq!(rows[1].selection.endpoint(), "Ubuntu");
        assert!(rows[1].show_endpoint);
        assert!(rows[1].state.can_open());
        assert!(!rows[1].state.can_kill());
    }

    #[test]
    fn retained_sessions_stay_in_the_tree_while_the_host_is_unavailable() {
        let host = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Unavailable,
            Vec::new(),
            None,
        );
        let retained = vec![
            SessionSelection::new("wsl", "Ubuntu", "one"),
            SessionSelection::new("wsl", "Ubuntu", "two"),
        ];

        let rows = tree_sessions(&host, None, &retained);

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].selection.session(), "one");
        assert_eq!(rows[1].selection.session(), "two");
        assert!(rows.iter().all(|row| !row.state.is_active()));
        assert!(rows.iter().all(|row| row.state.can_open()));
        assert!(rows.iter().all(|row| !row.state.can_kill()));
    }

    #[test]
    fn disconnected_cached_sessions_are_visible_but_cannot_start_fresh_actions() {
        let host = HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Disconnected,
            vec![SessionItem::new("cached", 0)],
            None,
        );

        let rows = tree_sessions(&host, None, &[]);

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].selection.session(), "cached");
        assert!(!rows[0].state.can_open());
        assert!(!rows[0].state.can_kill());
    }

    #[test]
    fn terminal_hit_testing_accounts_for_titlebar_and_collapsible_navigation() {
        let size = GridSize::new(80, 24).expect("valid grid");

        assert!(
            (application_navigation_width(true, true) - APP_NAVIGATION_WIDTH).abs() < f32::EPSILON
        );
        assert!(application_navigation_width(false, true).abs() < f32::EPSILON);
        assert!(application_navigation_width(true, false).abs() < f32::EPSILON);
        assert_eq!(
            terminal_cell_at_with_offset(
                APP_NAVIGATION_WIDTH + 12.0,
                APP_TITLEBAR_HEIGHT + 8.0,
                APP_NAVIGATION_WIDTH,
                APP_TITLEBAR_HEIGHT,
                8.0,
                16.0,
                size
            ),
            Some((1, 0))
        );
        assert_eq!(
            terminal_cell_at_with_offset(
                APP_NAVIGATION_WIDTH - 1.0,
                APP_TITLEBAR_HEIGHT + 8.0,
                APP_NAVIGATION_WIDTH,
                APP_TITLEBAR_HEIGHT,
                8.0,
                16.0,
                size
            ),
            None
        );
        assert_eq!(
            terminal_cell_at_with_offset(
                APP_NAVIGATION_WIDTH + 12.0,
                APP_TITLEBAR_HEIGHT - 1.0,
                APP_NAVIGATION_WIDTH,
                APP_TITLEBAR_HEIGHT,
                8.0,
                16.0,
                size
            ),
            None
        );
    }

    #[test]
    fn gpui_keyboard_events_preserve_logical_keys_and_event_types() {
        let keystroke = gpui::Keystroke {
            modifiers: gpui::Modifiers {
                shift: true,
                ..gpui::Modifiers::default()
            },
            key: "1".to_owned(),
            key_char: Some("!".to_owned()),
        };

        assert_eq!(
            terminal_key_input(&keystroke, KeyEvent::Repeat),
            Some(
                KeyInput::text_with_key(
                    "!",
                    "1",
                    Modifiers {
                        shift: true,
                        ..Modifiers::default()
                    },
                )
                .with_event(KeyEvent::Repeat)
            )
        );
        assert_eq!(
            terminal_key_input(&keystroke, KeyEvent::Release),
            Some(
                KeyInput::text_with_key(
                    "!",
                    "1",
                    Modifiers {
                        shift: true,
                        ..Modifiers::default()
                    },
                )
                .with_event(KeyEvent::Release)
            )
        );
    }

    #[test]
    fn unsupported_keys_without_text_are_silent() {
        for key in ["capslock", "shift", "control", "alt", "meta", "printscreen"] {
            let keystroke = gpui::Keystroke {
                modifiers: gpui::Modifiers::default(),
                key: key.to_owned(),
                key_char: None,
            };

            assert_eq!(terminal_key_input(&keystroke, KeyEvent::Press), None);
            assert_eq!(terminal_key_input(&keystroke, KeyEvent::Release), None);
        }
    }

    #[test]
    fn space_without_key_char_remains_printable() {
        let keystroke = gpui::Keystroke {
            modifiers: gpui::Modifiers::default(),
            key: "space".to_owned(),
            key_char: None,
        };

        assert_eq!(
            terminal_key_input(&keystroke, KeyEvent::Press),
            Some(KeyInput::text_with_key(" ", " ", Modifiers::default()))
        );
    }

    #[test]
    fn control_chords_without_key_char_reach_the_terminal_encoder() {
        for key in ["a", "e", "2", "[", "/"] {
            let keystroke = gpui::Keystroke {
                modifiers: gpui::Modifiers::control(),
                key: key.to_owned(),
                key_char: None,
            };

            assert_eq!(
                terminal_key_input(&keystroke, KeyEvent::Press),
                Some(KeyInput::text_with_key(
                    key,
                    key,
                    Modifiers {
                        control: true,
                        ..Modifiers::default()
                    },
                ))
            );
        }
    }

    #[test]
    fn sidebar_shortcut_is_owned_by_the_application() {
        let keystroke = gpui::Keystroke {
            modifiers: gpui::Modifiers {
                control: true,
                shift: true,
                ..gpui::Modifiers::default()
            },
            key: "b".to_owned(),
            key_char: None,
        };

        assert!(is_toggle_sidebar_shortcut(&keystroke));
        assert_eq!(terminal_key_input(&keystroke, KeyEvent::Press), None);
        assert_eq!(terminal_key_input(&keystroke, KeyEvent::Repeat), None);
        assert_eq!(terminal_key_input(&keystroke, KeyEvent::Release), None);
    }

    #[test]
    fn retained_ctrl_key_events_precede_sidebar_shortcut_classification() {
        let layout = LayoutKey {
            virtual_key: 0x42,
            unshifted: Some('b'),
            shifted: Some('B'),
            shift_required: false,
        };
        let press = gpui::Keystroke {
            modifiers: gpui::Modifiers::control(),
            key: "b".to_owned(),
            key_char: None,
        };
        let shortcut_shaped_event = gpui::Keystroke {
            modifiers: gpui::Modifiers {
                control: true,
                shift: true,
                ..gpui::Modifiers::default()
            },
            key: "b".to_owned(),
            key_char: None,
        };
        assert!(is_toggle_sidebar_shortcut(&shortcut_shaped_event));

        let press_key = canonical_terminal_key_with(&press, |_| Some(layout));
        let press_input = terminal_key_input_with_canonical(&press, KeyEvent::Press, &press_key)
            .expect("Ctrl+B is terminal input");
        let mut keyboard = TerminalKeyboard::default();
        keyboard.finish_accepted(
            &press_key.identity,
            Some(press_input.clone()),
            KeyEvent::Press,
        );

        let (repeat_key, repeat_input) =
            retained_key_event_with(&keyboard, &shortcut_shaped_event, KeyEvent::Repeat, |_| {
                Some(layout)
            })
            .expect("the retained terminal press owns its repeats");
        assert_eq!(repeat_key.identity, press_key.identity);
        assert_eq!(
            repeat_input,
            KeyInput::text_with_key(
                "B",
                "b",
                Modifiers {
                    shift: true,
                    control: true,
                    ..Modifiers::default()
                },
            )
            .with_event(KeyEvent::Repeat)
        );
        keyboard.finish_accepted(&repeat_key.identity, None, KeyEvent::Repeat);
        assert_eq!(keyboard.reserved_releases(), 1);

        let (release_key, release_input) =
            retained_key_event_with(&keyboard, &shortcut_shaped_event, KeyEvent::Release, |_| {
                Some(layout)
            })
            .expect("the retained terminal press owns its release");
        assert_eq!(release_key.identity, press_key.identity);
        assert_eq!(
            release_input,
            KeyInput::text_with_key(
                "b",
                "b",
                Modifiers {
                    shift: true,
                    control: true,
                    ..Modifiers::default()
                },
            )
            .with_event(KeyEvent::Release)
        );
        keyboard.finish_accepted(&release_key.identity, None, KeyEvent::Release);
        assert_eq!(keyboard.reserved_releases(), 0);
        assert!(
            retained_key_event_with(&keyboard, &shortcut_shaped_event, KeyEvent::Repeat, |_| {
                Some(layout)
            },)
            .is_none()
        );
    }

    #[test]
    fn shifted_control_fallback_preserves_kitty_key_parts() {
        let expected_modifiers = Modifiers {
            shift: true,
            control: true,
            ..Modifiers::default()
        };
        for (key, modifiers, produced, logical, layout) in [
            (
                "a",
                gpui::Modifiers {
                    control: true,
                    shift: true,
                    ..gpui::Modifiers::default()
                },
                "A",
                "a",
                LayoutKey {
                    virtual_key: 0x41,
                    unshifted: Some('a'),
                    shifted: Some('A'),
                    shift_required: false,
                },
            ),
            // GPUI folds Shift into Windows punctuation keys and clears the
            // modifier before delivering the keystroke.
            (
                "?",
                gpui::Modifiers::control(),
                "?",
                "/",
                LayoutKey {
                    virtual_key: 0xbf,
                    unshifted: Some('/'),
                    shifted: Some('?'),
                    shift_required: true,
                },
            ),
            (
                "_",
                gpui::Modifiers::control(),
                "_",
                "-",
                LayoutKey {
                    virtual_key: 0xbd,
                    unshifted: Some('-'),
                    shifted: Some('_'),
                    shift_required: true,
                },
            ),
            // Preserve the same result if a backend retains the modifier and
            // reports the unshifted logical key instead.
            (
                "/",
                gpui::Modifiers {
                    control: true,
                    shift: true,
                    ..gpui::Modifiers::default()
                },
                "?",
                "/",
                LayoutKey {
                    virtual_key: 0xbf,
                    unshifted: Some('/'),
                    shifted: Some('?'),
                    shift_required: false,
                },
            ),
        ] {
            let keystroke = gpui::Keystroke {
                modifiers,
                key: key.to_owned(),
                key_char: None,
            };
            let canonical = canonical_terminal_key_with(&keystroke, |_| Some(layout));

            assert_eq!(
                terminal_key_input_with_canonical(&keystroke, KeyEvent::Press, &canonical),
                Some(KeyInput::text_with_key(
                    produced,
                    logical,
                    expected_modifiers
                ))
            );
        }
    }

    #[test]
    fn no_layout_fallback_shifts_ascii_control_punctuation() {
        let modifiers = gpui::Modifiers {
            control: true,
            shift: true,
            ..gpui::Modifiers::default()
        };
        let expected_modifiers = Modifiers {
            control: true,
            shift: true,
            ..Modifiers::default()
        };
        for (logical, produced) in [("-", "_"), ("/", "?")] {
            let keystroke = gpui::Keystroke {
                modifiers,
                key: logical.to_owned(),
                key_char: None,
            };
            let canonical = canonical_terminal_key_with(&keystroke, |_| None);

            assert_eq!(canonical.layout, None);
            assert_eq!(
                terminal_key_input_with_canonical(&keystroke, KeyEvent::Press, &canonical),
                Some(KeyInput::text_with_key(
                    produced,
                    logical,
                    expected_modifiers,
                ))
            );
        }
    }

    #[test]
    fn layout_identity_pairs_non_us_shifted_press_and_release() {
        // German layouts place '+' and '*' on one key, unlike the fixed US
        // punctuation pairs. The layout resolver supplies both characters and
        // a virtual key that remains stable when Shift changes before key-up.
        let shifted = LayoutKey {
            virtual_key: 0xbb,
            unshifted: Some('+'),
            shifted: Some('*'),
            shift_required: true,
        };
        let unshifted = LayoutKey {
            shift_required: false,
            ..shifted
        };
        let press = gpui::Keystroke {
            modifiers: gpui::Modifiers::control(),
            key: "*".to_owned(),
            key_char: None,
        };
        let release = gpui::Keystroke {
            modifiers: gpui::Modifiers::control(),
            key: "+".to_owned(),
            key_char: None,
        };
        let press_key = canonical_terminal_key_with(&press, |_| Some(shifted));
        let release_key = canonical_terminal_key_with(&release, |_| Some(unshifted));

        assert_eq!(press_key.identity, release_key.identity);
        assert_eq!(press_key.identity, TerminalKeyIdentity::Layout(0xbb));
        assert_eq!(
            terminal_key_input_with_canonical(&press, KeyEvent::Press, &press_key),
            Some(KeyInput::text_with_key(
                "*",
                "+",
                Modifiers {
                    shift: true,
                    control: true,
                    ..Modifiers::default()
                }
            ))
        );

        let mut keyboard = TerminalKeyboard::default();
        let input = terminal_key_input_with_canonical(&press, KeyEvent::Press, &press_key)
            .expect("layout-resolved control key is representable");
        keyboard.finish_accepted(&press_key.identity, Some(input.clone()), KeyEvent::Press);
        assert!(keyboard.accepts(&release_key.identity, KeyEvent::Release));
        assert_eq!(
            keyboard.input_for(
                &release_key.identity,
                KeyEvent::Release,
                release_key.modifiers,
            ),
            Some(
                KeyInput::text_with_key(
                    "*",
                    "+",
                    Modifiers {
                        control: true,
                        ..Modifiers::default()
                    },
                )
                .with_event(KeyEvent::Release)
            )
        );
        keyboard.finish_accepted(&release_key.identity, None, KeyEvent::Release);
        assert_eq!(keyboard.reserved_releases(), 0);
    }

    #[test]
    fn altgr_text_keeps_virtual_key_identity_after_altgr_release() {
        let altgr_layout = LayoutKey {
            virtual_key: 0x51,
            unshifted: None,
            shifted: None,
            shift_required: false,
        };
        let plain_layout = LayoutKey {
            virtual_key: 0x51,
            unshifted: Some('q'),
            shifted: Some('Q'),
            shift_required: false,
        };
        let press = gpui::Keystroke {
            modifiers: gpui::Modifiers::default(),
            key: "@".to_owned(),
            key_char: Some("@".to_owned()),
        };
        let release = gpui::Keystroke {
            modifiers: gpui::Modifiers::default(),
            key: "q".to_owned(),
            key_char: None,
        };
        let press_key = canonical_terminal_key_with(&press, |_| Some(altgr_layout));
        let press_input = terminal_key_input_with_canonical(&press, KeyEvent::Press, &press_key)
            .expect("AltGr text comes from key_char");
        assert_eq!(press_key.identity, TerminalKeyIdentity::Layout(0x51));
        assert_eq!(
            press_input,
            KeyInput::text_with_key("@", "@", Modifiers::default())
        );

        let mut keyboard = TerminalKeyboard::default();
        keyboard.finish_accepted(
            &press_key.identity,
            Some(press_input.clone()),
            KeyEvent::Press,
        );
        let (release_key, release_input) =
            retained_key_event_with(&keyboard, &release, KeyEvent::Release, |_| {
                Some(plain_layout)
            })
            .expect("the virtual key still owns the release after AltGr is released");
        assert_eq!(release_key.identity, press_key.identity);
        assert_eq!(release_input, press_input.with_event(KeyEvent::Release));
        keyboard.finish_accepted(&release_key.identity, None, KeyEvent::Release);
        assert_eq!(keyboard.reserved_releases(), 0);
    }

    #[test]
    fn pressed_mouse_button_releases_at_the_last_terminal_cell() {
        let mut pointer = TerminalPointer::default();

        pointer.press(MouseButton::Left, (4, 7));
        assert_eq!(pointer.observe(Some((8, 9))), Some((8, 9)));
        assert_eq!(pointer.release_cell(MouseButton::Left, None), Some((8, 9)));
        assert_eq!(pointer.release_cell(MouseButton::Left, None), Some((8, 9)));
        pointer.finish_release(MouseButton::Left);
        assert_eq!(pointer.release_cell(MouseButton::Left, None), None);
    }

    #[test]
    fn untracked_mouse_release_is_silent() {
        let mut pointer = TerminalPointer::default();

        assert_eq!(pointer.release_cell(MouseButton::Right, Some((2, 3))), None);
        assert_eq!(pointer.release_cell(MouseButton::Right, None), None);
    }

    #[test]
    fn completed_wheel_steps_leave_only_a_fractional_remainder() {
        let mut remainder = 0.5;

        assert_eq!(terminal_wheel_steps(&mut remainder, 130.0, 1.0), 130);
        assert!((remainder - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn wheel_batches_preserve_direction_target_and_modifiers() {
        let first = WheelBatch {
            input: MouseInput {
                action: MouseAction::WheelUp,
                column: 4,
                row: 7,
                modifiers: Modifiers::default(),
            },
            remaining: 54,
        };
        let mut pending = VecDeque::from([QueuedUiInput {
            presentation_id: 8,
            input: PendingUiInput::Wheel(first),
            bytes: 0,
            accepted_after_refusal: None,
        }]);
        let same_target = WheelBatch {
            remaining: 10,
            ..first
        };
        assert!(coalesce_last_wheel(&mut pending, 8, same_target, Some(2)));
        assert!(matches!(
            pending[0].input,
            PendingUiInput::Wheel(WheelBatch { remaining: 64, .. })
        ));

        let later_opposite_target = WheelBatch {
            input: MouseInput {
                action: MouseAction::WheelDown,
                column: 12,
                row: 9,
                modifiers: Modifiers {
                    alt: true,
                    ..Modifiers::default()
                },
            },
            remaining: 3,
        };
        assert!(!coalesce_last_wheel(
            &mut pending,
            8,
            later_opposite_target,
            None
        ));
        pending.push_back(QueuedUiInput {
            presentation_id: 8,
            input: PendingUiInput::Wheel(later_opposite_target),
            bytes: 0,
            accepted_after_refusal: None,
        });
        assert_eq!(pending.len(), 2);
        assert!(matches!(
            pending[0].input,
            PendingUiInput::Wheel(WheelBatch {
                input: MouseInput {
                    action: MouseAction::WheelUp,
                    column: 4,
                    row: 7,
                    ..
                },
                remaining: 64,
            })
        ));
        assert!(matches!(
            pending[1].input,
            PendingUiInput::Wheel(WheelBatch {
                input: MouseInput {
                    action: MouseAction::WheelDown,
                    column: 12,
                    row: 9,
                    modifiers: Modifiers { alt: true, .. },
                },
                remaining: 3,
            })
        ));
    }

    #[test]
    fn shared_input_queue_reserves_capacity_for_balancing_releases() {
        let mouse_release = PendingUiInput::Mouse(MouseInput {
            action: MouseAction::Release(MouseButton::Left),
            column: 0,
            row: 0,
            modifiers: Modifiers::default(),
        });
        let key_release = PendingUiInput::Key(
            KeyInput::named(NamedKey::Enter, Modifiers::default()).with_event(KeyEvent::Release),
        );
        let key_repeat = PendingUiInput::Key(
            KeyInput::named(NamedKey::Enter, Modifiers::default()).with_event(KeyEvent::Repeat),
        );

        assert!(input_queue_has_capacity(
            &mouse_release,
            UI_INPUT_CAPACITY - 1,
            0,
            0,
            1,
        ));
        assert!(!input_queue_has_capacity(
            &mouse_release,
            UI_INPUT_CAPACITY,
            0,
            0,
            1,
        ));
        assert!(input_queue_has_capacity(
            &key_release,
            UI_INPUT_CAPACITY - 1,
            UI_INPUT_BYTE_CAPACITY,
            1,
            1,
        ));
        assert!(!input_queue_has_capacity(
            &key_repeat,
            UI_INPUT_CAPACITY - 4,
            0,
            0,
            1,
        ));
        assert!(input_queue_has_capacity(
            &key_repeat,
            UI_INPUT_CAPACITY - 5,
            0,
            0,
            1,
        ));
    }

    #[test]
    fn resize_stays_behind_older_input_and_coalesces_in_place() {
        let mut pending = VecDeque::from([QueuedUiInput {
            presentation_id: 7,
            input: PendingUiInput::Key(KeyInput::named(NamedKey::Enter, Modifiers::default())),
            bytes: 0,
            accepted_after_refusal: None,
        }]);
        let first = TerminalResize {
            columns: 80,
            rows: 24,
            pixel_width: 800,
            pixel_height: 480,
        };
        let latest = TerminalResize {
            columns: 120,
            rows: 40,
            pixel_width: 1_200,
            pixel_height: 800,
        };

        assert!(!coalesce_last_resize(&mut pending, 7, first));
        pending.push_back(QueuedUiInput {
            presentation_id: 7,
            input: PendingUiInput::Resize(first),
            bytes: 0,
            accepted_after_refusal: None,
        });
        assert!(coalesce_last_resize(&mut pending, 7, latest));
        assert!(matches!(pending[0].input, PendingUiInput::Key(_)));
        assert!(matches!(pending[1].input, PendingUiInput::Resize(value) if value == latest));
        assert!(input_queue_has_capacity(
            &PendingUiInput::Resize(latest),
            UI_INPUT_CAPACITY,
            UI_INPUT_BYTE_CAPACITY,
            0,
            0,
        ));
    }

    #[test]
    fn accepted_key_press_reserves_capacity_until_release_is_accepted() {
        let mut keyboard = TerminalKeyboard::default();
        let press = KeyInput::text_with_key("!", "1", Modifiers::default());
        let a = TerminalKeyIdentity::Layout(0x41);
        let b = TerminalKeyIdentity::Layout(0x42);
        let release_without_text = gpui::Keystroke {
            modifiers: gpui::Modifiers::default(),
            key: "a".to_owned(),
            key_char: None,
        };

        assert!(keyboard.accepts(&a, KeyEvent::Press));
        assert!(!keyboard.accepts(&a, KeyEvent::Repeat));
        assert!(!keyboard.accepts(&a, KeyEvent::Release));
        assert_eq!(keyboard.reservations_after_press(&a), 1);
        keyboard.finish_accepted(&a, Some(press.clone()), KeyEvent::Press);
        assert_eq!(keyboard.reserved_releases(), 1);
        assert_eq!(keyboard.reservations_after_press(&a), 1);
        assert!(keyboard.accepts(&a, KeyEvent::Repeat));
        assert!(keyboard.accepts(&a, KeyEvent::Release));
        assert!(!keyboard.accepts(&b, KeyEvent::Repeat));
        assert!(!keyboard.accepts(&b, KeyEvent::Release));
        let release_modifiers = Modifiers {
            alt: true,
            ..Modifiers::default()
        };
        assert_eq!(
            keyboard.input_for(&a, KeyEvent::Release, release_modifiers),
            Some(
                KeyInput::text_with_key("!", "1", release_modifiers).with_event(KeyEvent::Release)
            )
        );
        assert_eq!(
            terminal_key_input(&release_without_text, KeyEvent::Release),
            None
        );

        keyboard.finish_accepted(&a, None, KeyEvent::Repeat);
        assert_eq!(keyboard.reserved_releases(), 1);
        keyboard.finish_accepted(&a, None, KeyEvent::Release);
        assert_eq!(keyboard.reserved_releases(), 0);
        assert!(!keyboard.accepts(&a, KeyEvent::Repeat));
        assert!(!keyboard.accepts(&a, KeyEvent::Release));
    }

    #[test]
    fn measured_fractional_cell_width_is_not_rounded() {
        assert!((normalize_cell_width(8.25) - 8.25).abs() < f32::EPSILON);
        assert!((normalize_cell_width(0.5) - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn terminal_line_height_keeps_readable_leading() {
        assert!((terminal_line_height(14.0, 10.0, 3.0) - 19.0).abs() < f32::EPSILON);
        assert!((terminal_line_height(14.0, 12.0, 4.0) - 20.0).abs() < f32::EPSILON);
    }

    #[test]
    fn presentation_transition_clears_all_terminal_input_state() {
        let mut observed = Some(7);
        let mut paste_confirmation = true;
        let mut pending_input = VecDeque::from([QueuedUiInput {
            presentation_id: 7,
            input: PendingUiInput::Key(KeyInput::Named {
                key: NamedKey::Enter,
                modifiers: Modifiers::default(),
                event: KeyEvent::Press,
            }),
            bytes: 0,
            accepted_after_refusal: None,
        }]);
        let mut pending_input_bytes = 64;
        let mut refusal = InputRefusal::default();
        refusal.refuse();

        assert!(transitioned_presentation(&mut observed, None));
        clear_terminal_input_state(
            &mut paste_confirmation,
            &mut pending_input,
            &mut pending_input_bytes,
            &mut refusal,
        );

        assert_eq!(observed, None);
        assert!(!paste_confirmation);
        assert!(pending_input.is_empty());
        assert_eq!(pending_input_bytes, 0);
        assert!(!refusal.is_pending());

        paste_confirmation = true;
        pending_input.push_back(QueuedUiInput {
            presentation_id: 7,
            input: PendingUiInput::Key(KeyInput::Named {
                key: NamedKey::Enter,
                modifiers: Modifiers::default(),
                event: KeyEvent::Press,
            }),
            bytes: 0,
            accepted_after_refusal: None,
        });
        pending_input_bytes = 64;
        refusal.refuse();
        assert!(transitioned_presentation(&mut observed, Some(8)));
        clear_terminal_input_state(
            &mut paste_confirmation,
            &mut pending_input,
            &mut pending_input_bytes,
            &mut refusal,
        );

        assert_eq!(observed, Some(8));
        assert!(!paste_confirmation);
        assert!(pending_input.is_empty());
        assert_eq!(pending_input_bytes, 0);
        assert!(!refusal.is_pending());
        assert!(!transitioned_presentation(&mut observed, Some(8)));
    }

    #[test]
    fn queued_terminal_input_is_bound_to_its_originating_presentation() {
        let input = QueuedUiInput {
            presentation_id: 7,
            input: PendingUiInput::Key(KeyInput::named(NamedKey::Enter, Modifiers::default())),
            bytes: 0,
            accepted_after_refusal: None,
        };

        assert!(queued_input_matches_presentation(&input, Some(7)));
        assert!(!queued_input_matches_presentation(&input, Some(8)));
        assert!(!queued_input_matches_presentation(&input, None));
    }

    #[test]
    fn focused_ssh_password_field_has_a_visible_caret() {
        assert_eq!(ssh_prompt_input_text("", false), "Password or passphrase");
        assert_eq!(ssh_prompt_input_text("", true), "▏");
        assert_eq!(ssh_prompt_input_text("secret", false), "••••••");
        assert_eq!(ssh_prompt_input_text("secret", true), "••••••▏");
    }
}
