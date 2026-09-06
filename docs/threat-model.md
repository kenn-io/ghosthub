---
title: Threat Model
description: Security boundaries and trust assumptions for Ghosthub
---

# Threat Model

This document defines the security claims Ghosthub makes and the assumptions
used to classify security findings. Ghosthub is a native terminal and tmux/Herdr/Zellij
control plane for one user across machines that user administers. Ghosthub is
not itself a sandbox or a hardened client for attaching to hostile terminal
servers; its accepted worktree-sandbox design delegates isolation to explicit
local providers under the narrower boundary below.

## Assets and Security Goals

Ghosthub aims to protect:

- local user data exposed through app-mediated capabilities such as the
  clipboard
- terminal input and session metadata while they cross the network
- the session lifecycle boundary: ordinary presentation only attaches or
  detaches; creation and termination require separate, explicit user actions,
  with confirmation before tmux or Zellij Kill and Herdr Stop/Delete
- app-owned settings and persistence from unintended cross-host or
  cross-worktree mutation
- application-update integrity, rooted in the reviewed channel-specific
  Sparkle Ed25519 key and its feed-publication boundary, with Apple Developer
  ID signing and notarization as independent defenses

The main security goals are to use the system SSH trust and encryption model,
avoid sending local data to a remote pane except through an intentional
terminal interaction, and keep tmux, Herdr, and Zellij presentation non-destructive
outside explicit whole-session lifecycle requests.

Herdr does not expose a stable session-generation identifier. Ghosthub
revalidates name, state, configuration paths, and the selected host endpoint,
and a confirmation retains only the reviewed route key rather than an SSH
lease. Execution must reacquire that route before mutation, but Ghosthub does
not claim that this prevents a same-name/same-socket replacement race.
Stop can terminate every process in a session; Delete can permanently remove
saved shape. Both actions require confirmation, and Delete is never offered for
the default session.

Zellij likewise does not expose a stable session-generation identifier.
Ghosthub releases the preparation lease, then reacquires the reviewed route
and revalidates the selected host and active name before a confirmed kill. It
does not claim protection from replacement in the remaining check-to-command
race.

## Trust Boundaries

### Local Mac and user account

The Mac running Ghosthub, the logged-in user account, and software intentionally
installed under that account are trusted. Ghosthub does not defend against a
compromised local account, injected libraries, replacement development tools,
or an attacker who can modify Ghosthub's configuration or state. Packaged
Ghosthub releases invoke their signed, bundled kwt by exact path rather than
trusting a launcher-controlled local `PATH`.

### Configured SSH hosts

Every remote host added to Ghosthub is a **trusted peer** administered by the
user. This trust includes the host operating system, its SSH service, the
multiplexer servers and sockets, and processes running in panes Ghosthub
attaches to. SSH
host authentication and transport confidentiality are delegated to the user's
OpenSSH configuration and host-key policy.

Enabling an exe.dev account authorizes its configured SSH control endpoint to
enumerate VM destinations for that account. Ghosthub accepts only the
documented JSON inventory fields, uses each returned `ssh_dest` without
rewriting it, and still applies the user's OpenSSH configuration and host-key
policy when connecting to the VM. The provider cannot silently approve a VM
host key or supply terminal contents through the control response. A
compromised enabled provider can influence which SSH destinations Ghosthub
offers and attempts to reach, so it is part of the configured trusted-peer
boundary.

A malicious or compromised configured SSH host is outside Ghosthub's threat
model. In particular, Ghosthub does not claim availability, confidentiality,
or protocol robustness when the remote SSH endpoint, tmux server, or attached
pane deliberately emits malformed, deceptive, or unbounded terminal output.
Resource limits and escape-sequence filtering on these paths
are defense-in-depth and correctness measures; they do not make a hostile host
a supported security boundary.

Trusting a host does not grant it every local app capability. Ghosthub still
applies its clipboard policy and other explicit terminal-integration controls
so routine remote programs cannot silently exercise local UI capabilities that
the user did not enable. Remote panes may write the Mac clipboard through OSC
52 when allowed by the user's `clipboard-write` configuration. This is a
required terminal capability so copy-mode in a configured remote tmux session
can propagate copied text to macOS. Remote surfaces never service OSC 52
clipboard reads, regardless of `clipboard-read`. Ghosthub reads libghostty's
semantic request type before touching the Mac pasteboard. Only
`paste_from_clipboard` may receive clipboard contents; OSC 52 reads receive an
empty value. This follows the configured binding instead of assuming a
physical shortcut. Bracketed-paste framing remains authoritative, and unsafe
unbracketed text requires user confirmation before reaching the PTY. Selecting
Copy may similarly write the user's chosen terminal selection. Those
intentional interactions necessarily disclose their selected contents to the
attached pane.

### Windows WSL host

An installed WSL environment and the selected distro are local trusted-peer
state under the user's account. Ghosthub resolves only the system-owned
`wsl.exe`; it does not trust the current directory or launcher `PATH` to select
that executable. Presence alone does not authorize execution during initial
window construction. After the first frame, automatic discovery deliberately
may boot the WSL2 utility VM and configured or default distro and may create
and clean short-lived tmux capability-probe sessions in isolated socket
namespaces. Those probes must never use or mutate the user's default tmux
server.

Automatic discovery is bounded and cancellable. WSL absence omits the
synthetic host, while inspection, startup, timeout, admission, and protocol
failures remain classified on that host and do not become authority to restart
or terminate WSL, choose another distro or socket, or weaken mux admission.
The WSL distro and processes attached through it have the same terminal and
clipboard trust limits as configured SSH hosts: OSC 52 writes follow policy,
OSC 52 reads receive no clipboard contents, and only a genuine paste action
may acquire clipboard data for PTY input.

### Network

The network between Ghosthub and a configured host is untrusted. Passive
observers and active network attackers are in scope to the extent that SSH
normally protects against them. Ghosthub does not replace or weaken OpenSSH
host verification, authentication, or encryption.

Ghosthub's anonymous usage event is sent over HTTPS to PostHog. Its stable
identifier is a random installation UUID, not a hardware identifier, user
identity, host identity, repository path, or tmux session name. The event
contract excludes repository, worktree, host, session, path, command, and
terminal data, disables person-profile processing and GeoIP enrichment, and
can be disabled in Settings or through the documented environment switches.

### Loopback web UI (Rust applications)

Ghosthub fundamentally provides access to a shell. The web UI must therefore
only ever be reachable over highly secure transports that bad actors cannot
access: the loopback interface, a Tailscale-secured network, or an SSH
tunnel. This is the same deployment posture as Kenn Software's other web
applications (Forge): a loopback default bind, with any wider reachability
provided by an explicitly trusted secure transport, never by the application
listening on an untrusted network. Findings that presuppose an attacker with
network reach the deployment posture excludes are closed against this
paragraph.

Within that posture, the v1 web UI is loopback-only: an ephemeral loopback
bind with no non-loopback code path, an in-memory startup bearer credential,
exact Host validation and a required credential on every request, and exact
Origin validation on every websocket upgrade and state-changing request. The
full wire contract, including capability lifetimes and accepted multiplexer
multi-client behavior, is maintained in [Web UI](web-ui.md).

This section is the arbiter for triaging web-surface findings. A valid
finding names one of the in-scope attacker classes below and a concrete
capability that attacker gains beyond what it already has. Findings outside
these classes are closed with a pointer to this section rather than patched.

**In scope — hostile web content in the user's browser.** Malicious pages
probing loopback: DNS rebinding, CSRF, cross-origin websocket connection,
drive-by port scans, and credential leaks through history, cache, or
referrers. Defenses: exact Host before routing, exact Origin on upgrades and
state-changing requests, a credential on every request, the bootstrap
redirect that strips the token from the location bar with `no-store` and
`no-referrer`, an HttpOnly SameSite=Strict cookie, a same-origin CSP whose script-src is strict ('self', no inline) with inline styles allowed only for the embedded terminal library's runtime-injected stylesheet,
and hello/idle timeouts on upgraded sockets.

**In scope — other users on a shared machine.** Any local user can bind a
free loopback port, and browsers scope cookies to the hostname, never the
port, so a lured visit to an attacker's loopback port leaks the session
cookie value across user boundaries. The cookie therefore carries a
per-instance session value distinct from the bearer credential and authorizes
only the page shell and scene establishment — never terminal, presentation,
lifecycle, or other state-changing operations. Browser viewers are
independent scenes, each holding a scene secret minted only with non-ambient
proof (the bearer credential, or a single-use seconds-scale bootstrap mint
code), carried outside cookies and URLs, expiring on bounded idle and
absolute lifetimes. Interactive approvals (SSH prompts, clipboard reads,
lifecycle confirmations) are addressed to exactly one scene and fail closed
if that scene disappears.

**In scope — untrusted byte streams.** Session output and clipboard traffic
carry the same trust limits as native attachments regardless of viewer. The
server relays terminal bytes without interpretation by design; the viewer
(xterm.js in a browser, the native engine otherwise) is the single VT
interpreter and the place rendering-level attacks are mitigated. Clipboard
and paste behavior is governed by the shared contract vectors under
`contracts/clipboard/`; a divergence is a recorded known gap tied to tracked
work, and the browser-terminal milestone does not pass with open gaps.

**Out of scope.** Processes running as the same user as Ghosthub: they can
already spawn shells, read and write the user's files, and debug the
application, so a finding whose attacker is same-user local code demonstrates
nothing. Demands for server-side VT sanitization: the parserless relay is a
design invariant, and a sanitizing server would be a second interpreter — the
exact failure mode the architecture forbids. Network attackers: no
non-loopback bind exists in v1, so transport-security findings are not
applicable until a remote-bind feature changes this section first. Attacks
that require the user to hand the one-time bootstrap URL to the attacker.

**Interim acceptance (tied to a gate).** Scene credentials now gate the demo
attach: the attach hello requires a per-scene secret, and the ambient session
cookie alone can neither attach nor mint a scene. The single-use, seconds-TTL
mint code rides the URL fragment, which keeps it out of the bootstrap
navigation, server logs, history, and referrers. The residual weakness is the
reusable loopback origin itself: a service worker a local actor registered on
a previously-bound instance of `http://127.0.0.1:<ephemeral-port>` controls
that origin and intercepts every same-origin HTTP request before any
server-side check runs — the bootstrap query carrying the startup bearer, and
the `POST /api/v1/scene` exchange carrying the mint code in a header and
returning the scene secret in its body. The fragment keeps the mint code off
the navigation but not out of that exchange fetch, so a stale worker still
reaches both the bearer and the exchanged scene credentials. (The attach
websocket handshake itself is not worker-interceptable.) It closes when the
bootstrap and the scene exchange move to a per-instance origin — a
high-entropy hostname or equivalent one-time handoff, chosen to resolve on
every supported browser including Safari — tracked as a blocker of the
browser-terminal milestone (kata#09w1). Until then the deployment posture
above bounds the exposure: the only actors who can run a loopback service and
register a service worker are local, and Ghosthub is run only where local
actors are trusted. The acceptance does not extend to any release that
exposes real multiplexer sessions to a browser.

Browser-side clipboard behavior is likewise gated by that milestone. Paste
sanitization implements the shared contract vectors today. OSC 52 clipboard
*writes* from the browser terminal are not yet honored: the vendored xterm
build registers no OSC 52 handler, so a write is silently ignored rather than
accepted. This fails safe — the browser never writes the clipboard without
the shared gesture-provenance, base64, size, UTF-8, and selection checks —
and the write path lands with those checks and the shared fixtures when the
browser terminal is accepted, not during the demo.

### Local external state tools

Local state providers such as the bundled kwt, git, and tmux are trusted
programs running as the user. The embedded kwt revision is part of Ghosthub's
signed release input. Their output must still be validated for compatibility
and correctness, but deliberate compromise of those programs or their on-disk
state is outside the security model.

Expanded worktree change panels read only semantic file-status records through
Ghosthub's exact pinned kwt helper. The worktree path, repository identity, and
durable generation are supplied as guards and revalidated against current
inventory after the read. Returned file paths and rename origins are displayed
as untrusted text; they are never executed, opened, used as navigation targets,
or passed to a mutation. Ghosthub does not request diff content, fetch from the
network, or store these records. Polling stops when the panel is unmounted, the
sidebar is hidden, the app is inactive, or the owning window loses key status.

Pull-request import is an explicit user mutation delegated to the bundled local
kwt or Ghosthub's exact managed kwt revision on the selected remote host.
Configuring a remote macOS or Linux host authorizes Ghosthub to install and
update that per-user helper during inventory refresh. Ghosthub selects a sealed
app resource, verifies its SHA-256 after upload, and never replaces a system
kwt. Automatic provisioning is disabled for Windows until its kwt executables
are Authenticode-signed. Adding a remote project is still explicit: Ghosthub
shell-quotes one user-supplied absolute path and delegates registration to the
managed kwt rather than scanning remote directories or editing configuration.
Ghosthub passes kwt's opaque candidate identity back
unchanged and does not construct provider refs, worktree paths, branches, push
destinations, or tmux names. The imported checkout remains
untrusted contributor-controlled source. Kwt suppresses repository hooks,
filters, setup commands, and credential prompts during import. It may invoke
the user's configured Git credential helpers noninteractively to authenticate
an HTTPS fetch, but Ghosthub does not receive or manage those credentials.
Ghosthub does not sandbox the checkout or commands the user later runs inside
its tmux session. Import itself does not start tmux or execute a configured
project layout, bootstrap, agent, or checkout command. It returns the
deterministic workspace-specific socket identity without creating the server.

Testing a newly configured SSH connection and reviewing a host-scoped
inventory warning acquire a kwt lease and delegate host-key verification and
storage to the user's OpenSSH configuration, just like native attachment.
Ghosthub asks its revision-pinned kwt CLI for an immutable route snapshot.
Kwt's same-account daemon resolves the route with system `ssh -G` inside the
account login shell using the invocation's working directory and a
request-scoped environment after protected credential variables are removed.
Ghosthub scopes that daemon to SSH controller work by setting `KWT_HOME` to
`ssh/kwt` under its resolved application state home for route, lease, and
`kwt ssh exec` processes. An unrelated account kwt daemon therefore cannot
silently satisfy those capability checks, and Ghosthub never stops or replaces
that shared daemon as part of connection polling. The scoped daemon is a
trusted local peer, but OpenSSH remains authoritative for SSH configuration
and policy. The exact connection probe runs only through the lease arguments
and releases client ownership afterward. Ghosthub never falls back to a second
Swift resolution or connection path when this boundary fails.

The snapshot binds the complete ordered route and effective configuration to a
route identity, while each hop's execution projection contains only the
versioned allowlist proven against Ghosthub's connection behavior. Unknown
policies, malformed snapshots, helper failures, masterless results, or identity
drift fail closed before a native presentation launches.

Kwt owns the OpenSSH masters used by long-lived remote tmux, Herdr, and Zellij
presentations. Ghosthub receives opaque, fail-closed multiplexed arguments plus
a route identity and generation; it never opens, adopts, probes, or removes
kwt's control sockets. A presentation retains one connection across its setup,
terminal process, pane actions, and identity checks. Concurrent owners of one
route share one lease, and the final owner's release returns it to kwt, so
kwt's idle policy and its immediate disconnect of forwarded-agent masters
remain authoritative; Ghosthub never keeps a lease alive past its last owner.
A shared lease that fails terminally, or whose master OpenSSH can no longer
reach, is marked unusable so no new caller joins it, and it is replaced on the
next borrow. Reconnect state stores no lease token or socket arguments and
must re-resolve and reacquire. Daemon replacement terminates the old
connection rather than transferring it, so the presentation follows its
ordinary detectable reconnect or disconnected-state path.

Kwt's askpass operation is authoritative for host-key and authentication
prompts. Host-key prompts carry kwt-parsed host, algorithm, and fingerprint
fields; Ghosthub never reclassifies or parses OpenSSH prompt prose. Ghosthub
presents each ordered, deadline-bound prompt in one eligible window and returns
the answer to that exact prompt event. Closing or canceling
the presenting window transfers the unanswered prompt to another subscriber;
it never cancels another window's interest or extends the deadline. With no
eligible presenter, the operation fails immediately with
`ssh_interaction_required`. Password and keyboard-interactive responses exist
only in app memory for that attempt and never enter arguments, environment,
logs, or persistent state. OpenSSH writes approved keys to its configured
known-hosts file. Short-lived operations are also kwt-owned and deliberately
noninteractive. Worktree mutations run through `kwt ssh exec`; Ghosthub never
receives their control path, proxy command, or private projection. Remaining
multi-command and route-conditional operations borrow the route's pooled
connection until their higher-level kwt contracts are available. Both paths
report `ssh_interaction_required` rather than presenting a background prompt or
falling back to app-owned SSH lifecycle state, and both revalidate current
OpenSSH configuration before execution.

Lease cleanup failures quarantine the route instead of allowing reuse. Every
later acquisition makes a bounded cleanup attempt and otherwise reports
`ssh_cleanup_failed`; daemon-side dead-client reaping is the final authority.
Application termination releases scene leases concurrently, then releases the
shared pool under one bounded wait. An expired bound may leave cleanup to kwt,
but never authorizes Ghosthub to unlink daemon-owned socket state.
Remote connection probes emit a leading delimiter before accepting exact
reachability and capability lines from stdout. Stderr and marker text embedded
in shell banners are diagnostics, so SSH or shell messages cannot spoof a
successful probe.
Ghosthub never forces `accept-new`, writes a scanned key itself, or treats a
trusted short alias as authorization for a canonical MagicDNS FQDN.
When an SSH route contains unseen intermediate hosts, each trust sheet labels
the host exactly as OpenSSH names it and approval advances only to the next
prompt. The secure-entry sheet names the exact route host and warns that the
host controls the challenge, so credentials for the final destination are not
presented to an intermediate hop. A deliberate Continue action can submit the
empty response required by some keyboard-interactive challenges. A later
prompt is never treated as proof that the reviewed host changed its key.
Kwt-owned presentation and command leases prevent silent enrollment at every
host in a direct ProxyJump list.
Host-key enrollment policy and proxy-route trust policy are owned by the
revision-pinned kwt helper; Ghosthub itself no longer sets `UpdateHostKeys`
or inspects `ProxyCommand` routes. Ghosthub's own guarantee is narrower:
lease arguments returned by kwt are validated against a strict allowlist
before OpenSSH runs, and a route snapshot whose execution projection is
unsupported fails closed.

When the user opens the imported workspace, Ghosthub invokes kwt's protected
attach command through the remote account's login shell when applicable. Kwt
resolves persisted provenance, validates the recorded project clone and
complete live worktree identity, and excludes prunable or missing worktrees.
Registered upstream identity remains authoritative when a configured clone's
origin is a fork. An unregistered clone is accepted only when its live Git
identity matches the recorded repository; ambiguous or conflicting
registrations fail closed. The protected command creates or repairs an inert
shell-only session on a deterministic workspace-specific tmux server; it never
executes the project's configured layout. Before the first pane starts, kwt
removes its provider and fleet credential variables from the server
environment. It also installs session removal markers and filters those
credential names from the session's effective `update-environment`. Because
pane processes can mutate tmux options, Ghosthub never treats that option as
authorization. The command verifies the exact workspace marker before
repairing an existing session, clears any parent tmux client identity, and
executes `attach-session -E`. If the endpoint cannot be resolved, inventory
retains the explicit protected attachment mode and omits the socket; clients
must not reinterpret that result as the default server.
Kwt's ordinary `open` and dashboard actions refuse imported workspaces before
they can create a parallel direct-mode session.
Ghosthub likewise rejects a successful import response with a missing or blank
socket identity and never lets a pending default-server creation with the same
session name authorize a protected workspace launch.
Project removal supplies kwt the exact persisted path and credential-free
repository identity returned by current project inventory. Kwt's daemon holds
the shared project lifecycle fence while it resolves durable pull-request
provenance, probes protected tmux endpoints, and compare-and-swaps the registry.
A changed registration, live protected session, or incomplete endpoint set
fails closed; the operation never kills sessions or removes filesystem data.
Kwt unconditionally protects `KWT_GITHUB_TOKEN` and `KWT_FLEET_TOKEN` as well
as the configured fleet token name. Non-secret kwt state such as `KWT_HOME`
remains available inside panes.

Because import selects the new workspace, inert attachment is not by itself
enough: any file Ghosthub reads from the imported checkout is contributor
input. A project's `.ghosthub/terminal.conf` is loaded into the app-wide
libghostty configuration, where keybindings and terminal behavior apply to
every surface rather than only the selected worktree. Ghosthub therefore
treats project terminal configuration as trusted user authorship and reads it
only from checkouts the user controls. Selecting an imported pull-request
workspace, identified by its explicit protected attachment mode, falls back to
the project's own checkout. This is a trust boundary, not a sandbox: Ghosthub
still does not constrain a configuration the user wrote, nor commands the
user runs inside a pane.

Names in the user's shared tmux server are identifiers, not credentials.
Ghosthub attaches to the exact session name reported by kwt or selected from
direct discovery. When the user explicitly requests a new named session,
Ghosthub may run one create-or-attach phase. Local creation uses an atomic
`new-session -A` client invocation; remote creation uses `has-session` and
detached `new-session` before attachment. The name is validated as a single
command argument and the selected host identity is fixed before launch.
Remote creation authority is one-shot: after it succeeds, transport recovery
can only rerun `attach-session`. Existing same-named sessions are attached
without modifying their panes or windows. Creation never grants authority to
rename, resize, or otherwise structurally mutate sessions. The user's explicit
Cmd-D and Cmd-Shift-D actions grant one-shot authority to run `split-window`
against the active pane of the attachment's fixed endpoint, frozen SSH
configuration, socket, and captured tmux server PID, session ID, and creation
time. Ghosthub enables these actions only after the attachment's local or
remote binary reports tmux 3.4 or newer. After attaching, each POSIX surface
writes its TTY under a unique attachment token on the target host. Ghosthub
uses that TTY to bind the surface to the client's stable PID, creation time,
server, and session identity. A single tmux conditional revalidates that bound
identity and pane before splitting. A rename remains valid, but a replacement
client or a client switched to another session after binding does not inherit
the authority. Failed
client bindings are not cached or allowed to discard later queued requests.
Keyboard
equivalents require effective terminal focus and no attached sheet; selecting
the File menu item is itself an explicit request. This bypasses tmux key
bindings by design but leaves pane creation, layout, and process startup inside
tmux. Native Windows psmux surfaces do not expose or intercept the pane-split
actions.

For Herdr 0.8.0 or newer, the same explicit split actions grant one-shot
authority to run `herdr pane split --direction right|down --focus` through the
active attachment's frozen endpoint, SSH configuration, executable, and session
socket. The command environment removes inherited Herdr routing variables and
sets only `HERDR_SOCKET_PATH`; it does not accept an external pane identifier.
Herdr's server chooses its session-global focused pane and remains responsible
for pane creation and layout. Requests serialize per attachment, are not
retried, and queued requests are dropped when the attachment is invalidated.
Herdr exposes neither a stable session-generation identifier nor a client
identifier, while its socket path is name-derived. A same-name replacement can
therefore inherit this low-harm constructive authority; Ghosthub documents that
limit instead of representing the stronger tmux identity guarantee. Shared
focus was verified on Herdr 0.8.0, and supported later versions are trusted to
preserve the contract.

The separate Kill Session action is offered only for a session established as running by
discovery or a currently connected active attachment. Before confirmation,
Ghosthub binds the selected endpoint, socket, exact target, and tmux
server PID, `session_id`, and `session_created` identity. One tmux conditional
compares all three live values and executes `kill-session` only on a match, so
retained inventory cannot authorize killing a same-named replacement,
including one created during the same timestamp second or after a rapid tmux
server restart. An active client is detached only after the kill succeeds.

Passive activity sampling receives no authority to mutate a warm session. Its
bounded `capture-pane` reads only recent scrollback, excluding the visible
screen, from an endpoint connected during the current app launch. Identity
reads on both sides of the capture must match the enrolled server PID, session
ID, creation time, and active pane; a session mismatch retires the target and
a pane mismatch discards the sample. The host computes the capture checksum
over the exact captured text, including trailing blank output, and adds only
its byte count and scrollback line count. That fixed-size fingerprint and the
identity metadata are all that cross SSH or enter application state. Ghosthub
does not log or persist captured terminal text or warm-session state.

Ghosthub applies the selected Tmux Theme when it creates a new bare session.
Attachment to an existing session does not add a client-local palette or modify
tmux visual styles by default. The explicit shared-session override may reset
status/message styles and set existing window foreground/background defaults.
This presentation-only exception targets the exact selected session, affects
every attached client, and does not authorize changes to tmux key tables,
prefixes, mouse behavior, windows, panes, layout, history, or process state.
The separate explicit pane-split shortcuts authorize only creation of one pane
at a time in the active attachment.

### Worktree sandboxes

The accepted worktree-sandbox design introduces an intentionally narrower
trust boundary than Ghosthub's ordinary terminals. The selected existing
worktree and its Git metadata are writable inside a local provider resource so
edits and commits are shared with the host. The provider is expected to prevent
direct filesystem access elsewhere on the Mac, subject to the explicit mounts
and capabilities in [Worktree Sandboxes](sandboxes.md). Ghosthub validates the
exact worktree generation and manages only resources bound to its persisted
identity; an unmanaged or same-named replacement is never adopted or deleted.

Apple `container` distinguishes a standard checkout with an in-worktree `.git`
directory from a linked worktree with a gitfile and distinct common Git mount.
It pins every writable ancestor of a protected target as a nested mount point,
then uses read-only-path controls for every effective repository config and
hook target it can resolve. A linked layout additionally protects its `.git`
gitfile and worktree-specific `commondir` and `gitdir`; a standard layout pins
its writable `.git` directory against replacement and has no indirection
files. Pinning writable ancestors prevents directory rename from replacing
protected paths. Creation fails closed when the layout or indirection does not
resolve to the expected relationship, when a required target or ancestor is
absent, escapes its expected root, has mutable symlink indirection, changes
during preflight, or cannot be protected, or when a protected file has a
second hard link. Protected directories receive the same hard-link check for
every regular file beneath them. This narrows Git-metadata injection but does
not make shared worktree content safe to execute later on the host.

Direct hook symlinks are resolved. An in-mount intermediate symlink is accepted
only when its parent is already a protected read-only directory, because
protecting the symlink path itself does not prevent live unlink and
replacement. Every in-mount canonical regular-file target is protected, every
canonical target inside or outside the mounted roots must have exactly one
hard link, and an invalid chain fails closed. Because Apple mount plans are
immutable after creation, every Start repeats full preflight and requires its
canonical result to match the persisted creation plan. A changed layout,
config/include/hook target, symlink resolution, hard link, or missing target
blocks Start and requires explicit recreation.

The Apple boundary does not recursively protect interpreters, scripts,
libraries, or data that an already-protected hook or Git config command refers
to from the writable worktree. A sandbox can change those shared files, and a
later host Git command may execute them automatically. The claimed protection
covers direct Git metadata, direct hook entries, and direct hook symlink
targets, not their arbitrary transitive runtime dependencies.

Docker sbx has a documented partial boundary. Its standard `.git/hooks`
directory is mounted read-only as defense in depth, but `.git/config` remains
writable because sbx 0.38 does not accept file workspaces. The read-only hooks
directory is not a security barrier: a sandboxed process can set
`core.hooksPath` into the writable worktree, or configure `core.fsmonitor`,
`include.path`, and filter, diff, or merge drivers. The sbx boundary therefore
protects the rest of the Mac from direct sandbox filesystem access but does not
protect against host-side code execution through this repository's Git
metadata. A layout-aware hash baseline reports Git indirection, config,
resolved hook-path, and in-mount direct hook symlink-target drift at detach and
later reconciliation. Stop and Delete
fence and terminate provider execution before their final comparison. Detected
drift and inability to capture or compare the baseline both become independent
security notices that survive sandbox and worktree deletion until the user
dismisses them. The warning is neither prevention nor attribution and cannot
protect a host Git command run before comparison.

Docker sbx also forwards the host SSH agent whenever its daemon has one. In the
supported 0.38.0 version there is no per-sandbox disable flag or setting;
removing `SSH_AUTH_SOCK` only from the create command does not remove a socket
already available to the daemon. Processes inside the sandbox can request
signatures, authenticate Git-over-SSH, sign commits, or authenticate to other
SSH services reachable under provider network policy. Private key bytes remain
in the host agent, but signature and authentication authority is intentionally
exposed. Ghosthub presents this capability before creation and never describes
sbx as credentials-off.

For Apple, Ghosthub does not pass `--ssh`, mount a home directory, copy
credentials, or configure credential helpers. For either provider Ghosthub
does not manage provider login, secrets, or network policy. Push behavior is
provider-dependent and never a Ghosthub guarantee; review and push from the
host is the recommended workflow.

Apple sandbox image authority is the tag-free digest embedded from
`SANDBOX_IMAGE`, not a mutable registry tag. Candidate provenance and SPDX
SBOM attestations, the canonical Apple 1.2.2 vetting report, current
vulnerability dispositions, and the production alias must all bind to that
same digest before promotion. The protected workflow reads a proposed pin and
report as inert Git blobs through the GitHub API. Promotion uses a
repository-dispatch event, whose workflow source and ref are the default
branch, rather than a caller-selected manual-dispatch ref. Only that trusted
default-branch job receives the dedicated package-writer credential. No
repository-wide `GITHUB_TOKEN` receives registry write permission. The local
developer who
runs the Apple vet and the protected-environment reviewer are trusted; the report
does not cryptographically prove that its Apple checks ran, so approval is
limited to a report the reviewer produced or independently witnessed. CI does
independently verify the signed provenance and SBOM, image source/version
labels, a deterministic digest of every reviewed image input from trusted
`main`, report age, current vulnerability policy, and exact image digest. A
promotion status is only a pointer: the pull-request gate verifies that its
target is a recent completed successful run of the trusted promotion workflow
for that exact head and current trusted-main base, whose retag job crossed the
protected environment. Run age is measured from immutable creation time, not
mutable completion time. Planning rejects report evidence or a vulnerability
disposition that cannot remain valid through the complete 24-hour status
lifetime, while run authorization ends after 23 hours. It
also fingerprints the full reviewer, deployment, and branch policy and the
status-signing environment. The approved runner requires exact matches and an
unchanged trusted-main workflow authority immediately before registry mutation.
A repository ruleset provisioned with no bypass actors or ref exclusions
requires that status from a dedicated status-only GitHub App. Global up-to-date
enforcement stays disabled; trusted reconciliation invalidates stale promotion
evidence without forcing unrelated pull requests to rebase after every `main`
change. The app private key exists only in a
no-reviewer
environment restricted by an exact branch policy to the `main` branch, never a
same-named tag. A pinned token action consumes that key; repository Python
receives only a separately minted read-only installation token and never the
key or status-write token. The package-writer credential likewise exists only
in a no-reviewer, exact-`main` environment. Exactly the trusted promotion-gate
and promotion workflows may reference the status environment, and exactly the
trusted publisher may reference the package-writer environment, under GitHub's
case-insensitive environment-name semantics. Only the trusted promotion
workflow may reference the reviewer-protected production environment, whose
variable and secret names are exact. Job-level reusable workflows are rejected
except for the exact repository-owned `ci.yml@main` call. Dynamic environment
selection is
rejected, every workflow declares explicit top-level permissions, the job
refuses non-`main` effective refs, and no
`GITHUB_TOKEN` has status-write or package-write authority. The GHCR package
does not inherit repository Actions access. At the final production-tag
mutation boundary,
trusted promotion authenticates the App owner, slug, permissions, private key,
and complete single-repository installation scope, then rechecks both required
rulesets, pull-request evidence, and tag availability immediately before the
registry write. The completed run records an App-authenticated production
environment fingerprint and the exact promotion run; reconciliation requires
both to match current live authority before restoring merge authorization.
Reconciliation fences all open heads before inspecting their metadata.
Trusted-main tooling audits the proposed workflow tree without executing it and
refuses any change to a credential-bearing workflow before authorizing the
exact pull-request head. Inability to reconcile leaves that head blocked rather
than preserving an old status.
Main changes, a new pin PR head SHA, the immutable promotion-plan deadline, and
the 24-hour run-age limit invalidate authorization. A
registry, tag, report, workflow-run, environment, ruleset, or attestation
disagreement fails closed.

The candidate publisher transfers a tested inert image archive into a fresh
credentialed job that does not check out or execute repository code. Promotion
finishes repository-controlled evidence, policy, attestation, and vulnerability
checks on a read-only runner. Human approval then starts a fresh runner that
executes only fixed identity, alias, and retag commands. Repository code never
shares a runner with the status-write token or package-writer credential. These
controls reduce credential exposure inside the trusted workflow. Reviewed
`main` remains the trust anchor: this boundary does
not claim to withstand malicious code that has already passed review and landed
on `main`. Defending against that stronger adversary would require an external
immutable publisher or service with an independently governed source tree.

This machinery is a process-integrity boundary against a repository agent or
fatigued human merging a pin before promotion, not a multi-administrator access
control system. Removing the gate is an honest future simplification; replacing
the dedicated app with the repository-wide GitHub Actions identity is not,
because branch-authored workflows can request that identity.
The image's non-root
`ghosthub` account has
passwordless sudo for ordinary tool installation; it is not an in-VM security
layer and is never represented as one.

Changing repository source, build scripts, editor configuration, or another
executable file inside the intentionally shared worktree is in scope for the
sandbox's work product and outside the claimed filesystem boundary when the
user later executes that content on the host. A report that bypasses the
declared mounts or mutates another worktree or unmounted host path remains an
in-scope sandbox escape. For sbx, host execution reached only through the
documented repository Git-metadata channel is a product limitation, not an
escape from the stated boundary.

### Release distribution

GitHub release hosting and the network paths used to fetch an appcast or DMG
are not trusted to authorize executable code. Each
packaged Ghosthub channel requires an HTTPS appcast signed with its embedded
Sparkle Ed25519 public key and verifies the update archive before extraction.
Signed-feed failures never expire into Sparkle's rotation fallback. Changing
an asset or feed after publication without an applicable signing identity must
therefore fail closed.

Release artifacts are also Apple Developer ID signed and notarized. This is an
independent platform integrity check, not a second mandatory authorization
factor: Sparkle intentionally accepts either a valid Ed25519 chain or a
matching Apple identity so applications can rotate a lost key or certificate.
Ghosthub does not intentionally use that rotation path. Stable and nightly use
different Sparkle keys, but both use the same Apple Developer ID identity, so
the keys are defense in depth rather than independent authorization factors.
Compromise of a trusted Sparkle private key or the shared Apple signing
identity is therefore a release incident, not a failure this model claims the
client can contain.

The first nightly install does not inherit Sparkle authorization. Its mutable
latest-DMG pointer is only a discovery convenience: before copying the mounted
app, the operator verifies Gatekeeper acceptance and pins both the DMG and app
code signatures to Kenn Software's Apple Team Identifier, `2YMZH84KR8`. The
DMG identity is checked before mounting it. Control of the nightly distribution
repository plus an unrelated notarized Developer ID therefore cannot authorize
a bootstrap app. Compromise of Kenn Software's shared Apple signing identity
remains a release incident under the preceding assumption.

Nightly eligibility treats a feed with either required Sparkle signature
missing or structurally incomplete as repairable. This check is operational,
not an authorization decision: verifying an enclosure signature requires the
archive bytes, while clients verify both the feed and downloaded archive with
Sparkle. A hostile nightly distribution repository can still suppress or
corrupt channel metadata and deny nightly-update availability, but cannot turn
that metadata into an accepted update without a trusted signing identity.

Nightly publication treats the latest release's manifest as an operational
consistency boundary. It rejects candidates that are older than or conflict
with the directly read manifest and requires that manifest to match the state
observed by eligibility. It uploads the complete candidate as a draft,
revalidates the public manifest, completes retention, and then publishes and
marks the draft latest in one release transition. This prevents delayed or
out-of-order trusted workflow retries from silently rolling back the completed
channel and prevents clients from observing a partially uploaded release. It
does not make GitHub an update-authority boundary or claim availability against
a hostile host; Sparkle and Apple signing retain those roles and a compromised
host can still deny service.

Stable-feed routing and publication authority are the operational boundary
that protects stable users from nightly automation. The unattended nightly
environment can create releases only in the separate
`kenn-io/ghosthub-nightly` distribution repository and cannot create or replace
a release asset in the canonical repository or change the stable appcast. The
protected GitHub `release-signing` environment and its independent approval
policy, the `main`-restricted unattended `nightly-signing` environment, the
organization-controlled 1Password vault, both Sparkle private keys, the shared
Apple signing credentials, and the `kenn-dist-update-bot` private key are
trusted operational components. The workflow mints a short-lived installation
token restricted to the nightly distribution repository and requests only
Contents write permission. Loss or suspected disclosure of a signing identity
or publication credential is a release incident governed by the Kenn
operations runbook; it is not resolved by silently generating a replacement
key.

## In-Scope Failures

Security work should prioritize failures that cross a boundary without first
compromising a trusted component, including:

- sending clipboard contents or other local data to a remote pane without an
  intentional user action or enabled policy
- bypassing the user's SSH host identity and authentication policy
- confusing host, worktree, pane, or session identity in a way that mutates a
  different target
- allowing a managed sandbox to read or write an undeclared host path, inherit
  a replacement worktree generation, or mutate an unverified provider resource
- killing or structurally mutating a tmux session through Ghosthub's ordinary
  presentation, or terminating a session other than the exact target confirmed
  by the user
- exposing secrets through logs, persistence, or UI surfaces beyond their
  intended scope
- accepting or presenting an application update whose appcast, archive, or
  Apple signature does not satisfy the packaged release policy
- unsafe parsing or memory errors reachable from ordinary supported terminal
  and tmux behavior

Benign disconnects, reconnects, large but ordinary output, and valid tmux
layouts remain reliability and product-correctness concerns even when they are
not security-boundary violations.

## Explicitly Out of Scope

- a malicious or compromised configured SSH host
- a hostile tmux server or pane process on a configured host deliberately
  attacking the terminal parser
- denial of service caused by a trusted peer intentionally sending malformed
  or unbounded output
- compromise of the local Mac, user account, SSH agent, shell startup files,
  configuration, or locally installed command-line tools
- sandboxing commands the user chooses to run in an ordinary terminal pane
  outside an explicitly managed worktree sandbox
- availability of the network, SSH service, tmux server, or external state
  provider
- availability of nightly updates after compromise of the nightly distribution repository
  or its delivery path

The configured-host assumption does not waive the explicit local-capability
boundaries above. A remote pane that obtains the Mac clipboard through OSC 52,
or mutates a different tmux session through ambiguous targeting, is an
in-scope boundary failure even if the triggering bytes originated on a trusted
peer.

## Review Classification

A report whose exploit prerequisite is only a malicious or compromised
configured SSH host is not a security release blocker under this threat model.
It may still identify worthwhile defense-in-depth or reliability work and
should be prioritized according to its effect during ordinary supported use.
Reports that cross an in-scope boundary, or that can be triggered without
control of a trusted peer, remain security issues.

Changes to these assumptions are product decisions. Update this document and
the relevant architecture or terminal-session contract in the same change
when Ghosthub begins supporting untrusted hosts, multi-user systems, sandboxed
workloads, a different transport boundary, or a different release-distribution
boundary.
