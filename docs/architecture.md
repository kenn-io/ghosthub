# Architecture

This document is the architecture and product source of truth for Ghosthub.
Historical design plans stay outside the generated docs site. Security
boundaries and trusted-peer assumptions live in [Threat Model](threat-model.md).

Ghosthub is a native hub for local and remote terminal multiplexers (an
alternative to juggling SSH and multiplexer tabs in a general-purpose terminal
like iTerm2, Ghostty, or Kitty).

- **macOS:** SwiftUI/AppKit app embedding libghostty.
- **Windows and Linux (in development):** Rust + GPUI app embedding
  `libghostty-vt`, sharing the same product and session model. Crate layout,
  dependency rules, platform boundaries, and delivery order live in
  [Windows and Linux Rust Port](rust-port.md).
- **Loopback web UI (Rust):** locked v1 contract lives in [Web UI](web-ui.md).
  It relays an attach client to the multiplexer (never a bare shell), so the
  multiplexer keeps ownership of scrollback, mode state, history, and session
  lifetime. The relay is a parserless byte pipe with no server-side replay or
  resume; every reconnect is a fresh attach.

## Mental model

- **Host:** a machine running tmux and optionally Herdr, Rex, or Zellij. The
  local Mac is the default host; remote macOS and Linux hosts connect over SSH
  (often over a tailnet), and native Windows/psmux hosts are experimental.
- **Project:** a Git repository reported by kwt on a host.
- **Worktree:** a kwt workspace (primary checkout or linked Git worktree) with
  an exact tmux session name.
- **Directory workspace:** a kwt-registered plain directory with an exact tmux
  session name and no Git children.
- **Session:** an ordinary tmux session, running or stopped Herdr TUI session,
  backend terminal (live Herdr Core terminal/tab or Rex window), or active
  Zellij session. Herdr Core support is macOS-only today. The Rust Linux client
  also opens remote Rex windows over SSH, drawing Rex's tiled layout with one
  libghostty terminal (`kwt rex attach`) per pane and one `kwt rex control`
  channel for layout updates and pane actions.

### Sidebar and discovery

Hosts are the only top-level grouping in the sidebar. Under each host:

- **One unified session list** shows standalone tmux sessions, running or
  stopped Herdr TUI sessions, live Herdr Core terminals and desktop tabs, Rex
  windows, and active Zellij sessions, including sessions started outside
  Ghosthub or kwt.
- **Backend labels** (chip, colored text, or dot) distinguish backends. The
  sidebar options menu and **Settings → Sidebar** share label style, sort order,
  row height, and worktree visibility settings.
- **Ordering:** saved manual order, or sorted by name, backend, or agent
  attention. Stopped Herdr sessions always appear last.
- **Projects group:** sits quietly below the session list, showing repository
  trees followed by flat registered-directory rows. Inventories stay
  independent; kwt worktrees and directory workspaces remain tmux-backed.
- **Filtering and duplicates:** case-sensitive wildcard patterns hide matching
  standalone tmux sessions from navigation while discovery keeps full inventory
  so worktree rows still show live status. Kwt-owned sessions are hidden from
  the standalone session list by default, with a Sidebar toggle to expose them.
- **Window counts and agent badges:** a connected tmux view overlays its
  positive, identity-checked window count without changing discovery authority
  (sampled every 5 seconds while working, every 20 seconds while quiet).
  Detached ordinary worktree sessions use the count from current discovery;
  other live views fall back to their running or agent icon. Cached sessions
  never show as live while a host is unreachable. Tmux sessions running coding
  agents show approval, input, unviewed-done, or working badges from kwt
  agent-hook state; see [Agent attention](terminal-sessions.md#agent-attention).
- **Saved session restore:** each host lists tmux sessions kwt saved before a
  reboot or server stop as dimmed rows that rebuild windows/panes and resume
  Claude Code, Codex, and `agy` conversations; see
  [Saved session restore](terminal-sessions.md#saved-session-restore).

The macOS app does not display CPU or memory usage and does not poll local
process trees. Working indicators and window counts come from the session
activity controller; idle notifications and last-viewed timestamps stay
separate.

### Client attachment, Find, and passive activity

- **Backend ownership:** tmux, Herdr, and Zellij attach through their normal
  whole-session clients and keep control of their internal layout. Each scene
  has at most one active interactive view. Previously opened tmux clients may
  stay retained and noninteractive, and render previews when enabled. On POSIX
  hosts, **Always Live** mode may also connect newly discovered tmux sessions
  without activating them. Windows/psmux stays unattached until opened because
  psmux lacks a non-sizing preview client mode. Previews always reuse the
  retained client rather than opening a second one or reconstructing tmux state.
- **Terminal Find:** backend-owned. Standalone terminals use libghostty search.
  POSIX tmux 3.4+ uses an exact-client, exact-pane guarded copy-mode command
  (with match totals on tmux 3.5+ when complete). Herdr, Zellij, psmux, and
  older tmux versions report Find unavailable instead of searching only the
  local viewport. Swift owns the Find bar and serializes requests without
  reading pane history, match text, or highlights; queries stay in memory only
  and never enter logs or error messages.
- **Passive activity controller:** once an attachment connects, Ghosthub keeps
  that exact session warm for the rest of the app launch. One app-scoped
  in-memory controller serves all windows, sampling only warm sessions (never
  every discovered session) bound to tmux server PID, session ID, and creation
  time. The host checksums a bounded tail of the active pane's scrollback
  (excluding the visible screen, preserving trailing blanks) and returns only
  the checksum, byte count, scrollback line count, pane identity, and session
  identity. The first sample per pane, and the first after a resize, sets a
  quiet baseline; later scrollback changes at the same dimensions publish a
  short-lived activity indicator to both worktree and standalone rows. Warm
  state is never persisted, and a missing or replaced session stops sampling.

## Window model

Each workspace is an independent SwiftUI scene with its own model, selection,
and terminal coordinators. Workspaces open as separate windows (**Cmd-N**) or
native AppKit `NSWindow` tabs (**Cmd-T**). AppKit owns the tab bar, tab
dragging, and window merging; Ghosthub never draws a custom tab strip or maps
tmux windows onto native tabs.

### Scene-local vs. app-wide state

- **Scene-local:** sidebar disclosure state (expanded/collapsed hosts, Projects
  group, and projects). New scenes start with hosts expanded and projects
  collapsed. Disclosure state stays in view state across sidebar toggles and
  focus changes, and is neither app-wide nor persisted in scene descriptors.
- **App-wide:** saved row order, host display order, Settings preferences, and
  manual worktree flags.
- **Manual worktree flags:** toggled from the sidebar ellipsis menu; terminal
  activity never changes them. Keyed by stable host key, project key, and
  canonical kwt worktree generation so a fresh checkout at the same path does
  not inherit a flag. Rows without verified identity cannot be flagged; offline
  hosts and missing inventory never clear saved flags. One shared in-memory
  store exposes an observable value per durable key (cached with inventory rows)
  so only matching rows observe updates, without invalidating inventory
  sections, terminal roots, or unrelated previews. See
  [Sidebar performance](sidebar-performance.md).
- **Host display order:** shared between the sidebar and **Settings → Hosts**,
  saving moves immediately and separately from connection settings. Keyed by
  configuration keys plus a fixed local-host identity so renames and reconnects
  preserve order; newly added hosts append at the end. Settings includes a
  movable, non-removable Local Mac row while preserving stored positions of
  discovered hosts (such as exe.dev VMs) outside that list.

### Scene persistence and relaunch restoration

The workspace `WindowGroup` is data-backed. Each scene maintains a small
logical descriptor holding stable host and project keys, durable kwt worktree
generation or registered directory path, and at most one exact tmux (session,
socket, attachment mode), Herdr, Zellij, or backend-terminal identity. The
window UUID is used only for native scene adoption; runtime UUIDs and worktree
paths are never persisted as identity. A worktree without a canonical
generation falls back to project-only navigation; directory workspaces resolve
by authoritative kwt registry path on that host.

SwiftUI and macOS handle normal scene count, native tab groups, and window
geometry. Before a Sparkle relaunch, Ghosthub also writes an atomic one-shot
manifest under `~/.ghosthub/` recording ordered logical descriptors and live
window frames:

1. On relaunch, Ghosthub collects initial and late native scene values until
   AppKit finishes native window restoration and all restored workspace windows
   register their SwiftUI scenes.
2. Once scene bindings settle, unresolved scenes receive provisional unclaimed
   descriptors in saved order, and Ghosthub opens replay scenes (using fresh
   scene tokens so SwiftUI cannot coalesce them with late native scenes) for
   any descriptors still missing.
3. Late native descriptors remain authoritative and reclaim their slot,
   reassigning any displaced replay scene to the displaced descriptor.
4. The manifest stays on disk until every saved descriptor has started
   restoring in one live scene. Ghosthub applies saved ordinary frames when
   each `NSWindow` appears (constraining frames from unplugged displays onto an
   available display) without activating or reordering windows; macOS still
   owns Spaces, fullscreen windows, and tab groups.
5. After assignment, the scene model owns its descriptor and rewrites stale
   late native payloads sharing the window UUID before they can overwrite
   persisted state.

Once inventory arrives, Ghosthub resolves each descriptor to live models and
reattaches only after confirming the exact session:

- **tmux:** retained per scene by exact host, socket, and session identity;
  switching rows hides the previous surface without stopping its client or
  reconnect supervisor. Retained worktree views keep the generation observed at
  attach time so a later generation change counts as a replacement even if a
  runtime UUID is reused.
- **Herdr / backend terminals / Zellij:** restoration requires a fresh probe
  confirming the exact running Herdr name, exact backend-terminal kind and
  address (Herdr Core and Herdr TUI have distinct identities), or exact active
  Zellij name. Cached pre-refresh rows never authorize attachment. See
  [Herdr attachment](terminal-sessions.md#native-herdr-attachment).
- **Empty or offline scenes:** missing or offline targets stay pending across
  later refreshes; explicit user navigation cancels pending restoration. A
  scene saved without an active session restores sidebar selection without
  creating a worktree or directory session.

The host-scoped Console Panel is excluded from scene restoration and keeps its
global visibility toggle. Opening the same session in multiple windows shares
existing presentation behavior (tracked by kata `s75s`).

Closing a tab or window closes every retained view owned by that scene. Closing
the final window leaves Ghosthub running; **Cmd-Q** quits (confirmed by default
under **Settings → Terminal**). Neither closing views nor quitting ever kills a
tmux, Herdr, or Zellij session.

## Process boundaries

### Ghosthub.app (macOS)

The Swift app owns native UI and terminal hosting:

- SwiftUI/AppKit window shell and native tabs
- libghostty surface lifecycle, input, resize, and rendering
- Workspace/session selection and view state
- Local GRDB SQLite persistence for app-owned state
- SSH host settings and local/SSH client presentation

Pure domain models belong in `Sources/Workspace/`; external workspace state
comes through kwt's machine-readable CLI.

Hidden terminal surfaces release their GPU swap chain, buffers, and textures,
while Core Animation retains the last presented IOSurface until replaced so
macOS Mission Control previews on other Spaces remain populated.

### Windows and Linux Rust applications

The Rust apps run natively with GPUI and `libghostty-vt` without replacing or
embedding into the macOS Swift app. Parity is verified through the shared
`contracts/` fixture corpus rather than a shared runtime or database.

- **Platform scope:** Windows attaches to tmux (and discovers optional Herdr
  and Zellij) inside WSL2 via system-owned `wsl.exe` and ConPTY, plus
  configured POSIX SSH hosts over one kwt-owned SSH lease. Native Linux uses a
  local PTY for local tmux, Herdr, and Zellij, embeds the pinned kwt helper for
  local projects/worktrees, and connects to POSIX SSH hosts (including remote
  Rex windows). Missing or failing optional backends stay scoped to their own
  inventory.
- **Unified sidebar:** combines tmux, Herdr TUI, and Zellij into one per-host
  list sharing rendering, manual drag order, and keyboard navigation while
  preserving each backend's exact attachment and lifecycle rules. Sidebar
  preferences and row order live in shared config; host disclosure stays
  per-window. See [Windows and Linux Rust Port](rust-port.md).
- **Structural crate boundaries:** UI depends only on workspace, model, and
  surface crates; persistence cannot reach session launch or kill authority.
  The terminal backend stays behind a capability-shaped seam, and a leaf
  surface crate carries paint buffers and scroll-aware damage between the
  terminal worker and GPUI without granting UI any PTY capability.
- **UI responsiveness invariant:** window activation, input, paint, and
  snapshot reads never run host commands, filesystem probes, database I/O,
  resource sampling, or project reconciliation. Cancellable background lanes
  build owned host-scoped snapshots before a short generation-checked
  publication (never holding guards across I/O or awaits). Each host publishes
  independently, and command capture is bounded and descendant-contained so
  pipes cannot outlive a canceled refresh.
- **Windows WSL host lifecycle:** the app checks for system-owned `wsl.exe`
  without executing it at startup, renders one synthetic WSL host on frame 1,
  and begins discovery on frame 2 (45s cold-start budget, 30s afterward). Ready
  WSL inventory refreshes every 10 seconds while active (activation only flips
  an in-memory polling flag; refreshes never emit a transient Connecting state
  or interrupt in-flight operations, and failed/disconnected hosts do not loop).
  Optional Herdr discovery runs through WSL's login profile with inherited
  Herdr variables scrubbed. Bare tmux creation uses one non-cloneable
  `CreateOnce` with atomic `new-session -A` and a nonce-scoped private WSL
  receipt for live identity; Herdr Stop/Delete and tmux Kill revalidate fresh
  runtime identity under a serialized workspace operation fence.
- **Windows kwt inventory:** runs on its own 60-second active cadence (separate
  from the 10-second session cadence), reporting exact socket and `direct` vs.
  `protected` attachment mode (never inferred from socket naming). Explicit
  WSL `TMUX_TMPDIR` is forwarded to kwt commands.
- **Process ownership:** Ghosthub runs as one UI process with no Ghosthub-owned
  daemon. On Windows, closing or force-killing the app reaps only its `wsl.exe`
  relay and Linux tmux client, leaving the tmux server and sessions alive.
  psmux 3.3.7 capability failures remain rejection evidence rather than a
  product path. See [Terminal Sessions](terminal-sessions.md).
- **Retained views and persistence:** each workspace retains opened tmux
  clients synchronously across navigation; explicit close detaches only the
  selected view and app exit detaches all retained clients. Persistence uses a
  single async SQLite WAL writer that coalesces UI state and never holds a
  transaction across an await. Cold-start reconciliation consumes only
  published inventory generations and never probes or kills server state.

### Swift macOS kwt sockets and worktree removal

In the Swift macOS app, direct operations on the `kwt` socket clear
`TMUX_TMPDIR` to match the pinned kwt helper, while default and other named
sockets keep the account's `TMUX_TMPDIR`. Cached rows never cross-match across
socket roots. If kwt discovery fails, cached kwt rows remain alongside fresh
default-server rows and a host warning; that partial snapshot cannot confirm
kwt absence or start Always Live previews.

Removing a generation-backed worktree on macOS follows a strict guarded sequence:

1. Capture exact socket and live session identity (if running) plus kwt's
   no-fetch Git status for that exact path. Uncommitted changes (or an
   oversized change set that hits the inspection bound) escalate to an explicit
   force confirmation.
2. Re-read Git status right before killing the session so newly dirtied files
   require a fresh force confirmation.
3. Kill only that freshly verified tmux identity, then invoke pinned kwt's
   absence-guarded removal. kwt revalidates project, generation, and socket
   under its lifecycle lock and refuses deletion if the session reappeared. If
   ordinary removal still detects newer dirty files after the kill, Ghosthub
   restores the session and asks for force confirmation.

### Application updates

Packaged macOS releases embed Sparkle 2 and bind to one update channel at build
time:

- **Stable:** checks the HTTPS appcast attached to the latest GitHub release in
  `kenn-io/ghosthub`.
- **Nightly:** checks the separate nightly appcast in
  `kenn-io/ghosthub-nightly`, uses a distinct Sparkle Ed25519 public key, and
  displays as **Ghosthub Nightly** while sharing the `com.ghosthub` bundle ID
  and `~/.ghosthub/` state (installing one channel replaces the other; Sparkle
  never crosses channels). Dev builds without a packaged feed/key disable the
  update menu item.

A manual **Check for Updates…** probes the channel feed (verifying the Sparkle
signature and platform requirements) and cancels any queued older update before
starting a fresh Sparkle check if a newer compatible build exists; failed
probes keep the queued offer. Nightly dialogs format the UTC date and build
number without altering bundle version metadata.

When the user clicks **Install and Relaunch**, Ghosthub writes the relaunch
manifest and authorizes one updater-driven AppKit termination separate from the
quit-confirmation prompt (cleared on abort/error, kept armed across Sparkle's
post-relaunch cycle callback). Normal **Cmd-Q**, logout, restart, and shutdown
still use the user's quit-confirmation setting.

Release workflows generate appcasts only after the DMG is Developer ID signed,
notarized, stapled, and checksummed. Because stock Sparkle accepts either a
valid Ed25519 chain or a matching Apple signing identity (Ghosthub disables
signed-feed expiration and does not use key rotation), stable-feed routing and
separate publication authority are what keep unattended nightly credentials
from reaching stable users, with distinct Sparkle keys as defense in depth.
Private keys live only in 1Password and their GitHub environments
(approval-gated `release-signing` vs. `main`-restricted `nightly-signing`,
which mints a short-lived `kenn-dist-update-bot` token scoped only to
`kenn-io/ghosthub-nightly`). For first-time manual nightly installs (which
bypass Sparkle), operators must verify Gatekeeper acceptance and Kenn
Software's Apple Team ID on both the DMG and app.

### Anonymous usage telemetry

Packaged releases send at most one allowlisted `application active` event per
UTC day to PostHog using a small Ghosthub-owned Swift HTTP client (no
third-party analytics SDK, automatic lifecycle capture, or swizzling):

- **Identity:** a random installation UUID stored in `~/.ghosthub/telemetry.json`.
  UUID creation and UTC-day claims share one interprocess-locked transaction
  persisted before networking so parallel instances report once and lost
  responses are not retried. The activity day is monotonic.
- **Payload:** app name, native-app source, About version string (bare `X.Y.Z`
  only for stable releases; dev/nightly builds report their dev version), and
  build number. Person profiles and GeoIP enrichment are disabled. Repository,
  worktree, host, session, path, command, and terminal data are never sent.
- **Controls:** on by default in packaged releases; disable in Settings or via
  `GHOSTHUB_TELEMETRY_ENABLED=0` or `TELEMETRY_ENABLED=0`. Debug builds and
  tests omit the production client. Active apps schedule the next check for the
  next UTC day boundary and cancel it on resign active, rereading the privacy
  preference each time.

### External state

#### SSH routing, leases, and multiplexing

System OpenSSH owns SSH transport and host-key storage. Ghosthub's
revision-pinned kwt helper owns effective route resolution across kwt's CLI
boundary (using a dedicated `KWT_HOME` at `~/.ghosthub/ssh/kwt` so Ghosthub's
SSH daemon never collides with the user's normal kwt daemon, while local
project/worktree commands keep using the account's kwt home). kwt nonce-frames
`ssh -G` inside the login shell so banners cannot inject options and returns an
immutable route snapshot with a route digest and versioned allowlisted hop
projections.

- **Compression:** enabled by default on configured hosts and toggleable in
  Settings (off for dynamic exe.dev accounts and VMs because they have no
  Settings row). Applied to the target destination while jump hosts keep their
  own SSH config; changing it updates route identity and releases existing
  views without changing project-registry mutation fences.
- **Agent forwarding:** per-host override (`SSH configuration`, `On`, `Off`)
  applied to the target destination and carried across route resolution,
  leases, and short commands; jump hosts keep their own config.
- **Multiplexed leases:** long-lived remote tmux, Herdr, and Zellij views
  acquire kwt leases (kwt owns ControlMaster, ProxyJump chains, askpass,
  host-key parsing, generation, idle policy, and cleanup). One attachment keeps
  one connection from initial probe through exit. Reconnect stores logical
  intent only, re-resolving and reacquiring a fresh lease. Helper errors,
  malformed snapshots, unsupported policies, masterless results, or route
  changes fail closed.
- **Connection pooling and release:** concurrent callers on the same route
  identity share one lease. Returning the final reference hands the master back
  to kwt, which keeps ordinary masters warm until idle timeout and immediately
  disconnects forwarded-agent masters. A shared lease is marked unusable (no
  new joiners, released when the last owner drops it) on terminal helper
  failure, OpenSSH exit 255, or fallback to the lease's fail-closed proxy.
  Failed lease cleanup quarantines the route with bounded cleanup retries on
  later acquisitions.
- **Per-master session budgeting (`MaxSessions`, default 10):** Ghosthub tracks
  active sessions per control socket:
  - Terminals claim up to their share (7 of 10 by default), leaving up to 3
    slots for commands. Reconnect probes borrow a command slot without claiming
    a terminal slot.
  - Setup probes run as ordinary commands before a terminal claims its slot.
    Launches take priority over queued commands; if terminals already fill a
    master, launch fails retryably and reconnect moves to another master.
  - Short commands (including helper uploads) queue in FIFO order on dispatch
    threads (`BlockingTask`) rather than Swift's cooperative pool; canceling a
    caller dequeues it.
  - On server refusal, Ghosthub lowers that master's learned capacity to the
    currently open count (or backs off without lowering if another client holds
    the slots).
  - Overflow opens additional masters via `kwt ssh lease --connection <n>` (up
    to 16 per route). Commands turned away because terminals filled a master
    run once on a promptless replacement master with the same route identity.
  - Extra masters authenticate independently; prompts for different masters on
    one route serialize so a window shows at most one prompt at a time.
    `kwt ssh exec` worktree mutations are uncounted but participate in capacity
    learning and backoff.
- **Shared acquisition and prompts:** coalesced in two stages (resolution per
  normalized destination, then route-scoped lease). Each new ownership boundary
  re-resolves so SSH config edits surface as `ssh_configuration_changed`.
  Eligible windows subscribe to prompts in order; closing or canceling a
  presenter transfers unanswered prompts to the next subscriber without
  resetting kwt's deadline, and the last subscriber leaving cancels the
  operation.
- **Host keys, auth, and Tailscale browser checks:** OpenSSH remains
  authoritative and saves accepted keys to its configured `UserKnownHostsFile`.
  Interactive answers never touch arguments, environment, logs, or disk.
  Tailscale browser checks arrive as `ssh_browser_authentication` prompts with
  `--open-browser=false`, showing the URL and deadline across subscribed
  windows while kwt holds the SSH attempt open until approval, cancel, or
  expiry.
- **Short-lived commands and background refreshes:** Host Settings connection
  tests and host recovery acquire and release a kwt lease. Project/worktree
  inventory borrows one noninteractive lease per refresh (failing background
  prompts with `ssh_interaction_required`). Worktree mutations use
  `kwt ssh exec`. Remaining multi-command borrowers await the pool
  asynchronously and run only blocking OpenSSH calls off the cooperative pool.
- **Clipboard image paste (`Cmd-V`):** on local or remote POSIX tmux views with
  an image-only clipboard, Ghosthub converts to PNG, stages it in the session
  host's `~/.ghosthub/paste-images/` (reusing the remote view's frozen lease
  args, with size-scaled upload deadlines and attachment-generation checks),
  and pastes the path via libghostty. Text always wins over images when both
  are on the clipboard; `Ctrl-V` passes through to the terminal.
- **Demo exception and app quit:** `GHOSTHUB_DEMO_SCRATCH` bypasses kwt leases
  for isolated demo fixtures. On quit, Ghosthub closes scene surfaces and
  releases leases concurrently, then drains the shared pool under a 5-second
  AppKit bound without ever killing server-side sessions.
- **Remote probes:** emit a leading delimiter and parse exact markers from
  stdout only, so login banners or stderr cannot spoof reachability.

#### Rust SSH boundary

The Rust port uses pinned kwt rather than reimplementing SSH config or prompt
policy:

- On Windows, Host resolves `wsl.exe` by absolute Windows system path, runs the
  pinned Linux helper and `/usr/bin/ssh` inside the pinned WSL distro (because
  Windows OpenSSH lacks persistent ControlMaster sockets), and passes only an
  absolute `wsl.exe` argv to the terminal layer. Native Windows OpenSSH,
  masterless leases, and direct fallback are rejected.
- **Settings → Hosts** saves endpoints in `config.toml` without auto-connecting.
  Explicit **Connect** runs route resolution, lease acquisition, generation-fenced
  prompts, and inventory on a cancellable background lane per host.
- Supports tmux, Herdr, and Zellij discovery, attach, create/restart, and
  confirmed kill/stop/delete over the reviewed lease, verifying terminal types
  against remote terminfo (`xterm-256color` preferred, `xterm` fallback).
  Superseding navigation cancels queued/running probes; Zellij kills advance a
  host/route/name revision.
- Remote projects, worktrees, and directory workspaces run on a separate
  per-host kwt lane (provisioning the pinned `darwin`/`linux` `x86_64`/`arm64`
  helper), supporting both the default and `kwt` tmux servers (with `kwt`
  ignoring `TMUX_TMPDIR`). Removing a project revalidates repository, path, and
  fingerprint without touching files or sessions, preserving retained clients
  as session rows.
- Active ordinary SSH tmux clients recover automatically on exit 255 with
  1/2/4/8/16/30s backoff (15s deadline per attempt). Auth/route-review failures
  pause retries until **Retry**; navigation clears the saved target and
  **Cancel** pauses retries.

#### Bundled and managed kwt helpers

Ghosthub bundles revision-pinned kwt CLI binaries for local use (signed as app
code, invoked by bundle path) and for `darwin/{amd64,arm64}`,
`linux/{amd64,arm64}`, and `windows/{amd64,arm64}` remote hosts (sealed app
resources).

- **Remote macOS/Linux provisioning:** checked before kwt inventory. If missing
  or stale, Ghosthub selects the matching `uname` binary, uploads it, verifies
  SHA-256 and `kwt version` output on the host, and atomically installs it at
  `~/.ghosthub/helpers/kwt/<revision>/kwt` (keeping older version directories
  and `kwt.previous`, and cleaning up failed staged files). Concurrent scenes
  share one provisioning run per endpoint and cancel if the last caller leaves.
  Neither local nor remote code ever resolves an unrelated kwt from `PATH`.
- **Rust WSL helper:** path caches are never execution authority; the host
  revalidates digest and revision before every helper call and repairs
  atomically if missing or altered.
- **Windows remote provisioning:** explicit **Install Bundled kwt** probes
  architecture, uploads over OpenSSH, verifies SHA-256 and version, and
  atomically installs to `%USERPROFILE%\.ghosthub\helpers\kwt\<revision>\kwt.exe`
  (rolling back on failure). Automatic install stays off until the binaries are
  Authenticode-signed.
- **Retries and shell wrapper:** retryable kwt read errors use
  cancellation-aware 1s, 4s, and 15s backoff; non-retryable errors do not
  retry. On macOS/Linux, the login shell initializes the environment while
  Ghosthub's inventory scripts execute under POSIX `/bin/sh` (so non-POSIX
  shells like fish never parse them) and append any missing Homebrew, MacPorts,
  Linuxbrew, and Nix bin directories after the account's own `PATH`. Windows
  commands run via encoded noninteractive PowerShell.
- **Dual-server tmux discovery:** queries both the default server and the `kwt`
  server, keeping socket part of session identity everywhere. Passive remote
  kwt errors stay quiet, keep cached projects visible, and never degrade
  standalone session inventory.

#### Worktree changed-file panel and project recovery

- **Changed-file panel:** ephemeral, read-only status list calling pinned kwt
  with repository, absolute path, and worktree generation guards (Ghosthub
  never runs Git, computes diffs, or persists results). Only mounted panels in
  a visible sidebar of the active key window poll (5s after each completed
  read), coalesced by an app-wide broker capped at 4 concurrent reads (2 per
  host). Registration-change errors halt polling until the user clicks
  **Refresh** to reload inventory. Displays pages of 200 files, caps collapsed
  caches at 8 per scene, and isolates row updates via native observation.
- **Add / Remove Project:** **Add Project** passes one absolute path to
  `kwt projects add --json`. **Remove Project** calls
  `kwt projects remove <path> --expected-repository <identity> --expected-registration <fingerprint> --json`,
  failing closed on registration drift or live protected endpoints and never
  deleting files or sessions. Rust Windows maps native or WSL UNC folders into
  the selected distro and runs the same guarded POSIX commands. Native Windows
  hosts omit project registry mutations until native Windows paths are
  supported.
- **Moved project recovery:** missing folders carry `path_issue`, retaining
  cached worktrees while blocking mutations. Each unavailable registration gets
  one automatic `kwt projects recover` attempt (relocating only on an
  unambiguous match). **Locate Folder…** sends an explicit destination with
  repository and registration guards through kwt. Ghosthub never scans remote
  filesystems.

#### exe.dev host provider

An enabled exe.dev account is a host-inventory provider, not a terminal
backend. Ghosthub runs `ls --json` against the account's OpenSSH destination
and registers each running VM as a regular Linux SSH host using its exact
`ssh_dest` (never synthesizing hostnames or usernames). Optional tag filters
are part of discovery identity, enabled accounts must use distinct OpenSSH
destinations, display names are UI-only, and manual SSH host configs win over
duplicate dynamic VMs. Failed refreshes keep the last usable VM list;
successful refreshes drop stopped VMs. System OpenSSH, tmux, and kwt behave
identically to any other SSH host.

#### Pull-request import

kwt owns forge auth, candidate discovery, and worktree import; Ghosthub never
queries GitHub directly. Candidate discovery runs only when the user opens the
PR import sheet (cancellable, 5-minute network budget). Imports run
noninteractively using the host's Git credential helpers while suppressing
repository-controlled execution and without starting tmux or project layouts.
Opening an imported PR worktree invokes kwt's protected attach command, which
atomically validates project identity, registration fingerprint, generation,
session name, and isolated socket under kwt's lifecycle lock, starts an inert
shell-only session on the workspace-specific server, and attaches with
environment updates disabled.

### Experimental native Windows hosts

Configured Windows hosts use OpenSSH, PowerShell 5.1+, and psmux's `tmux.exe`
alias (Windows 11 build 22523+ for ConPTY TTY allocation; psmux 3.3.4+ for
scrollback-only activity sampling). Although psmux 3.3.7 fails the Rust port's
`kill-session -t =name` proof, the experimental Swift path resolves fresh
identity and kills by session ID. New Windows sessions pass the SSH account's
`PATH` via psmux's session-environment argument while preserving psmux's native
status bar and leaving existing sessions untouched.

## Startup and onboarding

Ghosthub runs independent kwt, tmux, Herdr, and Zellij discovery before picking
an empty state; missing Herdr or Zellij installs are silent. There is no
first-launch modal or repository-intake interstitial. When every inventory is
empty, the sidebar explains that kwt owns projects and tmux owns sessions, with
**Add Project** in the host **+** menu on macOS and Linux hosts.

## Source layout

| Path | Responsibility |
| --- | --- |
| `Sources/App/` | App composition, window orchestration, command boundaries, and session planning |
| `Sources/UI/` | Reusable SwiftUI/AppKit components |
| `Sources/Settings/` | Native settings and preferences |
| `Sources/Terminal/` | libghostty runtime and terminal surface views |
| `Sources/TerminalSupport/` | libghostty config/bootstrap helpers and split-tree layout/container (no libghostty link) |
| `Sources/Transport/` | Local/SSH routing, quoting, and command execution |
| `Sources/Tmux/` | Tmux discovery and attachment command model |
| `Sources/Herdr/` | Herdr discovery and attachment command model |
| `Sources/BackendTerminal/` | Herdr Core and Rex discovery, attach commands, and Rex/Herdr desktop layout models |
| `Sources/Zellij/` | Zellij discovery and attachment command model |
| `Sources/Workspace/` | Pure workspace, host, project, worktree, and session models |
| `Sources/Persistence/` | GRDB repositories for app-local state |
| `rust/` | Rust workspace for native Windows and Linux apps |
| `contracts/` | Rust-owned cross-platform behavioral fixtures |
| `docs/rust-port.md` | Rust-port architecture, gates, and delivery plan |
| `docs/web-ui.md` | Locked v1 loopback web UI contract for the Rust apps |
| `tools/` | Python bootstrap and packaging automation |
| `Tests/` | Swift tests |
| `tools/tests/` | Python tests |

### Terminal configuration and transparency

Terminal config is Ghosthub-owned (`~/.config/ghosthub/ghostty.conf`) and
applied transactionally through libghostty. Ghosthub watches the base config,
project `terminal.conf`, appearance, and recursive `config-file` includes with
debouncing. Invalid edits never replace the last valid config; automatic
reloads succeed silently and surface errors, while manual reloads always show a
result.

`LibghosttyRuntime` derives `TerminalBackgroundAppearance` (opacity, blur) from
libghostty's parsed `background-opacity` and `background-blur`. When opacity is
below 1, workspace windows become translucent, blur applies via
`ghostty_set_window_background_blur`, chrome tints at that opacity, and layers
behind the terminal render clear. Accessibility Increase Contrast and native
fullscreen both stay opaque.

## Session attachment

Each scene has one active interactive view slot shared across tmux, Herdr,
backend terminals, and Zellij. Switching to Herdr or Zellij hides any active
retained tmux client; switching to another tmux session hides the previous one.

### Herdr and Zellij boundaries

- **Herdr TUI (local Mac and POSIX SSH hosts):** lists running and stopped
  sessions. Open and restore are attach-only; Create and Restart use Herdr's
  launch path. Ghosthub controls only whole-session create, stop, restart,
  delete, plus explicit **Split Right** / **Split Down** on Herdr 0.8.0+
  (scrubbing inherited Herdr variables, setting only the session socket, and
  letting Herdr pick its session-global focused pane). Stop ends all processes
  while keeping saved layout; Delete removes stopped non-default sessions.
  Because Herdr has no stable session-generation ID, same-name/same-socket
  replacement is a documented race.
- **Zellij (local Mac and POSIX SSH hosts):** lists active sessions only,
  filtering exited/resurrectable entries. Open and restore are attach-only
  (remote restore freezes and rechecks one SSH route snapshot and cancels if
  the route changes). **New Zellij Session** uses `--session`, rejecting active
  and resurrectable name collisions. Ghosthub never resurrects or deletes
  exited sessions (and never passes `--force-run-commands`); an upstream
  resurrection right after Ghosthub's active probe is an accepted race.
  **Kill Session** revalidates host and name under a cross-window kill fence
  that detaches active views, pauses reconnects, bumps a per-session kill
  revision, removes cached rows, and triggers fresh discovery (revalidating on
  failure). Because Zellij has no stable generation ID, same-name replacement
  in the final check-to-kill window is an accepted race.

### Retained tmux clients and GPU-native previews

Kwt workspaces and standalone sessions share the same tmux client path.
Switching rows hides the retained client; **Cmd-W** closes only the active
client; closing a window or quitting closes all retained clients in that scene.
None of those paths runs `kill-session`.

- **Hidden sizing protection:** on POSIX hosts, hidden retained tmux clients
  set client-local `ignore-size` (and clear it atomically on the exact client
  before activation), never touching the session's global `window-size` option.
  If setting `ignore-size` fails, or if the tmux version lacks safe exact-client
  targeting, Ghosthub detaches instead of keeping a hidden sizing client.
- **GPU-native preview pipeline:** libghostty renders each retained client into
  a Metal IOSurface; a Metal Core Image context scales changed frames into a
  width-bounded preview IOSurface (height clamped to 1024 px for extreme aspect
  ratios; 16:10 placeholder until first frame) presented via Core Animation
  with zero CPU readback.
- **Preview modes:**
  - **Off:** no parking host, no preview work.
  - **Efficient:** captures on expand and when navigating away from an active
    tmux view.
  - **Live:** keeps up to 4 inactive surfaces (app-wide) mounted behind
    workspace content, refreshing at <= 2 fps.
  - **Always Live:** attaches every newly discovered POSIX tmux session
    incrementally with `ignore-size` and PTY sized to the active window plus
    tmux status rows (so it never resizes the session), expands tiles by
    default, and bypasses the 4-surface cap. Leaving Always Live detaches only
    policy-owned clients. Selecting a tile clears `ignore-size` atomically
    without detaching (so `destroy-unattached` cannot kill the session); stale
    promotions restore `ignore-size` or detach on failure.
- **Parking and identity guards:** parked surfaces block focus, pointer, and
  accessibility events, ignore transient reparenting DPI/resize callbacks, and
  pause capture while Ghosthub is inactive (resuming after activation delay in
  the key scene). Preview frames publish only after token-bound tmux client
  identity is verified and rechecked per frame; reconnect quarantines old
  frames until the same server and session bind again, and same-name
  replacements clear the frame.

### Mouse, links, splits, themes, creation, and reconnect

- **Mouse and Command-click links:** Ghosthub best-effort enables the POSIX
  session's shared `mouse` option on attach so wheel scrolling reaches tmux
  copy mode (leaving tmux mouse bindings intact; psmux unchanged). For
  Command-modified pointer events, Ghosthub injects libghostty's Shift mouse
  override at the embedded input boundary (reusing the last tracked in-window
  pointer position on modifier changes) so link highlighting and Command-click
  bypass tmux cleanly.
- **Pane splits (`Cmd-D` / `Cmd-Shift-D` and File menu):** on POSIX tmux 3.4+,
  each surface publishes its TTY under a unique token so Ghosthub binds the
  client's stable server, client, and session identity. Each serialized split
  runs one tmux conditional validating that identity and active pane (following
  renames, rejecting replacement clients or switched sessions) against the
  attachment's frozen SSH endpoint, independent of user tmux prefixes. Herdr
  0.8.0+ uses its socket-scoped split command as noted above; Windows/psmux
  omits splits.
- **Tmux themes and contrast:** new bare sessions get the selected Tmux Theme
  (`Follow ghostty.conf` reads resolved light/dark colors from libghostty's
  surface callback). Generated config sets `minimum-contrast = 3` locally for
  legibility on light backgrounds unless `ghostty.conf` sets an explicit value.
  Existing sessions keep their colors by default; **Apply Theme to Current
  Session** and the opt-in **Apply theme to shared tmux sessions** setting
  update status/message styles and window defaults for all clients (never on
  Console Panel or Windows/psmux, and never blocking attachment).
- **Session creation and launch profiles:** **New Tmux Session** is the only
  path where Ghosthub creates a bare tmux session: local uses atomic
  `new-session -A`; remote runs an idempotent detached create-if-absent phase
  then attaches (permanently demoting later reconnects to attach-only). Launch
  profiles on POSIX SSH hosts replace the detached phase with one PTY-backed
  atomic `new-session -A` running the trusted command; on transport failure, an
  exact session probe advances to attach-only if present or retries if absent.
  Worktrees run kwt's start-only command before attaching; unbound discovered
  sessions are always attach-only. Optimistic new rows stay visible while
  launching and reconcile via bounded tmux discovery retries.
- **Reconnect supervision:** each retained remote tmux view owns at most one
  supervisor (using shared host inventory for default server or headless
  `has-session` for named sockets) with 1, 2, 4, 8, 16, and 30s intervals and a
  15s probe timeout. Transport failures retry automatically; auth/host-key
  failures pause for native SSH recovery; exact absence ends the view;
  reachable non-transport errors show unable-to-attach. Navigation never
  cancels recovery. Remote commands record their exit status in a per-launch
  temp file because libghostty's outer macOS login process does not reliably
  propagate nested exit codes.

## State ownership

- **kwt JSON CLI:** authoritative for project/worktree identity and exact tmux
  session names. Opening a worktree runs kwt's start-only command rather than
  inferring liveness from inventory. On Rust Windows, kwt revalidates
  repository identity, registration fingerprint, path, generation, and session
  name under its project lifecycle lock; worktree creation uses no-launch
  branch flow before refreshing inventory; SSH worktree removal fences clean
  inspection, session kill, and generation-guarded deletion on the kwt and
  session lanes (dirty remote Rust worktrees require committing or stashing).
- **Direct tmux / Herdr / Zellij discovery:** authoritative for standalone live
  sessions. Exit 127 from Herdr or missing Zellij is silent; malformed output
  or other errors emit a host-scoped warning without affecting other backends.
- **macOS process-wide inventory cache:** owns kwt and tmux inventory keyed by
  resolved command host. Scenes subscribe by stable host ID; one cadence
  refreshes every 30s while active and immediately on reactivation, keeping
  cached rows with host warnings on failure. Worktree mutations capture a
  mutation epoch so stale publications are rejected and reconciled at fence
  end; removal tombstones stay respected. Herdr, Zellij, and backend terminal
  inventories stay scene-owned and rerun in background tasks on each tick and
  reactivation (skipping already-running lanes so fast app switching never
  cancels sweeps). Session-only overlays never overwrite kwt project structure.
- **Local GRDB persistence:** stores app-owned state only (view state, selected
  worktree/window state, native settings, configured SSH hosts and launch
  profiles, telemetry UUID and last activity day). No database migrations
  before the first production release.

## Direction

Ghosthub stays a native hub for local and remote terminal multiplexers: one
sidebar for tmux, Herdr, Rex, and Zellij across your Macs, Linux machines, and
tailnet, with no local shell needed to browse, switch, or reconnect. The app
owns discovery, native client views, and SSH reconnect supervision; each
multiplexer keeps ownership of its terminal state.
