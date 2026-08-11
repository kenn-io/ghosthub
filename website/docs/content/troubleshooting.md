---
description: Diagnose common Ghosthub installation, SSH, multiplexer, and worktree problems.
icon: lucide/life-buoy
---

# Troubleshooting

## A host does not connect

Test the exact destination outside Ghosthub:

```sh
ssh devbox
```

Resolve OpenSSH configuration, routing, agent, or server problems there first.
Then open **Settings → Hosts**, test the connection, and address any trust or
authentication prompt naming the failing host or ProxyJump hop.

Ghosthub does not support opaque `ProxyCommand` routes or a jump host that
itself uses another proxy.

## A remote host connects but shows no sessions

Confirm tmux is installed on the remote host:

```sh
tmux -V
tmux list-sessions
```

An expanded host with no discovered tmux, Herdr, or Zellij sessions or projects reports
that it is empty. Project inventory is separate from SSH reachability, so a
reachable host can also show a separate kwt diagnostic.

## Herdr Sessions does not appear

Herdr is optional and independent from tmux and projects. On the local Mac or
a remote macOS/Linux host, run:

```sh
command -v herdr
herdr session list --json
```

Ghosthub shows entries reported as running or stopped. If `herdr` is missing, the
host stays fully usable and Ghosthub silently omits **Herdr Sessions**. If the
command exists but fails or returns malformed JSON, the host header shows a
warning with **Retry** and a shortcut to Host Settings. Herdr is not probed on
experimental Windows hosts.

Closing a Herdr client never stops its server. A normal detach offers manual
**Reconnect**; automatic retry is reserved for remote SSH transport loss and
stops if the exact session is no longer running.

If a session is labeled **Stopped**, choose **Restart** to restore its saved
shape with new processes. **Stop Session…** intentionally terminates all
current processes; **Delete Session…** permanently removes saved state and is
not available for Herdr's default session.

## Reconnect needs attention

Automatic retry pauses for action when SSH requires a credential or host-key
decision. Choose **Review Connection**, complete the native prompt, and let the
existing presentation resume. **Reconnect Now** performs an immediate retry
when no review is pending.

## A project does not appear

For a remote macOS or Linux host, Ghosthub installs its managed kwt helper
automatically. If the host shows a provisioning warning, retry it or open Host
Settings. Then select the **+** beside that host's **Projects** group and
provide the absolute path to an existing checkout on that host. Ghosthub does
not discover
repositories by scanning.

Project registration is not yet supported for native Windows hosts.

## Pull-request import fails

Run these checks on the machine that contains the project:

```sh
gh auth status
git remote -v
git fetch --dry-run
```

For HTTPS GitHub remotes, `gh auth setup-git` can configure GitHub CLI as the
Git credential helper. Installing or authenticating `gh` only on the local Mac
does not help a project stored on a remote host.

## A shell key binding behaves differently

Check `~/.config/ghosthub/ghostty.conf` and your normal shell startup files.
Ghosthub uses libghostty's macOS login-shell path and shell integration. Do not
disable shell integration as a key-binding workaround.

If Ghosthub was launched from another terminal, quit and reopen it from
**Applications** to eliminate unusual launcher environment as a diagnostic
step.

## Find the application log

Press ++option+cmd+l++ to open the application log. Include the relevant
diagnostic text, Ghosthub version, macOS version, and reproducible steps when
filing a [GitHub issue](https://github.com/kenn-io/ghosthub/issues).

Do not publish passwords, private keys, session output, repository secrets, or
private hostnames in a public issue.
