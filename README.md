<p align="center">
  <a href="https://ghosthub.ai">
    <img src="Resources/AppIcon/Ghosthub.svg" width="112" alt="Ghosthub app icon">
  </a>
</p>

<h1 align="center">Ghosthub</h1>

<p align="center">
  <strong>All your multiplexers. One native terminal.</strong>
  <br>
  Open tmux, Herdr, and Zellij sessions on your Mac and SSH hosts.
  Add Git worktrees when you need them.
</p>

<p align="center">
  <img alt="macOS 15 or newer" src="https://img.shields.io/badge/macOS-15%2B-111111?style=flat-square&logo=apple">
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
  <a href="https://ghosthub.ai/overview/"><strong>Overview</strong></a>
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
    alt="Ghosthub showing local and remote tmux, Herdr, and Zellij sessions alongside tmux-backed worktrees"
  >
</p>

Ghosthub opens tmux, Herdr, and Zellij sessions on your Mac and on machines
reached over SSH. A terminal multiplexer keeps your shells and programs running
when you close a terminal or lose a connection. Ghosthub helps you find those
sessions, switch between them, and reconnect.

Each multiplexer keeps its panes, history, key bindings, and running programs.
You can also register a Git repository and use [kwt](https://kwt.sh) to create
worktrees from branches or GitHub pull requests. A worktree is a separate
checkout of a branch. Git and worktrees are optional.

Ghosthub is alpha software. Report bugs and request features through
[GitHub issues](https://github.com/kenn-io/ghosthub/issues).

## What can I do with it?

- Open local and remote sessions together in native Mac windows and tabs.
- Keep remote sessions connected through ordinary SSH interruptions.
- Preview tmux sessions and see which ones are producing output.
- Create Git worktrees and inspect their changed files in the sidebar.
- Search sessions, projects, and actions with **Command-Shift-P**.
- Set fonts and colors in Ghosthub's own `ghostty.conf`. Ghosthub uses
  libghostty for rendering and does not load Ghostty.app's settings.

See the [visual overview](https://ghosthub.ai/overview/) for a tour. The
[public guides](https://ghosthub.ai/docs/) explain setup, controls, and limits.

## Install and open a session

You need an Apple Silicon Mac with macOS 15 (Sequoia) or newer. Install Ghosthub:

```sh
brew install kenn-io/tap/ghosthub
```

Or download the [latest stable DMG](https://github.com/kenn-io/ghosthub/releases/latest)
and drag **Ghosthub** to **Applications**.

Install at least one supported multiplexer on the host where you work: tmux
3.2+, Herdr 0.8.0+, or Zellij 0.44+. For tmux on your Mac:

```sh
brew install tmux
```

1. Launch **Ghosthub** from **Applications**.
2. Expand your Mac in the sidebar.
3. Select an existing session, or select the **+** beside a session group to
   create one.

Closing a terminal view detaches from its session. The session keeps running.
Ending it requires a separate, confirmed **Kill Session…** or **Stop Session…**
action. See [Sessions](https://ghosthub.ai/docs/sessions/).

This README and the website docs follow `main`. The
[Unreleased changelog](CHANGELOG.md#unreleased) identifies changes newer than
the latest stable release. Read about
[stable and nightly builds](https://ghosthub.ai/docs/getting-started/#release-and-nightly-builds)
before trying them.

## Where do I go next?

| I want to… | Guide |
| --- | --- |
| Connect another machine or arrange hosts | [Remote hosts](https://ghosthub.ai/docs/remote-hosts/) |
| Create worktrees or find a moved project | [Projects and worktrees](https://ghosthub.ai/docs/projects-worktrees/) |
| Save a command for a new tmux session | [Launch profiles](https://ghosthub.ai/docs/launch-profiles/) |
| Use windows, tabs, and the Command Palette | [Windows and navigation](https://ghosthub.ai/docs/windows-navigation/) |
| Change fonts, colors, themes, or clipboard behavior | [Terminal configuration](https://ghosthub.ai/docs/terminal-configuration/) |
| Find or change a shortcut | [Keyboard shortcuts](https://ghosthub.ai/docs/keyboard-shortcuts/) |
| Understand or turn off anonymous usage reporting | [Privacy](https://ghosthub.ai/docs/privacy/) |
| Diagnose a connection or session problem | [Troubleshooting](https://ghosthub.ai/docs/troubleshooting/) |

Ghosthub uses your OpenSSH configuration and presents host-key reviews and
authentication prompts when needed. Remote macOS and Linux hosts can use tmux,
Herdr, or Zellij. Connections from the Mac app to native Windows/psmux hosts
are experimental; see the [requirements and limits](https://ghosthub.ai/docs/remote-hosts/#experimental-windows-hosts).

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
