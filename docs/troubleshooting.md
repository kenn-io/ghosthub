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

Click the host's caution icon. Ghosthub checks the exact SSH destination and,
if OpenSSH reports an unseen key, immediately presents its destination and
fingerprint for approval, saves it through OpenSSH, and retries inventory.
ProxyJump routes may show one review for each unseen host in the route. Opaque
ProxyCommand routes and jump hosts with another proxy route cannot be reviewed
safely and fail closed. If no unseen key is reported, the same recovery sheet
checks the connection. A reachable host keeps its inventory diagnostic and
offers **Retry**. If OpenSSH needs a password or another interactive response,
Ghosthub shows its exact challenge in a native secure-entry sheet. Complete the
prompt there; Ghosthub confirms the connection before you continue and keeps
that OpenSSH control connection for the app session. The response is not saved.
Use **Test Connection** to verify authentication and that `tmux` is on the
remote login-shell `PATH`.
Kwt does not need a system installation: follow a successful test with
**Install kwt Worktree Helper** when project inventory is missing. If the host
has never used kwt, enter an existing checkout's absolute path under **Add
Project** from the **+** menu beside that host; repeat for each repository
Ghosthub should display.

**Test Connection** follows your OpenSSH host-key policy. If the exact full
destination has an unseen key, Ghosthub presents OpenSSH's fingerprint for
explicit approval, asks OpenSSH to save that same key using its configured
`UserKnownHostsFile`, and retries the probe. A trusted short hostname or alias
is a separate OpenSSH identity. Ghosthub reviews effective `ask` and
`accept-new` policies but does not override `yes`, `no`, or `off`; change that
destination's SSH configuration deliberately if you want an in-app review.
After host-key review, Ghosthub securely brokers interactive responses to the
system OpenSSH client without putting them in command arguments, environment
variables, logs, or persistent storage.
A reachable host without tmux is reported
separately as **tmux is not installed** rather than as an SSH failure.
