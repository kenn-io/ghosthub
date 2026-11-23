---
title: Web UI
description: Locked v1 contract for the loopback web UI served by the Rust application
---

# Web UI

This document is the locked v1 contract for the browser UI served directly by
the Rust application on Windows and Linux. It governs the `web-ui` work before
implementation. The native GPUI application stays the primary interface; the
web UI is an independent client of the same runtime. For broader architecture
and security boundaries, see [Architecture](architecture.md),
[Windows and Linux Rust Port](rust-port.md), and [Threat Model](threat-model.md).

Each web client is a peer scene, independent of the native window. It never
shares the native scene's selection, presentation, geometry, or confirmation
state.

## V1 scope

**In scope:**

- Host and session inventory.
- Session attach and detach through per-viewer multiplexer clients.
- The loopback security boundary defined below.

**Excluded from v1** (see [V1 exclusions](#v1-exclusions)): output replay, PTY
pooling, multi-viewer arbitration, constructive and destructive session
operations, and any non-loopback access.

**Core principle: the multiplexer owns session state.** Ghosthub never relays a
bare shell. It relays an *attach client* to tmux, Zellij, or Herdr, which
already owns scrollback, cursor and DEC-mode state, history, and session
lifetime. That boundary eliminates server-side replay rings, mode-resync
preambles, and cross-device resume protocols: reconnecting opens a fresh attach
client and the multiplexer redraws the screen. For the same reason, the relay
stays parserless and byte-transparent. Browser-side xterm.js is the single VT
interpreter; adding a second parser on the server would introduce conflicting
state. For how this differs from raw-shell web terminals, see
[Web UI prior art](web-ui-prior-art.md).

## Ownership: Runtime, Scene, TerminalRelay

The current Rust `Workspace` combines durable runtime state with per-client
scene state (selection, active and retained presentations, terminal geometry,
and surface handles) and exposes a single-consumer `drain_events()` method
driven by the GPUI poll loop. Supporting a web UI requires splitting that state
into three explicit ownership tiers.

### Runtime (one per process)

`Runtime` owns host connections, inventory discovery and reconciliation,
mutation serialization, persistence, and generation-fenced revision
publication. Its existing consistency rules remain unchanged so multiple
clients can read safely at once: publication stays serialized under one lock,
snapshots stay internally consistent, and inventory generations advance
monotonically.

### Scene (one per client)

A `Scene` owns per-client state: selected host, active selection, presentation
ownership, viewer geometry, pending confirmations, one-shot capabilities, and
event routing. The native GPUI window is one `Scene`, and each authenticated
web client is another. Scenes never read or mutate each other's selection or
presentations.

**Strangler rule:** `Scene` may start as a layer that keeps the existing
`Workspace` API intact for GPUI. However, the web server must not use that API
until selection, presentation ownership, geometry, confirmations, and event
routing are genuinely isolated per scene. Wrapping shared state only hides
cross-client collisions.

### TerminalRelay (one per viewer)

Terminal I/O splits into one shared PTY process layer and two disjoint worker
types:

- **Shared PTY process layer:** owns command resolution, spawn containment (Job
  Objects on Windows), resize delivery, shutdown ordering, and child reaping.
  All launcher and process-lifetime logic lives here once.
- **`TerminalWorker` (native):** reads PTY bytes into the libghostty parser and
  publishes paint surfaces. Native behavior stays unchanged.
- **`ByteRelayWorker` (web):** forwards raw PTY bytes through bounded
  per-connection queues with no server-side VT parser.

**Invariant: one VT interpreter per PTY.** A VT parser answers device queries
(such as device attributes, status reports, and cursor position) by writing
responses back to the PTY. Mirroring the same output stream to browser-side
xterm.js would run two parsers against one PTY and inject duplicate responses
into application input. `TerminalWorker` therefore never exposes a raw-output
tap; native and web presentations stay separate worker types over the shared
spawn layer.

Each web viewer gets its own multiplexer attach client in its own PTY. tmux,
Zellij, and Herdr handle multi-client fan-out; Ghosthub does no server-side
fan-out, replay, or resize arbitration in v1.

## Event routing

Events travel on three lanes with distinct delivery rules:

1. **Internal runtime signals.** Consumed once by the runtime's event pump
   (worker lifecycle, transport transitions, and reconciliation triggers).
   Never serialized to clients.
2. **Broadcast notifications.** Serializable, revision-bearing facts sent to
   every connected `Scene` (inventory updates, operation completion, host
   connection state, and errors). Delivering to one scene never consumes the
   notification for another.
3. **Addressed requests.** Interactive prompts routed only to the `Scene` that
   started the operation (SSH password and host-key prompts, clipboard read
   approval, and lifecycle confirmations). Each carries an opaque one-shot
   capability that becomes invalid once answered.

**Fail closed if a scene disappears.** If the initiating `Scene` disconnects or
expires while a request is pending, the request and its capability cancel or
expire and the operation fails. Requests are never reassigned to another
`Scene`. Another `Scene` can explicitly retry the operation from the start,
creating a new request addressed to itself.

## Presentations and capabilities

The server mints an opaque, unguessable presentation ID after the runtime
resolves an attach plan. The ID is only a reference: every HTTP and websocket
operation that names it revalidates authentication and `Scene` ownership.
Creating a presentation requires a valid scene credential (see
[Scene credentials](#scene-credentials)), and the resulting presentation
belongs to that `Scene`.

Launch authorities remain in-process, single-use values. Existing negative
tests proving they are neither `Clone` nor `Serialize` remain authoritative,
and no wire format ever carries them. When presentation creation resolves a
launch capability, the server holds it in memory bound to the requesting
`Scene` with a short TTL and consumes it once. An expired capability requires a
fresh creation request.

Presentation creation also requires initial geometry: rows, columns, and pixel
dimensions measured from the viewer's painted region. The PTY and attach client
start at that exact size. Launching at a default size and resizing afterward is
forbidden because it reproduces the one-row-pane class of bugs documented in
Forge's invariant notes. A client that cannot yet measure real geometry must
wait before creating a presentation.

## Reconnect: fresh attachment, not resume

The server sends a terminal websocket close frame only after the previous
attachment's relay threads join and its PTY client is reaped. Viewers serialize
any replacement attachment behind that close frame so two PTY clients never
overlap on the same multiplexer session.

In v1, every websocket disconnect ends the presentation. Without replay,
resuming a raw PTY stream after dropped bytes can corrupt xterm.js parser
state. On disconnect, the server runs teardown in order:

1. Stop the relay.
2. Tear down the attach client and PTY.
3. Invalidate the presentation ID.

To continue, the client creates a new presentation using its current geometry,
resets its terminal buffer, and lets the multiplexer redraw the full screen.

The frontend `TerminalTransport` state machine must model this transition
explicitly. Alongside `connecting`, `connected`, `exited`, and `failed`, it
includes a `resetRequired` (reconnecting-fresh) transition that tells the
terminal pane to clear its buffer and decoder before attaching the replacement.
Going from `connected` to `disconnected` and back to `connected` while keeping
the old buffer is invalid in v1.

## Wire contracts

All HTTP routes and the websocket protocol are versioned. Every terminal
websocket starts with a hello/capabilities handshake: one text frame in each
direction stating the protocol version, frame and queue limits, and capability
flags. A client that needs an unsupported capability closes immediately.
Clients must not infer capabilities by inspecting URLs.

### Handshake fields

- **Server hello:** includes `protocol`, `limits` (`max_frame_bytes`,
  `max_message_bytes`, and `max_queued_output_bytes`), and `capabilities`
  (`replay: false`, `kitty_keyboard: false`, `unicode_width: 11`). The server
  enforces both `max_frame_bytes` and `max_message_bytes` (which covers
  reassembled fragmented messages), rather than merely advertising them.
- **Client hello:** includes `protocol` and `capabilities`, and must declare
  `unicode_width: 11` (Unicode-11 width tables loaded) and
  `ignores_conpty_mode_requests: true`.
- **Validation:** missing or mismatched required capabilities close the socket
  with policy code `1008`. Unknown fields are ignored for forward
  compatibility.
- **Scene authentication:** terminal and presentation websockets extend the
  client hello with `scene_id` and `scene_secret` (the capability-only
  `/ws/v1/hello` endpoint grants nothing and omits these fields). The server
  validates the scene credential and presentation ownership before any PTY
  bytes flow. A missing, expired, or mismatched credential, or a presentation
  owned by another scene, closes the socket with policy code `1008` and emits
  no terminal data. Terminal hellos may also restate per-presentation limit and
  capability values.

### Terminal framing

After the handshake:

| Direction | Frame | Payload |
| --- | --- | --- |
| server -> client | binary | raw PTY output bytes |
| server -> client | text | `exited`, `error`, lifecycle controls |
| client -> server | binary | raw input bytes |
| client -> server | text | `resize` (rows, cols, pixels), lifecycle controls |

### Backpressure, URLs, and inventory updates

- **Bounded backpressure:** maximum frame size, reassembled-message size, a
  bounded per-connection output queue, and close-on-backpressure are part of
  the contract. If a viewer cannot drain within the bound, the server
  disconnects it with a distinct close code instead of buffering without limit
  or silently dropping bytes mid-stream. Fresh-attachment reconnect makes this
  safe because the replacement presentation gets a clean multiplexer redraw.
- **Opaque URLs:** websocket and HTTP URLs carry opaque presentation IDs only,
  never host names, endpoints, session names, or multiplexer kinds.
- **Revision subscriptions:** inventory updates travel over an authenticated
  notifications channel that pushes broadcast events and revision advances.
  Clients fetch revision-bearing snapshots when notified instead of reproducing
  the native 33 ms poll loop over HTTP.

### Observed relay fidelity

A throwaway spike tested the parserless byte relay on the production pin
(`portable-pty` 0.9.0) through `wsl.exe` -> tmux 3.6 -> ConPTY into headless
xterm.js, comparing rendered cells row-for-row against `tmux capture-pane`.
Alternate screen, mid-session resize, SGR mouse, 24-bit color, wide characters,
and a nested Zellij client all matched exactly.

Three findings from that spike are encoded in the required hello capability
fields above:

- **Kitty keyboard protocol:** tmux swallows the query without answering, so
  the server advertises `kitty_keyboard: false`.
- **Unicode width:** stock xterm.js renders some emoji at width 1 where tmux
  uses width 2, so clients must load Unicode-11 width tables
  (`unicode_width: 11`).
- **ConPTY mode requests:** ConPTY injects mode requests such as `?9001h`
  (win32-input-mode). The relay does not filter them, so clients must ignore
  them silently (`ignores_conpty_mode_requests: true`).

The Escape key sends a bare ESC byte (`0x1B`) immediately in its own binary
frame. Encoders never synthesize Alt or Meta using ESC-prefix timing and never
hold the byte for local disambiguation. Delivery follows the multiplexer's own
escape-time setting. A nested multiplexer swallowing a lone ESC is accepted
upstream behavior. Full-chain input-encoding tests land alongside the relay
workers.

## Security

The v1 boundary is loopback-only, enforced in code rather than through default
configuration:

- **Loopback bind only:** the server binds an ephemeral loopback port and
  exposes no non-loopback bind option in v1.
- **Startup bearer credential:** the server mints an unguessable bearer
  credential in memory at startup. Non-browser clients send it on every
  request, compared in constant time. Browsers bootstrap once via a query
  parameter that sets an `HttpOnly`, `SameSite=Strict` cookie and redirects
  immediately to a token-free URL (even if the client is already
  authenticated), keeping the credential out of the address bar and history.
- **Narrow session cookie scope:** because browser cookies scope by hostname
  rather than port, any loopback cookie is sent to other loopback services the
  user visits. The session cookie therefore holds a per-instance value distinct
  from the bearer credential under a port-suffixed cookie name, and authorizes
  only the embedded page shell and scene establishment. It never authorizes
  terminal, presentation, lifecycle, or state-changing requests; capturing it
  from another loopback port grants none of those actions.
- **Independent header checks:** exact `Host` validation runs before routing on
  every request; a credential is required on every request; exact `Origin`
  validation runs on every websocket upgrade and state-changing request
  (ordinary navigations and asset fetches may omit `Origin`). No check replaces
  another.
- **Embedded assets and strict CSP:** frontend assets are embedded in the
  binary and served locally under a strict Content-Security-Policy with no
  remote origins. The application never fetches UI code over the network.
- **Bounded shutdown:** shutdown tears down every relay, attach client, and
  PTY, invalidates the credential, and sends proper websocket close frames. The
  HTTP listener and upgraded handlers share one bounded grace period, keeping
  the runtime alive until handlers finish or the grace period expires.

### Scene credentials

*Implemented in `ghosthub-web` (`scenes.rs`, the exchange endpoint, and the
attach hello gate); this section is the authority.*

Scene identity is an explicit credential, never inferred from ambient state:

- **Minting a browser scene:** the bootstrap redirect puts a single-use
  scene-mint code with a seconds-scale lifetime in the URL fragment, which
  browsers never transmit to servers. The page strips the fragment from history
  immediately and exchanges it, along with the session cookie and an exact
  `Origin` header in a state-changing request, for an opaque `scene_id` and
  `scene_secret`. The mint code is consumed on first presentation whether the
  exchange succeeds or fails. A sibling loopback service that captures the
  session cookie holds no mint code and cannot mint a scene, even if it forges
  `Host` and `Origin` directly.
- **Minting a non-browser scene:** non-browser clients mint scenes directly
  with the startup bearer credential.
- **Lifetimes and transport:** scene secrets live in memory under two
  simultaneous bounds: a 30-minute idle timeout and a 24-hour absolute
  lifetime from minting. Only successfully authenticated scene-scoped HTTP
  requests and websocket data frames refresh the idle timer (never failed auth,
  terminal output, or rendering). Expired scenes must bootstrap again. The
  scene secret travels only in an HTTP request header or the first websocket
  frame, never in a cookie or URL, so it never leaks across loopback ports.
- **Binding:** presentations, confirmations, one-shot capabilities, and
  addressed requests bind to `scene_id`, and every operation naming them
  revalidates `scene_secret`. Only the capability-only `/ws/v1/hello` endpoint
  accepts the session cookie alone. Expired or invalidated scenes fail closed
  under the event-routing rules. The native GPUI scene runs in-process and uses
  no wire credential.

Terminal processes reached through the web UI follow the same trust boundaries
as native attachments: remote hosts still connect over system SSH, and web
viewers gain no extra capability beyond a native attachment.

## Clipboard contract

Ghosthub enforces one clipboard and paste policy through two implementations:
the native path enforces it server-side at the VT parser, while the web path
enforces it client-side in the terminal frontend because the byte relay has no
parser. Both implementations are tested against shared, language-neutral
vectors in `contracts/` covering:

- **OSC 52 writes:** acceptance policy plus size and encoding validation.
- **OSC 52 reads:** denied; read requests receive no clipboard data.
- **Gesture provenance:** clipboard writes succeed only with a recent one-shot
  trusted user gesture; terminal output never counts as user input.
- **Paste sanitization:** C0/C1 control stripping, CRLF normalization, and
  bracketed-paste wrapping matching the terminal's current mode.

Browser clipboard reads are always denied, matching the native remote OSC 52
policy pinned by the shared contract vectors. Gesture-gated reads are outside
the locked v1 contract.

## Accepted multiplexer multi-client behavior

Because each viewer opens its own attach client, the multiplexer's own
multi-client rules apply. These behaviors are accepted in v1 (just as the
Zellij attach-resurrection race is documented and accepted):

- **tmux:** window sizing follows the user's tmux server policy (usually the
  smallest attached client unless configured otherwise). One viewer's window
  size can affect other attached clients. Ghosthub attaches to user-owned
  servers and does not modify server-wide tmux options.
- **Zellij:** attached clients share session state and sizing effects, and the
  existing attach-race behavior still applies.
- **Herdr:** focus and sizing are session-global, so any attached client can
  change what other clients see.

Server-side resize arbitration requires PTY pooling and is out of v1 scope.

## Crate and dependency boundaries

- **`ghosthub-web`:** owns the HTTP server, websocket handling, byte-relay
  endpoints, and embedded frontend assets. Its allowed crate edges are governed
  by the workspace's machine-enforced dependency graph.
- **Async confinement:** Tokio and Axum live strictly inside `ghosthub-web`.
  The runtime core stays synchronous (`std` threads and channels). The full
  linked closure must pass the workspace license gate.
- **Embedded Svelte SPA:** reusable terminal pieces (the xterm pane, split-tree
  algebra, paste and clipboard security modules, and renderer workarounds) live
  in `@kenn-io/kit-ui/terminal`, Effect-free, with `@xterm/*` as peer
  dependencies. The pane takes a transport-neutral `TerminalTransport`
  interface instead of a websocket path. Forge keeps an Effect-based adapter on
  its side, and Ghosthub ships its own adapter implementing this document's
  protocol. Forge's invariant documentation travels with the extracted code.

## Delivery order

1. Extract Forge's pure terminal and UI modules behind `TerminalTransport` into
   `@kenn-io/kit-ui/terminal` and consume them back in Forge.
2. Split shared `Runtime` state from per-client `Scene` state under the
   strangler rule above.
3. Factor PTY spawning into the shared process layer with separate
   `TerminalWorker` and `ByteRelayWorker` consumers.
4. Add the loopback-only, authenticated, versioned web server and embedded SPA.
5. Ship inventory plus attach/detach. Add constructive and destructive
   operations only after confirmations and one-shot capabilities are
   client-scoped end to end.
6. Add output replay and PTY pooling only if real reconnect pain or SSH-process
   pressure justifies them, never speculatively.

## V1 exclusions

- Output replay of any kind (reconnect is always a fresh attachment).
- PTY pooling, multi-viewer sharing of one PTY, and resize arbitration.
- Constructive and destructive session operations from the web UI (create,
  kill, stop, restart, delete) until addressed requests and one-shot
  capabilities are client-scoped.
- Non-loopback binding, reverse-proxy trust, and any remote browser access.
- Scene handoff or migration between clients.
