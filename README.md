<p align="center">
  <a href="https://ghosthub.io">
    <img src="Resources/AppIcon/Ghosthub.svg" width="112" alt="Ghosthub app icon">
  </a>
</p>

<h1 align="center">Ghosthub</h1>

<p align="center">
  <strong>A power terminal for your fleet of tmux sessions.</strong>
  <br>
  Find and enter the sessions behind your projects and coding agents,
  on your Mac or over SSH.
</p>

<p align="center">
  <img alt="macOS 26 or newer" src="https://img.shields.io/badge/macOS-26%2B-111111?style=flat-square&logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-111111?style=flat-square">
  <a href="LICENSE">
    <img alt="GNU AGPL v3.0" src="https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square">
  </a>
</p>

<p align="center">
  <a href="https://ghosthub.io"><strong>Website</strong></a>
  ·
  <a href="https://github.com/kenn-io/ghosthub/releases"><strong>Download</strong></a>
  ·
  <a href="https://ghosthub.io/guide/"><strong>Guide</strong></a>
  ·
  <a href="CHANGELOG.md"><strong>Changelog</strong></a>
  ·
  <a href="https://discord.gg/nEB7VaAnU9"><strong>Discord</strong></a>
</p>

<p align="center">
  <img
    src="https://raw.githubusercontent.com/kenn-io/ghosthub/website-assets/hero.png"
    width="960"
    alt="Ghosthub showing local and remote tmux sessions and kwt worktrees in its sidebar"
  >
</p>

Ghosthub discovers the tmux sessions you already have and organizes them by
host, project, and worktree. Tmux continues to own windows, panes, layout,
history, and process lifetime; Ghosthub provides the native macOS interface,
terminal presentation, and SSH reconnect supervision.

There is no proprietary session format, background daemon, or migration.

## Highlights

- **One fleet sidebar.** Navigate local sessions, remote sessions, projects,
  and worktrees—even when their tmux sessions were created outside Ghosthub.
- **Resilient SSH.** Keepalives and automatic reconnect preserve remote
  presentations through ordinary network interruptions.
- **Built-in worktree and pull-request workflows.** Add projects, create Git
  worktrees, and import GitHub pull requests through the bundled
  [kwt](https://kwt.sh) helper—no system kwt installation required.
- **Native tmux lifecycle.** Closing a presentation detaches. Ending a session
  requires the explicit, confirmed **Kill Session** action.
- **Native workspaces.** Open independent windows or macOS tabs, and search
  sessions and common actions from the Command Palette.
- **Fast terminal rendering.** Ghosthub embeds libghostty with an isolated,
  Ghostty-compatible configuration—no Electron and no Ghostty.app dependency.

## Install

Ghosthub requires:

- an Apple Silicon Mac
- macOS 26 (Tahoe) or newer
- tmux 3.2 or newer on each machine whose sessions you want to use

1. Download the latest notarized
   [Ghosthub DMG](https://github.com/kenn-io/ghosthub/releases).
2. Drag **Ghosthub** to **Applications** and launch it.
3. Install tmux locally if needed:

   ```sh
   brew install tmux
   ```

Remote hosts need tmux and non-interactive SSH authentication backed by a key
or SSH agent. Password-only hosts cannot populate the sidebar.

## Quick start

### Open or create a session

Expand your Mac in the sidebar and select an existing tmux session. Use the
host's **+** menu to create a named session. Closing its Ghosthub window or tab
only detaches; use the session action menu when you explicitly want to kill it.

### Add an SSH host

Open **Settings → Hosts**, add an SSH address such as `devbox`,
`alice@build-server`, or `server.example.com:2222`, and choose
**Test Connection**. If your OpenSSH policy prompts for a new host key, verify
the host once with system `ssh` first.

Tmux-only hosts need no other setup. For project and worktree context, choose
**Install kwt Worktree Helper** in Host Settings. Ghosthub copies the pinned
helper for that host's operating system and CPU; it does not install or replace
a system kwt.

### Add projects and worktrees

Open the **+** menu beside a local or remote host, choose **Add Project**, and
enter the absolute path to an existing checkout. Ghosthub registers that one
repository through its bundled or managed kwt helper and does not scan the
machine.

Pull-request import requires the
[GitHub CLI (`gh`)](https://cli.github.com/) on the host containing the project:
your Mac for a local project or the SSH machine for a remote one. Install it
there and run `gh auth login` on that same host before importing.

Select a project and press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>N</kbd> to create a Git
worktree or import a GitHub pull request. Selecting a listed worktree creates
or repairs its canonical tmux session when needed, then attaches an ordinary
tmux client.

## Navigation

Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>P</kbd> to open the **Command Palette** and
search across hosts, projects, worktrees, sessions, settings, and actions.

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
project override changes. The **Tmux Theme** setting controls how sessions
appear in Ghosthub. Shared tmux colors remain untouched by default; an explicit
opt-in applies the selected built-in theme to the session's existing windows
and chrome for every attached terminal. Use **Ghosthub → Reload Configuration**
for an explicit reload and diagnostic result.

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

## Build from source

Contributors need macOS 26, Xcode 26, Zig, uv, Go, and the Metal Toolchain.
Start with the [development quick start](docs/quickstart.md), then read
[CONTRIBUTING.md](CONTRIBUTING.md).

Architecture, security boundaries, terminal behavior, and release operations
are documented in [`docs/`](docs/README.md).

## License

Copyright 2026 Kenn Software LLC.

Ghosthub is free and open source software licensed under the
[GNU Affero General Public License v3.0](LICENSE).
