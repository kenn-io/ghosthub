---
description: Create, attach to, detach from, reopen, hide, and end tmux sessions.
icon: lucide/square-terminal
---

# Sessions

Ghosthub discovers every tmux session on each reachable configured host.
Sessions that are not bound to a kwt workspace appear directly under the host.
Worktree-backed sessions appear inside their project.

## Create a standalone session

1. Open the **+** menu beside a host.
2. Choose **New Session**.
3. Enter the tmux session name.

The new session is an ordinary tmux session. It remains usable from the `tmux`
CLI and other tmux clients.

## Attach and detach

Select a session in the sidebar or search for it in the Command Palette with
++shift+cmd+p++. Ghosthub opens it through a normal local or SSH tmux
client.

Closing a tab, closing a window, switching sessions, or quitting Ghosthub only
detaches the presentation. Tmux keeps the session and its processes alive.

## Reopen an exited standalone session

If a standalone session exits while its presentation is still open, Ghosthub
shows a **Reopen** action. Reopening creates a new tmux session with the exact
previous name. It cannot restore processes from the exited session.

## End a session deliberately

To end a standalone session that Ghosthub knows is running, hover over its
sidebar row and choose the subtle **×** control. For a worktree-backed session,
use **Kill Session…** in the worktree action menu.

Ghosthub confirms the host and exact tmux session before it sends
`kill-session`. Ending a session terminates all of its windows, panes, and
processes and cannot be undone.

Ghosthub cancels the operation if the host connection changes, or if the
original session disappears and another session appears under the same name.
If the command fails, the active attachment remains open.

!!! warning "Killing a session is different from removing a worktree"

    **Kill Session…** ends tmux processes but keeps the checkout. Removing a
    worktree ends its verified live session when necessary and then removes the
    checkout, while keeping the Git branch. See
    [Remove a worktree](projects-worktrees.md#remove-a-worktree).

## Hide standalone sessions

To keep tool-owned or noisy standalone sessions out of the sidebar:

1. Open **Settings → Worktrees**.
2. Add hidden tmux session patterns, one per line.

Patterns are case-sensitive. `*` matches any number of characters and `?`
matches one character. Ghosthub stores these patterns in
`~/.config/ghosthub/config.toml`.

The patterns apply only to standalone sessions. A matching kwt workspace stays
visible under its project.

## Ownership and safety

Ghosthub does not infer that closing a presentation means ending work. It
destroys a session only after an explicit, confirmed **Kill Session** action or
as part of confirmed worktree removal when that worktree has a verified live
session. Sessions created outside Ghosthub receive the same protection as
sessions created inside it.
