# Ghosthub

Ghosthub is a pre-release macOS application for switching among local and
remote git worktrees and durable tmux sessions through native,
GPU-accelerated terminal surfaces.

- **What it is:** a worktree-centric tmux client built on libghostty. The
  sidebar organizes kwt workspaces and otherwise-unbound tmux sessions across
  the local Mac and configured SSH hosts.
- **What it owns:** discovery, native presentation, SSH keepalives, and
  reconnect. Tmux owns windows, panes, layout, history, and process lifetime.
- **What ships:** `Ghosthub.app` with a revision-pinned local kwt helper.
- **License:** GNU Affero General Public License v3.0. See [`LICENSE`](LICENSE).

Architecture and product scope live in
[`docs/architecture.md`](docs/architecture.md); the full documentation
index is in [`docs/README.md`](docs/README.md).

## Status

Ghosthub is pre-release.

- No production deployments yet.
- Database migrations are intentionally out of scope until the first
  production release; pre-release schema changes edit the current
  bootstrap schema directly.
- The macOS app launches only after repo-local `libghostty` artifacts
  have been bootstrapped.
- Ghosthub is isolated from any installed `Ghostty.app`: repo-local
  `libghostty` artifacts, Ghosthub-owned config at
  `~/.config/ghosthub/`, and Ghosthub-owned state under
  `~/.ghosthub/`.

## Prerequisites

Requires **macOS 26 (Tahoe) + Xcode 26** to build and run.

On macOS:

- Full Xcode install with SwiftPM support (not just Command Line Tools)
- Active developer directory pointing at that Xcode (`xcode-select -p`)
- Metal Toolchain installed for the active Xcode selection
- Python 3 and [`uv`](https://github.com/astral-sh/uv) for the
  automation in `tools/`
- `zig` 0.15.2 or newer for the libghostty bootstrap
- `git`, `xcodebuild`, `xcrun`
- [`kwt`](https://github.com/kenn-io/kwt), or an explicit
  `KWT_BINARY_PATH`, for assembling a development app bundle
- Network access during bootstrap (fetches the pinned Ghostty source)

## Quick Start

```bash
# One-time: fetch + build libghostty against the pinned Ghostty revision.
make bootstrap-libghostty

# Build and launch the app.
make build
make run-app

# Run the test suites.
swift test
make python-test
```

`make bootstrap-libghostty` is idempotent — it exits without rebuilding
when staged artifacts already match the pinned revision. If the app
fails to launch with a bootstrap error, re-run that target.

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for common
bootstrap failures (zig version, Metal toolchain, Xcode selection).

For end-to-end testing against a real SSH host, see
[`docs/development.md`](docs/development.md#end-to-end-tests).

## Repository Layout

| Path | Contents |
|------|----------|
| `Sources/` | Swift modules for the macOS app (`App`, `UI`, `Workspace`, `Settings`, `Persistence`, `Terminal`, `TerminalSupport`) |
| `tools/` | Python automation for libghostty bootstrap and packaging |
| `Tests/` | Swift test suites and colocated Python tests |
| `Resources/`, `Vendor/` | Bundled assets and Ghostty bootstrap/version metadata |
| `scripts/` | Release scripts |
| `docs/` | Architecture, development, release, and troubleshooting docs |

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — product and architecture source of truth
- [`docs/threat-model.md`](docs/threat-model.md) — security boundaries and trust assumptions
- [`docs/terminal-sessions.md`](docs/terminal-sessions.md) — terminal ownership, shell startup, and restart semantics
- [`docs/development.md`](docs/development.md) — development workflows and remote-host integration
- [`docs/release.md`](docs/release.md) — signing, notarization, and release automation
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — bootstrap failures and common fixes

Agent-facing conventions live in [`AGENTS.md`](AGENTS.md) and
[`CLAUDE.md`](CLAUDE.md). Contributor-facing conventions live in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

Copyright 2026 Kenn Software LLC. Licensed under the GNU Affero General Public
License v3.0. See [`LICENSE`](LICENSE).
