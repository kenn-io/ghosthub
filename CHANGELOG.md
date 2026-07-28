# Changelog

Notable user-facing changes to Ghosthub are recorded here. Internal build,
test, and documentation-only changes are omitted.

## [Unreleased]

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

[Unreleased]: https://github.com/kenn-io/ghosthub/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/kenn-io/ghosthub/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/kenn-io/ghosthub/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/kenn-io/ghosthub/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/kenn-io/ghosthub/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kenn-io/ghosthub/releases/tag/v0.1.0
