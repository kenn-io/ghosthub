---
description: Comprehensive user documentation for Ghosthub.
icon: lucide/book-open
---

# Ghosthub documentation

Ghosthub is a native macOS terminal for your local and remote tmux sessions. It
can attach to any ordinary tmux session without Git setup. When you want
project context, it can also create and manage tmux sessions bound to Git
worktrees.

These docs explain how to operate Ghosthub. For a shorter, visual introduction,
start with the [five-minute Guide](https://ghosthub.ai/guide/).

## Start here

| If you want to… | Read… |
| --- | --- |
| Install Ghosthub and open a first session | [Getting Started](/docs/getting-started/) |
| Create, attach to, detach from, or end a tmux session | [Sessions](/docs/sessions/) |
| Connect a Mac, Linux, or experimental Windows host | [Remote Hosts](/docs/remote-hosts/) |
| Register a Git repository or create a worktree | [Projects and Worktrees](/docs/projects-worktrees/) |
| Use windows, tabs, the sidebar, or the Command Palette | [Windows and Navigation](/docs/windows-navigation/) |
| Change fonts, colors, shell behavior, or tmux themes | [Terminal Configuration](/docs/terminal-configuration/) |
| Find an application shortcut | [Keyboard Shortcuts](/docs/keyboard-shortcuts/) |
| Understand anonymous usage reporting and stored data | [Privacy](/docs/privacy/) |
| Diagnose a connection, tmux, or worktree problem | [Troubleshooting](/docs/troubleshooting/) |

## The important mental model

Ghosthub is a tmux client, not a replacement for tmux.

- **Hosts** are the local Mac or machines reached over SSH.
- **Sessions** are ordinary tmux sessions on a host. They do not need a Git
  repository.
- **Projects** are Git repositories registered with
  [kwt](https://kwt.sh) on a particular host.
- **Worktrees** are project checkouts with an exact, canonical tmux session
  name supplied by kwt.

Tmux continues to own windows, panes, layout, history, and running processes.
Closing a Ghosthub presentation detaches from a session; it does not end the
session. A session ends only through an explicit, confirmed **Kill Session**
action or removal of a worktree whose verified live session must be terminated.

Ghosthub uses an ordinary local or SSH tmux client for every attachment. It
does not use tmux control mode and it does not reconstruct terminal state in
Swift.

## Human and machine-readable pages

Every page has an HTML URL and a Markdown twin. For example:

- `https://ghosthub.ai/docs/sessions/`
- `https://ghosthub.ai/docs/sessions.md`

The complete machine-readable index is available at
[`https://ghosthub.ai/llms.txt`](https://ghosthub.ai/llms.txt).
