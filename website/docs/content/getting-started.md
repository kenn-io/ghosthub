---
description: Install Ghosthub and connect to a local tmux, Herdr, or Zellij session.
icon: lucide/rocket
---

# Getting started

Install Ghosthub, then connect to an existing multiplexer session or start a
new one straight from the sidebar without touching a local shell.

## Requirements

To run the Mac app, you need:

- an Apple Silicon Mac
- macOS 15 (Sequoia) or newer
- at least one supported multiplexer on the host where you work:
  - tmux 3.2 or newer
  - Herdr 0.8.0 or newer
  - Zellij 0.44 or newer
  - Rex or Herdr Core (experimental)

The **Cmd-D** and **Cmd-Shift-D** pane-splitting shortcuts require tmux 3.4 or
newer or Herdr 0.8.0 or newer on the attached session. On older versions, use
your multiplexer's normal split keys.

You can use any supported multiplexer by itself or mix them on the same host.
Each keeps its own panes, key bindings, and running programs. See
[Sessions](sessions.md) for what Ghosthub discovers and which actions work for
each backend.

Native Windows SSH hosts are experimental and have extra requirements. See
[Remote Hosts](remote-hosts.md#experimental-windows-hosts).

Native Windows and Linux apps are in development in Rust and are not part of the
macOS release. See the
[Rust development guide](https://github.com/kenn-io/ghosthub/blob/main/docs/rust-port.md)
for what they support today and how to build them.

## Install Ghosthub

Install the signed, notarized app from the Kenn Homebrew tap:

```sh
brew install kenn-io/tap/ghosthub
```

Then open **Ghosthub** from **Applications**.

If you prefer a manual install, download the latest DMG from
[GitHub Releases](https://github.com/kenn-io/ghosthub/releases), open it, and
drag **Ghosthub** into **Applications**.

If tmux is not installed on your Mac yet:

```sh
brew install tmux
```

Check the installed version:

```sh
tmux -V
```

Install Zellij locally if you want Zellij sessions:

```sh
brew install zellij
```

## First launch

The first time Ghosthub opens, a welcome sheet helps you set up hosts and
agent hooks.

![Ghosthub welcome sheet with Add SSH Host and the automatic agent hooks setting checked](/docs/assets/guide-welcome.png)

### Hosts

This Mac works right away. Click **Add SSH Host…** to close the welcome and
open **Settings → Hosts**, where you add the Macs and Linux machines you reach
over SSH. See [Remote hosts](remote-hosts.md).

### Agent hooks

kwt adds hooks to the user settings of each coding agent installed on a host,
such as Claude Code, Codex, and Antigravity. The hooks report what the agent
is doing, which lets Ghosthub:

- show [Approval, Input, Done, and Working badges](sessions.md#agents-waiting-for-you)
  in the sidebar and notify you;
- resume each agent's conversation when kwt
  [restores your sessions after a reboot](sessions.md#restore-sessions-after-a-reboot).

**Install and update agent hooks automatically** is checked on the welcome
sheet. When you click **Get Started** or **Add SSH Host…** with it checked,
Ghosthub:

1. Installs hooks on this Mac and every macOS and Linux SSH host.
2. Updates them after each Ghosthub update.
3. Installs them on each SSH host you add later.

Uncheck it to leave agent settings unchanged. Windows hosts are never set up
automatically. Codex asks you to trust new hooks: run `/hooks` once in Codex
on each host.

### Change it later

- **Settings → Agents → Agent Hooks** turns automatic hooks on or off, lists
  each host's hooks, and installs them on every host at once. See
  [Agents waiting for you](sessions.md#agents-waiting-for-you).
- **Show Welcome** in the Command Palette reopens the welcome sheet.
- Closing the sheet with Escape keeps automatic hooks off and does not show
  the sheet again.

### If you used Ghosthub before

After an update, the welcome sheet appears once, and only if a host has an
agent whose hooks are missing or out of date. That check reads hook status
and changes nothing. If a host cannot be reached, Ghosthub checks again at the
next launch.

## Open an existing session

1. Open Ghosthub.
2. Expand your Mac under **Hosts** in the sidebar.
3. Click any session in your Mac's list. The label at the end of each row names
   its backend: **tmux**, **zellij**, **herdr**, **herdr tui**, or **rex**.

Ghosthub attaches straight to that session with the backend's normal client.
Existing tmux windows and panes, Herdr workspaces, and Zellij tabs stay under
the backend's control. Closing the window or tab only detaches; your programs
keep running. Sessions started from a shell or a coding agent show up here too;
see [agent sessions](sessions.md#sessions-started-by-tools-and-agents).

![Ghosthub sidebar with a labeled session list under each host](/docs/assets/guide-sessions.png)

## Create a session

1. Click the **+** at the right end of your Mac's row in the sidebar.
2. Choose **New tmux Session…**, or when available, **New Zellij Session…** or
   **New Herdr Session…**.
3. Enter a name and create it.

This standalone session is not tied to any Git repository. Close the Ghosthub
window or tab to detach while your shell and programs keep running. Stopped
Herdr sessions stay visible at the bottom of the list, dimmed and labeled
**stopped**, so you can restart them with their saved layout later.

## Release and nightly builds

The [latest stable release](https://github.com/kenn-io/ghosthub/releases/latest)
is the standard download. Both the website download button and Homebrew install
it.

These guides track `main`. Sections marked **Unreleased** describe changes that
have not shipped in a stable release yet; the
[Unreleased changelog](changelog.md#unreleased) lists all of them in one place.

Nightly builds are separate test builds. If you try one, check its notes and
source commit, since a nightly can lag behind `main`. Installing a nightly
replaces the stable app and shares the same settings and saved state. Follow the
enrollment instructions included with the test build before installing it.
Website downloads and Homebrew stay on the stable channel.

## What to do next

- Read [Sessions](sessions.md) for previews, agent badges, restore, and ending
  sessions safely.
- Add SSH machines in [Remote Hosts](remote-hosts.md).
- Register Git repositories and create worktrees in
  [Projects and Worktrees](projects-worktrees.md).
- Learn windows, tabs, and Command Palette shortcuts in
  [Windows and Navigation](windows-navigation.md).

!!! note "Worktrees are optional"

    You do not need kwt, a Git repository, or a worktree to use Ghosthub. It
    works just as well as a standalone manager for local and remote tmux, Herdr,
    and Zellij sessions.
