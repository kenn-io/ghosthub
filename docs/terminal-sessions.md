# Terminal sessions

Terminal behavior is the highest-risk part of Ghosthub. Attached sessions must
behave like a normal macOS terminal while staying isolated from Ghostty.app
config and launcher-terminal environment variables.

## Product boundary

Ghosthub is a native hub for local and remote terminal multiplexers across the
local Mac and configured SSH hosts. Discovery reads five independent sources:

- **kwt workspaces:** Git projects, worktrees, and registered plain directories
  from kwt's JSON commands, with each workspace's exact `session_name`.
- **Standalone tmux sessions:** every other session from `tmux list-sessions`
  on the default tmux server or kwt's `kwt` server (socket is part of identity,
  so equal names on the two servers stay separate).
- **Herdr TUI sessions:** running and stopped sessions from
  `herdr session list --json` on the local Mac and remote POSIX hosts.
- **Backend terminals (macOS app):** live terminals from `herdr-core ls --json`
  and Rex windows from Ghosthub's pinned `kwt rex ls --json`; see
  [Backend terminals](#backend-terminals).
- **Zellij sessions:** active sessions from
  `zellij list-sessions --no-formatting` on the local Mac and remote POSIX
  hosts (exited/resurrectable sessions are filtered out).

Both tmux sources attach through the normal tmux client inside a libghostty
surface; Herdr TUI and Zellij attach through their normal whole-session clients.
Middleman-created sessions appear only because they are ordinary tmux sessions;
Ghosthub never calls Middleman. **New Tmux Session** creates an ordinary tmux
session that immediately joins regular discovery with the same detach-only view
lifecycle.

Herdr and Zellij are optional. Exit 127 during capability or inventory probes
is silent; malformed output or other errors produce only a host-scoped warning
without affecting tmux, kwt, or workspace availability.

The Rust Windows and Linux apps keep this same boundary (see
[Windows and Linux Rust Port](rust-port.md)); this document remains the source
of truth for ownership, reconnect, detach, and restart behavior on every
platform.

## Native tmux attachment

Ghosthub runs `tmux attach-session -E -t =<name>` locally, through OpenSSH on
remote POSIX hosts, and through encoded PowerShell + psmux's `tmux.exe` on
experimental Windows hosts. Ghosthub never uses `tmux -CC`, pane capture,
history replay, silent rendering children, or a Swift split-tree projection.
tmux owns windows, panes, layout, focus, status line, history, alternate
screen, processes, session lifetime, key bindings, and mouse bindings.

Ghosthub owns inventory, client surfaces, and connection state:

- **Mouse mode and Command-click links:** before attaching on POSIX hosts,
  Ghosthub best-effort enables the session's shared `mouse` option so wheel
  scrolling enters tmux copy mode even with a default tmux config (leaving tmux
  mouse bindings intact; psmux skips this). For Command-modified pointer
  movement, modifier changes (reusing the last tracked in-window pointer
  location), and left clicks, Ghosthub injects libghostty's Shift mouse-capture
  override internally so Command-click links bypass tmux without holding Shift.
- **SSH leases and session budgeting:** remote POSIX views acquire one
  multiplexed kwt SSH lease before their first probe and hold it through exit
  (reusing the same frozen route for tmux discovery, attach, splits, and
  identity checks; reconnect re-resolves from scratch). OpenSSH exit 255 marks
  a shared lease unusable; masterless leases fail closed. Each view claims a
  terminal slot on its master (moving to another kwt master when full; see
  [Architecture](architecture.md)). Read-only inventory and probe commands
  retry up to 5 times on `session open refused by peer` without marking the
  master unusable; mutating commands never retry automatically. Lease failures
  open a modal only when OpenSSH needs host-key review, auth, or config
  recovery; transport drops return to the background reconnect supervisor.
  Tailscale browser checks show a link in the recovery sheet and keep the
  attempt open until approved or timed out.

### Active-pane Find

**Cmd-F** searches full scrollback of the active pane without copying history
into Ghosthub:

- Standalone shells use libghostty's native search.
- POSIX tmux 3.4+ delegates to tmux copy mode fenced to the exact server,
  session, client, and pane. tmux 3.5+ reports exact totals when
  `search_count_partial` is 0; 3.4 reports match presence only. tmux 3.6+ gets
  the `--` option terminator; 3.4 to <3.6 uses the legacy command form.
- tmux controls wrapping and direction-change steps; copy mode is pane-wide so
  other clients on the same pane can see or cancel the search.
- Parking a preview, replacing an attachment, disconnecting, or closing the
  surface ends Find. Herdr, Zellij, Windows/psmux, and tmux <3.4 disable Find.
  Queries stay in memory only and never enter logs or diagnostics.

### Retained views, Kill Session, Rename Session, and themes

Each workspace window retains every tmux view it opens, keyed by host, socket,
attachment mode, and session name. Switching rows hides and marks the previous
surface occluded without closing its client; returning reuses it. **Cmd-W** or
a pane-close request detaches only the active view; closing the window or
quitting detaches all views without killing sessions.

- **Kill Session (confirmed):** offered only for sessions confirmed live.
  Captures host, socket, name, tmux server PID, `session_id`, and
  `session_created`, then executes one tmux conditional checking all three live
  values before running `kill-session` (Swift targets the exact name; Rust
  matches decoded names from a length-framed listing and targets only the
  captured stable session ID). Active clients detach only after the kill
  succeeds, and the window navigates away only if that killed session is still
  the active selection.
- **Rename Session:** offered only for standalone sessions on the default
  server of macOS/Linux hosts (never kwt-owned worktrees or directories; names
  starting with `kwt-wt-` or `kwt-workspace-` or colliding with a kwt workspace
  are rejected). Validates the captured server PID, `session_id`, and
  `session_created` inside one tmux conditional before running
  `rename-session`. Clients stay attached across renames (never detaching the
  last client). The requesting window rejects rename while its own view of that
  session is connecting, reconnecting, or resizing.
- **Cross-window rename tracking:** renames enter an in-memory log keyed by
  session identity, fencing older in-flight discovery listings. Windows that
  cannot rekey immediately apply the log once connected or on the next listing.
  Reconnecting SSH views reserve the new name and reattach by `session_id` when
  a rename is discovered. Name-swap cycles rekey one view to a synthetic
  temporary key to break the cycle. Standalone attaches also target
  `session_id` behind the same identity check. Cleanly detached views rekey and
  stay detached; if a window ends up holding two views of the same session, it
  keeps the active one and detaches the duplicate only inside a tmux queue
  confirming both clients are still on the kept session (never detaching a
  session's last client). Saved sidebar order moves to the new name.
- **Tmux themes:** applied on new bare session creation (`Follow ghostty.conf`
  reads libghostty's resolved light/dark colors). Existing sessions keep their
  own styles by default. The opt-in shared-session override (and one-shot
  **Session → Apply Theme to Current Session**) resets `status-style`,
  `message-style`, and `message-command-style` to terminal defaults and sets
  existing window foreground/background for all clients (never on Console Panel
  or Windows/psmux, where psmux applies `reverse` across the client).

## Backend terminals

Herdr Core and Rex expose individual backend terminals or multi-pane windows.
Ghosthub lists Herdr desktop tabs, standalone Herdr Core terminals, and Rex
windows in each host's unified session list (**herdr** and **rex** labels,
distinct from **herdr tui**), with address or Rex details shown after the
title. Sibling navigation walks the entire list in sidebar order and skips
stopped Herdr sessions.

- **Identity:** host, kind (`core` or `rex`), and address (`t7`, `tab:<id>`, or
  `window:<id>`). Display names are never identity.
- **Discovery:** runs all backends on a host over one SSH lease, independent of
  Herdr TUI discovery. Missing binaries are silent; failed backends keep their
  last listing with a host warning. Scheduled sweeps let slow runs finish;
  manual refresh or host changes replace them. Saved sidebar order prunes only
  after every backend on the host reports.
- **Opening and input gating:** opening a backend terminal (or a Herdr/Zellij
  session) re-lists its backend over a frozen SSH route while keeping the
  current view visible, pausing keystrokes and reconnects on that held view
  until the last pending check ends. Navigating away or pressing **Cmd-W**
  cancels pending checks immediately; a failed open restores focus to the held
  view unless the user moved focus elsewhere.
- **Reconnect and exit:** attach binds to the verified SSH route (a changed
  route stops and prompts to reopen). OpenSSH status 255, transport errors, or
  unready surfaces retry with backoff. Other client exits trigger one listing
  on the original route: if the terminal is gone, the view closes; if still
  listed (or the check fails), it waits for **Retry**. Auth/host-key errors
  offer **Review Connection**. Restoration waits until confirmed; Ghosthub 0.13
  entries that saved a Herdr desktop terminal as a Herdr session are dropped
  rather than attaching a same-named TUI session.

### Herdr Core terminals

Resolved via `herdr-core` in the host login shell (`hc` is never used). Uses
`herdr-core ls --json` and `herdr-core attach <address>` (verified with core
0.1.21). Lists only `state: live` local `t…` terminals (excluding finished and
`machine/t…` entries), displaying name, `where`, or agent label with the
address below.

Discovery also reads Herdr desktop's `herdr-app` layout document via `doc.get`
over `herdr-core connect` (read-only). Each desktop tab containing a live local
terminal becomes one `tab:<id>` row (suppressing individual rows for its
terminals); without a readable document, each terminal gets its own row. Tab
rows render in the same split container as Rex windows (nested binary splits
from row/column weights; active child for stacks; non-terminal panels and edge
floats omitted) and stay live via a `herdr-core connect` change subscription
(re-listing on document, terminal-set, label, title, or missed events). Focus
and zoom stay local to Ghosthub; split, close, resize, and float are disabled
(see the [user guide](https://ghosthub.ai/docs/sessions/#herdr-desktop-splits)).

Before discovery and attach, Ghosthub clears inherited Herdr TUI variables plus
`HC_SESSION`, `HC_SOCKET`, `HC_TERMINAL_ID`, and `HC_TERMINAL_SOCKET` so the
account's default core is always targeted (upstream `ls` can start it if not
running). Verify locally with
`make test-herdr-core HERDR_CORE_BINARY=/absolute/path/to/herdr-core`.

### Rex windows

Ghosthub accesses [Rex](https://www.superlogical.com/rex/docs) strictly through
its pinned kwt (bundled locally; `$HOME/.ghosthub/helpers/kwt/<revision>/kwt` on
SSH hosts, never `PATH`). kwt checks `REX_SERVER` or
`rex whoami --autostart=false` so Ghosthub never starts a stopped Rex server.

- **Listing:** `kwt rex ls --json` returns one row per `window:<id>` (auto
  `Window <id>` labels are replaced by the focused pane's title or foreground
  program/directory such as `zsh ~`; open windows update their row live).
- **Control and panes:** opening a window runs `kwt rex control <window-id>`
  (without a TTY over SSH) for streaming JSON layout views and RPC requests,
  drawing the tiled split tree plus floating layers back-to-front and attaching
  each pane with `kwt rex attach <block-id>`. Divider drags defer terminal
  resizes until release.
- **RPC operations (shown once Rex reports the updated view):**
  - Split Right / Split Down (++cmd+d++, ++shift+cmd+d++, header buttons):
    `session.new_split` in the focused pane's foreground directory.
  - Divider release: `session.resize_pane` (snaps back if Rex refuses).
  - Pane focus / focus shortcuts: `session.focus_block` (Ghosthub picks
    neighbors from its drawn layout and lets local focus lead lagging views;
    only the focused pane auto-claims keyboard focus).
  - Zoom: `session.zoom_block`.
  - Close Pane (confirmed): `block.close`.
  - Floating panes (Command Palette, unbound by default):
    `session.new_layer`, `session.float_block`, `session.move_block` (Tile),
    `session.resize_layer`, `session.raise_layer`, and `session.set_layer_state`
    (Minimize, disabled if no other pane would remain visible).
- **Creating sessions and windows:** **New Rex Session…** (host **+** menu or
  palette, optional name) and **New Rex Window** (palette, while a Rex window is
  shown) run `kwt rex new` once, without the listing retry, because a retry
  after a lost reply could open a second window. A new window joins the shown
  window's session with its shell in the focused pane's directory. Ghosthub
  then re-lists and opens the new window like a listed row. Hosts offer New Rex
  Session only while their last listing found a running server.
- **Detach and reconnect:** ++cmd+w++ detaches while leaving panes running.
  Closing the window in Rex closes Ghosthub's view. Control-channel drops retry
  with backoff on SSH (or wait for **Retry** locally); single-pane drops follow
  backend-terminal reconnect rules. Verify (including `kwt rex new`) with
  `make test-rex REX_BINARY=/absolute/path/to/rex` (on macOS,
  `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex`).

## Native Herdr attachment

### TUI sessions

Ghosthub resolves `herdr` in the login environment and attaches whole sessions
via `herdr session attach <exact-name>` (normal macOS login shell locally;
OpenSSH PTY + kwt lease remotely; never Herdr's own remote-client mode). Herdr
owns workspaces, tabs, panes, layout, history, key bindings, and processes.
Closing a view, tab, window, or app detaches only.

### Herdr pane splitting

**Cmd-D**, **Cmd-Shift-D**, and the File menu call
`herdr pane split --direction right|down --focus` when the active Herdr client
is 0.8.0+ and running (probed per attachment and refreshed after Create or
Restart). Uses the attachment's frozen executable, SSH args, and socket with
inherited Herdr variables scrubbed and only `HERDR_SOCKET_PATH` set, letting
Herdr pick its session-global focused pane (verified on Herdr 0.8.0). Requests
serialize per attachment without retry and cancel on detach. Because Herdr has
no stable generation or client ID, same-name/same-socket replacement is an
accepted limit.

### Herdr session lifecycle

- **Open / restore:** `herdr session attach <exact-name>` on running entries.
- **Create / Restart:** `herdr` (default) or `herdr --session <name>` (launches
  a missing server and attaches).
- **Stop / Delete (confirmed):** reacquires the reviewed SSH route, reruns
  `herdr session list --json`, and checks expected state and config paths
  before running. Stop ends all processes while preserving saved layout (and
  suppresses reconnects across all scenes until finished); Delete removes a
  stopped non-default session permanently (default session can never be
  deleted). Because Herdr lacks a stable generation ID, create collisions,
  same-socket replacement after revalidation, and `session attach` resurrecting
  a just-stopped server remain documented races.
- **Environment scrub:** discovery, probes, and attach clear `HERDR_ENV`,
  `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_CLIENT_SOCKET_PATH`,
  `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_BIN_PATH`,
  `HERDR_ACTIVE_WORKSPACE_ID`, `HERDR_ACTIVE_TAB_ID`, `HERDR_ACTIVE_PANE_ID`,
  and `HERDR_ACTIVE_PANE_CWD`. Automated fixtures must isolate Herdr with
  `XDG_CONFIG_HOME` (`HERDR_CONFIG_PATH` alone is insufficient).

## Native Zellij attachment

Ghosthub resolves `zellij` in the login environment (important on macOS so
Dock/Finder launches do not pass launchd's minimal `PATH` to a new Zellij
server) and attaches active sessions via `zellij attach <exact-name>` or
creates new ones via `zellij --session <exact-name>` (remote uses OpenSSH PTY +
kwt lease). Never place `--` before the session name (Zellij 0.45 treats args
after `--` as an initial command). Names starting with `-` (other than `-`
alone), `help`, and `options` cannot be created or attached; existing sessions
with those names remain listed and killable.

Zellij owns tabs, panes, layout, history, key bindings, config, plugins, and
processes. Ghosthub lists active sessions only, never resurrects or deletes
exited sessions, and never passes `--force-run-commands` (accepting Zellij's
narrow probe-to-attach resurrection race). Inherited `ZELLIJ`,
`ZELLIJ_PANE_ID`, and `ZELLIJ_SESSION_NAME` are cleared before discovery and
attach.

Closing a view detaches only; clean detaches stay detached. Remote SSH drops
probe the exact active session before reattaching. **Kill Session** confirms
host, name, and route key (without retaining the pre-confirmation lease),
reacquires the route, raises a cross-scene kill fence (detaching matching
clients, pausing reconnects, bumping a per-session kill revision), re-checks
active discovery, and runs `zellij kill-session <exact-name>` (accepting the
check-to-kill same-name race since Zellij has no generation ID).

## Rust client lifetime and application death

The Rust apps enforce the same disposable-client boundary. On Windows, the GPUI
client attaches to tmux, Herdr, and Zellij inside WSL2 (plus configured POSIX
SSH hosts via pinned kwt + `/usr/bin/ssh` inside WSL); closing or force-killing
Ghosthub must reap only the `wsl.exe` relay and Linux client while leaving the
tmux server alive. (Terminating the WSL distro ends the local relay/lease, not
remote SSH sessions.)

- **Structural launch authority:** attach plans are cloneable and cannot
  create; `CreateOnce` is non-cloneable/non-serializable and consumed into an
  attach plan; kwt repair/open is cloneable because probe/repair is safe to
  rerun. Local exits never reconnect; only remote OpenSSH exit 255 enters
  transport recovery.
- **WSL creation and admission:** local WSL creation runs
  `tmux new-session -A -E -s <name>` and writes server PID, session ID, and
  creation time via `/bin/sh -c` to a nonce-scoped private receipt (never
  printing framing into ConPTY). Tmux admission runs real ConPTY probes (second
  `new-session -A`, `-E` positive/preservation controls) inside a random
  mode-0700 `TMUX_TMPDIR` with a 2-second settle cleanup loop and inherited
  `TMUX`/`TMUX_PANE` scrubbed, never touching the user's default server. psmux
  3.3.7's failed `kill-session -t =name` proof keeps WSL2 tmux as the Windows
  MVP substrate.
- **Process containment and identity-checked attach:** `wsl.exe` is resolved
  through `GetSystemDirectoryW` and placed in a client-only
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` Job Object (verified with
  `IsProcessInJob`; on failure, Ghosthub tears down the client and releases
  state). Runtime identity combines kernel boot ID with PID 1 start time to
  detect distro-only restarts. Every attach runs a tmux `if-shell -F` checking
  server PID, session ID, and creation time, running `attach-session -E` only
  on a match and otherwise printing a framed mismatch marker and exiting cleanly.

## Relaunch restoration

Quitting or updating drops only disposable clients. On relaunch, Ghosthub
resolves each scene's logical descriptor against fresh inventory and uses
attach-only restoration (never creating missing sessions or switching
hosts/sockets):

- Worktrees match by durable kwt generation (missing generation stops at the
  project; observed generation cannot be cleared by partial inventory and
  treats generation changes as replacements). Directory workspaces match by
  registered path on the same host.
- **Sparkle Install and Relaunch:** writes a one-shot ordered window manifest
  under `~/.ghosthub/` before exit. On relaunch, Ghosthub waits for AppKit
  native restoration and binding quiescence, assigns unclaimed descriptors
  provisionally, opens fresh-token replay scenes for missing descriptors, lets
  late native descriptors reclaim their slots, applies saved window frames, and
  removes the manifest once every saved descriptor has begun restoring.
- **Per-backend rules:** tmux checks direct discovery; Herdr requires a fresh
  running probe; Zellij requires a fresh active probe plus frozen SSH route
  check; protected PR worktrees probe their exact socket before invoking
  `kwt pr attach` (never falling back to the default server). Offline targets
  stay pending until refreshed or canceled by user navigation. Empty scenes
  restore navigation without starting worktree sessions. Console Panel stays
  outside scene restoration (shared-window behavior tracked by kata `s75s`).
- **Rust cold-start Reconciler:** reads only published inventory generations
  (never probes hosts or kills sessions) and expires pending restores after 3
  failed refreshes, 10 minutes, or user navigation.

### Session creation, worktree open, and pane splits

- **Bare tmux creation:** local uses atomic `new-session -A` (closing the
  `destroy-unattached` race); remote runs one-shot `has-session` + detached
  `new-session` then attaches, permanently demoting reconnects to attach-only.
  Native Windows creation forwards the SSH account's `PATH` via `new-session -e`.
  Optimistic rows stay visible during launch and reconcile via bounded retries.
- **Worktree and directory open:** executes `kwt open <exact-path>` (with all
  four `--expected-*` guards for Git worktrees; omitted for plain directories)
  so kwt creates or repairs the layout without an intermediate detached session.
  If the managed helper is unavailable, cached live sessions still attach via
  `tmux attach-session`. On POSIX hosts, every tmux phase runs through the
  login shell and clears `TMUX_TMPDIR` on the `kwt` socket (retaining it on
  default/other sockets).
- **Protected worktree Kill and fallback row:** Kill queries fresh identity on
  the exact protected socket (never matching the default server). If an active
  or retained protected view loses its owning worktree row, Ghosthub keeps a
  fallback session row so the client stays reachable.
- **tmux binary resolution:** POSIX requires tmux 3.2+ (login shell hands probe
  to `/bin/sh` so fish never parses it); Windows resolves `tmux.exe` via
  PowerShell `Get-Command` (psmux 3.2 compat). Cached per frozen host route.

## SSH keepalive and reconnect

Remote clients use OpenSSH with server keepalives under bundled kwt's
`kwt.openssh.projection.v2` policy:

- **Compression:** on by default for saved hosts (toggleable in **Settings →
  Hosts**; off for dynamic exe.dev accounts/VMs; jump hosts keep their own SSH
  config). Contributes to route identity; changing it detaches open views on
  that host.
- **Scoped daemon and prompts:** route resolution, leases, and `kwt ssh exec`
  use `~/.ghosthub/ssh/kwt` (isolated from the user's normal kwt daemon).
  Prompts stream in order to one eligible window at a time; background
  inventory and short commands are noninteractive and fail closed if a prompt
  is needed.
- **Exit-status capture and backoff:** remote commands are one-shot and write
  their exit status to a per-launch temp file (since libghostty's outer macOS
  login wrapper can mask nested exit 255). Status 0 is clean detach, 255 is
  transport loss, and other nonzero codes are non-transport client errors. On
  255, the per-view supervisor probes at 1, 2, 4, 8, 16, and 30s attempt-start
  intervals (15s probe timeout, non-overlapping; **Reconnect Now** wakes it
  immediately). Default-server probes share host `list-sessions`; named sockets
  run headless `tmux -L <socket> has-session -t =<name>`; Herdr runs its own
  exact probe. Confirmed absence ends established sessions (unconfirmed kwt
  opens may retry once); auth/host-key errors pause and show **Connection needs
  attention** / **Review Connection** (never silently accepting a changed host
  key). Host Settings probes emit a leading marker so remote command failures
  are separated from exit-255 offline failures.
- **Windows ConPTY note:** experimental psmux requires Windows 11 build 22523+
  so standard OpenSSH PTYs preserve mouse reporting without `ssh -T`.
- **Clipboard and image paste:** remote panes may write the Mac clipboard via
  OSC 52 when `clipboard-write` permits; remote OSC 52 and Kitty clipboard
  reads are always blocked (only explicit `paste_from_clipboard` reads text;
  bracketed paste and unsafe-paste confirmation stay active). On local or
  remote POSIX tmux surfaces, **Cmd-V** with an image-only clipboard encodes a
  PNG, stages it into `~/.ghosthub/paste-images/` on the session host (pruning
  images older than 7 days), and pastes its path; text wins when both are
  present, and **Ctrl-V** passes through to the terminal.

## Inventory and startup

Startup runs kwt, tmux, and optional Herdr/Zellij discovery in parallel (Herdr
and Zellij skipped on Windows) and keeps a loading state until kwt returns so
empty onboarding never flashes prematurely. Failures degrade per host with
cached rows and a retry warning (exit 255 reported as SSH failure).

- **Remote kwt helpers:** auto-installed under `~/.ghosthub/` on macOS/Linux
  before kwt inventory (provisioning failures disable worktrees on that host
  without blocking tmux). **Add Project** revalidates host ID before passing
  one absolute path to kwt; **Remove Project** probes protected worktrees first
  (blocking if any protected session is live) and unregisters metadata only.
  Windows installs `%USERPROFILE%\.ghosthub\helpers\kwt\<revision>\kwt.exe`
  only via explicit **Install Bundled kwt** and hides project mutations.
- **Worktree removal (macOS):** binds project, generation, mode, socket, live
  identity or absence, and kwt change counts. Dirty checkouts require **Force
  Remove Worktree**; Ghosthub rechecks status right before killing the session,
  and restores the session for force confirmation if newer dirty files appear
  afterward.
- **Visibility and filtering:** kwt-owned sessions hide from standalone lists
  by default (configurable in **Settings → Sidebar**). Case-sensitive `*`/`?`
  patterns in `[tmux].hidden_session_patterns` (`~/.config/ghosthub/config.toml`)
  filter standalone sessions post-discovery without affecting worktrees or
  duplicate checks.
- **Passive activity sampling:** samples warm connected sessions every 5s while
  active, 20s while quiet, 30s when unavailable (10s timeout), capturing at
  most 160 scrollback lines (excluding visible screen) on the host and
  returning only a checksum plus byte/line counts. Every read re-verifies
  server PID, session ID, creation time, and pane ID/dimensions inside the same
  tmux dispatch (psmux 3.3.4+ verifies format/if-shell support first). Pane
  switches, resizes, or gaps >30s set a quiet baseline; genuine scrollback
  progress lights the indicator for 30s. Warm state survives view close, clears
  on quit/exit/replacement/host removal, and is never persisted.

### Agent attention

A trailing badge on a tmux session row shows coding-agent state (replacing the
recent-output dot):

| Agent state | Badge | Shown |
| --- | --- | --- |
| Waiting for permission approval | Amber speech bubble (**Approval**) | Until the agent moves on |
| Asking the user a question | Purple speech bubble (**Input**) | Until the agent moves on |
| Finished its turn | Small green dot (**Done**) | Until the user views the session |
| Working | Green dot (**Working**) | While the agent works |

Bubbles pulse slowly and the working dot pulses unless Reduce Motion is on.
Native window tabs show the same icon for Approval, Input, and Done (never
Working).

- **Hooks setup:** **Settings → Hosts → Agent Hooks** runs managed kwt
  (`kwt agent-hook status --json` and `kwt agent-hook install --json`),
  auto-loading for saved macOS/Linux SSH hosts on selection (waiting for **Test
  Connection** if unsaved connection edits exist, matching **Add Project**).
  Codex requires trusting new hooks once via `/hooks`.
- **Automatic hooks:** **Settings → Agents → Install and update agent hooks
  automatically** (`SettingsStore.autoInstallAgentHooks`, off until chosen,
  pre-checked on the welcome sheet) makes `AgentHookMaintainer` run the same
  status and install commands on this Mac and every macOS/Linux host, saved
  or discovered from exe.dev accounts (a saved host wins a shared destination
  or key), at launch, when the setting turns on, and for each host added or
  discovered later. It installs only where an available agent's hooks are
  missing or not current, once per connection per launch (a failed host is
  tried again on the next trigger); Windows hosts stay manual. Status is kept
  per connection, so a host whose SSH destination changes is read again. The **Agent Hooks** card in Settings → Agents lists every
  host's state and offers **Install on All Hosts**.
- **Welcome sheet:** `OnboardingPresenter` shows it in one workspace window. A
  first launch (no `ghosthub.db` yet) always shows it; otherwise it shows once
  only when a read-only status check finds a host whose agents lack current
  hooks. The check first waits up to 60 seconds for each enabled exe.dev
  account's VM list. A failed check or listing defers the decision to the next
  launch. **Add a Host…** finishes the sheet and opens Settings → Hosts with a
  new host draft. **Show Welcome** in the Command Palette reopens it.
- **Pane option and refresh:** hooks write `@kwt_agent` as
  `<state> <unix-seconds> <agent>` (`working`, `approval`, `input`, `done`),
  cleared on session start/end (no-op outside tmux and for subagents). POSIX
  discovery reads `list-panes -a -f '#{@kwt_agent}'` alongside `list-sessions`
  on activation and every 30s (not read on Windows).
- **Priority and acknowledgement:** Approval > Input > unseen Done > Working.
  Done clears only after querying tmux for the active client's server PID,
  session ID, and creation time when the session is active in the key window
  (discarding stale answers if selection or focus changed mid-query). Up to 512
  acknowledged sessions persist in `UserDefaults`.

### Saved session restore

Managed kwt saves tmux layouts and Claude Code, Codex, and `agy` conversations
as they change; once a server stops (for example after a reboot), saved entries
become restorable:

| Ghosthub action | kwt command |
| --- | --- |
| List restorable sessions | `kwt session snapshot --json` |
| Restore Saved tmux Sessions, or open a saved row | `kwt session restore --json <id>...` |
| Dismiss Saved Session (confirmed) | `kwt session dismiss <id>` |
| After a confirmed Kill Session | `kwt session forget --socket-name <name> --session-id <id> --server-pid <pid> --created <time>` |

- Ghosthub runs `snapshot` in the background on startup, host changes, and
  refreshes for local Mac and POSIX SSH hosts, keeping default and `kwt` socket
  entries on `HostSummary.savedTmuxSessions`.
- Saved entries appear as dimmed **saved** rows targeting the `.tmuxSession`
  they will recreate (preserving manual sort order; omitting worktree/directory
  entries restored by `kwt open` and already-live names; keeping only the
  newest entry per name; skipped by sibling navigation).
- Clicking a row marks it **restoring…**, blocks duplicate restores from any
  window while kwt rebuilds it, provisions remote kwt if needed, attaches if
  the user did not navigate away, and alerts only for failed entries or pane
  notes.
- A window whose plain tmux session ends, whether its client exits 255 and the
  reconnect probe finds the session gone or discovery confirms it, starts a
  fresh `snapshot` listing for that host and waits for it. When that listing
  has a saved copy of that session (same name, default socket, newest first,
  name not taken), the window shows **Restoring…** and restores it through the
  same shared restore path. A window that finds another window already
  restoring it waits for that restore and shares its outcome. An ended window
  attaches when discovery lists its session again, under the new server PID,
  session ID, and creation time the restored session has, whether discovery or
  the restore finishes first. A window that notices its client closed only
  after the session came back attaches too, because discovery no longer lists
  its own session. A restored session that ends before the window attaches
  shows that with **Retry Restore**; the window does not restore it again on
  its own. A failed restore shows kwt's reason with **Retry Restore** in every
  waiting window and is not retried on its own. While the listing runs, the
  window shows **Looking for a saved copy…**; a listing that fails shows its
  error with **Retry Restore**, and no window on that host restores from older
  cached copies until a listing succeeds. **Reopen**, which creates an empty
  session, appears only after a listing finds no saved copy.
- A confirmed Kill Session keeps every window from restoring that session from
  before the kill until kwt has forgotten its saved copy. Ghosthub runs
  `forget` in the background using the socket name (since killing the last
  session stops the server) so intentionally killed sessions are not offered
  for restore. The block covers the killed session's own tmux server, so a
  same-named session on another server can still be restored. Each kill holds
  its own block, so a duplicate kill that fails does not lift another's. If
  `forget` fails, the block stays until Ghosthub quits and the saved copy stays
  listed for the person to dismiss.
- Pull-request imports remain the one alternate-socket case: `kwt pr attach`
  validates provenance and creates or repairs the inert protected session on
  each attach and SSH reconnect via the managed kwt path (never falling back to
  the default server).

## Local PTY

App-owned local PTYs exist only for utility surfaces such as the log viewer;
they die with the app process.

## Shell startup rules

- Let libghostty launch the user's normal macOS login shell unless a strong
  product reason requires otherwise.
- Keep `TERM_PROGRAM=ghosthub` and strip launcher-terminal `EDITOR`/`VISUAL`.
- Keep Ghosthub config at `~/.config/ghosthub/ghostty.conf` and mutable app
  state under `~/.ghosthub/`. Never read Ghostty.app global config.
- Keep a small client-local minimum text contrast floor unless `ghostty.conf`
  sets one explicitly.
- Ship libghostty's `share` tree (`ghostty/` and `terminfo/` in
  `Contents/Resources`) and point `GHOSTTY_RESOURCES_DIR` at it so built-in
  themes, shell integration, and `xterm-ghostty` terminfo always resolve.
- Keep generated base config independent of tmux themes (apply tmux themes via
  tmux commands, never as a client-local libghostty overlay).
- Scrub `TMUX`/`TMUX_PANE` and documented Herdr/Zellij control variables before
  nested discovery or attach.
- Never install Ghosthub-owned layout, zoom, tab, or Herdr workspace bindings
  beyond explicit **Split Right** / **Split Down** requests.
- Never disable libghostty shell integration to work around keybinding bugs.

## Configuration reloading

Ghosthub watches `~/.config/ghosthub/ghostty.conf`, the selected local
project's `.ghosthub/terminal.conf` (skipped for protected PR checkouts, which
fall back to the user's project checkout), the appearance overlay, and
recursive `config-file` includes (including missing optional files) with
debouncing. Reloads are transactional: invalid candidates never replace the
last valid config. Automatic successes are silent; errors stay visible;
explicit reloads (**Ghosthub → Reload Configuration**, Command Palette,
<kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>,</kbd>) always report their outcome.

## Relay teardown containment

The Rust byte relay spawns each client as a session leader with the PTY as its
controlling terminal. On teardown it reaps the child and, on Unix, sweeps the
child's process group with `SIGKILL` after a non-reaping `waitid` leaves the
exited child a zombie so its PGID cannot recycle first. A disowned descendant
that moved into another process group while holding the slave open without
reading is the one edge case not reached by the group sweep (full session/tree
enumeration is future work, bounded by the trusted-network posture). On Windows
a Job Object contains the whole process tree.

## Verification

For changes to terminal startup, environment, config layering, libghostty
bootstrap, key handling, or remote terminal code, run:

```bash
make test-libghostty-bootstrap
make python-test
make swift-test
make build
```
