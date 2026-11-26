---
description: User-facing changes in each Ghosthub release.
icon: lucide/history
---

# Changelog

User-facing changes to Ghosthub are listed here. Internal build, test, and
docs-only changes are left out.

## [Unreleased]

### Added

- Open windows from a running [Rex](https://www.superlogical.com/rex/docs)
  server on your Mac or an SSH host, complete with their split panes. They
  appear in the host's session list with a **rex** label and in the Command
  Palette. Split, resize, focus, zoom, close, rearrange, and float panes in
  Ghosthub while Rex keeps the layout in sync. Closing a window in Ghosthub
  leaves its panes running in Rex. Start a Rex session from the host's **+**
  menu, or a new window in the shown session from the Command Palette.
- Herdr desktop tabs open with their split panes side by side as one **herdr**
  row per tab and follow layout changes made in Herdr desktop. Focus and zoom
  panes in Ghosthub while Herdr desktop keeps control of the layout.
- Rust port: open remote Rex windows over SSH, including over Tailscale. Split,
  focus, zoom, resize, and close panes; detaching leaves your programs running.
- Bring tmux sessions back after a reboot. Sessions kwt saved before a host
  restarted appear as dimmed **saved** rows; click one to rebuild its windows
  and panes and resume the Claude Code, Codex, and Antigravity CLI (`agy`)
  conversations inside it, or restore all of them from the host's **+** menu.
  See [Restore sessions after a reboot](sessions.md#restore-sessions-after-a-reboot).
- Expand `~` and `~/...` to the target host's home directory when adding or
  locating a project on your Mac or an SSH host.

### Changed

- A window that Ghosthub 0.13 saved with a Herdr desktop terminal open now
  reopens without that terminal; click it again in the sidebar to reattach.

### Fixed

- When a Herdr desktop terminal's program exits, Ghosthub now closes its view
  automatically instead of showing **Reconnect** until you click it.
- New Zellij sessions on your Mac now pick up programs added to `PATH` in
  `~/.zprofile`, such as Homebrew tools. Previously, launching Ghosthub from
  the Dock or Finder started Zellij with macOS's minimal default `PATH`, causing
  "command not found" errors. Already-running Zellij sessions keep their old
  `PATH` until you kill and recreate them.
- Ghosthub keyboard shortcuts now fire once instead of also passing through to
  the terminal, which could cause **Split Down** (`Cmd-Shift-D`) or **Split
  Right** (`Cmd-D`) to split a tmux pane twice.
- The local Mac's sidebar row now uses your Mac's Sharing name instead of
  looking up local hostnames through `/etc/hosts`, so loopback aliases for
  port-forwarded VMs no longer rename it.
- Opening a worktree whose `kwt open` takes longer than 7.5 seconds no longer
  gets stuck on "Opening…" indefinitely; Ghosthub now keeps waiting up to 60
  seconds for `kwt` to attach and shows an **Unable to attach** error with
  **Retry** if it still times out.
- Rust port: local tmux discovery on Linux and WSL now waits for its temporary
  probe server to exit before restarting it. Previously, startup could fail
  when `tmux kill-server` returned before the server finished shutting down.

## [0.13.1] - 2026-11-10

Ghosthub now finds tmux on Macs and Linux hosts where only `~/.zshrc` puts
Homebrew or another package manager on `PATH`.

### Fixed

- Ghosthub now finds tmux, kwt, Herdr, and Zellij installed with Homebrew,
  MacPorts, Linuxbrew, or Nix even when only `~/.zshrc` adds them to `PATH`.
  Remote Macs no longer report tmux as missing when it works in a normal SSH
  session.

## [0.13.0] - 2026-11-08

See when coding agents need your attention, open terminals from the Herdr
desktop app, and attach straight to Zellij 0.45 sessions.

### Added

- Open terminals from the newer Herdr desktop app in Ghosthub on macOS, locally
  or over SSH. They appear by desktop space and tab name under **Herdr
  Terminals**, separate from **Herdr TUI Sessions**. Closing the view leaves
  your program running; desktop spaces, tabs, and terminal lifecycle stay in
  Herdr.
- See what coding agents in your tmux sessions are doing. A sidebar badge shows
  **Approval**, **Input**, **Done**, or **Working**, and the native tab shows
  when its session needs you. Install the hooks per host under **Settings →
  Hosts → Agent Hooks**.

### Changed

- Ghosthub is now licensed under Apache 2.0. Contributions use the same license
  with no contributor license agreement. Third-party components keep their own
  licenses.

### Fixed

- On macOS, clicking an existing Zellij 0.45 session attaches straight to it
  instead of opening Zellij's session picker. This works for both local and SSH
  hosts.
- Closing a view while its program is still printing output, such as a Herdr
  session, no longer freezes Ghosthub.

## [0.12.0] - 2026-10-30

Flag worktrees to come back to, rename running tmux sessions, and pick up
sessions started outside Ghosthub.

### Added

- Mark worktrees with **Flag Worktree** in the sidebar menu. Flags appear across
  windows and survive restarts even when a host is offline. They are manual
  reminders stored on your Mac.
- Rename standalone tmux sessions from the sidebar menu or Command Palette.
  Open views follow the new name without stopping running programs. Worktree and
  directory sessions keep the names assigned by kwt.

### Changed

- Ghosthub now embeds libghostty 1.4.0, built with Zig 0.17.0. Your config stays
  at `~/.config/ghosthub/ghostty.conf`, and you do not need Ghostty.app or Zig
  installed.

### Fixed

- Cut redraw work for open tmux sessions, especially over SSH, by reusing
  terminal views instead of rebuilding launch commands.
- Herdr and Zellij sessions started outside Ghosthub now show up in the sidebar
  within about 30 seconds while Ghosthub is active and the host is connected,
  instead of waiting for a restart or reconnect.

## [0.11.3] - 2026-10-23

### Fixed

- The bundled kwt helper now rejects certificates from the compromised eMudhra
  intermediate CAs when talking to GitHub, such as during pull-request imports.
  This applies both locally and to the managed copies Ghosthub updates on remote
  hosts.
- With Git 2.56 or newer, Ghosthub can again list and remove a worktree whose
  Git link is broken instead of stopping with a Git error.
- Retrying after canceling worktree creation on a new branch now works instead
  of reusing the half-built checkout left behind.

## [0.11.2] - 2026-10-15

### Fixed

- Worktree sessions now reconnect cleanly after you switch branches inside the
  checkout.
- Stray or incomplete Git worktree entries no longer block workspace actions for
  the whole repository.

## [0.11.1] - 2026-10-07

### Fixed

- Bare Git repositories now list their linked worktrees without a Workspace
  Inventory Issue and no longer require a main checkout.

## [0.11.0] - 2026-09-20

Reorder hosts, locate moved project folders, paste clipboard images locally, and
see standalone sessions on kwt's tmux server.

### Added

- Drag host headers in the sidebar or reorder Local Mac and SSH hosts in
  **Settings → Hosts**. Both views share the same saved order across windows and
  launches.
- Recover moved project folders without removing the project. Ghosthub checks
  known repository locations once, then offers **Locate Folder…** while your
  other projects and sessions stay usable.
- Paste a Mac clipboard image into a local tmux session with **Command-V**, just
  like remote macOS and Linux sessions. Ghosthub saves a PNG on that host and
  pastes its path; if the clipboard also has text, text wins.
- Finish Tailscale SSH browser checks directly from Ghosthub's login sheet so
  the pending connection continues automatically after approval.

### Changed

- SSH compression is now on by default. Toggle **SSH compression** per host in
  **Settings → Hosts**; saving detaches open views on that host while remote
  sessions keep running and pick up the new setting when reopened.
- Large sidebars do less work when previews are off, changed-file panels refresh
  independently, and unused background resource polling is gone.

### Fixed

- Registered directory workspaces no longer get stuck in an endless loading
  state.
- Standalone tmux sessions on kwt's server now appear under **Tmux Sessions**,
  including sessions started with `kwt tmux run`. Ghosthub checks the default
  and kwt servers without scanning arbitrary named servers.
- The macOS app now uses kwt's socket directory even when your shell sets
  `TMUX_TMPDIR`. If kwt discovery fails, default-server sessions still refresh
  while cached kwt rows stay visible.

## [0.10.2] - 2026-09-10

Keep each window's sidebar state independent, cut redraw work when switching
back to Ghosthub, and keep terminal contents visible in Mission Control.

### Fixed

- Expanding or collapsing sidebar groups now affects only that window or tab,
  while inventory, ordering, and settings stay shared.
- Sidebar refreshes skip unchanged host data, switching back to Ghosthub avoids
  extra redraws, and live previews resume after the window is active instead of
  rendering during activation.
- Mission Control keeps showing the last terminal frame when a window is hidden
  or inactive.
- Nightly update notes keep a space between each Git commit hash and its
  summary.

## [0.10.1] - 2026-09-07

Show the right dialog for new SSH host keys, surface OpenSSH failure reasons,
support `.bare/` repositories, and preserve merge conflicts on imported pull
requests.

### Added

- Register repositories laid out as a `.bare/` directory with sibling worktrees;
  new worktrees keep that same layout.

### Fixed

- New SSH hosts now open the host-key review sheet instead of asking for a
  password when OpenSSH sends its confirmation prompt without a hint.
- Failed SSH connections show OpenSSH's explanation and exit status so login
  errors like `Permission denied (publickey)` are clear after trusting a host.
- Imported pull-request worktrees keep both sides of text conflicts when a later
  merge hits a conflict.

### Upgrade notes

- Pull-request imports require Git 2.42.0 or newer on macOS and Linux, or Git
  for Windows 2.53.0.windows.3 or newer, on the host that holds the project.
- Restart any separately running kwt processes after upgrading before running
  `kwt doctor --fix` to clear old worktree-creation locks.

## [0.10.0] - 2026-09-07

Search terminal scrollback, inspect changed files in the sidebar, paste images
into remote tmux sessions, and run Ghosthub on macOS 15 (Sequoia).

### Added

- Search the active terminal with **Command-F** (**Command-G** for older
  matches, **Shift-Command-G** for newer ones). Works in standalone terminals
  and local or remote tmux 3.4+ panes, including scrollback. Herdr, Zellij, and
  Windows psmux are not supported yet.
- Expand any worktree in the sidebar to see staged, modified, and untracked
  files without opening its session.
- Paste a Mac clipboard image into a remote tmux session with **Command-V**.
  Ghosthub uploads a PNG to the remote host and pastes its path; if the
  clipboard also contains text, text wins.
- Turn on **Always Live** previews to connect to and preview discovered tmux
  sessions on macOS and Linux hosts automatically. Requires tmux 3.4+ and uses
  more CPU, memory, and SSH connections.
- Rename any window or tab with **Window → Rename Window…** or by clicking its
  title. The custom name survives relaunches without renaming the underlying
  session.
- Open all visible worktrees in a project at once with **Open All Worktrees as
  Tabs** in the project's context menu.
- Enable translucent windows with `background-opacity` and `background-blur` in
  `ghostty.conf`. Fullscreen windows and macOS Increase Contrast stay opaque.

### Changed

- Ghosthub now runs on Apple Silicon Macs with **macOS 15 (Sequoia) or newer**.
- SSH host-key reviews and login prompts appear in native sheets naming the host
  or jump host asking. Windows share connections while needed and close idle
  ones after the last view leaves.
- Worktrees and registered directories now live on kwt's dedicated tmux server
  (`tmux -L kwt list-sessions`), while imported pull requests keep separate
  protected sessions.
- Worktrees and tmux sessions started outside Ghosthub appear across all windows
  as shared inventory refreshes.
- Tailscale host import starts with every peer unchecked so you pick only the
  hosts you want.
- Removing a dirty worktree requires reviewing and confirming that uncommitted
  changes will be discarded; the Git branch stays intact.

### Fixed

- **Check for Updates…** replaces a queued update when a newer release is found,
  and nightly update dialogs include the date and build number.
- Updates save and restore normal window positions and sizes, moving windows
  onto an active display if a monitor was unplugged (macOS still controls
  Spaces, fullscreen windows, and tab groups).
- **Command-W** closes only the active view while other opened sessions stay
  connected; **Shift-Command-W** closes the whole window.
- Brief SSH drops reconnect automatically without extra password prompts,
  temporary inventory errors retry, and background helper updates no longer
  interrupt session recovery.
- Hidden tmux clients and sidebar previews no longer shrink shared tmux windows.
- Copying terminal output no longer deadlocks input.
- Programs inside Ghosthub can now request macOS permissions for Photos, camera,
  microphone, and other protected resources.
- Fixed terminal memory and lifetime bugs that could cause leaks or crashes.
- Switching windows avoids unnecessary sidebar rebuilds, dragging the titlebar
  no longer opens Rename by accident, and translucent windows keep the
  configured titlebar opacity.
- Settings headings and the Hosts selector stay pinned while details scroll.

## [0.9.0] - 2026-08-15

Preview tmux sessions in the sidebar, jump to tabs with numbered shortcuts, and
enjoy cleaner worktree titles and light-mode contrast.

### Added

- Preview tmux sessions you have opened in the sidebar: **Efficient** shows a
  still snapshot and **Live** refreshes up to four inactive previews across the
  app. Previews start off by default, stay tied to the right session across
  reconnects, and reuse existing connections.
- Show how many tmux windows are open on each worktree row, falling back to the
  running or agent icon when no count is available.
- Switch native tabs with **Command-1** through **Command-8**, or **Command-9**
  for the last tab (custom Ghosthub shortcuts still take priority).

### Changed

- Native tabs and titlebars now show readable project and worktree names, and
  new worktree sessions get shorter names with a unique suffix.
- Mouse-wheel scrolling enters and scrolls tmux copy mode on macOS and Linux
  hosts by enabling tmux mouse mode while keeping tmux's mouse bindings in
  charge.
- Added a subtle local contrast floor so terminal text stays readable on light
  tmux backgrounds without changing colors for other clients; an explicit
  `minimum-contrast` setting still wins.

### Fixed

- Built-in Ghostty color schemes like `theme = Catppuccin Macchiato` now work
  out of the box, alongside bundled shell integration and terminal definitions.
- Keyboard shortcuts no longer risk crashing with multiple windows open, and
  session navigation follows the active window.
- Quitting no longer freezes Ghosthub while showing the confirmation prompt.
- Remote tmux, Herdr, and Zellij sessions resume reconnecting once a display is
  available after waking with the lid closed.
- **Command-click** reliably opens highlighted terminal links, including after
  moving or dragging the pointer.

## [0.8.2] - 2026-08-11

### Fixed

- **Command-B** and **Command-Shift-P** keep working after switching windows or
  closing dialogs, act once per press, and no longer hit a window behind an open
  dialog.

## [0.8.1] - 2026-08-11

### Fixed

- **Command-B** toggles the sidebar once instead of briefly closing and
  reopening it.
- Switching between Ghosthub windows is faster, especially with several windows
  open.

## [0.8.0] - 2026-08-11

Manage Zellij sessions alongside tmux and Herdr, unregister projects without
touching files on disk, and filter exe.dev VMs by tag.

### Added

- Create, attach to, and kill active Zellij sessions on your Mac and remote
  macOS and Linux hosts, with automatic reconnect after SSH drops. Killing
  requires confirmation; resurrecting exited sessions and managing panes stay in
  Zellij.
- Unregister a project from Ghosthub without deleting its repository, worktrees,
  or tmux sessions, even if the folder is already missing.
- Filter exe.dev VMs by tag so large accounts list only the machines you use.

### Changed

- Press **Control-Tab** and **Control-Shift-Tab** to cycle through visible
  worktrees or sessions in the same group, customizable in Keyboard Settings or
  `config.toml`.

### Fixed

- Returning to Ghosthub stays responsive even with many hosts and workspaces.
- Zellij reconnect stops if the host, SSH settings, or session changes instead
  of reconnecting with stale details.

## [0.7.0] - 2026-08-09

Manage Herdr sessions and exe.dev VMs alongside tmux, and keep tmux sessions
connected as you switch between them.

### Added

- Create, attach to, restart, stop, and delete Herdr sessions on your Mac and
  remote macOS and Linux hosts, with running and stopped sessions listed in the
  sidebar.
- Discover running exe.dev VMs as SSH hosts automatically.
- Save a command as a launch profile for new tmux sessions on macOS and Linux
  SSH hosts, including commands that need an interactive terminal.
- Split the active tmux or Herdr 0.8+ pane right with **Command-D** or down with
  **Command-Shift-D**.
- Spot tmux sessions with new output via a sidebar activity dot after opening
  them during the current launch.
- Published searchable user guides at [ghosthub.ai/docs](https://ghosthub.ai/docs/),
  with matching Markdown pages for agents.

### Changed

- Tmux sessions stay connected while you switch between them in the same window,
  and remote sessions reconnect automatically after brief SSH drops.
- Registered kwt directories appear alongside project worktrees, worktrees show
  whether their session is live, and duplicate rows are hidden from **Tmux
  Sessions** by default.
- Remote macOS and Linux hosts receive the matching kwt helper automatically;
  Windows helper installation remains manual until the executables are signed.
- Ghosthub can now be installed via Homebrew or by downloading the notarized
  DMG.

### Fixed

- Worktree removal stops if Ghosthub cannot verify what it is about to delete,
  and restores the right view if removal fails or the worktree moves mid-action.
- Showing or hiding the sidebar resizes the terminal smoothly.

## [0.6.0] - 2026-08-04

Handle SSH host keys and logins directly inside Ghosthub and drag sessions into
your preferred order.

### Added

- Review new SSH host keys and answer password or challenge prompts inside
  Ghosthub, with the host and fingerprint shown clearly. Answers stay in memory
  for the current run and work through supported SSH jump hosts.

### Changed

- Drag worktrees within a project or tmux sessions within a host to reorder
  them; the order survives restarts and drives keyboard navigation and the
  Command Palette.
- Imported Tailscale hosts keep their full MagicDNS names and use your SSH
  config username (or your Mac username if none is set).
- Resizing the sidebar keeps the active host and session title visible.
- Font picker lists fixed-width fonts and preserves your saved choice even when
  a font is temporarily unavailable.

### Fixed

- Launching Ghosthub opens a window even when macOS has no saved windows.
- Remote connections respect custom SSH ports and reuse authenticated
  connections; a normal tmux detach is no longer reported as a login or
  connection failure.

## [0.5.3] - 2026-08-02

### Changed

- No user-facing changes; published to verify that updating from 0.5.2 reopens
  the same windows and tmux sessions cleanly.

## [0.5.2] - 2026-08-02

### Fixed

- Updating now reopens your windows with their previous sidebar selections,
  sizes, positions, tabs, and tmux sessions instead of creating blank,
  duplicate, swapped, or missing windows.

## [0.5.1] - 2026-08-02

### Fixed

- Installing an update no longer crashes when macOS is slow to restore saved
  windows; Ghosthub waits for the original window and tmux session instead of
  opening a blank one.
- **Command-B** and the titlebar sidebar button affect only the focused window.

## [0.5.0] - 2026-08-02

Hide noisy tmux sessions, apply a theme to the current session, and restore your
windows after updates.

### Added

- Hide standalone tmux sessions with case-sensitive wildcard patterns in
  **Settings → Worktrees**.
- Apply your theme to a single session with **Apply Theme to Current Session**
  without changing other shared sessions automatically.
- Turn off quit confirmation in Terminal Settings.

### Changed

- You can close the last window and open a new one without relaunching Ghosthub.
- After an update, Ghosthub reopens confirmed windows and tmux sessions and
  reconnects once offline SSH hosts come back.
- **Follow ghostty.conf** uses your light or dark terminal colors for the tmux
  theme.

### Fixed

- Remote tmux sessions load your normal login-shell environment and SSH auth
  settings, and remote tmux copy mode can copy to the Mac clipboard via OSC 52.
- Pull-request imports work over HTTPS using the host's Git credentials, and
  removing an already-deleted worktree still stops its running tmux session.
- Tailscale host discovery works in packaged builds.
- Large sidebars and terminal resizing no longer stall layout.
- Config error banners clear after a successful reload, and cursors stop
  blinking in background windows.

## [0.4.0] - 2026-07-30

Create worktrees from existing branches, remove worktrees from the sidebar, and
try experimental Windows hosts.

### Added

- Create a worktree from an existing local or remote branch, with same-named
  branches labeled by remote.
- Remove linked worktrees after confirmation, stopping the matching tmux session
  and deleting the checkout through kwt while keeping the Git branch.
- Connect to experimental Windows hosts over SSH, open psmux sessions, and
  install the matching Windows kwt helper.

### Changed

- Project and worktree nesting is clearer, and primary checkouts open even when
  they sit outside kwt's default worktree folder.
- Hovering over a standalone tmux session reveals its kill control, while
  worktrees separate killing the session from removing files.
- Themes apply to new sessions created from Ghosthub while existing sessions
  keep their own colors unless **Apply theme to shared tmux sessions** is on.
- Development builds show their nearest release, commit, and dirty state in
  About.

### Fixed

- Detaching from tmux no longer marks the session as ended; if a standalone
  session actually exits, Ghosthub offers to reopen it by name.
- Config reload errors clear once a reload succeeds.
- Creating or removing worktrees stays in sync across windows so stale rows do
  not reappear.

## [0.3.0] - 2026-07-28

Open native tabs, import GitHub pull requests as worktrees, and register
projects on local or remote hosts.

### Added

- Open native macOS tabs with **Command-T** or separate windows with
  **Command-N**.
- Browse open GitHub pull requests and import them as worktrees through kwt.
- Install the matching kwt helper on Intel or ARM macOS and Linux hosts after
  confirmation.
- Register a local or remote repository with **Add Project** without scanning
  the machine or installing kwt by hand.
- End sessions deliberately with a confirmed **Kill Session** action in menus or
  the Command Palette.
- Added anonymous daily usage reporting, which can be turned off in Settings.

### Changed

- Clicking a worktree opens it even when its tmux session is stopped, starting
  or repairing the session automatically.
- Added connection testing during host setup and clearer errors when a host has
  no projects or sessions.
- Improved tool discovery on remote hosts using shells such as fish.

## [0.2.1] - 2026-07-23

### Added

- Terminal config changes reload automatically, with **Reload Configuration**
  available for manual reloads and error checks.

### Changed

- Fixed pasting in tmux sessions.
- Tmux status and message bars match Ghosthub's terminal colors.
- Made project actions easier to find and improved window sizing, detach, and
  quit behavior.

## [0.2.0] - 2026-07-23

### Added

- Install signed updates inside Ghosthub or check manually with **Check for
  Updates…**.

## [0.1.1] - 2026-07-22

### Changed

- An unreachable remote host no longer blocks local sessions or other already
  discovered hosts.
- Improved layout on smaller windows and showed clearer license details.

## [0.1.0] - 2026-07-22

### Added

- First release: manage local and remote tmux sessions in a native Mac app,
  reconnect automatically after dropped connections, and work with kwt projects
  and worktrees.

[Unreleased]: https://github.com/kenn-io/ghosthub/compare/v0.13.1...HEAD
[0.13.1]: https://github.com/kenn-io/ghosthub/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/kenn-io/ghosthub/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/kenn-io/ghosthub/compare/v0.11.3...v0.12.0
[0.11.3]: https://github.com/kenn-io/ghosthub/compare/v0.11.2...v0.11.3
[0.11.2]: https://github.com/kenn-io/ghosthub/compare/v0.11.1...v0.11.2
[0.11.1]: https://github.com/kenn-io/ghosthub/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/kenn-io/ghosthub/compare/v0.10.2...v0.11.0
[0.10.2]: https://github.com/kenn-io/ghosthub/compare/v0.10.1...v0.10.2
[0.10.1]: https://github.com/kenn-io/ghosthub/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/kenn-io/ghosthub/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/kenn-io/ghosthub/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/kenn-io/ghosthub/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/kenn-io/ghosthub/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/kenn-io/ghosthub/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/kenn-io/ghosthub/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/kenn-io/ghosthub/compare/v0.5.3...v0.6.0
[0.5.3]: https://github.com/kenn-io/ghosthub/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/kenn-io/ghosthub/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/kenn-io/ghosthub/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/kenn-io/ghosthub/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/kenn-io/ghosthub/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/kenn-io/ghosthub/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/kenn-io/ghosthub/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/kenn-io/ghosthub/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/kenn-io/ghosthub/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kenn-io/ghosthub/releases/tag/v0.1.0
