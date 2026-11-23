---
title: Threat Model
description: Security boundaries and trust assumptions for Ghosthub
---

# Threat model

This document defines Ghosthub's security claims and the trust assumptions used
to triage security findings. Ghosthub is a native hub for local and remote
tmux, Herdr, Rex, and Zellij sessions operated by one user across machines they
administer. It is not a sandbox and is not a hardened client for attaching to
hostile terminal servers.

## Assets and security goals

Ghosthub protects:

- **Local user data** reachable through app-mediated features such as the
  clipboard.
- **Terminal input and session metadata** in transit across untrusted networks.
- **The session lifecycle boundary:** normal viewing only attaches and
  detaches. Creating or ending sessions requires explicit user actions, with
  confirmation before tmux/Zellij **Kill** and Herdr **Stop**/**Delete**.
- **App-owned settings and local state** against cross-host or cross-worktree
  confusion.
- **Update integrity,** rooted in the channel-specific Sparkle Ed25519 key and
  feed-publication boundary, with Apple Developer ID signing and notarization
  as independent checks.

Core goals: rely on system OpenSSH for trust and encryption, never send local
data to a remote pane without an intentional user action, and keep normal
viewing non-destructive.

### Known backend identity limits

- **Herdr** has no stable session-generation ID. Ghosthub revalidates name,
  state, config paths, and host endpoint, and confirmations retain only the
  reviewed route key (reacquiring the route before mutation). Ghosthub does not
  claim protection against a same-name/same-socket replacement race. Both
  **Stop** (ends all processes) and **Delete** (permanently deletes saved
  layout, never offered on the default session) require confirmation.
- **Zellij** also has no stable session-generation ID. Ghosthub releases the
  preparation lease, then reacquires the reviewed route and revalidates host
  and active name before a confirmed kill, accepting the remaining
  check-to-command replacement race.

## Trust boundaries

### Local Mac and user account

The local Mac, the logged-in user account, and software installed under that
account are trusted. Ghosthub does not defend against a compromised local
account, library injection, tampered dev tools, or an attacker who can edit
Ghosthub's config or state. Packaged releases invoke their signed bundled kwt
by exact bundle path rather than resolving `kwt` from `PATH`.

### Configured SSH hosts

Every configured SSH host is a **trusted peer** administered by the user,
including its OS, SSH daemon, multiplexer servers/sockets, and processes inside
attached panes. Host authentication and transport encryption belong to system
OpenSSH and the user's `~/.ssh/config` and host-key policy.

Enabling an **exe.dev** account authorizes its SSH control destination to list
VMs for that account. Ghosthub accepts only documented JSON fields, uses each
returned `ssh_dest` verbatim, and applies OpenSSH config and host-key checks
normally when connecting. Because a compromised provider can influence which
SSH destinations Ghosthub lists, it sits inside the trusted-peer boundary (it
cannot silently approve VM host keys or inject terminal output through the
inventory response).

A malicious or compromised configured SSH host is outside this threat model.
Ghosthub does not claim availability, confidentiality, or parser hardening
against a hostile remote host sending malformed or unbounded terminal output;
resource limits and escape filtering on those paths are defense-in-depth and
correctness measures.

Trusting a host does not waive local capability boundaries:

- **OSC 52 clipboard writes:** allowed from remote panes only when permitted by
  `clipboard-write` so remote tmux copy mode can copy to macOS.
- **OSC 52 clipboard reads:** always blocked on remote surfaces regardless of
  `clipboard-read`. Ghosthub checks libghostty's semantic request type before
  touching the Mac pasteboard: only `paste_from_clipboard` can read the
  pasteboard, while OSC 52 reads receive an empty value.
- **Paste and copy safety:** bracketed-paste framing stays authoritative,
  unsafe unbracketed paste requires confirmation, and explicit Copy/Paste
  interactions disclose only the chosen content to the attached pane.

### Windows WSL host

An installed WSL environment and selected distro are local trusted peers under
the user's account. Ghosthub resolves only system-owned `wsl.exe` (never from
the current directory or `PATH`). Presence alone never executes `wsl.exe`
during initial window creation. After frame 1, automatic discovery may start
the WSL2 VM and distro and run short-lived tmux capability probes in isolated
socket namespaces without touching the user's default tmux server.

Discovery is bounded and cancellable. Missing WSL omits the host; startup,
timeout, admission, or protocol errors stay classified on that host without
restarting WSL, switching distros, or weakening admission. Attached WSL
processes share the same clipboard and paste rules as SSH hosts.

### Network

The network between Ghosthub and remote hosts is untrusted. Passive eavesdroppers
and active network attackers are in scope to the extent OpenSSH protects
against them; Ghosthub never weakens OpenSSH host verification, auth, or
encryption.

Anonymous daily usage pings go over HTTPS to PostHog using a random
installation UUID (no hardware ID, user, host, repo, path, command, or session
data; person profiles and GeoIP disabled; opt-out in Settings or via
environment variables).

### Loopback web UI (Rust applications)

Because Ghosthub provides shell access, the web UI must only be reachable over
trusted private transports: loopback, a Tailscale network, or an SSH tunnel
(never listening on an untrusted network). Findings that assume an attacker has
network access excluded by this posture are out of scope.

In v1, the web UI binds to an ephemeral loopback port only (no non-loopback
code path) with an in-memory startup bearer token, exact `Host` validation and
a required credential on every request, and exact `Origin` validation on every
WebSocket upgrade and state-changing request. Full wire rules live in
[Web UI](web-ui.md).

Use the classes below to triage web-UI security reports (a valid report names
an in-scope attacker class and a concrete capability gained):

- **In scope: hostile web content in the user's browser.** Protects against
  DNS rebinding, CSRF, cross-origin WebSocket upgrades, drive-by port scans,
  and credential leaks via history, cache, or referrers. Defenses: exact `Host`
  check before routing, exact `Origin` check on upgrades and mutations,
  credential required on every request, bootstrap redirect stripping the token
  from the URL bar with `no-store` and `no-referrer`, `HttpOnly`
  `SameSite=Strict` cookie, strict same-origin CSP (`script-src 'self'`, no
  inline scripts; inline styles allowed only for xterm.js's runtime stylesheet),
  and hello/idle timeouts on upgraded sockets.
- **In scope: other local users on a shared machine.** Because browsers scope
  cookies by hostname rather than port, another local user binding a loopback
  port could receive the session cookie if the user visits it. The cookie
  therefore carries a per-instance session value distinct from the bearer token
  and authorizes only the page shell and scene setup, never terminal I/O or
  lifecycle mutations. Each browser viewer is an independent scene holding a
  per-scene secret minted only with non-ambient proof (the bearer token or a
  single-use seconds-TTL bootstrap mint code), kept out of cookies and URLs,
  with bounded idle and absolute lifetimes. Interactive approvals (SSH prompts,
  clipboard reads, lifecycle confirmations) bind to one scene and fail closed
  if it disappears.
- **In scope: untrusted byte streams.** Output and clipboard traffic follow the
  same trust limits as native views. The server is a parserless byte relay by
  design; the viewer (xterm.js or the native engine) is the sole VT
  interpreter. Clipboard and paste rules follow the shared `contracts/clipboard/`
  vectors, and the browser-terminal milestone cannot pass with open gaps.
- **Out of scope:** same-user local processes (they can already spawn shells
  and debug Ghosthub); requests for server-side VT sanitization (violates the
  single-interpreter invariant); network attackers (no non-loopback bind in
  v1); attacks where the user hands the one-time bootstrap URL to an attacker.

**Interim acceptance (gated on `kata#09w1`):** scene secrets already gate the
demo attach (the ambient cookie alone cannot attach or mint a scene), and the
single-use mint code rides the URL fragment (off navigation requests, logs,
history, and referrers). One residual gap remains: because
`http://127.0.0.1:<port>` is a reusable loopback origin, a service worker
registered by another local user on an earlier bind of the same port can
intercept the bootstrap query and the `POST /api/v1/scene` fetch (though not
the WebSocket handshake itself). This closes when bootstrap and scene exchange
move to a per-instance origin (tracked as a blocker for the browser-terminal
milestone in `kata#09w1`). Until then, exposure is bounded by the local-trust
deployment posture and does not extend to any release exposing real multiplexer
sessions to a browser.

Browser paste sanitization implements the shared contract vectors today. OSC 52
clipboard *writes* from xterm.js are not wired up yet and fail safe (silently
ignored) until the shared gesture, base64, size, UTF-8, and selection checks
land with the browser-terminal milestone.

### Local external state tools

Local providers (bundled kwt, git, tmux) are trusted binaries running as the
user. The bundled kwt revision is signed release input; its output is still
validated for correctness, while deliberate compromise of local tools or their
on-disk state is out of scope.

#### Worktree changed files and pull-request import

- **Changed-file panel:** reads semantic Git status through pinned kwt guarded
  by path, repository identity, and durable generation, revalidated against
  current inventory after the read. Returned filenames and rename sources render
  as untrusted text (never executed, opened, or passed to mutations). No diffs,
  network fetches, or persistence; polling stops when unmounted, hidden,
  inactive, or not key.
- **Helper provisioning:** adding a remote macOS or Linux host authorizes
  installing and updating the sealed, SHA-256-verified kwt helper under
  `~/.ghosthub/` without touching system kwt. Automatic Windows provisioning
  stays disabled until Authenticode-signed. **Add Project** shell-quotes one
  user-supplied path and never scans remote filesystems.
- **Pull-request import:** Ghosthub passes kwt's opaque candidate ID verbatim
  without constructing refs, paths, branches, or tmux names. Imported checkouts
  are untrusted contributor code: kwt suppresses repo hooks, filters, setup
  commands, and credential prompts during import (allowing only noninteractive
  system/global Git credential helpers for HTTPS fetches) and does not start
  tmux or project layouts. Ghosthub does not sandbox commands the user later
  runs inside the pane.
- **Protected attach and project config isolation:** opening an imported PR
  workspace runs kwt's protected attach, validating provenance, clone identity,
  and live worktree identity (failing closed on conflict), stripping
  `KWT_GITHUB_TOKEN`, `KWT_FLEET_TOKEN`, and the configured fleet token from
  the isolated tmux server and `update-environment` (while keeping non-secret
  `KWT_HOME`), verifying the workspace removal marker, and attaching inertly
  with `attach-session -E`. Neither kwt nor Ghosthub ever treats a missing
  protected socket as the default server. Because `.ghosthub/terminal.conf`
  loads app-wide into libghostty, selecting a protected PR workspace falls back
  to the user's own project checkout instead of reading contributor-controlled
  `.ghosthub/terminal.conf`.
- **Project removal:** passes exact path, credential-free repository identity,
  and registration fingerprint; kwt holds its lifecycle lock, verifies
  provenance and protected endpoints, and compare-and-swaps the registry,
  failing closed on drift or live protected sessions and never deleting files
  or killing sessions.

#### SSH route resolution, leases, and prompts

- **Scoped SSH daemon:** Ghosthub runs kwt's SSH route/lease/`kwt ssh exec`
  commands with `KWT_HOME` set to `<state-home>/ssh/kwt` so an unrelated
  account kwt daemon cannot satisfy capability checks and connection polling
  never restarts the user's normal daemon. OpenSSH stays authoritative for SSH
  policy, and Ghosthub never falls back to a second Swift SSH path on failure.
- **Allowlisted route snapshots:** kwt resolves routes with `ssh -G` inside the
  login shell after stripping protected credential variables, returning an
  immutable snapshot bound to a route identity with allowlisted per-hop
  projections. Unknown policies, malformed snapshots, helper errors, masterless
  results, or route drift fail closed before launch.
- **Lease ownership and cleanup:** kwt owns OpenSSH ControlMaster sockets;
  Ghosthub validates returned lease arguments against a strict allowlist and
  never touches kwt's sockets directly. Shared leases release to kwt once the
  last owner leaves (forwarded-agent masters disconnect immediately). Broken
  leases are marked unusable; failed releases quarantine the route with bounded
  cleanup retries and daemon-side dead-client reaping as backstop. Reconnect
  stores no lease tokens and re-resolves from scratch; daemon replacement
  triggers normal detectable reconnect.
- **Prompt attribution and trust:** kwt's askpass parses OpenSSH host,
  algorithm, and fingerprint fields; Ghosthub never re-parses prompt prose.
  Each deadline-bound prompt targets one eligible window (transferring cleanly
  to the next subscriber on close/cancel, or failing with
  `ssh_interaction_required` if none exists). Answers stay in memory for that
  attempt only; approved keys are written by OpenSSH to `UserKnownHostsFile`.
  Short-lived background commands (`kwt ssh exec` and pooled borrowers) are
  strictly noninteractive and revalidate OpenSSH config first.
- **Jump hosts and probe framing:** remote probes emit a leading delimiter and
  parse markers from stdout only so banners cannot spoof reachability. Ghosthub
  never forces `accept-new`, never writes scanned keys, and never treats a
  short alias as trust for a MagicDNS FQDN. Every unseen ProxyJump hop shows
  its exact host name and warns that the named hop controls the challenge so
  final-host credentials are not given to an intermediate hop. Host-key
  enrollment and `ProxyCommand` rejection live in pinned kwt; Ghosthub enforces
  the strict lease-argument allowlist and fails closed on unsupported
  projections.

#### Session creation, splits, kills, activity, and themes

- **Creation:** tmux names are identifiers, not credentials. Explicit new
  sessions validate the name as a single argument on a fixed host (local atomic
  `new-session -A`; remote `has-session` + detached `new-session`, permanently
  demoted to attach-only on reconnect). Creation never authorizes renaming or
  mutating existing sessions.
- **Pane splits (`Cmd-D` / `Cmd-Shift-D`):** on tmux 3.4+, each surface writes
  its TTY under a unique attachment token so Ghosthub binds stable client PID,
  creation time, server, and session identity; one tmux conditional validates
  identity and active pane before splitting (following renames, rejecting
  replacement clients or switched sessions). On Herdr 0.8.0+, splits run
  `herdr pane split --direction right|down --focus` with inherited Herdr
  variables scrubbed and only `HERDR_SOCKET_PATH` set, accepting Herdr's
  lack of a stable generation ID. Windows/psmux omits splits.
- **Kill Session:** binds host, socket, target, server PID, `session_id`, and
  `session_created` before confirmation, then runs one tmux conditional
  checking all three live values so retained inventory can never kill a
  same-name replacement (even within the same second or after a fast restart).
  Active clients detach only after the kill succeeds.
- **Passive activity sampling:** read-only bounded `capture-pane` over recent
  scrollback (excluding visible screen) on warm sessions, bracketed on both
  sides by server PID, session ID, creation time, and active pane checks. Only
  the host-computed checksum, byte count, line count, and identity metadata
  cross SSH; terminal text is never logged or persisted.
- **Tmux themes:** applied only to newly created bare sessions or via the
  explicit shared-session override (status/message styles and existing window
  foreground/background only; never touches key tables, prefixes, mouse
  bindings, layout, or processes).

### Release distribution

GitHub hosting and download networks are untrusted. Packaged builds require an
HTTPS appcast signed by the channel's embedded Sparkle Ed25519 public key and
verify archives before extraction, with signed-feed expiration disabled so
tampered feeds or assets fail closed.

Apple Developer ID signing and notarization provide an independent platform
check, though stock Sparkle accepts either a valid Ed25519 chain or a matching
Apple identity for key rotation (Ghosthub does not intentionally use rotation).
Because stable and nightly share Kenn Software's Apple Developer ID identity
(Team ID `2YMZH84KR8`), separate Sparkle keys are defense in depth while
stable-feed routing and publication authority are the primary boundary keeping
unattended nightly automation away from stable users. Compromise of either a
Sparkle private key or the shared Apple identity is a release incident rather
than a client-contained failure.

- **Manual nightly enrollment:** bypasses Sparkle, so the operator must verify
  Gatekeeper acceptance and pin Team ID `2YMZH84KR8` on the DMG (before
  mounting) and on the app bundle.
- **Nightly manifest consistency:** nightly eligibility treats missing or
  incomplete feed signatures as repairable (an operational check, not client
  authorization). Publication validates against the directly read manifest,
  uploads a complete draft, revalidates, runs retention, and publishes as
  latest in one transition so out-of-order workflow retries cannot roll back the
  channel or expose partial uploads. A compromised hosting path can still deny
  availability, never forge a valid update.
- **Operational isolation:** unattended `nightly-signing` (`main`-restricted)
  mints a short-lived `kenn-dist-update-bot` token with Contents write access
  only to `kenn-io/ghosthub-nightly` and cannot alter `kenn-io/ghosthub`
  releases or the stable appcast. Approval-gated `release-signing`, the
  organization 1Password vault, both Sparkle private keys, Apple credentials,
  and the bot key are trusted operational components; suspected disclosure
  follows the Kenn operations runbook rather than silent key rotation.

## In-scope failures

Prioritize defects that cross a trust boundary without first compromising a
trusted component:

- Sending clipboard contents or local data to a remote pane without an
  intentional user action or enabled policy.
- Bypassing the user's SSH host-key or authentication policy.
- Confusing host, worktree, pane, or session identity in a way that mutates the
  wrong target.
- Killing or structurally mutating a session through normal viewing, or ending
  a session other than the exact confirmed target.
- Leaking secrets into logs, persistence, or UI beyond their intended scope.
- Accepting an update whose appcast, archive, or Apple signature violates
  packaged release policy.
- Unsafe parsing or memory errors triggered by ordinary supported terminal and
  tmux output.

Ordinary disconnects, reconnects, large benign output, and valid layouts are
reliability and correctness bugs rather than security-boundary violations.

## Explicitly out of scope

- A malicious or compromised configured SSH host.
- A hostile tmux server or pane on a configured host deliberately attacking the
  terminal parser.
- Denial of service from a trusted peer intentionally sending malformed or
  unbounded output.
- Compromise of the local Mac, user account, SSH agent, shell startup files,
  config, or locally installed CLI tools.
- Sandboxing commands the user chooses to run inside a pane.
- Network, SSH, tmux, or external-provider availability, or nightly update
  availability after compromise of the nightly repo or delivery path.

The trusted-peer assumption never waives explicit local capability boundaries:
a remote pane reading the Mac clipboard via OSC 52, or mutating the wrong
session through ambiguous targeting, is still an in-scope security bug even if
the bytes came from a trusted peer.

## Review classification

A report whose only prerequisite is a malicious or compromised configured SSH
host is not a security release blocker under this model (it may still be valid
reliability or defense-in-depth work). Reports that cross an in-scope boundary
or do not require controlling a trusted peer remain security issues.

Update this threat model alongside the relevant architecture or
terminal-session doc whenever Ghosthub adds support for untrusted hosts,
multi-user systems, sandboxed workloads, or a new transport or release
distribution boundary.
