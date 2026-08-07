---
description: Diagnose common Ghosthub installation, SSH, tmux, and worktree problems.
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

An expanded host with no discovered tmux sessions or projects reports that it
is empty. Project inventory is separate from SSH reachability, so a reachable
host can also show a separate kwt diagnostic.

## Reconnect needs attention

Automatic retry pauses for action when SSH requires a credential or host-key
decision. Choose **Review Connection**, complete the native prompt, and let the
existing presentation resume. **Reconnect Now** performs an immediate retry
when no review is pending.

## A project does not appear

For a remote macOS or Linux host, Ghosthub installs its managed kwt helper
automatically. If the host shows a provisioning warning, retry it or open Host
Settings. Then use the host's **Add Project** action and provide the absolute
path to an existing checkout on that host. Ghosthub does not discover
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
