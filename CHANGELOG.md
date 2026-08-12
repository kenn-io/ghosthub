# Changelog

Notable user-facing changes to Ghosthub are recorded here. Internal build,
test, and documentation-only changes are omitted.

## [Unreleased]

## [0.8.2] - 2026-08-11

### Fixed

- Configurable **Command-B** and **Command-Shift-P** shortcuts remain
  registered across window-focus and sheet transitions, dispatch exactly once,
  and no longer act beneath an open sheet.

## [0.8.1] - 2026-08-11

### Fixed

- **Command-B** now toggles the sidebar exactly once instead of briefly
  animating it closed and immediately reopening it.
- Switching between Ghosthub windows no longer rebuilds every open window's
  scene, removing the remaining activation lag in multi-window workflows.

## [0.8.0] - 2026-08-11

### Added

- Zellij joins Ghosthub's all-multiplexer fleet as a first-class peer on the
  local Mac and remote macOS and Linux hosts. Ghosthub discovers active
  sessions, creates or attaches through the ordinary Zellij client, reconnects
  remote attachments after transport loss, and provides a confirmed Kill
  Session action without exposing resurrection or pane management.
- Registered projects can be removed from Ghosthub without deleting their
  repositories, worktrees, or tmux sessions, including when the checkout is
  already missing. Ghosthub revalidates the exact kwt registration before
  removing it.
- exe.dev accounts can limit discovery to VMs carrying specific exe.dev tags,
  so a fleet of dozens of VMs shows only the ones you work in.

### Changed

- **Control-Tab** and **Control-Shift-Tab** cycle visible sibling worktrees,
  directory workspaces, or tmux, running Herdr, and active Zellij sessions.
  These and numbered sibling shortcuts can be customized in Keyboard Settings
  or `config.toml`.

### Fixed

- Returning focus to Ghosthub no longer starts a fresh fleet inventory sweep
  or process sample, keeping window activation responsive as the number of
  hosts and workspaces grows.
- Zellij reconnect, restoration, and confirmed kill recovery now stop when SSH
  settings, host identity, or exact session state changes instead of resuming a
  stale attachment.

## [0.7.0] - 2026-08-09

### Added

- Herdr sessions are now first-class peers to tmux sessions on the local Mac
  and remote macOS and Linux hosts. Ghosthub discovers running and stopped
  sessions, supports whole-session create, restart, stop, and delete actions,
  and can split the active Herdr pane with native shortcuts on Herdr 0.8 or
  later.
- Optional exe.dev integrations discover running VMs as SSH hosts without
  duplicating them in manual host settings.
- macOS and Linux hosts can save launch profiles for starting new tmux sessions
  with a chosen command, including commands that require an interactive
  terminal.
- **Command-D** and **Command-Shift-D** split the active tmux or Herdr pane to
  the right or down when the connected multiplexer supports native splitting.
- Recently active tmux sessions show an activity indicator after they have
  been opened during the current Ghosthub launch.
- Comprehensive searchable documentation is now available at
  [ghosthub.ai/docs](https://ghosthub.ai/docs/), with Markdown versions for
  machine readers.

### Changed

- Tmux presentations stay connected while navigating between sessions in the
  same window, and remote presentations automatically reconnect after
  transient SSH failures.
- Registered kwt directory workspaces appear alongside project worktrees.
  Worktree rows show confirmed live-session state, while duplicate entries are
  hidden from **Tmux Sessions** by default.
- Ghosthub automatically installs or updates its revision-pinned kwt helper on
  configured remote macOS and Linux hosts. Windows helper installation remains
  explicit while those executables are unsigned.
- Homebrew is now the primary installation path, with the notarized DMG kept as
  a direct alternative.

### Fixed

- Worktree removal now revalidates identity immediately before deletion,
  avoids destructive action when inventory is incomplete, and restores the
  correct presentation if removal fails or the worktree moved concurrently.
- Sidebar transitions resize the terminal smoothly without repeated terminal
  grid reflow.

## [0.6.0] - 2026-08-04

### Added

- SSH host setup now stays inside Ghosthub: unseen host keys are reviewed with
  their exact destination and fingerprint, while password and
  keyboard-interactive challenges use a native secure-entry sheet. Session-only
  credentials can authenticate direct hosts and supported ProxyJump routes
  without being written to disk.

### Changed

- Worktrees within a project and standalone tmux sessions within a host can be
  reordered by dragging. Ghosthub preserves that order across launches and
  inventory changes and uses it for keyboard navigation and the Command
  Palette.
- Tailscale imports preserve full MagicDNS identities and use the effective
  OpenSSH user when configured, falling back to the current macOS user.
- Sidebar resizing is smoother, and the active host and session title remain
  visible when the sidebar width changes.
- The terminal font picker lists fixed-width fonts while retaining a configured
  font that is temporarily unavailable.

### Fixed

- Fresh launches now open a workspace window when macOS has no restorable
  window state.
- Remote connections preserve explicit SSH ports, reuse authenticated
  connections for inventory, tmux, and helper installation, and report normal
  tmux detachment separately from authentication or transport failures.

## [0.5.3] - 2026-08-02

### Changed

- No user-facing behavior changes. This signed follow-up release provides an
  update target for validating that 0.5.2 preserves open workspace windows and
  exact tmux attachments during updater relaunch.

## [0.5.2] - 2026-08-02

### Fixed

- Update relaunches now restore every open workspace window with its prior
  navigation and exact tmux attachment while preserving macOS window geometry
  and tab grouping, without blank, duplicated, swapped, or dropped windows.

## [0.5.1] - 2026-08-02

### Fixed

- Installing an update and reopening saved windows no longer crashes when
  macOS temporarily withholds a window's restoration state; Ghosthub waits for
  the restored workspace and exact tmux attachment instead of replacing it
  with a fresh window.
- **Command-B** and the compact titlebar control now toggle the sidebar only in
  the focused window.

## [0.5.0] - 2026-08-02

### Added

- Standalone tmux sessions can be hidden from navigation with case-sensitive
  wildcard patterns managed in **Settings → Worktrees**.
- **Apply Theme to Current Session** immediately updates the active tmux
  session without enabling the persistent shared-session theme override.
- Quit confirmation can be disabled in Terminal Settings.

### Changed

- Closing the final workspace window leaves Ghosthub running so a new window
  can be opened without relaunching the app.
- Sparkle-authorized relaunches preserve native window restoration and reopen
  each exact prior tmux attachment that can be confirmed, including reconnects
  to temporarily offline SSH hosts.
- The **Follow ghostty.conf** tmux theme now uses libghostty's effective light
  or dark foreground and background colors when styling sessions.

### Fixed

- Remote tmux attachment again follows the account login-shell environment,
  honors OpenSSH authentication and connection sharing, and allows remote
  copy-mode to write to the Mac clipboard through OSC 52.
- HTTPS pull-request imports can use the host's configured Git credential
  helpers, and removing an already-missing worktree still reconciles its exact
  live tmux session.
- Tailscale host discovery works in packaged builds.
- Large sidebars and live terminal resizing no longer trigger SwiftUI layout
  stalls or excessive resize churn.
- Terminal configuration notices no longer replay after a successful reload,
  and cursors stop blinking when their window is in the background.

## [0.4.0] - 2026-07-30

### Added

- Existing local and remote branches can be selected when creating a
  worktree, including source-qualified choices when multiple remotes contain
  the same branch name.
- Non-primary worktrees can be removed from the sidebar with confirmation.
  Ghosthub terminates a verified live tmux session before delegating removal
  to kwt, while preserving the Git branch.
- Experimental native Windows hosts can connect over SSH through psmux,
  discover and attach sessions, and install revision-pinned Windows kwt
  helpers.

### Changed

- Project and worktree nesting is clearer in the sidebar, and registered
  primary checkouts open normally even when they live outside kwt's global
  worktree directory.
- Standalone tmux sessions use a direct hover removal control, while
  worktree-backed sessions keep distinct session and worktree lifecycle
  actions.
- Tmux Theme colors apply automatically only to new sessions created by
  Ghosthub. Existing local and remote sessions retain their own appearance
  unless **Apply theme to shared tmux sessions** is enabled.
- Development builds show the nearest release tag, commit distance, revision,
  and dirty state in About while preserving valid numeric macOS bundle
  versions.

### Fixed

- Closing or disconnecting a tmux attachment no longer implies that the
  server-side session ended. When a bare session does end, Ghosthub offers to
  reopen that exact named session.
- Generated terminal configuration is self-contained and reload failures are
  reported without showing misleading errors after successful automatic
  reloads.
- Worktree creation, removal, and inventory refreshes are coordinated across
  windows so stale rows and sessions do not reappear after mutations.

## [0.3.0] - 2026-07-28

### Added

- Native macOS workspace tabs with `⌘T`, alongside independent windows with
  `⌘N`.
- Pull-request discovery and worktree import through kwt.
- Managed kwt helpers for Darwin and Linux on amd64 and arm64 remote hosts,
  installed only after explicit permission.
- **Add Project** for registering one local or remote checkout without
  filesystem scanning or a system kwt installation.
- Confirmed **Kill Session** actions in session menus and the Command Palette.
- Privacy-bounded anonymous daily activity telemetry with a Settings opt-out.

### Changed

- Worktrees remain available when their canonical tmux session is not running;
  opening one creates or repairs the session before attachment.
- Remote-host onboarding now includes connection verification, actionable
  error details, empty-host guidance, and clearer host grouping.
- Tool discovery supports non-POSIX account shells such as fish.

## [0.2.1] - 2026-07-23

### Added

- Automatic terminal configuration reloads and an explicit
  **Reload Configuration** command with diagnostics.

### Changed

- Restored native paste behavior inside tmux-backed terminals.
- Tmux status and message areas now follow Ghosthub terminal colors.
- Improved project action discoverability, window sizing, and detach/quit
  behavior.

## [0.2.0] - 2026-07-23

### Added

- Signed automatic updates and a native **Check for Updates…** flow powered by
  Sparkle.

## [0.1.1] - 2026-07-22

### Changed

- Remote inventory failures now degrade per host without blocking usable local
  or cached sessions.
- Improved compact window sizing and application license metadata.

## [0.1.0] - 2026-07-22

- Initial development release with native libghostty terminal surfaces, local
  and SSH tmux session discovery, automatic reconnect, and kwt-backed project
  and worktree navigation.

[Unreleased]: https://github.com/kenn-io/ghosthub/compare/v0.8.2...HEAD
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
