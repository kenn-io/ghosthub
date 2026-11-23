---
description: Default and configurable keyboard shortcuts in Ghosthub.
icon: lucide/keyboard
---

# Keyboard shortcuts

On macOS, use the shortcuts below to jump between sessions, search scrollback,
split panes, and manage windows. For the Rust app, see
[Windows and Linux](#windows-and-linux). Open **Settings → Keyboard** to record,
clear, or reset any Ghosthub shortcut. tmux, Herdr, Zellij, and programs running
inside them keep their own key bindings.

## Default navigation

| Action | Shortcut |
| --- | --- |
| Next sibling | ++ctrl+tab++ |
| Previous sibling | ++ctrl+shift+tab++ |
| Previous native window tab | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>&#91;</kbd> |
| Next native window tab | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>&#93;</kbd> |
| Native window tabs 1 to 8 | <kbd>⌘</kbd><kbd>1</kbd> to <kbd>8</kbd> |
| Last native window tab | <kbd>⌘</kbd><kbd>9</kbd> |

Sibling navigation stays within the group you are currently in:

- Inside a worktree, it cycles through visible worktrees in the same project.
- Inside a directory workspace, it cycles through directory workspaces on the
  same host.
- Inside a standalone tmux, Zellij, Herdr, or Rex session, it cycles through the
  host's entire session list across backends, skipping stopped Herdr sessions.

Order follows the sidebar, including your current sort, manual drag order, and
visibility filters. If fewer than two items are available, Ghosthub passes the
key straight through to the terminal. Navigation shortcuts never auto-start a
stopped Herdr session.

Numbered sibling shortcuts (1 to 9) exist in Settings and start unbound. While
they are unbound, <kbd>⌘</kbd><kbd>1</kbd> through <kbd>⌘</kbd><kbd>8</kbd> pick
native tabs and <kbd>⌘</kbd><kbd>9</kbd> picks the last native tab (if a number
exceeds the tab count, Ghosthub picks the last tab). Assigning a Ghosthub
shortcut to Command-number overrides the native tab fallback.

## Other defaults

| Action | Shortcut |
| --- | --- |
| Open Command Palette | ++shift+cmd+p++ |
| Hide or show the sidebar | ++cmd+b++ |
| Create a worktree | ++shift+cmd+n++ |
| Import a pull request | ++shift+cmd+i++ |
| Split the active tmux, Herdr TUI, or Rex pane right | ++cmd+d++ |
| Split the active tmux, Herdr TUI, or Rex pane down | ++shift+cmd+d++ |
| Focus the Rex pane to the left, right, above, or below | ++option+cmd+left++, ++option+cmd+right++, ++option+cmd+up++, ++option+cmd+down++ |
| Focus the next or previous Rex pane | <kbd>⌘</kbd><kbd>&#93;</kbd>, <kbd>⌘</kbd><kbd>&#91;</kbd> |
| Zoom or unzoom the focused Rex pane | ++shift+cmd+enter++ |
| Reload configuration | ++shift+cmd+comma++ |
| Open application log | ++option+cmd+l++ |
| Find in the active terminal | ++cmd+f++ |
| Find next (toward older history) | ++cmd+g++ |
| Find previous (toward newer history) | ++shift+cmd+g++ |
| Hide the Find bar | ++shift+cmd+f++ |

**New tmux Session**, **New Herdr TUI Session**, **New Zellij Session**,
**New Rex Window**, and **Close Pane…** are in menus and the Command Palette
and start unbound. The Rex commands **New Floating Pane**, **Float or Tile
Pane**, and **Minimize Floating Window** are also in the Command Palette and
start unbound. Rex focus and zoom shortcuts apply only while viewing a Rex
window; otherwise those keys pass through to the terminal.

Herdr desktop tabs do not support Ghosthub's split shortcuts. See
[Herdr desktop splits](sessions.md#herdr-desktop-splits) for how their panes
work.

Standard macOS shortcuts are fixed and cannot be rebound in Ghosthub: Settings
(++cmd+comma++), New Window (++cmd+n++), New Tab (++cmd+t++), Close (++cmd+w++),
Close Window (++shift+cmd+w++), Quit (++cmd+q++), and standard Edit commands.
The Keyboard settings pane lists both fixed and fallback shortcuts for reference.

Closing a view, a window, or Ghosthub only detaches from tmux, Herdr, or Zellij;
it never ends your session.

## Edit a shortcut

In **Settings → Keyboard**, click a shortcut and press the new key combination.
Press **Escape** to cancel. Use the row menu to **Clear** an action or **Restore
Default**. Edits apply together when you close Settings.

Every configurable shortcut must include Command, Control, or Option so bare
keys and Shift-only combinations never steal normal typing from the terminal.
Ghosthub rejects duplicates and shortcuts reserved by fixed macOS commands,
showing the conflict inline.

![Keyboard settings with navigation shortcuts and row menus](/docs/assets/guide-keyboard.png)

## Configure `config.toml`

Custom shortcuts are saved in `~/.config/ghosthub/config.toml`:

```toml
[keyboard.shortcuts]
next-sibling = "ctrl+tab"
previous-sibling = "ctrl+shift+tab"
select-sibling-1 = "cmd+opt+1"
split-right = "none"
```

Omitted actions use their default binding; setting an action to `"none"` leaves
it unbound. Names are case-insensitive when read and normalized when saved.
Supported modifiers are `cmd`, `ctrl`, `opt`, and `shift`; supported keys
include letters, digits, punctuation, arrow keys, `tab`, `return`, `escape`,
`delete`, and `f1` through `f12`.

Ghosthub validates the entire shortcut table at once. One malformed, duplicate,
unsafe, or reserved binding rejects the whole edit: on a live reload, Ghosthub
keeps your last valid shortcuts, and if the file is already invalid at launch,
Ghosthub falls back to defaults until you fix and reload it. Errors appear in
the Keyboard pane and the application log without overwriting your file. Unknown
action names are left intact for forward compatibility.

After editing the file by hand, choose **Ghosthub → Reload Configuration**.

## Windows and Linux

The Rust app supports these configurable shortcuts:

| Action | Default |
| --- | --- |
| Command Palette | **Ctrl+Shift+P** |
| Toggle Sidebar | **Ctrl+Shift+B** |
| Next Session | **Ctrl+Tab** |
| Previous Session | **Ctrl+Shift+Tab** |
| Increase Font Size | **Ctrl+=** or **Ctrl+Plus** |
| Decrease Font Size | **Ctrl+-** |
| Reset Font Size | **Ctrl+0** |

Click the gear icon, then **Keyboard**. Click a shortcut and press the new key
combination, or press **Escape** to cancel. **Clear** unbinds an action and
**Restore Default** resets it. Changes save immediately across every open
window. Recording cancels if you leave the window or switch Settings panes.

![Keyboard settings preserving a saved Ctrl+Shift+P sidebar shortcut](/docs/assets/guide-rust-keyboard.png)

If another saved action already uses **Ctrl+Shift+P**, it keeps that binding and
the Command Palette starts unbound; either assign a different shortcut or free
**Ctrl+Shift+P** to restore its default. Explicit duplicate assignments are
rejected.

Every binding must include **Ctrl** or **Alt**. If a key conflicts with another
action, Copy, Paste, or an OS shortcut, the recorder keeps your previous
binding. **Ctrl+Shift+V** stays reserved for Paste and **Ctrl+Shift+C** for Copy
selection.

**Next Session** and **Previous Session** step through the visible sessions on
the current host in sidebar order, skipping stopped Herdr sessions. From a
worktree that is hidden from the session list, they jump to the first or last
available session; if none exists, the key goes to the terminal.

Font zoom affects every session opened in the current window (including retained
sessions when you switch back) without changing other windows or your saved
**Appearance** default. **Reset Font Size** returns to the saved Appearance
size, and new windows start at that default. The shifted Plus key also zooms in
while the default binding is active unless you explicitly bind that key to
something else.

You can also edit these shortcuts directly in `config.toml`:

```toml
[keyboard.shortcuts]
command-palette = "alt+p"
toggle-sidebar = "alt+b"
next-session = "alt+right"
previous-session = "none"
increase-font-size = "alt+up"
decrease-font-size = "alt+down"
reset-font-size = "ctrl+0"
```

Delete a line to fall back to its default, and restart Ghosthub after editing
the file by hand. Invalid or conflicting entries show a startup error until
fixed. Other macOS shortcuts are still being added to the Rust app.

## Multiplexer ownership

For terminal Find shortcuts, version requirements, and how Find interacts with
other clients, see [Find text in a terminal](sessions.md#find-text-in-a-terminal).

You can also split panes from the menu with **File → Split Right** or **File →
Split Down**. Ghosthub tells the active multiplexer to split its focused pane
directly, so custom prefixes and key bindings keep working. Splitting requires a
connected, focused session with no sheet open, running tmux 3.4+ or a running
Herdr 0.8.0+ session. On older versions, use your multiplexer's own split keys.
Pane splitting is not available on Windows psmux hosts.

Ghosthub never rewrites or overrides tmux, Herdr, shell, or program key
bindings. Any shortcut that Ghosthub does not handle passes straight through to
the active terminal.
