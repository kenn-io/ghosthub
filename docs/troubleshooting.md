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

Click the host's caution icon and choose **Review Host Key**. If OpenSSH reports
an unseen key, Ghosthub presents its exact destination and fingerprint for
approval, saves it through OpenSSH, and retries inventory. ProxyJump and
SSH-based ProxyCommand routes may show one review for each unseen host in the
route. If no unseen key is reported, open Host Settings and use **Test
Connection** to verify
authentication and that `tmux` is on the remote login-shell `PATH`. Kwt does
not need a system installation: follow a successful test with **Install kwt
Worktree Helper** when project inventory is missing. If the host has never used
kwt, enter an existing checkout's absolute path under **Add Project** from the
**+** menu beside that host; repeat for each repository Ghosthub should
display.

**Test Connection** follows your OpenSSH host-key policy. If the exact full
destination has an unseen key, Ghosthub presents OpenSSH's fingerprint for
explicit approval, asks OpenSSH to save that same key using its configured
`UserKnownHostsFile`, and retries the probe. A trusted short hostname or alias
is a separate OpenSSH identity. A reachable host without tmux is reported
separately as **tmux is not installed** rather than as an SSH failure.
