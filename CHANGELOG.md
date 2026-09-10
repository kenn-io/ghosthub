# Changelog

Notable user-facing changes to Ghosthub are recorded here. Internal build,
test, and documentation-only changes are omitted.

## [Unreleased]

## [0.10.2] - 2026-09-10

Keep each window's sidebar arranged independently and return to the app with
less redraw work. Mission Control also shows terminal contents again.

### Fixed

- Expanding or collapsing sidebar groups affects only that window or tab.
  New windows start with the default expansion; inventory, ordering, and
  settings remain shared.
- Sidebar refreshes skip unchanged host data, and returning to the app avoids
  unnecessary redraws. Live previews resume after the active window returns
  instead of doing their rendering work immediately during activation.
- Mission Control previews retain the last terminal frame when a window is
  hidden or inactive.
- Nightly update notes keep a readable space between each Git hash and its
  commit description.

## [0.10.1] - 2026-09-07

Review new SSH host keys in the right dialog and see why a connection fails.
This release also supports repositories with sibling worktrees and preserves
more information when imported pull requests have merge conflicts.

### Added

- Register repositories arranged as a `.bare/` directory with sibling
  worktrees. New worktrees keep that layout.

### Fixed

- New SSH hosts show a host-key trust review instead of asking for a password
  when OpenSSH sends its standard confirmation question without a prompt hint.
- Failed SSH connections show OpenSSH's explanation and exit status. If
  account authentication fails after you trust a host, you can now see the
  reason, such as `Permission denied (publickey)`.
- Imported pull-request worktrees keep both sides of text conflicts when a
  later merge conflicts.

### Upgrade notes

- Pull-request imports require Git 2.42.0 or newer on macOS and Linux, or
  Git for Windows 2.53.0.windows.3 or newer, on the host that owns the project.
- Restart any separately running kwt processes after upgrading before using
  `kwt doctor --fix` to clean up old worktree-creation locks.

## [0.10.0] - 2026-09-07

Find text in your terminal, see which files changed in a worktree, and paste
images into remote tmux sessions. This release also adds macOS Sequoia support
and makes remote connections and multi-window work smoother.

### Added

- Search the active terminal with **Command-F**. Use **Command-G** to move
  toward older matches and **Shift-Command-G** toward newer ones. Find works
  in standalone terminals and local or remote tmux 3.4+ panes, including their
  history. Herdr, Zellij, and Windows psmux are not supported yet.
- Expand a worktree to see staged, unstaged, and untracked files without
  leaving the sidebar or opening its terminal session.
- Paste a Mac clipboard image into a remote tmux session with **Command-V**.
  Ghosthub uploads a PNG to the remote host and pastes its path, ready for
  tools that accept image files. If the clipboard also contains text,
  Ghosthub pastes the text instead.
- Choose **Always Live** session previews to connect and preview discovered
  tmux sessions on reachable macOS and Linux hosts without opening each one.
  This mode requires tmux 3.4+ and uses more CPU, memory, and SSH connections.
- Give a window or tab a custom name with **Window → Rename Window…**, or
  click its title. The name returns after relaunch and leaves the underlying
  session name unchanged.
- Open a project's visible worktrees together with **Open All Worktrees as
  Tabs** in the project's context menu.
- Make window backgrounds translucent with `background-opacity` and
  `background-blur` in `ghostty.conf`. Full-screen windows and macOS Increase
  Contrast keep backgrounds opaque.

### Changed

- Run Ghosthub on Apple Silicon Macs with **macOS 15 (Sequoia) or newer**.
- Review SSH host keys and answer authentication prompts in native sheets
  that identify the host or jump host asking. Windows share connections while
  they need them, and idle connections can close after the last user leaves.
- Worktrees and registered directories use kwt's dedicated tmux server.
  To inspect those sessions from a shell, use `tmux -L kwt list-sessions`.
  Imported pull requests keep their separate protected sessions.
- Worktrees and tmux sessions created outside Ghosthub appear in every window
  as inventory refreshes. Windows share those requests instead of each
  repeating them.
- Choose exactly which Tailscale hosts to import; the picker starts with
  none selected.
- Remove a dirty worktree after reviewing and explicitly confirming that its
  uncommitted changes will be discarded. The Git branch is kept.

### Fixed

- **Check for Updates…** can replace an update waiting to install with a
  newer release. Nightly update dialogs show the date and build number.
- Updates preserve ordinary window positions and sizes when updating from a
  build with window-position capture. Windows move onto an available display
  if their original display was disconnected; macOS still controls Spaces,
  full-screen windows, and tab groups.
- **Command-W** closes only the active session in a workspace. Other opened
  sessions stay connected. Use **Shift-Command-W** to close the whole window.
- Brief SSH outages reconnect automatically without unnecessary password
  prompts. Temporary inventory failures retry, and remote helper maintenance
  no longer interrupts ordinary terminal recovery.
- Hidden tmux clients and previews no longer shrink shared terminal windows.
- Copying terminal output no longer deadlocks terminal input.
- Terminal programs can request macOS permission to use Photos, the camera,
  microphone, and other resources that require your consent.
- Terminal memory and lifetime fixes reduce leaks and crashes.
- Switching windows avoids unnecessary sidebar rebuilds. Resizing and
  dragging the titlebar no longer rebuilds its controls or opens Rename by
  accident, and translucent windows keep the configured titlebar opacity.
- Settings headings and the Hosts selector stay visible while details scroll.

## [0.9.0] - 2026-08-15

Preview running work in the sidebar, switch tabs with numbered shortcuts,
and read clearer worktree names and terminal colors.

### Added

- See previews of tmux sessions you have already opened. **Efficient** shows
  a still image; **Live** refreshes up to four inactive previews across the
  app. Previews are off by default, stay matched to the right session after
  reconnecting, and reuse existing connections.
- See how many tmux windows are running in each worktree. When the count is
  unavailable, the row keeps its running or agent indicator.
- Switch tabs with **Command-1** through **Command-8**, or jump to the last
  tab with **Command-9**. Your custom Ghosthub shortcuts take precedence.

### Changed

- Identify worktrees by readable project and worktree names in tabs and
  titlebars. New worktree sessions also get shorter names with a unique suffix.
- Scroll through tmux history with the mouse wheel on macOS and Linux hosts.
  Ghosthub enables tmux mouse mode and uses its existing mouse bindings.
- Terminal text stays readable on light tmux backgrounds without changing
  colors for other clients. An explicit `minimum-contrast` setting still wins.

### Fixed

- Use built-in Ghostty color schemes, such as `theme = Catppuccin Macchiato`,
  without downloading or copying theme files. Ghosthub also includes the
  shell integration and terminal definitions those terminals need.
- Keyboard shortcuts no longer risk a crash when multiple windows are open,
  and session navigation follows the active window.
- Quitting no longer freezes Ghosthub while it asks for confirmation.
- Remote tmux, Herdr, and Zellij sessions resume recovery when a display
  becomes available after the Mac wakes with its lid closed.
- **Command-click** reliably opens highlighted terminal links, including
  after moving or dragging the pointer.

## [0.8.2] - 2026-08-11

### Fixed

- **Command-B** and **Command-Shift-P** keep working after switching windows
  or closing a dialog. Each shortcut acts once and does not operate on the
  window behind an open dialog.

## [0.8.1] - 2026-08-11

### Fixed

- **Command-B** toggles the sidebar once instead of briefly closing it and
  immediately reopening it.
- Switching between Ghosthub windows is faster, especially with several
  windows open.

## [0.8.0] - 2026-08-11

Use Zellij alongside tmux and Herdr, remove projects without deleting their
files, and show only the exe.dev machines you need.

### Added

- Create, open, and kill Zellij sessions on your Mac or remote macOS and Linux
  hosts. Remote sessions reconnect after a lost connection. Killing a session
  requires confirmation; restoring exited sessions and managing panes remain
  tasks for Zellij itself.
- Remove a project from Ghosthub without deleting its repository, worktrees,
  or tmux sessions, even if the checkout is already missing. Ghosthub checks
  that the project registration still matches before removing it.
- Filter exe.dev machines by tag so larger accounts show only the machines
  you work with.

### Changed

- Use **Control-Tab** and **Control-Shift-Tab** to cycle through visible
  workspaces or sessions in the same group. Customize these and numbered
  navigation shortcuts in Keyboard Settings or `config.toml`.

### Fixed

- Returning to Ghosthub stays responsive with many hosts and workspaces.
- Zellij recovery stops when the host, SSH settings, or session changes,
  instead of reconnecting using outdated details.

## [0.7.0] - 2026-08-09

Manage Herdr sessions and exe.dev machines alongside your tmux work, and
keep tmux sessions connected while switching between them.

### Added

- Create, open, restart, stop, and delete Herdr sessions on your Mac or remote
  macOS and Linux hosts. Running and stopped sessions appear in the sidebar.
- Discover running exe.dev machines as SSH hosts without adding them again
  in Host Settings.
- Save a command as a launch profile for new tmux sessions on macOS and Linux,
  including commands that need an interactive terminal.
- Split the active tmux or Herdr pane right with **Command-D**, or down with
  **Command-Shift-D**, when the multiplexer supports it. Herdr requires 0.8+.
- Spot recently active tmux sessions by their sidebar indicator after you
  have opened them during the current Ghosthub launch.
- Search the documentation at [ghosthub.ai/docs](https://ghosthub.ai/docs/).
  Markdown versions are also available for machine readers.

### Changed

- Tmux sessions stay connected while you switch between them in the same
  window. Remote sessions reconnect automatically after brief SSH failures.
- Find registered kwt directories alongside project worktrees. Worktrees
  show whether their sessions are running, and duplicate entries are hidden
  from **Tmux Sessions** by default.
- Remote macOS and Linux hosts automatically receive the matching kwt helper
  when needed. Windows helper installation still requires an explicit action
  because those executables are unsigned.
- Install through Homebrew or download the notarized DMG directly.

### Fixed

- Worktree removal stops if Ghosthub cannot confirm what it would delete.
  If removal fails or the worktree moves during the operation, Ghosthub
  restores the correct terminal view.
- Opening and closing the sidebar resizes the terminal smoothly.

## [0.6.0] - 2026-08-04

Set up SSH hosts inside Ghosthub and arrange sessions in the order you use them.

### Added

- Review new SSH host keys and enter passwords or other authentication
  responses inside Ghosthub. Prompts show the destination and key fingerprint.
  Credentials stay in memory for the session and also work with supported
  SSH jump-host routes.

### Changed

- Drag worktrees within a project or tmux sessions within a host to reorder
  them. The order survives relaunches and is used by keyboard navigation and
  the Command Palette.
- Imported Tailscale hosts keep their full MagicDNS names and use the username
  from your SSH configuration, or your Mac username if none is configured.
- Resize the sidebar smoothly while keeping the active host and session
  title visible.
- Choose from fixed-width terminal fonts. A configured font stays selected
  even when it is temporarily unavailable.

### Fixed

- Launching Ghosthub opens a workspace even when macOS has no saved windows.
- Remote connections honor custom SSH ports and reuse your authenticated
  connection for sessions and host checks. A normal tmux disconnect is no
  longer reported as an authentication or connection failure.

## [0.5.3] - 2026-08-02

### Changed

- No user-facing changes. This release was published to check that updating
  from 0.5.2 reopens the same workspace windows and tmux sessions.

## [0.5.2] - 2026-08-02

### Fixed

- Updating reopens your workspace windows with their previous navigation and
  tmux sessions, without blank, duplicate, swapped, or missing windows. The
  release also addressed macOS window size, position, and tab restoration.

## [0.5.1] - 2026-08-02

### Fixed

- Installing an update no longer crashes when macOS is slow to restore saved
  windows. Ghosthub waits for the original workspace and tmux session instead
  of opening a fresh window.
- **Command-B** and the titlebar sidebar button affect only the focused window.

## [0.5.0] - 2026-08-02

Hide sessions you do not need, apply a theme to the current session, and
return to your work after updating.

### Added

- Hide standalone tmux sessions with case-sensitive wildcard patterns in
  **Settings → Worktrees**.
- Use **Apply Theme to Current Session** to change that session's appearance
  without turning on automatic theme changes for shared sessions.
- Turn off quit confirmation in Terminal Settings.

### Changed

- Close the last workspace window and open another without relaunching Ghosthub.
- After an update, Ghosthub reopens previous windows and tmux sessions it can
  confirm, and reconnects when temporarily offline SSH hosts return.
- **Follow ghostty.conf** uses your configured light or dark terminal colors
  for the tmux theme.

### Fixed

- Remote tmux sessions use the account's normal login-shell environment and
  SSH authentication settings. Copying text in remote tmux copy mode can send
  it to the Mac clipboard through OSC 52, the terminal clipboard protocol.
- Import pull requests over HTTPS using the host's configured Git credentials.
  Removing an already-missing worktree still handles its running tmux session.
- Discover Tailscale hosts in packaged builds.
- Large sidebars and terminal resizing no longer cause layout stalls.
- Configuration notices stop repeating after a successful reload, and cursors
  stop blinking in background windows.

## [0.4.0] - 2026-07-30

Create worktrees from existing branches, remove worktrees from the sidebar,
and try sessions on Windows hosts.

### Added

- Choose an existing local or remote branch when creating a worktree. Branches
  with the same name show which remote they come from.
- Remove worktrees other than the primary checkout after confirmation.
  Ghosthub stops the matching tmux session and removes the worktree through
  kwt, keeping the Git branch.
- Connect to experimental Windows hosts over SSH, discover and open psmux
  sessions, and install the matching Windows kwt helper.

### Changed

- See project and worktree nesting more clearly. Primary checkouts open even
  when they are outside kwt's usual worktree directory.
- Hover over a standalone tmux session to reveal its removal control.
  Worktrees have separate actions for ending the session and removing files.
- Themes apply automatically to new sessions created by Ghosthub. Existing
  sessions keep their appearance unless you enable **Apply theme to shared
  tmux sessions**.
- Identify development builds in About by their nearest release, commit, and
  whether they include uncommitted changes.

### Fixed

- Disconnecting from tmux no longer makes Ghosthub treat the session as ended.
  If a standalone session does end, Ghosthub offers to reopen it by name.
- Terminal configuration reloads report failures without showing errors after
  a successful reload.
- Created or removed worktrees stay in sync across windows; outdated rows and
  sessions no longer reappear after those actions.

## [0.3.0] - 2026-07-28

Open native tabs, import pull requests as worktrees, and add projects on
local or remote hosts.

### Added

- Open a native macOS tab with **Command-T** or a separate window with
  **Command-N**.
- Browse pull requests and import them as worktrees through kwt.
- Install the matching kwt helper on Intel or ARM macOS and Linux hosts after
  granting permission.
- Register a local or remote checkout with **Add Project**, without scanning
  the filesystem or installing kwt yourself.
- End sessions with a confirmed **Kill Session** action in menus or the
  Command Palette.
- Anonymous daily usage reporting, which you can turn off in Settings.

### Changed

- Open a worktree even when its tmux session is stopped. Ghosthub starts or
  repairs the session as needed.
- Test remote connections during setup and get clearer errors and guidance
  when a host has no projects or sessions.
- Find remote tools when the account uses a shell such as fish.

## [0.2.1] - 2026-07-23

### Added

- Terminal configuration changes reload automatically. Use **Reload
  Configuration** to reload manually and see any errors.

### Changed

- Paste works normally again in tmux terminals.
- Tmux status and message areas match Ghosthub's terminal colors.
- Project actions are easier to find, with improved window sizing and
  disconnect and quit behavior.

## [0.2.0] - 2026-07-23

### Added

- Install signed updates inside Ghosthub, or look for one with
  **Check for Updates…**.

## [0.1.1] - 2026-07-22

### Changed

- An unreachable remote host no longer blocks local sessions or sessions
  Ghosthub has already discovered.
- Smaller windows fit better, and the app shows clearer license information.

## [0.1.0] - 2026-07-22

### Added

- Open local and remote tmux sessions in a native Mac terminal, reconnect
  automatically after lost connections, and navigate projects and worktrees
  managed by kwt.

[Unreleased]: https://github.com/kenn-io/ghosthub/compare/v0.10.2...HEAD
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
