---
description: Fix common Ghosthub installation, SSH, multiplexer, and worktree issues.
icon: lucide/life-buoy
---

# Troubleshooting

## A host does not connect

Test the exact same destination from a plain terminal first:

```sh
ssh devbox
```

Fix any OpenSSH config, network, SSH agent, or server issue there first. Then
open **Settings → Hosts**, run **Test Connection**, and complete any host-key or
login prompt naming the host or ProxyJump hop.

Ghosthub does not support opaque `ProxyCommand` routes or a jump host that
chains into another proxy.

## Ghosthub says tmux was not found

Ghosthub runs remote commands through your login shell, which reads
`~/.zprofile` but not `~/.zshrc`. It also checks standard Homebrew, MacPorts,
Linuxbrew, and Nix paths. If tmux is installed somewhere else, check what your
login shell sees from your Mac:

```sh
ssh devbox 'zsh -lc "command -v tmux"'
```

If that prints nothing, add tmux's directory to `PATH` in `~/.zprofile` on that
host, or install tmux, then reopen the session. No app restart is needed.

## A remote host connects but shows no sessions

Check that tmux is installed and running on the remote host:

```sh
tmux -V
tmux list-sessions
```

For worktrees and registered directories managed by kwt, check kwt's separate
tmux server:

```sh
env -u TMUX_TMPDIR tmux -L kwt list-sessions
```

Imported pull requests run on separate protected sessions; open them from their
worktree rows in Ghosthub.

When a reachable host has no sessions or projects, expanding it in the sidebar
says so. Project discovery is separate from SSH reachability, and a background
kwt helper update error stays quiet until you run a project or worktree action
that needs the helper.

## Herdr sessions do not appear

Herdr is optional and independent of tmux and projects. On your Mac or the
remote macOS/Linux host, run:

```sh
command -v herdr
herdr session list --json
```

Ghosthub shows sessions reported as running or stopped. A session started
outside Ghosthub (for example with `herdr --session NAME`) appears within about
30 seconds while Ghosthub is in front. If `herdr` is not installed, the host
works normally without Herdr rows. If `herdr` exists but fails or prints invalid
JSON, the host header shows a warning with **Retry** and a link to Host
Settings. Herdr is not checked on experimental Windows hosts.

Closing a Herdr view never stops its server. A manual detach shows a
**Reconnect** button; automatic reconnect is only for dropped SSH connections
and stops if the session is no longer running.

On a **stopped** row, choose **Restart** to bring back its saved layout with
fresh processes. **Stop Session…** ends all running processes; **Delete
Session…** permanently removes the saved session and is disabled for Herdr's
default session.

## Zellij sessions do not appear

Zellij is optional and independent of tmux, Herdr, and projects. On your Mac or
the remote macOS/Linux host, run:

```sh
command -v zellij
zellij list-sessions --no-formatting
```

Ghosthub lists active Zellij sessions only. Sessions started outside Ghosthub
appear within about 30 seconds while Ghosthub is in front. If `zellij` is not
installed, the host works normally without Zellij rows. If `zellij` exists but
fails or prints unexpected output, the host header shows a warning with
**Retry** and a link to Host Settings. Zellij is not checked on experimental
Windows hosts.

Closing a Zellij view never kills its server. A manual detach shows a
**Reconnect** button; automatic reconnect is only for dropped SSH connections
and stops if the session is no longer active. Ghosthub does not resurrect or
delete exited Zellij sessions. To end an active session, choose **Kill
Session…** and confirm.

## Reconnect needs attention

Automatic reconnect pauses whenever SSH needs a password, challenge response, or
host-key check. Click **Review Connection**, finish the prompt, and the view
resumes. Click **Reconnect Now** to retry immediately when no review is waiting.

## A tmux session preview is unavailable

Under **Efficient** or **Live**, preview toggles appear only after you open a
tmux session in that window. **Always Live** connects and expands newly
discovered tmux sessions on macOS and Linux hosts automatically. Change the mode
in **Settings → Terminal → Session previews**. Previews are not available for
Herdr, Zellij, or native Windows/psmux sessions.

On a macOS or Linux host, run `tmux -V`. Previews require tmux 3.4 or newer so
Ghosthub can verify that the captured frame belongs to the exact attached
client. Older tmux sessions still open and work normally, but show **Preview
unavailable** instead of risking a stale or mismatched image.

## A project does not appear

Ghosthub automatically retries project and directory discovery when kwt reports
a retryable error, backing off between attempts while keeping other results
intact. If a warning stays after those retries, check the host manually.

On a remote macOS or Linux host, Ghosthub installs its managed kwt helper
automatically. Click **+** beside that host's **Projects** group and enter the
full path to an existing checkout on that host. Ghosthub repairs the helper
before registering and shows an error if repair fails; it never scans the host
for repositories.

Adding projects is not supported on native Windows hosts yet.

## Pull-request import fails

Run these checks on the machine where the repository lives:

```sh
gh auth status
git remote -v
git fetch --dry-run
```

For HTTPS GitHub remotes, run `gh auth setup-git` so Git can use GitHub CLI for
credentials. Installing or signing in to `gh` on your Mac alone does not help a
project hosted on a remote machine.

## A shell key binding behaves differently

Check `~/.config/ghosthub/ghostty.conf` and your normal shell startup files.
Ghosthub uses libghostty's standard macOS login-shell startup and shell
integration; do not disable shell integration to work around key-binding issues.

If you launched Ghosthub from another terminal, quit it and reopen it from
**Applications** to rule out inherited environment variables from that launcher.

## Find the application log

Press ++option+cmd+l++ to open the application log. When filing a
[GitHub issue](https://github.com/kenn-io/ghosthub/issues), include the relevant
log lines, your Ghosthub version, your macOS version, and steps to reproduce the
problem.

Do not paste passwords, private keys, session output, repository secrets, or
private hostnames into a public issue.
