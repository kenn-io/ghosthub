---
description: Comprehensive user documentation for Ghosthub.
icon: lucide/book-open
---

# Ghosthub documentation

Ghosthub is the native macOS terminal for all your multiplexers. Today it
supports local and remote tmux, Herdr, and Zellij sessions. Any supported
multiplexer works without Git setup; when you want project context, Ghosthub
can also create and manage tmux sessions bound to Git worktrees.

These docs explain how to operate Ghosthub. For a shorter, visual introduction,
start with the [five-minute Overview](https://ghosthub.ai/overview/).

## Start here

| If you want to… | Read… |
| --- | --- |
| Install Ghosthub and open a first session | [Getting Started](/docs/getting-started/) |
| See what changed in each release | [Changelog](/docs/changelog/) |
| Attach to tmux, Herdr, or Zellij, or manage a session | [Sessions](/docs/sessions/) |
| Connect a Mac, Linux, or experimental Windows host | [Remote Hosts](/docs/remote-hosts/) |
| Register a Git repository or create a worktree | [Projects and Worktrees](/docs/projects-worktrees/) |
| Use windows, tabs, the sidebar, or the Command Palette | [Windows and Navigation](/docs/windows-navigation/) |
| Change fonts, colors, shell behavior, or tmux themes | [Terminal Configuration](/docs/terminal-configuration/) |
| Find an application shortcut | [Keyboard Shortcuts](/docs/keyboard-shortcuts/) |
| Understand anonymous usage reporting and stored data | [Privacy](/docs/privacy/) |
| Diagnose a connection, multiplexer, or worktree problem | [Troubleshooting](/docs/troubleshooting/) |

## The important mental model

Ghosthub is a client and presentation layer for all multiplexers, not a
replacement for them. Every supported backend is a first-class peer and can
run beside the others on the same hosts. The model is intentionally open to
future backends, including the [terminal multiplexer Superlogical is
building](https://www.superlogical.com/) once it has a public integration
surface.

- **Hosts** are the local Mac or machines reached over SSH.
- **Sessions** are ordinary tmux sessions, running/stopped Herdr sessions, or
  active Zellij sessions on a host.
  They do not need a Git repository.
- **Projects** are Git repositories registered with
  [kwt](https://kwt.sh) on a particular host.
- **Worktrees** are project checkouts with an exact, canonical tmux session
  name supplied by kwt.

Tmux continues to own its windows, panes, layout, history, and processes. Herdr
continues to own its workspaces, tabs, panes, history, key bindings, and
processes. Closing a Ghosthub presentation detaches from a session; it does not
end the backend session. Ghosthub offers separate whole-session lifecycle
actions while leaving each multiplexer's internal model intact. Zellij owns
its tabs, panes, layout, history, plugins, and processes.

Ghosthub uses an ordinary local or SSH client for every attachment. It does not
use tmux control mode, Herdr's remote transport, or reconstruct any
multiplexer's terminal state in Swift.

## Human and machine-readable pages

Every page has an HTML URL and a Markdown twin. For example:

- `https://ghosthub.ai/docs/sessions/`
- `https://ghosthub.ai/docs/sessions.md`

The complete machine-readable index is available at
[`https://ghosthub.ai/llms.txt`](https://ghosthub.ai/llms.txt).
