# Ghosthub Development Guide

## General Workflow

When a task involves multiple steps (e.g., implement + commit + PR), complete ALL steps in sequence without stopping. If creating a branch, committing, and opening a PR, finish the entire chain.

Always commit after every turn. Don't wait for the user to ask — if you made changes, commit them before responding. Do not ask "shall I commit?" or "want me to commit?" — just commit. Committing is not a destructive or risky action; it is the expected default after every change.

## Project State

Ghosthub is pre-release. `docs/architecture.md` is the source of truth
for product scope and architecture. Treat the entire app, including its
persistence layer, as subject to direct iteration.

**No database migrations** until the first production release. Update the
current schema, bootstrap paths, fixtures, and tests directly.

- Kwt's machine-readable CLI is authoritative for project/worktree identity
  and exact tmux session names. Direct `tmux list-sessions` discovery supplies
  every otherwise-unbound session on each configured host.
- Packaged builds invoke their revision-pinned bundled kwt for local operations;
  remote hosts resolve and execute their own kwt.
- Kwt workspaces and unbound sessions open through the same ordinary tmux
  client. Ghosthub never uses `tmux -CC` or reconstructs tmux panes, windows,
  layouts, history, or terminal output in Swift.
- Ghosthub has no Middleman runtime or API dependency. Middleman-created tmux
  sessions remain visible when ordinary tmux discovery finds them.

## Repository Layout

- `Sources/` — Swift app modules (GhosthubApp, GhosthubUI,
  GhosthubWorkspace, GhosthubSettings, GhosthubTerminal,
  GhosthubTerminalSupport, GhosthubPersistence, GhosthubTmux)
- `Sources/TmuxControl/` — native tmux/SSH attachment command model
- `tools/` — Python bootstrap automation (`libghostty`)
- `Tests/` — Python tests (`Tests/test_*.py`) and Swift tests
  (`Tests/*/`)

## Build and Test

### Swift

```sh
make build                     # Build the app and required Swift targets
swift test                      # Run all Swift tests
make test-essential-workflows   # kwt inventory and ordinary tmux attachment smoke
```

If a turn touches the app, `Package.swift`, terminal integration, or any Swift
code that can affect app compilation or launch, the turn is not complete until
`make build` succeeds. Do not leave the app build broken.

If a turn changes kwt inventory, host resolution, tmux discovery, or native
tmux attachment, run `make test-essential-workflows` before claiming the
change is correct.

### Python tooling

```sh
make python-test                       # Run Python tests via uv-managed pytest
make test-libghostty-bootstrap         # Run the focused libghostty bootstrap Python tests
```

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
- Link issues via `kata edit <ref>`: `--parent <ref>` (set parent, ≤1),
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

## Conventions

- Commit every turn. Never amend commits. Agent turns must finish with a commit
  when they make changes.
- The canonical repository is `https://github.com/kenn-io/ghosthub`.
  Only push or open PRs when the user explicitly asks.
- Use `uv` for Python build/test execution rather than bare `python`, `pip`,
  or unpinned virtualenv state.
- Prefer Makefile targets for complex test invocations. If a Python or
  multi-flag test command is worth repeating, add a `make` target instead of
  relying on copied shell snippets.
- Default to Swift Testing for new Swift tests. Only add XCTest when the test
  harness genuinely requires it.
- When touching existing Swift tests, migrate them from XCTest to Swift
  Testing whenever practical instead of adding more XCTest-only coverage.
- Never include superpowers planning documents (`docs/superpowers/specs/`,
  `docs/superpowers/plans/`) in a PR. They are local working artifacts; remove
  them from the branch before pushing or opening a PR.
- Keep execution logic, issue-tracker access, and prompt rendering separated.
- Favor small files with clear responsibilities.
- Every new executable or library module ships with tests in the same change.
- Update `docs/architecture.md` when implementation changes an architectural assumption.

## Quality Gates

- `make build` is required for app-affecting Swift changes.
- **Formatting:** `make format` before committing Swift; CI runs
  `make format-check` and fails on drift.
- **Python:** `make python-test`
- **Swift:** `swift test` or targeted `xcodebuild test`
- Prefer deterministic unit tests around parsing, prompt generation, and
  process orchestration.
- Add integration tests at subprocess and file-system boundaries.

## Shell Safety

Use non-interactive shell flags so agents do not hang on prompts:
`cp -f`, `mv -f`, `rm -f`, `rm -rf`
