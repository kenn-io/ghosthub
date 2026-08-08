---
description: Attach to tmux and Herdr sessions, reconnect safely, and manage whole-session lifecycle.
icon: lucide/square-terminal
---

# Sessions

Ghosthub keeps three host inventories independent. Standalone tmux sessions
appear under **Tmux Sessions**, running and stopped Herdr sessions appear under **Herdr
Sessions**, and tmux-backed kwt worktrees and registered directories appear
under **Projects**, in that order. Registered directories are flat rows after
the repository hierarchies. A missing Herdr installation is normal: Ghosthub
simply omits its group without showing a warning.

You do not choose Herdr *instead of* Ghosthub. Herdr owns a session's internal
workspace, tabs, panes, history, key bindings, and processes;
Ghosthub discovers that session and presents its ordinary client beside your
tmux sessions and tmux-backed worktrees. Both multiplexers can be active on the
same host fleet.

## Create a standalone session

1. Expand the target host.
2. Select the **+** beside **Tmux Sessions** or **Herdr Sessions**.
3. Enter a session name.

A new tmux session remains usable from the `tmux` CLI and other tmux clients.
A new Herdr session is created with Herdr's own launch path and Ghosthub
attaches immediately. The **Herdr Sessions** group and its creation action
appear only when the host's `herdr session list --json` capability is
available. A name already present in either running or stopped state is
rejected; restart a stopped session instead.

## Attach and detach

Select a running tmux or Herdr session in the sidebar, or search for it in the Command
Palette with ++shift+cmd+p++. Ghosthub opens an ordinary local or SSH client
for the selected backend. Herdr receives the complete terminal and continues
to own its workspaces, tabs, panes, history, and key bindings.

Switching to another host, worktree, or session hides an opened tmux terminal
without detaching it. Each workspace keeps every tmux session you explicitly
open connected, and returning to one reuses the same terminal and client.
Switching away from Herdr detaches its presentation; the Herdr server and its
processes continue running.

Press ++cmd+w++ to detach only the active presentation. Closing a workspace
tab or window detaches every presentation it owns, and quitting Ghosthub
detaches them all. None of these actions ends a tmux session or stops a Herdr
server. A normal Herdr detach offers **Reconnect** and does not retry
automatically.

On a remote host, a dropped SSH transport enters automatic recovery. Ghosthub
probes the same exact session before each replacement client. Retry stops when
the session disappears, Herdr becomes unavailable, or the client reports a
non-transport failure. **Reconnect Now** skips the current delay; host-key or
authentication problems open the existing connection review flow.

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
sidebar row and choose the subtle **×** control. For a kwt-backed session, use
**Kill Session…** in its workspace action menu.

Ghosthub confirms the host and exact tmux session before it sends
`kill-session`. Ending a session terminates all of its windows, panes, and
processes and cannot be undone.

Ghosthub cancels the operation if the host connection changes, or if the
original session disappears and another session appears under the same name.
If the command fails, the active attachment remains open.

Herdr lifecycle is whole-session only:

- A running row offers **Stop Session…**. After confirmation, every shell,
  agent, server, test, and other process ends, while Herdr retains the saved
  workspace/tab/pane shape.
- A dimmed **Stopped** row offers **Restart**, which restores that shape with
  new processes and attaches immediately.
- A stopped named row also offers **Delete Session…**, which permanently
  removes its saved state after confirmation.
- Herdr's default session may be stopped and restarted, but never deleted.

These actions are also in the Command Palette. Ghosthub suppresses reconnect
across every open scene while an intentional stop runs, so another window does
not silently resurrect the session.

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
destroys a tmux session only after an explicit, confirmed **Kill Session**
action or as part of confirmed worktree removal when that worktree has a
verified live session. Sessions created outside Ghosthub receive the same
protection as sessions created inside it. For Herdr, Ghosthub manages only
whole-session create, stop, restart, and delete, plus the explicit Split Right
and Split Down requests against a connected Herdr 0.8.0-or-newer session. Herdr
selects the focused pane and continues to own themes, workspaces, tabs, panes,
agents, plugins, configuration, updates, and internal process behavior.
