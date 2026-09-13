# Sidebar performance review

Reviewed September 10, 2026, against `dedc40b2`, including the inventory
sharing change in `4c8bd7ed`.

## Measured refresh work

A deterministic test opens two scene models with the same populated inventory
store and holds the next inventory load. It calls `refreshKwtInventory` and counts work
before any new result returns. Temporary instrumentation in
`HostInventoryOverlay.apply` counts cached-host merges; Combine subscriptions
count warning and load-state publications. The test does not connect to real
hosts or open terminal clients.

| Work before a loader returns | Before | After |
| --- | ---: | ---: |
| Cached-host merges | 8 | 0 |
| Unchanged sidebar warning/state publications | 24 | 0 |

The retained regression test is
`WorkspaceSharedInventoryTests.refreshDoesNotRepublishUnchangedSidebarState`.
The merge instrumentation was temporary; snapshot equality alone cannot count
unnecessary merges. These are work counts, not elapsed-time or frame-rate
measurements. They do not establish that every source of perceived lag is gone.

The disclosure regression separately hosts two real `RootView` windows sharing
the same preferences. Pressing a session group's disclosure in one previously
collapsed both; it now changes only the targeted window. Disclosure state is
stored as parsed sets, eliminating the old per-check string parsing. The
app-wide disclosure preference predates `4c8bd7ed`.

## Application reactivation

Packaged builds check the persisted telemetry preference on each application
activation. `SettingsStore.refreshShareAnonymousUsageData` previously assigned
its published property even when the value was unchanged. Both `WorkspaceWindow`
and `RootView` observe this shared store, so the assignment invalidated every
window. The refresh now publishes only a changed preference; changes made by
another process still take effect.

The activation gate hosts two `RootView` windows with 100 or 500 synthetic tmux
sessions per window, using stable session identities and expanded session groups.
Ten unchanged preference refreshes caused 20 root-body evaluations at both sizes
before the fix and zero afterward. Section computations remained zero. This
measures the refresh invoked by telemetry, without sending telemetry events.

Retained live previews also resumed rendering synchronously on application
reactivation, before checking whether their scene was key. A non-key scene then
suspended and unparked those same surfaces. Rendering now resumes through the
existing delayed parking path after checking application activity, sidebar
visibility, preview mode, and scene focus. Efficient capture retries retain their
existing behavior. Preview changes that cancel the timer preserve pending
reacquisition and reschedule the delay; cancellation does not permit immediate
rendering or mounting the remaining fleet at once. Only successful mounts consume
a parking slot. If the parking host or a surface is unavailable, reacquisition
stays pending and pauses until a host or presentation event reschedules the delay.
Healthy previews continue their regular captures without polling for missing
views. The terminal regressions use real libghostty surfaces to check delayed
key-scene resume, no mounted-surface resume in a non-key scene, and deferred
mounting when a missing host or surface becomes available.

`make test-activation-gate` includes these regressions. These are deterministic
work checks, not end-to-end Command-Tab latency measurements. The broader
first-responder and latency benchmark remains tracked by `360m`; row construction
and hover measurements remain `s921`. Resource sampling already defers its first
sample on reactivation. Inventory still refreshes on return to the app, preserving
the existing freshness and stale-load replacement contracts.

## Inventory updates

`WorkspaceInventoryStore` publishes on each loading transition and each result.
Previously, `WorkspaceSceneModel.consumeSharedInventory` reapplied every cached
host on every publication, even when its revision checks found no new inventory.
This regressed the host-scoped application used before `4c8bd7ed`. With H hosts
and W windows, an ordinary successful KWT/tmux refresh cycle could perform
4 × W × H² cached-host merges. Explicit refresh adds invalidation publications.

Consumption now applies only hosts with new inventory or availability state.
Loading-only transitions still update progress and attempt restoration.
Successful observations still reconcile retained presentations and quarantined
removals, including when inventory content is unchanged. Warning and load-state
properties publish only when their values change.
Actual refresh-completion transitions still notify each scene, including a
refresh that returns identical data, so sidebar cleanup sees completion.

A worktree selection also records its last-viewed time in persistence and
replaces the scene snapshot. The unchanged-host branch then refreshes its
subscription and reapplies cached inventory. Removing the unconditional merge
from consumption eliminates one of the two full overlays formerly reached by
that path. Identical subscriber registration still recomputes subscriber host
sets; avoiding that work is a smaller remaining opportunity.

## Expanded-row measurements (September 11)

The follow-up compares ten session selections at 100 and 500 stable synthetic
sessions per host. Two real `RootView` windows use isolated preferences; tmux
groups are expanded, previews are off, and selection changes in one window.
The baseline is `ec8f8d4b` plus the same measurement instrumentation. The
measurements use a Debug build on Apple Silicon with macOS 26.6.2.

| Sessions | Drag items built before | After | Selection median before | After |
| --- | ---: | ---: | ---: | ---: |
| 100 | 110,000 | 1,100 | 22 ms | 20 ms |
| 500 | 2,750,000 | 5,500 | 186 ms | 131 ms |

These are representative samples, not timing thresholds. The timed interval
includes selection publication, a 1 ms run-loop turn, and hosting-view layout;
it does not establish display presentation time. Row evaluations remain 1,111
and 5,511 respectively. Cached sections are not recomputed. The remaining
131 ms at 500 rows is still too expensive for frequent interaction.

The sidebar now builds one sibling drag array per expanded group, including
worktrees, and shares it among the group's rows. It constructs Herdr actions
only for Herdr rows, avoiding a discarded second tmux killability scan. Preview
rows skip session resolution when previews are off, and empty saved ordering
preserves input order without sorting. Existing ordering and lifecycle action
coverage remains in place.

The initial `ActivationWorkGateTests.sidebarSelectionWork` gate bounded drag
construction relative to actual row evaluations at both sizes. Window activation
also runs against 100 and 500 sessions while retaining the existing root/section
budgets. Timing output is report-only.

## Expanded worktree projects (September 11)

A second fixture opens a project with 100 or 500 synthetic worktrees in the
same two-window harness. Previews are off. Disclosure uses an accessibility
press with enhanced accessibility enabled; these timings are not ordinary
mouse-click or visible-frame measurements. The baseline is `87c7009e` with
the same fixture. Selection again includes publication, a 1 ms run-loop turn,
and layout.

| Worktrees | Disclosure before | After | Selection median before | After |
| --- | ---: | ---: | ---: | ---: |
| 100 | 797 ms | 189 ms | 121 ms | 42 ms |
| 500 | 13,101 ms | 187 ms | 779 ms | 45 ms |

Sampling the baseline test worker during disclosure found most main-thread
work in SwiftUI accessibility focus updates and responder traversal. Wrapping
each expanded project's worktrees in a native `LazyVStack` reduced disclosure
row evaluations from 312/1,512 to 105 at both sizes. Ten selections now evaluate
740 rows at either size, down from 2,120/10,120. Sibling drag metadata still
includes the full project, preserving reorder targets.

Lazy layout applies only when previews are off. Preview-enabled modes keep
their expanded rows mounted because preview lifetime also controls capture
and parking eligibility. This patch does not change that contract. Changed-file
expansion and cached results belong to the sidebar; an offscreen panel's polling
task stops and resumes on remount, as it already does on ancestor collapse.

`ActivationWorkGateTests.expandedWorktreeInteractions` bounds row construction
independently of inventory size, scrolls to the final worktree and selects it
through accessibility, then checks that an expanded Changes panel survives
scrolling away and back. Timing output remains report-only.

## Session row layout (September 12)

The same native lazy layout now applies to expanded tmux session groups when
previews are off. The baseline is merged PR #245 (`12fbebc5`), with the worktree
layout change above applied. The fixture still uses two 1000 × 700 windows and
times ten selections, including the 1 ms run-loop turn and layout.

| Sessions | Selection median before | After | Row evaluations before | After |
| --- | ---: | ---: | ---: | ---: |
| 100 | 19.7 ms | 5.9 ms | 1,111 | 165 |
| 500 | 130.9 ms | 6.5 ms | 5,511 | 165 |

The selection gate now bounds row construction independently of inventory size
and separately bounds the full sibling drag list. It scrolls to the final session
and selects it through accessibility, checking that deferred rows remain reachable.
An Always Live check mounts 100 synthetic preview views through the real sidebar
callbacks and verifies that scrolling does not release their eligibility. This
UI fixture does not open terminal clients; the activation gate separately checks
the real coordinator and libghostty surfaces.

Synthetic mouse-enter and mouse-move events did not trigger SwiftUI hover updates
in this session. Those samples were rejected because no row work occurred; they
do not establish that hover is free or that its latency improved. Actual hover,
display presentation, and typing latency still need separate measurements.

## Remaining rendering costs

These costs are established by source inspection. Their individual contributions
to the measured selection time have not been isolated.

1. **Rows repeat linear inventory lookups.** Each tmux row still scans the host's
   sessions for killability. Worktree and enabled-preview builders resolve the
   same worktree repeatedly. Reuse known row data where it preserves the active
   connection and protected-workspace contracts.
2. **Hover invalidates the whole sidebar.** Hover state and dismissal tasks
   belong to `WorkspaceSidebarView`. Herdr and Zellij groups, and preview-enabled
   tmux and worktree groups, still eagerly construct expanded rows. Row views can
   own hover state, following the existing `ProjectRemovalButton` pattern.
   Measure row construction and layout before changing virtualization; an outer
   `LazyVStack` alone leaves eager descendants.
3. **Section-cache misses scan the fleet repeatedly.**
   `WorkspaceSidebarModel.sections` filters all worktrees per project and all
   terminal sessions per worktree. Populated saved ordering rebuilds its full
   position index per group. Group inputs once per computation before adding
   more retained caches.
4. **Multiple expanded Changes panels share result observation.** Each panel
   observes the store's entry dictionary. A changed result can reevaluate other
   mounted panels, although unrelated sidebar rows no longer rebuild. Measure
   several expanded panels before introducing finer observation per worktree.

Hover, scrolling latency, preview-enabled projects, and multiple changed-file panels
still need separate interaction measurements under `s921`. The broader
activation side-effect and causality contract remains under `360m`.

## Changed-file publication (September 12)

A hosted sidebar with 100/500 synthetic worktrees opens one project's first
Changes panel through accessibility. Previews are Off. The real polling loop
reads synthetic results through its loader boundary; a controlled sleep releases
one poll at a time. Ten identical results provide the control, followed by ten
results that each change one displayed filename. The test checks the resulting
accessibility label after every result. It also checks manual Refresh and loading
again after collapsing and reopening the panel.

| Worktrees | Identical result, before → after | Changed result, before → after | Unrelated rows, before → after |
| --- | ---: | ---: | ---: |
| 100 | 2.1 → 2.1 ms | 17.7 → 4.5 ms | 390 → 0 |
| 500 | 2.2 → 2.1 ms | 19.1 → 4.5 ms | 390 → 0 |

Times are representative medians from Debug builds on macOS 26.6.2 with a
320 × 700 sidebar and enhanced accessibility enabled. They include releasing
the poll, its asynchronous comparison/publication, a requested 1 ms polling
sleep, and hosting-view layout. Counts cover ten results. Identical results
rebuild zero rows before and after; section computations remain zero throughout.
These are not display-presentation measurements and exclude the real helper,
network, and normal five-second polling interval.

Previously the sidebar observed every store publication. Native property
observation now tracks expansion at sidebar scope and results in a child
Changes panel, which also owns the existing polling task. The sidebar still
retains expansion and cached results across unmounts. Identity checks, retry
policy, and request coordination are unchanged. The row-work regression fails
before this change and passes afterward, while checking that filenames update.
This establishes the rendering cost of a changed result; it does not attribute
the reported everyday typing lag to changed-file polling.

## Terminal input probes

The input smoke tests previously launched bare `python3`. With a mise shim,
libghostty's login-style argument zero became `-python3`, and the probe exited
before reading input. A direct Python path also needs a normal argument zero to
locate its standard library. Both test launchers now select Python with
`uv python find`; the tests launch it through `/usr/bin/env`. Production shell
startup and shell integration are unchanged. The real Ctrl-A and Option-D
regressions fail before this change and pass afterward.

Run `make benchmark-input` after bootstrapping libghostty to measure a local
PTY and an isolated native tmux client with 100/500 sidebar sessions, previews
off, and the sidebar shown/hidden. It uses the standard Swift test runner,
temporary preferences/configuration, and the standard private tmux server
fixture. It does not attach to existing sessions. The test shuts down every
terminal surface before returning.

Keys enter through `NSApplication.sendEvent` with two installed application
shortcut monitors, matching the per-scene production setup. Each phase checks
that all 35 keys reach both monitors. This covers application dispatch and
shortcut translation as well as window/terminal handling; event queueing before
dispatch remains outside the measurement.

For each scenario, five warmup keystrokes precede 30 measured `x` events. A raw
Python probe writes a small, uniquely numbered response. The benchmark reports
key-dispatch and key-to-libghostty-text-viewport timing, plus the longest
main-actor echo-poll delay (`longest_echo_poll_ms`). Polling requests a 1 ms
sleep, so scheduler delay sets a lower bound on observed echo time. The
rendered-layer extension below also checks pixels and attempts both vsync
settings. Normal terminal smoke tests continue to disable vsync; production
defaults are unchanged.

Window-refocus samples require both windows to actually become key. If this
session cannot deliver key-window transitions, the report explicitly says
`refocus=unavailable`; a retained first responder alone is insufficient proof.
These switches are between test windows, not Command-Tab from another app.
Refocus timing starts before making the terminal window key, so its dispatch
and echo measurements include the activation work.
Remote transport, active preview workloads, real application activation,
full-screen terminal workloads, and display presentation remain under `w8v8`.

On September 11, the six steady-input scenarios reported median echo times of
1.2–2.2 ms and p95 times of 2.2–2.3 ms. Dispatch p95 stayed below 0.08 ms;
the longest polling delay was 4.3 ms, including its requested sleep. This
small-line echo workload did not reproduce the reported typing lag. These are
text-viewport observations, not visible-frame timings. Window-refocus delivery
was unavailable, including through the AppKit launcher; that launcher's process
inspection/cleanup also failed after its benchmark test passed. No activation
latency conclusion is drawn from those attempts.

Repeating the local input benchmark with lazy sidebar rows on September 12
gave median text-viewport echo times of 1.2–2.2 ms and p95 below 2.3 ms.
Window-refocus delivery remained unavailable. The steady small-line workload
still did not reproduce the reported typing lag.

### Input overlapping changed inventory (September 12)

The benchmark now also changes an offscreen session's window count immediately
after each key dispatch, publishes the snapshot through an observed model, and
forces hosting-view layout before looking for the echo. It uses the normal
sidebar section cache and advances its snapshot revision on each publication.
This deliberately overlaps every key with refresh work; it does not represent
the app's refresh frequency or include inventory loading and scene reconciliation.

The comparison temporarily restores the eager tmux rows from merged PR #245,
then repeats with the pending lazy layout. Both use Debug builds, previews Off,
960 × 640 windows, five warmup keys, and 30 measured keys per phase. Timings below
measure snapshot publication and layout on the main thread after key dispatch.

| Sessions | Sidebar | Direct PTY, eager → lazy | Native tmux, eager → lazy |
| --- | --- | ---: | ---: |
| 100 | Shown | 19.9 → 3.4 ms | 21.1 → 3.4 ms |
| 500 | Shown | 134.9 → 5.2 ms | 136.1 → 5.2 ms |
| 500 | Hidden | 135.7 → 5.2 ms | 128.0 → 5.3 ms |

These are representative medians. Across all 35 publications, eager rows
evaluate 3,535/17,535 times at 100/500 sessions; lazy rows evaluate 455 times at
either size. Each phase recomputes sections 35 times. Terminal geometry checks
confirm that the hidden-sidebar case gives its space back to the terminal.
Hiding moves the sidebar out of view and makes it transparent; its mounted
content still updates. Hiding alone therefore does not isolate sidebar work.

The measured echo interval includes this forced layout and the subsequent
text-viewport read. It does not establish when the echo first became available
during layout, when a frame reached the display, or how long real keyboard
events waited before dispatch. A zero polling delay means the first read after
layout already found the echo. The unchanged-inventory phases still report
roughly 1–2 ms median echo times with no counted root or row evaluations.
Key-window transitions remain unavailable in this runner.

This comparison reproduces expensive main-thread inventory rendering with
previews Off and shows that lazy rows reduce it. It does not establish that
inventory refresh is the cause of the reported everyday typing lag. Changed-file
publication, application activation, and display timing remain unmeasured here.

### Rendered-layer probe (September 12)

The raw probe now also alternates one cell on the third line between black and
white for each key. The test first waits for the initial black cell, then checks
each response's opposite color in the IOSurface held by the terminal layer's
`contents`. The marker is separate from the text and cursor. Isolated test
configuration sets zero padding and an opaque background so the pixel position
comes directly from the actual cell dimensions. Each key waits for both its
numbered text response and its rendered marker before sending the next key.

In the pinned libghostty Metal path, the command-buffer completion callback
assigns the completed IOSurface to the layer, dispatching to the main queue for
asynchronous frames. `frame_ms` measures when the test observes those pixels in
the layer's model contents. It includes polling/readback overhead and any forced
inventory layout. The echo-poll metric excludes these later frame-poll waits.
It does not measure compositor consumption, display scanout,
physical-keyboard latency, or the age of an event waiting before dispatch.

Representative Debug results with previews Off and vsync disabled:

| Workload | Text response median | Rendered-layer median |
| --- | ---: | ---: |
| Steady input, all PTY/tmux scenarios | 1.1–2.2 ms | 1.2–2.3 ms |
| Inventory overlap, 100 sessions shown | 4.2–4.3 ms | 6.2–6.4 ms |
| Inventory overlap, 500 sessions shown/hidden | 5.7–6.5 ms | 7.9–8.4 ms |

Each phase records 35 keys, including five warmups. Steady input caused no root,
section, or sidebar-row evaluations. The runtime recorded 37 wakeup callbacks
for the PTY phases and 57–60 for tmux; inventory-overlap phases recorded 35.
These counts measure callbacks processed, not their execution cost or queue depth.
The workload now includes the colored cell and waits for rendering, so these
samples are not an exact repeat of the earlier text-only workload.

The vsync-enabled surface failed to initialize in this runner. A direct
`CGGetActiveDisplayList` query returned success with zero active displays,
matching libghostty's display-link initialization precondition. The benchmark
now reports `vsync=true unavailable (active_displays=0)` in that condition;
other initialization failures still fail the test. It checks the loaded vsync
value for runtimes it creates. Key-window delivery also remains unavailable.
Run `make benchmark-input` in an active macOS desktop to obtain the missing
vsync samples; that path remains unverified here. The current results do not
justify changing production renderer settings or establish the cause of the
reported everyday typing lag.

### Application event dispatch (September 12)

The user reports lag in both local and remote sessions with previews Off.
The earlier benchmark dispatched directly to the terminal window, bypassing
application event monitors. With application dispatch and two real shortcut
monitors installed, all 12 available PTY/tmux phases passed. Median rendered
layer timing was 1.3–1.6 ms steady and 7.9–8.2 ms during 500-session inventory
overlap. Dispatch p95 stayed below 0.1 ms. These measurements still use the
synthetic sidebar fixture and vsync disabled, not the full application scene.

A separate temporary probe called the real shortcut monitor for 1,000 ordinary
letter events. Median processing took about 1 microsecond with one monitor and
9 microseconds across ten monitors. Each monitor did translate and look up every
key, but that cost does not explain millisecond-scale lag in this probe. No
production shortcut change was justified. Background scene reconciliation,
output-heavy workloads, event queueing, and production-vsync timing remain open.
