# Internal Quick Start

These instructions are for Kenn engineers and approved contributors. Ghosthub
currently targets macOS and requires a full Xcode install because it builds
Swift code and bootstraps libghostty locally.

## Prerequisites

`tools/dev_setup_wizard.sh` walks through everything in this section and the
libghostty bootstrap, skipping steps that are already done. Run it when setting
up a new machine or when `mise exec -- make bootstrap-libghostty` fails; the list
below is what it checks. The wizard uses mise for builds and selects Xcode only
for its own process. It leaves the system-wide `xcode-select` setting unchanged.
When a manual Xcode install needs administrator access to `/Applications`, it
explains the privileged move and asks for confirmation first.

- Full Xcode install, not Command Line Tools only. Xcode 26.0.1 is the
  release CI validates; build with it. If another Xcode is selected, keep
  26.0.1 installed alongside it and build with
  `export DEVELOPER_DIR="/Applications/Xcode_26.0.1.app/Contents/Developer"`.
  Set this in your own shell for later builds too, using the installed path
  printed by the wizard.
- Confirm the selected release is exactly 26.0.1:

  ```bash
  xcodebuild -version
  ```

- Metal Toolchain installed for the selected Xcode.
- `uv` for Python tooling.
- Go for building Ghosthub's pinned kwt helper.
- A Zig version at least as new as `required_zig_version` in
  `Vendor/ghostty.version.json` for libghostty bootstrap.
- `git`, `xcodebuild`, and `xcrun`.

Install [mise](https://mise.jdx.dev), then run these commands in the repository
root to install the pinned Zig and the Go version configured in `mise.toml`:

```bash
mise install
mise exec -- go version
mise exec -- zig version
```

`mise install` does not add tools to your shell's `PATH`. Use `mise exec --`
for subsequent builds and checks as shown below; the wizard does this itself.

Complete Xcode's first-launch setup before bootstrapping:

```bash
sudo env DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -runFirstLaunch
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
mise exec -- make bootstrap-libghostty
mise exec -- make build
mise exec -- make run-app
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
mise exec -- make swift-warning-check
mise exec -- make swift-test
mise exec -- make python-test
mise exec -- make docs-build
```

For changes touching terminal startup, shell environment, terminal config,
embedded libghostty bootstrap, key handling, or remote terminal logic, run the
full terminal regression set listed in `AGENTS.md`.

## Install Hooks

```bash
mise exec -- make install-hooks
```

The hooks run formatting, basic file checks, and the Swift compiler warning
gate for Swift changes.
