---
title: Web UI
description: Locked v1 contract for the loopback web UI served by the Rust application
---

# Web UI

This document is the locked v1 contract for a browser-based UI served directly
by the Rust application on Windows and Linux. It is written before
implementation and governs the `web-ui` work. The native GPUI application
remains the primary presentation; the web UI is an additional, independently
owned client of the same runtime. Architecture context lives in
[Architecture](architecture.md) and [Windows and Linux Rust Port](rust-port.md);
security boundaries live in the [Threat Model](threat-model.md).

The web UI is a peer scene, not a mirror of the native window. It never shares
the native scene's selection, presentation, geometry, or confirmation state.

## V1 scope

In scope: host and session inventory, session attach and detach through
per-viewer multiplexer clients, and the loopback security boundary below.

Explicitly excluded from v1 (see [V1 exclusions](#v1-exclusions)): output
replay, PTY pooling and multi-viewer arbitration, constructive and destructive
session operations, and any non-loopback access.

## Ownership: Runtime, Scene, TerminalRelay

The current Rust `Workspace` mixes durable runtime state with what is really
per-client scene state (global selection, active presentation, retained
presentations, terminal geometry, surface handles) and exposes a
single-consumer `drain_events()` owned by the GPUI poll loop. The web UI
requires an explicit split into three ownership tiers.

### Runtime (one per process)

Owns host connections, inventory discovery and reconciliation, mutation
serialization, persistence, and generation-fenced revision publication. The
existing invariants — publication serialized under one lock, snapshots
internally consistent, inventory generations monotonic — are exactly the
consistency contract multiple concurrent clients require and must be
preserved unchanged.

### Scene (one per client)

A Scene owns per-client state: selected host, active selection, presentation
ownership, viewer geometry, pending confirmations, one-shot capabilities, and
event routing. The native GPUI window is one Scene. Each authenticated web
client is an independent Scene. Scenes never observe or mutate each other's
selection or presentations.

Strangler discipline: Scene may initially be introduced as a layer that
preserves the existing native `Workspace` API for GPUI. The web server must
not consume that API until selection, presentation ownership, geometry,
confirmations, and event routing are genuinely per-scene. A wrapper that
still shares this state merely hides the collision; sharing it across the
native window and a browser is a defect, not a milestone.

### TerminalRelay (one per viewer)

Terminal I/O is factored into a shared PTY process layer and two
presentation-specific workers:

- The shared layer owns command resolution, spawn containment (Job Objects on
  Windows), resize delivery, shutdown ordering, and child reaping. All
  launcher and process-lifetime behavior lives here exactly once.
- `TerminalWorker` (native): PTY bytes → alacritty parser → surface
  publication. Unchanged from today's worker semantics.
- `ByteRelayWorker` (web): PTY bytes ↔ bounded per-connection queues, with no
  server-side VT parser of any kind.

Invariant — exactly one VT interpreter per PTY. The parsed engine answers
device queries (device attributes, status reports, cursor position) by
writing responses back to the PTY. Mirroring those same output bytes to a
browser-side xterm.js instance would produce a second interpreter answering
the same queries and duplicate response bytes in the application's input.
The native worker therefore gains no raw-output tap; parsed and relay
presentations are disjoint worker types over the shared spawn layer.

Each web viewer receives its own multiplexer attach client in its own PTY.
tmux, Zellij, and Herdr are the broadcasters; Ghosthub performs no
server-side fan-out, replay, or resize arbitration across viewers in v1.

## Event routing

Events flow in three lanes with different delivery semantics:

1. **Internal runtime signals.** Consumed exactly once by the runtime's
   event pump (worker lifecycle, transport state transitions, reconciliation
   triggers). Never serialized to any client.
2. **Broadcast notifications.** Serializable, revision-bearing facts
   delivered to every connected Scene: inventory changed, operation
   completed, host connection state, errors. Delivery to one scene never
   consumes the notification for another.
3. **Addressed requests.** Interactive requests with exactly one permitted
   responder, routed only to the Scene that initiated the operation: SSH
   password and host-key prompts, clipboard read approval, and lifecycle
   confirmations. Each request carries an opaque one-shot capability that is
   invalidated when answered.

Fail closed on scene disappearance. If the initiating Scene disconnects or
expires while a request is outstanding, the request and its capability are
cancelled or expire; the underlying operation fails. Requests are never
reassigned to another Scene, silently or otherwise. Any other Scene may
explicitly retry the operation from the beginning, producing a new request
addressed to itself.

## Presentations and capabilities

A presentation ID is an opaque, unguessable reference minted server-side
after the runtime resolves an attach plan. It is a reference, not authority:
every HTTP and websocket operation that names a presentation re-validates
authentication and Scene ownership. Possession of an ID grants nothing.
Presentation creation requires a valid scene credential (see Scene
credentials under Security), and the minted presentation is owned by that
Scene.

Launch authorities remain in-process, single-use values. The existing
negative assertions proving they are neither `Clone` nor `Serialize` stay
authoritative; no wire format ever contains one. When presentation creation
resolves a launch capability, the server retains it in memory only, bound to
the requesting Scene, with a short TTL, and consumes it exactly once. An
expired capability requires a fresh creation request.

Presentation creation requires initial geometry: rows, columns, and pixel
dimensions measured from the viewer's actually painted region. The PTY and
attach client start at that size. Launching at a default size and resizing
after attach is forbidden; it reproduces the one-row-pane class of bugs
documented in Forge's invariant notes. A client that cannot yet measure real
geometry does not create a presentation.

## Reconnect: fresh attachment, not resume

The server sends a terminal close frame only after the previous
attachment's relay threads have joined and its PTY client is reaped, so
the close frame is the teardown acknowledgment a viewer serializes its
replacement attachment behind — two PTY clients never overlap on one
multiplexer session.

In v1 a websocket disconnect ends the presentation. Without replay, resuming
a raw PTY stream after missed bytes can leave xterm.js in a corrupted parse
state. On disconnect, in order: the relay terminates, the attach client and
PTY are torn down, and the presentation ID is invalidated. To continue, the
client creates a new presentation with current geometry, resets its terminal
buffer, and lets the multiplexer redraw the full screen.

The frontend `TerminalTransport` state machine must model this explicitly:
alongside `connecting`, `connected`, `exited`, and `failed`, it includes a
`resetRequired` (reconnecting-fresh) transition that tells the terminal pane
to clear its buffer and decoder before the replacement presentation attaches.
`connected → disconnected → connected` with a preserved buffer is not a legal
v1 sequence.

## Wire contracts

All HTTP routes and the websocket protocol are versioned. The first exchange
on every terminal websocket is a hello/capabilities handshake: one text frame
in each direction stating protocol version, frame and queue limits, and
capability flags. A client that requires an unsupported capability closes;
capability discovery by URL inspection is forbidden.

V1 hello fields. The server hello states `protocol`, `limits`
(`max_frame_bytes`, `max_message_bytes`, and `max_queued_output_bytes`; the
message limit applies to reassembled fragmented messages, and both size
limits are enforced, not merely advertised), and `capabilities`
(`replay: false`, `kitty_keyboard: false`, `unicode_width: 11`). The client
hello states `protocol` and `capabilities`, and must declare
`unicode_width: 11` (Unicode-11 width tables loaded) and
`ignores_conpty_mode_requests: true`. A missing or mismatched required
capability closes the socket with policy code 1008. Unknown fields are
ignored for forward compatibility.

Terminal and presentation websockets extend this exchange with scene
authentication; the capability-only `/ws/v1/hello` endpoint grants nothing
and omits these fields. A terminal client hello additionally states
`scene_id` and `scene_secret`, carrying the scene credential in the first
client frame per the Scene credentials contract. The server validates the
scene credential and the named presentation's ownership before any PTY
byte flows in either direction; a missing, expired, or mismatched scene
credential — or a presentation the scene does not own — closes the socket
with policy code 1008 and emits no terminal data. Terminal hellos may also
restate per-presentation limit and capability values.

Terminal framing after the handshake:

| Direction | Frame  | Payload |
| --- | --- | --- |
| server → client | binary | raw PTY output bytes |
| server → client | text | `exited`, `error`, lifecycle controls |
| client → server | binary | raw input bytes |
| client → server | text | `resize` (rows, cols, pixels), lifecycle controls |

Limits and backpressure are part of the contract: maximum frame and
reassembled-message sizes, a bounded per-connection output queue, and
close-on-backpressure. A viewer that
cannot drain within the bound is disconnected with a distinct close code
rather than buffered without limit or silently dropped mid-stream; the
fresh-attachment reconnect model makes this safe, because the replacement
presentation always renders a consistent multiplexer redraw.

Websocket and HTTP URLs carry opaque presentation IDs only — never host
names, endpoints, session names, or multiplexer kinds.

Inventory uses revision subscription, not polling: an authenticated
notifications channel pushes broadcast notifications and revision advances;
clients fetch revision-bearing snapshots when notified. The native 33 ms
poll loop is not reproduced over HTTP.

### Observed relay fidelity

A throwaway spike validated the parserless byte relay on the production pin
(portable-pty 0.9.0) through real `wsl.exe` → tmux 3.6 → ConPTY into headless
xterm.js, comparing rendered screen state row-for-row against
`tmux capture-pane`. Alternate screen, mid-session resize, SGR mouse,
24-bit color, wide characters, and a nested Zellij client all rendered
exactly; the relay architecture holds. Three consequences are encoded as the
required hello capability fields defined under Wire contracts:

- Kitty keyboard protocol is negotiated-unsupported through tmux (the query
  is swallowed without answer); servers advertise it truthfully.
- Unicode width is negotiated: clients need Unicode-11 width tables (stock
  xterm.js renders some emoji width 1 where tmux uses 2).
- Clients must silently ignore ConPTY-injected mode requests (for example
  `?9001h` win32-input-mode); the relay does not filter them.

The Escape key is encoded as a bare ESC byte (0x1B) sent immediately in its
own binary frame; encoders never synthesize Alt or meta through ESC-prefix
timing and never withhold the byte for local disambiguation. Delivery is
then governed by the multiplexer's own escape-time handling. A nested
multiplexer swallowing a lone ESC is accepted upstream behavior, recorded
with the other accepted multiplexer effects; full-chain input-encoding
tests land with the relay workers.

## Security

The v1 boundary is loopback-only, enforced in code rather than by default
configuration:

- The server binds an ephemeral loopback port. No non-loopback bind option
  exists in v1.
- An unguessable bearer credential is minted at startup and held in memory
  only; non-browser clients present it on every request, compared in
  constant time. Browsers bootstrap once via a query parameter that sets an
  HttpOnly, `SameSite=Strict` cookie and immediately redirects to a
  token-free URL — always, even when the client is already authenticated —
  so the credential never survives in the location bar or history.
- Browser cookies are scoped by hostname, never by port, so any loopback
  cookie is presented to every other loopback service the user browses. The
  session cookie therefore carries a per-instance session value distinct
  from the bearer credential, under a port-suffixed cookie name, and
  authorizes only the embedded page shell and scene establishment. It never
  authorizes terminal, presentation, lifecycle, or other state-changing
  operations; its capture by another loopback service grants none of them.
- Exact `Host` validation runs before routing on every request; a credential
  is required on every request; exact `Origin` validation runs on every
  websocket upgrade and state-changing request (ordinary navigations and
  asset fetches may omit `Origin`). No defense substitutes for another.
- Frontend assets are embedded in the binary and served locally under a
  strict Content-Security-Policy with no remote origins. The application
  never fetches UI code at runtime.
- Shutdown tears down every relay, attach client, and PTY, invalidates the
  credential, and closes websockets with proper close frames.

### Scene credentials

Scene identity is a credential, not an inference, and it is never minted
from ambient state alone. The bootstrap redirect mints a single-use
scene-mint code with a seconds-scale lifetime and delivers it in the
redirect fragment, which browsers do not transmit to servers; the page
removes it from history immediately and exchanges it — together with the
session cookie and exact Origin, in a state-changing request — for an
opaque scene id and scene secret. The code is consumed on first
presentation whether or not the exchange succeeds. The session cookie alone
can never mint a scene: a sibling loopback service that captures the
ambient cookie holds no mint code and gains no scene, presentation, or
terminal authority, even when it forges Host and Origin as a direct
client. Non-browser clients mint scenes with the startup bearer credential
directly.

Scene secrets are held in memory under two bounds enforced together: an
idle timeout of 30 minutes and an absolute lifetime of 24 hours from
minting. Expiry is refreshed only by successfully authenticated
scene-scoped HTTP requests and websocket data frames — never by failed
authentication, terminal output, or rendering. An expired scene requires a
fresh establishment from bootstrap. The scene secret travels only in a
request header on HTTP and in the first frame of a websocket; it is never
placed in a cookie or a URL, so it is never ambient and never crosses
loopback ports.

Presentations, confirmations, one-shot capabilities, and addressed requests
bind to the scene id, and every operation that names them re-validates the
scene secret. The version/capability hello endpoint grants nothing and may
be reached with the session cookie alone. An expired or invalidated scene
fails closed per the event-routing rules. The native GPUI scene is
in-process and carries no wire credential.

Terminal processes reached through the web UI have the same trust limits as
native attachments: the network path to remote hosts remains system SSH, and
web viewers gain no capability a native attachment would not have.

## Clipboard contract

There is one clipboard and paste policy with two implementations, not two
policies. The parsed native path enforces it server-side at the VT parser;
the web path enforces it client-side in the terminal frontend, because the
byte relay has no server-side parser. Both implementations are proven
against shared language-neutral test vectors — the existing `contracts/`
fixture pattern is the natural home — covering:

- OSC 52 write acceptance policy and size/encoding validation.
- OSC 52 reads: denied; read requests receive no clipboard contents.
- Gesture provenance: clipboard writes are honored only with a recent
  one-shot trusted user gesture; terminal output is never input provenance.
- Paste sanitization: C0/C1 control stripping, CRLF normalization, and
  bracketed-paste wrapping keyed to the terminal's current mode.

Clipboard reads from the browser are denied absolutely, matching the
native remote OSC 52 policy pinned by the shared contract vectors.
Gesture-gated reads, if ever offered, are a future capability outside the
locked v1 contract.

## Accepted multiplexer multi-client behavior

Per-viewer attach clients delegate fan-out to the multiplexer, and the
multiplexer's own multi-client semantics apply. These effects are accepted,
documented product behavior in v1, in the same way the Zellij
attach-resurrection race is documented:

- **tmux:** window sizing follows the user's tmux server policy (typically
  smallest attached client unless the user configures otherwise). One
  viewer's size can affect what other clients of the same session see.
  Ghosthub attaches to user-owned servers and does not manage server-wide
  tmux options to change this.
- **Zellij:** multiple clients share session state and sizing effects;
  existing attach-race documentation continues to apply.
- **Herdr:** focus and sizing are session-global; any attached client can
  affect every other client's view.

Mitigations such as Ghosthub-side resize arbitration require pooling and are
out of v1 scope.

## Crate and dependency boundaries

- A new `ghosthub-web` crate owns the HTTP server, websocket handling,
  byte-relay endpoints, and embedded frontend assets. It is added to the
  locked dependency policy like any other crate; the machine-enforced graph
  is the authority on its allowed edges.
- The async runtime (Tokio, with Axum) is confined to `ghosthub-web`. The
  runtime core stays synchronous (std threads and channels). The full linked
  closure must pass the workspace license gate.
- The frontend is a Svelte SPA embedded in the binary. Reusable terminal
  presentation — the xterm pane, split-tree algebra, paste and clipboard
  security modules, and renderer workarounds — lives in
  `@kenn-io/kit-ui/terminal`, Effect-free, with `@xterm/*` as peer
  dependencies. The pane accepts a transport-neutral `TerminalTransport`
  interface, not a websocket path. Forge retains an Effect-based adapter on
  its side; Ghosthub ships its own adapter speaking this document's
  protocol. Forge's invariant documentation travels with any extracted code.

## Delivery order

1. Extract Forge's pure terminal and UI pieces behind `TerminalTransport`
   into `@kenn-io/kit-ui/terminal`; Forge consumes them back.
2. Separate shared Runtime state from per-scene state behind the strangler
   rule above.
3. Factor PTY spawning into the shared layer with parsed and byte-relay
   workers.
4. Add the loopback-only, authenticated, versioned web server and embedded
   SPA.
5. Ship inventory plus attach/detach. Constructive and destructive
   operations arrive only after confirmations and one-shot capabilities are
   client-scoped end to end.
6. Add replay and pooling only in response to observed reconnect pain or
   SSH-process pressure, never speculatively.

## V1 exclusions

- Output replay of any kind (reconnect is always a fresh attachment).
- PTY pooling, multi-viewer sharing of one PTY, and resize arbitration.
- Constructive and destructive session operations from the web UI (create,
  kill, stop, restart, delete) until addressed requests and one-shot
  capabilities are client-scoped.
- Non-loopback binding, reverse-proxy trust, and any remote browser access.
- Scene handoff or migration between clients.
