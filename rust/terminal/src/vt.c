// The compiler checks libghostty's C layouts and option types here. Only the
// small owned-view ABI below crosses into Rust; no Ghostty grid pointers escape.
#include <ghostty/vt.h>
#include <stdlib.h>
#include <string.h>

typedef void (*Effect)(void *, uint32_t, const uint8_t *, size_t);
typedef struct {
    GhosttyTerminal terminal;
    GhosttyRenderState render;
    GhosttyRenderStateRowIterator rows;
    GhosttyRenderStateRowCells cells;
    GhosttyKeyEncoder encoder;
    GhosttyKeyEvent key;
    GhosttyTrackedGridRef selection_anchor;
    GhosttyTerminalScreen selection_screen;
    uint8_t *selection_text;
    size_t selection_len;
    GhosttyBuffer text;
    Effect effect;
    void *userdata;
    bool reading_clipboard;
    bool in_osc, osc_overflow;
    GhosttyBuffer osc;
} Vt;

typedef struct {
    uint16_t x, y;
    uint8_t visible, shape;
} VtCursor;

typedef struct {
    const uint8_t *text;
    size_t len;
    uint8_t foreground[3], background[3], style;
    bool selected;
} VtCell;

static void check(GhosttyResult result) {
    // All fallible calls here use valid fixed options, or allocate. Continuing
    // after an ABI error or allocation failure would publish invalid memory.
    if (result != GHOSTTY_SUCCESS) abort();
}

static void write_pty(GhosttyTerminal terminal, void *userdata,
                      const uint8_t *bytes, size_t len) {
    (void)terminal;
    Vt *vt = userdata;
    if (!vt->reading_clipboard) vt->effect(vt->userdata, 0, bytes, len);
}

static void clipboard_write(GhosttyTerminal terminal, void *userdata,
                            const GhosttyClipboardWrite *write) {
    (void)terminal;
    Vt *vt = userdata;
    // The stream-boundary handler below retains OSC 52's original selection
    // and encoded payload for Ghosthub's policy. The generic clipboard API
    // normalizes those fields, so do not publish from this callback.
    vt->reading_clipboard = true;
    GhosttyClipboardWriteReply reply = {
        .size = sizeof(reply), .result = GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED,
    };
    write->reply(write, &reply);
    vt->reading_clipboard = false;
}

static void clipboard_read(GhosttyTerminal terminal, void *userdata,
                           const GhosttyClipboardRead *read) {
    (void)terminal;
    Vt *vt = userdata;
    // Deny the synchronous generic request; OSC 52 policy is handled after
    // the library reports its complete stream boundary.
    vt->reading_clipboard = true;
    GhosttyClipboardReadReply reply = {
        .size = sizeof(reply), .result = GHOSTTY_CLIPBOARD_READ_RESULT_DENIED,
    };
    read->reply(read, &reply);
    vt->reading_clipboard = false;
}

void vt_free(Vt *vt) {
    if (!vt) return;
    ghostty_tracked_grid_ref_free(vt->selection_anchor);
    ghostty_free(NULL, vt->selection_text, vt->selection_len);
    ghostty_key_event_free(vt->key);
    ghostty_key_encoder_free(vt->encoder);
    ghostty_render_state_row_cells_free(vt->cells);
    ghostty_render_state_row_iterator_free(vt->rows);
    ghostty_render_state_free(vt->render);
    ghostty_terminal_free(vt->terminal);
    free(vt->text.ptr);
    free(vt->osc.ptr);
    free(vt);
}

Vt *vt_new(uint16_t columns, uint16_t rows, void *userdata, Effect effect) {
    Vt *vt = calloc(1, sizeof(*vt));
    if (!vt) return NULL;
    if (ghostty_terminal_new(NULL, &vt->terminal, columns, rows) != GHOSTTY_SUCCESS ||
        ghostty_render_state_new(NULL, &vt->render) != GHOSTTY_SUCCESS ||
        ghostty_render_state_row_iterator_new(NULL, &vt->rows) != GHOSTTY_SUCCESS ||
        ghostty_render_state_row_cells_new(NULL, &vt->cells) != GHOSTTY_SUCCESS ||
        ghostty_key_encoder_new(NULL, &vt->encoder) != GHOSTTY_SUCCESS ||
        ghostty_key_event_new(NULL, &vt->key) != GHOSTTY_SUCCESS) {
        vt_free(vt);
        return NULL;
    }
    vt->effect = effect;
    vt->userdata = userdata;
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, vt));
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)write_pty));
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, (const void *)clipboard_write));
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, (const void *)clipboard_read));
    size_t clipboard_limit = 1024 * 1024;
    size_t history_lines = 0;
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &history_lines));
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES, &clipboard_limit));
    // The app does not draw images yet. Do not acknowledge graphics it cannot
    // present or allow the terminal stream to read files from the local host.
    uint64_t no_images = 0;
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &no_images));
    bool disabled = false;
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &disabled));
    GhosttyString no_temp_directory = {0};
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, &no_temp_directory));
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &disabled));
    return vt;
}

void vt_colors(Vt *vt, const uint8_t *rgb) {
    GhosttyColorRgb foreground = {rgb[0], rgb[1], rgb[2]};
    GhosttyColorRgb background = {rgb[3], rgb[4], rgb[5]};
    GhosttyColorRgb palette[256];
    for (size_t i = 0; i < 256; ++i) {
        palette[i] = (GhosttyColorRgb){rgb[6 + i * 3], rgb[7 + i * 3], rgb[8 + i * 3]};
    }
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette));
}

bool vt_clear_selection(Vt *vt) {
    ghostty_tracked_grid_ref_free(vt->selection_anchor);
    vt->selection_anchor = NULL;
    GhosttySelection selection;
    GhosttyResult result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
    if (result == GHOSTTY_NO_VALUE) return false;
    check(result);
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL));
    return true;
}

void vt_select(Vt *vt, uint8_t action, uint16_t x, uint16_t y) {
    GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT,
        .value = {.coordinate = {.x = x, .y = y}}};
    if (action == 0) {
        check(ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &vt->selection_screen));
        check(ghostty_terminal_grid_ref_track(vt->terminal, point, &vt->selection_anchor));
    } else if (action == 1 && vt->selection_anchor) {
        GhosttyTerminalScreen screen;
        check(ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen));
        if (screen != vt->selection_screen) return;
        GhosttySelection selection = {0};
        GhosttyResult result = ghostty_tracked_grid_ref_snapshot(vt->selection_anchor, &selection.start);
        if (result == GHOSTTY_NO_VALUE) return;
        check(result);
        // A primary/alternate-screen switch must not move a drag to another screen.
        GhosttyPointCoordinate start;
        result = ghostty_terminal_point_from_grid_ref(vt->terminal, &selection.start,
            GHOSTTY_POINT_TAG_VIEWPORT, &start);
        if (result == GHOSTTY_NO_VALUE) return;
        check(result);
        check(ghostty_terminal_grid_ref(vt->terminal, point, &selection.end));
        check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection));
    } else if (action == 2) {
        ghostty_tracked_grid_ref_free(vt->selection_anchor);
        vt->selection_anchor = NULL;
    }
}

bool vt_copy_selection(Vt *vt, const uint8_t **text, size_t *len) {
    GhosttySelection selection;
    GhosttyResult result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
    if (result == GHOSTTY_NO_VALUE) return false;
    check(result);
    GhosttyFormatter formatter;
    check(ghostty_formatter_terminal_new(NULL, &formatter, vt->terminal));
    GhosttyFormatterFormat format = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    bool trim = true;
    check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &format));
    check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim));
    check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &trim));
    check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection));
    ghostty_free(NULL, vt->selection_text, vt->selection_len);
    check(ghostty_formatter_format_alloc(formatter, NULL, &vt->selection_text, &vt->selection_len));
    ghostty_formatter_free(formatter);
    *text = vt->selection_text;
    *len = vt->selection_len;
    return vt->selection_len > 0;
}

void vt_cursor(Vt *vt, uint8_t shape) {
    GhosttyCursorStyle style = shape == 1 ? GHOSTTY_CURSOR_STYLE_BAR :
                              shape == 2 ? GHOSTTY_CURSOR_STYLE_UNDERLINE : GHOSTTY_CURSOR_STYLE_BLOCK;
    check(ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style));
}

static void capture_osc(Vt *vt, const uint8_t *bytes, size_t len) {
    const size_t limit = ((1024 * 1024 + 2) / 3) * 4 + 32;
    if (vt->osc_overflow) return;
    if (len > limit - vt->osc.len) { vt->osc_overflow = true; return; }
    if (vt->osc.len + len > vt->osc.cap) {
        size_t capacity = vt->osc.cap ? vt->osc.cap * 2 : 4096;
        if (capacity < vt->osc.len + len) capacity = vt->osc.len + len;
        if (capacity > limit) capacity = limit;
        uint8_t *buffer = realloc(vt->osc.ptr, capacity);
        if (!buffer) abort();
        vt->osc.ptr = buffer;
        vt->osc.cap = capacity;
    }
    if (len) memcpy(vt->osc.ptr + vt->osc.len, bytes, len);
    vt->osc.len += len;
}

bool vt_write(Vt *vt, const uint8_t *bytes, size_t len) {
    bool alternate = false;
    while (len) {
        // Also observe between escape sequences so enter+exit in a single PTY
        // read still confirms alternate-screen startup.
        const uint8_t *escape = memchr(bytes, 0x1b, len);
        size_t count = escape ? (size_t)(escape - bytes) + 1 : len;
        GhosttyTerminalWriteStop stop = {.size = sizeof(stop)};
        GhosttyResult result = ghostty_terminal_vt_write_until(vt->terminal, bytes, count,
            GHOSTTY_TERMINAL_BOUNDARY_OSC_START | GHOSTTY_TERMINAL_BOUNDARY_OSC_END, &stop);
        if (result != GHOSTTY_NO_VALUE) check(result);
        if (vt->in_osc) capture_osc(vt, bytes, stop.consumed);
        if (stop.reached & GHOSTTY_TERMINAL_BOUNDARY_OSC_START) {
            vt->in_osc = true;
            vt->osc_overflow = false;
            vt->osc.len = 0;
        }
        if (stop.reached & GHOSTTY_TERMINAL_BOUNDARY_OSC_END) {
            // The boundary consumes only ESC, not the following backslash.
            // BEL and C1 boundaries also consume exactly one terminator byte.
            if (!vt->osc_overflow && vt->osc.len >= 1 &&
                (stop.end == GHOSTTY_TERMINAL_STRING_END_BEL ||
                 stop.end == GHOSTTY_TERMINAL_STRING_END_ST_ESC ||
                 stop.end == GHOSTTY_TERMINAL_STRING_END_ST_C1)) {
                vt->effect(vt->userdata, stop.end == GHOSTTY_TERMINAL_STRING_END_BEL ? 3 : 4,
                    vt->osc.ptr, vt->osc.len - 1);
            }
            vt->in_osc = false;
            vt->osc.len = 0;
        }
        GhosttyTerminalScreen screen;
        check(ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen));
        alternate |= screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
        bytes += stop.consumed;
        len -= stop.consumed;
    }
    return alternate;
}

void vt_resize(Vt *vt, uint16_t columns, uint16_t rows, uint32_t width, uint32_t height) {
    check(ghostty_terminal_resize(vt->terminal, columns, rows, width, height));
}

bool vt_mode(Vt *vt, uint16_t mode) {
    GhosttyTerminalModeConfig query = {.mode = ghostty_mode_new(mode, false)};
    check(ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_MODE, &query));
    return query.value;
}

int vt_snapshot(Vt *vt, VtCursor *cursor) {
    check(ghostty_render_state_update(vt->render, vt->terminal));
    GhosttyRenderStateDirty dirty;
    check(ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty));
    GhosttyRenderStateCursor c = {.size = sizeof(c)};
    check(ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &c));
    *cursor = (VtCursor){c.viewport_x, c.viewport_y, c.visible && c.viewport_has_value,
        c.visual_style == GHOSTTY_CURSOR_STYLE_BAR ? 1 :
        c.visual_style == GHOSTTY_CURSOR_STYLE_UNDERLINE ? 2 : 0};
    check(ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &vt->rows));
    return (int)dirty;
}

bool vt_row(Vt *vt, uint64_t *identity, bool *dirty) {
    if (!ghostty_render_state_row_iterator_next(vt->rows)) return false;
    GhosttyRenderStateRowId id;
    check(ghostty_render_state_row_get(vt->rows, GHOSTTY_RENDER_STATE_ROW_DATA_ID, &id));
    identity[0] = id.bits[0];
    identity[1] = id.bits[1];
    check(ghostty_render_state_row_get(vt->rows, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, dirty));
    check(ghostty_render_state_row_get(vt->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &vt->cells));
    return true;
}

bool vt_cell(Vt *vt, VtCell *cell) {
    if (!ghostty_render_state_row_cells_next(vt->cells)) return false;
    check(ghostty_render_state_row_cells_get(vt->cells,
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &cell->selected));
    GhosttyResult result = ghostty_render_state_row_cells_get(vt->cells,
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &vt->text);
    if (result == GHOSTTY_OUT_OF_SPACE) {
        uint8_t *text = realloc(vt->text.ptr, vt->text.len);
        if (!text) abort();
        vt->text.ptr = text;
        vt->text.cap = vt->text.len;
        result = ghostty_render_state_row_cells_get(vt->cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &vt->text);
    }
    check(result);
    cell->text = vt->text.ptr;
    cell->len = vt->text.len;
    GhosttyStyle style;
    check(ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style));
    GhosttyCell raw;
    GhosttyCellWide wide;
    check(ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw));
    check(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide));
    if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
        cell->len = 0;
    } else if (cell->len == 0) {
        cell->text = (const uint8_t *)" ";
        cell->len = 1;
    }
    GhosttyColorRgb foreground, background;
    result = ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground);
    if (result == GHOSTTY_NO_VALUE)
        check(ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &foreground));
    else check(result);
    result = ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background);
    if (result == GHOSTTY_NO_VALUE)
        check(ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &background));
    else check(result);
    memcpy(cell->foreground, &foreground, 3);
    memcpy(cell->background, &background, 3);
    cell->style = ((style.flags & GHOSTTY_STYLE_FLAG_BOLD) ? 1 : 0) |
        ((style.flags & GHOSTTY_STYLE_FLAG_ITALIC) ? 2 : 0) |
        (GHOSTTY_STYLE_UNDERLINE(style) ? 4 : 0) |
        ((style.flags & GHOSTTY_STYLE_FLAG_INVERSE) ? 8 : 0) |
        ((wide == GHOSTTY_CELL_WIDE_WIDE) ? 16 : 0) |
        ((style.flags & GHOSTTY_STYLE_FLAG_FAINT) ? 32 : 0) |
        ((style.flags & GHOSTTY_STYLE_FLAG_INVISIBLE) ? 64 : 0) |
        ((style.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH) ? 128 : 0);
    return true;
}

void vt_clean(Vt *vt) { check(ghostty_render_state_clean(vt->render)); }

// Named-key indices are Ghosthub's small vocabulary, not upstream enum values.
static GhosttyKey named_key(uint32_t key) {
    static const GhosttyKey keys[] = {
        GHOSTTY_KEY_UNIDENTIFIED, GHOSTTY_KEY_ENTER, GHOSTTY_KEY_TAB,
        GHOSTTY_KEY_BACKSPACE, GHOSTTY_KEY_ESCAPE, GHOSTTY_KEY_ARROW_UP,
        GHOSTTY_KEY_ARROW_DOWN, GHOSTTY_KEY_ARROW_LEFT, GHOSTTY_KEY_ARROW_RIGHT,
        GHOSTTY_KEY_HOME, GHOSTTY_KEY_END, GHOSTTY_KEY_PAGE_UP, GHOSTTY_KEY_PAGE_DOWN,
        GHOSTTY_KEY_INSERT, GHOSTTY_KEY_DELETE, GHOSTTY_KEY_NUMPAD_DECIMAL,
        GHOSTTY_KEY_NUMPAD_DIVIDE, GHOSTTY_KEY_NUMPAD_MULTIPLY,
        GHOSTTY_KEY_NUMPAD_SUBTRACT, GHOSTTY_KEY_NUMPAD_ADD,
        GHOSTTY_KEY_NUMPAD_ENTER, GHOSTTY_KEY_NUMPAD_EQUAL,
    };
    if (key < sizeof(keys) / sizeof(keys[0])) return keys[key];
    if (key >= 100 && key <= 124) return (GhosttyKey)(GHOSTTY_KEY_F1 + key - 100);
    if (key >= 200 && key <= 209) return (GhosttyKey)(GHOSTTY_KEY_NUMPAD_0 + key - 200);
    return GHOSTTY_KEY_UNIDENTIFIED;
}

size_t vt_key(Vt *vt, uint32_t named, uint32_t codepoint, uint16_t modifiers,
              uint8_t action, const uint8_t *text, size_t text_len,
              uint8_t *output, size_t capacity) {
    check(ghostty_key_encoder_set_from_terminal(vt->encoder, vt->terminal));
    // Linux and Windows Alt is always the terminal's Alt modifier.
    GhosttyOptionAsAlt alt = GHOSTTY_OPTION_AS_ALT_TRUE;
    check(ghostty_key_encoder_set(vt->encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt));
    // Our input vocabulary distinguishes keypad keys, but GPUI does not expose
    // NumLock. Preserve the application's explicit keypad mode in that case.
    bool ignore_numlock = false;
    check(ghostty_key_encoder_set(vt->encoder, GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK, &ignore_numlock));
    GhosttyKey key = named_key(named);
    if (!named) {
        if (codepoint >= 'a' && codepoint <= 'z') key = (GhosttyKey)(GHOSTTY_KEY_A + codepoint - 'a');
        else if (codepoint >= '0' && codepoint <= '9') key = (GhosttyKey)(GHOSTTY_KEY_DIGIT_0 + codepoint - '0');
        else {
            switch (codepoint) {
                case ' ': key = GHOSTTY_KEY_SPACE; break;
                case '`': key = GHOSTTY_KEY_BACKQUOTE; break;
                case '\\': key = GHOSTTY_KEY_BACKSLASH; break;
                case '[': key = GHOSTTY_KEY_BRACKET_LEFT; break;
                case ']': key = GHOSTTY_KEY_BRACKET_RIGHT; break;
                case ',': key = GHOSTTY_KEY_COMMA; break;
                case '=': key = GHOSTTY_KEY_EQUAL; break;
                case '-': key = GHOSTTY_KEY_MINUS; break;
                case '.': key = GHOSTTY_KEY_PERIOD; break;
                case '\'': key = GHOSTTY_KEY_QUOTE; break;
                case ';': key = GHOSTTY_KEY_SEMICOLON; break;
                case '/': key = GHOSTTY_KEY_SLASH; break;
                default: break;
            }
        }
    }
    check(ghostty_key_event_set_key(vt->key, key));
    check(ghostty_key_event_set_action(vt->key, action == 0 ? GHOSTTY_KEY_ACTION_PRESS :
        action == 1 ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_RELEASE));
    check(ghostty_key_event_set_mods(vt->key, modifiers));
    check(ghostty_key_event_set_utf8(vt->key, (GhosttyString){text, text_len}));
    check(ghostty_key_event_set_unshifted_codepoint(vt->key, codepoint));
    size_t written = 0;
    GhosttyResult result = ghostty_key_encoder_encode(vt->encoder, vt->key, output, capacity, &written);
    check(ghostty_key_event_set_utf8(vt->key, (GhosttyString){0}));
    if (result != GHOSTTY_OUT_OF_SPACE) check(result);
    return written;
}
