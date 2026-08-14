# Sidebar Navigation Lifetime Crash Design

## Problem

Ghosthub 0.8.2 can crash with `EXC_BAD_ACCESS` while SwiftUI evaluates
available keyboard shortcuts for a standalone tmux-session row. Ten open
workspace windows are normal operation and must remain stable.

The faulting main-thread stack retains the `name: String` associated with a
`WorkspaceNavigationTarget.tmuxSession`. The source enum tag is invalid, and
the corrupt words match live 32-bit process identifiers. Release-binary
disassembly shows the optimized `KeyboardNavigationModel.siblingTargets`
implementation releasing the outer sidebar-section array after a matching
row is found, then mapping the matching section's borrowed row array. A
resource sampler can reuse that freed storage for process-identifier arrays
before navigation finishes copying it.

The ten concurrent resource-sampling stacks in the crash report correspond
to ten independent workspace scenes. They increase allocation pressure, but
they do not share a sampling actor or make ten windows unsupported.

Tracked by kata issue `6y3t`.

## Scope

This change will make sibling navigation own its target arrays before it
checks or returns them. It will preserve existing ordering, visibility,
host-local grouping, project-local grouping, and stopped-Herdr filtering.

This change will not cache shortcut availability, share resource samplers
between scenes, reduce the supported number of windows, or change terminal
attachment behavior.

The investigation also found that `ProcessResourceMonitor` incorrectly
divides the return value from `proc_listchildpids` by the PID size. The API
already returns a PID count. That separate correctness bug is tracked by kata
issue `8tpw` and is not part of this crash fix.

## Design

`KeyboardNavigationModel.siblingTargets` will materialize an owned
`[WorkspaceNavigationTarget]` for each candidate sibling group while the
containing `WorkspaceSidebarSection` or `WorkspaceSidebarProject` is still
alive. It will then compare `currentTarget` with that owned array and return
the same array when it contains the target.

The implementation will use one small helper that converts
`[WorkspaceSidebarRow]` into owned targets and returns them only when they
contain the current target. Herdr rows will still be filtered to running
sessions before conversion. This removes the early-return pattern that
allows optimized code to keep only a borrowed nested row array.

No state, locks, caches, or new concurrency boundaries are needed. The
function remains deterministic and side-effect free.

## Testing

Existing keyboard-navigation tests will continue to verify exact sibling
ordering and eligibility for worktrees, directory workspaces, tmux, Herdr,
and Zellij sessions.

A new regression will exercise a ten-window-equivalent workload: ten
concurrent consumers repeatedly resolve tmux sibling targets from a snapshot
with heap-backed session names while another task generates short-lived PID
arrays. The test must validate exact targets, complete without a crash, and
run against optimized code as part of the focused verification.

The change will pass the focused UI tests, the complete Swift suite,
formatting, and `make build`. It does not touch terminal startup, discovery,
attachment, or release packaging, so the terminal regression matrix and
essential-workflow suite are not required by repository policy.

## Acceptance Criteria

- Ten open Ghosthub windows remain supported normal operation.
- Tmux sibling-shortcut evaluation never reads rows after their containing
  section storage is released.
- Sibling ordering and filtering remain unchanged for every backend.
- The allocation-pressure regression passes in an optimized build.
- Focused tests, `make swift-test`, `make format`, and `make build` pass.
