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

## Shell startup

For local shells, Ghosthub preserves libghostty's normal macOS login-shell and
shell-integration behavior. It does not force a custom shell command by
default. Your ordinary zsh startup files and key bindings should load as they
do in a native macOS terminal.

Ghosthub avoids inheriting launcher-terminal `EDITOR` and `VISUAL` values that
can unexpectedly change zsh keymaps. It sets `TERM_PROGRAM` to `ghosthub`.

## Session previews

**Settings → Terminal → Session previews** controls optional sidebar previews
for tmux presentations you have already opened in a workspace:

- **Off** is the default and performs no preview rendering.
- **Efficient** keeps a bitmap of the latest frame captured on disclosure or
  when you navigate away. It does not poll.
- **Live** polls expanded tiles at no more than two frames per second. Ghosthub
  limits live rendering to four inactive previews across all windows.

The preference applies immediately. Each workspace window remembers its own
expanded rows in memory, even while previews are Off. A fixed 16:10 tile shows
the complete captured frame with letterboxing when the terminal has another
aspect ratio. Reconnecting sessions show a placeholder until Ghosthub verifies
that the replacement client is attached to the same server-side session.

Previews reuse retained tmux clients only. They do not open sessions, create an
extra tmux or SSH client, persist terminal pixels to disk, or reconstruct tmux
panes and layout.

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

Theme application is not available for the Console Panel or native Windows
sessions.

## Clipboard behavior

Remote tmux copy mode can copy text to the Mac clipboard through OSC 52. Paste
uses the configured terminal shortcut and libghostty's safe paste path.

## Quit behavior

**Confirm before quitting Ghosthub** is enabled by default under
**Settings → Terminal**. Quitting the app or closing its windows detaches from
tmux and leaves sessions running.
