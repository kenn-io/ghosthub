# Troubleshooting

Common local bootstrap, build, and runtime failures and how to fix them.

## App exits on launch with a libghostty bootstrap error

Rerun bootstrap:

```bash
make bootstrap-libghostty
```

It is idempotent and exits immediately if staged artifacts already match the
pinned Ghostty revision. If it still fails, check the sections below.

## Bootstrap fails because `zig` does not match the pinned version

Install the Zig version pinned in `mise.toml` and run bootstrap through mise (a
newer Zig minor version is not interchangeable):

```bash
mise install zig
mise exec -- make bootstrap-libghostty
```

## Bootstrap fails with `missing Metal Toolchain`

Run Xcode's first-launch setup and download the Metal Toolchain for the active
Xcode:

```bash
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
xcrun --kill-cache
xcrun --sdk macosx --find metal
make bootstrap-libghostty
```

If that still fails, point `xcode-select` at a full Xcode install rather than
Command Line Tools alone:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
make bootstrap-libghostty
```

## Bootstrap reports that the active macOS SDK is incompatible

The pinned Zig build runner needs every architecture used by Zig and the target
XCFramework to appear in the SDK's `libSystem.B.tbd`. Some newer SDKs list only
`arm64e` instead of plain `arm64`, and cross or universal builds can need both
`arm64` and `x86_64`. Ghosthub checks this up front and automatically switches
to the newest compatible SDK already installed with Xcode or Command Line
Tools, printing the fallback path during bootstrap.

If no compatible SDK is found, install or select the supported Xcode baseline
named in the error and rerun:

```bash
make bootstrap-libghostty
```

Do not work around this by adding `--sysroot` to `LIBGHOSTTY_ZIG_BUILD_ARGS`:
that flag reaches the Ghostty build command, not the Zig build-runner compile
that fails first.

## Check bootstrap state without rebuilding

```bash
make check-libghostty
```

Reports whether staged `libghostty` artifacts match the pinned revision.

## Remote tmux attach fails on an SSH host

Click the host's warning icon in the sidebar. Ghosthub checks the exact SSH
destination and guides you through recovery:

- **Unseen host key:** Ghosthub displays the destination and fingerprint for
  approval, saves it through OpenSSH's `UserKnownHostsFile`, and retries
  inventory. ProxyJump routes review each unseen hop in order. Opaque
  `ProxyCommand` routes and jump hosts that chain into another proxy fail
  closed because their intermediate trust boundaries cannot be shown safely.
- **Interactive login prompts:** passwords, passphrases, and challenges appear
  in a native secure sheet naming the exact host or jump hop asking for them.
  Answers are passed to OpenSSH without touching CLI arguments, environment
  variables, logs, or disk. Shared OpenSSH connections stay open while windows
  use them; once the last owner releases the connection, kwt applies its idle
  policy.
- **Tailscale SSH browser checks:** click **Open Authentication Page** and
  finish sign-in in your browser; Ghosthub keeps the SSH attempt open and
  continues automatically after approval. If the link expires, retry to get a
  fresh one.

Use **Test Connection** in Host Settings to verify auth and confirm `tmux` is
on the remote login-shell `PATH`:

- **Host-key policy:** Ghosthub handles `ask` and `accept-new` policies in-app
  and respects explicit `yes`, `no`, or `off` settings without overriding them.
  Remember that a short alias and a full hostname are distinct OpenSSH
  identities.
- **Missing tmux:** a reachable host without tmux reports **tmux is not
  installed** separately from SSH failures.
- **Managed kwt helper:** Ghosthub installs and updates its pinned helper
  automatically on remote macOS and Linux hosts during inventory. Background
  update failures never interrupt standalone sessions or show a host warning;
  Ghosthub retries repair before any explicit project or worktree action and
  reports an error only if repair still fails. On a fresh host, register
  repositories via the **+** beside **Projects**.

## Herdr sessions do not appear

Herdr is optional and independent of tmux and projects. If `herdr` is not
installed, the host stays usable with no missing-tool warning. On your Mac or a
remote POSIX host, check what the login shell sees:

```bash
command -v herdr
herdr session list --json
```

Running and stopped sessions appear in the host's session list with a **herdr
tui** label. Stopped rows sit dimmed at the bottom; choose **Restart** to
relaunch their saved layout with fresh processes. Malformed JSON, a failing
`herdr` command, or an SSH error puts a warning with **Retry** on the host
header. Herdr is not supported on experimental Windows/psmux hosts.

Closing a Herdr view only detaches. **Stop Session…** confirms before ending
all processes while keeping the saved layout, and **Delete Session…** removes a
stopped named session permanently (never allowed for Herdr's default session).
A manual detach offers **Reconnect**; SSH drops retry automatically only while
a fresh exact-session check confirms the session is still running.
