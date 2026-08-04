# Internal Quick Start

These instructions are for Kenn engineers and approved contributors. Ghosthub
currently targets macOS and requires a full Xcode install because it builds
Swift code and bootstraps libghostty locally.

## Prerequisites

- Full Xcode install, not Command Line Tools only.
- Active developer directory pointing at that Xcode:

  ```bash
  xcode-select -p
  ```

- Metal Toolchain installed for the selected Xcode.
- `uv` for Python tooling.
- Go for building Ghosthub's pinned kwt helper.
- A Zig version at least as new as `required_zig_version` in
  `Vendor/ghostty.version.json` for libghostty bootstrap.
- `git`, `xcodebuild`, and `xcrun`.

Complete Xcode's first-launch setup before bootstrapping:

```bash
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
xcrun --kill-cache
xcrun --sdk macosx --find metal
```

The pinned Zig build runner cannot link against an SDK that omits an
architecture required by the Zig executable or selected XCFramework target
from `libSystem.B.tbd`. Bootstrap checks the active SDK and, when necessary,
automatically exposes the newest compatible SDK already installed with Xcode
or Command Line Tools. It does not change the system-wide Xcode selection. See
[Troubleshooting](troubleshooting.md) if no compatible SDK is installed.

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
