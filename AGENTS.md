# Ghosthub Agent Guide

Guidance for coding agents working in Ghosthub. It covers the product model,
technical boundaries, workflow rules, build commands, and test gates.

## Core mental model

Ghosthub is a **native hub for local and remote terminal multiplexers**
(macOS Swift app, plus an in-progress Rust port for Windows and Linux). It is
an alternative to juggling SSH and multiplexer tabs in a general-purpose
terminal like iTerm2, Ghostty, or Kitty, letting users work across hosts
without touching a local shell.

Four workflows have equal status:

- **tmux:** create or attach to any tmux session on a configured host, and
  restore tmux sessions kwt saved before a reboot.
- **Herdr and Rex:** create, attach to, stop, restart, or delete Herdr TUI
  sessions on supported hosts. On macOS, also discover and attach to backend
  terminals on local and remote POSIX hosts: live Herdr desktop (`herdr-core`)
  tabs and terminals, and Rex windows. Herdr desktop owns its creation,
  lifetime, and split layout (Ghosthub shows desktop tabs read-only). Rex owns
  its window layout and pane lifetime; Ghosthub draws Rex's layout and sends
  user layout changes back to Rex.
- **Zellij:** create, attach to, or kill active Zellij sessions on supported
  hosts.
- **Git worktrees (optional):** create tmux sessions bound to Git worktrees and
  manage branch and GitHub pull-request worktrees through kwt. Ghosthub is
  fully useful without Git or worktrees.

### Key concepts and boundaries

- **Hosts:** every machine is a Host. The local Mac is the default host; remote
  macOS and Linux hosts connect over SSH (native Windows/psmux hosts are
  experimental).
- **Projects:** Git repositories (and plain directory workspaces) reported by
  kwt on a host.
- **Worktrees:** kwt workspaces (primary checkouts or linked Git worktrees),
  each with an exact tmux session name.
- **Sessions:** worktree sessions and standalone tmux sessions open through a
  normal tmux client. Herdr TUI sessions list both running and stopped entries;
  opening a running one attaches, while creating or restarting runs Herdr's
  launch path. Active Zellij sessions open through a normal Zellij client. Each
  backend owns its windows, tabs, panes, layout, history, key bindings, and
  process lifetime.
- **Attachment:** each window/tab (`Scene`) has at most one active interactive
  view. Previously opened tmux clients may stay retained and noninteractive,
  and **Always Live** preview mode may also connect freshly discovered POSIX
  tmux sessions without activating them. Previews reuse the retained client
  rather than opening a second one. Ghosthub owns discovery, local/SSH client
  views, keepalives, and reconnect. Closing a view detaches only. Ending tmux
  or Zellij sessions requires a confirmed **Kill Session…** action. Herdr TUI
  **Stop** and **Delete** are separate confirmed actions; **Restart** and
  **Create** are constructive.
- **Backend terminals (`Sources/BackendTerminal/`):** Herdr Core terminals/tabs
  and Rex windows share one model (host, kind, address). Display names never
  identify a terminal. A Herdr Core terminal attaches in its own surface, and
  desktop tabs render in the read-only split view. A Rex window follows its
  layout over one `kwt rex control` channel and attaches each pane with
  `kwt rex attach` inside the split container from `Sources/TerminalSupport/`,
  always using Ghosthub's pinned kwt (never a `rex` client). Layout changes
  appear once Rex reports them. The sidebar lists every standalone session on a
  host in one list labeled **tmux**, **zellij**, **herdr**, **herdr tui**, or
  **rex**. Sibling navigation walks that whole list in sidebar order and skips
  stopped Herdr sessions. See
  [Backend terminals](docs/terminal-sessions.md#backend-terminals).
- **Rust Linux Rex support:** opens remote Rex windows over the existing SSH
  lease (including SSH over Tailscale), draws Rex's reported tiled layout with
  one libghostty terminal per pane, and sends pane operations over
  `kwt rex control`. Closing a view detaches all its clients; closing a pane is
  a separate confirmed action that ends its program.
- **Console Panel:** a host-scoped persistent terminal area (for example, for
  `roborev`) independent of the active worktree.
- **Middleman:** Ghosthub has no Middleman runtime or API dependency. Sessions
  created by Middleman appear only because they are ordinary tmux sessions.

### Authority and non-goals

Ghosthub is production software under active development, with some features
still in development or marked experimental; check the persistence rules below
before changing stored state.

- **Discovery authority:** kwt's machine-readable CLI owns project/worktree
  identity and exact tmux session names. Direct `tmux list-sessions` supplies
  standalone tmux sessions. Herdr's JSON list independently supplies running
  and stopped Herdr TUI sessions, and Zellij's list independently supplies
  active Zellij sessions (excluding exited/resurrectable ones). Missing Herdr
  or Zellij installs are normal and silent.
- **kwt helper distribution:** packaged builds use their revision-pinned
  bundled kwt locally and automatically install or update the matching helper
  under `~/.ghosthub/` on configured remote macOS and Linux hosts. Windows
  helper installation stays explicit until the executables are
  Authenticode-signed.
- **No filesystem scanning:** remote hosts register projects only through Host
  Settings **Add Project** (passing one absolute repository path to kwt).
  Ghosthub never scans remote filesystems or edits kwt config.
- **No backend reconstruction:** Ghosthub never uses `tmux -CC` and never
  reconstructs tmux, Herdr, or Zellij windows, tabs, panes, layouts, history,
  or terminal output in Swift.
- **Herdr scope:** whole-session create, stop, restart, and delete, plus
  explicit **Split Right** and **Split Down** requests on a capable active
  Herdr TUI attachment (Herdr still picks the focused pane and owns the
  layout). Ghosthub does not manage Herdr themes, workspaces, tabs, panes,
  agents, plugins, installs, updates, config, or server-wide state.
- **Zellij scope:** active-session create, attach, and confirmed kill only.
  Zellij has no atomic active-only attach, so an upstream attach can resurrect
  a session that exits right after Ghosthub's active check; this narrow race is
  accepted, and confirmed kills fence reconnects across windows. Ghosthub never
  offers resurrection or exited-session deletion and does not manage Zellij
  themes, plugins, installs, updates, config, or server-wide state.

## Source of truth hierarchy

1. `AGENTS.md`: mental model, workflow rules, build commands, and quality gates.
2. `docs/architecture.md`: product and architecture source of truth.
3. `docs/threat-model.md`: security boundaries and trusted-peer assumptions.
4. `docs/terminal-sessions.md`: terminal ownership, shell startup, and restart
   semantics.
5. `docs/release.md`: signing, notarization, and release process.

## Documentation

- Write for the person using or maintaining Ghosthub. Lead with the outcome,
  name who does what, use short sentences, and explain unfamiliar terms.
- Organize around reader questions. Put purpose and current behavior first;
  keep limits and future work separate. Include only sections the topic needs.
- Give each bullet one main idea. Use numbered steps for sequences, paragraphs
  for rationale, and tables or diagrams for comparisons and flows.
- State rules directly. Keep exact commands, field names, authorization checks,
  limits, and failure behavior intact when simplifying prose.
- Give each fact one owning page and link to it elsewhere. Update that section
  instead of appending a history of recent changes. Indexes should route
  readers, not repeat implementation status.
- Separate current behavior from approved unbuilt work, proposals, and old
  decisions. Keep rationale, approvals, and active exceptions with their
  removal conditions. Label superseded designs and keep them out of main nav.
- Keep the website, its Markdown companions, README, and engineering docs in
  sync. Distinguish the latest release from newer `main` behavior. Follow
  [docs/README.md](docs/README.md) for publishing layout and checks.

## Non-negotiable workflow rules

### Git, branches, and PRs

- Complete every step in a multi-step request without stopping (for example,
  branching, committing, and opening a PR).
- Commit every code- or doc-producing turn before responding, without asking
  whether to commit. Never leave task-related uncommitted work behind.
- Push completed task-branch commits to their configured remote before
  responding. Force-push only when the user explicitly requests a history
  rewrite.
- Never commit directly to `main` or `master`. Create a task branch before the
  first commit. If a commit accidentally lands on the default branch, move it
  to a task branch and reset the local default branch to its upstream before
  pushing.
- Never amend commits unless explicitly requested.
- Canonical repository: `https://github.com/kenn-io/ghosthub`. Only push or
  open pull requests when the user explicitly asks.
- Never include local superpowers planning docs (`docs/superpowers/specs/`,
  `docs/superpowers/plans/`) in a PR; remove them from the branch before
  pushing or opening a PR.
- Do not poll or watch GitHub Actions through `gh`, the GitHub API, or browser
  automation unless the user explicitly asks.
- Public contribution policy: no unsolicited PRs. Direct bug reports and
  feature requests to GitHub issues; prospective code contributors coordinate
  privately with Kenn Software first. Contributions use Apache-2.0 with no CLA.

### Pull request descriptions and screenshots

- Every PR must state whether it delivers a user-facing benefit or a developer
  experience improvement.
- Write PR descriptions as short, scannable plain-language bullets. Lead with
  user-visible purpose and concrete behavior, then material constraints or
  consequences. Do not narrate development history or add boilerplate headings
  like "Changes", "Validation", "Tests", or "Verification"; mention unusual
  validation inline only when it helps reviewers.
- Prefix every Rust-port PR title with the `rust-port` scope (for example,
  `feat(rust-port): open imported PR worktrees over SSH`) and attach inspected
  screenshots made with synthetic session data.
- Update the website user guides whenever a user-facing workflow changes.
  Regenerate and publish website screenshots only at feature acceptance and PR
  time, and only when accepted visuals actually changed (copy, accessibility,
  and non-visual changes do not need new captures). Prefer deterministic demo
  fixtures with synthetic data; never expose real account, host, project, or
  session data. Publish refreshed binaries to the orphan `website-assets`
  branch.

### Build, release, and schema rules

- Never leave the app build broken at the end of a turn.
- If a turn touches Swift app code, terminal integration, `Package.swift`, or
  bootstrap logic, `make build` must pass before ending the turn.
- If a turn changes kwt inventory, host resolution, tmux/Herdr/Zellij
  discovery, or native session attachment, run `make test-essential-workflows`.
- If a turn touches release packaging, signing, notarization, or
  `.github/workflows/release.yml`, update `docs/release.md` in the same turn.
- `RELEASE_VERSION` is the single source of the current release version outside
  dated entries in `website/docs/content/changelog.md` and published tags.
  Preparing a release updates only `RELEASE_VERSION` and that changelog;
  scripts, Makefiles, workflows, tests, and docs must read `RELEASE_VERSION` or
  use `X.Y.Z`.
- Write changelogs and release notes in plain language: lead with what users
  can do or what works better, and include implementation details only when
  they explain a constraint or required user action.
- Use `uv` for all Python tooling and tests (never bare `python`, `pip`, or ad
  hoc virtualenvs).
- Prefer Makefile targets over long raw commands; add a `make` target if a test
  or Python invocation is complex enough to copy around.
- **No database migrations** until the first production release. Update the
  current schema, bootstrap paths, fixtures, and tests directly.

## Commit messages

Use Conventional Commits for commit subjects and PR titles (PRs squash-merge,
so the PR title becomes the commit subject and the description becomes the
body):

```text
type(scope): summary
```

Allowed types:

- `feat`: new capability users can see or use.
- `fix`: user-visible bug fix.
- `perf`: user-visible speed or resource improvement.
- `refactor`, `test`, `docs`, `build`, `ci`, `chore`: no product behavior
  change.

Mark breaking changes with `!` before the colon (`feat(api)!: remove v1`) and a
`BREAKING CHANGE:` footer.

No tool reads these types. Release notes come only from the dated section of
`website/docs/content/changelog.md`, and the release maintainer picks the
version in `RELEASE_VERSION` (see [docs/release.md](docs/release.md)). So:

- A `feat`, `fix`, or `perf` PR adds its own plain-language entry under
  `## [Unreleased]` in `website/docs/content/changelog.md`. Without it, the
  change is missing from the release notes.
- The type tells the release maintainer how large the version bump should be:
  a breaking change, then `feat`, then `fix`.
- Nightly notes list every commit subject as written, so a missing type shows
  there too.

## Issue tracking

Use `kata` (bound via `.kata.toml`) as the sole work tracker. Do not create
markdown TODO lists or parallel trackers.

- Full guide: `kata quickstart`
- List open work: `kata list --json` (filter with `--status open`)
- Read an issue: `kata show <number> --json`
- Search before creating: `kata search "<terms>" --json`
- Create follow-up work:
  `kata create "<title>" --body "<body>" --label area:host --label priority:p2 --idempotency-key "<unique-key>" --json`
- Comment: `kata comment <number> --body "<text>" --json`
- Labels: `kata label add <number> <label>` / `kata label remove`
- Link issues with `kata edit <ref>`: `--parent <ref>` (at most one),
  `--blocks <ref>`, `--blocked-by <ref>`, `--related <ref>`, or `--remove-*`
- Close when actually done: `kata close <number> --reason done --json`
- Never run `kata delete` or `kata purge` without explicit user instruction.

**Allowed labels:** `area:{host,ui,infra,docs,remote,tests}`,
`priority:{p1,p2,p3}`, `epic`, `bug`, `enhancement`. Do not invent new label
prefixes without updating this file.

**Epics:** label the parent `epic`, list children in a markdown checklist in
its body, link each child with `kata edit <child> --parent <epic>`, and update
the checklist when closing a child.

## Testing and quality gates

### Test suite policy

- Test observable behavior and real security or operational contracts. Never
  assert that source files contain specific strings or ordering just to restate
  the implementation.
- Use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) for new
  Swift tests. Keep XCTest only where the harness genuinely needs it (AppKit,
  SwiftUI host lifecycle, libghostty, and existing UI/smoke suites). Migrate
  touched pure-logic/host tests to Swift Testing when practical, using
  parameterized tests for repetitive cases.
- Put all Python tests in `tools/tests/` using `pytest` via `uv` and Makefile
  targets. Keep `Tests/` Swift-only.
- Fix regressions with the narrowest test that catches the bug.
- Ship tests alongside every new executable or library module. Prefer
  deterministic unit tests for parsing, prompts, and orchestration, plus
  integration tests at subprocess and filesystem boundaries.

### Required checks

- Run `make format` before committing Swift changes (`make format-check` runs
  in CI). Use the formatter pinned in `mise.toml`; do not bypass hooks.
- Prek hooks run Swift formatting and basic file checks on both Linux and
  macOS; the Swift compiler warning hook runs on macOS, and macOS CI runs
  `make swift-warning-check`.
- Run Swift tests with `make swift-test` or targeted `xcodebuild test`.
- Tests that start a real tmux server must use `TestTmuxServer` and run under
  `tools/run_swift_tests.sh` (command-construction-only and Zellij tests do not
  need it).
- Tests creating a `TerminalSurfaceView` (directly or via a coordinator) must
  own it through teardown and await `shutdown()` before exiting; never rely on
  `deinit` or process exit to stop its shell.
- Run Python tests with `make python-test`.

## Naming

- Pick the shortest clear name. Do not prefix files, types, tests, helpers, or
  fixtures with `Ghosthub` when the module or directory already gives that
  context (use `HostProtocolTests`, not `GhosthubHostProtocolTests`).
- Use `Libghostty...` for Ghosthub wrappers around the embedded terminal
  library.
- Use `Ghostty` only for the upstream Ghostty project/source, Ghostty.app, its
  license, its config format, or upstream API names (`GhosttyKit`,
  `ghostty_surface_t`).
- Never say Ghosthub embeds or runs Ghostty. It embeds `libghostty`;
  Ghostty.app is a separate app.
- Clean up redundant naming drift when touching existing files.

## Terminal parity rules

This is the most failure-prone area in the codebase. Treat every rule below as
a hard constraint:

- Shell startup and keybindings must match a normal macOS terminal.
- Keep Ghosthub isolated from Ghostty.app config and state while preserving
  libghostty's upstream macOS login-shell startup.
- Never disable shell integration to work around keybinding bugs; zsh startup
  depends on it.
- Do not force a custom local shell command without a compelling reason; let
  libghostty launch the user's normal macOS login shell.
- Do not leak launcher-terminal environment into embedded shells, especially
  `EDITOR` and `VISUAL` (which can switch zsh keymaps and break `Ctrl-A`,
  `Ctrl-E`, `Ctrl-K`, and `Option-D`).
- Keep `TERM_PROGRAM` set to `ghosthub`.
- Do not pin `shell-integration-features` to work around cursor or keybinding
  bugs unless exposed as a deliberate user setting.
- Keep Ghosthub terminal config at `~/.config/ghosthub/ghostty.conf` and
  mutable app state under `~/.ghosthub/` (not `~/Library/Application Support/`
  or `~/.config/ghosthub/`). Global Ghostty.app config must never affect
  Ghosthub.

### Terminal regression checks

Whenever you touch terminal startup, shell environment, config layering,
libghostty bootstrap, key handling, or remote logic, run all four:

- `make test-libghostty-bootstrap`
- `make python-test`
- `make swift-test`
- `make build`

For interactive shell changes, also verify smoke coverage for dirty launcher
env, default shell integration loading user zsh startup files, and
`Ctrl-A`/`Option-D` through the workspace-hosted terminal path.

### Practical guardrails

- Fix terminal bugs at the shell-startup or environment boundary before
  changing AppKit key handling.
- Prefer end-to-end terminal smoke tests over helper-only unit tests for
  user-visible bugs.
- Bump the Ghosthub bootstrap schema and rebuild artifacts whenever you change
  libghostty bootstrap patches.
- Document Ghosthub-specific shell or config changes when you make them.

## Code organization and shell safety

- Keep execution logic, issue-tracker access, and prompt rendering separate,
  and favor small focused files.
- Update `docs/architecture.md` whenever an architectural assumption changes.
- Use non-interactive shell flags (`cp -f`, `mv -f`, `rm -f`, `rm -rf`) so
  commands never hang on prompts.

## Directory map

- `Sources/`: Swift modules (`GhosthubApp`, `GhosthubUI`, `GhosthubWorkspace`,
  `GhosthubSettings`, `GhosthubTerminal`, `GhosthubTerminalSupport`,
  `GhosthubPersistence`, `GhosthubTransport`, `GhosthubTmux`, `GhosthubHerdr`,
  `GhosthubZellij`, plus `BackendTerminal`).
- `Sources/App/`: main macOS app logic and UI.
- `Sources/UI/`: reusable SwiftUI/AppKit components.
- `Sources/Workspace/`: pure workspace, host, project, worktree, and session
  models.
- `Sources/Settings/`: native settings and preferences.
- `Sources/Terminal/`: `libghostty` integration and surface management.
- `Sources/TerminalSupport/`: libghostty config/bootstrap helpers and the
  split-tree layout/container (compiles without linking `libghostty`).
- `Sources/Persistence/`: database schema, models, and GRDB repositories.
- `Sources/Transport/`: local/SSH command routing and shell helpers.
- `Sources/Tmux/`: tmux attachment command model.
- `Sources/Herdr/`: Herdr discovery and attachment command model.
- `Sources/BackendTerminal/`: Herdr Core and Rex discovery, attachment
  commands, and Rex window layout model.
- `Sources/Zellij/`: Zellij discovery and attachment command model.
- `tools/`: Python build, bootstrap (`libghostty`), and packaging automation.
- `Tests/`: Swift test suites.
- `tools/tests/`: Python tests for build, packaging, and tool code.
