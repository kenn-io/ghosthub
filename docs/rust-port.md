# Windows and Linux Rust Port

This document is the maintained design for native Ghosthub applications on
Windows and Linux. The Rust applications are under active development; the
shipped macOS application remains SwiftUI/AppKit with libghostty. The shared
product and terminal invariants remain authoritative in
[architecture.md](architecture.md) and
[terminal-sessions.md](terminal-sessions.md).

The port exists to deliver the same native terminal for local and remote tmux
fleets on Windows and Linux. It is not a rewrite of the macOS application, a
shared runtime embedded into Swift, or a reason to change macOS away from
SwiftUI.

## 1. Product and Dependency Boundary

### Platform split

- macOS remains SwiftUI/AppKit and libghostty.
- Windows and Linux use Rust and GPUI.
- All platforms preserve the Host, Project, Worktree, and ordinary tmux
  Session mental model.
- Kwt remains authoritative for project/worktree identity and exact session
  names. Direct tmux-compatible discovery supplies otherwise-unbound sessions.
- Tmux or psmux owns server-side windows, panes, layout, history, alternate
  screen state, processes, and lifetime.
- Ghosthub owns discovery, presentation, ordinary-client attachment,
  transport reconnect, and explicit confirmed destruction.
- The implementations share behavioral contracts and fixtures, not a
  language-runtime boundary or a live database.

The Rust workspace lives under rust/. Rust-port development does not modify
Swift sources, tests, package configuration, or macOS workflows. The
repository-root contracts/ directory begins as a Rust-owned compatibility
corpus. Any future Swift consumer is a separately authorized parity project,
not an implicit requirement of Rust feature work.

### License closure

Every linked Rust dependency must satisfy the repository's approved
Apache-2.0-compatible policy. MIT and Apache-2.0 components are acceptable.
GPL and AGPL Zed crates, including its UI and terminal application layers, are
not acceptable dependencies.

The repository keeps `rust/deny.toml` as a reviewed allowlist and runs
cargo-deny against normal, build, development, target-specific, and GPUI
transitive dependencies. A dependency cannot enter the lockfile merely because
its direct crate has an acceptable license; the complete linked closure must
pass.

GPUI 0.2.2's complete Windows/Linux graph currently requires two exact
MPL-2.0 exceptions, `dwrote` 0.11.5 and `option-ext` 0.2.0. MPL-2.0 permits
combination with Apache-licensed code, but the exception remains crate-scoped
so a new copyleft dependency cannot arrive silently. Known unmaintained
transitives are individually identified in deny.toml and must be reconsidered
whenever the GPUI pin changes. GPL and AGPL third-party dependencies remain
unconditionally rejected. Ghosthub's own Rust packages retain the repository's
AGPL-3.0-or-later license and are excluded from the third-party allowlist check.

### Verified dependency findings

The pinned libghostty-vt C API provides key event encoding, including Kitty
keyboard flags, modifyOtherKeys, cursor/keypad application modes, and Alt
behavior. Its encoder takes those modes explicitly and does not require a
Ghostty terminal handle. It also provides OSC/SGR parsing utilities and paste
safety. The pinned public C API does not expose screen state, scrollback,
reflow, resize, or owned render snapshots.

Depending on Ghostty's internal Zig screen/page-list implementation would add
an unstable internal API and Zig to the required Windows/Linux toolchain.
Therefore the terminal-state gate evaluates the established pure-Rust
alacritty_terminal and wezterm-term paths in parallel with any Ghostty shim.
The backend is selected behind a capability-shaped TerminalEngine seam:
bytes in, resize, modes queryable, semantic effects, and Rust-owned paint
state out. No public crate or UI API presumes the outcome.

The exact kwt revision in repository-root `KWT_REVISION` is
12463d3a0b194d2d3937037ac5b57ad630114854. That source uses KWT_HOME or the
fixed $HOME/.config/kwt default. It does not read Ghosthub init.toml,
config_home, or XDG_CONFIG_HOME. Rust must not reproduce the unsupported
Ghosthub init.toml scanner. The two existing Swift copies are outside the Rust
port's scope and are not a prerequisite for Rust path fixtures.

### Executable bootstrap

The first checked-in workspace pins Rust 1.96.1 and GPUI 0.2.2. It contains
`ghosthub-model`, `ghosthub-ui`, and the `ghosthub-app` composition root with a
`ghosthub` binary. The GPUI window has been built and launched as a native
Windows ARM64 process. Linux enables both Wayland and X11 backends and is
compiled and tested independently rather than inferred from the Windows build.

Rust CI exists only in `.github/workflows/rust-port.yml`. It runs Windows and
Linux jobs for pushes and pull requests targeting the `rust-port` integration
branch. It is neither present on nor triggered for `main`; the shipped Swift
application's CI remains unchanged.

## 2. Terminal Presentation and Session Execution

### Launch authority is structural

The Rust type system distinguishes three authorities:

- AttachPlan is cloneable and can launch only one exact ordinary-client
  attachment.
- CreateOnce is neither cloneable nor serializable. Launch consumes it and
  returns the child presentation plus an AttachPlan.
- RepairOrOpen is cloneable and intentionally re-runnable. Its variants make
  ordinary kwt probe-before-open and protected pull-request repair/attach
  semantics explicit.

The path matrix is:

| Path | Initial authority | Later SSH reconnect |
| --- | --- | --- |
| Discovered unbound session | AttachPlan | Exact attach |
| Explicit local bare creation | CreateOnce with atomic new-session -A | None |
| Explicit remote bare creation | One-shot CreateOnce probe/create | AttachPlan |
| Ordinary kwt workspace | RepairOrOpen workspace variant | Exact probe, attach if present, rerun kwt open only if absent |
| Protected pull-request workspace | RepairOrOpen protected variant | Rerun exact kwt pr attach |

No mutable creation boolean exists. The remote reconnect loop cannot accept
CreateOnce.

Local ordinary-client exit always ends the presentation. Local tmux/psmux has
no transport reconnect. Remote OpenSSH exit status 255 alone invokes bounded
exponential reconnect; a connection healthy for 30 seconds resets backoff.
Every other status passes through unchanged.

### Terminal ownership

The terminal crate owns the complete frontend behavior, not merely VT parsing:

- GPUI key-event mapping and mode-aware encoding
- mouse protocol encoding and coordinates
- bracketed-paste framing and unsafe-paste confirmation
- OSC 52 parsing effects and clipboard policy
- PTY client lifecycle
- resize ordering
- terminal backend adaptation
- surface buffer publication

The selected VT backend remains private. If Ghostty key encoding is retained
over a pure-Rust screen backend, its explicit modes make that composition
correct, but its build and packaging cost still participates in the backend
decision.

Input fixtures take both the platform event and terminal mode state. They
cover Kitty levels, modifyOtherKeys, cursor/keypad application modes,
bracketed paste, AltGr as distinct from ordinary Ctrl+Alt, dead keys, and IME
composition.

OSC 52 reads are denied by default and never receive clipboard contents merely
because terminal output requested them. OSC 52 writes follow explicit policy.
Only a genuine user paste action may acquire clipboard contents for PTY input.

### PTY and worker flow

Windows ConPTY exposes a blocking anonymous-pipe reader through portable-pty.
The first implementation therefore uses:

- one dedicated reader thread
- one depth-one rendezvous handoff with reusable approximately 64 KiB buffers
- one serial terminal worker selecting between the byte handoff and ordered UI
  commands
- OS-pipe backpressure when the handoff is full

The invariant is bounded non-lossy delivery with no UI blocking, not the
absence of a byte channel. PTY bytes are never dropped or placed in an
unbounded queue. UI-to-worker input and resize remain ordered. Worker-to-UI
paint publication is latest-value, while non-coalescible semantic effects use
a reliable low-volume path.

### Surface buffers and damage

The backend-neutral ghosthub-surface leaf crate is shared by terminal,
workspace, and UI. It exposes Rust-owned paint buffers, dimensions,
generations, cursor/selection overlays, damage, and leases. It exposes no
PTY, FFI, backend, process, config, or GPUI capability.

Publication uses a bounded reusable-buffer mailbox. A returned buffer retains
its generation; the worker applies accumulated damage since that generation
before republishing. Unpublished frames coalesce in a latest-value slot.
Resize, theme invalidation, or unavailable damage history causes full damage.
UI paints directly from its leased buffer and performs no full-grid conversion
or copy per frame.

Scroll is a first-class damage operation: shift a row range by a signed delta,
then dirty only newly exposed rows and genuine in-place changes. A backend that
turns sustained one-line shell scrolling into repeated full-grid comparison,
copy, or repaint fails the selection gate.

### Resize authority

GPUI derives grid dimensions from element geometry and font metrics, then sends
one ordered resize containing sequence, grid, and pixel sizes. The worker
updates terminal state and PTY winsize as one logical operation.

Every published surface frame carries its generation, resize sequence, grid,
and pixel dimensions. GPUI letterboxes a stale frame rather than stretching an
old grid into new geometry.

### Verified mux capabilities and live identity

VerifiedTmuxBinary contains an absolute executable path, a supported protocol
version of at least 3.2, and an explicitly probed MuxCapabilities set.
Version alone does not prove:

- new-session -A atomic create-or-attach
- new-session -e environment injection
- attach-session -E
- exact =name targets
- isolated non-default server namespaces
- stable session and server-instance identity

VerifiedKwtHelper requires the exact revision, verified SHA-256, and
revision-scoped managed path.

Cached inventory identity is display-only. LiveIdentity has private fields and
can be produced only by a fresh query immediately before a destructive
operation. Conditional kill compares server PID, session ID, and creation
timestamp. Store cannot depend on the session crate and cannot serialize
runtime authority.

### Presentation registry

The application composition root constructs exactly one PresentationRegistry
and injects it; it is not static global state.

During attachment, an RAII PresentationLease reserves the effective endpoint,
socket, and requested exact name. The effective SSH endpoint includes resolved
hostname, port, and user. After a fresh query, promotion atomically replaces
the reservation with the live key:

~~~text
endpoint + socket + server PID + session ID + session creation time
~~~

Name is display/attachment metadata, not instance identity. Rename updates the
display name while retaining the live presentation. Server restart produces a
new live key even if a session ID is reused.

If two reservations promote to the same live key, the first wins. The loser
disconnects its already-connected ordinary client, releases its lease, and
focuses the winner. Drop releases reservations and durable entries on normal
close, PTY EOF, failure, and unwind.

### Windows server lifetime

The psmux server, like a POSIX tmux server, is an external long-lived session
owner. Terminal owns disconnecting the client; host capability resolution owns
whether the server survives.

A source audit found that portable-pty 0.9.0 does not create a Job Object and
creates the ConPTY child without CREATE_BREAKAWAY_FROM_JOB. This is a
version-scoped finding, not a dependency contract: the runtime gate verifies
the actual child and server Job Object membership and must rerun whenever the
portable-pty version changes.

When Ghosthub is in such a job:

- use CREATE_BREAKAWAY_FROM_JOB when the containing job permits breakaway
- use IsProcessInJob against both the spawned ConPTY client and the freshly
  queried psmux server process as the required primitive for the controlled
  inheritance and survival classifications
- when breakaway is denied, attach only to a conservatively proven
  independent pre-existing psmux server
- bare session creation may target that proven independent server but may not
  bootstrap a new server
- when no independent server exists, block local Windows attachment and
  creation with a diagnostic

Ghosthub never degrades to an app-lifetime session, name-based identity, or
the user's unsafe default server.

The live integration matrix kills the presentation/application child
gracefully and forcibly, then launches a fresh child and reattaches to the same
identity:

| Platform/context | Forced termination | Required result |
| --- | --- | --- |
| Linux | SIGKILL | tmux server/session survives |
| macOS Swift gate | SIGKILL | tmux server/session survives |
| Windows ordinary process | TerminateProcess | psmux server/session survives |
| Windows inherited kill-on-close job | Close/terminate containing process | independent psmux server/session survives |
| Windows breakaway denied with no independent server | No attachment | blocking diagnostic |

POSIX tmux daemonizes itself. The macOS/Linux gate primarily proves Ghosthub
does not retain stdio, process-group, or other accidental ownership. That
result is not evidence for the separate Windows Job Object path.

## 3. Workspace and State Ownership

### Rust packages

Workspace directories use short names and namespaced package names:

| Directory | Cargo package / output | Responsibility |
| --- | --- | --- |
| model | ghosthub-model, lib model | Pure domain values and classified diagnostics |
| surface | ghosthub-surface, lib surface | Rust-owned terminal paint vocabulary |
| session | ghosthub-session, lib session | Launch capabilities, verified mux/helper capabilities, live identity |
| config | ghosthub-config, lib config | Path resolution and read-only/writable preferences |
| store | ghosthub-store, lib store | SQLite records and attach-only descriptors |
| host | ghosthub-host, lib host | Local/SSH inventory, kwt, tmux/psmux, managed helpers |
| terminal | ghosthub-terminal, lib terminal | TerminalEngine, PTY worker, input, clipboard, surface publication |
| workspace | ghosthub-workspace, lib workspace | Inventory reconciliation, actions, selection, restoration |
| ui | ghosthub-ui, lib ui | GPUI windows and elements |
| app | ghosthub-app, bin ghosthub | Composition root |

The dependency constraints are:

~~~text
app
├── ui ─────────→ workspace, model, surface
├── workspace ──→ host, terminal, store, session, config, model, surface
├── host ───────→ session, config, model
├── terminal ───→ session, config, model, surface
├── store ──────→ model
├── session ────→ model
└── config ─────→ model
~~~

Cargo metadata tests traverse normal, build, and development dependencies.
Store cannot reach session through any transitive path. UI's constraint is
direct: across all three dependency kinds, it may depend directly only on
workspace, model, and surface, and never directly on host, terminal, store,
config, or session. Cross-boundary negative persistence tests live in the
contracts harness, which may depend on both store and session. Static trait
assertions are regression guards, not proofs: manual store records that mirror
authority fields remain an explicit human-review boundary.

Config reaches UI only when workspace projects font, theme, keybinding, and
appearance preferences into UI-facing view state.

### Roots and managed helpers

GhosthubHome is the common per-user root:

| Platform | Ghosthub home | Config | State | Local managed-helper namespace |
| --- | --- | --- | --- | --- |
| POSIX | $HOME/.ghosthub | $HOME/.config/ghosthub | Ghosthub home itself | GhosthubHome/helpers |
| Windows | %USERPROFILE%\.ghosthub | GhosthubHome\config | GhosthubHome\state | GhosthubHome\helpers |

GHOSTHUB_HOME changes the local root and its derived helper namespace.
GHOSTHUB_CONFIG_HOME changes only config. GHOSTHUB_STATE_HOME changes only
state and never relocates helpers. The default POSIX state being the home root
itself is a shipped irregularity. Local kwt operations use the packaged pinned
binary, never a helper resolved from these directories or PATH.

The remote helper activation root is a separate cross-controller contract:

- POSIX remote: $HOME/.ghosthub/helpers/kwt/{revision}/kwt
- Windows remote: %USERPROFILE%\.ghosthub\helpers\kwt\{revision}\kwt.exe

The shipped `Sources/App/KwtBinaryLocator.swift` already carries both
conventions. A remote controller deliberately ignores every GHOSTHUB override
on the remote host so another controller can find the same revision.
Consequently, an unavailable, unwritable, redirected, or pathological remote
account home has no helper-path override. Installation fails with an actionable
diagnostic requiring a corrected or different remote account. This enterprise
tradeoff is accepted for fleet predictability.

Rust config resolution is:

1. valid GHOSTHUB_CONFIG_HOME
2. valid GHOSTHUB_HOME with config appended
3. platform default

State resolution is:

1. valid GHOSTHUB_STATE_HOME
2. valid GHOSTHUB_HOME with state appended
3. platform default

Rust does not honor XDG_CONFIG_HOME or XDG_STATE_HOME. Linux's fixed config
default matches the usual XDG default location, while explicit relocation uses
GHOSTHUB_CONFIG_HOME.

All inputs and computed defaults must be local absolute paths. POSIX uses its
platform predicate. Windows accepts fully qualified drive-rooted paths and
rejects drive-relative, root-relative, UNC, and user-supplied device/verbatim
paths. A UNC-backed computed %USERPROFILE% is a blocking startup diagnostic
with a local override escape hatch. Windows builds enable long-path awareness;
validated local paths may use extended-length form internally.

Environment, filesystem, home-directory, and platform path behavior are
injected so contract tests can execute Windows cases on macOS without touching
the host filesystem.

### Process and concurrency ownership

Ghosthub has one UI application process and no Ghosthub-owned daemon or
Middleman. External tmux and psmux servers intentionally outlive it.
App-owned utility PTYs, such as a log viewer, are app-lifetime surfaces and do
not claim detach persistence.

Per host:

- serialized mutations preserve ordering for helper installation, project and
  worktree lifecycle, and session destruction
- concurrent reads cover inventory, probes, capability resolution, and
  connection testing
- reads are cancellable and superseded by newer reads of the same kind
- every operation has a timeout

Refresh generations are allocated monotonically. A result publishes only when
its generation is newer than the published generation. Cancelled, timed-out,
or late lower-generation results are discarded.

An unreachable host with cached inventory publishes it as stale/display-only.
Without a cache, it publishes unavailable state and a retryable classified
diagnostic. Neither case grants attachment or destruction authority.

### Store and reconciliation

SQLite runs in WAL mode. One writer task consumes a bounded non-lossy mpsc
queue. No database transaction or connection guard crosses an await point.
UI submission never waits synchronously for queue capacity or disk.

High-frequency low-value writes, including geometry, selection, presentation
history, and last-viewed timestamps, coalesce by stable key. Durable writes use
asynchronous acknowledgement and backpressure away from the GPUI thread.
Shutdown has a bounded flush policy.

Persisted history is display-only. Persistence may store attach-only
descriptors but cannot serialize creation, repair, or kill authority.

The Reconciler consumes only already-published inventory generations from the
host read lanes. It cannot probe a host, run kwt, invoke tmux/psmux, or derive
liveness independently. Runtime and cold-start reconciliation may forget or
mark Ghosthub records stale and remove presentation metadata; it may never
kill a server session.

Pending restoration is attach-only and ends at the first of three completed
failed host refreshes, ten minutes after scene activation, or user navigation.
Expiry returns to host/project navigation with an explicit retry. A host
returning hours later cannot spontaneously attach a window.

### Compatibility contracts

The planned repository-root contracts/ manifest has stable IDs, schema
versions, platform tags, and paths. Rust suites enumerate every applicable
entry and fail on unknown, missing, duplicate, or unconsumed fixtures. Rust
contract tests run in Windows and Linux CI. A later, separately authorized
Swift adapter may consume the same manifest without making Swift changes part
of the Rust delivery path.

The corpus covers:

- kwt inventory and worktree create/branch import/PR import lifecycles
- tmux/psmux resolution, capabilities, identity, and exact commands
- SSH exits, reconnect/backoff, host-key/authentication/askpass prompts
- path roots and platform-specific absoluteness
- attach-only restoration and display-only history
- Console Panel and utility-PTY lifetime
- terminal input with modes, AltGr, dead keys, and IME
- clipboard and paste policy
- surface resize, damage, scroll, and snapshots

## 4. First Vertical Slice and Delivery

### Blocking substrate gates

The first product UI integration starts only after these tracked gates close:

| Kata | Gate |
| --- | --- |
| 9bmg | Establish Rust contracts, architecture checks, and cargo-deny |
| xvrf | Select the VT backend and prove reusable scroll-aware surface publication |
| c2xv | Prove ConPTY I/O, Job Object handling, and application-death survival |
| v27t | Prove psmux command, isolation, and identity capabilities |

Prototype code may exercise GPUI or a candidate backend, but product crates do
not expose provisional backend-specific APIs.

### Slice 1: local attach only

The first executable milestone discovers and attaches to an existing local
tmux/psmux session in a native GPUI window, then detaches without destroying
it. It contains one local host, a minimal discovered-session sidebar, one
terminal presentation, and retryable diagnostics.

The flow resolves and verifies the exact mux binary, discovers live identity,
reserves the presentation, launches an AttachPlan, promotes the reservation,
renders through surface, disconnects on close, and reattaches to the surviving
identity from a fresh process.

Slice 1 reads font family, font size, and theme through:

~~~text
config → workspace projection → UI-facing state → GPUI
~~~

It has no settings editor.

Windows manual acceptance requires psmux to be installed and an isolated
named server/session to be started outside Ghosthub. Linux acceptance uses an
out-of-band isolated tmux server/session. Setup is documented as deterministic
commands rather than an implicit prerequisite.

The milestone proves:

- GPUI paints the selected VT backend through scroll-aware surface buffers
- keyboard, mouse, AltGr, IME, paste, and local clipboard policy work
- ordered resize and stale-frame letterboxing work
- buffers remain bounded and UI never blocks on PTY or store work
- reselecting the same session in one window refuses a second client and
  focuses the existing terminal
- client close, graceful app exit, and forced app death preserve the server
  and permit fresh-process reattachment
- Linux works under at least one Wayland and one X11 session

Cross-window focus arbitration is deferred until multi-window delivery.

Slice 1 excludes creation, kill, kwt inventory, worktree mutation, remote SSH,
managed-helper installation, persistence/restoration, multiple windows,
Console Panel, telemetry, updates, packaging, and acceptance screenshots.

### Failure branches

If c2xv or v27t fails, Slice 1 lands Linux-only and Windows returns to substrate
selection. It does not negotiate a weaker session lifetime under schedule
pressure. If every VT candidate fails xvrf, Slice 1 stops for architecture
reconsideration on both platforms.

### Test categories

The shipped make test-essential-workflows target is a fast filter loop over
KwtInventoryClientTests, TmuxHostResolverTests, TmuxAttachmentInfoTests, and
WorkspaceSidebarModelTests. It does not launch a live tmux server.

Rust keeps the same separation:

- test-rust-contracts is the fast parsing, capability, plan, sidebar,
  registry, and manifest gate
- test-rust-live-attach launches real isolated tmux/psmux servers, PTYs, and
  supervisor children for detach and app-death survival

Cargo test binaries own cross-platform orchestration. Make targets are thin
wrappers; Windows CI invokes the same Cargo tests without POSIX shell
scaffolding. POSIX uses a unique socket namespace. Windows uses a unique psmux
namespace backed by its named-pipe transport. Both assert that the user's
default server is untouched.

The Rust port adds no Swift or macOS live-attach work. POSIX tmux behavior on
Linux is not used as evidence for the separate Windows Job Object path.

### Follow-on order

After Slice 1:

1. Local Ghosthub inventory adds pinned bundled kwt, project/worktree
   inventory, unbound reconciliation, and the full sidebar hierarchy.
2. Launch authorities deliver user-visible plain session creation through
   CreateOnce and worktree selection through ordinary/protected RepairOrOpen.
3. Local lifecycle adds project registration, worktree creation, branch/PR
   import, deletion, and fresh-identity conditional Kill Session.
4. Remote hosts add OpenSSH diagnostics, managed-helper installation,
   attach-only transport reconnect, repair/open reconnect, and remote Windows.
5. Persistence and restoration add the coalescing writer, host settings,
   attach-only descriptors, bounded pending restoration, and inventory-only
   cold-start reconciliation.
6. Product completion adds multi-window behavior, Console Panel, settings,
   command palette, themes, accessibility, notifications, packaging, and
   release gates.

No later stage may weaken detach-only session lifetime, exact targeting,
capability-based launch authority, or the rule that reconciliation forgets
records but never kills server state.
