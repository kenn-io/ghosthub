---
description: Manage local and remote tmux, Herdr, and Zellij sessions without juggling SSH tabs or touching a local shell.
icon: lucide/book-open
---

# Ghosthub documentation

Ghosthub is a native Mac hub for local and remote terminal multiplexers. Instead
of opening tabs in a general-purpose terminal like iTerm2, Ghostty, or Kitty to
SSH into machines, list sessions, and reattach after drops, you pick a host and
session in Ghosthub and land straight inside it.

It works with tmux, Herdr, and Zellij across your Mac and SSH hosts, including
sessions started by coding agents. Add Git worktrees when you want a separate
checkout and session for each task.

For a quick visual tour, start with the
[five-minute overview](https://ghosthub.ai/overview/).

These guides and screenshots track `main`. Features marked **Unreleased** are
newer than the latest stable download. See
[release and nightly builds](/docs/getting-started/#release-and-nightly-builds)
to pick a build.

## Start here

| If you want to... | Read |
| --- | --- |
| Install Ghosthub and open your first session | [Getting Started](/docs/getting-started/) |
| See what changed in each release | [Changelog](/docs/changelog/) |
| Attach to tmux, Herdr, Rex, or Zellij, or manage sessions | [Sessions](/docs/sessions/) |
| Pick up work started by a tool or agent | [Agent sessions](/docs/sessions/#sessions-started-by-tools-and-agents) |
| Save a command for a new remote tmux session | [Launch profiles](/docs/launch-profiles/) |
| Connect a Mac, Linux, or experimental Windows host | [Remote Hosts](/docs/remote-hosts/) |
| Register a Git repository or create a worktree | [Projects and Worktrees](/docs/projects-worktrees/) |
| Use windows, tabs, the sidebar, or the Command Palette | [Windows and Navigation](/docs/windows-navigation/) |
| Change fonts, colors, shell behavior, or tmux themes | [Terminal Configuration](/docs/terminal-configuration/) |
| Find or customize a shortcut | [Keyboard Shortcuts](/docs/keyboard-shortcuts/) |
| Review anonymous usage reporting and local data | [Privacy](/docs/privacy/) |
| Fix a connection, multiplexer, or worktree problem | [Troubleshooting](/docs/troubleshooting/) |

## How Ghosthub organizes your work

A terminal multiplexer keeps your shells and programs running when you close a
window or lose your connection. Ghosthub finds those sessions across your
machines, puts them in one sidebar, and reconnects when SSH drops. You can run
tmux, Herdr, and Zellij side by side on the same host.

- **Hosts** are your Mac and any machines you reach over SSH.
- **Sessions** are ordinary tmux sessions, running or stopped Herdr sessions,
  Herdr desktop terminals and tabs, Rex windows, or active Zellij sessions on a
  host. They do not require a Git repository.
- **Projects** are Git repositories registered with [kwt](https://kwt.sh) on a
  host.
- **Worktrees** are separate branch checkouts inside a project, each paired with
  a kwt-managed tmux session.

Each multiplexer stays in charge of its own panes, layout, scrollback, key
bindings, and running programs. Closing a Ghosthub window or tab only detaches
and leaves your session running. To end a session, use a separate confirmed
**Kill Session…** or **Stop Session…** action.

![Ghosthub with local and remote sessions and project worktrees](/docs/assets/hero.png)

## Give these guides to your agent

Point your agent at [`llms.txt`](https://ghosthub.ai/llms.txt) so it can find
the right page. Every guide has both a web URL and a Markdown copy built from
the same source:

- `https://ghosthub.ai/docs/sessions/`
- `https://ghosthub.ai/docs/sessions.md`

Both versions contain the exact same commands, screenshots, and limits.
