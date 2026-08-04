---
title: Threat Model
description: Security boundaries and trust assumptions for Ghosthub
---

# Threat Model

This document defines the security claims Ghosthub makes and the assumptions
used to classify security findings. Ghosthub is a native terminal and tmux
control plane for one user across machines that user administers. It is not a
sandbox or a hardened client for attaching to hostile terminal servers.

## Assets and Security Goals

Ghosthub aims to protect:

- local user data exposed through app-mediated capabilities such as the
  clipboard
- terminal input and session metadata while they cross the network
- the session lifecycle boundary: ordinary presentation only attaches or
  detaches; creation and exact-target session termination require separate,
  explicit user actions, with confirmation before termination
- app-owned settings and persistence from unintended cross-host or
  cross-worktree mutation
- application-update integrity, rooted in the reviewed Sparkle Ed25519 key,
  with Apple Developer ID signing and notarization as independent defenses

The main security goals are to use the system SSH trust and encryption model,
avoid sending local data to a remote pane except through an intentional
terminal interaction, and keep tmux presentation non-destructive outside the
user's explicit named-session creation request.

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
user. This trust includes the host operating system, its SSH service, the tmux
server and socket, and processes running in panes Ghosthub attaches to. SSH
host authentication and transport confidentiality are delegated to the user's
OpenSSH configuration and host-key policy.

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

### Local external state tools

Local state providers such as the bundled kwt, git, and tmux are trusted
programs running as the user. The embedded kwt revision is part of Ghosthub's
signed release input. Their output must still be validated for compatibility
and correctness, but deliberate compromise of those programs or their on-disk
state is outside the security model.

Pull-request import is an explicit user mutation delegated to the bundled local
kwt or Ghosthub's exact managed kwt revision on the selected remote host.
Installing that remote helper is a separate explicit user action; Ghosthub
selects a sealed app resource, verifies its SHA-256 after upload, and never
replaces a system kwt. Adding a remote project is also explicit: Ghosthub
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
inventory warning delegate host-key verification and storage to the user's
OpenSSH configuration, just like inventory, attachment, and helper
installation. Ghosthub first reads the destination's effective configuration
with `ssh -G` and opens its private askpass review only when
`StrictHostKeyChecking` resolves to `ask` or `accept-new`; it never weakens a
configured `yes`, `no`, or `off` policy. For an unseen key, Ghosthub presents
the exact destination and fingerprint and returns `yes` only after explicit
approval. The approval is bound to the parsed algorithm and fingerprint, so a
benign address change cannot be mislabeled as a key change, and to the logical
host so the same key cannot authorize another route target. OpenSSH writes the
approved key to its configured `UserKnownHostsFile`,
after which Ghosthub retries the connection or inventory operation that led to
the review.
If OpenSSH then requires a password or another interactive response, Ghosthub
shows the exact challenge in a native secure field and brokers the response to
the system client through a user-only FIFO. The response exists in app memory
for that attempt but is never placed in process arguments, environment
variables, logs, or persistent storage. Later app operations share only the
authenticated control socket. The master has no persistence after the app
session ends: Ghosthub prevents it from forking, a parent-held watchdog pipe
terminates it if the app process disappears, the socket name contains an
app-launch nonce, and each launch uses its own process-owned socket namespace.
Startup cleanup removes only namespaces whose owner process is no longer
running, so a concurrent Ghosthub instance retains access to its masters. The
socket lives in the user-only Ghosthub state directory and is also scoped to the
logical destination, the normalized effective OpenSSH configuration for every
route target, and the proxy route. Changes to credentials, known-hosts files,
host-key identity, route, or app launch therefore cannot reuse an authenticated
master.
If that state path would exceed the Unix-socket limit, Ghosthub uses a random,
process-owned `/tmp` namespace with the same dead-owner cleanup rule and rejects
any path that remains too long.
Routine clients and generated ProxyJump helpers explicitly disable
`ControlMaster` and `ControlPersist`, so user configuration cannot turn them
into unsupervised persistent masters even when Ghosthub cannot prepare its
control socket. Authentication preparation
resolves one effective-config snapshot, verifies its cached control identity,
and launches the endpoint, route, authentication, and known-hosts options from
that same snapshot under an empty base SSH configuration. It restarts recovery
if the identity changed instead of mixing a cached socket path with live SSH
configuration.
Before Ghosthub reports authentication complete, it resolves the current route
and control path again; a mismatch terminates the stale shared session and
returns to explicit recovery.
Authentication uses the same account-login-shell boundary and guarded demo SSH
configuration as resolution and host-key review, so those phases cannot consult
different agent, configuration, or known-hosts state. Authentication removes
inherited `TMUX` and `TMUX_PANE` values before login-shell startup. Host-key
review launches with snapshot-derived endpoint, route, and known-hosts options
under an empty base SSH configuration, so live config changes cannot redirect
the reviewed operation.
Remote connection probes accept reachability and capability markers only from
stdout. Stderr is retained solely as diagnostics, so SSH or shell messages
cannot spoof a successful probe.
Ghosthub never forces `accept-new`, writes a scanned key itself, or treats a
trusted short alias as authorization for a canonical MagicDNS FQDN.
When an SSH route contains unseen intermediate hosts, each trust sheet labels
the host exactly as OpenSSH names it and approval advances only to the next
prompt. If that hop requires interactive authentication, Ghosthub establishes
its app-session master before asking OpenSSH for the next host's key. The
secure-entry sheet names that exact route host and warns that the host controls
the challenge. The label comes from the effective user, hostname, and port in
the launch configuration, so credentials for the final destination are not
presented to an intermediate hop. A deliberate Continue action can submit the
empty response required by some keyboard-interactive challenges. A later
prompt is never treated as proof that the reviewed host changed its key.
Routine inventory, transfer, and attachment operations prevent silent
enrollment at every host in a direct ProxyJump list. Review-managed `ask` and
`accept-new` connections also disable `UpdateHostKeys` so only the explicitly
approved key is persisted. Opaque ProxyCommand routes and jump hosts that
introduce another proxy route fail closed because Ghosthub cannot resolve every
intermediate trust policy independently.

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
executes `attach-session -E`. If provenance cannot be read, kwt fails
inventory rather than omitting the protected socket identity.
Kwt's ordinary `open` and dashboard actions refuse imported workspaces before
they can create a parallel session on the credential-bearing default server.
Ghosthub likewise rejects a successful import response with a missing or blank
socket identity and never lets a pending default-server creation with the same
session name authorize a protected workspace launch.
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
workspace, identified by its protected tmux socket, falls back to the
project's own checkout. This is a trust boundary, not a sandbox: Ghosthub
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
rename, split, resize, or otherwise structurally mutate sessions. The separate
Kill Session action is offered only for a session established as running by
discovery or a currently connected active attachment. Before confirmation,
Ghosthub binds the selected endpoint, socket, exact target, and tmux
server PID, `session_id`, and `session_created` identity. One tmux conditional
compares all three live values and executes `kill-session` only on a match, so
retained inventory cannot authorize killing a same-named replacement,
including one created during the same timestamp second or after a rapid tmux
server restart. An active client is detached only after the kill succeeds.

Ghosthub applies the selected Tmux Theme when it creates a new bare session.
Attachment to an existing session does not add a client-local palette or modify
tmux visual styles by default. The explicit shared-session override may reset
status/message styles and set existing window foreground/background defaults.
This presentation-only exception targets the exact selected session, affects
every attached client, and does not authorize changes to tmux key tables,
prefixes, mouse behavior, windows, panes, layout, history, or process state.

### Release distribution

GitHub release hosting and the network path used to fetch an appcast or DMG are
not trusted to authorize executable code. Packaged Ghosthub releases require an
HTTPS appcast signed with the embedded Sparkle Ed25519 public key and verify the
update archive before extraction. Signed-feed failures never expire into
Sparkle's rotation fallback. Changing an asset or feed after publication
without the private Sparkle key must therefore fail closed.

Release artifacts are also Apple Developer ID signed and notarized. This is an
independent platform integrity check, not a second mandatory authorization
factor: Sparkle intentionally accepts either a valid Ed25519 chain or a
matching Apple identity so applications can rotate a lost key or certificate.
Ghosthub does not intentionally use that rotation path. Compromise of the
trusted Sparkle private key can authorize an update and is therefore a release
incident, not a failure this model claims the client can contain.

The protected GitHub `release-signing` environment, its independent approval
policy, the organization-controlled 1Password vault, the Sparkle private key,
and the Apple signing credentials are trusted operational components. Loss or
suspected disclosure of either signing identity is a release incident governed
by the Kenn operations runbook; it is not resolved by silently generating a
replacement key.

## In-Scope Failures

Security work should prioritize failures that cross a boundary without first
compromising a trusted component, including:

- sending clipboard contents or other local data to a remote pane without an
  intentional user action or enabled policy
- bypassing the user's SSH host identity and authentication policy
- confusing host, worktree, pane, or session identity in a way that mutates a
  different target
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
- sandboxing commands the user chooses to run in a terminal pane
- availability of the network, SSH service, tmux server, or external state
  provider

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
workloads, or a different transport boundary.
