# Windows and Linux Rust Port

This document is the maintained design for native Ghosthub applications on
Windows and Linux. The first product slice is Windows-only, uses tmux in WSL2,
and discovers optional Herdr and Zellij sessions there; Linux remains a
compile-and-contract target until a native Linux product slice is authorized.
The shipped macOS application remains SwiftUI/AppKit with libghostty. The
shared product and terminal invariants remain authoritative in
[architecture.md](architecture.md) and
[terminal-sessions.md](terminal-sessions.md).

The port exists to deliver the same native terminal for local and remote
multiplexer fleets on Windows and Linux. It is not a rewrite of the macOS
application, a shared runtime embedded into Swift, or a reason to change macOS
away from SwiftUI.

## 1. Product and Dependency Boundary

### Platform split

- macOS remains SwiftUI/AppKit and libghostty.
- Windows uses Rust and GPUI. Its first product slice attaches to real tmux in
  a WSL2 distro through `wsl.exe` and ConPTY.
- Linux remains in Rust CI for compilation, contracts, architecture, lint, and
  dependency policy. A native Linux application is deferred.
- All platforms preserve the Host, Project, Worktree, and ordinary
  multiplexer-session mental model.
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

Repository-root `KWT_REVISION` is the sole source of the exact audited kwt
revision. That source uses KWT_HOME or the fixed $HOME/.config/kwt default. It
does not read Ghosthub init.toml, config_home, or XDG_CONFIG_HOME. Rust must not
reproduce the unsupported Ghosthub init.toml scanner. The two existing Swift
copies are outside the Rust port's scope and are not a prerequisite for Rust
path fixtures.

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

WSL is enabled automatically when the system-owned `wsl.exe` exists, but it is
not required to open or use the application shell. The composition root checks
the absolute Windows system path without executing WSL or searching `PATH`.
Absence publishes no WSL host; an inspection failure publishes an unavailable
synthetic WSL host with its classified diagnostic. Linux publishes no WSL host.

GPUI paints the application shell and disconnected synthetic host first, then
asks workspace to connect enabled hosts on the next frame. Discovery may cold
start WSL, but Connecting, Ready, empty inventory, Timeout, and other failures
remain scoped to that host. The initial total refresh budget is 45 seconds and
later attempts receive 30 seconds; each command retains its 15-second bound.
Expiry cancels the active generation and discards late publication. Retry
supersedes the earlier generation without changing the configured distro,
binary, socket directory, or identity rules.

An application-owned background cadence refreshes a ready WSL host every ten
seconds while the window is active, so sessions created or removed elsewhere
appear without an explicit Refresh click without polling WSL from an inactive
window. Window activation is presentation-only: it updates an in-memory polling
flag, focus, and other in-memory view state, but it never starts host discovery,
process sampling, filesystem access, database work, or inventory reconciliation.
Connecting, disconnected, and unavailable hosts do not retry automatically;
their existing Cancel, Connect, and Retry actions remain authoritative. Refresh
of an already-ready host retains Ready state, the last published session rows,
and constructive actions while work is in flight; starting it publishes no
transient UI revision. Automatic cadence skips an in-flight host refresh or
session operation and never starts the separate KWT inventory lane. It reuses
the admitted WSL host capability, including its endpoint- and runtime-bound
tmux verification cache. A resolved default-distro change always requires
fresh admission even when two WSL distributions report the same kernel boot ID
and PID 1 start time.

Each host command runs in a disposable descendant container: a kill-on-close
Job Object on Windows and a dedicated process group on Unix. Stdout and stderr
travel through a bounded fixed-chunk channel into capped capture buffers. On
exit, timeout, cancellation, or capture failure, Ghosthub terminates the whole
container before a bounded output drain, so a descendant retaining an inherited
pipe cannot strand discovery or accumulate refresh threads. Windows children
start suspended, join the Job Object, and only then execute user code, closing
the post-spawn assignment race.

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
  <configured absolute POSIX tmux path> if-shell -F -t =<session-id>: \
  <server-pid/session-id/creation-time condition> \
  "attach-session -E -t =<session-id>" \
  "display-message -p <identity-mismatch marker>"
~~~

Every outer value is a separate argv entry and no operating-system shell is
invoked. The final two argv entries are tmux command strings required by
`if-shell`; they contain only validated live identity values and fixed command
tokens. Defaults are `/usr/bin/tmux` and tmux's own socket resolution. Optional
read-only configuration supplies a different absolute binary or socket
directory. Ghosthub does not source login or interactive shell files, so a
shell-configured `TMUX_TMPDIR` must be repeated in Ghosthub configuration.

Discovery uses one `list-sessions -F` crossing whose format carries the server
PID, session ID, creation time, name, and attached state. It never starts one
transport process per discovered session.

The first attach classifies tmux's missing-or-unsuitable-terminal diagnostic.
It retries the same exact attach once with `TERM=xterm` and displays a
persisted reduced-color notice for the lifetime of that presentation rather
than requiring `infocmp`, `tput`, or `ncurses-bin`. Other local client exits do
not loop. Each published terminal worker receives a distinct presentation ID.
The fallback first unpublishes the failed worker and clears pending paste and
UI input state, so no input can cross into the replacement client.

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

### Optional Herdr capability in WSL

Herdr is discovered as an optional capability of the resolved WSL endpoint,
not as a second host and not as an application startup requirement. After tmux
admission, Host resolves an exact absolute `herdr` executable through WSL's
POSIX login profile (`/bin/sh -lc` with a fixed Ghosthub-owned probe), removes
every inherited Herdr routing variable named
in [Terminal Sessions](terminal-sessions.md), and invokes
`herdr session list --json` through direct argv. Exit 127 is silent absence.
Other executable, permission, transport, and malformed-output failures remain a
Herdr-scoped diagnostic and do not change tmux readiness or cached tmux rows.

The inventory preserves both running and stopped sessions and publishes them in
a separate compact Herdr group under the WSL host. Tmux and Herdr each own the
creation action beside their group header; the host row owns refresh, not
session creation. A refresh marks the host as connecting without discarding
either cached group, so navigation remains stable while replacement inventory
is in flight.

The Herdr executable and inventory are captured inside the same before/after
WSL runtime check as tmux, so a distro restart cannot combine evidence from
different runtime instances. Opening a running row uses
`herdr session attach <exact-name>`. Creating a named session consumes one
non-cloneable launch authority for `herdr --session <exact-name>` and never
replays it after failure. Both paths launch an ordinary ConPTY client through
direct argv after removing all inherited Herdr routing variables. Retained
presentation switching uses the same presentation slot as tmux. Selecting a
stopped row restarts it through the one-shot launch path: the default session
uses plain `herdr`, while a named session uses `herdr --session <exact-name>`.
Creation accepts Ghosthub's restricted user-authored name type; Restart carries
the authoritative discovered name unchanged, so an existing session is not
made unmanageable by newer creation rules. The captured default-session role
is part of restart and lifecycle validation alongside state and paths.
Stop and Delete require confirmation, then Host freshly revalidates the WSL
runtime, executable, expected running or stopped state, session directory, and
socket, followed by a final runtime check immediately before invoking the
direct lifecycle command. A per-session in-flight guard disables duplicate
actions. A workspace operation fence serializes attach, retained-client retry,
create or restart, and lifecycle mutation from fresh discovery through worker
publication or failure, so Stop and Delete cannot be followed by an older
launch completing. Stop first closes every matching client presentation;
Delete is offered only for stopped non-default sessions. The guard remains
until fresh inventory publishes or a classified operation failure is reported.
Every constructive or lifecycle publication advances the inventory generation
and cancels an older refresh, so an earlier full snapshot cannot overwrite the
result. Rust does not reinterpret Herdr as a tmux-compatible server or use
Herdr's remote mode.

### Optional Zellij capability in WSL

Zellij is a third optional capability of the same resolved WSL endpoint. Host
resolves one absolute executable through the POSIX login profile, removes
inherited `ZELLIJ`, `ZELLIJ_PANE_ID`, and `ZELLIJ_SESSION_NAME`, and invokes
`zellij list-sessions --no-formatting` through direct argv. Exit 127 is silent
absence. Zellij's exact no-active-sessions response is successful empty
inventory; other failures remain Zellij-scoped diagnostics and never hide tmux
or Herdr inventory. Exited entries that Zellij could resurrect are deliberately
excluded.

The sidebar gives Zellij its own compact group and creation action. Opening an
active row consumes an attach-only plan for `zellij attach -- <exact-name>`.
Creation consumes a non-cloneable one-shot launch for
`zellij --session=<exact-name>`. Both run as ordinary ConPTY clients, share the
retained-presentation switcher with tmux and Herdr, and never replay creation
after failure. Closing the client only detaches.

Kill Session is separate and confirmed. Host checks the current WSL runtime,
absolute executable, and exact active name, closes the matching presentation,
then repeats all checks immediately before `zellij kill-session --
<exact-name>`. Attachment, creation, and kill share the serialized session
operation lane, so an older launch cannot complete after an intentional kill.
Zellij exposes no stable session-generation identity; the same-name
replacement race described in [Terminal Sessions](terminal-sessions.md)
remains an explicit backend limitation rather than a false tmux-strength
guarantee.

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
composition. The input vocabulary preserves the logical unmodified key, the
produced text, and press, repeat, or release event type independently so Kitty
alternate-key and event reporting never has to reconstruct them from terminal
bytes.

Clipboard behavior follows the shipped Swift contract. Local and remote tmux
surfaces may write the system clipboard through OSC 52 when `clipboard-write`
allows it, so tmux copy-mode yanks reach Windows as they do on macOS. Remote
OSC 52 reads always receive an empty response regardless of `clipboard-read`;
local OSC 52 reads follow the configured local policy. Only a genuine user
paste action may acquire clipboard contents for PTY input, and the terminal
worker applies bracketed-paste framing and unsafe-paste confirmation before
writing it. The Windows WSL MVP includes OSC 52 writes, remote-read denial,
and explicit clipboard paste rather than treating them as deferred parity.

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
unbounded queue. Non-coalescible UI input uses an ordered queue bounded by both
command count and total payload bytes. GPUI retains backpressured input in its
own smaller bounded retry buffer and stops accepting more with a visible busy
diagnostic only when that buffer is also full. Paste approval and cancellation
use a separate bounded control lane so confirmation cannot be trapped behind
suspended input. Resize and mouse motion use bounded latest-value slots; a
button, key, paste, or protocol-response command first flushes earlier motion
into the ordered lane so coalescing cannot cross an ordering barrier.
Worker-to-UI paint publication is latest-value, while non-coalescible semantic
effects use a reliable low-volume path.

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

GPUI measures the selected font's glyph advance, ascent, and descent through
its text system. The measured cell width and line height are the single source
for rendering, grid dimensions, wheel scaling, and mouse hit testing. GPUI
publishes the latest resize containing sequence, grid, and pixel sizes; the
worker coalesces obsolete pending resizes and updates terminal state and PTY
winsize as one logical operation.

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

The Windows MVP instead verifies POSIX tmux inside WSL2. Host resolves
`wsl.exe` from the Windows system directory with `GetSystemDirectoryW`, never
through the current directory or launcher `PATH`, and carries that absolute
path through every command and attachment plan. Host constructs a fully
resolved invocation whose prefix is
`--distribution <name> --exec`, and whose absolute mux path and null config are
POSIX values such as `/usr/bin/tmux` and `/dev/null`. The invocation carries
`ExecutablePlatform::Posix`; the contract platform remains Windows because the
fixture executes where `wsl.exe` exists. WSL fixtures use a new strict fixture
ID and shape with an explicit executable-platform field. The existing psmux
fixture schema is unchanged.

All seven mux capabilities remain required even though the attach-only MVP
does not expose session creation. Host establishes command-only evidence on an
isolated WSL tmux server, then workspace supplies the real ConPTY admission
clients through `TerminalWorker`; terminal still receives only resolved argv
and never learns that WSL exists. The second `new-session -A`, the environment
positive control, and the `attach-session -E` proof therefore all run as
ordinary PTY clients rather than captured or control-mode processes. The
isolated session first adds a sentinel name to `update-environment`. A control
attachment without `-E` presents a conflicting client value and must change
the session environment; after the sentinel is reset, the same attachment
with `-E` must leave the session value unchanged. This positive control
prevents a broken attachment or irrelevant variable from looking like proof.
No `VerifiedTmuxBinary` exists until all live observations succeed; a failed
client fully unwinds the isolated server and leaves admission retryable.
Before the first probe session exists, host chooses a random private
`TMUX_TMPDIR`, installs its RAII cleanup guard, and creates the directory with
mode 0700; every command and ordinary admission client uses that socket root
in addition to `-L`. Installing the guard first makes cancellation cleanup
deterministic even when the WSL command completes without returning output.
Because terminating the Windows relay does not prove the Linux command has
stopped, uncertain creation repeatedly removes the path through a two-second
monotonic settle deadline, then performs a final removal and absence check;
ordinary settled cleanup removes it once.
Discovery, admission, and product attachment all execute through
`env -u TMUX -u TMUX_PANE` so launcher state cannot redirect socket selection.

VerifiedKwtHelper requires the exact revision, verified SHA-256, and
revision-scoped managed path.

Cached inventory identity is display-only. LiveIdentity has private fields and
can be produced only from a fresh, length-framed all-session query immediately
before a destructive operation. Host matches the decoded display name in Rust;
the name never crosses back into a tmux target expression. Conditional kill
then targets the captured session ID while comparing server PID, session ID,
and creation timestamp. Store cannot depend on the session crate and cannot
serialize runtime authority.

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
`unsafe_op_in_unsafe_fn = "deny"`. Two Windows-only modules may use narrowly
scoped `allow` attributes: terminal wraps `CreateJobObjectW`,
`SetInformationJobObject`, `AssignProcessToJobObject`, and `IsProcessInJob`
behind a safe RAII API, while host wraps `GetSystemDirectoryW` to resolve the
trusted WSL launcher. Every other module retains the workspace denial. The
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
├── host ───────→ session, config, model, contracts (development only)
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

The Windows Rust build cross-compiles that exact revision for the WSL
architecture with `tools/build_rust_kwt.ps1`. Cargo embeds the staged Linux
binary plus its SHA-256 and revision. Cargo tracks the configured staging path
even before it exists and accepts the helper only when its ELF machine matches
the selected Linux architecture and its bytes contain the pinned revision;
release builds fail if the helper is absent or invalid.
The host activates it at the POSIX managed-helper path with an atomic rename
and verifies both digest and reported revision before use. A process-local
cache remembers only the managed path: every operation revalidates the helper
before execution, and a missing or replaced helper is repaired atomically
before the requested KWT command runs. Developer builds may omit the bundle,
in which case KWT inventory alone is unavailable.

KWT project and worktree reads are a separate cancellable host operation from
tmux, Herdr, and Zellij inventory. The frequent session cadence never installs
the KWT helper, invokes KWT, or replays worktree reconciliation. One KWT
inventory read
uses exactly three machine-readable crossings: registered projects, the global
worktree list, and directory workspaces. After the admitted host first
publishes, Rust performs one background KWT read and then refreshes it every 60
seconds only while the window is active. A manual host refresh supersedes both
read generations. Failed or in-flight KWT reads retain the last usable project
tree and affect neither session availability nor terminal presentation.

The Projects header exposes **Add Project** whenever the current WSL host has
usable KWT inventory. The native folder picker accepts Windows folders and
`\\wsl.localhost\<distro>\...` paths; Ghosthub resolves drive paths through
that distro's `wslpath`, maps a matching WSL UNC path directly to its POSIX
path, and rejects a UNC path owned by another distro. An explicitly entered
POSIX absolute path remains supported. Registration delegates the resolved
path to the pinned helper's `projects add <path> --json` command. Each
registered project also exposes a confirmed **Remove Project** action. Removal
first re-reads project inventory, then invokes
`projects remove <exact-path> --expected-repository <credential-free-id>
--expected-registration <opaque-fingerprint> --json`; KWT performs the final
identity check against both values. Empty or missing registration fingerprints
are rejected as malformed inventory. Unregistration changes KWT
metadata only. It cannot delete the repository or worktrees and cannot stop or
kill tmux sessions. Ghosthub never scans WSL and never edits KWT configuration.

Project mutations use a serialized background lane distinct from GPUI and the
terminal worker. The last usable project tree remains visible while a command
runs. KWT's successful machine-readable mutation response is published
immediately; the broader project/worktree read then reconciles it. A failed
reconciliation cannot hide an add or resurrect a removal that KWT already
confirmed. A mutation supersedes only older KWT reads, and ordinary KWT
cadence waits for the mutation and its reconciliation to finish. Commands that
may already have crossed the process boundary are not cancelled or silently
retried. Every KWT command receives the same explicit `TMUX_TMPDIR` as tmux
discovery and attachment, so project session availability cannot be inferred
from a different server namespace.

The same serialized KWT lane now owns the first local worktree workflow.
Each registered project can load `branches --json` from its exact checkout and
create either a new branch (`add --branch`) or an existing local/remote branch
(`add`, optionally with `--from`) using `--no-launch`. After creation, Rust
refreshes authoritative KWT inventory and selects the exact repository,
worktree path, generation, and computed session name returned by that refresh.
The `add` invocation carries `--expected-repository` and
`--expected-registration`; KWT verifies those values against the selected
checkout while holding its project lifecycle lock before it mutates. A
replacement registration cannot inherit mutation authority from a cached row.
If the immediate post-create read is unavailable, Ghosthub retains the pending
project-and-branch identity and emits the normal created event when a later
authoritative inventory first resolves it. That event carries the navigation
generation that requested creation. It opens the worktree only while that
intent still owns the UI; later navigation or another dialog turns completion
into a notice instead of dismissing current work or changing presentations.
The UI thread performs none of those commands and keeps the previous project
tree visible throughout the operation.

Opening a worktree consumes no one-shot tmux creation authority. The terminal
launches the revision-pinned helper with the expected repository, registration
fingerprint, worktree generation, and computed session name. KWT reacquires
its project lifecycle lock, revalidates every identity, and only then repairs
or starts the exact tmux session. A separate Ghosthub preflight never grants
open authority. This is a
cloneable, deliberately re-runnable RepairOrOpen capability: KWT owns
probe/repair/bootstrap behavior and tmux continues to own the session. Directly
discovered unbound sessions remain strictly attach-only.
Once a worktree client resolves its live default-socket tmux identity, its
presentation key is normalized to that identity. The same client therefore
remains reusable when KWT later associates or disassociates the session with a
project. KWT-only validation failures retain the fresh host inventory and are
reported on the worktree action rather than disabling other multiplexers.

The Rust sidebar projects KWT-owned default-socket tmux sessions under their
project/worktree rows and removes only those exact sessions from the unbound
tmux group. Active and retained custom-socket presentations with an exact
current worktree owner remain accessible only from that row, whose live
indicator reflects the presentation; they do not claim a genuinely separate
default-socket session with the same name. Their navigation identity retains
the socket, worktree path, and generation. A standalone Kill Session action
queries that named socket for fresh identity before confirmation. Open actions
revalidate that same socket;
if current inventory no longer owns the exact presentation, its active or
retained client remains available as a fallback session row rather than being
hidden under a replacement worktree. A successful exact removal immediately
tombstones that path and generation in the cached tree before broader
reconciliation, so a KWT outage cannot resurrect an openable deleted row.
Before the removal dialog becomes actionable, a background query captures the
exact live tmux identity and socket when one exists. Confirmation consumes
that authority and terminates only the freshly confirmed tmux identity.
Ghosthub then invokes pinned KWT's absence-guarded removal; KWT revalidates the
project, registration, generation, and socket under its lifecycle lock and
requires the workspace session to remain absent before removing the checkout.
If the client exits and a same-named replacement starts, either the exact kill
or KWT's absence guard fails closed and the user must review the replacement.
KWT rows carry display identity and exact session names; they do not acquire
creation, repair, or destruction authority from cached inventory.

Pull-request import follows the same ownership boundary. The pinned helper is
the sole provider API for listing open pull requests and importing one into an
exact registered project. Ghosthub filters KWT's machine-readable title,
author, branch, number, URL, and draft fields for presentation, but passes the
selected candidate's opaque KWT selector back unchanged. Typed input is
accepted only as an exact loaded selector, a pull-request number, or a URL;
title, author, and branch searches remain filters and cannot be submitted as
selectors. An import is accepted only when KWT returns
the expected project path and a protected worktree with a generation, exact
session name, and nonempty tmux socket name. Ghosthub then refreshes
authoritative KWT inventory before publishing or opening that worktree; an
unavailable reconciliation reports scoped completion uncertainty rather than
inventing worktree authority from the request.

Protected pull-request worktrees use a distinct attachment capability. The
terminal launches `kwt pr attach` through the resolved argv plan, while the
workspace passes the exact project identity, registration fingerprint,
generation, session name, and socket back to KWT. KWT revalidates that
authority while holding its project lifecycle fence and before creating or
repairing the tmux session; the workspace repeats the checks after launch.
Readiness is confirmed by finding the spawned client PID on that protected
socket. A protected presentation never aliases or deduplicates with a
same-named session on the default tmux server. Protected removal uses the same
confirmed exact kill followed by absence-guarded KWT removal as default-socket
worktrees.
KWT's project lifecycle fence serializes that absence check with guarded
worktree session establishment, so a concurrent reopen prevents checkout
deletion.

Pull-request candidate discovery is an explicit user action and uses a
cancellable five-minute provider-operation budget because network and
credential-provider startup can legitimately exceed the 15-second local probe
deadline. Closing or superseding the dialog cancels the operation.

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

Windows Cargo builds embed and validate both the revision-pinned native KWT
controller and the Linux helper for the current architecture. The native PE
controller remains a packaged contract artifact, but it is not the Windows
product path for SSH leases: Windows OpenSSH does not provide the Unix-domain
ControlMaster socket required by KWT's persistent daemon lease. The product
therefore runs the Linux helper and `/usr/bin/ssh` inside the selected WSL
distro. The helper is activated under its existing content-addressed WSL path;
an existing file whose bytes or SHA-256 differ from the packaged bundle is
rejected instead of being replaced in place.

### KWT-owned SSH boundary

Rust does not reproduce OpenSSH configuration resolution, ProxyJump
expansion, host-key prompting, authentication prompting, or ControlMaster
lifecycle. On Windows, the host crate invokes the exact revision-pinned Linux
controller through system-owned `wsl.exe --distribution <distro> --exec` as
argv-only `kwt ssh resolve --json`; the matching `/usr/bin/ssh` in that distro
owns every master and client. Every controller and SSH command prefix checks
the captured WSL kernel boot ID and distro PID 1 start time inside that same
`wsl.exe` invocation before it executes the requested program. A distro restart
therefore invalidates route resolution, lease acquisition, inventory, refresh,
and terminal attachment instead of allowing evidence from the prior runtime to
authorize its replacement. The selected distro's OpenSSH configuration,
known-hosts files, agents, and credentials are authoritative. There is no
fallback to native Windows OpenSSH, a masterless KWT lease, or an unguarded
direct SSH client. The host accepts only projection policy
`kwt.openssh.projection.v1`, and treats its route identity and ordered target
list as one immutable reviewed snapshot. Owner-private projection lines may be
retained in memory for validation but are redacted from Rust debug output and
never reconstructed by Ghosthub.

Connection establishment uses the matching long-lived `kwt ssh lease --json`
operation bound to that route identity and projection policy. Its NDJSON
stream must retain one operation ID, contiguous sequence numbers, exact
prompt-to-hop attribution, and one terminal result. Host-key prompts are
non-sensitive and display KWT's structured host, algorithm, and fingerprint;
authentication prompts are sensitive. Both retain KWT's deadline and exact
logical, effective, and display target. A changed route,
unsupported masterless result, malformed event, or attribution mismatch fails
closed.

A successful lease exposes only generation-bound OpenSSH arguments. The host
owns the KWT lease process and keeps it alive for as long as any presentation
uses the connection. Closing the final owner closes stdin and waits a bounded
interval for release; cancellation or protocol failure terminates the
controller process. While the host is Ready, workspace event polling checks the
controller without blocking. An unexpected exit consumes the lease, contains
remaining descendants off the UI thread, discards the remote runtime context,
and publishes a host-scoped unavailable diagnostic before another SSH command
can reuse its arguments. The terminal crate never names KWT, parses a route, or
answers an SSH prompt. It receives only the resolved client program and argv
from a later host-built attach plan. On Windows that program is the absolute
system `wsl.exe`, followed by the selected distro, the runtime guard,
`/usr/bin/ssh`, the reviewed lease arguments, and the remote command. Ghosthub
accepts the pinned KWT lease result only as an option-only `-F`/`-o`/`-S`
prefix, then appends the reviewed logical destination exactly once before the
remote command. Lease authority is runtime-only and is never serialized.
Cancelling or failing a connection refresh discards that host's stale runtime
context and lease before publishing `Disconnected` or `Unavailable`; retained
terminal presentations keep only their own explicit lease ownership.

The first Rust remote-host slice exposes this boundary through a native
Settings shell modeled on the Swift app. The shell owns stable domain
navigation plus a consistent page header and detail area, so later settings
panes extend the container rather than replace it. Hosts is the first
implemented pane: its host list and selected-host editor add, edit, or remove
a named POSIX SSH endpoint with an optional user and port plus optional
absolute tmux and `TMUX_TMPDIR` overrides. Tmux, Herdr, and Zellij otherwise
resolve through the remote account's login environment. Saving rewrites only
the Rust application configuration. Each configured endpoint appears as a
disconnected host and connects only after an explicit Connect action; merely
starting Ghosthub or opening Settings never opens a network connection.

Connect resolves the route and acquires its KWT lease on a background host
lane. KWT host-key and authentication prompt events are presented by GPUI
with their exact display target and message. Authentication input is masked,
kept only until the one-shot response is sent, and never persisted or logged.
Cancel closes the prompt, cancels the host generation, and returns that host
to disconnected state without affecting WSL or another SSH host. A changed or
late prompt generation is rejected rather than applied to a replacement
connection.

After admission, Host independently discovers tmux, Herdr, and Zellij inventory
through the same reviewed lease. A missing or failed backend is backend-scoped
and never disables the host or hides another backend; configured tmux failures
remain visible beside the tmux group so its path can be corrected. Tmux
attachment retains exact server PID, session ID,
and creation-time authority. Running Herdr and active Zellij rows build their
ordinary attach-only client argv after scrubbing inherited backend routing
variables. Terminal launches each resolved client through ConPTY and remains
unaware of WSL, KWT, routing, SSH configuration, or multiplexer selection.
Before any remote tmux, Herdr, or Zellij client is launched, Host verifies the
remote terminfo database and selects `xterm-256color` when available, otherwise
the verified `xterm` baseline. Attach and constructive paths use that same
selection, and the reduced-color notice is published only after a fallback
client is successfully presented.
Each host's tmux, Herdr, and Zellij groups have independent disclosure controls;
collapsing navigation never detaches a client or changes session lifetime.

The current remote UI supports discovery, attach-only presentation, retained
switching, detach, one-shot Herdr creation/restart, and one-shot Zellij
creation. Constructive operations re-probe the backend through the existing
reviewed lease before launch, publish only an exact post-launch inventory
match, and run entirely off the UI thread. It deliberately withholds remote
tmux creation, tmux/Zellij kill, Herdr stop/delete, worktrees,
reconnect/backoff, and restoration until each operation has fresh remote
identity and lifecycle fencing. An absent control cannot silently fall back to
WSL or unguarded SSH.

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

UI responsiveness is a hard architecture invariant. GPUI activation, input,
painting, and snapshot reads never execute host commands, filesystem probes,
database transactions, Kwt reconciliation, or resource sampling. Host reads
and future project/worktree inventory merges run on cancellable background read
lanes. They build owned results before entering the short publication section;
no snapshot publication guard may cross external I/O, process waits, or an
await point. Runtime-only tmux, Herdr, or Zellij updates cannot replay
project/worktree reconciliation. Each host publishes independently, so one
slow host cannot delay completed inventory from another host.

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

The first executable milestone opens a native Windows GPUI shell independently
of WSL, then discovers and attaches to an existing tmux session in one resolved
WSL2 distro when the system WSL launcher is present. It detaches without
destroying the session. The shell contains a synthetic host list, a minimal
discovered-session view, one visible terminal presentation, a visible
cancellable WSL startup state, and host-scoped retryable diagnostics.

The Windows application shell keeps host and session navigation mounted while
a terminal presentation is active. A workspace retains the ordinary client,
worker, and surface for every presentation it explicitly opens. Selecting a
different discovered session hides the current surface without detaching its
client. A first visit captures the target from current inventory and performs
the normal fresh-identity attachment check; returning to an open session
remounts the retained surface synchronously. Retained entries are keyed by the
exact host, resolved endpoint, socket directory, session, and live identity.
Explicit close detaches only the selected presentation, and application
shutdown detaches every retained client. Navigation never sends a mux kill
command. The chrome is shaped for additional admitted local mux hosts, but
The initial slice exposed only WSL tmux; optional WSL Herdr and Zellij groups
now use the same shell and retained-presentation boundary. Psmux remains
rejection evidence until it satisfies the same capability bar.

The active presentation keeps a detach action that only closes its ordinary
client. Every session in the current live inventory separately exposes Kill
Session, including sessions that are not open. Kill performs a fresh WSL
runtime and tmux identity query before showing confirmation for the exact
endpoint. Approval carries that non-persistable authority into one tmux
conditional that compares server PID, session ID, and creation time, then
kills by the captured stable session ID only on a match. Cancellation changes
nothing; lookup, runtime, identity, and command failures leave the presentation
open. A successful kill removes only the matching active or retained
presentation and refreshes inventory. Kill completion rechecks the active
identity under the navigation lock before detaching, so a concurrent switch
cannot close an unrelated presentation. This action never shares the ordinary
detach path. Cached rows remain visible while a host is unavailable, but only
retained presentations can be reopened until the host reconnects.

The Windows shell draws one compact title bar in the same visual plane as the
application chrome. It retains the native window controls and dynamic
session/endpoint title, and exposes a sidebar button there. `Ctrl+Shift+B`
toggles the sidebar without consuming tmux's `Ctrl+B` prefix; terminal geometry
and pointer mapping update with the visible content area. Sidebar host entries
use one compact line for the logical host name; distro configuration is not
duplicated beneath it and remains visible only in endpoint-relevant contexts.

The flow resolves and verifies the exact mux binary, discovers live identity,
reserves the presentation, and launches an AttachPlan whose single tmux
`if-shell -F` command atomically compares server PID, session ID, and creation
time before its matching branch executes `attach-session -E`. It then promotes
the reservation, renders through surface, disconnects on close, and reattaches
to the surviving identity from a fresh process. An identity mismatch exits
without attaching and becomes a classified refresh diagnostic.

The same local WSL slice exposes explicit bare-session creation from the host
tree. The dialog applies the shipped 1-100 character tmux-name rules,
additionally rejects `#` before it can reach tmux format evaluation, and
rejects names already present in current inventory. Discovered sessions are
unaffected and remain attachable by live identity. Its title, validation copy,
terminal-marked input, and compact actions present only task-relevant content;
distro and lifecycle explanations are not shown in routine workflow chrome.
The dialog
pins its selected WSL endpoint and remains usable while that already-admitted
host performs a background inventory refresh; a disconnected, unavailable, or
changed endpoint must be selected again. Workspace performs one
fresh admitted-host read, terminal consumes a non-cloneable CreateOnce whose
ordinary client executes `new-session -A -E -s <name>`, and host captures the
resulting runtime, server, session ID, and creation time from a nonce-scoped
private WSL receipt written by the same tmux command queue. The receipt is
written by an explicit `/bin/sh -c` command rather than tmux's configurable
default shell, is opaque outside host, is removed after capture, and never
crosses ConPTY or the VT. Admission proves
`xterm-256color` on that same atomic client shape before caching it for
creation; if the distro lacks that terminfo entry, admission proves `xterm`
instead and creation immediately displays the reduced-color notice. Creation
never retries after consuming its authority. From that point the presentation
holds only attach authority. A race that creates the same name
after validation attaches to that exact existing session without changing its
layout. A failure after launch may detach and report the result but never
reruns creation or kills the session. Until promotion to attach authority,
workspace navigation owns a cancellable pending-creation reservation; choosing
another session or detaching restores navigation immediately and invalidates
the background task without gaining authority to destroy any session it may
have created.

Slice 1 reads font family, font size, and theme through:

~~~text
config → workspace projection → UI-facing state → GPUI
~~~

The Settings shell exposes durable Appearance and Hosts panes. Appearance edits
the validated terminal font and default colors, previews the draft, persists
the complete configuration atomically, and publishes the saved projection to
the running GPUI workspace. Existing terminal clients keep the palette they
negotiated until reopened; new clients use the saved defaults. Hosts owns only
`[[ssh-host]]` records. The shell's stable navigation, page header, list, and
detail regions are the permanent container for the remaining Swift settings
domains.
The parity inventory is:

| Swift domain | Rust state |
| --- | --- |
| Hosts | Native add, edit, remove, explicit connect, and SSH prompt UI |
| Appearance | Native font and default-color editor with preview and atomic persistence |
| Terminal | Startup configuration only; pane not yet implemented |
| Keyboard | Runtime shortcuts exist; pane not yet implemented |
| Worktrees | Project/worktree workflows exist; preferences pane not yet implemented |
| Agents | Not yet implemented |
| Privacy | Clipboard policy exists in configuration; pane not yet implemented |
| Integrations | Not yet implemented |

Adding the remaining panes extends the existing shell rather than replacing
it. WSL configuration remains startup-only until its settings surface lands.

Read-only configuration may select a distro name, an absolute POSIX tmux
binary, and an absolute POSIX `TMUX_TMPDIR`. Defaults are the current WSL
distro, `/usr/bin/tmux`, and tmux's own default socket resolution. Ghosthub
does not source interactive or login shell files in this slice. Users whose
sessions use another binary or socket directory must configure it explicitly;
the empty state names the resolved distro and whether the default or configured
socket environment was queried.

The Rust app reads `<resolved config root>/config.toml` at startup and rewrites
it atomically when supported Settings panes save changes. A missing file uses
defaults; malformed TOML, unknown fields, relative WSL paths, empty names, zero
font size, and non-`#RRGGBB` colors produce a visible startup diagnostic rather
than silent fallback. The schema is:

~~~toml
[wsl]
distro = "Ubuntu"
tmux-binary = "/usr/bin/tmux"
socket-directory = "/run/user/1000/tmux"

[terminal]
font-family = "Cascadia Mono"
font-size = 14
background = "#0c0f14"
foreground = "#d8dee9"
clipboard-write = true

[[ssh-host]]
name = "Studio"
hostname = "studio.example"
user = "wesm"
port = 22
# Optional: otherwise resolved through the remote login environment.
tmux-binary = "/opt/homebrew/bin/tmux"
socket-directory = "/run/user/1000/tmux"
~~~

Every WSL and terminal field is optional. SSH host name and hostname are
required, while user, port, tmux path override, and socket directory are
optional. Ghosthub resolves tmux, Herdr, and Zellij through the remote login
environment by default; an explicit tmux path remains available for unusual
installations. SSH endpoint identity is user, hostname, and port; duplicates
are rejected. `clipboard-write` governs remote OSC 52 writes; remote OSC 52
reads remain denied regardless of configuration.

Windows manual acceptance requires WSL2 and tmux. Ghosthub can create the first
session itself; setup remains documented as deterministic commands for tests
that exercise discovery of an externally created session. A missing server is
an empty inventory, not an error.

The milestone proves:

- GPUI paints the selected VT backend through scroll-aware surface buffers
- keyboard, SGR 1006 mouse reporting, AltGr, and bracketed paste work
- ordered resize and stale-frame letterboxing work
- buffers remain bounded and UI never blocks on PTY or store work
- reselecting the same session in one window refuses a second client and
  focuses the existing terminal as Ghosthub policy rather than a tmux limit
- explicit local creation consumes one atomic `new-session -A` authority,
  publishes the fresh live identity, and survives detach without rerunning
  creation
- client close, graceful app exit, and forced app death preserve the server
  and permit fresh-process reattachment to the exact same live identity
- failed relay-job membership fully unwinds the spawned attachment before the
  reservation is released and a diagnostic appears
- the genuine ConPTY attach proves `attach-session -E`, and TTY plumbing
  failure cannot be recorded as a missing mux capability
- `TERM=xterm-256color` works end-to-end or the initial attach retries once
  with `TERM=xterm` and displays a reduced-color notice

Cross-window focus arbitration is deferred until multi-window delivery.

Slice 1 includes policy-controlled OSC 52 writes to the Windows clipboard,
empty responses for remote OSC 52 reads, and explicit clipboard paste with
bracketed framing. It excludes IME composition, dead keys,
kwt inventory, worktree mutation, SSH reconnect and remote lifecycle,
managed-helper installation, native Linux product UI, persistence/restoration, multiple
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
- cargo test-wsl-kwt-live installs and verifies a staged pinned KWT helper and
  reads its real inventory
- `make rust-test-wsl-live` launches real isolated tmux servers inside a WSL2
  distro plus PTYs and supervisor children for detach and app-death survival;
  it also creates, detaches, reattaches, and explicitly kills one nonce-named
  Zellij session without touching other Zellij sessions

Cargo test binaries own cross-platform orchestration. Make targets are thin
wrappers; Windows CI invokes the same Cargo tests without POSIX shell
scaffolding. Windows tests use a unique WSL tmux socket namespace and assert
before and after each run that the user's default server is untouched.

The live gate runs separately from ordinary pull-request CI on a Windows x64
runner in the dedicated `ghosthub-wsl-acceptance` group. That runner must have
a usable WSL2 default distro, `/usr/bin/tmux`, and the Windows Rust build
toolchain. The group's GitHub settings permit only the canonical repository
and the exact `rust-wsl-live.yml` workflow.

The workflow is manual-only. It rejects every repository and ref except
`kenn-io/ghosthub`'s `rust-port` integration branch, then explicitly checks out
the immutable dispatch SHA. It never executes feature-branch or fork code on
the persistent runner. Feature changes run `make rust-test-wsl-live` on an
isolated developer machine before merge; after merge, the trusted integration
SHA receives the GitHub acceptance run. A successful live run is required
acceptance evidence for changes to WSL attachment, creation, guarded kill, or
client-lifetime behavior, and for KWT helper provisioning or inventory.

GitHub-hosted Windows runners remain the fast compile, unit, contract, and lint
gate because their installed WSL tooling does not guarantee a usable WSL2
distro or nested virtualization.

The Rust port adds no Swift or macOS live-attach work. Linux compilation is not
used as evidence for the Windows ConPTY-to-WSL relay path.

### Follow-on order

After Slice 1:

1. Local Ghosthub inventory and ordinary worktree RepairOrOpen now ship with
   pinned bundled kwt, project/worktree inventory, branch-backed creation,
   generation-guarded confirmed removal, and unbound reconciliation. Removal
   preserves the Git branch and terminates a live tmux session only through a
   freshly captured exact identity.
2. Local pull-request import and protected worktree attachment now ship through
   the pinned KWT provider contract and protected socket identity. Plain local
   session creation already ships through CreateOnce in the WSL slice.
3. Remaining local work adds project settings, Console Panel, and broader
   command and accessibility surfaces.
4. Remote POSIX host settings, explicit connect, KWT-owned prompts, tmux plus
   optional Herdr/Zellij inventory, and attach-only presentation now ship.
   Follow-on remote work adds identity-fenced lifecycle operations,
   managed-helper installation, transport reconnect, repair/open reconnect,
   worktrees, and remote Windows.
5. Persistence and restoration add the coalescing writer, host settings,
   attach-only descriptors, bounded pending restoration, and inventory-only
   cold-start reconciliation.
6. Product completion adds multi-window behavior, Console Panel, settings,
   command palette, themes, accessibility, notifications, packaging, and
   release gates.

No later stage may weaken detach-only session lifetime, exact targeting,
capability-based launch authority, or the rule that reconciliation forgets
records but never kills server state.
