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
make swift-test
swift test list   # enumerate tests without running
```

The test target gives every run its own pre-created `TMUX_TMPDIR` and removes
its tmux servers and sockets afterward. Cancelling a run forwards the signal
and gives the test group `GHOSTHUB_TEST_STOP_GRACE` seconds (default 20, or 2
under `tools/run_with_timeout.sh`) to unwind before it is force-killed. If a
test runner was hard-killed, use `make purge-test-tmux` to stop only
Ghosthub's test-prefixed tmux processes and remove their isolated and legacy
sockets; runs whose owning wrapper is still alive are left untouched.

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

This first builds the exact `KWT_REVISION` helper and exercises project
registration, daemon-backed inventory, removal of a missing checkout, and
inventory refresh in an isolated `KWT_HOME`. It then runs the focused kwt
inventory, host resolution, sidebar, and ordinary tmux attachment contracts.

## Apple Silicon macOS toolchain

Pull requests invoke the `main`-pinned `.github/workflows/ci.yml`. The
`GHOSTHUB_CI_RUNNER_MODE` repository variable selects the validation path for
canonical same-repository pull requests: `parallel` runs required hosted
validation beside advisory self-hosted validation, `self-hosted` runs required
self-hosted validation, and `hosted` runs required hosted validation. An unset
or invalid value falls back to hosted validation. Canonical `main` pushes, fork
pull requests, and noncanonical repository copies always run on GitHub's hosted
`macos-26` Apple Silicon image, independent of the selected mode.

The managed lane requires complete WindowServer GUI coverage. Hosted runners
explicitly exclude the five terminal smoke tests that require an active key
window instead of invoking them and accepting a runtime skip; the remaining
portable terminal and AppKit coverage continues to run there. The self-hosted
service account excludes the account-login-shell test, which continues to run
hosted. Both lanes reject every runtime skip among the tests selected for that
runner. Running hosted validation on every `main` push keeps that path
continuously usable as the fallback when self-hosted validation is preferred
for cost. Both lanes select a supported Xcode installation and the exact Zig
toolchain required by the pinned Ghostty source, then run their complete
available build and test gates.

Some newer Xcode SDK stubs do not advertise the plain `arm64-macos` target.
Local bootstrap checks every architecture required by the running Zig
executable and selected XCFramework target, then places a repository-local
`xcrun` shim ahead of `PATH` for the Zig process when the active SDK is
insufficient. SDK discovery points at the newest compatible installed SDK. The
selected developer directory and the caller's environment remain unchanged.
If no compatible SDK is installed, bootstrap stops with the searched locations
and the supported Xcode baseline instead of failing later with linker errors.

CI builds libghostty with `LIBGHOSTTY_XCFRAMEWORK_TARGET=native`, producing the
arm64 slice required by both runner paths. The project default remains
`aarch64` for developer Macs.

## Remote SSH Host Prerequisites

Remote hosts are bootstrapped from the app (Settings → Remote Hosts);
there is no longer a dedicated SSH e2e make target. Headless Linux
hosts should provide:

- `git` and `tmux` on the non-interactive SSH `PATH`

Kwt does not need to be installed system-wide. Ghosthub automatically copies
or updates its pinned architecture-matched helper in the remote user's
`~/.ghosthub/` directory when it loads inventory for a configured macOS or
Linux host. On a fresh host, enter each existing checkout's absolute path under
**Add Project**. The managed helper records it through kwt's supported registry
command and Ghosthub refreshes project/worktree inventory. Tmux discovery and
attachment continue to work if helper provisioning fails. Windows provisioning
remains explicit until its kwt executables are Authenticode-signed.

Ghosthub uses the host's OpenSSH configuration directly and invokes an
ordinary tmux client on the target host. Tmux owns windows, panes, layouts,
history, and session lifetime.

## Runtime state paths

- SQLite database: `~/.ghosthub/ghosthub.db`
- Ghosthub terminal config: `~/.config/ghosthub/ghostty.conf`

## Release packaging

A full local release-app build:

```bash
make release-app
```

The app version comes from `RELEASE_VERSION`; the build number defaults to the
current commit count. Override them only when deliberately testing alternate
packaging inputs.

Ghosthub bundles kwt CLI helpers but no daemon. A clean `make release-app`
builds the pinned local helper and the Darwin/Linux amd64/arm64 remote matrix
automatically; `KWT_BINARY_PATH` may name an existing local executable instead.
Outputs land in `dist/release/`.

DMG build:

```bash
make release-dmg
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
