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

Install the toolchain component for the active Xcode selection:

```bash
xcodebuild -downloadComponent MetalToolchain
make bootstrap-libghostty
```

If that still fails, make sure the active developer directory points
at a full Xcode install rather than Command Line Tools only:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
make bootstrap-libghostty
```

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
requires interactive verification, connect once with the system `ssh` command
to the exact full destination shown in Host Settings, verify its fingerprint,
and retry. A trusted short hostname or alias is a separate OpenSSH identity. A
reachable host without tmux is reported separately as **tmux is not installed**
rather than as an SSH failure.
