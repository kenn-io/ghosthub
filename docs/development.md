# Development

Commands for building, formatting, testing, and packaging Ghosthub locally. For
first-time machine setup, see [Quick start](quickstart.md). Coding agents use
these same commands alongside `AGENTS.md`.

## Swift app

Build the macOS app:

```bash
make build
```

Assemble and launch `dist/debug/Ghosthub.app`:

```bash
make run-app
```

`make run-app` verifies and builds the exact `KWT_REVISION` commit at
`.build/kwt/kwt` and embeds it into the debug bundle. To test a separately
built kwt binary instead:

```bash
make run-app KWT_BINARY_PATH=/absolute/path/to/kwt
```

That bundle records `GhosthubKwtSourceRevision` as `unpinned` and reads
`GhosthubKwtVersion` from the binary itself. Pass `KWT_VERSION` and
`KWT_SOURCE_REVISION` explicitly if you want to record known provenance.

Run the compiler warning gate:

```bash
make swift-warning-check
```

Format Swift code according to `.swiftformat` (CI runs `make format-check` and
fails on drift):

```bash
make format         # rewrite in place
make format-check   # check without modifying files
```

The global Prek hooks run SwiftFormat and basic file checks on Linux and macOS,
and run the Swift compiler warning check on macOS (macOS CI also runs
`make swift-warning-check`). Linux commits need no hook exceptions. Do not
install a second per-repository hook.

Install the pinned SwiftFormat through mise so hooks can find it:

```bash
mise install swiftformat
mise exec swiftformat -- git commit
```

CI verifies the `mise.toml` SwiftFormat version against
`.github/swiftformat.sha256`. To bump SwiftFormat in one PR:

1. Update `swiftformat` in `mise.toml` to the new release number (such as
   `0.63.1`).
2. Update `.github/swiftformat.sha256` with the SHA-256 of `swiftformat.zip`
   from that release, named `swiftformat-<version>.zip`.
3. Run `mise exec -- make format` and commit the diff.

Run Swift tests:

```bash
make swift-test
swift test list   # list tests without running them
```

`make swift-test` creates an isolated `TMUX_TMPDIR` per run and removes its
tmux servers and sockets afterward. Canceling a run forwards the signal and
waits `GHOSTHUB_TEST_STOP_GRACE` seconds (default 20, or 2 under
`tools/run_with_timeout.sh`) before force-killing. If a run was hard-killed,
run `make purge-test-tmux` to clean up only Ghosthub's test-prefixed tmux
processes and sockets without touching any active test run.

## Python tooling

The main Python tool is `tools/bootstrap_libghostty.py`. Run all Python tests
through `uv`-managed pytest:

```bash
make python-test
```

Run just the libghostty bootstrap tests:

```bash
make test-libghostty-bootstrap
```

## End-to-end tests

Run the core native workflow suite:

```bash
make test-essential-workflows
```

This builds the pinned `KWT_REVISION` helper, exercises project registration,
daemon-backed inventory, missing-checkout removal, and inventory refresh in an
isolated `KWT_HOME`, and runs the kwt inventory, host resolution, sidebar, and
tmux attachment contracts.

Test Zellij attachment inside a native libghostty surface on macOS:

```bash
make test-zellij-attach ZELLIJ_BINARY_PATH="$(command -v zellij)"
```

This runs in a temporary directory (isolated config, cache, data, logs, and
sockets), creating sessions, selecting exact names among multiple sessions,
typing into their shells, and detaching/reattaching without touching your real
Zellij sessions.

Test direct SSH, ProxyJump, and interactive ProxyJump auth against two local
Docker hosts using the pinned kwt helper:

```bash
make test-ssh-authentication-docker
```

The interactive ProxyJump test checks that host-key confirmations and
encrypted-key passphrase prompts attribute each prompt to the right hop over
kwt's bounded prompt channel. All keys, known-hosts files, SSH config, kwt
state, and sockets stay in temporary directories and never touch your account's
SSH config or kwt daemon.

## Apple Silicon macOS CI and bootstrap

PRs run `.github/workflows/ci.yml` on GitHub's hosted `macos-26` Apple Silicon
image (`macOS (Apple Silicon, hosted)`).

Hosted CI skips the five terminal smoke tests that require an active key
window; run those locally with `make swift-test`. All other portable terminal
and AppKit tests (including the account login-shell test) run in hosted CI,
which rejects any unexpected runtime skip.

Bootstrap fetches Ghostty dependencies with `zig build --fetch=all` before
compiling, retrying twice on failure (after 5s and 10s) while reusing already
downloaded packages. Compilation itself runs once offline so compiler errors
fail immediately. If all three downloads fail, check the log to see whether it
was a transient network error or a broken URL/hash.

When a newer Xcode SDK omits plain `arm64-macos` from its stubs, local
bootstrap checks the required architectures and puts a repo-local `xcrun` shim
ahead of `PATH` for Zig pointing at the newest compatible installed SDK,
leaving `xcode-select` and your environment untouched. If no compatible SDK
exists, bootstrap fails up front with the paths it searched instead of hitting
a late linker error.

CI builds libghostty with `LIBGHOSTTY_XCFRAMEWORK_TARGET=native` (arm64 slice),
while developer Macs default to `aarch64`.

A separate macOS compatibility workflow builds the unsigned release bundle on
GitHub's Apple Silicon `macos-15` image with Xcode 26.0.1, checks every
Mach-O deployment target against the macOS 15 floor, and runs the libghostty
runtime smoke suite on Sequoia.

## Remote SSH host prerequisites

Configure remote hosts in **Settings → Hosts**. SSH end-to-end tests run via
`make test-ssh-authentication-docker` (local Docker) and
`make test-ssh-authentication-live` (opt-in against
`GHOSTHUB_SSH_INTEGRATION_DESTINATION`).

Headless Linux hosts need `git` and `tmux` on their non-interactive SSH `PATH`.
kwt does not need to be installed system-wide: Ghosthub copies and updates its
architecture-matched pinned helper under `~/.ghosthub/` on configured macOS and
Linux hosts during inventory. Register repositories through **Add Project**
with each checkout's absolute path. If a background helper update fails,
standalone tmux discovery and attachment keep working; Ghosthub retries
helper repair before an explicit project or worktree action and reports an
error only if repair still fails. Windows helper install stays manual until
the executables are Authenticode-signed.

Ghosthub reads your OpenSSH config directly and opens a normal tmux client on
the target host. tmux owns windows, panes, layouts, history, and session
lifetime.

## Runtime state paths

- SQLite database: `~/.ghosthub/ghosthub.db`
- Ghosthub terminal config: `~/.config/ghosthub/ghostty.conf`
- App-owned kwt SSH daemon state: `~/.ghosthub/ssh/kwt`

## Release packaging

Build a local release app bundle into `dist/release/`:

```bash
make release-app
```

Version comes from `RELEASE_VERSION`, and the build number defaults to the git
commit count. Local bundles also embed `git describe`, which About and
anonymous usage pings report in place of the release version.

`make release-app` bundles kwt CLI helpers (no daemon), building the pinned
local helper plus the Darwin/Linux amd64/arm64 remote matrix automatically
unless `KWT_BINARY_PATH` overrides the local binary.

Build a DMG (and sign/notarize it if Apple credentials are in the environment):

```bash
make release-dmg
```

See [Release](release.md) for the full tag-release workflow and secrets setup.

## Working style

- Keep [architecture.md](architecture.md) updated when feature or architecture
  assumptions change.
- Add or update tests in the same change as logic edits.
- Never add database migrations before the first production release.
- Keep [release.md](release.md) and `.github/workflows/release.yml` in sync.
