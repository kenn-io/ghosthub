# Native Active-Pane Find

## Status

Approved design for GitHub issue #194, **Support find in terminal**.

## Summary

Ghosthub will provide the familiar macOS Find interaction while delegating
history search, match highlighting, and viewport movement to the backend that
owns the active pane. The first backend implementation is POSIX tmux. Herdr,
Zellij, and psmux remain unavailable until their installed command surfaces can
accept a search query and navigate results without synthesized user
keybindings.

The tmux implementation uses a small Ghosthub Find bar modeled on Ghostty.app.
The bar sends the current query and navigation requests to tmux copy mode. It
never captures, indexes, persists, logs, or renders pane history in Swift.

## Product Contract

Find searches the complete history owned by the active pane. Searching only
the libghostty client buffer is not an acceptable fallback for a multiplexer
session because that buffer may contain only the output rendered since the
client attached.

Ghosthub provides the same application-level commands wherever native Find is
available:

- **Find…** — Command-F
- **Find Next** — Command-G
- **Find Previous** — Shift-Command-G
- **Hide Find Bar** — Escape or the close button

The command names and shortcuts match Ghostty.app. For terminal history,
**Find Next** moves upward toward older matches and **Find Previous** moves
downward toward newer matches. This matches Ghostty.app's current terminal
search direction and tmux's natural backward-search flow.

Unsupported backends disable these commands. Ghosthub does not silently fall
back to visible-screen search, open an external editor, or inject a backend's
default key sequence.

## Goals

- Search the full active tmux pane history, including output produced before
  Ghosthub attached.
- Keep tmux authoritative for search semantics, highlighting, cursor
  selection, viewport position, and history lifetime.
- Present a Find bar that behaves like Ghostty.app rather than exposing tmux's
  status-line command prompt.
- Work for local and SSH-attached POSIX tmux sessions without changing tmux
  configuration or keybindings.
- Fence every operation to the exact server, client, session, and pane that was
  active when Find began.
- Keep unsupported backends explicit and non-destructive.

## Non-Goals

- Reconstructing or rendering multiplexer history in Swift.
- Returning pane text or match snippets to Ghosthub.
- Providing identical case-sensitivity, wrapping, or word-boundary semantics
  across different multiplexers. Each backend owns those semantics.
- Searching all panes, windows, tabs, sessions, or hosts.
- Searching stopped Herdr sessions or exited Zellij sessions.
- Adding or changing Herdr, Zellij, psmux, or tmux configuration.
- Restoring a search after navigation, reconnect, application relaunch, or
  session replacement.
- Displaying a tmux match count. tmux does not expose a reliable count through
  the command surface used here.

## Support Matrix

| Presentation | Find behavior |
| --- | --- |
| POSIX tmux 3.2 or newer | Available through native copy-mode search |
| Older POSIX tmux | Unavailable |
| psmux | Unavailable until its compatible command behavior is verified |
| Herdr | Unavailable because the current CLI can read history but cannot search or scroll to a match |
| Zellij | Unavailable because the current CLI cannot supply a search query without relying on configurable client keybindings |
| Standalone Ghosthub console | Available through libghostty because libghostty owns that surface's complete history |

The application derives availability from the active presentation and its
observed backend capability. Inventory presence alone does not imply Find
support.

## User Interaction

### Opening Find

Command-F opens a compact floating bar in the upper-right corner of the active
terminal. It contains:

- a single-line text field;
- an upward button for **Find Next**;
- a downward button for **Find Previous**; and
- a close button.

The field receives focus immediately. If the bar is already open, Command-F
focuses the field and selects its contents so the next typed character starts
a new query. Ghosthub keeps the most recent query in memory for that surface
until the surface closes; reopening Find restores and selects it.

The bar uses the same terminal-aware colors and compact visual treatment as
Ghostty.app. It omits the match counter for tmux. A missing count is better
than a guessed or incomplete count. The standalone console may show the count
reported by libghostty.

### Querying

The field sends a debounced query to the active backend. A nonempty tmux query
enters copy mode, moves to the bottom of history, and performs a plain-text
backward search. Resetting to the bottom makes an edited query select its most
recent match instead of continuing from a stale match.

Typing remains responsive while a remote command is in flight. Query work is
serial and latest-value-wins: at most one backend command runs at a time, and
intermediate values are discarded when newer input arrives. The final field
value is always the next value submitted.

Clearing the query exits the Find-owned tmux copy mode so stale highlights do
not remain visible. Typing a new nonempty value enters copy mode again.

### Navigating

Return, Command-G, and the upward button run **Find Next**. Shift-Return,
Shift-Command-G, and the downward button run **Find Previous**.

For tmux, **Find Next** repeats the backward search and moves toward older
matches. **Find Previous** reverses the search and moves toward newer matches.
Navigation does nothing while the query is empty.

### Closing

Escape or the close button hides the bar, cancels queued query work, exits copy
mode, and returns keyboard focus to the terminal. Starting a nonempty Find
query takes ownership of the pane's copy mode even if the user had already
entered it, so closing Find always returns to the live pane. This tradeoff
ensures that closing the bar cannot leave stale search highlighting behind.

Closing a workspace, switching presentation, disconnecting, or replacing any
fenced identity also ends Find. A later query or navigation request that finds
a different active pane closes the bar; it never follows that pane silently.

Search state is not restored after a reconnect. The user starts a fresh search
against the newly attached client.

## Architecture

### `TerminalFindController`

The active presentation exposes a small controller with these operations:

- availability;
- open;
- update query;
- find next;
- find previous; and
- close.

The controller communicates commands and state only. Its contract contains no
history text, match text, scroll offsets, or rendered terminal model.

The focused workspace scene routes Edit menu commands to its active
controller. Terminal shortcut reservation always sends Command-F, Command-G,
and Shift-Command-G to the application menu while a terminal has effective
focus, including when that presentation lacks Find support. This prevents an
unsupported multiplexer from falling through to libghostty's incomplete
client-buffer search. Menu availability determines whether the action can run.
Other views and text fields retain normal AppKit Find behavior because the
reservation applies only while a terminal has effective focus.

### Find State

Find state belongs to the visible terminal surface and contains:

- whether the bar is open;
- the current query;
- field focus and selection state;
- whether backend work is in flight; and
- an optional user-facing failure.

The state does not outlive its terminal surface and is never persisted. A
retained but hidden tmux surface closes Find before it is parked for preview.
Preview surfaces never expose Find.

### tmux Controller

The tmux controller lives beside other application-owned tmux operations. It
reuses the exact attached-client identity already established for pane splits:

- server process ID;
- client process ID and creation time;
- client terminal device;
- session ID and creation time; and
- active pane ID.

Opening Find freezes that identity. Every later command revalidates it at the
tmux mutation boundary. A same-named replacement session, replacement client,
or different active pane fails the guard and cannot receive the command.

The controller uses the resolved tmux executable, socket selection, host
account, and retained SSH lease already associated with the presentation. It
does not rediscover a route or follow a changed host configuration while Find
is active.

The tmux operations are:

1. For a nonempty query, enter copy mode for the fenced pane when needed.
2. Run `history-bottom` so query edits start from a stable position.
3. Run `search-backward-text` with the query as a separately quoted argument.
4. Run `search-again` for **Find Next**.
5. Run `search-reverse` for **Find Previous**.
6. Run `cancel` to end the Find-owned copy mode.

`search-backward-text` deliberately selects literal search rather than regular
expression search. Query text is passed through the existing shell-argument
quoting boundary and is never interpolated into a shell program or tmux format
expression.

The query necessarily crosses the trusted host account boundary as a tmux
command argument. Ghosthub never includes the query or rendered command in
application logs, failure diagnostics, or the terminal error overlay. The
query remains in Ghosthub memory only for the lifetime of its terminal
surface. tmux may retain its native previous-search value after copy mode
closes; Ghosthub neither duplicates nor persists that backend-owned state.

### Standalone Console Controller

A standalone console surface delegates to libghostty's `start_search`,
`search`, `navigate_search`, and `end_search` actions. Ghosthub handles the
corresponding start, end, total, and selected callbacks and hosts the same Find
bar. This is not a multiplexer fallback: libghostty is the console's terminal
and owns its full history.

## Failure Handling

Find fails soft. An unavailable backend disables the menu commands. It does not
produce a warning merely because its current version lacks Find support.

If an active operation fails:

- cancel queued work;
- close the Find bar;
- make no further backend mutation;
- return focus to the terminal when the presentation still exists; and
- show the existing compact terminal error overlay with a short diagnostic.

An identity mismatch uses the same replacement-session language as other
fenced tmux operations. SSH authentication and transport failures retain their
existing classifications. Find never opens a blocking alert and never retries
a query on a replacement connection. A later Command-F is a new operation and
may use a newly validated presentation route.

## Concurrency and Lifecycle

Each surface has at most one Find task lane. Query changes increment a local
generation. Completion publishes only when the surface, Find session,
generation, and frozen backend identity still match.

The lane serializes tmux commands and coalesces queued query changes. Close and
surface teardown cancel queued work. If a subprocess cannot be interrupted
after it begins, its result is ignored and its identity guard prevents it from
acting on a replacement target.

Find does not introduce a global lock across unrelated presentation
operations. Each tmux command places identity validation and its mutation in
one guarded tmux command queue, so a split, kill, detach, or reconnect cannot
redirect the mutation to another target. Find serializes only its own query and
navigation lane.

## Testing

### Pure behavior

- Menu availability follows the effectively focused presentation capability.
- Command-F, Command-G, and Shift-Command-G are reserved for the application
  whenever a terminal has effective focus, including unsupported backends.
- Opening an existing bar focuses and selects the remembered query.
- Empty queries disable navigation and end Find-owned copy mode.
- Query generations publish only the latest result.
- Closing, navigation, parking, and teardown cancel Find state.

### tmux integration

Tests use `TestTmuxServer` and the normal Swift test harness. They create real
scrollback and verify observable copy-mode behavior:

- the initial query selects the newest literal match;
- **Find Next** selects an older match;
- **Find Previous** returns to a newer match;
- punctuation with regular-expression meaning is searched literally;
- no-match queries leave the search active without inventing a result;
- clearing and closing exit copy mode;
- entering Find from an existing copy mode still exits to the live pane when
  Find closes;
- a changed server, client, session, or pane identity receives no command; and
- local and rendered remote command paths quote the query as data.

Failure tests also verify that query text never appears in logs or user-facing
diagnostics.

Remote runner tests verify that one query command is in flight, intermediate
queries coalesce, the final query executes, and close cancels pending work.

### libghostty console

Terminal smoke coverage verifies that libghostty callbacks open, update, and
close the bar; Return and Shift-Return navigate; Escape ends search; and owned
surfaces shut down through the existing teardown contract.

### Quality gates

Because this feature touches Swift terminal input, libghostty action handling,
tmux attachment operations, and user-visible workflow, implementation must run:

- `make format`
- `make test-libghostty-bootstrap`
- `make python-test`
- `make swift-test`
- `make test-essential-workflows`
- `make build`

The implementation updates `docs/architecture.md`,
`docs/terminal-sessions.md`, and the website Guide. At feature acceptance, it
also refreshes the documented UI screenshot through the repository's normal
website-assets workflow.

## Documentation Consequence

The architecture remains backend-owned: Ghosthub controls a native search
operation but does not become a history authority. The maintained architecture
and terminal-session documents must state that Find is the narrow exception
that lets Ghosthub request backend navigation while the backend continues to
own all pane text, match state, and rendering.

This design document is a local planning artifact. Repository policy requires
removing `docs/superpowers/specs/` from the task branch before any push or pull
request.
