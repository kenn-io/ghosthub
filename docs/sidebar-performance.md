# Sidebar performance

All timings below are representative Debug samples on Apple Silicon running
macOS 26.6.2, not CI thresholds or physical display latency. Input delays can
also come from other main-thread work not exercised by the isolated terminal
benchmark.

## Open terminal redraws

Redrawing an open tmux view reuses its retained terminal surface without
rebuilding the client launch command. Missing or failed surfaces still go
through the creation path, and clipboard policy, pane actions, and attachment
identity updates still apply to the retained client.

Profiling the Mac app caught launch-command quoting running on the main thread
during SwiftUI redraws. In a synthetic coordinator probe, 100 repeated lookups
took 110 ms for an SSH attachment and 3.9 ms locally. Reusing the surface
before building the command dropped both to about 0.2 ms. The regression test
verifies that repeated lookups build no new launch config and that an evicted
surface is recreated for both local and SSH attachments.

## Sidebar changes

Expanded tmux session and worktree groups use `LazyVStack` only when previews
are **Off**, limiting row construction to the viewport and nearby rows. When
previews are enabled, rows stay mounted because view lifetime drives preview
capture and parking. Full sibling drag lists still include offscreen rows, and
expansion state plus cached Changes results stay owned by the sidebar. An
offscreen Changes panel stops polling and resumes on remount, matching collapse
behavior.

`WorktreeChangesStore` uses Swift's native observation: the sidebar observes
expansion while `WorktreeChangesPanel` observes results and owns the polling
task, so a changed filename does not rebuild unrelated rows. Identity checks,
retry policy, and request coordination stay the same.

Manual worktree flags use a shared in-memory store with one observable value
per durable key so only matching worktree rows update. Flagging never
invalidates the whole sidebar, terminal roots, cached inventory sections, or
unrelated preview builders. Each row's durable key is computed once when
inventory sections build; renders read that cached value with no preference
reads, encoding, regexes, or extra scans. The store holds row values weakly so
it never retains hidden views. Explicit flag changes write preferences once,
and setting the same value is a no-op.

| Workload | Items | Before | After |
| --- | ---: | ---: | ---: |
| Tmux selection and layout | 100 | 19.7 ms | 5.9 ms |
| Tmux selection and layout | 500 | 130.9 ms | 6.5 ms |
| Worktree selection and layout | 100 | 121 ms | 42 ms |
| Worktree selection and layout | 500 | 779 ms | 45 ms |
| Worktree disclosure through accessibility | 100 | 797 ms | 189 ms |
| Worktree disclosure through accessibility | 500 | 13,101 ms | 187 ms |
| Changed-file publication and layout | 100 | 17.7 ms | 4.5 ms |
| Changed-file publication and layout | 500 | 19.1 ms | 4.5 ms |

Selection fixtures host two 1000 x 700 `RootView` windows with isolated
preferences across ten selections (including publication, a 1 ms run-loop turn,
and layout). Tmux selection compares eager rows from PR #245 (`12fbebc5`)
against lazy layout; the worktree baseline is `87c7009e`. Worktree disclosure
turns on enhanced accessibility and measures accessibility focus/responder
traversal rather than a normal mouse click.

Across ten tmux selections, row evaluations dropped from 1,111 / 5,511 (at 100
and 500 sessions) to 165 at both sizes. Single-line session rows later fit more
rows into the same viewport, bringing ten selections to 253 row evaluations at
both sizes (under the 300 gate). Worktree disclosure evaluations dropped from
312 / 1,512 to 105, and worktree selections dropped from 2,120 / 10,120 to 740.

The Changes fixture hosts a 320 x 700 sidebar with enhanced accessibility,
running the real polling loop against synthetic results (ten unchanged reads
followed by ten changed filenames, with a 1 ms polling sleep). Ten changed
results previously rebuilt 390 unrelated rows and now rebuild zero. Unchanged
results rebuild zero rows and take about 2.1 ms, with zero section rebuilds
(excluding real helper/network I/O and the normal 5-second poll interval).

## Regression checks and nightly acceptance

Run `make test-activation-gate` and
`make swift-test SWIFT_TEST_FILTER=WorktreeChanges`.

- `ActivationWorkGateTests` bounds row construction independent of inventory
  size, selects the last offscreen session and worktree through accessibility,
  and checks that Changes expansion survives scrolling offscreen and back.
- Its flag fixture hosts two windows with 100 or 500 worktrees (previews Off
  and Always Live) and requires 0 terminal-root evaluations, 0 section
  rebuilds, at most 16 row evaluations, and at most 4 preview-builder calls per
  window on a flag toggle, with preview mounts and selection untouched.
- `WorktreeFlagStoreTests` checks that repeated lookups neither read
  preferences nor encode state.
- The Changes fixture checks filenames, manual Refresh, collapse, and reopen.
- An Always Live fixture scrolls with 100 synthetic preview views mounted;
  separate terminal tests exercise real preview coordinators and libghostty.

The deterministic activation fixture drives SwiftUI's control-active state and
does not measure real Command-Tab latency or window-manager overhead. Synthetic
mouse events did not trigger SwiftUI hover updates in this runner and were
excluded.

An earlier report noted crashes with lazy sidebar views, with no verified
reproducer for this change. Passing focused gates does not prove long-running
stability; exercise nightly builds across normal multi-window scrolling,
selection, and group expansion before promoting lazy changes to stable.

## Terminal input benchmark

Run `make benchmark-input` after bootstrapping libghostty. It uses temporary
config and the private tmux fixture, shuts down all surfaces cleanly, and never
attaches to real sessions. It is opt-in (excluded from standard CI smoke tests)
and prints timings without machine-dependent pass/fail thresholds.

Scenarios cover a direct local PTY and a native tmux client with 100 and 500
sidebar sessions, sidebar shown and hidden, previews Off. Each phase runs 5
warmups followed by 30 measured keys sent through `NSApplication.sendEvent`,
verifying all 35 keys reach both installed shortcut monitors.

A Python probe echoes a numbered reply and flips a marker cell between black
and white. Each key waits for both the echoed text and the updated pixel in the
terminal layer's IOSurface before sending the next key (zero padding, opaque
background, exact cell dimensions). Reported numbers cover dispatch, viewport
text observation, rendered-layer observation, and longest main-actor echo-poll
wait (1 ms poll sleep; echo-poll excludes the frame wait).

In the pinned Metal renderer, a completed command buffer publishes its
IOSurface to the layer asynchronously on the main queue. Reading those
model-layer pixels includes polling and readback overhead and does not measure
compositor scanout, physical keyboard latency, or pre-dispatch queuing.

The inventory-overlap stress phases bump an offscreen session's window count
after every key, publishing through the real sidebar cache/revision path and
forcing layout (excluding inventory loading and full scene reconciliation).
Hiding the sidebar frees space for the terminal while leaving sidebar views
mounted and updating.

| Main-thread inventory publication and layout | Eager rows | Lazy rows |
| --- | ---: | ---: |
| 100 sessions, shown, PTY/tmux | 19.9 to 21.1 ms | 3.4 ms |
| 500 sessions, shown/hidden, PTY/tmux | 128.0 to 136.1 ms | 5.2 to 5.3 ms |

Eager-row comparisons temporarily restored PR #245's rows in the same fixture.
Across 35 updates, row evaluations fell from 3,535 / 17,535 (at 100 / 500
sessions) to 455 at either size; each phase recomputed sections 35 times.

With vsync off, representative rendered-layer medians were 1.3 to 1.6 ms steady
and 7.9 to 8.2 ms during 500-session inventory overlap; dispatch p95 stayed
under 0.1 ms, and steady phases rebuilt zero sidebar rows. A temporary
1,000-key probe measured shortcut translation at ~1 microsecond for one monitor
and ~9 microseconds for ten, so production shortcut handling was left alone.

When `CGGetActiveDisplayList` reports zero active displays, vsync surfaces fail
to initialize; the benchmark prints `vsync=true unavailable (active_displays=0)`
for that precondition while failing on other init errors. On September 13 with
one active display, all 24 steady and overlap phases passed across both vsync
settings (with vsync on: 8.3 to 8.4 ms steady, 7.8 to 8.4 ms overlap). Key
window delivery stayed unavailable, so inter-window refocus and Command-Tab
remain unverified. The first September 13 run timed out waiting for one tmux
probe's initial marker; an unchanged rerun passed and the root cause of that
one-off timeout is unconfirmed.

## Earlier shipped improvements

- **PR #242:** stopped loading-only inventory refreshes from reapplying cached
  hosts, kept disclosure state per window, and delayed live-preview resume
  until a scene is eligible. Two-scene refreshes dropped from 8 cached-host
  merges and 24 redundant state publications to zero; ten unchanged activation
  preference refreshes dropped from 20 root-view evaluations to zero. Only
  successful preview mounts consume parking slots, while failed mounts release
  their budget slot and keep reacquisition pending.
- **PR #245:** built sibling drag metadata once per group, cut unused row work,
  and fixed Python input probes to run via `uv` and `/usr/bin/env`. At 500
  sessions, drag items across ten selections fell from 2,750,000 to 5,500 and
  selection/layout fell from 186 ms to 131 ms (the baseline for the lazy-row
  numbers above).

## Remaining scope

The codebase still has repeated row lookups, sidebar-owned hover state, full
host scans on section-cache misses, and shared result observation across
multiple mounted Changes panels; measure each before changing it. Preview-on,
Herdr, and Zellij groups remain outside the lazy-layout change, and real
multi-window hover, activation, and typing latency still need separate
measurements.
