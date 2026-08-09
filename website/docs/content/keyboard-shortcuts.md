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
| Split the active tmux or Herdr pane right | ++cmd+d++ |
| Split the active tmux or Herdr pane down | ++shift+cmd+d++ |
| Close session presentation | ++cmd+w++ |
| Close window | ++shift+cmd+w++ |
| Open application log | ++option+cmd+l++ |
| Quit Ghosthub | ++cmd+q++ |

Closing a presentation, window, or the app detaches from tmux or Herdr. It does
not end the session.

Choose **File > Split Right** or **File > Split Down** if you prefer menus.
Ghosthub asks the active multiplexer to split its focused pane directly, so
custom prefixes and key bindings keep working. The shortcuts require a
connected terminal with keyboard focus and no open sheet. Tmux requires version
3.4 or newer; Herdr requires version 0.8.0 or newer and a confirmed running
session. With older versions, use the multiplexer’s normal split keys. Pane
splitting is not available on Windows psmux hosts.
