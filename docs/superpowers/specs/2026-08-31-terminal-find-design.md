# Native Active-Pane Find

## Status

Revised design awaiting review for GitHub issue #194, **Support find in
terminal**.

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
- **Hide Find Bar** — Shift-Command-F, Escape, or the close button

The default command names and shortcuts match Ghostty.app. Find commands are
catalog actions, so Ghosthub's existing keybinding preferences may rebind them.
For terminal history, **Find Next** moves upward toward older matches and
**Find Previous** moves downward toward newer matches. This matches
Ghostty.app's current terminal search direction and tmux's natural
backward-search flow.

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
- Displaying a current-match index for tmux. The tmux controller publishes an
  exact total when available but does not model the selected match's position
  within that total.

## Support Matrix

| Presentation | Find behavior |
| --- | --- |
| POSIX tmux 3.5 or newer | Available through native copy-mode search, with an exact total when tmux completes its count |
| POSIX tmux 3.4 | Available through native copy-mode search, without a match total |
| POSIX tmux older than 3.4 | Unavailable |
| psmux | Unavailable until its compatible command behavior is verified |
| Herdr | Unavailable because the current CLI can read history but cannot search or scroll to a match |
| Zellij | Unavailable because the current CLI cannot supply a search query without relying on configurable client keybindings |
| Standalone Ghosthub console | Available through libghostty because libghostty owns that surface's complete history |

The application derives availability from the active presentation and its
observed backend capability. Inventory presence alone does not imply Find
support. The tmux 3.4 floor intentionally matches the existing pane-split
capability gate. Find reuses that implementation's tested client-specific hook
guard instead of adding a second guard and a separate 3.2 compatibility path.
tmux 3.5 added the `search_count` and `search_count_partial` formats, so only
3.5 and newer can publish a match total.

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
Ghostty.app. `search_present` is the authoritative tmux result signal on every
supported tmux version. When it is `0`, the bar shows **No matches**, clears any
total, and disables navigation even though tmux remains in copy mode. When it
is `1`, the bar enables navigation. On tmux 3.5 and newer, it also shows a total
such as **5 matches** only when `search_count` is a valid unsigned integer and
`search_count_partial` is exactly `0`. It hides partial, empty, malformed, and
tmux 3.4 totals. It never presents a partial result as exact and does not invent
a current-match index. The standalone console may show the selected and total
counts reported by libghostty.

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
Navigation does nothing while the query is empty or the current result is
**No matches**.

### Closing

Shift-Command-F, Escape, or the close button hides the bar, cancels queued query
work, exits copy mode, and returns keyboard focus to the terminal. Starting a
nonempty Find query takes ownership of the pane's copy mode even if the user had
already entered it, so closing Find always returns to the live pane. This
tradeoff ensures that closing the bar cannot leave stale search highlighting
behind.

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
controller. The Find actions' default catalog bindings are Command-F,
Command-G, Shift-Command-G, and Shift-Command-F. Terminal shortcut reservation
sends the actions' effective bindings to the application menu while a terminal
has effective focus, including when that presentation lacks Find support. This
prevents an unsupported multiplexer from falling through to libghostty's
incomplete client-buffer search. Menu availability determines whether the
action can run. Other views and text fields retain normal AppKit Find behavior
because the reservation applies only while a terminal has effective focus.

### Find State

Find state belongs to the visible terminal surface and contains:

- whether the bar is open;
- the current query;
- field focus and selection state;
- whether backend work is in flight;
- the result state: idle, match, or no match;
- an optional exact match total; and
- an optional user-facing failure.

The state does not outlive its terminal surface and is never persisted. A
retained but hidden tmux surface closes Find before it is parked for preview.
Preview surfaces never expose Find.

### tmux Controller

The tmux controller lives beside other application-owned tmux operations. It
reuses the exact attached-client identity and guarded mutation mechanism already
established for pane splits:

- server process ID;
- client process ID and creation time;
- client terminal device;
- session ID and creation time; and
- active pane ID.

Opening Find freezes that identity. Every later command revalidates it at the
tmux mutation boundary. A same-named replacement session, replacement client,
or different active pane fails the guard and cannot receive the command.

Each mutation installs a uniquely indexed `after-refresh-client` hook, invokes
`refresh-client` against the frozen client TTY with a unique marker argument,
and removes the hook. Inside that client-specific hook, tmux validates the
server, client, session, pane, and `hook_argument_0` marker before executing the
mutation. This is the existing tmux 3.4-and-newer pane-split guard, not a new
3.2 guard assembled from client formats outside their meaningful hook context.
`hook_argument_0` is not documented in the tmux 3.7c manual, but it is an
inherited dependency already exercised by Ghosthub's real-tmux pane-split
integration test. Find keeps that executable coverage rather than treating the
manual omission as a separate fallback requirement.

The controller uses the resolved tmux executable, socket selection, host
account, and retained SSH lease already associated with the presentation. It
does not rediscover a route or follow a changed host configuration while Find
is active.

The tmux operations are:

1. For a nonempty query, enter copy mode for the fenced pane when needed.
2. Run `history-bottom` so query edits start from a stable position.
3. Run `search-backward-text` with the query as one tmux command argument.
4. Run `search-again` for **Find Next**.
5. Run `search-reverse` for **Find Previous**.
6. Run `cancel` to end the Find-owned copy mode.
7. On every supported tmux version, read `search_present` after search and
   navigation mutations. On tmux 3.5 and newer, also read `search_count` and
   `search_count_partial`. The read is one `display-message -p` in the same
   guarded tmux queue, not another SSH round trip. tmux 3.4 prints
   `GHOSTHUB_TMUX_FIND_STATE_<token>\t<search_present>`; tmux 3.5 and newer
   append `\t<search_count>\t<search_count_partial>`. The random per-operation
   token lets parsing ignore unrelated merged stdout and stderr. The controller
   accepts numeric or empty count fields only after it validates the marker and
   `search_present`. It never requests `search_match`, which would return
   matched pane text.

`search-backward-text` deliberately selects literal search rather than regular
expression search. The guarded mutation crosses one account-shell argv parse
and three tmux command parses: tmux parses the installed hook body, the marker
`if-shell` success body, and the identity `if-shell` success body that contains
the mutation. Its renderer builds commands from the inside out. It first
encodes the query as one single-quoted tmux command argument for the innermost
`send-keys -t <pane> -X search-backward-text -- <query>` command. It then
single-quotes that complete command as data at tmux depth two, single-quotes
the resulting child command again at tmux depth one, and finally shell-quotes
the top-level tmux argv once for the local or remote account shell.

A dedicated tmux-command argument encoder implements tmux parsing rules. At
every tmux nesting level, it emits the query and each child command only as a
single-quoted tmux token and splices an embedded single quote with the tmux
`'\''` form. It never emits query-bearing data in a double-quoted or unquoted
tmux token, because tmux expands `$NAME` and `${NAME}` in those forms at every
parse level. The shell argument helper alone is not sufficient for the nested
layers.

The query is never concatenated into a command body without that layer's
encoding and is never used as a tmux format. The search command does not request
format expansion, so literal text such as semicolons, quotes, backslashes,
`#{...}`, `$HOME`, `${x}`, and leading hyphens reaches `search-backward-text` as
data. The `--` terminator prevents a leading hyphen from becoming an option. The
Find field is single-line; Return and Shift-Return navigate instead of becoming
query characters.

The query necessarily crosses the trusted host account boundary as a tmux
command argument. Ghosthub never includes the query or rendered command in
application logs, failure diagnostics, or the terminal error overlay. The
query remains in Ghosthub memory only for the lifetime of its terminal
surface. tmux may retain its native previous-search value after copy mode
closes; Ghosthub neither duplicates nor persists that backend-owned state.

### tmux Multi-Client Behavior

tmux stores copy mode and its search state on the pane, not on an individual
client. The client-specific identity guard chooses and validates the pane but
does not make its copy-mode viewport private. Every attached client displaying
that pane can therefore see Find enter copy mode, move the viewport, highlight
matches, and return to the live pane. This includes a retained Ghosthub preview
client in another scene and independently attached third-party clients. A
preview reflects tmux's current rendering but never shows its own Find bar or
accepts Find controls.

This pane-wide effect is an accepted consequence of backend-owned search.
Ghosthub does not create a shadow pane, copy pane history, or lock out other
clients to hide it. Other clients remain free to change or exit copy mode, so
their actions and Ghosthub's actions follow tmux's native last-writer-wins
behavior. The identity fence prevents retargeting; it does not claim exclusive
ownership of pane mode. If another client ends the mode, a navigation command
fails soft and closes the initiating Find bar. Reopening the bar and submitting
a query starts a fresh guarded search.

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
- show the existing compact terminal error overlay with a short, Find-specific
  diagnostic.

An identity mismatch uses the same replacement-session language as other
fenced tmux operations. SSH authentication and transport failures retain their
existing classifications. Find never opens a blocking alert and never retries
a query on a replacement connection. A later Command-F is a new operation and
may use a newly validated presentation route.

Find reuses the overlay presentation, not the pane-split-specific names or
diagnostic plumbing. The implementation renames `paneSplitErrorMessage` to
`terminalOperationErrorMessage` and `NativePaneSplitErrorOverlay` to
`NativeTerminalOperationErrorOverlay`; pane split and Find failures share those
generic presentation names. Raw tmux stderr and rendered commands can contain
the query, so the controller does not pass
`TmuxPaneSplitFailure.normalizedDiagnostic` or any raw process output to the
overlay or application logs. It maps status, identity markers, and transport
classification to fixed query-free messages. Raw output may be examined
transiently for classification but is never published or retained.

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
- The default Command-F, Command-G, Shift-Command-G, and Shift-Command-F
  bindings are reserved for the application whenever a terminal has effective
  focus, including unsupported backends; rebinding the catalog actions updates
  the reserved shortcuts.
- Opening an existing bar focuses and selects the remembered query.
- Empty queries disable navigation and end Find-owned copy mode.
- `search_present=0` produces **No matches**, disables navigation, and wins over
  either empty or zero-valued count fields while copy mode remains active.
- Exact tmux totals appear only when the count is not partial; partial and
  unavailable totals remain hidden.
- Query generations publish only the latest result.
- Closing, navigation, parking, and teardown cancel Find state.

### tmux integration

Tests use `TestTmuxServer` and the normal Swift test harness. They create real
scrollback and verify observable copy-mode behavior:

- the initial query selects the newest literal match;
- **Find Next** selects an older match;
- **Find Previous** returns to a newer match;
- regular-expression punctuation is searched literally;
- semicolons, single and double quotes, a leading single quote, `#{...}`,
  backslashes, `$HOME`, `${x}`, and a leading hyphen survive all three tmux
  parsing depths and the shell boundary as literal query data;
- no-match queries leave only copy mode active, publish **No matches**, and make
  navigation a no-op;
- tmux 3.5-and-newer searches return an exact total from the same guarded queue,
  while tmux 3.4 searches do not request unavailable count formats;
- clearing and closing exit copy mode;
- entering Find from an existing copy mode still exits to the live pane when
  Find closes;
- a changed server, client, session, or pane identity receives no command; and
- local and rendered remote command paths quote the query as data.

Multi-client integration coverage attaches two clients to the same pane and
verifies the documented pane-wide behavior: search mode and viewport changes
are shared, only the initiating surface owns a Find bar, and another client's
exit from copy mode makes navigation fail soft rather than target a different
pane.

Failure tests also verify that query text never appears in logs or user-facing
diagnostics.

Result-parser tests feed marked output mixed with unrelated stdout and stderr.
They cover `search_present=0` with either zero-valued or empty count fields,
reject unmarked lines, and require exactly the version-specific state fields
defined above. Command-construction coverage verifies that the marked state
probe requests only `search_present`, `search_count`, and
`search_count_partial`. These tests cover Ghosthub's owned protocol; the
real-server integration test covers one current tmux rendering rather than
trying to force tmux's timing-dependent partial-count path.

Remote runner tests verify that one query command is in flight, intermediate
queries coalesce, the final query executes, and close cancels pending work.

### libghostty console

Terminal smoke coverage verifies that libghostty callbacks open, update, and
close the bar; Return and Shift-Return navigate; Shift-Command-F and Escape end
search; and owned surfaces shut down through the existing teardown contract.

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
