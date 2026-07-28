# Development

This document collects the commands and workflows used to develop Ghosthub
locally. For initial setup, see [Quick Start](quickstart.md).

## Swift App

Build the macOS app:

```bash
make build
```

Launch the app (assembles and opens `dist/debug/Ghosthub.app`):

```bash
make run-app
```

The packaged debug app embeds kwt. By default, `make run-app` verifies and
builds the exact revision in `KWT_REVISION` at `.build/kwt/kwt`. Point
`KWT_BINARY_PATH` at an existing executable to test a separately prepared
build:

```bash
make run-app KWT_BINARY_PATH=/absolute/path/to/kwt
```

Such a bundle records `GhosthubKwtSourceRevision` as `unpinned` and takes
`GhosthubKwtVersion` from what that binary reports, so it never claims the
pinned provenance. Set `KWT_VERSION` and `KWT_SOURCE_REVISION` explicitly to
record a helper whose origin you know.

Run the compiler warning gate:

```bash
make swift-warning-check
```

Apply or check the SwiftFormat rules in `.swiftformat`. CI runs the check, so
a drifting file fails the build:

```bash
make format         # rewrite in place
make format-check   # report without changing anything
```

`make install-hooks` wires the same formatter into a pre-commit hook.

Run Swift tests:

```bash
swift test
swift test list   # enumerate tests without running
```

## Python tooling

The main Python tool is `tools/bootstrap_libghostty.py`. Run the test
suite through `uv`-managed pytest:

```bash
make python-test
```

Focused targets:

```bash
make test-libghostty-bootstrap
```

## End-to-end tests

The primary native workflow suite is:

```bash
make test-essential-workflows
```

This runs the focused kwt inventory, host resolution, sidebar, and ordinary
tmux attachment contracts.

## Apple Silicon macOS CI

Pull requests and pushes to `main` run `.github/workflows/ci.yml` on GitHub's
hosted `macos-26` Apple Silicon image. The workflow pins Xcode 26.0.1 and the
exact Zig 0.15.2 toolchain required by the pinned Ghostty source, then runs the
complete build and test gates in a fresh environment. Newer Xcode 26 SDK stubs
are not link-compatible with that Ghostty/Zig build-tool combination.

CI builds libghostty with `LIBGHOSTTY_XCFRAMEWORK_TARGET=native`, producing the
arm64 slice for the hosted runner. The project default remains `aarch64` for
developer Macs. The hosted runner is temporary coverage while the Intel
`mac-pro-intel` runner is prepared for an eventual architecture matrix.

## Remote SSH Host Prerequisites

Remote hosts are bootstrapped from the app (Settings → Remote Hosts);
there is no longer a dedicated SSH e2e make target. Headless Linux
hosts should provide:

- `git` and `tmux` on the non-interactive SSH `PATH`

Kwt does not need to be installed system-wide. After the connection succeeds,
use **Install kwt Worktree Helper** in Host Settings to copy Ghosthub's pinned
architecture-matched helper into the remote user's `~/.ghosthub/` directory.
On a fresh host, enter each existing checkout's absolute path under **Add
Project**. The managed helper records it through kwt's supported registry
command and Ghosthub refreshes project/worktree inventory. Tmux-only discovery
and attachment work without either optional action.

Ghosthub uses the host's OpenSSH configuration directly and invokes an
ordinary tmux client on the target host. Tmux owns windows, panes, layouts,
history, and session lifetime.

## Runtime state paths

- SQLite database: `~/.ghosthub/ghosthub.db`
- Ghosthub terminal config: `~/.config/ghosthub/ghostty.conf`

## Release packaging

A full local release-app build:

```bash
make release-app \
  RELEASE_APP_VERSION=0.1.0 \
  RELEASE_BUILD_VERSION=0.1.0
```

Ghosthub bundles kwt CLI helpers but no daemon. A clean `make release-app`
builds the pinned local helper and the Darwin/Linux amd64/arm64 remote matrix
automatically; `KWT_BINARY_PATH` may name an existing local executable instead.
Outputs land in `dist/release/`.

DMG build:

```bash
make release-dmg \
  RELEASE_APP_VERSION=0.1.0 \
  RELEASE_BUILD_VERSION=0.1.0
```

If Apple signing and notary environment variables are present, this
target also signs and notarizes the DMG. The full tag-release
workflow and secret setup live in [`release.md`](release.md).

## Working style

When making meaningful changes:

- Keep [`architecture.md`](architecture.md) in sync with feature and
  architecture decisions.
- Prefer adding or updating tests in the same change as logic
  changes.
- Do not introduce database migrations before the first production
  release.
- Keep [`release.md`](release.md) and
  `.github/workflows/release.yml` in sync when changing release
  automation.
