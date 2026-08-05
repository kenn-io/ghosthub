# Terminal Sessions

Terminal behavior is the highest-risk part of Ghosthub. The app must behave
like a normal macOS terminal while remaining isolated from Ghostty.app
configuration and launcher-terminal environment.

## Product Boundary

Ghosthub is a native session switcher for tmux servers across the local Mac
and configured SSH hosts. There are two inventory sources:

- **kwt workspaces:** projects and worktrees read from kwt's supported JSON
  commands, including each worktree's exact `session_name`.
- **unbound sessions:** every other session returned by direct `tmux
  list-sessions` discovery on the host.

Both open through the same ordinary tmux client in one libghostty surface. A
session created by Middleman is visible when it exists on the host tmux server,
but Ghosthub does not consult Middleman to identify, create, attach, mutate, or
destroy it.

Ghosthub may also create one ordinary session when the user explicitly chooses
New Tmux Session for a host. This is not a separate managed-session type: the
result immediately joins the same direct tmux inventory and has the same
detach-only presentation lifecycle as every other session.

The planned Rust/GPUI Windows and Linux applications preserve this boundary.
Their detailed backend, worker, surface, capability, and delivery design is in
[Windows and Linux Rust Port](rust-port.md). This page remains authoritative
for ownership, reconnect, detach, and restart semantics on every platform.

## Native Tmux Attachment

Ghosthub invokes `tmux attach-session -E -t =<name>` for a local session. A
remote POSIX session uses the same tmux command through OpenSSH. An
experimental native Windows host invokes psmux's `tmux.exe` compatibility
alias through an encoded Windows PowerShell command and the same exact session
target. There is no
`tmux -CC`, pane capture, history replay, silent rendering child, Swift pane
map, split-tree projection, or Ghosthub tab bar. Tmux owns:

- windows, panes, layout, focus, and status-line presentation
- terminal history and alternate-screen state
- pane processes and session lifetime
- tmux-native key bindings and mouse behavior

Ghosthub owns only inventory presentation, the disposable terminal client,
and connection state. Navigating away, pressing Cmd-W, closing a window, or
quitting Ghosthub detaches the client and never destroys server-side state.
The separate Kill Session action is the only destructive lifecycle operation.
It is offered only when direct discovery or a currently connected active
attachment establishes that the session is running. Before displaying
confirmation, Ghosthub captures tmux's server PID, `session_id`, and
`session_created` values together with the exact local or SSH endpoint, socket,
and session name. Termination uses one tmux conditional command that compares
all three live identity values and invokes `kill-session -t =<name>:` only on
a match. The server PID distinguishes tmux server generations, while the
monotonically assigned session ID distinguishes same-named replacements within
one server even when their second-resolution creation timestamps match. A
replacement session is therefore never killed under stale cached inventory or
a disconnected attachment. Ghosthub detaches an active client only after that
command succeeds, so a failed lookup, SSH connection, identity check, or kill
leaves the presentation open. After success it rechecks the active attachment,
closing that exact current selection and navigating away only if it is the
killed target.

Ghosthub applies the selected Tmux Theme when it creates a new bare tmux
session. A built-in palette supplies its configured colors. Follow ghostty.conf
instead uses the effective foreground and background resolved by libghostty for
the current macOS appearance, including conditional light and dark themes.
Existing sessions retain their own appearance by default: Ghosthub neither
places a client-local palette over them nor changes their tmux options.

Users may enable the persistent shared-session override. On each future
attachment, that override resets the exact session's `status-style`,
`message-style`, and `message-command-style` to terminal-default colors and
sets each existing window's default foreground and background. A built-in
palette is applied within the attach command itself; kwt-backed workspaces
style after kwt's own client attaches. Follow ghostty.conf colors only exist
once the new surface publishes its resolved state, so Ghosthub applies them
one-shot and best-effort shortly after the attachment connects, verifying the
session's identity first. **Session -> Apply Theme to Current Session** and the
matching command-palette action apply the selected effective style immediately
to the connected active workspace tmux attachment without changing the
persistent preference or reconnecting. Console Panel terminals are not tmux
session targets. Both paths change shared tmux options, so every attached client
sees the result. These best-effort style commands do not change tmux interaction:
prefix and key tables, mouse behavior, windows, panes, history, and layout
remain untouched.
Native Windows attachment leaves psmux's status and message styles user-owned;
psmux does not preserve tmux's session-scoped rendering for these style resets
and may apply `reverse` across the client rather than only its status line. The
persistent override and one-shot action are therefore unavailable for native
Windows sessions.

## Rust Client Lifetime and Application Death

The planned Rust applications use the same ordinary-client boundary. The first
product slice is a native Windows GPUI client attaching to tmux inside WSL2;
Linux remains a compile-and-contract target until its native product slice is
authorized. A terminal worker and PTY own only the disposable client. The WSL
tmux server owns session lifetime and must survive client close, graceful
application exit, and forced Ghosthub termination.

Launch authority is structural:

- an attach plan is cloneable and cannot create
- one-shot creation is neither cloneable nor serializable and is consumed into
  an attach plan
- kwt repair/open authority is cloneable only because its documented
  probe/repair operation is intentionally safe to rerun

Local client exit always detaches and never reconnects. Only remote OpenSSH
status 255 enters transport reconnect. Bare remote creation becomes
attach-only before that loop; ordinary and protected kwt paths retain only
their explicitly documented repair/open behavior.

Psmux 3.3.7 failed the required exact-kill proof and never established genuine
ConPTY `attach-session -E` behavior. Its probe remains rejection evidence, but
it is not the Rust Windows substrate. The Windows MVP uses real POSIX tmux in
WSL2 and never degrades to psmux or an app-lifetime session.

That failed proof exercises `kill-session -t =name`. The experimental Swift
remote-Windows path instead resolves the exact target and fresh identity before
killing by session ID. Its complete conditional-kill flow remains subject to
isolated end-to-end psmux verification; the Rust rejection does not by itself
establish false success in the shipped path or make that path dead code.

The tmux server lives inside WSL2 and cannot inherit a Windows Job Object.
Ghosthub intentionally puts only the disposable `wsl.exe` ConPTY relay in an
application-owned `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` job and verifies its
membership with `IsProcessInJob`. This is client containment, not server
breakaway. If job creation, assignment, or verification fails after spawn,
Ghosthub closes the PTY master, waits a bounded interval, applies the
client-only termination fallback if required, releases the presentation
reservation, and only then reports failure.

Live integration tests supervise a child presentation/application, terminate
it gracefully and forcibly, then launch a fresh child and reattach to the same
WSL runtime, server, and session identity. Windows uses an isolated WSL tmux
socket namespace, TerminateProcess, and a client-only kill-on-close Job Object.
The test also proves that the Linux-side tmux client is reaped and that the
user's default server was never queried or mutated.

The guarantee covers Ghosthub termination, not `wsl --shutdown`, distro
termination, or a Windows lifecycle event that restarts WSL. Runtime identity
combines the kernel boot ID with PID 1 start time so a distro-only restart is
classified even while another distro keeps the shared kernel alive.

## Relaunch Restoration

Quitting Ghosthub or installing an update only drops disposable clients. When
macOS restores workspace scenes, Ghosthub resolves each scene's stable logical
descriptor against current inventory and uses attach-only restoration; it
never creates a missing session or falls back to a same-named target on a
different host or socket. Worktree identity is the durable generation reported
by kwt, so removing and recreating a worktree at the same path cannot inherit a
saved presentation; a missing generation restores only as far as the project.
Once a worktree presentation has observed a generation, incomplete inventory
cannot erase it and a different non-nil generation is treated as a replacement;
explicitly reselecting the worktree detaches the observed presentation and
attaches the replacement session.
For **Install and Relaunch**, Ghosthub also writes a one-shot ordered window
manifest under `~/.ghosthub/` before Sparkle terminates the app. On the next
launch, Ghosthub collects initial and late native scene values until AppKit
reports that native window restoration has finished and every restored workspace
window has registered its SwiftUI scene. Ghosthub waits for binding quiescence
before unresolved scenes receive provisional unclaimed descriptors, then opens
every saved window still missing. Later native descriptors correct provisional
assignments, including by moving a displaced session to a provisionally opened
replay scene. Replay requests use distinct scene tokens so SwiftUI cannot satisfy
them with a late native saved window, and displaced requests are explicitly
reissued. This covers absent or partial macOS restoration without swapping
sessions between restored geometry or tab groups. The manifest is removed only
after every saved window has begun attach-only restoration in one live assigned
scene; native scene restoration still supplies geometry and tab grouping when
available. Once assigned, the scene model's complete logical descriptor replaces
any delayed same-ID native payload with stale navigation or tmux data.
An ordinary local session must be present in direct discovery before Ghosthub
runs the exact `attach-session` path. Remote sessions use that same rule and,
after a confirmed attachment, Ghosthub's native reconnect supervisor owns any
transport recovery.
Offline or otherwise unavailable targets remain pending and retry when normal
inventory refreshes publish new state. Navigating the window elsewhere cancels
the pending target. If a scene was captured without an active tmux
presentation, Ghosthub restores its host, project, and worktree navigation but
does not open or create the worktree session until the user explicitly selects
it.

The Rust cold-start Reconciler consumes only inventory generations already
published by host read lanes. It cannot probe a host, invoke kwt, run
tmux/psmux, or derive liveness independently. It may forget or mark Ghosthub
records stale and remove presentation metadata; it can never destroy a server
session. Pending automatic restoration also expires after three completed
failed refreshes, ten minutes, or user navigation, whichever comes first.

A protected worktree is distinct from a same-named session on the default tmux
server. Restoration first probes the descriptor's exact host, protected socket,
and session name. Only a successful probe may delegate attachment to `kwt pr
attach`, which remains authoritative for validating and repairing that
workspace before executing the ordinary tmux client. The session can still
disappear between Ghosthub's probe and kwt's command; eliminating that benign
race requires a future atomic kwt attach-only contract. Ghosthub does not use
the default server as a fallback when the probe is absent or fails.

The host-scoped console surface is outside workspace scene restoration and is
reopened by the user. Restoring one session into multiple windows preserves
the same tmux-native shared-presentation behavior that existed before quit;
the broader collision and console policy remains tracked by kata `s75s`.

Explicit local creation uses one atomic `new-session -A` create-or-attach
client invocation. This closes the detached-session race when the user's tmux
server has `destroy-unattached` enabled. Explicit remote creation performs a
one-shot `has-session`/detached `new-session` phase before ordinary attachment.
The remote process then performs one ordinary attachment. If that client later
loses its transport, the native reconnect supervisor can only launch another
attach-only client; it can never rerun creation. The session name is validated
before launch and passed as one shell-quoted argument. If the exact name
already exists, it is attached without creating or structurally changing panes
or windows.

Kwt inventory includes every worktree, whether or not its canonical tmux
session is live. When the managed helper is available, Ghosthub therefore
executes `kwt open <exact-path>` as the initial attached tmux client. Kwt
idempotently repairs an existing session or creates the configured layout when
it is absent, without an intermediate detached session that
`destroy-unattached` could remove. Ghosthub uses this path even when cached
discovery contains the canonical name, because the session may have exited
since the sample. If the managed helper is explicitly unavailable, a cached
discovered session remains usable through ordinary `tmux attach-session`. On a
remote host, only an SSH transport loss can hand a kwt-opened session to
Ghosthub's native recovery supervisor. Ghosthub first probes the exact session:
confirmed presence advances to ordinary attachment, while confirmed absence
reruns `kwt open` only if the interrupted establishment was never confirmed.
Once attachment is confirmed, every later recovery remains attach-only. On
POSIX hosts, every remote tmux phase (creation,
attachment, open, and probe, styled or not) runs through the account login
shell so settings such as `TMUX_TMPDIR` resolve the same tmux server as later
styling and identity commands. On Windows, those phases use encoded
PowerShell commands within the same OpenSSH account environment. Unbound
discovered sessions remain attach-only.
Ghosthub does not expose rename, split, resize, window, or pane operations.
Kill Session is exposed separately from presentation only for a session known
to be running and always requires confirmation.

Native Windows creation also supplies the SSH account's process `PATH` through
psmux's `new-session -e` contract. Psmux otherwise starts detached panes
without the user-level path entries visible to Windows OpenSSH, which prevents
tools installed under locations such as `.local\bin`, WinGet links, or the npm
prefix from resolving. This applies only while creating a session; attachment
does not modify an existing session or running pane.

The requested session appears optimistically so transient SSH or discovery
latency cannot remove the user's only way back to it. Direct `list-sessions`
reconciliation begins only after the terminal runtime accepts the creation
command and uses bounded backoff. The optimistic entry remains while that
command is alive; authoritative absence retires it only after retries are
exhausted and the command has ended. Once confirmed, the active presentation
and all later retries are demoted to attach-only. Pending probes are scoped to
the resolved host endpoint and cancelled when that endpoint changes or the
owning window shuts down.

Before discovery or attachment, Ghosthub resolves an absolute tmux-compatible
binary path and verifies the reported tmux protocol version is 3.2 or newer.
On POSIX hosts the login shell initializes its environment, then delegates
Ghosthub's probe to `/bin/sh`; fish and other non-POSIX account shells never
interpret the POSIX probe itself. On Windows, Ghosthub starts noninteractive
Windows PowerShell and resolves `tmux.exe` with `Get-Command`.
Successful paths are cached per host; lookup and version failures remain
retryable and are presented to the user.

## SSH Keepalive and Reconnect

Remote clients use the user's OpenSSH configuration and add server keepalives.
If OpenSSH requires interactive authentication, Ghosthub shows its challenge
in a native secure-entry sheet and passes the session-only response through a
private FIFO. Later inventory and tmux clients reuse that app-session control
connection and remain noninteractive. Every control connection is named for
one app launch and supervised by a parent-held descriptor that stays open for
the app lifetime, so an app crash terminates the SSH master and a later launch
cannot reuse its socket.
Remote attachment and establishment shell commands are one-shot: they contain
no retry timing and never print reconnect status into the terminal buffer.
The local wrapper around each complete remote command records its final status
in an app-owned, per-attachment temporary file before it exits. The native
coordinator consumes that status instead of relying on libghostty's outer macOS
login process, whose reported status may be zero even when nested OpenSSH
exited 255.
After a confirmed attachment exits with OpenSSH's transport/setup status 255,
the scene's native supervisor probes the real SSH and tmux path at attempt-start
intervals of 1, 2, 4, 8, 16, and then 30 seconds. Each probe has a 15-second
end-to-end deadline; its runtime counts against the interval, and an overrun
clamps the next delay to zero. Attempts never overlap. **Reconnect Now** wakes
the same supervisor immediately instead of starting a parallel path.

Default-socket recovery shares the host's in-flight `list-sessions` probe with
inventory discovery. Protected sockets use a headless
`tmux -L <socket> has-session -t =<name>` probe so an unsuccessful attempt never
creates or flashes a terminal surface. Confirmed presence launches one new
attach-only client. Confirmed absence ends a default-socket or protected-socket
presentation only when that exact session had already been established; an
unconfirmed interrupted kwt establishment may rerun its one-shot creation path.
A reachable non-transport tmux failure is presented as unable to attach rather
than retried indefinitely. A clean detach does not start recovery.

Transport failures continue retrying automatically, with no more than 30
seconds between attempt starts. Authentication and host-key review failures
pause automatic retry and open the existing native recovery flow. Successful
recovery resumes the same supervisor. If SSH is already reachable when that
flow checks again, **Retry** resumes the supervisor as well as refreshing host
inventory. Only the recovery flow opened for that active tmux request may
resume it; authentication started from ordinary host inventory never reopens a
session. Dismissing it leaves an honest
**Connection needs attention** presentation with **Review Connection** when
native review is available; reopening that review retains the active recovery
request and can resume its supervisor after success. **Host Settings** remains
the fallback otherwise. A changed known-host
identity still requires the explicit known-hosts remediation described by that
flow; Ghosthub never silently accepts it.

A direct connection's OpenSSH `LocalCommand` writes a private marker after
transport and authentication succeed. Host verification emits a marker only
after the remote command begins. Status 255 and local wrapper failures such as
an unconfirmed timeout leave the host offline; a nonzero login-shell or
probe-command status is reachable and degraded only when that marker proves the
remote account executed the probe.

The initial psmux path allocates an ordinary SSH PTY and targets Windows 11
build 22523 or newer. Older ConPTY builds preserve keyboard input but consume
psmux mouse-reporting sequences; supporting them would require the separate
psmux `ssh -T` wrapper and is not part of this experiment.

Tmux remains alive on the remote host while the network is unavailable. After
connectivity returns, the client reattaches to the same exact session and tmux
renders its authoritative state. Copy-mode and programs on configured remote
hosts may write the Mac clipboard through OSC 52 when allowed by the user's
`clipboard-write` configuration, so remote tmux copy behaves like local tmux
copy. Remote terminal surfaces cannot read the local Mac clipboard through
OSC 52, regardless of `clipboard-read`. libghostty exposes the semantic type
of every clipboard request: Ghosthub supplies clipboard contents only for a
configured `paste_from_clipboard` action, independent of which key triggers
it. libghostty retains bracketed-paste framing and requires confirmation before
unsafe unbracketed text can reach the PTY.

## Inventory and Startup

At startup Ghosthub loads kwt project/worktree inventory and tmux session
inventory for every resolvable host. The initial content view remains in an
explicit loading state until kwt returns, so the empty onboarding state never
flashes before existing workspaces are known. That loaded empty state is
informational: kwt owns project registration, and Ghosthub does not expose a
retired repository-intake path as a nonfunctional substitute.

Inventory degrades per host. An unavailable remote host retains its cached
inventory and exposes a clickable detail warning on that host without blocking
the rest of the workspace. The detail offers a retry and a shortcut to Host
Settings; OpenSSH status 255 is reported as an SSH connection failure instead
of a login-shell or tmux failure. Remote hosts where Ghosthub's managed kwt is
absent remain available for direct tmux discovery and attachment. Inventory
never uploads the helper. The user grants permission with **Install kwt
Worktree Helper** in Host Settings, after which inventory and protected
attachment execute its exact revisioned path. On macOS and Linux, a fresh
helper has an empty project registry: **Add Project** in the host's **+** menu
passes one user-supplied absolute checkout path to kwt's noninteractive
registration command, then refreshes inventory. Immediately before
registration, Ghosthub re-resolves the host ID and rejects the operation if its
endpoint changed while Add Project was open. No filesystem scan occurs.

On experimental Windows hosts, an explicit Install Bundled kwt action probes
the process architecture, uploads the matching pinned AMD64 or ARM64 helper,
verifies its SHA-256 and exact revision, and activates it at
`%USERPROFILE%\.ghosthub\helpers\kwt\<revision>\kwt.exe`. Inventory and
workspace operations use only that exact per-user helper and never resolve
`kwt.exe` from `PATH`.
Project registration is not yet supported on Windows, so its Add Project
actions are hidden. Discovery never installs or updates remote software
implicitly.

Kwt session names are removed from the generic session group and rendered
under their project/worktree. Every remaining tmux session is eligible for the
host-level session group. Case-sensitive `*` and `?` wildcard patterns in
`hidden_session_patterns` under `[tmux]` inside
`~/.config/ghosthub/config.toml` hide matching standalone sessions from the
sidebar and command palette. Settings → Worktrees edits the same list, one
pattern per line. Filtering occurs after discovery and never suppresses a kwt
worktree, its running state, duplicate-name checks, or session identity.

Pull-request imports are the one alternate-socket case. Kwt returns the named
socket reserved for the workspace-specific server, and Ghosthub carries that
identity with the worktree selection. Import does not start tmux or execute a
configured project layout. A successful import without a
nonempty socket identity is rejected as malformed rather than treated as a
default-server session. Ghosthub supplies `-L <socket>` to its best-effort
presentation commands, but launches the client through `kwt pr attach
<workspace-path>`. Kwt verifies provenance and creates or repairs an inert
shell-only protected session before executing `attach-session -E`, including
on every SSH reconnect. Remote reconnects invoke Ghosthub's exact managed kwt
path rather than resolving `kwt` from the login-shell `PATH`. Project commands
run only after the user explicitly invokes them in that shell. Ghosthub never
directly creates or attaches
through the default server for that imported workspace.

## Local PTY

App-owned local PTY surfaces remain only for host-scoped utility surfaces such
as the log viewer while that auxiliary UI exists. They are not the worktree
session model and die with the app process.

## Shell Startup Rules

- Let libghostty launch the user's shell through its normal macOS login-shell
  path unless there is a strong product reason not to.
- Keep `TERM_PROGRAM=ghosthub`.
- Do not leak launcher-terminal `EDITOR` or `VISUAL` into embedded shells.
- Keep Ghosthub terminal config at `~/.config/ghosthub/ghostty.conf`.
- Keep the generated base config independent of tmux themes. Built-in Tmux
  Theme colors or libghostty's effective Follow ghostty.conf colors are applied
  at session creation, through the explicit shared-session override, or by the
  active-session command, never as a client-local libghostty overlay.
- Keep mutable Ghosthub app state under `~/.ghosthub/`.
- Do not read or depend on Ghostty.app global config.
- Do not install Ghosthub split, zoom, or tab keybindings. Native tmux owns
  those interactions and receives the terminal's ordinary input unchanged.
- Do not disable libghostty shell integration to work around keybinding
  bugs.

## Configuration Reloading

Ghosthub automatically watches the complete active terminal-configuration
graph: `~/.config/ghosthub/ghostty.conf`, the selected local project's
`.ghosthub/terminal.conf`, the app-owned appearance overlay, and recursive
`config-file` includes. Missing optional includes and absent project or
appearance files remain watched so creating them triggers a reload. Filesystem
events are debounced before rebuilding the graph.

An imported pull-request workspace is contributor-authored source, so its
`.ghosthub/terminal.conf` is never loaded. Selecting one uses the project's
own checkout instead.

Reloading is transactional. A candidate with diagnostics is rejected and the
last valid libghostty configuration remains active. Successful automatic
reloads are silent; automatic failures remain visible until dismissed or
superseded. Explicit reloads present their result. **Ghosthub → Reload
Configuration**, Quick Launch, and
<kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>,</kbd> all provide the explicit path.
Options that libghostty cannot apply to existing surfaces retain their upstream
restart or new-surface semantics.

## Verification

For terminal startup, environment, config layering, libghostty bootstrap, key
handling, or remote terminal changes, run:

```bash
make test-libghostty-bootstrap
make python-test
swift test
make build
```
