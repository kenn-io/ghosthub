---
description: Install Ghosthub and attach to your first local tmux session.
icon: lucide/rocket
---

# Getting started

## Requirements

Ghosthub currently requires:

- an Apple Silicon Mac
- macOS 26 (Tahoe) or newer
- tmux 3.2 or newer on the local Mac and on each remote macOS or Linux host

The Cmd-D and Cmd-Shift-D pane shortcuts require tmux 3.4 or newer on the
attached host. With tmux 3.2 or 3.3, use your normal tmux split keys.

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
3. Select an existing tmux session.

Ghosthub attaches an ordinary tmux client to that session. Existing tmux
windows, panes, processes, history, key bindings, and plugins stay under tmux's
control.

## Create a session

1. Open the **+** menu beside your Mac in the sidebar.
2. Choose **New Session**.
3. Enter a tmux session name and create it.

The session is not tied to a Git repository. Close the Ghosthub window or tab
to detach; your shell and other processes continue running in tmux.

## What to do next

- Learn the full session lifecycle in [Sessions](sessions.md).
- Add a machine over SSH in [Remote Hosts](remote-hosts.md).
- Add Git repository context in [Projects and Worktrees](projects-worktrees.md).
- Learn the main navigation commands in
  [Windows and Navigation](windows-navigation.md).

!!! note "Worktrees are optional"

    You do not need kwt, a Git repository, or a worktree to use Ghosthub as a
    local and remote tmux session switcher.
