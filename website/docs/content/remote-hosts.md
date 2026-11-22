---
description: Connect SSH hosts, review host keys, handle logins, and configure reconnects and remote helpers.
icon: lucide/server
---

# Remote hosts

Add a Mac or Linux machine over SSH to manage its sessions right alongside your
local ones. Ghosthub lists tmux sessions, running and stopped Herdr sessions,
Herdr desktop terminals, Rex windows, and active Zellij sessions on each host.
Herdr, Rex, and Zellij are optional. Native Windows hosts running psmux are
experimental and support tmux only.

## Before you add a host

A remote macOS or Linux host needs:

- a working OpenSSH server
- at least one supported multiplexer: tmux 3.2+, Herdr 0.8+, or Zellij 0.44+
- an SSH destination your Mac's OpenSSH config can reach

Ghosthub checks the remote multiplexer version when it attaches. **Cmd-D** and
**Cmd-Shift-D** pane splitting requires tmux 3.4 or newer or Herdr 0.8.0 or
newer; older versions still work with their own split keys.

If you are troubleshooting an SSH config or login issue, check that plain SSH
works from a terminal first:

```sh
ssh devbox
```

Ghosthub honors your OpenSSH config for usernames, ports, identity files,
agents, host-key rules, and supported jump hosts.

If Herdr is installed on the remote machine, Ghosthub automatically includes its
running and stopped sessions in that host's session list. It still connects over
Ghosthub's own OpenSSH transport, trust prompts, pooling, and reconnect loop
instead of Herdr's remote transport.

If a Rex server is running under that SSH account, the macOS app lists its
windows through Ghosthub's managed kwt helper.

If Zellij is installed, Ghosthub adds its active sessions to the host's session
list and skips exited sessions. Attachments use Ghosthub's normal OpenSSH
transport.

## Add and test a host

1. Open **Settings → Hosts**.
2. Add a destination such as `devbox`, `alice@build-server`, or an alias from
   `~/.ssh/config`.
3. Pick the host platform.
4. Click **Test Connection**.

If one host is unreachable, your other hosts keep working normally. When a
reachable host has no projects or sessions yet, expanding it in the sidebar says
so.

![Ghosthub Host Settings with the connection test and remote host details](/docs/assets/guide-hosts.png)

## Reorder hosts

Drag **Local Mac** or any remote host in **Settings → Hosts** to change its
order. The sidebar updates immediately, and the order stays saved across
launches and across all Ghosthub windows. Edits to a host's connection settings
still apply when you click **Done**.

You can also drag a host header directly in the sidebar to move its whole
section, including your Mac or an exe.dev host. An insertion line shows where
the section will land. **Settings → Hosts** shows Local Mac and your saved SSH
hosts in that same order; dragging there keeps the saved positions of discovered
hosts like exe.dev VMs intact. Local Mac is built in, so you can move it but
cannot remove it or give it an SSH destination. Newly added hosts appear at the
bottom.

## exe.dev hosts

Ghosthub can discover running exe.dev VMs automatically so you do not have to
add each VM by hand. Create and manage VMs in [exe.dev](https://exe.dev/docs),
then:

1. Open **Settings → Integrations**.
2. Add an exe.dev account. The default SSH destination is `exe.dev`.
3. Optionally enter **Tags** to filter which VMs appear, such as `dev` or
   `dev, prod`.
4. Click **Connect and Discover VMs** and finish any OpenSSH trust or login
   prompt.

Running VMs appear alongside your other hosts. Ghosthub uses each VM's exe.dev
SSH destination for tmux, optional Herdr or Zellij, and optional kwt discovery.

Leaving **Tags** blank discovers every VM on the account. With tags set,
Ghosthub shows only VMs that have at least one matching tag, and the account's
status line shows the filtered count. Tag matching is case-insensitive, and tags
are managed in exe.dev.

![Ghosthub Integrations settings showing a connected exe.dev account and discovered VM status](/docs/assets/guide-exe-dev.png)

## Host-key trust

When OpenSSH sees a new host key under an interactive trust policy, Ghosthub
shows the exact destination and fingerprint for you to check. Approve it only
after verifying the fingerprint through a trusted channel.

ProxyJump routes are checked one hop at a time, and every trust or login prompt
names the machine asking for it. Ghosthub blocks opaque `ProxyCommand` routes
and jump hosts that chain into another proxy because it cannot show the
intermediate trust boundaries clearly.

## Authentication

Ghosthub uses your existing OpenSSH keys and SSH agent. When SSH prompts for a
passphrase, password, or challenge response, Ghosthub shows a native secure
sheet naming the host that asked. Your answer stays in memory for the current
app run only. You can click **Continue** with an empty field when an SSH
challenge expects one.

### SSH agent forwarding

In **Settings → Hosts**, choose **Agent forwarding** for a saved host:

- **SSH configuration** follows that host's `ForwardAgent` setting (default).
- **On** forwards your local SSH agent to the host.
- **Off** turns forwarding off for that host, even if `~/.ssh/config` enables
  it.

Click **Done**, then reopen that host's sessions to pick up the change. The
setting applies to the target host; jump hosts keep their own SSH config.

Agent forwarding lets commands on the remote machine ask your local agent to
sign SSH logins while your private keys stay on your Mac. Load the keys you want
into your agent first, for example with `ssh-add ~/.ssh/id_ed25519`. Inside a
remote session, `ssh-add -l` shows which keys are forwarded. Forwarding stays
active as long as Ghosthub has a live connection to that host.

If a host shows a warning icon in the sidebar, click it to review its host key,
sign in, or retry. Signing in to refresh a host's session list updates the
sidebar without opening a session by itself.

### Tailscale browser checks

When Tailscale SSH asks for a browser check, click **Open Authentication Page**
in Ghosthub's prompt and finish signing in. Ghosthub holds that SSH attempt open
and continues automatically once you approve it. If the link expires, retry the
connection to get a fresh one.

The prompt names the host asking for approval, including a jump host when one is
involved. You can also copy the URL into your browser. Clicking **Cancel** stops
that connection attempt.

![Ghosthub authentication sheet showing a Tailscale sign-in link and waiting status](/docs/assets/guide-ssh-browser-authentication.png)

## Automatic reconnect

When an active SSH connection drops, Ghosthub shows **Connection interrupted**
and retries automatically, waiting at most 30 seconds between tries. Click
**Reconnect Now** to try immediately. Once the host is back, Ghosthub reattaches
to the exact same tmux, Herdr, or active Zellij session. Your programs stayed on
the remote server the whole time.

If SSH needs a login or host-key approval, the view switches to **Connection
needs attention**. Finish the prompt to return to the same session. If you close
the sheet, click **Review Connection** to bring it back.

If the connection still fails, Ghosthub shows OpenSSH's error message and exit
status. For example, `Permission denied (publickey)` means the server rejected
your login, not its host key: approving a host key verifies the server's
identity, while signing in still requires a valid username and SSH key.

## Slow connections

On slow or congested links, SSH compression can shrink text-heavy terminal
output. Ghosthub turns it on by default for saved remote hosts, including hosts
you added before this toggle existed. exe.dev accounts are the exception:
because Ghosthub discovers their VMs dynamically instead of storing them,
neither the account nor its VMs have an **SSH compression** toggle, and Ghosthub
leaves compression off for them.

To change compression for a saved host, open **Settings → Hosts**, select the
host, toggle **SSH compression**, and click **Done**. The change applies to new
SSH connections. Saving it detaches open views on that host while leaving the
remote sessions running; click a session again to reattach with the new setting.

You do not need to edit `~/.ssh/config`. Compression helps with heavy output
over slow links, though it cannot remove lag caused by packet loss or high
latency.

## Managed kwt helper

Hosts that only run standalone tmux, Herdr, or Zellij sessions do not need kwt.
When you use projects, worktrees, or Rex on a remote macOS or Linux host,
Ghosthub automatically copies and updates its matching revision-pinned kwt
helper under `~/.ghosthub/`. It verifies the binary and never touches a
system-wide kwt install.

If a background helper update fails, your tmux, Herdr, and Zellij sessions keep
working normally. When you trigger a project or worktree action, Ghosthub tries
to repair the helper first and shows an error only if the repair still fails.

Register individual repositories with **Add Project** in Host Settings. Ghosthub
never scans a remote filesystem on its own. See
[Projects and Worktrees](projects-worktrees.md).

## Tailscale hosts

Importing a Tailscale peer keeps its full MagicDNS name. Ghosthub uses the
username from your OpenSSH config, falling back to your local macOS username if
none is set. The import picker starts with every peer unchecked so you pick only
the machines you want.

![Host Settings with explicit Tailscale import controls](/docs/assets/guide-tailscale-import.png)

## Experimental Windows hosts

Connecting from macOS to a native Windows host requires:

- Windows 11 build 22523 or newer
- Windows OpenSSH
- Windows PowerShell 5.1 or newer
- [psmux](https://github.com/marlocarlo/psmux) with its `tmux.exe` alias
  available

Choose **Windows (psmux)** when adding the host. After **Test Connection**
succeeds, you can click **Install Bundled kwt** to upload the matching AMD64 or
ARM64 helper for that account. Because the Windows helper is not
Authenticode-signed yet, Ghosthub never installs it automatically; this setup is
aimed at developers and power users. Adding new projects from Ghosthub is not
supported on Windows yet, though projects already registered on that host can be
listed.

[Session activity indicators](sessions.md#activity-indicators) require psmux
3.3.4 or newer. Older supported versions still attach normally, just without
activity dots.

## Rust source builds

The unreleased Rust Linux build also connects to macOS and Linux SSH hosts
through its bundled KWT helper. See the
[native Linux SSH guide](https://github.com/kenn-io/ghosthub/blob/main/docs/rust-port.md#native-linux-ssh-sessions)
for setup and limits. It supports remote tmux, Herdr, and Zellij sessions, plus
[projects and worktrees](projects-worktrees.md#rust-source-builds).

When an active tmux session loses its SSH connection, Ghosthub retries after 1,
2, 4, 8, 16, and then 30 seconds, with a 15-second timeout per attempt. Click
**Refresh** or **Retry** beside the host to try immediately and reset the
backoff. Automatic retries pause while a worktree is being created or imported
so background reconnects do not interrupt it.

Ghosthub always reattaches to that exact session, even if it was renamed. It
will not create a missing session or attach to a brand-new session that reused
the same name. Switching to another session, detaching, or closing the window
cancels pending retries. If reconnecting fails, clicking **Retry** still targets
the original session. Reconnect also works when tmux alternate-screen switching
is disabled. Login errors, changed SSH settings, and host-key prompts pause
automatic retries; click **Retry** to review them. **Cancel** stops an active
attempt and turns off further automatic retries.

Automatic reconnect covers the default tmux server and kwt's shared server. For
inactive retained sessions, protected PR worktrees, Herdr, and Zellij, click the
row again to reopen it.

![Native Linux Ghosthub after reconnecting to the original tmux shell](/docs/assets/guide-rust-ssh-reconnect.png)
