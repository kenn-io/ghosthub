---
description: Comprehensive user documentation for Ghosthub.
icon: lucide/book-open
---

# Ghosthub documentation

Ghosthub is a native macOS terminal for local and remote tmux and Herdr
sessions. It can attach to either multiplexer without Git setup. When you want
project context, it can also create and manage tmux sessions bound to Git
worktrees.

These docs explain how to operate Ghosthub. For a shorter, visual introduction,
start with the [five-minute Overview](https://ghosthub.ai/overview/).

## Start here

| If you want to… | Read… |
| --- | --- |
| Install Ghosthub and open a first session | [Getting Started](/docs/getting-started/) |
| Attach to tmux or Herdr, or manage a session | [Sessions](/docs/sessions/) |
| Connect a Mac, Linux, or experimental Windows host | [Remote Hosts](/docs/remote-hosts/) |
| Register a Git repository or create a worktree | [Projects and Worktrees](/docs/projects-worktrees/) |
| Use windows, tabs, the sidebar, or the Command Palette | [Windows and Navigation](/docs/windows-navigation/) |
| Change fonts, colors, shell behavior, or tmux themes | [Terminal Configuration](/docs/terminal-configuration/) |
| Find an application shortcut | [Keyboard Shortcuts](/docs/keyboard-shortcuts/) |
| Understand anonymous usage reporting and stored data | [Privacy](/docs/privacy/) |
| Diagnose a connection, tmux, Herdr, or worktree problem | [Troubleshooting](/docs/troubleshooting/) |

## The important mental model

Ghosthub is a client and presentation layer for multiplexers, not a replacement
for them. Tmux and Herdr can run side by side on the same hosts: using Herdr
through Ghosthub does not replace Ghosthub, and it does not disable Ghosthub's
tmux sessions or tmux-backed worktrees.

- **Hosts** are the local Mac or machines reached over SSH.
- **Sessions** are ordinary tmux sessions or running/stopped Herdr sessions on a host.
  They do not need a Git repository.
- **Projects** are Git repositories registered with
  [kwt](https://kwt.sh) on a particular host.
- **Worktrees** are project checkouts with an exact, canonical tmux session
  name supplied by kwt.

Tmux continues to own its windows, panes, layout, history, and processes. Herdr
continues to own its workspaces, tabs, panes, history, key bindings, and
processes. Closing a Ghosthub presentation detaches from a session; it does not
end the backend session. Ghosthub offers separate whole-session lifecycle
actions for both multiplexers while leaving their internal models intact.

Ghosthub uses an ordinary local or SSH client for every attachment. It does not
use tmux control mode, Herdr's remote transport, or reconstruct either
multiplexer's terminal state in Swift.

## Human and machine-readable pages

Every page has an HTML URL and a Markdown twin. For example:

- `https://ghosthub.ai/docs/sessions/`
- `https://ghosthub.ai/docs/sessions.md`

The complete machine-readable index is available at
[`https://ghosthub.ai/llms.txt`](https://ghosthub.ai/llms.txt).
