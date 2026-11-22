---
description: Configure Ghosthub's libghostty rendering, fonts, colors, clipboard, and tmux themes.
icon: lucide/settings-2
---

# Terminal configuration

On macOS, Ghosthub renders attached sessions with libghostty 1.4.0 (built with
Zig 0.17.0) and reads its own configuration file for fonts, colors, and shell
settings. You do not need Ghostty.app or Zig installed.

## Rust Linux fonts (unreleased)

The native Rust Linux app bundles **Inter** for UI text and **JetBrains Mono**
for the default terminal font so the grid always uses a fixed-width font across
Linux machines.

Open **Settings → Appearance** to pick a terminal font, size, and theme.
Existing font choices stay intact; select **JetBrains Mono** to switch to the
bundled font. Windows keeps its native UI font and Cascadia Mono terminal
default. The macOS sections below cover the Swift app.

Use **Ctrl+=**, **Ctrl+-**, and **Ctrl+0** to zoom the current window's font
size temporarily without changing the saved Appearance default. You can change
those shortcuts in [Settings → Keyboard](keyboard-shortcuts.md#windows-and-linux).

![Rust Linux Appearance settings with the bundled terminal font](/docs/assets/guide-rust-appearance.png)

## Configuration file

Ghosthub's terminal config lives at:

```text
~/.config/ghosthub/ghostty.conf
```

It uses [Ghostty's config format](https://ghostty.org/docs/config/reference),
but Ghosthub loads it separately. Your Ghostty.app configuration does not affect
Ghosthub.

Ghosthub reloads automatically when `ghostty.conf` changes, or you can press
++shift+cmd+comma++ to reload right away.

## Terminal themes

Ghostty's built-in color schemes are bundled with Ghosthub, so you can set
`theme` to any of them by name:

```text
theme = Catppuccin Macchiato
```

Conditional light/dark themes and paths to custom theme files work the same way.

## Background transparency

Ghosthub reads `background-opacity` and `background-blur` from `ghostty.conf` at
launch and on reload:

```text
background-opacity = 0.85
background-blur = 20
```

When opacity is below 1, Ghosthub windows turn translucent with blur behind
them. Enabling **Increase contrast** (**System Settings → Accessibility →
Display**) forces opaque windows, and native macOS fullscreen is always opaque.
There is no separate opacity toggle in Ghosthub's Settings, though a project
`terminal.conf` or an imported `config-file` can override these values.

## Shell startup

For local shells, Ghosthub uses libghostty's normal macOS login-shell path and
shell integration instead of forcing a custom shell command, so your zsh startup
files and key bindings work just like in a normal Mac terminal.

Ghosthub clears launcher-terminal `EDITOR` and `VISUAL` variables so launching
Ghosthub from another terminal does not flip zsh into unexpected keymaps. It
sets `TERM_PROGRAM` to `ghosthub`.

## Session previews

Open **Settings → Terminal → Session previews** to turn on still or live tmux
previews in the sidebar. See
[Session previews](sessions.md#preview-opened-tmux-sessions) for preview modes,
tmux version requirements, and resource costs.

## Tmux themes

The **Tmux Theme** picker in Settings sets the colors used for new tmux sessions
created from Ghosthub. When set to **Follow ghostty.conf**, colors track your
current light or dark theme automatically.

Existing tmux sessions keep their own colors by default so Ghosthub does not
silently repaint a shared session for everyone attached to it.

To apply your theme to the current session once, choose **Session → Apply Theme
to Current Session** (or run it from the Command Palette). That updates the
session's windows and tmux bars for all attached clients.

To style future attachments to shared sessions automatically, turn on **Apply
theme to shared tmux sessions** in Settings.

Ghosthub also applies a small local contrast floor so inherited ANSI colors stay
readable on light and dark backgrounds without modifying the shared tmux theme.
If you set `minimum-contrast` in `ghostty.conf`, Ghosthub uses your value.

Tmux themes do not apply to the Console Panel or native Windows sessions.

![Ghosthub Appearance settings with the tmux theme picker](/docs/assets/guide-terminal.png)

## Clipboard behavior

Remote tmux copy mode can copy text to your Mac clipboard using OSC 52. The
`clipboard-write` setting controls whether Ghosthub allows those writes. Remote
programs cannot read your Mac clipboard through OSC 52, while pasting with your
normal shortcut keeps working.

To paste an image into a tool running inside a local or remote macOS or Linux
tmux session, copy the image on your Mac and press ++cmd+v++. Ghosthub writes a
PNG to `~/.ghosthub/paste-images/` on that host and pastes its full path into
the active pane. If the clipboard holds both text and an image, text wins.
++ctrl+v++ still passes straight to the terminal. Each new image paste also
cleans up cached images older than 7 days.

Image paste is not supported in Herdr, Zellij, or native Windows/psmux sessions.
See [Sessions](sessions.md#attach-and-detach) for session controls.

### Windows and Linux

In the Rust app, drag across visible terminal text to select it. Double-click
for a word, or triple-click for a full line even when it wraps across rows; drag
afterward to extend by words or lines. Hold **Shift** when tmux or another
terminal app captures mouse events. The highlight stays visible, and
**Ctrl+Shift+C** copies it. Use your multiplexer's copy mode to select text
scrolled off screen.

Selections copy to the clipboard automatically by default. Click the gear icon,
open **Terminal**, and turn off **Copy selections directly to the clipboard** to
copy only with **Ctrl+Shift+C**. Changes save right away across all windows, and
manual copies still work even when **Allow remote clipboard writes** is off.

![Selecting terminal text in the Rust app](/docs/assets/guide-rust-selection.png)

![Rust Terminal settings with automatic selection copying](/docs/assets/guide-rust-terminal-settings.png)

### Open terminal links

In the Rust app, **Ctrl-click** an underlined link to open it in your system's
default app, or hover to preview the URL. Plain clicks and drags still select
text; hold **Shift** if the terminal app uses the mouse.

Programs must emit OSC 8 hyperlinks; plain-text URLs are not auto-linked. tmux
3.4 and newer forward OSC 8 links automatically in normal sessions and kwt
worktrees, including protected PR workspaces, with no extra tmux config.

![Terminal links with a destination preview in the Rust app](/docs/assets/guide-rust-hyperlinks.png)

## Quit behavior

**Confirm before quitting Ghosthub** is on by default in **Settings →
Terminal**. Quitting Ghosthub or closing its windows only detaches and leaves
your sessions running.
