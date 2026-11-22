# Internal quick start

Build and run the macOS app from source. This guide is for Kenn engineers,
approved contributors, and their coding agents. To install the released app,
follow the [public getting started guide](https://ghosthub.ai/docs/getting-started/).

The build embeds libghostty 1.4.0 compiled with Zig 0.17.0. The exact Ghostty
revision and compiler live in `Vendor/ghostty.version.json`, and `mise.toml`
pins the same Zig version for local builds.

## Prerequisites

Run `tools/dev_setup_wizard.sh` when setting up a new Mac or when
`mise exec -- make bootstrap-libghostty` fails. It walks through every item
below and runs the libghostty bootstrap, skipping steps that are already done.
It uses mise for builds, sets `DEVELOPER_DIR` only for its own process without
changing system-wide `xcode-select`, and asks before making any privileged move
into `/Applications`.

What the wizard checks:

- **Full Xcode 26.0.1** (not Command Line Tools alone), matching release CI. If
  another Xcode is selected system-wide, keep 26.0.1 installed beside it and
  run `export DEVELOPER_DIR="/Applications/Xcode_26.0.1.app/Contents/Developer"`
  in your shell (using the path printed by the wizard).
- Confirm the active release is 26.0.1:

  ```bash
  xcodebuild -version
  ```

- **Metal Toolchain** installed for that Xcode.
- **`uv`** for Python tooling.
- **Go** for building Ghosthub's pinned kwt helper.
- **Zig** pinned in `mise.toml` for libghostty bootstrap (do not substitute a
  newer minor release).
- **`git`**, **`xcodebuild`**, and **`xcrun`**.

Install [mise](https://mise.jdx.dev), then install the pinned Zig and Go
versions from the repository root:

```bash
mise install
mise exec -- go version
mise exec -- zig version
```

Because `mise install` does not add shims to your shell `PATH`, prefix build
and test commands with `mise exec --` (the wizard handles this automatically).

Finish Xcode's first-launch setup before bootstrapping:

```bash
sudo env DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
xcrun --kill-cache
xcrun --sdk macosx --find metal
```

The pinned Zig build runner needs an SDK whose `libSystem.B.tbd` includes every
architecture required by Zig and the target XCFramework. Bootstrap checks the
active SDK and automatically selects the newest compatible SDK installed with
Xcode or Command Line Tools without changing system-wide `xcode-select`. See
[Troubleshooting](troubleshooting.md) if no compatible SDK is found.

## Build and launch

```bash
mise exec -- make bootstrap-libghostty
mise exec -- make build
mise exec -- make run-app
```

- `make bootstrap-libghostty` is idempotent and exits immediately if staged
  artifacts already match `Vendor/ghostty.version.json`.
- `make build` builds Ghosthub and its native dependencies only; the repo uses
  no git submodules.
- `make run-app` also builds and embeds the exact kwt commit from
  `KWT_REVISION`. Set `KWT_BINARY_PATH` only when testing a separately built
  kwt binary.

## Run checks

```bash
mise exec -- make swift-warning-check
mise exec -- make swift-test
mise exec -- make python-test
mise exec -- make docs-build
```

If you change terminal startup, shell environment, terminal config, libghostty
bootstrap, key handling, or remote terminal code, run the full terminal
regression suite listed in `AGENTS.md`.

## Commit checks

Use the managed global Prek hooks rather than installing a per-repo hook. They
run formatting, basic file checks, and (on macOS) the Swift compiler warning
gate. See [Development](development.md) for running those checks manually.
