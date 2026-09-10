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

## Remaining rendering costs

These costs are established by source inspection, not timing measurements.
They mostly predate `4c8bd7ed` and deserve a separate rendering benchmark.

1. **Reorder metadata grows quadratically within a group.**
   `WorkspaceSidebarView.hostContents` maps all worktree IDs inside each row's
   construction, and `worktreeButton` maps them again into drag items. The
   session-row builders similarly reconstruct all siblings for every row.
   Build one drag-item array per group and pass it to its rows.
2. **Rows repeat linear inventory lookups.** `sidebarButton` computes tmux
   killability, calls the general action builder, and then discards that
   builder's tmux/Zellij actions. The second call repeats the tmux session scan.
   Worktree and preview builders also resolve the same worktree repeatedly.
   Reuse known row data and invoke the Herdr action builder only for Herdr rows.
3. **Hover invalidates the whole sidebar.** Hover state and dismissal tasks
   belong to `WorkspaceSidebarView`; nested ordinary `VStack` containers eagerly
   construct expanded groups. Row views can own hover state, following the
   existing `ProjectRemovalButton` pattern. Measure row construction and layout
   before changing virtualization; an outer `LazyVStack` alone leaves eager
   descendants.
4. **Section-cache misses scan the fleet repeatedly.**
   `WorkspaceSidebarModel.sections` filters all worktrees per project and all
   terminal sessions per worktree. `WorkspaceSidebarOrder.ordered` rebuilds
   its full position index per group, even for empty saved ordering. Group
   inputs once per computation and reuse order indexes before adding caches.
5. **Changed-file updates observe at sidebar scope.** `WorktreeChangesStore`
   publishes its entry dictionary to the sidebar. A changed panel can invalidate
   unrelated rows. Unchanged successful polls already suppress publication;
   blaming every five-second poll would be incorrect.

`make test-activation-gate` covers root-body evaluations and section-cache
computations for two small windows. It does not measure row construction,
hover, layout, scrolling, or inventory merging. The next useful benchmark is
100 versus 500 synthetic rows, with projects expanded and previews off,
measuring selection, pointer movement, disclosure, and one changed-file result
separately. Session fixtures need stable tmux identities so action controls
participate in the measurement.
