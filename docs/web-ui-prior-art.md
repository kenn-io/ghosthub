# Web UI prior art: freshell

These notes summarize an architecture review of
[freshell](https://github.com/danshapiro/freshell) (MIT license), a browser
terminal with a similar "run locally, reach over VPN, Tailscale, or SSH" model
to Ghosthub's web UI. **No code was copied.** This document records what the
review confirmed, what Ghosthub intentionally does differently, and what ideas
are worth adopting later. It is a design reference only. [Web UI](web-ui.md)
and [Threat model](threat-model.md) remain the authorities.

## The core difference

freshell relays a **bare shell PTY**. Ghosthub relays an **attach client to a
multiplexer** (tmux, Zellij, or Herdr). Almost every design difference follows
from this boundary. Because freshell owns the raw stream, it must build
scrollback, output replay, session resume, and terminal-mode resync itself.
Because Ghosthub attaches to a multiplexer that already owns those behaviors,
its relay stays parserless and much simpler. See the state-authority rule in
[Web UI](web-ui.md).

## Patterns Ghosthub already shares

- **Process-group teardown.** freshell kills the child's whole process group
  (`kill(-pid, SIGKILL)`), rather than only the direct child, and guards
  against PID reuse so a backgrounded grandchild cannot hold the PTY slave
  open. Ghosthub's PTY teardown reached the same design independently: a
  non-reaping `waitid` pins the zombie leader, the group is swept, and the
  leader is reaped last.
- **Two-tier output backpressure.** A bounded, drop-oldest per-connection
  queue caps server memory, and a sustained-overflow disconnect drops dead
  peers. Ghosthub uses a bounded output queue paired with a stalled-send
  timeout to cut off viewers that stop draining.
- **Ordering `exit` behind queued output.** An exit signal must not overtake
  queued output, or the client tears down early and renders a blank pane.
  freshell threads exit through the output FIFO. Ghosthub sends the websocket
  close frame only after relay teardown finishes, making it an explicit
  teardown acknowledgment.
- **In-band, non-ambient websocket credentials.** freshell sends its
  websocket credential in the hello frame instead of a cookie or URL.
  Ghosthub sends its scene secret the same way and strengthens bootstrap by
  delivering a single-use mint code in the redirect fragment (which browsers
  never send to servers) instead of a `?token=` query parameter.

## Patterns Ghosthub intentionally avoids

- **One global bearer token for everything.** freshell uses a single
  long-lived secret across the page, HTTP requests, and websockets, with no
  per-session isolation, expiry, or revocation. Any authenticated client owns
  every shell on the host. Ghosthub mints per-scene secrets with idle and
  absolute lifetimes from a single-use mint code.
- **Server-side UTF-8 decoding into JSON strings.** freshell decodes PTY
  output as UTF-8, turning invalid bytes into U+FFFD, and mixes UTF-8 byte
  counts with UTF-16 code units during buffer eviction (causing premature
  eviction in box-drawing TUIs). Ghosthub relays raw **binary** frames so the
  browser stays the sole VT interpreter and byte fidelity stays intact.
- **Server-side VT scanners.** freshell runs batch-boundary, mode-projection,
  and idle-fingerprint scanners so a reconnecting xterm.js instance can recover
  from a bounded replay window. Ghosthub relies on the multiplexer to redraw on
  reattach, removing the need for server-side VT parsing.
- **Advisory-only `Origin` checks.** freshell's TypeScript server logs
  `Origin` mismatches without rejecting them (its Rust port later tightened
  this). Ghosthub enforces exact `Host` and `Origin` checks from the start.

## Ideas worth adopting (SPA pipeline, `y5d7`)

- **Asset-cache discipline.** *(Adopted in `y5d7`.)* Serve `index.html` with
  `no-store` and hashed assets as `immutable`, and return `404` for a missing
  hashed asset instead of falling back to the SPA shell so version skew fails
  loudly. Ghosthub embeds assets in the binary rather than reading them from
  disk, and applies the same rules: `build.rs` content-hashes each asset to
  `stem.<hash>.ext` and rewrites the page to match, while `service.rs` serves
  matching names as `immutable` and returns `404` for unknown ones. Pairing
  this with a protocol-mismatch close code that prompts stale clients to reload
  remains useful once the versioned frontend ships.
- **Typed gap frames instead of silent drops.** When queue overflow or replay
  eviction drops bytes, freshell sends a typed frame telling the client that
  scrollback was truncated. This is low priority for Ghosthub because reconnect
  reattaches and triggers a multiplexer redraw, but it is a good pattern if a
  raw-shell demo path is ever kept long-term.
- **Index history instead of owning it.** freshell never stores agent
  transcripts; it indexes each CLI's on-disk history and shells out to native
  `resume`. Ghosthub follows the same rule: kwt, tmux, Herdr, and Zellij own
  identity and history, and Ghosthub discovers them.

## Pitfalls to avoid

- **Maintaining two implementations in lockstep.** freshell maintains
  byte-matched TypeScript and Rust implementations during its port. Ghosthub
  keeps one Rust implementation.
- **Omitting a document CSP.** freshell renders untrusted terminal output and
  proxies local dev servers without a document Content-Security-Policy.
  Ghosthub ships a strict CSP: `script-src` stays strict, and inline styles are
  allowed only for the embedded terminal library's runtime stylesheet.
