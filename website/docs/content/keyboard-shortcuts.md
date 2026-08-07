---
description: Keyboard shortcuts for Ghosthub application and workspace actions.
icon: lucide/keyboard
---

# Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open Settings | ++cmd+comma++ |
| Reload terminal configuration | ++shift+cmd+comma++ |
| Open Command Palette | ++shift+cmd+p++ |
| Hide or show the sidebar | ++cmd+b++ |
| Select worktree 1–9 | ++cmd+1++ through ++cmd+9++ |
| Select previous worktree | ++option+cmd+up++ |
| Select next worktree | ++option+cmd+down++ |
| Create or import a worktree | ++shift+cmd+n++ |
| New window | ++cmd+n++ |
| New tab | ++cmd+t++ |
| Split the tmux pane right | ++cmd+d++ |
| Split the tmux pane down | ++shift+cmd+d++ |
| Close session presentation | ++cmd+w++ |
| Close window | ++shift+cmd+w++ |
| Open application log | ++option+cmd+l++ |
| Quit Ghosthub | ++cmd+q++ |

Closing a presentation, window, or the app detaches from tmux. It does not end
the session.

Choose **File > Split Right** or **File > Split Down** if you prefer menus.
Ghosthub asks tmux to split the pane directly, so custom prefixes and key
bindings keep working. The shortcuts require a connected tmux terminal with
keyboard focus, no open sheet, and tmux 3.4 or newer on the attached host. With
tmux 3.2 or 3.3, use your normal tmux split keys. Pane splitting is not yet
available on Windows psmux hosts.
