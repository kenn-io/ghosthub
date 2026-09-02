---
description: Keyboard navigation and configurable shortcuts in Ghosthub.
icon: lucide/keyboard
---

# Keyboard shortcuts

Ghosthub keeps application navigation separate from the shortcuts owned by
tmux, Herdr, and programs running inside the terminal. Open **Settings →
Keyboard** to record, clear, or restore a Ghosthub shortcut.

## Default navigation

| Action | Shortcut |
| --- | --- |
| Next sibling | ++ctrl+tab++ |
| Previous sibling | ++ctrl+shift+tab++ |
| Previous native window tab | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>&#91;</kbd> |
| Next native window tab | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>&#93;</kbd> |
| Native window tab 1–8 | <kbd>⌘</kbd><kbd>1</kbd>–<kbd>8</kbd> |
| Last native window tab | <kbd>⌘</kbd><kbd>9</kbd> |

Sibling navigation is local to what you are currently using:

- A worktree cycles through visible worktrees in the same project.
- A directory workspace cycles through directory workspaces on the same host.
- A standalone tmux session cycles through visible standalone tmux sessions on
  the same host.
- A Herdr session cycles through running Herdr sessions on the same host.
- A Zellij session cycles through active Zellij sessions on the same host.

The order matches the sidebar, including custom ordering and visibility
settings. At least two eligible siblings must exist. If navigation is not
available, Ghosthub leaves the key event untouched so the active terminal can
receive it. Stopped Herdr sessions are never started by a navigation shortcut.

Numbered sibling actions 1–9 are available in Settings but are unbound by
default. When those keys are otherwise unbound, <kbd>⌘</kbd><kbd>1</kbd> through
<kbd>⌘</kbd><kbd>8</kbd> select native tabs and <kbd>⌘</kbd><kbd>9</kbd> selects
the last native tab. If the requested tab number is beyond the end of a short
tab group, Ghosthub selects that group's last tab. An explicit Ghosthub
shortcut assignment takes precedence, so you can use Command-number for
numbered sibling navigation instead.

## Other defaults

| Action | Shortcut |
| --- | --- |
| Open Command Palette | ++shift+cmd+p++ |
| Hide or show the sidebar | ++cmd+b++ |
| Create a worktree | ++shift+cmd+n++ |
| Import a pull request | ++shift+cmd+i++ |
| Split the active tmux or Herdr pane right | ++cmd+d++ |
| Split the active tmux or Herdr pane down | ++shift+cmd+d++ |
| Reload configuration | ++shift+cmd+comma++ |
| Open application log | ++option+cmd+l++ |
| Find in the active terminal | ++cmd+f++ |
| Find next, toward older history | ++cmd+g++ |
| Find previous, toward newer history | ++shift+cmd+g++ |
| Hide the Find bar | ++shift+cmd+f++ |

New tmux Session, New Herdr Session, and New Zellij Session remain available
in menus and the Command Palette but are unbound by default.

Standard macOS commands are fixed rather than configurable in Ghosthub. These
include Settings (++cmd+comma++), New Window (++cmd+n++), New Tab (++cmd+t++),
Close (++cmd+w++), Close Window (++shift+cmd+w++), Quit (++cmd+q++), and the
usual Edit shortcuts. Numbered native tabs (++cmd+1++ through ++cmd+9++) are
fallbacks that yield to explicit Ghosthub shortcut assignments. The Keyboard
pane lists both groups for reference.

Closing a presentation, window, or the app detaches from tmux, Herdr, or Zellij. It does
not end the session.

## Edit a shortcut

In **Settings → Keyboard**, click a shortcut value and press the new key
combination. Press Escape to cancel recording. Use the row menu to **Clear** an
action or **Restore Default**. Changes remain in the Settings draft and take
effect together when Settings closes.

Every configurable binding must contain Command, Control, or Option. Bare keys
and Shift-only combinations are rejected because they could intercept ordinary
terminal input. Ghosthub also rejects a binding already used by another action
or reserved by a fixed macOS command; the recorder shows the conflict inline.

## Configure `config.toml`

Shortcut overrides are also stored in
`~/.config/ghosthub/config.toml`:

```toml
[keyboard.shortcuts]
next-sibling = "ctrl+tab"
previous-sibling = "ctrl+shift+tab"
select-sibling-1 = "cmd+opt+1"
split-right = "none"
```

A missing action uses its compiled default. Set an action to `"none"` to leave
it unbound. Names are case-insensitive when read and normalized when Settings
writes them. Supported modifiers are `cmd`, `ctrl`, `opt`, and `shift`;
supported keys include letters, digits, punctuation, arrows, `tab`, `return`,
`escape`, `delete`, and `f1` through `f12`.

Configuration validation is atomic. A malformed, duplicate, unsafe, or
reserved known binding rejects the complete edit. During a live reload,
Ghosthub keeps the last valid shortcut set. If the file is already invalid at
launch, Ghosthub uses compiled defaults until it is fixed and reloaded. The
Keyboard pane and application log report the error without rewriting the
invalid file. Unknown action names are preserved for forward compatibility.

Choose **Ghosthub → Reload Configuration** after editing the file manually.

## Multiplexer ownership

Command-F opens a compact Find bar for standalone terminals and supported
POSIX tmux sessions. Return and Command-G request the next match toward older
history; Shift-Return and Shift-Command-G request the previous match toward
newer history. Escape, Shift-Command-F, or the close button ends Find.

Standalone libghostty search follows Ghostty.app's newest-to-oldest,
non-wrapping behavior. Tmux owns wrapping and the first step after changing
direction. Tmux also owns pane-wide copy mode and the viewport, so another
client attached to the same pane can see or cancel the search. Find requires
tmux 3.4 or newer. Herdr, Zellij, Windows psmux, and older tmux versions leave
Find unavailable rather than searching only the visible client output.

Choose **File → Split Right** or **File → Split Down** if you prefer menus.
Ghosthub asks the active multiplexer to split its focused pane directly, so
custom prefixes and key bindings keep working. The shortcuts require a
connected terminal with keyboard focus and no open sheet. Tmux requires version
3.4 or newer; Herdr requires version 0.8.0 or newer and a confirmed running
session. With older versions, use the multiplexer’s normal split keys. Pane
splitting is not available on Windows psmux hosts.

Ghosthub does not configure or replace tmux, Herdr, shell, or terminal-program
key bindings. Unmatched and unavailable Ghosthub shortcuts continue through to
the active terminal.
