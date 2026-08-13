# Ghosthub Agent Guide

This document is the foundational mandate for AI agents (Gemini, Codex, etc.) working on Ghosthub. It provides the mental model, technical constraints, and non-negotiable workflows required to contribute effectively.

## Core Mental Model

Ghosthub is a **native terminal for local and remote tmux, Herdr, and Zellij
fleets** on macOS. It gives equal status to four ways of working:

- Create or attach to any tmux session on a configured host.
- Create, attach to, stop, restart, or delete Herdr sessions on a supported host.
- Create, attach to, or kill active Zellij sessions on a supported host.
- Create tmux sessions bound to git worktrees and manage the worktree lifecycle,
  including imports from branches and GitHub pull requests.

Worktrees are optional; Ghosthub remains fully useful without them.

- **Hosts:** Every machine is a Host. The local Mac is the default host. Remote machines (macOS/Linux) are added via SSH.
- **Projects:** A Project is a git repository reported by kwt on a specific Host.
- **Worktrees:** Projects contain kwt workspaces (standard checkouts or linked git worktrees), each with an exact tmux session name.
- **Sessions:** Worktree sessions and otherwise-unbound tmux sessions open through an ordinary tmux client. Running and stopped Herdr sessions are host inventory; opening a running session attaches, while creating or restarting uses Herdr's launch path. Active Zellij sessions are separate host inventory and open through an ordinary Zellij client. Each backend owns its windows, tabs, panes, layout, history, key bindings, and process lifetime.
- **Attachment:** Each scene presents at most one native tmux, Herdr, or Zellij client. Ghosthub owns discovery, local/SSH client presentation, keepalives, and reconnect. Closing a presentation detaches. Tmux and Zellij destruction require explicit, confirmed Kill Session actions. Herdr Stop and Delete are separate confirmed actions; Restart and Create are constructive actions.
- **Middleman:** Sessions created by Middleman remain discoverable because they are ordinary sessions on a host tmux server. Ghosthub does not use Middleman as session authority.
- **Console Panel:** A host-scoped persistent terminal area (e.g., for `roborev`) that is independent of the active worktree.

Ghosthub is alpha software. Treat the entire app, including its persistence
layer, as subject to direct iteration.

- Kwt's machine-readable CLI is authoritative for project/worktree identity
  and exact tmux session names. Direct `tmux list-sessions` discovery supplies
  every otherwise-unbound session on each configured host. Herdr's
  machine-readable session list independently supplies running and stopped Herdr sessions
  on the local Mac and remote POSIX hosts; a missing Herdr installation is
  normal and silent. Zellij's session list independently supplies active
  Zellij sessions on those hosts; exited/resurrectable sessions are excluded,
  and a missing Zellij installation is also normal and silent.
- Packaged builds invoke their revision-pinned bundled kwt for local operations.
  Configured remote macOS and Linux hosts automatically install or update
  Ghosthub's matching revision-pinned managed helper under `~/.ghosthub/`.
  Windows helper installation remains explicit until the kwt executables are
  Authenticode-signed.
- Fresh remote hosts gain project context through the explicit Host Settings
  **Add Project** action, which delegates one absolute repository path to kwt;
  Ghosthub never scans the remote filesystem or edits kwt configuration.
- Ghosthub never uses `tmux -CC` or reconstructs tmux panes, windows, layouts,
  history, or terminal output in Swift.
- Ghosthub never reconstructs Herdr workspaces, tabs, panes, history, or
  terminal output in Swift, and does not use Herdr as worktree authority.
  Whole-session create, stop, restart, and delete are the only Herdr lifecycle
  controls. The explicit Split Right and Split Down app actions may request one
  pane split from a capable active Herdr attachment; Herdr still chooses the
  focused pane and owns the resulting layout. Ghosthub never otherwise manages
  Herdr themes, workspaces, tabs, panes, agents, plugins, installation, updates,
  configuration, or server-wide state.
- Ghosthub never reconstructs Zellij tabs, panes, layout, history, or terminal
  output in Swift and never offers resurrection or deletion of exited Zellij
  sessions. Whole-session create, attach, and confirmed kill are the only
  Zellij lifecycle controls. Zellij has no atomic active-only attach command,
  so an upstream attach may resurrect a session that exits after Ghosthub's
  final active-state probe; this narrow race is documented, and confirmed
  kills fence Ghosthub reconnects across scenes. Ghosthub does not manage
  Zellij themes, plugins, installation, updates, configuration, or server-wide
  state.
- Ghosthub has no Middleman runtime or API dependency.

## Source of Truth Hierarchy

1. `AGENTS.md`: This guide (mental model, mandatory workflow, development
   workflow, build commands, and quality gates).
2. `docs/architecture.md`: Architecture and Product source of truth.
3. `docs/threat-model.md`: Security boundaries and trusted-peer assumptions.
4. `docs/terminal-sessions.md`: Source of truth for terminal ownership, shell startup, and restart semantics.
5. `docs/release.md`: Signing, notarization, and release process source of truth.

## Non-Negotiable Workflow Rules

- When a task involves multiple steps, complete all requested steps in sequence
  without stopping. If the task includes creating a branch, committing, and
  opening a pull request, finish the entire chain.
- Commit every turn when you make changes.
- Commit before responding without asking whether to commit; committing is the
  expected default after every change.
- Push completed task-branch commits to their configured remote before
  responding. Force-push only when the user explicitly requests a history
  rewrite.
- Ending a completed turn with task-related uncommitted work is forbidden. A
  clean task worktree is a precondition for handoff and for any roborev
  interaction.
- Never commit directly to `main` or `master`. When a task starts on the
  default branch, create a task-specific branch before the first commit. If a
  local commit lands on the default branch accidentally, move it to a task
  branch and restore the local default branch to its upstream before pushing.
- Never amend commits.
- Do not leave the app build broken at the end of a turn.
- If a turn touches Swift app code, terminal integration, `Package.swift`, or bootstrap logic, `make build` must pass before the turn is done.
- If a turn changes kwt inventory, host resolution, tmux, Herdr, or Zellij discovery,
  or native session attachment, run `make test-essential-workflows` before claiming the
  change is correct.
- If a turn touches release packaging, signing, notarization, or `.github/workflows/release.yml`, update `docs/release.md` in the same turn.
- `RELEASE_VERSION` is the sole source of the current release version outside
  dated `CHANGELOG.md` entries and immutable published tags. Preparing a
  release updates only `RELEASE_VERSION` and `CHANGELOG.md`; Makefiles, shell
  scripts, workflows, tests, and documentation must read that file or use an
  `X.Y.Z` placeholder, never duplicate the current version literal.
- For Python build tooling and tests, use `uv` rather than bare `python`, `pip`, or ad hoc virtualenv state.
- Prefer Makefile targets over raw multi-flag test commands; if a Python or test invocation is complex enough to be copied around, add a `make` target for it.
- Use `kata` for task management (see Issue Tracking below).
- User-facing workflow changes must update the website Guide when they affect
  documented behavior. Regenerate and publish the website screenshot set only
  at feature acceptance and when opening a pull request, and only when the
  accepted change materially alters visuals shown in those screenshots; copy,
  accessibility, and non-visual behavior changes do not require new captures.
  Do not capture or publish screenshots while a feature is still in
  development. User-facing workflow documentation must include a current
  screenshot of the UI it tells users to operate. Prefer deterministic demo
  fixtures with realistic synthetic data; use a manual capture only when the
  accepted workflow cannot be represented by the demo, and never expose real
  account, host, project, or session data. Publish required refreshed binaries
  to the orphan `website-assets` branch so ghosthub.ai does not ship stale
  product views.
- Pull request descriptions must be concise and optimized for human scanning:
  lead with a short rationale, then use bullets for the material behavior,
  constraints, and reviewer-relevant consequences. Do not add boilerplate or
  navel-gazing sections such as "Changes", "Validation", "Tests", or
  "Verification". Mention unusual validation only inline when it is genuinely
  useful reviewer context.
- The canonical repository is `https://github.com/kenn-io/ghosthub`. Open pull
  requests only when the user explicitly asks.
- The public repository does not accept unsolicited pull requests. Direct bug
  reports and feature requests to GitHub issues. Prospective code contributors
  must coordinate privately with Kenn Software and sign the CLA before their
  work can be accepted.
- Never include superpowers planning documents (`docs/superpowers/specs/`,
  `docs/superpowers/plans/`) in a pull request. Creating and using them locally
  during development is fine; they are local working artifacts. Remove them
  from the branch before pushing, opening, or updating a pull request.
- Do not poll or watch GitHub Actions through `gh`, the GitHub API, or browser automation unless the user explicitly asks you to do so.
- **NO DATABASE MIGRATIONS** until the first production release. Update the current schema, bootstrap paths, fixtures, and tests directly.

## Issue Tracking

Use `kata` as the only work tracker for this project. The workspace is bound
via `.kata.toml` at the repo root. Do not create markdown TODO lists or
parallel planning systems.

- See `kata quickstart` for the full agent guide.
- List open work: `kata list --json` (filter further with `--status open`).
- Read an issue: `kata show <number> --json`.
- Search before creating: `kata search "<terms>" --json`.
- Create follow-up work:
  `kata create "<title>" --body "<body>" --label area:host --label priority:p2 --idempotency-key "<unique-key>" --json`.
- Comment: `kata comment <number> --body "<text>" --json`.
- Add/remove labels: `kata label add <number> <label>` / `kata label remove`.
- Link issues via `kata edit <ref>`: `--parent <ref>` (set parent, at most one),
  `--blocks <ref>` / `--blocked-by <ref>` (ordering), `--related <ref>`
  (symmetric). Remove with the `--remove-*` variants.
- Close: `kata close <number> --reason done --json` (only when the work is
  actually complete).
- Never run `kata delete` or `kata purge` without explicit user instruction.

**Labels in use:** `area:{host,ui,infra,docs,remote,tests}`,
`priority:{p1,p2,p3}`, `epic`, plus `bug` and `enhancement`. Label new issues
appropriately; do not invent new label prefixes without updating this file.

**Epics:** the parent issue is labeled `epic` and lists children via a
markdown checklist in the body. Children also have a `parent` link via
`kata edit <child> --parent <epic>`. When closing a child, re-check the
parent's checklist.

## Test Suite Policy

- Tests must exercise observable behavior or a meaningful security or
  operational contract. Do not test that committed source contains particular
  strings, ordering, or exact text merely to restate the implementation.
- Default to Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) for new tests. Do not add new XCTest suites unless the harness genuinely requires XCTest.
- Prefer `pytest` for Python tests, run through `uv` and the Makefile targets.
- Migrate existing XCTest coverage to Swift Testing whenever you touch a test and the harness allows it, especially for pure-logic and host coverage. Do not churn large stable suites that still need XCTest just to change frameworks.
- Keep XCTest where the current harness still genuinely needs it, especially AppKit, SwiftUI host lifecycle, libghostty, and other UI/smoke paths that are already working.
- When migrating repetitive tests, prefer parameterized Swift Testing coverage over copy-pasted single-case methods.
- If you fix a regression, add or strengthen the narrowest test that would have caught it before moving on.
- Every new executable or library module ships with tests in the same change.
- Prefer deterministic unit tests around parsing, prompt generation, and
  process orchestration.
- Add integration tests at subprocess and file-system boundaries.

## Quality Gates

- Run `make format` before committing Swift changes. CI runs
  `make format-check` and fails on drift.
- Run Swift tests with `make swift-test` or targeted `xcodebuild test`.
- Tests that start a real tmux server must use `TestTmuxServer` and run under
  `tools/run_swift_tests.sh`; command-construction-only and Zellij tests do not
  need that fixture.
- Run Python tests with `make python-test`.

## Naming

- Avoid ceremonial naming. Prefer the shortest name that is still clear.
- Do not prefix files, types, tests, helpers, or fixtures with `Ghosthub` when the surrounding module or directory already provides that context.
- Prefer names like `HostProtocolTests` over `GhosthubHostProtocolTests`.
- Use `Libghostty...` for Ghosthub-owned wrappers around the embedded terminal library.
- Use `Ghostty` only when referring specifically to the upstream Ghostty project or source tree, Ghostty.app, its license, its configuration format, or upstream API/module names such as `GhosttyKit` and `ghostty_surface_t`.
- Never describe Ghosthub as embedding or running Ghostty. It embeds `libghostty`; Ghostty.app is a separate application.
- When touching existing code, clean up obviously redundant naming drift instead of extending it.

## Terminal Parity Rules

This is the most failure-prone part of the project. Treat it as a hard constraint.

- Ghosthub must behave like a normal macOS terminal app for shell startup and keybindings.
- Ghosthub is isolated from Ghostty.app configuration and state, but its embedded libghostty runtime should preserve the upstream library's macOS shell-startup semantics.
- Do not disable shell integration to work around keybinding bugs. Ghosthub relies on libghostty's shell integration for correct zsh startup behavior.
- Do not force a custom local shell command unless there is a very strong reason. Let libghostty launch the user shell using its normal macOS login-shell path.
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
- `make swift-test`
- `make build`

If the change is specifically about interactive shell behavior, also verify the existing smoke coverage around:

- dirty launcher env not breaking default shell bindings
- default libghostty shell integration loading user zsh startup files
- `Ctrl-A` / `Option-D` behavior through the workspace-hosted terminal path

## Practical Guardrails

- Prefer fixing terminal issues at the shell-startup or environment boundary before changing AppKit key handling.
- Prefer stronger end-to-end terminal smoke tests over helper-only unit tests when the bug is user-visible.
- If you change libghostty bootstrap patches, bump the Ghosthub bootstrap schema and rebuild artifacts.
- Keep Ghosthub-specific shell/config behavior documented when you change it.

## Code Organization

- Keep execution logic, issue-tracker access, and prompt rendering separated.
- Favor small files with clear responsibilities.
- Update `docs/architecture.md` when implementation changes an architectural
  assumption.

## Shell Safety

Use non-interactive shell flags so agents do not hang on prompts: `cp -f`,
`mv -f`, `rm -f`, `rm -rf`.

## Directory Map

- `Sources/`: Swift app modules (`GhosthubApp`, `GhosthubUI`,
  `GhosthubWorkspace`, `GhosthubSettings`, `GhosthubTerminal`,
  `GhosthubTerminalSupport`, `GhosthubPersistence`, `GhosthubTransport`,
  `GhosthubTmux`, `GhosthubHerdr`, `GhosthubZellij`).
- `Sources/App/`: Main macOS app logic and UI.
- `Sources/UI/`: Reusable SwiftUI/AppKit presentation components.
- `Sources/Workspace/`: Pure workspace, host, project, worktree, and session models.
- `Sources/Settings/`: Native settings and preferences.
- `Sources/Terminal/`: `libghostty` integration and surface management.
- `Sources/TerminalSupport/`: libghostty config/bootstrap support that can compile without the linked library.
- `Sources/Persistence/`: Database schema, models, and GRDB repositories.
- `Sources/Transport/`: Shared local/SSH command routing and shell helpers.
- `Sources/Tmux/`: Native tmux attachment command model.
- `Sources/Herdr/`: Native Herdr discovery and attachment command model.
- `Sources/Zellij/`: Native Zellij discovery and attachment command model.
- `tools/`: Python-based build, bootstrap (including `libghostty`), and
  packaging automation.
- `Tests/`: Swift and Python test suites. Python tests are in `Tests/test_*.py`;
  Swift tests are in `Tests/*/`.
