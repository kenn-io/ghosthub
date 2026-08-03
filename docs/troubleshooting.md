# Troubleshooting

Common bootstrap and build failures and how to fix them.

## App fails immediately on launch with a libghostty bootstrap error

Rerun bootstrap:

```bash
make bootstrap-libghostty
```

The target is idempotent; if staged artifacts already match the
pinned Ghostty revision, it exits without rebuilding. If bootstrap
still fails after this, check the sections below.

## Bootstrap fails because `zig` is older than the pinned Ghostty requirement

Install a newer zig (0.15.2 or later) and point the bootstrap at it
explicitly:

```bash
brew install zig
make bootstrap-libghostty LIBGHOSTTY_ZIG=/opt/homebrew/bin/zig
```

## Bootstrap fails with `missing Metal Toolchain`

Complete first-launch setup and install the toolchain component for the active
Xcode selection:

```bash
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
xcrun --kill-cache
xcrun --sdk macosx --find metal
make bootstrap-libghostty
```

If that still fails, make sure the active developer directory points
at a full Xcode install rather than Command Line Tools only:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
make bootstrap-libghostty
```

## Bootstrap reports that the active macOS SDK is incompatible

The pinned Zig build runner needs every architecture used by the Zig
executable and selected XCFramework target in the SDK's `libSystem.B.tbd`.
Some newer SDKs advertise only `arm64e` instead of plain `arm64`; cross and
universal builds may require both `arm64` and `x86_64`. Ghosthub detects this
before building and automatically uses the newest compatible macOS SDK already
installed with Xcode or Command Line Tools. The selected fallback is printed
during bootstrap.

If bootstrap reports that it could not find a compatible SDK, install or
select the supported Xcode baseline named in the error and rerun:

```bash
make bootstrap-libghostty
```

Do not add `--sysroot` to `LIBGHOSTTY_ZIG_BUILD_ARGS` for this failure. That
flag reaches the Ghostty build command but not the Zig build-runner compile
that fails first.

## Verify bootstrap state without rebuilding

```bash
make check-libghostty
```

Reports whether staged `libghostty` artifacts match the pinned
Ghostty revision.

## Remote tmux attach fails on an SSH host

Confirm the remote host has `git` and `tmux` on its login-shell `PATH`, then
verify the same SSH destination works with the system `ssh` command. Kwt does
not need a system installation: use **Test Connection** followed by **Install
kwt Worktree Helper** in Host Settings when project inventory is missing. If the host
has never used kwt, enter an existing checkout's absolute path under **Add
Project** from the **+** menu beside that host; repeat for each repository
Ghosthub should display.

**Test Connection** follows your OpenSSH host-key policy. If a new destination
requires interactive verification, connect to it once with the system `ssh`
command, verify its fingerprint, and retry. A reachable host without tmux is
reported separately as **tmux is not installed** rather than as an SSH failure.
