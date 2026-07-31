# Sidebar Layout Hang Design

## Problem

Ghosthub 0.4.0 became unresponsive after a user clicked a tmux session. The
macOS hang report shows the main thread continuously consuming CPU in
SwiftUI's lazy layout and AttributeGraph code for more than a minute. The
sample repeatedly traverses `LazySubviewPlacements`, `ForEachState`,
`_ViewList_Section`, pinned lazy-layout cache mutations, and deep alignment
resolution. It contains no blocked tmux, SSH, persistence, or libghostty work.

`WorkspaceSidebarView` is the workspace UI hierarchy matching that signature:
a `ScrollView` containing a pinned `LazyVStack`, with host `Section` values and
nested project, worktree, and tmux-session rows. Opening a session changes both
the selected row and active-session presentation, invalidating that hierarchy.
A minute-long application hang that requires Force Quit is unacceptable even
if the underlying SwiftUI behavior is intermittent.

## Decision

Replace the sidebar's pinned `LazyVStack` with a regular `VStack` inside the
existing `ScrollView`. Keep the current host `Section` structure, row builders,
styling, disclosure state, actions, and selection behavior unchanged.

The sidebar inventory is bounded by explicitly configured hosts and projects,
plus discovered tmux sessions. Eagerly laying out this navigation hierarchy is
a reasonable memory and startup tradeoff for removing the exact lazy/pinned
layout machinery present in every sampled stack. Host headers will scroll with
their contents instead of remaining pinned. The user explicitly accepted that
tradeoff.

Retaining `LazyVStack` while dropping only pinned headers would leave part of
the implicated lazy-layout path active. Rebuilding the sidebar with `List`
would introduce unnecessary styling, selection, and AppKit behavior changes.

## Regression Coverage

Add a focused macOS UI integration test that hosts `RootView` with the sidebar
visible, a snapshot containing ordinary tmux-session rows, and bindings for
selection and active-session state. Exercise the same transition as the real
row action: select a session, publish it as active, force layout, then switch
between sessions repeatedly while the sidebar remains mounted.

The test should assert Ghosthub-owned behavior: each switch completes through
the hosted view, the final selection and active session match, and the terminal
content builder presents the selected session. It must not assert SwiftUI type
names or source text, and it must not add timing thresholds that could be flaky
under CI load. The old implementation must be run first; if the intermittent
framework hang cannot be reproduced deterministically, the test still closes
the existing coverage gap but the production change remains justified by the
captured hang stack.

## Validation

Run the focused sidebar-visible integration test before and after the
production change, then run `make format`, the Swift suite, and `make build`.
The clean-worktree baseline currently exposes an unrelated `origin/main`
`GhosttyKit` module-map regression in `GhosthubTerminalTests`; do not alter
package configuration as part of this fix. Use the repository's previously
required module-map compiler flag when running the suite and report any
remaining baseline failure separately.

No architecture or website documentation changes are required because this
is a stability fix that removes sticky host headers without changing
Ghosthub's terminal, host, project, worktree, or session ownership model.

This Superpowers document is a local working artifact and must be removed from
the branch before any pull request is pushed, as required by `AGENTS.md`.
