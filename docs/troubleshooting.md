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

Click the host's caution icon. Ghosthub checks the exact SSH destination and,
if OpenSSH reports an unseen key, immediately presents its destination and
fingerprint for approval, saves it through OpenSSH, and retries inventory.
ProxyJump routes may show one review for each unseen host in the route. When a
jump host needs a password or another interactive response, Ghosthub asks for
it after that host's key is approved, names the exact hop controlling the
prompt, then continues to the next route key. Enter only that hop's credentials.
Opaque ProxyCommand routes and jump hosts with another proxy route cannot be
reviewed safely and fail closed. If no unseen key is reported, the same
recovery sheet checks the connection. A reachable host keeps its inventory
diagnostic and offers **Retry**. Ghosthub shows interactive challenges in a
native secure-entry sheet, confirms the connection before you continue, and
shares that OpenSSH connection while windows use it; once the last owner
releases it, kwt applies its own idle policy. The response is not saved.
Use **Test Connection** to verify authentication and that `tmux` is on the
remote login-shell `PATH`.
Kwt does not need a system installation: Ghosthub automatically installs or
updates its managed helper when it loads inventory for a configured remote
macOS or Linux host. Passive maintenance failures do not affect terminal
sessions or show a host warning. Ghosthub retries the repair when you request a
project or worktree operation and reports an error there if it still cannot
prepare the helper. If the host has never used kwt, enter an existing checkout's
absolute path with the **+** beside the **Projects** group for that host; repeat
for each repository Ghosthub should display.

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

## Herdr sessions do not appear

Ghosthub treats Herdr as an optional, independent host capability. A host with
no `herdr` executable shows no Herdr group or missing-tool warning and remains
fully usable for tmux and kwt. On the local Mac or a remote POSIX host, verify
the account login environment reports the expected sessions:

```bash
command -v herdr
herdr session list --json
```

Running and stopped sessions appear under **Herdr Sessions**. A stopped row is
dimmed and labeled **Stopped**; choose **Restart** to restore its saved shape
with new processes. Malformed
JSON, a failing Herdr command, or an SSH failure adds a host-scoped warning;
use its **Retry** action after correcting the command or connection. Herdr is
not supported on experimental Windows/psmux hosts.

Closing a Herdr presentation only detaches. **Stop Session…** is a separate,
confirmed action that terminates every process while preserving saved shape.
**Delete Session…** permanently removes a stopped named session and is never
available for Herdr's default session. A normal detach offers manual reconnect;
an SSH transport loss retries only while a fresh exact-session probe still
confirms the target.
