# Terminal Configuration Reload Notice Design

## Problem

`LibghosttyRuntime.configReloadNotice` is app-wide `@Published` state. An
explicit successful reload assigns a success notice that remains stored after
each window's local banner timer expires. Because `@Published` replays its
current value to new subscribers, every workspace window opened afterward
presents the old success notice as though another reload occurred.

## Required Behavior

- A reload outcome is broadcast to every workspace window that exists when the
  reload occurs.
- A workspace window opened later does not replay an earlier successful reload.
- An active reload or monitoring error remains available to a window opened
  later because it describes the runtime's current degraded state.
- Successful automatic reloads remain silent.
- Successful explicit reload banners retain their existing automatic dismissal
  timing, and error banners remain until dismissed or superseded.

## Design

Separate the runtime's retained notice state from its presentation event stream.
`LibghosttyRuntime` will keep the current notice available for diagnostics and
active-error recovery, while a non-replaying Combine publisher broadcasts new
notice changes to currently subscribed windows.

All notice publication and clearing will pass through runtime-owned methods so
the retained state and event stream cannot diverge. Publishing a success or
error updates the retained state and emits the same value. Clearing a notice
updates the retained state and emits `nil` so existing windows remove any
superseded banner.

`WorkspaceWindow` will subscribe to the non-replaying stream rather than the
`@Published` property. On appearance, it will seed its local banner only from a
currently retained error. It will never seed from a retained success. Therefore
all windows already subscribed receive a fresh explicit reload result, while a
new window receives only an ongoing failure that still needs attention.

The unavailable-terminal runtime will expose the same interface so the app
continues to compile in configurations without linked libghostty artifacts.

## Data Flow

1. Explicit or automatic reload logic produces a success, failure, warning, or
   clearing outcome.
2. The runtime updates its retained notice and sends the outcome through the
   non-replaying stream.
3. Every currently open `WorkspaceWindow` updates its local banner state.
4. A later window subscribes without receiving old stream events and restores
   only a retained error, if one exists.

## Testing

Add the narrowest regression coverage around the runtime-owned event contract:

- A subscriber present before an explicit successful reload receives its
  success notice.
- A subscriber added after that reload does not receive the retained success.
- Existing error-state coverage continues to prove that failures remain stored
  and successful automatic reloads clear resolved errors.

The production mutation caught by the new test is replacing the non-replaying
event stream with a replaying current-value stream. Validate the focused test,
then run the repository-mandated terminal regression checks:
`make test-libghostty-bootstrap`, `make python-test`, `swift test`, and
`make build`.

## Documentation and Scope

This fix restores the behavior already described in `docs/terminal-sessions.md`:
explicit reloads present their result, successful automatic reloads are silent,
and errors remain visible until dismissed or superseded. It does not change
configuration loading, window creation, banner copy, or banner appearance, so no
Guide or screenshot update is required.
