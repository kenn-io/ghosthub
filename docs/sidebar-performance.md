# Sidebar performance

Measurements collected September 10–13, 2026. Timings are representative Debug
samples on Apple Silicon with macOS 26.6.2, not CI timing thresholds or physical
display latency. The intermittent typing lag reported in local and remote
sessions with previews Off is no longer apparent to the reporter; its cause
remains unconfirmed and further investigation is paused.

## Sidebar changes

Expanded tmux session and worktree groups use native `LazyVStack` layout only
when previews are Off. This limits row construction to the viewport and nearby
rows. Preview-enabled groups stay mounted because their lifetime controls
capture and parking eligibility. Full sibling drag lists still include
offscreen rows, and expansion and cached Changes results remain sidebar-owned.
An offscreen Changes panel stops polling and resumes on remount, as it already
does when an ancestor group collapses.

`WorktreeChangesStore` uses native property observation. The sidebar observes
expansion, while `WorktreeChangesPanel` observes results and owns the existing
polling task. A changed filename therefore does not rebuild unrelated rows.
Identity validation, retry policy, and request coordination are unchanged.

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

The selection fixtures host two 1000 × 700 `RootView` windows with isolated
preferences and ten selections. Timings include publication, a requested 1 ms
run-loop turn, and layout. Tmux selection compares eager rows from merged
PR #245 (`12fbebc5`) with lazy layout; the worktree baseline is `87c7009e`.
Worktree disclosure enables enhanced accessibility and is not an ordinary
mouse-click measurement. Baseline sampling found substantial SwiftUI
accessibility focus and responder-traversal work.

Across ten tmux selections, row evaluations fell from 1,111/5,511 at 100/500
sessions to 165 at both sizes. Worktree disclosure row evaluations fell from
312/1,512 to 105; worktree selections fell from 2,120/10,120 to 740.

The Changes fixture hosts a 320 × 700 sidebar with enhanced accessibility. It
uses the real polling loop, synthetic loader results, and a controlled sleep
to release ten identical results followed by ten changed filenames. Timing
includes asynchronous comparison/publication, a requested 1 ms polling sleep,
and layout. Ten changed results previously rebuilt 390 unrelated rows and now
rebuild zero. Identical results rebuild zero rows before and after and take
about 2.1 ms. Section computations remain zero. This excludes real helper and
network work and the normal five-second polling interval.

## Regression checks and nightly acceptance

Run `make test-activation-gate` and
`make swift-test SWIFT_TEST_FILTER=WorktreeChanges` for the relevant checks.
`ActivationWorkGateTests` bounds row construction independently of inventory
size, selects the final offscreen session and worktree through accessibility,
and checks that Changes expansion survives scrolling away and back. The Changes
fixture checks displayed filenames, manual Refresh, collapse, and reopening.
An Always Live fixture keeps 100 synthetic preview views mounted while scrolling;
separate terminal tests exercise real preview coordinators and libghostty.

The deterministic activation fixture drives SwiftUI's control-active state;
it does not establish real Command-Tab latency or app-scene behavior above the
hosted view. Synthetic mouse events did not trigger SwiftUI hover updates in
this runner, so those samples were rejected.

The reporter previously encountered crashes with lazy sidebar components.
This change has no verified reproducer for that earlier failure. Passing the
focused checks does not establish long-running stability: use nightly builds
with normal multi-window work, scrolling, selection, and group expansion before
including these changes in a stable release. Crash stability during that trial
remains unverified.

## Terminal input benchmark

Run `make benchmark-input` after bootstrapping libghostty. It uses temporary
preferences/configuration and the standard private tmux fixture, shuts down its
surfaces, and never attaches to existing sessions. The opt-in benchmark is
excluded from ordinary CI smoke selection; it reports timings without imposing
machine-dependent thresholds.

Scenarios cover a direct local PTY and a native tmux client, 100/500 sidebar
sessions, shown/hidden sidebar states, and previews Off. Five warmups precede
30 measured keys. Keys enter through `NSApplication.sendEvent`; each phase
checks that all 35 keys reach both installed application shortcut monitors.

The Python probe echoes a numbered response and alternates a separate cell
between black and white. Every key waits for the expected text and the matching
pixel in the terminal layer's IOSurface before the next key is sent. Zero
padding, opaque backgrounds, and actual cell dimensions locate the marker.
Reported timings cover dispatch, text-viewport observation, rendered-layer
observation, and the longest main-actor echo-poll wait. Polling requests a 1 ms
sleep; the echo-poll metric excludes the later frame wait.

In the pinned Metal implementation, a completed command buffer publishes its
IOSurface to the layer, dispatching to the main queue for asynchronous frames.
Observing those model-layer pixels includes polling/readback overhead. It does
not measure compositor consumption, scanout, physical-keyboard latency, or an
event waiting before dispatch.

The inventory-overlap phases change an offscreen session's window count after
each key, publish through the real sidebar cache/revision path, and force
layout. This is a stress case, not normal refresh cadence; it excludes inventory
loading and full scene reconciliation. Hiding the sidebar returns its space to
the terminal but leaves its content mounted and updating.

| Main-thread inventory publication and layout | Eager rows | Lazy rows |
| --- | ---: | ---: |
| 100 sessions, shown, PTY/tmux | 19.9–21.1 ms | 3.4 ms |
| 500 sessions, shown/hidden, PTY/tmux | 128.0–136.1 ms | 5.2–5.3 ms |

These comparisons temporarily restored the eager rows from PR #245 in the same
fixture. Across 35 updates, row evaluations fell from 3,535/17,535 at 100/500
sessions to 455 at either size; each phase recomputed sections 35 times.

With application dispatch and vsync disabled, representative rendered-layer
medians were 1.3–1.6 ms steady and 7.9–8.2 ms during 500-session inventory overlap.
Dispatch p95 stayed below 0.1 ms, and steady phases rebuilt zero sidebar rows.
A temporary 1,000-key probe measured shortcut translation at about 1 microsecond
for one monitor and 9 microseconds for ten; it did not justify a production
shortcut change. No production renderer or key-handling settings were changed.

Earlier runs reported zero active displays via `CGGetActiveDisplayList`, and a
vsync-enabled surface failed to initialize. The benchmark reports
`vsync=true unavailable (active_displays=0)` for that precondition and checks
the loaded vsync value for runtimes it creates. Other initialization failures
still fail. On September 13, the runner reported one active display and the
benchmark passed all 24 steady/overlap phases across both vsync settings. With
vsync enabled, steady rendered-layer medians were 8.3–8.4 ms and inventory-overlap
medians were 7.8–8.4 ms. These are model-layer observations, not physical display
latency. Key-window delivery remained unavailable, so inter-window refocus and
Command-Tab remain unverified.

The first September 13 run timed out waiting for one tmux probe's initial text
and pixel marker. The unchanged rerun passed; the readiness failure's cause is
unconfirmed. This does not establish long-running app stability.

## Earlier shipped improvements

PR #242 stopped loading-only inventory publications from reapplying cached
hosts, retained window-local disclosure state, and delayed live-preview resume
until the scene is eligible. Two-scene refresh instrumentation counted eight
cached-host merges and 24 unchanged warning/state publications before a loader
returned; both fell to zero. Only successful preview mounts consume parking
slots, and failed mounts release their budget request while reacquisition stays
pending. Ten unchanged activation preference refreshes fell from 20 root-view
evaluations to zero. These are work counts, not activation latency.

PR #245 built sibling drag metadata once per group, avoided unused row work,
and repaired Python-backed input probes by selecting Python through uv and
launching through `/usr/bin/env`. At 500 sessions, drag items across ten
selections fell from 2,750,000 to 5,500 and selection/layout fell from 186 ms to
131 ms. The lazy-row comparison above starts from that improved baseline.

## Remaining scope

The source still contains repeated row lookups, sidebar-owned hover state,
fleet scans on section-cache misses, and shared result observation between
multiple mounted Changes panels. Their costs need separate measurements before
further changes. Eager preview-enabled, Herdr, and Zellij groups are outside the
lazy-layout change. Row/hover work remains tracked by `s921`, activation by
`360m`, and typing latency by `w8v8`; none is claimed fully resolved here.
