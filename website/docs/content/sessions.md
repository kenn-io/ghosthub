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

Switching to another host, worktree, or session hides the previous terminal
without detaching it. Each workspace keeps every session you explicitly open
connected, and returning to one reuses the same terminal and tmux client.

Press ++cmd+w++ to detach only the active presentation. Closing a workspace
tab or window detaches every presentation it owns, and quitting Ghosthub
detaches them all. None of these actions ends a tmux session; tmux keeps the
session and its processes alive.

## Activity indicators

After a session connects, Ghosthub remembers it for the rest of the app
launch. A small accent indicator appears beside its worktree or standalone
session row when Ghosthub observes recent tmux scrollback progress, then
clears about thirty seconds after output stops.

![Ghosthub sidebar showing an accent activity indicator beside a standalone session that is producing output while another session is selected](assets/guide-session-activity.png)

Only genuine output counts. Switching panes, resizing the window, or a
full-screen tool redrawing its prompt, spinner, or status display does not
light the indicator. Closing the window still only detaches; the warm session
stays visible across your other Ghosthub windows.

This activity state resets when Ghosthub quits. Ghosthub never scans sessions
you have not opened, and terminal text never leaves the host: the probe
returns only a checksum and size counters. On native Windows hosts, activity
indicators require psmux 3.3.4 or newer.

## Reopen an exited standalone session

If a standalone session exits while its presentation is still open, Ghosthub
shows a **Reopen** action. Reopening creates a new tmux session with the exact
previous name. It cannot restore processes from the exited session.

A clean detach or a confirmed ended session stays closed until you explicitly
open or reopen it.

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

Kwt-managed sessions are also omitted from the separate **Tmux Sessions** group
by default because their worktrees remain the canonical entry. You can expose
those duplicate session rows with the toggle in **Settings → Worktrees**. The
worktree's status glyph continues to reflect the live tmux session either way.

## Ownership and safety

Ghosthub does not infer that closing a presentation means ending work. It
destroys a session only after an explicit, confirmed **Kill Session** action or
as part of confirmed worktree removal when that worktree has a verified live
session. Sessions created outside Ghosthub receive the same protection as
sessions created inside it.
