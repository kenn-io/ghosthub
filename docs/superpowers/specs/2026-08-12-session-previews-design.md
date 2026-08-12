# Tmux Session Previews

**Status:** Proposed local design artifact

## Purpose

Ghosthub should optionally show miniature previews of already-opened tmux
sessions in the sidebar. A preview represents the complete native tmux client
that Ghosthub already presents. It does not expose or reconstruct tmux windows,
panes, layout, history, or terminal state in Swift.

The feature must remain off by default because continuous terminal rendering
and image capture consume graphics processing unit (GPU) time and memory. When
enabled, it must reuse retained presentations and must never open another tmux
or Secure Shell (SSH) client merely to produce a preview.

## Scope

The first version supports tmux presentations that have already been opened in
the current Ghosthub launch. This includes tmux sessions owned by worktrees,
registered directory workspaces, and otherwise-unbound tmux rows. It excludes:

- unopened discovered sessions;
- Herdr and Zellij sessions;
- the Console Panel;
- previews of individual tmux windows or panes;
- SVG or other vector reconstruction of terminal frames;
- persisted preview images;
- high-frame-rate animation.

The source is an already-rasterized IOSurface. Encoding that frame as SVG would
only wrap raster pixels and would not make terminal text or graphics truly
resolution-independent. A future temporary zoom view may enlarge the immutable
bitmap, but vector terminal reconstruction is outside this design.

## User Experience

Settings -> Terminal exposes a **Session previews** picker with three values:

- **Off** (default): Ghosthub shows ordinary rows and performs no preview
  capture or preview-only rendering.
- **Efficient**: Expanded previews show a recent immutable frame. Ghosthub
  captures when the preview expands while its session is active and immediately
  before navigation unmounts the active session. Inactive sessions keep their
  last captured frame.
- **Live**: Expanded previews refresh at no more than two frames per second.
  The active session is captured from its normal onscreen surface. Eligible
  inactive sessions continue rendering in a noninteractive parking host inside
  a visible workspace window.

When previews are not Off, an already-opened tmux row gains a disclosure
control. Rows start collapsed. Expansion state belongs to the workspace scene,
is memory-only, and lasts until that scene closes. This deliberately differs
from the global, durable disclosure state for the existing host and project
hierarchy. Switching to Off hides the controls but preserves the scene's
expansion set, so restoring Efficient or Live during the same launch restores
the user's layout.

An expanded tile uses the available sidebar width with a 16:10 frame. The
captured session image uses `scaledToFit`; Ghosthub letterboxes it with the
terminal background and never crops it. Clicking the tile performs the same
selection as clicking its session row.

The tile can show these restrained states:

- a quiet terminal placeholder before the first successful capture;
- the latest frame and its relative update time;
- a Live indicator while the tile is refreshing;
- a reconnecting or disconnected placeholder while server-side session
  identity is unverified;
- **Live preview limit reached** when an inactive expanded tile cannot obtain a
  live-rendering slot.

VoiceOver identifies the session, whether its preview is live or retained, its
relative update time when available, and any connection or limit status. The
ordinary session row remains the primary selection control.

## Existing Constraints

Every retained tmux presentation owns one `TerminalSurfaceView`. An AppKit view
can have only one parent. `TerminalSurfaceRepresentable` returns that shared
view rather than creating a mirror, so an active surface cannot appear in the
detail area and a preview host simultaneously.

Detached surfaces are marked occluded in `TerminalSurfaceView.viewDidMoveToWindow`
and stop rendering. An ordered-out or genuinely offscreen window is also
occluded. A live inactive preview must therefore keep the real surface attached
to the visible workspace window without displaying or resizing it.

The pinned macOS libghostty path does not emit `GHOSTTY_ACTION_RENDER`. That
action is only emitted when the application thread must draw, which does not
apply to this embedded macOS renderer. The existing `SurfaceRenderTracker`
plumbing is not a usable preview refresh signal. Session previews must not
depend on it.

## Architecture

### Preferences

`SessionPreviewMode` is an enum in `GhosthubSettings` with `off`, `efficient`,
and `live` cases. `SettingsStore` persists it through the same UserDefaults
pattern as other application preferences. The compiled default is `off`.

Changing modes has immediate effects:

- Live -> Efficient takes a final snapshot of each parked surface, unparks all
  inactive surfaces, and keeps their cached images.
- Efficient or Live -> Off unparks all surfaces and clears every cached preview
  image and timestamp.
- Off or Efficient -> Live evaluates the currently expanded eligible rows for
  live-rendering slots.

### Scene Preview Coordinator

Each `WorkspaceSceneModel` owns a `TmuxSessionPreviewCoordinator`. It connects
sidebar expansion, retained-presentation lifecycle, window and application
visibility, surface ownership, capture scheduling, and the application-wide
live-preview budget.

Preview state is keyed by the retained presentation identity used by
`TmuxPresentationKey`: host ID, exact session name, and optional protected
socket name. That endpoint key is not sufficient authority to reuse terminal
pixels: every successful capture also records the presentation's verified
`TmuxSessionIdentity` (tmux server PID, session ID, and creation time). Sidebar
row UUIDs are not presentation identity. A worktree generation change is still
a replacement event even when it reuses the same key, and the coordinator
clears the old preview explicitly.

The coordinator publishes small view state objects containing the image,
capture date, connection status, live state, and placeholder reason. SwiftUI
rows do not own surfaces, timers, or capture operations.

### Snapshot Capture

`TerminalSurfaceSnapshotter` is an AppKit component in `GhosthubTerminal`. It
reads the current IOSurface-backed `CALayer.contents`, compares the IOSurface
seed with the seed from the previous successful capture, and copies a changed
frame into an immutable `CGImage`/`NSImage` at the requested preview size.

The snapshotter follows these rules:

- execute surface and layer access on the main actor;
- serialize and coalesce requests per surface;
- copy the currently published IOSurface into immutable image storage rather
  than retaining the mutable IOSurface as the thumbnail;
- skip a Live bitmap copy and timestamp update when `IOSurfaceGetSeed` is
  unchanged;
- preserve the source aspect ratio and letterbox into the 16:10 output;
- report failure without changing terminal or attachment state.

Efficient mode has no timer. The coordinator captures an active surface when
its row first expands and captures every outgoing active tmux surface in the
active-presentation transition immediately before another presentation
replaces it in the detail area. Capturing every outgoing surface makes a frame
available if the user expands that inactive row later. The retained layer
contents remain a fallback capture source after SwiftUI removal, but the
explicit pre-unmount hook is the primary ordering contract.

Live mode uses one coalescing timer source per scene, scheduled no faster than
every 500 milliseconds. A tick captures the active onscreen surface when its
preview is expanded and captures every expanded inactive surface currently
granted a parking slot. It does not poll collapsed rows. Efficient capture
hooks and Live ticks run only while the application is active and the sidebar
is visible.

### Active Surface Handling

The active session remains mounted only in the normal detail presentation.
Its expanded Live tile snapshots the onscreen view. Expanding, collapsing, or
capturing the active tile never reparents the view and never changes its
terminal dimensions or focus state.

Clicking an active session's own preview is an idempotent selection. Clicking
an inactive parked preview performs this ordered handoff:

1. stop scheduling captures for the parked surface;
2. take a final snapshot when possible;
3. set the surface occluded by removing it from the parking host and release
   its live-preview slot;
4. activate the retained presentation;
5. let the existing `BorrowedTmuxSessionView` path mount the surface, clear
   `isParkedForPreview`, restore key-view eligibility, reset
   `suppressAutoFocus` to false, and request keyboard focus.

At no point does the surface have two parents.

### Live Preview Parking

`LivePreviewParkingHost` is an AppKit container installed behind opaque detail
content inside each visible workspace window. It is not an offscreen or
ordered-out window. The parking host keeps an inactive surface attached to the
same visible window so libghostty continues rendering while the sidebar shows
only an immutable image.

Parking obeys these invariants:

- set an explicit `isParkedForPreview` state before attachment; while set,
  `TerminalSurfaceView.acceptsFirstResponder` returns false, the view has no
  next/previous key-view links, and any existing first-responder/focused state
  is resigned before the surface enters the parking host;
- set `suppressAutoFocus = true` before attaching the surface because
  `viewDidMoveToWindow` otherwise requests first responder in a key window;
- bypass `BorrowedTmuxSessionView` and its focus-requesting `onAppear` path;
- preserve the surface's existing bounds, frame size, and backing scale so
  `viewDidMoveToWindow` cannot reflow the tmux client grid;
- stack parked surfaces behind an opaque cover instead of sizing them to the
  preview tile;
- disable interaction structurally: the parking container returns `nil` from
  `hitTest(_:)`, exposes no accessibility children, and installs no input or
  focus handlers;
- unpark all surfaces when the application becomes inactive or the sidebar is
  hidden, then reacquire slots when the gate reopens.

A failure to park degrades that tile to Efficient behavior and does not disturb
the retained attachment.

### Application-Wide Live Budget

An application-scoped `LivePreviewBudget` permits at most four inactive parked
surfaces across all workspace scenes. Active onscreen surfaces do not consume a
parking slot because they already render for ordinary use.

Slots are granted in expansion-request order. When a tile collapses, becomes
active, disconnects, is invalidated, loses visibility eligibility, or leaves
Live mode, it releases its slot. The oldest still-expanded eligible waiter is
then promoted. A waiting tile keeps its last frame and shows the limit status.

Separate scenes own separate tmux clients, terminal coordinators, and surface
views, even when they attach to the same server-side tmux session. The global
budget bounds aggregate resource use; it is not needed to resolve NSView parent
ownership between scenes.

## Data Flow

### Open and Expand

1. Opening a tmux session creates or reuses its normal retained presentation.
2. The preview coordinator observes that presentation and makes its sidebar row
   eligible for disclosure.
3. Expanding the active row in Efficient mode requests one snapshot.
4. Expanding an inactive row in Efficient mode shows its prior frame or the
   placeholder; it does not mount or poll the surface.
5. Expanding a row in Live mode either captures the active onscreen surface or
   requests a parking slot for the inactive surface.

### Navigate Away

1. Before changing the active retained presentation, the scene preview
   coordinator captures the outgoing active surface in Efficient mode. In Live
   mode it captures the outgoing surface only when its row is expanded.
2. In Efficient mode the surface unmounts normally and remains occluded.
3. In Live mode an expanded outgoing surface requests a parking slot. If
   granted, the parking host attaches it at the unchanged size with focus and
   hit testing disabled. Otherwise it remains unmounted with the final image.

### Reconnect and Replacement

A transport reconnect releases the stale parked surface and its budget slot.
The cached image remains quarantined and is not displayed while server-side
session identity is unverified; the tile shows a reconnecting or disconnected
placeholder derived from the existing per-handle
`borrowedTmuxConnectionStates`. When recovery verifies a
`TmuxSessionIdentity` equal to the identity recorded with the image, the
coordinator may display that image again and can capture or park the replacement
surface according to the current mode, expansion, visibility gates, and budget.
If recovery cannot verify the identity or observes a different server PID,
session ID, or creation time, the coordinator clears the quarantined image and
seed before presenting the replacement session.

Closing or invalidating a presentation clears both its parking state and cached
image. A replacement such as a new non-nil worktree generation under the same
session name also clears both, preventing pixels from the old session identity
from representing the replacement.

## Failure Handling and Privacy

- A failed capture preserves the prior image. If no prior image exists, the
  tile shows the quiet placeholder.
- A failed park or exhausted budget falls back to the latest retained frame.
- A closed surface, missing layer, unsupported layer content, or zero-sized
  frame cannot crash or fail the tmux attachment.
- Preview errors remain local to preview state and never enter connection
  recovery or attachment health.
- All images, IOSurface seeds, timestamps, expansion state, and queue state are
  memory-only. Ghosthub never writes terminal pixels to disk.
- Off mode releases cached terminal pixels promptly.

## Documentation and Acceptance Assets

Implementation changes the architectural wording that each scene presents only
one client. The maintained documentation and shared project instructions must
instead distinguish one **active interactive presentation** from retained tmux
clients whose surfaces may render only for explicitly enabled previews. Update:

- `docs/architecture.md`;
- `docs/terminal-sessions.md`;
- `AGENTS.md` and its `CLAUDE.md` counterpart/import;
- the website Guide with the preference, expansion behavior, mode costs, and
  four-preview limit.

At feature acceptance, capture a deterministic screenshot that shows an
expanded session preview without exposing real host, project, session, or
terminal data. Publish the refreshed screenshot binary to the orphan
`website-assets` branch as required by the repository workflow. A new Guide
section requires this screenshot even if no existing screenshot subject
changes.

This design document is a local Superpowers artifact. Remove it from the task
branch before any push, pull request creation, or pull request update.

## Verification

Use Swift Testing for new pure-logic coverage:

- preview-mode default, loading, and persistence;
- deterministic application-wide budget allocation, release, and waiter
  promotion;
- preview-state transitions among Off, Efficient, and Live;
- reconnect quarantining an image while releasing a stale parked surface, then
  restoring it only after equal `TmuxSessionIdentity` verification;
- missing or changed reconnect identity clearing the quarantined image;
- close, invalidation, and generation replacement clearing the image;
- active versus inactive capture routing;
- unchanged IOSurface seed suppression;
- capture failure preserving the last valid image.

Use the existing AppKit/libghostty terminal smoke harness where a real view and
window lifecycle are the behavior under test:

- parking preserves the surface size and terminal grid;
- parking sets `suppressAutoFocus` before window attachment and does not steal
  first responder;
- parked surface state refuses first responder, leaves the key-view loop, and
  resigns existing focus before attachment;
- the parking container rejects hit testing and accessibility exposure;
- a parked surface stays renderable in a visible covered host;
- the active preview captures without reparenting;
- clicking a parked preview performs capture, unmount, normal mount, and focus
  in that order;
- detaching or hiding releases occlusion and live-rendering state correctly;
- snapshot capture produces an immutable scaled frame from a real libghostty
  IOSurface without affecting terminal input.

Run the repository-required gates after implementation:

```sh
make format
make test-libghostty-bootstrap
make python-test
swift test
make test-essential-workflows
make build
```

Review the resulting diff for accidental pane projection, extra tmux/SSH
attachments, disk persistence of terminal pixels, focus regressions, terminal
grid resizing, and undocumented user-facing behavior.

## Acceptance Criteria

- Off is the default and performs no preview capture or preview-only rendering.
- Only already-opened retained tmux presentations can show previews.
- Efficient produces useful last-frame previews without timers or macOS render
  callbacks.
- Live updates expanded active previews and at most four inactive previews
  across the application at no more than two frames per second.
- Unchanged Live frames do not produce new bitmap copies.
- No preview creates another tmux or SSH client.
- Active surfaces are never reparented for capture.
- Parked surfaces cannot take focus, receive pointer input, or change terminal
  grid dimensions.
- Reconnects display a cached image only after equal `TmuxSessionIdentity`
  verification; missing or changed identity, close, invalidation, and
  generation replacement clear it.
- Preview failures never impair session attachment, reconnect, input, or close
  behavior.
- Preview images and state are never persisted.
- The Guide and acceptance screenshot accurately document the shipped UI.
