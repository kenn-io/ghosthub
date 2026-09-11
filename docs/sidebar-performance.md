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

`ActivationWorkGateTests.sidebarSelectionWork` bounds drag construction relative
to actual row evaluations at both sizes. The old implementation fails at both
sizes. Window activation also runs against 100 and 500 sessions while retaining
the existing root/section budgets. Timing output is report-only.

## Remaining rendering costs

These costs are established by source inspection. Their individual contributions
to the measured selection time have not been isolated.

1. **Rows repeat linear inventory lookups.** Each tmux row still scans the host's
   sessions for killability. Worktree and enabled-preview builders resolve the
   same worktree repeatedly. Reuse known row data where it preserves the active
   connection and protected-workspace contracts.
2. **Hover invalidates the whole sidebar.** Hover state and dismissal tasks
   belong to `WorkspaceSidebarView`; nested ordinary `VStack` containers eagerly
   construct expanded groups. Row views can own hover state, following the
   existing `ProjectRemovalButton` pattern. Measure row construction and layout
   before changing virtualization; an outer `LazyVStack` alone leaves eager
   descendants.
3. **Section-cache misses scan the fleet repeatedly.**
   `WorkspaceSidebarModel.sections` filters all worktrees per project and all
   terminal sessions per worktree. Populated saved ordering rebuilds its full
   position index per group. Group inputs once per computation before adding
   more retained caches.
4. **Changed-file updates observe at sidebar scope.** `WorktreeChangesStore`
   publishes its entry dictionary to the sidebar. A changed panel can invalidate
   unrelated rows. Unchanged successful polls already suppress publication;
   blaming every five-second poll would be incorrect.

Expanded worktree projects, hover, disclosure, scrolling, and one changed-file
result still need separate interaction measurements under `s921`. The broader
activation side-effect and causality contract remains under `360m`.

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

For each scenario, five warmup keystrokes precede 30 measured `x` events. A raw
Python probe writes a small, uniquely numbered response on the current line.
The benchmark reports key-dispatch and key-to-libghostty-text-viewport timing,
plus the longest main-actor polling delay. Polling requests a 1 ms sleep, so
scheduler delay sets a lower bound on observed echo time. The benchmark does
not time Core Animation presentation or physical display refresh, and the
terminal smoke runtime disables vsync.

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
