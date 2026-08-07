<p align="center">
  <a href="https://ghosthub.ai">
    <img src="Resources/AppIcon/Ghosthub.svg" width="112" alt="Ghosthub app icon">
  </a>
</p>

<h1 align="center">Ghosthub</h1>

<p align="center">
  <strong>A native power terminal for your tmux fleet.</strong>
  <br>
  Create or attach to any session, or manage worktree-bound sessions from Git
  branches and GitHub pull requests, locally or over SSH.
</p>

<p align="center">
  <img alt="macOS 26 or newer" src="https://img.shields.io/badge/macOS-26%2B-111111?style=flat-square&logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-111111?style=flat-square">
  <a href="LICENSE">
    <img alt="GNU AGPL v3.0" src="https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square">
  </a>
</p>

<p align="center">
  <a href="https://ghosthub.ai"><strong>Website</strong></a>
  ·
  <a href="https://github.com/kenn-io/ghosthub/releases"><strong>Download</strong></a>
  ·
  <a href="https://ghosthub.ai/guide/"><strong>Guide</strong></a>
  ·
  <a href="https://ghosthub.ai/docs/"><strong>Docs</strong></a>
  ·
  <a href="CHANGELOG.md"><strong>Changelog</strong></a>
  ·
  <a href="https://discord.gg/nEB7VaAnU9"><strong>Discord</strong></a>
</p>

<p align="center">
  <img
    src="https://raw.githubusercontent.com/kenn-io/ghosthub/refs/heads/website-assets/hero.png?asset=hero"
    width="960"
    alt="Ghosthub showing local and remote tmux sessions and kwt worktrees in its sidebar"
  >
</p>

Ghosthub creates and attaches to ordinary tmux sessions across your Mac and SSH
hosts, including sessions started outside Ghosthub. They need no Git project or
worktree setup: create a named session, pick up an existing one, and manage the
whole fleet from one native sidebar.

Ghosthub also manages tmux sessions bound to Git worktrees. Register a
repository, then continue a local or remote branch, create a branch, or import
a GitHub pull request without leaving the app. Its bundled [kwt](https://kwt.sh)
helper manages the linked worktree lifecycle while Ghosthub opens the canonical
tmux session for that workspace.

In both modes, tmux continues to own windows, panes, layout, history, and
process lifetime. Ghosthub provides the native, libghostty-powered terminal and
supervises SSH keepalives and reconnects.

There is no proprietary session format, background daemon, or migration.

Ghosthub is alpha software. It likely has more bugs than more mature terminal
applications like Ghostty, but please open
[GitHub issues](https://github.com/kenn-io/ghosthub/issues) to report bugs and
we will do our best to fix them.

## Highlights

- **Any tmux session.** Create or attach to sessions on local and remote hosts,
  including sessions created outside Ghosthub. No Git project or worktree is
  required.
- **Managed worktree sessions.** Register an existing checkout, continue a
  local or remote branch, create a branch, import a GitHub pull request, and
  remove a linked worktree through the bundled [kwt](https://kwt.sh)
  helper. No system kwt installation is required.
- **Resilient SSH.** Keepalives and automatic reconnect preserve remote
  presentations through ordinary network interruptions.
- **Deliberate tmux lifecycle.** Closing a presentation detaches. Confirmed
  controls end standalone or worktree-backed sessions, and a bare session that
  exits can be reopened under its exact previous name.
- **Experimental native Windows hosts.** Connect to OpenSSH hosts running
  PowerShell and [psmux](https://github.com/marlocarlo/psmux), with managed
  AMD64 and ARM64 kwt helpers for already registered project inventory.
- **Native workspaces.** Open independent windows or macOS tabs, and search
  sessions and common actions from the Command Palette.
- **Predictable tmux theming.** New sessions created by Ghosthub use the
  selected Tmux Theme, including resolved light and dark colors from
  `ghostty.conf`. Existing sessions keep their appearance unless you apply the
  theme to the active session or opt into shared-session styling.
- **Fast terminal rendering.** Ghosthub embeds libghostty with an isolated,
  Ghostty-compatible configuration. No Electron and no Ghostty.app dependency.

## Install

Ghosthub requires:

- an Apple Silicon Mac
- macOS 26 (Tahoe) or newer
- tmux 3.2 or newer locally and on remote macOS or Linux hosts

Experimental native Windows hosts require Windows 11 build 22523 or newer,
OpenSSH, Windows PowerShell 5.1 or newer, and psmux with its `tmux.exe`
compatibility alias available.

Install Ghosthub from the Kenn Homebrew tap:

```sh
brew install kenn-io/tap/ghosthub
```

Launch **Ghosthub** from **Applications**. As a manual alternative, download
the latest notarized [Ghosthub DMG](https://github.com/kenn-io/ghosthub/releases)
and drag **Ghosthub** to **Applications**.

Install tmux locally if needed:

```sh
brew install tmux
```

Remote macOS and Linux hosts need tmux. Every remote host needs
non-interactive SSH authentication backed by a key or SSH agent; password-only
hosts cannot populate the sidebar.

## Quick start

### Open or create a session

Expand your Mac in the sidebar and select an existing tmux session. Use the
host's **+** menu to create a named session. Closing its Ghosthub window or tab
only detaches. To end a standalone session, hover its sidebar row and click the
**×**; worktree-backed sessions keep **Kill Session…** in their action menu.
Both paths confirm the exact host and session before terminating it. If a bare
session exits on its own, **Reopen** creates the same named session again.

### Add an SSH host

Open **Settings → Hosts**, add an SSH address such as `devbox`,
`alice@build-server`, or `server.example.com:2222`, and choose
**Test Connection**. If your OpenSSH policy prompts for a new host key, verify
the host once with system `ssh` first.

Tmux-only hosts need no other setup. For project and worktree context, choose
**Install kwt Worktree Helper** in Host Settings. Ghosthub copies the pinned
helper for that host's operating system and CPU; it does not install or replace
a system kwt.

Native Windows support is experimental. Select **Windows (psmux)** for a
Windows OpenSSH host with PowerShell and psmux installed. Ghosthub can upload
its matching AMD64 or ARM64 kwt helper after explicit confirmation, but the
Windows helper is currently unsigned and project registration is not yet
available on Windows.

### Add projects and worktrees

Open the **+** menu beside a local or remote host, choose **Add Project**, and
enter the absolute path to an existing checkout. Ghosthub registers that one
repository through its bundled or managed kwt helper and does not scan the
machine.

Pull-request import requires the
[GitHub CLI (`gh`)](https://cli.github.com/) on the host containing the project:
your Mac for a local project or the SSH machine for a remote one. Install it
there and run `gh auth login` on that same host before importing. For an HTTPS
Git remote, ordinary Git authentication must also work there; `gh auth
setup-git` configures GitHub CLI as a Git credential helper.

Select a project and press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>N</kbd> to create a Git
worktree or import a GitHub pull request. The branch picker searches available
local and remote branches, distinguishes same-named sources, and creates a
local tracking branch when needed; unmatched input creates a new branch.
Selecting the primary checkout or a linked worktree creates or repairs its
canonical tmux session when needed, then attaches an ordinary tmux client.

To remove a non-primary worktree, hover its sidebar row and click the **×**.
After confirmation, Ghosthub terminates that worktree's verified live tmux
session if needed and asks kwt to remove the checkout. The Git branch is kept.

## Navigation

Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>P</kbd> to open the **Command Palette** and
search across hosts, projects, worktrees, sessions, settings, and actions.
Use **Settings → Worktrees** to hide tool-owned standalone tmux sessions with
case-sensitive `*` and `?` patterns. Kwt workspaces always remain visible under
their projects.

| Shortcut | Action |
| --- | --- |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>P</kbd> | Open Command Palette |
| <kbd>⌘</kbd><kbd>T</kbd> | Open a new workspace tab |
| <kbd>⌘</kbd><kbd>N</kbd> | Open a new workspace window |
| <kbd>⌘</kbd><kbd>B</kbd> | Show or hide the sidebar |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>N</kbd> | Create a worktree |
| <kbd>⌘</kbd><kbd>W</kbd> | Detach the current presentation |
| <kbd>⌘</kbd><kbd>,</kbd> | Open Settings |

## Terminal configuration

Ghosthub reads its own configuration at:

```text
~/.config/ghosthub/ghostty.conf
```

The file uses
[Ghostty's configuration format](https://ghostty.org/docs/config/reference),
but remains independent of Ghostty.app configuration and state. Ghosthub
reloads the active configuration when the base file, an included file, or a
project override changes. The **Tmux Theme** setting supplies colors for new
sessions created by Ghosthub. Existing sessions keep their own appearance by
default; **Apply theme to shared tmux sessions** explicitly applies the
selected colors before future attachments. Use **Session → Apply Theme to
Current Session** to update only the connected active session immediately.
Both choices update the session's existing windows and chrome for every
attached terminal. Quit confirmation is on by default and can be disabled in
Terminal Settings; closing the final workspace leaves Ghosthub running, while
Command-Q detaches every presentation and quits. Use **Ghosthub → Reload
Configuration** for an explicit reload and diagnostic result.

## How the pieces fit

**Tmux owns terminal sessions.** It remains authoritative for windows, panes,
layout, history, keybindings, plugins, and process lifetime.

**[Kwt](https://kwt.sh) owns worktree identity.** It reports projects,
worktrees, and their exact tmux session names. Kwt is optional when you only
want a local and remote tmux session switcher.

**Ghosthub owns presentation.** It discovers the fleet, presents native
terminal clients, organizes workspaces, and supervises SSH reconnect.

## Anonymous usage data

Packaged releases send at most one anonymous daily activity event, enabled by
default, containing only a random installation ID and the Ghosthub version and
build number. Repository, worktree, host, session, path, command, and terminal
data are not collected. Disable reporting in **Settings → Privacy**. The full
contract is documented in the
[architecture](docs/architecture.md#anonymous-usage-telemetry) and
[threat model](docs/threat-model.md).

## Development and contributions

Ghosthub does not accept unsolicited pull requests. Bug reports and feature
requests are welcome through
[GitHub issues](https://github.com/kenn-io/ghosthub/issues). Prospective code
contributors should [read the contribution policy](CONTRIBUTING.md) and
contact Kenn Software privately before starting work; accepted contributors
must sign a CLA.

Internal build instructions, architecture, security boundaries, terminal
behavior, and release operations are documented in [`docs/`](docs/README.md).

## License

Copyright 2026 Kenn Software LLC.

Ghosthub is free and open source software licensed under the
[GNU Affero General Public License v3.0](LICENSE).
