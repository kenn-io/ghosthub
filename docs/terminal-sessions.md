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

## Native Tmux Attachment

Ghosthub invokes `tmux attach-session -E -t =<name>` for a local session. A
remote session uses the same tmux command through OpenSSH. There is no
`tmux -CC`, pane capture, history replay, silent rendering child, Swift pane
map, split-tree projection, or Ghosthub tab bar. Tmux owns:

- windows, panes, layout, focus, and status-line presentation
- terminal history and alternate-screen state
- pane processes and session lifetime
- tmux-native key bindings and mouse behavior

Ghosthub owns only inventory presentation, the disposable terminal client,
and connection state. Navigating away, pressing Cmd-W, closing a window, or
quitting Ghosthub detaches the client and never runs `kill-pane`,
`kill-window`, or `kill-session`.

The one presentation exception is color normalization. Before attachment,
Ghosthub resets the selected session's `status-style`, `message-style`, and
`message-command-style` to terminal-default colors so tmux chrome follows
Ghosthub's configured foreground and background instead of tmux's built-in
green/black and yellow/black defaults. Reversed terminal colors highlight the
status and message areas without introducing a second fixed palette. These
best-effort style commands do not change tmux interaction: prefix and key
tables, mouse behavior, windows, panes, history, and layout remain untouched.

Explicit local creation uses one atomic `new-session -A` create-or-attach
client invocation. This closes the detached-session race when the user's tmux
server has `destroy-unattached` enabled. Explicit remote creation performs a
one-shot `has-session`/detached `new-session` phase before ordinary attachment.
The remote process then enters the attach-only SSH reconnect loop, so a later
transport reconnect can never rerun creation. The session name is validated
before launch and passed as one shell-quoted argument. If the exact name
already exists, it is attached without creating or structurally changing panes
or windows. Ordinary kwt worktree and discovered-session opens always use
`attach-session`; explicit named creation is the only exception to the
otherwise presentation-only boundary. Ghosthub does not expose rename, split,
resize, window, pane, or kill operations.

The requested session appears optimistically so transient SSH or discovery
latency cannot remove the user's only way back to it. Direct `list-sessions`
reconciliation begins only after the terminal runtime accepts the creation
command and uses bounded backoff. The optimistic entry remains while that
command is alive; authoritative absence retires it only after retries are
exhausted and the command has ended. Once confirmed, the active presentation
and all later retries are demoted to attach-only. Pending probes are scoped to
the resolved host endpoint and cancelled when that endpoint changes or the
owning window shuts down.

Before discovery or attachment, Ghosthub resolves an absolute tmux path
through the target host's login shell and verifies tmux 3.2 or newer.
The login shell initializes its environment, then delegates Ghosthub's probe
to `/bin/sh`; fish and other non-POSIX account shells never interpret the
POSIX probe itself.
Successful paths are cached per host; lookup and version failures remain
retryable and are presented to the user.

## SSH Keepalive and Reconnect

Remote clients use the user's OpenSSH configuration and add server keepalives.
Exit status 255, OpenSSH's transport/setup failure status, reconnects with
bounded exponential backoff. A connection that remains healthy for at least
30 seconds resets the backoff. Other statuses pass through unchanged, so a
normal tmux detach or a missing session does not create a reconnect loop.

Tmux remains alive on the remote host while the network is unavailable. After
connectivity returns, the client reattaches to the same exact session and tmux
renders its authoritative state. Remote terminal surfaces cannot read the
local Mac clipboard through terminal escape sequences, regardless of the
user's `clipboard-read` or `clipboard-write` configuration. libghostty exposes
the semantic type of every clipboard request: Ghosthub supplies clipboard
contents only for a configured `paste_from_clipboard` action, independent of
which key triggers it. libghostty retains bracketed-paste framing and requires
confirmation before unsafe unbracketed text can reach the PTY.

## Inventory and Startup

At startup Ghosthub loads kwt project/worktree inventory and tmux session
inventory for every resolvable host. The initial content view remains in an
explicit loading state until kwt returns, so the empty onboarding state never
flashes before existing workspaces are known. That loaded empty state is
informational: kwt owns project registration, and Ghosthub does not expose a
retired repository-intake path as a nonfunctional substitute.

Inventory degrades per host. An unavailable remote host retains its cached
inventory and exposes a retry warning on that host without blocking the rest of
the workspace. Remote hosts where kwt is absent remain available for direct
tmux discovery and attachment.

Kwt session names are removed from the generic session group and rendered
under their project/worktree. Every remaining tmux session is shown in the
host-level session group. No naming convention or ownership marker is used to
hide Middleman-created sessions.

Pull-request imports are the one alternate-socket case. Kwt returns the named
socket reserved for the workspace-specific server, and Ghosthub carries that
identity with the worktree selection. Import does not start tmux or execute a
configured project layout. A successful import without a
nonempty socket identity is rejected as malformed rather than treated as a
default-server session. Ghosthub supplies `-L <socket>` to its best-effort
presentation commands, but launches the client through `kwt pr attach
<workspace-path>`. Kwt verifies provenance and creates or repairs an inert
shell-only protected session before executing `attach-session -E`, including
on every SSH reconnect. Project commands run only after the user explicitly
invokes them in that shell. Ghosthub never directly creates or attaches
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

Reloading is transactional. A candidate with diagnostics is rejected and the
last valid libghostty configuration remains active. The app presents the result
of automatic and explicit reloads; errors remain visible until dismissed or
superseded. **Ghosthub → Reload Configuration**, Quick Launch, and
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
