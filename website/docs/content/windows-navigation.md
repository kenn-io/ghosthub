---
description: Navigate hosts and sessions with the sidebar, Command Palette, windows, and tabs.
icon: lucide/panels-top-left
---

# Windows and navigation

Each Ghosthub workspace can show a tmux, Herdr, or Zellij presentation. It can keep
multiple tmux presentations connected while showing one at a time; Herdr owns
the complete internal workspace shown by its client. Native macOS tabs group
complete Ghosthub workspaces and do not replace any multiplexer's internal
windows, tabs, or panes.

## Use the sidebar

The sidebar shows standalone tmux sessions, running and stopped Herdr sessions,
active Zellij sessions, projects,
and worktrees under each host. Select an item to attach. Moving among tmux
targets hides the previous terminal without detaching its local or SSH client;
moving away from Herdr or Zellij detaches only its presentation and leaves its server
running. Stopped Herdr rows are dimmed and labeled **Stopped**. Expand a host
to see its current inventory and connection diagnostics.

Press ++cmd+b++ to hide or show the sidebar. Hiding it gives the terminal
the full window while preserving its session attachment.

## Use the Command Palette

Press ++shift+cmd+p++ and type to search:

- hosts, projects, worktrees, and standalone tmux, Herdr, or Zellij sessions
- settings pages
- session lifecycle commands
- appearance and theme commands

Press Return to perform the selected action.

## Open tabs and windows

- ++cmd+t++ opens a workspace tab in the current window.
- ++cmd+n++ opens a separate workspace window.

Each can attach to a different local or remote tmux, Herdr, or Zellij session. Use the macOS
**Window** menu to move a tab into its own window or merge windows into a native
tab group.

## Close a presentation

++cmd+w++ closes and detaches only the active session presentation. Other
sessions opened in that workspace remain connected. ++shift+cmd+w++ closes the
containing workspace window and detaches every presentation it owns. Neither
action ends a tmux session or stops a Herdr or Zellij server. Use the separately
confirmed **Kill Session…** or **Stop Session…** action when termination is intentional.

Closing the final workspace leaves Ghosthub running. Use ++cmd+q++ to quit.
Quit confirmation is enabled by default and can be changed under
**Settings → Terminal**.

## Restore workspaces after launch or update

Ghosthub asks macOS to restore native windows and tabs. It reconnects each
saved presentation only when it can confirm the exact tmux, running Herdr, or
active Zellij
session. Offline SSH hosts continue retrying as inventory refreshes.

During an update relaunch, Ghosthub recreates saved windows if macOS does not
return them. A window that previously had no terminal attached restores its
navigation state without creating a worktree session. Select the worktree when
you are ready to attach.

## Rearrange navigation

Drag worktrees within a project, or reorder standalone tmux, Herdr, and Zellij sessions
within their host groups. The insertion line previews the destination. Ghosthub
remembers this display order without changing anything in Git, kwt, tmux,
Herdr, or Zellij.
