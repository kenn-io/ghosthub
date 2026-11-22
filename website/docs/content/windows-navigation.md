---
description: Move between hosts and sessions using the sidebar, Command Palette, native Mac windows, and tabs.
icon: lucide/panels-top-left
---

# Windows and navigation

Switch sessions from the sidebar or keep several open side by side in native Mac
windows and tabs. Each Ghosthub window or tab shows one session at a time while
keeping previously opened tmux sessions connected in the background. Inside each
session, tmux, Herdr, and Zellij remain in charge of their own windows, tabs,
and panes.

## Use the sidebar

Each host in the sidebar lists its standalone tmux, Zellij, Herdr, and Rex
sessions in one list labeled by backend, followed by its projects and worktrees.
Click any row to attach. Switching between tmux sessions hides the previous view
without detaching its client; switching away from Herdr or Zellij detaches that
view while leaving the server running. Stopped Herdr sessions appear dimmed and
labeled **stopped** at the bottom. Expand a host to see its sessions and any
connection warnings.

Click a host's name to collapse or expand it without detaching the open session.
Each window and tab remembers its own expanded and collapsed hosts and projects,
so tidying the sidebar in one window never changes another. New windows open
with hosts expanded and projects collapsed.

![Ghosthub sidebar with a labeled session list under each host](/docs/assets/guide-sessions.png)

Press ++cmd+b++ to hide or show the sidebar. Hiding it gives the active session
the whole window while keeping it attached.

## Use the Command Palette

Press ++shift+cmd+p++ and type to search:

- hosts, projects, worktrees, and standalone tmux, Herdr, Rex, or Zellij
  sessions
- Settings pages
- session actions
- appearance and theme commands

Press **Return** to run the highlighted item.

![Command Palette searching for a worktree](/docs/assets/guide-quick-launch.png)

### Windows and Linux

In the Rust app, click **Commands** in the title bar or press **Ctrl+Shift+P**
to search sessions, worktrees, registered directories, hosts, Settings pages, or
the sidebar toggle. Results match your sidebar visibility settings, and
collapsing a host does not hide its sessions from search.

Words can match different parts of a result, such as `studio review tmux`. Every
word must match, and case does not matter. Use **Up** and **Down** then
**Enter** (or click a result) to open it, or press **Escape** to return to your
current session.

Stopped Herdr sessions appear as **Restart** items; selecting one restarts it,
while selecting a running Herdr session attaches to it.

Create, Kill, Stop, Delete, and Rename stay in the sidebar menus for now; the
Rust palette covers navigation and Settings. Change or disable its shortcut in
[Settings → Keyboard](keyboard-shortcuts.md#windows-and-linux).

![Command Palette offering Restart for stopped Herdr sessions on local and SSH hosts](/docs/assets/guide-rust-command-palette.png)

## Open tabs and windows

- ++cmd+t++ opens a new tab in the current window.
- ++cmd+n++ opens a new window.
- ++cmd+1++ through ++cmd+8++ jump to numbered tabs.
- ++cmd+9++ jumps to the last tab.

Each tab or window can attach to a different local or remote session. Use macOS's
**Window** menu to split a tab into its own window or merge windows into tabs.
If you press a tab number past the end of a short group, Ghosthub picks the last
tab. The tab bar shows each tab's number and updates as you drag tabs around.

![Ghosthub window with numbered native tabs](/docs/assets/guide-native-tabs.png)

To label a specific Ghosthub window or tab, choose **Window → Rename Window…**.
The label applies only to that Ghosthub window or tab and survives relaunches
and updates. Save a blank title to go back to the automatic session and host
title. Renaming a window never renames a tmux session, Herdr or Zellij session,
or worktree. You can also hover over the compact title and click the title or
pencil icon to rename it; dragging from that area still moves the window.

![Ghosthub's editor for a workspace window or tab title](/docs/assets/guide-window-title.png)

## Close a view or window

++cmd+w++ closes and detaches only the active session view, leaving any other
tmux sessions opened in that window connected. ++shift+cmd+w++ closes the whole
window and detaches every session open in it. Neither shortcut kills a tmux
session or stops a Herdr or Zellij server; use the confirmed **Kill Session…**
or **Stop Session…** action when you want to end a session.

Closing the last window leaves Ghosthub running. Press ++cmd+q++ to quit. Quit
confirmation is on by default and can be toggled in **Settings → Terminal**.

## Restore windows after launch or update

Ghosthub lets macOS restore your windows and tabs, reconnecting each saved view
only when it confirms the exact tmux, running Herdr, or active Zellij session.
Offline SSH hosts keep retrying as inventory refreshes.

Before an update relaunches the app, Ghosthub records each normal window's
position, size, and session, and recreates those windows if macOS does not bring
them back. If a monitor was unplugged, its windows move to an active display.
macOS itself handles desktop Spaces, full-screen windows, and tab groups;
Ghosthub does not move windows across Spaces. Window frame restore works on
updates starting from builds that include this capture step.

A window that had no session open restores its sidebar selection without
automatically launching a worktree session; click the worktree when you want to
attach.

**Ghosthub → Check for Updates…** checks for a newer compatible build even when
an earlier update is already queued to install, replacing the queued update if a
newer one exists and keeping the queued one if the check fails. Nightly update
prompts include the date and build number so builds with the same version number
stay easy to tell apart.

## Rearrange navigation

To reorder hosts, see [Reorder hosts](remote-hosts.md#reorder-hosts), which
explains the shared order between the sidebar and **Settings → Hosts**.

You can also drag worktrees within a project, or drag sessions within a host's
session list when sorting is set to **Manual** (see
[Arrange the session list](sessions.md#arrange-the-session-list)). An insertion
line previews where the row will land. Reordering only affects Ghosthub's
sidebar and never changes anything in Git, kwt, tmux, Herdr, or Zellij.
