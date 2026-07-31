# Changelog

Notable user-facing changes to Ghosthub are recorded here. Internal build,
test, and documentation-only changes are omitted.

## [Unreleased]

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

[Unreleased]: https://github.com/kenn-io/ghosthub/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/kenn-io/ghosthub/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/kenn-io/ghosthub/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/kenn-io/ghosthub/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/kenn-io/ghosthub/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/kenn-io/ghosthub/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kenn-io/ghosthub/releases/tag/v0.1.0
