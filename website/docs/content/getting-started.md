---
description: Install Ghosthub and attach to a local tmux or Herdr session.
icon: lucide/rocket
---

# Getting started

## Requirements

Ghosthub currently requires:

- an Apple Silicon Mac
- macOS 26 (Tahoe) or newer
- tmux 3.2 or newer for tmux sessions
- Herdr 0.8.0 or newer for Herdr sessions

The Cmd-D and Cmd-Shift-D pane shortcuts require tmux 3.4 or newer or Herdr
0.8.0 or newer on the attached session. With older versions, use your normal
multiplexer split keys.

Use either multiplexer or both. When the Herdr CLI is available on the local
Mac or a remote POSIX host, Ghosthub discovers its running and stopped sessions.
Experimental Windows hosts do not support Herdr.

Ghosthub and Herdr are complementary, not competing choices. Keep using tmux
and tmux-backed worktrees wherever they fit, run Herdr wherever it fits, and
open both kinds of session from the same Ghosthub host sidebar.

Native Windows hosts are experimental and have additional requirements. See
[Remote Hosts](remote-hosts.md#experimental-windows-hosts).

## Install Ghosthub

Install the signed, notarized app from the Kenn Homebrew tap:

```sh
brew install kenn-io/tap/ghosthub
```

Then launch **Ghosthub** from **Applications**.

As a manual alternative, download the latest DMG from
[GitHub Releases](https://github.com/kenn-io/ghosthub/releases), open it, and
drag **Ghosthub** to **Applications**.

If tmux is not installed locally:

```sh
brew install tmux
```

Verify it with:

```sh
tmux -V
```

## Open an existing session

1. Launch Ghosthub.
2. Expand your Mac under **Hosts** in the sidebar.
3. Select an existing entry under **Tmux Sessions** or **Herdr Sessions**.

Ghosthub attaches the ordinary whole-session client for that backend. Existing
tmux windows and panes or Herdr workspaces, tabs, and panes stay under their
backend's control. Closing the presentation detaches without stopping the
server.

## Create a session

1. Expand your Mac in the sidebar.
2. Select the **+** beside **Tmux Sessions** or, when available, **Herdr
   Sessions**.
3. Enter a session name and create it.

The session is not tied to a Git repository. Close the Ghosthub window or tab
to detach; your shell and other processes continue running in its multiplexer.
Stopped Herdr sessions remain visible with a **Stopped** label so you can
restart their saved shape later.

## What to do next

- Learn the full session lifecycle in [Sessions](sessions.md).
- Add a machine over SSH in [Remote Hosts](remote-hosts.md).
- Add Git repository context in [Projects and Worktrees](projects-worktrees.md).
- Learn the main navigation commands in
  [Windows and Navigation](windows-navigation.md).

!!! note "Worktrees are optional"

    You do not need kwt, a Git repository, or a worktree to use Ghosthub as a
    local and remote tmux or Herdr session switcher.
