# Windows and Linux Rust Port

This document is the maintained design for native Ghosthub applications on
Windows and Linux. The first product slice is Windows-only and uses tmux in
WSL2; Linux remains a compile-and-contract target until a native Linux product
slice is authorized. The shipped macOS application remains SwiftUI/AppKit with
libghostty. The shared product and terminal invariants remain authoritative in
[architecture.md](architecture.md) and
[terminal-sessions.md](terminal-sessions.md).

The port exists to deliver the same native terminal for local and remote tmux
fleets on Windows and Linux. It is not a rewrite of the macOS application, a
shared runtime embedded into Swift, or a reason to change macOS away from
SwiftUI.

## 1. Product and Dependency Boundary

### Platform split

- macOS remains SwiftUI/AppKit and libghostty.
- Windows uses Rust and GPUI. Its first product slice attaches to real tmux in
  a WSL2 distro through `wsl.exe` and ConPTY.
- Linux remains in Rust CI for compilation, contracts, architecture, lint, and
  dependency policy. A native Linux application is deferred.
- All platforms preserve the Host, Project, Worktree, and ordinary tmux
  Session mental model.
- Kwt remains authoritative for project/worktree identity and exact session
  names. Direct tmux-compatible discovery supplies otherwise-unbound sessions.
- Tmux owns server-side windows, panes, layout, history, alternate-screen
  state, processes, and lifetime for the first slice. The rejected psmux 3.3.7
  capability result remains regression evidence rather than a product
  substrate.
- Ghosthub owns discovery, presentation, ordinary-client attachment,
  transport reconnect, and explicit confirmed destruction.
- The implementations share behavioral contracts and fixtures, not a
  language-runtime boundary or a live database.

The Rust workspace lives under rust/. Rust-port development does not modify
Swift sources, tests, package configuration, or macOS workflows. The
repository-root contracts/ directory is a Rust-owned compatibility corpus; its
manifest and first path-resolution fixtures are now executable on either Rust
target. Any future Swift consumer is a separately authorized parity project,
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

Local ordinary-client exit always ends the presentation. The Windows WSL MVP
does not reconnect a local `wsl.exe` relay after client exit. Remote OpenSSH
exit status 255 alone invokes bounded exponential reconnect; a connection
healthy for 30 seconds resets backoff. Every other status passes through
unchanged.

### Windows WSL command boundary

Host owns the concrete WSL transport and all WSL-shaped knowledge. It resolves
the configured distro or invokes the default distro directly to read
`WSL_DISTRO_NAME`, then pins every later command to that exact name. It does
not parse localized `wsl.exe --list` output. One direct `/usr/bin/cat` call
reads `/proc/version`, `/proc/sys/kernel/random/boot_id`, and `/proc/1/stat`;
the result must identify WSL2 and yields both shared-kernel and distro-instance
identity.

Host constructs AttachPlan with a fully resolved program and argv. Terminal
launches that value through ConPTY and never names or depends on the WSL
transport:

~~~text
wsl.exe --distribution <distro> --exec /usr/bin/env \
  TERM=xterm-256color [TMUX_TMPDIR=<configured absolute POSIX path>] \
  <configured absolute POSIX tmux path> attach-session -E -t =<exact name>
~~~

Every value is a separate argv entry; no shell command is composed. Defaults
are `/usr/bin/tmux` and tmux's own socket resolution. Optional read-only
configuration supplies a different absolute binary or socket directory.
Ghosthub does not source login or interactive shell files, so a
shell-configured `TMUX_TMPDIR` must be repeated in Ghosthub configuration.

Discovery uses one `list-sessions -F` crossing whose format carries the server
PID, session ID, creation time, name, and attached state. It never starts one
transport process per discovered session.

The first attach classifies tmux's missing-or-unsuitable-terminal diagnostic.
It retries the same exact attach once with `TERM=xterm` and displays a
reduced-color notice rather than requiring `infocmp`, `tput`, or
`ncurses-bin`. Other local client exits do not loop.

Host publishes classified diagnostics rather than flattening command failures:

- an absent tmux server is successful empty inventory
- exec status 127 is a missing configured tmux binary and points to the binary
  override
- permission denial identifies the executable or socket directory involved
- a non-WSL2 kernel is an unsupported-environment diagnostic
- invalid instance or inventory fields are malformed-output diagnostics
- failure to start or communicate with `wsl.exe` is a transport diagnostic

Failures remain retryable where another attempt can change the result. The
empty state names the resolved distro, binary, and default or configured socket
environment so zero sessions cannot silently conceal where Ghosthub looked.

### Terminal ownership

The terminal boundary owns the complete frontend behavior, not merely VT
parsing. UI performs the mechanical GPUI-to-neutral event conversion through
workspace re-exports; terminal owns every terminal-semantic decision:

- mode-aware key encoding
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
The Windows WSL MVP denies both OSC 52 reads and writes. Tmux copy mode remains
usable, but a copy-mode yank does not reach the Windows clipboard in this
slice.

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

The first Windows probe targeted psmux 3.3.7 (`05cc5d4`, SHA-256
`8A2370A98C47F5FF68DA4A317BFBAF4316DF19FE990B839BDACF856BEBC00405`)
through an isolated `-L ghosthub-test-*` namespace. It proved `new-session
-A`, `new-session -e`, exact `has-session`, stable `$3` identity across
rename, server PID change across restart, and namespace isolation. That build
is inadmissible: `kill-session -t =name` reports that the session is
still present after five seconds, and `attach-session -E` remains unproven
for that implementation. `cargo test-psmux-live` remains an opt-in rejection
regression: it passes by observing the failed exact-target proof and rejecting
the build rather than granting either capability from version or help output.
It is not a Windows MVP gate.

The experimental Swift remote-Windows path uses the same psmux build but does
not issue the demonstrated failing mutation: it resolves the exact target and
fresh identity, then kills by session ID. Its complete conditional-kill flow
still requires an isolated end-to-end psmux verification; the Rust rejection
does not make that shipped path dead code or establish that it reports false
success.

The Windows MVP instead verifies POSIX tmux inside WSL2. Host constructs a
fully resolved invocation whose Windows launcher is `wsl.exe`, whose prefix is
`--distribution <name> --exec`, and whose absolute mux path and null config are
POSIX values such as `/usr/bin/tmux` and `/dev/null`. The invocation carries
`ExecutablePlatform::Posix`; the contract platform remains Windows because the
fixture executes where `wsl.exe` exists. WSL fixtures use a new strict fixture
ID and shape with an explicit executable-platform field. The existing psmux
fixture schema is unchanged.

All seven mux capabilities remain required even though the attach-only MVP
does not create sessions. Six are established on an isolated WSL tmux server.
The genuine ConPTY lifetime gate supplies the seventh
`attach-preserve-environment` observation by attaching with `-E`, presenting a
conflicting client sentinel, and proving the session environment did not
change. No `VerifiedTmuxBinary` exists until that live observation succeeds.

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
hostname, port, and user. A WSL endpoint contains the resolved distro name;
kernel boot ID plus `/proc/1/stat` field 22 form a separate runtime instance
identity so a distro restart is detectable even when the shared WSL2 kernel
does not restart. After a fresh query, promotion atomically replaces the
reservation with the live key:

~~~text
endpoint + runtime instance + socket + server PID + session ID + session creation time
~~~

Name is display/attachment metadata, not instance identity. Rename updates the
display name while retaining the live presentation. Server restart produces a
new live key even if a session ID is reused.

If two reservations promote to the same live key, the first wins. The loser
disconnects its already-connected ordinary client, releases its lease, and
focuses the winner. Drop releases reservations and durable entries on normal
close, PTY EOF, failure, and unwind.

### Windows WSL relay and server lifetime

The WSL2 tmux server is the external long-lived session owner. It runs inside
the WSL utility VM rather than as a Windows descendant, so a Windows Job Object
cannot turn presentation teardown into server destruction. Terminal owns only
the disposable ConPTY and resolved `wsl.exe` attach client.

The first implementation pins portable-pty 0.9.0 after its full dependency
closure passes cargo-deny. Its raw Windows child-handle API is a
version-scoped source finding, not a lifetime contract, and is reverified on
every upgrade. Ghosthub assigns the spawned relay immediately to an
application-owned Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and
uses `IsProcessInJob` as the runtime membership assertion. This intentionally
inverts the obsolete psmux breakaway design: the relay must remain contained so
forced Ghosthub termination reaps the Linux-side tmux client, while the server
is inherently outside the job.

If job creation, assignment, or membership verification fails, Ghosthub closes
the PTY master, waits a bounded interval for the relay, applies the client-only
termination fallback if needed, releases the presentation reservation, and
only then publishes a diagnostic. It never leaves an already-spawned relay
running merely because promotion was refused. Portable-pty cannot create the
relay suspended, so a bounded spawn-to-assignment race remains accepted; a
presentation becomes active only after membership is proven.

The workspace changes `unsafe_code` from `forbid` to `deny` and adds
`unsafe_op_in_unsafe_fn = "deny"`. One Windows-only terminal module may use a
narrowly scoped `allow` to wrap `CreateJobObjectW`,
`SetInformationJobObject`, `AssignProcessToJobObject`, and `IsProcessInJob`
behind a safe RAII API. Every other crate retains the workspace denial. The
architecture harness verifies that every `ghosthub-*` workspace member opts
into workspace lints so a new crate cannot silently escape that policy.

The module uses the `windows-sys` 0.61.2 already selected by GPUI 0.2.2's
Windows graph rather than introducing another version. Its direct dependency,
portable-pty, and the selected terminal engine must pass cargo-deny before the
live gate links them.

The live integration matrix kills the presentation/application child
gracefully and forcibly, then launches a fresh child and reattaches to the same
identity:

| Platform/context | Forced termination | Required result |
| --- | --- | --- |
| macOS Swift gate | SIGKILL | tmux server/session survives |
| Windows WSL2 ordinary process | TerminateProcess | relay/client exits; exact tmux identity survives |
| Windows WSL2 inherited job | Close/terminate containing process | client-only job reaps relay; exact tmux identity survives |
| Windows job assignment or membership failure | No promoted presentation | spawned relay is unwound before diagnostic |

The guarantee covers Ghosthub presentation and application termination. It
does not promise survival across `wsl --shutdown`, distro termination, or a
Windows lifecycle event that restarts the WSL instance. The runtime instance
identity distinguishes that condition from disappearance inside the same
instance.

## 3. Workspace and State Ownership

### Rust packages

Workspace directories use short names and namespaced package names:

| Directory | Cargo package / output | Responsibility |
| --- | --- | --- |
| model | ghosthub-model, lib model | Pure domain values and classified diagnostics |
| input | ghosthub-input, lib input | Backend-neutral terminal input events, modes, and encoding |
| surface | ghosthub-surface, lib surface | Rust-owned terminal paint vocabulary |
| session | ghosthub-session, lib session | Launch capabilities, verified mux/helper capabilities, live identity |
| config | ghosthub-config, lib config | Path resolution and read-only/writable preferences |
| store | ghosthub-store, lib store | SQLite records and attach-only descriptors |
| host | ghosthub-host, lib host | Local/WSL/SSH resolution and inventory, kwt, muxes, managed helpers |
| terminal | ghosthub-terminal, lib terminal | TerminalEngine, resolved-client PTY worker, input, clipboard, surface publication |
| workspace | ghosthub-workspace, lib workspace | Inventory reconciliation, actions, selection, restoration |
| ui | ghosthub-ui, lib ui | GPUI windows and elements |
| app | ghosthub-app, bin ghosthub | Composition root |

The dependency constraints are:

~~~text
app
├── ui ─────────→ workspace, model, surface
├── workspace ──→ host, terminal, store, session, config, model, surface, input
├── host ───────→ session, config, model
├── terminal ───→ session, config, model, surface, input
├── store ──────→ model
├── session ────→ model
├── config ─────→ model
├── surface ────→ (leaf)
└── input ──────→ (leaf)
~~~

Cargo metadata tests traverse normal, build, and development dependencies.
The diagram is enforced as a direct allowlist for every declared package;
planned packages may be absent, but an undeclared internal package or edge
fails the gate. Test fixture consumers separately declare their development
edge to the contracts harness. The same harness reads each package manifest
and requires `[lints] workspace = true` for every `ghosthub-*` member.
Store cannot reach session through any transitive path. UI's constraint is
direct: across all three dependency kinds, it may depend directly only on
workspace, model, and surface, and never directly on host, terminal, store,
config, input, or session. UI names neutral input values only through
workspace re-exports, preserving the direct dependency boundary. Cross-boundary
negative persistence tests live in the
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
2. the platform state mapping from GhosthubHome: the root itself on POSIX and
   its state child on Windows

Rust does not honor XDG_CONFIG_HOME or XDG_STATE_HOME. Linux's fixed config
default matches the usual XDG default location, while explicit relocation uses
GHOSTHUB_CONFIG_HOME.

All inputs and computed defaults must be local absolute paths. POSIX uses its
platform predicate. Windows accepts fully qualified drive-rooted paths and
rejects drive-relative, root-relative, UNC, and user-supplied device/verbatim
paths. A UNC-backed computed %USERPROFILE% is a blocking startup diagnostic
with a local override escape hatch. Windows builds enable long-path awareness;
validated local paths may use extended-length form internally. A present but
invalid explicit override is also a blocking diagnostic; it is never ignored
in favor of a lower-precedence value.

Environment, home-directory, and platform path behavior are injected so
contract tests can execute either path flavor on either host. Rust has no
config-home file redirect, so root resolution has no filesystem dependency.

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

The repository-root contracts/ manifest has stable IDs, schema versions,
platform tags, suites, and paths. Rust suites enumerate every applicable entry
and fail on unknown, missing, duplicate, unsafe, or unconsumed fixtures. The
first shipped suite covers POSIX and Windows root resolution; subsequent gate
work adds its fixtures and consumer atomically. `cargo test-contracts` runs the
manifest, path, and Cargo-architecture gates in Windows and Linux CI. A later,
separately authorized Swift adapter may consume the same manifest without
making Swift changes part of the Rust delivery path.

The planned complete corpus covers:

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

The first Windows product UI integration starts only after these gates close:

| Gate |
| --- |
| Establish Rust contracts, architecture checks, and cargo-deny |
| Select the VT backend and prove reusable scroll-aware surface publication |
| Admit portable-pty and the terminal engine through the license closure |
| Prove WSL2 ConPTY I/O, client Job Object containment, relay teardown, and application-death survival |
| Verify WSL tmux commands, isolation, identity, and all seven required capabilities |

Prototype code may exercise GPUI or a candidate backend, but product crates do
not expose provisional backend-specific APIs.

### Slice 1: local attach only

The first executable milestone discovers and attaches to an existing tmux
session in one resolved WSL2 distro from a native Windows GPUI window, then
detaches without destroying it. It contains a minimal discovered-session
sidebar, one terminal presentation, a visible cancellable WSL startup state,
and retryable diagnostics.

The flow resolves and verifies the exact mux binary, discovers live identity,
reserves the presentation, launches an AttachPlan, promotes the reservation,
renders through surface, disconnects on close, and reattaches to the surviving
identity from a fresh process.

Slice 1 reads font family, font size, and theme through:

~~~text
config → workspace projection → UI-facing state → GPUI
~~~

It has no settings editor.

Read-only configuration may select a distro name, an absolute POSIX tmux
binary, and an absolute POSIX `TMUX_TMPDIR`. Defaults are the current WSL
distro, `/usr/bin/tmux`, and tmux's own default socket resolution. Ghosthub
does not source interactive or login shell files in this slice. Users whose
sessions use another binary or socket directory must configure it explicitly;
the empty state names the resolved distro and whether the default or configured
socket environment was queried.

Windows manual acceptance requires WSL2, tmux, and an existing session started
outside Ghosthub. Setup is documented as deterministic commands rather than an
implicit prerequisite. A missing server is an empty inventory, not an error.

The milestone proves:

- GPUI paints the selected VT backend through scroll-aware surface buffers
- keyboard, SGR 1006 mouse reporting, AltGr, and bracketed paste work
- ordered resize and stale-frame letterboxing work
- buffers remain bounded and UI never blocks on PTY or store work
- reselecting the same session in one window refuses a second client and
  focuses the existing terminal as Ghosthub policy rather than a tmux limit
- client close, graceful app exit, and forced app death preserve the server
  and permit fresh-process reattachment to the exact same live identity
- failed relay-job membership fully unwinds the spawned attachment before the
  reservation is released and a diagnostic appears
- the genuine ConPTY attach proves `attach-session -E`, and TTY plumbing
  failure cannot be recorded as a missing mux capability
- `TERM=xterm-256color` works end-to-end or the initial attach retries once
  with `TERM=xterm` and displays a reduced-color notice

Cross-window focus arbitration is deferred until multi-window delivery.

Slice 1 denies OSC 52 reads and writes; tmux copy-mode yanks therefore do not
reach the Windows clipboard. It excludes IME composition, dead keys, creation,
kill, kwt inventory, worktree mutation, remote SSH, managed-helper
installation, native Linux product UI, persistence/restoration, multiple
windows, Console Panel, telemetry, updates, packaging, and acceptance
screenshots.

### Failure branches

If the WSL ConPTY/lifetime or tmux capability gate fails, Windows returns to
substrate selection; there is no app-lifetime or psmux fallback. If every VT
candidate fails the terminal-state gate, product integration stops for
architecture reconsideration. Linux CI remains a compile-and-contract signal,
not an alternate product delivery branch.

### Test categories

The shipped make test-essential-workflows target is a fast filter loop over
KwtInventoryClientTests, TmuxHostResolverTests, TmuxAttachmentInfoTests, and
WorkspaceSidebarModelTests. It does not launch a live tmux server.

Rust keeps the same separation:

- cargo test-contracts is the fast manifest, parsing, capability, plan,
  sidebar, registry, and architecture gate
- test-rust-live-attach launches a real isolated tmux server inside a WSL2
  distro plus PTYs and supervisor children for detach and app-death survival

Cargo test binaries own cross-platform orchestration. Make targets are thin
wrappers; Windows CI invokes the same Cargo tests without POSIX shell
scaffolding. Windows tests use a unique WSL tmux socket namespace and assert
before and after each run that the user's default server is untouched.

The Rust port adds no Swift or macOS live-attach work. Linux compilation is not
used as evidence for the Windows ConPTY-to-WSL relay path.

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
