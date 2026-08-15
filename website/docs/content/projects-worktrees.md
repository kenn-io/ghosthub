---
description: Register Git projects or plain directories and open their workspaces.
icon: lucide/git-branch
---

# Projects, worktrees, and directories

Projects and worktrees add Git context to Ghosthub's ordinary tmux workflow.
They are optional.

Ghosthub delegates repository and worktree identity to
[kwt](https://kwt.sh). Packaged builds use their revision-pinned bundled kwt
locally and a matching managed helper on remote macOS or Linux hosts.

## Register a project

Start with an existing Git checkout on the target host.

1. Expand the local Mac or a remote macOS or Linux host.
2. Select the **+** beside **Projects**.
3. Enter the checkout's absolute path on that host.
4. Confirm the registration.

Ghosthub registers that one path through kwt and refreshes inventory. It does
not scan the machine or edit kwt configuration itself.

Ghosthub automatically maintains the
[managed kwt helper](remote-hosts.md#managed-kwt-helper) on configured remote
macOS and Linux hosts. Project registration is not yet available for native
Windows hosts.

If the SSH destination changes while the Add Project sheet is open, close the
sheet and start again so the confirmation applies to the current host.

## Remove a project

Hover over a project row and select its trash control, or Control-click the row
and choose **Remove Project…**. Then confirm the project and host. Ghosthub asks
kwt to unregister that project and refreshes inventory. You can remove the
registration even if its checkout folder has already been deleted. This does
not delete the repository, any worktree directory, or any tmux session. If an
imported pull-request worktree still has a live session on its protected tmux
server, kill that session before removing the project. Ordinary sessions that
remain live are still available under the host's **Tmux Sessions** group.

![Ghosthub showing the Remove Project action and its non-destructive confirmation](assets/guide-project-removal.png)

If the project or host connection changes while confirmation is open, Ghosthub
stops and asks you to start the removal again. Project removal is available on
the local Mac and configured remote macOS or Linux hosts, but not native
Windows hosts.

## Register a plain directory

A hub, notes tree, or other directory that is not a Git checkout can still use
the same kwt layouts and Ghosthub terminal flow. Register it on the target host:

```sh
kwt workspace add /absolute/path/to/directory
```

Refresh Ghosthub. The directory appears as one flat row in **Projects**, after
the repository rows. It has no expandable worktree children because one
registered directory owns one workspace session.

Select the row to let kwt create or repair its configured layout and attach the
ordinary tmux client. Removing the registration with `kwt workspace remove`
does not end a live session; after refresh, that session remains available
under **Tmux Sessions**.

## Open a project checkout

Select the project's primary checkout or any linked worktree in the sidebar.
Kwt supplies the exact canonical tmux session name. Ghosthub creates or repairs
that session when necessary and then attaches an ordinary tmux client. The
native window tab and titlebar show the project and worktree names instead of
that internal session name.
The worktree row shows a compact window count. While Ghosthub is connected,
the count refreshes with the existing background activity check: within about
five seconds for a working session and twenty seconds for a quiet session.
This also covers protected sockets. Detached ordinary sessions use the count
from current discovery. A running or agent glyph remains the fallback when no
trustworthy count is available, and cached sessions do not remain marked live
while the host is unreachable.

![Ghosthub showing a compact tmux window count on a worktree row](assets/guide-worktree-window-counts.png)

By default, a live kwt-managed session appears only on its worktree row instead
of being duplicated under **Tmux Sessions**. Open **Settings → Worktrees** and
turn off **Hide kwt-managed sessions from Tmux Sessions** if you want both
entries visible.

## Create a worktree from a branch

1. Select the project.
2. Press ++shift+cmd+n++ or choose the new-worktree action.
3. Select **Branch**.
4. Search local and remote branches that are not already checked out, or type a
   new branch name.
5. Confirm the worktree.

Selecting a remote source creates a local tracking branch when needed. The
picker distinguishes same-named sources. Input that does not match an existing
branch creates a new branch.

## Import a GitHub pull request

Pull-request import requires the [GitHub CLI](https://cli.github.com/) on the
host that contains the project—not merely on the Mac running Ghosthub.

On that host:

```sh
gh auth login
```

For an HTTPS Git remote, Git authentication must also work there. GitHub CLI
can configure itself as the credential helper:

```sh
gh auth setup-git
```

Then select the project, press ++shift+cmd+n++, choose **Pull Request**, and
search for an open pull request. Ghosthub asks kwt to import it and selects the
resulting worktree session.

## Remove a worktree

Hover over a non-primary worktree in the sidebar and choose **×**. After you
confirm the exact worktree and host, Ghosthub:

1. ends that worktree's verified live tmux session when necessary; and
2. asks kwt to remove the checkout.

The Git branch is kept. If the checkout is already absent, Ghosthub skips the
redundant filesystem removal but still reconciles the exact live session
covered by the confirmation. If the worktree or session changes while the
confirmation is open, Ghosthub stops and presents the current removal details
for fresh confirmation instead of continuing automatically.

After removal, the owning project remains selected. Ghosthub does not select
another worktree or open its tmux session on your behalf.

## Rearrange worktrees

Drag worktrees within a project to set their display order. The insertion line
shows the destination. This changes Ghosthub's navigation only; it does not
rename or reorder anything in Git, kwt, or tmux.
