# Terminal Sessions

Terminal behavior is the highest-risk part of Ghosthub. The app must behave
like a normal macOS terminal while remaining isolated from Ghostty.app
configuration and launcher-terminal environment.

## Product Boundary

Ghosthub is a native session switcher for tmux, Herdr, and Zellij fleets across the
local Mac and configured SSH hosts. There are four independent inventory
sources:

- **kwt workspaces:** projects, worktrees, and registered plain directories
  read from kwt's supported JSON commands, including each workspace's exact
  `session_name`.
- **unbound sessions:** every other session returned by direct `tmux
  list-sessions` discovery on the host.
- **Herdr sessions:** running and stopped sessions returned by `herdr session list --json`
  on the local Mac and remote POSIX hosts.
- **Zellij sessions:** active sessions returned by `zellij list-sessions
  --no-formatting` on the local Mac and remote POSIX hosts. Exited,
  resurrectable sessions are filtered out.

The two tmux-backed sources open through the same ordinary tmux client in one
libghostty surface. Herdr and Zellij open through their ordinary whole-session clients. A
session created by Middleman is visible when it exists on the host tmux server,
but Ghosthub does not consult Middleman to identify, create, attach, mutate, or
destroy it.

Ghosthub may also create one ordinary session when the user explicitly chooses
New Tmux Session for a host. This is not a separate managed-session type: the
result immediately joins the same direct tmux inventory and has the same
detach-only presentation lifecycle as every other session.

Herdr and Zellij are optional. Exit 127 during either capability or inventory
probe is silent and does not affect host usability. Invalid output and real command failures
produce only a host-scoped warning; they never change tmux reachability, kwt
availability, cached project inventory, or the workspace's blocking state.

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
- tmux-native key bindings and mouse behavior after Ghosthub enables the
  session-scoped `mouse` option

Ghosthub owns inventory presentation, terminal clients, and connection state.
Before each POSIX tmux presentation, Ghosthub best-effort enables the exact
session's `mouse` option. This makes wheel scrolling enter and navigate tmux
copy mode even when the server started from tmux's vanilla mouse-off default.
The option is session-scoped, so every attached client sees it; Ghosthub does
not add or replace mouse bindings. Native Windows/psmux attachment retains its
documented mouse-reporting limitation and does not receive this setup.
Command-click remains a macOS terminal action: Ghosthub supplies libghostty's
Shift mouse-capture override internally for Command-modified pointer movement,
modifier changes, and the left click. Modifier changes reuse the last tracked
in-window pointer position because keyboard events do not carry a reliable
mouse location. Libghostty removes the override before matching its Command
link binding. Tmux therefore does not capture link highlighting or activation,
and users do not need to hold Shift.
Each workspace window retains every presentation it explicitly opens, keyed by
the exact host, tmux socket, and session name. Navigating to another host,
worktree, or session removes the previous surface from the visible hierarchy
and marks it occluded without freeing the surface or terminating its tmux/SSH
client. Returning to it reuses the same handle and surface. Cmd-W or a
pane-originated close request detaches only the active presentation; closing a
workspace window or quitting Ghosthub detaches every presentation owned by
that window and never destroys server-side state. The separate Kill Session
action is the only destructive lifecycle operation.
It is offered only when direct discovery or a currently connected active
attachment establishes that the session is running. Before displaying
confirmation, Ghosthub captures tmux's server PID, `session_id`, and
`session_created` values together with the exact local or SSH endpoint, socket,
and session name. Termination uses one tmux conditional command that compares
all three live identity values and invokes `kill-session` against that exact
session only on a match. Swift targets the exact name. The Windows WSL client
captures authority from a fresh length-framed all-session listing, matches the
decoded name in Rust, and targets only the captured stable session ID; the name
never re-enters a tmux target or nested command parser. The server PID
distinguishes tmux server generations, while the
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
sees the result. Apart from enabling the session mouse option during attachment,
these best-effort style commands do not change tmux interaction: prefix and key
tables, mouse bindings, windows, panes, history, and layout remain untouched.
Native Windows attachment leaves psmux's status and message styles user-owned;
psmux does not preserve tmux's session-scoped rendering for these style resets
and may apply `reverse` across the client rather than only its status line. The
persistent override and one-shot action are therefore unavailable for native
Windows sessions.

## Native Herdr Attachment

Ghosthub resolves `herdr` in the host account's login environment and attaches
the complete session with `herdr session attach <exact-name>`. Local sessions
use libghostty's normal macOS login-shell path. Remote sessions use an ordinary
OpenSSH PTY, the same trusted host configuration and pooled connection as tmux,
and the remote account login environment. Ghosthub does not use Herdr's own
remote-client mode.

Herdr owns workspaces, tabs, panes, layout, history, key bindings, terminal
state, and the processes inside each session. Ghosthub owns discovery,
whole-session lifecycle requests, and the disposable client presentation. Each
scene has at most one active interactive tmux, Herdr, or Zellij presentation.
Already-opened tmux clients may remain retained and noninteractive for
explicitly enabled previews; previews never create another client.
Navigating away, pressing Cmd-W, closing a window, or quitting closes only the
client. Ghosthub never reconstructs or otherwise controls Herdr themes,
workspaces, tabs, panes, agents, plugins, installation, updates, configuration,
or server-wide state. The sole pane-level exception is an explicit Split Right
or Split Down request against the active attachment, described below.

### Herdr pane splitting

Cmd-D and Cmd-Shift-D, plus the matching File menu actions, request
`herdr pane split --direction right|down --focus` when the active Herdr client
reports version 0.8.0 or newer and its exact session is running. Capability is
probed independently for each attachment and refreshed after Create or Restart.
Older or malformed versions leave these app shortcuts unavailable and preserve
ordinary terminal input.

Each split uses the Herdr executable, SSH arguments, and session socket frozen
on that attachment. Ghosthub first removes every inherited Herdr control
variable, then sets only `HERDR_SOCKET_PATH` to that socket. It deliberately
omits `pane_id`: Herdr 0.8.0 uses one session-global focused pane, so the server
selects the pane the attached clients see. Ghosthub does not synthesize Herdr
key bindings or reconstruct the resulting pane tree.

Requests serialize per attachment. Detaching prevents queued requests from
being dispatched; results from an abandoned in-flight request are discarded,
although a command already delivered to Herdr may still take effect. Split
failures are not retried and appear over the active terminal. Herdr exposes no
stable session-generation or client identifier, and its socket path is derived
from the session name, so this constructive operation cannot receive tmux's
replacement-identity guarantee. The session-global-focus premise was verified
against Herdr 0.8.0; later supported versions are trusted to retain that API
contract.

### Herdr session lifecycle

Ordinary open and restoration use `herdr session attach <exact-name>` only for
inventory reported as running. Create and Restart are explicitly different:
they use plain `herdr` for the default session or `herdr --session <name>` for a
named session, which launches a missing server and attaches immediately.

Stop and Delete are separate confirmed operations. Immediately before either
command, Ghosthub reruns `herdr session list --json` through the current local
or SSH endpoint and checks the expected running/stopped state and configuration
paths. Stop terminates every process while retaining Herdr's saved shape;
Restart recreates processes within that shape. Delete requires a stopped,
non-default session and permanently removes its saved state. The default
session may be stopped and restarted but never deleted.

Herdr provides no stable generation ID. The socket path is derived from the
name, so path revalidation catches a relocated configuration root but cannot
prove that a same-name replacement is the original session. Three accepted
races remain: a create collision after the final absence check, same-socket
replacement after revalidation, and `session attach` resurrecting a server
that stops after running discovery. A failed client launch may therefore leave
a newly started server behind. Discovery reconciles the resulting state.

An intentional stop suppresses reconnect in every scene presenting that exact
host/name before the command runs. Success detaches all matching clients;
failure performs a fresh probe before recovery can resume. A scene never
blindly reconnects and resurrects a session another scene deliberately stopped.

Discovery, reconnect probes, and attachment remove inherited Herdr routing
identity before resolving or starting the client. The scrubbed variables are
`HERDR_ENV`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`,
`HERDR_CLIENT_SOCKET_PATH`, `HERDR_PANE_ID`, `HERDR_TAB_ID`,
`HERDR_WORKSPACE_ID`, `HERDR_BIN_PATH`, `HERDR_ACTIVE_WORKSPACE_ID`,
`HERDR_ACTIVE_TAB_ID`, `HERDR_ACTIVE_PANE_ID`, and
`HERDR_ACTIVE_PANE_CWD`. This is the Herdr equivalent of removing `TMUX` and
`TMUX_PANE`: launching Ghosthub from inside a multiplexer must not redirect a
new client into the enclosing session.

Live validation and automated fixtures must isolate Herdr with
`XDG_CONFIG_HOME`. `HERDR_CONFIG_PATH` alone is insufficient because it does
not relocate all session state.

## Native Zellij Attachment

Ghosthub resolves `zellij` in the host account's login environment and opens an
active session with `zellij attach <exact-name>`. **New Zellij Session** uses
`zellij --session <exact-name>`, which creates and presents a new session while
refusing both active and resurrectable name collisions. Local sessions use
libghostty's normal macOS login-shell path. Remote sessions use an ordinary
OpenSSH PTY with keepalives and the remote account login environment.

Zellij owns tabs, panes, layout, history, key bindings, terminal state,
configuration, plugins, and every process inside the session. Ghosthub owns
active-session discovery and the disposable client presentation. It does not
offer pane actions, an explicit resurrection workflow, or deletion of
resurrection data. Zellij does not expose an atomic active-only attachment:
Ghosthub validates the exact name as active first, but if the session exits
before `zellij attach` resolves it, Zellij may resurrect its saved layout.
Ghosthub never passes `--force-run-commands`; this narrow upstream race is
accepted rather than represented as a false attach-only guarantee. Discovery
and attachment remove inherited `ZELLIJ`, `ZELLIJ_PANE_ID`, and
`ZELLIJ_SESSION_NAME` values so launching Ghosthub from inside Zellij cannot
redirect the new client into the enclosing session.

Navigating away, pressing Cmd-W, closing a window, or quitting closes only the
client. A clean detach stays detached until the user reconnects. A remote SSH
transport failure probes the exact active session before launching a
replacement client and stops recovery if the session disappears, Zellij is no
longer available, or the failure requires connection review.

**Kill Session** is the only destructive Zellij lifecycle action. Ghosthub
confirms the host and name, establishes a shared same-session kill fence, then
repeats active-session discovery against the current endpoint immediately
before `zellij kill-session <exact-name>`. The fence cancels matching reconnect
attempts and detaches matching presentations in every scene before the command,
so neither a reconnect nor an already-launched client can immediately resurrect
a deliberately killed session. Successful kills invalidate in-flight Zellij
discovery, remove the row from every scene, and begin a fresh inventory probe.
A per-session kill revision also rejects attachment validation that began
before the kill. A failed kill releases the fence and revalidates an eligible
detached presentation or matching pending open or restoration before resuming
it, while preserving its navigation and route checks. Zellij does not expose a
stable session-generation identifier, so a same-name replacement between that
final check and the kill command cannot receive tmux's replacement-identity
guarantee. Closing or disconnecting never implies a kill.

## Worktree Sandbox Attachment

The accepted sandbox design uses one dedicated local tmux session on a
Ghosthub-owned socket for each managed sandbox. It never adds a pane or window
to the worktree's existing kwt session. The session's first process is an
ordinary interactive `container exec -it` or `sbx exec -it` client rooted at
the exact worktree. Tmux owns terminal layout, history, key bindings, and
process presentation; the sandbox provider owns the VM or container lifecycle.

Closing the terminal presentation detaches only its tmux client. It does not
stop or delete the provider resource. An existing dedicated tmux identity is
attach-only. A missing presentation may be constructed only after Create or an
explicit Start/Open action has revalidated the persisted sandbox, provider
identity, current worktree generation, and lifecycle fence. An optional saved
launch command runs only while constructing that new presentation after
Create, Start, or explicit Open; reconnects and ordinary attachment never
rerun it.

Before invoking Apple Start, Ghosthub repeats the complete sandbox preflight
and requires its canonical mount plan to match the plan persisted at Create.
Only after that check and provider startup may it construct the presentation. A
stopped resource whose Git layout, protected targets, hook symlink resolution,
or hard-link state changed is not started or attached; the user must explicitly
delete and recreate it.

Stop and Delete fence every matching presentation before acting on the exact
managed provider identity. They confirm provider execution has terminated
before the final Git-metadata drift comparison. Stop retains provider state;
Delete removes the dedicated tmux identity and sandbox record only after any
detected drift or comparison failure is persisted as an independent security
notice. Neither action may target a
prefix-only or same-named replacement. Provider resources remain stopped after
reboot until the user explicitly starts them. The complete provider and
worktree lifecycle contract is in [Worktree Sandboxes](sandboxes.md).

## Rust Client Lifetime and Application Death

The Rust applications use the same ordinary-client boundary. The native
Windows GPUI client attaches to tmux, Herdr, and Zellij inside WSL2;
Linux remains a compile-and-contract target until its native product slice is
authorized. A terminal worker and PTY own only the disposable client. The WSL
tmux server owns session lifetime and must survive client close, graceful
application exit, and forced Ghosthub termination.

The first Rust SSH slice preserves the same boundary for configured POSIX
hosts: KWT owns route resolution, host-key/authentication prompting, and the
runtime OpenSSH lease; Host builds an attach-only command for a freshly
discovered exact tmux identity; Terminal owns only the disposable ConPTY-backed
client. On Windows, both pinned KWT and OpenSSH run inside the selected WSL
distro, and Terminal launches an absolute `wsl.exe` relay with fully resolved
argv. Closing or crashing Ghosthub releases that relay, client, and lease but
never kills the remote tmux server. Terminating the selected WSL distro ends
the local lease and presentation, not the remote session. This slice ends the
presentation on client exit and does not yet implement the reconnect
supervisor described below.

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

Rust local WSL creation follows the same one-shot rule as shipped local
creation. After validating the normalized name, Ghosthub performs a fresh
admitted-host read and consumes one CreateOnce by launching the ordinary
ConPTY client with `tmux new-session -A -E -s <name>`. The same tmux command
queue writes server PID, session ID, and creation time to a nonce-scoped
private WSL receipt; identity framing never enters ConPTY or the terminal
screen. The receipt writer invokes `/bin/sh -c` explicitly, so tmux's
configurable `default-shell` cannot change its atomic POSIX semantics. Host
reads and removes that opaque receipt, rechecks the runtime, and
only then publishes the presentation. Every later activation is attach-only.
If creation and identity capture race another creator, `-A` attaches to the
exact same-named session.
If any step after launch fails, Ghosthub detaches the client and reports the
failure but neither reruns creation nor destroys the possibly created session.

Psmux 3.3.7 failed the required exact-kill proof and never established genuine
ConPTY `attach-session -E` behavior. Its probe remains rejection evidence, but
it is not the Rust Windows substrate. The Windows MVP uses real POSIX tmux in
WSL2 and never degrades to psmux or an app-lifetime session.

Tmux admission itself uses ordinary ConPTY clients supplied by the workspace
through the same terminal worker as product attachments. In an isolated
namespace, a second atomic `new-session -A`, an environment positive control
without `-E`, and the preservation probe with `-E` all run on real PTYs;
captured pipes and tmux control mode are not capability evidence. The verified
binary is cached only after those clients attach, their effects are observed,
and they detach. Any failure cleans the isolated server and leaves admission
retryable.

The WSL admission server is isolated before any session creation: Ghosthub
chooses a random private `TMUX_TMPDIR`, installs its cleanup guard before the
cancellable mode-0700 directory creation, applies the path to every probe
command and ordinary client, and removes it when admission ends. `-L`
capability proof is therefore not trusted to protect the user's default
server. If the creation command times out or loses its relay, cleanup repeatedly
removes the path through a two-second monotonic settle deadline because the
Linux command may finish late, then performs a final removal and verifies
absence. Discovery, admission, and attachment also unset inherited `TMUX` and
`TMUX_PANE` before setting the selected socket environment.

That failed proof exercises `kill-session -t =name`. The experimental Swift
remote-Windows path instead resolves the exact target and fresh identity before
killing by session ID. Its complete conditional-kill flow remains subject to
isolated end-to-end psmux verification; the Rust rejection does not by itself
establish false success in the shipped path or make that path dead code.

The tmux server lives inside WSL2 and cannot inherit a Windows Job Object.
Ghosthub resolves `wsl.exe` through `GetSystemDirectoryW` and carries its
absolute system-directory path through discovery and attachment; it never
uses current-directory or launcher-`PATH` executable search. Ghosthub
intentionally puts only the disposable `wsl.exe` ConPTY relay in an
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

After fresh WSL discovery, the ordinary client enters through one tmux
`if-shell -F` command targeted at the exact session. Its condition compares
the captured server PID, session ID, and creation time; only the matching
branch executes `attach-session -E`. The mismatch branch prints a classified
framed marker and exits without attaching. Ghosthub recognizes it only on a
clean exit whose normalized pre-attachment output exactly equals that marker,
so ordinary session output cannot impersonate the result. A server restart and
reused session ID therefore cannot redirect the client between discovery and
process launch.

## Relaunch Restoration

Quitting Ghosthub or installing an update only drops disposable clients. When
macOS restores workspace scenes, Ghosthub resolves each scene's stable logical
descriptor against current inventory and uses attach-only restoration; it
never creates a missing session or falls back to a same-named target on a
different host or socket. Worktree identity is the durable generation reported
by kwt, so removing and recreating a worktree at the same path cannot inherit a
saved presentation; a missing generation restores only as far as the project.
A directory workspace instead restores by its registered path on the same
stable host, because the kwt registry has no separate generation for it.
Once a worktree presentation has observed a generation, incomplete inventory
cannot erase it and a different non-nil generation is treated as a replacement;
explicitly reselecting the worktree invalidates the observed presentation and
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
any delayed same-ID native payload with stale navigation or presentation data.
An ordinary local session must be present in direct discovery before Ghosthub
runs the exact `attach-session` path. Remote sessions use that same rule and,
after a confirmed attachment, Ghosthub's native reconnect supervisor owns any
transport recovery.
An ordinary Herdr session restores only after a completed fresh Herdr probe on
the descriptor's exact host reports that exact name as running. A missing or
stopped session remains pending and never substitutes another name. Because
Herdr's attach command can restart a server that stops after the final probe,
Ghosthub accepts only that narrow probe-to-launch race.
An ordinary Zellij session restores only after a completed fresh Zellij probe
on the exact host reports the exact name as active. Remote restoration then
validates that session against one SSH connection snapshot, rechecks the route,
and reuses the snapshot for attachment; route drift cancels restoration. It
never creates a missing session intentionally, but the same unavoidable Zellij
probe-to-attach resurrection race applies.
Offline or otherwise unavailable targets remain pending and retry when normal
inventory refreshes publish new state. Navigating the window elsewhere cancels
the pending target. If a scene was captured without an active native
presentation, Ghosthub restores its host and selected project, worktree, or
directory navigation but does not open or create the workspace session until
the user explicitly selects it.

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

Kwt inventory includes every worktree and registered directory, whether or not
its canonical tmux session is live. When the managed helper is available,
Ghosthub therefore
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
Ghosthub does not expose rename, resize, or window operations. On an attached
tmux or capable Herdr terminal, Cmd-D and Cmd-Shift-D request Ghostty-style
split-right and split-down operations; the File menu exposes the same actions
and shortcuts. The Herdr routing contract is documented above. For tmux,
these actions require tmux 3.4 or newer; Ghosthub checks the binary on each
local or remote attachment and leaves normal tmux key bindings available on
older versions. On supported POSIX hosts, Ghosthub runs `split-window -h` or
`split-window -v` against the active pane of that attachment's exact host and
socket using its frozen SSH route. Once the client attaches, it publishes its
TTY and stable tmux server and session identity under that attachment's unique
token. Each split atomically finds and validates that exact client, then
targets the session's active pane.
Other clients attaching
at the same time cannot be mistaken for the Ghosthub surface. Renaming the
attached session therefore keeps splits working, while a same-named replacement
or a client switched to another session is rejected. Failed client discovery is
not cached, and each queued request receives its own attempt. Ghosthub
serializes requests for the attachment. The keyboard
shortcuts apply only while the terminal has effective keyboard focus and no
sheet is attached; choosing either File menu item remains an explicit request.
The action works regardless of the user's tmux prefix or key-table bindings
while tmux remains authoritative for pane creation and layout. If tmux rejects
a split, Ghosthub displays its diagnostic over the attachment. Native Windows
psmux attachments do not offer pane-split actions or intercept these shortcuts.
Kill Session is exposed separately from presentation only for a session known
to be running and always requires confirmation. For a protected worktree,
Ghosthub preserves the named socket, path, and generation in navigation state,
then queries that exact socket for fresh server and session identity before
showing confirmation. A same-named session on the default server is unrelated
and can never satisfy or receive the protected action. Opening also requires
the rendered socket to match fresh KWT inventory. If no current worktree owns
an active or retained protected presentation's complete identity, Ghosthub
keeps a fallback session row so that live client remains reachable.

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
binary path. POSIX hosts require tmux 3.2 or newer; the experimental Windows
path accepts psmux's tmux 3.2 compatibility level. On POSIX hosts the login
shell initializes its environment, then delegates Ghosthub's probe to
`/bin/sh`; fish and other non-POSIX account shells never interpret the POSIX
probe itself. On Windows, Ghosthub starts noninteractive Windows PowerShell
and resolves `tmux.exe` with `Get-Command`.
Successful paths are cached per frozen host connection; lookup and version
failures remain retryable and are presented to the user.

## SSH Keepalive and Reconnect

Remote clients use the user's OpenSSH configuration and add server keepalives.
If OpenSSH requires interactive authentication, Ghosthub shows its challenge
in a native secure-entry sheet and passes the session-only response through a
private FIFO. Later inventory, tmux, and Herdr clients reuse that app-session
control connection and remain noninteractive. Every control connection is named for
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
For both backends, status 0 is a clean detach, OpenSSH status 255 is transport
loss, and another nonzero status is a non-transport client failure. This relies
on the Herdr client's documented detach status; like tmux, a client-originated
255 may briefly enter recovery, then self-correct when the exact probe reports
the session absent.
After a confirmed attachment exits with OpenSSH's transport/setup status 255,
that presentation's native supervisor probes the real SSH and backend
path at attempt-start intervals of 1, 2, 4, 8, 16, and then 30 seconds. Each
probe has a 15-second end-to-end deadline; its runtime counts against the
interval, and an overrun clamps the next delay to zero. Attempts never overlap.
**Reconnect Now** wakes
the same supervisor immediately instead of starting a parallel path.

Default-socket recovery shares the host's in-flight `list-sessions` probe with
inventory discovery. Protected sockets use a headless
`tmux -L <socket> has-session -t =<name>` probe so an unsuccessful attempt never
creates or flashes a terminal surface. Confirmed presence launches one new
attach-only client. Confirmed absence ends a default-socket or protected-socket
presentation only when that exact session had already been established; an
unconfirmed interrupted kwt establishment may rerun its one-shot creation path.
A reachable non-transport client failure is presented as unable to attach
rather than retried indefinitely. A clean tmux, Herdr, or Zellij detach does not start
recovery. Herdr recovery shares only the supervisor policy: each attempt uses
its own exact Herdr session probe, stops when Herdr is unavailable or the name
is absent, and never creates a terminal surface for an unsuccessful probe.

Transport failures continue retrying automatically, with no more than 30
seconds between attempt starts, even while a retained tmux presentation is
inactive. Authentication and host-key review failures pause the presentation's
automatic retry and appear in the existing native recovery flow when it is
active. Successful recovery resumes the same supervisor. If SSH is already
reachable when that flow checks again, **Retry** resumes the supervisor as well
as refreshing host inventory. Only the recovery flow opened for that native
session request may resume it; authentication started from ordinary host
inventory never reopens a session. Dismissing it leaves an honest
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

Tmux, Herdr, and Zellij servers remain alive on the remote host while the network is
unavailable. After connectivity returns, the client reattaches to the same
exact session and its backend renders authoritative state. Copy-mode and
programs on configured remote
hosts may write the Mac clipboard through OSC 52 when allowed by the user's
`clipboard-write` configuration, so remote tmux copy behaves like local tmux
copy. Remote terminal surfaces cannot read the local Mac clipboard through
OSC 52, regardless of `clipboard-read`. libghostty exposes the semantic type
of every clipboard request: Ghosthub supplies clipboard contents only for a
configured `paste_from_clipboard` action, independent of which key triggers
it. libghostty retains bracketed-paste framing and requires confirmation before
unsafe unbracketed text can reach the PTY.

## Inventory and Startup

At startup Ghosthub loads kwt project/worktree inventory, tmux session
inventory, and optional Herdr and Zellij inventories for every supported
resolvable host. Herdr and Zellij are not probed on experimental Windows
hosts. The initial content view
remains in an
explicit loading state until kwt returns, so the empty onboarding state never
flashes before existing workspaces are known. That loaded empty state is
informational: kwt owns project registration, and Ghosthub does not expose a
retired repository-intake path as a nonfunctional substitute.

Inventory degrades per host. An unavailable remote host retains its cached
inventory and exposes a clickable detail warning on that host without blocking
the rest of the workspace. The detail offers a retry and a shortcut to Host
Settings; OpenSSH status 255 is reported as an SSH connection failure instead
of a login-shell or tmux failure. Remote hosts where Ghosthub's managed kwt is
absent remain available for direct tmux discovery and attachment. Before kwt
inventory runs for a configured macOS or Linux host, Ghosthub ensures its exact
revisioned helper is installed under the remote user's `~/.ghosthub/`
directory. A provisioning failure is reported for that host and disables its
worktree actions without blocking tmux inventory. On macOS and Linux, a fresh
helper has an empty project registry: the **+** beside the host's **Projects**
group passes one user-supplied absolute checkout path to kwt's noninteractive
registration command, then refreshes inventory. Immediately before
registration, Ghosthub re-resolves the host ID and rejects the operation if its
endpoint changed while Add Project was open. No filesystem scan occurs.
The project row's confirmed **Remove Project** action similarly revalidates the
project path and host endpoint, then asks kwt to unregister only that project
metadata. Repository and worktree directories are untouched. Before
unregistering, Ghosthub probes every protected-socket worktree and requires its
tmux session to be absent; a live or unverifiable protected session blocks
removal because it cannot be recovered through default-server discovery after
the project disappears. Ordinary live tmux sessions remain discoverable under
the host. The Rust Windows app exposes the same registration flow for its WSL
host.
Removing a registered project is separately confirmed and delegated to KWT
with the exact registered path, expected credential-free repository identity,
and opaque registration fingerprint. This unregisters metadata only:
repositories, worktrees, and tmux sessions remain untouched. Reads and
mutations stay off the UI thread, and the last usable project tree remains
visible while either is in flight.

Removing a generation-backed worktree is a distinct destructive action. The
confirmation is bound to its exact project, generation, tmux socket, and a
fresh live session identity or freshly confirmed absence. Pinned KWT
also reports the worktree's staged, unstaged, and untracked change counts
before Ghosthub presents the confirmation. A worktree with uncommitted changes
names that data-loss risk and requires an explicit **Force Remove Worktree**
action. Ghosthub checks for new changes again before it terminates a confirmed
session. If a clean worktree became dirty, Ghosthub presents the force warning
instead of attempting ordinary removal. KWT revalidates the identity facts
under the project lifecycle lock, terminates only the confirmed session when
necessary, and removes the checkout in the same guarded operation. A replaced
session or changed socket fails closed and requires new confirmation. Closing
or detaching a presentation never grants this removal authority.

On experimental Windows hosts, an explicit Install Bundled kwt action probes
the process architecture, uploads the matching pinned AMD64 or ARM64 helper,
verifies its SHA-256 and exact revision, and activates it at
`%USERPROFILE%\.ghosthub\helpers\kwt\<revision>\kwt.exe`. Inventory and
workspace operations use only that exact per-user helper and never resolve
`kwt.exe` from `PATH`.
Project registry mutations are not yet supported on Windows, so its Add Project
and Remove Project actions are hidden. Inventory never installs or updates the
unsigned Windows helper automatically.
This restriction does not apply to the Rust app's WSL host, which executes the
pinned Linux helper.

Direct tmux discovery marks a default-server worktree session as running when
its exact kwt session name is present and the host remains reachable. Cached
inventory does not preserve the live indicator through a discovery failure.
Kwt session names are removed from the generic session group by default and
remain rendered under their project/worktree. Settings → Worktrees can expose
those duplicate generic session entries. Every remaining tmux session is
eligible for the host-level session group. Case-sensitive `*` and `?` wildcard
patterns in
`hidden_session_patterns` under `[tmux]` inside
`~/.config/ghosthub/config.toml` hide matching standalone sessions from the
sidebar and command palette. Settings → Worktrees edits the same list, one
pattern per line. Filtering occurs after discovery and never suppresses a kwt
worktree, its running state, duplicate-name checks, or session identity.

Tmux activity indicators do not extend inventory polling. Once an ordinary
client has connected during the current app launch, Ghosthub samples only that
exact session as a warm target. Active warm sessions are sampled every five
seconds, quiet targets every twenty seconds, and unavailable targets back off
to thirty seconds. Each probe captures at most the active pane's latest 160
scrollback lines, excluding its visible screen, and computes a checksum on the
local or remote host without discarding trailing blank output, so terminal
text is not returned to Ghosthub. The fingerprint also carries the pane's
scrollback line count so blank or repeated output records progression until
the pane's history limit is reached. Once history is full, output that leaves
the bounded tail byte-identical reads as quiet: tmux exposes no cumulative
output counter, and its activity timestamps also advance on redraws, so this
keeps the deliberate bias toward quiet false negatives over misleading
attention signals.
The probe verifies the expected server PID, session ID, and creation time on
the host before any capture runs, targets the scrollback and capture reads at
the exact pane ID from that verified read, and re-evaluates the identity
predicate inside the same tmux server dispatch as each read, so a same-named
replacement session is never read even when it races the probe. Identity,
pane, and pane-dimension reads before and after the capture must also match.
Native Windows sampling verifies at runtime that psmux supports the format
predicate and if-shell contract, then uses the same atomic reads; when the
capability probe fails, the sample is refused rather than taken without the
predicate. The first sample after a pane switch, a pane resize, or a sampling gap
longer than the activity window establishes a quiet baseline; later
scrollback progression on that pane at unchanged dimensions marks the session
active for thirty seconds. Sample continuity is measured from each probe's
start, so a slow probe on a laggy host cannot stretch the gap past the window
and demote real changes to baselines. In-place prompt,
spinner, and status redraws do not count as activity, and neither do client
resizes, which reflow scrollback without representing new work.
Windows activity sampling requires psmux 3.3.4 or newer because earlier
versions do not expose negative scrollback ranges. Older supported psmux
versions remain available for discovery and attachment but publish no passive
activity state.
Closing a presentation does not remove warm state, while app termination,
session disappearance, or identity replacement does. Every host refresh and
every new scene reconciles warm entries against the currently configured
endpoints, so a reconfigured or removed host stops being sampled even when the
change happened while no window observed it. Retiring a warm entry cancels its
in-flight probe; a probe cancelled after its host command launched drains
within the probe's ten-second timeout and its result is discarded. This state
is not saved to the database.

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
- Keep a modest client-local minimum text contrast so inherited ANSI colors
  remain legible on light and dark backgrounds without rewriting shared tmux
  styles. Preserve an explicit user-configured value.
- Ship libghostty's emitted `share` tree with every build. The bootstrap emits
  the bundled theme corpus, shell integration, and compiled terminfo; app
  bundles stage `ghostty/` and `terminfo/` into `Contents/Resources`, and
  Ghosthub points `GHOSTTY_RESOURCES_DIR` at whichever layout it finds.
  Without it `theme = <name>` resolves only against a user's own
  `~/.config/ghostty/themes`.
- Keep the generated base config independent of tmux themes. Built-in Tmux
  Theme colors or libghostty's effective Follow ghostty.conf colors are applied
  at session creation, through the explicit shared-session override, or by the
  active-session command, never as a client-local libghostty overlay.
- Keep mutable Ghosthub app state under `~/.ghosthub/`.
- Before nested discovery or attachment, remove `TMUX` and `TMUX_PANE` for
  tmux and the documented Herdr control variables for Herdr so an enclosing
  multiplexer cannot redirect the client.
- Do not read or depend on Ghostty.app global config.
- Do not install Ghosthub-owned layout, zoom, or tab management. Each backend
  owns those interactions. Explicit app shortcuts may request a semantic split
  operation against the active tmux or Herdr attachment.
- Do not install Herdr workspace, tab, or pane keybindings. Apart from the
  explicit Split Right and Split Down app commands on capable attachments, the
  whole-session Herdr client receives ordinary terminal input unchanged.
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
make swift-test
make build
```
