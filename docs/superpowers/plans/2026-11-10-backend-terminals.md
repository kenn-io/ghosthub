# Backend terminals: Herdr Core and Rex (local working plan)

Not for the PR (AGENTS.md: remove docs/superpowers before pushing).
Kata epic: j89k. kwt side: kenn-io/kwt#222 (`kwt rex ls --json`, `kwt rex attach BLOCK_ID`).

## Decisions (from Wes, 2026-11-10)
- Rex attach client lives in kwt; ghosthub runs pinned kwt locally (bundled) and on SSH hosts
  (`$HOME/.ghosthub/helpers/kwt/<rev>/kwt`). Scope: local + POSIX SSH hosts.
- Shared terminal layer: backend-neutral "backend terminal" model used by Herdr Core and Rex.
  Herdr TUI sessions stay in the Herdr stack. Remove `HerdrBackend.core`.
- Later (separate PR): Ghosthub-drawn split tree of libghostty panes for Rex windows and
  Herdr desktop tabs, Cmd-D / Cmd-Shift-D ask the backend to split.

## Naming
`BackendTerminalKind` (`herdrCore` raw "core", `rex`), `BackendTerminalSummary`
(kind, address, title, detail), `WorkspaceBackendTerminalSelection` (hostID, kind, address),
`NativeBackendTerminalCoordinator`, `BorrowedBackendTerminalView`,
`BackendTerminalInventoryClient`. Avoid bare "Terminal" (collides with libghostty types).

## Steps
1. Workspace models + `HostSnapshot.backendTerminals` (+ per-kind availability/failure).
2. `Sources/Rex` module: `RexTerminalInventory` (kwt JSON parse), attach argv.
   Herdr module keeps `HerdrCoreInventory` + core attach argv.
3. App: inventory client (herdr-core ls + kwt rex ls, one SSH lease), coordinator extracted from
   NativeHerdrSessionCoordinator core path (no launch mode, lifecycle, pane split).
4. Scene model: move every `backend == .core` flow (discovery, presentation, reconnect,
   restoration descriptor, sibling navigation, absent-on-probe close) to backend terminals.
5. UI: sidebar groups "Herdr Terminals" / "Rex Terminals", palette, titlebar, accessibility.
6. Delete `HerdrBackend` (TUI only remains).
7. Tests: port core tests, add Rex parse/command/presentation tests, live
   `make test-rex` against an isolated Rex server if feasible.
8. Docs: AGENTS.md mental model, architecture.md, terminal-sessions.md, website sessions guide.
