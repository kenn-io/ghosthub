---
description: Configure SSH hosts, trust, authentication, remote helpers, and reconnect behavior.
icon: lucide/server
---

# Remote hosts

Ghosthub can discover and attach to tmux sessions on remote macOS and Linux
machines over SSH. Native Windows hosts using psmux are experimental.

## Before you add a host

A macOS or Linux host needs:

- a working OpenSSH server
- tmux 3.2 or newer
- a destination that your Mac's OpenSSH configuration can resolve

Test the same destination in Terminal first when diagnosing configuration or
authentication:

```sh
ssh devbox
```

Ghosthub follows OpenSSH configuration for users, ports, identity files,
agents, host-key policies, and supported jump routing.

## Add and test a host

1. Open **Settings → Hosts**.
2. Add a destination such as `devbox`, `alice@build-server`, or a configured SSH
   alias.
3. Choose the host platform.
4. Select **Test Connection**.

An unreachable host does not block discovery or use of the rest of the fleet.
An expanded, reachable host with no projects or tmux sessions says so in the
sidebar.

## Host-key trust

When OpenSSH encounters an unseen key under an interactive trust policy,
Ghosthub presents the exact destination and fingerprint for review. Approve it
only after comparing the fingerprint through a trusted channel.

ProxyJump routes are reviewed one hop at a time, and every trust or credential
prompt identifies the machine that controls it. Ghosthub rejects opaque
`ProxyCommand` routes and jump hosts that themselves use another proxy because
it cannot safely present the intermediate trust boundaries.

## Authentication

Ghosthub uses your OpenSSH identities and agent configuration. When SSH asks an
interactive question, Ghosthub presents a native secure-entry sheet naming the
host that requested the response. The response is kept only for the running app
session. **Continue** can intentionally submit an empty response when the
challenge requires one.

If a host shows a caution icon, select it to review trust, authenticate, or
retry. A successful ordinary host-inventory authentication refreshes inventory;
it does not open a tmux session by itself.

## Automatic reconnect

If an active SSH connection drops, Ghosthub shows **Connection interrupted**
and retries automatically, with no more than 30 seconds between attempts.
Choose **Reconnect Now** to try immediately. When the connection returns,
Ghosthub reattaches to the same exact tmux session; the server-side processes
were never moved into Ghosthub.

If SSH needs authentication or host-key review, the presentation changes to
**Connection needs attention**. Complete the native recovery flow to resume the
same reconnect supervisor. If you dismiss it, choose **Review Connection** to
open it again.

## Install the managed kwt helper

Tmux-only hosts do not need kwt. To show projects and worktrees on a remote
macOS or Linux host:

1. Test the host connection successfully.
2. Choose **Install kwt Worktree Helper** in Host Settings.
3. Confirm the upload.

Ghosthub copies its matching revision-pinned helper for the remote operating
system and CPU, verifies it, and stores it under `~/.ghosthub/`. It does not
install or replace a system-wide kwt.

Register individual repositories with the explicit **Add Project** action.
Ghosthub never scans a remote filesystem. See
[Projects and Worktrees](projects-worktrees.md).

## Tailscale hosts

Importing a Tailscale peer preserves its full MagicDNS name. Ghosthub uses the
user selected by OpenSSH configuration and falls back to the local macOS user
name when none is configured.

## Experimental Windows hosts

Native Windows support requires:

- Windows 11 build 22523 or newer
- Windows OpenSSH
- Windows PowerShell 5.1 or newer
- [psmux](https://github.com/marlocarlo/psmux) with its `tmux.exe`
  compatibility alias available

Choose **Windows (psmux)** when adding the host. After a successful connection
test, **Install Bundled kwt** can upload the matching AMD64 or ARM64 helper for
that user. The Windows helper is currently unsigned, so this path is intended
for development machines and power users. Adding a new project from Ghosthub is
not yet supported on Windows, although already registered project inventory can
be shown.
