# Quick Start

Ghosthub currently targets macOS and requires a full Xcode install because it
builds Swift code and bootstraps libghostty locally.

## Prerequisites

- Full Xcode install, not Command Line Tools only.
- Active developer directory pointing at that Xcode:

  ```bash
  xcode-select -p
  ```

- Metal Toolchain installed for the selected Xcode.
- `uv` for Python tooling.
- Go for building Ghosthub's pinned kwt helper.
- `zig` 0.15.2 or newer for libghostty bootstrap.
- `git`, `xcodebuild`, and `xcrun`.

## Build and Launch

```bash
make bootstrap-libghostty
make build
make run-app
```

`make bootstrap-libghostty` is idempotent. If the staged artifacts already
match `Vendor/ghostty.version.json`, it exits without rebuilding.

`make build` builds only Ghosthub and its native dependencies. The repository
does not initialize or build git submodules.

`make run-app` also builds and embeds the exact kwt revision recorded in
`KWT_REVISION`. Set `KWT_BINARY_PATH` only to package an existing, separately
prepared kwt executable.

## Run Checks

```bash
make swift-warning-check
swift test
make python-test
make docs-build
```

For changes touching terminal startup, shell environment, terminal config,
embedded libghostty bootstrap, key handling, or remote terminal logic, run the
full terminal regression set listed in `AGENTS.md`.

## Install Hooks

```bash
make install-hooks
```

The hooks run formatting, basic file checks, and the Swift compiler warning
gate for Swift changes.
