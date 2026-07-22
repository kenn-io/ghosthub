# Ghosthub Agent Guide

This document is the foundational mandate for AI agents (Gemini, Codex, etc.) working on Ghosthub. It provides the mental model, technical constraints, and non-negotiable workflows required to contribute effectively.

## Core Mental Model

Ghosthub is a **worktree-centric terminal multiplexer** for macOS.

- **Hosts:** Every machine is a Host. The local Mac is the default host. Remote machines (macOS/Linux) are added via SSH.
- **Projects:** A Project is a git repository reported by kwt on a specific Host.
- **Worktrees:** Projects contain kwt workspaces (standard checkouts or linked git worktrees), each with an exact tmux session name.
- **Sessions:** Every workspace session and every otherwise-unbound tmux session opens through the same ordinary tmux client. Tmux owns windows, panes, layout, history, and process lifetime.
- **Attachment:** Ghosthub owns discovery, local/SSH client presentation, keepalives, and reconnect. Closing a presentation detaches; it never destroys the tmux session.
- **Middleman:** Sessions created by Middleman remain discoverable because they are ordinary sessions on a host tmux server. Ghosthub does not use Middleman as session authority.
- **Console Panel:** A host-scoped persistent terminal area (e.g., for `roborev`) that is independent of the active worktree.

## Source of Truth Hierarchy

1. `AGENTS.md`: This guide (Mandatory Workflow & Mental Model).
2. `docs/architecture.md`: Architecture and Product source of truth.
3. `docs/threat-model.md`: Security boundaries and trusted-peer assumptions.
4. `CLAUDE.md`: Development workflow, build commands, and quality gates.
5. `docs/terminal-sessions.md`: Source of truth for terminal ownership, shell startup, and restart semantics.
6. `docs/release.md`: Signing, notarization, and release process source of truth.

## Non-Negotiable Workflow Rules

- Commit every turn when you make changes.
- Never amend commits.
- Do not leave the app build broken at the end of a turn.
- If a turn touches Swift app code, terminal integration, `Package.swift`, or bootstrap logic, `make build` must pass before the turn is done.
- If a turn touches release packaging, signing, notarization, or `.github/workflows/release.yml`, update `docs/release.md` in the same turn.
- For Python build tooling and tests, use `uv` rather than bare `python`, `pip`, or ad hoc virtualenv state.
- Prefer Makefile targets over raw multi-flag test commands; if a Python or test invocation is complex enough to be copied around, add a `make` target for it.
- Use `kata` for task management (see `CLAUDE.md`).
- Pull request descriptions should be concise, rationale-first prose. Do not add boilerplate or navel-gazing sections like "Changes", "Tests", or "Verification"; mention validation only when it is genuinely useful reviewer context.
- Do not poll or watch GitHub Actions through `gh`, the GitHub API, or browser automation unless the user explicitly asks you to do so.
- **NO DATABASE MIGRATIONS** until the first production release. Update the current schema, bootstrap paths, fixtures, and tests directly.

## Test Suite Policy

- Default to Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) for new tests. Do not add new XCTest suites unless the harness genuinely requires XCTest.
- Prefer `pytest` for Python tests, run through `uv` and the Makefile targets.
- Migrate existing XCTest coverage to Swift Testing whenever you touch a test and the harness allows it, especially for pure-logic and host coverage. Do not churn large stable suites that still need XCTest just to change frameworks.
- Keep XCTest where the current harness still genuinely needs it, especially AppKit, SwiftUI host lifecycle, libghostty, and other UI/smoke paths that are already working.
- When migrating repetitive tests, prefer parameterized Swift Testing coverage over copy-pasted single-case methods.
- If you fix a regression, add or strengthen the narrowest test that would have caught it before moving on.

## Naming

- Avoid ceremonial naming. Prefer the shortest name that is still clear.
- Do not prefix files, types, tests, helpers, or fixtures with `Ghosthub` when the surrounding module or directory already provides that context.
- Prefer names like `HostProtocolTests` over `GhosthubHostProtocolTests`.
- Keep product or integration prefixes only when they add real disambiguation, such as `Ghostty...` for Ghostty-specific integration surfaces.
- When touching existing code, clean up obviously redundant naming drift instead of extending it.

## Terminal Parity Rules

This is the most failure-prone part of the project. Treat it as a hard constraint.

- Ghosthub must behave like a normal macOS terminal app for shell startup and keybindings.
- Ghosthub is isolated from Ghostty.app configuration and state, but it should preserve Ghostty-style shell startup semantics inside the embedded terminal.
- Do not disable shell integration to work around keybinding bugs. Ghosthub relies on Ghostty-style shell integration for correct zsh startup behavior.
- Do not force a custom local shell command unless there is a very strong reason. Let the embedded Ghostty runtime launch the user shell using its normal macOS login-shell path.
- Do not leak launcher-terminal environment into embedded shells. In particular, `EDITOR` and `VISUAL` from the terminal used to launch Ghosthub can change zsh keymaps and break `Ctrl-A`, `Ctrl-E`, `Ctrl-K`, and `Option-D`.
- Keep `TERM_PROGRAM` Ghosthub-specific (`ghosthub`), but preserve working shell behavior.
- Do not pin `shell-integration-features` to work around cursor or keybinding issues unless Ghosthub exposes that behavior as a deliberate user setting.
- Ghosthub terminal config should remain Ghosthub-owned at `~/.config/ghosthub/ghostty.conf`.
- Ghosthub mutable application state should live under `~/.ghosthub/` rather than `~/Library/Application Support/` or `~/.config/ghosthub/`.
- Global Ghostty.app config must not affect Ghosthub.

## Terminal Regression Checks

If you touch terminal startup, shell environment, config layering, embedded libghostty bootstrap, key handling, or remote logic, run all of these:

- `make test-libghostty-bootstrap`
- `make python-test`
- `swift test`
- `make build`

If the change is specifically about interactive shell behavior, also verify the existing smoke coverage around:

- dirty launcher env not breaking default shell bindings
- default Ghostty shell integration loading user zsh startup files
- `Ctrl-A` / `Option-D` behavior through the workspace-hosted terminal path

## Practical Guardrails

- Prefer fixing terminal issues at the shell-startup or environment boundary before changing AppKit key handling.
- Prefer stronger end-to-end terminal smoke tests over helper-only unit tests when the bug is user-visible.
- If you change libghostty bootstrap patches, bump the Ghosthub bootstrap schema and rebuild artifacts.
- Keep Ghosthub-specific shell/config behavior documented when you change it.

## Directory Map

- `Sources/App/`: Main macOS app logic and UI.
- `Sources/UI/`: Reusable SwiftUI/AppKit presentation components.
- `Sources/Workspace/`: Pure workspace, host, project, worktree, and session models.
- `Sources/Settings/`: Native settings and preferences.
- `Sources/Terminal/`: `libghostty` integration and surface management.
- `Sources/TerminalSupport/`: Ghostty config/bootstrap support that can compile without libghostty.
- `Sources/Persistence/`: Database schema, models, and GRDB repositories.
- `tools/`: Python-based build, bootstrap, and packaging automation.
- `Tests/`: Swift and Python test suites.
