# Web UI prior art: freshell

Architectural notes from studying [freshell](https://github.com/danshapiro/freshell)
(MIT license), an adjacent browser-terminal system with the same "run at home,
reach it over VPN / Tailscale / SSH" posture as Ghosthub's web UI. We studied
its architecture; **no code was copied.** This document records what the study
validated, what we deliberately do differently, and what is worth adopting, so
the next person does not re-derive it. It is a design-rationale reference, not a
contract — [Web UI](web-ui.md) and [Threat model](threat-model.md) remain the
authorities.

## The load-bearing difference

freshell relays a **bare shell PTY**; Ghosthub relays an **attach client to a
multiplexer** (tmux / Zellij / Herdr). Almost every architectural divergence
follows from that one fact. Because freshell owns the raw stream, it must build
scrollback, replay, resume, and terminal-mode resync itself. Because Ghosthub
attaches to a multiplexer that already owns all of those, its relay can be far
simpler — see the state-authority principle in [Web UI](web-ui.md).

## What the study validated (we already do this)

- **Process-group teardown.** freshell kills the child's whole process group
  (`kill(-pid, SIGKILL)`), not just the direct child, and guards against a
  recycled pid, because a backgrounded grandchild otherwise leaks and can hold
  the PTY slave open. Ghosthub's PTY teardown independently arrived at the same
  design (non-reaping `waitid` pins the zombie leader, then the group is swept,
  then reaped). Convergent designs are reassuring here.
- **Two-tier output backpressure.** A bounded, drop-oldest per-connection queue
  guarantees bounded server memory; a sustained-overflow disconnect sheds a
  truly dead peer. Ghosthub has the bounded output queue plus a stalled-send
  timeout that cuts a non-draining viewer.
- **Ordering: `exit` behind queued output.** A terminal-exit signal must not
  overtake still-queued output, or the client tears down and renders a blank
  exited pane. freshell threads exit through the same FIFO; Ghosthub's close
  frame is sent only after teardown, as the teardown acknowledgment.
- **In-band, non-ambient credential for the websocket** (presented in the hello
  frame, never a cookie or URL). Ghosthub's scene secret travels the same way,
  and its fragment-delivered single-use mint code is stronger than freshell's
  `?token=` (a fragment never reaches the server at all).

## What we deliberately do NOT copy

- **A single global bearer token for everything.** freshell authenticates the
  page, every request, and the websocket with one long-lived shared secret and
  has **no per-session isolation, no expiry, and no revocation** — any
  authenticated client owns every shell on the host. Ghosthub's scene
  credentials are the opposite: per-scene secrets, idle and absolute lifetimes,
  established only from a single-use mint code. This is the gap that motivated
  building scene credentials at all.
- **Server-side UTF-8 decoding of the PTY stream into JSON strings.** freshell
  is not byte-transparent — invalid UTF-8 becomes U+FFFD, and it juggles UTF-8
  bytes versus UTF-16 code units for eviction (a real premature-eviction bug for
  box-drawing TUIs). Ghosthub relays raw **binary** frames; the browser is the
  only interpreter. Byte fidelity is the whole point of a parserless relay.
- **Server-side VT scanners** (batch-boundary, mode-projection, idle
  fingerprint). These exist in freshell only because it owns the raw stream and
  a bounded replay window; a reconnecting xterm would otherwise render wrong.
  Ghosthub's multiplexer redraws on reattach, so none of this is needed.
- **Advisory-only Origin.** freshell's TypeScript server logs Origin mismatches
  but never rejects (its Rust port hardened this). Ghosthub enforces exact Host
  and Origin from the start.

## Worth adopting later (mainly for the SPA pipeline, `y5d7`)

- **Asset-cache discipline.** Serve `index.html` with `no-store`, hashed assets
  as `immutable`, and — importantly — a **missing hashed asset must 404, never
  fall back to the SPA shell**, so version skew fails loudly instead of serving
  a broken bundle. Pair with a protocol-mismatch close that tells a stale client
  to reload. Ghosthub embeds assets in the binary rather than serving from disk,
  but the cache rules still apply.
- **Typed gap frames instead of silent loss.** Where bytes can be dropped
  (queue overflow, replay eviction), freshell emits a typed frame telling the
  client scrollback was truncated rather than losing it silently. Low priority
  for Ghosthub — reconnect re-attaches to the multiplexer, which redraws — but a
  clean idea if the demo raw-shell path is ever kept long-term.
- **Index-don't-own for history.** freshell never persists agent transcripts; it
  indexes each CLI's own on-disk history and shells out to the CLI's native
  `resume`. This is already Ghosthub's philosophy (kwt / tmux / Herdr / Zellij
  own identity and history; Ghosthub discovers), and it is why "resume from any
  device" is nearly free for both.

## Things to avoid outright

- **A dual TypeScript + Rust implementation kept in lockstep.** freshell is
  mid-port and maintains both, byte-matched. The parity tax is real; Ghosthub
  has one implementation.
- **No document CSP.** freshell renders untrusted terminal output and proxies
  arbitrary dev servers yet sets no document CSP — the study flags this as a
  gap. Ghosthub ships a strict CSP (script-src stays strict; inline styles are
  allowed only for the embedded terminal library's runtime stylesheet).
