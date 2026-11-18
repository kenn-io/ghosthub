# Rex Split Tree Design

Approved 2026-11-17. Ghosthub shows a whole Rex window as a split view of
libghostty panes, drawn from Rex's own layout and as fast as Rex.app.

## Reference behavior (Rex.app 0.1.0, server 0.1.0-preview.14)

| User action | Rex.app result | Ghosthub check |
| --- | --- | --- |
| Open a window | Every pane of the window's tiled layer, placed by the split tree | Fixture views render the same frames |
| Split right / down (⌘D / ⇧⌘D) | New pane after the focused one, which takes focus | Request sends `new_split`; next view focuses the new pane |
| Drag a divider | Frames move live; each terminal resizes once and the ratio commits once at mouse-up | No surface resize until mouse-up; one `resize_pane` |
| Click a pane | It takes focus | Local focus plus `focus_block` |
| Focus pane (⌥⌘ arrows, ⌘[ / ⌘]) | Nearest or next pane takes focus | `focus_direction`, `focus_next_pane`, `focus_previous_pane` |
| Zoom pane (⇧⌘↩) | Focused pane fills the window; others keep running | `zoom_block`; zoomed pane covers the container |
| Layout changed in another client | View updates | View event applies; surviving panes keep their views |
| Pane chrome | Rounded card, ~8pt gap, one-line header (program and directory); split/zoom/close buttons on the focused pane | Same structure |

Departure: ⌘W keeps Ghosthub's meaning (close the view, leave every pane
running). Close Pane is the pane header × or a command, after confirmation.

Out of scope for this version: split left/up, best fit, move/swap panes,
balance, rename, floating layers (not drawn), Herdr Core layouts.

## kwt: `kwt rex control SESSION_ID`

One long-lived Rex control connection, attached to one session, speaking
newline-delimited JSON on stdin and stdout.

Output lines:

- `{"type":"view","view":<session.view>,"terminals":{BLOCK_ID:{"name":..,"title":..,"program":..,"cwd":..}}}`
  once after attaching and again after `session_view_changed` or a terminal
  block's `title_changed`, `pwd_changed`, or `process_changed`. Bursts
  collapse: at most one view read is in flight, and a change during a read
  schedules one more read.
- `{"type":"reply","id":N,"result":{...}}` or
  `{"type":"reply","id":N,"error":{"code":..,"message":..}}`.
- `{"type":"ended"}` when the session is destroyed; the command then exits 0.

Input lines: `{"id":N,"method":M,"params":{...}}` where M is one of
`session.new_split`, `session.resize_pane`, `session.focus_block`,
`session.focus_direction`, `session.focus_next_pane`,
`session.focus_previous_pane`, `session.zoom_block`, `block.close`.
kwt sets `session_id`; any other method gets an error reply. Closed stdin
ends the command. It never starts a Rex server, and exits non-zero with a
message on stderr when the server or session is missing.

The Rex client gains an event channel (today it drops events). Tests use
the existing fake server, extended to push events.

## Ghosthub

### Sidebar

Rex rows group `kwt rex ls --json` terminals by session and window: one row
per Rex window. The title is the window label, or the focused pane's name
when Rex shows its default `Window xxxxxxxx` label. The detail is the
session label and the pane count. A Rex selection's address names the
session and window. Saved positions of the earlier per-pane rows are not
migrated.

### Split component (backend-neutral)

- `TerminalSplitTree`: value type. `Node` is `.pane(PaneID)` or
  `.split(SplitID, Axis, ratio, first, second)`; the tree also carries the
  focused and zoomed pane.
- `TerminalSplitLayout`: pure function from tree, bounds, gap, and backing
  scale to pixel-aligned pane frames and divider hit rectangles, with a
  minimum pane size for drag clamping.
- `TerminalSplitContainerView`: one AppKit view. `apply(_:)` diffs panes by
  ID, so a surviving pane keeps its card and terminal view and only frames
  change. Pane cards are rounded and carry a one-line header (title; split,
  zoom, close buttons when focused). Gaps are dividers with a resize cursor.
  A drag moves frames with surface resizing deferred; mouse-up flushes each
  surface once and reports the ratio. A zoomed pane covers the container;
  hidden panes keep running. Dividers are accessibility splitters named by
  the panes on each side.

### Rex window presentation

- Opening a window row starts `kwt rex control` locally or over the host's
  frozen SSH connection, and attaches each pane with the existing Rex
  terminal attach path (one `kwt rex attach` per block, existing reconnect).
- Each view maps the shown window's tiled layer to a `TerminalSplitTree`.
  New panes attach; panes gone from the view detach.
- Clicking a pane focuses it and sends `focus_block`. When the view's
  focused block changes, keyboard focus moves to that pane.
- ⌘W closes the view and stops the control channel; panes keep running.
- Known limit: Rex gives a terminal's size to the client that resized it
  last, so Rex.app showing the same window at the same time competes for it.

### Shortcuts (only while a Rex window is shown)

- ⌘D / ⇧⌘D: `new_split` beside the focused pane, side after, focus true.
- New configurable shortcuts: Focus Pane Left/Right/Up/Down (⌥⌘ arrows),
  Focus Next/Previous Pane (⌘] / ⌘[), Zoom Pane (⇧⌘↩).
- Close Pane: header × or command palette, confirmed, then `block.close`.

### Errors

- Control channel lost: the window shows the existing reconnect state.
- One pane's attach fails: that pane shows a small disconnected overlay.
- A request fails: logged; the view stays as Rex reports it.

## Verification

- Layout math against recorded Rex view fixtures.
- Pane identity: a surviving pane keeps its view object across `apply`.
- Drag: no surface resize before mouse-up; one `resize_pane` after.
- Presentation against a fake control channel, with one recorded view per pane.
- Real check: Ghosthub beside Rex.app on a throwaway local session (split,
  drag, focus, zoom), then delete the session.
- Budget: applying a layout only sets frames; a 16-pane layout computes in
  under 1 ms.

## Docs

Update the AGENTS.md "never reconstruct layout" rule, `architecture.md`, and
`terminal-sessions.md`: for Rex, Ghosthub draws Rex's own layout and never
invents one.

## Delivery

1. kwt PR: `kwt rex control`.
2. Ghosthub PR: pin that kwt, Rex window rows, split component, presentation,
   shortcuts, docs.
