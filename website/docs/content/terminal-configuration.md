---
description: Configure Ghosthub's libghostty terminal and tmux session themes.
icon: lucide/settings-2
---

# Terminal configuration

Ghosthub embeds libghostty for terminal rendering. It does not embed or run
Ghostty.app, and Ghostty.app is not a runtime dependency.

## Configuration file

Ghosthub's terminal configuration lives at:

```text
~/.config/ghosthub/ghostty.conf
```

The file uses [Ghostty's configuration format](https://ghostty.org/docs/config/reference),
but it is owned and loaded independently by Ghosthub. Global Ghostty.app
configuration does not affect Ghosthub.

Ghosthub reloads terminal configuration after the file changes. Use
++shift+cmd+comma++ to request a reload immediately.

## Terminal themes

Ghostty's built-in color schemes ship with Ghosthub, so `theme` accepts any of
their names directly:

```text
theme = Catppuccin Macchiato
```

Conditional light and dark themes, and paths to your own theme files, work the
same way.

## Shell startup

For local shells, Ghosthub preserves libghostty's normal macOS login-shell and
shell-integration behavior. It does not force a custom shell command by
default. Your ordinary zsh startup files and key bindings should load as they
do in a native macOS terminal.

Ghosthub avoids inheriting launcher-terminal `EDITOR` and `VISUAL` values that
can unexpectedly change zsh keymaps. It sets `TERM_PROGRAM` to `ghosthub`.

## Session previews

**Settings → Terminal → Session previews** controls optional sidebar previews
for tmux presentations in each workspace window:

- **Off** is the default and performs no preview rendering.
- **Efficient** keeps the latest GPU-rendered frame captured on disclosure or
  when you navigate away. It does not refresh in the background.
- **Live** refreshes expanded tiles at no more than two frames per second.
  Ghosthub limits live rendering to four inactive previews across all windows.
- **Always Live** attaches every freshly discovered tmux session on every
  reachable POSIX host, expands its tile by default, and removes the
  four-preview limit. Individual tiles can still be collapsed without
  disconnecting them.
  Clients start incrementally. Ghosthub matches each hidden client's terminal
  grid to the tmux window and status rows before attachment, so even a sole
  preview client leaves the server-side window size unchanged.
  Expect substantially higher CPU, GPU, memory, and SSH use.

The preference takes effect when you close Settings. Each workspace window
remembers its own expanded rows in memory, even while previews are Off. A tile
follows its terminal's aspect ratio, preserving the complete
frame without cropping.
Reconnecting sessions show a placeholder until Ghosthub verifies that the
replacement client is attached to the same server-side session.
Tmux older than 3.4 cannot provide a safe client identity, so Always Live skips
its automatic attachment. You can still open that session normally. Windows/
psmux sessions are not attached automatically because psmux has no non-sizing
client mode.

Efficient and Live preview only clients you opened. Always Live deliberately
opens one retained tmux or SSH client for each discovered POSIX session.
Preview rendering never adds a second client, persists terminal pixels to
disk, copies terminal pixels through the CPU, or reconstructs tmux panes and
layout.

## Tmux themes

The **Tmux Theme** picker in Settings supplies colors for new sessions created
by Ghosthub. When **Follow ghostty.conf** is selected, the effective foreground
and background follow the current light or dark appearance.

Existing tmux sessions keep their own appearance by default. This avoids
silently repainting a shared session for every attached client.

To change the active connected session once, choose **Session → Apply Theme to
Current Session** or the matching Command Palette action. It updates the
session's existing windows and tmux chrome for all attached clients.

To style future attachments to shared sessions automatically, enable **Apply
theme to shared tmux sessions** in Settings. This is an explicit opt-in.

Ghosthub also applies a modest client-local text-contrast floor so inherited
ANSI colors remain legible on light and dark backgrounds without changing the
shared tmux theme. An explicit `minimum-contrast` value in `ghostty.conf`
remains authoritative.

Theme application is not available for the Console Panel or native Windows
sessions.

## Clipboard behavior

Remote tmux copy mode can copy text to the Mac clipboard through OSC 52. Paste
uses the configured terminal shortcut and libghostty's safe paste path.

## Quit behavior

**Confirm before quitting Ghosthub** is enabled by default under
**Settings → Terminal**. Quitting the app or closing its windows detaches from
tmux and leaves sessions running.
