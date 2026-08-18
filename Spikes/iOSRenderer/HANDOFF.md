# iPad spike handoff

Status as of 2026-08-17: the renderer and input experiment is positive, and a
standalone remote tmux transport is implemented. The remaining acceptance step
is a live run against a real SSH host and existing tmux session.

## Where to resume

- Branch: `ios-spike`
- Current transport commit: `a4f57a2` (`Attach the iPad renderer spike to remote tmux`)
- Open Kata work: `qd13` (`Verify iPad remote transport reconnect and latency`)
- Detailed build and simulator instructions: `Spikes/iOSRenderer/README.md`

The branch contains ten focused commits beginning with the feasibility design
and ending with the SSH/tmux transport. It has not been merged into production
application structure.

## What is proven

The standalone iPadOS 17+ app can initialize Ghosthub's revision-pinned
libghostty, create a UIKit/Metal terminal surface, render ANSI and Unicode
content, encode software and hardware keyboard input, propagate exact terminal
geometry, and repeatedly destroy and recreate the surface safely.

The transport layer builds on SwiftNIO SSH and connects libghostty's external
I/O surface to an SSH session channel. It:

- verifies an explicitly supplied Ed25519 or ECDSA host public key;
- offers password authentication with the password retained only in memory;
- requests an `xterm-256color` PTY;
- attaches to one exact existing tmux session without creating or killing it;
- streams keyboard bytes, remote output, and window-size changes;
- disconnects only the SSH presentation; and
- retries after two seconds when a previously connected stream closes.

The Xcode project pins SwiftNIO SSH and its dependency graph in
`Package.resolved`. The spike remains isolated from Ghosthub's production UI,
persistence, host inventory, and release packaging.

## Last verified state

At `a4f57a2`, the app built, installed, and launched on an iPad Pro 13-inch (M5)
Simulator. The following repository gates passed:

```text
make test-ios-renderer
make test-libghostty-bootstrap
make python-test
swift test
make test-essential-workflows
make build
make format
make format-check
```

The focused iPad suite passed 17 tests. The broader runs passed 56 bootstrap
tests, 142 Python tests, 160 XCTest cases with five expected headless skips,
and 908 Swift Testing cases.

## What is not yet proven

No live SSH connection was attempted before pausing the spike. In particular,
these behaviors still need observation rather than inference from the
implementation:

- host-key verification and password authentication against a real server;
- correct display and interaction with an existing remote tmux session;
- keyboard latency and sustained output behavior;
- resize propagation to tmux; and
- recovery after an established network stream is interrupted.

The spike intentionally does not include public-key user authentication,
Keychain storage, first-use host trust, host or session discovery, tmux session
creation, production navigation, background lifecycle design, packaging, or
physical-device testing.

## Suggested next session

1. Build and launch the standalone target with the commands in the README.
2. On a test SSH host, enable password authentication and start a disposable
   tmux session.
3. Copy an independently trusted Ed25519 or ECDSA line from `known_hosts` into
   the app; do not derive trust from an unverified `ssh-keyscan` result.
4. Connect to the exact tmux session and verify typing, control/navigation keys,
   output rendering, rotation or window resizing, and clean disconnect.
5. Interrupt the established connection and confirm that the presentation
   reconnects without destroying the tmux session.
6. Record the result on Kata issue `qd13`. If the live checks pass, close that
   child and the `r2ge` feasibility epic before deciding whether to design a
   production iPad architecture.

The right decision point is still the live transport result. Renderer
viability is strong enough to continue, but this branch should remain an
experiment until that final boundary is exercised.
